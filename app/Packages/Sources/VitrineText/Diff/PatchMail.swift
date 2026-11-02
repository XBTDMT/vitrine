import Foundation

/// The email side of `git format-patch`: header values (RFC 2047 encoded words, folding), transfer encodings, the
/// `[PATCH 2/5]` subject prefix and the dates git and mail write. All input is untrusted text from the patch.
enum PatchMail {
    /// `Name: value` with an RFC 5322 field name (printable ASCII, no colon, no space).
    static func headerField(_ line: String) -> (name: String, value: String)? {
        guard let colon = line.firstIndex(of: ":"), colon > line.startIndex else { return nil }
        let name = line[..<colon]
        guard name.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { return nil }
        return (String(name), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// Decodes `=?charset?Q?…?=` and `=?charset?B?…?=` words. Whitespace between two encoded words is dropped, as
    /// RFC 2047 §6.2 says; anything malformed is left exactly as written.
    static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        var out = ""
        var rest = Substring(value)
        var lastWasEncoded = false
        while !rest.isEmpty {
            guard let start = rest.range(of: "=?") else { out += rest; break }
            let before = rest[..<start.lowerBound]
            if let decoded = decodeWord(rest[start.lowerBound...]) {
                if !(lastWasEncoded && before.allSatisfy({ $0 == " " || $0 == "\t" })) { out += before }
                out += decoded.text
                rest = decoded.rest
                lastWasEncoded = true
            } else {
                out += before + "=?"
                rest = rest[start.upperBound...]
                lastWasEncoded = false
            }
        }
        return out
    }

    private static func decodeWord(_ s: Substring) -> (text: String, rest: Substring)? {
        // =?charset?enc?text?=
        let parts = s.dropFirst(2)
        guard let q1 = parts.firstIndex(of: "?") else { return nil }
        let charset = parts[..<q1]
        let afterCharset = parts[parts.index(after: q1)...]
        guard let q2 = afterCharset.firstIndex(of: "?") else { return nil }
        let encoding = afterCharset[..<q2].uppercased()
        let payloadStart = afterCharset.index(after: q2)
        guard let end = afterCharset[payloadStart...].range(of: "?=") else { return nil }
        let payload = afterCharset[payloadStart..<end.lowerBound]
        guard charset.count <= 40, !charset.isEmpty else { return nil }
        let bytes: [UInt8]
        switch encoding {
        case "B":
            guard let data = Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters) else { return nil }
            bytes = [UInt8](data)
        case "Q":
            bytes = quotedPrintable(Array(payload.utf8), underscoreIsSpace: true)
        default:
            return nil
        }
        // The language suffix (`utf-8*en`) is not part of the charset name.
        let name = charset.split(separator: "*", maxSplits: 1).first.map(String.init) ?? String(charset)
        return (decode(bytes, charset: name), afterCharset[end.upperBound...])
    }

    /// Bytes in a named charset; UTF-8 when the name is unknown or the bytes do not fit it, Latin-1 last, so the
    /// result is always a string.
    static func decode(_ bytes: [UInt8], charset: String) -> String {
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cf != kCFStringEncodingInvalidId {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            if let s = String(bytes: bytes, encoding: encoding) { return s }
        }
        if let s = String(validating: bytes, as: UTF8.self) { return s }
        return String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    /// Quoted-printable (RFC 2045 §6.7): `=XX` is a byte, `=` at a line end is a soft break. A bad escape stays as
    /// written.
    static func quotedPrintable(_ input: [UInt8], underscoreIsSpace: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        while i < input.count {
            let b = input[i]
            if b == 0x3D {                                   // "="
                if i + 1 < input.count, input[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < input.count, input[i + 1] == 0x0D, input[i + 2] == 0x0A { i += 3; continue }
                if i + 2 < input.count, let h = hex(input[i + 1]), let l = hex(input[i + 2]) {
                    out.append(h << 4 | l); i += 3; continue
                }
            }
            out.append(underscoreIsSpace && b == 0x5F ? 0x20 : b)
            i += 1
        }
        return out
    }

    /// `Dana Reyes <dana@example.com>` → name and address; a bare address or a bare name is kept as it is.
    static func splitAuthor(_ value: String) -> (name: String?, email: String?) {
        let v = value.trimmingCharacters(in: .whitespaces)
        if let lt = v.lastIndex(of: "<"), let gt = v.lastIndex(of: ">"), lt < gt {
            var name = v[..<lt].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            let email = String(v[v.index(after: lt)..<gt])
            return (name.isEmpty ? nil : name, email.isEmpty ? nil : email)
        }
        if v.contains("@"), !v.contains(" ") { return (nil, v) }
        return (v.isEmpty ? nil : v, nil)
    }

    /// Strips git's leading bracket groups (`[PATCH v2 2/5]`, `[RFC]`) and `Re:`, as `git am` does, keeping the
    /// first group and the series position it names.
    static func splitSubject(_ raw: String) -> (subject: String, prefix: String?, index: Int?, total: Int?) {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        var groups: [Substring] = []
        while true {
            if s.lowercased().hasPrefix("re:") { s = s.dropFirst(3).drop { $0 == " " }; continue }
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { break }
            groups.append(s[...close])
            s = s[s.index(after: close)...].drop { $0 == " " }
        }
        var index: Int?, total: Int?
        if let first = groups.first {
            for token in first.dropFirst().dropLast().split(separator: " ") {
                let pair = token.split(separator: "/")
                if pair.count == 2, let a = Int(pair[0]), let b = Int(pair[1]), a >= 0, b > 0, b < 100_000 {
                    index = a; total = b
                }
            }
        }
        return (String(s), groups.isEmpty ? nil : groups.joined(separator: " "), index, total)
    }

    /// Dates as RFC 2822 mail (`Mon, 27 Oct 2026 10:00:00 +0100`) and as `git log` writes them
    /// (`Mon Oct 27 10:00:00 2026 +0100`), plus ISO 8601 (`--date=iso-strict`).
    static func parseDate(_ text: String) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count < 80 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE MMM d HH:mm:ss yyyy Z",
                       "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            formatter.dateFormat = format
            if let d = formatter.date(from: t) { return d }
        }
        // RFC 2822 allows a trailing comment: `+0100 (CET)`.
        if let paren = t.firstIndex(of: "("), paren > t.startIndex {
            return parseDate(String(t[..<paren]))
        }
        return nil
    }

    static func isHex(_ s: Substring, length: ClosedRange<Int>) -> Bool {
        length.contains(s.count) && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) }
    }
}
