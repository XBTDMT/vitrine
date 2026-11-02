import Foundation

/// The jq 1.7 grammar, by recursive descent with precedence climbing. Lowest to highest: `|` (right), `,` (left),
/// `//` (right), the assignments `= |= += -= *= /= %= //=` (non-associative), `or`, `and`, the comparisons
/// (non-associative), `+ -`, `* / %`, unary minus, then postfix terms (`.foo`, `[e]`, `[a:b]`, `[]`, `?`, `as`).
/// `try` and `catch` take a postfix term each, as jq's precedence makes them. Nesting is bounded so a hostile program
/// cannot exhaust the stack. roadmap: S-5
struct JQParser {
    enum Token: Equatable {
        case eof
        case dot
        case dotdot
        case field(String)
        case ident(String)
        case keyword(String)
        case variable(String)
        case number(Double)
        case format(String)
        /// An opening `"`; the parser reads the string body itself (interpolations hold whole programs).
        case quote
        case op(String)
    }

    static let keywords: Set<String> = [
        "def", "if", "then", "elif", "else", "end", "as", "reduce", "foreach", "try", "catch", "label", "import",
        "include", "module", "and", "or", "__loc__",
    ]
    static let formats: Set<String> = ["text", "json", "csv", "tsv", "html", "uri", "sh", "base64", "base64d", "base32", "base32d"]
    static let maxNesting = 512

    let src: [UInt8]
    let builtin: Bool
    private var pos = 0
    private var lookahead: (token: Token, start: Int, end: Int)?
    private var nesting = 0
    /// Inside an object value, `,` separates entries rather than being an operator.
    private var noComma = false

    init(_ program: String, builtin: Bool) {
        src = Array(program.utf8)
        self.builtin = builtin
    }

    // MARK: Errors

    private func syntax(_ reason: String, at offset: Int) -> JQError {
        JQError.syntax(reason, at: offset, in: src)
    }

    private func unsupported(_ message: String, at offset: Int) -> JQError {
        JQError(.unsupported, message, offset: offset)
    }

    private func describe(_ token: Token) -> String {
        switch token {
        case .eof: "end of program"
        case .dot: "'.'"
        case .dotdot: "'..'"
        case .field(let name): "'.\(name)'"
        case .ident(let name): "'\(name)'"
        case .keyword(let name): "'\(name)'"
        case .variable(let name): "'$\(name)'"
        case .number: "a number"
        case .format(let name): "'@\(name)'"
        case .quote: "a string"
        case .op(let text): "'\(text)'"
        }
    }

    // MARK: Lexing

    private static func isIdentStart(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
    private static func isIdentPart(_ c: UInt8) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    private mutating func skipSpace() {
        while pos < src.count {
            let c = src[pos]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                pos += 1
            } else if c == UInt8(ascii: "#") {
                while pos < src.count, src[pos] != 0x0A { pos += 1 }
            } else {
                return
            }
        }
    }

    private mutating func readIdent() -> String {
        let start = pos
        while pos < src.count, Self.isIdentPart(src[pos]) { pos += 1 }
        return String(decoding: src[start..<pos], as: UTF8.self)
    }

    private mutating func readNumber() throws -> Double {
        let start = pos
        while pos < src.count, Self.isDigit(src[pos]) { pos += 1 }
        if pos < src.count, src[pos] == UInt8(ascii: ".") {
            pos += 1
            while pos < src.count, Self.isDigit(src[pos]) { pos += 1 }
        }
        if pos < src.count, src[pos] == UInt8(ascii: "e") || src[pos] == UInt8(ascii: "E") {
            var p = pos + 1
            if p < src.count, src[p] == UInt8(ascii: "+") || src[p] == UInt8(ascii: "-") { p += 1 }
            if p < src.count, Self.isDigit(src[p]) {
                pos = p
                while pos < src.count, Self.isDigit(src[pos]) { pos += 1 }
            }
        }
        var text = String(decoding: src[start..<pos], as: UTF8.self)
        if text.hasPrefix(".") { text = "0" + text }
        if text.hasSuffix(".") { text += "0" }
        guard let value = Double(text) else { throw syntax("invalid number '\(text)'", at: start) }
        return value
    }

    private mutating func lex() throws -> (Token, Int, Int) {
        skipSpace()
        let start = pos
        guard pos < src.count else { return (.eof, pos, pos) }
        let c = src[pos]
        let next: UInt8? = pos + 1 < src.count ? src[pos + 1] : nil
        switch c {
        case UInt8(ascii: "\""):
            pos += 1
            return (.quote, start, pos)
        case UInt8(ascii: "."):
            if next == UInt8(ascii: ".") { pos += 2; return (.dotdot, start, pos) }
            if let next, Self.isIdentStart(next) {
                pos += 1
                return (.field(readIdent()), start, pos)
            }
            if let next, Self.isDigit(next) { return (.number(try readNumber()), start, pos) }
            pos += 1
            return (.dot, start, pos)
        case UInt8(ascii: "$"):
            pos += 1
            guard pos < src.count, Self.isIdentStart(src[pos]) else { throw syntax("expected a variable name after '$'", at: start) }
            let name = readIdent()
            if pos + 1 < src.count, src[pos] == UInt8(ascii: ":"), src[pos + 1] == UInt8(ascii: ":") {
                throw unsupported("modules (`$\(name)::…`) are not supported in Vitrine", at: start)
            }
            return (.variable(name), start, pos)
        case UInt8(ascii: "@"):
            pos += 1
            guard pos < src.count, Self.isIdentStart(src[pos]) else { throw syntax("expected a format name after '@'", at: start) }
            return (.format(readIdent()), start, pos)
        default:
            break
        }
        if Self.isDigit(c) { return (.number(try readNumber()), start, pos) }
        if Self.isIdentStart(c) {
            let name = readIdent()
            if pos + 1 < src.count, src[pos] == UInt8(ascii: ":"), src[pos + 1] == UInt8(ascii: ":") {
                throw unsupported("modules (`\(name)::…`) are not supported in Vitrine", at: start)
            }
            return (Self.keywords.contains(name) ? .keyword(name) : .ident(name), start, pos)
        }
        for candidate in ["//=", "|=", "+=", "-=", "*=", "/=", "%=", "==", "!=", "<=", ">=", "//"] {
            let bytes = Array(candidate.utf8)
            if pos + bytes.count <= src.count, Array(src[pos..<(pos + bytes.count)]) == bytes {
                pos += bytes.count
                return (.op(candidate), start, pos)
            }
        }
        if "|,:;()[]{}?=<>+-*/%".utf8.contains(c) {
            pos += 1
            return (.op(String(Character(Unicode.Scalar(c)))), start, pos)
        }
        let scalar = String(decoding: src[pos..<min(src.count, pos + 4)], as: UTF8.self).unicodeScalars.first.map { String($0) } ?? "?"
        throw syntax("unexpected character '\(scalar)'", at: start)
    }

    private mutating func peek() throws -> Token {
        if lookahead == nil {
            let (token, start, end) = try lex()
            lookahead = (token, start, end)
        }
        return lookahead!.token
    }

    /// Offset of the next token.
    private mutating func here() throws -> Int {
        _ = try peek()
        return lookahead!.start
    }

    @discardableResult
    private mutating func next() throws -> Token {
        let token = try peek()
        lookahead = nil
        return token
    }

    private mutating func expect(_ token: Token, _ what: String) throws {
        let at = try here()
        let got = try next()
        guard got == token else { throw syntax("expected \(what), found \(describe(got))", at: at) }
    }

    private mutating func unexpected() throws -> JQError {
        let at = try here()
        return syntax("unexpected \(describe(try peek()))", at: at)
    }

    /// The raw byte right after the peeked token (for `."key"` and `.[` after a term).
    private mutating func byteAfterPeek() throws -> UInt8? {
        _ = try peek()
        let end = lookahead!.end
        return end < src.count ? src[end] : nil
    }

    // MARK: Program

    mutating func parseProgram() throws -> JQNode {
        if try peek() == .eof { return .identity }
        let node = try parsePipe(noComma: false)
        guard try peek() == .eof else { throw try unexpected() }
        return node
    }

    private mutating func parsePipe(noComma: Bool) throws -> JQNode {
        nesting += 1
        defer { nesting -= 1 }
        if nesting > Self.maxNesting {
            throw JQError(.limit, "the program nests more than \(Self.maxNesting) levels deep", offset: try here())
        }
        let saved = self.noComma
        self.noComma = noComma
        defer { self.noComma = saved }
        let lhs = try parseBinary(minLevel: 1)
        if try peek() == .op("|") {
            try next()
            let rhs = try parsePipe(noComma: noComma)
            return .pipe(lhs, rhs)
        }
        return lhs
    }

    private enum Assoc { case left, right, none }

    private func binaryInfo(_ token: Token) -> (level: Int, assoc: Assoc)? {
        switch token {
        case .op(","): return noComma ? nil : (1, .left)
        case .op("//"): return (2, .right)
        case .op("="), .op("|="), .op("+="), .op("-="), .op("*="), .op("/="), .op("%="), .op("//="): return (3, .none)
        case .keyword("or"): return (4, .left)
        case .keyword("and"): return (5, .left)
        case .op("=="), .op("!="), .op("<"), .op("<="), .op(">"), .op(">="): return (6, .none)
        case .op("+"), .op("-"): return (7, .left)
        case .op("*"), .op("/"), .op("%"): return (8, .left)
        default: return nil
        }
    }

    private func combine(_ token: Token, _ lhs: JQNode, _ rhs: JQNode) -> JQNode {
        switch token {
        case .op(","): return .comma(lhs, rhs)
        case .op("//"): return .alternative(lhs, rhs)
        case .op("="): return .assign(.set, lhs, rhs)
        case .op("|="): return .assign(.update, lhs, rhs)
        case .op("+="): return .assign(.arithmetic(.add), lhs, rhs)
        case .op("-="): return .assign(.arithmetic(.subtract), lhs, rhs)
        case .op("*="): return .assign(.arithmetic(.multiply), lhs, rhs)
        case .op("/="): return .assign(.arithmetic(.divide), lhs, rhs)
        case .op("%="): return .assign(.arithmetic(.modulo), lhs, rhs)
        case .op("//="): return .assign(.alternative, lhs, rhs)
        case .keyword("or"): return .or(lhs, rhs)
        case .keyword("and"): return .and(lhs, rhs)
        case .op(let text): return .binary(JQBinaryOp(rawValue: text)!, lhs, rhs)
        default: return lhs
        }
    }

    private mutating func parseBinary(minLevel: Int) throws -> JQNode {
        var lhs = try parseUnary()
        while let (level, assoc) = binaryInfo(try peek()), level >= minLevel {
            let opAt = try here()
            let op = try next()
            let rhs = try parseBinary(minLevel: assoc == .right ? level : level + 1)
            lhs = combine(op, lhs, rhs)
            if assoc == .none, let (again, _) = binaryInfo(try peek()), again == level {
                throw syntax("\(describe(op)) cannot be chained without parentheses", at: opAt)
            }
        }
        return lhs
    }

    private mutating func parseUnary() throws -> JQNode {
        if try peek() == .op("-") {
            try next()
            let operand = try parseBinary(minLevel: 8)
            if case .literal(.number(let d)) = operand { return .literal(.number(-d)) }
            return .negate(operand)
        }
        return try parsePostfix(allowAs: true)
    }

    private mutating func parsePostfix(allowAs: Bool) throws -> JQNode {
        var term = try parsePrimary()
        while true {
            switch try peek() {
            case .field(let name):
                try next()
                term = .index(term, .literal(.string(name)))
            case .dot:
                let after = try byteAfterPeek()
                if after == UInt8(ascii: "\"") {
                    try next()
                    try expect(.quote, "a string")
                    term = .index(term, try parseStringBody(format: nil))
                } else if after == UInt8(ascii: "[") {
                    try next()
                } else {
                    return term
                }
            case .op("["):
                try next()
                term = try parseBracketSuffix(term)
            case .op("?"):
                try next()
                term = .tryCatch(term, nil)
            case .keyword("as") where allowAs:
                try next()
                let pattern = try parsePatterns()
                try expect(.op("|"), "'|' after the binding")
                let body = try parsePipe(noComma: noComma)
                return .bind(term, pattern, body)
            default:
                return term
            }
        }
    }

    /// After `[`: `]`, `e]`, `e:]`, `:e]`, `e:e]`.
    private mutating func parseBracketSuffix(_ term: JQNode) throws -> JQNode {
        if try peek() == .op("]") {
            try next()
            return .iterate(term)
        }
        if try peek() == .op(":") {
            try next()
            let to = try parsePipe(noComma: false)
            try expect(.op("]"), "']'")
            return .slice(term, nil, to)
        }
        let key = try parsePipe(noComma: false)
        if try peek() == .op(":") {
            try next()
            if try peek() == .op("]") {
                try next()
                return .slice(term, key, nil)
            }
            let to = try parsePipe(noComma: false)
            try expect(.op("]"), "']'")
            return .slice(term, key, to)
        }
        try expect(.op("]"), "']'")
        return .index(term, key)
    }

    private mutating func parsePrimary() throws -> JQNode {
        let start = try here()
        let token = try next()
        switch token {
        case .dot:
            if try peek() == .quote, lookahead!.start == start + 1 {
                try next()
                return .index(.identity, try parseStringBody(format: nil))
            }
            return .identity
        case .dotdot:
            return .recurseAll
        case .field(let name):
            return .index(.identity, .literal(.string(name)))
        case .number(let d):
            return .literal(.number(d))
        case .quote:
            return try parseStringBody(format: nil)
        case .format(let name):
            guard Self.formats.contains(name) else { throw syntax("\(name) is not a valid format", at: start) }
            if try peek() == .quote {
                try next()
                return try parseStringBody(format: name)
            }
            return .format(name)
        case .op("("):
            let inner = try parsePipe(noComma: false)
            try expect(.op(")"), "')'")
            return inner
        case .op("["):
            if try peek() == .op("]") {
                try next()
                return .array(nil)
            }
            let inner = try parsePipe(noComma: false)
            try expect(.op("]"), "']'")
            return .array(inner)
        case .op("{"):
            return try parseObject()
        case .variable(let name):
            return .variable(name, start)
        case .keyword("if"):
            return try parseIfRest()
        case .keyword("try"):
            let body = try parseTryOperand()
            if try peek() == .keyword("catch") {
                try next()
                return .tryCatch(body, try parseTryOperand())
            }
            return .tryCatch(body, nil)
        case .keyword("reduce"):
            let source = try parsePostfix(allowAs: false)
            try expect(.keyword("as"), "'as'")
            let pattern = try parsePatterns()
            try expect(.op("("), "'('")
            let initial = try parsePipe(noComma: false)
            try expect(.op(";"), "';'")
            let update = try parsePipe(noComma: false)
            try expect(.op(")"), "')'")
            return .reduce(source, pattern, initial, update)
        case .keyword("foreach"):
            let source = try parsePostfix(allowAs: false)
            try expect(.keyword("as"), "'as'")
            let pattern = try parsePatterns()
            try expect(.op("("), "'('")
            let initial = try parsePipe(noComma: false)
            try expect(.op(";"), "';'")
            let update = try parsePipe(noComma: false)
            var extract: JQNode?
            if try peek() == .op(";") {
                try next()
                extract = try parsePipe(noComma: false)
            }
            try expect(.op(")"), "')'")
            return .foreach(source, pattern, initial, update, extract)
        case .keyword("def"):
            let definition = try parseDefinition()
            if try peek() == .eof { return .funcDef(definition, .identity) }
            return .funcDef(definition, try parsePipe(noComma: noComma))
        case .keyword("label"):
            let at = try here()
            guard case .variable(let name) = try next() else { throw syntax("expected '$name' after 'label'", at: at) }
            try expect(.op("|"), "'|' after the label")
            return .label(name, try parsePipe(noComma: noComma))
        case .keyword("import"), .keyword("include"), .keyword("module"):
            if case .keyword(let word) = token {
                throw unsupported("modules (`\(word)`) are not supported in Vitrine", at: start)
            }
            throw syntax("unexpected keyword", at: start)
        case .ident("break"):
            let at = try here()
            guard case .variable(let name) = try next() else { throw syntax("expected '$name' after 'break'", at: at) }
            return .breakLabel(name, start)
        case .ident(let name):
            if try peek() != .op("(") {
                switch name {
                case "true": return .literal(.bool(true))
                case "false": return .literal(.bool(false))
                case "null": return .literal(.null)
                default: return .call(JQCall(name: name, args: [], offset: start))
                }
            }
            try next()
            var args: [JQNode] = []
            while true {
                args.append(try parsePipe(noComma: false))
                if try peek() == .op(";") { try next(); continue }
                try expect(.op(")"), "';' or ')'")
                break
            }
            return .call(JQCall(name: name, args: args, offset: start))
        default:
            throw syntax("unexpected \(describe(token))", at: start)
        }
    }

    /// `try`'s body and `catch`'s handler: a postfix term (with an optional leading minus).
    private mutating func parseTryOperand() throws -> JQNode {
        if try peek() == .op("-") {
            try next()
            return .negate(try parsePostfix(allowAs: false))
        }
        return try parsePostfix(allowAs: false)
    }

    private mutating func parseIfRest() throws -> JQNode {
        let condition = try parsePipe(noComma: false)
        try expect(.keyword("then"), "'then'")
        let then = try parsePipe(noComma: false)
        let at = try here()
        switch try next() {
        case .keyword("elif"): return .ifElse(condition, then, try parseIfRest())
        case .keyword("else"):
            let otherwise = try parsePipe(noComma: false)
            try expect(.keyword("end"), "'end'")
            return .ifElse(condition, then, otherwise)
        case .keyword("end"): return .ifElse(condition, then, nil)
        case let other: throw syntax("expected 'elif', 'else' or 'end', found \(describe(other))", at: at)
        }
    }

    /// After `def`: `name: body;` or `name(params): body;`.
    private mutating func parseDefinition() throws -> JQFuncDef {
        let at = try here()
        let nameToken = try next()
        let name: String
        switch nameToken {
        case .ident(let n): name = n
        case .keyword(let n) where !["def", "if", "then", "elif", "else", "end", "as", "reduce", "foreach", "try", "catch", "label"].contains(n):
            name = n
        default: throw syntax("expected a function name after 'def', found \(describe(nameToken))", at: at)
        }
        var params: [JQParam] = []
        if try peek() == .op("(") {
            try next()
            while true {
                let pat = try here()
                switch try next() {
                case .ident(let p): params.append(JQParam(name: p, isValue: false))
                case .variable(let p): params.append(JQParam(name: p, isValue: true))
                case let other: throw syntax("expected a parameter name, found \(describe(other))", at: pat)
                }
                if try peek() == .op(";") { try next(); continue }
                try expect(.op(")"), "';' or ')'")
                break
            }
        }
        try expect(.op(":"), "':' after the function name")
        let body = try parsePipe(noComma: false)
        try expect(.op(";"), "';' after the function body")
        return JQFuncDef(name: name, params: params, body: body, isBuiltin: builtin)
    }

    private mutating func parseObject() throws -> JQNode {
        var entries: [JQObjectEntry] = []
        if try peek() == .op("}") {
            try next()
            return .object([])
        }
        while true {
            let at = try here()
            let token = try next()
            switch token {
            case .variable(let name):
                entries.append(JQObjectEntry(key: .literal(.string(name)), value: .variable(name, at)))
            case .ident(let name), .keyword(let name):
                let key = JQNode.literal(.string(name))
                if try peek() == .op(":") {
                    try next()
                    entries.append(JQObjectEntry(key: key, value: try parsePipe(noComma: true)))
                } else {
                    entries.append(JQObjectEntry(key: key, value: .index(.identity, key)))
                }
            case .number(let d):
                // jq reads `{1: 2}` as a key that is not a string; refuse it at compile time.
                throw syntax("object keys must be strings, found the number \(JQNumberFormat.format(d))", at: at)
            case .quote, .format:
                var format: String?
                if case .format(let name) = token {
                    guard Self.formats.contains(name) else { throw syntax("\(name) is not a valid format", at: at) }
                    format = name
                    try expect(.quote, "a string after the format")
                }
                let key = try parseStringBody(format: format)
                if try peek() == .op(":") {
                    try next()
                    entries.append(JQObjectEntry(key: key, value: try parsePipe(noComma: true)))
                } else {
                    entries.append(JQObjectEntry(key: key, value: .index(.identity, key)))
                }
            case .op("("):
                let key = try parsePipe(noComma: false)
                try expect(.op(")"), "')'")
                try expect(.op(":"), "':' after a computed key")
                entries.append(JQObjectEntry(key: key, value: try parsePipe(noComma: true)))
            default:
                throw syntax("unexpected \(describe(token)) in an object", at: at)
            }
            if try peek() == .op(",") {
                try next()
                continue
            }
            try expect(.op("}"), "',' or '}'")
            return .object(entries)
        }
    }

    // MARK: Patterns

    private mutating func parsePatterns() throws -> JQPattern {
        let pattern = try parsePattern()
        if try peek() == .op("?"), let after = try byteAfterPeek(), after == UInt8(ascii: "/") {
            throw unsupported("destructuring alternatives (`?//`) are not supported in Vitrine yet", at: try here())
        }
        return pattern
    }

    private mutating func parsePattern() throws -> JQPattern {
        let at = try here()
        switch try next() {
        case .variable(let name):
            return .variable(name)
        case .op("["):
            var items: [JQPattern] = []
            while true {
                items.append(try parsePattern())
                if try peek() == .op(",") { try next(); continue }
                try expect(.op("]"), "',' or ']'")
                return .array(items)
            }
        case .op("{"):
            var entries: [JQObjectPatternEntry] = []
            while true {
                let kat = try here()
                switch try next() {
                case .variable(let name):
                    var sub: JQPattern?
                    if try peek() == .op(":") {
                        try next()
                        sub = try parsePattern()
                    }
                    entries.append(JQObjectPatternEntry(key: .variable(name), pattern: sub))
                case .ident(let name), .keyword(let name):
                    try expect(.op(":"), "':' after the key")
                    entries.append(JQObjectPatternEntry(key: .expression(.literal(.string(name))), pattern: try parsePattern()))
                case .quote:
                    let key = try parseStringBody(format: nil)
                    try expect(.op(":"), "':' after the key")
                    entries.append(JQObjectPatternEntry(key: .expression(key), pattern: try parsePattern()))
                case .op("("):
                    let key = try parsePipe(noComma: false)
                    try expect(.op(")"), "')'")
                    try expect(.op(":"), "':' after the key")
                    entries.append(JQObjectPatternEntry(key: .expression(key), pattern: try parsePattern()))
                case let other:
                    throw syntax("unexpected \(describe(other)) in an object pattern", at: kat)
                }
                if try peek() == .op(",") { try next(); continue }
                try expect(.op("}"), "',' or '}'")
                return .object(entries)
            }
        case let other:
            throw syntax("expected a pattern ($name, [...] or {...}), found \(describe(other))", at: at)
        }
    }

    // MARK: Strings

    /// The body of a string whose opening quote was just read: escapes, and `\(…)` interpolations parsed as programs.
    private mutating func parseStringBody(format: String?) throws -> JQNode {
        precondition(lookahead == nil)
        let start = pos - 1
        var parts: [JQStringPart] = []
        var buffer: [UInt8] = []
        func hex4(_ p: inout Int) throws -> UInt32 {
            guard p + 4 <= src.count else { throw syntax("invalid \\u escape", at: p) }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = src[p]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: throw syntax("invalid \\u escape", at: p)
                }
                v = v << 4 | d
                p += 1
            }
            return v
        }
        while true {
            guard pos < src.count else { throw syntax("unterminated string", at: start) }
            let c = src[pos]
            if c == UInt8(ascii: "\"") {
                pos += 1
                break
            }
            guard c == UInt8(ascii: "\\") else {
                buffer.append(c)
                pos += 1
                continue
            }
            let escapeAt = pos
            pos += 1
            guard pos < src.count else { throw syntax("unterminated string", at: start) }
            let e = src[pos]
            pos += 1
            switch e {
            case UInt8(ascii: "\""): buffer.append(0x22)
            case UInt8(ascii: "\\"): buffer.append(0x5C)
            case UInt8(ascii: "/"): buffer.append(0x2F)
            case UInt8(ascii: "b"): buffer.append(0x08)
            case UInt8(ascii: "f"): buffer.append(0x0C)
            case UInt8(ascii: "n"): buffer.append(0x0A)
            case UInt8(ascii: "r"): buffer.append(0x0D)
            case UInt8(ascii: "t"): buffer.append(0x09)
            case UInt8(ascii: "u"):
                var cursor = pos
                var scalar = try hex4(&cursor)
                pos = cursor
                if (0xD800..<0xDC00).contains(scalar), pos + 1 < src.count, src[pos] == 0x5C, src[pos + 1] == UInt8(ascii: "u") {
                    var p = pos + 2
                    let low = try hex4(&p)
                    if (0xDC00..<0xE000).contains(low) {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        pos = p
                    }
                }
                let u = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                buffer.append(contentsOf: Array(String(Character(u)).utf8))
            case UInt8(ascii: "("):
                if !buffer.isEmpty {
                    parts.append(.literal(String(decoding: buffer, as: UTF8.self)))
                    buffer.removeAll()
                }
                let inner = try parsePipe(noComma: false)
                let closeAt = try here()
                guard try next() == .op(")") else { throw syntax("expected ')' to close the interpolation", at: closeAt) }
                parts.append(.interpolation(inner))
            default:
                throw syntax("invalid escape '\\\(Character(Unicode.Scalar(e)))' in a string", at: escapeAt)
            }
        }
        if !buffer.isEmpty || parts.isEmpty { parts.append(.literal(String(decoding: buffer, as: UTF8.self))) }
        if parts.count == 1, case .literal(let s) = parts[0] { return .literal(.string(s)) }
        return .string(parts, format: format)
    }
}
