import AppKit

/// The one place Vitrine's look is defined. AppKit views read these directly; the web renderers get the same values
/// as CSS custom properties through `cssVariables(for:)`, so both engines draw from one palette (G-1).
public struct DesignTokens: Sendable {
    public struct Palette: Sendable, Equatable {
        public var background: String
        public var surface: String
        public var text: String
        public var secondaryText: String
        public var accent: String
        public var border: String
        public var selection: String
        public var codeBackground: String
        public var link: String

        public init(background: String, surface: String, text: String, secondaryText: String, accent: String,
                    border: String, selection: String, codeBackground: String, link: String) {
            self.background = background; self.surface = surface; self.text = text; self.secondaryText = secondaryText
            self.accent = accent; self.border = border; self.selection = selection
            self.codeBackground = codeBackground; self.link = link
        }
    }

    public var light: Palette
    public var dark: Palette
    public var proseFont: String
    public var monoFont: String
    public var baseSize: Double
    public var lineHeight: Double
    public var radius: Double
    public var spacing: Double

    /// The system palette, read from the approved design system (`GeneratedTokens`, tokens.json v2): page,
    /// window, body and secondary text, accent, hairline, selection, code ground, link.
    public static let standard = DesignTokens(
        light: systemPalette(.light), dark: systemPalette(.dark),
        proseFont: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif",
        monoFont: "ui-monospace, 'SF Mono', Menlo, monospace",
        baseSize: 14, lineHeight: 1.55, radius: 8, spacing: 16)

    static func systemPalette(_ appearance: Appearance) -> Palette {
        func v(_ name: String) -> String {
            guard let token = GeneratedTokens.color(name) else { preconditionFailure("design system lost token \(name)") }
            return token.value(for: appearance)
        }
        return Palette(background: v("page"), surface: v("win"), text: v("t1"), secondaryText: v("t2"), accent: v("accent"),
                       border: v("hair"), selection: v("sel"), codeBackground: v("code"), link: v("accent-text"))
    }

    public enum Appearance: String, Sendable { case light, dark }

    public func palette(for appearance: Appearance) -> Palette { appearance == .dark ? dark : light }

    /// CSS custom properties for the given appearance; the web templates reference only these names.
    public func cssVariables(for appearance: Appearance) -> String {
        let p = palette(for: appearance)
        return """
        --vt-bg: \(p.background); --vt-surface: \(p.surface); --vt-text: \(p.text); --vt-text-2: \(p.secondaryText);
        --vt-accent: \(p.accent); --vt-border: \(p.border); --vt-selection: \(p.selection); --vt-code-bg: \(p.codeBackground);
        --vt-link: \(p.link); --vt-font: \(proseFont); --vt-mono: \(monoFont); --vt-size: \(baseSize)px;
        --vt-lh: \(lineHeight); --vt-radius: \(radius)px; --vt-space: \(spacing)px;
        """ + " " + Self.systemCSS(for: appearance)
    }

    /// Every design-system token as `--v-<name>: <value>;` (colours and shadows for the appearance, then sizes, radii, type,
    /// fonts, materials and motion), for pages drawn straight from the system tokens.
    public static func systemCSS(for appearance: Appearance) -> String {
        (GeneratedTokens.colors.map { "--v-\($0.name): \($0.value(for: appearance));" }
            + GeneratedTokens.shadows.map { "--v-\($0.name): \($0.value(for: appearance));" }
            + GeneratedTokens.metrics.map { "--v-\($0.name): \($0.value);" }).joined(separator: " ")
    }

    /// The appearance the host window is showing right now.
    @MainActor public static func currentAppearance(for view: NSView?) -> Appearance {
        let appearance = view?.effectiveAppearance ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

public extension NSColor {
    /// A CSS colour string from the token tables: `#RRGGBB`, `#RRGGBBAA` or `rgb(a)(r, g, b[, a])`. Anything else
    /// (a gradient) gives nil; callers that back a view with it pick a solid token instead.
    convenience init?(css: String) {
        let s = css.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            let hex = s.dropFirst()
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            let rgba = hex.count == 6 ? (v << 8) | 0xFF : v
            self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                      blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
            return
        }
        guard s.hasPrefix("rgb"), let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let parts = s[s.index(after: open)..<s.index(before: s.endIndex)].split(separator: ",")
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 || parts.count == 4, parts.allSatisfy({ $0 != nil }) else { return nil }
        let n = parts.map { $0! }
        self.init(srgbRed: n[0] / 255, green: n[1] / 255, blue: n[2] / 255, alpha: n.count == 4 ? n[3] : 1)
    }
}
