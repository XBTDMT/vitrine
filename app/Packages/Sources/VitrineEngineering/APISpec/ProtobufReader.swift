import Foundation

/// `.proto` files (proto2, proto3 and editions), read by `CTokens`. Nested messages are followed to
/// `APISpecReader.maxNesting` levels and skipped past that; a statement that does not parse is skipped with a
/// warning. Options are recorded by name with simple values, aggregates as `{…}`. roadmap: S-22
enum ProtobufReader {
    static let maxFieldNumber = 536_870_911

    static func read(_ bytes: [UInt8], cut: Bool) -> ProtobufSummary? {
        var p = ProtoParser(bytes)
        p.parseFile()
        return p.summary(cut: cut)
    }
}

/// The `.proto` parser. Each body loop either consumes a token or stops at `}` / the end. roadmap: S-22
struct ProtoParser {
    private var t: CTokens
    private var syntax: String?
    private var edition: String?
    private var package: String?
    private var imports: [ProtobufSummary.Import] = []
    private var options: [ProtobufSummary.Option] = []
    private var messages: [ProtobufSummary.Message] = []
    private var enums: [ProtobufSummary.Enumeration] = []
    private var services: [ProtobufSummary.Service] = []
    private var extensions: [ProtobufSummary.Extension] = []
    private var counts = (messages: 0, enums: 0, fields: 0, rpcs: 0)
    private var truncated = false
    /// Where reading failed: the line, the token there and a note for debugging.
    private var errors: [(line: Int, token: String, message: String)] = []
    private var recognised = 0

    init(_ bytes: [UInt8]) { t = CTokens(bytes) }

    private mutating func error(_ message: String) {
        if errors.count < 5 { errors.append((t.tok.line, t.tok.text, message)) }
    }

    private var scopePrefix: String { package.map { "\($0)." } ?? "" }

    // MARK: File

    mutating func parseFile() {
        while !t.atEnd {
            let tok = t.tok
            if tok.isSymbol(";") { t.advance(); continue }
            if tok.isSymbol("}") { error("unexpected }"); t.advance(); continue }
            guard tok.kind == .ident else { error("unexpected “\(tok.text)”"); t.skipStatement(); continue }
            switch tok.text {
            case "syntax":
                t.advance()
                if t.accept("="), t.tok.kind == .string { syntax = t.tok.text; t.advance(); recognised += 1 }
                else { error("a syntax line needs = \"proto3\"") }
                t.skipStatement()
            case "edition":
                t.advance()
                if t.accept("="), t.tok.kind == .string { edition = t.tok.text; t.advance(); recognised += 1 }
                t.skipStatement()
            case "package":
                t.advance()
                if let name = t.ident() { package = name; recognised += 1 }
                t.skipStatement()
            case "import":
                t.advance()
                var modifier: String?
                if t.tok.isIdent("public") || t.tok.isIdent("weak") { modifier = t.tok.text; t.advance() }
                if t.tok.kind == .string {
                    appendCapped(&imports, .init(path: t.tok.text, modifier: modifier), &truncated)
                    t.advance()
                    recognised += 1
                }
                t.skipStatement()
            case "option":
                t.advance()
                if let option = parseOptionBody() { appendCapped(&options, option, &truncated) }
                t.skipStatement()
            case "message":
                t.advance()
                if let m = parseMessage(scope: scopePrefix, depth: 0) { appendCapped(&messages, m, &truncated); recognised += 1 }
            case "enum":
                t.advance()
                if let e = parseEnum(scope: scopePrefix) { appendCapped(&enums, e, &truncated); recognised += 1 }
            case "service":
                t.advance()
                if let s = parseService() { appendCapped(&services, s, &truncated); recognised += 1 }
            case "extend":
                t.advance()
                if let e = parseExtend(scope: scopePrefix) { appendCapped(&extensions, e, &truncated) }
            default:
                error("unexpected “\(tok.text)”")
                t.skipStatement()
            }
        }
    }

    /// `name = value` after `option`; the name keeps its parentheses (`(acme.rule).min`).
    private mutating func parseOptionBody() -> ProtobufSummary.Option? {
        var name = ""
        while !t.atEnd, !t.tok.isSymbol("="), !t.tok.isSymbol(";"), !t.tok.isSymbol("}"), name.count < 200 {
            name += t.tok.text
            t.advance()
        }
        guard t.accept("=") else { return nil }
        let value = optionValue()
        return name.isEmpty ? nil : .init(name: name, value: value)
    }

    /// A constant: strings (adjacent ones joined), identifiers, numbers with a sign, or `{…}` for an aggregate.
    private mutating func optionValue() -> String {
        if t.tok.isSymbol("{") { t.skipGroup("{", "}"); return "{…}" }
        if t.tok.kind == .string {
            var s = ""
            while t.tok.kind == .string { s += t.tok.text; t.advance() }
            return "\"\(SpecText.oneLine(s, limit: 120))\""
        }
        var s = ""
        if t.tok.isSymbol("-") || t.tok.isSymbol("+") { s = t.tok.text; t.advance() }
        if t.tok.kind == .ident || t.tok.kind == .number { s += t.tok.text; t.advance() }
        return s
    }

    // MARK: Messages

    private mutating func parseMessage(scope: String, depth: Int) -> ProtobufSummary.Message? {
        guard let name = t.ident() else { error("expected a message name"); t.skipStatement(); return nil }
        guard t.tok.isSymbol("{") else { error("expected { after message \(name)"); t.skipStatement(); return nil }
        counts.messages += 1
        var m = ProtobufSummary.Message(name: name, fullName: scope + name, fields: [], oneofs: [], messages: [], enums: [],
                                        reservedNumbers: [], reservedNames: [], nestingCut: false)
        if depth >= APISpecReader.maxNesting {
            t.skipGroup("{", "}")
            m.nestingCut = true
            truncated = true
            return m
        }
        t.advance()                                                 // {
        parseMessageBody(&m, depth: depth)
        return m
    }

    /// Reads members up to and including the closing `}`.
    private mutating func parseMessageBody(_ m: inout ProtobufSummary.Message, depth: Int) {
        let inner = m.fullName + "."
        while !t.atEnd {
            let tok = t.tok
            if tok.isSymbol("}") { t.advance(); return }
            if tok.isSymbol(";") { t.advance(); continue }
            guard tok.kind == .ident else { error("unexpected “\(tok.text)” in message \(m.name)"); t.skipStatement(); continue }
            switch tok.text {
            case "message" where t.ahead.kind == .ident:
                t.advance()
                if let nested = parseMessage(scope: inner, depth: depth + 1) {
                    if nested.nestingCut { m.nestingCut = true }
                    appendCapped(&m.messages, nested, &truncated)
                }
            case "enum" where t.ahead.kind == .ident:
                t.advance()
                if let e = parseEnum(scope: inner) { appendCapped(&m.enums, e, &truncated) }
            case "oneof" where t.ahead.kind == .ident:
                t.advance()
                parseOneof(into: &m)
            case "map" where t.ahead.isSymbol("<"):
                t.advance()
                if let f = parseMapField() { addField(f, to: &m) }
            case "reserved":
                t.advance()
                parseReserved(into: &m)
            case "extensions":
                t.skipStatement()
            case "option":
                t.advance()
                _ = parseOptionBody()
                t.skipStatement()
            case "extend" where t.ahead.kind == .ident:
                t.advance()
                _ = parseExtend(scope: inner)
            default:
                if let f = parseField(oneof: nil, into: &m, depth: depth) { addField(f, to: &m) }
            }
        }
        error("message \(m.name) is not closed")
    }

    private mutating func addField(_ f: ProtobufSummary.Field, to m: inout ProtobufSummary.Message) {
        counts.fields += 1
        appendCapped(&m.fields, f, &truncated)
    }

    /// `label? type name = number [options];`, or a proto2 `label group Name = number { … }`.
    private mutating func parseField(oneof: String?, into m: inout ProtobufSummary.Message, depth: Int) -> ProtobufSummary.Field? {
        var label = ProtobufSummary.Field.Label.none
        if let l = ProtobufSummary.Field.Label(rawValue: t.tok.text), l != .none, t.tok.kind == .ident, t.ahead.kind == .ident {
            label = l
            t.advance()
        }
        if t.tok.isIdent("group"), t.ahead.kind == .ident {
            t.advance()
            guard let groupName = t.ident(), t.accept("=") else { error("expected a group"); t.skipStatement(); return nil }
            let number = parseNumber()
            if t.tok.isSymbol("[") { t.skipGroup("[", "]") }
            var nested = ProtobufSummary.Message(name: groupName, fullName: m.fullName + "." + groupName, fields: [], oneofs: [],
                                                 messages: [], enums: [], reservedNumbers: [], reservedNames: [], nestingCut: false)
            counts.messages += 1
            if t.tok.isSymbol("{") {
                if depth + 1 >= APISpecReader.maxNesting { t.skipGroup("{", "}"); nested.nestingCut = true; truncated = true }
                else { t.advance(); parseMessageBody(&nested, depth: depth + 1) }
            }
            appendCapped(&m.messages, nested, &truncated)
            return .init(label: label, type: groupName, name: groupName.lowercased(), number: number, oneof: oneof,
                         mapKey: nil, mapValue: nil, deprecated: false)
        }
        guard t.tok.kind == .ident, t.ahead.kind == .ident else {
            error("expected a field in message \(m.name)")
            t.skipStatement()
            return nil
        }
        let type = t.tok.text
        t.advance()
        let name = t.tok.text
        t.advance()
        guard t.accept("=") else { error("field \(name) has no number"); t.skipStatement(); return nil }
        let number = parseNumber()
        let deprecated = t.tok.isSymbol("[") ? parseFieldOptions() : false
        if !t.accept(";") { error("expected ; after field \(name)"); t.skipStatement() }
        return .init(label: label, type: type, name: name, number: number, oneof: oneof, mapKey: nil, mapValue: nil,
                     deprecated: deprecated)
    }

    private mutating func parseMapField() -> ProtobufSummary.Field? {
        t.advance()                                                 // <
        guard let key = t.ident(), t.accept(","), let value = t.ident(), t.accept(">"), let name = t.ident(), t.accept("=") else {
            error("a map field is malformed")
            t.skipStatement()
            return nil
        }
        let number = parseNumber()
        let deprecated = t.tok.isSymbol("[") ? parseFieldOptions() : false
        if !t.accept(";") { t.skipStatement() }
        return .init(label: .none, type: "map<\(key), \(value)>", name: name, number: number, oneof: nil, mapKey: key,
                     mapValue: value, deprecated: deprecated)
    }

    private mutating func parseNumber() -> Int? {
        guard t.tok.kind == .number else { return nil }
        let text = t.tok.text
        t.advance()
        return ProtoParser.integer(text)
    }

    /// A decimal, hex (`0x`) or octal (`0…`) integer with at most one sign. The sign and the magnitude are read
    /// together, so `-9223372036854775808` is Int.min and anything outside Int (or a second sign, as in a `-`
    /// token followed by `-9…`) is nil, never a negation that overflows.
    static func integer(_ text: String) -> Int? {
        var s = Substring(text)
        var negative = false
        if s.hasPrefix("-") { negative = true; s = s.dropFirst() } else if s.hasPrefix("+") { s = s.dropFirst() }
        let digits: Substring, radix: Int
        if s.hasPrefix("0x") || s.hasPrefix("0X") { (digits, radix) = (s.dropFirst(2), 16) }
        else if s.count > 1, s.hasPrefix("0") { (digits, radix) = (s.dropFirst(), 8) }
        else { (digits, radix) = (s, 10) }
        // UInt64(_:radix:) would accept a sign of its own: only digits may follow the one sign read above.
        guard let first = digits.first, first != "+", first != "-", let magnitude = UInt64(digits, radix: radix) else { return nil }
        if negative {
            guard magnitude <= UInt64(Int.max) + 1 else { return nil }
            return magnitude == UInt64(Int.max) + 1 ? Int.min : -Int(magnitude)
        }
        return Int(exactly: magnitude)
    }

    /// `[ … ]`, reporting `deprecated = true`. Nested braces and brackets are skipped by counting.
    private mutating func parseFieldOptions() -> Bool {
        var depth = 0
        var deprecated = false
        while !t.atEnd {
            if t.tok.isSymbol("[") || t.tok.isSymbol("{") { depth += 1 }
            if t.tok.isSymbol("]") || t.tok.isSymbol("}") { depth -= 1 }
            if depth == 1, t.tok.isIdent("deprecated"), t.ahead.isSymbol("=") {
                t.advance(); t.advance()
                if t.tok.isIdent("true") { deprecated = true }
                continue
            }
            t.advance()
            if depth == 0 { break }
        }
        return deprecated
    }

    private mutating func parseOneof(into m: inout ProtobufSummary.Message) {
        guard let name = t.ident(), t.accept("{") else { error("a oneof is malformed"); t.skipStatement(); return }
        var oneof = ProtobufSummary.Oneof(name: name, fieldNames: [])
        while !t.atEnd, !t.tok.isSymbol("}") {
            if t.tok.isSymbol(";") { t.advance(); continue }
            if t.tok.isIdent("option") { t.skipStatement(); continue }
            if let f = parseField(oneof: name, into: &m, depth: 0) {
                appendCapped(&oneof.fieldNames, f.name, &truncated)
                addField(f, to: &m)
            }
        }
        t.accept("}")
        appendCapped(&m.oneofs, oneof, &truncated)
    }

    private mutating func parseReserved(into m: inout ProtobufSummary.Message) {
        var current = ""
        func flush(_ m: inout ProtobufSummary.Message, _ truncated: inout Bool) {
            if !current.isEmpty { appendCapped(&m.reservedNumbers, current, &truncated) }
            current = ""
        }
        while !t.atEnd, !t.tok.isSymbol(";"), !t.tok.isSymbol("}") {
            let tok = t.tok
            if tok.kind == .string { appendCapped(&m.reservedNames, tok.text, &truncated) }
            else if tok.isSymbol(",") { flush(&m, &truncated) }
            else if tok.kind == .number || tok.isIdent("to") || tok.isIdent("max") {
                current += current.isEmpty ? tok.text : " \(tok.text)"
            } else if tok.kind == .ident {
                appendCapped(&m.reservedNames, tok.text, &truncated)    // editions write names bare
            }
            t.advance()
        }
        flush(&m, &truncated)
        t.accept(";")
    }

    // MARK: Enums, services, extensions

    private mutating func parseEnum(scope: String) -> ProtobufSummary.Enumeration? {
        guard let name = t.ident(), t.accept("{") else { error("an enum is malformed"); t.skipStatement(); return nil }
        counts.enums += 1
        var e = ProtobufSummary.Enumeration(name: name, fullName: scope + name, values: [], allowAlias: false)
        while !t.atEnd {
            let tok = t.tok
            if tok.isSymbol("}") { t.advance(); return e }
            if tok.isSymbol(";") { t.advance(); continue }
            if tok.isIdent("option"), t.ahead.kind == .ident || t.ahead.isSymbol("(") {
                t.advance()
                if let o = parseOptionBody(), o.name == "allow_alias", o.value == "true" { e.allowAlias = true }
                t.skipStatement()
                continue
            }
            if tok.isIdent("reserved") { t.skipStatement(); continue }
            guard tok.kind == .ident, t.ahead.isSymbol("=") else { error("unexpected “\(tok.text)” in enum \(name)"); t.skipStatement(); continue }
            t.advance(); t.advance()
            var text = ""
            if t.tok.isSymbol("-") { text = "-"; t.advance() }
            var number: Int?
            if t.tok.kind == .number { number = ProtoParser.integer(text + t.tok.text); t.advance() }
            let deprecated = t.tok.isSymbol("[") ? parseFieldOptions() : false
            appendCapped(&e.values, .init(name: tok.text, number: number, deprecated: deprecated), &truncated)
            if !t.accept(";") { t.skipStatement() }
        }
        error("enum \(name) is not closed")
        return e
    }

    private mutating func parseService() -> ProtobufSummary.Service? {
        guard let name = t.ident(), t.accept("{") else { error("a service is malformed"); t.skipStatement(); return nil }
        var s = ProtobufSummary.Service(name: name, rpcs: [])
        while !t.atEnd {
            let tok = t.tok
            if tok.isSymbol("}") { t.advance(); return s }
            if tok.isSymbol(";") { t.advance(); continue }
            if tok.isIdent("rpc") {
                t.advance()
                if let rpc = parseRPC() { counts.rpcs += 1; appendCapped(&s.rpcs, rpc, &truncated) }
                continue
            }
            if tok.isIdent("option") { t.skipStatement(); continue }
            error("unexpected “\(tok.text)” in service \(name)")
            t.skipStatement()
        }
        error("service \(name) is not closed")
        return s
    }

    private mutating func parseRPC() -> ProtobufSummary.RPC? {
        guard let name = t.ident() else { error("expected an rpc name"); t.skipStatement(); return nil }
        func streamedType(_ t: inout CTokens) -> (String, Bool)? {
            guard t.accept("(") else { return nil }
            var stream = false
            if t.tok.isIdent("stream"), t.ahead.kind == .ident { stream = true; t.advance() }
            guard let type = t.ident(), t.accept(")") else { return nil }
            return (type, stream)
        }
        guard let request = streamedType(&t), t.acceptIdent("returns"), let response = streamedType(&t) else {
            error("rpc \(name) is malformed")
            t.skipStatement()
            return nil
        }
        var deprecated = false
        if t.tok.isSymbol("{") {
            t.advance()
            while !t.atEnd, !t.tok.isSymbol("}") {
                if t.tok.isIdent("option") {
                    t.advance()
                    if let o = parseOptionBody(), o.name == "deprecated", o.value == "true" { deprecated = true }
                    t.skipStatement()
                } else {
                    t.skipStatement()
                }
            }
            t.accept("}")
        } else if !t.accept(";") {
            t.skipStatement()
        }
        return .init(name: name, requestType: request.0, responseType: response.0, clientStreaming: request.1,
                     serverStreaming: response.1, deprecated: deprecated)
    }

    private mutating func parseExtend(scope: String) -> ProtobufSummary.Extension? {
        guard let target = t.ident(), t.tok.isSymbol("{") else { error("an extend block is malformed"); t.skipStatement(); return nil }
        t.advance()
        var holder = ProtobufSummary.Message(name: target, fullName: scope + target, fields: [], oneofs: [], messages: [],
                                             enums: [], reservedNumbers: [], reservedNames: [], nestingCut: false)
        parseMessageBody(&holder, depth: APISpecReader.maxNesting - 1)
        return .init(target: target, fields: holder.fields)
    }

    // MARK: Summary and checks

    func summary(cut: Bool) -> ProtobufSummary? {
        if recognised == 0, !errors.isEmpty { return nil }
        var warnings = SpecWarnings()
        for e in errors { warnings.add(.caution, e.token.isEmpty ? L.skippedAtEnd(e.line) : L.skippedAt(e.line, SpecText.oneLine(e.token, limit: 40))) }
        if syntax == nil, edition == nil, recognised > 0 {
            warnings.add(.caution, L.noSyntaxLine)
        }
        var required: [String] = []
        func check(_ m: ProtobufSummary.Message, _ w: inout SpecWarnings) {
            var byNumber: [Int: [String]] = [:]
            let ranges = m.reservedNumbers.compactMap(ProtoParser.range)
            for f in m.fields {
                guard let n = f.number else { continue }
                byNumber[n, default: []].append(f.name)
                if n < 1 || n > ProtobufReader.maxFieldNumber {
                    w.add(.danger, L.numberOutOfRange("\(m.name).\(f.name)", String(n), String(ProtobufReader.maxFieldNumber)))
                } else if (19_000...19_999).contains(n) {
                    w.add(.danger, L.numberInImplementationRange("\(m.name).\(f.name)", String(n)))
                }
                if ranges.contains(where: { $0.contains(n) }) {
                    w.add(.danger, L.reservedNumberUsed("\(m.name).\(f.name)", String(n)))
                }
                if m.reservedNames.contains(f.name) {
                    w.add(.danger, L.reservedNameUsed("\(m.name).\(f.name)"))
                }
                if f.label == .required, required.count < 1_000 { required.append("\(m.name).\(f.name)") }
            }
            for (n, names) in byNumber.sorted(by: { $0.key < $1.key }) where names.count > 1 {
                w.add(.danger, L.duplicateFieldNumber(m.name, String(n), names.joined(separator: ", ")))
            }
            for e in m.enums { checkEnum(e, &w) }
            for nested in m.messages { check(nested, &w) }
        }
        func checkEnum(_ e: ProtobufSummary.Enumeration, _ w: inout SpecWarnings) {
            if syntax == "proto3", let first = e.values.first, first.number != 0 {
                w.add(.danger, L.enumFirstNotZero(e.name, "\(first.name) = \(first.number.map(String.init) ?? "?")"))
            }
            if !e.allowAlias {
                var seen: [Int: String] = [:]
                for v in e.values {
                    guard let n = v.number else { continue }
                    if let other = seen[n] {
                        w.add(.danger, L.enumDuplicateNumber(e.name, other, v.name, String(n)))
                    } else { seen[n] = v.name }
                }
            }
        }
        for m in messages { check(m, &warnings) }
        for e in enums { checkEnum(e, &warnings) }
        if !required.isEmpty {
            warnings.add(.caution, L.requiredFields(required.count, SpecText.examples(required)))
        }
        let deprecatedRPCs = services.flatMap { s in s.rpcs.filter(\.deprecated).map { "\(s.name).\($0.name)" } }
        if !deprecatedRPCs.isEmpty {
            warnings.add(.caution, L.deprecatedRPCs(deprecatedRPCs.count, SpecText.examples(deprecatedRPCs)))
        }
        if t.endedInside { warnings.add(.caution, L.endsInsideString) }

        return ProtobufSummary(syntax: syntax, edition: edition, package: package, imports: imports, options: options,
                               messages: messages, enums: enums, services: services, extensions: extensions,
                               messageCount: counts.messages, enumCount: counts.enums, fieldCount: counts.fields,
                               rpcCount: counts.rpcs, warnings: warnings.list,
                               truncated: truncated || cut || t.endedInside)
    }

    /// "5", "9 to 11", "100 to max" as a closed range.
    static func range(_ text: String) -> ClosedRange<Int>? {
        let parts = text.split(separator: " ")
        guard let lo = parts.first.flatMap({ integer(String($0)) }) else { return nil }
        if parts.count == 3, parts[1] == "to" {
            let hi = parts[2] == "max" ? ProtobufReader.maxFieldNumber : integer(String(parts[2]))
            guard let hi, hi >= lo else { return nil }
            return lo...hi
        }
        return lo...lo
    }
}
