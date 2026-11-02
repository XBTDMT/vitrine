import AppKit
import VitrineDocument
import VitrineUI

/// The 260 pt Inspector (data 3): a small File / Column / Row segmented control on `card2`, then label/value rows.
/// File lists the facts, Column the selected column's profile, Row the selected row's fields. roadmap: S-6
@MainActor
final class DataInspector: NSView {
    enum Tab: Int { case file, column, row }

    let tabs: NSSegmentedControl
    private let stack = NSStackView()
    private let model: any TabularModel
    private(set) var tab: Tab = .file
    private(set) var column = 0
    private(set) var row = 0
    /// What the current tab shows, as label and value (tests read it).
    private(set) var entries: [DataEntry] = []
    /// The File tab's drawn sections as last drawn (tests read them).
    private(set) var sections: [DataFileSection] = []
    /// A text table's token count (CSV, TSV; A-4): the File tab ends with the context-fit meter. nil for databases and
    /// column files, which are not text.
    var tokens: TokenCount? {
        didSet { if tokens != oldValue, tab == .file { refresh() } }
    }
    /// The meter as last drawn (tests read it).
    private(set) var tokenMeter: TokenMeterView?
    /// A row-group segment was clicked: the shown row to scroll to.
    var onJump: ((Int) -> Void)?
    /// The shown row at the top of the grid; the File tab redraws when it moves into another row group.
    var visibleRow = 0 {
        didSet {
            guard tab == .file, !isHidden, model.chunk(ofShownRow: visibleRow) != model.chunk(ofShownRow: oldValue) else { return }
            refresh()
        }
    }

    init(model: any TabularModel) {
        self.model = model
        tabs = NSSegmentedControl(labels: [model.fileTabTitle,
                                           String(localized: "Column", bundle: .previewKit, comment: "Inspector tab: the selected column's profile."),
                                           String(localized: "Row", bundle: .previewKit, comment: "Inspector tab: the selected row's fields.")],
                                  trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        let bar = TabBar()
        tabs.controlSize = .small
        tabs.segmentDistribution = .fillEqually
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        let content = NSScrollView()
        let flipped = FlippedView()
        flipped.addSubview(stack)
        content.documentView = flipped
        content.drawsBackground = false
        content.hasVerticalScroller = true
        content.autohidesScrollers = true
        let line = SepLine()
        for v in [bar, tabs, content, stack, flipped, line] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(bar); bar.addSubview(tabs); addSubview(content); addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor), line.heightAnchor.constraint(equalToConstant: 0.5),
            bar.topAnchor.constraint(equalTo: topAnchor), bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabs.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10), tabs.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            tabs.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8), bar.bottomAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            content.topAnchor.constraint(equalTo: bar.bottomAnchor), content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
            flipped.topAnchor.constraint(equalTo: content.contentView.topAnchor),
            flipped.leadingAnchor.constraint(equalTo: content.contentView.leadingAnchor),
            flipped.widthAnchor.constraint(equalTo: content.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor, constant: -12),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func tabChanged() { tab = Tab(rawValue: tabs.selectedSegment) ?? .file; refresh() }

    func show(_ selection: DataSelection) {
        switch selection {
        case .file: tab = .file
        case .column(let c): tab = .column; column = c
        case .row(let r): tab = .row; row = r
        }
        tabs.selectedSegment = tab.rawValue
        refresh()
    }

    func refresh() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        var note: String?
        switch tab {
        case .file:
            entries = model.fileEntries()
            if model.parts.isEmpty {
                if let caption = model.fileCaption {
                    // Parquet / Arrow (A-7): where these facts come from, in place of the heading.
                    let label = NSTextField(labelWithString: caption)
                    label.font = .systemFont(ofSize: Metric.value("fs-micro"))
                    label.textColor = NSColor.token("t3")
                    stack.addArrangedSubview(label)
                } else {
                    stack.addArrangedSubview(Self.heading(String(localized: "This file", bundle: .previewKit, comment: "Inspector heading over the file's facts."), detail: nil))
                }
            } else {
                // Database (data r3-a): the tables and views, each with its row count; a click shows its rows.
                stack.addArrangedSubview(Self.heading(model.partsHeading, detail: nil))
                stack.setCustomSpacing(6, after: stack.arrangedSubviews[0])
                for (i, part) in model.parts.enumerated() {
                    let row = PartRow(part: part) { [weak self] in self?.model.selectPart(i) }
                    stack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
                stack.setCustomSpacing(14, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
                stack.addArrangedSubview(Self.heading(String(localized: "File", bundle: .previewKit, comment: "Inspector heading over the database file's facts, below its tables."), detail: nil))
            }
        case .column:
            entries = model.columnEntries(column)
            stack.addArrangedSubview(Self.heading(model.title(column), detail: entries.first?.value, tag: model.typeTag(column)))
            note = model.profileNote
        case .row:
            entries = model.rowEntries(row)
            // The record view (I-4): one field per line, each with its column's type tag.
            let number = model.rowNumber(row).formatted(), total = model.rowCount.formatted()
            stack.addArrangedSubview(Self.heading(String(localized: "Row \(number) of \(total)", bundle: .previewKit, comment: "Inspector heading for the selected row. Arguments: its row number, the row count."), detail: nil))
        }
        stack.setCustomSpacing(8, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
        let chart = tab == .column ? model.columnChart(column) : nil
        if let chart {
            if !chart.histogram.isEmpty { add(DataProfileViews.histogram(chart), spacing: 7) }
            add(DataProfileViews.quality(chart), spacing: 10)
        }
        // With the chart drawn, its legend already says how many values fit, don't, and are empty (the design lists
        // only Distinct, Min, Max, Mean and Median under it); `entries` keeps every line for describe and tests.
        // The labels as the models write them (translated), so the match holds in every language.
        let redundant: Set<String> = chart == nil ? [] : [
            String(localized: "Values", bundle: .previewKit, comment: "Column fact label: number of non-empty values profiled."),
            String(localized: "Empty", bundle: .previewKit, comment: "Column fact label: number of empty values profiled."),
            String(localized: "Don't fit", bundle: .previewKit, comment: "Column fact label: number of values that do not fit the column's type."),
            "NULL",
        ]
        let shown = (tab == .column ? Array(entries.dropFirst()) : entries).filter { !redundant.contains($0.label) }
        for (i, entry) in shown.enumerated() {
            let line = Self.line(entry, numeric: tab != .row, tag: tab == .row ? model.typeTag(i) : nil)
            stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let chart {
            if let text = chart.note {
                stack.setCustomSpacing(10, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
                add(DataProfileViews.note(text), spacing: 12)
            }
            let tops = DataProfileViews.topValues(chart)
            if let first = tops.first {
                stack.setCustomSpacing(12, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
                stack.addArrangedSubview(first)
                stack.setCustomSpacing(6, after: first)
                for row in tops.dropFirst() {
                    stack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
            }
        }
        sections = tab == .file ? model.fileSections(visibleRow: visibleRow) : []
        for section in sections { addSection(section) }
        if tab == .file, let tokens {
            // A-4: the context-fit meter under the file's facts, the same section Details draws.
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }
            let meter = TokenMeterView(meter: TokenMeter(tokens))
            stack.addArrangedSubview(meter)
            meter.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            tokenMeter = meter
        } else {
            tokenMeter = nil
        }
        if let note, !note.isEmpty {
            let label = NSTextField(labelWithString: note)
            label.font = .systemFont(ofSize: Metric.value("fs-micro"))
            label.textColor = NSColor.token("t2")
            stack.setCustomSpacing(10, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
            stack.addArrangedSubview(label)
        }
    }

    /// A File-tab section (A-7): the "Row groups · 19" strip and its caption, or "Columns · min → max" lines.
    private func addSection(_ section: DataFileSection) {
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }
        switch section {
        case .strip(let title, let count, let selected, let caption):
            add(DataProfileViews.label(title, size: Metric.value("fs-caption"), token: "t2", weight: .semibold), spacing: 6)
            let strip = ChunkStrip(count: count, selected: selected) { [weak self] k in
                guard let self, let row = self.model.firstShownRow(ofChunk: k) else { return }
                self.onJump?(row)
            }
            strip.translatesAutoresizingMaskIntoConstraints = false
            strip.heightAnchor.constraint(equalToConstant: 24).isActive = true
            add(strip, spacing: 4)
            add(DataProfileViews.label(caption, size: Metric.value("fs-micro"), token: "t2"), spacing: 4)
        case .entries(let title, let lines):
            add(DataProfileViews.label(title, size: Metric.value("fs-caption"), token: "t2", weight: .semibold), spacing: 6)
            for line in lines {
                let row = Self.line((line.label, line.value), numeric: true)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    /// Adds a full-width part and the space after it.
    private func add(_ view: NSView, spacing: CGFloat) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(spacing, after: view)
    }

    private static func heading(_ title: String, detail: String?, tag: String? = nil) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = NSColor.token("t1")
        name.lineBreakMode = .byTruncatingTail
        guard let detail else { return name }
        let type = NSTextField(labelWithString: detail)
        type.font = .systemFont(ofSize: 11.5)
        type.textColor = NSColor.token("t3")
        let row = NSStackView(views: (tag.map { [TagView(tag: $0)] } ?? []) + [name, NSView(), type])
        row.orientation = .horizontal
        row.spacing = 6
        row.distribution = .fill
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    /// "Distinct        9": the label in t2 on the left, the value in t1 on the right (tabular digits).
    private static func line(_ entry: DataEntry, numeric: Bool, tag: String? = nil) -> NSView {
        let label = NSTextField(labelWithString: entry.label)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = NSColor.token("t2")
        label.lineBreakMode = .byTruncatingTail
        let value = NSTextField(labelWithString: entry.value.isEmpty ? "—" : entry.value)
        value.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        value.textColor = NSColor.token(entry.value.isEmpty ? "t3" : "t1")
        value.alignment = .right
        value.lineBreakMode = .byTruncatingMiddle
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: (tag.map { [TagView(tag: $0)] } ?? []) + [label, value])
        row.orientation = .horizontal
        row.spacing = 12
        if tag != nil { row.setCustomSpacing(6, after: row.arrangedSubviews[0]) }
        row.distribution = .fill
        return row
    }

    // Canvas → win (data 11): the inspector sits on the window token, the rows on the page token.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("win").cgColor }
}

/// The tab strip: `card2` with a `sep` line under it (data 3).
final class TabBar: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("card2").cgColor }
    override func draw(_ dirtyRect: NSRect) {}
}

/// A 0.5 pt horizontal line in the `sep` token.
final class SepLine: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("sep").cgColor }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One table or view on the Database tab: its name, its row count (or "view") on the right in tabular digits, the
/// picked one on `sel`. A click picks it.
final class PartRow: NSView {
    private let action: () -> Void
    private let isSelected: Bool

    init(part: DataPart, action: @escaping () -> Void) {
        self.action = action
        isSelected = part.isSelected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        let name = NSTextField(labelWithString: part.name)
        name.font = .systemFont(ofSize: 12, weight: part.isSelected ? .semibold : .regular)
        name.textColor = NSColor.token("t1")
        name.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: part.detail)
        detail.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        detail.textColor = NSColor.token("t2")
        detail.alignment = .right
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        for v in [name, detail] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(part.name), \(part.detail)")
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = isSelected ? NSColor.token("sel").cgColor : NSColor.clear.cgColor }
}

/// A header type tag outside the table header (the Column heading, the record view): the same box `DataHeaderCell` draws.
final class TagView: NSView {
    let typeTag: String
    init(tag: String) {
        self.typeTag = tag
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: DataHeaderCell.tagWidth(tag)), heightAnchor.constraint(equalToConstant: 15)])
        // "date" is drawn as a calendar; the other tags are read as they are drawn.
        setAccessibilityLabel(tag == "date" ? String(localized: "date", bundle: .previewKit, comment: "Accessibility label of a column's type tag: the column holds dates.") : tag)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let cell = DataHeaderCell(title: "", quality: nil, alignment: .left)
        cell.typeTag = typeTag
        cell.drawTag(in: bounds)
    }
}

/// The row-group strip (data design "Parquet / Arrow, footer first"): one rounded segment per group in `series-1`
/// at 42 % fill, the group in view at full strength and the rest at 35 %; a click leads to that group's first row.
/// Past 64 groups the segments become hairlines of the same width share. roadmap: S-21
final class ChunkStrip: NSView {
    let count: Int
    let selected: Int
    private let action: (Int) -> Void

    init(count: Int, selected: Int, action: @escaping (Int) -> Void) {
        self.count = count
        self.selected = selected
        self.action = action
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        let groups = count.formatted(), shown = (selected + 1).formatted()
        setAccessibilityLabel(String(localized: "\(groups) row groups, showing \(shown)", bundle: .previewKit, comment: "Accessibility label of the row-group strip. Arguments: number of groups, the group on screen."))
    }

    required init?(coder: NSCoder) { nil }

    private var segmentWidth: CGFloat { count > 0 ? bounds.width / CGFloat(count) : 0 }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }
        let gap: CGFloat = count > 64 ? 0 : 2
        let colour = NSColor.token("series-1")
        for k in 0..<count {
            let rect = NSRect(x: CGFloat(k) * segmentWidth + 0.5, y: 2, width: max(1, segmentWidth - gap), height: bounds.height - 4)
            colour.withAlphaComponent(0.42 * (k == selected ? 1 : 0.35)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: count > 64 ? 0 : 2, yRadius: count > 64 ? 0 : 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard segmentWidth > 0 else { return }
        action(min(count - 1, max(0, Int(x / segmentWidth))))
    }
}
