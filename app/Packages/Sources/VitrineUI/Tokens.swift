/// The shapes of the generated design-system tables (`Tokens.generated.swift`, built from
/// design/mockups/unified/tokens.json by app/tools/gen_tokens.py). Values are CSS colour strings: `#RRGGBB`,
/// `rgba(…)`, or for a few large grounds a `linear-gradient(…)`; `NSColor(css:)` reads the first two.

/// One system colour, `--v-<name>` in CSS.
public struct ColorToken: Sendable, Equatable {
    public let name: String
    public let light: String
    public let dark: String

    public init(name: String, light: String, dark: String) {
        self.name = name; self.light = light; self.dark = dark
    }

    public func value(for appearance: DesignTokens.Appearance) -> String { appearance == .dark ? dark : light }
}

/// The twelve colours of a Markdown theme (tokens.json › markdownThemes › keys).
public struct ThemeColors: Sendable, Equatable {
    /// page, body text, secondary text, links and accent, hairlines, code ground
    public let bg, fg, fg2, acc, rule, code: String
    /// syntax keyword, string, number, comment, function; find highlight
    public let sk, ss, sn, sc, sf, hl: String

    public init(bg: String, fg: String, fg2: String, acc: String, rule: String, code: String,
                sk: String, ss: String, sn: String, sc: String, sf: String, hl: String) {
        self.bg = bg; self.fg = fg; self.fg2 = fg2; self.acc = acc; self.rule = rule; self.code = code
        self.sk = sk; self.ss = ss; self.sn = sn; self.sc = sc; self.sf = sf; self.hl = hl
    }
}

/// One theme of the Markdown Collection: its type and its colours in both appearances.
public struct MarkdownThemeSpec: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let font: String
    public let headingFont: String
    public let mono: String
    /// Body size in px, line height as a multiple, text measure in px.
    public let size: Double
    public let lineHeight: Double
    public let measure: Int
    public let headingWeight: Int
    public let light: ThemeColors
    public let dark: ThemeColors

    public init(id: String, name: String, font: String, headingFont: String, mono: String, size: Double,
                lineHeight: Double, measure: Int, headingWeight: Int, light: ThemeColors, dark: ThemeColors) {
        self.id = id; self.name = name; self.font = font; self.headingFont = headingFont; self.mono = mono
        self.size = size; self.lineHeight = lineHeight; self.measure = measure; self.headingWeight = headingWeight
        self.light = light; self.dark = dark
    }

    public func colors(for appearance: DesignTokens.Appearance) -> ThemeColors { appearance == .dark ? dark : light }
}

public extension GeneratedTokens {
    /// A system colour by token name; nil when the design system has no such token.
    static func color(_ name: String) -> ColorToken? { colorsByName[name] }

    private static let colorsByName: [String: ColorToken] = Dictionary(uniqueKeysWithValues: colors.map { ($0.name, $0) })
}
