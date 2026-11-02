import Foundation
import VitrineSupport

/// The one contract (ARCHITECTURE §4): every parser returns a `PreviewDocument`, every surface consumes one. One
/// parse feeds the Quick Look view, the thumbnail, the Vitrine window, `vitrine describe`, MCP, Spotlight text and
/// export. Its JSON form (`Codable`) is the describe and MCP output, so fields are added, never renamed.
public struct PreviewDocument: Sendable, Equatable, Codable {
    public var kind: FileKind
    /// A finer format than the kind says, when the parser found one: `claude-code-transcript`, `openapi-3.1`.
    public var dialect: String?
    /// Ordered facts for the metadata strip and cards.
    public var facts: [Fact]
    /// Trust and lens results. Lenses run after parsing and add badges; they never change the views.
    public var badges: [Badge]
    /// The alternatives the viewer switch offers, best first. Never empty.
    public var views: [DocumentView]
    /// Whether the views show the whole file. A partial document always says so on screen.
    public var coverage: Coverage
    /// The viewer switch's names for the views, one per view, when a family names them itself ("Rows" and "Schema"
    /// for SQLite, "Tree" for a structured file its renderer draws natively); nil = each view's own `title`.
    public var viewTitles: [String]?
    /// The text's language-model token count (A-4), for the context-fit meter; nil when the file is not text.
    /// Set with `setTokens`, which keeps the `tokens` fact in step.
    public var tokens: TokenCount?

    public init(kind: FileKind, dialect: String? = nil, facts: [Fact] = [], badges: [Badge] = [],
                views: [DocumentView], coverage: Coverage = .complete) {
        precondition(!views.isEmpty, "a document offers at least one view")
        self.kind = kind; self.dialect = dialect; self.facts = facts; self.badges = badges
        self.views = views; self.coverage = coverage
    }

    /// The first view, the one shown when the preview opens.
    public var primaryView: DocumentView { views[0] }

    public func fact(_ key: String) -> Fact? { facts.first { $0.key == key } }

    /// Plain text for find, Spotlight and token counts, produced on demand from the views: the first text-bearing
    /// view's source text, or for rendered Markdown with no source view, its HTML with the tags removed.
    public var searchText: String {
        for view in views {
            switch view {
            case .text(let s): return s
            case .code(let s, _): return s
            case .markdown, .formatted: continue
            }
        }
        for case .markdown(let m) in views { return m.html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
        return ""
    }
}

/// One fact: a stable key (`size`, `encoding`, `rows`), a label for people, and a display value.
public struct Fact: Sendable, Equatable, Codable {
    public var key: String
    public var label: String
    public var value: String

    public init(key: String, label: String, value: String) {
        self.key = key; self.label = label; self.value = value
    }
}

/// A trust or lens result. `evidence` points into the file (byte offsets) when the lens knows where.
public struct Badge: Sendable, Equatable, Codable {
    public enum Level: String, Sendable, Codable, Comparable {
        case info, caution, danger
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
        private var rank: Int { switch self { case .info: 0; case .caution: 1; case .danger: 2 } }
    }

    public var level: Level
    public var title: String
    public var detail: String
    public var evidence: Range<Int64>?

    public init(level: Level, title: String, detail: String, evidence: Range<Int64>? = nil) {
        self.level = level; self.title = title; self.detail = detail; self.evidence = evidence
    }
}

/// How much of the file the views show.
public enum Coverage: Sendable, Equatable, Codable {
    case complete
    /// `shown` bytes (or rows, per `unit`) of `total`, when the total is known; `reason` is said on screen.
    case partial(shown: Int64, total: Int64?, unit: Unit, reason: String)

    /// `nodes`: the nodes of a structured document's tree (S-5).
    public enum Unit: String, Sendable, Codable { case bytes, rows, members, nodes }

    public var isComplete: Bool { self == .complete }
}

/// One way of showing the document. Families add cases as they land (§4 lists the full set: table, tree, cards,
/// conversation, diff, hex, media, web); a new case is a compile error in every exhaustive switch, by design.
public enum DocumentView: Sendable, Equatable, Codable {
    case markdown(MarkdownContent)
    case code(String, language: String)
    /// The same content re-indented (a minified JSON, XML or property list), shown beside the original.
    case formatted(String, language: String)
    case text(String)

    /// The view's identifier for the viewer switch: English on purpose. The switch picks its icon and the pages pick
    /// their modes by it, and describe prints it; people see it translated through CapsuleView.displayTitle (H-6).
    public var title: String {
        switch self {
        case .markdown: "Rendered"
        case .code: "Code"
        case .formatted: "Formatted"
        case .text: "Source"
        }
    }
}

/// Rendered Markdown: the body HTML and its outline.
public struct MarkdownContent: Sendable, Equatable, Codable {
    public struct Heading: Sendable, Equatable, Codable {
        public var level: Int
        public var text: String
        public var id: String
        public init(level: Int, text: String, id: String) { self.level = level; self.text = text; self.id = id }
    }

    public var html: String
    public var headings: [Heading]

    public init(html: String, headings: [Heading]) { self.html = html; self.headings = headings }
}
