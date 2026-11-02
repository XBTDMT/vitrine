import AppKit
import SwiftUI

public extension NSColor {
    /// A design-system colour that follows the view's appearance, like a catalog colour: `NSColor.token("t2")`.
    /// Gradient tokens have no solid colour and fall back to clear (and assert in debug).
    static func token(_ name: String) -> NSColor {
        guard let token = GeneratedTokens.color(name) else {
            assertionFailure("no design token \(name)")
            return .clear
        }
        let light = NSColor(css: token.light) ?? .clear, dark = NSColor(css: token.dark) ?? .clear
        return NSColor(name: NSColor.Name("vitrine." + name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

public extension Color {
    /// `Color.token("accent-text")`: the design-system colour, following light and dark.
    static func token(_ name: String) -> Color { Color(nsColor: .token(name)) }
}

/// Size tokens as numbers for native layout: `Metric.value("h-capsule")` → 40.
public enum Metric {
    public static func value(_ name: String) -> CGFloat {
        guard let raw = GeneratedTokens.metrics.first(where: { $0.name == name })?.value,
              raw.hasSuffix("px"), let n = Double(raw.dropLast(2)) else {
            assertionFailure("no px metric \(name)")
            return 0
        }
        return CGFloat(n)
    }
}
