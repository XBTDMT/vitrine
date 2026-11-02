import Foundation

/// Minified CSS and SQL laid out for reading (C-5, code design state 4): the file on disk is never touched, the
/// page says it was formatted and offers the original. JSON, XML and property lists are formatted by the structured
/// views. Strings, quoted names and comments are kept byte for byte. roadmap: S-5
public enum CodeFormatter {
    /// Formatting is offered when the file is a few very long lines.
    public static func isMinified(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty, text.utf8.count >= 200 else { return false }
        let longest = lines.map(\.utf8.count).max() ?? 0
        return lines.count <= 3 && longest >= 200 || longest >= 2_000 && text.utf8.count / lines.count >= 300
    }

    /// The formatted text, or nil when this language is not one Vitrine formats or the file is not minified.
    public static func format(_ text: String, language: String) -> String? {
        guard isMinified(text) else { return nil }
        switch language {
        case "css", "scss", "less": return css(text)
        case "sql": return sql(text)
        default: return nil
        }
    }

    // MARK: CSS

    public static func css(_ source: String) -> String {
        var out = ""
        var depth = 0
        var i = source.startIndex
        let pad = { String(repeating: "  ", count: depth) }
        var lineStart = true
        func emit(_ s: String) {
            if lineStart { out += pad(); lineStart = false }
            out += s
        }
        func newline() { while out.hasSuffix(" ") { out.removeLast() }; out += "\n"; lineStart = true }
        while i < source.endIndex {
            let c = source[i]
            if c == "\"" || c == "'" {
                let end = closing(source, from: i, quote: c)
                emit(String(source[i..<end])); i = end; continue
            }
            if c == "/", source.index(after: i) < source.endIndex, source[source.index(after: i)] == "*" {
                let end = source.range(of: "*/", range: source.index(i, offsetBy: 2)..<source.endIndex)?.upperBound ?? source.endIndex
                emit(String(source[i..<end])); newline(); i = end; continue
            }
            switch c {
            case "{":
                emit(lineStart ? "{" : (out.hasSuffix(" ") ? "{" : " {")); depth += 1; newline()
            case "}":
                if !lineStart { newline() }
                depth = max(0, depth - 1); emit("}"); newline()
                if depth == 0 { out += "\n" }
            case ";":
                emit(";"); newline()
            case ":" where depth > 0:
                emit(": ")
                // Skip the space that may follow.
                var j = source.index(after: i)
                while j < source.endIndex, source[j] == " " { j = source.index(after: j) }
                i = j; continue
            case "\n", "\r", "\t", " ":
                if !lineStart, !out.hasSuffix(" ") { out += " " }
            default:
                emit(String(c))
            }
            i = source.index(after: i)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: SQL

    /// Clause words that start a line at their depth; JOINs and set operators too.
    static let clauses: [[String]] = [
        ["select"], ["from"], ["where"], ["group", "by"], ["order", "by"], ["having"], ["limit"], ["offset"],
        ["union", "all"], ["union"], ["intersect"], ["except"], ["insert", "into"], ["values"], ["update"], ["set"],
        ["delete", "from"], ["left", "outer", "join"], ["right", "outer", "join"], ["full", "outer", "join"],
        ["left", "join"], ["right", "join"], ["inner", "join"], ["cross", "join"], ["full", "join"], ["join"],
        ["with"], ["returning"], ["on", "conflict"], ["create", "table"], ["create", "index"], ["create", "view"],
        ["alter", "table"], ["drop", "table"],
    ]

    public static func sql(_ source: String) -> String {
        let tokens = sqlTokens(source)
        var out = ""
        var depth = 0
        var clauseIndent = 0
        var inSelectList = false
        var parenStack: [Bool] = [] // whether each open paren holds a subquery
        func newline(_ indent: Int) {
            while out.hasSuffix(" ") { out.removeLast() }
            if !out.isEmpty { out += "\n" }
            out += String(repeating: "  ", count: max(0, indent))
        }
        var k = 0
        while k < tokens.count {
            let t = tokens[k]
            let lower = t.lowercased()
            // A clause word (one, two or three words) at the start of its line.
            if let clause = clauses.first(where: { words in
                words.indices.allSatisfy { k + $0 < tokens.count && tokens[k + $0].lowercased() == words[$0] }
            }) {
                newline(depth + clauseIndent)
                out += clause.indices.map { tokens[k + $0].uppercased() }.joined(separator: " ") + " "
                inSelectList = clause == ["select"]
                k += clause.count
                continue
            }
            switch t {
            case "(":
                let sub = k + 1 < tokens.count && ["select", "with"].contains(tokens[k + 1].lowercased())
                parenStack.append(sub)
                // A call hugs its parenthesis (COUNT(t.id)); IN (, VALUES (, AS ( keep the space.
                let previous = k > 0 ? tokens[k - 1].lowercased() : ""
                if let first = previous.first, first.isLetter || first == "_",
                   !["in", "values", "as", "on", "and", "or", "exists", "not", "from", "join", "where", "select", "into", "table", "using", "over"].contains(previous) {
                    while out.hasSuffix(" ") { out.removeLast() }
                }
                out += "("
                if sub { depth += 1 }
            case ")":
                if parenStack.popLast() == true { depth -= 1; newline(depth + clauseIndent) }
                while out.hasSuffix(" ") { out.removeLast() }
                out += ") "
            case ",":
                while out.hasSuffix(" ") { out.removeLast() }
                out += ","
                // A comma in the select list starts a line, unless it is inside a call's parentheses.
                if inSelectList && parenStack.allSatisfy({ $0 }) { newline(depth + clauseIndent + 1) } else { out += " " }
            case ";":
                while out.hasSuffix(" ") { out.removeLast() }
                out += ";\n"
                depth = 0; parenStack.removeAll(); inSelectList = false
            default:
                if lower == "and" || lower == "or", (parenStack.last ?? true) {
                    newline(depth + clauseIndent + 1)
                    out += t.uppercased() + " "
                } else if keywords.contains(lower) {
                    out += t.uppercased() + " "
                } else {
                    out += t + " "
                }
            }
            k += 1
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static let keywords: Set<String> = ["as", "on", "in", "is", "not", "null", "and", "or", "distinct", "case", "when", "then",
                                        "else", "end", "asc", "desc", "like", "between", "exists", "into", "by", "all", "primary",
                                        "key", "references", "default", "unique", "count", "sum", "avg", "min", "max", "coalesce"]

    /// Words, numbers, quoted strings and names, comments and single symbols; spaces dropped.
    static func sqlTokens(_ s: String) -> [String] {
        var out: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isWhitespace { i = s.index(after: i); continue }
            if c == "'" || c == "\"" || c == "`" {
                let end = closing(s, from: i, quote: c); out.append(String(s[i..<end])); i = end; continue
            }
            if c == "-", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "-" {
                let end = s[i...].firstIndex(of: "\n") ?? s.endIndex; out.append(String(s[i..<end])); i = end; continue
            }
            if c == "/", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "*" {
                let end = s.range(of: "*/", range: s.index(i, offsetBy: 2)..<s.endIndex)?.upperBound ?? s.endIndex
                out.append(String(s[i..<end])); i = end; continue
            }
            if c.isLetter || c.isNumber || c == "_" || c == "." || c == "$" || c == "@" || c == ":" {
                var j = i
                while j < s.endIndex, s[j].isLetter || s[j].isNumber || "_.$@:".contains(s[j]) { j = s.index(after: j) }
                out.append(String(s[i..<j])); i = j; continue
            }
            // Two-character operators.
            let two = String(s[i..<(s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex)])
            if ["<=", ">=", "<>", "!=", "||", "::"].contains(two) { out.append(two); i = s.index(i, offsetBy: 2); continue }
            out.append(String(c)); i = s.index(after: i)
        }
        return out
    }

    /// The index after the quote that closes the string opened at `from` (a doubled quote stays inside).
    static func closing(_ s: String, from: String.Index, quote: Character) -> String.Index {
        var j = s.index(after: from)
        while j < s.endIndex {
            if s[j] == "\\" { j = s.index(j, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex; continue }
            if s[j] == quote {
                let next = s.index(after: j)
                if next < s.endIndex, s[next] == quote { j = s.index(after: next); continue }
                return next
            }
            j = s.index(after: j)
        }
        return s.endIndex
    }
}
