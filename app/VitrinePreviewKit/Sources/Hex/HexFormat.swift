import Foundation

/// A run of printable ASCII in the file ("notes/inbox" at 0x20): the drawer's Text runs and the Strings view.
/// roadmap: S-5
public struct HexTextRun: Sendable, Equatable {
    public var offset: Int64
    public var length: Int
    public var text: String
}

/// The hex inspector's words and text forms: offsets ("0x0C"), the gutter's selection line, the text runs, a
/// classic hex dump, and the Copy-as formats (hex, C array, Base64, raw text). Pure, so tests read them directly.
/// roadmap: S-5
public enum HexFormat {
    /// Runs shorter than this are not text worth naming.
    public static let minimumRun = 4

    /// "0x0C", "0x1F40": upper case, at least two digits.
    public static func offset(_ n: Int64) -> String {
        let s = String(n, radix: 16, uppercase: true)
        return "0x" + (s.count < 2 ? "0" + s : s)
    }

    /// The offset column: "0000001F", as wide as the file needs and never under eight digits.
    static func column(_ n: Int64, digits: Int) -> String {
        let s = String(n, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }

    static func digits(forSize size: Int64) -> Int { max(8, String(max(0, size - 1), radix: 16).count) }

    /// The gutter: "Offset 0x0C · 1 byte selected", "Offset 0x0C–0x0F · 4 bytes selected".
    public static func selection(_ range: ClosedRange<Int64>) -> String {
        let n = range.upperBound - range.lowerBound + 1
        let from = offset(range.lowerBound), to = offset(range.upperBound), count = n.formatted()
        return n == 1
            ? String(localized: "Offset \(from) · \(count) byte selected", bundle: .previewKit, comment: "Status line: one selected byte. Arguments: its offset (hex), the count.")
            : String(localized: "Offset \(from)–\(to) · \(count) bytes selected", bundle: .previewKit, comment: "Status line: the selected bytes. Arguments: first offset, last offset (hex), the count.")
    }

    static func isPrintable(_ b: UInt8) -> Bool { b >= 0x20 && b < 0x7F }

    /// Printable runs of at least `minimumRun` bytes in `bytes`, which start at `base`; at most `limit`.
    public static func runs(in bytes: [UInt8], base: Int64 = 0, limit: Int = .max) -> [HexTextRun] {
        var out: [HexTextRun] = []
        var start: Int?
        func close(_ end: Int) {
            if let s = start, end - s >= minimumRun, out.count < limit {
                out.append(HexTextRun(offset: base + Int64(s), length: end - s, text: String(decoding: bytes[s..<end], as: UTF8.self)))
            }
            start = nil
        }
        for (i, b) in bytes.enumerated() {
            if isPrintable(b) { if start == nil { start = i } } else { close(i) }
            if out.count >= limit { return out }
        }
        close(bytes.count)
        return out
    }

    /// Which bytes of `bytes` sit in a printable run of at least `minimumRun`. The caller hands three bytes of
    /// context on either side so a run crossing the edge is still measured.
    static func inRun(_ bytes: [UInt8]) -> [Bool] {
        var flags = [Bool](repeating: false, count: bytes.count)
        var i = 0
        while i < bytes.count {
            guard isPrintable(bytes[i]) else { i += 1; continue }
            var j = i
            while j < bytes.count, isPrintable(bytes[j]) { j += 1 }
            if j - i >= minimumRun { for k in i..<j { flags[k] = true } }
            i = j
        }
        return flags
    }

    /// Shannon entropy in bits per byte (0 to 8); nil under 256 bytes, too few to say.
    public static func entropy(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 256 else { return nil }
        var counts = [Int](repeating: 0, count: 256)
        for b in bytes { counts[Int(b)] += 1 }
        let n = Double(bytes.count)
        return counts.reduce(0.0) { sum, c in c == 0 ? sum : sum - Double(c) / n * log2(Double(c) / n) }
    }

    // MARK: Text forms

    /// `00000000  41 43 4D 45 50 4B 47 31  01 00 00 00 5B 82 D8 6A  |ACMEPKG1....[..j|`, sixteen bytes a line.
    public static func dump(_ bytes: [UInt8], base: Int64 = 0, digits: Int = 8) -> String {
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 1)
        var i = 0
        while i < bytes.count {
            let row = bytes[i..<min(bytes.count, i + 16)]
            var hex = ""
            for (k, b) in row.enumerated() {
                if k == 8 { hex += " " }
                hex += hexByte(b) + " "
            }
            let width = 16 * 3 + 1
            hex += String(repeating: " ", count: max(0, width - hex.count))
            let ascii = String(row.map { isPrintable($0) ? Character(UnicodeScalar($0)) : "." })
            lines.append("\(column(base + Int64(i), digits: digits))  \(hex) |\(ascii)|")
            i += 16
        }
        return lines.joined(separator: "\n")
    }

    static let hexDigits = Array("0123456789ABCDEF")
    static func hexByte(_ b: UInt8) -> String { String([hexDigits[Int(b >> 4)], hexDigits[Int(b & 0xF)]]) }

    /// "DE AD BE EF", sixteen bytes a line.
    public static func hex(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: bytes.count, by: 16).map { i in
            bytes[i..<min(bytes.count, i + 16)].map(hexByte).joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// `const unsigned char bytes[4] = { 0xDE, 0xAD, 0xBE, 0xEF };`, twelve bytes a line.
    public static func cArray(_ bytes: [UInt8], name: String = "bytes") -> String {
        let body = stride(from: 0, to: bytes.count, by: 12).map { i in
            "    " + bytes[i..<min(bytes.count, i + 12)].map { "0x" + hexByte($0) }.joined(separator: ", ")
        }.joined(separator: ",\n")
        return "const unsigned char \(name)[\(bytes.count)] = {\n\(body)\n};"
    }

    public static func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

    /// The bytes as UTF-8, invalid sequences replaced, NUL bytes dropped so the text pastes cleanly.
    public static func rawText(_ bytes: [UInt8]) -> String { String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self) }

    /// The Strings view: one run a line with its offset.
    static func strings(_ runs: [HexTextRun], scanned: Int64, total: Int64, digits: Int) -> String {
        let first = ByteCountFormatter.string(fromByteCount: scanned, countStyle: .file)
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let least = minimumRun.formatted(), count = runs.count.formatted()
        let head: String
        switch (scanned < total, runs.count) {
        case (true, 0): head = String(localized: "No text runs of \(least) or more printable characters in the first \(first) of \(size).", bundle: .previewKit, comment: "Strings view heading: none found in the part of the file read. Arguments: minimum run length, size read, file size.")
        case (true, 1): head = String(localized: "\(count) text run of \(least) or more printable characters in the first \(first) of \(size):", bundle: .previewKit, comment: "Strings view heading: one run found in the part read. Arguments: count, minimum run length, size read, file size.")
        case (true, _): head = String(localized: "\(count) text runs of \(least) or more printable characters in the first \(first) of \(size):", bundle: .previewKit, comment: "Strings view heading: runs found in the part read. Arguments: count, minimum run length, size read, file size.")
        case (false, 0): head = String(localized: "No text runs of \(least) or more printable characters in the file.", bundle: .previewKit, comment: "Strings view heading: none found. The argument is the minimum run length.")
        case (false, 1): head = String(localized: "\(count) text run of \(least) or more printable characters in the file:", bundle: .previewKit, comment: "Strings view heading: one run found. Arguments: count, minimum run length.")
        case (false, _): head = String(localized: "\(count) text runs of \(least) or more printable characters in the file:", bundle: .previewKit, comment: "Strings view heading: runs found. Arguments: count, minimum run length.")
        }
        return ([head, ""] + runs.map { "\(column($0.offset, digits: digits))  \($0.text)" }).joined(separator: "\n")
    }
}
