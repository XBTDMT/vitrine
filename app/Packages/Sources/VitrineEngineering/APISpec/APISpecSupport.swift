import Foundation
import VitrineData

/// A read-only view of one node of a `StructuredTree` (VitrineData's JSON and YAML readers), with the key lookup
/// and scalar access the spec readers need. Nothing is copied: the tree's arrays are shared, and children are reached
/// through the tree's flat index without recursion. roadmap: S-22
struct SpecNode {
    let tree: StructuredTree
    let index: Int

    var node: StructuredNode { tree[index] }
    var kind: StructuredNodeKind { tree[index].kind }
    var isObject: Bool { kind == .object }
    var isArray: Bool { kind == .array }
    var isNull: Bool { kind == .null }
    /// The object key this node sits under.
    var name: String? { tree[index].name }
    /// Children kept in the tree.
    var count: Int { tree[index].childCount }
    /// Children the source holds, counted even past a limit.
    var sourceCount: Int { max(tree[index].sourceChildCount, tree[index].childCount) }

    subscript(key: String) -> SpecNode? {
        guard kind == .object else { return nil }
        for position in 0..<count {
            if let c = tree.child(position, of: index), tree[c].name == key { return SpecNode(tree: tree, index: c) }
        }
        return nil
    }

    /// The kept children in source order (members of an object, items of an array).
    var children: [SpecNode] {
        (0..<count).compactMap { tree.child($0, of: index).map { SpecNode(tree: tree, index: $0) } }
    }

    /// A scalar as display text (numbers exactly as written); nil for containers and null.
    var scalar: String? {
        switch kind {
        case .object, .array, .null: return nil
        default: return tree[index].preview
        }
    }

    var string: String? { kind == .string ? tree[index].preview : nil }
    var bool: Bool? { kind == .bool ? tree[index].preview.lowercased() == "true" : nil }
    var isTrue: Bool { bool == true }
    /// The strings of an array of strings (other items skipped), or a lone string as one element.
    var strings: [String] {
        if let s = string { return [s] }
        guard isArray else { return [] }
        return children.compactMap(\.scalar)
    }

    /// A short JSON-like rendering of a value for defaults and enum values: scalars as written (strings quoted when
    /// `quoteStrings`), containers as `[…]` / `{…}` (or `[]` / `{}` when empty).
    func displayValue(quoteStrings: Bool = true) -> String {
        switch kind {
        case .object: return count == 0 ? "{}" : "{…}"
        case .array: return count == 0 ? "[]" : "[…]"
        case .null: return "null"
        case .string:
            let s = SpecText.oneLine(tree[index].preview, limit: 120)
            return quoteStrings ? "\"\(s)\"" : s
        default: return tree[index].preview
        }
    }
}

/// Parses JSON or YAML bytes with VitrineData's structured readers and hands back the first document's root, or
/// nil when nothing readable came out. roadmap: S-22
enum SpecDocument {
    struct Parsed {
        let root: SpecNode
        /// The reader stopped before the end (syntax error, node limit, cut input).
        let partial: Bool
        /// The first syntax error, as "line N: reason".
        let syntaxError: String?
    }

    static func parse(_ data: Data, format: StructuredFormat, inputCut: Bool) -> Parsed? {
        var options = StructuredOptions()
        options.maxInputBytes = Int64(APISpecReader.maxBytes)
        options.maxPreviewBytes = 4096
        options.maxDepth = 256
        options.maxDiagnostics = 8
        let result = StructuredParser.parse(data, format: format, options: options,
                                            fileSize: inputCut ? Int64(data.count) + 1 : nil)
        guard let first = result.tree.roots.first else { return nil }
        let root = SpecNode(tree: result.tree, index: first)
        let error = result.error.map { e in e.location.map { "line \($0.line): \(e.reason)" } ?? e.reason }
        return Parsed(root: root, partial: !result.coverage.isComplete || inputCut, syntaxError: error)
    }
}

/// Text helpers shared by the readers. roadmap: S-22
enum SpecText {
    /// Trimmed, cut to `limit` characters with an ellipsis; nil when empty.
    static func cap(_ text: String?, _ limit: Int) -> String? {
        guard var s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.utf8.count > limit, s.count > limit {
            s = String(s.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return s
    }

    /// One line: runs of whitespace (newlines included) become one space; cut to `limit` characters.
    static func oneLine(_ text: String?, limit: Int = APISpecReader.maxTextLength) -> String {
        guard let text else { return "" }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return cap(collapsed, limit) ?? ""
    }

    static func oneLineOrNil(_ text: String?, limit: Int = APISpecReader.maxTextLength) -> String? {
        let s = oneLine(text, limit: limit)
        return s.isEmpty ? nil : s
    }

    /// "a, b, c and 3 more" for a warning's examples.
    static func examples(_ items: [String], max: Int = 3) -> String {
        let shown = items.prefix(max).joined(separator: ", ")
        return items.count > max ? L.more(shown, items.count - max) : shown
    }
}

/// Appends while under `APISpecReader.maxListItems`, else sets `truncated`. roadmap: S-22
func appendCapped<T>(_ list: inout [T], _ item: T, _ truncated: inout Bool) {
    if list.count < APISpecReader.maxListItems { list.append(item) } else { truncated = true }
}

/// Collects warnings, at most `APISpecReader.maxWarnings`, dropping exact repeats. roadmap: S-22
struct SpecWarnings {
    private(set) var list: [APISpecWarning] = []

    mutating func add(_ level: APISpecWarning.Level, _ reason: String) {
        let w = APISpecWarning(level, reason)
        guard list.count < APISpecReader.maxWarnings, !list.contains(w) else { return }
        list.append(w)
    }
}

// MARK: - A lexer for the C-like formats (Protocol Buffers, Avro IDL)

/// One token of a `.proto` or `.avdl` file. roadmap: S-22
struct CToken: Equatable {
    enum Kind: Equatable { case ident, number, string, symbol, eof }
    var kind: Kind
    var text: String
    var line: Int
    /// The `/** … */` comment right before this token (Avro IDL docs).
    var doc: String?

    func isSymbol(_ s: String) -> Bool { kind == .symbol && text == s }
    func isIdent(_ s: String) -> Bool { kind == .ident && text == s }
}

/// A pull lexer over bytes: identifiers (dots allowed inside and in front, for qualified names; a dash too right
/// after `@`, for Avro annotations like `@java-class`; backquoted identifiers), numbers, single- or double-quoted
/// strings with the usual escapes, `//` and `/* */` comments, and every other byte as a one-character symbol.
/// It never fails: an unterminated string or comment ends at the end of input. roadmap: S-22
struct CLexer {
    private let b: [UInt8]
    private var i = 0
    private(set) var line = 1
    private var afterAt = false
    /// The input ended inside a string or comment.
    private(set) var endedInside = false

    init(_ bytes: [UInt8]) {
        b = bytes
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
    }

    private static func isIdentStart(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isIdentChar(_ c: UInt8) -> Bool { isIdentStart(c) || isDigit(c) }

    mutating func next() -> CToken {
        var doc: String?
        // Whitespace and comments.
        while i < b.count {
            let c = b[i]
            if c == 0x0A { line += 1; i += 1; continue }
            if c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0C || c == 0x0B { i += 1; continue }
            if c == 0x2F, i + 1 < b.count, b[i + 1] == 0x2F {
                while i < b.count, b[i] != 0x0A { i += 1 }
                continue
            }
            if c == 0x2F, i + 1 < b.count, b[i + 1] == 0x2A {
                let isDoc = i + 2 < b.count && b[i + 2] == 0x2A && !(i + 3 < b.count && b[i + 3] == 0x2F)
                let start = i + (isDoc ? 3 : 2)
                i += 2
                while i + 1 < b.count, !(b[i] == 0x2A && b[i + 1] == 0x2F) {
                    if b[i] == 0x0A { line += 1 }
                    i += 1
                }
                if i + 1 >= b.count { endedInside = true; i = b.count; break }
                if isDoc { doc = CLexer.cleanDoc(Array(b[start..<max(start, i)])) }
                i += 2
                continue
            }
            break
        }
        guard i < b.count else { return CToken(kind: .eof, text: "", line: line, doc: doc) }
        let c = b[i]
        let startLine = line
        let wasAfterAt = afterAt
        afterAt = false

        if CLexer.isIdentStart(c) || (c == 0x2E && i + 1 < b.count && CLexer.isIdentStart(b[i + 1])) {
            let start = i
            i += 1
            while i < b.count {
                let d = b[i]
                if CLexer.isIdentChar(d) { i += 1; continue }
                if d == 0x2E, i + 1 < b.count, CLexer.isIdentStart(b[i + 1]) { i += 1; continue }
                if d == 0x2D, wasAfterAt, i + 1 < b.count, CLexer.isIdentChar(b[i + 1]) { i += 1; continue }
                break
            }
            return CToken(kind: .ident, text: String(decoding: b[start..<i], as: UTF8.self), line: startLine, doc: doc)
        }
        if c == 0x60 {                                           // `backquoted identifier`
            let start = i + 1
            i += 1
            while i < b.count, b[i] != 0x60, b[i] != 0x0A { i += 1 }
            let text = String(decoding: b[start..<i], as: UTF8.self)
            if i < b.count, b[i] == 0x60 { i += 1 }
            return CToken(kind: .ident, text: text, line: startLine, doc: doc)
        }
        if CLexer.isDigit(c) || ((c == 0x2D || c == 0x2B || c == 0x2E) && i + 1 < b.count && CLexer.isDigit(b[i + 1])) {
            let start = i
            i += 1
            let hex = c == 0x30 && i < b.count && (b[i] == 0x78 || b[i] == 0x58)
            while i < b.count {
                let d = b[i]
                if CLexer.isIdentChar(d) || d == 0x2E { i += 1; continue }
                if (d == 0x2B || d == 0x2D), !hex, b[i - 1] == 0x65 || b[i - 1] == 0x45 { i += 1; continue }
                break
            }
            return CToken(kind: .number, text: String(decoding: b[start..<i], as: UTF8.self), line: startLine, doc: doc)
        }
        if c == 0x22 || c == 0x27 {
            i += 1
            var out: [UInt8] = []
            var closed = false
            while i < b.count {
                let d = b[i]
                if d == c { i += 1; closed = true; break }
                if d == 0x0A { break }                               // strings do not span lines
                if d == 0x5C, i + 1 < b.count {
                    let e = b[i + 1]
                    i += 2
                    switch e {
                    case 0x6E: out.append(0x0A)
                    case 0x74: out.append(0x09)
                    case 0x72: out.append(0x0D)
                    default: out.append(e)
                    }
                    continue
                }
                if out.count < 65_536 { out.append(d) }
                i += 1
            }
            if !closed { endedInside = i >= b.count }
            return CToken(kind: .string, text: String(decoding: out, as: UTF8.self), line: startLine, doc: doc)
        }
        i += 1
        if c == 0x40 { afterAt = true }
        if c >= 0x80 {                                              // a stray UTF-8 sequence: one symbol
            while i < b.count, b[i] & 0xC0 == 0x80 { i += 1 }
            return CToken(kind: .symbol, text: "?", line: startLine, doc: doc)
        }
        return CToken(kind: .symbol, text: String(UnicodeScalar(c)), line: startLine, doc: doc)
    }

    /// A `/** … */` body without the leading `*` of each line.
    static func cleanDoc(_ bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("*") { s.removeFirst() }
            return s.trimmingCharacters(in: .whitespaces)
        }
        return SpecText.oneLineOrNil(lines.joined(separator: " "))
    }
}

/// A token stream with one token of lookahead over `CLexer`, and the recovery moves the parsers share.
/// roadmap: S-22
struct CTokens {
    private var lexer: CLexer
    private(set) var tok: CToken
    private(set) var ahead: CToken

    init(_ bytes: [UInt8]) {
        lexer = CLexer(bytes)
        tok = lexer.next()
        ahead = lexer.next()
    }

    var atEnd: Bool { tok.kind == .eof }
    var endedInside: Bool { lexer.endedInside }

    mutating func advance() {
        tok = ahead
        ahead = ahead.kind == .eof ? ahead : lexer.next()
    }

    /// Consumes the symbol when it is next.
    @discardableResult
    mutating func accept(_ symbol: String) -> Bool {
        guard tok.isSymbol(symbol) else { return false }
        advance()
        return true
    }

    @discardableResult
    mutating func acceptIdent(_ word: String) -> Bool {
        guard tok.isIdent(word) else { return false }
        advance()
        return true
    }

    /// The next identifier, consumed; nil (nothing consumed) when the next token is not one.
    mutating func ident() -> String? {
        guard tok.kind == .ident else { return nil }
        let t = tok.text
        advance()
        return t
    }

    /// Skips one balanced `open … close` group starting at the current token (which must be `open`). Iterative, so
    /// any nesting is safe. Returns false when the input ended first.
    @discardableResult
    mutating func skipGroup(_ open: String, _ close: String) -> Bool {
        guard tok.isSymbol(open) else { return true }
        var depth = 0
        while !atEnd {
            if tok.isSymbol(open) { depth += 1 } else if tok.isSymbol(close) { depth -= 1 }
            advance()
            if depth == 0 { return true }
        }
        return false
    }

    /// Skips to the end of the current statement: past the next `;` at this level, past a `{ … }` block that ends
    /// it, or up to (not past) a `}` that closes the enclosing block. Always moves at least one token unless at a
    /// closing brace or the end.
    mutating func skipStatement() {
        var depth = 0
        while !atEnd {
            if depth == 0, tok.isSymbol("}") { return }
            if tok.isSymbol("{") || tok.isSymbol("(") || tok.isSymbol("[") || tok.isSymbol("<") { depth += 1 }
            else if tok.isSymbol("}") || tok.isSymbol(")") || tok.isSymbol("]") || tok.isSymbol(">") {
                depth = max(0, depth - 1)
                if depth == 0, tok.isSymbol("}") { advance(); return }
            } else if depth == 0, tok.isSymbol(";") { advance(); return }
            advance()
        }
    }
}
