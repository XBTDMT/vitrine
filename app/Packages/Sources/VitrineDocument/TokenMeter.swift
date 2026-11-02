import Foundation

/// The context-fit meter's words and numbers (A-4; chrome r3-b's inspector "Tokens" section): the count, its label
/// (estimate or exact), one row per common context window with the share it takes, and how the count was made. One
/// model, drawn natively in the Details inspector and as HTML in the Markdown column; neither computes anything.
/// roadmap: S-21
public struct TokenMeter: Sendable, Equatable {
    /// The windows the design draws: 200K, the size most agents run with today, and 1M, the largest common one.
    public static let windows = [200_000, 1_000_000]
    /// Shares below this read "under 0.1%" rather than "0.0%".
    static let smallestShare = 0.001

    public struct Row: Sendable, Equatable {
        /// The window's size in tokens.
        public var window: Int
        /// The share of the window the text takes; above 1 when it does not fit.
        public var share: Double
        public var fits: Bool { share <= 1 }
        /// How much of the bar to fill, 0…1.
        public var fill: Double { min(1, max(0, share)) }
        /// "1.6% of a 200K window", "under 0.1% of a 1M window", "Over a 200K window (2.4×)".
        public var text: String
        /// The same for a narrow column (the Markdown sidebar): "1.6% of 200K", "Over 200K (2.4×)".
        public var compactText: String
    }

    public let count: TokenCount
    public let rows: [Row]

    public init(_ count: TokenCount, windows: [Int] = TokenMeter.windows) {
        self.count = count
        rows = windows.filter { $0 > 0 }.map { window in
            let share = Double(count.value) / Double(window)
            return Row(window: window, share: share, text: Self.rowText(share: share, window: window),
                       compactText: Self.compactText(share: share, window: window))
        }
    }

    /// "≈ 3,180" or "3,052".
    public var number: String { count.formatted }

    /// What the number counts: Claude's tokens as an estimate (the design's label), or an exact tokenizer's.
    public var unit: String {
        count.isEstimate
            ? String(localized: "Claude tokens, estimate", bundle: .module, comment: "Token meter: what the estimated number counts, beside it.")
            : String(localized: "tokens, exact", bundle: .module, comment: "Token meter: an exact count from a public tokenizer, beside the number.")
    }

    /// How the count was made, from its counter; a count whose counter this build does not know still says whether
    /// it is an estimate.
    public var method: String {
        if let counter = TokenCounting.counter(id: count.method) { return counter.methodDescription }
        return count.isEstimate
            ? String(localized: "Estimated; no tokenizer ran.", bundle: .module, comment: "Token meter foot: an estimate from a counter this version does not know.")
            : String(localized: "Counted with a tokenizer.", bundle: .module, comment: "Token meter foot: an exact count from a counter this version does not know.")
    }

    /// One sentence for VoiceOver: the number, its label and every row.
    public var accessibilityLabel: String {
        ([number + " " + unit] + rows.map(\.text)).joined(separator: ". ")
    }

    /// A window's size as people say it: "200K", "1M" (locale-aware).
    public static func windowName(_ window: Int) -> String {
        window.formatted(.number.notation(.compactName))
    }

    static func rowText(share: Double, window: Int) -> String {
        let name = windowName(window)
        if share > 1 {
            let times = share.formatted(.number.precision(.fractionLength(1)))
            return String(localized: "Over a \(name) window (\(times)×)", bundle: .module,
                          comment: "Token meter row when the text does not fit a context window. Arguments: the window size such as 200K, then how many times larger, such as 2.4.")
        }
        if share > 0, share < smallestShare {
            let floor = smallestShare.formatted(.percent.precision(.fractionLength(1)))
            return String(localized: "under \(floor) of a \(name) window", bundle: .module,
                          comment: "Token meter row when the text is a tiny share of a context window. Arguments: a percentage such as 0.1%, then the window size such as 200K.")
        }
        return String(localized: "\(percentText(share)) of a \(name) window", bundle: .module,
                      comment: "Token meter row: the share of a context window the text takes. Arguments: a percentage such as 1.6%, then the window size such as 200K.")
    }

    static func compactText(share: Double, window: Int) -> String {
        let name = windowName(window)
        if share > 1 {
            let times = share.formatted(.number.precision(.fractionLength(1)))
            return String(localized: "Over \(name) (\(times)×)", bundle: .module,
                          comment: "Token meter row in a narrow column when the text does not fit a context window. Arguments: the window size such as 200K, then how many times larger, such as 2.4.")
        }
        if share > 0, share < smallestShare {
            let floor = smallestShare.formatted(.percent.precision(.fractionLength(1)))
            return String(localized: "under \(floor) of \(name)", bundle: .module,
                          comment: "Token meter row in a narrow column when the text is a tiny share of a context window. Arguments: a percentage such as 0.1%, then the window size such as 1M.")
        }
        return String(localized: "\(percentText(share)) of \(name)", bundle: .module,
                      comment: "Token meter row in a narrow column: the share of a context window the text takes. Arguments: a percentage such as 1.6%, then the window size such as 200K.")
    }

    /// One decimal under 10%, none above: "1.6%", "48%".
    static func percentText(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0)))
    }
}

extension PreviewDocument {
    /// The meter for the document's token count; nil when it has none.
    public var tokenMeter: TokenMeter? { tokens.map { TokenMeter($0) } }
}
