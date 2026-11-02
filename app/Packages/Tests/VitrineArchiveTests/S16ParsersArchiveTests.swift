import XCTest
@testable import VitrineArchive

/// S-16 hardening: hostile zip directories and link chains, built byte by byte with invented names. Each test used to
/// trap the process (F15, F18, F19) or give a false "no outward links" verdict (F46). roadmap: S-16
final class S16ParsersArchiveTests: XCTestCase {
    private func symlink(_ name: String, to target: String) -> ZipBuilder.Entry {
        var e = ZipBuilder.Entry(name, data: Array(target.utf8))
        e.external = 0o120777 << 16
        return e
    }

    // F15: a ZIP64 compressed size near Int64.max made `dataOffset + compressed` trap in the member read.
    func testZip64CompressedSizeNearInt64MaxReadsAsTruncated() throws {
        var entry = ZipBuilder.Entry("xl/workbook.xml", data: Array("<workbook/>".utf8))
        entry.zip64 = true
        entry.compressedSize = 0x7FFF_FFFF_FFFF_FFFF
        entry.uncompressedSize = 11
        var builder = ZipBuilder()
        builder.entries = [entry]
        let source = DataByteSource(builder.build())
        let listing = try ZipReader.list(source: source)
        XCTAssertEqual(listing.entries.first?.compressedSize, 0x7FFF_FFFF_FFFF_FFFF)
        XCTAssertThrowsError(try VitrineArchive.memberData(source: source, listing: listing, entryIndex: 0, limit: 1024)) { error in
            guard case ArchiveError.truncated = error else { return XCTFail("expected truncated, got \(error)") }
        }
        // The deflate path shares the bound.
        var deflated = entry
        deflated.method = 8
        builder.entries = [deflated]
        let source2 = DataByteSource(builder.build())
        let listing2 = try ZipReader.list(source: source2)
        XCTAssertThrowsError(try VitrineArchive.memberData(source: source2, listing: listing2, entryIndex: 0, limit: 1024))
    }

    // F18: a ZIP64 end record whose disk number is 0xFFFFFFFF made the error message's `disk + 1` trap.
    func testZip64DiskNumberAllOnesIsRefusedNotTrapped() throws {
        var builder = ZipBuilder()
        builder.entries = [ZipBuilder.Entry("a.txt", data: Array("a".utf8))]
        builder.zip64Directory = true
        var bytes = builder.build()
        let signature: [UInt8] = [0x50, 0x4B, 0x06, 0x06]
        let record = try XCTUnwrap((0...(bytes.count - 4)).first { Array(bytes[$0..<($0 + 4)]) == signature })
        for i in 0..<4 { bytes[record + 16 + i] = 0xFF }          // signature 4, size 8, versions 2 + 2, then disk
        XCTAssertThrowsError(try ZipReader.list(source: DataByteSource(bytes))) { error in
            guard case ArchiveError.unsupported(let why) = error else { return XCTFail("expected unsupported, got \(error)") }
            XCTAssertTrue(why.contains("4294967296"), why)
        }
    }

    // F19: two members whose ZIP64 local-header offsets sit just under Int64.max made `headerOffset + 30` trap in the
    // overlap check, so the safety card never drew.
    func testZip64HeaderOffsetsNearInt64MaxReadAsOverlapNotTrap() throws {
        var builder = ZipBuilder()
        for name in ["one.txt", "two.txt"] {
            var e = ZipBuilder.Entry(name, data: Array("x".utf8))
            e.zip64 = true
            e.localOffsetOverride = 0x7FFF_FFFF_FFFF_FFF0
            builder.entries.append(e)
        }
        let source = DataByteSource(builder.build())
        let listing = try ZipReader.list(source: source)
        XCTAssertEqual(listing.entries.count, 2)
        let report = ArchiveSafety.scan(listing)
        XCTAssertEqual(report.finding(.overlappingEntries)?.count, 1)
        // Reading such a member is damage, said plainly.
        XCTAssertThrowsError(try VitrineArchive.memberData(source: source, listing: listing, entryIndex: 0, limit: 16))
    }

    // F46: links that each look internal by their text climb out through each other.
    func testLinkChainThroughOtherLinksIsSeenToEscape() throws {
        var builder = ZipBuilder()
        builder.entries = [
            symlink("a", to: "."),
            symlink("b", to: "a/.."),
            symlink("c", to: "b/.."),
            symlink("d", to: "c/Users/fixture/Library/LaunchAgents"),
            ZipBuilder.Entry("d/evil.plist", data: Array("<plist/>".utf8)),
            symlink("docs/latest", to: "../versions/2"),
            ZipBuilder.Entry("versions/2/readme.txt", data: Array("hi".utf8)),
        ]
        let report = ArchiveSafety.scan(try ZipReader.list(source: DataByteSource(builder.build())))
        let outside = try XCTUnwrap(report.finding(.linkOutsideArchive), "\(report.findings.map(\.kind))")
        XCTAssertEqual(outside.paths, ["b → a/..", "c → b/..", "d → c/Users/fixture/Library/LaunchAgents"])
        XCTAssertEqual(report.finding(.symlink)?.paths, ["a → .", "docs/latest → ../versions/2"])
    }

    func testLinkResolutionFollowsALinkedFolderAndFoldsCase() throws {
        var builder = ZipBuilder()
        builder.entries = [
            symlink("lib", to: "pkg/deep/dir"),
            symlink("up", to: "lib/../../../.."),      // lib is pkg/deep/dir: four levels up is the root's parent
            symlink("ok", to: "lib/../sibling"),       // pkg/deep/sibling: inside
            symlink("lib/inner", to: "../../x"),       // written through lib: pkg/deep/dir/inner → pkg/x, inside
            symlink("lib/out", to: "../../../../x"),   // four up from pkg/deep/dir: outside
            symlink("Dot", to: "."),
            symlink("climb", to: "dot/.."),            // APFS reads "dot" as "Dot", the root: its parent is outside
        ]
        let report = ArchiveSafety.scan(try ZipReader.list(source: DataByteSource(builder.build())))
        XCTAssertEqual(report.finding(.linkOutsideArchive)?.paths,
                       ["up → lib/../../../..", "lib/out → ../../../../x", "climb → dot/.."])
        XCTAssertEqual(report.finding(.symlink)?.paths,
                       ["lib → pkg/deep/dir", "ok → lib/../sibling", "lib/inner → ../../x", "Dot → ."])
    }

    func testLinkCyclesAndOverlongChainsCannotBeShownInsideAndStayFast() throws {
        var builder = ZipBuilder()
        builder.entries = [symlink("x", to: "y/z"), symlink("y", to: "x/z")]
        // A chain longer than macOS follows (MAXSYMLINKS is 32), then many links pointing into the chain.
        builder.entries.append(symlink("l0", to: "."))
        for i in 1...40 { builder.entries.append(symlink("l\(i)", to: "l\(i - 1)")) }
        for i in 0..<900 { builder.entries.append(symlink("many/m\(i)", to: "../l40/../l40/../l40")) }
        let listing = try ZipReader.list(source: DataByteSource(builder.build()), limits: ArchiveLimits(maxSymlinkTargets: 10_000))
        let clock = ContinuousClock()
        let started = clock.now
        let report = ArchiveSafety.scan(listing)
        XCTAssertLessThan(clock.now - started, .seconds(2))
        let outside = try XCTUnwrap(report.finding(.linkOutsideArchive))
        XCTAssertTrue(outside.paths.contains("x → y/z"))
        XCTAssertTrue(outside.paths.contains("y → x/z"))
        XCTAssertEqual(outside.count, 2 + (40 - 32) + 900, "cycles, links past the hop limit, and links through them")
        XCTAssertFalse(outside.paths.contains("l32 → l31"), "a chain of 32 hops still resolves")
    }

    func testTheLexicalJudgementIsUnchangedWithoutOtherLinks() {
        XCTAssertFalse(ArchivePath.linkEscapes(linkPath: "a/b/link", target: "../../c"))
        XCTAssertTrue(ArchivePath.linkEscapes(linkPath: "a/b/link", target: "../../../c"))
        XCTAssertTrue(ArchivePath.linkEscapes(linkPath: "link", target: "/etc/hosts"))
        XCTAssertTrue(ArchivePath.linkEscapes(linkPath: "a/link", target: "D:\\y"))
    }
}
