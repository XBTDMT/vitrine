import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Inline Markdown, for drawing natively where a web view does not fit (a README inside a folder's repository
/// card). roadmap: S-9
public indirect enum MarkdownInline: Sendable, Equatable {
    case text(String)
    case code(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case link([MarkdownInline], url: String)
    /// Images are not loaded natively; their alt text stands in.
    case image(alt: String)
    case softBreak
    case lineBreak
}

/// Block Markdown, the same parse the Markdown preview uses (cmark-gfm with the GitHub extensions), as values.
/// roadmap: S-9
public indirect enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, [MarkdownInline])
    case paragraph([MarkdownInline])
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    /// A GitHub alert (`> [!NOTE]`): its kind ("Note", "Tip" …) and body.
    case alert(kind: String, [MarkdownBlock])
    /// Items in order; `checked` is nil for a plain item, true or false for a task.
    case list(ordered: Bool, start: Int, items: [(blocks: [MarkdownBlock], checked: Bool?)])
    case table(rows: [[[MarkdownInline]]])
    case rule
    /// Raw HTML, shown as text.
    case html(String)

    public static func == (a: MarkdownBlock, b: MarkdownBlock) -> Bool {
        switch (a, b) {
        case let (.heading(l1, i1), .heading(l2, i2)): l1 == l2 && i1 == i2
        case let (.paragraph(x), .paragraph(y)): x == y
        case let (.code(l1, t1), .code(l2, t2)): l1 == l2 && t1 == t2
        case let (.quote(x), .quote(y)): x == y
        case let (.alert(k1, x), .alert(k2, y)): k1 == k2 && x == y
        case let (.list(o1, s1, i1), .list(o2, s2, i2)):
            o1 == o2 && s1 == s2 && i1.count == i2.count && zip(i1, i2).allSatisfy { $0.blocks == $1.blocks && $0.checked == $1.checked }
        case let (.table(x), .table(y)): x == y
        case (.rule, .rule): true
        case let (.html(x), .html(y)): x == y
        default: false
        }
    }
}

/// Parses Markdown into blocks, stopping after `maxBlocks` top-level blocks (a README preview needs its start,
/// not its whole length). Front matter is dropped. roadmap: S-9
public enum MarkdownBlocks {
    private static let extensionsRegistered: Void = { cmark_gfm_core_extensions_ensure_registered() }()

    public static func parse(_ markdown: String, maxBlocks: Int = 200) -> [MarkdownBlock] {
        _ = extensionsRegistered
        let source = MarkdownHTML.stripFrontMatter(markdown)
        guard let parser = cmark_parser_new(Int32(CMARK_OPT_VALIDATE_UTF8 | CMARK_OPT_FOOTNOTES)) else { return [] }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        source.withCString { cmark_parser_feed(parser, $0, strlen($0)) }
        guard let doc = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(doc) }
        return blocks(children(of: doc).prefix(maxBlocks))
    }

    private typealias Node = UnsafeMutablePointer<cmark_node>

    private static func children(of node: Node) -> [Node] {
        var out: [Node] = []
        var child = cmark_node_first_child(node)
        while let c = child { out.append(c); child = cmark_node_next(c) }
        return out
    }

    private static func literal(_ node: Node) -> String { cmark_node_get_literal(node).map { String(cString: $0) } ?? "" }
    private static func typeName(_ node: Node) -> String { cmark_node_get_type_string(node).map { String(cString: $0) } ?? "" }

    private static func blocks(_ nodes: some Sequence<Node>) -> [MarkdownBlock] { nodes.compactMap(block) }

    private static func block(_ node: Node) -> MarkdownBlock? {
        switch cmark_node_get_type(node) {
        case CMARK_NODE_HEADING: return .heading(level: Int(cmark_node_get_heading_level(node)), inlines(node))
        case CMARK_NODE_PARAGRAPH: return .paragraph(inlines(node))
        case CMARK_NODE_CODE_BLOCK:
            let info = cmark_node_get_fence_info(node).map { String(cString: $0) }?.split(separator: " ").first.map(String.init)
            var text = literal(node)
            if text.hasSuffix("\n") { text.removeLast() }
            return .code(language: info?.isEmpty == false ? info : nil, text: text)
        case CMARK_NODE_BLOCK_QUOTE:
            var inner = blocks(children(of: node))
            if case .paragraph(var first)? = inner.first, case .text(let t)? = first.first,
               let m = t.range(of: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]"#, options: .regularExpression) {
                let kind = MarkdownHTML.Alerts.kinds[String(t[m].dropFirst(2).dropLast())] ?? String(localized: "Note", bundle: .module, comment: "Title of a Markdown alert box (GitHub's [!NOTE]).")
                let rest = String(t[m.upperBound...])
                first.removeFirst()
                if !rest.isEmpty { first.insert(.text(rest), at: 0) }
                while case .softBreak? = first.first { first.removeFirst() }
                if first.isEmpty { inner.removeFirst() } else { inner[0] = .paragraph(first) }
                return .alert(kind: kind, inner)
            }
            return .quote(inner)
        case CMARK_NODE_LIST:
            let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
            let items = children(of: node).map { item -> (blocks: [MarkdownBlock], checked: Bool?) in
                let task = typeName(item) == "tasklist"
                return (blocks(children(of: item)), task ? cmark_gfm_extensions_get_tasklist_item_checked(item) : nil)
            }
            return .list(ordered: ordered, start: Int(cmark_node_get_list_start(node)), items: items)
        case CMARK_NODE_THEMATIC_BREAK: return .rule
        case CMARK_NODE_HTML_BLOCK:
            let text = literal(node).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.hasPrefix("<!--") ? nil : .html(text)
        default:
            if typeName(node) == "table" {
                return .table(rows: children(of: node).map { row in children(of: row).map { inlines($0) } })
            }
            return nil
        }
    }

    private static func inlines(_ node: Node) -> [MarkdownInline] { children(of: node).compactMap(inline) }

    private static func inline(_ node: Node) -> MarkdownInline? {
        switch cmark_node_get_type(node) {
        case CMARK_NODE_TEXT: return .text(literal(node))
        case CMARK_NODE_CODE: return .code(literal(node))
        case CMARK_NODE_EMPH: return .emphasis(inlines(node))
        case CMARK_NODE_STRONG: return .strong(inlines(node))
        case CMARK_NODE_LINK: return .link(inlines(node), url: cmark_node_get_url(node).map { String(cString: $0) } ?? "")
        case CMARK_NODE_IMAGE:
            let alt = inlines(node).map(plain).joined()
            return .image(alt: alt)
        case CMARK_NODE_SOFTBREAK: return .softBreak
        case CMARK_NODE_LINEBREAK: return .lineBreak
        case CMARK_NODE_HTML_INLINE: return nil
        default:
            if typeName(node) == "strikethrough" { return .strikethrough(inlines(node)) }
            return nil
        }
    }

    /// The text of inline content without its styling.
    public static func plain(_ inline: MarkdownInline) -> String {
        switch inline {
        case .text(let s), .code(let s): s
        case .emphasis(let x), .strong(let x), .strikethrough(let x), .link(let x, _): x.map(plain).joined()
        case .image(let alt): alt
        case .softBreak: " "
        case .lineBreak: "\n"
        }
    }
}
