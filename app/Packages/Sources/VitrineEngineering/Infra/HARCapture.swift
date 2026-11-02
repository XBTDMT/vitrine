import Foundation

/// What an HTTP Archive (`.har`) captured: its requests as a waterfall (start offset, duration, method, status, host,
/// path, response size), the hosts it talked to, the total time, and how many cookies, Set-Cookie and Authorization
/// headers it carries, by name only: no header, cookie, query or body value is ever kept. roadmap: S-22
public struct HARSummary: Sendable, Equatable {
    /// One request, for the waterfall. roadmap: S-22
    public struct Entry: Sendable, Equatable {
        /// Milliseconds after the earliest request started; nil when the entry's start time is unreadable.
        public var startOffsetMs: Double?
        /// The entry's total time in milliseconds (`time`), nil when absent or negative.
        public var durationMs: Double?
        public var method: String
        /// 0 when the request got no response.
        public var status: Int
        public var host: String
        /// The path with its query reduced to parameter names (`/search?q&page`), at most 120 characters.
        public var path: String
        /// Response body size in bytes (`content.size`, else `bodySize`), nil when unknown.
        public var responseSize: Int?
        public var mimeType: String?

        public init(startOffsetMs: Double?, durationMs: Double?, method: String, status: Int, host: String, path: String,
                    responseSize: Int?, mimeType: String?) {
            self.startOffsetMs = startOffsetMs; self.durationMs = durationMs; self.method = method; self.status = status
            self.host = host; self.path = path; self.responseSize = responseSize; self.mimeType = mimeType
        }
    }

    /// Names (and counts) of the credentials a capture carries in plain text. roadmap: S-22
    public struct Credentials: Sendable, Equatable {
        /// Request cookies by name (from `cookies` and `Cookie` headers).
        public var cookieNames: [InfraNameCount]
        /// Response cookies by name (from `cookies` and `Set-Cookie` headers).
        public var setCookieNames: [InfraNameCount]
        public var cookieCount: Int
        public var setCookieCount: Int
        /// `Authorization` and `Proxy-Authorization` request headers.
        public var authorizationCount: Int

        public init(cookieNames: [InfraNameCount], setCookieNames: [InfraNameCount], cookieCount: Int, setCookieCount: Int,
                    authorizationCount: Int) {
            self.cookieNames = cookieNames; self.setCookieNames = setCookieNames; self.cookieCount = cookieCount
            self.setCookieCount = setCookieCount; self.authorizationCount = authorizationCount
        }
    }

    public var version: String?
    /// The tool that wrote it (`creator.name` and version).
    public var creator: String?
    public var pages: Int
    public var entries: [Entry]
    public var totalEntries: Int
    /// Host → requests, most first.
    public var hosts: [InfraNameCount]
    /// From the earliest start to the latest end, in milliseconds.
    public var totalTimeMs: Double
    /// Sum of response sizes that are known.
    public var totalResponseBytes: Int
    /// Requests with a body (`postData`), which may hold form fields or passwords.
    public var requestsWithBody: Int
    public var credentials: Credentials
    public var headline: String
    public var facts: [InfraFact]
    public var warnings: [InfraWarning]
    public var truncated: Bool
}

enum HARReader {
    /// The longest time one entry may claim: 30 days in milliseconds. Longer is not a request (a HAR's `time` is
    /// how long one request took) and is read as unknown.
    static let maxEntryMilliseconds: Double = 30 * 24 * 60 * 60 * 1000

    /// "1,234 ms". Converted to an integer only when the value fits one; otherwise it is shown as a plain number,
    /// never trapped on.
    static func millisecondsText(_ ms: Double) -> String {
        let rounded = ms.rounded()
        if rounded.isFinite, let whole = Int64(exactly: rounded) {
            return Duration.milliseconds(whole).formatted(.units(allowed: [.milliseconds], width: .abbreviated))
        }
        return Measurement(value: ms, unit: UnitDuration.milliseconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.significantDigits(3))))
    }

    static func read(_ parsed: InfraParse.Result, capped: Bool) -> HARSummary? {
        guard let root = parsed.roots.first, let log = root["log"], log.isObject else { return nil }
        guard let entriesNode = log["entries"], entriesNode.isArray || log["creator"] != nil else { return nil }
        var truncated = capped || !parsed.complete

        let parser = HARDates()
        var raw: [(start: Date?, entry: HARSummary.Entry)] = []
        var total = 0
        var hosts = NameCounter()
        var cookies = NameCounter(), setCookies = NameCounter()
        var authorization = 0, withBody = 0, bytes = 0
        var earliest: Date?, latestEnd: Date?

        for e in entriesNode.items where e.isObject {
            total += 1
            let request = e["request"], response = e["response"]
            let (host, path) = split(url: request?["url"]?.text ?? "")
            hosts.add(host.isEmpty ? String(localized: "(no host)", bundle: .module, comment: "Host shown for a HAR request whose URL has no host.") : host)
            let start = e["startedDateTime"]?.text.flatMap(parser.date)
            var duration = e["time"]?.double
            // A negative, non-finite or implausible time (past `maxEntryMilliseconds`) is unknown, not a number to
            // add up: 1e300 ms is no request's duration, and it would carry the total past any integer.
            if let d = duration, d < 0 || !d.isFinite || d > Self.maxEntryMilliseconds { duration = nil }
            if let start {
                if earliest.map({ start < $0 }) ?? true { earliest = start }
                let end = start.addingTimeInterval((duration ?? 0) / 1000)
                if latestEnd.map({ end > $0 }) ?? true { latestEnd = end }
            }
            var size = response?["content"]?["size"]?.int
            if size == nil || size! < 0 { size = response?["bodySize"]?.int }
            if let s = size, s < 0 { size = nil }
            // Sizes are the file's own numbers: the total stops at Int.max instead of trapping on overflow.
            let (sum, overflow) = bytes.addingReportingOverflow(size ?? 0)
            bytes = overflow ? .max : sum
            if request?["postData"] != nil { withBody += 1 }

            for c in request?["cookies"]?.items ?? [] { if let n = c["name"]?.text { cookies.add(InfraText.cut(n, 120)) } }
            for c in response?["cookies"]?.items ?? [] { if let n = c["name"]?.text { setCookies.add(InfraText.cut(n, 120)) } }
            let requestHasCookieList = !(request?["cookies"]?.items.isEmpty ?? true)
            let responseHasCookieList = !(response?["cookies"]?.items.isEmpty ?? true)
            for h in request?["headers"]?.items ?? [] {
                switch h["name"]?.text?.lowercased() {
                case "authorization", "proxy-authorization": authorization += 1
                case "cookie" where !requestHasCookieList:
                    for name in cookieNames(h["value"]?.string ?? "") { cookies.add(name) }
                default: break
                }
            }
            for h in response?["headers"]?.items ?? [] where h["name"]?.text?.lowercased() == "set-cookie" && !responseHasCookieList {
                // A HAR may fold several Set-Cookie headers into one value separated by newlines.
                for line in (h["value"]?.string ?? "").split(whereSeparator: \.isNewline) {
                    if let name = cookieNames(String(line)).first { setCookies.add(name) }
                }
            }
            if raw.count < InfraReader.maxItems {
                let status = response?["status"]?.int ?? 0
                raw.append((start, .init(startOffsetMs: nil, durationMs: duration, method: InfraText.cut(request?["method"]?.text ?? "?", 16),
                                         status: status, host: host, path: path, responseSize: size,
                                         mimeType: response?["content"]?["mimeType"]?.text.map { InfraText.cut($0, 80) })))
            } else {
                truncated = true
            }
        }
        let entries = raw.map { item -> HARSummary.Entry in
            var entry = item.entry
            if let start = item.start, let earliest { entry.startOffsetMs = (start.timeIntervalSince(earliest) * 1000).rounded() }
            return entry
        }
        let totalTime = earliest.flatMap { e in latestEnd.map { max(0, $0.timeIntervalSince(e) * 1000) } } ?? 0
        truncated = truncated || hosts.truncated || cookies.truncated || setCookies.truncated

        let credentials = HARSummary.Credentials(cookieNames: cookies.sorted, setCookieNames: setCookies.sorted,
                                                 cookieCount: cookies.total, setCookieCount: setCookies.total,
                                                 authorizationCount: authorization)
        var warnings = WarningList()
        if authorization > 0 {
            warnings.add(.danger, .authorizationHeaders,
                         String(localized: "\(authorization) Authorization headers are saved in plain text; anyone with this file can reuse them while they are valid.", bundle: .module, comment: "Infra card warning (danger) on an HTTP archive (HAR); Authorization is an HTTP header name, kept as written. Values are never shown."))
        }
        if cookies.total + setCookies.total > 0 {
            let cookieCount = cookies.total + setCookies.total
            warnings.add(.caution, .cookies, String(localized: "\(cookieCount) cookies are saved in plain text, which can include session logins.", bundle: .module, comment: "Infra card warning on an HTTP archive (HAR): cookies sent or set in the capture. Values are never shown."))
        }

        let version = log["version"]?.text
        let creator = log["creator"].flatMap { c in c["name"]?.text.map { name in [name, c["version"]?.text].compactMap { $0 }.joined(separator: " ") } }
        let pages = log["pages"]?.count ?? 0
        let hostList = hosts.sorted
        var facts: [InfraFact] = [
            .init(id: "requests", label: String(localized: "Requests", bundle: .module, comment: "Infra card fact label: HTTP requests in a HAR capture."), value: total.formatted()),
            .init(id: "hosts", label: String(localized: "Hosts", bundle: .module, comment: "Infra card fact label: distinct servers a HAR capture talked to."), value: hostList.count.formatted()),
            .init(id: "totalTime", label: String(localized: "Total time", bundle: .module, comment: "Infra card fact label: time from the first request's start to the last one's end."),
                  value: Self.millisecondsText(totalTime)),
            .init(id: "responseBytes", label: String(localized: "Response bytes", bundle: .module, comment: "Infra card fact label: total size of the response bodies."), value: bytes.formatted(.byteCount(style: .file))),
        ]
        if let creator { facts.append(.init(id: "creator", label: String(localized: "Captured by", bundle: .module, comment: "Infra card fact label: the tool that wrote the HAR file."), value: InfraText.cut(creator, 120))) }
        if pages > 0 { facts.append(.init(id: "pages", label: String(localized: "Pages", bundle: .module, comment: "Infra card fact label: web pages recorded in a HAR capture."), value: pages.formatted())) }
        if withBody > 0 { facts.append(.init(id: "requestBodies", label: String(localized: "Requests with a body", bundle: .module, comment: "Infra card fact label: requests that sent data (forms, uploads)."), value: withBody.formatted())) }
        let cookieTotal = cookies.total + setCookies.total
        facts.append(.init(id: "credentials", label: String(localized: "Cookies / Authorization", bundle: .module, comment: "Infra card fact label: cookies and Authorization headers in a HAR capture; Authorization is an HTTP header name."),
                           value: String(localized: "\(cookieTotal) / \(authorization) (names only)", bundle: .module, comment: "Infra card fact value: cookie count, then Authorization header count; only their names are kept.")))

        let hostCount = hostList.count
        let headline = String(localized: "HTTP archive · \(total) requests · \(hostCount) hosts", bundle: .module, comment: "Infra card headline for an HTTP archive (HAR): request count and distinct host count.")
        return HARSummary(version: version, creator: creator, pages: pages, entries: entries, totalEntries: total, hosts: hostList,
                          totalTimeMs: totalTime.rounded(), totalResponseBytes: bytes, requestsWithBody: withBody,
                          credentials: credentials, headline: headline, facts: facts, warnings: warnings.sorted, truncated: truncated)
    }

    /// Host and display path of a URL; the query keeps parameter names only, the fragment and any user info are
    /// dropped.
    static func split(url: String) -> (host: String, path: String) {
        var rest = Substring(url)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] } else if rest.hasPrefix("data:") {
            return (String(localized: "(data)", bundle: .module, comment: "Host shown for a HAR request to an inline data: URL, which has no server."), "data:")
        }
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        var tail = rest[authorityEnd...]
        if let hash = tail.firstIndex(of: "#") { tail = tail[..<hash] }
        var path = String(tail)
        if let q = tail.firstIndex(of: "?") {
            let names = tail[tail.index(after: q)...].split(separator: "&").prefix(50).map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "" }
            path = String(tail[..<q]) + (names.isEmpty ? "" : "?" + names.joined(separator: "&"))
        }
        if path.isEmpty { path = "/" }
        return (InfraText.cut(String(authority).lowercased(), 200), InfraText.cut(path, 120))
    }

    /// `a=1; b=2` → `[a, b]`; for a Set-Cookie line only the first pair is the cookie.
    static func cookieNames(_ header: String) -> [String] {
        header.split(separator: ";").prefix(100).compactMap { pair in
            let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? nil : InfraText.cut(name, 120)
        }
    }
}

/// ISO 8601 dates as HAR writes them, with or without fractional seconds.
struct HARDates {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }
}
