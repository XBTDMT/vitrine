import Foundation
import Synchronization
import XCTest
@testable import VitrineBinary

/// Disk images come from `hdiutil create` only; nothing here attaches, mounts or verifies an image.
final class DiskImageTests: XCTestCase {
    /// One UDZO image shared by the tests that only read or copy it (`hdiutil create` takes seconds per image).
    private static let base = Mutex<FixtureFolder?>(nil)

    func sharedBase() throws -> (FixtureFolder, URL) {
        let folder = try Self.base.withLock { cached -> FixtureFolder in
            if let cached { return cached }
            let made = try FixtureFolder("vitrine-binary-dmg")
            BundleCleanup.keep(made)
            try makeImage(made, "base.dmg", format: "UDZO")
            cached = made
            return made
        }
        return (folder, folder.path("base.dmg"))
    }

    func makeImage(_ folder: FixtureFolder, _ name: String, format: String) throws {
        try folder.write("src-\(name)/hello.txt", String(repeating: "hello disk image\n", count: 200))
        try folder.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", "src-\(name)", "-volname", "Fixture",
                                            "-format", format, "-o", name])
    }

    func testCompressedImages() throws {
        let folder = try FixtureFolder()
        let (_, base) = try sharedBase()
        try FileManager.default.copyItem(at: base, to: folder.path("UDZO.dmg"))
        for (format, expected) in [("UDZO", "UDZO (zlib)"), ("ULFO", "ULFO (LZFSE)"), ("UDBZ", "UDBZ (bzip2)")] {
            if format != "UDZO" { try makeImage(folder, "\(format).dmg", format: format) }
            let image = try DiskImageReader.read(contentsOf: folder.path("\(format).dmg"))
            XCTAssertEqual(image.container, .udif, format)
            XCTAssertFalse(image.isEncrypted)
            XCTAssertTrue(image.notes.isEmpty, "\(format): \(image.notes)")
            let trailer = try XCTUnwrap(image.trailer)
            XCTAssertEqual(trailer.version, 4)
            XCTAssertTrue(trailer.isFlattened)
            XCTAssertFalse(trailer.isSegmented)
            XCTAssertGreaterThan(trailer.dataForkLength, 0)
            XCTAssertGreaterThan(trailer.xmlLength, 0)
            XCTAssertEqual(trailer.masterChecksumType.name, "CRC-32")
            XCTAssertEqual(trailer.codeSignatureLength, 0)
            XCTAssertGreaterThan(image.sectorCount ?? 0, 0)
            XCTAssertEqual(image.inferredFormat, expected, format)
            XCTAssertFalse(image.partitions.isEmpty)
            XCTAssertFalse(image.partitionsTruncated)
            // The partitions together cover the image's sectors, and one of them holds the file system.
            XCTAssertEqual(image.partitions.reduce(0) { $0 + $1.sectorCount }, image.sectorCount)
            XCTAssertTrue(image.partitions.contains { $0.name.contains("Apple_HFS") || $0.name.contains("Apple_APFS") },
                          "\(image.partitions.map(\.name))")
            XCTAssertNil(image.codeSignature)
            XCTAssertFalse(image.hasTicketSlot)
        }
        try makeImage(folder, "raw.dmg", format: "UDRO")
        XCTAssertEqual(try DiskImageReader.read(contentsOf: folder.path("raw.dmg")).inferredFormat, "uncompressed (UDRO/UDRW)")
    }

    func testSignedImage() throws {
        let folder = try FixtureFolder()
        try FileManager.default.copyItem(at: try sharedBase().1, to: folder.path("signed.dmg"))
        try folder.run("/usr/bin/codesign", ["-s", "-", "-i", "com.example.image", "signed.dmg"])
        let image = try DiskImageReader.read(contentsOf: folder.path("signed.dmg"))
        let trailer = try XCTUnwrap(image.trailer)
        XCTAssertGreaterThan(trailer.codeSignatureLength, 0)
        let signature = try XCTUnwrap(image.codeSignature, "\(image.notes)")
        XCTAssertEqual(signature.identifier, "com.example.image")
        XCTAssertTrue(signature.isAdhoc)
        XCTAssertFalse(image.hasTicketSlot)
        XCTAssertEqual(SignatureVerifier.assess(url: folder.path("signed.dmg")).status, .adhoc)
    }

    func testEncryptedImageSaysSoHonestly() throws {
        let folder = try FixtureFolder()
        try folder.write("src/secret.txt", "inside an encrypted image\n")
        try folder.run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", "src", "-volname", "Locked", "-encryption",
                                            "AES-256", "-stdinpass", "-format", "UDZO", "-o", "locked.dmg"],
                       input: Data("fixture-passphrase".utf8))
        let image = try DiskImageReader.read(contentsOf: folder.path("locked.dmg"))
        XCTAssertTrue(image.isEncrypted)
        guard case .encryptedV2(let header) = image.container else { return XCTFail("expected encrcdsa: \(image.container)") }
        XCTAssertEqual(header.version, 2)
        XCTAssertEqual(header.keyBits, 256)
        XCTAssertEqual(header.blockSize, 512)
        XCTAssertGreaterThan(header.encryptedDataSize, 0)
        XCTAssertNil(image.trailer)
        XCTAssertTrue(image.partitions.isEmpty)

        // The other encrypted containers, from their published markers.
        XCTAssertEqual(try DiskImageReader.read(source: BinaryDataSource(Array("AEA1".utf8) + [UInt8](repeating: 0, count: 600))).container,
                       .appleEncryptedArchive)
        XCTAssertEqual(try DiskImageReader.read(source: BinaryDataSource([UInt8](repeating: 7, count: 600) + Array("cdsaencr".utf8))).container,
                       .encryptedV1)
    }

    func testHostileTrailers() throws {
        let good = [UInt8](try Data(contentsOf: try sharedBase().1))
        let k = good.count - 512

        func with(_ edit: (inout [UInt8]) -> Void) -> [UInt8] { var copy = good; edit(&copy); return copy }
        func put64(_ bytes: inout [UInt8], _ at: Int, _ v: UInt64) {
            for i in 0..<8 { bytes[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(7 - i))) }
        }

        assertBinaryError(try DiskImageReader.read(source: BinaryDataSource(Array("tiny".utf8))))
        assertBinaryError(try DiskImageReader.read(source: BinaryDataSource([UInt8](repeating: 0, count: 4096))), matching: {
            if case .notRecognized = $0 { true } else { false }
        })
        // A trailer that states another size.
        assertBinaryError(try DiskImageReader.read(source: BinaryDataSource(with { $0[k + 10] = 0x04 })))
        // The partition list outside the file, or larger than the cap: the trailer is still shown, with a note.
        var image = try DiskImageReader.read(source: BinaryDataSource(with { put64(&$0, k + 216, UInt64(1) << 50) }))
        XCTAssertNotNil(image.trailer)
        XCTAssertTrue(image.partitions.isEmpty)
        XCTAssertFalse(image.notes.isEmpty)
        var limits = BinaryLimits()
        limits.maxDiskImagePlistBytes = 100
        image = try DiskImageReader.read(source: BinaryDataSource(good), limits: limits)
        XCTAssertTrue(image.notes.first?.contains("cap") == true)
        // A code signature range that lies; a data fork that runs past the end.
        image = try DiskImageReader.read(source: BinaryDataSource(with {
            put64(&$0, k + 296, UInt64.max - 4); put64(&$0, k + 304, 100); put64(&$0, k + 32, UInt64.max)
        }))
        XCTAssertEqual(image.notes.count, 2, "\(image.notes)")
        XCTAssertNil(image.codeSignature)

        // A partition table claiming a billion chunks reads only those that are there.
        var mish: [UInt8] = []
        mish.be32(0x6D69_7368); mish.be32(1); mish.be64(0); mish.be64(64)
        mish += [UInt8](repeating: 0, count: 200 - mish.count)
        mish.be32(1_000_000_000)
        mish.be32(0x8000_0005); mish.be32(0); mish.be64(0); mish.be64(64); mish.be64(0); mish.be64(1234)
        let partition = try DiskImageReader.parseMish(mish, name: "hostile", id: 0)
        XCTAssertEqual(partition.chunkCount, 1)
        XCTAssertEqual(partition.storedBytes, 1234)
        XCTAssertEqual(partition.compression, ["zlib"])
        XCTAssertEqual(partition.byteCount, 64 * 512)
        assertBinaryError(try DiskImageReader.parseMish(Array("nope".utf8), name: "x", id: nil))

        // Random damage, concentrated on the trailer and the plist, never traps.
        var rng = XorShift(5)
        for round in 0..<400 {
            var copy = good
            for _ in 0..<(1 + rng.below(6)) {
                let at = round % 2 == 0 ? k + rng.below(512) : Int(image.trailer?.xmlOffset ?? 0) + rng.below(Int(image.trailer?.xmlLength ?? 1))
                if at < copy.count { copy[at] = UInt8(truncatingIfNeeded: rng.next()) }
            }
            _ = try? DiskImageReader.read(source: BinaryDataSource(copy))
        }
        fuzz(good, rounds: 200, seed: 3) { damaged in _ = try? DiskImageReader.read(source: BinaryDataSource(damaged)) }
    }
}
