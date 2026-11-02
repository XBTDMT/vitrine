import Foundation
import VitrineUI

/// A Markdown theme: one theme of the Collection the design system defines (tokens.json › markdownThemes, generated
/// into `GeneratedTokens.markdownThemes`), with its type and its light and dark colours. `markdown.theme` in the
/// app-group defaults selects one by id. A user theme file format is S-12's call; it will map onto the same spec.
public struct MarkdownTheme: Sendable, Identifiable, Equatable {
    public let spec: MarkdownThemeSpec

    public init(spec: MarkdownThemeSpec) { self.spec = spec }

    public var id: String { spec.id }
    public var name: String { spec.name }

    /// The Collection, in Settings order; the first (Vitrine) is the default.
    public static let builtIn: [MarkdownTheme] = GeneratedTokens.markdownThemes.map(MarkdownTheme.init(spec:))

    public static let defaultID = builtIn[0].id

    public static func theme(id: String?) -> MarkdownTheme {
        builtIn.first { $0.id == id } ?? builtIn[0]
    }

    /// The page ground, which also backs the web view while it loads.
    public func background(for appearance: DesignTokens.Appearance) -> String { spec.colors(for: appearance).bg }

    /// The CSS variables the Markdown page reads, named as the design names them (`--bg`, `--fg`, `--acc` …,
    /// design/mockups/unified/markdown.html), plus every system token as `--v-*`.
    public func cssVariables(for appearance: DesignTokens.Appearance, textScale: Double = 1) -> String {
        let c = spec.colors(for: appearance)
        return """
        --bg: \(c.bg); --fg: \(c.fg); --fg2: \(c.fg2); --acc: \(c.acc); --rule: \(c.rule); --code: \(c.code);
        --sk: \(c.sk); --ss: \(c.ss); --sn: \(c.sn); --sc: \(c.sc); --sf: \(c.sf); --hl: \(c.hl);
        --font: \(spec.font); --hfont: \(spec.headingFont); --mono: \(spec.mono); --fs: \(Self.px(spec.size * textScale))px;
        --lh: \(spec.lineHeight); --measure: \(spec.measure)px; --hw: \(spec.headingWeight);
        """ + " " + DesignTokens.systemCSS(for: appearance)
    }

    /// The colours diagrams take (`--dg-*`), from this theme in `appearance` (the Diagrams setting, H-1).
    public func diagramVariables(for appearance: DesignTokens.Appearance) -> String {
        let c = spec.colors(for: appearance)
        return "--dg-bg: \(c.bg); --dg-fg: \(c.fg); --dg-fg2: \(c.fg2); --dg-acc: \(c.acc); --dg-rule: \(c.rule); --dg-code: \(c.code);"
    }

    /// The text sizes "Aa" steps through, as a share of the theme's own size.
    public static let textScales: [Double] = [0.85, 0.92, 1, 1.1, 1.2, 1.35, 1.5]

    /// The scale step nearest a stored value, so a hand-edited setting still lands on a step.
    public static func textScale(_ stored: Double?) -> Double {
        guard let stored else { return 1 }
        return textScales.min { abs($0 - stored) < abs($1 - stored) } ?? 1
    }

    private static func px(_ v: Double) -> String { String(format: "%.2f", v).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }
}
