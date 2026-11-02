import Foundation

/// The OSV ecosystems a lockfile card can be checked against (A-12, G-26), spelled as OSV spells them: the folder
/// names of its bulk export (`<ECOSYSTEM>/all.zip`) and the `affected[].package.ecosystem` values inside the records.
/// roadmap: S-22
public enum OSVEcosystem: String, CaseIterable, Sendable, Codable {
    case npm = "npm", pypi = "PyPI", crates = "crates.io", go = "Go", rubygems = "RubyGems", packagist = "Packagist",
         swiftURL = "SwiftURL", pub = "Pub", hex = "Hex"

    /// The OSV ecosystem whose records describe a lockfile's packages: npm, yarn, pnpm and bun → npm; cargo →
    /// crates.io; bundler → RubyGems; poetry, uv and pipenv → PyPI; Go modules → Go; SwiftPM → SwiftURL; composer →
    /// Packagist; CocoaPods → nil (OSV has no CocoaPods ecosystem, so those lockfiles cannot be checked).
    public static func forLockfile(_ e: LockfileSummary.Ecosystem) -> OSVEcosystem? {
        switch e {
        case .npm, .yarn, .pnpm, .bun: return .npm
        case .cargo: return .crates
        case .bundler: return .rubygems
        case .poetry, .uv, .pipenv: return .pypi
        case .goModules: return .go
        case .swiftPM: return .swiftURL
        case .composer: return .packagist
        case .cocoapods: return nil
        }
    }

    /// The ecosystem's own version scheme is SemVer, so ECOSYSTEM ranges may be compared as SemVer when every
    /// version in play parses as one.
    var usesSemVer: Bool {
        switch self {
        case .npm, .crates, .go, .hex, .pub: return true
        case .pypi, .rubygems, .packagist, .swiftURL: return false
        }
    }

    /// A package name as this ecosystem compares it: PyPI per PEP 503 (lowercase, runs of `-`, `_`, `.` → `-`);
    /// Packagist lowercase; SwiftURL the repository URL lowercased without scheme, user, trailing `/` or `.git`;
    /// npm, crates.io, RubyGems, Hex, Pub and Go exactly as written (trimmed).
    func normalizedName(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .pypi:
            var out = ""
            out.reserveCapacity(name.utf8.count)
            var inRun = false
            for ch in name.lowercased() {
                if ch == "-" || ch == "_" || ch == "." {
                    if !inRun { out.append("-") }
                    inRun = true
                } else {
                    out.append(ch)
                    inRun = false
                }
            }
            return out
        case .packagist:
            return name.lowercased()
        case .swiftURL:
            var s = Substring(name.lowercased())
            if let scheme = s.range(of: "://") { s = s[scheme.upperBound...] }
            if let at = s.firstIndex(of: "@"), !s[..<at].contains("/") { s = s[s.index(after: at)...] }  // git@host or user@host
            if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") {                           // scp form host:owner/repo
                let after = s[s.index(after: colon)...]
                if !(after.first?.isNumber ?? false) { s = Substring(s[..<colon] + "/" + after) }
            }
            while s.hasSuffix("/") { s = s.dropLast() }
            if s.hasSuffix(".git") { s = s.dropLast(4) }
            while s.hasSuffix("/") { s = s.dropLast() }
            return String(s)
        case .npm, .crates, .go, .rubygems, .hex, .pub:
            return name
        }
    }

    /// A locked version as this ecosystem's advisories write it: RubyGems drops a platform suffix
    /// (`1.15.4-x86_64-linux` → `1.15.4`); every ecosystem trims whitespace.
    func normalizedVersion(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if self == .rubygems, let dash = v.firstIndex(of: "-") { return String(v[..<dash]) }
        return v
    }
}
