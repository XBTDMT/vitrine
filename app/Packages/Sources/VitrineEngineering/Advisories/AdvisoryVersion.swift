import Foundation

// Version ordering and OSV range evaluation for the advisory engine (A-12, G-26). Two orderings: SemVer 2.0 (with a
// leading `v` allowed and build metadata ignored), and a conservative ordering for ECOSYSTEM ranges whose scheme is
// not SemVer (numeric dot segments, then known pre- and post-release words, then text). Within one comparison set
// the ordering is chosen once, so sorting always sees a consistent total order. roadmap: S-22

/// One OSV range event. roadmap: S-22
struct OSVEvent: Sendable, Equatable {
    enum Kind: UInt8, Sendable { case introduced = 0, fixed = 1, lastAffected = 2, limit = 3 }
    var kind: Kind
    var version: String
}

/// One OSV range of a type the engine evaluates (GIT ranges are dropped while reading). roadmap: S-22
struct OSVRange: Sendable, Equatable {
    enum Kind: UInt8, Sendable { case semver = 1, ecosystem = 2 }
    var kind: Kind
    var events: [OSVEvent]
}

/// A SemVer 2.0 version. Numbers are kept as digit strings without leading zeros and compared by length, then by
/// digits, so arbitrarily long numbers never overflow. roadmap: S-22
struct SemVer: Comparable, Sendable {
    var core: [Substring]          // major, minor, patch
    var prerelease: [Substring]    // empty for a release

    /// Parses `v1.2.3-pre.1+build`. One or two core numbers are accepted and padded with zeros (OSV writes `1.2` now
    /// and then); anything else that does not fit returns nil.
    init?(_ raw: String) {
        var s = Substring(raw)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        var pre: Substring = ""
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...]
            s = s[..<dash]
            if pre.isEmpty { return nil }
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var core: [Substring] = []
        for p in parts {
            guard !p.isEmpty, p.utf8.count <= 64, p.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            core.append(SemVer.stripZeros(p))
        }
        while core.count < 3 { core.append("0") }
        var ids: [Substring] = []
        if !pre.isEmpty {
            for id in pre.split(separator: ".", omittingEmptySubsequences: false) {
                guard !id.isEmpty, id.utf8.count <= 128,
                      id.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D })
                else { return nil }
                ids.append(id)
            }
        }
        self.core = core
        self.prerelease = ids
    }

    static func stripZeros(_ s: Substring) -> Substring {
        let trimmed = s.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : trimmed
    }

    static func isNumeric(_ s: Substring) -> Bool { s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }

    /// Compares two digit strings without leading zeros.
    static func compareDigits(_ a: Substring, _ b: Substring) -> Int {
        if a.utf8.count != b.utf8.count { return a.utf8.count < b.utf8.count ? -1 : 1 }
        return a == b ? 0 : (a < b ? -1 : 1)
    }

    static func compare(_ a: SemVer, _ b: SemVer) -> Int {
        for k in 0..<3 {
            let c = compareDigits(a.core[k], b.core[k])
            if c != 0 { return c }
        }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        case (false, false): break
        }
        for k in 0..<min(a.prerelease.count, b.prerelease.count) {
            let x = a.prerelease[k], y = b.prerelease[k]
            let xn = isNumeric(x), yn = isNumeric(y)
            let c: Int
            if xn && yn { c = compareDigits(stripZeros(x), stripZeros(y)) }
            else if xn { c = -1 }                       // numeric identifiers sort before alphanumeric ones
            else if yn { c = 1 }
            else { c = x == y ? 0 : (x < y ? -1 : 1) }  // ASCII order
            if c != 0 { return c }
        }
        return a.prerelease.count == b.prerelease.count ? 0 : (a.prerelease.count < b.prerelease.count ? -1 : 1)
    }

    static func < (a: SemVer, b: SemVer) -> Bool { compare(a, b) < 0 }
    static func == (a: SemVer, b: SemVer) -> Bool { compare(a, b) == 0 }
}

/// The conservative ordering for ECOSYSTEM ranges that are not SemVer (PyPI, RubyGems, Packagist …). A version is
/// split into numbers and words at every non-alphanumeric character and at every digit/letter boundary, after a
/// leading `v`. Positions compare by rank: dev < alpha/a < beta/b < rc/c/pre/preview < other words < (end) <
/// post/p/patch/r/rev < numbers. Numbers compare numerically, other words case-insensitively, and trailing zero
/// numbers equal the end (`1.0` == `1.0.0`). roadmap: S-22
enum ConservativeVersion {
    enum Token: Equatable {
        case number(Substring)   // without leading zeros
        case word(String)        // lowercased
    }

    static func tokens(_ raw: String) -> [Token] {
        var s = Substring(raw)
        if s.first == "v" || s.first == "V", s.dropFirst().first?.isNumber == true { s = s.dropFirst() }
        var out: [Token] = []
        var start: Substring.Index? = nil
        var digits = false
        func flush(_ end: Substring.Index) {
            guard let st = start else { return }
            let piece = s[st..<end]
            out.append(digits ? .number(SemVer.stripZeros(piece)) : .word(piece.lowercased()))
            start = nil
        }
        var i = s.startIndex
        while i < s.endIndex, out.count < 64 {
            let c = s[i]
            let isDigit = c.isASCII && c.isNumber
            let isLetter = c.isASCII && c.isLetter
            if isDigit || isLetter {
                if start != nil, isDigit != digits { flush(i) }
                if start == nil { start = i; digits = isDigit }
            } else {
                flush(i)
            }
            i = s.index(after: i)
        }
        flush(i)
        return out
    }

    /// The rank of a position; numbers and the end have fixed ranks, words by their meaning.
    private static func rank(_ t: Token?) -> Int {
        switch t {
        case nil: return 5
        case .number?: return 7
        case .word(let w)?:
            switch w {
            case "dev": return 0
            case "a", "alpha": return 1
            case "b", "beta": return 2
            case "c", "rc", "pre", "preview": return 3
            case "post", "p", "pl", "patch", "r", "rev": return 6
            default: return 4
            }
        }
    }

    static func compare(_ a: String, _ b: String) -> Int {
        let x = tokens(a), y = tokens(b)
        var i = 0
        while i < max(x.count, y.count) {
            let p = i < x.count ? x[i] : nil
            let q = i < y.count ? y[i] : nil
            i += 1
            // A trailing zero number equals the end.
            if p == nil, case .number("0")? = q { continue }
            if q == nil, case .number("0")? = p { continue }
            let rp = rank(p), rq = rank(q)
            if rp != rq { return rp < rq ? -1 : 1 }
            switch (p, q) {
            case (.number(let m)?, .number(let n)?):
                let c = SemVer.compareDigits(m, n)
                if c != 0 { return c }
            case (.word(let m)?, .word(let n)?):
                if m != n { return m < n ? -1 : 1 }
            default: break
            }
        }
        return 0
    }
}

/// Compares versions for one ecosystem and range type, with the ordering fixed for a whole comparison set.
/// roadmap: S-22
struct VersionOrdering: Sendable {
    let semver: Bool

    /// SemVer when the range is SEMVER, or ECOSYSTEM in a SemVer ecosystem, and every version in the set parses
    /// as SemVer (the `"0"` and `"*"` sentinels excepted); the conservative ordering otherwise.
    init(ecosystem: OSVEcosystem, kind: OSVRange.Kind, versions: [String]) {
        if kind == .semver || ecosystem.usesSemVer {
            semver = versions.allSatisfy { $0 == "0" || $0 == "*" || SemVer($0) != nil }
        } else {
            semver = false
        }
    }

    func compare(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        if semver, let x = SemVer(a), let y = SemVer(b) { return SemVer.compare(x, y) }
        return ConservativeVersion.compare(a, b)
    }

    /// Whether two versions name the same release, choosing the ordering for just this pair.
    static func equal(_ a: String, _ b: String, ecosystem: OSVEcosystem) -> Bool {
        if a == b { return true }
        if let x = SemVer(a), let y = SemVer(b) { return SemVer.compare(x, y) == 0 }
        if ecosystem.usesSemVer { return false }
        return ConservativeVersion.compare(a, b) == 0
    }

    /// Sorts and deduplicates versions under one ordering chosen for the whole list.
    static func sortedUnique(_ versions: [String], ecosystem: OSVEcosystem) -> [String] {
        let order = VersionOrdering(ecosystem: ecosystem, kind: .ecosystem, versions: versions)
        var out: [String] = []
        for v in versions.sorted(by: { order.compare($0, $1) < 0 }) where out.last.map({ order.compare($0, v) != 0 }) ?? true {
            out.append(v)
        }
        return out
    }
}

enum OSVRangeEvaluator {
    /// OSV's evaluation algorithm (schema 1.6): with `limit` events, the version must be below at least one limit;
    /// then the remaining events, sorted by version (`introduced: "0"` first, introduced before fixed at the same
    /// version), are walked in order: introduced at or below the version opens the range, fixed at or below it
    /// closes it, last_affected below it closes it.
    static func isAffected(_ version: String, range: OSVRange, ecosystem: OSVEcosystem) -> Bool {
        var all = range.events.map(\.version)
        all.append(version)
        let order = VersionOrdering(ecosystem: ecosystem, kind: range.kind, versions: all)
        let limits = range.events.filter { $0.kind == .limit }
        if !limits.isEmpty, !limits.contains(where: { $0.version == "*" || order.compare(version, $0.version) < 0 }) {
            return false
        }
        let events = range.events.filter { $0.kind != .limit }.sorted { a, b in
            let a0 = a.kind == .introduced && a.version == "0", b0 = b.kind == .introduced && b.version == "0"
            if a0 != b0 { return a0 }
            if !a0 {
                let c = order.compare(a.version, b.version)
                if c != 0 { return c < 0 }
            }
            return a.kind.rawValue < b.kind.rawValue
        }
        var vulnerable = false
        for e in events {
            switch e.kind {
            case .introduced:
                if e.version == "0" || order.compare(version, e.version) >= 0 { vulnerable = true }
            case .fixed:
                if order.compare(version, e.version) >= 0 { vulnerable = false }
            case .lastAffected:
                if order.compare(version, e.version) > 0 { vulnerable = false }
            case .limit:
                break
            }
        }
        return vulnerable
    }
}
