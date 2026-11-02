import AppKit
import VitrineUI

/// The byte-decoding drawer under the rows (code design state 13, CHANGES §code 10): 150 pt on `card2` with a `sep`
/// hairline on top. Left, "Bytes at cursor" with its Little / Big switch and one row per reading, the best fit for
/// the selection in the accent colour; every row copies (⌘C, double-click, or its menu). Right, the file's text runs;
/// a click selects one in the rows. ⌘I shows or hides it. roadmap: S-5
@MainActor
final class HexDrawer: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let height: CGFloat = 150
    /// Under this width the text runs step aside and the readings take the whole drawer.
    static let runsMinimumWidth: CGFloat = 520

    let title = NSTextField(labelWithString: String(localized: "Bytes at cursor", bundle: .previewKit, comment: "Decoding drawer title: the bytes at the selection read several ways."))
    let endian = NSSegmentedControl(labels: [String(localized: "Little", bundle: .previewKit, comment: "Byte order switch: little-endian."),
                                             String(localized: "Big", bundle: .previewKit, comment: "Byte order switch: big-endian.")],
                                    trackingMode: .selectOne, target: nil, action: nil)
    let readings = HexCopyTable()
    let placeholder = NSTextField(labelWithString: String(localized: "Select a byte to read it as numbers, a date or text.", bundle: .previewKit, comment: "Decoding drawer, nothing selected yet."))
    let runsTitle = NSTextField(labelWithString: HexDrawer.runsHeading)
    let runsTable = NSTableView()
    static let runsHeading = String(localized: "Text runs", bundle: .previewKit, comment: "Decoding drawer heading over the runs of printable text.")
    private let readingsScroll = NSScrollView()
    private let runsScroll = NSScrollView()
    private let runsPane = NSView()
    private let divider = HexRule()
    private let topRule = HexRule()

    private(set) var rows: [HexDecodedRow] = []
    private(set) var runs: [HexTextRun] = []
    var onEndian: ((HexEndian) -> Void)?
    var onRun: ((HexTextRun) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = .systemFont(ofSize: Metric.value("fs-sub"), weight: .semibold)
        title.textColor = .token("t1")
        runsTitle.font = .systemFont(ofSize: Metric.value("fs-caption"), weight: .semibold)
        runsTitle.textColor = .token("t2")
        placeholder.font = .systemFont(ofSize: Metric.value("fs-control"))
        placeholder.textColor = .token("t3")
        endian.controlSize = .small
        endian.selectedSegment = 0
        endian.target = self
        endian.action = #selector(endianChanged)
        endian.setAccessibilityLabel(String(localized: "Byte order", bundle: .previewKit, comment: "Accessibility label of the little/big-endian switch."))

        configure(readings, scroll: readingsScroll, columns: ["label", "value"])
        // The values keep room for a whole date ("21 Oct 2026, 09:14:03 UTC"); the labels take the rest.
        readings.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        readings.tableColumns[1].width = 196
        readings.tableColumns[1].resizingMask = []
        readings.doubleAction = #selector(HexCopyTable.copyValue(_:))
        readings.target = readings
        readings.copyText = { [weak self] rows, withLabels in
            guard let self else { return "" }
            return rows.compactMap { self.rows.indices.contains($0) ? self.rows[$0] : nil }
                .map { withLabels ? "\($0.label)\t\($0.value)" : $0.value }.joined(separator: "\n")
        }
        configure(runsTable, scroll: runsScroll, columns: ["run"])
        runsTable.target = self
        runsTable.action = #selector(runClicked)

        for v in [title, endian, readingsScroll, placeholder] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        for v in [runsTitle, runsScroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; runsPane.addSubview(v) }
        for v in [runsPane, divider, topRule] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        let left = readingsScroll
        NSLayoutConstraint.activate([
            topRule.topAnchor.constraint(equalTo: topAnchor), topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor), topRule.heightAnchor.constraint(equalToConstant: 0.5),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 9), title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            endian.centerYAnchor.constraint(equalTo: title.centerYAnchor), endian.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            left.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5), left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            left.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            placeholder.leadingAnchor.constraint(equalTo: left.leadingAnchor), placeholder.topAnchor.constraint(equalTo: left.topAnchor, constant: 4),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: left.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 0.5),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 8), divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            runsPane.topAnchor.constraint(equalTo: topAnchor, constant: 8), runsPane.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            runsTitle.topAnchor.constraint(equalTo: runsPane.topAnchor, constant: 1), runsTitle.leadingAnchor.constraint(equalTo: runsPane.leadingAnchor, constant: 2),
            runsScroll.topAnchor.constraint(equalTo: runsTitle.bottomAnchor, constant: 4), runsScroll.leadingAnchor.constraint(equalTo: runsPane.leadingAnchor),
            runsScroll.trailingAnchor.constraint(equalTo: runsPane.trailingAnchor), runsScroll.bottomAnchor.constraint(equalTo: runsPane.bottomAnchor),
        ])
        wideConstraints = [
            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 9),
            runsPane.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 12),
            runsPane.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            // Readings 1.2 : runs 1, as the design's flex.
            runsPane.widthAnchor.constraint(equalTo: left.widthAnchor, multiplier: 1 / 1.2),
        ]
        narrowConstraints = [left.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)]
        NSLayoutConstraint.activate(wideConstraints)
        show(rows: [])
    }

    required init?(coder: NSCoder) { nil }

    private var wideConstraints: [NSLayoutConstraint] = []
    private var narrowConstraints: [NSLayoutConstraint] = []
    private var isNarrow = false

    private func configure(_ table: NSTableView, scroll: NSScrollView, columns: [String]) {
        for id in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 19
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("card2").cgColor }

    override func layout() {
        let narrow = bounds.width < Self.runsMinimumWidth
        if narrow != isNarrow {
            isNarrow = narrow
            runsPane.isHidden = narrow
            divider.isHidden = narrow
            NSLayoutConstraint.deactivate(narrow ? wideConstraints : narrowConstraints)
            NSLayoutConstraint.activate(narrow ? narrowConstraints : wideConstraints)
        }
        super.layout()
    }

    // MARK: Content

    func show(rows: [HexDecodedRow]) {
        self.rows = rows
        placeholder.isHidden = !rows.isEmpty
        readings.reloadData()
        // The reading that fits the selection best is in view, however far down the list it is.
        if let best = rows.firstIndex(where: \.highlighted) { readings.scrollRowToVisible(best) }
    }

    func show(runs: [HexTextRun], scanned: Int64, total: Int64) {
        self.runs = runs
        let first = ByteCountFormatter.string(fromByteCount: scanned, countStyle: .file)
        runsTitle.stringValue = scanned < total
            ? String(localized: "Text runs · first \(first)", bundle: .previewKit, comment: "Decoding drawer heading: text runs found in the first part of the file; the argument is a size.")
            : Self.runsHeading
        runsTable.reloadData()
    }

    @objc private func endianChanged() { onEndian?(endian.selectedSegment == 1 ? .big : .little) }

    @objc private func runClicked() {
        let row = runsTable.clickedRow >= 0 ? runsTable.clickedRow : runsTable.selectedRow
        guard runs.indices.contains(row) else { return }
        onRun?(runs[row])
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === readings ? rows.count : runs.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView === readings ? HexRuledRowView() : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        if tableView === runsTable { return HexRunCell(run: runs[row]) }
        let reading = rows[row]
        let field = NSTextField(labelWithString: id == "label" ? reading.label : reading.value)
        field.lineBreakMode = .byTruncatingTail
        if id == "label" {
            field.font = .systemFont(ofSize: Metric.value("fs-control"))
            field.textColor = .token("t2")
            field.toolTip = reading.label
        } else {
            field.font = .monospacedSystemFont(ofSize: Metric.value("fs-mono-sm"), weight: reading.highlighted ? .semibold : .regular)
            field.textColor = .token(reading.highlighted ? "accent-text" : "t1")
            field.alignment = .right
            field.toolTip = reading.value
        }
        field.setAccessibilityLabel("\(reading.label): \(reading.value)")
        return field
    }
}

/// A table whose rows copy: ⌘C and double-click copy the values, the menu also offers label and value. roadmap: S-5
@MainActor
final class HexCopyTable: NSTableView {
    var copyText: ((IndexSet, Bool) -> String)?
    var pasteboard: NSPasteboard = .general

    override init(frame: NSRect) {
        super.init(frame: frame)
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Copy Value", bundle: .previewKit, comment: "Context menu item in the decoding drawer."), action: #selector(copyValue(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Copy Name and Value", bundle: .previewKit, comment: "Context menu item in the decoding drawer."), action: #selector(copyRow(_:)), keyEquivalent: "").target = self
        self.menu = menu
    }

    required init?(coder: NSCoder) { nil }

    private var targetRows: IndexSet {
        clickedRow >= 0 && !selectedRowIndexes.contains(clickedRow) ? IndexSet(integer: clickedRow) : selectedRowIndexes
    }

    @objc func copy(_ sender: Any?) { put(copyText?(selectedRowIndexes, false)) }
    @objc func copyValue(_ sender: Any?) { put(copyText?(targetRows, false)) }
    @objc func copyRow(_ sender: Any?) { put(copyText?(targetRows, true)) }

    private func put(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// A reading's row with the `sep` hairline under it (`.c-insp-r`). roadmap: S-5
@MainActor
final class HexRuledRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        NSColor.token("sep").setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
    }
}

/// One text run: the S tag in the string colour, the text in quotes, its offset on the right (`.c-ol`).
/// roadmap: S-5
@MainActor
final class HexRunCell: NSView {
    init(run: HexTextRun) {
        super.init(frame: .zero)
        let tag = NSTextField(labelWithString: "S")
        tag.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        tag.textColor = .token("on-accent")
        tag.alignment = .center
        tag.wantsLayer = true
        tag.drawsBackground = true
        tag.backgroundColor = .token("syn-str")
        tag.layer?.cornerRadius = 4
        tag.layer?.masksToBounds = true
        let text = NSTextField(labelWithString: "\"\(run.text.prefix(80))\"")
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .token("t1")
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let offset = NSTextField(labelWithString: HexFormat.offset(run.offset))
        offset.font = .systemFont(ofSize: Metric.value("fs-caption"))
        offset.textColor = .token("t3")
        offset.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [tag, text, offset] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            tag.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), tag.centerYAnchor.constraint(equalTo: centerYAnchor),
            tag.widthAnchor.constraint(equalToConstant: 16), tag.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: tag.trailingAnchor, constant: 6), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            offset.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 6),
            offset.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2), offset.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        let place = HexFormat.offset(run.offset)
        setAccessibilityLabel(String(localized: "Text \(run.text) at \(place)", bundle: .previewKit, comment: "Accessibility label of a text run. Arguments: the text, its hex offset."))
    }

    required init?(coder: NSCoder) { nil }
}

/// A 0.5 pt rule in the `sep` token, across or down. roadmap: S-5
@MainActor
final class HexRule: NSView {
    init() { super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("sep").cgColor }
}
