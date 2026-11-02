import AppKit
import VitrineUI

/// The small drawn parts the Glass Case card and the trust verdict are made of (cards r3-a, trust r3-a, the unified
/// system's `.tile32`, `.chip`, `.ans .no`): token-coloured boxes, the gradient kind tile, chips, the numbered finding
/// chip and a label that wraps at its real width. Every colour is a token resolved in `updateLayer`, so light and dark
/// follow. roadmap: S-8, S-22

/// A CSS font weight (400, 500, 600, 650, 700) as an AppKit weight; SF is variable, so 650 draws between semibold
/// and bold as the design asks.
func cssWeight(_ w: Int) -> NSFont.Weight {
    let stops: [(Int, CGFloat)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
    if w <= stops[0].0 { return NSFont.Weight(stops[0].1) }
    for (a, b) in zip(stops, stops.dropFirst()) where w <= b.0 {
        let t = CGFloat(w - a.0) / CGFloat(b.0 - a.0)
        return NSFont.Weight(a.1 + (b.1 - a.1) * t)
    }
    return NSFont.Weight(stops.last!.1)
}

/// A type token's weight (`fs-headline` → 650), from the generated tokens.
func tokenWeight(_ type: String) -> Int {
    GeneratedTokens.metrics.first(where: { $0.name == type + "-w" }).flatMap { Int($0.value) } ?? 400
}

/// The system font at a type token's size and weight, or at an explicit CSS weight.
@MainActor
func tokenFont(_ type: String, weight: Int? = nil) -> NSFont {
    systemFont(Metric.value(type), cssWeight: weight ?? tokenWeight(type))
}

/// The system font at a CSS weight. AppKit snaps `systemFont(ofSize:weight:)` to the named weights (650 would draw
/// as bold), so an in-between weight sets SF's own `wght` axis to the exact value.
func systemFont(_ size: CGFloat, cssWeight w: Int) -> NSFont {
    let named = NSFont.systemFont(ofSize: size, weight: cssWeight(w))
    guard w % 100 != 0 else { return named }
    let wght = 0x7767_6874 // 'wght'
    let descriptor = NSFont.systemFont(ofSize: size, weight: cssWeight(w / 100 * 100)).fontDescriptor
        .addingAttributes([.variation: [wght: w]])
    return NSFont(descriptor: descriptor, size: size) ?? named
}

/// The same font with tabular figures (`font-variant-numeric: tabular-nums`).
func tabularFigures(_ font: NSFont) -> NSFont {
    let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
        NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
        NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
    ]]])
    return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
}

/// The value of a font's `wght` axis (SF's CSS-like weight), nil when the font has none.
func fontWeightAxis(_ font: NSFont) -> Double? {
    let variation = CTFontCopyVariation(font) as? [Int: Double]
    return variation?[0x7767_6874]
}

/// A view whose layer colour is a token, resolved in updateLayer so light and dark follow.
@MainActor
class TokenBox: NSView {
    var fill: String? { didSet { needsDisplay = true } }
    /// Drawn at this opacity: the danger box's chip is white at .22 (trust r3-a `.chip.on-solid`).
    var fillAlpha: CGFloat = 1 { didSet { needsDisplay = true } }
    var border: String? { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 1
    var radius: CGFloat = 0

    init(fill: String?, radius: CGFloat = 0, border: String? = nil, borderWidth: CGFloat = 1) {
        self.fill = fill; self.radius = radius; self.border = border; self.borderWidth = borderWidth
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = radius
            layer?.backgroundColor = fill.map { name -> CGColor in
                let color = NSColor.token(name)
                guard fillAlpha < 1, let rgb = color.usingColorSpace(.sRGB) else { return color.cgColor }
                return rgb.withAlphaComponent(rgb.alphaComponent * fillAlpha).cgColor
            }
            layer?.borderColor = border.map { NSColor.token($0).cgColor }
            layer?.borderWidth = border == nil ? 0 : borderWidth
        }
    }
}

/// The 32 pt kind tile (`.tile32`, cards r3-a): the kind colour drawn as a top-to-bottom gradient from the colour
/// mixed with 18 % white to the colour itself, a 0.5 pt darker inner edge and a 1 pt light line along the top, with
/// an 18 pt white glyph.
@MainActor
final class KindTileView: NSView {
    let token: String
    private let gradient = CAGradientLayer()
    static let size: CGFloat = 32

    init(token: String, symbol: String) {
        self.token = token
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = true
        layer?.addSublayer(gradient)
        let glyph = cardSymbol(symbol, size: 18, color: "on-accent", weight: .medium)
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size), heightAnchor.constraint(equalToConstant: Self.size),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor), glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// The three colours the tile is drawn with, for the view's appearance: gradient top, gradient bottom, edge.
    func colors() -> (top: NSColor, bottom: NSColor, edge: NSColor, highlight: NSColor) {
        var out = (NSColor.clear, NSColor.clear, NSColor.clear, NSColor.clear)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.token(token).usingColorSpace(.sRGB) ?? .gray
            let white = NSColor.token("on-accent").usingColorSpace(.sRGB) ?? .white
            let top = base.blended(withFraction: 0.18, of: white) ?? base
            out = (top, base, base.shadow(withLevel: 0.12) ?? base, top.blended(withFraction: 0.25, of: white) ?? top)
        }
        return out
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let c = colors()
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = c.edge.cgColor
        // An unflipped layer's y runs up, so the first stop (the top) sits at y = 1; the first point is the light line.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        let line = NSNumber(value: Double(1 / Self.size))
        gradient.colors = [c.highlight, c.highlight, c.top, c.bottom].map(\.cgColor)
        gradient.locations = [0, line, line, 1]
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}

/// A numbered finding (trust `.ans .no`, v2 V8): a 16 pt circle, its number white 10.5/700, on the strong danger or
/// caution colour.
@MainActor
final class NumberChip: TokenBox {
    let number: Int
    let label: NSTextField
    static let size: CGFloat = 16

    init(number: Int, danger: Bool) {
        self.number = number
        label = cardLabel("\(number)", font: tokenFont("fs-micro", weight: 700), color: "on-accent")
        label.alignment = .center
        super.init(fill: danger ? "danger-strong" : "caution-strong", radius: Self.size / 2)
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size), heightAnchor.constraint(equalToConstant: Self.size),
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// A 22 pt chip, radius 11, an 11 pt glyph and 11.5/500 words (`.chip`).
@MainActor
final class ChipView: TokenBox {
    let label: NSTextField

    init(text: String, symbol: String?, fill: String, fillAlpha: CGFloat = 1, textColor: String, border: String? = nil) {
        label = cardLabel(text, font: tokenFont("fs-sub", weight: 500), color: textColor)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        super.init(fill: fill, radius: Metric.value("h-chip") / 2, border: border, borderWidth: 0.5)
        self.fillAlpha = fillAlpha
        addSubview(label)
        var constraints = [heightAnchor.constraint(equalToConstant: Metric.value("h-chip")),
                           label.centerYAnchor.constraint(equalTo: centerYAnchor),
                           label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9)]
        if let symbol {
            let glyph = cardSymbol(symbol, size: 11, color: textColor, weight: .semibold)
            addSubview(glyph)
            constraints += [glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7), glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
                            label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 5)]
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9))
        }
        NSLayoutConstraint.activate(constraints)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }
}

/// A multi-line label that wraps at the width layout gives it (its leading and trailing are pinned), so it reflows
/// when the panel is resized instead of truncating at a guessed width.
@MainActor
final class WrappingLabel: NSTextField {
    convenience init(_ text: String, font: NSFont, color: String, lines: Int) {
        self.init(labelWithString: text)
        configure(font: font, color: color, lines: lines)
    }

    convenience init(attributed: NSAttributedString, lines: Int) {
        self.init(labelWithAttributedString: attributed)
        configure(font: nil, color: nil, lines: lines)
    }

    private func configure(font: NSFont?, color: String?, lines: Int) {
        if let font { self.font = font }
        if let color { textColor = NSColor.token(color) }
        maximumNumberOfLines = lines
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
        cell?.truncatesLastVisibleLine = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        preferredMaxLayoutWidth = 200
    }

    override func layout() {
        super.layout()
        if frame.width > 1, abs(preferredMaxLayoutWidth - frame.width) > 0.5 {
            preferredMaxLayoutWidth = frame.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// A one-line label in a token colour.
@MainActor
func cardLabel(_ text: String, font: NSFont, color: String) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = font
    field.textColor = NSColor.token(color)
    field.maximumNumberOfLines = 1
    field.lineBreakMode = .byTruncatingTail
    field.cell?.truncatesLastVisibleLine = true
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

/// An SF Symbol in a token colour.
@MainActor
func cardSymbol(_ name: String, size: CGFloat, color: String, weight: NSFont.Weight = .semibold) -> NSImageView {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? NSImage()
    let view = NSImageView(image: image)
    view.contentTintColor = NSColor.token(color)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentHuggingPriority(.required, for: .horizontal)
    view.setContentCompressionResistancePriority(.required, for: .horizontal)
    return view
}
