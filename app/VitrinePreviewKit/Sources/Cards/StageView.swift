import AppKit
import VitrineUI

/// The lit stage the object stands on: the `stage` token, which is a top-to-bottom gradient (cards r3-a). The stops
/// are read from the token for the view's appearance, so light and dark follow. roadmap: S-8
@MainActor
final class StageView: NSView {
    private let gradient = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { nil }

    /// The colour stops of a `linear-gradient(…)` token value, top first; a solid colour gives one stop.
    static func stops(_ css: String) -> [NSColor] {
        guard css.hasPrefix("linear-gradient") else { return NSColor(css: css).map { [$0] } ?? [] }
        let regex = try? NSRegularExpression(pattern: "#[0-9A-Fa-f]{6,8}|rgba?\\([^)]*\\)")
        let ns = css as NSString
        return (regex?.matches(in: css, range: NSRange(location: 0, length: ns.length)) ?? []).compactMap { NSColor(css: ns.substring(with: $0.range)) }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let value = GeneratedTokens.color("stage").map { dark ? $0.dark : $0.light } ?? ""
        let colors = Self.stops(value)
        // An unflipped layer's y runs up, so the first stop (the top) sits at y = 1.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = (colors.count == 1 ? colors + colors : colors).map(\.cgColor)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}
