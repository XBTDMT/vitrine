import Foundation

/// Masking secrets in config files before they are shown (code state 16, T-4): a value whose key names a secret
/// (SECRET, TOKEN, PASSWORD, API_KEY …), a value that looks like a known credential whatever its key, and the password
/// in a URL's user part. The value becomes bullets (8 to 24, so the length is only roughly said); the key, the line
/// and everything else stay. Masking happens before the text reaches the page, the copy menu or the pill, so a
/// preview never holds the secret. roadmap: S-5
public enum SecretMask {
    public struct Result: Sendable, Equatable {
        public let text: String
        /// Values masked.
        public let count: Int
    }

    /// Languages whose files are key = value lines.
    public static let languages: Set<String> = ["dotenv", "properties", "ini"]

    static let secretKey = try! NSRegularExpression(
        pattern: #"(SECRET|TOKEN|PASSWORD|PASSWD|PWD|PASSPHRASE|API_?KEY|APIKEY|PRIVATE_?KEY|ACCESS_?KEY|AUTH|CREDENTIAL|DSN|SALT|SIGNING|CLIENT_?SECRET|SESSION_?KEY|COOKIE_?SECRET|WEBHOOK|(?<![A-Z0-9])PASS(?![A-Z0-9]))"#,
        options: [.caseInsensitive])
    /// Credentials recognisable by their form: Stripe, GitHub, AWS, Slack, OpenAI-style keys, Google API keys, JWTs.
    static let credential = try! NSRegularExpression(
        pattern: #"^(sk|rk|pk)_(live|test)_[A-Za-z0-9]{8,}|^gh[pousr]_[A-Za-z0-9]{20,}|^github_pat_[A-Za-z0-9_]{20,}|^AKIA[0-9A-Z]{16}$|^xox[abposr]-[A-Za-z0-9-]{10,}|^sk-[A-Za-z0-9_-]{20,}|^AIza[0-9A-Za-z_-]{30,}|^eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\."#)
    /// scheme://user:password@host. A match may only start where a scheme can (not inside a run of scheme
    /// characters) and every run is possessive, so a long value with no "://" is read once, not once per start
    /// (S-16: the unanchored form took minutes on a 200,000-character value).
    static let urlPassword = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9+.-])([A-Za-z][A-Za-z0-9+.-]*+://[^:/@\s]++:)([^@/\s]++)(@)"#)

    public static func bullets(_ length: Int) -> String { String(repeating: "•", count: min(24, max(8, length))) }

    public static func mask(_ text: String) -> Result {
        var count = 0
        var out: [Substring] = []
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let raw = lines.popFirst() {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), !trimmed.hasPrefix("!"),
                  let sep = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { out.append(raw); continue }
            let key = line[..<sep].replacingOccurrences(of: "export ", with: "").trimmingCharacters(in: .whitespaces)
            var valueStart = line.index(after: sep)
            while valueStart < line.endIndex, line[valueStart] == " " || line[valueStart] == "\t" { valueStart = line.index(after: valueStart) }
            let rawValue = String(line[valueStart...])
            // Keep quotes and a trailing comment around the value as they are.
            var core = rawValue
            var lead = "", trail = ""
            if let q = core.first, q == "\"" || q == "'", let end = core.dropFirst().firstIndex(of: q) {
                lead = String(q); trail = String(core[end...]); core = String(core[core.index(after: core.startIndex)..<end])
            } else if let hash = core.range(of: " #") {
                trail = String(core[hash.lowerBound...]); core = String(core[..<hash.lowerBound])
            }
            let ns = key as NSString
            let keyIsSecret = secretKey.firstMatch(in: key, range: NSRange(location: 0, length: ns.length)) != nil
            let valueNS = core as NSString
            let looksLikeCredential = credential.firstMatch(in: core, range: NSRange(location: 0, length: valueNS.length)) != nil
            if !core.isEmpty, keyIsSecret || looksLikeCredential {
                count += 1
                out.append(Substring(String(line[..<valueStart]) + lead + bullets(core.count) + trail))
                continue
            }
            // A URL with a password in an ordinary value: only the password goes.
            if let m = urlPassword.firstMatch(in: core, range: NSRange(location: 0, length: valueNS.length)),
               let pw = Range(m.range(at: 2), in: core) {
                count += 1
                var masked = core
                masked.replaceSubrange(pw, with: bullets(core[pw].count))
                out.append(Substring(String(line[..<valueStart]) + lead + masked + trail))
                continue
            }
            out.append(raw)
        }
        return Result(text: out.joined(separator: "\n"), count: count)
    }
}
