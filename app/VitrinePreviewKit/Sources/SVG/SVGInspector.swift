import AppKit
import VitrineDocument
import VitrineUI

/// The SVG Inspector (data design "SVG preview", 260 pt on `card2` with a `sep` line at its left): the facts as
/// label/value rows (viewBox, size, elements, scripts, external refs, and foreignObject and entities when present),
/// then "Background" with Checker · Light · Dark when there is a picture, then one row per warning with its level's
/// colour. roadmap: S-6
@MainActor
final class SVGInspector: NSView {
    private let stack = NSStackView()
    let backgroundControl: NSSegmentedControl
    private(set) var background: SVGBackground
    var onBackground: ((SVGBackground) -> Void)?
    /// The rows as label and value (tests read them).
    private(set) var rows: [(label: String, value: String)] = []
    private(set) var warningTitles: [String] = []

    /// Facts shown here; the pill's headline and the line count are left to the capsule's tooltip.
    static let shownFacts = ["viewBox", "declaredSize", "size", "elements", "scripts", "externalRefs", "foreignObjects", "entities"]

    static var backgroundWord: String {
        String(localized: "Background", bundle: .previewKit, comment: "SVG Inspector heading: what the picture sits on.")
    }

    init(document: PreviewDocument, background: SVGBackground, hasPicture: Bool) {
        self.background = background
        backgroundControl = NSSegmentedControl(labels: SVGBackground.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        backgroundControl.controlSize = .small
        backgroundControl.segmentDistribution = .fillEqually
        backgroundControl.selectedSegment = background.rawValue
        backgroundControl.target = self
        backgroundControl.action = #selector(backgroundChanged)
        backgroundControl.setAccessibilityLabel(Self.backgroundWord)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        let scroll = NSScrollView()
        let flipped = SVGFlippedView()
        flipped.addSubview(stack)
        scroll.documentView = flipped
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let line = SVGSepLine()
        for v in [scroll, flipped, stack, line] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(scroll); addSubview(line)
        let padX = Metric.value("sp-14"), padY = Metric.value("sp-12")
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor), line.widthAnchor.constraint(equalToConstant: 0.5),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: line.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            flipped.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            flipped.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor, constant: padY),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: padX),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor, constant: -padX),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor, constant: -padY),
        ])
        update(document: document, hasPicture: hasPicture)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func backgroundChanged() {
        background = SVGBackground(rawValue: backgroundControl.selectedSegment) ?? .checker
        onBackground?(background)
    }

    /// Picks a background as a click would (tests).
    func select(_ background: SVGBackground) {
        backgroundControl.selectedSegment = background.rawValue
        backgroundChanged()
    }

    func update(document: PreviewDocument, hasPicture: Bool) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        rows = []
        for key in Self.shownFacts {
            guard let fact = document.fact(key) else { continue }
            let level = Self.level(of: fact, in: document)
            let row = Self.row(fact.label, fact.value, valueToken: level.map(Self.textToken) ?? "t1")
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append((fact.label, fact.value))
        }
        if hasPicture {
            stack.setCustomSpacing(Metric.value("sp-14"), after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
            stack.addArrangedSubview(Self.heading(Self.backgroundWord))
            stack.setCustomSpacing(Metric.value("sp-6"), after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
            stack.addArrangedSubview(backgroundControl)
            backgroundControl.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let badges = document.badges.sorted { $0.level > $1.level }
        warningTitles = badges.map(\.title)
        if !badges.isEmpty, let last = stack.arrangedSubviews.last {
            stack.setCustomSpacing(Metric.value("sp-16"), after: last)
            stack.addArrangedSubview(Self.heading(String(localized: "Warnings", bundle: .previewKit, comment: "SVG Inspector heading: the warnings list.")))
            stack.setCustomSpacing(Metric.value("sp-6"), after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
            for badge in badges {
                let row = SVGWarningRow(badge)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                stack.setCustomSpacing(Metric.value("sp-8"), after: row)
            }
        }
    }

    /// Scripts in the danger colour, external refs in the caution colour, when there are any.
    private static func level(of fact: Fact, in document: PreviewDocument) -> Badge.Level? {
        guard fact.value != "0" else { return nil }
        switch fact.key {
        case "scripts": return .danger
        case "externalRefs", "foreignObjects": return .caution
        default: return nil
        }
    }

    static func textToken(_ level: Badge.Level) -> String {
        switch level { case .danger: "danger-text"; case .caution: "caution-text"; case .info: "t2" }
    }

    private static func heading(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: Metric.value("fs-micro"), weight: .semibold)
        label.textColor = NSColor.token("t3")
        return label
    }

    /// "Elements        14": the label in t2 on the left, the value on the right in tabular digits.
    private static func row(_ labelText: String, _ valueText: String, valueToken: String) -> NSView {
        let label = NSTextField(labelWithString: labelText)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = NSColor.token("t2")
        label.lineBreakMode = .byTruncatingTail
        let value = NSTextField(labelWithString: valueText)
        value.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        value.textColor = NSColor.token(valueToken)
        value.alignment = .right
        value.lineBreakMode = .byTruncatingMiddle
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, value])
        row.orientation = .horizontal
        row.spacing = Metric.value("sp-12")
        row.distribution = .fill
        return row
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("card2").cgColor }
}

/// One warning: a dot in its level's colour, the title, and the detail under it in t2. roadmap: S-6
@MainActor
final class SVGWarningRow: NSView {
    private let dot = SVGDot()

    init(_ badge: Badge) {
        super.init(frame: .zero)
        dot.token = badge.level == .danger ? "danger" : badge.level == .caution ? "caution" : "t3"
        let title = NSTextField(labelWithString: badge.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = NSColor.token(SVGInspector.textToken(badge.level) == "t2" ? "t1" : SVGInspector.textToken(badge.level))
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 0
        let detail = NSTextField(wrappingLabelWithString: badge.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor.token("t2")
        detail.isSelectable = true
        for v in [dot, title, detail] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        let dotSize: CGFloat = 7
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor), dot.widthAnchor.constraint(equalToConstant: dotSize),
            dot.heightAnchor.constraint(equalToConstant: dotSize), dot.centerYAnchor.constraint(equalTo: title.firstBaselineAnchor, constant: -4),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: Metric.value("sp-6")),
            title.trailingAnchor.constraint(equalTo: trailingAnchor), title.topAnchor.constraint(equalTo: topAnchor),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Metric.value("sp-2")),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        detail.preferredMaxLayoutWidth = Metric.value("w-inspector") - 2 * Metric.value("sp-14") - dotSize - Metric.value("sp-6")
        title.preferredMaxLayoutWidth = detail.preferredMaxLayoutWidth
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(localized: "\(badge.title). \(badge.detail)", bundle: .previewKit,
                                     comment: "Accessibility label of an SVG warning row: its title, then its detail."))
    }

    required init?(coder: NSCoder) { nil }
}

/// A round dot in a token colour.
final class SVGDot: NSView {
    var token = "t3" { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.token(token).cgColor
        layer?.cornerRadius = bounds.height / 2
    }
    override func layout() { super.layout(); needsDisplay = true }
}

/// A 0.5 pt line in the `sep` token.
final class SVGSepLine: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("sep").cgColor }
}

final class SVGFlippedView: NSView {
    override var isFlipped: Bool { true }
}
