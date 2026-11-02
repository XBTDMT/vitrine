import Foundation

/// JSON Schema documents (draft-04 to 2020-12), JSON or YAML, already parsed by VitrineData. The properties tree
/// goes `APISpecReader.maxPropertyDepth` levels deep and keeps at most `maxPropertyNodes` properties in all; `$ref`
/// targets are collected over the whole flat tree without recursion and local ones (`#/…`) are checked against
/// the document. Nothing remote is fetched. roadmap: S-22
enum JSONSchemaReader {
    static let maxPropertyNodes = 20_000

    static func read(_ doc: SpecDocument.Parsed) -> JSONSchemaSummary? {
        let root = doc.root
        guard root.isObject else { return nil }
        var truncated = doc.partial
        var warnings = SpecWarnings()
        if let error = doc.syntaxError {
            warnings.add(.caution, L.syntaxError(error))
        }
        let schemaURI = root["$schema"]?.string
        var budget = maxPropertyNodes
        var missingRequired: [String] = []

        var source = root
        if root["properties"] == nil, let items = root["items"], items["properties"] != nil { source = items }
        let properties = Self.properties(of: source, depth: 1, path: "", budget: &budget, truncated: &truncated,
                                         missingRequired: &missingRequired)

        var definitionNames: [String] = []
        var definitionCount = 0
        for key in ["$defs", "definitions"] {
            guard let defs = root[key], defs.isObject else { continue }
            definitionCount += defs.sourceCount
            for d in defs.children { if let n = d.name { appendCapped(&definitionNames, n, &truncated) } }
        }

        // Every $ref in the document, by a flat scan of the root's subtree.
        var refs: [String] = []
        var seen = Set<String>()
        let tree = root.tree
        var i = root.index
        let end = max(tree[root.index].subtreeEnd, root.index + 1)
        while i < min(end, tree.count) {
            let n = tree[i]
            if n.name == "$ref", n.kind == .string, !seen.contains(n.preview) {
                seen.insert(n.preview)
                appendCapped(&refs, n.preview, &truncated)
            }
            i += 1
        }
        let unresolved = refs.filter { $0.hasPrefix("#/") && resolve(pointer: $0, in: root) == nil }
        if !unresolved.isEmpty {
            warnings.add(.caution, L.unresolvedRefs(unresolved.count, SpecText.examples(unresolved)))
        }
        if !missingRequired.isEmpty {
            warnings.add(.caution, L.requiredNotDefined(SpecText.examples(missingRequired)))
        }
        if let id = root["$id"]?.string ?? root["id"]?.string, id.lowercased().hasPrefix("http://") {
            warnings.add(.caution, L.plainHTTPId(SpecText.oneLine(id, limit: 80)))
        }

        return JSONSchemaSummary(title: SpecText.oneLineOrNil(root["title"]?.scalar),
                                 description: SpecText.cap(root["description"]?.scalar, APISpecReader.maxDescriptionLength),
                                 draft: draft(schemaURI), schemaURI: schemaURI,
                                 id: root["$id"]?.string ?? root["id"]?.string, rootTypes: types(of: root),
                                 properties: properties, definitionCount: definitionCount, definitionNames: definitionNames,
                                 refs: refs, rootCombinators: combinators(of: root), warnings: warnings.list,
                                 truncated: truncated)
    }

    /// The draft a `$schema` URI names.
    static func draft(_ uri: String?) -> String? {
        guard let uri = uri?.lowercased() else { return nil }
        for d in ["draft-03", "draft-04", "draft-05", "draft-06", "draft-07"] where uri.contains(d) { return d }
        for d in ["2019-09", "2020-12"] where uri.contains(d) { return d }
        return nil
    }

    static func types(of node: SpecNode) -> [String] {
        var list = node["type"]?.strings ?? []
        if list == ["array"] || (list.isEmpty && node["items"] != nil), let items = node["items"], items.isObject {
            let inner = items["type"]?.strings ?? []
            let name = inner.isEmpty ? (items["$ref"]?.string.map(refName) ?? "any") : inner.joined(separator: " | ")
            list = ["array<\(name)>"]
        }
        if list.isEmpty, node["const"] != nil { list = ["const"] }
        return list
    }

    static func combinators(of node: SpecNode) -> [String] {
        ["allOf", "anyOf", "oneOf"].compactMap { key in
            guard let list = node[key], list.isArray else { return nil }
            return "\(key) (\(list.sourceCount))"
        } + (node["not"] != nil ? ["not"] : [])
    }

    /// The last segment of a ref, for `array<Harbor>`.
    static func refName(_ ref: String) -> String {
        String(ref.split(separator: "/").last ?? Substring(ref))
    }

    static func properties(of node: SpecNode, depth: Int, path: String, budget: inout Int, truncated: inout Bool,
                           missingRequired: inout [String]) -> [JSONSchemaSummary.Property] {
        guard let props = node["properties"], props.isObject else { return [] }
        let required = Set(node["required"]?.strings ?? [])
        let names = Set(props.children.compactMap(\.name))
        for r in required.sorted() where !names.contains(r) && missingRequired.count < 100 {
            missingRequired.append(path.isEmpty ? r : "\(path).\(r)")
        }
        var list: [JSONSchemaSummary.Property] = []
        for p in props.children {
            guard let name = p.name else { continue }
            guard budget > 0 else { truncated = true; break }
            budget -= 1
            var property = JSONSchemaSummary.Property(
                name: name, types: p.isObject ? types(of: p) : [], required: required.contains(name),
                description: SpecText.oneLineOrNil(p["description"]?.scalar ?? p["title"]?.scalar),
                enumValues: [], format: p["format"]?.scalar, ref: p["$ref"]?.string,
                combinators: p.isObject ? combinators(of: p) : [], deprecated: p["deprecated"]?.isTrue ?? false,
                children: [], childrenCut: false)
            for v in p["enum"]?.children ?? [] {
                appendCapped(&property.enumValues, v.displayValue(quoteStrings: false), &truncated)
            }
            if property.types.isEmpty, !property.enumValues.isEmpty { property.types = ["enum"] }
            let holder: SpecNode? = p["properties"] != nil ? p : (p["items"]?["properties"] != nil ? p["items"] : nil)
            if let holder {
                if depth < APISpecReader.maxPropertyDepth {
                    property.children = properties(of: holder, depth: depth + 1, path: path.isEmpty ? name : "\(path).\(name)",
                                                   budget: &budget, truncated: &truncated, missingRequired: &missingRequired)
                } else {
                    property.childrenCut = true
                }
            }
            appendCapped(&list, property, &truncated)
        }
        return list
    }

    /// Follows a JSON Pointer fragment (`#/$defs/Harbor`, with `~0`, `~1` and percent escapes) through the document.
    static func resolve(pointer: String, in root: SpecNode) -> SpecNode? {
        var node = root
        let body = pointer.dropFirst(2)
        for raw in body.split(separator: "/", omittingEmptySubsequences: false) {
            let token = (String(raw).removingPercentEncoding ?? String(raw))
                .replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if node.isArray {
                guard let k = Int(token), k >= 0, k < node.count, let c = node.tree.child(k, of: node.index) else { return nil }
                node = SpecNode(tree: node.tree, index: c)
            } else {
                guard let next = node[token] else { return nil }
                node = next
            }
        }
        return node
    }
}
