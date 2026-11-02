// VitrineDetect — the seven validators of DETECTORS.md §5. Each receives the folded secret text and returns
// `pass` or `reject(code)`; the code is a short identifier safe for logs, never the text.
public import Foundation

public enum ValidationResult: Equatable, Sendable {
    case pass
    /// `subkind` is an annotation for the label (only `awsKeyIdPrefix` sets it).
    case passAnnotated(subkind: String)
    case reject(code: String)

    public var passes: Bool {
        if case .reject = self { return false }
        return true
    }
}

public enum Validators {
    public static func run(_ validator: Validator, on text: String) -> ValidationResult {
        switch validator {
        case .none: return .pass
        case .luhn: return luhn(text)
        case .ibanMod97: return ibanMod97(text)
        case .entropy(let min): return entropy(text, min: min)
        case .jwt: return jwt(text)
        case .githubChecksum: return githubChecksum(text)
        case .awsKeyIdPrefix: return awsKeyIdPrefix(text)
        case .phoneShape(let lo, let hi): return phoneShape(text, minDigits: lo, maxDigits: hi)
        }
    }

    // MARK: §5.1 Luhn

    public static func luhn(_ text: String) -> ValidationResult {
        let digits = text.compactMap { $0.wholeNumberValue }.filter { $0 >= 0 && $0 <= 9 }
        guard (13...19).contains(digits.count) else { return .reject(code: "luhn.length") }
        if Set(digits).count == 1 { return .reject(code: "luhn.repeated") }
        if isSequence(digits) { return .reject(code: "luhn.sequence") }
        var sum = 0
        for (offset, d) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0 ? .pass : .reject(code: "luhn.checksum")
    }

    /// True when the digits are a prefix of `0123456789…` or `1234567890…` repeated (rulers and test strings).
    static func isSequence(_ digits: [Int]) -> Bool {
        guard let first = digits.first, first == 0 || first == 1 else { return false }
        for (i, d) in digits.enumerated() where d != (first + i) % 10 { return false }
        return true
    }

    // MARK: §5.2 IBAN mod-97

    public static let ibanLengths: [String: Int] = [
        "DE": 22, "FR": 27, "GB": 22, "ES": 24, "IT": 27, "NL": 18, "BE": 16, "CH": 21, "AT": 20, "PT": 25,
        "PL": 28, "SE": 24, "NO": 15, "DK": 18, "FI": 18, "IE": 22, "LU": 20, "CZ": 24, "HU": 28, "RO": 24,
        "BG": 22, "HR": 21, "SK": 24, "SI": 19, "LT": 20, "LV": 21, "EE": 20, "GR": 27, "CY": 28, "MT": 31,
        "IS": 26, "LI": 21, "MC": 27, "SM": 27, "TR": 26, "SA": 24, "AE": 23, "QA": 29, "IL": 23, "BR": 29,
        "CR": 22, "GT": 28, "DO": 28, "PK": 24, "JO": 30, "KW": 30, "LB": 28, "MU": 30, "TN": 24, "UA": 29,
        "GE": 22, "AZ": 28, "KZ": 20, "BH": 22, "VG": 24, "GI": 23, "FO": 18, "GL": 18, "AL": 28, "AD": 24,
        "BA": 20, "MK": 19, "ME": 22, "RS": 22, "XK": 20, "MD": 24, "BY": 28, "EG": 29, "LY": 25, "IQ": 23,
        "SC": 31, "ST": 25, "TL": 23, "VA": 22, "SV": 28, "BI": 16, "DJ": 27, "RU": 33, "SD": 18, "SO": 23,
        "NI": 28, "OM": 23, "FK": 18, "MN": 20, "YE": 30, "HN": 28,
    ]

    public static func ibanMod97(_ text: String) -> ValidationResult {
        let compact = text.uppercased().filter { !$0.isWhitespace }
        guard compact.count >= 5 else { return .reject(code: "iban.length") }
        let country = String(compact.prefix(2))
        guard let expected = ibanLengths[country] else { return .reject(code: "iban.country") }
        guard compact.count == expected else { return .reject(code: "iban.length") }
        let rearranged = String(compact.dropFirst(4)) + String(compact.prefix(4))
        // Streaming mod 97: digits appended one at a time, letters as two digits (A=10 … Z=35).
        var remainder = 0
        for ch in rearranged {
            let value: Int
            if let d = ch.wholeNumberValue, ch.isASCII {
                value = d
            } else if let a = ch.asciiValue, a >= 65, a <= 90 {
                value = Int(a) - 55
            } else {
                return .reject(code: "iban.charset")
            }
            if value >= 10 {
                remainder = (remainder * 100 + value) % 97
            } else {
                remainder = (remainder * 10 + value) % 97
            }
        }
        return remainder == 1 ? .pass : .reject(code: "iban.checksum")
    }

    // MARK: §5.3 entropy

    /// Placeholder shapes that are never a secret; matched case-insensitively against the whole text.
    public static let placeholderPatterns: [String] = [
        "changeme", "password", "example", #"your[-_ ]?(?:key|token|secret)"#, "xxxx+", "<[^>]+>",
        #"\$\{[^}]+\}"#, "%[A-Z_]+%", "true|false|null|none|undefined",
    ]

    private static let placeholderRegex: NSRegularExpression = {
        let alternation = placeholderPatterns.map { "(?:\($0))" }.joined(separator: "|")
        // Force-unwrap is safe: the list is a compile-time constant covered by tests.
        return try! NSRegularExpression(pattern: "(?i)^(?:" + alternation + ")$", options: [])
    }()

    public static func isPlaceholder(_ text: String) -> Bool {
        placeholderRegex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }

    public static func shannonEntropy(_ text: String) -> Double {
        let chars = Array(text)
        guard !chars.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in chars { counts[c, default: 0] += 1 }
        let n = Double(chars.count)
        return counts.values.reduce(0.0) { acc, count in
            let p = Double(count) / n
            return acc - p * log2(p)
        }
    }

    public static func entropy(_ text: String, min: Double) -> ValidationResult {
        guard text.count >= 8 else { return .reject(code: "entropy.short") }
        guard text.contains(where: { $0.isNumber }) else { return .reject(code: "entropy.nodigit") }
        guard text.contains(where: { $0.isLetter }) else { return .reject(code: "entropy.noletter") }
        if isPlaceholder(text) { return .reject(code: "entropy.placeholder") }
        return shannonEntropy(text) >= min ? .pass : .reject(code: "entropy.low")
    }

    // MARK: §5.4 JWT

    public static func base64URLDecode(_ part: Substring) -> Data? {
        var s = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - s.count % 4) % 4
        if pad == 3 { return nil }
        s += String(repeating: "=", count: pad)
        return Data(base64Encoded: s)
    }

    public static func jwt(_ text: String) -> ValidationResult {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 5 else { return .reject(code: "jwt.parts") }
        guard let headerData = base64URLDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] != nil
        else { return .reject(code: "jwt.header") }
        guard base64URLDecode(parts[1]) != nil else { return .reject(code: "jwt.payload") }
        return .pass
    }

    // MARK: §5.5 GitHub checksum

    static let base62Alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// Base62 (0-9A-Za-z) of `value`, left-padded with `0` to `width`.
    public static func base62(_ value: UInt32, width: Int) -> String {
        var v = value
        var out: [Character] = []
        while v > 0 {
            out.append(base62Alphabet[Int(v % 62)])
            v /= 62
        }
        while out.count < width { out.append("0") }
        return String(out.reversed())
    }

    private static let classicGitHubPrefix = try! NSRegularExpression(pattern: "^gh[pousr]_", options: [])

    public static func githubChecksum(_ text: String) -> ValidationResult {
        let whole = NSRange(location: 0, length: text.utf16.count)
        // Fine-grained `github_pat_` tokens have no documented checksum → pass (§5.5).
        guard classicGitHubPrefix.firstMatch(in: text, range: whole) != nil else { return .pass }
        let body = Array(text.dropFirst(4))
        guard body.count == 36 else { return .reject(code: "github.length") }
        let payload = String(body[0..<30])
        let checksum = String(body[30..<36])
        let expected = base62(crc32(Array(payload.utf8)), width: 6)
        return checksum == expected ? .pass : .reject(code: "github.checksum")
    }

    // MARK: §5.6 AWS key id prefix

    public static let awsPrefixKinds: [String: String] = [
        "AKIA": "access key", "ASIA": "temporary key", "AGPA": "group", "AIDA": "IAM user", "AROA": "role",
        "AIPA": "instance profile", "ANPA": "managed policy", "ANVA": "policy version", "ASCA": "certificate",
        "ABIA": "context", "ACCA": "context",
    ]

    public static func awsKeyIdPrefix(_ text: String) -> ValidationResult {
        let prefix = String(text.prefix(4))
        if let kind = awsPrefixKinds[prefix] { return .passAnnotated(subkind: kind) }
        return .pass   // everything the regex admits passes; the validator only annotates
    }

    // MARK: §5.7 phone shape

    public static func phoneShape(_ text: String, minDigits: Int, maxDigits: Int) -> ValidationResult {
        let digits = text.filter { $0.isNumber && $0.isASCII }
        guard (minDigits...maxDigits).contains(digits.count) else { return .reject(code: "phone.digits") }
        if Set(digits).count == 1 { return .reject(code: "phone.repeated") }
        return .pass
    }
}
