import Foundation

/// GraphQL SDL schemas and executable documents (`.graphql`, `.gql`, `.graphqls`), read by a pull lexer and a
/// parser without recursion: list types are bounded, selection sets and values are skipped by counting brackets.
/// A definition that does not parse is skipped with a warning and reading goes on at the next definition.
/// roadmap: S-22
enum GraphQLReader {
    static func read(_ bytes: [UInt8], cut: Bool) -> GraphQLSummary? {
        var parser = GQLParser(bytes)
        parser.parseDocument()
        return parser.summary(cut: cut)
    }
}

/// One GraphQL token. roadmap: S-22
struct GQLToken {
    enum Kind: Equatable { case name, punct, number, string, eof }
    var kind: Kind
    var text: String
    var line: Int

    func isPunct(_ p: String) -> Bool { kind == .punct && text == p }
    func isName(_ n: String) -> Bool { kind == .name && text == n }
}

/// The GraphQL lexer: ignores whitespace, commas, `#` comments and a BOM; reads names, numbers, punctuators
/// (`...` as one) and strings, including block strings with their common indentation removed. roadmap: S-22
struct GQLLexer {
    private let b: [UInt8]
    private var i = 0
    private var line = 1
    private(set) var endedInside = false

    init(_ bytes: [UInt8]) {
        b = bytes
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
    }

    private static func isNameStart(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    mutating func next() -> GQLToken {
        while i < b.count {
            let c = b[i]
            if c == 0x0A { line += 1; i += 1; continue }
            if c == 0x0D { if !(i + 1 < b.count && b[i + 1] == 0x0A) { line += 1 }; i += 1; continue }
            if c == 0x20 || c == 0x09 || c == 0x2C { i += 1; continue }
            if c == 0x23 { while i < b.count, b[i] != 0x0A, b[i] != 0x0D { i += 1 }; continue }
            break
        }
        guard i < b.count else { return GQLToken(kind: .eof, text: "", line: line) }
        let c = b[i]
        let startLine = line
        if GQLLexer.isNameStart(c) {
            let start = i
            while i < b.count, GQLLexer.isNameStart(b[i]) || GQLLexer.isDigit(b[i]) { i += 1 }
            return GQLToken(kind: .name, text: String(decoding: b[start..<i], as: UTF8.self), line: startLine)
        }
        if GQLLexer.isDigit(c) || (c == 0x2D && i + 1 < b.count && GQLLexer.isDigit(b[i + 1])) {
            let start = i
            i += 1
            while i < b.count {
                let d = b[i]
                if GQLLexer.isDigit(d) || d == 0x2E || d == 0x65 || d == 0x45 { i += 1; continue }
                if (d == 0x2B || d == 0x2D), b[i - 1] == 0x65 || b[i - 1] == 0x45 { i += 1; continue }
                break
            }
            return GQLToken(kind: .number, text: String(decoding: b[start..<i], as: UTF8.self), line: startLine)
        }
        if c == 0x22 {
            if i + 2 < b.count, b[i + 1] == 0x22, b[i + 2] == 0x22 { return blockString(startLine) }
            return quotedString(startLine)
        }
        if c == 0x2E, i + 2 < b.count, b[i + 1] == 0x2E, b[i + 2] == 0x2E {
            i += 3
            return GQLToken(kind: .punct, text: "...", line: startLine)
        }
        i += 1
        if c >= 0x80 {
            while i < b.count, b[i] & 0xC0 == 0x80 { i += 1 }
            return GQLToken(kind: .punct, text: "?", line: startLine)
        }
        return GQLToken(kind: .punct, text: String(UnicodeScalar(c)), line: startLine)
    }

    private mutating func quotedString(_ startLine: Int) -> GQLToken {
        i += 1
        var out: [UInt8] = []
        while i < b.count {
            let d = b[i]
            if d == 0x22 { i += 1; return GQLToken(kind: .string, text: String(decoding: out, as: UTF8.self), line: startLine) }
            if d == 0x0A || d == 0x0D { break }
            if d == 0x5C, i + 1 < b.count {
                let e = b[i + 1]
                i += 2
                switch e {
                case 0x6E: out.append(0x0A)
                case 0x74: out.append(0x09)
                case 0x72: out.append(0x0D)
                case 0x62, 0x66: break
                case 0x75:                                          // \uXXXX (or \u{…})
                    var hex: [UInt8] = []
                    if i < b.count, b[i] == 0x7B {
                        i += 1
                        while i < b.count, b[i] != 0x7D, hex.count < 8 { hex.append(b[i]); i += 1 }
                        if i < b.count, b[i] == 0x7D { i += 1 }
                    } else {
                        while i < b.count, hex.count < 4 { hex.append(b[i]); i += 1 }
                    }
                    if let v = UInt32(String(decoding: hex, as: UTF8.self), radix: 16), let s = UnicodeScalar(v) {
                        out.append(contentsOf: Array(String(s).utf8))
                    }
                default: out.append(e)
                }
                continue
            }
            if out.count < 65_536 { out.append(d) }
            i += 1
        }
        endedInside = i >= b.count
        return GQLToken(kind: .string, text: String(decoding: out, as: UTF8.self), line: startLine)
    }

    private mutating func blockString(_ startLine: Int) -> GQLToken {
        i += 3
        var raw: [UInt8] = []
        var closed = false
        while i < b.count {
            if b[i] == 0x22, i + 2 < b.count, b[i + 1] == 0x22, b[i + 2] == 0x22 { i += 3; closed = true; break }
            if b[i] == 0x5C, i + 3 < b.count, b[i + 1] == 0x22, b[i + 2] == 0x22, b[i + 3] == 0x22 {
                raw.append(contentsOf: [0x22, 0x22, 0x22]); i += 4; continue
            }
            if b[i] == 0x0A { line += 1 }
            if raw.count < 65_536 { raw.append(b[i]) }
            i += 1
        }
        if !closed { endedInside = true }
        return GQLToken(kind: .string, text: GQLLexer.blockValue(String(decoding: raw, as: UTF8.self)), line: startLine)
    }

    /// The spec's BlockStringValue: common indentation removed, blank first and last lines dropped.
    static func blockValue(_ raw: String) -> String {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let indents = lines.dropFirst().filter { !$0.allSatisfy { $0 == " " || $0 == "\t" } }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        if let common = indents.min(), common > 0 {
            for k in lines.indices.dropFirst() { lines[k] = String(lines[k].dropFirst(min(common, lines[k].count))) }
        }
        while let f = lines.first, f.allSatisfy({ $0 == " " || $0 == "\t" }) { lines.removeFirst() }
        while let l = lines.last, l.allSatisfy({ $0 == " " || $0 == "\t" }) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// The GraphQL parser. Every loop consumes a token or stops; nothing recurses. roadmap: S-22
struct GQLParser {
    /// Where reading failed: the line, the token there (empty at the end of input) and a note for debugging.
    struct Failure: Error { let line: Int; let token: String; let message: String }

    private var lexer: GQLLexer
    private var tok: GQLToken

    private var types: [GraphQLSummary.TypeDefinition] = []
    private var typeCounts: [GraphQLSummary.TypeKind: Int] = [:]
    private var definedNames: [String: Int] = [:]
    private var directives: [GraphQLSummary.DirectiveDefinition] = []
    private var operations: [GraphQLSummary.Operation] = []
    private var fragments: [GraphQLSummary.Fragment] = []
    private var schemaRoots: [GraphQLSummary.OperationKind: String] = [:]
    private var sawSchemaBlock = false
    private var errors: [Failure] = []
    private var truncated = false
    /// Root-type fields collected while parsing, in case `types` is capped before they appear.
    private var rootFieldsByType: [String: [GraphQLSummary.Field]] = [:]

    static let definitionKeywords: Set<String> = ["schema", "scalar", "type", "interface", "union", "enum", "input",
                                                  "directive", "extend", "query", "mutation", "subscription", "fragment"]

    init(_ bytes: [UInt8]) {
        lexer = GQLLexer(bytes)
        tok = lexer.next()
    }

    private mutating func advance() { tok = lexer.next() }

    private func fail(_ message: String) -> Failure { Failure(line: tok.line, token: tok.text, message: message) }

    private mutating func expectName(_ what: String) throws -> String {
        guard tok.kind == .name else { throw fail("expected \(what)") }
        let t = tok.text
        advance()
        return t
    }

    private mutating func expectPunct(_ p: String) throws {
        guard tok.isPunct(p) else { throw fail("expected \(p)") }
        advance()
    }

    // MARK: Document

    mutating func parseDocument() {
        while tok.kind != .eof {
            do {
                try parseDefinition()
            } catch let failure as Failure {
                if errors.count < 5 { errors.append(failure) }
                recover()
            } catch {
                recover()
            }
        }
    }

    /// Skips to the next definition keyword at bracket depth 0, moving at least one token.
    private mutating func recover() {
        var depth = 0
        var moved = false
        while tok.kind != .eof {
            if moved, depth == 0, tok.kind == .name, GQLParser.definitionKeywords.contains(tok.text) { return }
            if moved, depth == 0, tok.kind == .string { return }
            if tok.isPunct("{") || tok.isPunct("(") || tok.isPunct("[") { depth += 1 }
            if tok.isPunct("}") || tok.isPunct(")") || tok.isPunct("]") { depth = max(0, depth - 1) }
            advance()
            moved = true
        }
    }

    private mutating func parseDefinition() throws {
        var description: String?
        if tok.kind == .string {
            description = SpecText.oneLineOrNil(tok.text)
            advance()
        }
        if tok.isPunct("{") {
            appendCapped(&operations, .init(kind: .query, name: nil, variables: []), &truncated)
            try skipSelectionSet()
            return
        }
        guard tok.kind == .name else { throw fail("unexpected \(tok.text.isEmpty ? "end of file" : "“\(tok.text)”")") }
        switch tok.text {
        case "schema": advance(); try parseSchema(extend: false)
        case "scalar": advance(); try parseType(.scalar, extend: false, description: description)
        case "type": advance(); try parseType(.object, extend: false, description: description)
        case "interface": advance(); try parseType(.interface, extend: false, description: description)
        case "union": advance(); try parseType(.union, extend: false, description: description)
        case "enum": advance(); try parseType(.enumeration, extend: false, description: description)
        case "input": advance(); try parseType(.input, extend: false, description: description)
        case "directive": advance(); try parseDirectiveDefinition()
        case "extend":
            advance()
            let kinds: [String: GraphQLSummary.TypeKind] = ["scalar": .scalar, "type": .object, "interface": .interface,
                                                            "union": .union, "enum": .enumeration, "input": .input]
            if tok.isName("schema") { advance(); try parseSchema(extend: true) }
            else if tok.kind == .name, let kind = kinds[tok.text] { advance(); try parseType(kind, extend: true, description: nil) }
            else { throw fail("expected a type kind after extend") }
        case "query": advance(); try parseOperation(.query)
        case "mutation": advance(); try parseOperation(.mutation)
        case "subscription": advance(); try parseOperation(.subscription)
        case "fragment":
            advance()
            let name = try expectName("a fragment name")
            guard tok.isName("on") else { throw fail("expected on") }
            advance()
            let condition = try expectName("a type condition")
            _ = try parseDirectives()
            appendCapped(&fragments, .init(name: name, typeCondition: condition), &truncated)
            try skipSelectionSet()
        default:
            throw fail("unexpected “\(tok.text)”")
        }
    }

    // MARK: Type system

    private mutating func parseSchema(extend: Bool) throws {
        _ = try parseDirectives()
        sawSchemaBlock = true
        guard tok.isPunct("{") else {
            if extend { return }
            throw fail("expected {")
        }
        advance()
        while !tok.isPunct("}") {
            guard tok.kind != .eof else { throw fail("the schema block is not closed") }
            let op = try expectName("query, mutation or subscription")
            try expectPunct(":")
            let type = try expectName("a type name")
            if let kind = GraphQLSummary.OperationKind(rawValue: op) { schemaRoots[kind] = type }
        }
        advance()
    }

    private mutating func parseType(_ kind: GraphQLSummary.TypeKind, extend: Bool, description: String?) throws {
        let name = try expectName("a type name")
        var def = GraphQLSummary.TypeDefinition(name: name, kind: kind, description: description, isExtension: extend,
                                                implements: [], fields: [], enumValues: [], unionMembers: [], directives: [])
        if tok.isName("implements") {
            advance()
            if tok.isPunct("&") { advance() }
            def.implements.append(try expectName("an interface name"))
            while tok.isPunct("&") {
                advance()
                if def.implements.count < 100 { def.implements.append(try expectName("an interface name")) }
            }
        }
        def.directives = try parseDirectives().names
        switch kind {
        case .object, .interface, .input:
            if tok.isPunct("{") { def.fields = try parseFields(owner: name, input: kind == .input) }
        case .enumeration:
            if tok.isPunct("{") { def.enumValues = try parseEnumValues() }
        case .union:
            if tok.isPunct("=") {
                advance()
                if tok.isPunct("|") { advance() }
                appendCapped(&def.unionMembers, try expectName("a member type"), &truncated)
                while tok.isPunct("|") {
                    advance()
                    appendCapped(&def.unionMembers, try expectName("a member type"), &truncated)
                }
            }
        case .scalar:
            break
        }
        if !extend {
            typeCounts[kind, default: 0] += 1
            definedNames[name, default: 0] += 1
        }
        if kind == .object { rootFieldsByType[name, default: []] += def.fields.prefix(APISpecReader.maxListItems) }
        appendCapped(&types, def, &truncated)
    }

    private mutating func parseFields(owner: String, input: Bool) throws -> [GraphQLSummary.Field] {
        advance()                                                   // {
        var fields: [GraphQLSummary.Field] = []
        while !tok.isPunct("}") {
            guard tok.kind != .eof else { throw fail("the fields of \(owner) are not closed") }
            var description: String?
            if tok.kind == .string { description = SpecText.oneLineOrNil(tok.text); advance() }
            let name = try expectName("a field name")
            let arguments = tok.isPunct("(") && !input ? try parseArguments(variables: false) : []
            try expectPunct(":")
            let type = try parseTypeReference()
            var defaultValue: String?
            if tok.isPunct("=") { advance(); defaultValue = try valueText() }
            let applied = try parseDirectives()
            appendCapped(&fields, .init(name: name, arguments: arguments, type: type, defaultValue: defaultValue,
                                        description: description, deprecated: applied.deprecated,
                                        deprecationReason: applied.reason, directives: applied.names), &truncated)
        }
        advance()
        return fields
    }

    private mutating func parseEnumValues() throws -> [GraphQLSummary.EnumValue] {
        advance()
        var values: [GraphQLSummary.EnumValue] = []
        while !tok.isPunct("}") {
            guard tok.kind != .eof else { throw fail("the enum values are not closed") }
            var description: String?
            if tok.kind == .string { description = SpecText.oneLineOrNil(tok.text); advance() }
            let name = try expectName("an enum value")
            let applied = try parseDirectives()
            appendCapped(&values, .init(name: name, description: description, deprecated: applied.deprecated,
                                        deprecationReason: applied.reason), &truncated)
        }
        advance()
        return values
    }

    /// `( name: Type = default @dir … )`, or operation variables `( $name: Type … )`.
    private mutating func parseArguments(variables: Bool) throws -> [GraphQLSummary.Argument] {
        advance()                                                   // (
        var args: [GraphQLSummary.Argument] = []
        while !tok.isPunct(")") {
            guard tok.kind != .eof else { throw fail("the argument list is not closed") }
            if tok.kind == .string { advance() }                   // argument description
            var name: String
            if variables {
                try expectPunct("$")
                name = "$" + (try expectName("a variable name"))
            } else {
                name = try expectName("an argument name")
            }
            try expectPunct(":")
            let type = try parseTypeReference()
            var defaultValue: String?
            if tok.isPunct("=") { advance(); defaultValue = try valueText() }
            let applied = try parseDirectives()
            appendCapped(&args, .init(name: name, type: type, defaultValue: defaultValue, deprecated: applied.deprecated), &truncated)
        }
        advance()
        return args
    }

    /// `Name`, `Name!`, `[Name!]!` … with at most `maxNesting` brackets.
    private mutating func parseTypeReference() throws -> String {
        var opens = 0
        while tok.isPunct("[") {
            opens += 1
            guard opens <= APISpecReader.maxNesting else { throw fail("the list type is nested too deeply") }
            advance()
        }
        var text = try expectName("a type")
        if tok.isPunct("!") { text += "!"; advance() }
        for _ in 0..<opens {
            try expectPunct("]")
            text = "[\(text)]"
            if tok.isPunct("!") { text += "!"; advance() }
        }
        return text
    }

    /// Applied directives: their names, and `@deprecated` with its reason.
    private mutating func parseDirectives() throws -> (names: [String], deprecated: Bool, reason: String?) {
        var names: [String] = []
        var deprecated = false
        var reason: String?
        while tok.isPunct("@") {
            advance()
            let name = try expectName("a directive name")
            if names.count < 50 { names.append(name) }
            if name == "deprecated" { deprecated = true }
            if tok.isPunct("(") {
                advance()
                while !tok.isPunct(")") {
                    guard tok.kind != .eof else { throw fail("the directive arguments are not closed") }
                    let arg = try expectName("an argument name")
                    try expectPunct(":")
                    let isString = tok.kind == .string
                    let raw = tok.text
                    let value = try valueText()
                    if name == "deprecated", arg == "reason" { reason = SpecText.oneLineOrNil(isString ? raw : value) }
                }
                advance()
            }
        }
        return (names, deprecated, reason)
    }

    /// One value as short display text; lists and objects are read by counting brackets.
    private mutating func valueText() throws -> String {
        switch tok.kind {
        case .string:
            let s = "\"\(SpecText.oneLine(tok.text, limit: 80))\""
            advance()
            return s
        case .name, .number:
            let s = tok.text
            advance()
            return s
        case .punct where tok.text == "$":
            advance()
            return "$" + (try expectName("a variable name"))
        case .punct where tok.text == "[" || tok.text == "{":
            var out = ""
            var depth = 0
            repeat {
                if tok.kind == .eof { throw fail("a value is not closed") }
                if tok.isPunct("[") || tok.isPunct("{") { depth += 1 }
                if tok.isPunct("]") || tok.isPunct("}") { depth -= 1 }
                if out.count < 120 {
                    let piece = tok.kind == .string ? "\"\(tok.text)\"" : tok.text
                    let joinTight = out.isEmpty || out.hasSuffix("[") || out.hasSuffix("{") || piece == "]" || piece == "}" || piece == ":"
                    out += (joinTight ? "" : " ") + piece
                }
                advance()
            } while depth > 0
            return out.count >= 120 ? String(out.prefix(120)) + "…" : out
        default:
            throw fail("expected a value")
        }
    }

    private mutating func parseDirectiveDefinition() throws {
        try expectPunct("@")
        let name = try expectName("a directive name")
        let args = tok.isPunct("(") ? try parseArguments(variables: false) : []
        var repeatable = false
        if tok.isName("repeatable") { repeatable = true; advance() }
        guard tok.isName("on") else { throw fail("expected on") }
        advance()
        if tok.isPunct("|") { advance() }
        var locations = [try expectName("a directive location")]
        while tok.isPunct("|") {
            advance()
            let location = try expectName("a directive location")
            if locations.count < 40 { locations.append(location) }
        }
        appendCapped(&directives, .init(name: name, arguments: args, locations: locations, repeatable: repeatable), &truncated)
    }

    // MARK: Executable definitions

    private mutating func parseOperation(_ kind: GraphQLSummary.OperationKind) throws {
        var name: String?
        if tok.kind == .name { name = tok.text; advance() }
        let variables = tok.isPunct("(") ? try parseArguments(variables: true) : []
        _ = try parseDirectives()
        appendCapped(&operations, .init(kind: kind, name: name, variables: variables), &truncated)
        try skipSelectionSet()
    }

    private mutating func skipSelectionSet() throws {
        guard tok.isPunct("{") else { throw fail("expected a selection set") }
        var depth = 0
        repeat {
            if tok.kind == .eof { throw fail("a selection set is not closed") }
            if tok.isPunct("{") { depth += 1 }
            if tok.isPunct("}") { depth -= 1 }
            advance()
        } while depth > 0
    }

    // MARK: Summary

    func summary(cut: Bool) -> GraphQLSummary? {
        let hasSchema = !types.isEmpty || !directives.isEmpty || sawSchemaBlock
        let hasOperations = !operations.isEmpty || !fragments.isEmpty
        // Nothing parsed and errors raised: not GraphQL (an empty file, by contrast, is an empty document).
        if !hasSchema, !hasOperations, !errors.isEmpty { return nil }
        let kind: GraphQLSummary.DocumentKind = hasSchema && hasOperations ? .mixed : hasSchema ? .schema : hasOperations ? .operations : .empty

        let defaults: [GraphQLSummary.OperationKind: String] = [.query: "Query", .mutation: "Mutation", .subscription: "Subscription"]
        func root(_ k: GraphQLSummary.OperationKind) -> String? {
            if let explicit = schemaRoots[k] { return explicit }
            if let name = defaults[k], rootFieldsByType[name] != nil { return name }
            return nil
        }
        let queryType = root(.query), mutationType = root(.mutation), subscriptionType = root(.subscription)
        func fields(_ name: String?) -> [GraphQLSummary.Field] {
            guard let name else { return [] }
            return Array((rootFieldsByType[name] ?? []).prefix(APISpecReader.maxListItems))
        }

        var deprecated: [String] = []
        var truncated = self.truncated || cut || lexer.endedInside
        for t in types {
            for f in t.fields {
                if f.deprecated { appendCapped(&deprecated, "\(t.name).\(f.name)", &truncated) }
                for a in f.arguments where a.deprecated { appendCapped(&deprecated, "\(t.name).\(f.name)(\(a.name))", &truncated) }
            }
            for v in t.enumValues where v.deprecated { appendCapped(&deprecated, "\(t.name).\(v.name)", &truncated) }
        }

        var warnings = SpecWarnings()
        for e in errors {
            warnings.add(.caution, e.token.isEmpty ? L.skippedAtEnd(e.line) : L.skippedAt(e.line, SpecText.oneLine(e.token, limit: 40)))
        }
        let twice = definedNames.filter { $0.value > 1 }.keys.sorted()
        if !twice.isEmpty {
            warnings.add(.danger, L.definedTwice(SpecText.examples(twice)))
        }
        if !deprecated.isEmpty {
            warnings.add(.caution, L.gqlDeprecated(deprecated.count, SpecText.examples(deprecated)))
        }
        if operations.count > 1, operations.contains(where: { $0.name == nil }) {
            warnings.add(.caution, L.anonymousWithOthers)
        }
        var opNames: [String: Int] = [:]
        for op in operations { if let n = op.name { opNames[n, default: 0] += 1 } }
        let dupOps = opNames.filter { $0.value > 1 }.keys.sorted()
        if !dupOps.isEmpty { warnings.add(.caution, L.duplicateOperationNames(SpecText.examples(dupOps))) }
        if lexer.endedInside { warnings.add(.caution, L.endsInsideString) }

        return GraphQLSummary(documentKind: kind, types: types, typeCounts: typeCounts, queryType: queryType,
                              mutationType: mutationType, subscriptionType: subscriptionType,
                              queryFields: fields(queryType), mutationFields: fields(mutationType),
                              subscriptionFields: fields(subscriptionType), directives: directives,
                              deprecated: deprecated, operations: operations, fragments: fragments,
                              warnings: warnings.list, truncated: truncated)
    }
}
