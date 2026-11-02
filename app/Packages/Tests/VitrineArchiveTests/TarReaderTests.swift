import XCTest
@testable import VitrineArchive

final class TarReaderTests: XCTestCase {
    private var folder: FixtureFolder!

    override func setUpWithError() throws { folder = try FixtureFolder() }
    override func tearDown() { folder = nil }

    private let ownership = ["--uid", "1234", "--gid", "5678", "--uname", "keeper", "--gname", "crew"]
    private let longName = "deep/" + String(repeating: "n", count: 120) + ".txt"
    private let longTarget = String(repeating: "t", count: 130)

    /// A small tree with a folder, a file, a symlink, a long name and a long link target.
    private func makeTree(long: Bool) throws {
        try folder.write("tree/docs/guide.txt", "chapter one\n")
        try folder.write("tree/run.sh", "echo invented\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path("tree/run.sh").path)
        try folder.symlink("tree/docs/latest", to: "guide.txt")
        if long {
            try folder.write("tree/" + longName, "long")
            try folder.symlink("tree/far", to: longTarget)
        }
    }

    private func entry(_ listing: ArchiveListing, _ path: String) throws -> ArchiveEntry {
        try XCTUnwrap(listing.entries.first { $0.path == path }, "no entry \(path) in \(listing.entries.map(\.path))")
    }

    // MARK: - Tool-made archives in each dialect

    func testUstarFromBsdtar() throws {
        try makeTree(long: false)
        try folder.run("/usr/bin/tar", ["--format", "ustar"] + ownership + ["-cf", "u.tar", "tree"])
        let listing = try folder.list("u.tar")
        XCTAssertEqual(listing.format, .tar(.ustar))
        XCTAssertEqual(listing.tar?.endMarker, .twoZeroBlocks)
        XCTAssertTrue(listing.coverage.isComplete)
        XCTAssertTrue(listing.notes.isEmpty, "\(listing.notes)")

        let guide = try entry(listing, "tree/docs/guide.txt")
        XCTAssertEqual(guide.type, .file)
        XCTAssertEqual(guide.uncompressedSize, 12)
        XCTAssertEqual(guide.uid, 1234)
        XCTAssertEqual(guide.gid, 5678)
        XCTAssertEqual(guide.userName, "keeper")
        XCTAssertEqual(guide.groupName, "crew")
        XCTAssertEqual(guide.mode.map { $0 & 0o170000 }, 0o100000)
        XCTAssertNil(guide.compressedSize)
        XCTAssertEqual(guide.dataOffset.map { $0 - guide.headerOffset }, 512)
        guard case .instant(let date)? = guide.modified else { return XCTFail("tar times are instants") }
        XCTAssertLessThan(abs(date.timeIntervalSinceNow), 3_600)

        XCTAssertEqual(try entry(listing, "tree/run.sh").permissions, 0o755)
        XCTAssertEqual(try entry(listing, "tree/docs/").type, .directory)
        let link = try entry(listing, "tree/docs/latest")
        XCTAssertEqual(link.type, .symlink)
        XCTAssertEqual(link.linkTarget, "guide.txt")
    }

    func testPaxLongNamesAndLinks() throws {
        try makeTree(long: true)
        try folder.run("/usr/bin/tar", ["--format", "pax"] + ownership + ["-cf", "p.tar", "tree"])
        let listing = try folder.list("p.tar")
        XCTAssertEqual(listing.format, .tar(.pax))
        XCTAssertEqual(try entry(listing, "tree/" + longName).uncompressedSize, 4)
        XCTAssertEqual(try entry(listing, "tree/far").linkTarget, longTarget)
        XCTAssertFalse(listing.entries.contains { $0.path.contains("PaxHeader") }, "metadata members are not entries")
    }

    func testGNULongNamesAndLinks() throws {
        try makeTree(long: true)
        try folder.run("/usr/bin/tar", ["--format", "gnutar"] + ownership + ["-cf", "g.tar", "tree"])
        let listing = try folder.list("g.tar")
        XCTAssertEqual(listing.format, .tar(.gnu))
        XCTAssertEqual(try entry(listing, "tree/" + longName).uncompressedSize, 4)
        XCTAssertEqual(try entry(listing, "tree/far").linkTarget, longTarget)
        XCTAssertFalse(listing.entries.contains { $0.path.contains("LongLink") })
        XCTAssertEqual(try entry(listing, "tree/run.sh").userName, "keeper")
    }

    func testUstarPrefixField() throws {
        let path = "tree/" + String(repeating: "p", count: 90) + "/" + String(repeating: "q", count: 60) + ".txt"
        try folder.write(path, "prefixed")
        try folder.run("/usr/bin/tar", ["--format", "ustar", "-cf", "prefix.tar", "tree"])
        let listing = try folder.list("prefix.tar")
        XCTAssertEqual(listing.format, .tar(.ustar))
        XCTAssertEqual(try entry(listing, path).uncompressedSize, 8)
    }

    func testV7() throws {
        try makeTree(long: false)
        try folder.run("/usr/bin/tar", ["--format", "v7", "-cf", "v7.tar", "tree"])
        let listing = try folder.list("v7.tar")
        XCTAssertEqual(listing.format, .tar(.v7))
        XCTAssertEqual(try entry(listing, "tree/docs/").type, .directory, "V7 marks folders by a trailing slash")
        XCTAssertNil(try entry(listing, "tree/run.sh").userName)
    }

    func testListingSkipsMemberData() throws {
        try folder.write("heavy/movie.bin", noise(8 * 1024 * 1024))
        try folder.write("heavy/after.txt", "after the big one")
        try folder.run("/usr/bin/tar", ["-cf", "heavy.tar", "heavy"])
        let source = CountingSource(try FileByteSource(url: folder.path("heavy.tar")))
        let listing = try VitrineArchive.list(source: source, fileName: "heavy.tar")
        XCTAssertEqual(Set(listing.entries.map(\.path)), ["heavy/", "heavy/movie.bin", "heavy/after.txt"])
        XCTAssertLessThan(source.bytesRead, 300 * 1024, "headers and one window each, not 8 MB of data")
    }

    // MARK: - Hand-built headers

    func testEveryTypeFlagAndDeviceNumbers() throws {
        var tar = TarBuilder()
        tar.header("dev/tty0", type: "3", mode: 0o620, devMajor: 4, devMinor: 1)
        tar.header("dev/disk9", type: "4", mode: 0o640, devMajor: 1, devMinor: 9)
        tar.header("run/pipe", type: "6")
        tar.header("bin/tool", type: "0", size: 3, mode: 0o4755); tar.data([1, 2, 3])
        tar.header("bin/alias", type: "1", link: "bin/tool")
        tar.header("share/", type: "5", mode: 0o2775)
        tar.header("contig.bin", type: "7", size: 1); tar.data([9])
        tar.header("VOLUME", type: "V")
        tar.header("weird", type: "Z")
        tar.end()
        let listing = try TarReader.list(source: DataByteSource(tar.bytes))
        XCTAssertEqual(listing.entries.map(\.type), [.characterDevice, .blockDevice, .fifo, .file, .hardlink, .directory,
                                                     .file, .other("volume label"), .other("tar type ‘Z’")])
        XCTAssertEqual(listing.entries[0].device, DeviceNumber(major: 4, minor: 1))
        XCTAssertEqual(listing.entries[1].device, DeviceNumber(major: 1, minor: 9))
        XCTAssertTrue(listing.entries[3].isSetUID)
        XCTAssertEqual(listing.entries[4].linkTarget, "bin/tool")
        XCTAssertTrue(listing.entries[5].isSetGID)
        XCTAssertEqual(listing.entries[6].uncompressedSize, 1)
    }

    func testPaxRecordsAndGlobals() throws {
        var tar = TarBuilder()
        tar.pax("g", [("uname", "global-owner"), ("comment", "made by hand")])
        tar.header("first.txt", size: 2); tar.data([0x61, 0x62])
        tar.pax("x", [("path", "renamed/π-ünïcode.txt"), ("mtime", "1700000000.25"), ("size", "5"), ("uname", "")])
        tar.header("short-name.txt", size: 0, uname: "")
        tar.data([1, 2, 3, 4, 5])                    // the pax size wins over the header's 0
        tar.header("third.txt", size: 0)
        tar.end()
        let listing = try TarReader.list(source: DataByteSource(tar.bytes))
        XCTAssertEqual(listing.format, .tar(.pax))
        XCTAssertEqual(listing.entries.map(\.path), ["first.txt", "renamed/π-ünïcode.txt", "third.txt"])
        XCTAssertEqual(listing.entries[0].userName, "global-owner")
        XCTAssertEqual(listing.entries[1].uncompressedSize, 5)
        XCTAssertEqual(listing.entries[1].modified, .instant(Date(timeIntervalSince1970: 1_700_000_000.25)))
        XCTAssertNil(listing.entries[1].userName, "an empty x value unsets the global for that member")
        XCTAssertEqual(listing.entries[2].userName, "global-owner")
        XCTAssertEqual(listing.tar?.globalAttributes["comment"], "made by hand")
    }

    func testBase256SizeAndNegativeTime() throws {
        // GNU base-256: 0x80 marker then a big-endian value (here 9 GiB), which octal in 11 digits cannot hold.
        var field = [UInt8](repeating: 0, count: 12)
        field[0] = 0x80
        let nine: UInt64 = 9 * 1024 * 1024 * 1024
        for i in 0..<8 { field[11 - i] = UInt8(truncatingIfNeeded: nine >> (8 * UInt64(i))) }
        XCTAssertEqual(TarReader.parseNumber(field[...]), Int64(nine))
        var negative = [UInt8](repeating: 0xFF, count: 12)
        negative[11] = 0xFE
        XCTAssertEqual(TarReader.parseNumber(negative[...]), -2)
        XCTAssertEqual(TarReader.parseNumber(Array("0000644 \0".utf8)[...]), 0o644)
        XCTAssertEqual(TarReader.parseNumber(Array("   12\0".utf8)[...]), 0o12)
        XCTAssertNil(TarReader.parseNumber(Array("12x4".utf8)[...]))

        var tar = TarBuilder()
        tar.header("sparse-claim.img", size: 0, magic: .gnu, sizeField: field)
        let listing = try TarReader.list(source: DataByteSource(tar.bytes))
        XCTAssertEqual(listing.entries.first?.uncompressedSize, Int64(nine))
        XCTAssertEqual(listing.entries.first?.isTruncated, true, "9 GiB of data is not in a 512-byte file")
    }

    func testTruncatedTailIsReported() throws {
        try folder.write("cut/a.txt", String(repeating: "a", count: 3_000))
        try folder.write("cut/b.txt", String(repeating: "b", count: 3_000))
        try folder.run("/usr/bin/tar", ["--format", "ustar", "-cf", "cut.tar", "cut/a.txt", "cut/b.txt"])  // b last
        let bytes = try folder.bytes("cut.tar")
        let full = try TarReader.list(source: DataByteSource(bytes))
        let b = try entry(full, "cut/b.txt")

        // Cut inside b's data.
        let inside = try TarReader.list(source: DataByteSource(Array(bytes.prefix(Int(b.headerOffset) + 512 + 100))))
        XCTAssertEqual(inside.entries.last?.path, "cut/b.txt")
        XCTAssertEqual(inside.entries.last?.isTruncated, true)
        XCTAssertTrue(inside.notes.contains(.truncatedEntry(path: "cut/b.txt")))
        XCTAssertFalse(inside.coverage.isComplete)

        // Cut at a header boundary, before the end marker: everything is listed, the marker is missing.
        let end = Int(b.headerOffset) + 512 + 3_072
        let boundary = try TarReader.list(source: DataByteSource(Array(bytes.prefix(end))))
        XCTAssertEqual(boundary.entries.count, full.entries.count)
        XCTAssertTrue(boundary.notes.contains(.missingEndMarker))
        XCTAssertEqual(boundary.tar?.endMarker, TarInfo.EndMarker.none)

        // One zero block.
        let single = try TarReader.list(source: DataByteSource(Array(bytes.prefix(end + 512))))
        XCTAssertEqual(single.tar?.endMarker, .oneZeroBlock)
        XCTAssertTrue(single.notes.contains(.singleZeroBlockEnd))

        // Cut inside a header.
        let header = try TarReader.list(source: DataByteSource(Array(bytes.prefix(Int(b.headerOffset) + 200))))
        XCTAssertFalse(header.coverage.isComplete)
        XCTAssertEqual(header.entries.count, full.entries.count - 1)
    }

    func testChecksumDamage() throws {
        var tar = TarBuilder()
        tar.header("good.txt")
        tar.header("bad.txt", corruptChecksum: true)
        tar.end()
        let listing = try TarReader.list(source: DataByteSource(tar.bytes))
        XCTAssertEqual(listing.entries.map(\.path), ["good.txt"])
        guard case .partial(_, _, let reason) = listing.coverage else { return XCTFail("partial") }
        XCTAssertTrue(reason.contains("checksum"), reason)

        var first = TarBuilder()
        first.header("bad.txt", corruptChecksum: true)
        assertArchiveError(try TarReader.list(source: DataByteSource(first.bytes)), matching: { $0 == .notAnArchive })
    }

    func testMetadataRecordLimitAndMalformedPax() throws {
        var big = TarBuilder()
        big.header("././@LongLink", type: "L", size: 4_000)
        big.data([UInt8](repeating: 0x61, count: 4_000))
        big.header("short")
        big.end()
        let limited = try TarReader.list(source: DataByteSource(big.bytes), limits: ArchiveLimits(maxMetadataRecordBytes: 1_024))
        XCTAssertTrue(limited.entries.isEmpty)
        XCTAssertFalse(limited.coverage.isComplete)
        let allowed = try TarReader.list(source: DataByteSource(big.bytes))
        XCTAssertEqual(allowed.entries.first?.path, String(repeating: "a", count: 4_000))

        assertArchiveError(try TarReader.parsePax(Array("99 path=x\n".utf8)))
        assertArchiveError(try TarReader.parsePax(Array("8 nokey\n".utf8)))
        XCTAssertEqual(try TarReader.parsePax(Array("12 path=a=b\n".utf8)), ["path": "a=b"])
    }

    func testEntryCap() throws {
        var tar = TarBuilder()
        for i in 0..<30 { tar.header("f\(i)") }
        tar.end()
        let listing = try TarReader.list(source: DataByteSource(tar.bytes), limits: ArchiveLimits(maxEntries: 7))
        XCTAssertEqual(listing.entries.count, 7)
        XCTAssertEqual(listing.coverage, .partial(listed: 7, total: nil, reason: "listing stops at 7 entries"))
    }

    func testEmptyTarAndTrailingData() throws {
        let empty = [UInt8](repeating: 0, count: 10_240)
        XCTAssertEqual(try VitrineArchive.detect(source: DataByteSource(empty), fileName: "nothing.tar"), .tar)
        let listing = try VitrineArchive.list(source: DataByteSource(empty), fileName: "nothing.tar")
        XCTAssertTrue(listing.entries.isEmpty)
        XCTAssertEqual(listing.tar?.endMarker, .twoZeroBlocks)

        var tar = TarBuilder()
        tar.header("x")
        tar.end()
        tar.bytes += Array("appended junk".utf8)
        let junk = try TarReader.list(source: DataByteSource(tar.bytes))
        XCTAssertTrue(junk.notes.contains(.trailingData(bytes: 13)))
    }

    func testEveryTruncationIsHandled() throws {
        try makeTree(long: true)
        try folder.run("/usr/bin/tar", ["--format", "pax", "-cf", "t.tar", "tree"])
        let bytes = try folder.bytes("t.tar")
        for length in stride(from: 0, to: bytes.count, by: 7) {
            do { _ = try TarReader.list(source: DataByteSource(Array(bytes.prefix(length)))) } catch is ArchiveError {}
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<1_000 {
            var damaged = bytes
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                damaged[Int.random(in: 0..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            do { _ = try TarReader.list(source: DataByteSource(damaged)) } catch is ArchiveError {}
        }
    }
}
