import Foundation

/// OpenAPI 3.0 / 3.1 / 3.2 and Swagger 2.0 documents, JSON or YAML, already parsed by VitrineData. Only what the
/// file states is reported: `$ref`s are not followed and nothing is fetched. roadmap: S-22
enum OpenAPIReader {
    static let methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace", "query"]

    static func read(_ doc: SpecDocument.Parsed) -> OpenAPISummary? {
        let root = doc.root
        guard root.isObject else { return nil }
        let isSwagger = root["openapi"] == nil
        guard let version = (isSwagger ? root["swagger"] : root["openapi"])?.scalar else { return nil }
        var truncated = doc.partial
        var warnings = SpecWarnings()
        if let error = doc.syntaxError {
            warnings.add(.caution, L.syntaxError(error))
        }

        let dialect: OpenAPISummary.Dialect
        if isSwagger { dialect = .swagger2 }
        else if version.hasPrefix("3.0") { dialect = .openAPI30 }
        else if version.hasPrefix("3.1") { dialect = .openAPI31 }
        else if version.hasPrefix("3.2") { dialect = .openAPI32 }
        else { dialect = .otherOpenAPI }

        let info = root["info"]
        let title = SpecText.oneLineOrNil(info?["title"]?.scalar)
        let apiVersion = SpecText.oneLineOrNil(info?["version"]?.scalar, limit: 80)
        let description = SpecText.cap(info?["description"]?.scalar, APISpecReader.maxDescriptionLength)

        // Security schemes.
        var schemes: [OpenAPISummary.SecurityScheme] = []
        let schemeNode = isSwagger ? root["securityDefinitions"] : root["components"]?["securitySchemes"]
        for s in schemeNode?.children ?? [] where s.isObject {
            appendCapped(&schemes, securityScheme(name: s.name ?? "", s), &truncated)
        }

        // Servers.
        var servers: [OpenAPISummary.Server] = []
        if isSwagger {
            let host = root["host"]?.scalar
            let base = root["basePath"]?.scalar ?? ""
            let schemesList = root["schemes"]?.strings ?? []
            if let host {
                for scheme in schemesList.isEmpty ? [""] : schemesList {
                    let url = scheme.isEmpty ? host + base : "\(scheme)://\(host)\(base)"
                    appendCapped(&servers, server(url, description: nil), &truncated)
                }
            } else if !base.isEmpty {
                appendCapped(&servers, server(base, description: nil), &truncated)
            }
        } else {
            for s in root["servers"]?.children ?? [] {
                guard let url = s["url"]?.scalar else { continue }
                appendCapped(&servers, server(url, description: SpecText.oneLineOrNil(s["description"]?.scalar)), &truncated)
            }
        }

        // Security requirements.
        let global = requirement(root["security"])
        var operations: [OpenAPISummary.Operation] = []
        var operationCount = 0
        var pathCount = 0
        for pathItem in root["paths"]?.children ?? [] {
            guard let path = pathItem.name, pathItem.isObject else { continue }
            pathCount += 1
            var entries = pathItem.children.filter { methods.contains(($0.name ?? "").lowercased()) && $0.isObject }
            // OpenAPI 3.2 `additionalOperations`: other methods under their own names.
            if let extra = pathItem["additionalOperations"] { entries += extra.children.filter(\.isObject) }
            for op in entries {
                operationCount += 1
                let own = op["security"].map { requirement($0) }
                let effective = own ?? global
                let operation = OpenAPISummary.Operation(
                    method: (op.name ?? "").uppercased(), path: path,
                    operationId: SpecText.oneLineOrNil(op["operationId"]?.scalar, limit: 200),
                    summary: SpecText.oneLineOrNil(op["summary"]?.scalar),
                    tags: Array(op["tags"]?.strings.prefix(50) ?? []),
                    deprecated: op["deprecated"]?.isTrue ?? false,
                    security: effective.names, declaresSecurity: own != nil,
                    allowsAnonymous: effective.anonymous && !effective.names.isEmpty)
                appendCapped(&operations, operation, &truncated)
            }
        }

        // Tag groups: declared tags in order, then used-only tags, then untagged.
        var order: [String] = []
        var descriptions: [String: String] = [:]
        for t in root["tags"]?.children ?? [] {
            guard let n = t["name"]?.scalar, !order.contains(n) else { continue }
            order.append(n)
            descriptions[n] = SpecText.oneLineOrNil(t["description"]?.scalar)
        }
        var members: [String: [Int]] = [:]
        var untagged: [Int] = []
        for (index, op) in operations.enumerated() {
            if op.tags.isEmpty { untagged.append(index); continue }
            for tag in Set(op.tags) {
                if members[tag] == nil, !order.contains(tag) { order.append(tag) }
                members[tag, default: []].append(index)
            }
        }
        var groups: [OpenAPISummary.TagGroup] = order.compactMap { tag in
            guard let list = members[tag] else { return nil }
            return OpenAPISummary.TagGroup(name: tag, description: descriptions[tag], operationIndices: list.sorted())
        }
        if !untagged.isEmpty { groups.append(OpenAPISummary.TagGroup(name: nil, description: nil, operationIndices: untagged)) }

        // Components.
        var counts: [OpenAPISummary.ComponentCount] = []
        var schemaCount = 0
        if isSwagger {
            for key in ["definitions", "parameters", "responses", "securityDefinitions"] {
                if let n = root[key], n.isObject { counts.append(.init(kind: key, count: n.sourceCount)) }
            }
            schemaCount = root["definitions"]?.sourceCount ?? 0
        } else {
            for c in root["components"]?.children ?? [] where c.isObject {
                appendCapped(&counts, .init(kind: c.name ?? "", count: c.sourceCount), &truncated)
            }
            schemaCount = root["components"]?["schemas"]?.sourceCount ?? 0
        }
        let webhooks = root["webhooks"]?.sourceCount ?? 0

        // Warnings.
        let unsecured = operations.filter(\.isUnsecured)
        if !unsecured.isEmpty, unsecured.count < operations.count {
            let names = unsecured.map { "\($0.method) \($0.path)" }
            warnings.add(.caution, L.unsecuredOperations(unsecured.count, operations.count, SpecText.examples(names)))
        }
        if !schemes.isEmpty, operations.allSatisfy(\.isUnsecured), !operations.isEmpty {
            warnings.add(.caution, L.schemesUnused)
        }
        let plain = servers.filter(\.isPlainHTTP)
        if !plain.isEmpty {
            let urls = SpecText.examples(plain.map(\.url))
            if schemes.isEmpty {
                warnings.add(.caution, L.plainHTTP(urls))
            } else {
                warnings.add(.danger, L.plainHTTPWithCredentials(urls))
            }
        }
        for s in schemes {
            if s.type == "basic" || (s.type == "http" && s.detail?.hasPrefix("basic") == true) {
                warnings.add(.caution, L.basicAuth(s.name))
            }
            if s.type == "apiKey", s.detail?.hasPrefix("query") == true {
                warnings.add(.caution, L.apiKeyInQuery(s.name))
            }
            if s.type == "oauth2", s.detail?.contains("implicit") == true {
                warnings.add(.caution, L.implicitFlow(s.name))
            }
        }
        var seen: [String: Int] = [:]
        for op in operations { if let id = op.operationId { seen[id, default: 0] += 1 } }
        let duplicates = seen.filter { $0.value > 1 }.keys.sorted()
        if !duplicates.isEmpty {
            warnings.add(.caution, L.duplicateOperationIds(SpecText.examples(duplicates)))
        }
        if operationCount > operations.count { truncated = true }

        return OpenAPISummary(dialect: dialect, specVersion: version, title: title, apiVersion: apiVersion,
                              description: description, servers: servers, operations: operations,
                              operationCount: operationCount, pathCount: pathCount, tagGroups: groups,
                              componentCounts: counts, schemaCount: schemaCount, securitySchemes: schemes,
                              globalSecurity: global.names, webhookCount: webhooks, warnings: warnings.list,
                              truncated: truncated)
    }

    /// The scheme names of a `security` requirement list, and whether one alternative is the empty `{}`.
    static func requirement(_ node: SpecNode?) -> (names: [String], anonymous: Bool) {
        guard let node, node.isArray else { return ([], false) }
        var names: [String] = []
        var anonymous = false
        for alternative in node.children {
            if alternative.count == 0 { anonymous = true }
            for scheme in alternative.children {
                if let n = scheme.name, !names.contains(n), names.count < 50 { names.append(n) }
            }
        }
        return (names, anonymous)
    }

    static func server(_ url: String, description: String?) -> OpenAPISummary.Server {
        let lower = url.lowercased()
        var plain = false
        if lower.hasPrefix("http://") {
            let host = lower.dropFirst(7).prefix { $0 != "/" && $0 != ":" && $0 != "?" }
            let local = host == "localhost" || host.hasPrefix("127.") || host == "[" || host.hasPrefix("[::1")
                || host == "0.0.0.0" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasPrefix("{")
            plain = !local
        }
        return OpenAPISummary.Server(url: SpecText.oneLine(url, limit: 300), description: description, isPlainHTTP: plain)
    }

    static func securityScheme(name: String, _ s: SpecNode) -> OpenAPISummary.SecurityScheme {
        let type = s["type"]?.scalar ?? "unknown"
        var detail: String?
        switch type {
        case "apiKey":
            let location = s["in"]?.scalar ?? "?"
            detail = "\(location) \(s["name"]?.scalar ?? "")".trimmingCharacters(in: .whitespaces)
        case "http":
            let scheme = (s["scheme"]?.scalar ?? "").lowercased()
            detail = scheme + (s["bearerFormat"]?.scalar.map { " (\($0))" } ?? "")
        case "oauth2":
            if let flows = s["flows"], flows.isObject {
                detail = "flows: " + flows.children.compactMap(\.name).joined(separator: ", ")
            } else if let flow = s["flow"]?.scalar {
                detail = "flow: \(flow)"
            }
        case "openIdConnect":
            detail = s["openIdConnectUrl"]?.scalar
        default:
            break
        }
        return .init(name: name, type: type, detail: SpecText.oneLineOrNil(detail, limit: 200))
    }
}
