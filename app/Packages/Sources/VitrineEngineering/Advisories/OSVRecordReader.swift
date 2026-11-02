import Foundation

/// One `affected` entry of an OSV record, reduced to what matching needs: the normalised package name, the
/// enumerated versions and the SEMVER/ECOSYSTEM ranges. roadmap: S-22
struct OSVAffected: Sendable, Equatable {
    var name: String
    var versions: [String]
    var ranges: [OSVRange]
}

/// What one OSV record contributes to an index (A-12, G-26). roadmap: S-22
struct OSVRecord: Sendable {
    var advisory: Advisory          // `fixed` stays empty; it depends on the ranges that match a version
    var affected: [OSVAffected]
}

/// Reads OSV records (schema 1.6) as untrusted bytes: at most `maxRecordBytes`, parsed by the bounded lockfile JSON
/// reader (no recursion past its depth limit, never throws), with every list and string capped. roadmap: S-22
enum OSVRecordReader {
    static let maxRecordBytes = 1 << 20
    static let maxSummary = 200
    static let maxAliases = 10
    static let maxIDLength = 128
    static let maxNameLength = 1024
    static let maxVersionLength = 256
    static let maxAffected = 10_000
    static let maxRanges = 256
    static let maxEvents = 2_048
    static let maxVersions = 50_000

    enum Outcome {
        case record(OSVRecord)
        /// Withdrawn, or no `affected` entry for this ecosystem: skipped, not counted as unreadable.
        case notApplicable
        /// Too large, not JSON, not an object, or without an id: counted in `skippedRecords`.
        case unreadable
    }

    static func read(_ data: Data, ecosystem: OSVEcosystem) -> Outcome {
        guard !data.isEmpty, data.count <= maxRecordBytes else { return .unreadable }
        let (parsed, complete) = LockJSONReader.parse([UInt8](data))
        guard complete, let root = parsed, root.members != nil else { return .unreadable }
        guard let id = root["id"]?.string, !id.isEmpty, id.utf8.count <= maxIDLength else { return .unreadable }
        if let withdrawn = root["withdrawn"], !isNull(withdrawn) { return .notApplicable }

        var affected: [OSVAffected] = []
        var entrySeverity: Advisory.Severity?
        for entry in (root["affected"]?.array ?? []).prefix(maxAffected) {
            guard let package = entry["package"], package["ecosystem"]?.string == ecosystem.rawValue,
                  let rawName = package["name"]?.string, !rawName.isEmpty, rawName.utf8.count <= maxNameLength else { continue }
            let name = ecosystem.normalizedName(rawName)
            guard !name.isEmpty else { continue }
            var versions: [String] = []
            for v in (entry["versions"]?.array ?? []).prefix(maxVersions) {
                if let s = v.string, let clean = cleanVersion(s) { versions.append(clean) }
            }
            var ranges: [OSVRange] = []
            for r in (entry["ranges"]?.array ?? []).prefix(maxRanges) {
                let kind: OSVRange.Kind
                switch r["type"]?.string {
                case "SEMVER": kind = .semver
                case "ECOSYSTEM": kind = .ecosystem
                default: continue                     // GIT ranges name commits, not versions
                }
                var events: [OSVEvent] = []
                for e in (r["events"]?.array ?? []).prefix(maxEvents) {
                    let pairs: [(String, OSVEvent.Kind)] = [("introduced", .introduced), ("fixed", .fixed),
                                                            ("last_affected", .lastAffected), ("limit", .limit)]
                    for (key, k) in pairs {
                        if let s = e[key]?.string, let clean = cleanVersion(s) { events.append(OSVEvent(kind: k, version: clean)) }
                    }
                }
                if !events.isEmpty { ranges.append(OSVRange(kind: kind, events: events)) }
            }
            guard !versions.isEmpty || !ranges.isEmpty else { continue }
            affected.append(OSVAffected(name: name, versions: versions, ranges: ranges))
            for key in ["database_specific", "ecosystem_specific"] {
                if let s = entry[key]?["severity"]?.string.flatMap(severityWord) { entrySeverity = max(entrySeverity ?? s, s) }
            }
        }
        guard !affected.isEmpty else { return .notApplicable }

        var aliases: [String] = []
        for a in root["aliases"]?.array ?? [] {
            guard aliases.count < maxAliases else { break }
            if let s = a.string.map(oneLine), !s.isEmpty, s.utf8.count <= maxIDLength, !aliases.contains(s) { aliases.append(s) }
        }

        let advisory = Advisory(id: oneLine(id), aliases: aliases, summary: summary(root),
                                severity: severity(root, entrySeverity: entrySeverity),
                                isMalicious: id.hasPrefix("MAL-"), fixed: [])
        return .record(OSVRecord(advisory: advisory, affected: affected))
    }

    private static func isNull(_ v: LockJSON) -> Bool {
        if case .null = v { return true }
        return false
    }

    /// A version string as stored: trimmed, non-empty, at most `maxVersionLength` bytes.
    private static func cleanVersion(_ s: String) -> String? {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, v.utf8.count <= maxVersionLength else { return nil }
        return v
    }

    /// Control characters and line breaks become single spaces.
    static func oneLine(_ s: String) -> String {
        var out = ""
        var space = false
        for scalar in s.unicodeScalars {
            if scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == " " {
                space = true
                continue
            }
            if space, !out.isEmpty { out.append(" ") }
            space = false
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// The summary, else the first non-empty line of the details, on one line and capped.
    private static func summary(_ root: LockJSON) -> String? {
        var text = root["summary"]?.string.map(oneLine) ?? ""
        if text.isEmpty, let details = root["details"]?.string {
            let line = details.prefix(4096).split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            text = line.map { oneLine(String($0)) } ?? ""
        }
        guard !text.isEmpty else { return nil }
        if text.count > maxSummary { text = String(text.prefix(maxSummary - 1)) + "…" }
        return text
    }

    private static func severityWord(_ s: String) -> Advisory.Severity? {
        switch s.lowercased() {
        case "critical": return .critical
        case "high": return .high
        case "moderate", "medium": return .moderate
        case "low": return .low
        default: return nil
        }
    }

    /// `database_specific.severity`, then an affected entry's severity word, then the highest CVSS v3 base score in
    /// the record's or its entries' `severity` lists, then `.unknown`.
    private static func severity(_ root: LockJSON, entrySeverity: Advisory.Severity?) -> Advisory.Severity {
        if let s = root["database_specific"]?["severity"]?.string.flatMap(severityWord) { return s }
        if let s = entrySeverity { return s }
        var lists = [root["severity"]?.array ?? []]
        for entry in (root["affected"]?.array ?? []).prefix(maxAffected) { lists.append(entry["severity"]?.array ?? []) }
        var best: Double?
        for item in lists.joined().prefix(1_000) {
            guard let type = item["type"]?.string, type == "CVSS_V3", let score = item["score"]?.string else { continue }
            let value = CVSSScore.v3BaseScore(score) ?? Double(score).flatMap { (0...10).contains($0) ? $0 : nil }
            if let v = value { best = max(best ?? v, v) }
        }
        return best.map(CVSSScore.severity) ?? .unknown
    }
}
