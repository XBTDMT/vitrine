import Foundation

/// A JSON value as the lockfile readers need it. Objects keep their members in file order (lockfiles list packages
/// in a meaningful order) and look keys up by a linear search, which is cheap for the small objects it is used on.
/// roadmap: S-22
enum LockJSON {
    case object([LockJSONMember])
    case array([LockJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    subscript(key: String) -> LockJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }
    /// The members of an object as (key, value) pairs, in file order.
    var members: [(key: String, value: LockJSON)]? {
        if case .object(let m) = self { return m.map { ($0.key, $0.value) } } else { return nil }
    }
    var array: [LockJSON]? { if case .array(let a) = self { return a } else { return nil } }
    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    /// A string, or a number written as text (lockfileVersion is a number, pipfile-spec too).
    var text: String? {
        switch self {
        case .string(let s), .number(let s): return s
        default: return nil
        }
    }
    var isTrue: Bool { if case .bool(true) = self { return true } else { return false } }
}

/// One member of a JSON object. roadmap: S-22
struct LockJSONMember {
    let key: String
    let value: LockJSON
}

/// A forgiving JSON reader for untrusted lockfiles. It never throws: where the bytes end early or stop making sense
/// it closes every open object and array and returns what it read, with `complete` false, so an 8 MB prefix of a
/// 20 MB package-lock.json still gives a partial summary. Nesting is bounded by `maxDepth` (no unbounded recursion);
/// with `comments` it also skips // and /* */ comments, and it always accepts trailing commas (bun.lock is JSONC).
/// roadmap: S-22
struct LockJSONReader {
    static let maxDepth = 128

    private let b: [UInt8]
    private var i = 0
    private let comments: Bool
    private var stopped = false

    private init(_ bytes: [UInt8], comments: Bool) {
        b = bytes
        self.comments = comments
    }

    static func parse(_ bytes: [UInt8], comments: Bool = false) -> (value: LockJSON?, complete: Bool) {
        var r = LockJSONReader(bytes, comments: comments)
        if r.b.starts(with: [0xEF, 0xBB, 0xBF]) { r.i = 3 }
        let v = r.value(depth: 0)
        return (v, !r.stopped)
    }

    private mutating func skipSpace() {
        while i < b.count {
            let c = b[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1; continue }
            if comments, c == 0x2F, i + 1 < b.count {          // '/'
                if b[i + 1] == 0x2F {                            // line comment
                    while i < b.count, b[i] != 0x0A { i += 1 }
                    continue
                }
                if b[i + 1] == 0x2A {                            // block comment
                    i += 2
                    while i + 1 < b.count, !(b[i] == 0x2A && b[i + 1] == 0x2F) { i += 1 }
                    i = min(b.count, i + 2)
                    continue
                }
            }
            break
        }
    }

    private mutating func value(depth: Int) -> LockJSON? {
        skipSpace()
        guard !stopped, i < b.count else { stopped = true; return nil }
        switch b[i] {
        case 0x7B: return object(depth: depth)                   // {
        case 0x5B: return array(depth: depth)                    // [
        case 0x22: return string().map(LockJSON.string)          // "
        case 0x74: return literal("true", .bool(true))
        case 0x66: return literal("false", .bool(false))
        case 0x6E: return literal("null", .null)
        default: return number()
        }
    }

    private mutating func object(depth: Int) -> LockJSON? {
        guard depth < Self.maxDepth else { stopped = true; return nil }
        i += 1
        var members: [LockJSONMember] = []
        while true {
            skipSpace()
            guard i < b.count else { stopped = true; break }
            let c = b[i]
            if c == 0x7D { i += 1; return .object(members) }      // }
            if c == 0x2C { i += 1; continue }                     // , (trailing and repeated commas are tolerated)
            guard c == 0x22, let key = string() else { stopped = true; break }
            skipSpace()
            guard i < b.count, b[i] == 0x3A else { stopped = true; break }   // :
            i += 1
            guard let v = value(depth: depth + 1) else { break }
            members.append(LockJSONMember(key: key, value: v))
            if stopped { break }
        }
        return .object(members)
    }

    private mutating func array(depth: Int) -> LockJSON? {
        guard depth < Self.maxDepth else { stopped = true; return nil }
        i += 1
        var items: [LockJSON] = []
        while true {
            skipSpace()
            guard i < b.count else { stopped = true; break }
            if b[i] == 0x5D { i += 1; return .array(items) }      // ]
            if b[i] == 0x2C { i += 1; continue }
            guard let v = value(depth: depth + 1) else { break }
            items.append(v)
            if stopped { break }
        }
        return .array(items)
    }

    private mutating func literal(_ word: String, _ v: LockJSON) -> LockJSON? {
        let w = Array(word.utf8)
        guard i + w.count <= b.count, Array(b[i..<(i + w.count)]) == w else { stopped = true; return nil }
        i += w.count
        return v
    }

    private mutating func number() -> LockJSON? {
        let start = i
        while i < b.count, (0x30...0x39).contains(b[i]) || b[i] == 0x2D || b[i] == 0x2B || b[i] == 0x2E || b[i] == 0x65 || b[i] == 0x45 {
            i += 1
        }
        guard i > start else { stopped = true; return nil }
        return .number(String(decoding: b[start..<i], as: UTF8.self))
    }

    /// A string starting at the opening quote. Plain strings are sliced; escapes are decoded, including \u pairs.
    private mutating func string() -> String? {
        i += 1
        let start = i
        while i < b.count, b[i] != 0x22, b[i] != 0x5C { i += 1 }
        if i < b.count, b[i] == 0x22 {
            defer { i += 1 }
            return String(decoding: b[start..<i], as: UTF8.self)
        }
        var out = Array(b[start..<i])
        while i < b.count {
            let c = b[i]
            if c == 0x22 { i += 1; return String(decoding: out, as: UTF8.self) }
            if c != 0x5C { out.append(c); i += 1; continue }
            guard i + 1 < b.count else { break }
            let e = b[i + 1]
            i += 2
            switch e {
            case 0x6E: out.append(0x0A)
            case 0x74: out.append(0x09)
            case 0x72: out.append(0x0D)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x75:
                guard var scalar = hex4() else { stopped = true; return nil }
                if (0xD800...0xDBFF).contains(scalar), i + 1 < b.count, b[i] == 0x5C, b[i + 1] == 0x75 {
                    i += 2
                    if let low = hex4(), (0xDC00...0xDFFF).contains(low) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                }
                let u = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                out.append(contentsOf: Array(String(Character(u)).utf8))
            default: out.append(e)                                  // \" \\ \/ and anything else literally
            }
        }
        stopped = true
        return nil
    }

    private mutating func hex4() -> UInt32? {
        guard i + 4 <= b.count else { return nil }
        var v: UInt32 = 0
        for k in 0..<4 {
            let c = b[i + k]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: return nil
            }
            v = v << 4 | d
        }
        i += 4
        return v
    }
}
