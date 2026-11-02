import Foundation
import Synchronization
import XCTest
@testable import VitrineArchive

/// Every fixture is made at test time in a fresh temporary folder, from invented names and contents: archives come
/// from the system tools (`/usr/bin/zip`, `tar`, `gzip`, `ditto`) or are built byte by byte for the cases no tool
/// will write (traversal names, ZIP64, damage). Nothing is extracted, and nothing outside the folder is read.
final class FixtureFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitrine-archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL { try write(relative, Data(text.utf8)) }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }

    func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(at: path(relative), withIntermediateDirectories: true)
    }

    func symlink(_ relative: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative).path, withDestinationPath: target)
    }

    func bytes(_ relative: String) throws -> [UInt8] { [UInt8](try Data(contentsOf: path(relative))) }

    /// Runs a system tool inside the folder and fails the test with its stderr when it exits non-zero.
    @discardableResult
    func run(_ tool: String, _ arguments: [String], allowFailure: Bool = false) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = url
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0, !allowFailure {
            throw FixtureError.toolFailed("\(tool) \(arguments.joined(separator: " ")): "
                                          + String(decoding: errors, as: UTF8.self))
        }
        return output
    }

    func list(_ relative: String, limits: ArchiveLimits = .default) throws -> ArchiveListing {
        try VitrineArchive.list(contentsOf: path(relative), limits: limits)
    }
}

enum FixtureError: Error { case toolFailed(String) }

/// Deterministic pseudo-random bytes (xorshift), so "incompressible" fixtures are the same on every run.
func noise(_ count: Int, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> Data {
    var state = seed
    var bytes = [UInt8](repeating: 0, count: count)
    for i in bytes.indices {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        bytes[i] = UInt8(truncatingIfNeeded: state)
    }
    return Data(bytes)
}

/// A source that counts the bytes readers ask for: the proof that listing does not read member data.
final class CountingSource: ArchiveByteSource {
    let inner: any ArchiveByteSource
    private let counter = Mutex<Int64>(0)

    init(_ inner: any ArchiveByteSource) { self.inner = inner }

    var size: Int64 { inner.size }
    var bytesRead: Int64 { counter.withLock { $0 } }

    func read(at offset: Int64, count: Int) throws -> [UInt8] {
        let bytes = try inner.read(at: offset, count: count)
        counter.withLock { $0 += Int64(bytes.count) }
        return bytes
    }
}

extension Array where Element == UInt8 {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for i in 0..<4 { append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
    mutating func le64(_ v: UInt64) { for i in 0..<8 { append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
}

/// Writes zip bytes directly, for what tools refuse to make: `../` names, ZIP64 records, encryption flags without
/// a password, damage. Member data is written stored (or as given), the directory as specified.
struct ZipBuilder {
    struct Entry {
        var name: [UInt8]
        var data: [UInt8] = []
        var method: UInt16 = 0
        var flags: UInt16 = 0
        /// Host in the high byte (3 = Unix, 0 = MS-DOS), spec version in the low byte.
        var madeBy: UInt16 = 3 << 8 | 20
        var external: UInt32 = 0o100644 << 16
        var crc: UInt32?
        var compressedSize: UInt64?
        var uncompressedSize: UInt64?
        var dosTime: UInt16 = 0
        var dosDate: UInt16 = 0
        var centralExtra: [UInt8] = []
        var comment: [UInt8] = []
        /// Point this directory record at another member's local header (overlap, bombs).
        var localOffsetOverride: UInt64?
        /// Write saturated 32-bit fields and a ZIP64 extra field.
        var zip64 = false
        var omitZip64Extra = false

        init(_ name: String, data: [UInt8] = []) { self.name = Array(name.utf8); self.data = data }
        init(bytes: [UInt8], data: [UInt8] = []) { self.name = bytes; self.data = data }
    }

    var entries: [Entry] = []
    var comment: [UInt8] = []
    var zip64Directory = false
    /// Bytes put in front of the archive without correcting any offset (a naive self-extractor).
    var stub: [UInt8] = []

    func build() -> [UInt8] {
        var body: [UInt8] = []
        var offsets: [UInt64] = []
        for e in entries {
            offsets.append(UInt64(body.count))
            let crc = e.crc ?? CRC32.checksum(e.data)
            body.le32(0x0403_4B50)
            body.le16(20); body.le16(e.flags); body.le16(e.method); body.le16(e.dosTime); body.le16(e.dosDate)
            body.le32(crc)
            body.le32(e.zip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: e.compressedSize ?? UInt64(e.data.count)))
            body.le32(e.zip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: e.uncompressedSize ?? UInt64(e.data.count)))
            body.le16(UInt16(e.name.count)); body.le16(0)
            body += e.name
            body += e.data
        }
        let directoryOffset = UInt64(body.count)
        var directory: [UInt8] = []
        for (i, e) in entries.enumerated() {
            let crc = e.crc ?? CRC32.checksum(e.data)
            let compressed = e.compressedSize ?? UInt64(e.data.count)
            let uncompressed = e.uncompressedSize ?? UInt64(e.data.count)
            let offset = e.localOffsetOverride ?? offsets[i]
            var extra = e.centralExtra
            if e.zip64, !e.omitZip64Extra {
                extra.le16(0x0001); extra.le16(24); extra.le64(uncompressed); extra.le64(compressed); extra.le64(offset)
            }
            directory.le32(0x0201_4B50)
            directory.le16(e.madeBy); directory.le16(e.zip64 ? 45 : 20); directory.le16(e.flags); directory.le16(e.method)
            directory.le16(e.dosTime); directory.le16(e.dosDate); directory.le32(crc)
            directory.le32(e.zip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: compressed))
            directory.le32(e.zip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: uncompressed))
            directory.le16(UInt16(e.name.count)); directory.le16(UInt16(extra.count)); directory.le16(UInt16(e.comment.count))
            directory.le16(0); directory.le16(0); directory.le32(e.external)
            directory.le32(e.zip64 ? 0xFFFF_FFFF : UInt32(truncatingIfNeeded: offset))
            directory += e.name + extra + e.comment
        }
        body += directory
        if zip64Directory {
            let recordOffset = UInt64(body.count)
            body.le32(0x0606_4B50); body.le64(44); body.le16(45); body.le16(45); body.le32(0); body.le32(0)
            body.le64(UInt64(entries.count)); body.le64(UInt64(entries.count))
            body.le64(UInt64(directory.count)); body.le64(directoryOffset)
            body.le32(0x0706_4B50); body.le32(0); body.le64(recordOffset); body.le32(1)
        }
        body.le32(0x0605_4B50); body.le16(0); body.le16(0)
        body.le16(zip64Directory ? 0xFFFF : UInt16(truncatingIfNeeded: entries.count))
        body.le16(zip64Directory ? 0xFFFF : UInt16(truncatingIfNeeded: entries.count))
        body.le32(zip64Directory ? 0xFFFF_FFFF : UInt32(directory.count))
        body.le32(zip64Directory ? 0xFFFF_FFFF : UInt32(directoryOffset))
        body.le16(UInt16(comment.count))
        body += comment
        return stub + body
    }
}

/// Writes tar headers directly, for the types and encodings tools will not make without privileges (devices) or
/// at all (bad checksums, base-256 sizes).
struct TarBuilder {
    enum Magic { case ustar, gnu, v7 }

    var bytes: [UInt8] = []

    static func octal(_ value: Int64, width: Int) -> [UInt8] {
        let digits = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, width - 1 - digits.count)) + digits
        return Array(padded.utf8) + [0]
    }

    mutating func header(_ name: String, type: Character = "0", size: Int64 = 0, mode: Int64 = 0o644,
                         link: String = "", magic: Magic = .ustar, uid: Int64 = 1000, gid: Int64 = 1000,
                         uname: String = "fixture", gname: String = "fixture", mtime: Int64 = 1_700_000_000,
                         devMajor: Int64 = 0, devMinor: Int64 = 0, prefix: String = "",
                         sizeField: [UInt8]? = nil, corruptChecksum: Bool = false) {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ field: [UInt8], at offset: Int, max: Int) {
            for (i, b) in field.prefix(max).enumerated() { h[offset + i] = b }
        }
        put(Array(name.utf8), at: 0, max: 100)
        put(Self.octal(mode, width: 8), at: 100, max: 8)
        put(Self.octal(uid, width: 8), at: 108, max: 8)
        put(Self.octal(gid, width: 8), at: 116, max: 8)
        put(sizeField ?? Self.octal(size, width: 12), at: 124, max: 12)
        put(Self.octal(mtime, width: 12), at: 136, max: 12)
        h[156] = type.asciiValue ?? 0x30
        put(Array(link.utf8), at: 157, max: 100)
        switch magic {
        case .ustar: put(Array("ustar\u{0}00".utf8), at: 257, max: 8)
        case .gnu: put(Array("ustar  \u{0}".utf8), at: 257, max: 8)
        case .v7: break
        }
        if magic != .v7 {
            put(Array(uname.utf8), at: 265, max: 32)
            put(Array(gname.utf8), at: 297, max: 32)
            put(Self.octal(devMajor, width: 8), at: 329, max: 8)
            put(Self.octal(devMinor, width: 8), at: 337, max: 8)
            if magic == .ustar { put(Array(prefix.utf8), at: 345, max: 155) }
        }
        for i in 148..<156 { h[i] = 0x20 }
        var sum = h.reduce(0) { $0 + Int64($1) }
        if corruptChecksum { sum += 1 }
        put(Self.octal(sum, width: 7) + [0x20], at: 148, max: 8)
        bytes += h
    }

    mutating func data(_ data: [UInt8]) {
        bytes += data
        let pad = (512 - data.count % 512) % 512
        bytes += [UInt8](repeating: 0, count: pad)
    }

    mutating func pax(_ type: Character = "x", _ records: [(String, String)]) {
        var body: [UInt8] = []
        for (key, value) in records {
            let core = key.utf8.count + value.utf8.count + 3
            var length = core + 1
            while String(length).count + core != length { length = String(length).count + core }
            body += Array("\(length) \(key)=\(value)\n".utf8)
        }
        header("PaxHeaders/entry", type: type, size: Int64(body.count))
        data(body)
    }

    mutating func end() { bytes += [UInt8](repeating: 0, count: 1024) }
}

extension XCTestCase {
    /// Asserts that `body` throws an `ArchiveError` (never a trap), optionally of the expected case.
    func assertArchiveError(_ body: @autoclosure () throws -> Any, matching predicate: (ArchiveError) -> Bool = { _ in true },
                            _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try body()
            XCTFail("expected an ArchiveError \(message)", file: file, line: line)
        } catch let error as ArchiveError {
            XCTAssertTrue(predicate(error), "unexpected \(error) \(message)", file: file, line: line)
            XCTAssertFalse(error.reason.isEmpty, file: file, line: line)
        } catch {
            XCTFail("expected an ArchiveError, got \(error) \(message)", file: file, line: line)
        }
    }
}
