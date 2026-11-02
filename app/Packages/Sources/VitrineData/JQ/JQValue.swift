import Foundation

/// A jq value: JSON's six kinds, with every number a double as jq 1.7 keeps it. Not `indirect`: arrays and objects
/// already live on the heap, so each scalar stays inline (a boxed number per element would cost a heap allocation
/// each on a 50 MB input). Equality is jq's: strings compare by their UTF-8 bytes (not by Unicode canonical
/// equivalence, which Swift's `String ==` uses), objects compare by their key sets and values whatever the key order,
/// and `nan` equals nothing. roadmap: S-5
public enum JQValue: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JQValue])
    case object(JQObject)

    /// jq's `type` name: "null", "boolean", "number", "string", "array" or "object".
    public var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    /// `false` and `null` are false; everything else is true.
    public var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        default: true
        }
    }
}

extension JQValue: Equatable {
    public static func == (a: JQValue, b: JQValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return JQOrder.compareStrings(x, y) == 0
        case (.array(let x), .array(let y)):
            guard x.count == y.count else { return false }
            for i in x.indices where x[i] != y[i] { return false }
            return true
        case (.object(let x), .object(let y)): return x == y
        default: return false
        }
    }
}

extension JQValue: CustomStringConvertible {
    /// The compact JSON text, as `jq -c` prints it.
    public var description: String { compactJSON() }
}

/// A jq object: keys keep their insertion order (what jq 1.7 prints), lookups go through a hash index once the object
/// grows past a few keys, and `sortedKeys` gives jq's `keys` order (by Unicode code point). Setting an existing key
/// replaces its value in place, as jq does; removing one and setting it again puts it last. Storage is shared until
/// written (copy on write). The object also remembers how deep it nests, so the engine can bound value depth without
/// walking every object again. roadmap: S-5
public struct JQObject: Sendable {
    final class Storage: @unchecked Sendable {
        var keys: [String]
        var values: [JQValue]
        /// Key → slot, built once the object has more than `indexThreshold` keys. Keys equal under Swift's String
        /// equality but not byte for byte share an entry; `slot(of:)` checks the bytes and scans when they differ.
        var index: [String: Int]?
        /// 1 + the deepest value's depth (an upper bound after removals).
        var depth: Int

        init(keys: [String] = [], values: [JQValue] = [], index: [String: Int]? = nil, depth: Int = 1) {
            self.keys = keys; self.values = values; self.index = index; self.depth = depth
        }

        func copy() -> Storage { Storage(keys: keys, values: values, index: index, depth: depth) }
    }

    static let indexThreshold = 8
    var storage: Storage

    public init() { storage = Storage() }

    /// Pairs in order; a repeated key keeps its first position and takes the later value.
    public init(_ pairs: some Sequence<(String, JQValue)>) {
        self.init()
        for (key, value) in pairs { set(key, value) }
    }

    public var count: Int { storage.keys.count }
    public var isEmpty: Bool { storage.keys.isEmpty }
    /// Keys in insertion order (jq's output order).
    public var keys: [String] { storage.keys }
    /// Values in insertion order.
    public var values: [JQValue] { storage.values }
    /// Keys sorted by Unicode code point, as jq's `keys` returns them.
    public var sortedKeys: [String] { storage.keys.sorted { JQOrder.compareStrings($0, $1) < 0 } }
    /// Key-value pairs in insertion order.
    public var pairs: [(key: String, value: JQValue)] { Array(zip(storage.keys, storage.values)).map { ($0.0, $0.1) } }

    public subscript(key: String) -> JQValue? {
        get { slot(of: key).map { storage.values[$0] } }
        set {
            if let newValue { set(key, newValue) } else { remove(key) }
        }
    }

    var depth: Int { storage.depth }

    func slot(of key: String) -> Int? {
        if let index = storage.index {
            guard let i = index[key] else { return nil }
            if JQOrder.compareStrings(storage.keys[i], key) == 0 { return i }
        }
        for i in storage.keys.indices where JQOrder.compareStrings(storage.keys[i], key) == 0 { return i }
        return nil
    }

    private mutating func makeUnique() {
        if !isKnownUniquelyReferenced(&storage) { storage = storage.copy() }
    }

    /// Sets `key`. `valueDepth`, when the caller already knows it, saves walking the value.
    mutating func set(_ key: String, _ value: JQValue, valueDepth: Int? = nil) {
        let depth = 1 + (valueDepth ?? JQDepth.of(value))
        makeUnique()
        if depth > storage.depth { storage.depth = depth }
        if let i = slot(of: key) {
            storage.values[i] = value
            return
        }
        storage.keys.append(key)
        storage.values.append(value)
        let n = storage.keys.count - 1
        if storage.index != nil {
            if storage.index![key] == nil { storage.index![key] = n }
        } else if storage.keys.count > Self.indexThreshold {
            rebuildIndex()
        }
    }

    mutating func remove(_ key: String) {
        guard let i = slot(of: key) else { return }
        makeUnique()
        storage.keys.remove(at: i)
        storage.values.remove(at: i)
        if storage.index != nil { rebuildIndex() }
    }

    private mutating func rebuildIndex() {
        var index: [String: Int] = [:]
        index.reserveCapacity(storage.keys.count)
        for (i, key) in storage.keys.enumerated() where index[key] == nil { index[key] = i }
        storage.index = index
    }
}

extension JQObject: Equatable {
    /// Same keys (byte for byte) with equal values, in any order.
    public static func == (a: JQObject, b: JQObject) -> Bool {
        if a.storage === b.storage { return true }
        guard a.count == b.count else { return false }
        for (i, key) in a.storage.keys.enumerated() {
            guard let j = b.slot(of: key), a.storage.values[i] == b.storage.values[j] else { return false }
        }
        return true
    }
}

extension JQObject: Sequence {
    public func makeIterator() -> AnyIterator<(key: String, value: JQValue)> {
        var i = 0
        let keys = storage.keys, values = storage.values
        return AnyIterator {
            guard i < keys.count else { return nil }
            defer { i += 1 }
            return (keys[i], values[i])
        }
    }
}

/// How deeply a value nests: 0 for a scalar, 1 for an empty container. Objects remember theirs; arrays are walked, but
/// only through nested arrays. roadmap: S-5
enum JQDepth {
    static func of(_ value: JQValue) -> Int {
        switch value {
        case .array(let items):
            var deepest = 0
            for item in items {
                switch item {
                case .array, .object: deepest = max(deepest, of(item))
                default: continue
                }
            }
            return 1 + deepest
        case .object(let object): return object.depth
        default: return 0
        }
    }
}

/// jq's total order: null < false < true < numbers < strings < arrays < objects; strings by code point (their UTF-8
/// bytes), arrays element by element, objects by their sorted key sets and then their values in key order.
/// roadmap: S-5
enum JQOrder {
    static func rank(_ value: JQValue) -> Int {
        switch value {
        case .null: 0
        case .bool(let b): b ? 2 : 1
        case .number: 3
        case .string: 4
        case .array: 5
        case .object: 6
        }
    }

    /// -1, 0 or 1. `nan` sorts below every other number and equal to itself, so sorting stays a total order.
    static func compare(_ a: JQValue, _ b: JQValue) -> Int {
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb ? -1 : 1 }
        switch (a, b) {
        case (.number(let x), .number(let y)):
            if x.isNaN || y.isNaN { return x.isNaN ? (y.isNaN ? 0 : -1) : 1 }
            return x < y ? -1 : (x == y ? 0 : 1)
        case (.string(let x), .string(let y)):
            return compareStrings(x, y)
        case (.array(let x), .array(let y)):
            for i in 0..<min(x.count, y.count) {
                let c = compare(x[i], y[i])
                if c != 0 { return c }
            }
            return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
        case (.object(let x), .object(let y)):
            let kx = x.sortedKeys, ky = y.sortedKeys
            for i in 0..<min(kx.count, ky.count) {
                let c = compareStrings(kx[i], ky[i])
                if c != 0 { return c }
            }
            if kx.count != ky.count { return kx.count < ky.count ? -1 : 1 }
            for key in kx {
                let c = compare(x[key] ?? .null, y[key] ?? .null)
                if c != 0 { return c }
            }
            return 0
        default:
            return 0
        }
    }

    /// Byte-wise comparison of the UTF-8 encodings, which is code point order.
    static func compareStrings(_ a: String, _ b: String) -> Int {
        var a = a, b = b
        return a.withUTF8 { pa in
            b.withUTF8 { pb in
                let n = min(pa.count, pb.count)
                if n > 0, let x = pa.baseAddress, let y = pb.baseAddress {
                    let c = memcmp(x, y, n)
                    if c != 0 { return c < 0 ? -1 : 1 }
                }
                return pa.count == pb.count ? 0 : (pa.count < pb.count ? -1 : 1)
            }
        }
    }

    /// The indices of `keys` in a stable sort by jq's order. Keys that are all numbers or all strings (or one-element
    /// arrays of them, as `sort_by(f)` builds) sort on their plain values.
    static func stableSortIndices(_ keys: [JQValue]) -> [Int] {
        var plain = keys
        if keys.allSatisfy({ if case .array(let a) = $0 { a.count == 1 } else { false } }) {
            plain = keys.map { if case .array(let a) = $0 { a[0] } else { $0 } }
        }
        var numbers: [Double] = []
        numbers.reserveCapacity(plain.count)
        for case .number(let d) in plain where !d.isNaN { numbers.append(d) }
        if numbers.count == plain.count {
            return plain.indices.sorted { i, j in numbers[i] != numbers[j] ? numbers[i] < numbers[j] : i < j }
        }
        var strings: [String] = []
        strings.reserveCapacity(plain.count)
        for case .string(let s) in plain { strings.append(s) }
        if strings.count == plain.count {
            return plain.indices.sorted { i, j in
                let c = compareStrings(strings[i], strings[j])
                return c != 0 ? c < 0 : i < j
            }
        }
        return keys.indices.sorted { i, j in
            let c = compare(keys[i], keys[j])
            return c != 0 ? c < 0 : i < j
        }
    }

    /// Groups of indices whose keys are equal in jq's order, groups sorted by key and each group in input order — what
    /// a stable sort followed by grouping equal neighbours gives, in linear time plus a sort of the distinct keys.
    static func groupIndices(_ keys: [JQValue]) -> [[Int]] {
        var slot: [[UInt8]: Int] = [:]
        var groups: [[Int]] = []
        var representatives: [JQValue] = []
        for (i, key) in keys.enumerated() {
            var text: [UInt8] = []
            canonical(key, into: &text)
            if let g = slot[text] {
                groups[g].append(i)
            } else {
                slot[text] = groups.count
                groups.append([i])
                representatives.append(key)
            }
        }
        return stableSortIndices(representatives).map { groups[$0] }
    }

    /// A text equal for two values exactly when `compare` says they are equal: object keys sorted, -0 as 0, nan
    /// distinct from null.
    static func canonical(_ value: JQValue, into out: inout [UInt8]) {
        switch value {
        case .null: out.append(UInt8(ascii: "n"))
        case .bool(let b): out.append(b ? UInt8(ascii: "t") : UInt8(ascii: "f"))
        case .number(let d):
            if d.isNaN { out.append(UInt8(ascii: "N")); return }
            if d.isInfinite { out.append(contentsOf: Array((d < 0 ? "-I" : "I").utf8)); return }
            out.append(UInt8(ascii: "#"))
            out.append(contentsOf: Array(JQNumberFormat.format(d == 0 ? 0 : d).utf8))
        case .string(let s): JQJSONWriter.appendString(s, to: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                canonical(item, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let object):
            out.append(UInt8(ascii: "{"))
            for (i, key) in object.sortedKeys.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                JQJSONWriter.appendString(key, to: &out)
                out.append(UInt8(ascii: ":"))
                canonical(object[key] ?? .null, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }
}
