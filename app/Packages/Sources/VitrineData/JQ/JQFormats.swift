import Foundation

/// jq's `@format` strings (`@text @json @csv @tsv @html @uri @sh @base64 @base64d @base32 @base32d`), `tostring` and
/// `tojson`. roadmap: S-5
enum JQFormats {
    static func toJSON(_ value: JQValue, _ interp: JQInterpreter) throws -> String {
        guard let text = JQJSONWriter.compact(value, budget: interp.limits.maxResultBytes) else {
            throw JQStop(reason: "a string grew past the result size limit of \(interp.limits.maxResultBytes) bytes")
        }
        return text
    }

    static func toString(_ value: JQValue, _ interp: JQInterpreter) throws -> String {
        if case .string(let s) = value { return s }
        return try toJSON(value, interp)
    }

    static func apply(_ name: String, _ value: JQValue, _ interp: JQInterpreter) throws -> String {
        switch name {
        case "text": return try toString(value, interp)
        case "json": return try toJSON(value, interp)
        case "html": return html(try toString(value, interp))
        case "uri": return uri(try toString(value, interp))
        case "csv": return try csv(value, interp, separator: ",", name: "csv")
        case "tsv": return try csv(value, interp, separator: "\t", name: "tsv")
        case "sh": return try shell(value, interp)
        case "base64": return Data(try toString(value, interp).utf8).base64EncodedString()
        case "base64d": return try base64Decode(try toString(value, interp), original: value)
        case "base32": return base32(Array(try toString(value, interp).utf8))
        case "base32d": return try base32Decode(try toString(value, interp), original: value)
        default: throw JQThrown("\(name) is not a valid format")
        }
    }

    static func html(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "&": out += "&amp;"
            case "'": out += "&#39;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func uri(_ s: String) -> String {
        var out = ""
        let hex = Array("0123456789ABCDEF")
        for byte in s.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out.append("%")
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0xF)])
            }
        }
        return out
    }

    static func csv(_ value: JQValue, _ interp: JQInterpreter, separator: String, name: String) throws -> String {
        guard case .array(let items) = value else {
            throw JQThrown("\(JQOps.described(value)) cannot be \(name)-formatted, only an array can be")
        }
        var fields: [String] = []
        fields.reserveCapacity(items.count)
        for item in items {
            switch item {
            case .null: fields.append("")
            case .bool(let b): fields.append(b ? "true" : "false")
            case .number(let d): fields.append(JQNumberFormat.format(d))
            case .string(let s):
                if name == "csv" {
                    fields.append("\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
                } else {
                    var escaped = ""
                    for scalar in s.unicodeScalars {
                        switch scalar {
                        case "\\": escaped += "\\\\"
                        case "\t": escaped += "\\t"
                        case "\n": escaped += "\\n"
                        case "\r": escaped += "\\r"
                        default: escaped.unicodeScalars.append(scalar)
                        }
                    }
                    fields.append(escaped)
                }
            case .array, .object:
                throw JQThrown("\(JQOps.described(item)) is not valid in a \(name) row")
            }
        }
        let text = fields.joined(separator: separator)
        try interp.checkStringSize(text.utf8.count)
        return text
    }

    static func shell(_ value: JQValue, _ interp: JQInterpreter) throws -> String {
        func quote(_ item: JQValue) throws -> String {
            switch item {
            case .string(let s): return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
            case .array, .object: throw JQThrown("\(JQOps.described(item)) can not be escaped for shell")
            default: return try toJSON(item, interp)
            }
        }
        if case .array(let items) = value {
            return try items.map(quote).joined(separator: " ")
        }
        return try quote(value)
    }

    static func base64Decode(_ s: String, original: JQValue) throws -> String {
        var text = s.filter { !$0.isWhitespace }
        while text.hasSuffix("=") { text.removeLast() }
        let remainder = text.utf8.count % 4
        if remainder == 1 { throw JQThrown("\(JQOps.described(original)) is not valid base64 data") }
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: text) else {
            throw JQThrown("\(JQOps.described(original)) is not valid base64 data")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    static func base32(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let chunk = Array(bytes[i..<min(i + 5, bytes.count)])
            var buffer = [UInt8](repeating: 0, count: 5)
            for (j, b) in chunk.enumerated() { buffer[j] = b }
            let bits = buffer.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let produced = [0, 2, 4, 5, 7, 8][chunk.count]
            for k in 0..<8 {
                if k < produced {
                    out.append(base32Alphabet[Int((bits >> UInt64(35 - 5 * k)) & 31)])
                } else {
                    out.append(UInt8(ascii: "="))
                }
            }
            i += 5
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func base32Decode(_ s: String, original: JQValue) throws -> String {
        var bits: UInt64 = 0
        var count = 0
        var out: [UInt8] = []
        for byte in s.utf8 {
            if byte == UInt8(ascii: "=") { break }
            guard let v = base32Alphabet.firstIndex(of: byte) else {
                throw JQThrown("\(JQOps.described(original)) is not valid base32 data")
            }
            bits = (bits << 5) | UInt64(v)
            count += 5
            if count >= 8 {
                count -= 8
                out.append(UInt8((bits >> UInt64(count)) & 0xFF))
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// jq's UTC date functions: `gmtime`, `mktime`, `strftime`, `strptime` (and, in jq, `todate`/`fromdate` on top).
/// Always UTC and the C locale, so results never depend on the Mac's clock, zone or language. roadmap: S-5
enum JQDates {
    static func gmtime(_ value: JQValue) throws -> JQValue {
        guard case .number(let d) = value else { throw JQThrown("gmtime() requires a number") }
        guard d.isFinite, abs(d) < 1e15 else { throw JQThrown("gmtime() requires a finite number of seconds") }
        let seconds = d.rounded(.down)
        var t = time_t(seconds)
        var parts = tm()
        guard gmtime_r(&t, &parts) != nil else { throw JQThrown("error converting number of seconds since epoch to datetime") }
        return .array([
            .number(Double(parts.tm_year) + 1900), .number(Double(parts.tm_mon)), .number(Double(parts.tm_mday)),
            .number(Double(parts.tm_hour)), .number(Double(parts.tm_min)), .number(Double(parts.tm_sec) + (d - seconds)),
            .number(Double(parts.tm_wday)), .number(Double(parts.tm_yday)),
        ])
    }

    static func brokenDown(_ value: JQValue, _ function: String) throws -> tm {
        guard case .array(let items) = value, items.count >= 6 else {
            throw JQThrown("\(function) requires array of 6 numbers")
        }
        var numbers: [Double] = []
        for item in items {
            guard case .number(let d) = item, d.isFinite, abs(d) < 1e12 else {
                throw JQThrown("\(function) requires parsed datetime inputs")
            }
            numbers.append(d)
        }
        var parts = tm()
        parts.tm_year = Int32(numbers[0] - 1900)
        parts.tm_mon = Int32(numbers[1])
        parts.tm_mday = Int32(numbers[2])
        parts.tm_hour = Int32(numbers[3])
        parts.tm_min = Int32(numbers[4])
        parts.tm_sec = Int32(numbers[5].rounded(.down))
        if numbers.count > 6 { parts.tm_wday = Int32(numbers[6]) }
        if numbers.count > 7 { parts.tm_yday = Int32(numbers[7]) }
        return parts
    }

    static func mktime(_ value: JQValue) throws -> JQValue {
        guard case .array = value else { throw JQThrown("mktime requires array of 6 numbers") }
        var parts = try brokenDown(value, "mktime")
        let t = timegm(&parts)
        return .number(Double(t))
    }
}
