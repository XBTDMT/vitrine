import Foundation

/// A TOML value as Cargo.lock, poetry.lock and uv.lock use them. Numbers, booleans and dates stay as their text.
/// roadmap: S-22
indirect enum LockTOML {
    case string(String)
    case array([LockTOML])
    case table([String: LockTOML])
    case other(String)

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var array: [LockTOML]? { if case .array(let a) = self { return a } else { return nil } }
    var table: [String: LockTOML]? { if case .table(let t) = self { return t } else { return nil } }
    /// A string or a bare value (a number such as `version = 3`) as text.
    var text: String? {
        switch self {
        case .string(let s), .other(let s): return s
        default: return nil
        }
    }
}

/// One table of a TOML document: its header (`package`, `package.source`, `metadata.files`; empty for the keys
/// before the first header), whether it was an array-of-tables header (`[[package]]`), and its keys. Dotted keys
/// are kept joined (`a.b = 1` is the key "a.b"). roadmap: S-22
struct LockTOMLSection {
    var header: String
    var isArray: Bool
    var values: [String: LockTOML] = [:]
}

/// A small TOML reader, enough for lockfiles: headers, keys (bare, quoted, dotted), basic and literal strings
/// (single and multi-line), arrays across lines, inline tables, comments, and bare values kept as text. It never
/// throws: a line it cannot read is skipped and counted, and nesting is bounded by `maxDepth`. roadmap: S-22
struct LockTOMLReader {
    static let maxDepth = 32

    private let b: [UInt8]
    private var i = 0
    private(set) var skippedLines = 0

    private init(_ bytes: [UInt8]) { b = bytes }

    static func parse(_ bytes: [UInt8]) -> (sections: [LockTOMLSection], skippedLines: Int) {
        var r = LockTOMLReader(bytes)
        if r.b.starts(with: [0xEF, 0xBB, 0xBF]) { r.i = 3 }
        var sections = [LockTOMLSection(header: "", isArray: false)]
        while true {
            r.skipBlank(newlines: true)
            guard r.i < r.b.count else { break }
            if r.b[r.i] == 0x5B {                                       // [
                if let s = r.header() { sections.append(s) } else { r.skippedLines += 1; r.skipLine() }
                continue
            }
            let lineStart = r.i
            if let key = r.key(), r.expect(0x3D), let v = r.value(depth: 0) {   // =
                sections[sections.count - 1].values[key] = v
                r.skipBlank(newlines: false)
                if r.i < r.b.count, r.b[r.i] != 0x0A { r.skippedLines += 1 }
                r.skipLine()
            } else {
                r.skippedLines += 1
                if r.i <= lineStart { r.i = lineStart }
                r.skipLine()
            }
        }
        return (sections, r.skippedLines)
    }

    // MARK: Scanning

    private mutating func skipBlank(newlines: Bool) {
        while i < b.count {
            let c = b[i]
            if c == 0x20 || c == 0x09 || c == 0x0D || (newlines && c == 0x0A) { i += 1; continue }
            if c == 0x23 { while i < b.count, b[i] != 0x0A { i += 1 }; continue }      // # comment
            break
        }
    }

    private mutating func skipLine() {
        while i < b.count, b[i] != 0x0A { i += 1 }
        if i < b.count { i += 1 }
    }

    private mutating func expect(_ c: UInt8) -> Bool {
        skipBlank(newlines: false)
        guard i < b.count, b[i] == c else { return false }
        i += 1
        return true
    }

    private mutating func header() -> LockTOMLSection? {
        let isArray = i + 1 < b.count && b[i + 1] == 0x5B
        i += isArray ? 2 : 1
        var parts: [String] = []
        while true {
            skipBlank(newlines: false)
            guard let part = keyPart() else { return nil }
            parts.append(part)
            skipBlank(newlines: false)
            guard i < b.count else { return nil }
            if b[i] == 0x2E { i += 1; continue }                         // .
            break
        }
        guard i < b.count, b[i] == 0x5D else { return nil }              // ]
        i += 1
        if isArray {
            guard i < b.count, b[i] == 0x5D else { return nil }
            i += 1
        }
        skipLine()
        return LockTOMLSection(header: parts.joined(separator: "."), isArray: isArray)
    }

    private mutating func key() -> String? {
        var parts: [String] = []
        while true {
            skipBlank(newlines: false)
            guard let part = keyPart() else { return nil }
            parts.append(part)
            skipBlank(newlines: false)
            if i < b.count, b[i] == 0x2E { i += 1; continue }
            return parts.joined(separator: ".")
        }
    }

    private mutating func keyPart() -> String? {
        guard i < b.count else { return nil }
        if b[i] == 0x22 { return basicString() }
        if b[i] == 0x27 { return literalString() }
        let start = i
        while i < b.count {
            let c = b[i]
            let bare = (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) || c == 0x2D || c == 0x5F
            if !bare { break }
            i += 1
        }
        return i > start ? String(decoding: b[start..<i], as: UTF8.self) : nil
    }

    // MARK: Values

    private mutating func value(depth: Int) -> LockTOML? {
        guard depth < Self.maxDepth else { return nil }
        skipBlank(newlines: false)
        guard i < b.count else { return nil }
        switch b[i] {
        case 0x22:
            if hasTriple(0x22) { return multiline(quote: 0x22).map(LockTOML.string) }
            return basicString().map(LockTOML.string)
        case 0x27:
            if hasTriple(0x27) { return multiline(quote: 0x27).map(LockTOML.string) }
            return literalString().map(LockTOML.string)
        case 0x5B: return array(depth: depth)
        case 0x7B: return inlineTable(depth: depth)
        default:
            let start = i
            while i < b.count, ![0x2C, 0x5D, 0x7D, 0x0A, 0x23].contains(b[i]) { i += 1 }
            let text = String(decoding: b[start..<i], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .other(text)
        }
    }

    private mutating func array(depth: Int) -> LockTOML? {
        i += 1
        var items: [LockTOML] = []
        while true {
            skipBlank(newlines: true)
            guard i < b.count else { return nil }
            if b[i] == 0x5D { i += 1; return .array(items) }
            if b[i] == 0x2C { i += 1; continue }
            guard let v = value(depth: depth + 1) else { return nil }
            items.append(v)
        }
    }

    /// Inline tables are single-line in TOML 1.0; newlines are tolerated here so a hand-edited file still reads.
    private mutating func inlineTable(depth: Int) -> LockTOML? {
        i += 1
        var table: [String: LockTOML] = [:]
        while true {
            skipBlank(newlines: true)
            guard i < b.count else { return nil }
            if b[i] == 0x7D { i += 1; return .table(table) }
            if b[i] == 0x2C { i += 1; continue }
            guard let k = key(), expect(0x3D), let v = value(depth: depth + 1) else { return nil }
            table[k] = v
        }
    }

    private func hasTriple(_ q: UInt8) -> Bool {
        i + 2 < b.count && b[i + 1] == q && b[i + 2] == q
    }

    private mutating func basicString() -> String? {
        i += 1
        var out: [UInt8] = []
        while i < b.count {
            let c = b[i]
            if c == 0x22 { i += 1; return String(decoding: out, as: UTF8.self) }
            if c == 0x0A { return nil }
            if c == 0x5C, i + 1 < b.count {
                let e = b[i + 1]
                i += 2
                switch e {
                case 0x6E: out.append(0x0A)
                case 0x74: out.append(0x09)
                case 0x72: out.append(0x0D)
                default: out.append(e)                                   // \" \\ and \u escapes kept loosely
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return nil
    }

    private mutating func literalString() -> String? {
        i += 1
        let start = i
        while i < b.count, b[i] != 0x27, b[i] != 0x0A { i += 1 }
        guard i < b.count, b[i] == 0x27 else { return nil }
        defer { i += 1 }
        return String(decoding: b[start..<i], as: UTF8.self)
    }

    private mutating func multiline(quote q: UInt8) -> String? {
        i += 3
        let start = i
        while i + 2 < b.count {
            if b[i] == q, b[i + 1] == q, b[i + 2] == q {
                let s = String(decoding: b[start..<i], as: UTF8.self)
                i += 3
                return s
            }
            i += (q == 0x22 && b[i] == 0x5C) ? 2 : 1
        }
        i = b.count
        return nil
    }
}
