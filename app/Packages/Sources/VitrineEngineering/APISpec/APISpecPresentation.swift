import Foundation

/// Builds the flat outline with its row cap. roadmap: S-22
struct OutlineBuilder {
    private(set) var items: [APISpecOutlineItem] = []
    private(set) var truncated = false

    mutating func add(_ depth: Int, _ title: String, _ detail: String? = nil, deprecated: Bool = false) {
        guard items.count < APISpecReader.maxListItems else { truncated = true; return }
        items.append(APISpecOutlineItem(depth: depth, title: title, detail: detail.flatMap { $0.isEmpty ? nil : $0 }, deprecated: deprecated))
    }

    var full: Bool { items.count >= APISpecReader.maxListItems }
}

extension APISpec {
    /// The headline, facts, outline and warnings a docs-style card draws for this spec. roadmap: S-22
    public var presentation: APISpecPresentation {
        var o = OutlineBuilder()
        let headline: String
        var facts: [APISpecFact] = []
        switch self {
        case .openAPI(let s):
            headline = [s.title ?? (s.dialect == .swagger2 ? L.swaggerDocument : L.openAPIDocument), s.apiVersion]
                .compactMap { $0 }.joined(separator: " ")
            facts.append(.init(L.format, (s.dialect == .swagger2 ? "Swagger " : "OpenAPI ") + s.specVersion))
            if let v = s.apiVersion { facts.append(.init(L.apiVersion, v)) }
            if let first = s.servers.first {
                facts.append(.init(L.servers, s.servers.count == 1 ? first.url : L.firstAndMore(first.url, s.servers.count - 1)))
            }
            facts.append(.init(L.operations, "\(s.operationCount)"))
            facts.append(.init(L.paths, "\(s.pathCount)"))
            if s.schemaCount > 0 { facts.append(.init(L.schemas, "\(s.schemaCount)")) }
            if !s.securitySchemes.isEmpty {
                facts.append(.init(L.security, s.securitySchemes.map { "\($0.name) (\([$0.type, $0.detail].compactMap { $0 }.joined(separator: " ")))" }
                    .joined(separator: ", ")))
            }
            if s.deprecatedCount > 0 { facts.append(.init(L.deprecated, "\(s.deprecatedCount)")) }
            if s.webhookCount > 0 { facts.append(.init(L.webhooks, "\(s.webhookCount)")) }
            for group in s.tagGroups {
                o.add(0, group.name ?? L.untagged, L.operationCount(group.operationIndices.count))
                for k in group.operationIndices where k < s.operations.count {
                    let op = s.operations[k]
                    o.add(1, "\(op.method) \(op.path)", op.summary ?? op.operationId, deprecated: op.deprecated)
                }
            }

        case .graphQL(let s):
            let typeTotal = s.typeCounts.values.reduce(0, +)
            switch s.documentKind {
            case .schema, .mixed: headline = L.graphQLSchema(typeTotal)
            case .operations: headline = L.graphQLOperations(s.operations.count)
            case .empty: headline = L.graphQLDocument
            }
            for kind in GraphQLSummary.TypeKind.allCases {
                if let n = s.typeCounts[kind], n > 0 { facts.append(.init(Self.kindLabel(kind), "\(n)")) }
            }
            if s.queryType != nil { facts.append(.init(L.queryFields, "\(s.queryFields.count)")) }
            if s.mutationType != nil { facts.append(.init(L.mutationFields, "\(s.mutationFields.count)")) }
            if s.subscriptionType != nil { facts.append(.init(L.subscriptionFields, "\(s.subscriptionFields.count)")) }
            if !s.directives.isEmpty { facts.append(.init(L.directives, "\(s.directives.count)")) }
            if !s.deprecated.isEmpty { facts.append(.init(L.deprecated, "\(s.deprecated.count)")) }
            if !s.operations.isEmpty { facts.append(.init(L.operations, "\(s.operations.count)")) }
            if !s.fragments.isEmpty { facts.append(.init(L.fragments, "\(s.fragments.count)")) }
            let roots: [(String?, [GraphQLSummary.Field])] = [(s.queryType, s.queryFields), (s.mutationType, s.mutationFields),
                                                              (s.subscriptionType, s.subscriptionFields)]
            for (name, fields) in roots {
                guard let name else { continue }
                o.add(0, name, L.fieldCount(fields.count))
                for f in fields { o.add(1, f.signature, f.description, deprecated: f.deprecated) }
            }
            let rootNames = Set([s.queryType, s.mutationType, s.subscriptionType].compactMap { $0 })
            for t in s.types where !(rootNames.contains(t.name) && t.kind == .object) {
                let title = (t.isExtension ? "extend " : "") + "\(t.kind.rawValue) \(t.name)"
                let detail: String
                switch t.kind {
                case .enumeration: detail = L.valueCount(t.enumValues.count)
                case .union: detail = t.unionMembers.joined(separator: " | ")
                case .scalar: detail = t.description ?? ""
                default: detail = L.fieldCount(t.fields.count)
                }
                o.add(0, title, detail)
                for f in t.fields { o.add(1, f.signature, f.description, deprecated: f.deprecated) }
                for v in t.enumValues { o.add(1, v.name, v.description, deprecated: v.deprecated) }
                if o.full { break }
            }
            for d in s.directives {
                o.add(0, "directive @\(d.name)", d.locations.joined(separator: " | "))
            }
            for op in s.operations {
                o.add(0, "\(op.kind.rawValue) \(op.name ?? L.anonymous)", op.variables.map(\.signature).joined(separator: ", "))
            }
            for f in s.fragments { o.add(0, "fragment \(f.name)", "on \(f.typeCondition)") }

        case .protobuf(let s):
            let syntax = s.edition.map { "edition \($0)" } ?? s.syntax ?? "proto2"
            headline = (s.package ?? L.protocolBuffers) + " (\(syntax))"
            facts.append(.init(L.syntax, syntax))
            if let p = s.package { facts.append(.init(L.package, p)) }
            if !s.imports.isEmpty { facts.append(.init(L.imports, "\(s.imports.count)")) }
            facts.append(.init(L.messages, "\(s.messageCount)"))
            if s.enumCount > 0 { facts.append(.init(L.enums, "\(s.enumCount)")) }
            if !s.services.isEmpty { facts.append(.init(L.services, "\(s.services.count)")) }
            if s.rpcCount > 0 { facts.append(.init(L.rpcs, "\(s.rpcCount)")) }
            for svc in s.services {
                o.add(0, "service \(svc.name)", L.rpcCount(svc.rpcs.count))
                for r in svc.rpcs { o.add(1, r.signature, nil, deprecated: r.deprecated) }
            }
            func message(_ m: ProtobufSummary.Message, _ depth: Int, _ o: inout OutlineBuilder) {
                o.add(depth, "message \(m.name)", L.fieldCount(m.fields.count))
                for f in m.fields {
                    let label = f.label == .none ? "" : f.label.rawValue + " "
                    o.add(depth + 1, "\(label)\(f.type) \(f.name)\(f.number.map { " = \($0)" } ?? "")",
                          f.oneof.map { "oneof \($0)" }, deprecated: f.deprecated)
                }
                for e in m.enums { enumeration(e, depth + 1, &o) }
                for n in m.messages where depth < 8 && !o.full { message(n, depth + 1, &o) }
            }
            func enumeration(_ e: ProtobufSummary.Enumeration, _ depth: Int, _ o: inout OutlineBuilder) {
                o.add(depth, "enum \(e.name)", L.valueCount(e.values.count))
                for v in e.values { o.add(depth + 1, "\(v.name)\(v.number.map { " = \($0)" } ?? "")", nil, deprecated: v.deprecated) }
            }
            for m in s.messages where !o.full { message(m, 0, &o) }
            for e in s.enums where !o.full { enumeration(e, 0, &o) }
            for x in s.extensions {
                o.add(0, "extend \(x.target)", L.fieldCount(x.fields.count))
                for f in x.fields { o.add(1, "\(f.type) \(f.name)\(f.number.map { " = \($0)" } ?? "")") }
            }

        case .jsonSchema(let s):
            headline = s.title ?? s.id ?? L.jsonSchema
            if let d = s.draft { facts.append(.init(L.draft, d)) }
            if !s.rootTypes.isEmpty { facts.append(.init(L.type, s.rootTypes.joined(separator: " | "))) }
            facts.append(.init(L.properties, "\(s.properties.count)"))
            let required = s.properties.filter(\.required).count
            if required > 0 { facts.append(.init(L.required, "\(required)")) }
            if s.definitionCount > 0 { facts.append(.init(L.definitions, "\(s.definitionCount)")) }
            if !s.refs.isEmpty { facts.append(.init(L.references, "\(s.refs.count)")) }
            if !s.rootCombinators.isEmpty { facts.append(.init(L.combines, s.rootCombinators.joined(separator: ", "))) }
            func property(_ p: JSONSchemaSummary.Property, _ depth: Int, _ o: inout OutlineBuilder) {
                var parts: [String] = []
                if !p.types.isEmpty { parts.append(p.types.joined(separator: " | ")) }
                if let r = p.ref { parts.append("→ \(JSONSchemaReader.refName(r))") }
                if p.required { parts.append(L.requiredMark) }
                if let f = p.format { parts.append(f) }
                if !p.enumValues.isEmpty { parts.append(SpecText.oneLine(p.enumValues.joined(separator: ", "), limit: 80)) }
                parts += p.combinators
                o.add(depth, p.name, parts.joined(separator: " · "), deprecated: p.deprecated)
                for c in p.children where !o.full { property(c, depth + 1, &o) }
            }
            for p in s.properties where !o.full { property(p, 0, &o) }
            if !s.definitionNames.isEmpty {
                o.add(0, L.definitions, "\(s.definitionCount)")
                for d in s.definitionNames { o.add(1, d) }
            }

        case .avro(let s):
            headline = s.rootType
            facts.append(.init(L.source, s.source == .idl ? L.avroIDL : s.source == .protocolJSON ? L.avroProtocol : L.avroSchema))
            if let ns = s.namespace { facts.append(.init(L.namespace, ns)) }
            let records = s.namedTypes.filter { $0.kind == .record || $0.kind == .error }.count
            if records > 0 { facts.append(.init(L.records, "\(records)")) }
            let enums = s.namedTypes.filter { $0.kind == .enumeration }.count
            if enums > 0 { facts.append(.init(L.enums, "\(enums)")) }
            let fixed = s.namedTypes.filter { $0.kind == .fixed }.count
            if fixed > 0 { facts.append(.init(L.fixedTypes, "\(fixed)")) }
            facts.append(.init(L.fields, "\(s.namedTypes.reduce(0) { $0 + $1.fields.count })"))
            if !s.messages.isEmpty { facts.append(.init(L.messages, "\(s.messages.count)")) }
            for t in s.namedTypes {
                let detail: String
                switch t.kind {
                case .record, .error: detail = L.fieldCount(t.fields.count)
                case .enumeration: detail = SpecText.oneLine(t.symbols.joined(separator: ", "), limit: 120)
                case .fixed: detail = t.size.map { L.byteCount($0) } ?? ""
                }
                o.add(0, "\(t.kind.rawValue) \(t.fullName)", detail)
                for f in t.fields { o.add(1, "\(f.name): \(f.type)", f.defaultValue.map { "= \($0)" } ?? f.doc) }
                if o.full { break }
            }
            for m in s.messages {
                o.add(0, "\(m.name)(\(m.parameters.map { "\($0.type) \($0.name)" }.joined(separator: ", ")))",
                      (m.oneWay ? L.oneWay : "→ \(m.response)") + (m.errors.isEmpty ? "" : " throws \(m.errors.joined(separator: ", "))"))
            }
        }
        return APISpecPresentation(headline: headline, facts: facts, outline: o.items, outlineTruncated: o.truncated,
                                   warnings: warnings, truncated: truncated)
    }

    static func kindLabel(_ kind: GraphQLSummary.TypeKind) -> String {
        switch kind {
        case .object: L.objectTypes
        case .input: L.inputTypes
        case .enumeration: L.enums
        case .interface: L.interfaces
        case .union: L.unions
        case .scalar: L.scalars
        }
    }
}
