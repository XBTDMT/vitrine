import Foundation

/// Collects Avro named types and the checks over them, shared by the JSON and IDL readers. roadmap: S-22
struct AvroCollector {
    static let primitives: Set<String> = ["null", "boolean", "int", "long", "float", "double", "bytes", "string"]

    var namedTypes: [AvroSummary.NamedType] = []
    var definedFullNames: [String: Int] = [:]
    /// (full name as it would resolve, short name, where it is used).
    var references: [(full: String, short: String, usedIn: String)] = []
    var warnings = SpecWarnings()
    var truncated = false

    mutating func define(_ type: AvroSummary.NamedType) {
        definedFullNames[type.fullName, default: 0] += 1
        appendCapped(&namedTypes, type, &truncated)
    }

    mutating func reference(_ name: String, namespace: String?, usedIn: String) {
        guard references.count < 10_000 else { return }
        let full = name.contains(".") ? name : (namespace.map { "\($0).\(name)" } ?? name)
        references.append((full, name, usedIn))
    }

    mutating func checkRecord(_ type: AvroSummary.NamedType) {
        var names: [String: Int] = [:]
        for f in type.fields { names[f.name, default: 0] += 1 }
        let twice = names.filter { $0.value > 1 }.keys.sorted()
        if !twice.isEmpty {
            warnings.add(.danger, L.duplicateFieldNames(type.name, SpecText.examples(twice)))
        }
    }

    /// Union defaults must match the union's first branch.
    mutating func checkUnionDefault(field: String, record: String, branches: [String], defaultValue: String?) {
        guard let first = branches.first, let d = defaultValue else { return }
        if d == "null", first != "null" {
            warnings.add(.caution, L.nullDefaultNotFirst("\(record).\(field)", branches.joined(separator: " | ")))
        } else if d != "null", first == "null" {
            warnings.add(.caution, L.defaultButNullFirst("\(record).\(field)"))
        }
    }

    mutating func finish() {
        let shortNames = Set(namedTypes.map(\.name))
        var missing: [String] = []
        for r in references where definedFullNames[r.full] == nil && definedFullNames[r.short] == nil && !shortNames.contains(r.short) {
            let label = r.short
            if !missing.contains(label), missing.count < 100 { missing.append(label) }
        }
        if !missing.isEmpty {
            warnings.add(.caution, L.undefinedTypes(missing.count, SpecText.examples(missing)))
        }
        let twice = definedFullNames.filter { $0.value > 1 }.keys.sorted()
        if !twice.isEmpty {
            warnings.add(.danger, L.avroDefinedTwice(SpecText.examples(twice)))
        }
    }
}

// MARK: - JSON (.avsc, .avpr)

/// Avro schemas and protocols written as JSON, already parsed by VitrineData. Types are rendered by a recursion
/// bounded at `APISpecReader.maxNesting`. roadmap: S-22
enum AvroJSONReader {
    static func read(_ doc: SpecDocument.Parsed, isProtocolFile: Bool) -> AvroSummary? {
        let root = doc.root
        var c = AvroCollector()
        if let error = doc.syntaxError {
            c.warnings.add(.caution, L.syntaxError(error))
        }
        var summary: AvroSummary
        if root.isObject, let proto = root["protocol"]?.string {
            let ns = root["namespace"]?.string
            for t in root["types"]?.children ?? [] {
                _ = render(t, namespace: ns, depth: 0, enclosing: nil, usedIn: proto, collector: &c)
            }
            var messages: [AvroSummary.Message] = []
            for m in root["messages"]?.children ?? [] where m.isObject {
                var params: [AvroSummary.Field] = []
                for p in m["request"]?.children ?? [] {
                    appendCapped(&params, field(p, namespace: ns, record: m.name ?? "", collector: &c), &c.truncated)
                }
                let response = m["response"].map { render($0, namespace: ns, depth: 0, enclosing: nil, usedIn: m.name ?? "", collector: &c) } ?? "null"
                let errors = (m["errors"]?.children ?? []).compactMap(\.scalar)
                for e in errors { c.reference(e, namespace: ns, usedIn: m.name ?? "") }
                appendCapped(&messages, .init(name: m.name ?? "", parameters: params, response: response, errors: errors,
                                              oneWay: m["one-way"]?.isTrue ?? false), &c.truncated)
            }
            c.finish()
            summary = AvroSummary(source: .protocolJSON, protocolName: proto, namespace: ns,
                                  doc: SpecText.oneLineOrNil(root["doc"]?.scalar), rootType: "protocol \(proto)",
                                  namedTypes: c.namedTypes, messages: messages, imports: [], warnings: [], truncated: false)
        } else {
            if isProtocolFile { return nil }
            let rootType = render(root, namespace: nil, depth: 0, enclosing: nil, usedIn: "the root", collector: &c)
            guard !rootType.isEmpty else { return nil }
            c.finish()
            let first = c.namedTypes.first
            let rootIsNamed = ["record", "error", "enum", "fixed"].contains(root["type"]?.string ?? "")
            let kindWord = rootIsNamed ? (first.map { $0.kind.rawValue + " " } ?? "") : ""
            summary = AvroSummary(source: .schema, protocolName: nil, namespace: rootIsNamed ? first?.namespace : nil,
                                  doc: rootIsNamed ? first?.doc : nil, rootType: kindWord + rootType,
                                  namedTypes: c.namedTypes, messages: [], imports: [], warnings: [], truncated: false)
        }
        summary.warnings = c.warnings.list
        summary.truncated = c.truncated || doc.partial
        return summary
    }

    /// A type as text; named types are registered on the way.
    static func render(_ node: SpecNode, namespace: String?, depth: Int, enclosing: String?, usedIn: String,
                       collector c: inout AvroCollector) -> String {
        guard depth < APISpecReader.maxNesting else { c.truncated = true; return "…" }
        if let name = node.string {
            if !AvroCollector.primitives.contains(name) { c.reference(name, namespace: namespace, usedIn: usedIn) }
            return name
        }
        if node.isArray {
            return node.children.prefix(64).map { render($0, namespace: namespace, depth: depth + 1, enclosing: enclosing, usedIn: usedIn, collector: &c) }
                .joined(separator: " | ")
        }
        guard node.isObject else { return "" }
        let typeNode = node["type"]
        let type = typeNode?.string ?? ""
        switch type {
        case "record", "error", "enum", "fixed":
            var name = node["name"]?.string ?? ""
            var ns = node["namespace"]?.string ?? namespace
            if let dot = name.lastIndex(of: ".") {
                ns = String(name[..<dot])
                name = String(name[name.index(after: dot)...])
            }
            if name.isEmpty {
                c.warnings.add(.danger, L.unnamedType(type))
                name = L.unnamed
            }
            let kind: AvroSummary.NamedType.Kind = type == "record" ? .record : type == "error" ? .error : type == "enum" ? .enumeration : .fixed
            var named = AvroSummary.NamedType(kind: kind, name: name, namespace: ns?.isEmpty == true ? nil : ns,
                                              doc: SpecText.oneLineOrNil(node["doc"]?.scalar), fields: [], symbols: [],
                                              size: nil, aliases: Array((node["aliases"]?.strings ?? []).prefix(50)),
                                              definedIn: enclosing)
            switch kind {
            case .record, .error:
                // Register the name first so a recursive reference resolves, then fill the fields.
                let slot = c.namedTypes.count
                c.define(named)
                for f in node["fields"]?.children ?? [] {
                    appendCapped(&named.fields, field(f, namespace: named.namespace, record: named.name, depth: depth + 1,
                                                       enclosing: named.fullName, collector: &c), &c.truncated)
                }
                if slot < c.namedTypes.count { c.namedTypes[slot] = named }
                c.checkRecord(named)
            case .enumeration:
                named.symbols = []
                for s in node["symbols"]?.children ?? [] { if let v = s.scalar { appendCapped(&named.symbols, v, &c.truncated) } }
                if let d = node["default"]?.string, !named.symbols.contains(d) {
                    c.warnings.add(.danger, L.enumDefaultNotSymbol(name, d))
                }
                c.define(named)
            case .fixed:
                named.size = node["size"]?.scalar.flatMap { Int($0) }
                c.define(named)
            }
            let base = named.fullName
            if let logical = node["logicalType"]?.string { return "\(logicalLabel(logical, node)) (\(base))" }
            return base
        case "array":
            let items = node["items"].map { render($0, namespace: namespace, depth: depth + 1, enclosing: enclosing, usedIn: usedIn, collector: &c) } ?? "?"
            return "array<\(items)>"
        case "map":
            let values = node["values"].map { render($0, namespace: namespace, depth: depth + 1, enclosing: enclosing, usedIn: usedIn, collector: &c) } ?? "?"
            return "map<\(values)>"
        default:
            // A primitive (or a reference) written as an object, possibly with a logical type; or a nested type object.
            var base: String
            if let typeNode, !typeNode.isNull, typeNode.string == nil {
                base = render(typeNode, namespace: namespace, depth: depth + 1, enclosing: enclosing, usedIn: usedIn, collector: &c)
            } else {
                base = type
                if !type.isEmpty, !AvroCollector.primitives.contains(type) { c.reference(type, namespace: namespace, usedIn: usedIn) }
            }
            if base.isEmpty { base = "?" }
            if let logical = node["logicalType"]?.string { return "\(logicalLabel(logical, node)) (\(base))" }
            return base
        }
    }

    static func logicalLabel(_ logical: String, _ node: SpecNode) -> String {
        if logical == "decimal" {
            let p = node["precision"]?.scalar ?? "?"
            let s = node["scale"]?.scalar ?? "0"
            return "decimal(\(p),\(s))"
        }
        return logical
    }

    static func field(_ f: SpecNode, namespace: String?, record: String, depth: Int = 1, enclosing: String? = nil,
                      collector c: inout AvroCollector) -> AvroSummary.Field {
        let name = f["name"]?.scalar ?? L.unnamed
        let typeNode = f["type"]
        let type = typeNode.map { render($0, namespace: namespace, depth: depth, enclosing: enclosing, usedIn: record, collector: &c) } ?? "?"
        let defaultValue = f["default"]?.displayValue()
        var optional = false
        var logical: String?
        if let typeNode, typeNode.isArray {
            let branches = typeNode.children.map { $0.string ?? ($0["type"]?.string ?? "complex") }
            optional = branches.contains("null")
            c.checkUnionDefault(field: name, record: record, branches: branches, defaultValue: defaultValue)
        }
        if let typeNode, typeNode.isObject { logical = typeNode["logicalType"]?.string }
        return .init(name: name, type: type, doc: SpecText.oneLineOrNil(f["doc"]?.scalar), defaultValue: defaultValue,
                     optional: optional, logicalType: logical)
    }
}

// MARK: - IDL (.avdl)

/// Avro IDL, best effort: `protocol` blocks and the newer `namespace …; schema …;` form, records, errors, enums,
/// fixed types, fields with `union { … }`, `array<…>`, `map<…>`, `T?`, logical type keywords and `decimal(p, s)`,
/// annotations (`@namespace`, `@logicalType`, `@aliases` read; others skipped), `/** … */` docs, defaults and
/// messages. Anything it does not follow is skipped to the next `;` or block with a warning. roadmap: S-22
enum AvroIDLReader {
    static let logicalKeywords: [String: String] = [
        "date": "date (int)", "time_ms": "time-millis (int)", "timestamp_ms": "timestamp-millis (long)",
        "local_timestamp_ms": "local-timestamp-millis (long)", "uuid": "uuid (string)",
    ]

    static func read(_ bytes: [UInt8], cut: Bool) -> AvroSummary? {
        var p = AvroIDLParser(bytes)
        p.parse()
        return p.summary(cut: cut)
    }
}

/// The Avro IDL parser over `CTokens`. Each loop consumes a token or stops at `}` / the end. roadmap: S-22
struct AvroIDLParser {
    private var t: CTokens
    private var c = AvroCollector()
    private var protocolName: String?
    private var namespace: String?
    private var protocolDoc: String?
    private var mainSchema: String?
    private var imports: [String] = []
    private var messages: [AvroSummary.Message] = []
    /// Where reading failed: the line, the token there and a note for debugging.
    private var errors: [(line: Int, token: String, message: String)] = []
    private var recognised = 0

    init(_ bytes: [UInt8]) { t = CTokens(bytes) }

    private mutating func error(_ message: String) {
        if errors.count < 5 { errors.append((t.tok.line, t.tok.text, message)) }
    }

    /// Annotations before a declaration: the ones the summary uses, the rest skipped.
    private mutating func annotations() -> [String: String] {
        var found: [String: String] = [:]
        while t.tok.isSymbol("@") {
            t.advance()
            guard let name = t.ident() else { break }
            var value = ""
            if t.tok.isSymbol("(") {
                t.advance()
                var depth = 1
                while !t.atEnd {
                    if t.tok.isSymbol("(") || t.tok.isSymbol("[") || t.tok.isSymbol("{") { depth += 1 }
                    if t.tok.isSymbol(")") || t.tok.isSymbol("]") || t.tok.isSymbol("}") { depth -= 1 }
                    if depth == 0 { t.advance(); break }
                    if value.count < 200 { value += t.tok.kind == .string ? t.tok.text : (t.tok.isSymbol(",") ? ", " : t.tok.text) }
                    t.advance()
                }
            }
            found[name] = value
        }
        return found
    }

    mutating func parse() {
        while !t.atEnd {
            let doc = t.tok.doc
            let notes = annotations()
            if t.tok.isSymbol(";") { t.advance(); continue }
            if t.tok.isSymbol("}") { t.advance(); continue }
            if t.tok.isIdent("protocol") {
                t.advance()
                protocolName = t.ident()
                protocolDoc = doc
                if let ns = notes["namespace"], !ns.isEmpty { namespace = ns }
                recognised += 1
                guard t.accept("{") else { error("expected { after protocol"); t.skipStatement(); continue }
                parseBody(inProtocol: true)
                continue
            }
            if t.tok.isIdent("namespace") {
                t.advance()
                namespace = t.ident()
                recognised += 1
                t.skipStatement()
                continue
            }
            if t.tok.isIdent("schema") {
                t.advance()
                mainSchema = parseType(usedIn: "schema")
                recognised += 1
                t.skipStatement()
                continue
            }
            if !parseDeclaration(doc: doc, notes: notes, inProtocol: false) {
                error("unexpected “\(t.tok.text)”")
                t.skipStatement()
            }
        }
    }

    /// The members of a protocol, up to and including its `}`.
    private mutating func parseBody(inProtocol: Bool) {
        while !t.atEnd {
            if t.tok.isSymbol("}") { t.advance(); return }
            if t.tok.isSymbol(";") { t.advance(); continue }
            let doc = t.tok.doc
            let notes = annotations()
            if t.tok.isSymbol("}") { t.advance(); return }
            if !parseDeclaration(doc: doc, notes: notes, inProtocol: inProtocol) {
                if inProtocol, parseMessage(doc: doc) { continue }
                error("unexpected “\(t.tok.text)”")
                t.skipStatement()
            }
        }
        error("the protocol is not closed")
    }

    /// import / record / error / enum / fixed; false when the next tokens are none of these.
    private mutating func parseDeclaration(doc: String?, notes: [String: String], inProtocol: Bool) -> Bool {
        guard t.tok.kind == .ident else { return false }
        let ns = notes["namespace"].flatMap { $0.isEmpty ? nil : $0 } ?? namespace
        let aliases = notes["aliases"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        switch t.tok.text {
        case "import" where t.ahead.kind == .ident:
            t.advance(); t.advance()
            if t.tok.kind == .string { appendCapped(&imports, t.tok.text, &c.truncated); t.advance() }
            t.skipStatement()
            recognised += 1
            return true
        case "record", "error":
            guard t.ahead.kind == .ident else { return false }
            let kind: AvroSummary.NamedType.Kind = t.tok.text == "record" ? .record : .error
            t.advance()
            let name = t.ident() ?? L.unnamed
            var named = AvroSummary.NamedType(kind: kind, name: name, namespace: ns, doc: doc, fields: [], symbols: [],
                                              size: nil, aliases: aliases, definedIn: nil)
            guard t.accept("{") else { error("expected { after \(name)"); t.skipStatement(); return true }
            let slot = c.namedTypes.count
            c.define(named)
            while !t.atEnd, !t.tok.isSymbol("}") {
                if t.tok.isSymbol(";") { t.advance(); continue }
                for f in parseFields(record: name) { appendCapped(&named.fields, f, &c.truncated) }
            }
            t.accept("}")
            if slot < c.namedTypes.count { c.namedTypes[slot] = named }
            c.checkRecord(named)
            recognised += 1
            return true
        case "enum":
            guard t.ahead.kind == .ident else { return false }
            t.advance()
            let name = t.ident() ?? L.unnamed
            var named = AvroSummary.NamedType(kind: .enumeration, name: name, namespace: ns, doc: doc, fields: [],
                                              symbols: [], size: nil, aliases: aliases, definedIn: nil)
            guard t.accept("{") else { error("expected { after \(name)"); t.skipStatement(); return true }
            while !t.atEnd, !t.tok.isSymbol("}") {
                if let s = t.ident() { appendCapped(&named.symbols, s, &c.truncated) } else { t.advance() }
            }
            t.accept("}")
            if t.accept("="), let d = t.ident(), !named.symbols.contains(d) {
                c.warnings.add(.danger, L.enumDefaultNotSymbol(name, d))
            }
            t.accept(";")
            c.define(named)
            recognised += 1
            return true
        case "fixed":
            guard t.ahead.kind == .ident else { return false }
            t.advance()
            let name = t.ident() ?? L.unnamed
            var size: Int?
            if t.accept("("), t.tok.kind == .number { size = Int(t.tok.text); t.advance(); t.accept(")") }
            c.define(.init(kind: .fixed, name: name, namespace: ns, doc: doc, fields: [], symbols: [], size: size,
                           aliases: aliases, definedIn: nil))
            t.skipStatement()
            recognised += 1
            return true
        default:
            return false
        }
    }

    /// `type name (= default)? (, name (= default)?)* ;` — one or more fields.
    private mutating func parseFields(record: String) -> [AvroSummary.Field] {
        let doc = t.tok.doc
        let typeNotes = annotations()
        guard t.tok.kind == .ident else { error("expected a field in \(record)"); t.skipStatement(); return [] }
        let type = parseType(usedIn: record, notes: typeNotes, depth: 0)
        var fields: [AvroSummary.Field] = []
        repeat {
            let fieldDoc = t.tok.doc ?? doc
            _ = annotations()
            guard let name = t.ident() else { error("expected a field name in \(record)"); t.skipStatement(); return fields }
            var defaultValue: String?
            if t.accept("=") { defaultValue = jsonValue() }
            let branches = type.branches
            if !branches.isEmpty { c.checkUnionDefault(field: name, record: record, branches: branches, defaultValue: defaultValue) }
            fields.append(.init(name: name, type: type.text, doc: fieldDoc, defaultValue: defaultValue,
                                optional: type.optional, logicalType: type.logical))
        } while t.accept(",")
        if !t.accept(";") { t.skipStatement() }
        return fields
    }

    struct IDLType {
        var text: String
        var optional = false
        var logical: String?
        /// A union's branches in order (`T?` is `null | T`), for the default check.
        var branches: [String] = []
    }

    private mutating func parseType(usedIn: String, notes: [String: String] = [:]) -> String {
        parseType(usedIn: usedIn, notes: notes, depth: 0).text
    }

    private mutating func parseType(usedIn: String, notes: [String: String], depth: Int) -> IDLType {
        guard depth < APISpecReader.maxNesting else { c.truncated = true; t.skipStatement(); return IDLType(text: "…") }
        var result: IDLType
        if t.acceptIdent("union") {
            var parts: [IDLType] = []
            if t.accept("{") {
                while !t.atEnd, !t.tok.isSymbol("}") {
                    let n = annotations()
                    parts.append(parseType(usedIn: usedIn, notes: n, depth: depth + 1))
                    if !t.accept(",") { break }
                }
                t.accept("}")
            }
            let branches = parts.map(\.text)
            result = IDLType(text: branches.joined(separator: " | "), optional: branches.contains("null"), branches: branches)
        } else if t.tok.isIdent("array") || t.tok.isIdent("map"), t.ahead.isSymbol("<") {
            let word = t.tok.text
            t.advance(); t.advance()
            let n = annotations()
            let inner = parseType(usedIn: usedIn, notes: n, depth: depth + 1)
            t.accept(">")
            result = IDLType(text: "\(word)<\(inner.text)>")
        } else if t.tok.isIdent("decimal"), t.ahead.isSymbol("(") {
            t.advance(); t.advance()
            var args: [String] = []
            while !t.atEnd, !t.tok.isSymbol(")") { if t.tok.kind == .number { args.append(t.tok.text) }; t.advance() }
            t.accept(")")
            result = IDLType(text: "decimal(\(args.joined(separator: ","))) (bytes)", logical: "decimal")
        } else if let name = t.ident() {
            if let logical = AvroIDLReader.logicalKeywords[name] {
                result = IDLType(text: logical, logical: String(logical.prefix { $0 != " " }))
            } else {
                if name != "void", !AvroCollector.primitives.contains(name) { c.reference(name, namespace: namespace, usedIn: usedIn) }
                result = IDLType(text: name)
                if let logical = notes["logicalType"], !logical.isEmpty {
                    result = IDLType(text: "\(logical) (\(name))", logical: logical)
                }
            }
        } else {
            error("expected a type in \(usedIn)")
            result = IDLType(text: "?")
        }
        if t.accept("?") {
            result = IDLType(text: "null | \(result.text)", optional: true, logical: result.logical, branches: ["null", result.text])
        }
        return result
    }

    /// A JSON default, as written: a scalar, or `[…]` / `{…}` (read by counting brackets).
    private mutating func jsonValue() -> String {
        if t.tok.isSymbol("[") || t.tok.isSymbol("{") {
            let empty = t.ahead.isSymbol(t.tok.isSymbol("[") ? "]" : "}")
            let open = t.tok.text
            t.skipGroup(open, open == "[" ? "]" : "}")
            return empty ? (open == "[" ? "[]" : "{}") : (open == "[" ? "[…]" : "{…}")
        }
        var s = ""
        if t.tok.isSymbol("-") { s = "-"; t.advance() }
        switch t.tok.kind {
        case .string: s = "\"\(SpecText.oneLine(t.tok.text, limit: 120))\""; t.advance()
        case .number, .ident: s += t.tok.text; t.advance()
        default: break
        }
        return s
    }

    /// `ResponseType name(ParamType p, …) (throws E, …)? oneway? ;`
    private mutating func parseMessage(doc: String?) -> Bool {
        guard t.tok.kind == .ident else { return false }
        let response = parseType(usedIn: "a message")
        guard let name = t.ident(), t.accept("(") else { error("a message is malformed"); t.skipStatement(); return true }
        var params: [AvroSummary.Field] = []
        while !t.atEnd, !t.tok.isSymbol(")") {
            let n = annotations()
            let type = parseType(usedIn: name, notes: n, depth: 0)
            guard let pname = t.ident() else { break }
            var defaultValue: String?
            if t.accept("=") { defaultValue = jsonValue() }
            appendCapped(&params, .init(name: pname, type: type.text, doc: nil, defaultValue: defaultValue,
                                        optional: type.optional, logicalType: type.logical), &c.truncated)
            if !t.accept(",") { break }
        }
        if !t.accept(")") { t.skipStatement(); return true }
        var errorsThrown: [String] = []
        var oneWay = false
        if t.acceptIdent("throws") {
            repeat {
                if let e = t.ident() { errorsThrown.append(e); c.reference(e, namespace: namespace, usedIn: name) }
            } while t.accept(",")
        }
        if t.acceptIdent("oneway") { oneWay = true }
        if !t.accept(";") { t.skipStatement() }
        appendCapped(&messages, .init(name: name, parameters: params, response: response, errors: errorsThrown, oneWay: oneWay), &c.truncated)
        recognised += 1
        return true
    }

    mutating func summary(cut: Bool) -> AvroSummary? {
        if recognised == 0 { return nil }
        for e in errors { c.warnings.add(.caution, e.token.isEmpty ? L.skippedAtEnd(e.line) : L.skippedAt(e.line, SpecText.oneLine(e.token, limit: 40))) }
        if !errors.isEmpty { c.warnings.add(.caution, L.idlBestEffort) }
        if t.endedInside { c.warnings.add(.caution, L.endsInsideString) }
        c.finish()
        let root: String
        if let protocolName { root = "protocol \(protocolName)" }
        else if let mainSchema { root = mainSchema }
        else if let first = c.namedTypes.first { root = "\(first.kind.rawValue) \(first.fullName)" }
        else { root = "IDL" }
        return AvroSummary(source: .idl, protocolName: protocolName, namespace: namespace, doc: protocolDoc,
                           rootType: root, namedTypes: c.namedTypes, messages: messages, imports: imports,
                           warnings: c.warnings.list, truncated: c.truncated || cut || t.endedInside)
    }
}
