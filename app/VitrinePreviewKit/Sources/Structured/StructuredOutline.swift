import AppKit
import VitrineData
import VitrineUI

/// The Tree view's outline (code design 9: 22 pt rows, counts in the `.cnt` pill, the selected row on the accent
/// tint with its Value and Path copy buttons): one row per node, children asked for only when a row is unfolded, and a
/// container with more than `pageSize` rows shows a page of them with "N more items" rows that load the next page
/// when clicked (state 5's "3 items above · 0 – 2" / "244 more items · 4 – 247"). Folded by default past level 2,
/// within a row budget, so a large document paints at once. roadmap: S-5
@MainActor
final class StructuredOutline: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// The copy buttons' words, on the path bar and on a selected row.
    nonisolated static var pathWord: String { String(localized: "Path", bundle: .previewKit, comment: "Button: copies the selected tree node's path.") }
    nonisolated static var valueWord: String { String(localized: "Value", bundle: .previewKit, comment: "Button: copies the selected tree node's value.") }

    final class NodeItem: NSObject { let index: Int; init(_ index: Int) { self.index = index } }
    /// A placeholder for rows of `parent` outside its page: `above` the page or after it.
    final class MoreItem: NSObject {
        let parent: Int?; let above: Bool; let range: Range<Int>
        init(parent: Int?, above: Bool, range: Range<Int>) { self.parent = parent; self.above = above; self.range = range }
    }
    /// A line of information in the tree: children a limit kept out, or where a syntax error stopped the parse.
    final class NoteItem: NSObject {
        let text: String; let isError: Bool
        init(_ text: String, isError: Bool) { self.text = text; self.isError = isError }
    }

    /// Rows shown per page of one container's children.
    static let pageSize = 200
    /// Rows unfolded by default (level 2 and up stays folded past this).
    static let defaultRowBudget = 300
    /// A level-1 container with more rows than this stays folded, so its siblings stay on the first screen.
    static let defaultContainerRows = 50
    /// Nodes find visits before it stops and says its count is a floor.
    static let findLimit = 250_000

    let table = NSOutlineView()
    let model: StructuredTreeModel
    var onSelect: ((Int?) -> Void)?
    var pasteboard: NSPasteboard = .general
    private var items: [Int: NodeItem] = [:]
    /// The page shown for each paged container (key -1: the top level).
    private var windows: [Int: Range<Int>] = [:]
    private var rowsCache: [Int: [NSObject]] = [:]

    init(model: StructuredTreeModel) {
        self.model = model
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("node"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.outlineTableColumn = column
        table.headerView = nil
        table.rowHeight = Metric.value("h-row")
        table.indentationPerLevel = Metric.value("sp-14")
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.reloadData()
    }

    func item(_ index: Int) -> NodeItem {
        if let item = items[index] { return item }
        let item = NodeItem(index); items[index] = item; return item
    }

    /// The rows under `parent` (nil = top level): its page of nodes, the "more" rows around the page, then notes.
    func rows(_ parent: Int?) -> [NSObject] {
        let key = parent ?? -1
        if let rows = rowsCache[key] { return rows }
        let count = model.childCount(of: parent)
        let window = count > Self.pageSize ? (windows[key] ?? 0..<Self.pageSize) : 0..<count
        var rows: [NSObject] = []
        if window.lowerBound > 0 { rows.append(MoreItem(parent: parent, above: true, range: 0..<window.lowerBound)) }
        for position in window { rows.append(item(model.child(position, of: parent))) }
        if window.upperBound < count { rows.append(MoreItem(parent: parent, above: false, range: window.upperBound..<count)) }
        let omitted = model.omittedCount(of: parent)
        if omitted > 0 {
            rows.append(NoteItem(String(localized: "\(omitted) more in the file, not kept: a size limit stopped the tree", bundle: .previewKit,
                                        comment: "Tree note: how many children were not kept because of a size limit."), isError: false))
        }
        if parent == nil, let error = model.result.error {
            // The reason is the parser's own words.
            let note = error.location.map {
                String(localized: "Line \($0.line): \(error.reason). The tree stops here; Source shows the whole file.", bundle: .previewKit,
                       comment: "Tree note at a syntax error: the line, the parser's reason, then where to read the whole file.")
            } ?? String(localized: "\(error.reason). The tree stops here; Source shows the whole file.", bundle: .previewKit,
                        comment: "Tree note at a syntax error: the parser's reason, then where to read the whole file.")
            rows.append(NoteItem(note, isError: true))
        }
        rowsCache[key] = rows
        return rows
    }

    /// Unfolds level-1 containers of up to `defaultContainerRows` rows while the visible rows stay within
    /// `defaultRowBudget` (code state 5: collapsed by default past level 2). A single top row (a property list's Root, an XML document element)
    /// counts as level 0.
    func expandDefault() {
        var budget = Self.defaultRowBudget - rows(nil).count
        var level1 = rows(nil).compactMap { $0 as? NodeItem }.filter { model.isExpandable($0.index) }
        if level1.count == 1, rows(nil).count == 1, let only = level1.first {
            table.expandItem(only)
            budget -= rows(only.index).count
            level1 = rows(only.index).compactMap { $0 as? NodeItem }.filter { model.isExpandable($0.index) }
        }
        for node in level1 {
            let cost = rows(node.index).count
            guard cost <= min(budget, Self.defaultContainerRows) else { continue }
            table.expandItem(node)
            budget -= cost
        }
    }

    var selectedNode: Int? { (table.item(atRow: table.selectedRow) as? NodeItem)?.index }

    // MARK: Paging

    @objc private func clicked() {
        guard let more = table.item(atRow: table.clickedRow) as? MoreItem else { return }
        showMore(more)
    }

    /// Loads the next page in the "more" row's direction.
    func showMore(_ more: MoreItem) {
        let key = more.parent ?? -1
        let count = model.childCount(of: more.parent)
        let window = windows[key] ?? 0..<Self.pageSize
        windows[key] = more.above ? max(0, window.lowerBound - Self.pageSize)..<window.upperBound
            : window.lowerBound..<min(count, window.upperBound + Self.pageSize)
        reloadChildren(of: more.parent)
    }

    private func reloadChildren(of parent: Int?) {
        rowsCache[parent ?? -1] = nil
        table.reloadItem(parent.map { item($0) }, reloadChildren: true)
    }

    /// Unfolds `node`'s ancestors, moves each paged ancestor's page onto the path, selects the row and scrolls to it.
    func reveal(_ node: Int) {
        var chain: [Int] = []
        var current = model.outlineParent(of: node)
        while let parent = current { chain.append(parent); current = model.outlineParent(of: parent) }
        chain.reverse()
        let parents: [Int?] = [nil] + chain.map { Optional($0) }
        for (parent, child) in zip(parents, chain + [node]) {
            let count = model.childCount(of: parent)
            if count > Self.pageSize {
                let position = model.position(of: child)
                let key = parent ?? -1
                if !(windows[key] ?? 0..<Self.pageSize).contains(position) {
                    windows[key] = position..<(position + 1)
                    reloadChildren(of: parent)
                }
            }
            if let parent { table.expandItem(item(parent)) }
        }
        let row = table.row(forItem: item(node))
        guard row >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Copy (state 5: per-node Value and Path)

    func copyValue(of node: Int) { put(model.copyText(of: node)) }
    func copyPath(of node: Int) { put(model.path(of: node)) }

    private func put(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Find (the capsule's find, S-24)

    private var findQuery = ""
    private var matches: [Int] = []
    /// The tree's ruler (B-7): each match marked at its place in the whole document, collapsed parts included.
    weak var ruler: RulerScroller?

    private func placeMarks() {
        let total = Double(max(1, model.tree.count))
        ruler?.marks = matches.enumerated().map { i, node in (Double(node) / total, i == findIndex ? .current : .match) }
    }
    private var searchedAll = true
    private var findIndex = -1

    /// Keys and values containing the query, in document order, folded or not; the current one is revealed and
    /// selected. Bounded at `limit` nodes, like the folder outline.
    func find(_ query: String, forward: Bool, limit: Int = StructuredOutline.findLimit) -> FindResult {
        if query != findQuery {
            findQuery = query
            findIndex = -1
            (matches, searchedAll) = model.matches(query, limit: limit)
        }
        guard !matches.isEmpty else { table.deselectAll(nil); return FindResult(count: 0, index: -1, searchedAll: searchedAll) }
        findIndex = forward ? (findIndex + 1) % matches.count : (findIndex - 1 + matches.count) % matches.count
        reveal(matches[findIndex])
        placeMarks()
        return FindResult(count: matches.count, index: findIndex, searchedAll: searchedAll)
    }

    func clearFind() { findQuery = ""; matches = []; findIndex = -1; searchedAll = true; table.deselectAll(nil); ruler?.marks = [] }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return rows(nil).count }
        guard let node = item as? NodeItem else { return 0 }
        return rows(node.index).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        rows((item as? NodeItem)?.index)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? NodeItem else { return false }
        return model.isExpandable(node.index)
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = StructuredCell()
        switch item {
        case let node as NodeItem:
            cell.show(model.row(node.index, expanded: outlineView.isItemExpanded(node)))
        case let more as MoreItem:
            let n = more.range.count, from = more.range.lowerBound, to = more.range.upperBound - 1
            let note = switch (model.isXML, more.above) {
            case (true, true): String(localized: "\(n) elements above · \(from) – \(to)", bundle: .previewKit,
                                      comment: "Tree row for a page of XML elements above the shown ones, then their index range.")
            case (true, false): String(localized: "\(n) more elements · \(from) – \(to)", bundle: .previewKit,
                                       comment: "Tree row for a page of XML elements below the shown ones, then their index range.")
            case (false, true): String(localized: "\(n) items above · \(from) – \(to)", bundle: .previewKit,
                                       comment: "Tree row for a page of items above the shown ones, then their index range.")
            case (false, false): String(localized: "\(n) more items · \(from) – \(to)", bundle: .previewKit,
                                        comment: "Tree row for a page of items below the shown ones, then their index range.")
            }
            cell.showNote(note, isError: false)
        case let note as NoteItem:
            cell.showNote(note.text, isError: note.isError)
        default: break
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = StructuredRowView()
        row.isError = (item as? NoteItem)?.isError == true
        if let node = item as? NodeItem {
            row.onCopyValue = { [weak self] in self?.copyValue(of: node.index) }
            row.onCopyPath = { [weak self] in self?.copyPath(of: node.index) }
        }
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is NodeItem }

    func outlineViewSelectionDidChange(_ notification: Notification) { onSelect?(selectedNode) }

    // A folded container shows its inline preview, an unfolded one only its count: redraw the row when it turns.
    func outlineViewItemDidExpand(_ notification: Notification) { refresh(notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { refresh(notification) }

    private func refresh(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? NodeItem else { return }
        let row = table.row(forItem: item)
        guard row >= 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }
}

/// One row's content: the text runs in their syntax colours, the child count pill, the type tag at the right.
@MainActor
final class StructuredCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    let count = CountPill()
    let typeLabel = NSTextField(labelWithString: "")
    private var noteConstraints: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        for v in [label, count, typeLabel] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        typeLabel.font = .systemFont(ofSize: Metric.value("fs-caption"))
        typeLabel.textColor = NSColor.token("t2")
        typeLabel.alignment = .right
        typeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: Metric.value("sp-4")),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.trailingAnchor.constraint(lessThanOrEqualTo: typeLabel.leadingAnchor, constant: -Metric.value("sp-8")),
            label.trailingAnchor.constraint(lessThanOrEqualTo: typeLabel.leadingAnchor, constant: -Metric.value("sp-8")),
            typeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metric.value("sp-10")),
            typeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ row: StructuredTreeModel.Row) {
        let mono = NSFont.monospacedSystemFont(ofSize: Metric.value("fs-mono"), weight: .regular)
        let text = NSMutableAttributedString()
        for segment in row.segments {
            text.append(NSAttributedString(string: segment.text, attributes: [.font: mono, .foregroundColor: NSColor.token(segment.token)]))
        }
        label.attributedStringValue = text
        count.text = row.count
        typeLabel.stringValue = row.typeTag ?? ""
        toolTip = row.typeTag.map { "\($0): \(row.text)" }
    }

    func showNote(_ text: String, isError: Bool) {
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: Metric.value("fs-sub")),
            .foregroundColor: NSColor.token(isError ? "caution-text" : "t2"),
        ])
        count.text = nil
        typeLabel.stringValue = ""
        toolTip = text
    }

    /// The selected row's copy buttons sit where the type tag is.
    var tagHidden = false { didSet { typeLabel.isHidden = tagHidden } }
}

/// "248 items": 11 pt t2 text on the `fill` token, fully rounded (`.cnt`).
@MainActor
final class CountPill: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String? {
        didSet { label.stringValue = text ?? ""; isHidden = text == nil }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: Metric.value("fs-caption"))
        label.textColor = NSColor.token("t2")
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metric.value("sp-6")),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metric.value("sp-6")),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Metric.value("sp-2")),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metric.value("sp-2")),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.token("fill").cgColor
        layer?.cornerRadius = bounds.height / 2
    }

    override func layout() { super.layout(); needsDisplay = true }
}

/// The selected row on `sel` (the accent tint, not the solid system highlight) with Value and Path copy buttons at
/// its right (state 5); a syntax-error note on `caution-soft`.
@MainActor
final class StructuredRowView: NSTableRowView {
    var isError = false
    var onCopyValue: (() -> Void)?
    var onCopyPath: (() -> Void)?
    private var actions: NSStackView?

    override var isEmphasized: Bool { get { false } set {} }

    override var isSelected: Bool {
        didSet {
            guard onCopyValue != nil else { return }
            if isSelected, actions == nil { addActions() }
            actions?.isHidden = !isSelected
            for case let cell as StructuredCell in subviews.flatMap({ [$0] + $0.subviews }) { cell.tagHidden = isSelected }
        }
    }

    private func addActions() {
        let value = Self.button(StructuredOutline.valueWord, #selector(copyValue), self,
                                help: String(localized: "Copy the value", bundle: .previewKit, comment: "Tooltip of a tree row's Value button."))
        let path = Self.button(StructuredOutline.pathWord, #selector(copyPath), self,
                               help: String(localized: "Copy the path", bundle: .previewKit, comment: "Tooltip of a tree row's Path button."))
        let stack = NSStackView(views: [value, path])
        stack.spacing = Metric.value("sp-4")
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metric.value("sp-8")),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        actions = stack
    }

    static func button(_ title: String, _ action: Selector, _ target: AnyObject, help: String) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage(),
                              target: target, action: action)
        button.imagePosition = .imageLeading
        button.controlSize = .mini
        button.bezelStyle = .push
        button.font = .systemFont(ofSize: Metric.value("fs-caption"))
        button.toolTip = help
        return button
    }

    @objc private func copyValue() { onCopyValue?() }
    @objc private func copyPath() { onCopyPath?() }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.token("sel").setFill()
        bounds.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isError else { return }
        NSColor.token("caution-soft").setFill()
        let r = Metric.value("r-ctl")
        NSBezierPath(roundedRect: bounds.insetBy(dx: Metric.value("sp-8"), dy: 1), xRadius: r, yRadius: r).fill()
    }
}
