import Foundation

/// What a column holds, judged from a sample. Order is from most to least specific within each family: an integer is
/// also a decimal, a date is also a date-time, and everything is text.
public enum CSVColumnType: String, Sendable, Equatable, CaseIterable, Codable {
    /// Every sampled value was empty.
    case empty
    case boolean
    case integer
    case decimal
    case date
    case dateTime
    case text

    public var displayName: String {
        switch self {
        case .empty: String(localized: "Empty", bundle: .module, comment: "Column type: every sampled value was empty.")
        case .boolean: String(localized: "Boolean", bundle: .module, comment: "Column type: true/false values.")
        case .integer: String(localized: "Integer", bundle: .module, comment: "Column type: whole numbers.")
        case .decimal: String(localized: "Decimal", bundle: .module, comment: "Column type: numbers with a fractional part.")
        case .date: String(localized: "Date", bundle: .module, comment: "Column type: calendar dates.")
        case .dateTime: String(localized: "Date and time", bundle: .module, comment: "Column type: dates with a time of day.")
        case .text: String(localized: "Text", bundle: .module, comment: "Column type: free text.")
        }
    }

    var isNumeric: Bool { self == .integer || self == .decimal }
    var isTemporal: Bool { self == .date || self == .dateTime }
}

/// How a column's values are written, where the sample had to decide.
public struct CSVValueStyle: Sendable, Equatable, Codable {
    /// `3,14` is a number (semicolon files, where the comma is free).
    public var decimalComma: Bool
    /// `03/04/2024` is 3 April rather than March 4. Decided per column: any value whose first part is above 12
    /// settles it. Dotted dates (`03.04.2024`) are always day first.
    public var dayFirst: Bool

    public init(decimalComma: Bool = false, dayFirst: Bool = false) {
        self.decimalComma = decimalComma; self.dayFirst = dayFirst
    }
}

/// A column's inferred type and how well the sample fits it.
public struct CSVColumnTypeInfo: Sendable, Equatable, Codable {
    public var index: Int
    public var type: CSVColumnType
    /// Values looked at, empty ones included.
    public var sampled: Int
    public var nonEmpty: Int
    /// Non-empty values that fit `type`. `nonEmpty - fitCount` cells get marked as not fitting.
    public var fitCount: Int
    public var style: CSVValueStyle

    public var misfitCount: Int { nonEmpty - fitCount }

    /// Whether one cell fits the column's type, for marking the ones that do not. Empty cells always fit: missing is
    /// not wrong.
    public func accepts(_ value: String) -> Bool {
        CSVValueClassifier.accepts(value, type: type, style: style)
    }

    /// The value as a number in this column's style ("1.234,5" with a decimal comma), for sorting a numbers column;
    /// nil for a column of another type or a value that is not a number.
    public func number(_ value: String) -> Double? {
        guard type.isNumeric else { return nil }
        return CSVValueClassifier.number(value, style: style)
    }
}

/// Infers column types from sampled values.
public enum CSVColumnInference {
    /// The share of non-empty values a type must fit to be the column's type. Below it the column is text: a
    /// preview that calls a mostly-text column "Integer" and marks most cells as misfits is worse than one that
    /// calls it text.
    public static let fitThreshold = 0.8

    /// Infers every column of `rows`; rows shorter than `columnCount` count as empty in the missing columns.
    public static func infer(rows: [CSVRow], columnCount: Int, dialect: CSVDialect) -> [CSVColumnTypeInfo] {
        let style = CSVValueStyle(decimalComma: dialect.allowsDecimalComma)
        return (0..<columnCount).map { column in
            infer(rows.map { $0[column] }, index: column, style: style)
        }
    }

    /// Infers one column. `style.dayFirst` is ignored and decided from the values.
    public static func infer(_ values: [String], index: Int = 0, style: CSVValueStyle = CSVValueStyle()) -> CSVColumnTypeInfo {
        var counts: [CSVColumnType: Int] = [:]
        var dayFirstVotes = 0, monthFirstVotes = 0
        for value in values {
            let kind = CSVValueClassifier.classify(value, style: style)
            counts[kind, default: 0] += 1
            if kind.isTemporal, let order = CSVValueClassifier.slashOrderEvidence(value) {
                if order { dayFirstVotes += 1 } else { monthFirstVotes += 1 }
            }
        }
        let nonEmpty = values.count - (counts[.empty] ?? 0)
        var resolved = style
        resolved.dayFirst = dayFirstVotes > monthFirstVotes
        guard nonEmpty > 0 else {
            return CSVColumnTypeInfo(index: index, type: .empty, sampled: values.count, nonEmpty: 0, fitCount: 0, style: resolved)
        }
        let needed = Double(nonEmpty) * fitThreshold
        let booleans = counts[.boolean] ?? 0
        let integers = counts[.integer] ?? 0, decimals = counts[.decimal] ?? 0
        let dates = counts[.date] ?? 0, dateTimes = counts[.dateTime] ?? 0

        let type: CSVColumnType
        if Double(booleans) >= needed {
            type = .boolean
        } else if Double(integers + decimals) >= needed {
            type = decimals == 0 ? .integer : .decimal
        } else if Double(dates + dateTimes) >= needed {
            type = dateTimes == 0 ? .date : .dateTime
        } else {
            type = .text
        }
        // Count fits again under the decided style: a slash date valid only in the other order does not fit.
        let fits = type == .text ? nonEmpty : values.reduce(0) { total, value in
            total + (CSVValueClassifier.isNonEmpty(value) && CSVValueClassifier.accepts(value, type: type, style: resolved) ? 1 : 0)
        }
        return CSVColumnTypeInfo(index: index, type: type, sampled: values.count, nonEmpty: nonEmpty, fitCount: fits,
                                 style: resolved)
    }
}

/// Reads one value as a number, boolean or date. Hand-written over UTF-8 bytes rather than DateFormatter and
/// NumberFormatter: those are locale-dependent (a preview must read `1.5` the same on every Mac), and slow enough
/// to matter at a few thousand cells per open.
enum CSVValueClassifier {
    static func classify(_ value: String, style: CSVValueStyle) -> CSVColumnType {
        withTrimmedBytes(value) { bytes in
            if bytes.isEmpty { return .empty }
            if isBoolean(bytes) { return .boolean }
            if let isInteger = scanNumber(bytes, decimalComma: style.decimalComma) { return isInteger ? .integer : .decimal }
            if let date = parseDate(bytes, dayFirst: nil) { return date.hasTime ? .dateTime : .date }
            return .text
        }
    }

    static func isNonEmpty(_ value: String) -> Bool { withTrimmedBytes(value) { !$0.isEmpty } }

    static func accepts(_ value: String, type: CSVColumnType, style: CSVValueStyle) -> Bool {
        withTrimmedBytes(value) { bytes in
            if bytes.isEmpty { return true }
            switch type {
            case .text: return true
            case .empty: return false
            case .boolean: return isBoolean(bytes)
            case .integer: return scanNumber(bytes, decimalComma: style.decimalComma) == true
            case .decimal: return scanNumber(bytes, decimalComma: style.decimalComma) != nil
            case .date: return parseDate(bytes, dayFirst: style.dayFirst).map { !$0.hasTime } ?? false
            case .dateTime: return parseDate(bytes, dayFirst: style.dayFirst) != nil
            }
        }
    }

    static func number(_ value: String, style: CSVValueStyle) -> Double? {
        withTrimmedBytes(value) { bytes in
            guard scanNumber(bytes, decimalComma: style.decimalComma) != nil else { return nil }
            var text = String(decoding: bytes, as: UTF8.self)
            if style.decimalComma { text = text.replacingOccurrences(of: ",", with: ".") }
            if text.hasPrefix("+") { text.removeFirst() }
            return Double(text)
        }
    }

    static func date(_ value: String, style: CSVValueStyle) -> (date: Date, hasTime: Bool)? {
        withTrimmedBytes(value) { bytes in
            parseDate(bytes, dayFirst: style.dayFirst).map { (Date(timeIntervalSince1970: $0.seconds), $0.hasTime) }
        }
    }

    /// For a slash date whose order is settled by its own digits: true when it can only be day first (`25/03/2024`),
    /// false when only month first (`03/25/2024`), nil otherwise.
    static func slashOrderEvidence(_ value: String) -> Bool? {
        withTrimmedBytes(value) { bytes in
            guard let parts = leadingDayMonthParts(bytes), parts.separator == UInt8(ascii: "/") else { return nil }
            if parts.first > 12 && parts.second <= 12 { return true }
            if parts.second > 12 && parts.first <= 12 { return false }
            return nil
        }
    }

    // MARK: Bytes

    private static func withTrimmedBytes<T>(_ value: String, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        var value = value
        return value.withUTF8 { all in
            var lower = 0, upper = all.count
            while lower < upper, all[lower] == 0x20 || all[lower] == 0x09 { lower += 1 }
            while upper > lower, all[upper - 1] == 0x20 || all[upper - 1] == 0x09 { upper -= 1 }
            return body(UnsafeBufferPointer(rebasing: all[lower..<upper]))
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    // MARK: Booleans

    private static let booleanWords: Set<String> = ["true", "false", "yes", "no", "t", "f", "y", "n"]

    private static func isBoolean(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count <= 5 else { return false }
        return booleanWords.contains(String(decoding: bytes, as: UTF8.self).lowercased())
    }

    // MARK: Numbers

    /// `[+-] digits [sep digits] [e [+-] digits]`, or `[+-] sep digits …`. No thousands separators: `1,234` in a
    /// comma file would have been quoted, and accepting it would misread decimal-comma files.
    private static func scanNumber(_ bytes: UnsafeBufferPointer<UInt8>, decimalComma: Bool) -> Bool? {
        let n = bytes.count
        var i = 0
        if i < n, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
        var integerDigits = 0, fractionDigits = 0
        while i < n, isDigit(bytes[i]) { i += 1; integerDigits += 1 }
        var hasSeparator = false
        if i < n, bytes[i] == UInt8(ascii: ".") || (decimalComma && bytes[i] == UInt8(ascii: ",")) {
            hasSeparator = true
            i += 1
            while i < n, isDigit(bytes[i]) { i += 1; fractionDigits += 1 }
        }
        guard integerDigits + fractionDigits > 0 else { return nil }
        var hasExponent = false
        if i < n, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            hasExponent = true
            i += 1
            if i < n, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            var exponentDigits = 0
            while i < n, isDigit(bytes[i]) { i += 1; exponentDigits += 1 }
            guard exponentDigits > 0 else { return nil }
        }
        guard i == n else { return nil }
        return !hasSeparator && !hasExponent
    }

    // MARK: Dates

    struct ParsedDate { var seconds: Double; var hasTime: Bool }

    private struct DayMonthParts { var first: Int; var second: Int; var year: Int; var separator: UInt8; var end: Int }

    /// `AA/BB/YYYY` or `AA.BB.YYYY` at the start of `bytes`.
    private static func leadingDayMonthParts(_ bytes: UnsafeBufferPointer<UInt8>) -> DayMonthParts? {
        var i = 0
        guard let a = digits(bytes, &i, min: 1, max: 2), i < bytes.count else { return nil }
        let separator = bytes[i]
        guard separator == UInt8(ascii: "/") || separator == UInt8(ascii: ".") else { return nil }
        i += 1
        guard let b = digits(bytes, &i, min: 1, max: 2), i < bytes.count, bytes[i] == separator else { return nil }
        i += 1
        guard let year = digits(bytes, &i, min: 4, max: 4) else { return nil }
        return DayMonthParts(first: a, second: b, year: year, separator: separator, end: i)
    }

    /// Reads `min…max` digits at `i`, advancing it; nil (and `i` unchanged) when there are fewer than `min`.
    private static func digits(_ bytes: UnsafeBufferPointer<UInt8>, _ i: inout Int, min: Int, max: Int) -> Int? {
        var value = 0, j = i
        while j < bytes.count, j - i < max, isDigit(bytes[j]) { value = value * 10 + Int(bytes[j] - 0x30); j += 1 }
        guard j - i >= min else { return nil }
        i = j
        return value
    }

    /// The forms read:
    /// - ISO 8601 dates `YYYY-MM-DD` and `YYYY/MM/DD`;
    /// - `MM/DD/YYYY` or `DD/MM/YYYY` (`dayFirst`; nil accepts whichever order is a valid date), and `DD.MM.YYYY`;
    /// - any of those followed by `T` or a space and `HH:MM[:SS[.fraction]]`, an optional ` AM`/` PM`, and an optional
    ///   zone `Z`, `±HH`, `±HHMM` or `±HH:MM`.
    /// Times without a zone are read as UTC: the value orders and ranges a column, it is never shown converted.
    static func parseDate(_ bytes: UnsafeBufferPointer<UInt8>, dayFirst: Bool?) -> ParsedDate? {
        guard bytes.count >= 8 else { return nil }
        var year = 0, month = 0, day = 0
        var i = 0
        if bytes.count >= 4, isDigit(bytes[0]), isDigit(bytes[1]), isDigit(bytes[2]), isDigit(bytes[3]) {
            guard let y = digits(bytes, &i, min: 4, max: 4), i < bytes.count else { return nil }
            let separator = bytes[i]
            guard separator == UInt8(ascii: "-") || separator == UInt8(ascii: "/") else { return nil }
            i += 1
            guard let m = digits(bytes, &i, min: 1, max: 2), i < bytes.count, bytes[i] == separator else { return nil }
            i += 1
            guard let d = digits(bytes, &i, min: 1, max: 2) else { return nil }
            (year, month, day) = (y, m, d)
        } else if let parts = leadingDayMonthParts(bytes) {
            year = parts.year
            i = parts.end
            if parts.separator == UInt8(ascii: ".") {
                (day, month) = (parts.first, parts.second)
            } else if let dayFirst {
                (day, month) = dayFirst ? (parts.first, parts.second) : (parts.second, parts.first)
            } else {
                // Either order: month first when it is valid, else day first.
                (month, day) = isValidDate(year, parts.first, parts.second) ? (parts.first, parts.second) : (parts.second, parts.first)
            }
        } else {
            return nil
        }
        guard isValidDate(year, month, day) else { return nil }
        var seconds = Double(daysFromCivil(year, month, day)) * 86_400
        guard i < bytes.count else { return ParsedDate(seconds: seconds, hasTime: false) }

        guard bytes[i] == UInt8(ascii: "T") || bytes[i] == UInt8(ascii: " ") else { return nil }
        i += 1
        guard var hour = digits(bytes, &i, min: 1, max: 2), i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
        i += 1
        guard let minute = digits(bytes, &i, min: 2, max: 2) else { return nil }
        var second = 0.0
        if i < bytes.count, bytes[i] == UInt8(ascii: ":") {
            i += 1
            guard let whole = digits(bytes, &i, min: 2, max: 2) else { return nil }
            second = Double(whole)
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") || bytes[i] == UInt8(ascii: ",") {
                i += 1
                var scale = 0.1, any = false
                while i < bytes.count, isDigit(bytes[i]) { second += Double(bytes[i] - 0x30) * scale; scale /= 10; i += 1; any = true }
                guard any else { return nil }
            }
        }
        if i + 2 < bytes.count, bytes[i] == UInt8(ascii: " "), let meridiem = meridiem(bytes, at: i + 1) {
            guard hour >= 1 && hour <= 12 else { return nil }
            hour = hour % 12 + (meridiem ? 12 : 0)
            i += 3
        }
        guard hour < 24, minute < 60, second < 61 else { return nil }
        seconds += Double(hour * 3600 + minute * 60) + second
        if i < bytes.count {
            let sign = bytes[i]
            if sign == UInt8(ascii: "Z") {
                i += 1
            } else if sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                i += 1
                guard let zoneHours = digits(bytes, &i, min: 2, max: 2), zoneHours <= 14 else { return nil }
                var zoneMinutes = 0
                if i < bytes.count, bytes[i] == UInt8(ascii: ":") { i += 1 }
                if i < bytes.count {
                    guard let m = digits(bytes, &i, min: 2, max: 2), m < 60 else { return nil }
                    zoneMinutes = m
                }
                let offset = Double(zoneHours * 3600 + zoneMinutes * 60)
                seconds -= sign == UInt8(ascii: "+") ? offset : -offset
            }
        }
        guard i == bytes.count else { return nil }
        return ParsedDate(seconds: seconds, hasTime: true)
    }

    /// `AM` → false, `PM` → true, any case, at `index` (two bytes).
    private static func meridiem(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool? {
        guard index + 1 < bytes.count else { return nil }
        let first = bytes[index] | 0x20, second = bytes[index + 1] | 0x20
        guard second == UInt8(ascii: "m") else { return nil }
        if first == UInt8(ascii: "a") { return false }
        if first == UInt8(ascii: "p") { return true }
        return nil
    }

    private static func isValidDate(_ year: Int, _ month: Int, _ day: Int) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= lengths[month - 1]
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's `days_from_civil`), so dates
    /// need no Calendar and no time zone.
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
