import Foundation
import Testing
@testable import VitrineEngineering

// The advisory engine (A-12, G-26) on invented OSV records: every id (GHSA-xxxx-invented …), package name
// (harbor-utils, acme-notes …) and version below is made up and written by hand in OSV schema 1.6's shape; none is
// real advisory data. Nothing here runs git or touches the network; files go to a fresh temporary folder.
// roadmap: S-22

/// One invented OSV record as JSON bytes.
private func record(id: String, ecosystem: String = "npm", name: String = "harbor-utils", ranges: String = "",
                    versions: [String] = [], extra: String = "") -> Data {
    let versionList = versions.map { "\"\($0)\"" }.joined(separator: ", ")
    let rangePart = ranges.isEmpty ? "" : ", \"ranges\": [\(ranges)]"
    let json = """
    { "schema_version": "1.6.0", "id": "\(id)", "modified": "2026-01-01T00:00:00Z"\(extra.isEmpty ? "" : ", " + extra),
      "affected": [ { "package": { "ecosystem": "\(ecosystem)", "name": "\(name)" },
                      "versions": [\(versionList)]\(rangePart) } ] }
    """
    return Data(json.utf8)
}

private func semver(_ events: String) -> String { "{ \"type\": \"SEMVER\", \"events\": [\(events)] }" }
private func ecosystemRange(_ events: String) -> String { "{ \"type\": \"ECOSYSTEM\", \"events\": [\(events)] }" }

private func makeIndex(_ eco: OSVEcosystem, _ records: [Data]) -> AdvisoryIndex {
    AdvisoryIndex.build(ecosystem: eco, records: records, sourceLastModified: nil)
}

private func makeIndex(_ records: [Data]) -> AdvisoryIndex { makeIndex(.npm, records) }

private func ids(_ i: AdvisoryIndex, _ name: String, _ version: String) -> [String] {
    i.advisories(name: name, version: version).map(\.id)
}

private func temporaryFile(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-advisory-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

@Suite("Advisory names and versions")
struct AdvisoryOrderingTests {
    @Test func pep503Normalisation() {
        #expect(OSVEcosystem.pypi.normalizedName("Harbor_Utils") == "harbor-utils")
        #expect(OSVEcosystem.pypi.normalizedName("harbor.-_utils") == "harbor-utils")
        #expect(OSVEcosystem.pypi.normalizedName("ACME--Notes__Kit") == "acme-notes-kit")
        #expect(OSVEcosystem.packagist.normalizedName("Acme/Harbor-Utils") == "acme/harbor-utils")
        #expect(OSVEcosystem.npm.normalizedName("@acme/harbor-utils") == "@acme/harbor-utils")
        #expect(OSVEcosystem.swiftURL.normalizedName("https://GitHub.com/acme/harbor-utils.git/") == "github.com/acme/harbor-utils")
        #expect(OSVEcosystem.swiftURL.normalizedName("git@github.com:acme/harbor-utils.git") == "github.com/acme/harbor-utils")
        #expect(OSVEcosystem.go.normalizedName("example.com/Acme/harbor") == "example.com/Acme/harbor")

        let i = makeIndex(.pypi, [record(id: "PYSEC-0000-invented", ecosystem: "PyPI", name: "Harbor.Utils",
                                     ranges: ecosystemRange("{\"introduced\": \"0\"}, {\"fixed\": \"2.0\"}"))])
        #expect(ids(i, "harbor_utils", "1.5") == ["PYSEC-0000-invented"])
        #expect(ids(i, "HARBOR-UTILS", "2.0").isEmpty)
    }

    @Test func semverOrderingWithPrereleases() throws {
        let chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
                     "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "v1.10.0", "2.0.0"]
        for (a, b) in zip(chain, chain.dropFirst()) {
            let x = try #require(SemVer(a)), y = try #require(SemVer(b))
            #expect(x < y, "\(a) < \(b)")
        }
        #expect(try #require(SemVer("1.0.0+build.5")) == (try #require(SemVer("1.0.0+other"))))
        #expect(try #require(SemVer("v2.0.0+incompatible")) == (try #require(SemVer("2.0.0"))))
        // Go pseudo-versions are SemVer prereleases and sort before the release they precede.
        let pseudo = try #require(SemVer("v0.0.0-20260101120000-abcdef123456"))
        #expect(pseudo < (try #require(SemVer("0.0.1"))))
        #expect(SemVer("not-a-version") == nil)
        #expect(SemVer("1.2.3.4") == nil)
        #expect(SemVer("99999999999999999999999.0.0")! > SemVer("9999999999999999999999.0.0")!)
    }

    @Test func conservativeOrdering() {
        #expect(ConservativeVersion.compare("1.0", "1.0.0") == 0)
        #expect(ConservativeVersion.compare("1.0a1", "1.0") < 0)
        #expect(ConservativeVersion.compare("1.0.dev1", "1.0a1") < 0)
        #expect(ConservativeVersion.compare("1.0rc1", "1.0") < 0)
        #expect(ConservativeVersion.compare("1.0.post1", "1.0") > 0)
        #expect(ConservativeVersion.compare("1.0.post1", "1.0.1") < 0)
        #expect(ConservativeVersion.compare("1.10", "1.9") > 0)
        #expect(ConservativeVersion.compare("v5.4.3", "5.4.3") == 0)
        #expect(ConservativeVersion.compare("2.0.0.pre", "2.0.0") < 0)
    }

    @Test func goPseudoVersionsAndIncompatibleDoNotCrash() {
        let i = makeIndex(.go, [record(id: "GO-0000-invented", ecosystem: "Go", name: "example.com/acme/harbor",
                                   ranges: semver("{\"introduced\": \"0\"}, {\"fixed\": \"1.4.0\"}"))])
        #expect(ids(i, "example.com/acme/harbor", "v0.0.0-20260101120000-abcdef123456") == ["GO-0000-invented"])
        #expect(ids(i, "example.com/acme/harbor", "v1.3.9+incompatible") == ["GO-0000-invented"])
        #expect(ids(i, "example.com/acme/harbor", "v1.4.0").isEmpty)
        #expect(ids(i, "example.com/acme/harbor", "v2.0.0+incompatible").isEmpty)
        #expect(ids(i, "example.com/acme/harbor", "garbage-version-!!").count <= 1)
    }
}

@Suite("Advisory events and records")
struct AdvisoryRecordTests {
    @Test func introducedFixedAndLastAffected() {
        let i = makeIndex([
            record(id: "GHSA-aaaa-invented", ranges: semver("{\"introduced\": \"1.2.0\"}, {\"fixed\": \"1.4.0\"}, {\"introduced\": \"2.0.0\"}, {\"fixed\": \"2.1.3\"}")),
            record(id: "GHSA-bbbb-invented", ranges: semver("{\"introduced\": \"0\"}, {\"last_affected\": \"1.2.5\"}")),
            record(id: "GHSA-cccc-invented", ranges: semver("{\"introduced\": \"3.0.0-beta.1\"}, {\"limit\": \"3.0.0\"}")),
        ])
        #expect(ids(i, "harbor-utils", "1.1.9") == ["GHSA-bbbb-invented"])
        #expect(Set(ids(i, "harbor-utils", "1.2.0")) == ["GHSA-aaaa-invented", "GHSA-bbbb-invented"])
        #expect(Set(ids(i, "harbor-utils", "1.2.5")) == ["GHSA-aaaa-invented", "GHSA-bbbb-invented"])
        #expect(ids(i, "harbor-utils", "1.2.6") == ["GHSA-aaaa-invented"])
        #expect(ids(i, "harbor-utils", "1.4.0").isEmpty)
        #expect(ids(i, "harbor-utils", "1.9.0").isEmpty)
        #expect(ids(i, "harbor-utils", "2.1.0-rc.1") == ["GHSA-aaaa-invented"])
        #expect(ids(i, "harbor-utils", "2.1.3").isEmpty)
        #expect(ids(i, "harbor-utils", "3.0.0-rc.1") == ["GHSA-cccc-invented"])
        #expect(ids(i, "harbor-utils", "3.0.0").isEmpty)
        #expect(ids(i, "harbor-utils", "2.9.9").isEmpty)
        #expect(ids(i, "other-pkg", "1.2.0").isEmpty)
        // Fixed versions come from the matching ranges, sorted by version.
        #expect(i.advisories(name: "harbor-utils", version: "1.3.0").first?.fixed == ["1.4.0", "2.1.3"])
        // Events out of order are sorted before the walk.
        let shuffled = makeIndex([record(id: "GHSA-dddd-invented", ranges: semver("{\"fixed\": \"1.4.0\"}, {\"introduced\": \"1.2.0\"}"))])
        #expect(ids(shuffled, "harbor-utils", "1.3.0") == ["GHSA-dddd-invented"])
        #expect(ids(shuffled, "harbor-utils", "1.5.0").isEmpty)
    }

    @Test func enumeratedVersionsOverrideEcosystemRanges() {
        let i = makeIndex(.pypi, [record(id: "PYSEC-1111-invented", ecosystem: "PyPI", name: "acme-notes",
                                     ranges: ecosystemRange("{\"introduced\": \"0\"}, {\"fixed\": \"2.0\"}"),
                                     versions: ["1.0", "1.1", "1.2rc1"])])
        #expect(ids(i, "acme-notes", "1.1") == ["PYSEC-1111-invented"])
        #expect(ids(i, "acme-notes", "1.1.0") == ["PYSEC-1111-invented"])      // PEP 440 equality
        #expect(ids(i, "acme-notes", "1.2rc1") == ["PYSEC-1111-invented"])
        #expect(ids(i, "acme-notes", "1.5").isEmpty)                         // inside the range, not listed
        #expect(i.advisories(name: "acme-notes", version: "1.0").first?.fixed == ["2.0"])
        // Without a list, the ECOSYSTEM range is evaluated with the conservative ordering.
        let unlisted = makeIndex(.pypi, [record(id: "PYSEC-2222-invented", ecosystem: "PyPI", name: "acme-notes",
                                            ranges: ecosystemRange("{\"introduced\": \"1.0\"}, {\"fixed\": \"1.10\"}"))])
        #expect(ids(unlisted, "acme-notes", "1.9") == ["PYSEC-2222-invented"])
        #expect(ids(unlisted, "acme-notes", "1.10.post1").isEmpty)
        #expect(ids(unlisted, "acme-notes", "1.10a1") == ["PYSEC-2222-invented"])
    }

    @Test func withdrawnAndOtherEcosystemRecordsAreSkipped() {
        let i = makeIndex([
            record(id: "GHSA-wwww-invented", ranges: semver("{\"introduced\": \"0\"}"), extra: "\"withdrawn\": \"2026-02-01T00:00:00Z\""),
            record(id: "GHSA-pppp-invented", ecosystem: "PyPI", ranges: ecosystemRange("{\"introduced\": \"0\"}")),
            record(id: "GHSA-kkkk-invented", ranges: semver("{\"introduced\": \"0\"}")),
            record(id: "GHSA-gggg-invented", ranges: "{ \"type\": \"GIT\", \"repo\": \"https://example.com/x\", \"events\": [{\"introduced\": \"0\"}] }"),
        ])
        #expect(ids(i, "harbor-utils", "1.0.0") == ["GHSA-kkkk-invented"])
        #expect(i.meta.records == 1)
        #expect(i.meta.packages == 1)
        #expect(i.skippedRecords == 0)
    }

    @Test func maliciousRecordsAreFlaggedAndFirst() throws {
        let i = makeIndex([
            record(id: "MAL-2026-0001-invented", ranges: semver("{\"introduced\": \"0\"}")),
            record(id: "GHSA-hhhh-invented", ranges: semver("{\"introduced\": \"0\"}"),
                   extra: "\"database_specific\": { \"severity\": \"CRITICAL\" }"),
        ])
        let found = i.advisories(name: "harbor-utils", version: "0.1.0")
        #expect(found.map(\.id) == ["MAL-2026-0001-invented", "GHSA-hhhh-invented"])
        #expect(found[0].isMalicious && !found[1].isMalicious)
    }

    @Test func severityFromDatabaseSpecificAndCVSS() throws {
        let i = makeIndex([
            record(id: "GHSA-s001-invented", name: "a-pkg", ranges: semver("{\"introduced\": \"0\"}"),
                   extra: "\"database_specific\": { \"severity\": \"MODERATE\" }, \"severity\": [{ \"type\": \"CVSS_V3\", \"score\": \"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H\" }]"),
            record(id: "GHSA-s002-invented", name: "b-pkg", ranges: semver("{\"introduced\": \"0\"}"),
                   extra: "\"severity\": [{ \"type\": \"CVSS_V3\", \"score\": \"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H\" }]"),
            record(id: "GHSA-s003-invented", name: "c-pkg", ranges: semver("{\"introduced\": \"0\"}"),
                   extra: "\"severity\": [{ \"type\": \"CVSS_V3\", \"score\": \"CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:U/C:L/I:L/A:N\" }]"),
            record(id: "GHSA-s004-invented", name: "d-pkg", ranges: semver("{\"introduced\": \"0\"}"),
                   extra: "\"severity\": [{ \"type\": \"CVSS_V4\", \"score\": \"CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N\" }]"),
            record(id: "GHSA-s005-invented", name: "e-pkg", ranges: semver("{\"introduced\": \"0\"}"),
                   extra: "\"severity\": [{ \"type\": \"CVSS_V3\", \"score\": \"CVSS:3.0/AV:L/AC:H/PR:H/UI:R/S:U/C:L/I:N/A:N\" }]"),
        ])
        #expect(i.advisories(name: "a-pkg", version: "1.0.0").first?.severity == .moderate)
        #expect(i.advisories(name: "b-pkg", version: "1.0.0").first?.severity == .critical)
        #expect(i.advisories(name: "c-pkg", version: "1.0.0").first?.severity == .moderate)
        #expect(i.advisories(name: "d-pkg", version: "1.0.0").first?.severity == .unknown)
        #expect(i.advisories(name: "e-pkg", version: "1.0.0").first?.severity == .low)
        // The specification's worked values.
        #expect(CVSSScore.v3BaseScore("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H") == 9.8)
        #expect(CVSSScore.v3BaseScore("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H") == 10.0)
        #expect(CVSSScore.v3BaseScore("CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:U/C:L/I:L/A:N") == 5.4)
        #expect(CVSSScore.v3BaseScore("CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N") == 6.1)
        #expect(CVSSScore.v3BaseScore("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:N") == 0)
        #expect(CVSSScore.v3BaseScore("CVSS:3.1/AV:N/AC:L") == nil)
        #expect(CVSSScore.v3BaseScore("CVSS:2.0/AV:N") == nil)
        #expect(CVSSScore.roundUp(4.02) == 4.1)
        #expect(CVSSScore.roundUp(4.0) == 4.0)
    }

    @Test func summaryAliasesAndCaps() throws {
        let long = String(repeating: "x", count: 500)
        let aliases = (0..<15).map { "\"CVE-2026-\(1000 + $0)\"" }.joined(separator: ", ")
        let i = makeIndex([
            record(id: "GHSA-cap1-invented", name: "a-pkg", ranges: semver("{\"introduced\": \"0\"}"),
                   extra: "\"summary\": \"\(long)\", \"aliases\": [\(aliases)]"),
            record(id: "PYSEC-cap2-invented", name: "b-pkg", ranges: semver("{\"introduced\": \"0\"}"),
                   extra: "\"details\": \"\\n\\nFirst line of the invented details.\\nSecond line.\""),
        ])
        let a = try #require(i.advisories(name: "a-pkg", version: "1.0.0").first)
        #expect(a.summary?.count == 200)
        #expect(a.aliases.count == 10 && a.aliases.first == "CVE-2026-1000")
        let b = try #require(i.advisories(name: "b-pkg", version: "1.0.0").first)
        #expect(b.summary == "First line of the invented details.")
        // At most five fixed versions.
        let many = (1...8).map { "{\"introduced\": \"\($0).0.0\"}, {\"fixed\": \"\($0).0.5\"}" }.joined(separator: ", ")
        let m = makeIndex([record(id: "GHSA-fix8-invented", ranges: semver(many))])
        #expect(m.advisories(name: "harbor-utils", version: "3.0.1").first?.fixed == ["1.0.5", "2.0.5", "3.0.5", "4.0.5", "5.0.5"])
    }

    @Test func malformedRecordsAreCounted() {
        let i = makeIndex([
            Data("{ not json".utf8),
            Data("[1, 2, 3]".utf8),
            Data("{ \"affected\": [] }".utf8),                         // no id
            Data(),
            Data(String(repeating: "[", count: 5_000).utf8),            // deeper than the reader's bound
            Data(("{\"id\": \"GHSA-big-invented\", \"details\": \"" + String(repeating: "y", count: 1_100_000) + "\"}").utf8),
            record(id: "GHSA-good-invented", ranges: semver("{\"introduced\": \"0\"}, {\"fixed\": \"1.0.0\"}")),
            Data("{ \"id\": \"GHSA-odd-invented\", \"affected\": [ { \"package\": 7, \"ranges\": \"no\" }, 3 ], \"severity\": 9 }".utf8),
        ])
        #expect(i.skippedRecords == 6)
        #expect(i.meta.records == 1)
        #expect(ids(i, "harbor-utils", "0.9.0") == ["GHSA-good-invented"])
    }
}

@Suite("Advisory index files and lockfiles")
struct AdvisoryIndexTests {
    @Test func writeReadRoundTrip() throws {
        let modified = Date(timeIntervalSince1970: 1_790_000_000)
        let built = AdvisoryIndex.build(ecosystem: .crates, records: [
            record(id: "RUSTSEC-0000-invented", ecosystem: "crates.io", name: "harbor_utils",
                   ranges: semver("{\"introduced\": \"0.3.0\"}, {\"fixed\": \"0.3.7\"}"),
                   extra: "\"aliases\": [\"CVE-2026-0001\"], \"summary\": \"Invented overflow\", \"database_specific\": { \"severity\": \"HIGH\" }"),
            record(id: "GHSA-rt02-invented", ecosystem: "crates.io", name: "acme-notes", versions: ["1.0.0"]),
            Data("broken".utf8),
        ], sourceLastModified: modified)
        let url = try temporaryFile("crates.vtadv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try built.write(to: url)
        let opened = try AdvisoryIndex.read(from: url)
        #expect(opened.meta.ecosystem == .crates)
        #expect(opened.meta.sourceLastModified == modified)
        #expect(abs(opened.meta.builtAt.timeIntervalSince(built.meta.builtAt)) < 0.001)
        #expect(opened.meta.records == 2 && opened.meta.packages == 2 && opened.meta.formatVersion == 1)
        #expect(opened.skippedRecords == 1)
        let found = opened.advisories(name: "harbor_utils", version: "0.3.2")
        #expect(found == built.advisories(name: "harbor_utils", version: "0.3.2"))
        #expect(found == [Advisory(id: "RUSTSEC-0000-invented", aliases: ["CVE-2026-0001"], summary: "Invented overflow",
                                   severity: .high, isMalicious: false, fixed: ["0.3.7"])])
        #expect(opened.advisories(name: "acme-notes", version: "1.0.0").map(\.id) == ["GHSA-rt02-invented"])
        #expect(opened.advisories(name: "harbor-utils", version: "0.3.2").isEmpty)   // crates.io names are exact

        // A file that is not an index, or is cut short, throws instead of crashing.
        let junk = try temporaryFile("junk.vtadv")
        try Data("not an index at all, but long enough to have a header of sixty-four bytes in it".utf8).write(to: junk)
        #expect(throws: AdvisoryIndex.IndexError.notAnIndex) { try AdvisoryIndex.read(from: junk) }
        let whole = try Data(contentsOf: url)
        try whole.prefix(80).write(to: junk)
        #expect(throws: AdvisoryIndex.IndexError.self) { try AdvisoryIndex.read(from: junk) }
    }

    private func package(_ name: String, _ version: String?, source: String? = nil) -> LockfileSummary.Package {
        LockfileSummary.Package(name: name, version: version, source: source, sourceKind: .registry, isDirect: nil,
                                integrity: true, licence: nil)
    }

    private func summary(_ eco: LockfileSummary.Ecosystem, _ packages: [LockfileSummary.Package]) -> LockfileSummary {
        LockfileSummary(ecosystem: eco, formatVersion: nil, packages: packages, totalPackages: packages.count,
                        directCount: nil, sources: [], pinning: LockfileSummary.Pinning(exact: packages.count),
                        licences: nil, truncated: false)
    }

    @Test func matchesOverALockfileSummary() {
        let i = makeIndex([
            record(id: "GHSA-m001-invented", name: "harbor-utils", ranges: semver("{\"introduced\": \"0\"}, {\"fixed\": \"2.0.0\"}"),
                   extra: "\"database_specific\": { \"severity\": \"LOW\" }"),
            record(id: "MAL-2026-0002-invented", name: "@acme/tiny-lint", versions: ["0.3.2"]),
            record(id: "GHSA-m003-invented", name: "acme-notes", ranges: semver("{\"introduced\": \"1.0.0\"}, {\"fixed\": \"1.2.1\"}"),
                   extra: "\"database_specific\": { \"severity\": \"HIGH\" }"),
        ])
        let s = summary(.pnpm, [
            package("harbor-utils", "1.5.0"),
            package("acme-notes", "1.2.0"),
            package("acme-notes", "1.2.0"),          // the same pair twice is matched once
            package("left-pad-lite", "2.0.1"),
            package("@acme/tiny-lint", "0.3.2"),
            package("local-kit", nil),
            package("harbor-utils", "2.0.0"),
        ])
        let m = i.matches(s)
        #expect(m.map { $0.package } == ["@acme/tiny-lint", "acme-notes", "harbor-utils"])
        #expect(m.map { $0.version } == ["0.3.2", "1.2.0", "1.5.0"])
        #expect(m[0].advisories.first?.isMalicious == true)
        #expect(m[1].advisories.first?.fixed == ["1.2.1"])
        // Another ecosystem's lockfile, and CocoaPods, match nothing.
        #expect(i.matches(summary(.cargo, [package("harbor-utils", "1.5.0")])).isEmpty)
        #expect(OSVEcosystem.forLockfile(.cocoapods) == nil)
        #expect(OSVEcosystem.forLockfile(.uv) == .pypi && OSVEcosystem.forLockfile(.bundler) == .rubygems)
        #expect(OSVEcosystem.forLockfile(.composer) == .packagist && OSVEcosystem.forLockfile(.swiftPM) == .swiftURL)
        // At most 200 matches.
        let many = makeIndex((0..<250).map { record(id: "GHSA-n\($0)-invented", name: "pkg-\($0)", ranges: semver("{\"introduced\": \"0\"}")) })
        #expect(many.matches(summary(.npm, (0..<250).map { package("pkg-\($0)", "1.0.0") })).count == 200)
    }

    @Test func matchesPerEcosystemNames() {
        let py = makeIndex(.pypi, [record(id: "PYSEC-3333-invented", ecosystem: "PyPI", name: "Harbor_Utils", versions: ["0.4.0"])])
        #expect(py.matches(summary(.poetry, [package("harbor.utils", "0.4.0")])).count == 1)
        let gems = makeIndex(.rubygems, [record(id: "GHSA-gem1-invented", ecosystem: "RubyGems", name: "harbor-utils",
                                            ranges: ecosystemRange("{\"introduced\": \"0\"}, {\"fixed\": \"1.15.5\"}"))])
        #expect(gems.matches(summary(.bundler, [package("harbor-utils", "1.15.4-x86_64-linux")])).first?.version == "1.15.4-x86_64-linux")
        let php = makeIndex(.packagist, [record(id: "GHSA-php1-invented", ecosystem: "Packagist", name: "Acme/Harbor",
                                            ranges: ecosystemRange("{\"introduced\": \"5.0.0\"}, {\"fixed\": \"5.4.4\"}"))])
        #expect(php.matches(summary(.composer, [package("acme/harbor", "v5.4.3")])).count == 1)
        #expect(php.matches(summary(.composer, [package("acme/harbor", "v5.4.4")])).isEmpty)
        let swift = makeIndex(.swiftURL, [
            record(id: "GHSA-sw01-invented", ecosystem: "SwiftURL", name: "https://github.com/acme/harbor-kit.git",
                   ranges: semver("{\"introduced\": \"1.0.0\"}, {\"fixed\": \"1.3.0\"}")),
            record(id: "GHSA-sw02-invented", ecosystem: "SwiftURL", name: "gitlab.example.com/other/harbor-kit",
                   ranges: semver("{\"introduced\": \"0\"}")),
        ])
        let pins = swift.matches(summary(.swiftPM, [package("harbor-kit", "1.2.0", source: "github.com")]))
        #expect(pins.first?.advisories.map(\.id) == ["GHSA-sw01-invented"])
        #expect(swift.advisories(name: "github.com/acme/harbor-kit/", version: "1.2.0").map(\.id) == ["GHSA-sw01-invented"])
    }

    /// A pin's repository URL (Package.resolved's `location`) matches exactly: a same-named repository of another
    /// owner on the same host no longer matches, and the reader keeps the URL without credentials.
    @Test func swiftPinsMatchByTheirRepositoryURL() throws {
        let swift = makeIndex(.swiftURL, [
            record(id: "GHSA-sw11-invented", ecosystem: "SwiftURL", name: "https://github.com/acme/harbor-kit", ranges: semver("{\"introduced\": \"0\"}")),
            record(id: "GHSA-sw12-invented", ecosystem: "SwiftURL", name: "https://github.com/other/harbor-kit", ranges: semver("{\"introduced\": \"0\"}")),
        ])
        let resolved = """
        {"pins":[{"identity":"harbor-kit","kind":"remoteSourceControl","location":"https://ci:token123@github.com/acme/harbor-kit.git",
          "state":{"revision":"0123456789abcdef0123456789abcdef01234567","version":"1.2.0"}}],"version":3}
        """
        let summary = try #require(LockfileReader.read(data: Data(resolved.utf8), fileName: "Package.resolved"))
        #expect(summary.packages.first?.locator == "https://github.com/acme/harbor-kit.git")
        #expect(swift.matches(summary).first?.advisories.map(\.id) == ["GHSA-sw11-invented"])
    }

    @Test func scaleBuildWriteReadAndLookups() throws {
        let recordCount = 250_000
        let packageCount = 100_000
        var records: [Data] = []
        records.reserveCapacity(recordCount)
        for k in 0..<recordCount {
            let name = "invented-pkg-\(k % packageCount)"
            let id = k % 5 == 0 ? "MAL-2026-\(k)-invented" : "GHSA-\(k)-invented"
            let major = k / packageCount
            records.append(record(id: id, name: name,
                                  ranges: semver("{\"introduced\": \"\(major).0.0\"}, {\"fixed\": \"\(major).4.0\"}"),
                                  extra: "\"summary\": \"Invented advisory number \(k)\", \"aliases\": [\"CVE-2026-\(k)\"], \"database_specific\": { \"severity\": \"HIGH\" }"))
        }
        let built = AdvisoryIndex.build(ecosystem: .npm, records: records, sourceLastModified: nil)
        records = []
        #expect(built.meta.records == recordCount && built.meta.packages == packageCount)
        let url = try temporaryFile("npm.vtadv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try built.write(to: url)

        let clock = ContinuousClock()
        var opened: AdvisoryIndex?
        let readTime = try clock.measure { opened = try AdvisoryIndex.read(from: url) }
        let index = try #require(opened)
        var hits = 0
        let lookupTime = clock.measure {
            for k in 0..<1_000 {
                let n = (k * 7_919) % packageCount
                hits += index.advisories(name: "invented-pkg-\(n)", version: "1.2.0").count
                _ = index.advisories(name: "absent-pkg-\(k)", version: "1.2.0")
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print("advisory scale test: \(recordCount) records, file \(size) bytes, read \(readTime), 2000 lookups \(lookupTime)")
        #expect(hits >= 1_000)
        #expect(readTime < .milliseconds(200))
        #expect(lookupTime < .milliseconds(500))
    }
}
