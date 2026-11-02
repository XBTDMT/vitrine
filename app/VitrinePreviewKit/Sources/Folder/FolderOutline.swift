import AppKit
import VitrineGit
import VitrineUI

/// The folder's list: one place at a time (the previewed folder or a subfolder it was navigated into), folders
/// opening in place, rows arranged by `FolderArrangement` under group headers, Finder tags as dots after the
/// name, top-level folder sizes from the background count. Two column sets: Name, Date, Size, Kind with sortable
/// headers; or, on a repository's page, Name, Last commit, When with no header. roadmap: S-9
@MainActor
final class FolderOutline: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let table = BrowseOutlineView()
    private(set) var root: FolderNode

    /// The repository's columns: each top-level item's last commit and when, and the status letter of every
    /// changed path (a folder takes the letter of what changed inside it). roadmap: S-9
    struct GitColumns {
        var lastTouch: [String: (subject: String, date: Date?)] = [:]
        /// Path relative to the work tree → status letter.
        var marks: [String: GitChange.Kind] = [:]
        let rootPath: String

        init(read: RepositoryRead, root: URL) {
            rootPath = root.standardizedFileURL.path
            for (name, c) in read.summary.lastTouch { lastTouch[name] = (c.subject, c.author?.date ?? c.committer?.date) }
            for change in read.summary.status?.changes ?? [] {
                let path = change.path.hasSuffix("/") ? String(change.path.dropLast()) : change.path
                marks[path] = change.kind
                var p = Substring(path)
                while let slash = p.lastIndex(of: "/") {
                    p = p[..<slash]
                    let key = String(p)
                    if let existing = marks[key], existing != change.kind { marks[key] = .modified } else if marks[key] == nil { marks[key] = change.kind }
                }
            }
        }

        func relative(_ node: FolderNode) -> String {
            let path = node.url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { return node.name }
            return String(path.dropFirst(rootPath.count + 1))
        }
    }

    /// A group header row ("Today 3").
    final class GroupRow: NSObject {
        let title: String
        let count: Int
        init(title: String, count: Int) { self.title = title; self.count = count }
    }

    enum Mode { case plain, repository }

    var git: GitColumns? { didSet { table.reloadData(); contentHeightChanged?() } }
    var contentHeightChanged: (() -> Void)?
    private(set) var mode: Mode
    var arrangement = FolderArrangement() { didSet { if arrangement != oldValue { rearrange() } } }
    /// The current place's background count; top-level folders take their size from it.
    var sizes: FolderSizes? { didSet { sizesChanged() } }
    var onActivate: ((FolderNode) -> Void)?
    var onSelect: ((FolderNode?) -> Void)?
    var onArrangementChange: ((FolderArrangement) -> Void)?

    private var rows: [AnyObject] = []
    private var sortedChildren: [ObjectIdentifier: [FolderNode]] = [:]
    private var header: NSTableHeaderView?
    private var settingSort = false
    static let plainColumns = ["name", "date", "size", "kind"]
    static let repositoryColumns = ["name", "commit", "when"]

    init(root: FolderNode, git: GitColumns? = nil) {
        self.root = root
        self.git = git
        mode = git == nil ? .plain : .repository
        super.init()
        let columns: [(String, String, Double, Bool)] = [
            ("name", FolderArrangement.Key.name.title, 280, false), ("date", FolderArrangement.Key.modified.title, 118, false),
            ("size", FolderArrangement.Key.size.title, 78, true), ("kind", FolderArrangement.Key.kind.title, 150, false),
            ("commit", String(localized: "Last commit", bundle: .previewKit, comment: "Folder list column header in a git repository: the last commit that touched the item."), 300, false),
            ("when", String(localized: "When", bundle: .previewKit, comment: "Folder list column header in a git repository: when the item last changed."), 96, true),
        ]
        for (id, title, width, right) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.headerCell.alignment = right ? .right : .left
            if let key = Self.sortKey(id) { column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: key.defaultAscending) }
            table.addTableColumn(column)
            if id == "name" { table.outlineTableColumn = column }
        }
        header = table.headerView
        table.rowHeight = Metric.value("h-row")
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onActivate = { [weak self] row in self?.activate(row: row) }
        applyMode()
        rearrange()
        NotificationCenter.default.addObserver(self, selector: #selector(expansionChanged), name: NSOutlineView.itemDidExpandNotification, object: table)
        NotificationCenter.default.addObserver(self, selector: #selector(expansionChanged), name: NSOutlineView.itemDidCollapseNotification, object: table)
    }

    @objc private func expansionChanged() { contentHeightChanged?() }

    static func sortKey(_ column: String) -> FolderArrangement.Key? {
        switch column {
        case "name": .name
        case "size": .size
        case "kind": .kind
        case "date": nil      // the date column's key follows the arrangement (set in `syncHeader`)
        default: nil
        }
    }

    /// The repository page's columns, or the plain list's (a subfolder of a repository, or any folder).
    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        applyMode()
        table.reloadData()
        contentHeightChanged?()
    }

    private func applyMode() {
        let shown = mode == .plain ? Self.plainColumns : Self.repositoryColumns
        for column in table.tableColumns { column.isHidden = !shown.contains(column.identifier.rawValue) }
        if mode == .repository {
            // The design's repository outline has no header row; the commit column takes the spare width.
            table.headerView = nil
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        } else {
            table.headerView = header
            table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        }
        syncHeader()
    }

    /// Shows another place (navigation): its rows, nothing selected, nothing searched.
    func show(root: FolderNode) {
        self.root = root
        clearFind()
        sizes = nil
        rearrange()
    }

    /// The rows' height plus the header, for sizing the outline's card.
    var contentHeight: CGFloat {
        let header = table.headerView?.frame.height ?? 0
        var h: CGFloat = 0
        for r in 0..<table.numberOfRows { h += table.rect(ofRow: r).height }
        return h + header + 2
    }

    func reload() { root.forget(); clearFind(); rearrange() }

    private func rearrange() {
        sortedChildren = [:]
        let size: (FolderNode) -> Int64? = { [weak self] in self?.size(of: $0) }
        rows = arrangement.rows(root.children(), size: size).map { row -> AnyObject in
            switch row {
            case .group(let title, let count): GroupRow(title: title, count: count)
            case .node(let n): n
            }
        }
        syncHeader()
        table.reloadData()
        contentHeightChanged?()
        onArrangementChange?(arrangement)
    }

    /// Header chevrons and the date column's title follow the arrangement.
    private func syncHeader() {
        guard let date = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("date")) else { return }
        let dateKey = arrangement.dateColumn
        date.title = dateKey.title
        date.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: dateKey.defaultAscending)
        let id: String? = switch arrangement.sort {
        case .name: "name"
        case .size: "size"
        case .kind: "kind"
        case .modified, .added: arrangement.sort == dateKey ? "date" : nil
        case .tags: nil
        }
        settingSort = true
        table.sortDescriptors = id.map { [NSSortDescriptor(key: $0, ascending: arrangement.ascending)] } ?? []
        settingSort = false
        // The chevron on the sorted column's header (the table draws it only for a click it handled itself).
        let chevron = NSImage(named: arrangement.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
        for column in table.tableColumns {
            table.setIndicatorImage(column.identifier.rawValue == id ? chevron : nil, in: column)
        }
        table.highlightedTableColumn = id.flatMap { table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier($0)) }
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !settingSort, let d = outlineView.sortDescriptors.first, let id = d.key else { return }
        var a = arrangement
        a.sort = id == "date" ? arrangement.dateColumn : (Self.sortKey(id) ?? .name)
        a.ascending = d.ascending
        arrangement = a
    }

    /// A top-level item's size: a file's own, a folder's from the count (nil while it is counted).
    func size(of n: FolderNode) -> Int64? {
        guard n.isFolder || n.isPackage else { return n.size }
        guard isTopLevel(n) else { return nil }
        return sizes?.children[n.name]?.bytes
    }

    private func sizesChanged() {
        if arrangement.sort == .size || arrangement.group == .size {
            rearrange()
            return
        }
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "size" }), table.numberOfRows > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: IndexSet(integer: column))
    }

    // MARK: Selection and stepping (the peek follows the selection)

    var selectedNode: FolderNode? { table.selectedRow >= 0 ? table.item(atRow: table.selectedRow) as? FolderNode : nil }

    /// Moves the selection to the next (+1) or previous (-1) item, skipping group headers; false at either end.
    @discardableResult
    func step(_ delta: Int) -> Bool {
        var row = table.selectedRow
        repeat {
            row += delta
            guard row >= 0, row < table.numberOfRows else { return false }
        } while table.item(atRow: row) is GroupRow
        select(row: row)
        return true
    }

    func select(_ node: FolderNode) {
        let row = table.row(forItem: node)
        if row >= 0 { select(row: row) }
    }

    private func select(row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        activate(row: table.clickedRow)
    }

    private func activate(row: Int) {
        guard let n = table.item(atRow: row) as? FolderNode else { return }
        onActivate?(n)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { onSelect?(selectedNode) }

    // MARK: Find (the capsule's find, S-24)

    /// Folders are read as the search goes, so it is bounded: past this many items the count is a floor.
    static let findLimit = 10_000
    private var findQuery = ""
    private var matches: [(node: FolderNode, folders: [FolderNode])] = []
    /// Each match's turn in the walk of the whole folder, and how many items the walk saw, for the ruler (B-7).
    private var matchTurns: [Int] = []
    private var walked = 1
    weak var ruler: RulerScroller?

    private func placeMarks() {
        let total = Double(max(1, walked))
        ruler?.marks = matchTurns.enumerated().map { i, turn in (Double(turn) / total, i == findIndex ? .current : .match) }
    }
    private var searchedAll = true
    private var findIndex = -1

    /// Every item whose name contains the query, depth first in the place's order, packages unopened; the current
    /// one is revealed (its folders opened) and selected.
    func find(_ q: String, forward: Bool) -> FindResult {
        if q != findQuery {
            findQuery = q
            findIndex = -1
            matches = []
            matchTurns = []
            searchedAll = true
            if !q.isEmpty {
                var visited = 0
                defer { walked = visited }
                let top = rows.compactMap { $0 as? FolderNode }
                var stack: [(FolderNode, [FolderNode])] = top.reversed().map { ($0, []) }
                while let (n, folders) = stack.popLast() {
                    visited += 1
                    if visited > Self.findLimit { searchedAll = false; break }
                    if n.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { matches.append((n, folders)); matchTurns.append(visited) }
                    if n.isFolder { stack.append(contentsOf: children(of: n).reversed().map { ($0, folders + [n]) }) }
                }
            }
        }
        guard !matches.isEmpty else { table.deselectAll(nil); return FindResult(count: 0, index: -1, searchedAll: searchedAll) }
        findIndex = forward ? (findIndex + 1) % matches.count : (findIndex - 1 + matches.count) % matches.count
        let match = matches[findIndex]
        for folder in match.folders { table.expandItem(folder) }
        select(match.node)
        placeMarks()
        return FindResult(count: matches.count, index: findIndex, searchedAll: searchedAll)
    }

    func clearFind() { findQuery = ""; matches = []; matchTurns = []; findIndex = -1; searchedAll = true; table.deselectAll(nil); ruler?.marks = [] }

    // MARK: Data source

    /// A folder's children in the arrangement's order (folders below the top have no counted size).
    private func children(of n: FolderNode) -> [FolderNode] {
        if let c = sortedChildren[ObjectIdentifier(n)] { return c }
        let c = arrangement.sorted(n.children(), size: { $0.isFolder ? nil : $0.size })
        sortedChildren[ObjectIdentifier(n)] = c
        return c
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return rows.count }
        return (item as? FolderNode).map { children(of: $0).count } ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? FolderNode else { return rows[index] }
        return children(of: n)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FolderNode)?.isFolder == true }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is FolderNode }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is GroupRow ? 26 : Metric.value("h-row") }

    /// "09:12" today, "Thu" this week, "Oct 3" this year, "Oct 3, 2025" before.
    static func shortDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days > 0, days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// A folder's size cell while its size is counted.
    static let counting = String(localized: "counting", bundle: .previewKit, comment: "Folder list size cell: the folder's size is still being counted.")

    /// The text of one cell (tests read it here).
    func text(for n: FolderNode, column id: String) -> String {
        switch id {
        case "name": return n.name
        case "size":
            guard n.isFolder || n.isPackage else { return ByteCountFormatter.string(fromByteCount: n.size, countStyle: .file) }
            guard let bytes = size(of: n) else { return sizes?.finished == false && isTopLevel(n) ? Self.counting : "—" }
            let floor = sizes?.children[n.name]?.complete == false
            return (floor ? "≥ " : "") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case "kind": return n.kind
        case "commit": return git?.lastTouch[git?.relative(n) ?? n.name]?.subject ?? ""
        case "when":
            let date = git?.lastTouch[git?.relative(n) ?? n.name]?.date ?? n.modified
            return date.map { GitText.relative($0) } ?? ""
        default:
            let date = arrangement.dateColumn == .added ? n.added : n.modified
            return date.map { Self.shortDate($0) } ?? ""
        }
    }

    /// An item of the place itself (not of a folder opened inside it). Paths, not URLs: a folder's URL may or
    /// may not end in "/".
    private func isTopLevel(_ n: FolderNode) -> Bool {
        n.url.deletingLastPathComponent().standardizedFileURL.path == root.url.standardizedFileURL.path
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? GroupRow {
            guard tableColumn == nil || tableColumn?.identifier.rawValue == "name" else { return NSView() }
            return Self.groupCell(group)
        }
        guard let n = item as? FolderNode else { return nil }
        let id = tableColumn?.identifier.rawValue ?? "name"
        let cell = NSTableCellView()
        let value = text(for: n, column: id)
        let label = NSTextField(labelWithString: value)
        let size = id == "when" ? Metric.value("fs-sub") : Metric.value("fs-control")
        label.font = id == "name" || id == "commit" ? .systemFont(ofSize: size) : .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        label.textColor = NSColor.token(id == "name" ? "t1" : (value == Self.counting ? "t3" : "t2"))
        label.alignment = id == "size" || id == "when" ? .right : .left
        label.lineBreakMode = id == "commit" ? .byTruncatingTail : .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(label)
        var leading = label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        var trailing = label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)
        if id == "name" {
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: n.url.path))
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
            leading = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5)
            // After the name: the status letter (`.st-m` beside "src"), then the tag dots (`.tag`).
            var after: [NSView] = []
            if let git, let kind = git.marks[git.relative(n)] {
                let mark = NSTextField(labelWithString: kind.rawValue)
                mark.font = .monospacedSystemFont(ofSize: Metric.value("fs-caption"), weight: .semibold)
                mark.textColor = NSColor.token(RepositoryPanel.markToken(kind))
                after.append(mark)
            }
            let colored = n.tags.filter { $0.nsColor != nil }
            if !colored.isEmpty {
                let dots = TagDots(tags: colored)
                dots.toolTip = n.tags.map(\.name).joined(separator: ", ")
                after.append(dots)
            }
            if !after.isEmpty {
                let trail = NSStackView(views: after)
                trail.spacing = 4
                trail.translatesAutoresizingMaskIntoConstraints = false
                trail.setContentCompressionResistancePriority(.required, for: .horizontal)
                trail.setContentHuggingPriority(.required, for: .horizontal)
                cell.addSubview(trail)
                NSLayoutConstraint.activate([trail.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5),
                                             trail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                             trail.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4)])
                trailing = label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -(trail.fittingSize.width + 9))
            }
        }
        NSLayoutConstraint.activate([leading, trailing, label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    /// `.ogrp`: 26 pt, the title at the bottom (11/600, t2) and the count after it in t3.
    private static func groupCell(_ group: GroupRow) -> NSView {
        let cell = NSTableCellView()
        let text = NSMutableAttributedString(string: group.title, attributes: [
            .font: NSFont.systemFont(ofSize: Metric.value("fs-caption"), weight: .semibold), .foregroundColor: NSColor.token("t2")])
        text.append(NSAttributedString(string: "  \(group.count.formatted())", attributes: [
            .font: NSFont.systemFont(ofSize: Metric.value("fs-caption")), .foregroundColor: NSColor.token("t3")]))
        let label = NSTextField(labelWithAttributedString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 0),
                                     label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4)])
        let title = group.title, count = group.count.formatted()
        cell.setAccessibilityLabel(group.count == 1
            ? String(localized: "\(title), \(count) item", bundle: .previewKit, comment: "Accessibility label of a folder list group header with one item. Arguments: group title, count.")
            : String(localized: "\(title), \(count) items", bundle: .previewKit, comment: "Accessibility label of a folder list group header. Arguments: group title, count."))
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = FlaggedRow()
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? FlaggedRow)?.isOdd = row % 2 == 1 && !(outlineView.item(atRow: row) is GroupRow)
    }
}

/// Finder tag dots after a name: 8 pt circles in the tag colours, overlapping, ringed in the page colour.
/// roadmap: S-9
@MainActor
final class TagDots: NSView {
    private let colors: [NSColor]
    init(tags: [FinderTag]) {
        colors = tags.prefix(3).compactMap(\.nsColor)
        super.init(frame: .zero)
        let names = tags.map(\.name).formatted(.list(type: .and))
        setAccessibilityLabel(String(localized: "Tags: \(names)", bundle: .previewKit, comment: "Accessibility label of an item's Finder tag dots; the argument is the tag names as a list."))
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 8 + CGFloat(max(0, colors.count - 1)) * 5 + 2, height: 10) }
    override func draw(_ dirtyRect: NSRect) {
        for (i, color) in colors.enumerated().reversed() {
            let r = NSRect(x: 1 + CGFloat(i) * 5, y: (bounds.height - 8) / 2, width: 8, height: 8)
            NSColor.token("page").setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: -1, dy: -1)).fill()
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
        }
    }
}
