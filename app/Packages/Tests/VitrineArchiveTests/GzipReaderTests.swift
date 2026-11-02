import XCTest
@testable import VitrineArchive

final class GzipReaderTests: XCTestCase {
    private var folder: FixtureFolder!

    override func setUpWithError() throws { folder = try FixtureFolder() }
    override func tearDown() { folder = nil }

    /// A gzip member around one stored deflate block, with whichever optional header fields are asked for.
    private func member(_ payload: [UInt8], name: String? = nil, comment: String? = nil, extra: [UInt8]? = nil,
                        headerCRC: Bool = false, mtime: UInt32 = 0, os: UInt8 = 3, flagsOverride: UInt8? = nil,
                        method: UInt8 = 8) -> [UInt8] {
        var flags: UInt8 = 0
        if headerCRC { flags |= 0x02 }
        if extra != nil { flags |= 0x04 }
        if name != nil { flags |= 0x08 }
        if comment != nil { flags |= 0x10 }
        var out: [UInt8] = [0x1F, 0x8B, method, flagsOverride ?? flags]
        out.le32(mtime)
        out += [2, os]
        if let extra { out.le16(UInt16(extra.count)); out += extra }
        if let name { out += Array(name.utf8) + [0] }
        if let comment { out += Array(comment.utf8) + [0] }
        if headerCRC { out.le16(UInt16(truncatingIfNeeded: CRC32.checksum(out))) }
        out.append(0x01)
        out.le16(UInt16(payload.count)); out.le16(~UInt16(payload.count))
        out += payload
        out.le32(CRC32.checksum(payload))
        out.le32(UInt32(truncatingIfNeeded: payload.count))
        return out
    }

    func testGzipToolHeaderAndTrailer() throws {
        let text = String(repeating: "weather report, calm seas\n", count: 400)
        let original = try folder.write("forecast.txt", text)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_650_000_000)],
                                              ofItemAtPath: original.path)
        try folder.run("/usr/bin/gzip", ["-N", "-9", "forecast.txt"])
        let listing = try folder.list("forecast.txt.gz")
        XCTAssertEqual(listing.format, .gzip)
        XCTAssertEqual(listing.gzip?.originalName, "forecast.txt")
        XCTAssertEqual(listing.gzip?.modified, Date(timeIntervalSince1970: 1_650_000_000))
        XCTAssertEqual(listing.gzip?.operatingSystem, "Unix")
        XCTAssertEqual(listing.gzip?.trailerSize, UInt32(text.utf8.count))
        XCTAssertEqual(listing.gzip?.trailerCRC32, CRC32.checksum(Array(text.utf8)))
        let entry = try XCTUnwrap(listing.entries.first)
        XCTAssertEqual(listing.entries.count, 1)
        XCTAssertEqual(entry.path, "forecast.txt")
        XCTAssertEqual(entry.uncompressedSize, Int64(text.utf8.count))
        XCTAssertTrue(entry.uncompressedSizeIsModulo4GiB)
        XCTAssertTrue(listing.notes.contains(.gzipSizeIsModulo4GiB))
        XCTAssertEqual(entry.method, .deflate)
        XCTAssertLessThan(entry.compressedSize ?? .max, Int64(text.utf8.count) / 10)
    }

    func testNameFallsBackToTheFileName() throws {
        try folder.write("ledger.csv", "a,b\n1,2\n")
        try folder.run("/usr/bin/gzip", ["-n", "ledger.csv"])
        let listing = try folder.list("ledger.csv.gz")
        XCTAssertNil(listing.gzip?.originalName)
        XCTAssertNil(listing.gzip?.modified, "-n stores no time stamp")
        XCTAssertEqual(listing.entries.first?.path, "ledger.csv")
        XCTAssertEqual(GzipReader.strippedName("bundle.TGZ"), "bundle.tar")
    }

    func testEveryOptionalHeaderField() throws {
        var extra: [UInt8] = Array("AP".utf8)
        extra.le16(3); extra += [7, 8, 9]
        let bytes = member(Array("payload".utf8), name: "inner.dat", comment: "hand made", extra: extra,
                           headerCRC: true, mtime: 1_234_567_890, os: 11)
        let listing = try GzipReader.list(source: DataByteSource(bytes))
        let info = try XCTUnwrap(listing.gzip)
        XCTAssertEqual(info.originalName, "inner.dat")
        XCTAssertEqual(info.comment, "hand made")
        XCTAssertEqual(info.extraSubfieldIDs, ["AP"])
        XCTAssertTrue(info.hasHeaderCRC)
        XCTAssertEqual(info.operatingSystem, "NTFS")
        XCTAssertEqual(info.compressionHint, "maximum compression")
        XCTAssertEqual(info.modified, Date(timeIntervalSince1970: 1_234_567_890))
        XCTAssertEqual(info.trailerSize, 7)
        XCTAssertEqual(listing.entries.first?.compressedSize, Int64(bytes.count - info.headerLength - 8))
    }

    func testMalformedHeaders() throws {
        let good = member(Array("x".utf8), name: "n")
        assertArchiveError(try GzipReader.list(source: DataByteSource(member([1], flagsOverride: 0x20))), matching: {
            if case .malformed = $0 { true } else { false }
        })
        assertArchiveError(try GzipReader.list(source: DataByteSource(member([1], method: 7))), matching: {
            if case .unsupported = $0 { true } else { false }
        })
        for length in 0..<good.count {
            do { _ = try GzipReader.list(source: DataByteSource(Array(good.prefix(length)))) } catch is ArchiveError {}
        }
        // A name with no terminator runs to the end of the file.
        var unterminated: [UInt8] = [0x1F, 0x8B, 8, 0x08, 0, 0, 0, 0, 0, 3]
        unterminated += [UInt8](repeating: 0x41, count: 100)
        assertArchiveError(try GzipReader.list(source: DataByteSource(unterminated)))
    }

    // MARK: - Tar inside gzip

    private func makeTree() throws {
        try folder.write("bundle/README.md", "# Invented bundle\n")
        try folder.write("bundle/src/main.swift", "print(\"hi\")\n")
        try folder.write("bundle/src/util.swift", String(repeating: "// util\n", count: 300))
        try folder.symlink("bundle/current", to: "src")
    }

    func testTarGzListsTheTarInside() throws {
        try makeTree()
        try folder.run("/usr/bin/tar", ["--format", "pax", "-czf", "bundle.tar.gz", "bundle"])
        try folder.run("/usr/bin/tar", ["--format", "pax", "-cf", "bundle.tar", "bundle"])
        let compressed = try folder.list("bundle.tar.gz")
        let plain = try folder.list("bundle.tar")
        XCTAssertEqual(compressed.format, .tarGzip(.pax))
        XCTAssertTrue(compressed.coverage.isComplete)
        XCTAssertEqual(compressed.entries.map(\.path), plain.entries.map(\.path))
        XCTAssertEqual(compressed.entries.map(\.uncompressedSize), plain.entries.map(\.uncompressedSize))
        XCTAssertEqual(compressed.entries.first { $0.path == "bundle/current" }?.linkTarget, "src")
        XCTAssertNotNil(compressed.gzip)
        XCTAssertEqual(compressed.tar?.endMarker, .twoZeroBlocks)
    }

    func testTgzByGzipTool() throws {
        try makeTree()
        try folder.run("/usr/bin/tar", ["--format", "ustar", "-cf", "bundle.tar", "bundle"])
        try folder.run("/usr/bin/gzip", ["-S", ".tgz", "bundle.tar"])
        let listing = try folder.list("bundle.tar.tgz")
        XCTAssertEqual(listing.format, .tarGzip(.ustar))
        XCTAssertEqual(listing.entries.count, 6)
        XCTAssertEqual(listing.gzip?.originalName, "bundle.tar")
    }

    func testDecompressionCapGivesPartialCoverage() throws {
        try folder.write("capped/a-first.txt", "first")
        try folder.write("capped/b-big.bin", noise(3 * 1024 * 1024))
        try folder.write("capped/c-after.txt", "after")
        try folder.run("/usr/bin/tar", ["-czf", "capped.tgz", "capped/a-first.txt", "capped/b-big.bin", "capped/c-after.txt"])

        let source = CountingSource(try FileByteSource(url: folder.path("capped.tgz")))
        let limits = ArchiveLimits(maxDecompressedBytes: 1024 * 1024)
        let listing = try VitrineArchive.list(source: source, fileName: "capped.tgz", limits: limits)
        XCTAssertEqual(listing.entries.map(\.path), ["capped/a-first.txt", "capped/b-big.bin"])
        XCTAssertEqual(listing.entries.last?.isTruncated, false, "not truncated: not examined")
        guard case .partial(2, nil, let reason) = listing.coverage else { return XCTFail("\(listing.coverage)") }
        XCTAssertTrue(reason.contains("decompressed"), reason)
        XCTAssertLessThan(source.bytesRead, 1_300 * 1024, "reads stop near the cap, not at 3 MB")
        XCTAssertLessThanOrEqual(listing.tar?.bytesExamined ?? .max, 1024 * 1024)

        let whole = try VitrineArchive.list(source: FileByteSource(url: folder.path("capped.tgz")), fileName: "capped.tgz")
        XCTAssertEqual(whole.entries.count, 3)
        XCTAssertTrue(whole.coverage.isComplete)
    }

    func testTarSpreadOverTwoGzipMembers() throws {
        try makeTree()
        try folder.run("/usr/bin/tar", ["--format", "ustar", "-cf", "bundle.tar", "bundle"])
        let tar = try folder.bytes("bundle.tar")
        let half = tar.count / 2
        try folder.write("one", Data(tar.prefix(half)))
        try folder.write("two", Data(tar.suffix(from: half)))
        try folder.run("/usr/bin/gzip", ["-n", "one"])
        try folder.run("/usr/bin/gzip", ["-n", "two"])
        try folder.write("joined.tar.gz", Data(try folder.bytes("one.gz") + folder.bytes("two.gz")))

        let listing = try folder.list("joined.tar.gz")
        XCTAssertEqual(listing.format, .tarGzip(.ustar))
        XCTAssertEqual(listing.entries.count, 6)
        XCTAssertTrue(listing.coverage.isComplete, "\(listing.coverage)")
        XCTAssertTrue(listing.notes.contains(.gzipMembers(count: 2)), "\(listing.notes)")
    }

    func testCorruptDeflateInsideTgz() throws {
        try makeTree()
        try folder.run("/usr/bin/tar", ["-czf", "bundle.tgz", "bundle"])
        var bytes = try folder.bytes("bundle.tgz")
        for i in stride(from: 40, to: bytes.count - 8, by: 3) { bytes[i] ^= 0x5A }
        do {
            let listing = try GzipReader.list(source: DataByteSource(bytes), fileName: "bundle.tgz")
            XCTAssertFalse(listing.coverage.isComplete && listing.entries.count == 6, "damage cannot go unnoticed")
        } catch is ArchiveError {}

        // Every truncation of a real .tgz either lists, lists partially, or refuses.
        let clean = try folder.bytes("bundle.tgz")
        for length in stride(from: 0, to: clean.count, by: 5) {
            do { _ = try VitrineArchive.list(source: DataByteSource(Array(clean.prefix(length))), fileName: "b.tgz") }
            catch is ArchiveError {}
        }
    }

    func testEmptyTarInsideGzip() throws {
        try folder.write("empty.tar", Data(count: 10_240))
        try folder.run("/usr/bin/gzip", ["empty.tar"])
        let listing = try folder.list("empty.tar.gz")
        XCTAssertEqual(listing.format, .tarGzip(.ustar))
        XCTAssertTrue(listing.entries.isEmpty)
    }
}
