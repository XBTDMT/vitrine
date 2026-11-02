import Foundation

/// What an email message holds (N-5), from an `.eml` file (RFC 5322 + MIME) or an Outlook `.msg` file: who sent it
/// to whom and when, its subject, the plain and HTML bodies decoded, its attachments, the receiving server's SPF,
/// DKIM and DMARC verdicts, and hints that it may not be from who it says (a display name carrying a different
/// address, failed authentication, attachments that can run code). The HTML body is text for the caller to render
/// safely (no remote content); nothing here fetches anything. roadmap: S-23
public struct EmailSummary: Sendable, Equatable {
    /// The file format the message came from. roadmap: S-23
    public enum Format: String, Sendable, Equatable {
        case eml, msg
    }

    /// A mailbox: display name and address. roadmap: S-23
    public struct Address: Sendable, Equatable {
        public var name: String?
        public var address: String?

        public init(name: String?, address: String?) {
            self.name = name
            self.address = address
        }

        /// "Ana Lima <ana@acme.example>", or whichever half exists.
        public var display: String {
            switch (name, address) {
            case let (name?, address?): "\(name) <\(address)>"
            case let (name?, nil): name
            case let (nil, address?): address
            default: ""
            }
        }

        /// The address's domain, lowercased.
        public var domain: String? {
            guard let address, let at = address.lastIndex(of: "@") else { return nil }
            let domain = address[address.index(after: at)...].lowercased()
            return domain.isEmpty ? nil : domain
        }
    }

    /// An attached file. roadmap: S-23
    public struct Attachment: Sendable, Equatable {
        public var name: String?
        public var mediaType: String
        /// Decoded size in bytes.
        public var size: Int
        /// Shown inside the body (an inline image) rather than offered as a file.
        public var isInline: Bool
        public var contentID: String?
    }

    /// One node of the MIME tree, in document order. roadmap: S-23
    public struct Part: Sendable, Equatable {
        /// 0 for the message itself.
        public var depth: Int
        public var mediaType: String
        public var name: String?
        /// Decoded size in bytes (0 for multipart containers).
        public var size: Int
        public var disposition: String?
        public var charset: String?
        public var transferEncoding: String?
    }

    /// The receiving server's verdicts from the topmost Authentication-Results header. roadmap: S-23
    public struct Authentication: Sendable, Equatable {
        /// The server that wrote the verdicts (the authserv-id).
        public var server: String?
        /// Lowercased verdicts as written (`pass`, `fail`, `softfail`, `neutral`, `none`, `temperror`, `permerror`).
        public var spf: String?
        public var dkim: String?
        public var dmarc: String?
    }

    public static let maxBodyCharacters = 1_000_000
    public static let maxParts = 1_000
    public static let maxHeaders = 500
    public static let maxDepth = 16

    public var format: Format
    public var subject: String?
    public var from: Address?
    /// The Sender header (or, in a .msg, the sending account when it differs from From).
    public var sender: Address?
    public var replyTo: [Address]
    public var to: [Address]
    public var cc: [Address]
    public var bcc: [Address]
    public var date: Date?
    /// The Date header as written.
    public var dateText: String?
    public var messageID: String?
    /// Every header in order, decoded and unfolded (at most `maxHeaders`, values at most 4,000 characters).
    public var headers: [EverydayFact]
    public var plainBody: String?
    public var htmlBody: String?
    public var attachments: [Attachment]
    public var parts: [Part]
    public var authentication: Authentication?
    public var warnings: [EverydayWarning]
    public var truncated: Bool

    public init(format: Format) {
        self.format = format
        self.replyTo = []
        self.to = []
        self.cc = []
        self.bcc = []
        self.headers = []
        self.attachments = []
        self.parts = []
        self.warnings = []
        self.truncated = false
    }

    public var headline: String {
        subject.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(localized: "(no subject)", bundle: .module, comment: "Headline of an email card whose message has no subject.")
    }

    public var facts: [EverydayFact] {
        var facts: [EverydayFact] = []
        if let from { facts.append(EverydayFact(String(localized: "From", bundle: .module, comment: "Fact label on an email card: the sender."), from.display)) }
        if !to.isEmpty {
            facts.append(EverydayFact(String(localized: "To", bundle: .module, comment: "Fact label on an email card: the recipients."),
                                      to.prefix(5).map(\.display).joined(separator: ", ") + (to.count > 5 ? " +\(to.count - 5)" : "")))
        }
        if !cc.isEmpty {
            facts.append(EverydayFact(String(localized: "Cc", bundle: .module, comment: "Fact label on an email card: copied recipients."),
                                      cc.prefix(5).map(\.display).joined(separator: ", ") + (cc.count > 5 ? " +\(cc.count - 5)" : "")))
        }
        let dateLabel = String(localized: "Date", bundle: .module, comment: "Fact label on an email card: when it was sent.")
        if let date {
            facts.append(EverydayFact(dateLabel, ISO8601DateFormatter.string(from: date, timeZone: TimeZone(identifier: "UTC")!,
                                                                          formatOptions: [.withInternetDateTime])))
        } else if let dateText {
            facts.append(EverydayFact(dateLabel, dateText))
        }
        let files = attachments.filter { !$0.isInline }
        if !files.isEmpty {
            facts.append(EverydayFact(String(localized: "Attachments", bundle: .module, comment: "Fact label on an email card: number of attached files."),
                                      "\(files.count)"))
        }
        if let auth = authentication {
            let verdicts = [("SPF", auth.spf), ("DKIM", auth.dkim), ("DMARC", auth.dmarc)]
                .compactMap { label, value in value.map { "\(label) \($0)" } }
            if !verdicts.isEmpty {
                facts.append(EverydayFact(String(localized: "Authentication", bundle: .module,
                                                 comment: "Fact label on an email card: the receiving server's SPF, DKIM and DMARC verdicts."),
                                          verdicts.joined(separator: ", ")))
            }
        }
        return facts
    }
}

/// The RFC 5322 + MIME parser behind `EmailSummary` for `.eml` files, and the checks shared with `.msg`.
enum EverydayMail {
    static func looksLikeMail(_ head: String) -> Bool {
        let lines = EverydayText.lines(head).prefix(40)
        var known = 0
        for line in lines {
            let lower = line.lowercased()
            for name in ["from:", "to:", "subject:", "date:", "message-id:", "received:", "mime-version:", "return-path:"]
            where lower.hasPrefix(name) { known += 1 }
            if line.isEmpty { break }
        }
        return known >= 2
    }

    static func read(_ bytes: [UInt8]) -> EmailSummary? {
        let (headerEnd, bodyStart) = splitHeaders(bytes, 0..<bytes.count)
        let headers = parseHeaders(bytes[0..<headerEnd])
        guard headers.contains(where: { ["from", "to", "subject", "date", "message-id", "received"].contains($0.name) }) else {
            return nil
        }
        var summary = EmailSummary(format: .eml)
        if headers.count > EmailSummary.maxHeaders { summary.truncated = true }
        for header in headers.prefix(EmailSummary.maxHeaders) {
            summary.headers.append(EverydayFact(header.original, EverydayText.cap(decodeWords(header.value), 4_000)))
        }
        func first(_ name: String) -> String? { headers.first { $0.name == name }?.value }
        summary.subject = first("subject").map { EverydayText.collapse(decodeWords($0)) }
        summary.from = first("from").flatMap { addresses($0).first }
        summary.sender = first("sender").flatMap { addresses($0).first }
        summary.replyTo = first("reply-to").map(addresses) ?? []
        summary.to = headers.filter { $0.name == "to" }.flatMap { addresses($0.value) }
        summary.cc = headers.filter { $0.name == "cc" }.flatMap { addresses($0.value) }
        summary.bcc = headers.filter { $0.name == "bcc" }.flatMap { addresses($0.value) }
        summary.dateText = first("date").map { EverydayText.collapse($0) }
        summary.date = summary.dateText.flatMap(parseDate)
        summary.messageID = first("message-id").map { $0.trimmingCharacters(in: .whitespaces) }
        summary.authentication = first("authentication-results").flatMap(authentication)

        var walker = MIMEWalker(bytes: bytes)
        walker.walk(headers: headers, body: bodyStart..<bytes.count, depth: 0)
        summary.parts = walker.parts
        summary.attachments = walker.attachments
        summary.plainBody = walker.plain
        summary.htmlBody = walker.html
        if walker.truncated { summary.truncated = true }
        if walker.tooDeep {
            summary.warnings.append(EverydayWarning(.caution, code: "email.tooDeep",
                reason: String(localized: "The message nests parts more than \(EmailSummary.maxDepth) deep; the deeper parts were not read.", bundle: .module,
                               comment: "Warning on an email card; the argument is the nesting limit.")))
        }
        addChecks(&summary)
        return summary
    }

    // MARK: Checks shared with .msg

    static let riskyExtensions: Set<String> = [
        "exe", "scr", "com", "pif", "bat", "cmd", "vbs", "vbe", "js", "jse", "wsf", "wsh", "hta", "msi", "msp", "jar",
        "lnk", "ps1", "psm1", "reg", "cpl", "dll", "iso", "img", "vhd", "vhdx", "app", "pkg", "command", "scpt", "docm",
        "xlsm", "pptm", "dotm", "xlam", "sh", "apk", "appx", "msix", "one", "chm", "url", "library-ms", "settingcontent-ms",
    ]
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "jpg", "jpeg", "png", "zip", "rtf"]

    /// The first `local@domain.tld` written in `text` — what the regex
    /// `[A-Za-z0-9._%+\-]+@([A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+)` finds first — in one forward pass. That regex was
    /// quadratic on a long run of address characters with no `@` (a display name can be megabytes long): it scanned
    /// the run again from every start. Here each `@` looks back over the run before it and forward over the domain
    /// after it, and both stop at the next `@`, so every character is visited a bounded number of times.
    static func firstAddress(in text: String) -> (address: String, domain: String)? {
        func isLocal(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || "._%+-".contains(c)) }
        func isLabel(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "-") }
        var runStart: String.Index?            // where the current run of local-part characters began
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "@", let start = runStart {
                // The domain: one or more labels, then one or more ".label" groups, each as long as it goes.
                let domainStart = text.index(after: i)
                var j = domainStart
                while j < text.endIndex, isLabel(text[j]) { j = text.index(after: j) }
                var groups = 0
                if j > domainStart {
                    while j < text.endIndex, text[j] == "." {
                        let labelStart = text.index(after: j)
                        var k = labelStart
                        while k < text.endIndex, isLabel(text[k]) { k = text.index(after: k) }
                        guard k > labelStart else { break }
                        j = k
                        groups += 1
                    }
                }
                if groups > 0 { return (String(text[start..<j]), String(text[domainStart..<j])) }
            }
            runStart = isLocal(c) ? (runStart ?? i) : nil
            i = text.index(after: i)
        }
        return nil
    }

    static func addChecks(_ summary: inout EmailSummary) {
        // The display name names one address while the message comes from another domain.
        if let from = summary.from, let name = from.name, let actual = from.domain,
           let claimed = firstAddress(in: name) {
            let claimedDomain = claimed.domain.lowercased()
            if !sameOrganization(claimedDomain, actual) {
                let shown = claimed.address
                let real = from.address ?? actual
                summary.warnings.append(EverydayWarning(.caution, code: "email.displayNameMismatch",
                    reason: String(localized: "The sender's name shows the address \(shown) but the message comes from \(real): a common phishing trick.", bundle: .module,
                                   comment: "Warning on an email card; the first argument is the address written in the sender's name, the second the real sender address.")))
            }
        }
        if let auth = summary.authentication {
            if auth.dmarc == "fail" {
                summary.warnings.append(EverydayWarning(.danger, code: "email.dmarcFail",
                    reason: String(localized: "The receiving server says this message failed DMARC: it may not be from the domain it claims.", bundle: .module,
                                   comment: "Warning on an email card. DMARC is a standard's name and stays as it is.")))
            }
            let failed = [("SPF", auth.spf), ("DKIM", auth.dkim)].filter { ["fail", "softfail", "permerror"].contains($0.1 ?? "") }.map(\.0)
            if !failed.isEmpty {
                let checks = failed.joined(separator: ", ")
                summary.warnings.append(EverydayWarning(.caution, code: "email.authFail",
                    reason: String(localized: "The receiving server could not verify the sender (failed: \(checks)).", bundle: .module,
                                   comment: "Warning on an email card; the argument is SPF, DKIM or both (standard names that stay as they are).")))
            }
        }
        var risky: [String] = []
        for attachment in summary.attachments {
            guard let name = attachment.name else { continue }
            let pieces = name.lowercased().split(separator: ".")
            guard pieces.count >= 2, let ext = pieces.last else { continue }
            let doubled = pieces.count >= 3 && documentExtensions.contains(String(pieces[pieces.count - 2]))
            if riskyExtensions.contains(String(ext)) || (doubled && !documentExtensions.contains(String(ext))) {
                risky.append(name)
            }
        }
        if !risky.isEmpty {
            let names = risky.prefix(3).joined(separator: ", ")
            summary.warnings.append(EverydayWarning(.danger, code: "email.riskyAttachment",
                reason: String(localized: "These attachments can run code when opened: \(names).", bundle: .module,
                               comment: "Warning on an email card; the argument is one or more attachment file names.")))
        }
    }

    /// Two domains belong to the same organisation when one is the other or a subdomain of it.
    static func sameOrganization(_ a: String, _ b: String) -> Bool {
        a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }

    static func authentication(_ value: String) -> EmailSummary.Authentication {
        var auth = EmailSummary.Authentication()
        let server = value.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let server, !server.contains("=") { auth.server = server.split(separator: " ").first.map(String.init) }
        for match in value.lowercased().matches(of: /(?:^|[\s;])(spf|dkim|dmarc)\s*=\s*([a-z]+)/) {
            switch match.1 {
            case "spf": if auth.spf == nil { auth.spf = String(match.2) }
            case "dkim":
                // Several signatures: any pass counts as pass.
                if auth.dkim == nil || match.2 == "pass" { auth.dkim = String(match.2) }
            case "dmarc": if auth.dmarc == nil { auth.dmarc = String(match.2) }
            default: break
            }
        }
        return auth
    }

    // MARK: Headers

    struct Header {
        /// Lowercased.
        var name: String
        var original: String
        /// Unfolded, not decoded.
        var value: String
    }

    /// The end of the header block and the start of the body (after the blank line).
    static func splitHeaders(_ bytes: [UInt8], _ range: Range<Int>) -> (Int, Int) {
        var i = range.lowerBound
        var lineStart = i
        while i < range.upperBound {
            if bytes[i] == 0x0A {
                let line = lineStart..<i
                let isBlank = line.isEmpty || (line.count == 1 && bytes[line.lowerBound] == 0x0D)
                if isBlank { return (lineStart, i + 1) }
                lineStart = i + 1
            }
            i += 1
        }
        return (range.upperBound, range.upperBound)
    }

    static func parseHeaders(_ slice: ArraySlice<UInt8>) -> [Header] {
        let text = String(validating: Array(slice), as: UTF8.self) ?? EverydayText.latin1(slice)
        var headers: [Header] = []
        for line in EverydayText.lines(text) {
            if let first = line.first, first == " " || first == "\t" {
                if !headers.isEmpty { headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            if headers.count >= 5_000 { break }
            headers.append(Header(name: name.lowercased(), original: name,
                                  value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return headers
    }

    /// RFC 2047 encoded words (`=?utf-8?B?…?=`, `=?iso-8859-1?Q?…?=`) decoded; the space between two adjacent encoded
    /// words is dropped.
    static func decodeWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        var out = ""
        var rest = Substring(value)
        var lastWasEncoded = false
        while let match = rest.firstMatch(of: /=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?=/) {
            let before = rest[..<match.range.lowerBound]
            if !(lastWasEncoded && before.allSatisfy(\.isWhitespace)) { out += before }
            var charset = String(match.1)
            if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }   // RFC 2231 language
            let payload = String(match.3)
            let bytes: [UInt8]?
            if match.2 == "B" || match.2 == "b" {
                bytes = EverydayText.base64(payload)
            } else {
                bytes = EverydayText.quotedPrintable(Array(payload.utf8).map { $0 == 0x5F ? 0x20 : $0 })
            }
            if let bytes {
                out += EverydayText.decode(bytes, charset: charset)
            } else {
                out += rest[match.range]
            }
            lastWasEncoded = true
            rest = rest[match.range.upperBound...]
        }
        out += rest
        return out
    }

    // MARK: Addresses

    /// An address list (`"Lima, Ana" <ana@acme.example>, bo@acme.example (Bo), Team: a@x, b@y;`) split into mailboxes.
    static func addresses(_ value: String) -> [EmailSummary.Address] {
        var tokens: [String] = []
        var current = ""
        var quoted = false, angle = 0, paren = 0, escaped = false
        for c in value {
            if escaped { current.append(c); escaped = false; continue }
            switch c {
            case "\\" where quoted: escaped = true; current.append(c); continue
            case "\"": quoted.toggle()
            case "<" where !quoted: angle += 1
            case ">" where !quoted: angle = max(0, angle - 1)
            case "(" where !quoted: paren += 1
            case ")" where !quoted: paren = max(0, paren - 1)
            case ",", ";":
                if !quoted && angle == 0 && paren == 0 { tokens.append(current); current = ""; continue }
            case ":":
                // A group's name ("Team:") is dropped.
                if !quoted && angle == 0 && paren == 0 && !current.contains("@") { current = ""; continue }
            default: break
            }
            current.append(c)
        }
        tokens.append(current)
        var result: [EmailSummary.Address] = []
        for token in tokens where result.count < 1_000 {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let open = trimmed.lastIndex(of: "<"), let close = trimmed[open...].firstIndex(of: ">") {
                let address = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                let name = displayName(String(trimmed[..<open]))
                result.append(.init(name: name, address: address.isEmpty ? nil : address))
            } else {
                var address = trimmed
                var name: String?
                if let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close {
                    name = displayName(String(trimmed[trimmed.index(after: open)..<close]))
                    address = (trimmed[..<open] + trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                }
                if address.contains("@") {
                    result.append(.init(name: name, address: address))
                } else if let decoded = displayName(address) {
                    result.append(.init(name: decoded, address: nil))
                }
            }
        }
        return result
    }

    static func displayName(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
            text = text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        text = EverydayText.collapse(decodeWords(text))
        return text.isEmpty ? nil : text
    }

    // MARK: Dates

    /// The header with its (comments) replaced by a space, in one pass. RFC 5322 comments nest; an unclosed one
    /// runs to the end. (The regex this replaces rescanned to the end from every "(": minutes on a long header.)
    static func withoutComments(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.utf8.count)
        var depth = 0
        for ch in raw {
            if ch == "(" { if depth == 0 { out.append(" ") }; depth += 1; continue }
            if ch == ")", depth > 0 { depth -= 1; continue }
            if depth == 0 { out.append(ch) }
        }
        return out
    }

    static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9,
                         "oct": 10, "nov": 11, "dec": 12]
    static let zones = ["ut": 0, "utc": 0, "gmt": 0, "z": 0, "est": -5, "edt": -4, "cst": -6, "cdt": -5, "mst": -7,
                        "mdt": -6, "pst": -8, "pdt": -7]

    /// RFC 5322 dates (`Tue, 3 Nov 2026 09:30:00 +0100`), with the obsolete forms (two-digit years, zone names,
    /// comments, missing seconds).
    static func parseDate(_ raw: String) -> Date? {
        let cleaned = withoutComments(raw)
        let tokens = cleaned.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
        var day: Int?, month: Int?, year: Int?, time: [Int]?, offset: Int?
        for token in tokens {
            let lower = token.lowercased()
            if let m = months[String(lower.prefix(3))], lower.allSatisfy(\.isLetter), month == nil { month = m; continue }
            if token.contains(":") {
                let parts = token.split(separator: ":").compactMap { Int($0) }
                if parts.count >= 2, parts.count == token.split(separator: ":").count { time = parts }
                continue
            }
            if (token.hasPrefix("+") || token.hasPrefix("-")), token.count == 5, let n = Int(token.dropFirst()) {
                // A zone no clock uses would show a wrong time as if it were right.
                guard n % 100 < 60, n / 100 <= 14 else { return nil }
                offset = (n / 100 * 3600 + n % 100 * 60) * (token.hasPrefix("-") ? -1 : 1)
                continue
            }
            if let hours = zones[lower] { offset = hours * 3600; continue }
            if let n = Int(token) {
                if day == nil, month == nil, n >= 1, n <= 31 { day = n } else if year == nil { year = n } else if day == nil { day = n }
            }
        }
        guard let day, let month, var year, let time else { return nil }
        if year < 50 { year += 2000 } else if year < 1000 { year += 1900 }
        // Foundation does not refuse out-of-range components: it rolls them into a different, wrong date
        // (year Int.max reads as year 1). A header outside a calendar's range is no date at all (S-16).
        guard (1...9999).contains(year), (1...31).contains(day),
              time.count < 3 || (0...60).contains(time[2]) else { return nil }
        var components = DateComponents(year: year, month: month, day: day, hour: time[0], minute: time[1],
                                        second: time.count > 2 ? time[2] : 0)
        components.timeZone = TimeZone(secondsFromGMT: offset ?? 0)
        guard (0..<24).contains(time[0]), (0..<60).contains(time[1]) else { return nil }
        return Calendar(identifier: .gregorian).date(from: components)
    }

    // MARK: MIME

    /// Content-Type or Content-Disposition: the value before the first `;` and its parameters, with RFC 2231
    /// continuations (`name*0=`, `name*1=`) and extended values (`name*=utf-8''%E2%82%AC.pdf`) assembled.
    static func parameters(_ raw: String) -> (value: String, params: [String: String]) {
        var pieces: [String] = []
        var current = ""
        var quoted = false, escaped = false
        for c in raw {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\", quoted { escaped = true; continue }
            if c == "\"" { quoted.toggle(); continue }
            if c == ";", !quoted { pieces.append(current); current = ""; continue }
            current.append(c)
        }
        pieces.append(current)
        let value = pieces.removeFirst().trimmingCharacters(in: .whitespaces).lowercased()
        var simple: [String: String] = [:]
        var continued: [String: [(Int, String, Bool)]] = [:]
        for piece in pieces.prefix(100) {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            var key = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            var extended = false
            if key.hasSuffix("*") { extended = true; key.removeLast() }
            if let star = key.lastIndex(of: "*"), let index = Int(key[key.index(after: star)...]) {
                continued[String(key[..<star]), default: []].append((index, val, extended))
            } else if extended {
                simple[key] = decode2231(val, hasCharset: true)
            } else if simple[key] == nil {
                simple[key] = val
            }
        }
        for (key, list) in continued where simple[key] == nil {
            let sorted = list.sorted { $0.0 < $1.0 }
            var charset: String?
            var bytes: [UInt8] = []
            for (i, piece) in sorted.enumerated() {
                var text = Substring(piece.1)
                if piece.2 {
                    if i == 0, let first = text.firstIndex(of: "'"), let second = text[text.index(after: first)...].firstIndex(of: "'") {
                        charset = String(text[..<first])
                        text = text[text.index(after: second)...]
                    }
                    bytes += percentDecode(text)
                } else {
                    bytes += Array(text.utf8)
                }
            }
            simple[key] = EverydayText.decode(bytes, charset: charset)
        }
        return (value, simple)
    }

    static func decode2231(_ raw: String, hasCharset: Bool) -> String {
        var text = Substring(raw)
        var charset: String?
        if hasCharset, let first = text.firstIndex(of: "'"), let second = text[text.index(after: first)...].firstIndex(of: "'") {
            charset = String(text[..<first])
            text = text[text.index(after: second)...]
        }
        return EverydayText.decode(percentDecode(text), charset: charset)
    }

    static func percentDecode(_ text: Substring) -> [UInt8] {
        let utf8 = Array(text.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < utf8.count {
            if utf8[i] == 0x25, i + 2 < utf8.count, let hi = EverydayText.hex(utf8[i + 1]), let lo = EverydayText.hex(utf8[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(utf8[i])
                i += 1
            }
        }
        return out
    }

    /// Walks a MIME tree iteratively in depth (bounded), collecting the parts, the first plain and HTML bodies, and
    /// the attachments.
    struct MIMEWalker {
        let bytes: [UInt8]
        var parts: [EmailSummary.Part] = []
        var attachments: [EmailSummary.Attachment] = []
        var plain: String?
        var html: String?
        var truncated = false
        var tooDeep = false

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func walk(headers: [Header], body: Range<Int>, depth: Int) {
            guard parts.count < EmailSummary.maxParts else { truncated = true; return }
            func first(_ name: String) -> String? { headers.first { $0.name == name }?.value }
            let contentType = parameters(first("content-type") ?? "text/plain")
            var mediaType = contentType.value.isEmpty ? "text/plain" : contentType.value
            if !mediaType.contains("/") { mediaType = "text/plain" }
            let disposition = first("content-disposition").map(parameters)
            let encoding = first("content-transfer-encoding")?.trimmingCharacters(in: .whitespaces).lowercased()
            let name = (disposition?.params["filename"] ?? contentType.params["name"]).map { EverydayMail.decodeWords($0) }

            if mediaType.hasPrefix("multipart/") {
                parts.append(.init(depth: depth, mediaType: mediaType, name: nil, size: 0, disposition: disposition?.value,
                                   charset: nil, transferEncoding: encoding))
                guard let boundary = contentType.params["boundary"], !boundary.isEmpty else { return }
                guard depth + 1 < EmailSummary.maxDepth else { tooDeep = true; truncated = true; return }
                for child in splitMultipart(body, boundary: boundary) {
                    let (headerEnd, bodyStart) = EverydayMail.splitHeaders(bytes, child)
                    let childHeaders = EverydayMail.parseHeaders(bytes[child.lowerBound..<headerEnd])
                    walk(headers: childHeaders, body: bodyStart..<child.upperBound, depth: depth + 1)
                    if parts.count >= EmailSummary.maxParts { truncated = true; return }
                }
                return
            }

            let raw = Array(bytes[body])
            let decoded: [UInt8]
            switch encoding {
            case "base64": decoded = EverydayText.base64(String(decoding: raw, as: UTF8.self)) ?? []
            case "quoted-printable": decoded = EverydayText.quotedPrintable(raw)
            default: decoded = raw
            }
            let charset = contentType.params["charset"]
            parts.append(.init(depth: depth, mediaType: mediaType, name: name, size: decoded.count,
                               disposition: disposition?.value, charset: charset, transferEncoding: encoding))
            let isAttachment = disposition?.value == "attachment" || (name != nil && disposition?.value != "inline")
            if !isAttachment, mediaType == "text/plain", plain == nil {
                plain = cap(EverydayText.decode(decoded, charset: charset))
                return
            }
            if !isAttachment, mediaType == "text/html", html == nil {
                html = cap(EverydayText.decode(decoded, charset: charset))
                return
            }
            if mediaType.hasPrefix("text/") && name == nil && !isAttachment { return }
            if attachments.count < EmailSummary.maxParts {
                var attachmentName = name
                if attachmentName == nil, mediaType == "message/rfc822" {
                    let (end, _) = EverydayMail.splitHeaders(decoded, 0..<decoded.count)
                    let inner = EverydayMail.parseHeaders(decoded[0..<end])
                    attachmentName = inner.first { $0.name == "subject" }.map { EverydayMail.decodeWords($0.value) + ".eml" }
                        ?? String(localized: "Attached message", bundle: .module,
                                  comment: "Name shown for a forwarded email attached without a file name or subject.") + ".eml"
                }
                let contentID = first("content-id")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                attachments.append(.init(name: attachmentName, mediaType: mediaType, size: decoded.count,
                                         isInline: disposition?.value == "inline" || (disposition == nil && contentID != nil && name == nil),
                                         contentID: contentID))
            }
        }

        mutating func cap(_ text: String) -> String {
            guard text.count > EmailSummary.maxBodyCharacters else { return text }
            truncated = true
            return String(text.prefix(EmailSummary.maxBodyCharacters))
        }

        /// The byte ranges of a multipart body's parts: between `--boundary` lines, up to `--boundary--`.
        func splitMultipart(_ body: Range<Int>, boundary: String) -> [Range<Int>] {
            let delimiter = Array(("--" + boundary).utf8)
            var ranges: [Range<Int>] = []
            var partStart: Int?
            var lineStart = body.lowerBound
            var i = body.lowerBound
            while lineStart < body.upperBound {
                // Find the end of this line.
                i = lineStart
                while i < body.upperBound, bytes[i] != 0x0A { i += 1 }
                let lineEnd = i
                if lineEnd - lineStart >= delimiter.count, bytes[lineStart] == 0x2D,
                   bytes[lineStart..<(lineStart + delimiter.count)].elementsEqual(delimiter) {
                    let after = lineStart + delimiter.count
                    let closing = after + 2 <= lineEnd && bytes[after] == 0x2D && bytes[after + 1] == 0x2D
                    // "--b1x" is not a delimiter for boundary "b1": only "--", spaces or CR may follow it.
                    let plain = bytes[after..<lineEnd].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
                    guard closing || plain else { lineStart = lineEnd + 1; continue }
                    if let start = partStart {
                        // The line break before the delimiter belongs to it.
                        var end = lineStart
                        if end > start, bytes[end - 1] == 0x0A { end -= 1 }
                        if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                        ranges.append(start..<max(start, end))
                        if ranges.count >= EmailSummary.maxParts { return ranges }
                    }
                    if closing { return ranges }
                    partStart = min(lineEnd + 1, body.upperBound)
                }
                lineStart = lineEnd + 1
            }
            if let start = partStart, start < body.upperBound { ranges.append(start..<body.upperBound) }
            return ranges
        }
    }
}
