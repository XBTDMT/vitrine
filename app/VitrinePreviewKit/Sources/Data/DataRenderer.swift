import AppKit
import VitrineData
import VitrineDocument
import VitrineSupport
import VitrineUI

/// CSV, TSV and SQLite in the picked data design (r3-a Inspector, design/mockups/data/r3-a.html): a virtualised
/// native table (sticky header on card2 with a 2 pt quality line, numbers right-aligned in tabular digits, zebra on
/// real rows) and a 260 pt Inspector on the right with File (Database for SQLite, listing its tables), Column and
/// Row. The facts, copy, find and viewer switch live in the capsule; nothing is drawn above the rows. roadmap: S-6
@MainActor
public final class DataRenderer: NSObject, Renderer {
    public static func canRender(_ kind: FileKind) -> Bool {
        switch kind {
        case .csv, .sqlite, .dataset: return true
        default: return false
        }
    }

    public override required init() { super.init() }

    private var model: (any TabularModel)?
    static let exactCountLimit = 8 * 1024 * 1024

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        if case .sqlite = kind { return try renderSQLite(url: url) }
        if case .dataset = kind { return try renderColumnar(url: url) }
        var hint: CSVDelimiter?
        if case .csv(let delimiter) = kind { hint = CSVDelimiter(delimiter) }
        let table = try CSVTable.open(url, delimiterHint: hint)
        // The document keeps the source text as its view, so copy and the text switch work; the pill reads the facts.
        // A file up to `exactCountLimit` is counted before the first paint (milliseconds), so the pill says "300 rows";
        // a larger one says "≥ 200 rows" until the background index is built, then the pill updates in place.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max
        let exactIndex = size <= Self.exactCountLimit ? try? await table.buildIndex() : nil
        let source = try PlainTextRenderer.textDocument(url: url, kind: kind)
        let document = Self.tableAndText(FamilyFacts.csv(source, url: url, table: table, index: exactIndex))
        let model = DataModel(table: table, index: exactIndex)
        self.model = model
        let view = DataView(model: model)
        view.tableName = url.deletingPathExtension().lastPathComponent
        let preview = Self.preview(view: view, document: document, owner: self)
        if exactIndex == nil {
            model.onIndexed = { [weak preview] index in
                preview?.updateDocument(Self.tableAndText(FamilyFacts.csv(source, url: url, table: table, index: index)))
            }
        }
        model.start()
        return preview
    }

    /// CSV and TSV offer Table and Text in the viewer switch (data 1): the rows, or the file as stored (the lint
    /// banner's Text view). Both entries carry the source text; the host draws the Table itself as view 0.
    static func tableAndText(_ document: PreviewDocument) -> PreviewDocument {
        var doc = document
        doc.views = [doc.views[0], doc.views[0]]
        doc.viewTitles = ["Table",
                         "Text"]
        return doc
    }

    /// SQLite opens on its first table with the Inspector on the Database tab (data r3-a, D-2). A file whose header
    /// is not SQLite's (a `.db` that is something else) throws, and Quick Look falls back to its own preview.
    private func renderSQLite(url: URL) throws -> RenderedPreview {
        let model = try SQLiteDataModel(url: url)
        self.model = model
        let view = DataView(model: model)
        let preview = Self.preview(view: view, document: model.document(), owner: self,
                                   showView: { [weak view] index in view?.showSchema(index == 1); return true })
        model.onDocumentChange = { [weak preview, weak model] in
            guard let model else { return }
            preview?.updateDocument(model.document())
        }
        model.start()
        return preview
    }

    /// Parquet, Arrow / Feather and xlsx (B-4, G-20): read by VitrineData's own readers into the same grid; the
    /// Inspector opens on the File tab (the footer's facts, the row-group strip and the columns' ranges, data design
    /// "Parquet / Arrow, footer first"); a workbook's sheets are its parts. A file the reader refuses throws, with the
    /// reason, and Quick Look falls back to its own preview. roadmap: S-21
    private func renderColumnar(url: URL) throws -> RenderedPreview {
        let model = try ColumnarDataModel(url: url)
        self.model = model
        let view = DataView(model: model)
        view.tableName = SQLiteQueryEngine.tableName(for: url.lastPathComponent)
        let preview = Self.preview(view: view, document: model.document(), owner: self)
        model.onDocumentChange = { [weak preview, weak model] in
            guard let model else { return }
            preview?.updateDocument(model.document())
        }
        model.start()
        return preview
    }

    /// Find filters the rows (data 1): the capsule's field reads "Filter", the gutter counts the matches, and sort and
    /// the position readout share the gutter (data 2).
    private static func preview(view: DataView, document: PreviewDocument, owner: AnyObject,
                                showView: (@MainActor (Int) -> Bool)? = nil) -> RenderedPreview {
        let preview = RenderedPreview(view: view, document: document, owner: owner,
                                      scrollOffset: { [weak view] in view.map { Double($0.scroll.contentView.bounds.origin.y) } },
                                      restoreScroll: { [weak view] y in
                                          guard let scroll = view?.scroll else { return }
                                          scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                                          scroll.reflectScrolledClipView(scroll.contentView)
                                      },
                                      toggleInspector: { [weak view] in view?.toggleInspector() },
                                      find: { [weak view] query, _ in await view?.filter(query) ?? FindResult(count: 0, index: -1) },
                                      clearFind: { [weak view] in view.map { v in Task { _ = await v.filter("") } } },
                                      showView: showView,
                                      findStyle: .filter)
        view.onGutter = { [weak preview] status in preview?.updateGutter(status) }
        view.inspector.tokens = document.tokens
        preview.copyFormats = { [weak view] in
            view?.copyOffer() ?? (String(localized: "Copy as", bundle: .previewKit, comment: "Heading of the Copy as menu."), [])
        }
        view.onTextView = { [weak preview] in preview?.requestView(1) }
        preview.cancelWork = { [weak view] in view?.cancel() }
        DataQueryController.install(on: preview, view: view)
        view.updateGutter()
        return preview
    }
}

/// The rows and, beside them, the Inspector.
@MainActor
final class DataView: NSView {
    let scroll = NSScrollView()
    let grid: DataGrid
    let inspector: DataInspector
    private var inspectorWidth: NSLayoutConstraint!

    let model: any TabularModel
    /// The gutter's text changed (position, matches, sort state).
    var onGutter: ((GutterStatus?) -> Void)?
    /// What the user asked for; the model's `arrangement` is what is applied (they differ while work runs).
    private(set) var filterText = ""
    private(set) var sort: (column: Int, ascending: Bool)?
    /// "Sorting by total…", "Filtering…" while an arrangement runs.
    private(set) var busy: String?
    private var generation = 0
    private var layoutVersion: Int
    /// The caution banner above the rows (I-6), collapsed when the file has no shape problem.
    let banner = LintBanner()
    private var bannerHeight: NSLayoutConstraint!
    private var lintStep = -1
    /// The table's name for Copy as SQL INSERT: the SQLite table, or the CSV file's name.
    var tableName = "data"
    /// The banner's Text view button: show the file as stored (the viewer switch's Text).
    var onTextView: (() -> Void)?
    /// A query's result drawn over these rows (I-8); while it shows, Copy as copies the result.
    weak var overlay: DataView?
    /// SQLite's drawn Schema view, made when first shown.
    private(set) var schema: SQLiteSchemaView?

    init(model: any TabularModel) {
        self.model = model
        layoutVersion = model.layoutVersion
        grid = DataGrid(model: model)
        inspector = DataInspector(model: model)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        scroll.documentView = grid.table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let edge = Hairline()
        self.edge = edge
        for v in [banner, scroll, edge, inspector] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        inspectorWidth = inspector.widthAnchor.constraint(equalToConstant: Metric.value("w-inspector"))
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: topAnchor), banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: edge.leadingAnchor), bannerHeight,
            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: edge.leadingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor), edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 0.5), edge.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspector.topAnchor.constraint(equalTo: topAnchor), inspector.bottomAnchor.constraint(equalTo: bottomAnchor),
            inspector.trailingAnchor.constraint(equalTo: trailingAnchor), inspectorWidth,
        ])
        grid.onSelect = { [weak self] selection in
            guard let self else { return }
            // A click on a header or a row opens the Inspector (data r3-a); a file of one table opens with it closed.
            if self.inspector.isHidden, selection != .file { self.toggleInspector() }
            self.inspector.show(selection)
            self.updateGutter()
        }
        grid.table.allowsMultipleSelection = true
        banner.onNext = { [weak self] in self?.nextIssue() }
        banner.onText = { [weak self] in self?.onTextView?() }
        grid.onSort = { [weak self] column, ascending in self?.setSort(column: column, ascending: ascending) }
        inspector.onJump = { [weak self] row in self?.scrollToRow(row) }
        model.onChange = { [weak self] in self?.modelChanged() }
        if !model.opensInspector { toggleInspector() }
        refreshLint()
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
    }

    private func modelChanged() {
        if model.layoutVersion != layoutVersion {
            // Another table: its own columns, so the sort goes; the filter in the field applies to it too.
            layoutVersion = model.layoutVersion
            sort = nil
            if !filterText.isEmpty { Task { _ = await run() } }
            schema?.reload()
        }
        grid.reload()
        inspector.refresh()
        refreshLint()
        updateGutter()
    }

    private weak var edge: NSView?

    // MARK: Lint banner (I-6)

    private func refreshLint() {
        guard let lint = model.lint else {
            banner.isHidden = true
            bannerHeight.constant = 0
            return
        }
        banner.show(lint, step: lintStep)
        banner.isHidden = false
        bannerHeight.constant = LintBanner.height
    }

    /// Selects the next ragged row the index recorded (skipping any the filter hides) and scrolls to it.
    func nextIssue() {
        guard let lint = model.lint, !lint.rows.isEmpty else { return }
        for _ in lint.rows.indices {
            lintStep = (lintStep + 1) % lint.rows.count
            if let shown = model.shownRow(forSource: lint.rows[lintStep]) {
                grid.table.selectRowIndexes(IndexSet(integer: shown), byExtendingSelection: false)
                grid.table.scrollRowToVisible(shown)
                break
            }
        }
        banner.show(lint, step: lintStep)
    }

    // MARK: Schema view (D-2)

    /// Shows SQLite's drawn schema in place of the rows (true), or the rows again (false).
    func showSchema(_ on: Bool) {
        guard let sqlite = model as? SQLiteDataModel else { return }
        if on, schema == nil, let edge {
            let view = SQLiteSchemaView(model: sqlite)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: edge.leadingAnchor),
            ])
            schema = view
        }
        schema?.isHidden = !on
        scroll.isHidden = on
        banner.isHidden = on || model.lint == nil
    }

    // MARK: Copy as (I-7)

    /// The selected cells (a selected column within selected rows), else the selected rows, else every shown row up to
    /// `copyLimit`, as CSV, TSV, a Markdown table, JSON or SQL INSERT statements.
    static let copyLimit = 10_000

    func copyOffer() -> (heading: String, formats: [CopyFormat]) {
        if let overlay, overlay !== self { return overlay.copyOffer() }
        let selected = grid.table.selectedRowIndexes
        let rows: [Int] = selected.isEmpty ? Array(0..<min(model.shownCount, Self.copyLimit)) : Array(selected.prefix(Self.copyLimit))
        let columns: [Int] = (!selected.isEmpty && grid.selectedColumn != nil) ? [grid.selectedColumn!] : Array(0..<model.columnCount)
        let heading: String
        let count = rows.count.formatted()
        if !selected.isEmpty, columns.count == 1 {
            heading = rows.count == 1
                ? String(localized: "Copy \(count) cell as", bundle: .previewKit, comment: "Heading of the Copy as menu: one selected cell. The argument is a formatted number.")
                : String(localized: "Copy \(count) cells as", bundle: .previewKit, comment: "Heading of the Copy as menu: the selected cells; the argument is their count.")
        } else if !selected.isEmpty {
            heading = rows.count == 1
                ? String(localized: "Copy \(count) row as", bundle: .previewKit, comment: "Heading of the Copy as menu: one selected row. The argument is a formatted number.")
                : String(localized: "Copy \(count) rows as", bundle: .previewKit, comment: "Heading of the Copy as menu: the selected rows; the argument is their count.")
        } else if model.shownCount > Self.copyLimit {
            let limit = Self.copyLimit.formatted()
            heading = String(localized: "Copy the first \(limit) rows as", bundle: .previewKit, comment: "Heading of the Copy as menu: only the first rows are copied; the argument is their count.")
        } else {
            heading = String(localized: "Copy all \(count) rows as", bundle: .previewKit, comment: "Heading of the Copy as menu: every shown row; the argument is their count.")
        }
        var name = (model as? SQLiteDataModel)?.current?.name ?? tableName
        if let columnar = model as? ColumnarDataModel, columnar.format == .xlsx { name = columnar.dataset.parts[columnar.selected].name }
        let exporter = DataExport(model: model, rows: rows, columns: columns, table: name)
        // Column files read rows in windows: the ones copied are read first, so no cell copies as a placeholder.
        let columnar = model as? ColumnarDataModel
        let prepare = { columnar?.prepare(shownRows: rows) }
        return (heading, [
            CopyFormat(title: "CSV") { prepare(); return exporter.delimited(",") },
            CopyFormat(title: "TSV") { prepare(); return exporter.delimited("\t") },
            CopyFormat(title: String(localized: "Markdown table", bundle: .previewKit, comment: "Copy as menu item: the rows as a Markdown table.")) { prepare(); return exporter.markdown() },
            CopyFormat(title: "JSON") { prepare(); return exporter.json() },
            CopyFormat(title: "SQL INSERT") { prepare(); return exporter.sqlInsert() },
        ])
    }

    @objc private func scrolled() {
        updateGutter()
        inspector.visibleRow = firstVisibleRow
    }

    /// The shown row at the top of the grid.
    var firstVisibleRow: Int { max(0, grid.table.rows(in: scroll.contentView.bounds).location) }

    /// Scrolls so that shown row `row` is at the top (a row-group segment's click).
    func scrollToRow(_ row: Int) {
        guard row >= 0, row < model.shownCount else { return }
        let rect = grid.table.rect(ofRow: row)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: rect.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        updateGutter()
        inspector.visibleRow = row
    }

    // MARK: Filter and sort (I-4)

    /// Keeps the rows that contain `query` in any cell; "" shows every row again.
    func filter(_ query: String) async -> FindResult {
        filterText = query
        let done = await run()
        return FindResult(count: query.isEmpty ? 0 : model.shownCount, index: 0, searchedAll: done)
    }

    /// Sorts by a column (true ascending, false descending), or restores file order (nil).
    @discardableResult
    func setSort(column: Int, ascending: Bool?) -> Task<Bool, Never> {
        sort = ascending.map { (column, $0) }
        let started = start()
        return Task { await finish(started) }
    }

    func cancel() {
        generation += 1
        model.cancelArrange()
        busy = nil
        let applied = model.arrangement
        sort = applied.sortColumn.map { ($0, applied.ascending) }
        updateGutter()
    }

    private func run() async -> Bool { await finish(start()) }

    /// The synchronous half: the busy line shows at once. nil when the request is what is already applied.
    private func start() -> (generation: Int, next: DataArrangement)? {
        generation += 1
        let next = DataArrangement(filter: filterText, sortColumn: sort?.column, ascending: sort?.ascending ?? true)
        if next == model.arrangement { busy = nil; updateGutter(); return nil }
        busy = next.sortColumn.map { column in
            let name = model.title(column)
            return String(localized: "Sorting by \(name)…", bundle: .previewKit, comment: "Status line while rows are sorted; the argument is the column name.")
        } ?? (next.filter.isEmpty ? nil : String(localized: "Filtering…", bundle: .previewKit, comment: "Status line while rows are filtered."))
        updateGutter()
        return (generation, next)
    }

    private func finish(_ started: (generation: Int, next: DataArrangement)?) async -> Bool {
        guard let started else { return true }
        // Cancelled (or superseded) before the work began: never start it.
        guard started.generation == generation else { return false }
        let done = await model.arrange(started.next)
        guard started.generation == generation else { return false }
        busy = nil
        if done { grid.table.scrollRowToVisible(0) }
        updateGutter()
        return done
    }

    // MARK: Gutter (data 2)

    /// Left: "1,206 of 48,120 rows match" under a filter, else "Row 1,604,233 of 3,214,880" once the rows do not all
    /// fit. Right: the running work with Cancel, or the sort in force ("Sorted by total ↓").
    func gutterStatus() -> GutterStatus? {
        let applied = model.arrangement
        var leading: String?
        if !applied.filter.isEmpty {
            let shown = model.shownCount.formatted(), all = model.rowCount.formatted()
            leading = model.rowCount == 1
                ? String(localized: "\(shown) of \(all) row match", bundle: .previewKit, comment: "Status line under a filter, when the file has one row. Arguments: matching rows, all rows.")
                : String(localized: "\(shown) of \(all) rows match", bundle: .previewKit, comment: "Status line under a filter. Arguments: matching rows, all rows.")
        } else {
            // "Rows 1–19 of 48,120" (data 2): the rows in view, once they do not all fit.
            let visible = grid.table.rows(in: scroll.contentView.bounds)
            if model.shownCount > visible.length, model.shownCount > 0 {
                let first = max(0, min(visible.location, model.shownCount - 1))
                let last = min(model.shownCount - 1, first + max(visible.length, 1) - 1)
                let from = model.rowNumber(first).formatted(), to = model.rowNumber(last).formatted()
                let total = model.shownCount.formatted()
                leading = first == last
                    ? String(localized: "Row \(from) of \(total)", bundle: .previewKit, comment: "Status line: the one row in view. Arguments: its number, the row count.")
                    : String(localized: "Rows \(from)–\(to) of \(total)", bundle: .previewKit, comment: "Status line: the rows in view. Arguments: first row number, last row number, the row count.")
            }
        }
        var trailing: String?
        if let busy { trailing = busy }
        else if let selection = selectionSummary() { trailing = selection }
        else if let c = applied.sortColumn {
            let name = model.title(c)
            trailing = applied.ascending
                ? String(localized: "Sorted by \(name) ↑", bundle: .previewKit, comment: "Status line: rows sorted ascending by this column.")
                : String(localized: "Sorted by \(name) ↓", bundle: .previewKit, comment: "Status line: rows sorted descending by this column.")
        } else if let c = grid.selectedColumn {
            let name = model.title(c)
            trailing = String(localized: "Column \(name)", bundle: .previewKit, comment: "Status line: the selected column's name.")
        }
        if leading == nil, trailing == nil { return nil }
        return GutterStatus(leading: leading, trailing: trailing, busy: busy != nil)
    }

    func updateGutter() { onGutter?(gutterStatus()) }

    /// The selection's aggregates (I-4, data 2): "7 cells · Sum 615.00 · Average 87.86 · Min 8.00 · Max 234.00" for a
    /// selected column within two or more selected rows, "3 rows" for rows alone. Bounded at 100,000 cells.
    func selectionSummary() -> String? {
        let selected = grid.table.selectedRowIndexes
        guard selected.count > 1 else { return nil }
        guard let c = grid.selectedColumn else {
            let count = selected.count.formatted()
            return String(localized: "\(count) rows", bundle: .previewKit, comment: "Status line: how many rows are selected (two or more).")
        }
        var numbers: [Double] = []
        var cells = 0
        for row in selected.prefix(100_000) {
            cells += 1
            if let n = model.number(row: row, column: c) { numbers.append(n) }
        }
        let count = selected.count.formatted()
        var parts = [selected.count > 100_000
            ? String(localized: "≥ \(count) cells", bundle: .previewKit, comment: "Status line: at least this many cells are selected (only the first 100,000 are summed).")
            : String(localized: "\(count) cells", bundle: .previewKit, comment: "Status line: how many cells are selected.")]
        if !numbers.isEmpty {
            let sum = Self.format(numbers.reduce(0, +)), average = Self.format(numbers.reduce(0, +) / Double(numbers.count))
            let low = Self.format(numbers.min()!), high = Self.format(numbers.max()!)
            parts += [String(localized: "Sum \(sum)", bundle: .previewKit, comment: "Status line: the sum of the selected numbers."),
                      String(localized: "Average \(average)", bundle: .previewKit, comment: "Status line: the average of the selected numbers."),
                      String(localized: "Min \(low)", bundle: .previewKit, comment: "Status line: the smallest selected number."),
                      String(localized: "Max \(high)", bundle: .previewKit, comment: "Status line: the largest selected number.")]
            if numbers.count != cells {
                let counted = numbers.count.formatted()
                parts.append(String(localized: "Count \(counted)", bundle: .previewKit, comment: "Status line: how many selected cells hold numbers."))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Two decimals when any value has a fraction, as the design's "615.00"; whole numbers otherwise.
    static func format(_ x: Double) -> String {
        x.rounded() == x && abs(x) < 1e15 ? Int(x).formatted() : x.formatted(.number.precision(.fractionLength(2)))
    }

    override func cancelOperation(_ sender: Any?) {
        if busy != nil { cancel() } else { super.cancelOperation(sender) }
    }

    required init?(coder: NSCoder) { nil }

    func toggleInspector() {
        inspector.isHidden.toggle()
        inspectorWidth.constant = inspector.isHidden ? 0 : Metric.value("w-inspector")
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("page").cgColor }
}

/// A 0.5 pt vertical hairline in the `hair` token.
final class Hairline: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("hair").cgColor }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
}
