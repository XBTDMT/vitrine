import AppKit
import VitrineUI

/// What the user picked in the grid, which the Inspector follows.
enum DataSelection: Equatable {
    case file
    case column(Int)
    case row(Int)
}

/// The view-based table: a row-number gutter, then one column per data column. Cells come from `TabularModel.cell`,
/// which reads a page only when a row of it is first drawn. roadmap: S-6
@MainActor
final class DataGrid: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let gutter = NSUserInterfaceItemIdentifier("rn")
    let table = NSTableView()
    let model: any TabularModel
    private var layoutVersion: Int
    var onSelect: ((DataSelection) -> Void)?
    /// A click on the header of the column already selected, or a pick from the header's menu: sort by it.
    var onSort: ((_ column: Int, _ ascending: Bool?) -> Void)?
    private(set) var selectedColumn: Int?

    init(model: any TabularModel) {
        self.model = model
        layoutVersion = model.layoutVersion
        super.init()
        let rn = NSTableColumn(identifier: Self.gutter)
        rn.title = ""
        rn.width = 44
        rn.minWidth = 30
        rn.headerCell = DataHeaderCell(title: "", quality: nil, alignment: .right)
        table.addTableColumn(rn)
        addColumns()
        table.headerView = DataHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 26))
        let menu = NSMenu()
        menu.delegate = self
        table.headerView?.menu = menu
        // Rows 22 pt (G20).
        table.rowHeight = Metric.value("h-row")
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.style = .plain
        table.allowsColumnSelection = false
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.reloadData()
    }

    private func addColumns() {
        for c in 0..<model.columnCount {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(c)"))
            column.title = model.title(c)
            column.width = Self.width(model, column: c)
            column.minWidth = 40
            let header = DataHeaderCell(title: model.title(c), quality: model.hasMisfits(c),
                                        alignment: model.isNumeric(c) ? .right : .left)
            header.typeTag = model.typeTag(c)
            column.headerCell = header
            column.headerToolTip = model.headerTooltip(c)
            table.addTableColumn(column)
        }
    }

    /// A width from the header and the first page's values, clamped like Numbers does on open.
    static func width(_ model: any TabularModel, column: Int) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Metric.value("fs-control"))
        // The title plus its type tag (19–28 pt and a 4 pt gap).
        var longest = (model.title(column) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).width
            + DataHeaderCell.tagWidth(model.typeTag(column)) + 4
        for value in model.sampleValues(column: column) {
            longest = max(longest, (value as NSString).size(withAttributes: [.font: font]).width)
        }
        return min(260, max(56, ceil(longest) + 18))
    }

    func reload() {
        if model.layoutVersion != layoutVersion {
            // Another table: new columns, nothing selected, back to the top.
            layoutVersion = model.layoutVersion
            for column in table.tableColumns.dropFirst() { table.removeTableColumn(column) }
            selectedColumn = nil
            addColumns()
            table.deselectAll(nil)
            table.scrollRowToVisible(0)
        }
        let arrangement = model.arrangement
        for (c, column) in table.tableColumns.dropFirst().enumerated() {
            (column.headerCell as? DataHeaderCell)?.quality = model.hasMisfits(c)
            (column.headerCell as? DataHeaderCell)?.alignment = model.isNumeric(c) ? .right : .left
            (column.headerCell as? DataHeaderCell)?.sort = arrangement.sortColumn == c ? arrangement.ascending : nil
            (column.headerCell as? DataHeaderCell)?.typeTag = model.typeTag(c)
            column.headerToolTip = model.headerTooltip(c)
        }
        table.headerView?.needsDisplay = true
        table.reloadData()
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { model.shownCount }

    // MARK: Delegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? DataCell) ?? DataCell(identifier: id)
        if id == Self.gutter {
            cell.set(text: model.rowNumber(row).formatted(), font: .monospacedDigitSystemFont(ofSize: Metric.value("fs-micro"), weight: .regular),
                     color: "t3", alignment: .right)
            return cell
        }
        let c = Int(id.rawValue.dropFirst()) ?? 0
        let value = model.cell(row: row, column: c)
        let numeric = model.isNumeric(c)
        let misfit = value.style == .misfit
        cell.set(text: value.text, font: numeric ? .monospacedDigitSystemFont(ofSize: Metric.value("fs-control"), weight: .regular)
                                                 : .systemFont(ofSize: Metric.value("fs-control")),
                 color: misfit ? "caution-text" : value.style == .missing ? "t3" : "t1", alignment: numeric ? .right : .left,
                 marking: model.arrangement.filter)
        cell.misfit = misfit
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = DataRowView()
        view.grid = self
        return view
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? DataRowView)?.isOdd = row % 2 == 1
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        // The corner above the row numbers clears the picked column: selections and copies are whole rows again.
        if tableColumn.identifier == Self.gutter { clearColumn(); return }
        guard let c = Int(tableColumn.identifier.rawValue.dropFirst()) else { return }
        // First click selects the column (its profile opens); a click on the selected column sorts by it, the next
        // reverses, the next restores file order.
        if selectedColumn == c {
            let a = model.arrangement
            onSort?(c, a.sortColumn != c ? true : (a.ascending ? false : nil))
        } else {
            selectColumn(c)
        }
    }

    func selectColumn(_ c: Int) {
        selectedColumn = c
        for (i, column) in table.tableColumns.dropFirst().enumerated() { (column.headerCell as? DataHeaderCell)?.isOn = i == c }
        table.headerView?.needsDisplay = true
        for i in 0..<table.numberOfRows { table.rowView(atRow: i, makeIfNecessary: false)?.needsDisplay = true }
        onSelect?(.column(c))
    }

    func clearColumn() {
        guard selectedColumn != nil else { return }
        selectedColumn = nil
        for column in table.tableColumns.dropFirst() { (column.headerCell as? DataHeaderCell)?.isOn = false }
        table.headerView?.needsDisplay = true
        for i in 0..<table.numberOfRows { table.rowView(atRow: i, makeIfNecessary: false)?.needsDisplay = true }
        let row = table.selectedRow
        onSelect?(row >= 0 ? .row(row) : .file)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        onSelect?(row >= 0 ? .row(row) : (selectedColumn.map { .column($0) } ?? .file))
    }
}

extension DataGrid: NSMenuDelegate {
    /// The header's menu for the column under the pointer: sort ascending, descending, or back to file order.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = table.clickedColumn - 1
        guard c >= 0, c < model.columnCount else { return }
        let title = model.title(c)
        let items: [(String, Bool?)] = [
            (String(localized: "Sort by \(title) Ascending", bundle: .previewKit, comment: "Column header menu item; the argument is the column name."), true),
            (String(localized: "Sort by \(title) Descending", bundle: .previewKit, comment: "Column header menu item; the argument is the column name."), false),
            (String(localized: "File Order", bundle: .previewKit, comment: "Column header menu item: show the rows in the file's own order."), nil),
        ]
        for (label, ascending) in items {
            let item = NSMenuItem(title: label, action: #selector(sortFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = c
            item.representedObject = ascending.map { NSNumber(value: $0) }
            let a = model.arrangement
            item.state = (ascending == nil ? a.sortColumn == nil : a.sortColumn == c && a.ascending == ascending) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func sortFromMenu(_ item: NSMenuItem) {
        onSort?(item.tag, (item.representedObject as? NSNumber)?.boolValue)
    }
}

/// A label cell; reused through the table's identifier queue.
final class DataCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    var misfit = false { didSet { needsDisplay = true } }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func set(text: String, font: NSFont, color: String, alignment: NSTextAlignment, marking query: String = "") {
        label.font = font
        label.textColor = NSColor.token(color)
        label.alignment = alignment
        if query.isEmpty {
            label.stringValue = text
        } else {
            // The filter's matches marked in `find` (G15), as in the design's filtered table.
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.lineBreakMode = .byTruncatingTail
            let marked = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.token(color), .paragraphStyle: style])
            var range = text.startIndex..<text.endIndex
            while let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range) {
                marked.addAttribute(.backgroundColor, value: NSColor.token("find"), range: NSRange(found, in: text))
                range = found.upperBound..<text.endIndex
            }
            label.attributedStringValue = marked
        }
        misfit = false
    }

    override func draw(_ dirtyRect: NSRect) {
        if misfit { NSColor.token("caution-soft").setFill(); bounds.fill() }
        // The column separator: 0.5 pt in `sep` on the leading edge.
        NSColor.token("sep").setFill()
        NSRect(x: 0, y: 0, width: 0.5, height: bounds.height).fill()
    }
}

/// Zebra on real rows only (`zebra`), the selected row in `sel`, the selected column in `sel-col`, and a `sep`
/// hairline under each row.
final class DataRowView: NSTableRowView {
    weak var grid: DataGrid?
    var isOdd = false { didSet { needsDisplay = true } }

    override func drawBackground(in dirtyRect: NSRect) {
        if isOdd { NSColor.token("zebra").setFill(); bounds.fill() }
        if let grid, let c = grid.selectedColumn, c + 1 < grid.table.numberOfColumns {
            NSColor.token("sel-col").setFill()
            let r = grid.table.rect(ofColumn: c + 1)
            NSRect(x: r.minX, y: 0, width: r.width, height: bounds.height).fill()
        }
        NSColor.token("sep").setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.token("sel").setFill()
        bounds.fill()
    }

    override var isEmphasized: Bool { get { false } set {} }
}

/// The sticky header: `card2`, a `hair` line under it.
final class DataHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.token("card2").setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
}

/// One header: the title (t2, semibold; t1 when its column is selected) and the 2 pt quality line at its foot,
/// `fill2` when every sampled value fits the column's type, `caution` when some do not.
final class DataHeaderCell: NSTableHeaderCell {
    /// nil = no quality line (the row-number gutter).
    var quality: Bool?
    var isOn = false
    /// The column the rows are sorted by: true ascending, false descending (a chevron after the title); nil = not.
    var sort: Bool?
    /// The type tag before the title (G12, `.d-tg`): "123", "Aa", "≡", "@", "1.5", "0|1", "BIN"; "date" draws a calendar.
    var typeTag: String?

    static let tagFont = NSFont.monospacedSystemFont(ofSize: Metric.value("fs-micro"), weight: .medium)

    /// 15 pt tall, at least 19 wide, 3 pt either side of the text.
    static func tagWidth(_ tag: String?) -> CGFloat {
        guard let tag else { return 0 }
        if tag == "date" { return 19 }
        return max(19, ceil((tag as NSString).size(withAttributes: [.font: tagFont]).width) + 6)
    }

    init(title: String, quality: Bool?, alignment: NSTextAlignment) {
        self.quality = quality
        super.init(textCell: title)
        self.alignment = alignment
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    /// The tag box: a 0.5 pt `hair` outline, radius `r-kbd`, the text in t2 mono 500 ("date" draws a calendar).
    func drawTag(in box: NSRect) {
        guard let tag = typeTag else { return }
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.25, dy: 0.25), xRadius: Metric.value("r-kbd"), yRadius: Metric.value("r-kbd"))
        path.lineWidth = 0.5
        NSColor.token("hair").setStroke()
        path.stroke()
        if tag == "date", let cal = NSImage(systemSymbolName: "calendar", accessibilityDescription: String(localized: "date", bundle: .previewKit, comment: "Accessibility label of a column's type tag: the column holds dates."))?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular)) {
            let ink = NSColor.token("t2")
            let tinted = NSImage(size: cal.size, flipped: false) { r in cal.draw(in: r); ink.set(); r.fill(using: .sourceAtop); return true }
            tinted.draw(in: NSRect(x: box.midX - cal.size.width / 2, y: box.midY - cal.size.height / 2, width: cal.size.width, height: cal.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let tagAttributes: [NSAttributedString.Key: Any] = [.font: Self.tagFont, .foregroundColor: NSColor.token("t2")]
            let size = (tag as NSString).size(withAttributes: tagAttributes)
            (tag as NSString).draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: tagAttributes)
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor.token("card2").setFill()
        cellFrame.fill()
        NSColor.token("hair").setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 0.5, width: cellFrame.width, height: 0.5).fill()
        NSColor.token("sep").setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.minY, width: 0.5, height: cellFrame.height).fill()
        if let quality {
            NSColor.token(quality ? "caution" : "fill2").setFill()
            NSRect(x: cellFrame.minX, y: cellFrame.maxY - 2, width: cellFrame.width, height: 2).fill()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.token(isOn ? "t1" : "t2"),
            .paragraphStyle: style,
        ]
        let text = stringValue as NSString
        let h = text.size(withAttributes: attributes).height
        var titleRect = NSRect(x: cellFrame.minX + 8, y: cellFrame.midY - h / 2 - 1, width: cellFrame.width - 16, height: h)
        // AppKit draws the header past the last column with a copy of that column's cell and no title: no tag there.
        if let tag = typeTag, !text.isEqual(to: "") {
            // The tag box: a 0.5 pt `hair` outline, radius `r-kbd`, the text in t2 mono 500. In a right-aligned column the
            // tag still leads, at the cell's start (the design's header is one row: tag, then title).
            let w = Self.tagWidth(tag)
            let box = NSRect(x: cellFrame.minX + 8, y: cellFrame.midY - 7.5 - 1, width: w, height: 15)
            drawTag(in: box)
            titleRect.origin.x += w + 4
            titleRect.size.width -= w + 4
        }
        if let ascending = sort,
           let chevron = NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: ascending
            ? String(localized: "ascending", bundle: .previewKit, comment: "Accessibility description of the sort arrow in a column header.")
            : String(localized: "descending", bundle: .previewKit, comment: "Accessibility description of the sort arrow in a column header."))?
               .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
            // The sort chevron sits right after the title (data I-4), in a right-aligned column too.
            let size = chevron.size
            titleRect.size.width -= size.width + 4
            let titleWidth = min(text.size(withAttributes: attributes).width, titleRect.width)
            let chevronX = alignment == .right ? titleRect.maxX + 4 : titleRect.minX + titleWidth + 4
            let ink = NSColor.token("t1")
            let tinted = NSImage(size: size, flipped: false) { rect in
                chevron.draw(in: rect)
                ink.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: chevronX, y: cellFrame.midY - size.height / 2 - 1, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        text.draw(in: titleRect, withAttributes: attributes)
    }
}
