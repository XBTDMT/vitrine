import AppKit
import VitrineDocument
import VitrineSupport
import VitrineTokenizers
import VitrineUI

/// The context-fit meter (A-4), drawn as chrome r3-b's inspector "Tokens" section: a "Tokens" heading, the count in
/// 15 pt bold with its label ("Claude tokens, estimate") beside it, one 60 × 4 bar per window with its share, and the
/// method in t3 underneath. A window the text does not fit fills its bar in caution. It draws a `TokenMeter` and
/// computes nothing, so an exact counter changes the words, not this view. roadmap: S-21
@MainActor
final class TokenMeterView: NSView {
    static let barWidth: CGFloat = 60
    static let barHeight: CGFloat = 4

    let meter: TokenMeter
    private(set) var bars: [MeterBar] = []
    private(set) var rowFields: [WrappingLabel] = []
    let numberField: NSTextField
    let unitField: NSTextField
    let methodField: WrappingLabel
    /// The exact OpenAI count (G-29), filled off the main thread when the person has it on (Settings › General).
    let exactField: WrappingLabel
    static let exactKey = "tokens.openaiExact"

    init(meter: TokenMeter, exactText: String? = nil, fileURL: URL? = nil, defaults: UserDefaults = VitrineDefaults.defaults(suite: VitrineDefaults.suiteName)) {
        self.meter = meter
        numberField = cardLabel(meter.number, font: tabularFigures(systemFont(15, cssWeight: 700)), color: "t1")
        unitField = cardLabel(meter.unit, font: tokenFont("fs-sub"), color: "t2")
        methodField = WrappingLabel(meter.method, font: tokenFont("fs-sub"), color: "t3", lines: 0)
        exactField = WrappingLabel("", font: tabularFigures(tokenFont("fs-sub")), color: "t2", lines: 4)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let heading = cardLabel(String(localized: "Tokens", bundle: .previewKit, comment: "Heading of the inspector's token meter section (A-4)."),
                                font: tokenFont("fs-caption", weight: 600), color: "t2")
        numberField.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [heading, numberField, unitField, methodField, exactField] { addSubview(v) }
        var constraints = [
            heading.topAnchor.constraint(equalTo: topAnchor), heading.leadingAnchor.constraint(equalTo: leadingAnchor),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            numberField.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4), numberField.leadingAnchor.constraint(equalTo: leadingAnchor),
            unitField.leadingAnchor.constraint(equalTo: numberField.trailingAnchor, constant: 8),
            unitField.firstBaselineAnchor.constraint(equalTo: numberField.firstBaselineAnchor),
            unitField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ]
        var previous: NSView = numberField
        for (index, row) in meter.rows.enumerated() {
            let bar = MeterBar(fill: row.fill, over: !row.fits)
            // Two lines at most, so a longer language wraps rather than cutting the share off; the bar sits on the first.
            let font = tabularFigures(tokenFont("fs-sub"))
            let text = WrappingLabel(row.text, font: font, color: row.fits ? "t2" : "caution-text", lines: 2)
            addSubview(bar); addSubview(text)
            constraints += [
                text.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: index == 0 ? 6 : 3),
                bar.leadingAnchor.constraint(equalTo: leadingAnchor),
                bar.centerYAnchor.constraint(equalTo: text.firstBaselineAnchor, constant: -font.xHeight / 2),
                bar.widthAnchor.constraint(equalToConstant: Self.barWidth), bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
                text.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8), text.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
            bars.append(bar); rowFields.append(text)
            previous = text
        }
        constraints += [
            methodField.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 5),
            methodField.leadingAnchor.constraint(equalTo: leadingAnchor), methodField.trailingAnchor.constraint(equalTo: trailingAnchor),
            exactField.topAnchor.constraint(equalTo: methodField.bottomAnchor, constant: 4),
            exactField.leadingAnchor.constraint(equalTo: leadingAnchor), exactField.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomAnchor.constraint(equalTo: exactField.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(meter.accessibilityLabel)
        if let exactText, exactText.utf8.count <= O200kCounter.maxBytes {
            let openAI = defaults.object(forKey: Self.exactKey) as? Bool ?? true
            exactTask = Task { [weak self] in
                let lines = await Task.detached(priority: .utility) { Self.exactLines(exactText, openAI: openAI, besides: fileURL) }.value
                guard let self, !lines.isEmpty, !Task.isCancelled else { return }
                self.showExact(lines)
            }
        }
    }

    /// The exact counts this text has (G-29): OpenAI's o200k when on, and the model tokenizer.json beside the file.
    nonisolated static func exactLines(_ text: String, openAI: Bool, besides fileURL: URL?) -> [String] {
        var lines: [String] = []
        if openAI, let count = O200kCounter().count(.text(text)) {
            lines.append(String(localized: "OpenAI (o200k): \(count.value.formatted()) tokens, exact", bundle: .previewKit,
                                comment: "Token meter line under the estimate: the exact count from OpenAI's o200k_base tokenizer. Names stay as they are."))
        }
        if let file = fileURL, let model = HFTokenizer.beside(file) {
            lines.append(String(localized: "\(model.name) tokenizer.json: \(model.count(text).formatted()) tokens, exact", bundle: .previewKit,
                                comment: "Token meter line: the exact count from the model tokenizer.json in the file's folder; the first argument is that folder's name, the second the count."))
        }
        return lines
    }

    private(set) var exactTask: Task<Void, Never>?

    func showExact(_ lines: [String]) {
        exactField.stringValue = lines.joined(separator: "\n")
        setAccessibilityLabel(([meter.accessibilityLabel] + lines).joined(separator: ". "))
    }

    required init?(coder: NSCoder) { nil }

    /// One window's bar: a `fill2` track with the share in `accent`, or full in `caution` when the text does not fit.
    /// A share too small to see still shows a sliver, so "under 0.1%" is not drawn as empty.
    @MainActor
    final class MeterBar: NSView {
        let fill: Double
        let over: Bool
        private let filled = CALayer()
        static let sliver: CGFloat = 1.5

        init(fill: Double, over: Bool) {
            self.fill = fill; self.over = over
            super.init(frame: .zero)
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            layer?.masksToBounds = true
            layer?.addSublayer(filled)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }

        /// The filled width for the bar's current width.
        var filledWidth: CGFloat {
            guard fill > 0 else { return 0 }
            return min(bounds.width, max(Self.sliver, (bounds.width * fill).rounded(.toNearestOrAwayFromZero)))
        }

        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.cornerRadius = bounds.height / 2
                layer?.backgroundColor = NSColor.token("fill2").cgColor
                filled.backgroundColor = NSColor.token(over ? "caution" : "accent").cgColor
            }
            filled.cornerRadius = bounds.height / 2
            filled.frame = CGRect(x: 0, y: 0, width: filledWidth, height: bounds.height)
        }

        override func layout() {
            super.layout()
            needsDisplay = true
        }
    }
}
