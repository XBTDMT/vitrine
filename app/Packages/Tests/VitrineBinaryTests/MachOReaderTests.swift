import Foundation
import XCTest
@testable import VitrineBinary

final class MachOReaderTests: XCTestCase {
    // MARK: - Real binaries from the toolchain

    func testThinExecutable() throws {
        let fx = try SharedFixtures.get()
        let file = try MachOReader.read(contentsOf: fx.thin)
        XCTAssertFalse(file.isUniversal)
        XCTAssertEqual(file.architectures, ["arm64"])
        let slice = try XCTUnwrap(file.slices.first)
        XCTAssertTrue(slice.isComplete, "\(slice.notes)")
        XCTAssertTrue(slice.is64Bit)
        XCTAssertFalse(slice.isBigEndian)
        XCTAssertEqual(slice.fileType, .executable)
        XCTAssertEqual(slice.fileType.name, "executable")
        XCTAssertTrue(slice.isPIE)
        XCTAssertTrue(slice.flags.names.contains("PIE"))
        XCTAssertTrue(slice.flags.names.contains("TWOLEVEL"))
        XCTAssertNotNil(slice.entryOffset)

        let build = try XCTUnwrap(slice.platforms.first)
        XCTAssertEqual(build.platform, .macOS)
        XCTAssertEqual(build.platform.name, "macOS")
        XCTAssertEqual(build.minimumOS, MachOVersion(major: 13, minor: 0))
        XCTAssertGreaterThanOrEqual(build.sdk.major, 13)
        XCTAssertEqual(build.source, .buildVersion)
        XCTAssertTrue(build.tools.contains { $0.name == "ld" })

        XCTAssertEqual(slice.rpaths, ["@loader_path/../Frameworks"])
        let system = try XCTUnwrap(slice.linkedDylibs.first { $0.path == "/usr/lib/libSystem.B.dylib" })
        XCTAssertEqual(system.kind, .load)
        XCTAssertGreaterThan(system.currentVersion.major, 1000)
        let fx2 = try XCTUnwrap(slice.linkedDylibs.first { $0.path == "@rpath/libfx.dylib" })
        XCTAssertEqual(fx2.kind, .weak)
        XCTAssertEqual(fx2.currentVersion.description, "2.3.4")
        XCTAssertEqual(fx2.compatibilityVersion.description, "2.0")

        XCTAssertEqual(Set(slice.segments.map(\.name)).isSuperset(of: ["__PAGEZERO", "__TEXT", "__LINKEDIT"]), true)
        let text = try XCTUnwrap(slice.segments.first { $0.name == "__TEXT" })
        XCTAssertEqual(text.initialProtection, "r-x")
        XCTAssertGreaterThan(text.sectionCount, 0)
        XCTAssertNil(slice.encryption)

        // The arm64 linker signs ad hoc on its own: the signature is present and says so.
        XCTAssertTrue(slice.hasCodeSignature)
        let signature = try XCTUnwrap(slice.codeSignature, slice.codeSignatureProblem ?? "")
        XCTAssertTrue(signature.isAdhoc)
        XCTAssertTrue(signature.primary?.flags.contains(.linkerSigned) == true)

        // The UUID agrees with the toolchain's own reader.
        let otool = try fx.folder.run("/usr/bin/otool", ["-l", fx.thin.path])
        let uuidLine = try XCTUnwrap(otool.split(separator: "\n").first { $0.contains(" uuid ") })
        XCTAssertEqual(slice.uuid?.uuidString, uuidLine.split(separator: " ").last.map(String.init))
    }

    func testUniversalBinary32And64BitHeaders() throws {
        let fx = try SharedFixtures.get()
        for (url, wide) in [(fx.fat, false), (fx.fat64, true)] {
            let file = try MachOReader.read(contentsOf: url)
            XCTAssertTrue(file.isUniversal)
            XCTAssertEqual(file.usesFat64, wide)
            XCTAssertEqual(Set(file.architectures), ["arm64", "x86_64"])
            XCTAssertTrue(file.unreadableSlices.isEmpty)
            XCTAssertTrue(file.notes.isEmpty, "\(file.notes)")
            for slice in file.slices {
                XCTAssertTrue(slice.isComplete, "\(slice.cpu): \(slice.notes)")
                XCTAssertEqual(slice.platforms.first?.minimumOS, MachOVersion(major: 12, minor: 0))
                XCTAssertGreaterThan(slice.fileOffset, 0)
                XCTAssertNotNil(slice.uuid)
            }
            let lipo = try fx.folder.run("/usr/bin/lipo", ["-archs", url.path])
            XCTAssertEqual(Set(lipo.split(whereSeparator: \.isWhitespace).map(String.init)), Set(file.architectures))
        }
    }

    func testDylibInstallNameAndVersions() throws {
        let fx = try SharedFixtures.get()
        let slice = try XCTUnwrap(try MachOReader.read(contentsOf: fx.dylib).slices.first)
        XCTAssertEqual(slice.fileType, .dylib)
        XCTAssertEqual(slice.fileType.name, "dynamic library")
        XCTAssertEqual(slice.installName?.path, "@rpath/libfx.dylib")
        XCTAssertEqual(slice.installName?.kind, .id)
        XCTAssertEqual(slice.installName?.currentVersion, MachOVersion(major: 2, minor: 3, patch: 4))
        XCTAssertNil(slice.entryOffset)
    }

    func testOlderVersionMinCommand() throws {
        let fx = try SharedFixtures.get()
        let slice = try XCTUnwrap(try MachOReader.read(contentsOf: fx.old).slices.first)
        XCTAssertEqual(slice.cpu.name, "x86_64")
        let build = try XCTUnwrap(slice.platforms.first)
        XCTAssertEqual(build.source, .versionMin)
        XCTAssertEqual(build.platform, .macOS)
        XCTAssertEqual(build.minimumOS, MachOVersion(major: 10, minor: 13))
    }

    func testArm64eSubtype() throws {
        let fx = try SharedFixtures.get()
        let slice = try XCTUnwrap(try MachOReader.read(contentsOf: fx.arm64e).slices.first)
        XCTAssertEqual(slice.cpu.name, "arm64e")
        XCTAssertNotNil(slice.cpu.pointerAuthenticationABIVersion)
    }

    func testSniffing() throws {
        let fx = try SharedFixtures.get()
        for url in [fx.thin, fx.fat, fx.fat64, fx.dylib] {
            XCTAssertTrue(MachOReader.looksLikeMachO(try BinaryFileSource(url: url).read(at: 0, count: 8)))
        }
        // A Java class file shares the universal magic; its "count" is the class version.
        XCTAssertFalse(MachOReader.looksLikeMachO([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x34]))
        XCTAssertFalse(MachOReader.looksLikeMachO(Array("#!/bin/sh\n".utf8)))
    }

    // MARK: - Hand-built cases

    func testEncryptionInfoBigEndianAndVersionMinFromBytes() throws {
        var b = MachOBuilder()
        b.bigEndian = true
        b.is64 = false
        b.cpuType = 18                                            // ppc
        b.commands = [
            b.command(0x21, b.word(0x4000) + b.word(0x8000) + b.word(1)),           // LC_ENCRYPTION_INFO
            b.command(0x25, b.word(0x0009_0000) + b.word(0x000A_0000)),             // LC_VERSION_MIN_IPHONEOS 9.0
            b.command(0x2A, b.quad(UInt64(1) << 40 | UInt64(2) << 30 | UInt64(3) << 20)),  // LC_SOURCE_VERSION
        ]
        let slice = try XCTUnwrap(try MachOReader.read(source: BinaryDataSource(b.build())).slices.first)
        XCTAssertTrue(slice.isComplete, "\(slice.notes)")
        XCTAssertTrue(slice.isBigEndian)
        XCTAssertEqual(slice.cpu.name, "ppc")
        XCTAssertEqual(slice.encryption, EncryptionInfo(offset: 0x4000, size: 0x8000, cryptID: 1))
        XCTAssertEqual(slice.encryption?.isEncrypted, true)
        XCTAssertEqual(slice.platforms.first?.platform, .iOS)
        XCTAssertEqual(slice.platforms.first?.minimumOS.description, "9.0")
        XCTAssertEqual(slice.platforms.first?.sdk.description, "10.0")
        XCTAssertEqual(slice.sourceVersion, "1.2.3")
    }

    func testCPUNames() {
        XCTAssertEqual(CPUType(type: 0x0100_0007, subtype: 8).name, "x86_64h")
        XCTAssertEqual(CPUType(type: 7, subtype: 3).name, "i386")
        XCTAssertEqual(CPUType(type: 12, subtype: 12).name, "armv7k")
        XCTAssertEqual(CPUType(type: 0x0200_000C, subtype: 1).name, "arm64_32")
        XCTAssertEqual(CPUType(type: 0x0100_000C, subtype: Int32(bitPattern: 0x8200_0002)).name, "arm64e")
        XCTAssertEqual(CPUType(type: 0x0100_000C, subtype: Int32(bitPattern: 0x8200_0002)).pointerAuthenticationABIVersion, 2)
        XCTAssertEqual(CPUType(type: 99, subtype: 1).name, "cpu 99 subtype 1")
        XCTAssertEqual(MachOPlatform(rawValue: 11).name, "visionOS")
        XCTAssertEqual(MachOPlatform(rawValue: 6).name, "Mac Catalyst")
        XCTAssertEqual(MachOFileType(rawValue: 8).name, "bundle")
    }

    func testHostileLoadCommandsAreBoundedNotTrapped() throws {
        var b = MachOBuilder()
        // A command whose size runs past the area, after one good command.
        b.commands = [b.command(0x1B, [UInt8](repeating: 0xAB, count: 16)), b.word(0x1D) + b.word(4096)]
        var slice = try XCTUnwrap(try MachOReader.read(source: BinaryDataSource(b.build())).slices.first)
        XCTAssertNotNil(slice.uuid)
        XCTAssertEqual(slice.readLoadCommands, 1)
        XCTAssertFalse(slice.isComplete)

        // cmdsize 0 would loop forever in a naive reader.
        b.commands = [b.word(0x1B) + b.word(0) + [UInt8](repeating: 0, count: 16)]
        slice = try XCTUnwrap(try MachOReader.read(source: BinaryDataSource(b.build())).slices.first)
        XCTAssertEqual(slice.readLoadCommands, 0)
        XCTAssertTrue(slice.notes.contains { $0.contains("impossible size") })

        // An absurd command count with a small area: read what is there, say the rest.
        b.commands = [b.command(0x1B, [UInt8](repeating: 1, count: 16))]
        b.declaredCount = 0xFFFF_FFFF
        slice = try XCTUnwrap(try MachOReader.read(source: BinaryDataSource(b.build())).slices.first)
        XCTAssertEqual(slice.readLoadCommands, 1)
        XCTAssertEqual(slice.declaredLoadCommands, Int(UInt32.max))
        XCTAssertFalse(slice.notes.isEmpty)

        // sizeofcmds larger than the file.
        b.declaredCount = 1
        b.declaredSize = 0xFFFF_FFF0
        slice = try XCTUnwrap(try MachOReader.read(source: BinaryDataSource(b.build())).slices.first)
        XCTAssertNotNil(slice.uuid)
        XCTAssertTrue(slice.notes.contains { $0.contains("only") })

        // A dylib whose name offset points outside its command, next to a good one.
        b = MachOBuilder()
        b.commands = [b.dylib(0xC, "/usr/lib/libgood.dylib"), b.dylib(0xC, "/bad", nameOffset: 0xFFFF),
                      b.dylib(0xC, "/bad", nameOffset: 4)]
        slice = try XCTUnwrap(try MachOReader.read(source: BinaryDataSource(b.build())).slices.first)
        XCTAssertEqual(slice.linkedDylibs.map(\.path), ["/usr/lib/libgood.dylib"])
        XCTAssertEqual(slice.notes.count, 2)

        // LC_BUILD_VERSION claiming a million tools.
        b.commands = [b.command(0x32, b.word(1) + b.word(0x000E_0000) + b.word(0x000F_0000) + b.word(1_000_000)
                                + b.word(3) + b.word(0x0400_0000))]
        slice = try XCTUnwrap(try MachOReader.read(source: BinaryDataSource(b.build())).slices.first)
        XCTAssertEqual(slice.platforms.first?.tools.count, 1)
        XCTAssertEqual(slice.platforms.first?.minimumOS.description, "14.0")

        // A segment claiming more sections than it holds and file bytes past the end.
        b.commands = [b.command(0x19, Array("__TEXT".utf8) + [UInt8](repeating: 0, count: 10) + b.quad(0) + b.quad(0x4000)
                                + b.quad(0) + b.quad(0xFFFF_FFFF) + b.word(5) + b.word(5) + b.word(500) + b.word(0))]
        slice = try XCTUnwrap(try MachOReader.read(source: BinaryDataSource(b.build())).slices.first)
        XCTAssertEqual(slice.segments.first?.name, "__TEXT")
        XCTAssertEqual(slice.notes.count, 2)

        // The load command cap.
        b.commands = Array(repeating: b.command(0x1B, [UInt8](repeating: 2, count: 16)), count: 50)
        var limits = BinaryLimits()
        limits.maxLoadCommands = 10
        slice = try XCTUnwrap(try MachOReader.read(source: BinaryDataSource(b.build()), limits: limits).slices.first)
        XCTAssertEqual(slice.readLoadCommands, 10)
        XCTAssertFalse(slice.isComplete)

        // A signature range outside the file.
        b.commands = [b.command(0x1D, b.word(0x7FFF_0000) + b.word(0x1000))]
        slice = try XCTUnwrap(try MachOReader.read(source: BinaryDataSource(b.build())).slices.first)
        XCTAssertTrue(slice.hasCodeSignature)
        XCTAssertNil(slice.codeSignature)
        XCTAssertNotNil(slice.codeSignatureProblem)
    }

    func testTruncatedHeadersThrow() {
        assertBinaryError(try MachOReader.read(source: BinaryDataSource([])), matching: {
            if case .notRecognized = $0 { true } else { false }
        })
        assertBinaryError(try MachOReader.read(source: BinaryDataSource([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0, 0, 1])), matching: {
            if case .truncated = $0 { true } else { false }
        })
        assertBinaryError(try MachOReader.read(source: BinaryDataSource(Array("not a binary at all".utf8))))
    }

    func testHostileUniversalHeaders() throws {
        let fx = try SharedFixtures.get()
        let thin = [UInt8](try Data(contentsOf: fx.thin))

        func fat(_ entries: [(UInt32, UInt32)], count: UInt32? = nil, payload: [UInt8] = []) -> [UInt8] {
            var out: [UInt8] = []
            out.be32(0xCAFE_BABE); out.be32(count ?? UInt32(entries.count))
            for (offset, size) in entries {
                out.be32(0x0100_000C); out.be32(0); out.be32(offset); out.be32(size); out.be32(14)
            }
            return out + payload
        }

        // No architectures; Java-like counts.
        assertBinaryError(try MachOReader.read(source: BinaryDataSource(fat([]))))
        assertBinaryError(try MachOReader.read(source: BinaryDataSource(fat([], count: 0xFFFF))), matching: {
            if case .notRecognized = $0 { true } else { false }
        })
        // The table runs past the file.
        assertBinaryError(try MachOReader.read(source: BinaryDataSource(fat([], count: 5))), matching: {
            if case .truncated = $0 { true } else { false }
        })

        // One good slice at 4096, one outside the file, one overlapping the header, one duplicating the good one.
        var padded = fat([(4096, UInt32(thin.count)), (0x7FFF_FFF0, 0x100), (0, 64), (4096, UInt32(thin.count))])
        padded += [UInt8](repeating: 0, count: 4096 - padded.count) + thin
        let file = try MachOReader.read(source: BinaryDataSource(padded))
        XCTAssertEqual(file.slices.count, 2)
        XCTAssertEqual(file.unreadableSlices.count, 2)
        XCTAssertTrue(file.notes.contains { $0.contains("overlaps") })
        XCTAssertEqual(file.slices.first?.linkedDylibs.isEmpty, false)

        // Every slice unreadable: the reader refuses with the first reason.
        assertBinaryError(try MachOReader.read(source: BinaryDataSource(fat([(0x7FFF_FFF0, 0x100)]))), matching: {
            if case .malformed = $0 { true } else { false }
        })

        // A slice whose header says another CPU than the table.
        var other = fat([(4096, UInt32(thin.count))])
        other[8 + 3] = 7                                              // table says x86_64
        other += [UInt8](repeating: 0, count: 4096 - other.count) + thin
        let mismatch = try MachOReader.read(source: BinaryDataSource(other))
        XCTAssertTrue(mismatch.notes.contains { $0.contains("says") })
    }

    func testRandomDamageNeverTraps() throws {
        let fx = try SharedFixtures.get()
        var parsed = 0, refused = 0
        for url in [fx.thin, fx.fat, fx.fat64, fx.signed, fx.dylib] {
            let bytes = [UInt8](try Data(contentsOf: url))
            fuzz(bytes, rounds: 400, seed: UInt64(bytes.count)) { damaged in
                do { _ = try MachOReader.read(source: BinaryDataSource(damaged)); parsed += 1 }
                catch is BinaryError { refused += 1 }
                catch { XCTFail("unexpected error \(error)") }
            }
        }
        XCTAssertEqual(parsed + refused, 2000)
        XCTAssertGreaterThan(parsed, 0)

        // Every truncation point of the signed binary's first 8 KiB.
        let signed = [UInt8](try Data(contentsOf: fx.signed))
        for length in stride(from: 0, to: min(signed.count, 8192), by: 7) {
            _ = try? MachOReader.read(source: BinaryDataSource(Array(signed.prefix(length))))
        }
    }
}
