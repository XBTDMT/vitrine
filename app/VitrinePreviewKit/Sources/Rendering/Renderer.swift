import AppKit
import VitrineDocument
import VitrineSupport
import VitrineUI

/// A finished preview: the view Quick Look shows, the document it was drawn from, and what the controller needs to
/// manage it.
@MainActor
public final class RenderedPreview {
    public let view: NSView
    /// What was parsed (ARCHITECTURE §4); the same value feeds describe, MCP and thumbnails.
    public private(set) var document: PreviewDocument
    public var kind: FileKind { document.kind }
    /// Called when the file changed on disk and the view can update in place without flicker; returns the re-parsed
    /// document. nil = re-render from scratch.
    public let reload: (@MainActor (URL) async throws -> PreviewDocument)?
    /// Current vertical scroll offset, for scroll memory; nil when the view does not scroll.
    public let scrollOffset: (@MainActor () -> Double?)?
    public let restoreScroll: (@MainActor (Double) -> Void)?
    /// Shows or hides the preview's own side column (Markdown's contents); nil when it has none.
    public let toggleInspector: (@MainActor () -> Void)?
    /// Finds in the preview's own view (the query, forward or back); nil = the view cannot be searched.
    public let find: (@MainActor (String, Bool) async -> FindResult)?
    public let clearFind: (@MainActor () -> Void)?
    /// Native views in the viewer switch: called with the index the switch picked (0 included, so the renderer can go
    /// back to its first view). Return true when the renderer now shows that view inside its own `view` (a structured
    /// file's Tree beside its Source); false lets the host show that index's text in the native text view, as it does
    /// for every document without this. nil = the renderer draws only view 0. roadmap: S-5
    public let showView: (@MainActor (Int) -> Bool)?
    /// The object that drew the view and receives its callbacks (a web page's messages). The controller keeps only
    /// the preview, so the preview keeps this alive for as long as the view is shown.
    private let owner: AnyObject?

    /// Export as HTML… (I-10): offered when the renderer can write its page as a standalone file (Markdown).
    public var htmlExporter: HTMLExporting? { owner as? HTMLExporting }

    public init(view: NSView, document: PreviewDocument, owner: AnyObject? = nil,
                reload: (@MainActor (URL) async throws -> PreviewDocument)? = nil,
                scrollOffset: (@MainActor () -> Double?)? = nil,
                restoreScroll: (@MainActor (Double) -> Void)? = nil,
                toggleInspector: (@MainActor () -> Void)? = nil,
                find: (@MainActor (String, Bool) async -> FindResult)? = nil,
                clearFind: (@MainActor () -> Void)? = nil,
                showView: (@MainActor (Int) -> Bool)? = nil,
                findStyle: FindStyle = .search) {
        self.view = view; self.document = document; self.owner = owner; self.reload = reload; self.scrollOffset = scrollOffset; self.restoreScroll = restoreScroll
        self.toggleInspector = toggleInspector; self.find = find; self.clearFind = clearFind; self.showView = showView
        self.findStyle = findStyle
        findModes = [findStyle]
    }

    /// Whether find marks matches or filters rows (tables).
    public let findStyle: FindStyle

    /// The modes the find field's badge switches between, the default first (data: Filter, then Query). roadmap: S-6
    public var findModes: [FindStyle]
    /// Runs a read-only SQL query in the Query mode and shows its rows in place of the file's (I-8); nil = no Query.
    public var query: (@MainActor (String) async -> QueryOutcome)?
    /// Leaves the query's rows and shows the file's own again.
    public var clearQuery: (@MainActor () -> Void)?
    /// The query field's placeholder: "SELECT * FROM orders".
    public var queryPlaceholder: String?
    /// The query language's name on the badge and in the mode menu: "SQL" for tables (G-13), "jq" for trees (G-17).
    public var queryLanguage = "SQL"

    /// What the preview says in the gutter; nil = the coverage line only.
    public private(set) var gutter: GutterStatus?
    /// Set by the host while the preview is on screen, so the gutter follows `updateGutter`.
    var gutterChanged: (@MainActor (GutterStatus?) -> Void)?
    /// Stops the long work the gutter shows as busy (the gutter's Cancel); nil = nothing to cancel.
    public var cancelWork: (@MainActor () -> Void)?

    /// The Copy-as menu (I-7): when set, the capsule's copy button opens these formats, headed by `copyHeading()`
    /// ("Copy 7 cells as"); nil = copy the document's text.
    public var copyFormats: (@MainActor () -> (heading: String, formats: [CopyFormat]))?

    /// Set by the host: shows one of the document's views in the viewer switch (the lint banner's "Text view").
    var viewRequested: (@MainActor (Int) -> Void)?
    public func requestView(_ index: Int) { viewRequested?(index) }

    public func updateGutter(_ status: GutterStatus?) {
        guard status != gutter else { return }
        gutter = status
        gutterChanged?(status)
    }

    /// Prefixes the find field turns into a badge (code state 1); empty = plain find.
    public var findPrefixes: [FindPrefix] = []
    /// Fold to matches (code state 1): folds the lines away from every match, or unfolds them; nil = no button.
    public var foldToMatches: (@MainActor (Bool) -> Void)?

    /// Set by the host while the preview is on screen when it offers its Details sheet (every fact and the token meter,
    /// chrome r3-b, A-4) for a text preview without a side panel of its own; nil when it offers none.
    var toggleDetails: (@MainActor () -> Void)?
    /// True when `toggleInspector` hands on to the host's Details whenever the renderer's own panel is not on screen
    /// (code: the hex decoder exists only in the Hex view), so the host offers Details beside it.
    public var defersToHostDetails = false
    /// Shows or hides the host's Details sheet; nothing when the host offers none.
    public func toggleHostDetails() { toggleDetails?() }

    /// The capsule's More button (code state 15: theme, wrap, line numbers…); nil = no button.
    public var displayOptions: (@MainActor () -> Void)?

    /// Set by the host while the preview is on screen, so the capsule's count follows a find that is still streaming.
    var findResultChanged: (@MainActor (FindResult) -> Void)?

    /// A find still reading the file (a huge file, state 14) has more matches or has finished: the capsule's count
    /// follows ("18 so far", then "3 of 41").
    public func updateFindResult(_ result: FindResult) { findResultChanged?(result) }

    /// A reload re-parsed the file; the view was updated in place.
    func replaceDocument(_ document: PreviewDocument) { self.document = document }

    /// Set by the host while the preview is on screen, so the capsule follows `updateDocument`.
    var documentChanged: (@MainActor (PreviewDocument) -> Void)?

    /// The renderer learned more after the first paint (an exact row count, another table picked): the document is
    /// replaced and the capsule's pill, tooltip and viewer switch follow.
    public func updateDocument(_ document: PreviewDocument) {
        self.document = document
        documentChanged?(document)
    }
}

/// One renderer per file family. Renderers are chosen by `RendererRegistry` from the sniffed `FileKind`.
@MainActor
public protocol Renderer {
    static func canRender(_ kind: FileKind) -> Bool
    init()
    func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview
}

public struct RenderContext: Sendable {
    public var tokens: DesignTokens
    public var appearance: DesignTokens.Appearance
    public var defaultsSuite: String?
    /// Where renderers keep caches (drawn diagrams); nil = the process's own caches folder.
    public var cachesDirectory: URL?
    public var defaults: UserDefaults { VitrineDefaults.defaults(suite: defaultsSuite) }
    public init(tokens: DesignTokens = .standard, appearance: DesignTokens.Appearance, defaultsSuite: String? = VitrineDefaults.suiteName,
                cachesDirectory: URL? = nil) {
        self.tokens = tokens; self.appearance = appearance; self.defaultsSuite = defaultsSuite; self.cachesDirectory = cachesDirectory
    }
}

public enum RenderError: Error, LocalizedError, Sendable {
    case unreadable(URL)
    case unsupported(FileKind)
    case tooLarge(Int64)
    case cancelled
    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return String(localized: "Cannot read \(url.lastPathComponent)", bundle: .previewKit, comment: "Preview error; the argument is the file's name.")
        case .unsupported:
            return String(localized: "No preview for this file type", bundle: .previewKit, comment: "Preview error: Vitrine has no preview for the file's kind.")
        case .tooLarge(let n):
            return String(localized: "File too large to preview (\(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)))", bundle: .previewKit,
                          comment: "Preview error; the argument is the file's size, such as '2.1 GB'.")
        case .cancelled:
            return String(localized: "Preview cancelled", bundle: .previewKit, comment: "Preview error: the preview was stopped.")
        }
    }
}

/// Ordered list of renderer types; the first whose `canRender` says yes wins. Families register themselves here;
/// the order is the priority (a specific renderer before the plain-text fallback).
@MainActor
public enum RendererRegistry {
    public static var renderers: [any Renderer.Type] = [MarkdownRenderer.self, NotebookRenderer.self, ArchiveRenderer.self, FolderRenderer.self, DataRenderer.self,
                                                        BinaryCardRenderer.self, SessionRenderer.self, StructuredRenderer.self, DiffRenderer.self, CodeRenderer.self, SVGRenderer.self, ImageRenderer.self,
                                                        FontRenderer.self, HexRenderer.self,
                                                        PlainTextRenderer.self]

    public static func renderer(for kind: FileKind) -> (any Renderer)? {
        renderers.first { $0.canRender(kind) }?.init()
    }
}

/// A renderer that can write what it shows as one self-contained HTML file: styles, pictures and maths fonts inside,
/// no script, nothing fetched when it opens (I-10). roadmap: S-24
@MainActor
public protocol HTMLExporting: AnyObject {
    func exportHTML(title: String) async throws -> String
}
