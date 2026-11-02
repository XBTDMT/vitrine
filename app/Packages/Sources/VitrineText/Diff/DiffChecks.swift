import Foundation

/// The diff design's Checks group (S-7, "A patch that adds something risky"): what a patch adds that deserves a look
/// before applying it — a secret (a value under a secret-named key, or shaped like a known credential, or a private
/// key block), and a script that downloads and runs code (`curl … | sh`). Only added lines are checked. A secret's
/// value is masked in the rows the page draws (`maskedText`), so a preview never shows it. roadmap: S-7
public enum DiffChecks {
    public struct Finding: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Codable { case secret, script }
        public enum Level: String, Sendable, Codable { case caution, danger }
        public var kind: Kind
        public var level: Level
        /// "Adds a live payment key", "Downloads and runs a script".
        public var title: String
        /// ".env.example, line 4 · Stripe secret key shape · value masked".
        public var detail: String
        public var file: Int
        public var hunk: Int
        public var line: Int
    }

    public struct Result: Sendable, Equatable {
        public var findings: [Finding]
        /// Masked text for lines that hold a secret, keyed by "file:hunk:line".
        public var masked: [String: String]

        public init(findings: [Finding], masked: [String: String]) { self.findings = findings; self.masked = masked }

        public func maskedText(file: Int, hunk: Int, line: Int) -> String? { masked["\(file):\(hunk):\(line)"] }
    }

    /// At most this many findings are reported (a patch adding a thousand keys says so once per file after that).
    public static let maxFindings = 50

    public static func scan(_ patch: Patch) -> Result {
        var findings: [Finding] = []
        var masked: [String: String] = [:]
        for (f, file) in patch.files.enumerated() {
            let name = file.path
            let executable = file.newMode?.isExecutable == true && file.oldMode?.isExecutable != true
            for (h, hunk) in file.hunks.enumerated() {
                for (l, line) in hunk.lines.enumerated() where line.kind == .added {
                    if let secret = secret(in: line.text) {
                        masked["\(f):\(h):\(l)"] = secret.masked
                        if findings.count < maxFindings {
                            findings.append(Finding(kind: .secret, level: secret.live ? .danger : .caution, title: secret.title,
                                                    detail: line.newNumber.map { String(localized: "\(name), line \($0) · \(secret.shape) · value masked", bundle: .module, comment: "Detail of a finding in a patch: the file name, the line number, the kind of secret found. The secret itself is never shown.") }
                                                        ?? String(localized: "\(name) · \(secret.shape) · value masked", bundle: .module, comment: "Detail of a finding in a patch: the file name and the kind of secret found. The secret itself is never shown."),
                                                    file: f, hunk: h, line: l))
                        }
                    }
                    if findings.count < maxFindings, isDownloadAndRun(line.text) {
                        let shape = scriptShape(line.text)
                        let detail: String = switch (line.newNumber, executable) {
                        case (let n?, true): String(localized: "\(name), line \(n) · \(shape) · also made executable", bundle: .module, comment: "Detail of a finding in a patch: the file, the line, the command shape such as curl … | sh, and that the file was made executable.")
                        case (let n?, false): String(localized: "\(name), line \(n) · \(shape)", bundle: .module, comment: "Detail of a finding in a patch: the file, the line and the command shape such as curl … | sh.")
                        case (nil, true): String(localized: "\(name) · \(shape) · also made executable", bundle: .module, comment: "Detail of a finding in a patch: the file, the command shape such as curl … | sh, and that the file was made executable.")
                        case (nil, false): String(localized: "\(name) · \(shape)", bundle: .module, comment: "Detail of a finding in a patch: the file and the command shape such as curl … | sh.")
                        }
                        findings.append(Finding(kind: .script, level: .caution, title: String(localized: "Downloads and runs a script", bundle: .module, comment: "Title of a finding: a patch adds a command that downloads code and runs it."),
                                                detail: detail, file: f, hunk: h, line: l))
                    }
                }
            }
        }
        return Result(findings: findings, masked: masked)
    }

    // MARK: Secrets

    struct Secret { let title: String; let shape: String; let live: Bool; let masked: String }

    /// Known credential shapes: name, pattern, whether it is a live (production) key. The first is Stripe's live secret
    /// key, the one `secret(in:)` calls a live payment key.
    static let shapes: [(String, NSRegularExpression, Bool)] = [
        (String(localized: "Stripe secret key shape", bundle: .module, comment: "Name of a credential pattern found in a patch, shown in a finding's detail; product names stay as they are."), #"\b[sr]k_live_[A-Za-z0-9]{8,}"#, true),
        (String(localized: "Stripe test key shape", bundle: .module, comment: "Name of a credential pattern found in a patch, shown in a finding's detail; product names stay as they are."), #"\b[sr]k_test_[A-Za-z0-9]{8,}"#, false),
        (String(localized: "GitHub token shape", bundle: .module, comment: "Name of a credential pattern found in a patch, shown in a finding's detail; product names stay as they are."), #"\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}"#, true),
        (String(localized: "AWS access key shape", bundle: .module, comment: "Name of a credential pattern found in a patch, shown in a finding's detail; product names stay as they are."), #"\bAKIA[0-9A-Z]{16}\b"#, true),
        (String(localized: "Slack token shape", bundle: .module, comment: "Name of a credential pattern found in a patch, shown in a finding's detail; product names stay as they are."), #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, true),
        (String(localized: "API key shape", bundle: .module, comment: "Name of a credential pattern found in a patch, shown in a finding's detail; product names stay as they are."), #"\bsk-[A-Za-z0-9_-]{20,}"#, true),
        (String(localized: "Google API key shape", bundle: .module, comment: "Name of a credential pattern found in a patch, shown in a finding's detail; product names stay as they are."), #"\bAIza[0-9A-Za-z_-]{30,}"#, true),
        (String(localized: "JSON Web Token shape", bundle: .module, comment: "Name of a credential pattern found in a patch, shown in a finding's detail; product names stay as they are."), #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}"#, false),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1), $0.2) }

    static let privateKey = try! NSRegularExpression(pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#)

    static func secret(in text: String) -> Secret? {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        if privateKey.firstMatch(in: text, range: all) != nil {
            return Secret(title: String(localized: "Adds a private key", bundle: .module, comment: "Title of a finding: a patch adds a private key."), shape: String(localized: "private key block", bundle: .module, comment: "Name of a credential pattern found in a patch, shown in a finding's detail; product names stay as they are."), live: true, masked: text)
        }
        for (index, (shape, regex, live)) in shapes.enumerated() {
            guard let m = regex.firstMatch(in: text, range: all), let r = Range(m.range, in: text) else { continue }
            let value = String(text[r])
            // Keep the recognisable prefix ("sk_live_", "ghp_", "AKIA"), mask the rest.
            let known = ["sk_live_", "rk_live_", "sk_test_", "rk_test_", "github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "xoxb-", "xoxp-", "AKIA", "AIza", "sk-"]
            let prefix = known.first { value.hasPrefix($0) } ?? ""
            var masked = text
            masked.replaceSubrange(r, with: prefix + SecretMask.bullets(value.count - prefix.count))
            let title = index == 0 ? String(localized: "Adds a live payment key", bundle: .module, comment: "Title of a finding: a patch adds a live Stripe secret key.")
                : live ? String(localized: "Adds a secret", bundle: .module, comment: "Title of a finding: a patch adds a secret such as a token or password.")
                : String(localized: "Adds a test key", bundle: .module, comment: "Title of a finding: a patch adds a test (not live) key.")
            return Secret(title: title, shape: shape, live: live, masked: masked)
        }
        // A value under a secret-named key (KEY=value, key: value), as config files write it.
        let result = SecretMask.mask(text)
        if result.count > 0 {
            return Secret(title: String(localized: "Adds a secret", bundle: .module, comment: "Title of a finding: a patch adds a secret such as a token or password."), shape: String(localized: "a secret-named key", bundle: .module, comment: "Name of a credential pattern found in a patch, shown in a finding's detail; product names stay as they are. A value under a key named like password or token."), live: false, masked: result.text)
        }
        return nil
    }

    // MARK: Scripts

    static let downloadAndRun = try! NSRegularExpression(
        pattern: #"\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z|da|k)?sh\b|\b(ba|z)?sh\s+-c\s+"?\$\((curl|wget)\b|\biex\s*\(?\s*\(?\s*(iwr|irm|Invoke-WebRequest|Invoke-RestMethod)\b"#,
        options: [.caseInsensitive])

    static func isDownloadAndRun(_ text: String) -> Bool {
        downloadAndRun.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func scriptShape(_ text: String) -> String {
        let lower = text.lowercased()
        let fetch = lower.contains("wget") ? "wget" : lower.contains("curl") ? "curl" : "download"
        return "\(fetch) … | sh"
    }
}
