import Foundation

/// A small line lexer for Finder thumbnails (S-18): enough to colour code the way the code view does (keywords,
/// types, strings, numbers, comments, keys, tags), with no web view and no grammar files. A block comment or a string
/// that spans lines carries over. It reads at most the lines a thumbnail can show. roadmap: S-18
public struct CodeLexer: Sendable {
    public enum Token: Sendable, Equatable {
        case plain, keyword, type, function, string, number, comment, key, tag, attribute, punctuation, constant
    }

    public struct Run: Sendable, Equatable {
        public var text: String
        public var token: Token
        public init(_ text: String, _ token: Token) { self.text = text; self.token = token }
    }

    /// How a language writes its comments, strings and keys.
    public struct Syntax: Sendable {
        var lineComments: [String] = []
        var blockComments: [(open: String, close: String)] = []
        var quotes: [Character] = ["\"", "'"]
        var keywords: Set<String> = []
        /// Configuration: `name:` or `name =` at the start of a line is a key, the rest a value.
        var keyed = false
        /// Markup: `<tag attr="v">`.
        var markup = false
        /// Words that begin with a capital are types (C-like languages).
        var capitalTypes = true
    }

    let syntax: Syntax
    private var openBlock: String?

    public init(language: String) { syntax = Self.syntax(for: language.lowercased()) }

    /// Each line's runs, in order; tabs become four spaces.
    public mutating func lex(_ lines: [String]) -> [[Run]] { lines.map { lex(line: $0.replacingOccurrences(of: "\t", with: "    ")) } }

    mutating func lex(line: String) -> [Run] {
        if syntax.markup { return lexMarkup(line) }
        var runs: [Run] = []
        let chars = Array(line)
        var i = 0
        func push(_ s: String, _ t: Token) {
            guard !s.isEmpty else { return }
            if let last = runs.last, last.token == t { runs[runs.count - 1].text += s } else { runs.append(Run(s, t)) }
        }
        func starts(_ s: String, at k: Int) -> Bool {
            let p = Array(s); return k + p.count <= chars.count && Array(chars[k..<(k + p.count)]) == p
        }
        // A block comment carried from the line before.
        if let close = openBlock {
            if let end = find(close, in: chars, from: 0) {
                push(String(chars[0..<end + close.count]), .comment); i = end + close.count; openBlock = nil
            } else { return [Run(line, .comment)] }
        }
        // A key at the start of a configuration line.
        if syntax.keyed, i == 0, let key = Self.keyEnd(chars) {
            push(String(chars[0..<key]), .key); i = key
        }
        while i < chars.count {
            let c = chars[i]
            if let lc = syntax.lineComments.first(where: { starts($0, at: i) }), lc != "#" || i == 0 || chars[i - 1] == " " || chars[i - 1] == "\t" {
                push(String(chars[i...]), .comment); break
            }
            if let block = syntax.blockComments.first(where: { starts($0.open, at: i) }) {
                if let end = find(block.close, in: chars, from: i + block.open.count) {
                    push(String(chars[i..<end + block.close.count]), .comment); i = end + block.close.count; continue
                }
                push(String(chars[i...]), .comment); openBlock = block.close; break
            }
            if syntax.quotes.contains(c) {
                var j = i + 1
                while j < chars.count, chars[j] != c { j += chars[j] == "\\" ? 2 : 1 }
                j = min(j + 1, chars.count)
                // In JSON a string followed by a colon is a key.
                var k = j
                while k < chars.count, chars[k] == " " { k += 1 }
                let isKey = syntax.keyed && syntax.quotes == ["\""] && k < chars.count && chars[k] == ":"
                push(String(chars[i..<j]), isKey ? .key : .string); i = j; continue
            }
            if c.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i
                while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "x" || chars[j] == "_" { j += 1 }
                push(String(chars[i..<j]), .number); i = j; continue
            }
            if c.isLetter || c == "_" || c == "@" || c == "$" || c == "#" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "-" && syntax.keyed { j += 1 }
                let word = String(chars[i..<j])
                let token: Token
                if syntax.keywords.contains(word) { token = ["true", "false", "nil", "null", "none", "None", "True", "False", "yes", "no"].contains(word) ? .constant : .keyword }
                else if j < chars.count, chars[j] == "(" { token = .function }
                else if syntax.capitalTypes, word.first?.isUppercase == true { token = .type }
                else { token = .plain }
                push(word, token); i = j; continue
            }
            push(String(c), c.isPunctuation || c.isSymbol ? .punctuation : .plain)
            i += 1
        }
        return runs
    }

    func lexMarkup(_ line: String) -> [Run] {
        var runs: [Run] = []
        let chars = Array(line); var i = 0
        func push(_ s: String, _ t: Token) { if !s.isEmpty { runs.append(Run(s, t)) } }
        while i < chars.count {
            if chars[i] == "<" {
                var j = i + 1
                while j < chars.count, chars[j] != ">" && chars[j] != " " { j += 1 }
                push(String(chars[i..<j]), .tag); i = j
                while i < chars.count, chars[i] != ">" {
                    if chars[i] == "\"" || chars[i] == "'" {
                        let q = chars[i]; var k = i + 1
                        while k < chars.count, chars[k] != q { k += 1 }
                        k = min(k + 1, chars.count); push(String(chars[i..<k]), .string); i = k
                    } else if chars[i].isLetter {
                        var k = i
                        while k < chars.count, chars[k].isLetter || chars[k] == "-" || chars[k] == ":" { k += 1 }
                        push(String(chars[i..<k]), .attribute); i = k
                    } else { push(String(chars[i]), .punctuation); i += 1 }
                }
                if i < chars.count { push(">", .tag); i += 1 }
            } else {
                var j = i
                while j < chars.count, chars[j] != "<" { j += 1 }
                push(String(chars[i..<j]), .plain); i = j
            }
        }
        return runs
    }

    func find(_ s: String, in chars: [Character], from: Int) -> Int? {
        let p = Array(s)
        guard p.count <= chars.count else { return nil }
        var k = from
        while k + p.count <= chars.count { if Array(chars[k..<(k + p.count)]) == p { return k }; k += 1 }
        return nil
    }

    /// `  name:` / `name =` / `"name":` / `export NAME=`: the end of the key, including its indentation.
    static func keyEnd(_ chars: [Character]) -> Int? {
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "-" { i += 1 }
        if i + 7 <= chars.count, String(chars[i..<(i + 7)]) == "export " { i += 7 }
        let start = i
        if i < chars.count, chars[i] == "\"" {
            i += 1; while i < chars.count, chars[i] != "\"" { i += 1 }; i += 1
        } else {
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || "_.-[]".contains(chars[i]) { i += 1 }
        }
        guard i > start, i <= chars.count else { return nil }
        var j = i
        while j < chars.count, chars[j] == " " { j += 1 }
        guard j < chars.count, chars[j] == ":" || chars[j] == "=" else { return nil }
        return i
    }

    // MARK: Languages

    static let cKeywords: Set<String> = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto",
        "struct", "enum", "union", "typedef", "static", "const", "extern", "void", "int", "char", "long", "short", "unsigned", "signed",
        "float", "double", "bool", "true", "false", "sizeof", "inline", "volatile", "auto", "register", "NULL", "nullptr"]
    static let familyKeywords: [String: Set<String>] = [
        "swift": ["import", "let", "var", "func", "class", "struct", "enum", "protocol", "extension", "actor", "init", "deinit", "self", "Self",
                  "if", "else", "guard", "switch", "case", "default", "for", "in", "while", "repeat", "return", "throw", "throws", "try",
                  "await", "async", "private", "fileprivate", "internal", "public", "open", "static", "final", "override", "mutating",
                  "some", "any", "where", "true", "false", "nil", "defer", "do", "catch", "break", "continue", "typealias", "lazy", "weak"],
        "go": ["package", "import", "func", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "if", "else",
               "for", "range", "switch", "case", "default", "return", "break", "continue", "select", "true", "false", "nil"],
        "rust": ["fn", "let", "mut", "pub", "use", "mod", "struct", "enum", "impl", "trait", "for", "in", "if", "else", "match", "loop",
                 "while", "return", "self", "Self", "crate", "super", "async", "await", "move", "ref", "where", "true", "false", "const", "static", "unsafe", "dyn"],
        "java": ["package", "import", "class", "interface", "enum", "extends", "implements", "public", "private", "protected", "static",
                 "final", "abstract", "void", "new", "return", "if", "else", "for", "while", "switch", "case", "default", "try", "catch",
                 "finally", "throw", "throws", "this", "super", "true", "false", "null", "int", "long", "boolean", "var", "record"],
        "kotlin": ["package", "import", "class", "object", "interface", "fun", "val", "var", "if", "else", "when", "for", "while", "return",
                   "private", "public", "internal", "override", "data", "sealed", "suspend", "true", "false", "null", "this", "in", "is"],
        "javascript": ["import", "export", "from", "default", "const", "let", "var", "function", "class", "extends", "return", "if", "else",
                       "for", "while", "of", "in", "new", "this", "async", "await", "try", "catch", "throw", "true", "false", "null",
                       "undefined", "typeof", "interface", "type", "enum", "implements", "public", "private", "readonly", "as"],
        "python": ["import", "from", "as", "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is",
                   "with", "try", "except", "finally", "raise", "lambda", "yield", "async", "await", "pass", "None", "True", "False", "self"],
        "ruby": ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "do", "return", "require", "self", "nil",
                 "true", "false", "yield", "begin", "rescue", "attr_reader", "attr_accessor", "private"],
        "shell": ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export",
                  "local", "echo", "set", "unset", "source", "exit", "sudo", "curl", "cd"],
        "sql": ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table",
                "index", "view", "primary", "key", "references", "join", "left", "inner", "on", "group", "by", "order", "limit", "as",
                "integer", "text", "real", "null", "SELECT", "FROM", "WHERE", "AND", "OR", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                "DELETE", "CREATE", "TABLE", "INDEX", "PRIMARY", "KEY", "JOIN", "ON", "GROUP", "BY", "ORDER", "LIMIT", "AS", "INTEGER", "TEXT", "NULL"],
        "lua": ["local", "function", "end", "if", "then", "else", "elseif", "for", "in", "do", "while", "return", "nil", "true", "false", "and", "or", "not"],
        "haskell": ["module", "import", "where", "data", "type", "class", "instance", "let", "in", "case", "of", "if", "then", "else", "do"],
        "php": ["function", "class", "public", "private", "protected", "return", "if", "else", "foreach", "as", "echo", "new", "namespace", "use", "true", "false", "null"],
        "elixir": ["def", "defp", "defmodule", "do", "end", "fn", "if", "else", "case", "cond", "when", "true", "false", "nil", "import", "alias"],
        "config": ["true", "false", "null", "yes", "no", "on", "off"],
    ]

    static func syntax(for language: String) -> Syntax {
        var s = Syntax()
        let cStyle = { (keywords: Set<String>) -> Syntax in
            var x = Syntax(); x.lineComments = ["//"]; x.blockComments = [("/*", "*/")]; x.keywords = keywords; return x
        }
        switch language {
        case "swift": s = cStyle(familyKeywords["swift"]!); s.quotes = ["\""]
        case "go": s = cStyle(familyKeywords["go"]!); s.quotes = ["\"", "'", "`"]
        case "rust": s = cStyle(familyKeywords["rust"]!); s.quotes = ["\""]
        case "java", "groovy", "scala", "dart", "csharp", "c#": s = cStyle(familyKeywords["java"]!)
        case "kotlin": s = cStyle(familyKeywords["kotlin"]!)
        case "javascript", "typescript", "jsx", "tsx", "vue": s = cStyle(familyKeywords["javascript"]!); s.quotes = ["\"", "'", "`"]
        case "c", "cpp", "c++", "objective-c", "objective-cpp", "zig", "proto", "verilog": s = cStyle(cKeywords.union(["class", "public", "private", "template", "namespace", "using", "@interface", "@implementation", "@end", "#include", "#import", "#define"]))
        case "php": s = cStyle(familyKeywords["php"]!); s.lineComments = ["//", "#"]
        case "css", "less", "scss", "sass": s = cStyle([]); s.keyed = true; s.capitalTypes = false
        case "python": s.lineComments = ["#"]; s.keywords = familyKeywords["python"]!
        case "ruby", "perl", "r": s.lineComments = ["#"]; s.keywords = familyKeywords["ruby"]!
        case "elixir": s.lineComments = ["#"]; s.keywords = familyKeywords["elixir"]!
        case "shell", "bash", "zsh", "fish", "powershell", "makefile", "dockerfile", "cmake":
            s.lineComments = ["#"]; s.keywords = familyKeywords["shell"]!; s.capitalTypes = false
        case "yaml", "toml", "ini", "properties", "dotenv", "conf", "hcl", "terraform", "nix":
            s.lineComments = ["#", ";"]; s.keyed = true; s.keywords = familyKeywords["config"]!; s.capitalTypes = false
        case "json", "jsonc", "json5", "jsonl", "json lines":
            s.lineComments = ["//"]; s.quotes = ["\""]; s.keywords = ["true", "false", "null"]; s.keyed = true; s.capitalTypes = false
        case "sql": s.lineComments = ["--"]; s.blockComments = [("/*", "*/")]; s.keywords = familyKeywords["sql"]!; s.capitalTypes = false
        case "lua": s.lineComments = ["--"]; s.keywords = familyKeywords["lua"]!
        case "haskell": s.lineComments = ["--"]; s.blockComments = [("{-", "-}")]; s.keywords = familyKeywords["haskell"]!
        case "lisp", "clojure", "asm": s.lineComments = [";"]; s.capitalTypes = false
        case "latex", "erlang": s.lineComments = ["%"]; s.quotes = []; s.capitalTypes = false
        case "ocaml", "fsharp": s.blockComments = [("(*", "*)")]; s.keywords = ["let", "in", "match", "with", "fun", "type", "module", "open", "if", "then", "else"]
        case "applescript": s.lineComments = ["--", "#"]; s.blockComments = [("(*", "*)")]; s.keywords = ["tell", "end", "set", "to", "on", "if", "then", "else", "return", "repeat", "application"]
        case "xml", "plist", "html", "svg": s.markup = true
        default: s.quotes = []; s.capitalTypes = false
        }
        return s
    }
}
