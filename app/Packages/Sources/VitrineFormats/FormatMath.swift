import Foundation

/// Arithmetic on numbers read from files, which can hold any value at all. roadmap: S-16
///
/// Swift traps on an overflowing `+` and on `Int(_:)` of a Double that is NaN, infinite or out of range, so a reader
/// that does either with a file's numbers can be crashed by the file. The rule here:
/// - counts a card only displays saturate (a sum of token counts pinned at Int.max is honest about "very large");
/// - offsets and lengths are checked, and a value that does not fit means the file is damaged;
/// - a Double becomes an Int only when it is finite and in range, otherwise the caller shows "cannot read".
enum FormatMath {
    /// `a + b`, pinned at Int.max or Int.min instead of trapping. For display counts only.
    static func saturatingAdd(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return sum }
        return b > 0 ? Int.max : Int.min
    }

    /// The saturating sum of `values`. For display counts only.
    static func saturatingSum<S: Sequence>(_ values: S) -> Int where S.Element == Int {
        values.reduce(0, saturatingAdd)
    }

    /// `offset + length` when it fits in an Int, nil when it does not (the file is damaged).
    static func end(_ offset: Int, _ length: Int) -> Int? {
        let (sum, overflow) = offset.addingReportingOverflow(length)
        return overflow ? nil : sum
    }

    /// The Int a Double holds, rounded to the nearest whole number, when the Double is finite and the result fits
    /// in an Int; nil otherwise.
    static func int(rounding value: Double) -> Int? {
        int(value.rounded())
    }

    /// The Int a Double holds, truncated toward zero, when the Double is finite and the result fits in an Int; nil
    /// otherwise. (2^63 itself is a Double but not an Int, hence the strict upper bound.)
    static func int(_ value: Double) -> Int? {
        guard value.isFinite, value >= -9_223_372_036_854_775_808.0, value < 9_223_372_036_854_775_808.0 else { return nil }
        return Int(value)
    }
}
