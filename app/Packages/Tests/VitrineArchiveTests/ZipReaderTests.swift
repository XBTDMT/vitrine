import XCTest
@testable import VitrineArchive

final class ZipReaderTests: XCTestCase {
    private var folder: FixtureFolder!

    override func setUpWithError() throws { folder = try FixtureFolder() }
    override func tearDown() { folder = nil }

    private func entry(_ listing: ArchiveListing, _ path: String, file: StaticString = #filePath,
                       line: UInt = #line) throws -> ArchiveEntry {
        try XCTUnwrap(listing.entries.first { $0.path == path }, "no entry \(path)", file: file, line: line)
    }

    // MARK: - Archives made by the system tools

    func testInfoZipArchiveListsFilesFoldersSymlinksAndModes() throws {
        let notes = String(repeating: "Lantern notes, harbour side.\n", count: 200)
        try folder.write("kit/notes.txt", notes)
        try folder.write("kit/raw.bin", noise(3_000))
        try folder.write("kit/sub/empty.txt", "")
        try folder.symlink("kit/link-to-notes", to: "notes.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: folder.path("kit/raw.bin").path)
        try folder.run("/usr/bin/zip", ["-q", "-r", "-y", "kit.zip", "kit"])

        let listing = try folder.list("kit.zip")
        XCTAssertEqual(listing.format, .zip)
        XCTAssertTrue(listing.coverage.isComplete)
        XCTAssertEqual(Set(listing.entries.map(\.path)),
                       ["kit/", "kit/notes.txt", "kit/raw.bin", "kit/sub/", "kit/sub/empty.txt", "kit/link-to-notes"])

        let text = try entry(listing, "kit/notes.txt")
        XCTAssertEqual(text.type, .file)
        XCTAssertEqual(text.uncompressedSize, Int64(notes.utf8.count))
        XCTAssertEqual(text.method, .deflate)
        XCTAssertLessThan(text.compressedSize ?? .max, Int64(notes.utf8.count) / 10)
        XCTAssertEqual(text.crc32, CRC32.checksum(Array(notes.utf8)))
        XCTAssertEqual(text.permissions, 0o644)
        XCTAssertEqual(text.pathEncoding, .utf8)
        // Info-ZIP writes the extended timestamp field: an instant, close to now.
        guard case .instant(let date)? = text.modified else { return XCTFail("expected a UT timestamp") }
        XCTAssertLessThan(abs(date.timeIntervalSinceNow), 3_600)

        XCTAssertEqual(try entry(listing, "kit/raw.bin").permissions, 0o750)
        XCTAssertEqual(try entry(listing, "kit/raw.bin").method, .stored, "zip stores what does not compress")
        XCTAssertEqual(try entry(listing, "kit/sub/").type, .directory)
        let link = try entry(listing, "kit/link-to-notes")
        XCTAssertEqual(link.type, .symlink)
        XCTAssertEqual(link.linkTarget, "notes.txt", "the target is read from the member's few data bytes")
        XCTAssertEqual(link.mode.map { $0 & 0o170000 }, 0o120000)
        XCTAssertEqual(listing.zip?.isZip64, false)
        XCTAssertEqual(listing.zip?.declaredEntryCount, 6)
    }

    func testDittoArchiveHasUTF8NamesWithoutTheFlagAndDataDescriptors() throws {
        try folder.write("Cartes/café ñandú.txt", "menu du jour")
        try folder.write("Cartes/日本語.txt", "テスト")
        try folder.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "Cartes", "cartes.zip"])

        let listing = try folder.list("cartes.zip")
        let names = Set(listing.entries.map(\.path))
        XCTAssertTrue(names.contains("Cartes/café ñandú.txt") || names.contains("Cartes/café ñandú.txt".decomposedStringWithCanonicalMapping),
                      "\(names)")
        XCTAssertTrue(names.contains("Cartes/日本語.txt"), "\(names)")
        let files = listing.entries.filter { $0.type == .file }
        XCTAssertEqual(files.count, 2)
        for file in files {
            XCTAssertTrue(file.hasDataDescriptor, "ditto streams: sizes follow the data, the directory has them")
            XCTAssertEqual(file.pathEncoding, .utf8)
            XCTAssertGreaterThan(file.uncompressedSize ?? 0, 0)
        }
    }

    func testStreamedZipFromStdinUsesDataDescriptors() throws {
        try folder.write("in.txt", String(repeating: "tide table\n", count: 50))
        try folder.run("/usr/bin/zip", ["-q", "-fd", "streamed.zip", "in.txt"])
        let listing = try folder.list("streamed.zip")
        let e = try entry(listing, "in.txt")
        XCTAssertTrue(e.hasDataDescriptor)
        XCTAssertEqual(e.uncompressedSize, 550)
    }

    func testTraditionalEncryptionFromZipTool() throws {
        try folder.write("vault/plan.txt", "meet at the lighthouse")
        try folder.run("/usr/bin/zip", ["-q", "-P", "not-a-real-password", "locked.zip", "vault/plan.txt"])
        let listing = try folder.list("locked.zip")
        let e = try entry(listing, "vault/plan.txt")
        XCTAssertEqual(e.encryption, .traditional)
        XCTAssertEqual(e.uncompressedSize, 22, "sizes are in the clear")
    }

    func testListingReadsOnlyTheEndOfTheFile() throws {
        try folder.write("big/blob.bin", noise(6 * 1024 * 1024))
        for i in 0..<20 { try folder.write("big/small-\(i).txt", "item \(i)") }
        try folder.run("/usr/bin/zip", ["-q", "-r", "-0", "big.zip", "big"])
        let source = CountingSource(try FileByteSource(url: folder.path("big.zip")))
        let listing = try VitrineArchive.list(source: source, fileName: "big.zip")
        XCTAssertEqual(listing.entries.count, 22)
        XCTAssertGreaterThan(source.size, 6 * 1024 * 1024)
        XCTAssertLessThan(source.bytesRead, 160 * 1024, "the end search plus the directory, never the 6 MB member")
    }

    func testSelfExtractorStubIsSkippedAndOffsetsCorrected() throws {
        try folder.write("payload/readme.txt", "hello from the payload")
        try folder.run("/usr/bin/zip", ["-q", "-r", "payload.zip", "payload"])
        let stub = Array("MZ-not-really-an-executable-stub".utf8) + [UInt8](repeating: 0x90, count: 4_000)
        try folder.write("sfx.bin", Data(stub + (try folder.bytes("payload.zip"))))

        let listing = try folder.list("sfx.bin")
        XCTAssertEqual(listing.format, .zip, "found by its end record alone")
        XCTAssertEqual(listing.zip?.prependedBytes, Int64(stub.count))
        XCTAssertTrue(listing.notes.contains(.prependedData(bytes: Int64(stub.count))))
        let e = try entry(listing, "payload/readme.txt")
        XCTAssertEqual(e.uncompressedSize, 22)
        XCTAssertEqual(try folder.bytes("sfx.bin")[Int(e.headerOffset)..<Int(e.headerOffset) + 4], [0x50, 0x4B, 0x03, 0x04])
    }

    // MARK: - Built byte by byte

    func testNameEncodings() throws {
        var builder = ZipBuilder()
        var dos = ZipBuilder.Entry(bytes: [0x80, 0x81, 0x82, 0x2E, 0x74, 0x78, 0x74])   // "Çüé.txt" in CP437
        dos.madeBy = 0 << 8 | 20
        dos.external = 0x20
        var flagged = ZipBuilder.Entry("naïve-π.txt")
        flagged.flags = 0x0800
        var unixUndeclared = ZipBuilder.Entry("señal.txt")                         // UTF-8, no flag, Unix host
        unixUndeclared.madeBy = 3 << 8 | 20
        var unixInvalid = ZipBuilder.Entry(bytes: [0x61, 0xE9, 0x62])               // not UTF-8 → CP437 (0xE9 is Θ)
        unixInvalid.madeBy = 3 << 8 | 20
        var badDeclared = ZipBuilder.Entry(bytes: [0x78, 0xFF, 0x79])
        badDeclared.flags = 0x0800
        var unicodeField = ZipBuilder.Entry(bytes: Array("plain.txt".utf8))
        let real = Array("réel.txt".utf8)
        unicodeField.centralExtra.le16(0x7075); unicodeField.centralExtra.le16(UInt16(5 + real.count))
        unicodeField.centralExtra.append(1); unicodeField.centralExtra.le32(CRC32.checksum(Array("plain.txt".utf8)))
        unicodeField.centralExtra += real
        var staleUnicode = ZipBuilder.Entry(bytes: Array("renamed.txt".utf8))
        staleUnicode.centralExtra.le16(0x7075); staleUnicode.centralExtra.le16(UInt16(5 + real.count))
        staleUnicode.centralExtra.append(1); staleUnicode.centralExtra.le32(0xDEAD_BEEF)
        staleUnicode.centralExtra += real
        builder.entries = [dos, flagged, unixUndeclared, unixInvalid, badDeclared, unicodeField, staleUnicode]
        let listing = try ZipReader.list(source: DataByteSource(builder.build()))

        XCTAssertEqual(listing.entries.map(\.path),
                       ["Çüé.txt", "naïve-π.txt", "señal.txt", "aΘb", "x\u{FFFD}y", "réel.txt", "renamed.txt"])
        XCTAssertEqual(listing.entries.map(\.pathEncoding), [.cp437, .utf8, .utf8, .cp437, .invalidUTF8, .utf8, .utf8])
        XCTAssertNil(listing.entries[0].mode, "MS-DOS host: no Unix mode")
    }

    func testCP437TableCoversTheHighHalf() {
        XCTAssertEqual(TextDecoding.cp437High.count, 128)
        XCTAssertEqual(TextDecoding.cp437([0xE1, 0xFB, 0x9C, 0xB0]), "ß√£░")
        XCTAssertEqual(TextDecoding.cp437([0x07, 0x41]), "\u{07}A", "control codes stay control codes")
    }

    func testZip64RecordsAndExtraFields() throws {
        var builder = ZipBuilder()
        var huge = ZipBuilder.Entry("disk-image.raw", data: Array("tiny".utf8))
        huge.zip64 = true
        huge.uncompressedSize = 5_000_000_000
        huge.compressedSize = 4
        var normal = ZipBuilder.Entry("after.txt", data: Array("after".utf8))
        normal.zip64 = true
        builder.entries = [huge, normal]
        builder.zip64Directory = true
        builder.comment = Array("made by hand".utf8)
        let listing = try ZipReader.list(source: DataByteSource(builder.build()))

        XCTAssertEqual(listing.zip?.isZip64, true)
        XCTAssertEqual(listing.zip?.comment, "made by hand")
        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertEqual(listing.entries[0].uncompressedSize, 5_000_000_000)
        XCTAssertEqual(listing.entries[0].compressedSize, 4)
        XCTAssertEqual(listing.entries[1].uncompressedSize, 5)
        XCTAssertEqual(listing.entries[1].headerOffset, Int64(30 + 14 + 4), "offset from the ZIP64 extra field")
    }

    func testZip64WithAStubInFront() throws {
        var builder = ZipBuilder()
        var e = ZipBuilder.Entry("inside.txt", data: Array("x".utf8))
        e.zip64 = true
        builder.entries = [e]
        builder.zip64Directory = true
        builder.stub = [UInt8](repeating: 0xCC, count: 777)
        let listing = try VitrineArchive.list(source: DataByteSource(builder.build()))
        XCTAssertEqual(listing.zip?.prependedBytes, 777)
        XCTAssertEqual(listing.entries.first?.headerOffset, 777)
    }

    func testCommentContainingAFakeEndSignature() throws {
        var builder = ZipBuilder()
        builder.entries = [ZipBuilder.Entry("a.txt", data: Array("a".utf8))]
        // A comment that itself looks like an end record (with a wrong comment length) must not fool the search.
        var fake: [UInt8] = []
        fake.le32(0x0605_4B50); fake += [UInt8](repeating: 0, count: 16); fake.le16(3)
        builder.comment = Array("note: ".utf8) + fake + Array(" end".utf8)
        let listing = try ZipReader.list(source: DataByteSource(builder.build()))
        XCTAssertEqual(listing.entries.map(\.path), ["a.txt"])
        XCTAssertEqual(listing.zip?.comment?.hasSuffix(" end"), true)
    }

    func testEmptyZip() throws {
        let listing = try ZipReader.list(source: DataByteSource(ZipBuilder().build()))
        XCTAssertTrue(listing.entries.isEmpty)
        XCTAssertTrue(listing.coverage.isComplete)
        XCTAssertEqual(try VitrineArchive.detect(source: DataByteSource(ZipBuilder().build())), .zip)
    }

    func testEncryptionAndAESExtraField() throws {
        var aes = ZipBuilder.Entry("secret.docx", data: [1, 2, 3])
        aes.method = 99
        aes.flags = 0x0001
        aes.centralExtra.le16(0x9901); aes.centralExtra.le16(7)
        aes.centralExtra.le16(2); aes.centralExtra += Array("AE".utf8); aes.centralExtra.append(3); aes.centralExtra.le16(8)
        var strong = ZipBuilder.Entry("strong.bin")
        strong.flags = 0x0041
        var wrapped = ZipBuilder.Entry("odd.bin")
        wrapped.method = 99
        var builder = ZipBuilder()
        builder.entries = [aes, strong, wrapped]
        let listing = try ZipReader.list(source: DataByteSource(builder.build()))
        XCTAssertEqual(listing.entries[0].encryption, .aes(bits: 256))
        XCTAssertEqual(listing.entries[0].method, .deflate, "the real method comes from the AES field")
        XCTAssertEqual(listing.entries[1].encryption, .strong)
        XCTAssertEqual(listing.entries[2].method, .aesWrapped)
        XCTAssertEqual(CompressionMethod(zipCode: 12).name, "BZIP2")
        XCTAssertEqual(CompressionMethod(zipCode: 93), .zstd)
        XCTAssertEqual(CompressionMethod(zipCode: 4242), .other(4242))
    }

    func testTimestamps() throws {
        // 2024-02-29 13:45:58 in DOS fields.
        var dos = ZipBuilder.Entry("leap.txt")
        dos.dosDate = UInt16((2024 - 1980) << 9 | 2 << 5 | 29)
        dos.dosTime = UInt16(13 << 11 | 45 << 5 | 29)
        var ut = ZipBuilder.Entry("ut.txt")
        ut.dosDate = dos.dosDate
        ut.centralExtra.le16(0x5455); ut.centralExtra.le16(5); ut.centralExtra.append(1); ut.centralExtra.le32(1_700_000_000)
        var ntfs = ZipBuilder.Entry("ntfs.txt")
        ntfs.centralExtra.le16(0x000A); ntfs.centralExtra.le16(32); ntfs.centralExtra.le32(0)
        ntfs.centralExtra.le16(1); ntfs.centralExtra.le16(24)
        ntfs.centralExtra.le64(UInt64((1_600_000_000 + 11_644_473_600) * 10_000_000))
        ntfs.centralExtra.le64(0); ntfs.centralExtra.le64(0)
        var bad = ZipBuilder.Entry("bad-date.txt")
        bad.dosDate = UInt16(44 << 9 | 13 << 5 | 1)                                  // month 13
        var builder = ZipBuilder()
        builder.entries = [dos, ut, ntfs, bad]
        let listing = try ZipReader.list(source: DataByteSource(builder.build()))

        guard case .wallClock(let parts)? = listing.entries[0].modified else { return XCTFail("DOS is wall-clock") }
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second],
                       [2024, 2, 29, 13, 45, 58])
        let utc = try XCTUnwrap(listing.entries[0].modified?.date(in: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(utc.timeIntervalSince1970, 1_709_214_358)
        XCTAssertEqual(listing.entries[1].modified, .instant(Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(listing.entries[2].modified?.date()?.timeIntervalSince1970 ?? 0, 1_600_000_000, accuracy: 0.001)
        XCTAssertNil(listing.entries[3].modified)
    }

    func testModesFromExternalAttributes() throws {
        func make(_ name: String, mode: UInt32, host: UInt16 = 3) -> ZipBuilder.Entry {
            var e = ZipBuilder.Entry(name)
            e.madeBy = host << 8 | 20
            e.external = mode << 16
            return e
        }
        var dosDir = ZipBuilder.Entry("DOSDIR")
        dosDir.madeBy = 0
        dosDir.external = 0x10
        var builder = ZipBuilder()
        builder.entries = [make("d", mode: 0o040755), make("l", mode: 0o120777), make("c", mode: 0o020644),
                           make("b", mode: 0o060644), make("p", mode: 0o010644), make("s", mode: 0o140755),
                           make("x", mode: 0o104755), make("osx", mode: 0o100600, host: 19), make("slash/", mode: 0),
                           dosDir]
        let types = try ZipReader.list(source: DataByteSource(builder.build())).entries.map(\.type)
        XCTAssertEqual(types, [.directory, .symlink, .characterDevice, .blockDevice, .fifo, .other("socket"), .file,
                               .file, .directory, .directory])
        let suid = try ZipReader.list(source: DataByteSource(builder.build())).entries[6]
        XCTAssertTrue(suid.isSetUID)
        XCTAssertEqual(suid.permissions, 0o4755)
    }

    func testInfoZipUnixUidGid() throws {
        var e = ZipBuilder.Entry("owned.txt")
        e.centralExtra.le16(0x7875); e.centralExtra.le16(11)
        e.centralExtra.append(1); e.centralExtra.append(4); e.centralExtra.le32(501)
        e.centralExtra.append(4); e.centralExtra.le32(20)
        var builder = ZipBuilder()
        builder.entries = [e]
        let entry = try XCTUnwrap(ZipReader.list(source: DataByteSource(builder.build())).entries.first)
        XCTAssertEqual(entry.uid, 501)
        XCTAssertEqual(entry.gid, 20)
    }

    func testDeflatedSymlinkTargetIsInflated() throws {
        // A raw deflate stream made of one stored block holds the target "../outside" uncompressed.
        let target = Array("../outside".utf8)
        var deflated: [UInt8] = [0x01]
        deflated.le16(UInt16(target.count)); deflated.le16(~UInt16(target.count))
        deflated += target
        var link = ZipBuilder.Entry("dir/escape", data: deflated)
        link.method = 8
        link.external = 0o120777 << 16
        link.crc = CRC32.checksum(target)
        link.uncompressedSize = UInt64(target.count)
        var builder = ZipBuilder()
        builder.entries = [link]
        let listing = try ZipReader.list(source: DataByteSource(builder.build()))
        XCTAssertEqual(listing.entries.first?.linkTarget, "../outside")
    }

    func testSymlinkTargetCapIsReported() throws {
        var builder = ZipBuilder()
        for i in 0..<5 {
            var link = ZipBuilder.Entry("link\(i)", data: Array("t\(i)".utf8))
            link.external = 0o120777 << 16
            builder.entries.append(link)
        }
        let listing = try ZipReader.list(source: DataByteSource(builder.build()), limits: ArchiveLimits(maxSymlinkTargets: 2))
        XCTAssertEqual(listing.entries.compactMap(\.linkTarget), ["t0", "t1"])
        XCTAssertTrue(listing.notes.contains(.symlinkTargetsNotRead(count: 3)))
    }

    func testEntryCapGivesPartialCoverage() throws {
        var builder = ZipBuilder()
        builder.entries = (0..<50).map { ZipBuilder.Entry("f\($0).txt") }
        let listing = try ZipReader.list(source: DataByteSource(builder.build()), limits: ArchiveLimits(maxEntries: 10))
        XCTAssertEqual(listing.entries.count, 10)
        guard case .partial(let listed, let total, let reason) = listing.coverage else { return XCTFail("partial") }
        XCTAssertEqual(listed, 10)
        XCTAssertEqual(total, 50)
        XCTAssertTrue(reason.contains("10"))
    }

    // MARK: - Damage

    func testMalformedArchivesAreRefusedWithAReason() throws {
        var builder = ZipBuilder()
        builder.entries = [ZipBuilder.Entry("one.txt", data: Array("1".utf8)), ZipBuilder.Entry("two.txt")]
        let good = builder.build()

        assertArchiveError(try ZipReader.list(source: DataByteSource([])), matching: { $0 == .notAnArchive })
        assertArchiveError(try ZipReader.list(source: DataByteSource(Array("just some text, no zip".utf8))),
                           matching: { $0 == .notAnArchive })
        assertArchiveError(try ZipReader.list(source: DataByteSource(Array(good.prefix(40)))), matching: {
            if case .truncated = $0 { true } else { false }
        }, "a zip cut before its directory")

        // The end record points the directory past the end of the file.
        var outside = good
        let end = outside.count - 22
        outside.replaceSubrange((end + 16)..<(end + 20), with: [0xFF, 0xFF, 0xFF, 0x7F])
        assertArchiveError(try ZipReader.list(source: DataByteSource(outside)), matching: {
            if case .malformed = $0 { true } else { false }
        })

        // A multi-disk set.
        var split = good
        split[end + 4] = 2
        assertArchiveError(try ZipReader.list(source: DataByteSource(split)), matching: {
            if case .unsupported = $0 { true } else { false }
        })

        // A saturated size with no ZIP64 field.
        var missing = ZipBuilder.Entry("needs64.bin")
        missing.zip64 = true
        missing.omitZip64Extra = true
        var b2 = ZipBuilder()
        b2.entries = [missing]
        assertArchiveError(try ZipReader.list(source: DataByteSource(b2.build())), matching: {
            if case .malformed = $0 { true } else { false }
        })
    }

    func testDamageAfterTheFirstEntryShowsWhatCameBefore() throws {
        var builder = ZipBuilder()
        builder.entries = [ZipBuilder.Entry("first.txt"), ZipBuilder.Entry("second.txt"), ZipBuilder.Entry("third.txt")]
        var bytes = builder.build()
        let directoryOffset = Int(bytes.le32(at: bytes.count - 22 + 16) ?? 0)
        let second = directoryOffset + 46 + "first.txt".utf8.count
        bytes[second] = 0x00                                    // break the second record's signature
        let listing = try ZipReader.list(source: DataByteSource(bytes))
        XCTAssertEqual(listing.entries.map(\.path), ["first.txt"])
        guard case .partial(1, 3, let reason) = listing.coverage else { return XCTFail("\(listing.coverage)") }
        XCTAssertTrue(reason.contains("damaged"))
    }

    func testEveryTruncationAndRandomDamageIsHandled() throws {
        try folder.write("fz/a.txt", String(repeating: "alpha ", count: 40))
        try folder.write("fz/b.txt", "beta")
        try folder.symlink("fz/c", to: "a.txt")
        try folder.run("/usr/bin/zip", ["-q", "-r", "-y", "fz.zip", "fz"])
        let bytes = try folder.bytes("fz.zip")

        for length in 0..<bytes.count {
            do { _ = try ZipReader.list(source: DataByteSource(Array(bytes.prefix(length)))) } catch is ArchiveError {}
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            var damaged = bytes
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                damaged[Int.random(in: 0..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            do { _ = try VitrineArchive.list(source: DataByteSource(damaged), fileName: "fz.zip") } catch is ArchiveError {}
        }
    }
}
