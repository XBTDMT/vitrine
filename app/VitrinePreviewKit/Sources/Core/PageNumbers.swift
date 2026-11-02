import Foundation

/// Numbers a web page hands to Swift: in a `WKScriptMessage`'s body, or in what a `callAsyncJavaScript` call returns.
/// Every one goes through here before Swift converts it or does arithmetic with it. roadmap: S-16
///
/// Why: the page's script is Vitrine's own, but what it reports rests on the document (a stylesheet can make sizes
/// NaN or huge, a crafted file can hold billions of lines), and a page message is the one channel the document can
/// reach. `Int(Double)` traps on NaN, infinities and values beyond Int's range; `NSNumber.intValue` silently turns
/// them into garbage, and the next `index + 1` or `to - from + 1` traps instead (S-16 F53 and its follow-up). So a
/// number is accepted only when it is finite, whole where a whole number is meant, and inside the range the receiver
/// gives it: an index inside the list it indexes, a line inside the lines shown, a count no larger than what it
/// counts. Anything else is nil, and the receiver ignores the message rather than guessing.
enum PageNumbers {
    /// A whole number the page sent, when it is one: a number (never a boolean or a string), finite, whole after
    /// rounding, and inside `range`; nil otherwise.
    static func integer(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let number = finite(value), abs(number) < 1e15, let whole = Int(exactly: number.rounded()), range.contains(whole) else { return nil }
        return whole
    }

    /// An index the page sent into a list of `indices` (a file of a patch, a row of a table): nil when it is not a
    /// whole number inside them, and always nil for an empty list.
    static func index(_ value: Any?, in indices: Range<Int>) -> Int? {
        guard !indices.isEmpty else { return nil }
        return integer(value, in: indices.lowerBound...(indices.upperBound - 1))
    }

    /// A measurement the page sent (a scroll offset, a distance in points): a finite number inside `range`; nil
    /// otherwise.
    static func number(_ value: Any?, in range: ClosedRange<Double>) -> Double? {
        guard let number = finite(value), range.contains(number) else { return nil }
        return number
    }

    /// A scroll offset in points: finite and not negative. The bound only keeps it a number the page can take back.
    static func scrollOffset(_ value: Any?) -> Double? { number(value, in: 0...maxPoints) }

    /// The most points a page measures: far past any page Vitrine draws (a window of a huge file is 4,096 lines).
    static let maxPoints = 1e9

    /// The most matches a find on a page reports.
    static let maxMatches = Int(Int32.max)

    /// A page find's answer, `{count, index}`: the count in 0…`maxMatches`, the current match inside the count
    /// (-1 when none). A count that is not a number in range is no matches; an index outside the count is no
    /// current match.
    static func matches(_ answer: [String: Any]?) -> (count: Int, index: Int) {
        let count = integer(answer?["count"], in: 0...maxMatches) ?? 0
        return (count, integer(answer?["index"], in: -1...(count - 1)) ?? -1)
    }

    /// A number, never a boolean (`true` bridges to 1 otherwise) and never NaN or an infinity.
    private static func finite(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
}
