import Foundation

/// How strictly a `.json` file is read.
public enum JSONSyntax: String, Sendable, Equatable, Codable {
    /// RFC 8259 first; when that fails, the lenient reader, and the dialect it needed (JSONC, JSON5, JSON Lines) is
    /// reported. What a viewer wants: `.json` files in the wild are often JSONC (VS Code settings) or JSON Lines.
    case automatic
    /// RFC 8259 only: the first violation is the error.
    case strict
    /// JSONC and JSON5: comments, trailing commas, single quotes, unquoted keys, hex, `+Infinity`, `NaN`.
    case lenient
}

/// Every bound the structured engines work within. The defaults fit ARCHITECTURE §7: a tree stays well under the
/// extension's 300 MB and a hostile file stops at a limit with a partial tree instead of exhausting memory or stack.
public struct StructuredOptions: Sendable, Equatable {
    /// Nodes kept in a tree. Parsing goes on counting past it, so the coverage note can say "of N".
    public var maxNodes = 500_000
    /// Nodes deeper than this are counted but not kept. Every parser here is iterative, so depth costs heap, never
    /// stack; the limit keeps the outline usable.
    public var maxDepth = 512
    /// Bytes read from a file for one tree. A larger file gets a partial tree of its first part.
    public var maxInputBytes: Int64 = 64 * 1024 * 1024
    /// A value preview is cut to this many UTF-8 bytes (at a character boundary) and marked truncated.
    public var maxPreviewBytes = 256
    /// Object keys and names longer than this are cut and end in "…".
    public var maxKeyBytes = 1024
    /// YAML: nodes that alias expansion may add in total. Stops "billion laughs" (nested aliases doubling a tree).
    public var maxAliasExpansionNodes = 100_000
    /// XML: character data XMLParser may deliver, as a multiple of the input size (plus 1 MB). Internal entities
    /// that expand past it abort the parse (the XML form of billion laughs).
    public var maxEntityExpansionRatio: Int64 = 8
    /// Diagnostics kept per parse (bad JSON Lines lines, unsupported YAML constructs).
    public var maxDiagnostics = 1_000
    public var jsonSyntax: JSONSyntax = .automatic
    /// JSON Lines: a line longer than this is reported, not parsed.
    public var maxLineBytes = 16 * 1024 * 1024
    /// JSON Lines: one line-start checkpoint every this many lines (a seek then skips at most this many lines).
    public var lineIndexStride = 256
    /// JSON Lines: indexing stops here and reports partial coverage.
    public var lineIndexByteLimit: Int64 = 4 * 1024 * 1024 * 1024
    /// Formatted text stops here and says so.
    public var maxFormattedBytes = 64 * 1024 * 1024

    public init() {}
}

/// Why a tree is not the whole document.
public enum StructuredLimit: Sendable, Equatable, Hashable, Codable {
    case nodeLimit(Int)
    case depthLimit(Int)
    /// Only the first `readBytes` of `fileSize` were read.
    case inputByteLimit(readBytes: Int64, fileSize: Int64)
    case aliasExpansionLimit(Int)
    case entityExpansionLimit
    /// The parse stopped at the error in `StructuredParseResult.error`.
    case syntaxError

    public var note: String {
        switch self {
        case .nodeLimit(let n): String(localized: "the node limit (\(n.formatted())) was reached", bundle: .module, comment: "Why a structured file's tree is partial; lower-case, no final period.")
        case .depthLimit(let n): String(localized: "nodes nested deeper than \(n.formatted()) levels are not shown", bundle: .module, comment: "Why a structured file's tree is partial; lower-case, no final period.")
        case .inputByteLimit(let read, let size):
            String(localized: "only the first \(ByteCountFormatter.string(fromByteCount: read, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) were read", bundle: .module, comment: "Why a structured file's tree is partial; the arguments are byte sizes; lower-case, no final period.")
        case .aliasExpansionLimit(let n): String(localized: "alias expansion stopped at \(n.formatted()) nodes", bundle: .module, comment: "Why a YAML tree is partial; lower-case, no final period.")
        case .entityExpansionLimit: String(localized: "entity expansion was stopped (the document expands far beyond its size)", bundle: .module, comment: "Why an XML tree is partial; lower-case, no final period.")
        case .syntaxError: String(localized: "the parse stopped at a syntax error", bundle: .module, comment: "Why a structured file's tree is partial; lower-case, no final period.")
        }
    }
}

/// What the tree accounts for, in ARCHITECTURE §4 terms (unit: nodes). Always rendered when partial.
public enum StructuredCoverage: Sendable, Equatable {
    case complete(nodes: Int)
    /// `totalNodes` is known when the parser still scanned the whole document after it stopped keeping nodes.
    case partial(shownNodes: Int, totalNodes: Int?, reasons: [StructuredLimit])

    public var isComplete: Bool { if case .complete = self { true } else { false } }

    public var reasons: [StructuredLimit] { if case .partial(_, _, let reasons) = self { reasons } else { [] } }

    /// "Showing 500,000 of 1,204,331 nodes: the node limit (500,000) was reached." nil when complete.
    public var note: String? {
        guard case .partial(let shown, let total, let reasons) = self else { return nil }
        let why = reasons.map(\.note).joined(separator: "; ")
        switch (total, why.isEmpty) {
        case (let total?, true): return String(localized: "Showing \(shown.formatted()) of \(total.formatted()) nodes.", bundle: .module, comment: "Coverage note for a partial structured-file tree.")
        case (let total?, false): return String(localized: "Showing \(shown.formatted()) of \(total.formatted()) nodes: \(why).", bundle: .module, comment: "Coverage note for a partial structured-file tree; the last argument lists the reasons.")
        case (nil, true): return String(localized: "Showing \(shown.formatted()) nodes.", bundle: .module, comment: "Coverage note for a partial structured-file tree whose total is unknown.")
        case (nil, false): return String(localized: "Showing \(shown.formatted()) nodes: \(why).", bundle: .module, comment: "Coverage note for a partial structured-file tree whose total is unknown; the last argument lists the reasons.")
        }
    }
}

/// A position in the source, as an editor would show it.
public struct StructuredLocation: Sendable, Equatable, Codable, CustomStringConvertible {
    /// 1-based.
    public var line: Int
    /// 1-based, in characters (Unicode scalars) from the line start; nil when the reader does not know it.
    public var column: Int?
    public var byteOffset: Int64?

    public init(line: Int, column: Int?, byteOffset: Int64? = nil) {
        self.line = line; self.column = column; self.byteOffset = byteOffset
    }

    public var description: String { column.map { "\(line):\($0)" } ?? "\(line)" }
}

/// One finding from a parse.
public struct StructuredDiagnostic: Sendable, Equatable, Codable, CustomStringConvertible {
    public enum Severity: String, Sendable, Equatable, Codable {
        /// The input is not valid in its format.
        case error
        /// Valid input this engine does not model (a YAML complex key); shown honestly rather than guessed.
        case unsupported
        /// Worth knowing, nothing is wrong (a DTD that was not loaded, transcoded input).
        case warning
    }

    public var severity: Severity
    public var location: StructuredLocation?
    /// Short, lower-case, no trailing period: "expected ',' or '}' after an object member".
    public var reason: String

    public init(_ severity: Severity, _ reason: String, at location: StructuredLocation? = nil) {
        self.severity = severity; self.reason = reason; self.location = location
    }

    /// "3:14: expected ':' after a key".
    public var description: String { location.map { "\($0): \(reason)" } ?? reason }
}
