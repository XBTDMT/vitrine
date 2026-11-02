import Foundation

/// `strftime` and `strptime` in the C locale and UTC, written out in Swift so no setting of the Mac (language,
/// region, time zone) changes a result. Directives: a A b B c C d D e F g G h H I j k l m M n p r R s S t T u U V w W
/// x X y Y z Z %. roadmap: S-5
extension JQDates {
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                         "November", "December"]

    private static func pad(_ n: Int, _ width: Int, _ fill: Character = "0") -> String {
        let digits = String(abs(n))
        let padded = digits.count < width ? String(repeating: fill, count: width - digits.count) + digits : digits
        return n < 0 ? "-" + padded : padded
    }

    /// ISO 8601 week-based year and week number.
    private static func isoWeek(year: Int, yday: Int, wday: Int) -> (Int, Int) {
        func p(_ y: Int) -> Int { (y + y / 4 - y / 100 + y / 400) % 7 }
        func weeks(_ y: Int) -> Int { p(y) == 4 || p(y - 1) == 3 ? 53 : 52 }
        let isoWeekday = wday == 0 ? 7 : wday
        let week = (yday + 1 - isoWeekday + 10) / 7
        if week < 1 { return (year - 1, weeks(year - 1)) }
        if week > weeks(year) { return (year + 1, 1) }
        return (year, week)
    }

    static func strftime(_ value: JQValue, _ format: JQValue) throws -> JQValue {
        guard case .string(let fmt) = format else { throw JQThrown("strftime/1 requires a string format") }
        var input = value
        if case .number = value { input = try gmtime(value) }
        guard case .array = input else { throw JQThrown("strftime/1 requires parsed datetime inputs") }
        let parts = try brokenDown(input, "strftime/1")
        var copy = parts
        let epoch = Int(timegm(&copy))
        return .string(try render(fmt, parts, epoch: epoch))
    }

    private static func render(_ fmt: String, _ t: tm, epoch: Int) throws -> String {
        let year = Int(t.tm_year) + 1900, mon = Int(t.tm_mon), mday = Int(t.tm_mday)
        let hour = Int(t.tm_hour), minute = Int(t.tm_min), sec = Int(t.tm_sec)
        let wday = ((Int(t.tm_wday) % 7) + 7) % 7, yday = Int(t.tm_yday)
        let monthName = (0..<12).contains(mon) ? months[mon] : "?"
        var out = ""
        var chars = fmt.makeIterator()
        while let c = chars.next() {
            guard c == "%" else { out.append(c); continue }
            guard let d = chars.next() else { out.append("%"); break }
            switch d {
            case "a": out += String(weekdays[wday].prefix(3))
            case "A": out += weekdays[wday]
            case "b", "h": out += String(monthName.prefix(3))
            case "B": out += monthName
            case "c": out += try render("%a %b %e %H:%M:%S %Y", t, epoch: epoch)
            case "C": out += pad(year / 100, 2)
            case "d": out += pad(mday, 2)
            case "D", "x": out += try render("%m/%d/%y", t, epoch: epoch)
            case "e": out += pad(mday, 2, " ")
            case "F": out += try render("%Y-%m-%d", t, epoch: epoch)
            case "g": out += pad(isoWeek(year: year, yday: yday, wday: wday).0 % 100, 2)
            case "G": out += String(isoWeek(year: year, yday: yday, wday: wday).0)
            case "H": out += pad(hour, 2)
            case "I": out += pad(hour % 12 == 0 ? 12 : hour % 12, 2)
            case "j": out += pad(yday + 1, 3)
            case "k": out += pad(hour, 2, " ")
            case "l": out += pad(hour % 12 == 0 ? 12 : hour % 12, 2, " ")
            case "m": out += pad(mon + 1, 2)
            case "M": out += pad(minute, 2)
            case "n": out += "\n"
            case "p": out += hour < 12 ? "AM" : "PM"
            case "r": out += try render("%I:%M:%S %p", t, epoch: epoch)
            case "R": out += try render("%H:%M", t, epoch: epoch)
            case "s": out += String(epoch)
            case "S": out += pad(sec, 2)
            case "t": out += "\t"
            case "T", "X": out += try render("%H:%M:%S", t, epoch: epoch)
            case "u": out += String(wday == 0 ? 7 : wday)
            case "U": out += pad((yday + 7 - wday) / 7, 2)
            case "V": out += pad(isoWeek(year: year, yday: yday, wday: wday).1, 2)
            case "w": out += String(wday)
            case "W": out += pad((yday + 7 - (wday + 6) % 7) / 7, 2)
            case "y": out += pad(((year % 100) + 100) % 100, 2)
            case "Y": out += String(year)
            case "z": out += "+0000"
            case "Z": out += "UTC"
            case "%": out += "%"
            default: throw JQThrown("strftime/1: the directive %\(d) is not supported in Vitrine")
            }
        }
        return out
    }

    /// The same directives as `strftime`; names match in either case and abbreviated; whitespace in the format
    /// matches any run of whitespace; `%z` and `%Z` are read and ignored, as jq's `mktime` ignores them.
    static func strptime(_ value: JQValue, _ format: JQValue) throws -> JQValue {
        guard case .string(let text) = value, case .string(let fmt) = format else {
            throw JQThrown("strptime/1 requires string inputs and arguments")
        }
        var reader = DateReader(input: Array(text.unicodeScalars)[...],
                                failure: JQThrown("date \"\(text)\" does not match format \"\(fmt)\""))
        try reader.parse(fmt)
        guard reader.input.isEmpty else { throw reader.failure }
        var parts = tm()
        if let epoch = reader.epoch {
            var t = time_t(epoch)
            guard gmtime_r(&t, &parts) != nil else { throw reader.failure }
        } else {
            parts.tm_year = Int32(clamping: reader.year - 1900)
            parts.tm_mon = Int32(clamping: reader.month)
            parts.tm_mday = Int32(clamping: reader.day)
            parts.tm_hour = Int32(clamping: reader.hour + (reader.pm == true ? 12 : 0))
            parts.tm_min = Int32(clamping: reader.minute)
            parts.tm_sec = Int32(clamping: reader.second)
            // Fill in the weekday and day of the year from the date, as jq does.
            var copy = parts
            var t = timegm(&copy)
            var normalized = tm()
            if gmtime_r(&t, &normalized) != nil {
                parts.tm_wday = normalized.tm_wday
                parts.tm_yday = reader.yearDay.map { Int32(clamping: $0) } ?? normalized.tm_yday
            }
        }
        return .array([
            .number(Double(parts.tm_year) + 1900), .number(Double(parts.tm_mon)), .number(Double(parts.tm_mday)),
            .number(Double(parts.tm_hour)), .number(Double(parts.tm_min)), .number(Double(parts.tm_sec)),
            .number(Double(parts.tm_wday)), .number(Double(parts.tm_yday)),
        ])
    }

    private struct DateReader {
        var input: ArraySlice<Unicode.Scalar>
        let failure: JQThrown
        var year = 1900, month = 0, day = 1, hour = 0, minute = 0, second = 0
        var yearDay: Int?
        var epoch: Int?
        var pm: Bool?

        mutating func skipSpace() {
            while let f = input.first, f.properties.isWhitespace { input = input.dropFirst() }
        }

        mutating func number(_ maxDigits: Int, signed: Bool = false) throws -> Int {
            skipSpace()
            var negative = false
            if signed, let f = input.first, f == "-" || f == "+" {
                negative = f == "-"
                input = input.dropFirst()
            }
            var digits = 0, v = 0
            while digits < maxDigits, let f = input.first, f.value >= 48, f.value <= 57 {
                v = v * 10 + Int(f.value - 48)
                digits += 1
                input = input.dropFirst()
            }
            guard digits > 0 else { throw failure }
            return negative ? -v : v
        }

        mutating func name(_ names: [String]) throws -> Int {
            let rest = String(String.UnicodeScalarView(input)).lowercased()
            for (i, full) in names.enumerated() {
                for candidate in [full.lowercased(), String(full.prefix(3)).lowercased()] where rest.hasPrefix(candidate) {
                    input = input.dropFirst(candidate.unicodeScalars.count)
                    return i
                }
            }
            throw failure
        }

        mutating func parse(_ fmt: String) throws {
            var chars = fmt.unicodeScalars.makeIterator()
            while let c = chars.next() {
                if c.properties.isWhitespace { skipSpace(); continue }
                guard c == "%" else {
                    guard input.first == c else { throw failure }
                    input = input.dropFirst()
                    continue
                }
                guard let d = chars.next() else { throw failure }
                switch d {
                case "a", "A": _ = try name(JQDates.weekdays)
                case "b", "B", "h": month = try name(JQDates.months)
                case "c": try parse("%a %b %e %H:%M:%S %Y")
                case "C": year = try number(2) * 100 + year % 100
                case "d", "e": day = try number(2)
                case "D", "x": try parse("%m/%d/%y")
                case "F": try parse("%Y-%m-%d")
                case "H", "k": hour = try number(2)
                case "I", "l": hour = try number(2) % 12
                case "j": yearDay = try number(3) - 1
                case "m": month = try number(2) - 1
                case "M": minute = try number(2)
                case "n", "t": skipSpace()
                case "p":
                    let rest = String(String.UnicodeScalarView(input)).uppercased()
                    if rest.hasPrefix("AM") { pm = false } else if rest.hasPrefix("PM") { pm = true } else { throw failure }
                    input = input.dropFirst(2)
                case "r": try parse("%I:%M:%S %p")
                case "R": try parse("%H:%M")
                case "s": epoch = try number(20, signed: true)
                case "S": second = try number(2)
                case "T", "X": try parse("%H:%M:%S")
                case "y":
                    let y = try number(2)
                    year = y < 69 ? 2000 + y : 1900 + y
                case "Y": year = try number(6, signed: true)
                case "z":
                    skipSpace()
                    if input.first == "Z" { input = input.dropFirst() } else { _ = try number(4, signed: true) }
                case "Z":
                    while let f = input.first, f.properties.isAlphabetic { input = input.dropFirst() }
                case "%":
                    guard input.first == "%" else { throw failure }
                    input = input.dropFirst()
                default:
                    throw JQThrown("strptime/1: the directive %\(d) is not supported in Vitrine")
                }
            }
        }
    }
}
