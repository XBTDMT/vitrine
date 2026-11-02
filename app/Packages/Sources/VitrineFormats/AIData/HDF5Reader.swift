import Foundation

/// An HDF5 file's structure (A-7; also netCDF-4 and Keras `.h5`): the superblock (versions 0 to 3), the group tree
/// walked through symbol tables (old-style groups) and link messages (compact new-style groups), and each dataset's
/// shape, datatype, layout, filters and attribute names. Best effort and bounded: what is not read (dense link or
/// attribute storage in fractal heaps, external files, shared messages) is listed in `notRead`, never guessed.
/// Checksums are not verified. roadmap: S-21
public struct HDF5Summary: Sendable, Equatable {
    /// What an entry in the tree is. roadmap: S-21
    public enum Kind: Sendable, Equatable {
        case group
        case dataset
        /// A committed (named) datatype.
        case namedDatatype
        /// A soft link and the path it points to.
        case softLink(String)
        /// A link into another file: the file and the path inside it.
        case externalLink(file: String, path: String)
        /// An object whose header could not be read; `note` says why.
        case unread
    }

    /// One entry of the tree, in depth-first order. roadmap: S-21
    public struct Object: Sendable, Equatable {
        /// `/`, `/group/dataset`.
        public var path: String
        public var name: String
        public var depth: Int
        public var kind: Kind
        /// A dataset's dimensions; [] for a scalar; nil for a null dataspace or when unknown.
        public var shape: [Int]?
        /// Maximum dimensions when the file states them; -1 stands for unlimited.
        public var maxShape: [Int]?
        /// The datatype in plain words: "32-bit signed integer, little-endian", "variable-length string".
        public var datatype: String?
        /// contiguous, chunked (with chunk dimensions), compact or virtual.
        public var layout: String?
        /// Filter names in pipeline order: deflate, shuffle, fletcher32, szip, …
        public var filters: [String]
        /// Attribute names stored in the object header, at most 100.
        public var attributes: [String]
        /// Why something about this object was not read.
        public var note: String?

        public init(path: String, name: String, depth: Int, kind: Kind, shape: [Int]?, maxShape: [Int]?,
                    datatype: String?, layout: String?, filters: [String], attributes: [String], note: String?) {
            self.path = path
            self.name = name
            self.depth = depth
            self.kind = kind
            self.shape = shape
            self.maxShape = maxShape
            self.datatype = datatype
            self.layout = layout
            self.filters = filters
            self.attributes = attributes
            self.note = note
        }
    }

    public var headline: String
    public var superblockVersion: Int
    /// Where the superblock was found (0, or after a user block at 512, 1024, …).
    public var superblockOffset: Int
    public var offsetSize: Int
    public var lengthSize: Int
    /// At most `maxObjects` entries.
    public var objects: [Object]
    public var objectsTruncated: Bool
    public var groupCount: Int
    public var datasetCount: Int
    /// Plain-English notes on structures this reader did not walk.
    public var notRead: [String]
    /// Path, kind, shape, datatype, layout and attributes for the first `AIDataTable.maxRows` entries.
    public var table: AIDataTable
    public var facts: [AIDataFact]
    public var warnings: [AIDataWarning]

    public static let maxObjects = 2_000
    public static let maxDepth = 32

    public init(headline: String, superblockVersion: Int, superblockOffset: Int, offsetSize: Int, lengthSize: Int,
                objects: [Object], objectsTruncated: Bool, groupCount: Int, datasetCount: Int, notRead: [String],
                table: AIDataTable, facts: [AIDataFact], warnings: [AIDataWarning]) {
        self.headline = headline
        self.superblockVersion = superblockVersion
        self.superblockOffset = superblockOffset
        self.offsetSize = offsetSize
        self.lengthSize = lengthSize
        self.objects = objects
        self.objectsTruncated = objectsTruncated
        self.groupCount = groupCount
        self.datasetCount = datasetCount
        self.notRead = notRead
        self.table = table
        self.facts = facts
        self.warnings = warnings
    }
}

enum AIHDF5Reader {
    static let signature: [UInt8] = [0x89, 0x48, 0x44, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The superblock sits at 0 or at a power of two from 512 on (after a user block).
    static func superblockOffset(_ bytes: [UInt8]) -> Int? {
        var offset = 0
        while offset + 8 <= bytes.count {
            if bytes[offset..<(offset + 8)].elementsEqual(signature) { return offset }
            offset = offset == 0 ? 512 : offset * 2
        }
        return nil
    }

    static func read(_ bytes: [UInt8], superblockAt offset: Int, context: AIReadContext) -> HDF5Summary {
        var walker = Walker(bytes: bytes, superblock: offset)
        walker.run()
        return walker.summary(context: context)
    }

    /// One object header's messages: type and the byte range of its data.
    struct Message {
        var type: Int
        var flags: UInt8
        var data: Range<Int>
    }

    struct Walker {
        let b: [UInt8]
        let superblock: Int
        var version = -1
        var o = 8
        var l = 8
        var base = 0
        var objects: [HDF5Summary.Object] = []
        var truncated = false
        var notRead: [String] = []
        var warnings: [AIDataWarning] = []
        var visitedGroups = Set<Int>()
        var headerReads = 0

        init(bytes: [UInt8], superblock: Int) {
            self.b = bytes
            self.superblock = superblock
        }

        // MARK: Bytes

        func u8(_ at: Int) -> Int? { at >= 0 && at < b.count ? Int(b[at]) : nil }

        func uint(_ at: Int, _ width: Int) -> UInt64? {
            guard width > 0, width <= 8, at >= 0, at + width <= b.count else { return nil }
            var v: UInt64 = 0
            for k in (0..<width).reversed() { v = v << 8 | UInt64(b[at + k]) }
            return v
        }

        func int(_ at: Int, _ width: Int) -> Int? { uint(at, width).flatMap { $0 <= UInt64(Int.max) ? Int($0) : nil } }

        /// A file address (relative to the base) as an index into the bytes; nil when undefined or out of range.
        func address(_ at: Int) -> Int? {
            guard let raw = uint(at, o) else { return nil }
            let undefined: UInt64 = o >= 8 ? .max : (UInt64(1) << UInt64(o * 8)) - 1
            guard raw != undefined, raw < UInt64(Int.max / 2) else { return nil }
            let absolute = base + Int(raw)
            return absolute >= 0 && absolute < b.count ? absolute : nil
        }

        /// `length` bytes from `start`, clamped to the bytes held; never a reversed or overflowing range.
        func span(_ start: Int, _ length: Int) -> Range<Int> {
            let s = max(0, min(start, b.count))
            let e = length <= 0 ? s : (length <= b.count - s ? s + length : b.count)
            return s..<e
        }

        func isUndefinedAddress(_ at: Int) -> Bool {
            guard let raw = uint(at, o) else { return false }
            return raw == (o >= 8 ? .max : (UInt64(1) << UInt64(o * 8)) - 1)
        }

        func matches(_ at: Int, _ text: String) -> Bool {
            let t = Array(text.utf8)
            return at >= 0 && at + t.count <= b.count && b[at..<(at + t.count)].elementsEqual(t)
        }

        func cString(_ at: Int, max: Int = 1024) -> String? {
            guard at >= 0, at < b.count else { return nil }
            var end = at
            while end < b.count, end - at < max, b[end] != 0 { end += 1 }
            return String(decoding: b[at..<end], as: UTF8.self)
        }

        // MARK: Superblock and walk

        mutating func run() {
            let s = superblock
            guard let v = u8(s + 8) else { return }
            version = v
            var rootHeader: Int?
            var rootScratch: (btree: Int, heap: Int)?
            switch v {
            case 0, 1:
                guard let os = u8(s + 13), let ls = u8(s + 14), [2, 4, 8].contains(os), [2, 4, 8].contains(ls) else {
                    warnings.append(AIDataWarning(.caution, String(localized: "The superblock is damaged: its address and length sizes are not 2, 4 or 8 bytes.", bundle: .module, comment: "HDF5 warning.")))
                    return
                }
                o = os; l = ls
                var p = s + 24 + (v == 1 ? 4 : 0)
                base = int(p, o).flatMap { $0 < b.count ? $0 : nil } ?? 0
                p += 4 * o  // base, free-space, end of file, driver information
                // The root group's symbol table entry.
                rootHeader = address(p + o)
                if uint(p + 2 * o, 4) == 1, let btree = address(p + 2 * o + 8), let heap = address(p + 3 * o + 8) {
                    rootScratch = (btree, heap)
                }
            case 2, 3:
                guard let os = u8(s + 9), let ls = u8(s + 10), [2, 4, 8].contains(os), [2, 4, 8].contains(ls) else {
                    warnings.append(AIDataWarning(.caution, String(localized: "The superblock is damaged: its address and length sizes are not 2, 4 or 8 bytes.", bundle: .module, comment: "HDF5 warning.")))
                    return
                }
                o = os; l = ls
                let p = s + 12
                let stated = int(p, o) ?? 0
                base = stated < b.count ? stated : 0
                rootHeader = address(p + 3 * o)
            default:
                warnings.append(AIDataWarning(.caution, String(localized: "Superblock version \(v) is newer than this reader knows (0 to 3); the structure was not read.", bundle: .module, comment: "HDF5 warning. The argument is a version number.")))
                return
            }
            guard let root = rootHeader else {
                notRead.append(String(localized: "The root group's object header lies outside the bytes read.", bundle: .module, comment: "HDF5 note."))
                objects.append(object(path: "/", name: "/", depth: 0, kind: .unread, note: String(localized: "not in the bytes read", bundle: .module, comment: "HDF5 note on an object.")))
                return
            }
            visit(header: root, path: "/", name: "/", depth: 0, scratch: rootScratch)
        }

        func object(path: String, name: String, depth: Int, kind: HDF5Summary.Kind, note: String? = nil) -> HDF5Summary.Object {
            HDF5Summary.Object(path: path, name: name, depth: depth, kind: kind, shape: nil, maxShape: nil, datatype: nil,
                               layout: nil, filters: [], attributes: [], note: note)
        }

        private mutating func add(_ entry: HDF5Summary.Object) -> Bool {
            guard objects.count < HDF5Summary.maxObjects else { truncated = true; return false }
            objects.append(entry)
            return true
        }

        /// Reads the object header at `header`, records the object and walks into it when it is a group.
        mutating func visit(header: Int, path: String, name: String, depth: Int, scratch: (btree: Int, heap: Int)? = nil) {
            guard objects.count < HDF5Summary.maxObjects else { truncated = true; return }
            headerReads += 1
            guard headerReads < 4 * HDF5Summary.maxObjects else { truncated = true; return }
            guard let messages = messages(at: header) else {
                _ = add(object(path: path, name: name, depth: depth, kind: .unread,
                               note: String(localized: "its object header could not be read", bundle: .module, comment: "HDF5 note on an object.")))
                return
            }
            var entry = object(path: path, name: name, depth: depth, kind: .group)
            var hasDataspace = false, hasLayout = false, hasDatatype = false
            var symbolTable: (btree: Int, heap: Int)?
            var links: [(name: String, target: LinkTarget)] = []
            var isGroupish = false
            for m in messages {
                let d = m.data.lowerBound
                if m.flags & 0x02 != 0 {
                    // A shared message: its body is a reference to the shared copy.
                    if m.type == 3 { hasDatatype = true; entry.datatype = String(localized: "shared datatype", bundle: .module, comment: "HDF5 datatype shown when the datatype is shared and not read.") }
                    if m.type == 1 { hasDataspace = true }
                    continue
                }
                switch m.type {
                case 0x0001:
                    hasDataspace = true
                    let (shape, max) = dataspace(m.data)
                    entry.shape = shape
                    entry.maxShape = max
                case 0x0003:
                    hasDatatype = true
                    entry.datatype = datatype(d, end: m.data.upperBound, depth: 0)
                case 0x0008:
                    hasLayout = true
                    entry.layout = layout(m.data)
                case 0x000B:
                    entry.filters = filters(m.data)
                case 0x000C:
                    if entry.attributes.count < 100, let n = attributeName(m.data) { entry.attributes.append(n) }
                case 0x0015:
                    if address(d + 2 + ((u8(d + 1) ?? 0) & 1 != 0 ? 2 : 0)) != nil {
                        notRead.append(String(localized: "Attributes of \(path) are kept in dense storage (a fractal heap), which this reader does not walk.", bundle: .module, comment: "HDF5 note. The argument is an object path."))
                    }
                case 0x0011:
                    isGroupish = true
                    if let bt = address(d), let heap = address(d + o) {
                        symbolTable = (bt, heap)
                    } else {
                        notRead.append(String(localized: "The index of group \(path) lies outside the bytes read.", bundle: .module, comment: "HDF5 note. The argument is a group path."))
                        entry.note = String(localized: "its members could not be listed", bundle: .module, comment: "HDF5 note on a group.")
                    }
                case 0x0002:
                    isGroupish = true
                    let flags = u8(d + 1) ?? 0
                    let heapAt = d + 2 + (flags & 1 != 0 ? 8 : 0)
                    if !isUndefinedAddress(heapAt), uint(heapAt, o) != nil {
                        notRead.append(String(localized: "The links of \(path) are kept in dense storage (a fractal heap), which this reader does not walk.", bundle: .module, comment: "HDF5 note. The argument is a group path."))
                        entry.note = String(localized: "links in dense storage were not read", bundle: .module, comment: "HDF5 note on a group.")
                    }
                case 0x0006:
                    isGroupish = true
                    if links.count < HDF5Summary.maxObjects, let link = link(m.data) { links.append(link) }
                default:
                    break
                }
            }
            if hasDataspace && hasLayout {
                entry.kind = .dataset
            } else if hasDatatype && !hasDataspace && !isGroupish {
                entry.kind = .namedDatatype
            } else {
                entry.kind = .group
            }
            guard add(entry) else { return }
            guard entry.kind == .group else { return }
            guard visitedGroups.insert(header).inserted else {
                objects[objects.count - 1].note = String(localized: "already shown (the file links to this group more than once)", bundle: .module, comment: "HDF5 note on a group.")
                return
            }
            guard depth < HDF5Summary.maxDepth else {
                objects[objects.count - 1].note = String(localized: "deeper than \(HDF5Summary.maxDepth) levels; not opened", bundle: .module, comment: "HDF5 note on a group. The argument is a level count.")
                truncated = true
                return
            }
            if let table = symbolTable ?? (isGroupish ? nil : scratch) {
                for child in symbolTableChildren(btree: table.btree, heap: table.heap) {
                    guard objects.count < HDF5Summary.maxObjects else { truncated = true; return }
                    switch child.target {
                    case .hard(let addr): visit(header: addr, path: join(path, child.name), name: child.name, depth: depth + 1)
                    case .soft(let target): _ = add(object(path: join(path, child.name), name: child.name, depth: depth + 1, kind: .softLink(target)))
                    case .external, .missing: _ = add(object(path: join(path, child.name), name: child.name, depth: depth + 1, kind: .unread, note: String(localized: "its object header lies outside the bytes read", bundle: .module, comment: "HDF5 note on an object.")))
                    }
                }
            }
            for child in links {
                guard objects.count < HDF5Summary.maxObjects else { truncated = true; return }
                let childPath = join(path, child.name)
                switch child.target {
                case .hard(let addr): visit(header: addr, path: childPath, name: child.name, depth: depth + 1)
                case .soft(let target): _ = add(object(path: childPath, name: child.name, depth: depth + 1, kind: .softLink(target)))
                case .external(let file, let inner):
                    _ = add(object(path: childPath, name: child.name, depth: depth + 1, kind: .externalLink(file: file, path: inner)))
                    notRead.append(String(localized: "\(childPath) links to another file (\(file)), which is not opened.", bundle: .module, comment: "HDF5 note. The arguments are a path and a file name."))
                case .missing:
                    _ = add(object(path: childPath, name: child.name, depth: depth + 1, kind: .unread, note: String(localized: "its object header lies outside the bytes read", bundle: .module, comment: "HDF5 note on an object.")))
                }
            }
        }

        func join(_ parent: String, _ name: String) -> String { parent == "/" ? "/" + name : parent + "/" + name }

        // MARK: Object headers

        /// Every message of the object header at `at`, following continuation blocks; nil when it is not a header.
        func messages(at start: Int) -> [Message]? {
            var out: [Message] = []
            var blocks: [(Range<Int>, v2: Bool)] = []
            var visited = Set<Int>()
            var v2 = false
            var creationOrder = false
            var expected = Int.max
            if matches(start, "OHDR") {
                guard u8(start + 4) == 2, let flags = u8(start + 5) else { return nil }
                v2 = true
                creationOrder = flags & 0x04 != 0
                var p = start + 6
                if flags & 0x20 != 0 { p += 16 }
                if flags & 0x10 != 0 { p += 4 }
                let width = 1 << (flags & 0x03)
                guard let size = int(p, width) else { return nil }
                p += width
                blocks.append((span(p, size), true))
            } else if u8(start) == 1 {
                guard let count = int(start + 2, 2), let size = int(start + 8, 4) else { return nil }
                expected = count
                let p = start + 16
                guard p <= b.count else { return nil }
                blocks.append((span(p, size), false))
            } else {
                return nil
            }
            visited.insert(start)
            var index = 0
            while index < blocks.count, index < 64, out.count < 4_096, out.count < expected {
                let (range, isV2) = blocks[index]
                index += 1
                var p = range.lowerBound
                let headerSize = isV2 ? 4 + (creationOrder ? 2 : 0) : 8
                while p + headerSize <= range.upperBound, out.count < expected, out.count < 4_096 {
                    let type: Int, size: Int, flags: UInt8
                    if isV2 {
                        type = Int(b[p]); size = Int(b[p + 1]) | Int(b[p + 2]) << 8; flags = b[p + 3]
                    } else {
                        type = Int(b[p]) | Int(b[p + 1]) << 8; size = Int(b[p + 2]) | Int(b[p + 3]) << 8; flags = b[p + 4]
                    }
                    let data = p + headerSize
                    guard data + size <= range.upperBound else { break }
                    if type == 0x0010, let next = address(data), let length = int(data + o, l), visited.insert(next).inserted {
                        if isV2 {
                            if matches(next, "OCHK") { blocks.append((span(next + 4, length - 8), true)) }
                        } else {
                            blocks.append((span(next, length), false))
                        }
                    }
                    out.append(Message(type: type, flags: flags, data: data..<(data + size)))
                    p = data + size
                }
            }
            _ = v2
            return out
        }

        /// Dimensions and maximum dimensions (-1 for unlimited); [] for a scalar, nil for a null dataspace.
        func dataspace(_ r: Range<Int>) -> ([Int]?, [Int]?) {
            let d = r.lowerBound
            guard let version = u8(d), let rank = u8(d + 1), let flags = u8(d + 2), rank <= 32 else { return (nil, nil) }
            var p: Int
            if version == 1 {
                p = d + 8
            } else {
                if u8(d + 3) == 2 { return (nil, nil) }
                p = d + 4
            }
            var dims: [Int] = []
            for _ in 0..<rank {
                guard p + l <= r.upperBound, let v = uint(p, l) else { return (nil, nil) }
                dims.append(v > UInt64(Int.max) ? Int.max : Int(v))
                p += l
            }
            var max: [Int]?
            if flags & 1 != 0 {
                var m: [Int] = []
                for _ in 0..<rank {
                    guard p + l <= r.upperBound, let v = uint(p, l) else { break }
                    let unlimited: UInt64 = l >= 8 ? .max : (UInt64(1) << UInt64(l * 8)) - 1
                    m.append(v == unlimited ? -1 : (v > UInt64(Int.max) ? Int.max : Int(v)))
                    p += l
                }
                if m.count == Int(rank) { max = m }
            }
            return (dims, max)
        }

        /// The datatype starting at `d` in plain words.
        func datatype(_ d: Int, end: Int, depth: Int) -> String? {
            guard depth < 8, d + 8 <= end, let b0 = u8(d), let bits0 = u8(d + 1), let bits1 = u8(d + 2),
                  let size = int(d + 4, 4) else { return nil }
            let cls = b0 & 0x0F
            let typeVersion = b0 >> 4
            let bitsText = size * 8
            let order = bits0 & 1 != 0 ? String(localized: ", big-endian", bundle: .module, comment: "HDF5 datatype suffix.") : (size > 1 ? String(localized: ", little-endian", bundle: .module, comment: "HDF5 datatype suffix.") : "")
            switch cls {
            case 0:
                return (bits0 & 0x08 != 0
                        ? String(localized: "\(bitsText)-bit signed integer", bundle: .module, comment: "HDF5 datatype. The argument is a bit count.")
                        : String(localized: "\(bitsText)-bit unsigned integer", bundle: .module, comment: "HDF5 datatype. The argument is a bit count.")) + order
            case 1:
                return String(localized: "\(bitsText)-bit float", bundle: .module, comment: "HDF5 datatype. The argument is a bit count.") + order
            case 2:
                return String(localized: "\(bitsText)-bit time", bundle: .module, comment: "HDF5 datatype. The argument is a bit count.")
            case 3:
                return (bits0 >> 4) & 0x0F == 1
                    ? String(localized: "fixed-length UTF-8 string (\(size) bytes)", bundle: .module, comment: "HDF5 datatype. The argument is a byte count.")
                    : String(localized: "fixed-length ASCII string (\(size) bytes)", bundle: .module, comment: "HDF5 datatype. The argument is a byte count.")
            case 4:
                return String(localized: "bitfield (\(size) bytes)", bundle: .module, comment: "HDF5 datatype. The argument is a byte count.")
            case 5:
                return String(localized: "opaque (\(size) bytes)", bundle: .module, comment: "HDF5 datatype. The argument is a byte count.")
            case 6:
                let members = bits0 | bits1 << 8
                return String(localized: "compound (\(members) members, \(size) bytes)", bundle: .module, comment: "HDF5 datatype. The arguments are a member count and a byte count.")
            case 7:
                return String(localized: "reference", bundle: .module, comment: "HDF5 datatype.")
            case 8:
                let base = datatype(d + 8, end: end, depth: depth + 1) ?? "?"
                return String(localized: "enumeration of \(base)", bundle: .module, comment: "HDF5 datatype. The argument is the base datatype.")
            case 9:
                if bits0 & 0x0F == 1 { return String(localized: "variable-length string", bundle: .module, comment: "HDF5 datatype.") }
                let base = datatype(d + 8, end: end, depth: depth + 1) ?? "?"
                return String(localized: "variable-length sequence of \(base)", bundle: .module, comment: "HDF5 datatype. The argument is the base datatype.")
            case 10:
                guard let rank = u8(d + 8), rank <= 32 else { return String(localized: "array", bundle: .module, comment: "HDF5 datatype.") }
                var dims: [String] = []
                for k in 0..<rank { if let v = uint(d + 12 + 4 * k, 4) { dims.append(String(v)) } }
                let baseAt = d + 12 + 4 * rank + (typeVersion < 3 ? 4 * rank : 0)
                let base = datatype(baseAt, end: end, depth: depth + 1) ?? "?"
                let shape = dims.joined(separator: " × ")
                return String(localized: "array [\(shape)] of \(base)", bundle: .module, comment: "HDF5 datatype. The arguments are dimensions and the base datatype.")
            default:
                return String(localized: "datatype class \(cls)", bundle: .module, comment: "HDF5 datatype of an unknown class. The argument is the class number.")
            }
        }

        func layout(_ r: Range<Int>) -> String? {
            let d = r.lowerBound
            guard let version = u8(d) else { return nil }
            let cls: Int?
            switch version {
            case 1, 2: cls = u8(d + 2)
            case 3, 4, 5: cls = u8(d + 1)
            default: cls = nil
            }
            switch cls {
            case 0: return String(localized: "compact", bundle: .module, comment: "HDF5 dataset layout.")
            case 1: return String(localized: "contiguous", bundle: .module, comment: "HDF5 dataset layout.")
            case 2:
                if version == 3, let rank = u8(d + 2), rank >= 2, rank <= 33 {
                    var dims: [String] = []
                    let p = d + 3 + o
                    for k in 0..<(rank - 1) {
                        guard p + 4 * k + 4 <= r.upperBound, let v = uint(p + 4 * k, 4) else { break }
                        dims.append(String(v))
                    }
                    if dims.count == rank - 1 {
                        let shape = dims.joined(separator: " × ")
                        return String(localized: "chunked (\(shape))", bundle: .module, comment: "HDF5 dataset layout. The argument is the chunk dimensions.")
                    }
                }
                return String(localized: "chunked", bundle: .module, comment: "HDF5 dataset layout.")
            case 3: return String(localized: "virtual", bundle: .module, comment: "HDF5 dataset layout.")
            default: return nil
            }
        }

        func filters(_ r: Range<Int>) -> [String] {
            let d = r.lowerBound
            guard let version = u8(d), let count = u8(d + 1), count <= 32 else { return [] }
            var p = d + (version == 1 ? 8 : 2)
            var out: [String] = []
            for _ in 0..<count {
                guard let id = int(p, 2) else { break }
                p += 2
                var nameLength = 0
                if version == 1 || id >= 256 {
                    guard let n = int(p, 2) else { break }
                    nameLength = n
                    p += 2
                }
                guard let values = int(p + 2, 2) else { break }
                p += 4
                var stated: String?
                if nameLength > 0 {
                    stated = cString(p, max: nameLength)
                    p += version == 1 ? (nameLength + 7) / 8 * 8 : nameLength
                }
                p += 4 * values
                if version == 1, values % 2 == 1 { p += 4 }
                guard p <= r.upperBound else { break }
                let known = [1: "deflate", 2: "shuffle", 3: "fletcher32", 4: "szip", 5: "nbit", 6: "scaleoffset",
                             32001: "blosc", 32004: "lz4", 32008: "bitshuffle", 32015: "zstd"][id]
                out.append(known ?? stated.flatMap { $0.isEmpty ? nil : $0 } ?? "filter \(id)")
            }
            return out
        }

        func attributeName(_ r: Range<Int>) -> String? {
            let d = r.lowerBound
            guard let version = u8(d), let nameSize = int(d + 2, 2), nameSize > 0 else { return nil }
            let start = version == 3 ? d + 9 : d + 8
            guard start + nameSize <= r.upperBound else { return nil }
            return cString(start, max: nameSize)
        }

        enum LinkTarget {
            case hard(Int)
            case soft(String)
            case external(String, String)
            case missing
        }

        func link(_ r: Range<Int>) -> (name: String, target: LinkTarget)? {
            let d = r.lowerBound
            guard u8(d) == 1, let flags = u8(d + 1) else { return nil }
            var p = d + 2
            var type = 0
            if flags & 0x08 != 0 { type = u8(p) ?? 0; p += 1 }
            if flags & 0x04 != 0 { p += 8 }
            if flags & 0x10 != 0 { p += 1 }
            let width = 1 << (flags & 0x03)
            guard let length = int(p, width), length > 0, length < 65_536 else { return nil }
            p += width
            guard p + length <= r.upperBound else { return nil }
            let name = String(decoding: b[p..<(p + length)], as: UTF8.self)
            p += length
            switch type {
            case 0:
                return (name, address(p).map(LinkTarget.hard) ?? .missing)
            case 1:
                guard let n = int(p, 2), p + 2 + n <= r.upperBound else { return (name, .soft("?")) }
                return (name, .soft(String(decoding: b[(p + 2)..<(p + 2 + n)], as: UTF8.self)))
            case 64:
                guard let n = int(p, 2), p + 2 + n <= r.upperBound, n >= 1 else { return (name, .external("?", "?")) }
                let file = cString(p + 3, max: n - 1) ?? "?"
                let inner = cString(p + 3 + file.utf8.count + 1, max: max(0, n - 2 - file.utf8.count)) ?? "?"
                return (name, .external(file, inner))
            default:
                return (name, .soft(String(localized: "user-defined link type \(type)", bundle: .module, comment: "HDF5 link target. The argument is a type number.")))
            }
        }

        // MARK: Old-style groups

        /// The names and header addresses in a symbol-table group: B-tree (version 1, group nodes) → symbol nodes,
        /// names from the local heap.
        mutating func symbolTableChildren(btree: Int, heap: Int) -> [(name: String, target: LinkTarget)] {
            guard matches(heap, "HEAP"), let dataSize = int(heap + 8, l), let dataAt = address(heap + 8 + 2 * l) else {
                notRead.append(String(localized: "A group's name heap is damaged or outside the bytes read.", bundle: .module, comment: "HDF5 note."))
                return []
            }
            var out: [(String, LinkTarget)] = []
            var nodes: [(Int, Int)] = [(btree, 0)]
            var seen = Set<Int>()
            while let (node, level) = nodes.popLast() {
                guard seen.insert(node).inserted, seen.count < 10_000, out.count < HDF5Summary.maxObjects else { break }
                if matches(node, "TREE") {
                    guard u8(node + 4) == 0, let nodeLevel = u8(node + 5), let used = int(node + 6, 2), level < 64 else { continue }
                    let first = node + 8 + 2 * o
                    var children: [Int] = []
                    for k in 0..<min(used, 4_096) {
                        guard let child = address(first + k * (l + o) + l) else { break }
                        children.append(child)
                    }
                    // Depth-first in key order: push in reverse.
                    for child in children.reversed() { nodes.append((child, nodeLevel > 0 ? level + 1 : level)) }
                } else if matches(node, "SNOD") {
                    guard let count = int(node + 6, 2) else { continue }
                    let entrySize = 2 * o + 24
                    for k in 0..<min(count, 4_096) {
                        let e = node + 8 + k * entrySize
                        guard let nameOffset = int(e, o), nameOffset < dataSize, nameOffset < b.count,
                              let name = cString(dataAt + nameOffset), !name.isEmpty else { continue }
                        if uint(e + 2 * o, 4) == 2, let linkOffset = int(e + 2 * o + 8, 4), linkOffset < dataSize {
                            out.append((name, .soft(cString(dataAt + linkOffset) ?? "?")))
                        } else {
                            out.append((name, address(e + o).map(LinkTarget.hard) ?? .missing))
                        }
                    }
                } else {
                    notRead.append(String(localized: "A group's index node is damaged or outside the bytes read.", bundle: .module, comment: "HDF5 note."))
                }
            }
            return out
        }

        // MARK: Summary

        func summary(context: AIReadContext) -> HDF5Summary {
            let groups = objects.filter { $0.kind == .group }.count
            let datasets = objects.filter { $0.kind == .dataset }.count
            var warnings = self.warnings
            if truncated {
                warnings.append(AIDataWarning(.caution, String(localized: "The tree is larger than this preview walks; the first \(objects.count) entries are shown.", bundle: .module, comment: "HDF5 warning. The argument is an entry count.")))
            }
            if context.wasCut { warnings.append(context.readCapWarning) }
            let unread = objects.filter { $0.kind == .unread }.count
            if unread > 0 && !context.wasCut {
                warnings.append(AIDataWarning(.caution, String(localized: "\(unread) objects could not be read; the file may be damaged or cut short.", bundle: .module, comment: "HDF5 warning. The argument is an object count.")))
            }

            var facts: [AIDataFact] = [
                AIDataFact(String(localized: "Format", bundle: .module, comment: "Fact label."),
                           String(localized: "HDF5, superblock version \(version)", bundle: .module, comment: "HDF5 fact value. The argument is a version number.")),
                AIDataFact(String(localized: "Groups", bundle: .module, comment: "Fact label: HDF5 groups."), groups.formatted()),
                AIDataFact(String(localized: "Datasets", bundle: .module, comment: "Fact label: HDF5 datasets."), datasets.formatted()),
            ]
            if superblock > 0 {
                facts.append(AIDataFact(String(localized: "User block", bundle: .module, comment: "Fact label: bytes before an HDF5 superblock."),
                                        ByteCountFormatter.string(fromByteCount: Int64(superblock), countStyle: .file)))
            }
            let filters = AIText.unique(objects.flatMap(\.filters))
            if !filters.isEmpty {
                facts.append(AIDataFact(String(localized: "Filters", bundle: .module, comment: "Fact label: HDF5 compression filters."), filters.joined(separator: ", ")))
            }

            let rows = objects.prefix(AIDataTable.maxRows).map { obj -> [String] in
                let kind: String
                var extra = obj.datatype ?? ""
                switch obj.kind {
                case .group: kind = String(localized: "group", bundle: .module, comment: "HDF5 object kind.")
                case .dataset: kind = String(localized: "dataset", bundle: .module, comment: "HDF5 object kind.")
                case .namedDatatype: kind = String(localized: "datatype", bundle: .module, comment: "HDF5 object kind.")
                case .softLink(let target): kind = String(localized: "soft link", bundle: .module, comment: "HDF5 object kind."); extra = "→ " + target
                case .externalLink(let file, let path): kind = String(localized: "external link", bundle: .module, comment: "HDF5 object kind."); extra = "→ \(file):\(path)"
                case .unread: kind = String(localized: "not read", bundle: .module, comment: "HDF5 object kind.")
                }
                return [AIText.cap(obj.path), kind, obj.shape.map(AINumpyReader.shapeText) ?? "", AIText.cap(extra),
                        obj.layout ?? "", AIText.cap(obj.attributes.joined(separator: ", ")), obj.note ?? ""]
            }
            let table = AIDataTable(columns: [String(localized: "Path", bundle: .module, comment: "Table column."),
                                              String(localized: "Kind", bundle: .module, comment: "Table column."),
                                              String(localized: "Shape", bundle: .module, comment: "Table column."),
                                              String(localized: "Type", bundle: .module, comment: "Table column."),
                                              String(localized: "Layout", bundle: .module, comment: "Table column."),
                                              String(localized: "Attributes", bundle: .module, comment: "Table column."),
                                              String(localized: "Note", bundle: .module, comment: "Table column.")],
                                    rows: Array(rows), totalRows: truncated ? nil : objects.count,
                                    isTruncated: truncated || objects.count > rows.count)
            let headline = version < 0
                ? String(localized: "HDF5 file", bundle: .module, comment: "Headline for an HDF5 file whose superblock could not be read.")
                : String(localized: "HDF5 · \(groups) groups, \(datasets) datasets", bundle: .module, comment: "Headline. The arguments are counts.")
            return HDF5Summary(headline: headline, superblockVersion: version, superblockOffset: superblock,
                               offsetSize: o, lengthSize: l, objects: objects, objectsTruncated: truncated,
                               groupCount: groups, datasetCount: datasets, notRead: AIText.unique(notRead, limit: 100),
                               table: table, facts: facts, warnings: warnings)
        }
    }
}
