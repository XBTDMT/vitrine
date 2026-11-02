import Foundation

/// The value kinds every structured format maps into, so one outline view and one set of colours serve JSON, YAML,
/// TOML, XML and property lists alike. roadmap: S-5
public enum StructuredNodeKind: UInt8, Sendable, Equatable, Codable, CaseIterable {
    case object, array, string, number, bool, null, date, data

    public var isContainer: Bool { self == .object || self == .array }

    public var displayName: String {
        switch self {
        case .object: String(localized: "Object", bundle: .module, comment: "Kind of a value in a structured file (JSON, YAML, TOML, XML, property list). A set of key-value pairs.")
        case .array: String(localized: "Array", bundle: .module, comment: "Kind of a value in a structured file (JSON, YAML, TOML, XML, property list). An ordered list.")
        case .string: String(localized: "String", bundle: .module, comment: "Kind of a value in a structured file (JSON, YAML, TOML, XML, property list). Text.")
        case .number: String(localized: "Number", bundle: .module, comment: "Kind of a value in a structured file (JSON, YAML, TOML, XML, property list).")
        case .bool: String(localized: "Boolean", bundle: .module, comment: "Kind of a value in a structured file (JSON, YAML, TOML, XML, property list). true or false.")
        case .null: String(localized: "Null", bundle: .module, comment: "Kind of a value in a structured file (JSON, YAML, TOML, XML, property list). No value.")
        case .date: String(localized: "Date", bundle: .module, comment: "Kind of a value in a structured file (JSON, YAML, TOML, XML, property list).")
        case .data: String(localized: "Data", bundle: .module, comment: "Kind of a value in a structured file (JSON, YAML, TOML, XML, property list). Raw bytes.")
        }
    }
}

/// What a node is in its source, beyond its value kind. JSON-family nodes are all `.value`; XML needs to tell an
/// element from its attributes and its text so the outline and the XPath-like path read right; YAML marks aliases
/// it could not expand; JSON Lines marks a line that did not parse.
public enum StructuredNodeRole: UInt8, Sendable, Equatable, Codable, CaseIterable {
    case value, element, attribute, text, cdata, comment, processingInstruction, alias, invalid
}

/// Where a node sits in the bytes the parser read. Every part is optional because not every reader knows it: the JSON,
/// YAML and TOML parsers know all of it; for XML, elements and their attributes carry the start tag's span (found by
/// `XMLLexer`) while text, comments and CDATA have only XMLParser's line and column; binary and OpenStep property
/// lists (PropertyListSerialization) have none.
public struct StructuredSpan: Sendable, Equatable, Codable {
    /// Byte offset from the start of the file (for transcoded UTF-16 input: of the UTF-8 text).
    public var byteOffset: Int64?
    /// Bytes from the node's first byte to its last; for containers, through the closing bracket.
    public var byteLength: Int64?
    /// 1-based line.
    public var line: Int?
    /// 1-based column. The JSON, TOML and XML-tag spans count bytes from the line start (cheap even on a 20 MB
    /// minified line); YAML counts characters; XML text is what XMLParser reports. Error locations
    /// (`StructuredLocation`) always count characters.
    public var column: Int?

    public init(byteOffset: Int64? = nil, byteLength: Int64? = nil, line: Int? = nil, column: Int? = nil) {
        self.byteOffset = byteOffset; self.byteLength = byteLength; self.line = line; self.column = column
    }

    public static let unknown = StructuredSpan()
}

/// One node of a structured document, stored flat. The fields are compact (Int32 indices, sentinel -1 for "unknown")
/// because a tree may hold 500,000 of them inside a Quick Look extension's 300 MB; the public accessors turn the
/// sentinels into optionals.
public struct StructuredNode: Sendable, Equatable {
    public internal(set) var kind: StructuredNodeKind
    public internal(set) var role: StructuredNodeRole
    /// The object key, element or attribute name, processing-instruction target; nil for array items and roots.
    public internal(set) var name: String?
    /// The value as display text: decoded strings, numbers exactly as written, dates as written, "12 bytes" for data.
    /// Empty for containers. Cut to `StructuredOptions.maxPreviewBytes` (see `isPreviewTruncated`).
    public internal(set) var preview: String
    public internal(set) var isPreviewTruncated: Bool
    /// A limit (nodes, depth, alias expansion) or the end of readable input kept some children out of the tree.
    public internal(set) var childrenOmitted: Bool

    var parentRaw: Int32
    var depthRaw: Int32
    var childStartRaw: Int32 = 0
    var storedChildCount: Int32 = 0
    var sourceChildCountRaw: Int32 = 0
    var subtreeEndRaw: Int32 = -1
    var indexInParentRaw: Int32 = 0
    var offsetRaw: Int64
    var lengthRaw: Int64
    var lineRaw: Int
    var columnRaw: Int32

    init(kind: StructuredNodeKind, role: StructuredNodeRole, name: String?, preview: String, isPreviewTruncated: Bool,
         parent: Int32, depth: Int32, span: StructuredSpan) {
        self.kind = kind; self.role = role; self.name = name; self.preview = preview
        self.isPreviewTruncated = isPreviewTruncated; self.childrenOmitted = false
        self.parentRaw = parent; self.depthRaw = depth
        self.offsetRaw = span.byteOffset ?? -1
        self.lengthRaw = span.byteLength ?? -1
        self.lineRaw = span.line ?? -1
        self.columnRaw = Int32(clamping: span.column ?? -1)
    }

    /// The parent's index in `StructuredTree.nodes`, nil for a root.
    public var parent: Int? { parentRaw >= 0 ? Int(parentRaw) : nil }
    /// 0 for a root, 1 for its children, and so on.
    public var depth: Int { Int(depthRaw) }
    /// Children kept in the tree.
    public var childCount: Int { Int(storedChildCount) }
    /// Children the source holds, counted even when a limit kept them out (so "1,204 items" stays true).
    public var sourceChildCount: Int { Int(sourceChildCountRaw) }
    /// Position among the parent's kept children (or among the roots).
    public var indexInParent: Int { Int(indexInParentRaw) }
    /// One past the last descendant: nodes are in pre-order, so `index..<subtreeEnd` is this node's whole subtree.
    public var subtreeEnd: Int { Int(subtreeEndRaw) }

    public var span: StructuredSpan {
        StructuredSpan(byteOffset: offsetRaw >= 0 ? offsetRaw : nil, byteLength: lengthRaw >= 0 ? lengthRaw : nil,
                       line: lineRaw >= 0 ? lineRaw : nil, column: columnRaw >= 0 ? Int(columnRaw) : nil)
    }
}

/// How `StructuredTree.path(of:)` writes a path.
public enum StructuredPathStyle: Sendable, Equatable, Codable {
    /// `$.users[3].name`, `$["key with spaces"]` — JSON, JSON Lines, YAML, TOML and property lists.
    case jsonPath
    /// `/feed/entry[2]/title`, `/feed/@lang`, `/feed/entry[2]/title/text()` — XML.
    case xpath
}

/// A whole document as a flat pre-order array, which is what an outline needs: O(1) parent, child count, n-th child
/// and subtree range for any node, no recursion to walk it, and one allocation instead of one per node.
public struct StructuredTree: Sendable {
    public let pathStyle: StructuredPathStyle
    public let nodes: [StructuredNode]
    /// Top-level nodes: one for a JSON or TOML document, one per YAML document, one per JSON Lines line, the document
    /// element plus any prolog or epilog comments and processing instructions for XML.
    public let roots: [Int]
    /// Every node's kept children, contiguous per parent, indexed by `StructuredNode.childStartRaw`.
    let childIndex: [Int32]
    let tags: [Int32: String]
    let anchors: [Int32: String]

    init(pathStyle: StructuredPathStyle, nodes: [StructuredNode], roots: [Int], childIndex: [Int32],
         tags: [Int32: String], anchors: [Int32: String]) {
        self.pathStyle = pathStyle; self.nodes = nodes; self.roots = roots; self.childIndex = childIndex
        self.tags = tags; self.anchors = anchors
    }

    public static func empty(_ style: StructuredPathStyle) -> StructuredTree {
        StructuredTree(pathStyle: style, nodes: [], roots: [], childIndex: [], tags: [:], anchors: [:])
    }

    public var count: Int { nodes.count }
    public var isEmpty: Bool { nodes.isEmpty }
    public subscript(index: Int) -> StructuredNode { nodes[index] }

    /// The kept children of `node`, in source order.
    public func children(of node: Int) -> [Int] {
        children(of: node, in: 0..<nodes[node].childCount)
    }

    /// A page of `node`'s children, for an outline that asks for rows as they scroll into view.
    public func children(of node: Int, in range: Range<Int>) -> [Int] {
        let n = nodes[node]
        let lower = max(0, range.lowerBound), upper = min(n.childCount, range.upperBound)
        guard upper > lower else { return [] }
        let start = Int(n.childStartRaw)
        return childIndex[(start + lower)..<(start + upper)].map(Int.init)
    }

    /// The `position`-th kept child of `node`, nil past the end.
    public func child(_ position: Int, of node: Int) -> Int? {
        let n = nodes[node]
        guard position >= 0, position < n.childCount else { return nil }
        return Int(childIndex[Int(n.childStartRaw) + position])
    }

    /// The YAML tag as written (`!!str`, `!custom`), when the node had one.
    public func tag(of node: Int) -> String? { tags[Int32(node)] }
    /// The YAML anchor name (without `&`), when the node had one.
    public func anchor(of node: Int) -> String? { anchors[Int32(node)] }

    /// The deepest kept node's depth (0 for a lone scalar).
    public var maxStoredDepth: Int { nodes.reduce(0) { max($0, $1.depth) } }

    /// The root `node` belongs to.
    public func root(of node: Int) -> Int {
        var current = node
        while let parent = nodes[current].parent { current = parent }
        return current
    }

    // MARK: Paths

    /// A readable path to `node` within its document: `$.users[3].name` or `/feed/entry[2]/title`. Built by walking
    /// parents, so it costs the node's depth (plus its siblings for an XPath predicate), never the tree's size.
    public func path(of node: Int) -> String {
        var chain: [Int] = []
        var current: Int? = node
        while let index = current { chain.append(index); current = nodes[index].parent }
        chain.reverse()
        switch pathStyle {
        case .jsonPath: return jsonPath(chain)
        case .xpath: return xpath(chain)
        }
    }

    /// `path(of:)` prefixed with its document when the tree holds more than one: "line 42: $.name" for JSON Lines,
    /// "document 2: $.spec" for YAML.
    public func qualifiedPath(of node: Int, rootLabel: (Int) -> String? = { _ in nil }) -> String {
        let base = path(of: node)
        let rootNode = root(of: node)
        if let label = rootLabel(rootNode) { return "\(label): \(base)" }
        guard roots.count > 1, pathStyle == .jsonPath else { return base }
        return "document \(nodes[rootNode].indexInParent + 1): \(base)"
    }

    private func jsonPath(_ chain: [Int]) -> String {
        var out = "$"
        for index in chain.dropFirst() {
            let node = nodes[index]
            guard let parent = node.parent else { continue }
            if nodes[parent].kind == .array || node.name == nil {
                out += "[\(node.indexInParent)]"
            } else if let name = node.name {
                out += Self.isIdentifier(name) ? ".\(name)" : "[\(Self.quoted(name))]"
            }
        }
        return out
    }

    private func xpath(_ chain: [Int]) -> String {
        var out = ""
        for index in chain {
            let node = nodes[index]
            switch node.role {
            case .attribute: out += "/@\(node.name ?? "")"
            case .text, .cdata: out += "/text()" + xpathPredicate(index) { $0.role == .text || $0.role == .cdata }
            case .comment: out += "/comment()" + xpathPredicate(index) { $0.role == .comment }
            case .processingInstruction:
                let target = node.name ?? ""
                out += "/processing-instruction('\(target)')" + xpathPredicate(index) {
                    $0.role == .processingInstruction && $0.name == target
                }
            default:
                let name = node.name ?? "*"
                out += "/\(name)" + xpathPredicate(index) { $0.role == node.role && $0.name == name }
            }
        }
        return out.isEmpty ? "/" : out
    }

    /// "[n]" (1-based) when the node shares its name with a sibling, as XPath needs to tell them apart; "" otherwise.
    private func xpathPredicate(_ index: Int, sameAs matches: (StructuredNode) -> Bool) -> String {
        let siblings: [Int]
        if let parent = nodes[index].parent { siblings = children(of: parent) } else { siblings = roots }
        var position = 0, total = 0
        for sibling in siblings where matches(nodes[sibling]) {
            total += 1
            if sibling == index { position = total }
        }
        return total > 1 ? "[\(position)]" : ""
    }

    /// RFC 9535 member-name shorthand: `name-first` is a letter, `_` or any non-ASCII character; digits may follow.
    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.utf8.first else { return false }
        func nameFirst(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b >= 0x80 }
        guard nameFirst(first) else { return false }
        return name.utf8.allSatisfy { nameFirst($0) || ($0 >= 48 && $0 <= 57) }
    }

    static func quoted(_ name: String) -> String {
        var out = "\""
        for scalar in name.unicodeScalars {
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
}
