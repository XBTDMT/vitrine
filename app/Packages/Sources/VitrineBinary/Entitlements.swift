import Foundation

/// A property-list value as entitlements, Info.plist files and profiles carry it, in a Sendable, comparable form.
public indirect enum PlistValue: Sendable, Equatable, CustomStringConvertible {
    case bool(Bool)
    case integer(Int64)
    case real(Double)
    case string(String)
    case date(Date)
    case data([UInt8])
    case array([PlistValue])
    case dictionary([String: PlistValue])

    /// Values one conversion may build. A binary property list can point to one object from many places, and Core
    /// Foundation hands that one shared object back each time, so a few hundred bytes can describe a tree of 16^12
    /// nodes (the property-list form of "billion laughs"). Every value built counts against this budget.
    public static let maxConvertedValues = 500_000

    /// The conversion found more values than `maxConvertedValues`: the property list is too large to show.
    public struct TooManyValues: Error, Equatable {}

    /// Converts what `PropertyListSerialization` returns; nil for anything a property list cannot hold, or for a
    /// value that expands past `maxConvertedValues`. Depth is bounded so a hostile nesting cannot exhaust the stack.
    public init?(propertyList value: Any, depth: Int = 0) {
        var budget = Self.maxConvertedValues
        guard let converted = try? Self.converting(value, depth: depth, budget: &budget) else { return nil }
        self = converted
    }

    /// The conversion under a value budget shared by the whole walk. Nil for anything a property list cannot hold
    /// (or nested past 64 levels, which the parent leaves out); throws `TooManyValues` once the budget is spent.
    public static func converting(_ value: Any, depth: Int = 0, budget: inout Int) throws -> PlistValue? {
        guard depth < 64 else { return nil }
        budget -= 1
        guard budget >= 0 else { throw TooManyValues() }
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .real(n.doubleValue) }
            return .integer(n.int64Value)
        case let s as String: return .string(s)
        case let d as Date: return .date(d)
        case let d as Data: return .data([UInt8](d))
        case let a as [Any]:
            var items: [PlistValue] = []
            items.reserveCapacity(min(a.count, budget))
            for item in a { if let converted = try converting(item, depth: depth + 1, budget: &budget) { items.append(converted) } }
            return .array(items)
        case let d as [String: Any]:
            var out: [String: PlistValue] = [:]
            for (k, v) in d { if let converted = try converting(v, depth: depth + 1, budget: &budget) { out[k] = converted } }
            return .dictionary(out)
        default: return nil
        }
    }

    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var integerValue: Int64? { if case .integer(let i) = self { i } else { nil } }
    public var dateValue: Date? { if case .date(let d) = self { d } else { nil } }
    public var arrayValue: [PlistValue]? { if case .array(let a) = self { a } else { nil } }
    public var dictionaryValue: [String: PlistValue]? { if case .dictionary(let d) = self { d } else { nil } }
    public var dataValue: [UInt8]? { if case .data(let d) = self { d } else { nil } }
    /// The strings of an array value (non-strings skipped), or a lone string as one element.
    public var stringArray: [String] {
        switch self {
        case .string(let s): [s]
        case .array(let a): a.compactMap(\.stringValue)
        default: []
        }
    }

    public var description: String {
        switch self {
        case .bool(let b): b ? "true" : "false"
        case .integer(let i): String(i)
        case .real(let r): String(r)
        case .string(let s): s
        case .date(let d): ISO8601DateFormatter().string(from: d)
        case .data(let d): "<\(d.count) bytes>"
        case .array(let a): "[" + a.map(\.description).joined(separator: ", ") + "]"
        case .dictionary(let d):
            "{" + d.keys.sorted().map { "\($0) = \(d[$0]?.description ?? "")" }.joined(separator: ", ") + "}"
        }
    }
}

/// Decodes property lists from untrusted bytes with a size cap. XML, binary and OpenStep formats are accepted;
/// Core Foundation's plist parser does not resolve external entities or fetch anything.
enum PropertyListDecoder {
    static func dictionary(_ bytes: [UInt8], limit: Int, what: String) throws -> [String: PlistValue] {
        guard bytes.count <= limit else {
            throw BinaryError.unsupported("\(what) is \(bytes.count) bytes, more than the \(limit)-byte cap")
        }
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil)
        } catch {
            throw BinaryError.malformed("\(what) is not a readable property list")
        }
        var budget = PlistValue.maxConvertedValues
        let value: PlistValue?
        do { value = try PlistValue.converting(object, budget: &budget) } catch {
            throw BinaryError.unsupported("\(what) is too large to show: it expands to more than \(PlistValue.maxConvertedValues) values")
        }
        guard let dict = value?.dictionaryValue else { throw BinaryError.malformed("\(what) is not a dictionary") }
        return dict
    }
}

/// Apple's DER entitlements (CoreEntitlements, the `0xfade7172` blob): `[APPLICATION 16] { INTEGER version,
/// [CONTEXT 16] dictionary }`, where a dictionary is a run of `SEQUENCE { UTF8String key, value }` and a value is a
/// BOOLEAN, INTEGER, UTF8String, SEQUENCE (array) or another `[CONTEXT 16]` dictionary.
enum DEREntitlements {
    struct Element {
        let tag: UInt8
        let content: ArraySlice<UInt8>
    }

    static let maxDepth = 32
    static let maxElements = 100_000

    static func decode(_ bytes: [UInt8]) throws -> [String: PlistValue] {
        var budget = maxElements
        var index = bytes.startIndex
        let outer = try element(bytes[...], &index)
        guard outer.tag == 0x70 else { throw BinaryError.malformed("DER entitlements do not start with [APPLICATION 16]") }
        var inner = outer.content.startIndex
        let version = try element(outer.content, &inner)
        guard version.tag == 0x02 else { throw BinaryError.malformed("DER entitlements have no version") }
        let dict = try element(outer.content, &inner)
        guard dict.tag == 0xB0 else { throw BinaryError.malformed("DER entitlements hold no dictionary") }
        guard case .dictionary(let out) = try value(dict, depth: 0, budget: &budget) else {
            throw BinaryError.malformed("DER entitlements hold no dictionary")
        }
        return out
    }

    /// One TLV at `index` (definite lengths only, as DER requires), advancing past it.
    static func element(_ bytes: ArraySlice<UInt8>, _ index: inout Int) throws -> Element {
        guard index < bytes.endIndex else { throw BinaryError.truncated("DER entitlements end early") }
        let tag = bytes[index]
        guard tag & 0x1F != 0x1F else { throw BinaryError.unsupported("DER entitlements use a long-form tag") }
        index += 1
        guard index < bytes.endIndex else { throw BinaryError.truncated("DER entitlements end early") }
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let width = length & 0x7F
            guard width >= 1, width <= 4 else { throw BinaryError.malformed("DER entitlements have a bad length") }
            guard bytes.endIndex - index >= width else { throw BinaryError.truncated("DER entitlements end early") }
            length = 0
            for _ in 0..<width { length = length << 8 | Int(bytes[index]); index += 1 }
        }
        guard length <= bytes.endIndex - index else { throw BinaryError.truncated("a DER value runs past its parent") }
        defer { index += length }
        return Element(tag: tag, content: bytes[index..<(index + length)])
    }

    static func value(_ e: Element, depth: Int, budget: inout Int) throws -> PlistValue {
        budget -= 1
        guard budget > 0 else { throw BinaryError.unsupported("DER entitlements hold more than \(maxElements) values") }
        guard depth < maxDepth else { throw BinaryError.unsupported("DER entitlements nest deeper than \(maxDepth)") }
        switch e.tag {
        case 0x01:
            return .bool(e.content.first.map { $0 != 0 } ?? false)
        case 0x02:
            guard !e.content.isEmpty, e.content.count <= 8 else { throw BinaryError.malformed("a DER integer is too wide") }
            var v: Int64 = (e.content.first ?? 0) & 0x80 != 0 ? -1 : 0
            for byte in e.content { v = v << 8 | Int64(byte) }
            return .integer(v)
        case 0x0C:
            return .string(String(decoding: e.content, as: UTF8.self))
        case 0x30:
            var items: [PlistValue] = []
            var i = e.content.startIndex
            while i < e.content.endIndex {
                items.append(try value(try element(e.content, &i), depth: depth + 1, budget: &budget))
            }
            return .array(items)
        case 0xB0, 0x31:
            var out: [String: PlistValue] = [:]
            var i = e.content.startIndex
            while i < e.content.endIndex {
                let pair = try element(e.content, &i)
                guard pair.tag == 0x30 else { throw BinaryError.malformed("a DER dictionary entry is not a pair") }
                var j = pair.content.startIndex
                let key = try element(pair.content, &j)
                guard key.tag == 0x0C else { throw BinaryError.malformed("a DER dictionary key is not a string") }
                let item = try value(try element(pair.content, &j), depth: depth + 1, budget: &budget)
                out[String(decoding: key.content, as: UTF8.self)] = item
            }
            return .dictionary(out)
        default:
            throw BinaryError.unsupported(String(format: "DER entitlements use tag 0x%02x", e.tag))
        }
    }
}
