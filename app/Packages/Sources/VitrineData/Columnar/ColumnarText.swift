import Foundation

/// How a stored value reads in a cell, the Inspector and Copy as: dates as ISO dates, timestamps in their zone (UTC
/// without a suffix), decimals with their scale, bytes as short hex, floats in their shortest exact form. No
/// formatter objects: the calendar arithmetic is done here, so millions of cells cost no allocation beyond the
/// string. roadmap: S-21
public enum ColumnarText {
    /// The text of `cell` in a column of `kind`.
    public static func text(_ cell: ColumnarCell, kind: ColumnarKind) -> String {
        switch cell {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return s
        case .text(let s, _): return s
        case .bytes(let b):
            if kind == .uuid, b.count == 16 { return uuid(b) }
            return hex(b)
        case .double(let d): return double(d)
        case .int(let n): return int(n, kind: kind)
        }
    }

    /// A footer statistic as the File tab lists it: whole numbers with grouping ("2,412,903"), the rest as cells read.
    public static func summary(_ cell: ColumnarCell, kind: ColumnarKind) -> String {
        if case .int(let n) = cell, case .integer(_, let signed) = kind {
            return signed || n >= 0 ? n.formatted() : UInt64(bitPattern: n).formatted()
        }
        return text(cell, kind: kind)
    }

    /// The number a cell stands for (for sums, sorting and charts); nil when it is not one.
    public static func number(_ cell: ColumnarCell, kind: ColumnarKind) -> Double? {
        switch cell {
        case .int(let n):
            switch kind {
            case .decimal(_, let scale): return Double(n) / pow(10, Double(scale))
            case .integer(64, false): return Double(UInt64(bitPattern: n))
            default: return Double(n)
            }
        case .double(let d): return d.isFinite ? d : nil
        case .bool(let b): return b ? 1 : 0
        case .text(_, let n): return n
        default: return nil
        }
    }

    static func int(_ n: Int64, kind: ColumnarKind) -> String {
        switch kind {
        case .integer(64, false): return String(UInt64(bitPattern: n))
        case .decimal(_, let scale): return decimal(unscaled: String(n.magnitude), negative: n < 0, scale: scale)
        case .date: return date(days: n)
        case .dateMillis:
            let (days, rest) = floorDivide(n, 86_400_000)
            return rest == 0 ? date(days: days) : timestamp(n, unit: .millis, zone: "UTC")
        case .time(let unit): return time(n, unit: unit)
        case .timestamp(let unit, let zone): return timestamp(n, unit: unit, zone: zone)
        case .duration(let unit): return duration(n, unit: unit)
        case .float: return double(Double(n))
        default: return String(n)
        }
    }

    /// Shortest form that reads back to the same value: "23.4", "1e-07", "inf".
    public static func double(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        if d.rounded() == d, abs(d) < 1e16 { return String(Int64(d)) }
        return "\(d)"
    }

    /// "123.45" from "12345" at scale 2.
    public static func decimal(unscaled digits: String, negative: Bool, scale: Int) -> String {
        // The readers refuse scales past 76 (no decimal type has more digits); this keeps the text bounded anyway.
        let scale = min(scale, 76)
        guard scale > 0 else {
            let shifted = scale < 0 && digits != "0" ? digits + String(repeating: "0", count: min(-scale, 64)) : digits
            return (negative ? "-" : "") + shifted
        }
        var d = digits
        if d.count <= scale { d = String(repeating: "0", count: scale - d.count + 1) + d }
        let cut = d.index(d.endIndex, offsetBy: -scale)
        return (negative ? "-" : "") + d[..<cut] + "." + d[cut...]
    }

    /// A big-endian two's complement integer (a Parquet FIXED_LEN_BYTE_ARRAY or BYTE_ARRAY decimal, an Arrow
    /// Decimal128/256 after byte reversal) as decimal digits and a sign. Up to 64 bytes.
    public static func bigEndianInteger(_ bytes: [UInt8]) -> (digits: String, negative: Bool) {
        guard !bytes.isEmpty else { return ("0", false) }
        var b = Array(bytes.prefix(64))
        let negative = b[0] & 0x80 != 0
        if negative {
            // Two's complement magnitude: invert and add one.
            for i in b.indices { b[i] = ~b[i] }
            var i = b.count - 1
            while i >= 0 { let (v, o) = b[i].addingReportingOverflow(1); b[i] = v; if !o { break }; i -= 1 }
        }
        var digits: [UInt8] = []
        var number = b
        while number.contains(where: { $0 != 0 }) {
            var remainder = 0
            for i in number.indices {
                let acc = remainder << 8 | Int(number[i])
                number[i] = UInt8(acc / 10)
                remainder = acc % 10
            }
            digits.append(UInt8(remainder))
        }
        if digits.isEmpty { return ("0", false) }
        return (String(digits.reversed().map { Character(String($0)) }), negative)
    }

    public static func hex(_ bytes: [UInt8], limit: Int = 32) -> String {
        let shown = bytes.prefix(limit).map { String(format: "%02x", $0) }.joined()
        return bytes.count > limit ? String(localized: "\(shown)… (\(bytes.count.formatted()) bytes)", bundle: .module, comment: "A binary value cut short in a table cell: hex digits, then the full length in bytes.") : shown
    }

    public static func uuid(_ b: [UInt8]) -> String {
        let h = b.map { String(format: "%02x", $0) }
        return [h[0..<4], h[4..<6], h[6..<8], h[8..<10], h[10..<16]].map { $0.joined() }.joined(separator: "-")
    }

    // MARK: Calendar

    /// Floor division and the non-negative remainder.
    static func floorDivide(_ a: Int64, _ b: Int64) -> (Int64, Int64) {
        let q = a / b, r = a % b
        return r < 0 ? (q - 1, r + b) : (q, r)
    }

    /// Year, month and day of a day count since 1970-01-01 in the proleptic Gregorian calendar (the civil-from-days
    /// algorithm described by Howard Hinnant, "chrono-Compatible Low-Level Date Algorithms").
    static func civil(days: Int64) -> (year: Int64, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = Int(doy - (153 * mp + 2) / 5 + 1)
        let m = Int(mp < 10 ? mp + 3 : mp - 9)
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// Days since 1970-01-01 of a civil date (the inverse of `civil`).
    public static func days(year: Int64, month: Int, day: Int) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let m = Int64(month)
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + Int64(day) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public static func date(days: Int64) -> String {
        guard abs(days) < 3_000_000_000 else { return String(localized: "\(days.formatted()) days", bundle: .module, comment: "A date too far from today to show as a calendar date: a number of days since 1970.") }
        let c = civil(days: days)
        let year = c.year < 0 || c.year > 9999 ? String(c.year) : pad(Int(c.year), 4)
        return "\(year)-\(pad(c.month, 2))-\(pad(c.day, 2))"
    }

    /// "2026-09-01 00:01:00", with a fraction only when the value has one, in `zone` (nil and "UTC" show
    /// the stored clock time; an Olson name or "+05:30" moves it to that zone and says so).
    public static func timestamp(_ value: Int64, unit: ColumnarTimeUnit, zone: String?) -> String {
        var (seconds, fraction) = floorDivide(value, unit.perSecond)
        var suffix = ""
        if let zone, !zone.isEmpty, zone.uppercased() != "UTC", zone != "Z", zone != "+00:00", zone != "Etc/UTC" {
            if let offset = offsetSeconds(zone: zone, at: seconds) {
                let (moved, overflow) = seconds.addingReportingOverflow(Int64(offset))
                if !overflow { seconds = moved; suffix = " " + zone }
            }
        }
        let (days, secondOfDay) = floorDivide(seconds, 86_400)
        // Seconds always, so a column's values line up; a fraction only when the value has one.
        return date(days: days) + " " + clock(secondOfDay, fraction: fraction, unit: unit, alwaysSeconds: true) + suffix
    }

    static func offsetSeconds(zone: String, at seconds: Int64) -> Int? {
        if let tz = TimeZone(identifier: zone) { return tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds))) }
        // "+05:30", "-0800".
        let digits = zone.filter(\.isNumber)
        guard let sign = zone.first, sign == "+" || sign == "-", digits.count == 4, let n = Int(digits) else { return nil }
        let value = (n / 100) * 3_600 + (n % 100) * 60
        return sign == "-" ? -value : value
    }

    public static func time(_ value: Int64, unit: ColumnarTimeUnit) -> String {
        let (seconds, fraction) = floorDivide(value, unit.perSecond)
        let (_, ofDay) = floorDivide(seconds, 86_400)
        return clock(ofDay, fraction: fraction, unit: unit, alwaysSeconds: true)
    }

    static func clock(_ secondOfDay: Int64, fraction: Int64, unit: ColumnarTimeUnit, alwaysSeconds: Bool = false) -> String {
        let h = Int(secondOfDay / 3_600), m = Int(secondOfDay / 60 % 60), s = Int(secondOfDay % 60)
        var text = "\(pad(h, 2)):\(pad(m, 2))"
        if s != 0 || fraction != 0 || alwaysSeconds { text += ":\(pad(s, 2))" }
        if fraction != 0 {
            let width = unit == .millis ? 3 : (unit == .micros ? 6 : 9)
            var f = pad(Int(fraction), width)
            while f.hasSuffix("0") { f.removeLast() }
            text += "." + f
        }
        return text
    }

    public static func duration(_ value: Int64, unit: ColumnarTimeUnit) -> String {
        let (seconds, fraction) = floorDivide(value, unit.perSecond)
        if fraction == 0 { return "\(seconds) s" }
        return "\(double(Double(value) / Double(unit.perSecond))) s"
    }

    static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}
