import Foundation

/// One security advisory as a lockfile card shows it (A-12, G-26): its OSV id, aliases, a short summary, how severe
/// the database says it is, whether it reports a malicious package, and the versions that fix it. Read from OSV
/// records on this Mac; nothing is looked up over the network. roadmap: S-22
public struct Advisory: Sendable, Equatable, Codable {
    /// How severe an advisory is, lowest first; `.unknown` when the record gives no usable severity. roadmap: S-22
    public enum Severity: String, Sendable, Codable, Comparable {
        case unknown, low, moderate, high, critical

        var rank: Int {
            switch self {
            case .unknown: return 0
            case .low: return 1
            case .moderate: return 2
            case .high: return 3
            case .critical: return 4
            }
        }

        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    /// GHSA-…, PYSEC-…, RUSTSEC-…, GO-…, MAL-…
    public var id: String
    /// Other ids for the same advisory (CVE-…), at most 10.
    public var aliases: [String]
    /// The record's summary, or the first line of its details when it has none, on one line, at most 200 characters.
    public var summary: String?
    /// From `database_specific.severity`, else from the highest CVSS v3 base score in `severity`, else `.unknown`.
    public var severity: Severity
    /// The id starts with "MAL-": OSV's malicious-package reports.
    public var isMalicious: Bool
    /// The `fixed` versions of the ranges that matched, sorted by version, deduplicated, at most 5.
    public var fixed: [String]

    public init(id: String, aliases: [String], summary: String?, severity: Severity, isMalicious: Bool, fixed: [String]) {
        self.id = id
        self.aliases = aliases
        self.summary = summary
        self.severity = severity
        self.isMalicious = isMalicious
        self.fixed = fixed
    }

    /// Malicious first, then severity descending, then id, so the order is the same on every run.
    static func ordered(_ a: Advisory, _ b: Advisory) -> Bool {
        if a.isMalicious != b.isMalicious { return a.isMalicious }
        if a.severity != b.severity { return a.severity > b.severity }
        return a.id < b.id
    }
}

/// One locked package that has advisories in the database (A-12, G-26). roadmap: S-22
public struct AdvisoryMatch: Sendable, Equatable {
    public var package: String
    public var version: String
    /// Malicious first, then severity descending.
    public var advisories: [Advisory]

    public init(package: String, version: String, advisories: [Advisory]) {
        self.package = package
        self.version = version
        self.advisories = advisories
    }
}
