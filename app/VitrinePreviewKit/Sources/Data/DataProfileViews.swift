import AppKit
import VitrineUI

/// The Column tab's drawn parts (I-5, data column profile): the histogram with its low and high values, the quality
/// bar with its legend, the caution note quoting values that don't fit, and the top values with bars. Sizes and
/// colours follow `design/mockups/unified/data.html` (`.d-qb`, `.d-cbar`, `.d-ctr`, `.slab`). roadmap: S-6
@MainActor
enum DataProfileViews {
    /// 46 pt of bars in `series-1`, 1 pt corners, an 1.2 pt gap; the low and high values under it in t3.
    static func histogram(_ chart: DataColumnChart) -> NSView {
        let bars = HistogramView(counts: chart.histogram)
        bars.translatesAutoresizingMaskIntoConstraints = false
        bars.heightAnchor.constraint(equalToConstant: 46).isActive = true
        let low = label(chart.low, size: 10.5, token: "t3")
        let high = label(chart.high, size: 10.5, token: "t3")
        let range = NSStackView(views: [low, NSView(), high])
        range.orientation = .horizontal
        let stack = NSStackView(views: [bars, range])
        stack.orientation = .vertical
        stack.spacing = 3
        stack.alignment = .leading
        for v in [bars, range] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    /// The 3 pt bar (valid in `fill2`, don't-fit in `caution`, empty dashed in t3) and its legend.
    static func quality(_ chart: DataColumnChart) -> NSView {
        let bar = QualityBar(valid: chart.valid, misfit: chart.misfit, empty: chart.empty)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 3).isActive = true
        let valid = chart.valid.formatted(), empty = chart.empty.formatted()
        var items: [NSView] = [legend(String(localized: "\(valid) valid", bundle: .previewKit, comment: "Chart legend: how many values fit the column's type."), swatch: "fill2", text: "t2")]
        if chart.misfit > 0 { items.append(legend(chart.misfitKind.legend(chart.misfit), swatch: "caution", text: "caution-text")) }
        if chart.empty > 0 {
            items.append(legend(String(localized: "\(empty) empty", bundle: .previewKit, comment: "Chart legend: how many values are empty."), swatch: "t3", text: "t2"))
        }
        let row = NSStackView(views: items)
        row.orientation = .horizontal
        row.spacing = 10
        let stack = NSStackView(views: [bar, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// The caution note: 11 pt caution text on `caution-soft`, 7 pt corners.
    static func note(_ text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = NSColor.token("caution-text")
        field.translatesAutoresizingMaskIntoConstraints = false
        let box = TokenBox(fill: "caution-soft", radius: 7)
        box.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: box.topAnchor, constant: 6), field.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
        ])
        return box
    }

    /// "Top values", then one 18 pt row per value: the value (64 pt), a 6 pt track with the share in `series-1`, the count.
    static func topValues(_ chart: DataColumnChart) -> [NSView] {
        guard !chart.top.isEmpty else { return [] }
        let heading = label(String(localized: "Top values", bundle: .previewKit, comment: "Inspector heading over a column's most common values."), size: Metric.value("fs-caption"), token: "t2", weight: .semibold)
        let total = max(chart.topTotal, chart.top.map(\.count).max() ?? 1, 1)
        return [heading] + chart.top.prefix(5).map { top in
            let name = label(top.value.isEmpty ? String(localized: "(empty)", bundle: .previewKit, comment: "Stands for an empty value in the list of most common values.") : top.value, size: Metric.value("fs-sub"), token: "t1")
            name.lineBreakMode = .byTruncatingTail
            name.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let track = ShareTrack(share: Double(top.count) / Double(total))
            track.translatesAutoresizingMaskIntoConstraints = false
            track.heightAnchor.constraint(equalToConstant: 6).isActive = true
            let count = label(top.count.formatted(), size: Metric.value("fs-sub"), token: "t2", mono: true)
            count.alignment = .right
            count.widthAnchor.constraint(equalToConstant: 52).isActive = true
            let row = NSStackView(views: [name, track, count])
            row.orientation = .horizontal
            row.spacing = 8
            row.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return row
        }
    }

    static func label(_ text: String, size: CGFloat, token: String, weight: NSFont.Weight = .regular, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = NSColor.token(token)
        return field
    }

    private static func legend(_ text: String, swatch: String, text token: String) -> NSView {
        let dot = TokenBox(fill: swatch, radius: 2)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7)])
        let row = NSStackView(views: [dot, label(text, size: 11, token: token)])
        row.orientation = .horizontal
        row.spacing = 4
        return row
    }
}

final class HistogramView: NSView {
    let counts: [Int]
    init(counts: [Int]) { self.counts = counts; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let top = counts.max(), top > 0 else { return }
        let gap: CGFloat = 1.2
        let w = (bounds.width - gap * CGFloat(counts.count - 1)) / CGFloat(counts.count)
        NSColor.token("series-1").setFill()
        for (i, n) in counts.enumerated() {
            // A bin with any value shows at least a sliver, as the design's 0.8 pt bars do.
            let h = n == 0 ? 0 : max(0.8, bounds.height * CGFloat(n) / CGFloat(top))
            NSBezierPath(roundedRect: NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: h), xRadius: 1, yRadius: 1).fill()
        }
    }
}

final class QualityBar: NSView {
    let valid: Int, misfit: Int, empty: Int
    init(valid: Int, misfit: Int, empty: Int) {
        self.valid = valid; self.misfit = misfit; self.empty = empty
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let total = CGFloat(max(valid + misfit + empty, 1))
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).addClip()
        var x: CGFloat = 0
        for (n, token) in [(valid, "fill2"), (misfit, "caution")] where n > 0 {
            let w = bounds.width * CGFloat(n) / total
            NSColor.token(token).setFill()
            NSRect(x: x, y: 0, width: w, height: bounds.height).fill()
            x += w
        }
        // Empty values: 2 pt dashes in t3 (`.d-qn`).
        NSColor.token("t3").setFill()
        var dash = x
        while dash < bounds.width, empty > 0 {
            NSRect(x: dash, y: 0, width: min(2, bounds.width - dash), height: bounds.height).fill()
            dash += 4
        }
    }
}

final class ShareTrack: NSView {
    let share: Double
    init(share: Double) { self.share = share; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.token("fill").setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        NSColor.token("series-1").withAlphaComponent(0.85).setFill()
        let w = max(bounds.height, bounds.width * CGFloat(min(max(share, 0), 1)))
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: 3, yRadius: 3).fill()
    }
}
