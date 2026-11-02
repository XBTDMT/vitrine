import AppKit
import VitrineUI

/// The native hex inspector (code design state 13, FEATURE-MAP E-8): offset | sixteen bytes in two groups of eight |
/// ASCII, drawn only for the rows in view from a paged source, so a file of any size opens at once. One selection is
/// shown in both columns; the drawer under the rows decodes the bytes at the cursor; printable runs are tinted and a
/// known signature's evidence bytes carry the danger tint. Find (bytes or text) streams over the file with progress
/// and Cancel; ":0x1F00" jumps to an offset. Copy as hex, C array, Base64, raw text or a hex dump.
///
/// Any renderer can offer a Hex view of its file: `HexView.make(url:)`, place it, and route the capsule's calls to
/// `find`, `clearFind`, `copyOffer`, `toggleInspector` and `cancelSearch`; set `onGutter` to feed the gutter.
/// `HexRenderer.preview(view:document:owner:)` does all of that for a preview of its own. roadmap: S-5
@MainActor
public final class HexView: NSView {
    /// The bytes on show; replaced on reload.
    public private(set) var source: HexByteSource
    /// What the first bytes say the file is, when they say.
    public private(set) var signature: HexSignature?
    /// The printable runs in the first `runsScanLength` bytes (the drawer's list and the Strings view).
    public private(set) var runs: [HexTextRun] = []
    public static let runsScanLength: Int64 = 1024 * 1024
    static let runsLimit = 2_000
    /// Copy as takes at most this much: the selection's (or the file's) first megabyte.
    public static let copyLimit: Int64 = 1024 * 1024

    let header = HexHeaderView()
    let scroll = NSScrollView()
    let spacer = HexSpacer()
    let canvas = HexCanvas()
    let drawer = HexDrawer()
    private var drawerHeight: NSLayoutConstraint!

    private(set) var layoutMetrics: HexLayout
    private(set) var map: HexScrollMap
    private let glyphs = HexGlyphs.monospaced(Metric.value("fs-mono-sm"))
    private let boldGlyphs = HexGlyphs.monospaced(Metric.value("fs-mono-sm"), weight: .semibold)
    /// Scaled scrolling keeps its exact row here; the clip's y is rounded.
    private var scaledTop: Double?

    /// The fixed end of the selection and the moving one (the cursor); nil until a byte is picked.
    private(set) var anchor: Int64?
    private(set) var cursor: Int64?
    /// Where the last click or key landed: ⌘C copies hex from the hex column, text from the ASCII one.
    public private(set) var activeColumn: HexColumn = .hex
    private(set) var endian: HexEndian = .little

    /// Feeds the gutter (selection on the left; search progress, a stopped search or a note on the right).
    public var onGutter: ((GutterStatus?) -> Void)? { didSet { updateGutter() } }

    // MARK: Make

    /// The factory renderers use: a hex view of the file at `url`. Opening reads only the first megabyte (the
    /// signature and text runs) and the rows in view.
    public static func make(url: URL) throws -> HexView { HexView(source: try HexByteSource(url: url)) }

    public init(source: HexByteSource) {
        self.source = source
        let digits = HexFormat.digits(forSize: source.count)
        layoutMetrics = HexLayout(bytesPerRow: 16, offsetDigits: digits, charWidth: HexGlyphs.monospaced(Metric.value("fs-mono-sm")).advance)
        map = HexScrollMap(rows: Self.rows(source.count, 16), viewport: 0)
        super.init(frame: NSRect(x: 0, y: 0, width: 680, height: 440))
        wantsLayer = true
        scroll.documentView = spacer
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        canvas.hex = self
        drawer.onEndian = { [weak self] e in self?.endian = e; self?.refreshDrawer() }
        drawer.onRun = { [weak self] run in
            guard let self else { return }
            self.select(run.offset...(run.offset + Int64(run.length) - 1), column: .ascii)
            self.reveal(run.offset, center: true)
        }
        for v in [header, scroll, canvas, drawer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        drawerHeight = drawer.heightAnchor.constraint(equalToConstant: HexDrawer.height)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: HexLayout.headerHeight),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: drawer.topAnchor),
            canvas.topAnchor.constraint(equalTo: scroll.topAnchor), canvas.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            drawer.leadingAnchor.constraint(equalTo: leadingAnchor), drawer.trailingAnchor.constraint(equalTo: trailingAnchor),
            drawer.bottomAnchor.constraint(equalTo: bottomAnchor), drawerHeight,
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        readHead()
        refreshDrawer()
    }

    required init?(coder: NSCoder) { nil }

    static func rows(_ count: Int64, _ perRow: Int) -> Int64 { (count + Int64(perRow) - 1) / Int64(perRow) }

    /// The signature and the text runs, from the first megabyte only.
    private func readHead() {
        let head = source.bytes(in: 0..<min(source.count, Self.runsScanLength))
        signature = HexSignature.identify(Array(head.prefix(HexSignature.sampleLength)))
        runs = HexFormat.runs(in: head, limit: Self.runsLimit)
        drawer.show(runs: runs, scanned: min(source.count, Self.runsScanLength), total: source.count)
    }

    /// The file changed on disk: show the new bytes, keep the place and as much of the selection as still exists.
    public func reload(url: URL) throws {
        let top = topByte
        source = try HexByteSource(url: url)
        clearFind()
        readHead()
        if let a = anchor, let c = cursor {
            let last = source.count - 1
            if last < 0 { anchor = nil; cursor = nil } else { anchor = min(a, last); cursor = min(c, last) }
        }
        relayout(force: true, keepingTop: top)
        refreshDrawer()
        updateGutter()
    }

    // MARK: Layout and scrolling

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() { layer?.backgroundColor = NSColor.token("page").cgColor }

    public override func layout() {
        super.layout()
        relayout(force: false, keepingTop: nil)
    }

    /// The byte at the top of the view, kept across a resize that changes how many bytes a row holds.
    var topByte: Int64 { Int64(topRow) * Int64(layoutMetrics.bytesPerRow) }

    private func relayout(force: Bool, keepingTop: Int64?) {
        let viewport = scroll.contentView.bounds.height
        let fit = HexLayout.fitting(bounds.width, offsetDigits: HexFormat.digits(forSize: source.count), charWidth: glyphs.advance)
        let next = HexScrollMap(rows: Self.rows(source.count, fit.bytesPerRow), viewport: viewport)
        guard force || fit != layoutMetrics || next != map else { return }
        let top = keepingTop ?? topByte
        layoutMetrics = fit
        map = next
        header.layout = fit
        spacer.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(map.contentHeight))
        scrollTo(topRow: Double(top / Int64(fit.bytesPerRow)))
        canvas.needsDisplay = true
    }

    /// The first row in view, fractional.
    var topRow: Double {
        if map.isScaled, let scaledTop { return scaledTop }
        return map.topRow(forY: Double(scroll.contentView.bounds.origin.y))
    }

    /// Rows that fit the view at once.
    var visibleRowCount: Int { max(1, Int(scroll.contentView.bounds.height / HexLayout.rowHeight) - 1) }

    func scrollTo(topRow t: Double) {
        let clamped = min(max(0, t), map.maxTopRow)
        scaledTop = map.isScaled ? clamped : nil
        scroll.contentView.scroll(to: NSPoint(x: 0, y: map.y(forTopRow: clamped)))
        scroll.reflectScrolledClipView(scroll.contentView)
        canvas.needsDisplay = true
    }

    /// The scroll offset for scroll memory and its restore.
    public var scrollOffset: Double { Double(scroll.contentView.bounds.origin.y) }
    public func restoreScroll(_ y: Double) { scrollTo(topRow: map.topRow(forY: y)) }

    @objc private func scrolled() {
        // A scroll the view did not make itself (the scroller, a restore) drops the scaled row it kept.
        if map.isScaled, let kept = scaledTop, abs(map.y(forTopRow: kept) - Double(scroll.contentView.bounds.origin.y)) > 1 { scaledTop = nil }
        canvas.needsDisplay = true
    }

    /// One row is one row, also when the scroll range is scaled for a very large file.
    func scrollWheel(from event: NSEvent) {
        guard map.isScaled else { return scroll.scrollWheel(with: event) }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * HexLayout.rowHeight
        scrollTo(topRow: topRow - Double(dy / HexLayout.rowHeight))
    }

    /// Scrolls so the row holding `offset` is in view (in the middle when `center`).
    public func reveal(_ offset: Int64, center: Bool = false) {
        let row = Double(offset / Int64(layoutMetrics.bytesPerRow))
        let shown = Double(visibleRowCount)
        if center { scrollTo(topRow: row - shown / 2); return }
        if row < topRow.rounded(.up) { scrollTo(topRow: row) }
        else if row > topRow + shown - 1 { scrollTo(topRow: row - shown + 1) }
    }

    // MARK: Drawer (the inspector)

    /// ⌘I: shows or hides the decoding drawer.
    public func toggleInspector() {
        drawer.isHidden.toggle()
        drawerHeight.constant = drawer.isHidden ? 0 : HexDrawer.height
    }

    public var isInspectorShown: Bool { !drawer.isHidden }

    private func refreshDrawer() {
        guard let range = selection else { return drawer.show(rows: []) }
        let n = Int(min(Int64(Int.max), range.upperBound - range.lowerBound + 1))
        let bytes = source.bytes(in: range.lowerBound..<range.lowerBound + Int64(max(HexDecoder.wanted, min(n, 256))))
        let from = HexFormat.offset(range.lowerBound), to = HexFormat.offset(range.upperBound), count = n.formatted()
        let head = HexDecodedRow(label: String(localized: "Selection", bundle: .previewKit, comment: "Decoding drawer row: where the selection is and how many bytes."),
                                 value: n == 1
                                     ? String(localized: "\(from) · \(count) byte", bundle: .previewKit, comment: "Decoding drawer value: one selected byte. Arguments: its hex offset, the count.")
                                     : String(localized: "\(from) – \(to) · \(count) bytes", bundle: .previewKit, comment: "Decoding drawer value: the selected bytes. Arguments: first and last hex offset, the count."))
        drawer.show(rows: [head] + HexDecoder.rows(bytes: bytes, selectionLength: n, endian: endian))
    }

    /// The drawer's readings, for tests and the inspector's copy.
    var readings: [HexDecodedRow] { drawer.rows }

    public func setEndian(_ e: HexEndian) {
        endian = e
        drawer.endian.selectedSegment = e == .big ? 1 : 0
        refreshDrawer()
    }

    // MARK: Selection

    /// The selected bytes, both ends included; nil before a byte is picked.
    public var selection: ClosedRange<Int64>? {
        guard let anchor, let cursor else { return nil }
        return min(anchor, cursor)...max(anchor, cursor)
    }

    /// Selects `range` (clamped to the file), shown in both columns.
    public func select(_ range: ClosedRange<Int64>, column: HexColumn = .hex) {
        guard source.count > 0 else { return }
        let last = source.count - 1
        anchor = min(max(0, range.lowerBound), last)
        cursor = min(max(0, range.upperBound), last)
        activeColumn = column
        selectionChanged()
    }

    public func selectAll() {
        guard source.count > 0 else { return }
        select(0...(source.count - 1), column: activeColumn)
    }

    private func selectionChanged() {
        canvas.needsDisplay = true
        refreshDrawer()
        updateGutter()
    }

    /// The byte under a point in the canvas, and its column.
    func byte(at point: NSPoint) -> (offset: Int64, column: HexColumn)? {
        guard source.count > 0 else { return nil }
        let row = Int64(max(0, floor(topRow + Double((point.y - HexLayout.topPad) / HexLayout.rowHeight))))
        let hit = layoutMetrics.hit(x: point.x)
        return (min(source.count - 1, row * Int64(layoutMetrics.bytesPerRow) + Int64(hit.index)), hit.column)
    }

    func pointerSelect(at point: NSPoint, extend: Bool, dragging: Bool) {
        guard let hit = byte(at: point) else { return }
        if !extend || anchor == nil { anchor = hit.offset }
        cursor = hit.offset
        if !dragging { activeColumn = hit.column }
        if dragging {
            // Dragging past the top or bottom edge scrolls a row at a time.
            if point.y < 0 { scrollTo(topRow: topRow - 1) } else if point.y > canvas.bounds.height { scrollTo(topRow: topRow + 1) }
        }
        selectionChanged()
    }

    func moveCursor(by delta: Int64, extend: Bool) {
        guard source.count > 0 else { return }
        let from = cursor ?? 0
        moveCursor(to: cursor == nil ? 0 : from + delta, extend: extend)
    }

    func moveCursor(rows: Int, extend: Bool) { moveCursor(by: Int64(rows) * Int64(layoutMetrics.bytesPerRow), extend: extend) }

    func moveCursor(to offset: Int64, extend: Bool) {
        guard source.count > 0 else { return }
        let target = min(max(0, offset), source.count - 1)
        if !extend || anchor == nil { anchor = target }
        cursor = target
        reveal(target)
        selectionChanged()
    }

    // MARK: Copy

    /// ⌘C in the rows: the selection as hex from the hex column, as text from the ASCII column.
    func copySelection(to pasteboard: NSPasteboard = .general) {
        guard let range = selection else { return }
        let bytes = source.bytes(in: range.lowerBound..<min(range.upperBound + 1, range.lowerBound + Self.copyLimit))
        pasteboard.clearContents()
        pasteboard.setString(activeColumn == .hex ? HexFormat.hex(bytes) : HexFormat.rawText(bytes), forType: .string)
    }

    /// The capsule's Copy-as menu: the selection (or the whole file), its first megabyte when larger.
    public func copyOffer() -> (heading: String, formats: [CopyFormat]) {
        let range: Range<Int64>
        let heading: String
        if let s = selection {
            let n = s.upperBound - s.lowerBound + 1
            range = s.lowerBound..<s.lowerBound + min(n, Self.copyLimit)
            let count = n.formatted(), limit = ByteCountFormatter.string(fromByteCount: Self.copyLimit, countStyle: .memory)
            heading = n > Self.copyLimit ? String(localized: "Copy the selection's first \(limit) as", bundle: .previewKit, comment: "Heading of the Copy as menu: only the start of a large selection is copied; the argument is a size.")
                : n == 1 ? String(localized: "Copy \(count) byte as", bundle: .previewKit, comment: "Heading of the Copy as menu: one selected byte.")
                : String(localized: "Copy \(count) bytes as", bundle: .previewKit, comment: "Heading of the Copy as menu: the selected bytes; the argument is their count.")
        } else {
            range = 0..<min(source.count, Self.copyLimit)
            let count = source.count.formatted(), limit = ByteCountFormatter.string(fromByteCount: Self.copyLimit, countStyle: .memory)
            heading = source.count > Self.copyLimit
                ? String(localized: "Copy the first \(limit) as", bundle: .previewKit, comment: "Heading of the Copy as menu: only the start of a large file is copied; the argument is a size.")
                : String(localized: "Copy all \(count) bytes as", bundle: .previewKit, comment: "Heading of the Copy as menu: the whole file; the argument is its size in bytes.")
        }
        let source = self.source, digits = layoutMetrics.offsetDigits
        return (heading, [
            CopyFormat(title: String(localized: "Hex", bundle: .previewKit, comment: "Copy as menu item: the bytes as hexadecimal digits.")) { HexFormat.hex(source.bytes(in: range)) },
            CopyFormat(title: String(localized: "C array", bundle: .previewKit, comment: "Copy as menu item: the bytes as a C array literal.")) { HexFormat.cArray(source.bytes(in: range)) },
            CopyFormat(title: "Base64") { HexFormat.base64(source.bytes(in: range)) },
            CopyFormat(title: String(localized: "Raw text", bundle: .previewKit, comment: "Copy as menu item: the bytes as text.")) { HexFormat.rawText(source.bytes(in: range)) },
            CopyFormat(title: String(localized: "Hex dump", bundle: .previewKit, comment: "Copy as menu item: offsets, hex and ASCII columns as text.")) { HexFormat.dump(source.bytes(in: range), base: range.lowerBound, digits: digits) },
        ])
    }

    // MARK: Find

    private var findQuery = ""
    private var outcome: HexSearchOutcome?
    private var running: Task<Void, Never>?
    private var findGeneration = 0
    private var matchIndex = -1
    private var patternLength = 0
    private var searchProgress: Int64?
    /// A word for the gutter's right about the last jump ("past the end").
    private var note: String?
    /// The chunk a search reads at a time (tests make it small).
    var searchChunkSize = HexSearcher.chunkSize

    /// A search is running.
    public var isSearching: Bool { running != nil }
    /// The finished (or stopped) search's matches.
    public var matches: [Int64] { outcome?.matches ?? [] }

    /// The capsule's find: bytes or text, streamed over the whole file; Return steps through the matches. ":offset"
    /// jumps there and selects the byte. A new query cancels the search before it.
    public func find(_ q: String, forward: Bool) async -> FindResult {
        guard !q.isEmpty else { clearFind(); return FindResult(count: 0, index: -1) }
        let query = HexQuery(q)
        switch query {
        case .offset(let o):
            clearFind()
            guard o >= 0, o < source.count else {
                let asked = HexFormat.offset(o), last = HexFormat.offset(max(0, source.count - 1))
                note = source.count == 0
                    ? String(localized: "The file is empty", bundle: .previewKit, comment: "Status line: an offset was asked of an empty file.")
                    : String(localized: "\(asked) is past the end (last byte \(last))", bundle: .previewKit, comment: "Status line: the offset typed is beyond the file. Arguments: that offset, the last byte's offset (hex).")
                updateGutter()
                return FindResult(count: 0, index: -1)
            }
            select(o...o)
            reveal(o, center: true)
            return FindResult(count: 1, index: 0)
        case .invalidOffset:
            clearFind()
            note = String(localized: "Type an offset after the colon: :4096 or :0x1000", bundle: .previewKit, comment: "Status line: how to jump to an offset in the hex view. Keep “:4096” and “:0x1000” as they are.")
            updateGutter()
            return FindResult(count: 0, index: -1)
        case .bytes, .text:
            break
        }
        guard let pattern = query.pattern else { return FindResult(count: 0, index: -1) }
        if q == findQuery {
            if running != nil { return await latestResult() }
            if outcome != nil { step(forward: forward); return currentResult() }
        }

        // A new search.
        running?.cancel()
        findGeneration += 1
        let generation = findGeneration
        findQuery = q
        outcome = nil
        matchIndex = -1
        note = nil
        patternLength = pattern.bytes.count
        searchProgress = 0
        updateGutter()
        canvas.needsDisplay = true
        let source = self.source, chunk = searchChunkSize, owner = HexWeak(self)
        let work = Task.detached(priority: .userInitiated) { () -> HexSearchOutcome in
            var last = ContinuousClock.now
            return HexSearcher.search(pattern.bytes, caseInsensitive: pattern.caseInsensitive, in: source, chunkSize: chunk) { searched in
                let now = ContinuousClock.now
                if now - last > .milliseconds(80) {
                    last = now
                    Task { @MainActor in owner.view?.searchProgressed(searched, generation: generation) }
                }
                return true
            }
        }
        // The job stores the outcome before anyone awaiting it resumes, so every caller reads the finished state.
        let job = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            self?.searchFinished(result, generation: generation)
        }
        running = job
        await job.value
        return await latestResult()
    }

    /// Waits for whatever search is running now, then reports the state it left.
    private func latestResult() async -> FindResult {
        while let job = running { await job.value }
        return currentResult()
    }

    private func currentResult() -> FindResult {
        guard let outcome, !outcome.matches.isEmpty else { return FindResult(count: 0, index: -1, searchedAll: outcome?.complete ?? true) }
        return FindResult(count: outcome.matches.count, index: matchIndex, searchedAll: outcome.complete)
    }

    private func step(forward: Bool) {
        let count = outcome?.matches.count ?? 0
        guard count > 0, let outcome else { return }
        matchIndex = forward ? (matchIndex + 1) % count : (matchIndex - 1 + count) % count
        reveal(outcome.matches[matchIndex], center: true)
        canvas.needsDisplay = true
    }

    private func searchProgressed(_ searched: Int64, generation: Int) {
        guard generation == findGeneration, running != nil else { return }
        searchProgress = searched
        updateGutter()
    }

    private func searchFinished(_ result: HexSearchOutcome, generation: Int) {
        guard generation == findGeneration else { return }
        outcome = result
        running = nil
        searchProgress = nil
        // The first match is current as soon as the search ends, before any caller resumes.
        if !result.matches.isEmpty {
            matchIndex = 0
            reveal(result.matches[0], center: true)
        }
        canvas.needsDisplay = true
        updateGutter()
    }

    /// The gutter's Cancel and Escape: stops the search where it is; the matches found so far stay.
    public func cancelSearch() { running?.cancel() }

    public func clearFind() {
        findGeneration += 1
        running?.cancel()
        running = nil
        outcome = nil
        findQuery = ""
        matchIndex = -1
        searchProgress = nil
        note = nil
        canvas.needsDisplay = true
        updateGutter()
    }

    // MARK: Gutter

    /// Left: the selection ("Offset 0x0C–0x0F · 4 bytes selected"). Right: "Searching… 40 MB of 200 MB" with Cancel
    /// while a search runs, then what bounded it ("Searched 40 MB of 200 MB · stopped"), or a jump's note.
    public func gutterStatus() -> GutterStatus? {
        let leading = selection.map(HexFormat.selection)
        var trailing: String?
        var busy = false
        let mb = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        if let p = searchProgress {
            let done = mb(p), total = mb(source.count)
            trailing = String(localized: "Searching… \(done) of \(total)", bundle: .previewKit, comment: "Status line while searching. Arguments: size searched, file size.")
            busy = true
        } else if let note {
            trailing = note
        } else if let outcome, outcome.cancelled {
            let done = mb(outcome.searched), total = mb(outcome.total)
            trailing = String(localized: "Searched \(done) of \(total) · stopped", bundle: .previewKit, comment: "Status line: a search was stopped. Arguments: size searched, file size.")
        } else if let outcome, outcome.capped {
            let count = outcome.matches.count.formatted()
            trailing = String(localized: "First \(count) matches", bundle: .previewKit, comment: "Status line: the search stopped at this many matches.")
        }
        if leading == nil, trailing == nil { return nil }
        return GutterStatus(leading: leading, trailing: trailing, busy: busy)
    }

    func updateGutter() { onGutter?(gutterStatus()) }

    // MARK: Drawing

    /// How a byte is shown, strongest first. roadmap: S-5
    enum Mark { case selected, findCurrent, find, evidence, run, zero, plain }

    func drawRows(in ctx: CGContext, size: CGSize) {
        let l = layoutMetrics
        let per = Int64(l.bytesPerRow)
        guard source.count > 0 else {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: Metric.value("fs-control")), .foregroundColor: NSColor.token("t3")]
            (String(localized: "Empty file · 0 bytes", bundle: .previewKit, comment: "Hex view of an empty file.") as NSString).draw(at: NSPoint(x: l.hexX, y: HexLayout.topPad + 2), withAttributes: attrs)
            return
        }
        let top = topRow
        let first = Int64(max(0, floor(top)))
        let shown = Int64(ceil(Double(size.height) / Double(HexLayout.rowHeight))) + 1
        let last = min(map.rows, first + shown)
        guard first < last else { return }
        // Three bytes either side, so a text run crossing the edge of the view is still measured.
        let lo = first * per, hi = min(source.count, last * per)
        let context = source.bytes(in: max(0, lo - 3)..<min(source.count, hi + 3))
        let lead = Int(lo - max(0, lo - 3))
        let runFlags = HexFormat.inRun(context)

        let sel = selection
        let evidence = signature?.evidence ?? []
        let matchList = outcome?.matches ?? []
        let current = matchIndex >= 0 && matchIndex < matchList.count ? matchList[matchIndex] : nil
        var nextMatch = lowerBound(matchList, lo - Int64(max(1, patternLength)) + 1)
        func inMatch(_ o: Int64) -> Bool {
            while nextMatch < matchList.count, matchList[nextMatch] + Int64(patternLength) <= o { nextMatch += 1 }
            var i = nextMatch
            while i < matchList.count, matchList[i] <= o { if o < matchList[i] + Int64(patternLength) { return true }; i += 1 }
            return false
        }
        func mark(_ o: Int64, _ b: UInt8, inRun: Bool) -> Mark {
            if let sel, sel.contains(o) { return .selected }
            if let current, o >= current, o < current + Int64(patternLength) { return .findCurrent }
            if !matchList.isEmpty, inMatch(o) { return .find }
            if evidence.contains(where: { $0.contains(o) }) { return .evidence }
            if inRun { return .run }
            return b == 0 ? .zero : .plain
        }

        let colors = Palette()
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let rh = HexLayout.rowHeight
        let baselineShift = (rh + glyphs.ascent - glyphs.descent) / 2
        for row in first..<last {
            let y = HexLayout.topPad + CGFloat(Double(row) - top) * rh
            let baseline = y + baselineShift
            let offsetText = HexFormat.column(row * per, digits: l.offsetDigits)
            ctx.setFillColor(colors.t3)
            glyphs.draw(offsetText.utf8.map { glyphs.hex[Int(hexValue($0))] }, at: CGPoint(x: HexLayout.padding, y: baseline), in: ctx)
            for i in 0..<l.bytesPerRow {
                let o = row * per + Int64(i)
                guard o < source.count else { break }
                let k = Int(o - lo) + lead
                guard k < context.count else { break }
                let b = context[k]
                let m = mark(o, b, inRun: runFlags[k])
                let hexRect = CGRect(x: l.hexCellX(i), y: y + 1.5, width: HexLayout.cellWidth, height: rh - 3)
                let asciiRect = CGRect(x: l.asciiCellX(i), y: y + 1.5, width: l.asciiCell, height: rh - 3)
                colors.background(m, rect: hexRect, in: ctx)
                colors.background(m, rect: asciiRect, in: ctx)
                let face = m == .evidence ? boldGlyphs : glyphs
                ctx.setFillColor(colors.text(m, ascii: false))
                face.draw([face.hex[Int(b >> 4)], face.hex[Int(b & 0xF)]],
                          at: CGPoint(x: hexRect.minX + (HexLayout.cellWidth - 2 * face.advance) / 2, y: baseline), in: ctx)
                ctx.setFillColor(colors.text(m, ascii: true))
                face.draw([face.ascii[Int(b)]], at: CGPoint(x: asciiRect.minX + 0.25, y: baseline), in: ctx)
            }
        }
        ctx.restoreGState()
    }

    private func hexValue(_ c: UInt8) -> UInt8 { c <= 0x39 ? c - 0x30 : c - 0x37 }

    private func lowerBound(_ a: [Int64], _ x: Int64) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) / 2; if a[mid] < x { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    /// The token colours resolved once per draw, in the view's appearance. roadmap: S-5
    private struct Palette {
        let t1 = NSColor.token("t1").cgColor, t2 = NSColor.token("t2").cgColor, t3 = NSColor.token("t3").cgColor
        let sel = NSColor.token("sel").cgColor, accent = NSColor.token("accent-text").cgColor
        let find = NSColor.token("find").cgColor, findCur = NSColor.token("find-cur").cgColor
        let dangerSoft = NSColor.token("danger-soft").cgColor, dangerLine = NSColor.token("danger-line").cgColor
        let dangerText = NSColor.token("danger-text").cgColor, fill2 = NSColor.token("fill2").cgColor

        func background(_ m: Mark, rect: CGRect, in ctx: CGContext) {
            let fill: CGColor?, stroke: CGColor?
            switch m {
            case .selected: fill = sel; stroke = accent
            case .findCurrent: fill = findCur; stroke = nil
            case .find: fill = find; stroke = nil
            case .evidence: fill = dangerSoft; stroke = dangerLine
            case .run: fill = fill2; stroke = nil
            case .zero, .plain: fill = nil; stroke = nil
            }
            guard let fill else { return }
            let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
            if let stroke {
                ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 3, cornerHeight: 3, transform: nil))
                ctx.setStrokeColor(stroke)
                ctx.setLineWidth(0.5)
                ctx.strokePath()
            }
        }

        func text(_ m: Mark, ascii: Bool) -> CGColor {
            switch m {
            case .selected, .findCurrent, .find, .run: return t1
            case .evidence: return dangerText
            case .zero: return t3
            case .plain: return ascii ? t2 : t1
            }
        }
    }
}

/// A weak reference to the view that a background search can carry back to the main actor. roadmap: S-5
@MainActor
final class HexWeak {
    weak var view: HexView?
    init(_ view: HexView) { self.view = view }
}

/// The scroll view's document: empty, as tall as the rows (or the scaled range), so the scroller is true.
/// roadmap: S-5
@MainActor
final class HexSpacer: NSView {
    override var isFlipped: Bool { true }
}
