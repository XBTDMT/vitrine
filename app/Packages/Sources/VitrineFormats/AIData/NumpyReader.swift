import Foundation
import VitrineArchive

/// A NumPy array's element type, from the header's `descr`. roadmap: S-21
public struct NPYDtype: Sendable, Equatable {
    /// The kind letter NumPy uses. roadmap: S-21
    public enum Kind: String, Sendable, Equatable {
        case bool = "b", signedInteger = "i", unsignedInteger = "u", float = "f", complex = "c"
        case datetime = "M", timedelta = "m", bytes = "S", unicode = "U", void = "V", object = "O"
    }

    /// How multi-byte values are stored. roadmap: S-21
    public enum ByteOrder: String, Sendable, Equatable {
        case little, big, notApplicable
    }

    /// One field of a structured dtype. roadmap: S-21
    public struct Field: Sendable, Equatable {
        public var name: String
        /// The field's own descr text (`<f4`, or a nested structure written as text).
        public var descr: String
        /// The field's sub-array shape, when it has one (`('pos', '<f4', (3,))`).
        public var shape: [Int]

        public init(name: String, descr: String, shape: [Int]) {
            self.name = name
            self.descr = descr
            self.shape = shape
        }
    }

    /// The descr as the header writes it (`<f8`, `|O`), or a list of fields written back as text.
    public var descr: String
    /// Plain English: "64-bit float, little-endian", "structured (3 fields)".
    public var description: String
    /// nil for a structured dtype.
    public var kind: Kind?
    /// Bytes per element, when known.
    public var itemSize: Int?
    public var byteOrder: ByteOrder
    /// The fields of a structured dtype, at most 1,000.
    public var fields: [Field]
    /// The dtype holds Python objects somewhere (itself or a field): loading it means unpickling.
    public var containsObjects: Bool

    public init(descr: String, description: String, kind: Kind?, itemSize: Int?, byteOrder: ByteOrder, fields: [Field],
                containsObjects: Bool) {
        self.descr = descr
        self.description = description
        self.kind = kind
        self.itemSize = itemSize
        self.byteOrder = byteOrder
        self.fields = fields
        self.containsObjects = containsObjects
    }
}

/// A NumPy `.npy` file (A-7): format version, dtype, shape, memory order, where the data starts, and the first values
/// of a simple numeric array. An object dtype is flagged (`containsPythonObjects`) so the caller can send the file to
/// the pickle check: NumPy loads such arrays by unpickling. roadmap: S-21
public struct NPYSummary: Sendable, Equatable {
    public var headline: String
    /// "1.0", "2.0", "3.0".
    public var version: String
    /// nil when the header could not be read.
    public var dtype: NPYDtype?
    /// nil when the header could not be read; [] for a scalar.
    public var shape: [Int]?
    /// The product of the shape, nil when it overflows or is unknown.
    public var elementCount: Int?
    /// Elements are stored column-major (Fortran order) rather than row-major.
    public var fortranOrder: Bool
    /// Where the array's bytes start: the magic, the header length field and the header.
    public var dataOffset: Int
    /// The bytes the shape and dtype call for, when both are known.
    public var expectedDataBytes: Int?
    /// The data bytes present after the header in what was read.
    public var availableDataBytes: Int
    public var containsPythonObjects: Bool
    /// Up to `maxPreview` values in storage order, for bool, integer, float and complex dtypes.
    public var preview: [String]
    public var facts: [AIDataFact]
    public var warnings: [AIDataWarning]

    public static let maxPreview = 100

    public init(headline: String, version: String, dtype: NPYDtype?, shape: [Int]?, elementCount: Int?,
                fortranOrder: Bool, dataOffset: Int, expectedDataBytes: Int?, availableDataBytes: Int,
                containsPythonObjects: Bool, preview: [String], facts: [AIDataFact], warnings: [AIDataWarning]) {
        self.headline = headline
        self.version = version
        self.dtype = dtype
        self.shape = shape
        self.elementCount = elementCount
        self.fortranOrder = fortranOrder
        self.dataOffset = dataOffset
        self.expectedDataBytes = expectedDataBytes
        self.availableDataBytes = availableDataBytes
        self.containsPythonObjects = containsPythonObjects
        self.preview = preview
        self.facts = facts
        self.warnings = warnings
    }
}

/// A NumPy `.npz` archive (A-7): a zip of `.npy` members (`np.savez`, `np.savez_compressed`), each listed with its
/// dtype and shape from its header. roadmap: S-21
public struct NPZSummary: Sendable, Equatable {
    /// One array in the archive. roadmap: S-21
    public struct Member: Sendable, Equatable {
        /// The array's name (`arr_0`, or the keyword it was saved under): the member path without `.npy`.
        public var name: String
        public var path: String
        public var dtype: NPYDtype?
        public var shape: [Int]?
        public var fortranOrder: Bool
        public var containsPythonObjects: Bool
        /// The member is deflated (`savez_compressed`).
        public var compressed: Bool
        public var uncompressedSize: Int64?
        /// Why the header could not be read, when it could not.
        public var problem: String?

        public init(name: String, path: String, dtype: NPYDtype?, shape: [Int]?, fortranOrder: Bool,
                    containsPythonObjects: Bool, compressed: Bool, uncompressedSize: Int64?, problem: String?) {
            self.name = name
            self.path = path
            self.dtype = dtype
            self.shape = shape
            self.fortranOrder = fortranOrder
            self.containsPythonObjects = containsPythonObjects
            self.compressed = compressed
            self.uncompressedSize = uncompressedSize
            self.problem = problem
        }
    }

    public var headline: String
    /// At most `maxMembers` arrays.
    public var members: [Member]
    public var membersTruncated: Bool
    /// Files in the zip that are not `.npy` arrays.
    public var otherFiles: Int
    public var containsPythonObjects: Bool
    /// Name, dtype, shape, size, compressed for each listed array.
    public var table: AIDataTable
    public var facts: [AIDataFact]
    public var warnings: [AIDataWarning]

    public static let maxMembers = 1_000

    public init(headline: String, members: [Member], membersTruncated: Bool, otherFiles: Int,
                containsPythonObjects: Bool, table: AIDataTable, facts: [AIDataFact], warnings: [AIDataWarning]) {
        self.headline = headline
        self.members = members
        self.membersTruncated = membersTruncated
        self.otherFiles = otherFiles
        self.containsPythonObjects = containsPythonObjects
        self.table = table
        self.facts = facts
        self.warnings = warnings
    }
}

enum AINumpyReader {
    static let magic: [UInt8] = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]  // \x93NUMPY
    /// NumPy itself refuses headers over 10,000 bytes unless asked; a little more is allowed here.
    static let maxHeaderBytes = 1024 * 1024

    static func hasMagic(_ bytes: [UInt8]) -> Bool { bytes.starts(with: magic) }

    static var objectWarning: AIDataWarning {
        AIDataWarning(.danger, String(localized: "This array holds Python objects. NumPy can only load it by unpickling, which can run code; open it only if you trust where it came from.", bundle: .module, comment: "NumPy danger warning; NumPy is a product name."))
    }

    static var endsInHeader: String { String(localized: "The file ends inside its header.", bundle: .module, comment: "NumPy header problem.") }

    // MARK: Header

    struct Header {
        var version: String
        var dtype: NPYDtype?
        var shape: [Int]?
        var fortranOrder: Bool
        var dataOffset: Int
        var problem: String?
    }

    /// The header of an `.npy` (or the start of one): never nil once the magic matched.
    static func header(_ bytes: [UInt8]) -> Header? {
        guard hasMagic(bytes) else { return nil }
        guard bytes.count >= 10 else {
            return Header(version: "?", dtype: nil, shape: nil, fortranOrder: false, dataOffset: bytes.count,
                          problem: endsInHeader)
        }
        let major = Int(bytes[6]), minor = Int(bytes[7])
        let version = "\(major).\(minor)"
        let lengthWidth = major >= 2 ? 4 : 2
        guard major >= 1, major <= 3 else {
            return Header(version: version, dtype: nil, shape: nil, fortranOrder: false, dataOffset: 8,
                          problem: String(localized: "Format version \(version) is not one this reader knows (1.0 to 3.0).", bundle: .module, comment: "NumPy header problem. The argument is a version such as 4.0."))
        }
        guard bytes.count >= 8 + lengthWidth else {
            return Header(version: version, dtype: nil, shape: nil, fortranOrder: false, dataOffset: bytes.count,
                          problem: endsInHeader)
        }
        var length = 0
        for k in 0..<lengthWidth { length |= Int(bytes[8 + k]) << (8 * k) }
        let start = 8 + lengthWidth
        let dataOffset = start + length
        guard length <= maxHeaderBytes else {
            return Header(version: version, dtype: nil, shape: nil, fortranOrder: false, dataOffset: dataOffset,
                          problem: String(localized: "The header says it is \(length) bytes long, more than this reader reads.", bundle: .module, comment: "NumPy header problem. The argument is a byte count."))
        }
        guard dataOffset <= bytes.count else {
            return Header(version: version, dtype: nil, shape: nil, fortranOrder: false, dataOffset: dataOffset,
                          problem: endsInHeader)
        }
        // Version 3 headers are UTF-8, earlier ones Latin-1.
        let raw = Array(bytes[start..<dataOffset])
        let text = major >= 3 ? String(decoding: raw, as: UTF8.self) : String(raw.map { Character(Unicode.Scalar($0)) })
        var parser = AIPythonLiteral(text)
        guard let dict = parser.parse(), case .dict(let entries) = dict else {
            return Header(version: version, dtype: nil, shape: nil, fortranOrder: false, dataOffset: dataOffset,
                          problem: String(localized: "The header is not the Python dictionary NumPy writes.", bundle: .module, comment: "NumPy header problem."))
        }
        func entry(_ key: String) -> AIPythonLiteral.Value? { entries.first { $0.0 == .string(key) }?.1 }
        guard let descr = entry("descr"), let dtype = self.dtype(descr) else {
            return Header(version: version, dtype: nil, shape: nil, fortranOrder: false, dataOffset: dataOffset,
                          problem: String(localized: "The header has no dtype this reader understands.", bundle: .module, comment: "NumPy header problem; dtype is NumPy's term, keep it."))
        }
        var shape: [Int]?
        if case .tuple(let items)? = entry("shape") {
            let dims = items.compactMap { item -> Int? in if case .int(let n) = item, n >= 0 { n } else { nil } }
            if dims.count == items.count { shape = dims }
        }
        var fortran = false
        if case .bool(let b)? = entry("fortran_order") { fortran = b }
        return Header(version: version, dtype: dtype, shape: shape, fortranOrder: fortran, dataOffset: dataOffset,
                      problem: shape == nil ? String(localized: "The header's shape is missing or not a tuple of sizes.", bundle: .module, comment: "NumPy header problem.") : nil)
    }

    /// A dtype from a descr value: a string, or a list of field tuples.
    static func dtype(_ value: AIPythonLiteral.Value, depth: Int = 0) -> NPYDtype? {
        switch value {
        case .string(let text):
            return simpleDtype(text)
        case .list(let items):
            guard depth < 8 else { return nil }
            var fields: [NPYDtype.Field] = []
            var size: Int? = 0
            var objects = false
            for item in items.prefix(1_000) {
                guard case .tuple(let parts) = item, parts.count >= 2 else { return nil }
                var name = "?"
                switch parts[0] {
                case .string(let s): name = s
                case .tuple(let titled): if titled.count == 2, case .string(let s) = titled[1] { name = s }
                default: break
                }
                guard let sub = dtype(parts[1], depth: depth + 1) else { return nil }
                var subShape: [Int] = []
                if parts.count >= 3 {
                    // NumPy refuses a sub-array dimension that is not a whole number of zero or more; so does this
                    // reader, so no negative size can reach the item size (a negative one made `available - expected`
                    // overflow).
                    let dims: [AIPythonLiteral.Value]
                    if case .tuple(let items) = parts[2] { dims = items } else { dims = [parts[2]] }
                    for dim in dims {
                        guard case .int(let n) = dim, n >= 0 else { return nil }
                        subShape.append(n)
                    }
                }
                objects = objects || sub.containsObjects
                var count: Int? = 1
                for d in subShape { count = count.flatMap { c in c.multipliedReportingOverflow(by: d).overflow ? nil : c * d } }
                if let s = size, let item = sub.itemSize, let count, case let (m, false) = item.multipliedReportingOverflow(by: count), case let (t, false) = s.addingReportingOverflow(m) { size = t } else { size = nil }
                fields.append(NPYDtype.Field(name: name, descr: sub.descr, shape: subShape))
            }
            let descr = "[" + fields.map { "('\($0.name)', '\($0.descr)'\($0.shape.isEmpty ? "" : ", \($0.shape)"))" }.joined(separator: ", ") + "]"
            let fieldCount = fields.count
            return NPYDtype(descr: AIText.cap(descr, 2_000),
                            description: String(localized: "structured (\(fieldCount) fields)", bundle: .module, comment: "NumPy dtype description. The argument is a field count."),
                            kind: nil, itemSize: size, byteOrder: .notApplicable, fields: fields, containsObjects: objects)
        default:
            return nil
        }
    }

    /// `<f8`, `|b1`, `>i4`, `<U12`, `|S5`, `<M8[ns]`, `|O`.
    static func simpleDtype(_ text: String) -> NPYDtype? {
        var chars = Substring(text)
        var order = NPYDtype.ByteOrder.little
        if let first = chars.first, "<>|=".contains(first) {
            order = first == ">" ? .big : first == "|" ? .notApplicable : .little
            chars = chars.dropFirst()
        }
        guard let letter = chars.first else { return nil }
        let kindLetter: String = letter == "?" ? "b" : letter == "a" ? "S" : String(letter)
        guard let kind = NPYDtype.Kind(rawValue: kindLetter) else { return nil }
        chars = chars.dropFirst()
        let digits = chars.prefix { $0.isASCII && $0.isNumber }
        let rest = chars.dropFirst(digits.count)
        var count = digits.isEmpty ? nil : Int(digits).flatMap { $0 <= 1 << 40 ? $0 : nil }
        if letter == "?" { count = 1 }
        let unit = rest.hasPrefix("[") && rest.hasSuffix("]") ? String(rest.dropFirst().dropLast()) : nil
        guard rest.isEmpty || unit != nil else { return nil }
        var itemSize: Int?
        let description: String
        let orderText = order == .big
            ? String(localized: ", big-endian", bundle: .module, comment: "Datatype suffix.")
            : (order == .little && (count ?? 1) > 1 && kind != .bytes && kind != .void
               ? String(localized: ", little-endian", bundle: .module, comment: "Datatype suffix.") : "")
        let n = count ?? 0
        let bits = n * 8
        let unitText = unit.map { " [\($0)]" } ?? ""
        switch kind {
        case .bool: itemSize = count ?? 1; description = String(localized: "boolean", bundle: .module, comment: "NumPy dtype description.")
        case .signedInteger: itemSize = count; description = String(localized: "\(bits)-bit signed integer", bundle: .module, comment: "Datatype description. The argument is a bit count.") + orderText
        case .unsignedInteger: itemSize = count; description = String(localized: "\(bits)-bit unsigned integer", bundle: .module, comment: "Datatype description. The argument is a bit count.") + orderText
        case .float: itemSize = count; description = String(localized: "\(bits)-bit float", bundle: .module, comment: "Datatype description. The argument is a bit count.") + orderText
        case .complex: itemSize = count; description = String(localized: "\(bits)-bit complex", bundle: .module, comment: "Datatype description. The argument is a bit count.") + orderText
        case .datetime: itemSize = count ?? 8; description = "datetime64" + unitText
        case .timedelta: itemSize = count ?? 8; description = "timedelta64" + unitText
        case .bytes: itemSize = count; description = String(localized: "byte string (\(n) bytes)", bundle: .module, comment: "NumPy dtype description. The argument is a byte count.")
        case .unicode: itemSize = count.map { $0 * 4 }; description = String(localized: "Unicode string (\(n) characters)", bundle: .module, comment: "NumPy dtype description. The argument is a character count.")
        case .void: itemSize = count; description = String(localized: "raw bytes (\(n) bytes)", bundle: .module, comment: "NumPy dtype description. The argument is a byte count.")
        case .object: itemSize = 8; description = String(localized: "Python object", bundle: .module, comment: "NumPy dtype description.")
        }
        if [.signedInteger, .unsignedInteger, .float, .complex].contains(kind), count == nil || count == 0 { return nil }
        return NPYDtype(descr: text, description: description, kind: kind, itemSize: itemSize, byteOrder: order,
                        fields: [], containsObjects: kind == .object)
    }

    // MARK: NPY

    static func readNPY(_ bytes: [UInt8], context: AIReadContext) -> NPYSummary {
        let h = header(bytes)!  // the caller checked the magic
        var warnings: [AIDataWarning] = []
        var elementCount: Int?
        var expected: Int?
        if let shape = h.shape {
            var n = 1
            var overflow = false
            for d in shape {
                let (r, o) = n.multipliedReportingOverflow(by: d)
                if o { overflow = true; break }
                n = r
            }
            elementCount = overflow ? nil : n
            if let count = elementCount, let size = h.dtype?.itemSize {
                let (r, o) = count.multipliedReportingOverflow(by: size)
                expected = o || r < 0 ? nil : r   // never negative, so `available - expected` cannot overflow
            }
        }
        let available = max(0, bytes.count - h.dataOffset)
        let objects = h.dtype?.containsObjects ?? false
        if objects { warnings.append(objectWarning) }
        if let problem = h.problem { warnings.append(AIDataWarning(.caution, problem)) }
        if let expected, !objects, available < expected {
            if context.wasCut {
                warnings.append(context.readCapWarning)
            } else {
                let missing = expected - available
                warnings.append(AIDataWarning(.caution, String(localized: "The file is shorter than its header says: \(missing) bytes of data are missing.", bundle: .module, comment: "NumPy warning. The argument is a byte count.")))
            }
        } else if let expected, !objects, available > expected, !context.wasCut {
            let extra = available - expected
            warnings.append(AIDataWarning(.caution, String(localized: "\(extra) bytes follow the array's data.", bundle: .module, comment: "NumPy warning. The argument is a byte count.")))
        }
        let preview = h.dtype.map { previewValues(bytes, from: h.dataOffset, dtype: $0, count: min(elementCount ?? 0, NPYSummary.maxPreview)) } ?? []

        let version = h.version
        var facts: [AIDataFact] = [AIDataFact(AIReadContext.formatLabel, String(localized: "NumPy array, version \(version)", bundle: .module, comment: "NumPy fact value. The argument is a version such as 1.0."))]
        if let dtype = h.dtype { facts.append(AIDataFact(String(localized: "Type", bundle: .module, comment: "Fact label: an array's element type."), dtype.description)) }
        if let shape = h.shape { facts.append(AIDataFact(String(localized: "Shape", bundle: .module, comment: "Fact label: an array's dimensions."), shapeText(shape))) }
        if let elementCount { facts.append(AIDataFact(String(localized: "Elements", bundle: .module, comment: "Fact label: values in an array."), elementCount.formatted())) }
        if let expected { facts.append(AIDataFact(String(localized: "Data", bundle: .module, comment: "Fact label: the size of an array's data."), ByteCountFormatter.string(fromByteCount: Int64(expected), countStyle: .file))) }
        if h.fortranOrder {
            facts.append(AIDataFact(String(localized: "Order", bundle: .module, comment: "Fact label: an array's memory order."),
                                    String(localized: "column-major (Fortran); the preview is in storage order", bundle: .module, comment: "NumPy fact value.")))
        }

        var headline = String(localized: "NumPy array", bundle: .module, comment: "Headline start for a NumPy array; NumPy is a product name.")
        if let shape = h.shape { headline += " · " + shapeText(shape) }
        if let dtype = h.dtype { headline += " · " + dtype.descr }
        return NPYSummary(headline: AIText.cap(headline, 300), version: h.version, dtype: h.dtype, shape: h.shape,
                          elementCount: elementCount, fortranOrder: h.fortranOrder, dataOffset: h.dataOffset,
                          expectedDataBytes: expected, availableDataBytes: available, containsPythonObjects: objects,
                          preview: preview, facts: facts, warnings: warnings)
    }

    static func shapeText(_ shape: [Int]) -> String {
        shape.isEmpty ? String(localized: "scalar", bundle: .module, comment: "The shape of an array with no dimensions.")
            : shape.map { String($0) }.joined(separator: " × ")
    }

    /// The first `count` values of a bool, integer, float or complex array, as NumPy would print them.
    static func previewValues(_ bytes: [UInt8], from offset: Int, dtype: NPYDtype, count: Int) -> [String] {
        guard let kind = dtype.kind, let size = dtype.itemSize, size > 0, count > 0, offset <= bytes.count else { return [] }
        let numeric: Set<NPYDtype.Kind> = [.bool, .signedInteger, .unsignedInteger, .float, .complex]
        guard numeric.contains(kind) else { return [] }
        let big = dtype.byteOrder == .big
        func word(_ at: Int, _ width: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<width {
                let b = UInt64(bytes[at + (big ? k : width - 1 - k)])
                v = v << 8 | b
            }
            return v
        }
        func float(_ at: Int, _ width: Int) -> String? {
            switch width {
            case 2: return "\(halfToFloat(UInt16(word(at, 2))))"
            case 4: return "\(Float(bitPattern: UInt32(word(at, 4))))"
            case 8: return "\(Double(bitPattern: word(at, 8)))"
            default: return nil
            }
        }
        var out: [String] = []
        let available = (bytes.count - offset) / size
        for index in 0..<min(count, available) {
            let at = offset + index * size
            switch kind {
            case .bool:
                out.append(bytes[at] != 0 ? "True" : "False")
            case .signedInteger:
                guard [1, 2, 4, 8].contains(size) else { return [] }
                let raw = word(at, size)
                let shift = UInt64(64 - size * 8)
                out.append(String(Int64(bitPattern: raw << shift) >> Int64(shift)))
            case .unsignedInteger:
                guard [1, 2, 4, 8].contains(size) else { return [] }
                out.append(String(word(at, size)))
            case .float:
                guard let v = float(at, size) else { return [] }
                out.append(v)
            case .complex:
                guard size == 8 || size == 16, let re = float(at, size / 2), let im = float(at + size / 2, size / 2) else { return [] }
                out.append(im.hasPrefix("-") ? "\(re)\(im)j" : "\(re)+\(im)j")
            default:
                return []
            }
        }
        return out
    }

    /// IEEE 754 half precision, decoded by hand (Float16 is not available on every Mac Vitrine builds for).
    static func halfToFloat(_ h: UInt16) -> Float {
        let sign: UInt32 = UInt32(h >> 15) << 31
        let exponent = Int((h >> 10) & 0x1F)
        let mantissa = UInt32(h & 0x3FF)
        if exponent == 0 {
            if mantissa == 0 { return Float(bitPattern: sign) }
            let value = Float(mantissa) / 1024 * Float(pow(2.0, -14.0))
            return sign != 0 ? -value : value
        }
        if exponent == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13)) }
        return Float(bitPattern: sign | UInt32(exponent - 15 + 127) << 23 | (mantissa << 13))
    }

    // MARK: NPZ

    static func readNPZ(_ bytes: [UInt8], listing: ArchiveListing, context: AIReadContext) -> NPZSummary {
        var members: [NPZSummary.Member] = []
        var others = 0
        var truncated = false
        for (index, entry) in listing.entries.enumerated() where !entry.isDirectory {
            guard entry.path.lowercased().hasSuffix(".npy") else { others += 1; continue }
            guard members.count < NPZSummary.maxMembers else { truncated = true; continue }
            let name = String(entry.path.dropLast(4))
            let compressed = entry.method != nil && entry.method != .stored
            var problem: String?
            var h: Header?
            if entry.isEncrypted {
                problem = String(localized: "The member is encrypted.", bundle: .module, comment: "Why an array inside an .npz cannot be read.")
            } else if let first = AIZip.member(bytes, listing: listing, index: index, limit: 64 * 1024) {
                h = header(first.bytes)
                // A header longer than the first read: read again up to its stated length.
                if let found = h, found.dtype == nil, found.dataOffset > first.bytes.count, !first.isComplete,
                   found.dataOffset <= maxHeaderBytes + 12,
                   let again = AIZip.member(bytes, listing: listing, index: index, limit: found.dataOffset) {
                    h = header(again.bytes)
                }
                if h == nil { problem = String(localized: "The member is not a NumPy array.", bundle: .module, comment: "Why an array inside an .npz cannot be read.") }
                else if let p = h?.problem { problem = p }
            } else {
                problem = String(localized: "The member could not be read.", bundle: .module, comment: "Why an array inside an .npz cannot be read.")
            }
            members.append(NPZSummary.Member(name: name, path: entry.path, dtype: h?.dtype, shape: h?.shape,
                                             fortranOrder: h?.fortranOrder ?? false,
                                             containsPythonObjects: h?.dtype?.containsObjects ?? false,
                                             compressed: compressed, uncompressedSize: entry.uncompressedSize,
                                             problem: problem))
        }
        let objects = members.contains { $0.containsPythonObjects }
        var warnings: [AIDataWarning] = []
        if objects {
            let names = members.filter(\.containsPythonObjects).prefix(5).map(\.name).joined(separator: ", ")
            warnings.append(AIDataWarning(.danger, String(localized: "Some arrays (\(names)) hold Python objects. NumPy can only load them by unpickling, which can run code; open this file only if you trust where it came from.", bundle: .module, comment: "NumPy archive danger warning. The argument is a list of array names.")))
        }
        let broken = members.filter { $0.problem != nil }.count
        if broken > 0 { warnings.append(AIDataWarning(.caution, String(localized: "\(broken) array headers could not be read.", bundle: .module, comment: "NumPy archive warning. The argument is a count."))) }
        if !listing.coverage.isComplete || context.wasCut { warnings.append(context.readCapWarning) }

        let total = listing.entries.filter { !$0.isDirectory && $0.path.lowercased().hasSuffix(".npy") }.count
        var facts: [AIDataFact] = [AIDataFact(String(localized: "Arrays", bundle: .module, comment: "Fact label: arrays in an .npz file."), total.formatted())]
        if members.contains(where: \.compressed) {
            facts.append(AIDataFact(String(localized: "Compression", bundle: .module, comment: "Fact label."), "deflate (savez_compressed)"))
        }
        if others > 0 { facts.append(AIDataFact(String(localized: "Other files", bundle: .module, comment: "Fact label: files in an .npz that are not arrays."), others.formatted())) }
        let yes = String(localized: "yes", bundle: .module, comment: "Table cell: the member is compressed.")
        let no = String(localized: "no", bundle: .module, comment: "Table cell: the member is not compressed.")
        let rows = members.prefix(AIDataTable.maxRows).map { m in
            [AIText.cap(m.name), m.dtype?.descr ?? "", m.shape.map(shapeText) ?? "",
             m.uncompressedSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "",
             m.compressed ? yes : no, m.problem ?? ""]
        }
        let headline = String(localized: "NumPy archive · \(total) arrays", bundle: .module, comment: "Headline for an .npz file; NumPy is a product name. The argument is an array count.")
        return NPZSummary(headline: headline, members: members,
                          membersTruncated: truncated, otherFiles: others, containsPythonObjects: objects,
                          table: AIDataTable(columns: [String(localized: "Name", bundle: .module, comment: "Table column."),
                                                       String(localized: "Type", bundle: .module, comment: "Table column."),
                                                       String(localized: "Shape", bundle: .module, comment: "Table column."),
                                                       String(localized: "Size", bundle: .module, comment: "Table column."),
                                                       String(localized: "Compressed", bundle: .module, comment: "Table column."),
                                                       String(localized: "Problem", bundle: .module, comment: "Table column.")],
                                             rows: Array(rows), totalRows: total, isTruncated: total > rows.count),
                          facts: facts, warnings: warnings)
    }
}

/// The small Python literal subset NumPy writes in an `.npy` header: dicts, lists, tuples, strings, integers,
/// True/False/None. Bounded in depth and length.
struct AIPythonLiteral {
    indirect enum Value: Equatable {
        case dict([(Value, Value)])
        case list([Value])
        case tuple([Value])
        case string(String)
        case int(Int)
        case bool(Bool)
        case none

        static func == (a: Value, b: Value) -> Bool {
            switch (a, b) {
            case (.string(let x), .string(let y)): x == y
            case (.int(let x), .int(let y)): x == y
            case (.bool(let x), .bool(let y)): x == y
            case (.none, .none): true
            case (.list(let x), .list(let y)), (.tuple(let x), .tuple(let y)): x == y
            case (.dict(let x), .dict(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            default: false
            }
        }
    }

    private let chars: [Character]
    private var i = 0
    private var items = 0
    static let maxDepth = 16
    static let maxItems = 20_000

    init(_ text: String) { chars = Array(text) }

    mutating func parse() -> Value? {
        guard let v = value(depth: 0) else { return nil }
        skip()
        return i == chars.count ? v : nil
    }

    private mutating func skip() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

    private mutating func value(depth: Int) -> Value? {
        skip()
        items += 1
        guard i < chars.count, depth < Self.maxDepth, items < Self.maxItems else { return nil }
        let c = chars[i]
        switch c {
        case "{":
            i += 1
            var entries: [(Value, Value)] = []
            while true {
                skip()
                if i < chars.count, chars[i] == "}" { i += 1; return .dict(entries) }
                guard let key = value(depth: depth + 1) else { return nil }
                skip()
                guard i < chars.count, chars[i] == ":" else { return nil }
                i += 1
                guard let v = value(depth: depth + 1) else { return nil }
                entries.append((key, v))
                skip()
                if i < chars.count, chars[i] == "," { i += 1; continue }
                if i < chars.count, chars[i] == "}" { i += 1; return .dict(entries) }
                return nil
            }
        case "[", "(":
            let close: Character = c == "[" ? "]" : ")"
            i += 1
            var list: [Value] = []
            while true {
                skip()
                if i < chars.count, chars[i] == close { i += 1; break }
                guard let v = value(depth: depth + 1) else { return nil }
                list.append(v)
                skip()
                if i < chars.count, chars[i] == "," { i += 1; continue }
                if i < chars.count, chars[i] == close { i += 1; break }
                return nil
            }
            return c == "[" ? .list(list) : .tuple(list)
        case "'", "\"":
            i += 1
            var s = ""
            while i < chars.count, chars[i] != c {
                if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                s.append(chars[i])
                i += 1
            }
            guard i < chars.count else { return nil }
            i += 1
            return .string(s)
        default:
            if c == "-" || c.isASCII && c.isNumber {
                var digits = ""
                if c == "-" { digits = "-"; i += 1 }
                while i < chars.count, chars[i].isASCII, chars[i].isNumber, digits.count < 20 { digits.append(chars[i]); i += 1 }
                if i < chars.count, chars[i] == "L" || chars[i] == "l" { i += 1 }  // Python 2's long suffix
                return Int(digits).map(Value.int)
            }
            for (word, v) in [("True", Value.bool(true)), ("False", Value.bool(false)), ("None", Value.none)] {
                let w = Array(word)
                if i + w.count <= chars.count, Array(chars[i..<(i + w.count)]) == w {
                    i += w.count
                    return v
                }
            }
            return nil
        }
    }
}
