import Foundation
import VitrineSupport

/// A marimo notebook read from its Python text (A-8): marimo saves a notebook as a `.py` file (`import marimo`,
/// `app = marimo.App(…)`, each cell an `@app.cell` function, Markdown cells as `mo.md(r"""…""")`). This reader only
/// reads the text, with a small Python lexer that knows strings, comments and brackets; nothing in the file is ever
/// run or imported. marimo stores no outputs, so a cell is its code (or its Markdown) as written. roadmap: S-21
public enum MarimoReader {
    public enum CellKind: String, Sendable, Equatable { case code, markdown }

    /// How the file declares the cell: `@app.cell`, `@app.function`, `@app.class_definition`, `with app.setup:`, or
    /// `app._unparsable_cell(…)` (marimo's way of saving a cell whose code does not parse).
    public enum Origin: String, Sendable, Equatable { case cell, function, classDefinition, setup, unparsable }

    public struct Cell: Sendable, Equatable {
        public var kind: CellKind
        /// The function's name; `_` for an anonymous cell, `setup` for the setup cell.
        public var name: String
        /// The code as marimo's editor shows it: the function body dedented, without the closing `return` that only
        /// hands names on to other cells. For a function or class cell, the definition itself.
        public var code: String
        /// A Markdown cell's text, its indentation cleaned as `mo.md` cleans it.
        public var markdown: String?
        /// `hide_code=True`: marimo hides the code when the notebook runs as an app.
        public var hideCode: Bool
        public var origin: Origin

        public init(kind: CellKind, name: String, code: String, markdown: String? = nil, hideCode: Bool = false, origin: Origin = .cell) {
            self.kind = kind; self.name = name; self.code = code; self.markdown = markdown; self.hideCode = hideCode; self.origin = origin
        }

        /// A name the author gave (marimo names anonymous cells `_`).
        public var isNamed: Bool { !name.isEmpty && !name.allSatisfy { $0 == "_" } }
    }

    public struct Option: Sendable, Equatable {
        public var key: String
        public var value: String
    }

    public struct Notebook: Sendable, Equatable {
        public var cells: [Cell]
        public var totalCells: Int
        /// More cells than the limit; `cells` holds the first `maxCells`.
        public var cut: Bool
        /// `__generated_with`: the marimo version that wrote the file.
        public var version: String?
        /// `marimo.App(…)`'s keyword arguments in file order, string values unquoted.
        public var appOptions: [Option]

        public func option(_ key: String) -> String? { appOptions.first { $0.key == key }?.value }
        /// `width="medium"`, `"full"`, `"columns"` …
        public var width: String? { option("width") }
        public var title: String? { option("app_title").flatMap { $0.isEmpty ? nil : $0 } }
    }

    public struct Limits: Sendable, Equatable {
        public var maxInputBytes = 16 * 1024 * 1024
        public var maxCells = 5_000
        public init(maxInputBytes: Int = 16 * 1024 * 1024, maxCells: Int = 5_000) {
            self.maxInputBytes = maxInputBytes; self.maxCells = max(1, maxCells)
        }
        public static let standard = Limits()
    }

    /// Reads the notebook. Throws `CompareError` when the text is too large or is not a marimo notebook (the same
    /// markers `FileSniffer.looksLikeMarimo` asks for).
    public static func read(_ data: Data, limits: Limits = .standard) throws -> Notebook {
        guard data.count <= limits.maxInputBytes else {
            throw CompareError(.tooLarge, side: nil, reason: String(localized: "the notebook is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limits.maxInputBytes), countStyle: .file))", bundle: .module, comment: "A compare could not start: lower-case reason; the argument is a file size."))
        }
        guard FileSniffer.looksLikeMarimo(data) else {
            throw CompareError(.malformed, side: nil, reason: String(localized: "not a marimo notebook (no “import marimo” and “marimo.App(” at the top)", bundle: .module, comment: "Why a .py file is not drawn as a marimo notebook: lower-case reason; 'import marimo' and 'marimo.App(' are code and stay as they are."))
        }
        return read(String(decoding: data, as: UTF8.self), limits: limits)
    }

    /// Reads the notebook from text that is already known to be marimo's.
    public static func read(_ text: String, limits: Limits = .standard) -> Notebook {
        let source = Source(text)
        var cells: [Cell] = []
        var version: String?
        var options: [Option] = []
        var appName = "app"
        var decorators: [String] = []
        var k = 0
        let lines = source.lines
        while k < lines.count {
            let line = lines[k]
            guard line.logical, line.indent == 0, !line.isBlank, !line.isComment else { k += 1; continue }
            let statementEnd = source.statementEnd(k)
            let statement = source.text(k, statementEnd)
            let blockEnd = source.blockEnd(k)
            if statement.hasPrefix("@") {
                decorators.append(statement)
                k = statementEnd
                continue
            }
            defer { decorators.removeAll() }
            if let assigned = match(statement, #"^([A-Za-z_]\w*)\s*=\s*marimo\.App\s*\("#) {
                appName = assigned
                options = keywordArguments(statement)
            } else if statement.hasPrefix("__generated_with") {
                version = Literal.parse(statement.drop { $0 != "=" }.dropFirst().trimmingCharacters(in: .whitespaces))?.value
            } else if statement.hasPrefix("def ") || statement.hasPrefix("async def ") || statement.hasPrefix("class ") {
                let deco = decorators.first { $0.hasPrefix("@\(appName).") } ?? ""
                let kindWord = match(deco, #"^@[A-Za-z_]\w*\.(\w+)"#) ?? ""
                let hide = deco.range(of: #"\bhide_code\s*=\s*True\b"#, options: .regularExpression) != nil
                if kindWord == "cell" {
                    let name = match(statement, #"def\s+([A-Za-z_]\w*)"#) ?? "_"
                    let body = source.body(header: k, headerEnd: statementEnd, blockEnd: blockEnd)
                    cells.append(cell(name: name, body: body, hide: hide, origin: .cell))
                } else if kindWord == "function" || kindWord == "class_definition" {
                    let isClass = statement.hasPrefix("class ")
                    let name = match(statement, isClass ? #"class\s+([A-Za-z_]\w*)"# : #"def\s+([A-Za-z_]\w*)"#) ?? "_"
                    cells.append(Cell(kind: .code, name: name, code: trimBlankLines(source.text(k, blockEnd)), hideCode: hide,
                                      origin: kindWord == "function" ? .function : .classDefinition))
                }
            } else if statement.range(of: "^with\\s+\(appName)\\.setup\\b", options: .regularExpression) != nil {
                let hide = statement.range(of: #"\bhide_code\s*=\s*True\b"#, options: .regularExpression) != nil
                let body = source.body(header: k, headerEnd: statementEnd, blockEnd: blockEnd)
                cells.append(Cell(kind: .code, name: "setup", code: body, hideCode: hide, origin: .setup))
            } else if statement.hasPrefix("\(appName)._unparsable_cell(") {
                let open = statement.index(statement.startIndex, offsetBy: appName.count + "._unparsable_cell(".count)
                let code = Literal.parse(statement[open...].trimmingCharacters(in: .whitespacesAndNewlines))?.value ?? ""
                let name = keywordArguments(statement).first { $0.key == "name" }?.value ?? "_"
                cells.append(Cell(kind: .code, name: name, code: cleandoc(code), origin: .unparsable))
            }
            k = max(blockEnd, statementEnd)
        }
        let total = cells.count
        let cut = total > limits.maxCells
        return Notebook(cells: cut ? Array(cells.prefix(limits.maxCells)) : cells, totalCells: total, cut: cut, version: version,
                        appOptions: options)
    }

    /// An `@app.cell` body: a Markdown cell when it is only `mo.md(<string>)`, otherwise code.
    static func cell(name: String, body: String, hide: Bool, origin: Origin) -> Cell {
        if let markdown = markdownCall(body) {
            return Cell(kind: .markdown, name: name, code: body, markdown: markdown, hideCode: hide, origin: origin)
        }
        return Cell(kind: .code, name: name, code: body, hideCode: hide, origin: origin)
    }

    /// `mo.md(r"""…""")`, `mo.md("…")`, `mo.md(f"""…""")`, adjacent literals joined: the Markdown, cleaned as
    /// `mo.md` cleans it (`inspect.cleandoc`); nil when the cell is anything more than that one call.
    public static func markdownCall(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("mo.md(") else { return nil }
        // One array, walked by index: each literal is read where it starts, never by copying the rest of the cell.
        let chars = Array(trimmed.dropFirst(6))
        var i = 0
        func skipSpace() { while i < chars.count, chars[i].isWhitespace { i += 1 } }
        var text = ""
        var any = false
        while true {
            skipSpace()
            guard let literal = Literal.parse(chars, at: i) else { break }
            text += literal.value
            i += literal.length
            any = true
        }
        skipSpace()
        if i < chars.count, chars[i] == "," { i += 1; skipSpace() }
        guard any, i == chars.count - 1, chars[i] == ")" else { return nil }
        return cleandoc(text)
    }

    // MARK: Text helpers

    static func match(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// `name(a=1, b="x", c=[1, 2])` → [a: 1, b: x, c: [1, 2]]: the first call's keyword arguments, split at the
    /// commas outside strings and brackets; string values unquoted.
    static func keywordArguments(_ call: String) -> [Option] {
        guard let open = call.firstIndex(of: "(") else { return [] }
        let chars = Array(call[call.index(after: open)...])
        var parts: [String] = [], current = "", depth = 0, i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "'" {
                let n = Literal.parse(chars, at: i)?.length ?? 1
                current += String(chars[i..<min(chars.count, i + n)])
                i += n
                continue
            }
            if c == "(" || c == "[" || c == "{" { depth += 1 }
            if c == ")" || c == "]" || c == "}" {
                if depth == 0 { parts.append(current); current = ""; break }
                depth -= 1
            }
            if c == ",", depth == 0 { parts.append(current); current = "" } else { current.append(c) }
            i += 1
        }
        return parts.compactMap { part in
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = p.firstIndex(of: "="), let key = match(String(p[..<eq]).trimmingCharacters(in: .whitespaces), #"^([A-Za-z_]\w*)$"#) else { return nil }
            let raw = p[p.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let literal = Literal.parse(raw), literal.length == raw.count { return Option(key: key, value: literal.value) }
            return Option(key: key, value: raw)
        }
    }

    /// Python's `inspect.cleandoc`: tabs expanded, the first line's leading space dropped, the common indentation of
    /// the other lines removed, blank lines at either end removed.
    public static func cleandoc(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\t", with: "        ").components(separatedBy: "\n")
        let margin = lines.dropFirst().filter { !$0.allSatisfy(\.isWhitespace) }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        if !lines.isEmpty { lines[0] = String(lines[0].drop { $0 == " " }) }
        for i in lines.indices.dropFirst() { lines[i] = String(lines[i].dropFirst(min(margin, lines[i].prefix { $0 == " " }.count))) }
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func trimBlankLines(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Python string literals

    /// One Python string literal at the start of a text: prefix (r, f, u, rf …; never b), quotes (one or three),
    /// its value (escapes processed unless raw; an f-string's `{{` and `}}` read as braces, its fields kept as
    /// written) and how many characters it spans.
    struct Literal {
        var value: String
        var length: Int

        static func parse(_ text: String) -> Literal? { parse(Array(text), at: 0) }

        /// The literal starting at `chars[start]`; its `length` counts from `start`. Callers that walk a long text
        /// pass the whole array and an index, so reading many literals costs their own lengths, not the text's.
        static func parse(_ chars: [Character], at start: Int) -> Literal? {
            var i = start
            var raw = false, format = false
            while i < chars.count, i - start < 2, "rRfFuU".contains(chars[i]) {
                if "rR".contains(chars[i]) { raw = true }
                if "fF".contains(chars[i]) { format = true }
                i += 1
            }
            guard i < chars.count, chars[i] == "\"" || chars[i] == "'" else { return nil }
            let q = chars[i]
            let triple = i + 2 < chars.count && chars[i + 1] == q && chars[i + 2] == q
            i += triple ? 3 : 1
            var value = ""
            while i < chars.count {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count {
                    let n = chars[i + 1]
                    if raw { value.append(c); value.append(n) } else { value += escape(n) }
                    i += 2
                    continue
                }
                if triple {
                    if c == q, i + 2 < chars.count, chars[i + 1] == q, chars[i + 2] == q {
                        return Literal(value: format ? unbrace(value) : value, length: i + 3 - start)
                    }
                } else if c == q {
                    return Literal(value: format ? unbrace(value) : value, length: i + 1 - start)
                } else if c == "\n" {
                    return nil
                }
                value.append(c)
                i += 1
            }
            return nil
        }

        static func escape(_ n: Character) -> String {
            switch n {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            case "\\": return "\\"
            case "'": return "'"
            case "\"": return "\""
            case "\n": return ""
            default: return "\\" + String(n)
            }
        }

        static func unbrace(_ s: String) -> String { s.replacingOccurrences(of: "{{", with: "{").replacingOccurrences(of: "}}", with: "}") }
    }

    // MARK: Lines, with the lexer's state at each start

    /// The file as lines, each marked with whether it starts a logical line: not inside a string, brackets or a
    /// backslash continuation. Python's syntax characters are ASCII, so the lexer walks UTF-8 bytes.
    struct Source {
        struct Line {
            var text: String
            var logical: Bool
            /// Leading spaces and tabs.
            var indent: Int
            var isBlank: Bool
            var isComment: Bool
        }

        let lines: [Line]

        init(_ text: String) {
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let texts = normalized.components(separatedBy: "\n")
            var result: [Line] = []
            result.reserveCapacity(texts.count)
            var string: (quote: UInt8, triple: Bool)?
            var depth = 0
            var continued = false
            for (n, t) in texts.enumerated() {
                let bytes = Array(t.utf8)
                let startsClean = string == nil && depth == 0 && !continued
                let indent = bytes.prefix { $0 == 0x20 || $0 == 0x09 }.count
                let body = bytes.dropFirst(indent)
                let first = n == 0 && t.hasPrefix("\u{FEFF}") ? Array(t.utf8.dropFirst(3)).first : body.first
                result.append(Line(text: t, logical: startsClean, indent: n == 0 && t.hasPrefix("\u{FEFF}") ? 0 : indent,
                                   isBlank: body.isEmpty, isComment: startsClean && first == 0x23))
                continued = false
                var i = 0
                while i < bytes.count {
                    let b = bytes[i]
                    if let s = string {
                        if b == 0x5C { i += 2; continue }   // a backslash keeps the next character in the string, raw or not
                        if b == s.quote {
                            if !s.triple { string = nil } else if i + 2 < bytes.count, bytes[i + 1] == b, bytes[i + 2] == b { string = nil; i += 3; continue }
                        }
                        i += 1
                        continue
                    }
                    switch b {
                    case 0x23: i = bytes.count; continue          // # comment to the end of the line
                    case 0x22, 0x27:                               // " or '
                        if i + 2 < bytes.count, bytes[i + 1] == b, bytes[i + 2] == b { string = (b, true); i += 3; continue }
                        string = (b, false)
                    case 0x28, 0x5B, 0x7B: depth += 1              // ( [ {
                    case 0x29, 0x5D, 0x7D: depth = max(0, depth - 1)
                    case 0x5C where i == bytes.count - 1: continued = true
                    default: break
                    }
                    i += 1
                }
                // A one-quote string cannot run past its line (unless the line ends in a backslash inside it).
                if let s = string, !s.triple, bytes.last != 0x5C { string = nil }
            }
            lines = result
        }

        func text(_ from: Int, _ to: Int) -> String { lines[from..<min(to, lines.count)].map(\.text).joined(separator: "\n") }

        /// The line after the logical line that starts at `k` (its continuation lines included).
        func statementEnd(_ k: Int) -> Int {
            var j = k + 1
            while j < lines.count, !lines[j].logical { j += 1 }
            return j
        }

        /// The line after the block a top-level statement at `k` opens: up to the next line that starts a logical
        /// line at the left margin.
        func blockEnd(_ k: Int) -> Int {
            var j = statementEnd(k)
            while j < lines.count {
                let l = lines[j]
                if l.logical, !l.isBlank, l.indent == 0 { break }
                j += 1
            }
            return j
        }

        /// The body of a `def` or `with` block, dedented, without a closing `return` that only re-exports names.
        func body(header: Int, headerEnd: Int, blockEnd: Int) -> String {
            var body = Array(lines[headerEnd..<blockEnd])
            // A body on the header's own line (`def _(): return`), rare: kept after the colon.
            let headerText = text(header, headerEnd)
            if body.allSatisfy(\.isBlank), let after = Self.textAfterHeaderColon(headerText) {
                let inline = after.trimmingCharacters(in: .whitespaces)
                if !inline.isEmpty, !inline.hasPrefix("#") { body = [Line(text: inline, logical: true, indent: 0, isBlank: false, isComment: false)] }
            }
            while let last = body.last, last.isBlank || (last.logical && last.isComment && last.indent == 0) { body.removeLast() }
            let margin = body.filter { $0.logical && !$0.isBlank }.map(\.indent).min() ?? 0
            var out = body.map { line -> Line in
                var l = line
                let cut = min(margin, l.text.prefix { $0 == " " || $0 == "\t" }.count)
                l.text = String(l.text.dropFirst(cut))
                l.indent = max(0, l.indent - cut)
                return l
            }
            // The closing statement at the body's own margin: `return`, `return x,` or `return (a, b)` → dropped.
            if let s = out.lastIndex(where: { $0.logical && !$0.isBlank && !$0.isComment && $0.indent == 0 }) {
                let statement = out[s...].map(\.text).joined(separator: "\n")
                if Self.onlyReExports(statement) { out.removeSubrange(s...) }
            }
            return MarimoReader.trimBlankLines(out.map(\.text).joined(separator: "\n"))
        }

        /// What follows the colon that ends a `def` header: the last `)` followed by optional space, an optional
        /// `-> annotation` without a colon, then `:` (the pattern `\)\s*(->[^:]*)?:`, searched from the end). One
        /// backwards pass that remembers the nearest colon ahead, so a header of any length costs its length; the
        /// regular expression it replaces backtracked over the whole header for every `)` (F57).
        static func textAfterHeaderColon(_ header: String) -> String? {
            let scalars = Array(header.unicodeScalars)
            var nextColon: Int?
            var i = scalars.count - 1
            while i >= 0 {
                let c = scalars[i]
                if c == ":" {
                    nextColon = i
                } else if c == ")", let colon = nextColon {
                    // Only the space right after this `)` is walked; the next `)` to the left walks its own.
                    var q = i + 1
                    while q < colon, scalars[q].properties.isWhitespace { q += 1 }
                    if q == colon || (q + 1 < colon && scalars[q] == "-" && scalars[q + 1] == ">") {
                        var out = String.UnicodeScalarView()
                        out.append(contentsOf: scalars[(colon + 1)...])
                        return String(out)
                    }
                }
                i -= 1
            }
            return nil
        }

        static func onlyReExports(_ statement: String) -> Bool {
            let lines = statement.components(separatedBy: "\n").map { line -> String in
                line.firstIndex(of: "#").map { String(line[..<$0]) } ?? line
            }
            var s = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("return"), s.count == 6 || s.dropFirst(6).first.map({ $0 == " " || $0 == "(" }) == true else { return false }
            s = String(s.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("("), s.hasSuffix(")") { s = String(s.dropFirst().dropLast()) }
            return s.split(separator: ",", omittingEmptySubsequences: false).allSatisfy { part in
                let p = part.trimmingCharacters(in: .whitespaces)
                return p.isEmpty || p.range(of: #"^[A-Za-z_]\w*$"#, options: .regularExpression) != nil
            }
        }
    }
}

extension MarimoReader.Notebook {
    /// The notebook in the shape the notebook page draws (A-8): code cells as Python, Markdown cells as their text,
    /// no outputs (marimo stores none), the cell's name as its id when the author named it. roadmap: S-21
    public var notebookShape: NotebookReader.Notebook {
        let shaped = cells.map { cell in
            NotebookReader.Cell(kind: cell.kind == .markdown ? .markdown : .code, id: cell.isNamed ? cell.name : nil,
                                source: cell.kind == .markdown ? (cell.markdown ?? cell.code) : cell.code)
        }
        return NotebookReader.Notebook(cells: shaped, metadata: Data(), cut: cut, totalCells: totalCells, format: nil,
                                       kernelDisplayName: nil, kernelName: nil, language: "python", languageVersion: nil, title: title)
    }
}
