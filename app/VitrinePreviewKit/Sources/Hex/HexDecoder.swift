import Foundation

/// The byte order the decoding drawer reads numbers in (its Little / Big switch). roadmap: S-5
public enum HexEndian: Sendable, Equatable { case little, big }

/// One line of the decoding drawer: "UInt32" and "1,792,574,043". `highlighted` marks the reading that fits the
/// selection best (four bytes that make a plausible date read as one). roadmap: S-5
public struct HexDecodedRow: Sendable, Equatable {
    public var label: String
    public var value: String
    public var highlighted: Bool
    public init(label: String, value: String, highlighted: Bool = false) { self.label = label; self.value = value; self.highlighted = highlighted }
}

/// Reads the bytes at the cursor every way the drawer offers: integers of 8 to 64 bits signed and unsigned, floats,
/// Unix and Mac absolute times as dates, a four-character code, and UTF-8 / UTF-16 text. Pure: it is handed the bytes
/// from the cursor on (`bytes`, up to `wanted`) and how many are selected. roadmap: S-5
public enum HexDecoder {
    /// Bytes the drawer asks for from the cursor: 8 for the widest number, more for the text readings.
    public static let wanted = 64

    public static func rows(bytes: [UInt8], selectionLength: Int, endian: HexEndian) -> [HexDecodedRow] {
        let e = endian == .little ? "LE" : "BE"
        func uint(_ n: Int) -> UInt64? {
            guard bytes.count >= n else { return nil }
            let slice = bytes[0..<n]
            let ordered = endian == .little ? Array(slice.reversed()) : Array(slice)
            return ordered.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        func need(_ n: Int) -> String { Self.needs(n) }
        let n = selectionLength

        var rows: [HexDecodedRow] = []
        rows.append(HexDecodedRow(label: String(localized: "Binary (first byte)", bundle: .previewKit, comment: "Decoding drawer row: the first byte as binary digits."), value: bytes.first.map(binary) ?? need(1)))
        rows.append(HexDecodedRow(label: "UInt8", value: uint(1).map { $0.formatted() } ?? need(1), highlighted: n == 1))
        rows.append(HexDecodedRow(label: "Int8", value: uint(1).map { Int8(bitPattern: UInt8($0)).formatted() } ?? need(1)))
        rows.append(HexDecodedRow(label: "UInt16 \(e)", value: uint(2).map { $0.formatted() } ?? need(2), highlighted: n == 2))
        rows.append(HexDecodedRow(label: "Int16 \(e)", value: uint(2).map { Int16(bitPattern: UInt16($0)).formatted() } ?? need(2)))
        let u32 = uint(4)
        let unix32 = u32.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let unixPlausible = unix32.map(isPlausible) ?? false
        rows.append(HexDecodedRow(label: "UInt32 \(e)", value: u32.map { $0.formatted() } ?? need(4), highlighted: n == 4 && !unixPlausible))
        rows.append(HexDecodedRow(label: "Int32 \(e)", value: u32.map { Int32(bitPattern: UInt32($0)).formatted() } ?? need(4)))
        let u64 = uint(8)
        let mac = u64.map { Double(bitPattern: $0) }
        let macDate = mac.flatMap { $0.isFinite ? Date(timeIntervalSinceReferenceDate: $0) : nil }
        let macPlausible = macDate.map(isPlausible) ?? false
        rows.append(HexDecodedRow(label: "UInt64 \(e)", value: u64.map { $0.formatted() } ?? need(8)))
        rows.append(HexDecodedRow(label: "Int64 \(e)", value: u64.map { Int64(bitPattern: $0).formatted() } ?? need(8),
                                  highlighted: n == 8 && !macPlausible))
        rows.append(HexDecodedRow(label: "Float32 \(e)", value: u32.map { float(Double(Float(bitPattern: UInt32($0)))) } ?? need(4)))
        rows.append(HexDecodedRow(label: "Float64 \(e)", value: mac.map(float) ?? need(8)))
        rows.append(HexDecodedRow(label: String(localized: "Unix time (UInt32)", bundle: .previewKit, comment: "Decoding drawer row: four bytes read as a Unix timestamp. Keep “UInt32”."), value: unix32.map(date) ?? need(4), highlighted: n == 4 && unixPlausible))
        rows.append(HexDecodedRow(label: String(localized: "Unix time (Int64)", bundle: .previewKit, comment: "Decoding drawer row: eight bytes read as a Unix timestamp. Keep “Int64”."), value: u64.map { seconds -> String in
            let s = Int64(bitPattern: seconds)
            // Beyond ±10,000 years a Date is meaningless; say so instead of printing nonsense.
            guard abs(s) < 315_000_000_000 else { return Self.outOfRange }
            return date(Date(timeIntervalSince1970: TimeInterval(s)))
        } ?? need(8)))
        rows.append(HexDecodedRow(label: String(localized: "Mac absolute time (Float64)", bundle: .previewKit, comment: "Decoding drawer row: eight bytes read as a Mac absolute time. Keep “Float64”."),
                                  value: mac == nil ? need(8) : macDate.map { abs($0.timeIntervalSinceReferenceDate) < 315_000_000_000 ? date($0) : Self.outOfRange }
                                      ?? String(localized: "not a number", bundle: .previewKit, comment: "Decoding drawer value: the bytes are not a finite number."),
                                  highlighted: n == 8 && macPlausible))
        rows.append(HexDecodedRow(label: String(localized: "Four-character code", bundle: .previewKit, comment: "Decoding drawer row: four bytes read as a four-character code (like 'ftyp')."), value: fourCC(bytes)))
        rows.append(HexDecodedRow(label: "UTF-8", value: utf8(bytes, limit: max(n, 32))))
        rows.append(HexDecodedRow(label: "UTF-16 \(e)", value: utf16(bytes, limit: max(n, 32), endian: endian)))
        return rows
    }

    /// "needs 4 bytes": a reading that has too few bytes after the cursor.
    static func needs(_ n: Int) -> String {
        let count = n.formatted()
        return n == 1
            ? String(localized: "needs \(count) byte", bundle: .previewKit, comment: "Decoding drawer value: this reading needs one byte after the cursor.")
            : String(localized: "needs \(count) bytes", bundle: .previewKit, comment: "Decoding drawer value: this reading needs more bytes than remain after the cursor; the argument is how many.")
    }

    static let outOfRange = String(localized: "out of range", bundle: .previewKit, comment: "Decoding drawer value: the number is too large to be a date.")
    static let notText = String(localized: "not valid text", bundle: .previewKit, comment: "Decoding drawer value: the bytes are not valid text in this encoding.")

    static func binary(_ b: UInt8) -> String {
        let s = String(b, radix: 2)
        return String(repeating: "0", count: 8 - s.count) + s
    }

    /// Dates between 1990 and 2100 are what a timestamp in a file most likely is.
    static func isPlausible(_ d: Date) -> Bool {
        d.timeIntervalSince1970 >= 631_152_000 && d.timeIntervalSince1970 < 4_102_444_800
    }

    /// "21 Oct 2026, 09:14:03 UTC": one fixed form, so a date in a file reads the same on every Mac.
    static func date(_ d: Date) -> String {
        let style = Date.VerbatimFormatStyle(
            format: "\(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits), \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
            locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt, calendar: Calendar(identifier: .gregorian))
        return d.formatted(style) + " UTC"
    }

    static func float(_ x: Double) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x < 0 ? "-∞" : "∞" }
        if x == 0 { return x.sign == .minus ? "-0" : "0" }
        let a = abs(x)
        if a >= 1e-4 && a < 1e9 { return x.formatted(.number.precision(.significantDigits(1...7))) }
        return x.formatted(.number.notation(.scientific).precision(.significantDigits(1...4)))
    }

    /// Four printable ASCII bytes, in file order: 'ftyp'.
    static func fourCC(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 4 else { return needs(4) }
        let four = bytes[0..<4]
        guard four.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else {
            return String(localized: "not printable", bundle: .previewKit, comment: "Decoding drawer value: the four bytes are not printable characters.")
        }
        return "'" + String(decoding: four, as: UTF8.self) + "'"
    }

    /// The longest run of valid, printable UTF-8 from the cursor, up to `limit` bytes.
    static func utf8(_ bytes: [UInt8], limit: Int) -> String {
        let window = Array(bytes.prefix(limit))
        var end = window.count
        while end > 0 {
            if let s = String(validating: window[0..<end], as: UTF8.self) {
                return show(s, cut: end < window.count || bytes.count > limit)
            }
            end -= 1
        }
        return notText
    }

    static func utf16(_ bytes: [UInt8], limit: Int, endian: HexEndian) -> String {
        let window = Array(bytes.prefix(limit))
        var units: [UInt16] = []
        var i = 0
        while i + 1 < window.count {
            let a = UInt16(window[i]), b = UInt16(window[i + 1])
            units.append(endian == .little ? b << 8 | a : a << 8 | b)
            i += 2
        }
        var end = units.count
        while end > 0 {
            if let s = String(validating: units[0..<end], as: UTF16.self) { return show(s, cut: end < units.count || bytes.count > limit) }
            end -= 1
        }
        return notText
    }

    /// Text as the drawer shows it: control characters escaped; nothing printable at all reads as not text.
    static func show(_ s: String, cut: Bool) -> String {
        var out = ""
        var printable = 0
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\0": out += "\\0"
            default:
                if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .unassigned {
                    out += "\\u{\(String(scalar.value, radix: 16))}"
                } else {
                    out.unicodeScalars.append(scalar)
                    printable += 1
                }
            }
        }
        guard printable > 0 else { return notText }
        return "\"" + out + "\"" + (cut ? "…" : "")
    }
}
