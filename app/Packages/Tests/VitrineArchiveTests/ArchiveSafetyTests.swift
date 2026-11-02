import XCTest
@testable import VitrineArchive

final class ArchiveSafetyTests: XCTestCase {
    private func symlink(_ name: String, to target: String) -> ZipBuilder.Entry {
        var e = ZipBuilder.Entry(name, data: Array(target.utf8))
        e.external = 0o120777 << 16
        return e
    }

    private func scan(_ builder: ZipBuilder, policy: SafetyPolicy = .default) throws -> SafetyReport {
        ArchiveSafety.scan(try ZipReader.list(source: DataByteSource(builder.build())), policy: policy)
    }

    func testHostileZipNamesAndLinks() throws {
        var builder = ZipBuilder()
        var setuid = ZipBuilder.Entry("bin/helper")
        setuid.external = 0o104755 << 16
        var setgid = ZipBuilder.Entry("bin/group-helper")
        setgid.external = 0o102755 << 16
        var locked = ZipBuilder.Entry("vault/keys.txt")
        locked.flags = 0x0001
        builder.entries = [
            ZipBuilder.Entry("../../evil.txt"),
            ZipBuilder.Entry("safe/../../../etc/fake.conf"),
            ZipBuilder.Entry("/tmp/absolute.txt"),
            ZipBuilder.Entry("C:\\Users\\fixture\\run.bat"),
            ZipBuilder.Entry("docs\\..\\..\\windows-up.txt"),
            ZipBuilder.Entry("bell\u{07}name.txt"),
            ZipBuilder.Entry("invoice\u{202E}fdp.exe"),
            ZipBuilder.Entry("dup.txt"), ZipBuilder.Entry("./dup.txt"), ZipBuilder.Entry("dup.txt"),
            ZipBuilder.Entry("Readme.md"), ZipBuilder.Entry("README.md"),
            symlink("links/escape", to: "../../outside/secret.txt"),
            symlink("links/rooted", to: "/etc/hosts"),
            symlink("links/inside", to: "../docs/guide.txt"),
            setuid, setgid, locked,
        ]
        let report = try scan(builder)

        func check(_ kind: SafetyFinding.Kind, count: Int, file: StaticString = #filePath, line: UInt = #line) -> [String] {
            guard let finding = report.finding(kind) else {
                XCTFail("missing \(kind) in \(report.findings.map(\.kind))", file: file, line: line); return []
            }
            XCTAssertEqual(finding.count, count, "\(kind): \(finding.paths)", file: file, line: line)
            XCTAssertFalse(finding.title.isEmpty, file: file, line: line)
            XCTAssertFalse(finding.detail.isEmpty, file: file, line: line)
            return finding.paths
        }
        XCTAssertEqual(check(.parentTraversal, count: 3),
                       ["../../evil.txt", "safe/../../../etc/fake.conf", "docs\\..\\..\\windows-up.txt"])
        XCTAssertEqual(check(.absolutePath, count: 1), ["/tmp/absolute.txt"])
        XCTAssertEqual(check(.windowsPath, count: 2).count, 2)
        XCTAssertEqual(check(.controlCharacters, count: 1), ["bell\\u{7}name.txt"])
        XCTAssertEqual(check(.bidiOverride, count: 1), ["invoice\\u{202E}fdp.exe"], "shown escaped, never spoofed")
        XCTAssertEqual(check(.duplicatePath, count: 2), ["dup.txt"], "two extra copies of one path")
        XCTAssertEqual(check(.caseCollision, count: 1), ["Readme.md ≈ README.md"])
        XCTAssertEqual(check(.linkOutsideArchive, count: 2),
                       ["links/escape → ../../outside/secret.txt", "links/rooted → /etc/hosts"])
        XCTAssertEqual(check(.symlink, count: 1), ["links/inside → ../docs/guide.txt"])
        XCTAssertEqual(check(.setuid, count: 1), ["bin/helper"])
        XCTAssertEqual(check(.setgid, count: 1), ["bin/group-helper"])
        XCTAssertEqual(check(.encrypted, count: 1), ["vault/keys.txt"])

        XCTAssertEqual(report.highestLevel, .danger)
        let levels = report.findings.map(\.level)
        XCTAssertEqual(levels, levels.sorted(by: >), "most severe first")
    }

    func testDevicesPipesAndHardlinksInTar() throws {
        var tar = TarBuilder()
        tar.header("dev/null-ish", type: "3", devMajor: 3, devMinor: 2)
        tar.header("dev/sda-ish", type: "4", devMajor: 8, devMinor: 0)
        tar.header("run/fifo", type: "6")
        tar.header("data/real.txt", size: 1); tar.data([0x41])
        tar.header("data/alias.txt", type: "1", link: "data/real.txt")
        tar.header("data/sneaky", type: "1", link: "../../etc/shadow-fake")
        tar.header("data/shared/", type: "5", mode: 0o2775)
        tar.end()
        let report = ArchiveSafety.scan(try TarReader.list(source: DataByteSource(tar.bytes)))
        XCTAssertEqual(report.finding(.specialFile)?.count, 3)
        XCTAssertEqual(report.finding(.hardlink)?.paths, ["data/alias.txt ⇒ data/real.txt"])
        XCTAssertEqual(report.finding(.linkOutsideArchive)?.paths, ["data/sneaky ⇒ ../../etc/shadow-fake"])
        XCTAssertEqual(report.finding(.setgid)?.count, 1)
        XCTAssertNil(report.expansionRatio, "plain tar stores members as they are")
    }

    func testZipBombSignalsFromTheDirectory() throws {
        // Declared sizes are all the scan needs: 3 GiB from 2 KB (within the 32-bit fields), and members sharing
        // one block of data.
        var builder = ZipBuilder()
        var bomb = ZipBuilder.Entry("zeros.bin", data: [UInt8](repeating: 0, count: 2_000))
        bomb.method = 8
        bomb.uncompressedSize = 3 * 1024 * 1024 * 1024
        builder.entries = [bomb]
        for i in 0..<3 {
            var copy = ZipBuilder.Entry("copy\(i).bin")
            copy.method = 8
            copy.compressedSize = 2_000
            copy.uncompressedSize = 1024 * 1024 * 1024
            copy.localOffsetOverride = 0
            builder.entries.append(copy)
        }
        let report = try scan(builder)
        XCTAssertEqual(report.finding(.entryExpansion)?.count, 4)
        XCTAssertNotNil(report.finding(.archiveExpansion))
        XCTAssertEqual(report.finding(.overlappingEntries)?.count, 3)
        XCTAssertGreaterThan(report.expansionRatio ?? 0, 1_000)
        XCTAssertEqual(report.totalUncompressedSize, 6 * 1024 * 1024 * 1024)
    }

    func testRealCompressedZerosTripTheRatio() throws {
        let folder = try FixtureFolder()
        try folder.write("blank/zeros.img", Data(count: 24 * 1024 * 1024))
        try folder.run("/usr/bin/zip", ["-q", "-r", "-9", "blank.zip", "blank"])
        let report = ArchiveSafety.scan(try folder.list("blank.zip"))
        XCTAssertNotNil(report.finding(.entryExpansion))
        XCTAssertNotNil(report.finding(.archiveExpansion))
        XCTAssertNil(report.finding(.overlappingEntries))
    }

    func testOrdinaryArchiveIsClean() throws {
        let folder = try FixtureFolder()
        try folder.write("project/README.md", "# Invented project\n")
        try folder.write("project/src/app.swift", "let answer = 42\n")
        try folder.write("project/assets/logo.bin", noise(20_000))
        try folder.run("/usr/bin/zip", ["-q", "-r", "project.zip", "project"])
        let report = ArchiveSafety.scan(try folder.list("project.zip"))
        XCTAssertTrue(report.isClean, "\(report.findings)")
        XCTAssertNil(report.highestLevel)
    }

    func testPathCapCountsAreExact() throws {
        var builder = ZipBuilder()
        builder.entries = (0..<30).map { ZipBuilder.Entry("../up-\($0).txt") }
        let report = try scan(builder, policy: SafetyPolicy(maxPathsPerFinding: 5, manyEntriesThreshold: 20))
        let traversal = try XCTUnwrap(report.finding(.parentTraversal))
        XCTAssertEqual(traversal.count, 30)
        XCTAssertEqual(traversal.paths.count, 5)
        XCTAssertTrue(traversal.pathsTruncated)
        XCTAssertNotNil(report.finding(.manyEntries))
    }

    func testIncompleteListingIsAFinding() throws {
        var builder = ZipBuilder()
        builder.entries = (0..<10).map { ZipBuilder.Entry("f\($0)") }
        let listing = try ZipReader.list(source: DataByteSource(builder.build()), limits: ArchiveLimits(maxEntries: 4))
        let report = ArchiveSafety.scan(listing)
        XCTAssertEqual(report.finding(.incompleteListing)?.paths, ["4 of 10 entries listed: listing stops at 4 entries"])
    }

    func testLinkResolution() {
        XCTAssertFalse(ArchivePath.linkEscapes(linkPath: "a/b/link", target: "../c"))
        XCTAssertFalse(ArchivePath.linkEscapes(linkPath: "a/b/link", target: "../../c"))
        XCTAssertTrue(ArchivePath.linkEscapes(linkPath: "a/b/link", target: "../../../c"))
        XCTAssertTrue(ArchivePath.linkEscapes(linkPath: "link", target: ".."))
        XCTAssertFalse(ArchivePath.linkEscapes(linkPath: "link", target: "./x/../y"))
        XCTAssertTrue(ArchivePath.linkEscapes(linkPath: "a/link", target: "x/../../../y"))
        XCTAssertTrue(ArchivePath.linkEscapes(linkPath: "a/link", target: "..\\..\\y"))
        XCTAssertTrue(ArchivePath.linkEscapes(linkPath: "a/link", target: "D:\\y"))
        XCTAssertTrue(ArchivePath.linkEscapes(linkPath: "../a/link", target: "x"))
        XCTAssertEqual(ArchivePath.normalized("./a//b/./c/"), "a/b/c")
        XCTAssertEqual(ArchivePath.visible("ok\u{2066}\u{1B}"), "ok\\u{2066}\\u{1B}")
    }

    func testNormalizationCollisionCountsAsCaseCollision() throws {
        var builder = ZipBuilder()
        builder.entries = [ZipBuilder.Entry("caf\u{E9}.txt"), ZipBuilder.Entry("cafe\u{301}.txt")]
        let report = try scan(builder)
        XCTAssertEqual(report.finding(.caseCollision)?.count, 1, "APFS treats the two spellings as one name")
        XCTAssertNil(report.finding(.duplicatePath))
    }
}
