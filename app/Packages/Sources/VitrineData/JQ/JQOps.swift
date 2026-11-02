import Foundation

/// jq's operators and indexing, with its type rules and error wording. roadmap: S-5
enum JQOps {
    static func dump(_ v: JQValue) -> String { JQJSONWriter.errorDump(v) }

    static func described(_ v: JQValue) -> String { "\(v.typeName) (\(dump(v)))" }

    // MARK: Indexing

    /// `.[key]`: object by string, array by number (negative counts from the end), slices by `{start, end}`, an
    /// array of indices by an array; null gives null.
    static func index(_ value: JQValue, _ key: JQValue) throws -> JQValue {
        switch (value, key) {
        case (.object(let object), .string(let name)):
            return object[name] ?? .null
        case (.array(let items), .number(let n)):
            guard let i = arrayIndex(n, count: items.count) else { return .null }
            return items[i]
        case (.null, .string), (.null, .number), (.null, .null):
            return .null
        case (.null, .object(let range)), (.array, .object(let range)), (.string, .object(let range)):
            return try slice(value, range["start"] ?? .null, range["end"] ?? .null)
        case (.array(let items), .array(let needle)):
            return indices(of: needle, in: items)
        case (.array, .string(let name)):
            throw JQThrown("Cannot index array with \"\(name)\"")
        case (_, .string(let name)):
            throw JQThrown("Cannot index \(value.typeName) with \"\(name)\"")
        default:
            throw JQThrown("Cannot index \(value.typeName) with \(key.typeName)")
        }
    }

    /// An in-range index for `n` (floored; negative from the end), nil when out of range or not finite.
    static func arrayIndex(_ n: Double, count: Int) -> Int? {
        guard n.isFinite else { return nil }
        var f = n.rounded(.down)
        if f < 0 { f += Double(count) }
        guard f >= 0, f < Double(count) else { return nil }
        return Int(f)
    }

    /// Positions where `needle` occurs as a contiguous run of `items` (null for an empty needle, as jq).
    static func indices(of needle: [JQValue], in items: [JQValue]) -> JQValue {
        guard !needle.isEmpty else { return .null }
        var out: [JQValue] = []
        if needle.count <= items.count {
            for start in 0...(items.count - needle.count) {
                var match = true
                for j in needle.indices where items[start + j] != needle[j] { match = false; break }
                if match { out.append(.number(Double(start))) }
            }
        }
        return .array(out)
    }

    /// Clamped slice bounds for a sequence of `count`: start floored, end rounded up, negatives from the end.
    static func sliceBounds(_ start: JQValue, _ end: JQValue, count: Int) throws -> (Int, Int) {
        func number(_ v: JQValue, _ fallback: Double) throws -> Double {
            switch v {
            case .null: return fallback
            case .number(let d): return d
            default: throw JQThrown("Start and end indices of an array slice must be numbers")
            }
        }
        var s = try number(start, 0), e = try number(end, Double(count))
        let n = Double(count)
        if s.isNaN { s = 0 }
        if e.isNaN { e = n }
        if s < 0 { s += n }
        if e < 0 { e += n }
        s = min(max(s, 0), n)
        e = min(max(e, 0), n)
        if e < s { e = s }
        let lower = Int(s.rounded(.down))
        let upper = min(count, Int(e.rounded(.up)))
        return (lower, max(lower, upper))
    }

    static func slice(_ value: JQValue, _ start: JQValue, _ end: JQValue) throws -> JQValue {
        switch value {
        case .null:
            return .null
        case .array(let items):
            let (s, e) = try sliceBounds(start, end, count: items.count)
            return .array(Array(items[s..<e]))
        case .string(let text):
            let scalars = text.unicodeScalars
            let (s, e) = try sliceBounds(start, end, count: scalars.count)
            let a = scalars.index(scalars.startIndex, offsetBy: s)
            let b = scalars.index(a, offsetBy: e - s)
            return .string(String(scalars[a..<b]))
        default:
            throw JQThrown("Cannot index \(value.typeName) with object")
        }
    }

    // MARK: Arithmetic

    static func binary(_ op: JQBinaryOp, _ a: JQValue, _ b: JQValue, _ interp: JQInterpreter) throws -> JQValue {
        switch op {
        case .add: return try add(a, b, interp)
        case .subtract: return try subtract(a, b)
        case .multiply: return try multiply(a, b, interp)
        case .divide: return try divide(a, b, interp)
        case .modulo: return try modulo(a, b)
        case .equal: return .bool(a == b)
        case .notEqual: return .bool(a != b)
        case .less: return .bool(JQOrder.compare(a, b) < 0)
        case .lessEqual: return .bool(JQOrder.compare(a, b) <= 0)
        case .greater: return .bool(JQOrder.compare(a, b) > 0)
        case .greaterEqual: return .bool(JQOrder.compare(a, b) >= 0)
        }
    }

    static func add(_ a: JQValue, _ b: JQValue, _ interp: JQInterpreter) throws -> JQValue {
        switch (a, b) {
        case (.null, _): return b
        case (_, .null): return a
        case (.number(let x), .number(let y)): return .number(x + y)
        case (.string(let x), .string(let y)):
            try interp.checkStringSize(x.utf8.count + y.utf8.count)
            return .string(x + y)
        case (.array(let x), .array(let y)):
            try interp.checkArraySize(x.count + y.count)
            return .array(x + y)
        case (.object(var x), .object(let y)):
            for (key, value) in zip(y.storage.keys, y.storage.values) { x.set(key, value) }
            return .object(x)
        default:
            throw JQThrown("\(described(a)) and \(described(b)) cannot be added")
        }
    }

    static func subtract(_ a: JQValue, _ b: JQValue) throws -> JQValue {
        switch (a, b) {
        case (.number(let x), .number(let y)): return .number(x - y)
        case (.array(let x), .array(let y)):
            return .array(x.filter { item in !y.contains(item) })
        default:
            throw JQThrown("\(described(a)) and \(described(b)) cannot be subtracted")
        }
    }

    static func multiply(_ a: JQValue, _ b: JQValue, _ interp: JQInterpreter) throws -> JQValue {
        switch (a, b) {
        case (.number(let x), .number(let y)): return .number(x * y)
        case (.string(let s), .number(let n)), (.number(let n), .string(let s)):
            // jq 1.7: repeat the string n times (n truncated toward zero); fewer than once gives null.
            guard n >= 1 else { return .null }
            let times = n >= Double(Int32.max) ? Int(Int32.max) : Int(n)
            try interp.checkStringSize(s.utf8.count.multipliedReportingOverflow(by: times).overflow
                                       ? Int.max : s.utf8.count * times)
            return .string(String(repeating: s, count: times))
        case (.object(let x), .object(let y)):
            return .object(deepMerge(x, y))
        default:
            throw JQThrown("\(described(a)) and \(described(b)) cannot be multiplied")
        }
    }

    static func deepMerge(_ a: JQObject, _ b: JQObject) -> JQObject {
        var out = a
        for (key, value) in zip(b.storage.keys, b.storage.values) {
            if case .object(let left) = out[key] ?? .null, case .object(let right) = value {
                out.set(key, .object(deepMerge(left, right)))
            } else {
                out.set(key, value)
            }
        }
        return out
    }

    static func divide(_ a: JQValue, _ b: JQValue, _ interp: JQInterpreter) throws -> JQValue {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            if y == 0 { throw JQThrown("\(described(a)) and \(described(b)) cannot be divided because the divisor is zero") }
            return .number(x / y)
        case (.string(let x), .string(let y)):
            return split(x, by: y)
        default:
            throw JQThrown("\(described(a)) and \(described(b)) cannot be divided")
        }
    }

    static func modulo(_ a: JQValue, _ b: JQValue) throws -> JQValue {
        guard case .number(let x) = a, case .number(let y) = b else {
            throw JQThrown("\(described(a)) and \(described(b)) cannot be divided")
        }
        if x.isNaN || y.isNaN { return .number(.nan) }
        let divisor = truncatedInt(y)
        if divisor == 0 { throw JQThrown("\(described(a)) and \(described(b)) cannot be divided because the divisor is zero") }
        let dividend = truncatedInt(x)
        if divisor == -1 { return .number(0) }
        return .number(Double(dividend % divisor))
    }

    /// Truncates toward zero into Int64's range, as jq's `(intmax_t)` cast does for in-range values.
    static func truncatedInt(_ d: Double) -> Int64 {
        if d >= 9.2e18 { return Int64.max }
        if d <= -9.2e18 { return Int64.min }
        return Int64(d.rounded(.towardZero))
    }

    /// `"a,b" / ","` and `split(",")`: by the separator's bytes; an empty separator splits into characters
    /// (code points); an empty input gives [].
    static func split(_ text: String, by separator: String) -> JQValue {
        if text.isEmpty { return .array([]) }
        if separator.isEmpty { return .array(text.unicodeScalars.map { .string(String($0)) }) }
        let hay = Array(text.utf8), needle = Array(separator.utf8)
        var out: [JQValue] = []
        var start = 0, i = 0
        while i + needle.count <= hay.count {
            if hay[i] == needle[0], Array(hay[i..<(i + needle.count)]) == needle {
                out.append(.string(String(decoding: hay[start..<i], as: UTF8.self)))
                i += needle.count
                start = i
            } else {
                i += 1
            }
        }
        out.append(.string(String(decoding: hay[start...], as: UTF8.self)))
        return .array(out)
    }
}

/// `getpath`, `setpath` and `delpaths` over jq paths (arrays of keys, indices and `{start, end}` slices).
/// roadmap: S-5
enum JQPaths {
    static func get(_ root: JQValue, _ path: [JQValue]) throws -> JQValue {
        var current = root
        for component in path {
            if case .null = current { return .null }
            current = try JQOps.index(current, component)
        }
        return current
    }

    static func set(_ root: JQValue, _ path: [JQValue], _ value: JQValue, _ interp: JQInterpreter) throws -> JQValue {
        if path.count > interp.valueDepthLimit {
            throw JQStop(reason: "a value nested deeper than the depth limit of \(interp.valueDepthLimit) levels")
        }
        let result = try set(root, path[...], value, interp)
        try interp.checkDepth(result)
        return result
    }

    private static func set(_ root: JQValue, _ path: ArraySlice<JQValue>, _ value: JQValue, _ interp: JQInterpreter) throws -> JQValue {
        guard let key = path.first else { return value }
        let rest = path.dropFirst()
        switch key {
        case .string(let name):
            switch root {
            case .null:
                var object = JQObject()
                object.set(name, try set(.null, rest, value, interp))
                return .object(object)
            case .object(var object):
                let child = object[name] ?? .null
                object.set(name, try set(child, rest, value, interp))
                return .object(object)
            default:
                throw JQThrown("Cannot index \(root.typeName) with \"\(name)\"")
            }
        case .number(let n):
            var items: [JQValue]
            switch root {
            case .null: items = []
            case .array(let a): items = a
            default: throw JQThrown("Cannot index \(root.typeName) with number")
            }
            guard n.isFinite else { throw JQThrown("Array index must be finite") }
            var i = Int(n.rounded(.down).jqClamped(-9e15, 9e15))
            if i < 0 {
                i += items.count
                if i < 0 { throw JQThrown("Out of bounds negative array index") }
            }
            if i >= items.count {
                try interp.checkArraySize(i + 1)
                items.append(contentsOf: repeatElement(JQValue.null, count: i + 1 - items.count))
            }
            items[i] = try set(items[i], rest, value, interp)
            return .array(items)
        case .object(let range):
            var items: [JQValue]
            switch root {
            case .null: items = []
            case .array(let a): items = a
            default: throw JQThrown("Cannot update field at object index of \(root.typeName)")
            }
            let (s, e) = try JQOps.sliceBounds(range["start"] ?? .null, range["end"] ?? .null, count: items.count)
            let replaced = try set(.array(Array(items[s..<e])), rest, value, interp)
            guard case .array(let replacement) = replaced else {
                throw JQThrown("A slice of an array can only be assigned another array")
            }
            items.replaceSubrange(s..<e, with: replacement)
            return .array(items)
        default:
            throw JQThrown("Invalid path component")
        }
    }

    /// Deletes every path, longest and last first (jq sorts them and deletes from the end).
    static func delete(_ root: JQValue, _ paths: [[JQValue]], _ interp: JQInterpreter) throws -> JQValue {
        let sorted = paths.map { JQValue.array($0) }.sorted { JQOrder.compare($0, $1) < 0 }
        var current = root
        for case .array(let path) in sorted.reversed() {
            try interp.tick()
            current = try delete(current, path[...])
        }
        return current
    }

    private static func delete(_ root: JQValue, _ path: ArraySlice<JQValue>) throws -> JQValue {
        guard let key = path.first else { return .null }
        if case .null = root { return .null }
        let rest = path.dropFirst()
        if rest.isEmpty {
            switch (root, key) {
            case (.object(var object), .string(let name)):
                object.remove(name)
                return .object(object)
            case (.array(var items), .number(let n)):
                guard n.isFinite else { return root }
                var i = Int(n.rounded(.down).jqClamped(-9e15, 9e15))
                if i < 0 {
                    i += items.count
                    if i < 0 { throw JQThrown("Out of bounds negative array index") }
                }
                if i < items.count { items.remove(at: i) }
                return .array(items)
            case (.array(var items), .object(let range)):
                let (s, e) = try JQOps.sliceBounds(range["start"] ?? .null, range["end"] ?? .null, count: items.count)
                items.removeSubrange(s..<e)
                return .array(items)
            case (_, .string(let name)):
                throw JQThrown("Cannot delete field at object index of \(root.typeName) (\"\(name)\")")
            default:
                throw JQThrown("Cannot delete field at index of \(root.typeName)")
            }
        }
        let child = try JQOps.index(root, key)
        if case .null = child { return root }
        let updated = try delete(child, rest)
        switch (root, key) {
        case (.object(var object), .string(let name)):
            object.set(name, updated)
            return .object(object)
        case (.array(var items), .number(let n)):
            guard let i = JQOps.arrayIndex(n, count: items.count) else { return root }
            items[i] = updated
            return .array(items)
        case (.array(var items), .object(let range)):
            let (s, e) = try JQOps.sliceBounds(range["start"] ?? .null, range["end"] ?? .null, count: items.count)
            guard case .array(let replacement) = updated else { return root }
            items.replaceSubrange(s..<e, with: replacement)
            return .array(items)
        default:
            return root
        }
    }
}

extension Double {
    func jqClamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}
