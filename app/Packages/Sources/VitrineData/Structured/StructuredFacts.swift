import Foundation

/// One fact for the metadata strip. VitrineData does not depend on VitrineDocument, so this mirrors `Fact` (stable
/// key, label, display value) and the document layer maps it one to one, as it does `CSVFact`.
public struct StructuredFact: Sendable, Equatable {
    public var key: String
    public var label: String
    public var value: String
}

/// The facts a structured preview shows. Typed values first, display strings on request, so a banner can reason on
/// `error` while the strip just prints.
public struct StructuredFacts: Sendable, Equatable {
    public var format: StructuredFormat
    public var dialect: StructuredDialect
    /// Nodes kept in the tree.
    public var nodeCount: Int
    /// Nodes in the source as far as the parse saw (exact when the coverage says so).
    public var sourceNodeCount: Int
    public var maxDepth: Int
    /// The single top-level value's kind; nil when there are several roots (YAML documents, JSON Lines records).
    public var topLevelKind: StructuredNodeKind?
    /// Keys or items of the single top-level value; with several roots, how many.
    public var topLevelSize: Int?
    /// The XML document element's name.
    public var rootElementName: String?
    /// YAML documents or JSON Lines records; 1 otherwise.
    public var documentCount: Int
    public var error: StructuredDiagnostic?
    public var isMinified: Bool
    public var coverage: StructuredCoverage

    /// Keys: `format`, `nodes`, `depth`, `topLevel`, `documents` (YAML, JSON Lines), `layout` (when minified), `error`
    /// (when there is one), `coverage` (when partial).
    public func entries(locale: Locale = .current) -> [StructuredFact] {
        func number(_ n: Int) -> String { n.formatted(.number.locale(locale)) }
        var facts: [StructuredFact] = [StructuredFact(key: "format", label: String(localized: "Format", bundle: .module, comment: "Fact label for a structured file (JSON, YAML, TOML, XML, property list)."), value: dialect.displayName)]
        var nodes = number(nodeCount)
        if case .partial(_, let total, _) = coverage {
            nodes = total.map { String(localized: "\(number(nodeCount)) of \(number($0))", bundle: .module, comment: "Nodes fact value for a partial tree: nodes shown of the total.") }
                ?? String(localized: "\(number(nodeCount)) shown", bundle: .module, comment: "Nodes fact value for a partial tree whose total is unknown.")
        }
        facts.append(StructuredFact(key: "nodes", label: String(localized: "Nodes", bundle: .module, comment: "Fact label for a structured file (JSON, YAML, TOML, XML, property list). The number of values in the tree."), value: nodes))
        facts.append(StructuredFact(key: "depth", label: String(localized: "Depth", bundle: .module, comment: "Fact label for a structured file (JSON, YAML, TOML, XML, property list). How deeply values are nested."), value: number(maxDepth)))
        if let top = topLevelDescription(number) {
            facts.append(StructuredFact(key: "topLevel", label: String(localized: "Top level", bundle: .module, comment: "Fact label for a structured file (JSON, YAML, TOML, XML, property list). What the outermost value is."), value: top))
        }
        if format == .yaml {
            facts.append(StructuredFact(key: "documents", label: String(localized: "Documents", bundle: .module, comment: "Fact label for a structured file (JSON, YAML, TOML, XML, property list). The number of YAML documents in the file."), value: number(documentCount)))
        } else if dialect == .jsonLines {
            facts.append(StructuredFact(key: "documents", label: String(localized: "Records", bundle: .module, comment: "Fact label for a structured file (JSON, YAML, TOML, XML, property list). The number of lines (records) in a JSON Lines file."), value: number(documentCount)))
        }
        if isMinified {
            facts.append(StructuredFact(key: "layout", label: String(localized: "Layout", bundle: .module, comment: "Fact label for a structured file (JSON, YAML, TOML, XML, property list). How the text is laid out."), value: String(localized: "Minified", bundle: .module, comment: "Layout fact value: the file is squeezed onto very long lines.")))
        }
        if let error {
            let value: String
            switch (error.location, error.location?.column) {
            case (let location?, let column?): value = String(localized: "Line \(number(location.line)), column \(number(column)): \(error.reason)", bundle: .module, comment: "Error fact value: where a syntax error is, then the problem.")
            case (let location?, nil): value = String(localized: "Line \(number(location.line)): \(error.reason)", bundle: .module, comment: "Error fact value: the line of a syntax error, then the problem.")
            default: value = error.reason
            }
            facts.append(StructuredFact(key: "error", label: String(localized: "Error", bundle: .module, comment: "Fact label for a structured file (JSON, YAML, TOML, XML, property list). The first syntax error."), value: value))
        }
        if let note = coverage.note { facts.append(StructuredFact(key: "coverage", label: String(localized: "Shown", bundle: .module, comment: "Fact label for a structured file (JSON, YAML, TOML, XML, property list). How much of the file the tree shows."), value: note)) }
        return facts
    }

    private func topLevelDescription(_ number: (Int) -> String) -> String? {
        if let rootElementName {
            let size = topLevelSize ?? 0
            return size == 1 ? String(localized: "<\(rootElementName)>, 1 child", bundle: .module, comment: "Top level fact value for XML: the root element and its one child.")
                : String(localized: "<\(rootElementName)>, \(number(size)) children", bundle: .module, comment: "Top level fact value for XML: the root element and how many children (not 1).")
        }
        guard let kind = topLevelKind else {
            return topLevelSize.map { dialect == .jsonLines ? String(localized: "\(number($0)) records", bundle: .module, comment: "Top level fact value: the number of JSON Lines records.")
                : String(localized: "\(number($0)) documents", bundle: .module, comment: "Top level fact value: the number of YAML documents.") }
        }
        let size = topLevelSize ?? 0
        switch kind {
        case .object: return size == 1 ? String(localized: "Object, 1 key", bundle: .module, comment: "Top level fact value: an object with one key.")
            : String(localized: "Object, \(number(size)) keys", bundle: .module, comment: "Top level fact value: an object and how many keys (not 1).")
        case .array: return size == 1 ? String(localized: "Array, 1 item", bundle: .module, comment: "Top level fact value: an array with one item.")
            : String(localized: "Array, \(number(size)) items", bundle: .module, comment: "Top level fact value: an array and how many items (not 1).")
        default: return kind.displayName
        }
    }
}

extension StructuredParseResult {
    public var facts: StructuredFacts {
        var kind: StructuredNodeKind?
        var size: Int?
        var element: String?
        let tree = self.tree
        if format == .xml, let root = tree.roots.first(where: { tree[$0].role == .element }) {
            element = tree[root].name
            size = tree[root].sourceChildCount
            kind = .object
        } else if tree.roots.count == 1, format != .jsonLines, let root = tree.roots.first {
            kind = tree[root].kind
            size = tree[root].kind.isContainer ? tree[root].sourceChildCount : nil
        } else if !tree.roots.isEmpty {
            size = documentCount
        }
        return StructuredFacts(format: format, dialect: dialect, nodeCount: tree.count, sourceNodeCount: sourceNodeCount,
                               maxDepth: maxDepth, topLevelKind: kind, topLevelSize: size, rootElementName: element,
                               documentCount: documentCount, error: error, isMinified: layout.isMinified, coverage: coverage)
    }
}
