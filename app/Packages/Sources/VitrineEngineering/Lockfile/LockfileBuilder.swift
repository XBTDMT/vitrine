import Foundation

/// Where one package comes from, as a format reader classified it: the kind, the host (already stripped of any user
/// or password), a short label for the package row, and for git whether a commit is recorded. roadmap: S-22
struct LockfileOrigin: Equatable {
    var kind: LockfileSummary.Source.Kind
    var host: String?
    var label: String?
    var commit: Bool = false

    static let unknown = LockfileOrigin(kind: .unknown, host: nil, label: nil)
    static let defaultRegistry = LockfileOrigin(kind: .registry, host: nil, label: nil)
    static func registry(_ host: String?) -> LockfileOrigin { LockfileOrigin(kind: .registry, host: host, label: host) }
    static func git(_ host: String?, commit: Bool) -> LockfileOrigin { LockfileOrigin(kind: .git, host: host, label: host, commit: commit) }
    static func url(_ host: String?) -> LockfileOrigin { LockfileOrigin(kind: .url, host: host, label: host) }
    static func path(_ path: String?) -> LockfileOrigin {
        LockfileOrigin(kind: .path, host: nil, label: path.map { LockfileText.capped($0, 160) })
    }
}

/// Collects packages as a format reader finds them and makes the summary: the capped list, the true count, the
/// source groups, the pinning buckets and the licence counts. Each format reader fills one and calls `summary()`.
/// roadmap: S-22
struct LockfileBuilder {
    let ecosystem: LockfileSummary.Ecosystem
    var formatVersion: String?
    /// Set by a reader whose format records which packages are direct; `directCount` stays nil otherwise.
    var directKnown = false
    /// Set by a reader whose format carries licences; `licences` stays nil otherwise.
    var carriesLicences = false
    var truncated = false

    private(set) var packages: [LockfileSummary.Package] = []
    private(set) var total = 0
    private var direct = 0
    private var pinning = LockfileSummary.Pinning()
    private var licenceCounts: [String: Int] = [:]
    private var sourceCounts: [SourceKey: Int] = [:]
    private var seen: Set<String> = []

    private struct SourceKey: Hashable { var kind: LockfileSummary.Source.Kind; var host: String? }

    init(_ ecosystem: LockfileSummary.Ecosystem) { self.ecosystem = ecosystem }

    /// Counts one package. `exact` says the version is one fixed version (not a range, a branch or a URL); a reader
    /// that knows better than `LockfileText.looksExact` passes its own answer. `dedupKey`, when given, makes a second
    /// package with the same key a no-op (pnpm's peer variants, go.sum's repeated lines, platform builds).
    mutating func add(name: String, version: String?, origin: LockfileOrigin, integrity: Bool, isDirect: Bool?,
                      licence: String? = nil, exact: Bool? = nil, dedupKey: String? = nil, locator: String? = nil) {
        if let dedupKey {
            guard seen.insert(dedupKey).inserted else { return }
        }
        let name = LockfileText.capped(name, 256)
        let version = version.map { LockfileText.capped($0, 128) }
        let licence = licence.map { LockfileText.capped($0, 100) }.flatMap { $0.isEmpty ? nil : $0 }
        total += 1
        if isDirect == true { direct += 1 }

        switch origin.kind {
        case .git: if origin.commit { pinning.gitWithCommit += 1 } else { pinning.gitWithoutCommit += 1 }
        case .path: pinning.unpinned += 1
        case .url: if integrity { pinning.withIntegrity += 1 } else { pinning.unpinned += 1 }
        default:
            if integrity { pinning.withIntegrity += 1 }
            else if exact ?? LockfileText.looksExact(version) { pinning.exact += 1 }
            else { pinning.unpinned += 1 }
        }
        sourceCounts[SourceKey(kind: origin.kind, host: origin.host), default: 0] += 1
        if carriesLicences, let licence { licenceCounts[licence, default: 0] += 1 }

        if packages.count < LockfileReader.maxPackages {
            packages.append(LockfileSummary.Package(name: name, version: version, source: origin.label,
                                                    sourceKind: origin.kind, isDirect: isDirect,
                                                    integrity: integrity, licence: licence,
                                                    locator: locator.map { LockfileText.capped(Self.withoutCredentials($0), 512) }))
        } else {
            truncated = true
        }
    }

    /// `https://user:token@host/path` → `https://host/path`: a locator never keeps credentials.
    static func withoutCredentials(_ url: String) -> String {
        guard var parts = URLComponents(string: url), parts.user != nil || parts.password != nil else { return url }
        parts.user = nil; parts.password = nil
        return parts.string ?? url
    }

    func summary() -> LockfileSummary {
        let sources = sourceCounts.map { LockfileSummary.Source(kind: $0.key.kind, host: $0.key.host, count: $0.value) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
                return (a.host ?? "") < (b.host ?? "")
            }
        return LockfileSummary(ecosystem: ecosystem, formatVersion: formatVersion, packages: packages,
                               totalPackages: total, directCount: directKnown ? direct : nil, sources: sources,
                               pinning: pinning, licences: carriesLicences && !licenceCounts.isEmpty ? licenceCounts : nil, truncated: truncated)
    }
}

/// Small text helpers shared by the format readers: hosts out of URLs, commits out of fragments, exact versions,
/// name@version splitting. All of them scan by hand (no regular expressions) and bound what they keep.
/// roadmap: S-22
enum LockfileText {
    static func capped(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }

    /// The host of a URL or a git location, lowercased, without user, password or port: `https://u:p@h:1/x`,
    /// `git+ssh://git@h/x.git`, `git@h:owner/x.git`, `github:owner/x`. nil when there is no plausible host.
    static func host(_ raw: String) -> String? {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        for (prefix, host) in [("github:", "github.com"), ("gitlab:", "gitlab.com"), ("bitbucket:", "bitbucket.org"),
                               ("gist:", "gist.github.com")] where s.hasPrefix(prefix) {
            return host
        }
        if let scheme = s.range(of: "://") {
            s = s[scheme.upperBound...]
        } else if let at = s.firstIndex(of: "@"), let colon = s[at...].firstIndex(of: ":"), !s[..<at].contains("/") {
            // scp form: git@github.com:owner/repo.git
            s = s[s.index(after: at)..<colon]
            return validHost(s)
        } else {
            return nil
        }
        let end = s.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? s.endIndex
        var authority = s[..<end]
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if authority.hasPrefix("[") { return nil }   // IPv6 literals are not worth a label
        if let colon = authority.firstIndex(of: ":") { authority = authority[..<colon] }
        return validHost(authority)
    }

    private static func validHost(_ s: Substring) -> String? {
        let h = s.lowercased()
        guard !h.isEmpty, h.count <= 253,
              h.unicodeScalars.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "." || $0 == "-" || $0 == "_" })
        else { return nil }
        return h
    }

    /// true for 7 to 64 hexadecimal characters: a full or abbreviated commit.
    static func isCommit<S: StringProtocol>(_ s: S) -> Bool {
        (7...64).contains(s.count) && s.unicodeScalars.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") || ($0 >= "A" && $0 <= "F") }
    }

    /// Whether a git location records a commit: a `#<hex>` fragment, `#commit=<hex>` (yarn berry) or a
    /// `rev=`/`commit=` query value that is a commit.
    static func gitHasCommit(_ location: String) -> Bool {
        if let hash = location.lastIndex(of: "#") {
            let fragment = location[location.index(after: hash)...]
            if isCommit(fragment) { return true }
            for part in fragment.split(separator: "&") where part.hasPrefix("commit=") {
                if isCommit(part.dropFirst("commit=".count)) { return true }
            }
        }
        return false
    }

    /// A git location as npm, yarn and bun write it: `git+…`, `git://…`, `github:…`, `git@host:…`, or an https URL
    /// to a `.git` repository.
    static func looksGit(_ s: String) -> Bool {
        s.hasPrefix("git+") || s.hasPrefix("git://") || s.hasPrefix("git@") || s.hasPrefix("github:") ||
            s.hasPrefix("gitlab:") || s.hasPrefix("bitbucket:") || s.hasPrefix("gist:") || s.contains(".git#") || s.hasSuffix(".git")
    }

    /// One fixed version: starts with a digit (or v and a digit) and has no range characters.
    static func looksExact(_ version: String?) -> Bool {
        guard var v = version?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return false }
        if v.hasPrefix("==") { v.removeFirst(2) }
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        guard let first = v.unicodeScalars.first, first >= "0", first <= "9" else { return false }
        return !v.contains { "^~<>=*| ,".contains($0) } && !v.contains("://")
    }

    /// Splits `name@spec` at the first `@` after the first character, so `@scope/name@1.0.0` keeps its scope.
    static func splitNameAt(_ s: Substring) -> (name: String, spec: String?) {
        guard s.count > 1, let at = s.dropFirst().firstIndex(of: "@") else { return (String(s), nil) }
        return (String(s[..<at]), String(s[s.index(after: at)...]))
    }

    /// The last component of a slash path, for names out of `node_modules/…` keys and folder paths.
    static func lastComponent(_ s: Substring) -> Substring {
        guard let slash = s.lastIndex(of: "/") else { return s }
        return s[s.index(after: slash)...]
    }

    /// The text decoded as UTF-8 (invalid bytes replaced), without a byte-order mark, line ends normalised to \n.
    static func decode(_ bytes: [UInt8]) -> String {
        var slice = bytes[...]
        if slice.starts(with: [0xEF, 0xBB, 0xBF]) { slice = slice.dropFirst(3) }
        let s = String(decoding: slice, as: UTF8.self)
        return s.contains("\r") ? s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : s
    }
}
