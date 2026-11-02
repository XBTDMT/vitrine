import AppKit
import VitrineUI

/// The trace waterfall (format view F8, option A; design/mockups/formats/decisions.html): one card with a label column
/// (kind mark, name indented by depth, detail, time) and the waterfall on a shared time axis; errors are marked in the
/// danger colours and the selected row opens its facts in place, under the row, so nothing covers the bars. Click or
/// ↑/↓ selects, Esc closes. Rows scroll inside the stage under a fixed axis header and only the visible rows are drawn,
/// so 2,000 spans cost what 15 do. Every colour is a token resolved while drawing, so light and dark follow.
/// roadmap: S-22
@MainActor
final class WaterfallStageView: NSView {
    let rows: [WaterfallRow]
    private let model: WaterfallModel
    private let header: WaterfallHeader
    let canvas: WaterfallCanvas
    let scrollView = NSScrollView()

    /// The row opened in place; the first failed row when the view opens (the one warning worth a look), else none.
    var selectedIndex: Int? {
        get { canvas.selected }
        set { canvas.select(newValue) }
    }

    init(rows: [WaterfallRow]) {
        self.rows = rows
        model = WaterfallModel(rows: rows)
        header = WaterfallHeader(model: model)
        canvas = WaterfallCanvas(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Metric.value("r-card")
        addSubview(header)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = canvas
        addSubview(scrollView)
        canvas.selected = model.firstError
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Waterfall", bundle: .previewKit, comment: "Accessibility name of the trace waterfall view."))
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The card: `card` ground, a hairline ring, the card radius (cards r3-a `.gp`). Drawn, not layer-set, so the
    /// snapshot (cacheDisplay) and the live view look the same.
    override func draw(_ dirtyRect: NSRect) {
        let radius = Metric.value("r-card")
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        NSColor.token("card").setFill()
        path.fill()
        NSColor.token("hair").setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func layout() {
        super.layout()
        let inner = bounds.insetBy(dx: 1, dy: 1)
        let headerHeight = WaterfallHeader.height
        header.frame = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: headerHeight)
        scrollView.frame = NSRect(x: inner.minX, y: inner.minY + headerHeight, width: inner.width,
                                  height: max(0, inner.height - headerHeight))
        let width = scrollView.contentSize.width
        let columns = WaterfallColumns(width: width, detailWidth: model.detailWidth)
        header.columns = columns
        canvas.columns = columns
        canvas.setFrameSize(NSSize(width: width, height: canvas.contentHeight))
    }
}

/// What the waterfall needs from the rows, worked out once: the time span, the unit, each row's kind and the width
/// the detail column wants. Pure, so it can be measured in tests.
struct WaterfallModel {
    enum Kind: Equatable {
        case agent, model, tool, request, other

        var color: String {
            switch self {
            case .agent: "series-5"
            case .model: "series-2"
            case .tool: "series-3"
            case .request: "series-6"
            case .other: "series-1"
            }
        }

        var symbol: String {
            switch self {
            case .agent: "sparkles"
            case .model: "bubble.left.fill"
            case .tool: "wrench.fill"
            case .request: "waveform.path.ecg"
            case .other: "circle.fill"
            }
        }

        /// The kind a span or request name reads as: OpenTelemetry GenAI operation names (`invoke_agent`, `chat`,
        /// `execute_tool` …), HTTP methods for requests (HAR, client spans), anything else plain.
        static func of(_ name: String) -> Kind {
            let lower = name.lowercased()
            let first = lower.split(separator: " ", maxSplits: 1).first.map(String.init) ?? lower
            if first == "invoke_agent" || first == "create_agent" || first == "agent" || lower.hasPrefix("agent ") { return .agent }
            if ["chat", "text_completion", "generate_content", "embeddings", "completion", "llm"].contains(first) { return .model }
            if first == "execute_tool" || first == "tool" || first.hasPrefix("tool.") { return .tool }
            if ["get", "post", "put", "patch", "delete", "head", "options", "connect", "trace"].contains(first)
                || lower.hasPrefix("http") { return .request }
            return .other
        }
    }

    let rows: [WaterfallRow]
    let minStart: Double
    /// Milliseconds from the earliest start to the latest end; never zero.
    let total: Double
    /// A run under a second reads in milliseconds, a longer one in seconds.
    let usesMilliseconds: Bool
    let kinds: [Kind]
    let firstError: Int?
    /// The detail column's width, from the widest detail (sampled); 0 when no row has one.
    let detailWidth: CGFloat

    init(rows: [WaterfallRow]) {
        self.rows = rows
        let starts = rows.map(\.startMs).filter(\.isFinite)
        let start = starts.min() ?? 0
        let end = rows.map { $0.startMs + max(0, $0.durationMs) }.filter(\.isFinite).max() ?? start
        minStart = start
        total = max(end - start, 0.001)
        usesMilliseconds = total < 1000
        kinds = rows.map { Kind.of($0.name) }
        firstError = rows.firstIndex(where: \.isError)
        var widest: CGFloat = 0
        var seen = 0
        let font = tabularFigures(systemFont(Metric.value("fs-callout"), cssWeight: 400))
        for row in rows {
            guard let detail = row.detail, !detail.isEmpty else { continue }
            widest = max(widest, ceil((detail as NSString).size(withAttributes: [.font: font]).width))
            seen += 1
            if seen >= 400 { break }
        }
        detailWidth = widest == 0 ? 0 : min(max(widest, 56), 150)
    }

    /// A duration or an offset in the run's unit: "450 ms", "2.05 s".
    func time(_ ms: Double) -> String {
        usesMilliseconds ? "\(Int(ms.rounded())) ms" : String(format: "%.2f s", ms / 1000)
    }

    /// An axis tick: "0.0 s", "2.1 s", "120 ms".
    func tick(_ ms: Double) -> String {
        usesMilliseconds ? "\(Int(ms.rounded())) ms" : String(format: "%.1f s", ms / 1000)
    }

    /// The input and output token counts in a detail like "3,780 → 220 tokens", for the token split bar; nil when
    /// the detail is not a token count.
    static func tokenSplit(_ detail: String?) -> (input: String, output: String, inValue: Double, outValue: Double)? {
        guard let detail, detail.lowercased().contains("token"), let arrow = detail.range(of: "→") else { return nil }
        func number(_ text: Substring, last: Bool) -> (String, Double)? {
            let words = text.split(separator: " ").filter { $0.first?.isNumber == true }
            guard let word = last ? words.last : words.first else { return nil }
            var raw = String(word).replacingOccurrences(of: ",", with: "")
            var scale = 1.0
            if raw.hasSuffix("K") || raw.hasSuffix("k") { scale = 1000; raw.removeLast() }
            if raw.hasSuffix("M") { scale = 1_000_000; raw.removeLast() }
            guard let value = Double(raw) else { return nil }
            return (String(word), value * scale)
        }
        guard let input = number(detail[..<arrow.lowerBound], last: true),
              let output = number(detail[arrow.upperBound...], last: false),
              input.1 + output.1 > 0 else { return nil }
        return (input.0, output.0, input.1, output.1)
    }
}

/// Where each column sits for a width: name (flexible), detail, time, bars (cue: the mockup's 330 / 70 / 62 / 430).
struct WaterfallColumns: Equatable {
    static let pad: CGFloat = 10, gap: CGFloat = 10, timeWidth: CGFloat = 62

    var nameX: CGFloat = 0, nameWidth: CGFloat = 0
    var detailX: CGFloat = 0, detailWidth: CGFloat = 0
    var timeX: CGFloat = 0
    var barsX: CGFloat = 0, barsWidth: CGFloat = 0

    init() {}

    init(width: CGFloat, detailWidth wanted: CGFloat) {
        let detail = wanted > 0
        let available = max(0, width - 2 * Self.pad - Self.timeWidth - Self.gap * (detail ? 3 : 2) - (detail ? wanted : 0))
        var bars = floor(available * 0.56)
        var name = available - bars
        if name < 120 { name = min(120, available); bars = max(0, available - name) }
        nameX = Self.pad
        nameWidth = name
        detailX = nameX + nameWidth + Self.gap
        detailWidth = detail ? wanted : 0
        timeX = detail ? detailX + detailWidth + Self.gap : detailX
        barsX = timeX + Self.timeWidth + Self.gap
        barsWidth = bars
    }

    /// The x of a fraction of the run on the bars column.
    func x(_ fraction: Double) -> CGFloat { barsX + CGFloat(fraction) * barsWidth }
}

/// The fixed axis header: column names and five time ticks on the `card2` ground (mockup `.wfh`).
@MainActor
final class WaterfallHeader: NSView {
    static let height: CGFloat = 26
    private let model: WaterfallModel
    var columns = WaterfallColumns() { didSet { if columns != oldValue { needsDisplay = true } } }

    init(model: WaterfallModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Metric.value("r-card") - 1
        let ground = NSBezierPath()
        ground.move(to: NSPoint(x: 0, y: bounds.maxY))
        ground.line(to: NSPoint(x: 0, y: radius))
        ground.appendArc(withCenter: NSPoint(x: radius, y: radius), radius: radius, startAngle: 180, endAngle: 270)
        ground.line(to: NSPoint(x: bounds.maxX - radius, y: 0))
        ground.appendArc(withCenter: NSPoint(x: bounds.maxX - radius, y: radius), radius: radius, startAngle: 270, endAngle: 360)
        ground.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY))
        ground.close()
        NSColor.token("card2").setFill()
        ground.fill()
        NSColor.token("sep").setFill()
        NSRect(x: 0, y: bounds.maxY - 0.5, width: bounds.width, height: 0.5).fill()

        let label: [NSAttributedString.Key: Any] = [.font: systemFont(11, cssWeight: 600), .foregroundColor: NSColor.token("t2")]
        let lineY = (bounds.height - 14) / 2
        drawText(String(localized: "Name", bundle: .previewKit, comment: "Waterfall column: the span or request name."), attributes: label,
                 in: NSRect(x: columns.nameX, y: lineY, width: columns.nameWidth, height: 14), alignment: .left)
        if columns.detailWidth > 0 {
            drawText(String(localized: "Detail", bundle: .previewKit, comment: "Waterfall column: tokens, status or size of a span."),
                     attributes: label, in: NSRect(x: columns.detailX, y: lineY, width: columns.detailWidth, height: 14), alignment: .right)
        }
        drawText(String(localized: "Time", bundle: .previewKit, comment: "Waterfall column: how long a span took."), attributes: label,
                 in: NSRect(x: columns.timeX, y: lineY, width: WaterfallColumns.timeWidth, height: 14), alignment: .right)

        guard columns.barsWidth > 40 else { return }
        let tick: [NSAttributedString.Key: Any] = [.font: tabularFigures(systemFont(10, cssWeight: 400)), .foregroundColor: NSColor.token("t3")]
        for step in 0...4 {
            let fraction = Double(step) / 4
            let text = model.tick(fraction * model.total)
            let x = columns.x(fraction)
            let rect = step == 4 ? NSRect(x: x - 62, y: lineY + 1, width: 60, height: 13) : NSRect(x: x, y: lineY + 1, width: 60, height: 13)
            drawText(text, attributes: tick, in: rect, alignment: step == 4 ? .right : .left)
        }
    }
}

/// The scrolling rows. Row `i` sits at `i × 30`, plus the opened detail's height for rows under the selected one, so
/// both the row under a point and the rows inside a rectangle are found by arithmetic, never by walking every row.
@MainActor
final class WaterfallCanvas: NSView {
    static let rowHeight: CGFloat = 30
    private let model: WaterfallModel
    var columns = WaterfallColumns() { didSet { if columns != oldValue { needsDisplay = true } } }
    var selected: Int? {
        didSet { if selected != oldValue { needsDisplay = true } }
    }
    private var symbols: [String: NSImage] = [:]
    private let nameFont = systemFont(Metric.value("fs-callout"), cssWeight: 400)
    private let numberFont = tabularFigures(systemFont(Metric.value("fs-callout"), cssWeight: 400))
    private let detailFont = tabularFigures(systemFont(Metric.value("fs-control"), cssWeight: 400))
    private let detailBold = systemFont(Metric.value("fs-control"), cssWeight: 600)

    init(model: WaterfallModel) {
        self.model = model
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    /// The opened detail's height: the full name, the timing line, the detail or token line and its split bar.
    var detailHeight: CGFloat {
        guard let selected, model.rows.indices.contains(selected) else { return 0 }
        let row = model.rows[selected]
        var height: CGFloat = 8 + 17 + 3 + 17 + 10
        if row.detail?.isEmpty == false { height += 20 }
        if WaterfallModel.tokenSplit(row.detail) != nil { height += 14 }
        return height
    }

    var contentHeight: CGFloat { CGFloat(model.rows.count) * Self.rowHeight + detailHeight }

    /// The top of row `i`.
    func top(of index: Int) -> CGFloat {
        CGFloat(index) * Self.rowHeight + ((selected.map { index > $0 } ?? false) ? detailHeight : 0)
    }

    /// The row at a y, and whether the y falls in its opened detail; nil past the last row.
    func row(atY y: CGFloat) -> (index: Int, inDetail: Bool)? {
        guard !model.rows.isEmpty, y >= 0 else { return nil }
        if let selected {
            let detailTop = CGFloat(selected + 1) * Self.rowHeight
            if y >= detailTop && y < detailTop + detailHeight { return (selected, true) }
            if y >= detailTop + detailHeight {
                let index = Int((y - detailHeight) / Self.rowHeight)
                return index < model.rows.count ? (index, false) : nil
            }
        }
        let index = Int(y / Self.rowHeight)
        return index < model.rows.count ? (index, false) : nil
    }

    /// Opens a row in place (nil closes) and keeps it in sight.
    func select(_ index: Int?) {
        let index = index.flatMap { model.rows.indices.contains($0) ? $0 : nil }
        selected = index
        setFrameSize(NSSize(width: frame.width, height: contentHeight))
        if let index {
            scrollToVisible(NSRect(x: 0, y: top(of: index), width: 1, height: Self.rowHeight + detailHeight))
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = row(atY: point.y) else { return }
        if hit.inDetail { return }
        select(hit.index == selected ? nil : hit.index)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: select(min(model.rows.count - 1, (selected ?? -1) + 1))
        case 126: select(max(0, (selected ?? model.rows.count) - 1))
        case 53: select(nil)
        default: super.keyDown(with: event)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !model.rows.isEmpty else { return }
        let first = row(atY: max(0, dirtyRect.minY))?.index ?? model.rows.count
        let last = row(atY: min(contentHeight - 0.5, dirtyRect.maxY))?.index ?? model.rows.count - 1
        guard first <= last else { return }
        for index in first...last { drawRow(index) }
        if let selected, selected >= first, selected <= last { drawDetail(selected) }
    }

    private func symbol(_ name: String) -> NSImage? {
        if let image = symbols[name] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        symbols[name] = image
        return image
    }

    private func drawRow(_ index: Int) {
        let row = model.rows[index]
        let kind = model.kinds[index]
        let y = top(of: index)
        let rect = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
        // A failed row keeps its danger tint when selected; the selection then shows as the opened detail and an
        // edge bar, so the warning never turns into the selection colour.
        if row.isError {
            NSColor.token("danger-soft").setFill(); rect.fill(using: .sourceOver)
        } else if index == selected {
            NSColor.token("sel").setFill(); rect.fill(using: .sourceOver)
        }
        if index == selected {
            NSColor.token(row.isError ? "danger" : "accent").setFill()
            NSRect(x: 0, y: y, width: 3, height: Self.rowHeight + detailHeight).fill()
        }
        NSColor.token("sep").setFill()
        if index > 0 { NSRect(x: 0, y: y, width: bounds.width, height: 0.5).fill(using: .sourceOver) }
        if columns.barsWidth > 0 {
            for step in 0...4 {
                NSRect(x: columns.x(Double(step) / 4) - (step == 4 ? 0.5 : 0), y: y, width: 0.5, height: Self.rowHeight).fill(using: .sourceOver)
            }
        }

        // Label column: kind mark, the name indented by depth.
        let indent = min(CGFloat(max(0, row.depth)), 12) * 16
        let dotX = columns.nameX + min(indent, max(0, columns.nameWidth - 60))
        let dot = NSRect(x: dotX, y: y + 6, width: 18, height: 18)
        NSColor.token(kind.color).setFill()
        NSBezierPath(roundedRect: dot, xRadius: 5, yRadius: 5).fill()
        if let image = symbol(kind.symbol) {
            let size = image.size
            image.draw(in: NSRect(x: dot.midX - size.width / 2, y: dot.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let textX = dot.maxX + 6
        drawText(row.name, attributes: [.font: nameFont, .foregroundColor: NSColor.token(row.isError ? "danger-text" : "t1")],
                 in: NSRect(x: textX, y: y + 7, width: max(0, columns.nameX + columns.nameWidth - textX), height: 17), alignment: .left)

        if columns.detailWidth > 0 {
            let has = row.detail?.isEmpty == false
            drawText(has ? row.detail! : "—", attributes: [.font: numberFont, .foregroundColor: NSColor.token(has ? "t1" : "t2")],
                     in: NSRect(x: columns.detailX, y: y + 7, width: columns.detailWidth, height: 17), alignment: .right)
        }
        drawText(model.time(max(0, row.durationMs)), attributes: [.font: numberFont, .foregroundColor: NSColor.token("t2")],
                 in: NSRect(x: columns.timeX, y: y + 7, width: WaterfallColumns.timeWidth, height: 17), alignment: .right)

        // The bar on the shared axis.
        guard columns.barsWidth > 0, row.startMs.isFinite, row.durationMs.isFinite else { return }
        let start = max(0, min(1, (row.startMs - model.minStart) / model.total))
        let end = max(start, min(1, (row.startMs - model.minStart + max(0, row.durationMs)) / model.total))
        var bar = NSRect(x: columns.x(start), y: y + 9, width: max(2, CGFloat(end - start) * columns.barsWidth), height: 12)
        bar.size.width = min(bar.width, columns.barsX + columns.barsWidth - bar.minX)
        NSColor.token(row.isError ? "danger" : kind.color).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
    }

    /// The selected row opened in place (mockup `.wfdet`): its full name, when it ran, how long, its status, and the
    /// detail, split into input and output tokens with a bar when the detail is a token count.
    private func drawDetail(_ index: Int) {
        let row = model.rows[index]
        let top = CGFloat(index + 1) * Self.rowHeight
        let rect = NSRect(x: 0, y: top, width: bounds.width, height: detailHeight)
        NSColor.token(row.isError ? "danger-soft" : "sel").setFill(); rect.fill(using: .sourceOver)
        NSColor.token("sep").setFill(); NSRect(x: 0, y: top, width: bounds.width, height: 0.5).fill(using: .sourceOver)
        NSColor.token(row.isError ? "danger" : "accent").setFill(); NSRect(x: 0, y: top, width: 3, height: detailHeight).fill()

        let left = columns.nameX + 38
        let width = max(0, bounds.width - left - WaterfallColumns.pad)
        var y = top + 8
        drawText(row.name, attributes: [.font: detailBold, .foregroundColor: NSColor.token(row.isError ? "danger-text" : "t1")],
                 in: NSRect(x: left, y: y, width: width, height: 17), alignment: .left)
        y += 20

        let failed = String(localized: "Failed", bundle: .previewKit, comment: "Waterfall detail: the span ended in an error.")
        let ok = String(localized: "OK", bundle: .previewKit, comment: "Waterfall detail: the span ended without an error.")
        let start = row.startMs - model.minStart
        drawPairs([
            (String(localized: "Starts", bundle: .previewKit, comment: "Waterfall detail: when the span started, from the run's start."), model.time(start), "t1", false),
            (String(localized: "Duration", bundle: .previewKit, comment: "Waterfall detail: how long the span took."), model.time(max(0, row.durationMs)), "t1", false),
            (String(localized: "Ends", bundle: .previewKit, comment: "Waterfall detail: when the span ended, from the run's start."),
             model.time(start + max(0, row.durationMs)), "t1", false),
            (String(localized: "Status", bundle: .previewKit, comment: "Waterfall detail: whether the span failed."),
             row.isError ? failed : ok, row.isError ? "danger-text" : "t1", row.isError),
        ], x: left, y: y, maxX: left + width)
        y += 20

        guard let detail = row.detail, !detail.isEmpty else { return }
        if let split = WaterfallModel.tokenSplit(detail) {
            drawPairs([
                (String(localized: "Input", bundle: .previewKit, comment: "Waterfall detail: tokens sent to the model."),
                 String(localized: "\(split.input) tokens", bundle: .previewKit, comment: "Waterfall detail: a token count."), "t1", false),
                (String(localized: "Output", bundle: .previewKit, comment: "Waterfall detail: tokens the model wrote."),
                 String(localized: "\(split.output) tokens", bundle: .previewKit, comment: "Waterfall detail: a token count."), "t1", false),
            ], x: left, y: y, maxX: left + width)
            let barWidth = min(420, width)
            let inWidth = round(barWidth * CGFloat(split.inValue / (split.inValue + split.outValue)))
            let barY = y + 22
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: left, y: barY, width: barWidth, height: 6), xRadius: 3, yRadius: 3).addClip()
            NSColor.token("series-2").setFill(); NSRect(x: left, y: barY, width: inWidth, height: 6).fill()
            NSColor.token("series-1").setFill(); NSRect(x: left + inWidth, y: barY, width: barWidth - inWidth, height: 6).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            drawPairs([(String(localized: "Detail", bundle: .previewKit, comment: "Waterfall column: tokens, status or size of a span."), detail, "t1", false)],
                      x: left, y: y, maxX: left + width)
        }
    }

    /// Key-value pairs on one line (mockup `.kv`): the key in `t2`, the value after it, 16 pt between pairs.
    private func drawPairs(_ pairs: [(key: String, value: String, color: String, bold: Bool)], x: CGFloat, y: CGFloat, maxX: CGFloat) {
        var cursor = x
        for pair in pairs where cursor < maxX {
            let key = NSAttributedString(string: pair.key, attributes: [.font: detailFont, .foregroundColor: NSColor.token("t2")])
            let keyWidth = ceil(key.size().width)
            drawText(pair.key, attributes: [.font: detailFont, .foregroundColor: NSColor.token("t2")],
                     in: NSRect(x: cursor, y: y, width: min(keyWidth, maxX - cursor), height: 17), alignment: .left)
            cursor += keyWidth + 6
            let attributes: [NSAttributedString.Key: Any] = [.font: pair.bold ? detailBold : detailFont, .foregroundColor: NSColor.token(pair.color)]
            let valueWidth = ceil((pair.value as NSString).size(withAttributes: attributes).width)
            guard cursor < maxX else { break }
            drawText(pair.value, attributes: attributes, in: NSRect(x: cursor, y: y, width: min(valueWidth, maxX - cursor), height: 17), alignment: .left)
            cursor += valueWidth + 16
        }
    }
}

/// One line of text in a rectangle, truncated at the tail.
@MainActor
func drawText(_ text: String, attributes: [NSAttributedString.Key: Any], in rect: NSRect, alignment: NSTextAlignment) {
    guard rect.width > 1 else { return }
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    style.alignment = alignment
    var all = attributes
    all[.paragraphStyle] = style
    (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: all)
}
