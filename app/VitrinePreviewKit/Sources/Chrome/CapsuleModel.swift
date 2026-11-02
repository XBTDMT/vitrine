import AppKit
import Observation
import VitrineDocument
import VitrineSupport

/// What the Glass Capsule shows and does for the preview on screen (D1: one frame under every preview; chrome
/// design r3-b, design/mockups/unified/chrome.html). The controller owns one model and swaps the document in;
/// the SwiftUI views only read it and call its actions. roadmap: S-24
@MainActor
@Observable
final class CapsuleModel {
    private(set) var document: PreviewDocument?
    /// Which of the document's views is showing (the viewer switch); 0 is the renderer's own view.
    private(set) var viewIndex = 0
    private(set) var copied = false
    var canToggleInspector = false
    var canFind = false
    /// The find field: open or closed, its text, and the last result.
    private(set) var finding = false
    var findQuery = ""
    private(set) var findResult: FindResult?
    /// Apps for "Open in…"; empty hides the menu.
    var openInApps: [OpenInApp] = []
    /// "Reveal in Finder" (X-3, through VitrineHelper): shown when the preview is of a file on disk.
    var canReveal = false
    /// In the Vitrine window the window's toolbar carries Open with and Info (system rule V7), so the capsule
    /// leaves out Open in… and the inspector toggle.
    var hidesWindowActions = false
    /// Search (mark and step), filter (keep matching rows) or query (SQL) for the preview on screen.
    var findStyle: FindStyle = .search
    /// The modes the badge switches between, the default first; one or none = no switch (I-8). roadmap: S-6
    var findModes: [FindStyle] = []
    /// The last query run's outcome in the Query mode.
    private(set) var queryOutcome: QueryOutcome?
    /// A query is running (the field says so until it returns).
    private(set) var queryRunning = false
    var queryPlaceholder: String?
    var queryLanguage = "SQL"
    /// The preview's own gutter text and busy state, beside the capsule.
    var gutter: GutterStatus?
    /// The preview's Copy-as menu; nil = the copy button copies the document's text.
    @ObservationIgnored var copyFormats: (@MainActor () -> (heading: String, formats: [CopyFormat]))?

    /// Wired by the controller.
    @ObservationIgnored var onShowView: ((Int) -> Void)?
    @ObservationIgnored var onToggleInspector: (() -> Void)?
    /// Find prefixes (code state 1): the one typed, shown as a badge, and those the preview offers.
    var findPrefixes: [FindPrefix] = []
    var findPrefix: FindPrefix?
    /// Fold to matches (code state 1).
    var canFoldToMatches = false
    var foldedToMatches = false
    @ObservationIgnored var onFoldToMatches: ((Bool) -> Void)?

    func toggleFoldToMatches() {
        foldedToMatches.toggle()
        onFoldToMatches?(foldedToMatches)
    }

    /// A prefix typed at the start of the field becomes the badge; the field keeps the rest.
    func takePrefix() {
        guard findPrefix == nil else { return }
        for p in findPrefixes.sorted(by: { $0.token.count > $1.token.count }) where findQuery.hasPrefix(p.token) {
            findPrefix = p
            findQuery = String(findQuery.dropFirst(p.token.count))
            return
        }
    }

    /// Delete in an empty field takes the badge away.
    func dropPrefix() -> Bool {
        guard findPrefix != nil, findQuery.isEmpty else { return false }
        findPrefix = nil
        onClearFind?()
        findResult = nil
        return true
    }

    /// The More button (code state 15): shown when the preview has display options.
    var canShowDisplayOptions = false
    @ObservationIgnored var onDisplayOptions: (() -> Void)?
    func showDisplayOptions() { onDisplayOptions?() }
    @ObservationIgnored var onFind: ((String, Bool) async -> FindResult)?
    @ObservationIgnored var onClearFind: (() -> Void)?
    @ObservationIgnored var onQuery: ((String) async -> QueryOutcome)?
    @ObservationIgnored var onOpenIn: ((OpenInApp) -> Void)?
    @ObservationIgnored var onReveal: (() -> Void)?
    @ObservationIgnored var onCancelWork: (() -> Void)?
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    @ObservationIgnored private var copiedReset: Task<Void, Never>?

    func show(_ document: PreviewDocument, canToggleInspector: Bool, canFind: Bool) {
        if self.document?.kind != document.kind || self.document?.views.count != document.views.count { viewIndex = 0 }
        self.document = document
        self.canToggleInspector = canToggleInspector
        self.canFind = canFind
        if !canFind { closeFind() }
    }

    /// The metadata strip's settings (I-13): which facts, in what order, how loud. Set by the host from the defaults.
    var strip = MetadataStrip.Settings.standard
    /// What the host knows about the file beyond the document: its date and the app that opens it.
    var fileFacts = MetadataStrip.FileFacts()

    /// "Markdown · 4.2 KB · ≈ 890 tok": the strip's facts in its order. By default the kind (a family that names the
    /// file more finely gives a `kindName`: "Photo", "Animated image"), the family's headline ("3,214 rows × 8 columns",
    /// "Syntax error at 12:5", "66 lines"), the size, the encoding and the token count.
    var pillText: String {
        guard let d = document else { return "" }
        return MetadataStrip.parts(d, settings: strip, file: fileFacts).joined(separator: " · ")
    }

    /// The pill's tooltip: every warning first, then every fact, one per line.
    var pillDetail: String {
        guard let d = document else { return "" }
        let badges = d.badges.sorted { $0.level > $1.level }.map { Self.labelled($0.title, $0.detail) }
        let facts = d.facts.filter { $0.key != "headline" }.map { Self.labelled($0.label, $0.value) }
        return (badges + facts).joined(separator: "\n")
    }

    /// "Label: value", one line of the pill's tooltip.
    static func labelled(_ label: String, _ value: String) -> String {
        String(localized: "\(label): \(value)", bundle: .previewKit,
               comment: "One line of the capsule pill's tooltip: a fact's label, then its value.")
    }

    /// The state dot: grey when calm, the caution or danger colour when a lens found something (chrome: one state).
    var dotToken: String {
        switch document?.badges.map(\.level).max() {
        case .danger?: "danger"
        case .caution?: "caution"
        default: document?.fact("verdict")?.value == FamilyFacts.noProblems ? "ok" : "t3"
        }
    }

    /// The gutter's left home: how much is shown, when not all of it is.
    var coverageText: String? {
        guard case .partial(let shown, let total, let unit, _)? = document?.coverage else { return nil }
        let fmt: (Int64) -> String = { n in
            unit == .bytes ? ByteCountFormatter.string(fromByteCount: n, countStyle: .file) : n.formatted()
        }
        // Each sentence whole, one per unit (H-6): bytes come formatted as sizes, the counts as numbers.
        if let total {
            switch unit {
            case .bytes: return String(localized: "Showing \(fmt(shown)) of \(fmt(total))", bundle: .previewKit,
                                       comment: "Gutter coverage line: how much of a large file is shown, both as sizes ('1 MB of 12.6 MB').")
            case .rows: return String(localized: "Showing \(shown) of \(total) rows", bundle: .previewKit,
                                      comment: "Gutter coverage line for a table.")
            case .members: return String(localized: "Showing \(shown) of \(total) members", bundle: .previewKit,
                                         comment: "Gutter coverage line for an archive listing.")
            case .nodes: return String(localized: "Showing \(shown) of \(total) nodes", bundle: .previewKit,
                                       comment: "Gutter coverage line for a JSON/YAML tree.")
            }
        }
        switch unit {
        case .bytes: return String(localized: "Showing the first \(fmt(shown))", bundle: .previewKit,
                                   comment: "Gutter coverage line when the total is unknown: the first part shown, as a size.")
        case .rows: return String(localized: "Showing the first \(shown) rows", bundle: .previewKit,
                                  comment: "Gutter coverage line for a table whose total is unknown.")
        case .members: return String(localized: "Showing the first \(shown) members", bundle: .previewKit,
                                     comment: "Gutter coverage line for an archive whose total is unknown.")
        case .nodes: return String(localized: "Showing the first \(shown) nodes", bundle: .previewKit,
                                   comment: "Gutter coverage line for a tree whose total is unknown.")
        }
    }

    var viewTitles: [String] { document.map { $0.viewTitles ?? $0.views.map(\.title) } ?? [] }

    /// A newly embedded preview opens on its first view, even when the last file had as many views of the same kind.
    func resetViewSwitch() { viewIndex = 0 }

    func selectView(_ index: Int) {
        guard let d = document, d.views.indices.contains(index), index != viewIndex else { return }
        viewIndex = index
        onShowView?(index)
    }

    /// Export (I-10): only where Vitrine may save a file, the Vitrine window; HTML where the renderer can write a page.
    var canExport = false
    var canExportHTML = false
    @ObservationIgnored var onCopyImage: (@MainActor () async -> Bool)?
    @ObservationIgnored var onExport: ((PreviewExport.Format) -> Void)?

    /// Copy as Image (I-10): the preview as drawn, and the same tick.
    func copyImage() {
        Task { if await onCopyImage?() == true { showCopied() } }
    }

    func export(_ format: PreviewExport.Format) { onExport?(format) }

    /// Copies the document's text (Markdown: its source), and shows a tick for a moment.
    func copy() {
        guard let text = document?.searchText, !text.isEmpty else { return }
        copy(text)
    }

    /// Copies one Copy-as format's text, and shows the same tick.
    func copy(_ format: CopyFormat) {
        guard let perform = format.perform else { copy(format.text()); return }
        Task { if await perform(pasteboard) { showCopied() } }
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showCopied()
    }

    private func showCopied() {
        copied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { self?.copied = false }
        }
    }

    func toggleInspector() { onToggleInspector?() }

    func open(in app: OpenInApp) { onOpenIn?(app) }
    func reveal() { onReveal?() }

    func cancelWork() { onCancelWork?() }

    /// The side panel's button names what it opens: Markdown's contents on the left, the data Inspector and the
    /// card's Details on the right.
    var inspectorSymbol: String {
        if case .markdown? = document?.kind { return "sidebar.left" }
        // The hex inspector's byte decoder is a drawer under the rows (code 13). roadmap: S-5
        if case .binary? = document?.kind { return "rectangle.bottomthird.inset.filled" }
        return "sidebar.right"
    }

    var inspectorHelp: String {
        switch document?.kind {
        case .markdown?:
            return String(localized: "Show or hide the contents", bundle: .previewKit,
                          comment: "Capsule button tooltip: toggles a Markdown file's table of contents.")
        case .csv?, .sqlite?, .dataset?:
            return String(localized: "Show or hide the Inspector", bundle: .previewKit,
                          comment: "Capsule button tooltip: toggles the data Inspector panel.")
        case .appBundle?, .installerPackage?, .diskImage?, .provisioningProfile?:
            return String(localized: "Show or hide Details", bundle: .previewKit,
                          comment: "Capsule button tooltip: toggles a card's Details panel.")
        case .binary?:
            return String(localized: "Show or hide the byte decoder", bundle: .previewKit,
                          comment: "Capsule button tooltip: toggles the hex view's byte decoder.")
        default:
            return String(localized: "Show or hide the side panel", bundle: .previewKit,
                          comment: "Capsule button tooltip: toggles the preview's side panel.")
        }
    }

    /// The gutter's left: the preview's own line (position, matches) when it has one, else the coverage line.
    var gutterLeading: String? { gutter?.leading ?? coverageText }

    // MARK: Find

    func openFind() { finding = true }

    /// Return finds the next match, Shift-Return the previous; a changed query starts from the top.
    func find(forward: Bool = true) async {
        // A query runs on Return (`runQuery`), never per keystroke.
        guard canFind, findStyle != .query, let onFind else { return }
        guard !findQuery.isEmpty else { onClearFind?(); findResult = nil; return }
        if foldedToMatches, findPrefix == nil { foldedToMatches = false }
        findResult = await onFind((findPrefix?.token ?? "") + findQuery, forward)
        if foldedToMatches { onFoldToMatches?(true) }
    }

    /// A streaming find reported more (huge files): shown only while the field is open on a search.
    func streamedFindResult(_ result: FindResult) {
        guard finding, findStyle == .search, !findQuery.isEmpty else { return }
        findResult = result
    }

    /// Done and Escape: the file's own rows again, and the next ⌘F opens on the default mode.
    func closeFind() {
        if finding || findResult != nil || queryOutcome != nil { onClearFind?() }
        finding = false
        findQuery = ""
        findPrefix = nil
        foldedToMatches = false
        findResult = nil
        queryOutcome = nil
        if let first = findModes.first { findStyle = first }
    }

    // MARK: Query (I-8)

    /// The badge's menu: Filter or Query. Switching leaves the other mode's rows and starts with an empty field.
    func setFindMode(_ mode: FindStyle) {
        guard findModes.contains(mode), mode != findStyle else { return }
        if findResult != nil || queryOutcome != nil || !findQuery.isEmpty { onClearFind?() }
        findQuery = ""
        findResult = nil
        queryOutcome = nil
        findStyle = mode
    }

    /// Return in the Query mode: runs the SQL read-only; the outcome's line replaces the count.
    func runQuery() async {
        guard canFind, findStyle == .query, let onQuery else { return }
        let sql = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }
        queryRun += 1
        let run = queryRun
        queryRunning = true
        let outcome = await onQuery(sql)
        // A newer Return superseded this run: its outcome is the one to show.
        guard run == queryRun else { return }
        queryRunning = false
        // Done pressed while it ran: the field is gone, so is the outcome.
        guard finding, findStyle == .query else { return }
        queryOutcome = outcome
    }

    @ObservationIgnored private var queryRun = 0

    /// The badge's word: SQL in the Query mode (data 1), Filter otherwise.
    var findModeTitle: String {
        switch findStyle {
        case .query: queryLanguage
        case .filter: String(localized: "Filter", bundle: .previewKit, comment: "Find field mode badge: keep only the matching rows.")
        case .search: String(localized: "Find", bundle: .previewKit, comment: "Find field mode badge: mark and step through matches.")
        }
    }

    /// The mode menu's words for the plain mode: tables filter rows, trees find.
    var plainModeTitle: String {
        findModes.first == .filter
            ? String(localized: "Filter rows", bundle: .previewKit, comment: "Find mode menu item: filter a table's rows.")
            : String(localized: "Find", bundle: .previewKit, comment: "Find field mode badge: mark and step through matches.")
    }

    /// Why the last query did not run, in its engine's words ("no such column: nope", "jq: error: …"); nil otherwise.
    var queryFailure: String? {
        guard findStyle == .query, !queryRunning, let outcome = queryOutcome else { return nil }
        return outcome.message
    }

    /// "3 of 12", "No matches", "3 of 12+" when the search stopped at its bound, or nothing before the first search.
    var findCountText: String? {
        if findStyle == .query {
            if queryRunning { return String(localized: "Running…", bundle: .previewKit, comment: "Find field: a query is running.") }
            guard let outcome = queryOutcome else { return nil }
            return outcome.message == nil ? outcome.summary
                : String(localized: "Didn't run", bundle: .previewKit, comment: "Find field: the query did not run (its error shows on hover).")
        }
        guard let r = findResult else { return nil }
        if findStyle == .filter {
            // Filter (data 1): how many rows are left, a floor while the scan has not reached the end.
            if r.count == 0 {
                return r.searchedAll ? String(localized: "No rows", bundle: .previewKit, comment: "Filter result: no row matches.")
                    : String(localized: "No rows yet", bundle: .previewKit, comment: "Filter result: no row matches so far; the scan goes on.")
            }
            return r.searchedAll ? String(localized: "\(r.count) rows", bundle: .previewKit, comment: "Filter result: how many rows match.")
                : String(localized: "≥ \(r.count) rows", bundle: .previewKit,
                         comment: "Filter result while the scan goes on: at least this many rows match.")
        }
        if let label = r.label { return label }
        if r.inProgress {
            // A find still reading a huge file (state 14): "18 so far", "3 of 18 so far".
            return r.index < 0
                ? String(localized: "\(r.count) so far", bundle: .previewKit, comment: "Find result while still reading a huge file: matches found so far.")
                : String(localized: "\(r.index + 1) of \(r.count) so far", bundle: .previewKit,
                         comment: "Find result while still reading a huge file: the current match of those found so far.")
        }
        if r.count == 0 {
            return r.searchedAll ? String(localized: "No matches", bundle: .previewKit, comment: "Find result: nothing matches.")
                : String(localized: "No matches (search stopped early)", bundle: .previewKit,
                         comment: "Find result: nothing matched before the search reached its bound.")
        }
        return r.searchedAll
            ? String(localized: "\(r.index + 1) of \(r.count)", bundle: .previewKit, comment: "Find result: the current match of all matches, e.g. '3 of 12'.")
            : String(localized: "\(r.index + 1) of \(r.count)+", bundle: .previewKit,
                     comment: "Find result when the search stopped at its bound, so the count is a floor: '3 of 12+'.")
    }
}
