import Foundation
import XCTest
@testable import VitrineArchive

/// The libarchive-backed reader (G-15): every E-9 format lists through the same types the Swift readers produce.
/// Fixtures come from /usr/bin/tar (bsdtar writes 7-Zip, XAR, ISO 9660, ar, cpio and every compression filter),
/// /usr/bin/hdiutil (an ISO), /usr/bin/ar (a DEB), or are built byte by byte where nothing writes them (RAR, CAB,
/// LHA, RPM; see HandBuilt). Contents are invented. roadmap: S-8
final class LibarchiveReaderTests: XCTestCase {
    private func project(_ folder: FixtureFolder) throws {
        try folder.write("proj/readme.txt", "An invented readme.\n")
        try folder.write("proj/src/main.c", "int main(void) { return 0; }\n")
    }

    private func names(_ listing: ArchiveListing) -> [String] {
        listing.entries.map { ArchivePath.normalized($0.path) }.sorted()
    }

    private func libarchiveFormat(_ listing: ArchiveListing, file: StaticString = #filePath,
                                  line: UInt = #line) -> LibarchiveFormat? {
        guard case .libarchive(let f) = listing.format else {
            XCTFail("not read by libarchive: \(listing.format)", file: file, line: line); return nil
        }
        return f
    }

    // MARK: Compressed tars and lone streams

    func testCompressedTarsList() throws {
        let folder = try FixtureFolder()
        try project(folder)
        let cases: [(flag: String, file: String, filter: String, display: String)] = [
            ("-J", "p.tar.xz", "xz", "Tar archive (xz)"),
            ("--lzma", "p.tar.lzma", "lzma", "Tar archive (LZMA)"),
            ("--lzip", "p.tar.lz", "lzip", "Tar archive (lzip)"),
            ("-Z", "p.tar.Z", "compress (.Z)", "Tar archive (compress (.Z))"),
            ("-j", "p.tar.bz2", "bzip2", "Tar archive (bzip2)"),
        ]
        for c in cases {
            try folder.run("/usr/bin/tar", [c.flag, "-cf", c.file, "proj"])
            let listing = try folder.list(c.file)
            let format = try XCTUnwrap(libarchiveFormat(listing), c.file)
            XCTAssertEqual(format.container, .tar, c.file)
            XCTAssertEqual(format.filters, [c.filter], c.file)
            XCTAssertEqual(listing.format.name, c.display, c.file)
            XCTAssertTrue(listing.format.isCompressed, c.file)
            XCTAssertEqual(names(listing), ["proj", "proj/readme.txt", "proj/src", "proj/src/main.c"], c.file)
            XCTAssertEqual(listing.entries.first { $0.path.hasSuffix("readme.txt") }?.uncompressedSize, 20, c.file)
            // libarchive gives no per-member packed size: it stays unknown, never estimated.
            XCTAssertTrue(listing.entries.allSatisfy { $0.compressedSize == nil }, c.file)
            XCTAssertTrue(listing.coverage.isComplete, c.file)
        }
    }

    func testLoneXzStreamIsOneMemberWithItsCountedSize() throws {
        let folder = try FixtureFolder()
        try folder.write("notes.txt", String(repeating: "invented line\n", count: 500))
        try folder.run("/usr/bin/tar", ["--format", "raw", "-J", "-cf", "notes.txt.xz", "notes.txt"])
        let listing = try folder.list("notes.txt.xz")
        let format = try XCTUnwrap(libarchiveFormat(listing))
        XCTAssertEqual(format.container, .raw)
        XCTAssertEqual(listing.format.name, "xz-compressed file")
        XCTAssertEqual(listing.entries.map(\.path), ["notes.txt"])
        XCTAssertEqual(listing.entries.first?.uncompressedSize, 7_000)
    }

    /// Zstandard and LZ4 streams are decoded in the process (vendored decoders, G-15 correction) whatever this Mac's
    /// libarchive would do: a tar (proj/readme.txt, proj/src/main.c, invented) compressed by the zstd and lz4 command
    /// lines, kept here as bytes; and a Zstandard frame of raw blocks built by hand. roadmap: S-8
    func testZstandardAndLZ4TarsListWithoutAnyProgram() throws {
        let enabled = LibarchiveSession.inProcessFilters.map(LibarchiveSession.decodesInProcess)
        XCTAssertTrue(enabled.allSatisfy { $0 })
        let zst = try XCTUnwrap(Data(base64Encoded: "KLUv/WQAD8UFAMJIHBlwzwOo155DtfIJ4oFRFaOQIoR4JwC0EE4KVxfe9UY/b1stKNRKQX+lj8kHXTJUejixRSK5EAPQfFv7KXINb3bn8LH34lM/TEc55uXmZs5l4mbaWlX77nyPhyKGzdK5Y94yevPGZIOsY0Mo3Z0Jxt4nGyBALSft7AdfAfIUbmX+VzJGJevwNFkDrgCt6lgMSKIBaAF41A9GNTscjrrBAW4BCaMQqwtLqV7B1B4IPLDdrdmJFwGsASPE"))
        let lz4 = try XCTUnwrap(Data(base64Encoded: "BCJNGGRApxoBAABvcHJvai8AAQBLcTAwMDc1NSAIABI2CAAxMDAwEAAEAgD/ByAxNTI3MTIwMjA2NyAwMTMwMzcAIDWXAEsCAgDyAXVzdGFyADAwdG9ueW5vZWwWAA4CAD93aGUdAAcC5QAH1QARIBQADwIAkAEAAq9yZWFkbWUudHh0sgBCYTAwMDY0NPABDwACAysxNAACfzUwMzAAIDCOAEILAgAPAALsy09yYml0IG5vdGVzChoBDwIA/9MBAAQ/c3JjBAZJAPgFDwAGHD82MjYABv9ZAAACb21haW4uY/QDQg8ABg4rMzUABk80NzE0AAb/VEBpbnQg+wH/BSh2b2lkKSB7IHJldHVybiAwOyB9EQb/4w8CAP///9pQAAAAAAAAAAAA4tQ4GA=="))
        for (bytes, filter) in [(zst, "zstd"), (lz4, "lz4")] {
            let listing = try VitrineArchive.list(bytes: [UInt8](bytes), fileName: "p.tar." + (filter == "zstd" ? "zst" : "lz4"))
            XCTAssertEqual(libarchiveFormat(listing)?.container, .tar, filter)
            XCTAssertEqual(libarchiveFormat(listing)?.filters.first, filter)
            XCTAssertEqual(names(listing), ["proj", "proj/readme.txt", "proj/src", "proj/src/main.c"], filter)
            XCTAssertEqual(listing.entries.first { $0.path.hasSuffix("main.c") }?.uncompressedSize, 29)
            // A member reads back from the decoded stream.
            let index = try XCTUnwrap(listing.entries.firstIndex { $0.path.hasSuffix("readme.txt") })
            let member = try VitrineArchive.memberData(source: DataByteSource([UInt8](bytes)), listing: listing, entryIndex: index, limit: 1024)
            XCTAssertEqual(String(decoding: member.bytes, as: UTF8.self), "Orbit notes\n", filter)
        }
    }

    func testAHandBuiltZstandardFrameAndACutOne() throws {
        // Magic, a header with a 128 KB window and no checksum, then one last raw block holding the text.
        let text = Array("lumen notes, stored as a raw block\n".utf8)
        let size = UInt32(text.count) << 3 | 1  // last block, type raw
        let frame: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x38, UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16)] + text
        let listing = try VitrineArchive.list(bytes: frame, fileName: "notes.txt.zst")
        XCTAssertEqual(libarchiveFormat(listing)?.container, .raw)
        XCTAssertEqual(names(listing), ["notes.txt"])
        let member = try VitrineArchive.memberData(source: DataByteSource(frame), fileName: "notes.txt.zst", listing: listing, entryIndex: 0, limit: 1024)
        XCTAssertEqual(member.bytes, text)
        // The same frame cut short says so instead of listing a short file as whole.
        XCTAssertThrowsError(try VitrineArchive.memberData(source: DataByteSource(Array(frame.dropLast(5))), fileName: "notes.txt.zst",
                                                           listing: listing, entryIndex: 0, limit: 1024))
    }

    // MARK: Containers

    func testSevenZip() throws {
        let folder = try FixtureFolder()
        try project(folder)
        try folder.run("/usr/bin/tar", ["--format", "7zip", "-cf", "p.7z", "proj"])
        let listing = try folder.list("p.7z")
        XCTAssertEqual(libarchiveFormat(listing)?.container, .sevenZip)
        XCTAssertEqual(listing.format.name, "7-Zip archive")
        XCTAssertEqual(names(listing), ["proj", "proj/readme.txt", "proj/src", "proj/src/main.c"])
        XCTAssertEqual(listing.entries.first { $0.path.hasSuffix("main.c") }?.uncompressedSize, 29)
        XCTAssertEqual(listing.entries.first { $0.path == "proj/src" || $0.path == "proj/src/" }?.type, .directory)
    }

    func testISO9660FromHdiutil() throws {
        let folder = try FixtureFolder()
        try project(folder)
        try folder.run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-o", "disc.iso", "proj"])
        let listing = try folder.list("disc.iso")
        XCTAssertEqual(libarchiveFormat(listing)?.container, .iso9660)
        XCTAssertEqual(listing.format.name, "ISO 9660 disc image")
        let found = names(listing)
        XCTAssertTrue(found.contains("readme.txt"), "\(found)")
        XCTAssertTrue(found.contains("src/main.c"), "\(found)")
        XCTAssertFalse(listing.format.isCompressed)
    }

    func testCpioXarAndAr() throws {
        let folder = try FixtureFolder()
        try project(folder)
        try folder.run("/usr/bin/tar", ["--format", "newc", "-cf", "p.cpio", "proj"])
        let cpio = try folder.list("p.cpio")
        XCTAssertEqual(libarchiveFormat(cpio)?.container, .cpio)
        XCTAssertEqual(names(cpio), ["proj", "proj/readme.txt", "proj/src", "proj/src/main.c"])
        XCTAssertEqual(cpio.entries.first { $0.path.hasSuffix("readme.txt") }?.permissions, 0o644)

        try folder.run("/usr/bin/tar", ["--format", "xar", "-cf", "p.xar", "proj"])
        let xar = try folder.list("p.xar")
        XCTAssertEqual(libarchiveFormat(xar)?.container, .xar)
        XCTAssertEqual(names(xar), ["proj", "proj/readme.txt", "proj/src", "proj/src/main.c"])

        try folder.run("/usr/bin/tar", ["--format", "ar", "-cf", "p.a", "-C", "proj", "readme.txt"])
        let ar = try folder.list("p.a")
        XCTAssertEqual(libarchiveFormat(ar)?.container, .ar)
        XCTAssertEqual(ar.entries.map(\.path), ["readme.txt"])
        XCTAssertEqual(ar.format.name, "ar archive")
    }

    func testDebianPackageAndItsNestedTars() throws {
        let folder = try FixtureFolder()
        try folder.write("debian-binary", "2.0\n")
        try folder.write("ctl/control", "Package: invented\nVersion: 1.0\n")
        try folder.write("root/usr/bin/invented", "#!/bin/sh\necho hi\n")
        try folder.run("/usr/bin/tar", ["-czf", "control.tar.gz", "-C", "ctl", "control"])
        try folder.run("/usr/bin/tar", ["-cJf", "data.tar.xz", "-C", "root", "usr"])
        try folder.run("/usr/bin/tar", ["--format", "ar", "-cf", "invented_1.0_all.deb", "debian-binary", "control.tar.gz", "data.tar.xz"])
        let deb = try folder.list("invented_1.0_all.deb")
        let format = try XCTUnwrap(libarchiveFormat(deb))
        XCTAssertTrue(format.isDebianPackage)
        XCTAssertEqual(deb.format.name, "Debian package")
        XCTAssertEqual(deb.entries.map(\.path), ["debian-binary", "control.tar.gz", "data.tar.xz"])

        let source = try FileByteSource(url: folder.path("invented_1.0_all.deb"))
        let data = try VitrineArchive.openNested(source: source, fileName: "invented_1.0_all.deb", listing: deb, entryIndex: 2)
        XCTAssertEqual(data.name, "data.tar.xz")
        XCTAssertEqual(names(data.listing), ["usr", "usr/bin", "usr/bin/invented"])
        let control = try VitrineArchive.openNested(source: source, listing: deb, entryIndex: 1)
        XCTAssertEqual(control.listing.entries.map(\.path), ["control"])
        // One level further: a member of the nested archive, read from memory.
        let text = try VitrineArchive.memberData(source: control.source, listing: control.listing, entryIndex: 0, limit: 64)
        XCTAssertEqual(String(decoding: text.bytes, as: UTF8.self), "Package: invented\nVersion: 1.0\n")
        XCTAssertTrue(text.isComplete)
    }

    func testRPMWithACompressedCpioPayload() throws {
        let folder = try FixtureFolder()
        try folder.write("root/usr/share/invented/notes.txt", "invented\n")
        try folder.run("/usr/bin/tar", ["--format", "newc", "-cJf", "payload.cpio.xz", "-C", "root", "usr"])
        try folder.write("invented-1.0-1.noarch.rpm", Data(HandBuilt.rpm(payload: try folder.bytes("payload.cpio.xz"))))
        let listing = try folder.list("invented-1.0-1.noarch.rpm")
        let format = try XCTUnwrap(libarchiveFormat(listing))
        XCTAssertEqual(format.container, .cpio)
        XCTAssertEqual(format.filters, ["rpm", "xz"])
        XCTAssertEqual(listing.format.name, "RPM package (xz)")
        XCTAssertTrue(names(listing).contains("usr/share/invented/notes.txt"), "\(names(listing))")
    }

    func testCabinet() throws {
        let folder = try FixtureFolder()
        let bytes = HandBuilt.cab([.init("setup.inf", "[Version]\n"), .init("readme.txt", "invented\n")])
        try folder.write("invented.cab", Data(bytes))
        let listing = try folder.list("invented.cab")
        XCTAssertEqual(libarchiveFormat(listing)?.container, .cab)
        XCTAssertEqual(listing.entries.map(\.path), ["setup.inf", "readme.txt"])
        XCTAssertEqual(listing.entries.map(\.uncompressedSize), [10, 9])
        let data = try VitrineArchive.memberData(source: DataByteSource(bytes), path: "readme.txt", limit: 100)
        XCTAssertEqual(String(decoding: data.bytes, as: UTF8.self), "invented\n")
    }

    func testLHA() throws {
        let folder = try FixtureFolder()
        let bytes = HandBuilt.lha([.init("notes.txt", "invented lha member\n")])
        try folder.write("old.lzh", Data(bytes))
        let listing = try folder.list("old.lzh")
        XCTAssertEqual(libarchiveFormat(listing)?.container, .lha)
        XCTAssertEqual(listing.entries.map(\.path), ["notes.txt"])
        XCTAssertEqual(listing.entries.first?.uncompressedSize, 20)
        let data = try VitrineArchive.memberData(source: DataByteSource(bytes), path: "notes.txt", limit: 100)
        XCTAssertEqual(String(decoding: data.bytes, as: UTF8.self), "invented lha member\n")
    }

    // MARK: RAR

    func testRAR4StoredAndSolidFlag() throws {
        let members: [HandBuilt.Member] = [.init(directory: "docs"), .init("docs/a.txt", "alpha\n"), .init("b.txt", "bravo bravo\n")]
        let plain = try VitrineArchive.list(bytes: HandBuilt.rar4(members), fileName: "x.rar")
        let format = try XCTUnwrap(libarchiveFormat(plain))
        XCTAssertEqual(format.container, .rar)
        XCTAssertEqual(format.isSolid, false)
        XCTAssertEqual(plain.format.name, "RAR archive")
        XCTAssertEqual(names(plain), ["b.txt", "docs", "docs/a.txt"])
        XCTAssertEqual(plain.entries.first { $0.path == "b.txt" }?.uncompressedSize, 12)
        XCTAssertEqual(plain.entries.first { $0.path == "docs" }?.type, .directory)
        let member = try VitrineArchive.memberData(source: DataByteSource(HandBuilt.rar4(members)), path: "docs/a.txt", limit: 3)
        XCTAssertEqual(member.bytes, Array("alp".utf8))
        XCTAssertFalse(member.isComplete)

        let solid = try VitrineArchive.list(bytes: HandBuilt.rar4(members, solid: true))
        XCTAssertEqual(libarchiveFormat(solid)?.isSolid, true)
        XCTAssertEqual(solid.format.name, "RAR archive (solid)")
    }

    func testRAR4EncryptedMembersAreFlagged() throws {
        let listing = try VitrineArchive.list(bytes: HandBuilt.rar4([.init("secret.txt", "invented\n")], encryptFiles: true))
        XCTAssertEqual(listing.entries.map(\.path), ["secret.txt"])
        XCTAssertEqual(listing.entries.first?.encryption, .format("RAR"))
        XCTAssertEqual(ArchiveSafety.scan(listing).finding(.encrypted)?.count, 1)
        XCTAssertThrowsError(try VitrineArchive.memberData(source: DataByteSource(HandBuilt.rar4([.init("secret.txt", "x")], encryptFiles: true)),
                                                           path: "secret.txt", limit: 10))
    }

    func testRAR4EncryptedHeadersSayTheNamesAreHidden() throws {
        let listing = try VitrineArchive.list(bytes: HandBuilt.rar4([.init("hidden.txt", "invented\n")], encryptedHeaders: true))
        XCTAssertTrue(listing.entries.isEmpty)
        XCTAssertTrue(listing.notes.contains(.encryptedHeaders))
        XCTAssertFalse(listing.coverage.isComplete)
        let report = ArchiveSafety.scan(listing)
        XCTAssertNotNil(report.finding(.encrypted))
        XCTAssertNotNil(report.finding(.incompleteListing))
    }

    func testRAR5Stored() throws {
        let members: [HandBuilt.Member] = [.init(directory: "docs"), .init("docs/a.txt", "alpha\n"), .init("b.txt", "bravo\n")]
        let listing = try VitrineArchive.list(bytes: HandBuilt.rar5(members, solid: true), fileName: "y.rar")
        let format = try XCTUnwrap(libarchiveFormat(listing))
        XCTAssertEqual(format.container, .rar5)
        XCTAssertEqual(format.isSolid, true)
        XCTAssertEqual(names(listing), ["b.txt", "docs", "docs/a.txt"])
        XCTAssertEqual(listing.entries.first { $0.path == "docs/a.txt" }?.uncompressedSize, 6)
        let data = try VitrineArchive.memberData(source: DataByteSource(HandBuilt.rar5(members)), path: "b.txt", limit: 100)
        XCTAssertEqual(data.bytes, Array("bravo\n".utf8))
    }

    // MARK: Bounds

    func testDecompressedBytesCapStopsAndSaysSo() throws {
        let folder = try FixtureFolder()
        for i in 0..<4 { try folder.write("big/part\(i).bin", noise(400_000, seed: UInt64(i + 1))) }
        try folder.run("/usr/bin/tar", ["-cJf", "big.tar.xz", "big"])
        let listing = try folder.list("big.tar.xz", limits: ArchiveLimits(maxDecompressedBytes: 500_000))
        guard case .partial(let listed, _, let reason) = listing.coverage else { return XCTFail("listing was complete") }
        XCTAssertLessThan(listed, 5)
        XCTAssertTrue(reason.hasPrefix("Stopped after decompressing"), reason)
        XCTAssertNotNil(ArchiveSafety.scan(listing).finding(.incompleteListing))
    }

    func testTimeBudgetStopsASlowReadAndSaysWhere() throws {
        let folder = try FixtureFolder()
        for i in 0..<6 { try folder.write("slow/f\(i).bin", noise(200_000, seed: UInt64(i + 7))) }
        try folder.run("/usr/bin/tar", ["-cJf", "slow.tar.xz", "slow"])
        let slow = SlowSource(try FileByteSource(url: folder.path("slow.tar.xz")), delay: 0.03)
        let listing = try VitrineArchive.list(source: slow, fileName: "slow.tar.xz", limits: ArchiveLimits(timeBudget: 0.4))
        guard case .partial(_, nil, let reason) = listing.coverage else { return XCTFail("listing was complete") }
        XCTAssertTrue(reason.hasPrefix("Stopped after 0.4 s; in a compressed stream"), reason)
    }

    func testEntryCapIsPartial() throws {
        let folder = try FixtureFolder()
        for i in 0..<12 { try folder.write("many/f\(i).txt", "\(i)\n") }
        try folder.run("/usr/bin/tar", ["--format", "7zip", "-cf", "many.7z", "many"])
        let listing = try folder.list("many.7z", limits: ArchiveLimits(maxEntries: 5))
        XCTAssertEqual(listing.entries.count, 5)
        XCTAssertEqual(listing.coverage, .partial(listed: 5, total: nil, reason: "Only the first 5 entries are listed"))
    }

    func testCancelledListingThrows() async throws {
        let folder = try FixtureFolder()
        try project(folder)
        try folder.run("/usr/bin/tar", ["-cJf", "p.txz", "proj"])
        let url = folder.path("p.txz")
        let task = Task.detached { () throws -> ArchiveListing in
            withUnsafeCurrentTask { $0?.cancel() }
            return try VitrineArchive.list(contentsOf: url)
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled listing returned")
        } catch is CancellationError {
        }
    }

    func testGarbageWithAStrongSignatureIsAnErrorNotACrash() throws {
        var bytes: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
        bytes += [UInt8](noise(4_000))
        XCTAssertThrowsError(try VitrineArchive.list(bytes: bytes, fileName: "broken.7z"))
        var rar: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        rar += [UInt8](noise(300, seed: 3))
        // libarchive's RAR 5 reader treats an unreadable first header as the end: an empty listing, never invented
        // members and never a trap.
        if let listing = try? VitrineArchive.list(bytes: rar, fileName: "broken.rar") {
            XCTAssertTrue(listing.entries.isEmpty)
        }
        // Every truncation of real archives lists what it can or throws; none traps.
        let folder = try FixtureFolder()
        try project(folder)
        try folder.run("/usr/bin/tar", ["--format", "7zip", "-cf", "p.7z", "proj"])
        let samples = [try folder.bytes("p.7z"), HandBuilt.rar4([.init("a.txt", "alpha")]), HandBuilt.rar5([.init("a.txt", "alpha")]),
                       HandBuilt.cab([.init("a.txt", "alpha")])]
        for sample in samples {
            for cut in stride(from: 1, to: sample.count, by: 3) {
                _ = try? VitrineArchive.list(bytes: Array(sample.prefix(cut)))
            }
        }
    }

    func testDetectionKeepsTheSwiftReadersForTheirFormats() throws {
        let folder = try FixtureFolder()
        try project(folder)
        try folder.run("/usr/bin/tar", ["-cf", "p.tar", "proj"])
        try folder.run("/usr/bin/tar", ["-czf", "p.tgz", "proj"])
        XCTAssertEqual(try VitrineArchive.detect(source: FileByteSource(url: folder.path("p.tar"))), .tar)
        XCTAssertEqual(try VitrineArchive.detect(source: FileByteSource(url: folder.path("p.tgz"))), .gzip)
        try folder.run("/usr/bin/tar", ["-cjf", "p.tbz", "proj"])
        XCTAssertEqual(try VitrineArchive.detect(source: FileByteSource(url: folder.path("p.tbz"))), .libarchive)
    }

    // MARK: Member data across readers

    func testMemberDataFromZipTarAndGzip() throws {
        let folder = try FixtureFolder()
        let text = String(repeating: "invented member text ", count: 400)
        try folder.write("m/long.txt", text)
        try folder.write("m/short.txt", "short\n")
        try folder.run("/usr/bin/zip", ["-q", "-r", "m.zip", "m"])
        try folder.run("/usr/bin/zip", ["-q", "-0", "-r", "stored.zip", "m"])
        try folder.run("/usr/bin/tar", ["-cf", "m.tar", "m"])
        try folder.run("/usr/bin/tar", ["-czf", "m.tgz", "m"])
        for name in ["m.zip", "stored.zip", "m.tar", "m.tgz"] {
            let source = try FileByteSource(url: folder.path(name))
            let head = try VitrineArchive.memberData(source: source, fileName: name, path: "m/long.txt", limit: 100)
            XCTAssertEqual(head.bytes, Array(text.utf8.prefix(100)), name)
            XCTAssertFalse(head.isComplete, name)
            XCTAssertEqual(head.memberSize, Int64(text.utf8.count), name)
            let all = try VitrineArchive.memberData(source: source, fileName: name, path: "m/short.txt", limit: 100)
            XCTAssertEqual(all.bytes, Array("short\n".utf8), name)
            XCTAssertTrue(all.isComplete, name)
        }
        try folder.write("lone.txt", text)
        try folder.run("/usr/bin/gzip", ["-k", "lone.txt"])
        let lone = try VitrineArchive.memberData(source: FileByteSource(url: folder.path("lone.txt.gz")), fileName: "lone.txt.gz",
                                                 path: "lone.txt", limit: 50)
        XCTAssertEqual(lone.bytes, Array(text.utf8.prefix(50)))
    }

    func testNestedZipInsideASevenZipAndTheLimit() throws {
        let folder = try FixtureFolder()
        try folder.write("inner/hello.txt", "hello from inside\n")
        try folder.mkdir("outer")
        try folder.run("/usr/bin/zip", ["-q", "-r", "outer/inner.zip", "inner"])
        try folder.run("/usr/bin/tar", ["--format", "7zip", "-cf", "outer.7z", "outer"])
        let source = try FileByteSource(url: folder.path("outer.7z"))
        let listing = try VitrineArchive.list(source: source, fileName: "outer.7z")
        let index = try XCTUnwrap(listing.entries.firstIndex { $0.path.hasSuffix("inner.zip") })
        let nested = try VitrineArchive.openNested(source: source, listing: listing, entryIndex: index)
        XCTAssertEqual(nested.listing.format, .zip)
        XCTAssertEqual(names(nested.listing), ["inner", "inner/hello.txt"])
        XCTAssertNotNil(ArchiveSafety.scan(listing).finding(.nestedArchive))

        let tight = ArchiveLimits(maxNestedArchiveBytes: 16)
        XCTAssertThrowsError(try VitrineArchive.openNested(source: source, listing: listing, entryIndex: index, limits: tight)) { error in
            XCTAssertTrue((error as? ArchiveError)?.reason.contains("archives inside archives open up to") == true, "\(error)")
        }
    }

    // MARK: T-9 safety on the new formats

    func testSafetyFindingsReachTheNewFormats() throws {
        let folder = try FixtureFolder()
        try folder.write("w/invoice.pdf.exe", "MZ invented\n")
        try folder.write("w/tool.sh", "#!/bin/sh\n")
        try folder.write("w/inner.tar.gz", Data(noise(32)))
        try folder.run("/bin/chmod", ["755", "w/tool.sh"])
        try folder.write("w/link-target.txt", "x\n")
        try folder.symlink("w/escape", to: "../../etc/hosts")
        // bsdtar's -s rewrites a stored name; -P keeps the rewritten "../" as written.
        try folder.run("/usr/bin/tar", ["-cJf", "w.txz", "-P", "-s", ",^w/link-target.txt,../outside.txt,", "w"])
        let report = ArchiveSafety.scan(try folder.list("w.txz"))
        XCTAssertNotNil(report.finding(.parentTraversal), "\(report.findings.map(\.kind))")
        XCTAssertNotNil(report.finding(.linkOutsideArchive))
        XCTAssertEqual(report.finding(.disguisedProgram)?.paths, ["w/invoice.pdf.exe"])
        XCTAssertEqual(report.finding(.program)?.paths, ["w/tool.sh"])
        XCTAssertEqual(report.finding(.nestedArchive)?.paths, ["w/inner.tar.gz"])
        XCTAssertEqual(report.highestLevel, .danger)

        try folder.run("/usr/bin/tar", ["--format", "7zip", "-cf", "abs.7z", "-P", "-s", ",^w/tool.sh,/usr/local/bin/tool,", "w"])
        XCTAssertNotNil(ArchiveSafety.scan(try folder.list("abs.7z")).finding(.absolutePath))
    }

    func testCompressedNewFormatsAreJudgedForExpansion() throws {
        let folder = try FixtureFolder()
        try folder.write("z/zeros.img", Data(count: 24 * 1024 * 1024))
        try folder.run("/usr/bin/tar", ["-cJf", "z.txz", "z"])
        let report = ArchiveSafety.scan(try folder.list("z.txz"))
        XCTAssertNotNil(report.finding(.archiveExpansion))
        // A stored container is not judged: an ISO's size is its contents.
        try folder.run("/usr/bin/tar", ["--format", "newc", "-cf", "z.cpio", "z"])
        XCTAssertNil(ArchiveSafety.scan(try folder.list("z.cpio")).finding(.archiveExpansion))
    }
}

/// A source that sleeps on every read: a slow disk, so the time budget has something to stop.
final class SlowSource: ArchiveByteSource {
    let inner: any ArchiveByteSource
    let delay: TimeInterval
    init(_ inner: any ArchiveByteSource, delay: TimeInterval) { self.inner = inner; self.delay = delay }
    var size: Int64 { inner.size }
    func read(at offset: Int64, count: Int) throws -> [UInt8] {
        Thread.sleep(forTimeInterval: delay)
        return try inner.read(at: offset, count: min(count, 16 * 1024))
    }
}
