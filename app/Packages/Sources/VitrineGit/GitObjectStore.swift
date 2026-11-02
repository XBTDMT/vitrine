import Foundation
import VitrineSupport

/// The four object types a repository stores. roadmap: S-9
public enum GitObjectType: String, Sendable, Equatable {
    case commit, tree, blob, tag

    init?(packCode: Int) {
        switch packCode {
        case 1: self = .commit
        case 2: self = .tree
        case 3: self = .blob
        case 4: self = .tag
        default: return nil
        }
    }
}

/// An object's type and inflated content (without the `type size\0` header).
public struct GitObject: Sendable, Equatable {
    public let type: GitObjectType
    public let content: [UInt8]
}

/// Reads objects straight from `.git/objects`: loose files (zlib) and pack files through their `.idx` v2 index,
/// resolving OFS_DELTA and REF_DELTA chains. Nothing is ever written. Every read is bounded: object size, delta
/// depth and a small cache of resolved pack entries (a commit walk touches the same bases again and again).
/// Not thread-safe; one store belongs to one read. roadmap: S-9
final class GitObjectStore {
    private let objectDirs: [URL]
    private var packs: [GitPack] = []
    private let maxDeltaDepth: Int
    /// Resolved pack entries by (pack, offset), evicted oldest first past `cacheLimit` bytes.
    private var cache: [PackKey: GitObject] = [:]
    private var cacheOrder: [PackKey] = []
    private var cacheBytes = 0
    private let cacheLimit = 24 << 20
    /// Packs that could not be opened, for the facts ("1 pack unreadable").
    private(set) var unreadablePacks = 0

    private struct PackKey: Hashable { let pack: Int; let offset: Int64 }

    init(objectsDirectory: URL, maxDeltaDepth: Int = 64) {
        var dirs = [objectsDirectory]
        // objects/info/alternates: other object stores this one borrows from (one level, at most four).
        if let text = SmallFile.text(objectsDirectory.appendingPathComponent("info/alternates"), max: 64 << 10) {
            for line in text.split(whereSeparator: \.isNewline).prefix(4) {
                let path = line.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty, !path.hasPrefix("#") else { continue }
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : objectsDirectory.appendingPathComponent(path)
                dirs.append(url.standardizedFileURL)
            }
        }
        objectDirs = dirs
        self.maxDeltaDepth = maxDeltaDepth
        for dir in dirs {
            let packDir = dir.appendingPathComponent("pack")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: packDir.path)) ?? []
            for name in names.sorted().prefix(512) where name.hasSuffix(".idx") {
                let base = String(name.dropLast(4))
                do {
                    packs.append(try GitPack(index: packDir.appendingPathComponent(name), pack: packDir.appendingPathComponent(base + ".pack")))
                } catch {
                    unreadablePacks += 1
                }
            }
        }
    }

    var packCount: Int { packs.count }

    /// The object, or nil when it is missing (a shallow clone, a partial clone, a damaged store) or over `maxBytes`.
    func object(_ id: GitObjectID, maxBytes: Int) -> GitObject? {
        try? read(id, maxBytes: maxBytes, depth: 0)
    }

    /// Like `object`, but says why it failed.
    func read(_ id: GitObjectID, maxBytes: Int, depth: Int) throws -> GitObject {
        guard depth <= maxDeltaDepth else { throw GitError.overBudget("the delta chain is too long") }
        for (n, pack) in packs.enumerated() {
            if let offset = try pack.offset(of: id) { return try packed(pack: n, offset: offset, maxBytes: maxBytes, depth: depth) }
        }
        for dir in objectDirs {
            let hex = id.hex
            let url = dir.appendingPathComponent(String(hex.prefix(2))).appendingPathComponent(String(hex.dropFirst(2)))
            if let object = try loose(url, maxBytes: maxBytes) { return object }
        }
        throw GitError.unreadable("object \(id.short) is not in this repository")
    }

    // MARK: Loose objects

    private func loose(_ url: URL, maxBytes: Int) throws -> GitObject? {
        guard let source = try? BoundedFileSource<GitError>(url: url) else { return nil }
        // Compressed bytes can exceed the content for tiny objects, never by much for large ones.
        guard source.size <= Int64(maxBytes) + Int64(maxBytes / 8) + 4096 else { throw GitError.overBudget("the object is too large") }
        let compressed = try source.read(at: 0, count: Int(source.size))
        guard let raw = GitZlib.inflateAll(compressed, limit: maxBytes + 64) else { throw GitError.malformed("a loose object does not inflate") }
        guard let nul = raw.prefix(40).firstIndex(of: 0) else { throw GitError.malformed("a loose object has no header") }
        let header = String(decoding: raw[..<nul], as: UTF8.self).split(separator: " ")
        guard header.count == 2, let type = GitObjectType(rawValue: String(header[0])), let size = Int(header[1]) else {
            throw GitError.malformed("a loose object has a bad header")
        }
        let content = Array(raw[(nul + 1)...])
        guard content.count == size else { throw GitError.malformed("a loose object's size does not match its header") }
        guard size <= maxBytes else { throw GitError.overBudget("the object is too large") }
        return GitObject(type: type, content: content)
    }

    // MARK: Pack entries

    private func packed(pack n: Int, offset: Int64, maxBytes: Int, depth: Int) throws -> GitObject {
        let key = PackKey(pack: n, offset: offset)
        if let hit = cache[key] {
            guard hit.content.count <= maxBytes else { throw GitError.overBudget("the object is too large") }
            return hit
        }
        guard depth <= maxDeltaDepth else { throw GitError.overBudget("the delta chain is too long") }
        let pack = packs[n]
        let head = try pack.source.read(at: offset, count: 32)
        guard !head.isEmpty else { throw GitError.truncated("a pack entry lies past the end of its pack") }
        var i = 0
        var byte = head[i]; i += 1
        let code = Int(byte >> 4) & 7
        var size = Int(byte & 0x0F)
        var shift = 4
        while byte & 0x80 != 0 {
            guard i < head.count, shift <= 56 else { throw GitError.malformed("a pack entry header is too long") }
            byte = head[i]; i += 1
            size |= Int(byte & 0x7F) << shift
            shift += 7
        }
        let result: GitObject
        switch code {
        case 1...4:
            guard size <= maxBytes else { throw GitError.overBudget("the object is too large") }
            let content = try GitZlib.inflate(pack.source, at: offset + Int64(i), expected: size)
            result = GitObject(type: GitObjectType(packCode: code)!, content: content)
        case 6:   // OFS_DELTA: the base is earlier in the same pack
            let distance = try GitVarint.offset(head, &i)
            let baseOffset = offset - Int64(distance)
            guard distance > 0, baseOffset >= 12 else { throw GitError.malformed("a delta points outside its pack") }
            let base = try packed(pack: n, offset: baseOffset, maxBytes: maxBytes, depth: depth + 1)
            result = try delta(on: base, pack: pack, at: offset + Int64(i), size: size, maxBytes: maxBytes)
        case 7:   // REF_DELTA: the base is named (in this pack, another, or loose)
            guard i + 20 <= head.count, let baseID = GitObjectID(bytes: Array(head[i..<(i + 20)])) else {
                throw GitError.truncated("a delta's base name ends early")
            }
            i += 20
            let base = try read(baseID, maxBytes: maxBytes, depth: depth + 1)
            result = try delta(on: base, pack: pack, at: offset + Int64(i), size: size, maxBytes: maxBytes)
        default:
            throw GitError.malformed("a pack entry has unknown type \(code)")
        }
        remember(result, key)
        return result
    }

    private func delta(on base: GitObject, pack: GitPack, at offset: Int64, size: Int, maxBytes: Int) throws -> GitObject {
        // A delta is never much larger than its result; this bound stops a lying header from asking for gigabytes.
        guard size <= maxBytes + maxBytes / 2 + 1024 else { throw GitError.overBudget("the delta is too large") }
        let instructions = try GitZlib.inflate(pack.source, at: offset, expected: size)
        return GitObject(type: base.type, content: try GitDelta.apply(instructions, to: base.content, maxBytes: maxBytes))
    }

    private func remember(_ object: GitObject, _ key: PackKey) {
        guard object.content.count <= cacheLimit / 4 else { return }
        cache[key] = object
        cacheOrder.append(key)
        cacheBytes += object.content.count
        while cacheBytes > cacheLimit, !cacheOrder.isEmpty {
            let old = cacheOrder.removeFirst()
            cacheBytes -= cache.removeValue(forKey: old)?.content.count ?? 0
        }
    }
}

/// Git's delta format: the base size, the result size, then copy and insert instructions. Every copy is checked
/// against the base and every insert against the delta, and the result must come out exactly the declared size.
/// roadmap: S-9
enum GitDelta {
    static func apply(_ delta: [UInt8], to base: [UInt8], maxBytes: Int) throws -> [UInt8] {
        var i = 0
        let baseSize = try GitVarint.size(delta, &i)
        let resultSize = try GitVarint.size(delta, &i)
        guard baseSize == base.count else { throw GitError.malformed("a delta was made for a different base") }
        guard resultSize <= maxBytes else { throw GitError.overBudget("the object is too large") }
        var out = [UInt8]()
        out.reserveCapacity(resultSize)
        while i < delta.count {
            let op = delta[i]; i += 1
            if op & 0x80 != 0 {
                var offset = 0, size = 0
                for bit in 0..<4 where op & (1 << bit) != 0 {
                    guard i < delta.count else { throw GitError.truncated("a delta copy ends early") }
                    offset |= Int(delta[i]) << (8 * bit); i += 1
                }
                for bit in 0..<3 where op & (1 << (4 + bit)) != 0 {
                    guard i < delta.count else { throw GitError.truncated("a delta copy ends early") }
                    size |= Int(delta[i]) << (8 * bit); i += 1
                }
                if size == 0 { size = 0x10000 }
                guard offset + size <= base.count else { throw GitError.malformed("a delta copies past the end of its base") }
                guard out.count + size <= resultSize else { throw GitError.malformed("a delta overruns its declared size") }
                out.append(contentsOf: base[offset..<(offset + size)])
            } else if op != 0 {
                let n = Int(op)
                guard i + n <= delta.count else { throw GitError.truncated("a delta insert ends early") }
                guard out.count + n <= resultSize else { throw GitError.malformed("a delta overruns its declared size") }
                out.append(contentsOf: delta[i..<(i + n)]); i += n
            } else {
                throw GitError.malformed("a delta uses the reserved instruction 0")
            }
        }
        guard out.count == resultSize else { throw GitError.malformed("a delta's result is not its declared size") }
        return out
    }
}

/// One pack: its `.idx` (v2) for lookups and its `.pack` for the entries. Both are read with `pread` in small
/// windows, so a multi-gigabyte pack costs only the lookups. roadmap: S-9
final class GitPack {
    let source: BoundedFileSource<GitError>
    private let index: BoundedFileSource<GitError>
    private let fanout: [UInt32]
    private let count: Int

    init(index indexURL: URL, pack packURL: URL) throws {
        index = try BoundedFileSource(url: indexURL)
        source = try BoundedFileSource(url: packURL)
        let header = try index.readExactly(8 + 1024, at: 0, "the pack index header", failing: GitError.self)
        guard header[0..<4] == [0xFF, 0x74, 0x4F, 0x63][...] else { throw GitError.unsupported("pack index v1") }
        var cursor = BoundedByteCursor<GitError>(header, at: 4, bigEndian: true, what: "the pack index header")
        guard try cursor.u32() == 2 else { throw GitError.unsupported("pack index version") }
        var fan = [UInt32]()
        fan.reserveCapacity(256)
        var previous: UInt32 = 0
        for _ in 0..<256 {
            let v = try cursor.u32()
            guard v >= previous else { throw GitError.malformed("the pack index fan-out goes backwards") }
            fan.append(v); previous = v
        }
        fanout = fan
        count = Int(fan[255])
        // Names, CRCs and offsets must all fit, plus the two trailing checksums.
        guard index.size >= Int64(8 + 1024 + count * 28 + 40) else { throw GitError.truncated("the pack index is shorter than its object count") }
        let packHeader = try source.readExactly(12, at: 0, "the pack header", failing: GitError.self)
        guard packHeader[0..<4] == Array("PACK".utf8)[...] else { throw GitError.malformed("not a pack file") }
        let version = UInt32(packHeader[4]) << 24 | UInt32(packHeader[5]) << 16 | UInt32(packHeader[6]) << 8 | UInt32(packHeader[7])
        guard version == 2 || version == 3 else { throw GitError.unsupported("pack version \(version)") }
    }

    /// Where `id` starts in the pack, by binary search over the sorted names in its fan-out bucket.
    func offset(of id: GitObjectID) throws -> Int64? {
        let first = Int(id.bytes[0])
        var lo = first == 0 ? 0 : Int(fanout[first - 1])
        var hi = Int(fanout[first])
        while lo < hi {
            let mid = (lo + hi) / 2
            let name = try index.readExactly(20, at: Int64(8 + 1024 + mid * 20), "a pack index name", failing: GitError.self)
            if name == id.bytes { return try entryOffset(mid) }
            if name.lexicographicallyPrecedes(id.bytes) { lo = mid + 1 } else { hi = mid }
        }
        return nil
    }

    private func entryOffset(_ n: Int) throws -> Int64 {
        let small = try index.readExactly(4, at: Int64(8 + 1024 + count * 24 + n * 4), "a pack offset", failing: GitError.self)
        let v = UInt32(small[0]) << 24 | UInt32(small[1]) << 16 | UInt32(small[2]) << 8 | UInt32(small[3])
        guard v & 0x8000_0000 != 0 else { return Int64(v) }
        let at = Int64(8 + 1024 + count * 28) + Int64(v & 0x7FFF_FFFF) * 8
        let big = try index.readExactly(8, at: at, "a large pack offset", failing: GitError.self)
        var value: UInt64 = 0
        for b in big { value = value << 8 | UInt64(b) }
        guard value < UInt64(Int64.max) else { throw GitError.malformed("a pack offset is out of range") }
        return Int64(value)
    }
}
