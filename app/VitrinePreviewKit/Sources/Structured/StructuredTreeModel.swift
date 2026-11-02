import Foundation
import VitrineData

/// What the Tree view of a structured file shows, apart from AppKit: which nodes are rows and in what order, how each
/// row reads (key, value, inline preview, child count, type tag, each with its colour token), the selected node's path,
/// the text a per-node copy puts on the pasteboard, and a bounded find over keys and values. The tree itself comes from
/// the structured engine (VitrineData `StructuredParser`); this layer only reads it. Code design state 5 (JSON tree:
/// folding, counts, path, per-node copy), 9 (binary property list as a typed tree), 10 (XML as an element tree with
/// attributes), design/mockups/unified/code.html. roadmap: S-5
@MainActor
final class StructuredTreeModel {
    let result: StructuredParseResult
    /// The bytes the tree was parsed from (at most `FamilyFacts.parseLimit`): copy reads a node's source text here.
    let source: Data
    var tree: StructuredTree { result.tree }

    /// JSON, YAML and TOML list a single top-level object's keys as the first rows (state 5 and the config.yaml pane);
    /// a property list shows its "Root" row (state 9) and XML its document element (state 10).
    let hidesRoot: Bool
    let isXML: Bool
    let isPropertyList: Bool
    /// JSON and TOML write strings in quotes; YAML, property lists and XML text read better bare (states 5, 9, 10).
    let quotesStrings: Bool
    /// XML rows leave out attributes (they read inline on their element's row) and an element's lone text child (it
    /// is the element's value): the kept children per element, built when first asked for.
    private var xmlChildren: [Int: [Int]] = [:]

    /// What a top-level item is called when there are several, or always when set by a query: "Document 2" for
    /// YAML documents, "Result 1" for a jq query's outputs (I-8).
    var rootNoun = RootNoun.document
    var alwaysNameRoots = false

    /// The top-level items' name, as whole localized phrases with their number (H-6).
    enum RootNoun {
        case document, result

        /// "Document 2", "Result 1": the row's key.
        func title(_ n: Int) -> String {
            switch self {
            case .document: String(localized: "Document \(n)", bundle: .previewKit, comment: "Tree row: one of several YAML documents in a file.")
            case .result: String(localized: "Result \(n)", bundle: .previewKit, comment: "Tree row: one of a jq query's results.")
            }
        }

        /// "document 2", "result 1": the path row's first part (lower case).
        func pathPart(_ n: Int) -> String {
            switch self {
            case .document: String(localized: "document \(n)", bundle: .previewKit,
                                   comment: "Path row, first part (lower case): which YAML document the selected node is in.")
            case .result: String(localized: "result \(n)", bundle: .previewKit,
                                 comment: "Path row, first part (lower case): which jq result the selected node is in.")
            }
        }
    }

    init(result: StructuredParseResult, source: Data) {
        self.result = result
        self.source = source
        isXML = result.format == .xml
        isPropertyList = result.format == .propertyList
        quotesStrings = [.json, .jsonc, .json5, .toml].contains(result.dialect)
        let tree = result.tree
        hidesRoot = [.json, .yaml, .toml].contains(result.format) && tree.roots.count == 1
            && tree[tree.roots[0]].kind.isContainer
    }

    // MARK: Rows

    /// Rows under `parent` (nil = the top level), before paging.
    func childCount(of parent: Int?) -> Int {
        guard let parent else { return hidesRoot ? tree[tree.roots[0]].childCount : tree.roots.count }
        if isXML { return xmlKept(parent).count }
        return tree[parent].childCount
    }

    /// The `position`-th row under `parent`.
    func child(_ position: Int, of parent: Int?) -> Int {
        guard let parent else { return hidesRoot ? tree.child(position, of: tree.roots[0]) ?? 0 : tree.roots[position] }
        if isXML { return xmlKept(parent)[position] }
        return tree.child(position, of: parent) ?? 0
    }

    /// Where `node` sits among its outline parent's rows.
    func position(of node: Int) -> Int {
        let parent = outlineParent(of: node)
        if isXML, let parent { return xmlKept(parent).firstIndex(of: node) ?? 0 }
        return tree[node].indexInParent
    }

    /// The row the outline nests `node` under: its tree parent, or nil at the top level (a hidden root's children are
    /// top-level rows).
    func outlineParent(of node: Int) -> Int? {
        guard let parent = tree[node].parent else { return nil }
        if hidesRoot, parent == tree.roots[0] { return nil }
        return parent
    }

    /// The row that stands for `node`: itself, or for an XML attribute or an element's lone text, the element; nil for
    /// a hidden root.
    func rowNode(for node: Int) -> Int? {
        if hidesRoot, node == tree.roots[0] { return nil }
        guard isXML, let parent = tree[node].parent else { return node }
        let n = tree[node]
        if n.role == .attribute { return parent }
        if n.role == .text || n.role == .cdata, isLoneText(parent) { return parent }
        return node
    }

    func isExpandable(_ node: Int) -> Bool {
        let n = tree[node]
        guard n.kind.isContainer else { return false }
        return childCount(of: node) > 0
    }

    /// Children the source holds that the tree did not keep (a node or depth limit).
    func omittedCount(of parent: Int?) -> Int {
        guard let parent else { return 0 }
        let n = tree[parent]
        return max(0, n.sourceChildCount - n.childCount)
    }

    private func xmlKept(_ element: Int) -> [Int] {
        if let kept = xmlChildren[element] { return kept }
        let all = tree.children(of: element)
        var kept = all.filter { tree[$0].role != .attribute }
        if kept.count == 1, tree[kept[0]].role == .text || tree[kept[0]].role == .cdata { kept = [] }
        xmlChildren[element] = kept
        return kept
    }

    private func isLoneText(_ element: Int) -> Bool {
        tree[element].role == .element && xmlKept(element).isEmpty
            && tree.children(of: element).contains { tree[$0].role == .text || tree[$0].role == .cdata }
    }

    // MARK: How a row reads

    /// One run of a row's text and the colour token it is drawn in.
    struct Segment: Equatable {
        var text: String
        var token: String
    }

    /// A row: its text runs (key, punctuation, value or inline preview), the count pill for a container, and the type
    /// tag at the right for a value.
    struct Row: Equatable {
        var segments: [Segment]
        var count: String?
        var typeTag: String?
        var text: String { segments.map(\.text).joined() }
    }

    func row(_ node: Int, expanded: Bool) -> Row {
        let n = tree[node]
        var segments: [Segment] = []
        var count: String?
        var typeTag: String?
        if let key = keySegment(node) {
            segments.append(key)
            if !isXML || n.role != .element { segments.append(Segment(text: ": ", token: "syn-punct")) }
        }
        if isXML, n.role == .element {
            for attribute in tree.children(of: node) where tree[attribute].role == .attribute {
                segments.append(Segment(text: " " + (tree[attribute].name ?? ""), token: "syn-attr"))
                segments.append(Segment(text: "=", token: "syn-punct"))
                segments.append(Segment(text: "\"\(tree[attribute].preview)\"", token: "syn-str"))
            }
            let kept = childCount(of: node)
            if kept == 0 {
                if let text = tree.children(of: node).first(where: { [.text, .cdata].contains(tree[$0].role) }) {
                    segments.append(Segment(text: " ", token: "t1"))
                    segments.append(contentsOf: valueSegments(text))
                } else if n.preview.isEmpty, n.sourceChildCount == 0 {
                    segments.append(Segment(text: " " + String(localized: "(empty)", bundle: .previewKit,
                                                                     comment: "Tree row: an XML element with no content."), token: "t2"))
                }
            } else {
                if !expanded, let lead = elementLead(node) { segments.append(Segment(text: " " + lead, token: "t2")) }
                let total = kept + omittedCount(of: node)
                count = String(localized: "\(total) children", bundle: .previewKit, comment: "Tree row: how many child elements an XML element has.")
            }
            return Row(segments: segments, count: count, typeTag: nil)
        }
        if n.kind.isContainer {
            if !expanded, let inline = inlinePreview(node) { segments.append(Segment(text: inline, token: "t2")) }
            let total = n.sourceChildCount
            let object = n.kind == .object
            switch (isPropertyList, object) {
            case (false, true): count = String(localized: "\(total) keys", bundle: .previewKit, comment: "Tree row: how many keys an object has.")
            case (false, false): count = String(localized: "\(total) items", bundle: .previewKit, comment: "Tree row: how many items an array has.")
            case (true, true): count = String(localized: "Dictionary · \(total) keys", bundle: .previewKit,
                                              comment: "Tree row of a property list: a dictionary, then how many keys it has.")
            case (true, false): count = String(localized: "Array · \(total) items", bundle: .previewKit,
                                               comment: "Tree row of a property list: an array, then how many items it has.")
            }
        } else {
            segments.append(contentsOf: valueSegments(node))
            typeTag = typeName(node)
        }
        return Row(segments: segments, count: count, typeTag: typeTag)
    }

    private func keySegment(_ node: Int) -> Segment? {
        let n = tree[node]
        if isXML {
            switch n.role {
            case .element: return Segment(text: "<\(n.name ?? "")>", token: "syn-kw")
            case .processingInstruction: return Segment(text: "<?\(n.name ?? "")", token: "syn-com")
            default: return nil
            }
        }
        guard let parent = n.parent else {
            if isPropertyList {
                return Segment(text: String(localized: "Root", bundle: .previewKit, comment: "Tree row: a property list's top-level item."), token: "syn-key")
            }
            if tree.roots.count > 1 || alwaysNameRoots { return Segment(text: rootNoun.title(n.indexInParent + 1), token: "t2") }
            return Segment(text: String(localized: "root", bundle: .previewKit, comment: "Tree row (lower case): a JSON/YAML document's top-level value."), token: "t2")
        }
        if tree[parent].kind == .array || n.name == nil { return Segment(text: "\(n.indexInParent)", token: "t3") }
        return Segment(text: n.name ?? "", token: "syn-key")
    }

    /// A value as it reads in its row, coloured by its type.
    func valueSegments(_ node: Int) -> [Segment] {
        let n = tree[node]
        let cut = n.isPreviewTruncated ? "…" : ""
        switch n.role {
        case .comment: return [Segment(text: "<!-- \(n.preview)\(cut) -->", token: "syn-com")]
        case .processingInstruction: return [Segment(text: " \(n.preview)\(cut)?>", token: "syn-com")]
        case .cdata:
            // CDATA is XML's own word.
            let text = n.isPreviewTruncated
                ? String(localized: "CDATA · \(n.preview.count)+ chars · “\(Self.short(n.preview, 40))”", bundle: .previewKit,
                         comment: "Tree row of an XML CDATA section: at least this many characters, then its start in quotes.")
                : String(localized: "CDATA · \(n.preview.count) chars · “\(Self.short(n.preview, 40))”", bundle: .previewKit,
                         comment: "Tree row of an XML CDATA section: how many characters, then its start in quotes.")
            return [Segment(text: text, token: "t2")]
        case .alias:
            return [Segment(text: n.preview, token: "syn-kw"),
                    Segment(text: "  " + String(localized: "alias", bundle: .previewKit, comment: "Tree row tag (lower case): a YAML alias (*name)."), token: "t2")]
        case .invalid: return [Segment(text: n.preview + cut, token: "caution-text")]
        case .text: return [Segment(text: n.preview + cut, token: "syn-str")]
        default: break
        }
        switch n.kind {
        case .string:
            let text = quotesStrings ? "\"\(n.preview)\(cut)\"" : n.preview + cut
            return [Segment(text: text, token: Self.looksLikeDate(n.preview) ? "syn-ty" : "syn-str")]
        case .number: return [Segment(text: n.preview + cut, token: "syn-num")]
        case .bool:
            let yes = n.preview == "true"
            return [Segment(text: isPropertyList ? (yes ? "YES" : "NO") : n.preview, token: "syn-bool")]
        case .null: return [Segment(text: n.preview.isEmpty ? "null" : n.preview, token: "syn-bool")]
        case .date: return [Segment(text: isPropertyList ? Self.plistDate(n.preview) : n.preview, token: "syn-ty")]
        case .data: return [Segment(text: n.preview, token: "t2")]
        case .object, .array: return []
        }
    }

    /// "String", "Number", …: the tag at the right of a value's row.
    func typeName(_ node: Int) -> String {
        let n = tree[node]
        switch n.role {
        case .text: return String(localized: "Text", bundle: .previewKit, comment: "Tree type tag: XML text.")
        case .cdata: return "CDATA"
        case .comment: return String(localized: "Comment", bundle: .previewKit, comment: "Tree type tag: an XML comment.")
        case .alias: return String(localized: "Alias", bundle: .previewKit, comment: "Tree type tag: a YAML alias.")
        case .invalid: return String(localized: "Invalid", bundle: .previewKit, comment: "Tree type tag: a value that does not parse.")
        default: return n.kind.displayName
        }
    }

    /// `{ theme, sync, fontSize, … }` or `[ "home", "work", … ]` (property list arrays: `( a, b )`) for a folded
    /// container: its first three children.
    func inlinePreview(_ node: Int) -> String? {
        let n = tree[node]
        guard n.childCount > 0 else { return n.kind == .object ? "{ }" : (isPropertyList ? "( )" : "[ ]") }
        let first = tree.children(of: node, in: 0..<3)
        let parts: [String] = first.map { child in
            let c = tree[child]
            if n.kind == .object { return Self.short(c.name ?? "", 24) }
            if c.kind.isContainer { return c.kind == .object ? "{…}" : (isPropertyList ? "(…)" : "[…]") }
            return Self.short(valueSegments(child).map(\.text).joined(), 24)
        }
        let more = n.sourceChildCount > first.count ? ", …" : ""
        let (open, close) = n.kind == .object ? ("{", "}") : (isPropertyList ? ("(", ")") : ("[", "]"))
        return "\(open) \(parts.joined(separator: ", "))\(more) \(close)"
    }

    /// A folded XML element's lead text: its own text, or its first child element's (an RSS item reads by its title).
    private func elementLead(_ node: Int) -> String? {
        if !tree[node].preview.isEmpty { return Self.short(tree[node].preview, 48) }
        for child in xmlKept(node).prefix(4) where tree[child].role == .element && !tree[child].preview.isEmpty {
            return Self.short(tree[child].preview, 48)
        }
        return nil
    }

    static func short(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    private static let dateShape = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?$"#)

    /// An ISO 8601 date or date-time written as a string (state 5 colours `createdAt` as a type).
    static func looksLikeDate(_ text: String) -> Bool {
        guard text.count >= 10, text.count <= 35, text.first?.isNumber == true else { return false }
        return dateShape.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// "2 Oct 2026 at 14:12:09" for a property list date (state 9); the ISO text when it does not parse.
    static func plistDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    // MARK: Path

    /// `$.notes[3].attachments[0].size`, `/rss/channel/item[2]/title`, "document 2: $.spec" for a second YAML document.
    func path(of node: Int) -> String { tree.qualifiedPath(of: node) }

    /// The path as the path row shows it: `$ › notes › [3] › attachments › [0] › size`.
    func pathComponents(of node: Int?) -> [String] {
        guard let node else { return tree.pathStyle == .xpath ? ["/"] : ["$"] }
        if tree.pathStyle == .xpath { return tree.path(of: node).split(separator: "/").map(String.init) }
        var chain: [Int] = []
        var current: Int? = node
        while let index = current { chain.append(index); current = tree[index].parent }
        chain.reverse()
        var parts = ["$"]
        if tree.roots.count > 1 || alwaysNameRoots { parts = [rootNoun.pathPart(tree[chain[0]].indexInParent + 1), "$"] }
        for index in chain.dropFirst() {
            let n = tree[index]
            guard let parent = n.parent else { continue }
            parts.append(tree[parent].kind == .array || n.name == nil ? "[\(n.indexInParent)]" : (n.name ?? ""))
        }
        return parts
    }

    // MARK: Copy

    /// What "Copy value" puts on the pasteboard: a value's full text (a string without its quotes), a container's
    /// source text when the parser knows where it sits in the file, otherwise the container written out as JSON (a
    /// binary property list has no source text) or as XML.
    func copyText(of node: Int) -> String {
        let n = tree[node]
        if isXML, n.role == .element {
            if childCount(of: node) == 0, let text = tree.children(of: node).first(where: { [.text, .cdata].contains(tree[$0].role) }) {
                return fullValue(text)
            }
            var out = ""
            writeXML(node, indent: 0, into: &out)
            return out
        }
        if !n.kind.isContainer { return fullValue(node) }
        if !isXML, !isPropertyList, let slice = sourceSlice(node) { return slice }
        var out = ""
        writeJSON(node, indent: 0, into: &out)
        return out
    }

    /// A value's whole text: the preview, or when the preview was cut, the value read again from its source bytes.
    private func fullValue(_ node: Int) -> String {
        let n = tree[node]
        guard n.isPreviewTruncated, let raw = sourceSlice(node) else { return n.preview }
        if n.kind == .string, quotesStrings, let data = raw.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
            return decoded
        }
        return raw
    }

    private func sourceSlice(_ node: Int) -> String? {
        let span = tree[node].span
        guard let offset = span.byteOffset, let length = span.byteLength, offset >= 0, length > 0,
              offset + length <= Int64(source.count) else { return nil }
        let start = source.startIndex + Int(offset)
        return String(decoding: source[start..<(start + Int(length))], as: UTF8.self)
    }

    /// Copy stops writing a synthesised container past this many characters.
    static let copyLimit = 4 * 1024 * 1024

    private func writeJSON(_ node: Int, indent: Int, into out: inout String) {
        guard out.utf8.count < Self.copyLimit else { return }
        let n = tree[node]
        let pad = String(repeating: "  ", count: indent + 1)
        switch n.kind {
        case .object, .array:
            let children = tree.children(of: node)
            let (open, close) = n.kind == .object ? ("{", "}") : ("[", "]")
            guard !children.isEmpty else { out += open + close; return }
            out += open + "\n"
            for (i, child) in children.enumerated() {
                out += pad
                if n.kind == .object { out += StructuredTreeModel.jsonString(tree[child].name ?? "") + ": " }
                writeJSON(child, indent: indent + 1, into: &out)
                out += i == children.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: indent) + close
        case .number: out += n.preview
        case .bool: out += n.preview == "true" ? "true" : "false"
        case .null: out += "null"
        case .string, .date, .data: out += StructuredTreeModel.jsonString(fullValue(node))
        }
    }

    private func writeXML(_ node: Int, indent: Int, into out: inout String) {
        guard out.utf8.count < Self.copyLimit else { return }
        let n = tree[node]
        let pad = String(repeating: "  ", count: indent)
        switch n.role {
        case .element:
            let name = n.name ?? ""
            out += pad + "<" + name
            for attribute in tree.children(of: node) where tree[attribute].role == .attribute {
                out += " \(tree[attribute].name ?? "")=\"\(Self.xmlEscaped(fullValue(attribute), quote: true))\""
            }
            let content = tree.children(of: node).filter { tree[$0].role != .attribute }
            if content.isEmpty { out += "/>\n"; return }
            if content.count == 1, tree[content[0]].role == .text {
                out += ">" + Self.xmlEscaped(fullValue(content[0]), quote: false) + "</\(name)>\n"
                return
            }
            out += ">\n"
            for child in content { writeXML(child, indent: indent + 1, into: &out) }
            out += pad + "</\(name)>\n"
        case .text: out += pad + Self.xmlEscaped(fullValue(node), quote: false) + "\n"
        case .cdata: out += pad + "<![CDATA[" + fullValue(node) + "]]>\n"
        case .comment: out += pad + "<!-- " + fullValue(node) + " -->\n"
        case .processingInstruction: out += pad + "<?\(n.name ?? "") \(fullValue(node))?>\n"
        default: out += pad + fullValue(node) + "\n"
        }
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func xmlEscaped(_ s: String, quote: Bool) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if quote { out = out.replacingOccurrences(of: "\"", with: "&quot;") }
        return out
    }

    // MARK: Find

    /// Rows whose key or value contains `query`, in document order, each once. The tree is walked in its stored
    /// pre-order and the walk stops after `limit` nodes, so a 500,000-node tree answers at once; `searchedAll` false
    /// means the count is a floor (the capsule then says "1 of 40+").
    func matches(_ query: String, limit: Int) -> (rows: [Int], searchedAll: Bool) {
        guard !query.isEmpty else { return ([], true) }
        var rows: [Int] = []
        var seen = Set<Int>()
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let count = tree.count
        let end = min(count, max(0, limit))
        for index in 0..<end {
            let n = tree[index]
            let hit = (n.name?.range(of: query, options: options) != nil) || (!n.preview.isEmpty && n.preview.range(of: query, options: options) != nil)
            guard hit, let row = rowNode(for: index), seen.insert(row).inserted else { continue }
            rows.append(row)
        }
        return (rows, end == count)
    }
}
