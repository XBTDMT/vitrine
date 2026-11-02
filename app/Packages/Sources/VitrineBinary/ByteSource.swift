import Foundation
import VitrineSupport

// The byte sources and the cursor live in VitrineSupport (`ByteSource.swift`), shared with VitrineArchive, so the code
// that reads untrusted bytes exists once and cannot drift. The names below keep this module's API as it was; errors
// still arrive as `BinaryError`, because the shared readers throw the error type they are given.

/// Random-access bytes of one binary, package or disk image (the shared `ByteSource`). Readers ask for small
/// windows (a header, a load command area, a trailer) and never for the whole file.
public typealias BinaryByteSource = ByteSource
/// A binary read with `pread`; refuses anything but a regular file and throws `BinaryError`.
public typealias BinaryFileSource = BoundedFileSource<BinaryError>
/// Bytes already in memory: a member of an archive, a test fixture.
public typealias BinaryDataSource = MemoryByteSource
/// A window of another source: one architecture of a universal binary.
public typealias BinarySliceSource = SliceByteSource
/// Bounds-checked reads over untrusted bytes in either byte order that throw `BinaryError`.
typealias ByteCursor = BoundedByteCursor<BinaryError>

/// The shared readers raise `BinaryError` through these cases (`unreadable`, `truncated`, `malformed`).
extension BinaryError: ByteReadFailure {}

extension ByteSource {
    /// Exactly `count` bytes at `offset`, or `BinaryError.truncated` naming `what` (`malformed` for a negative
    /// count); the shared `readExactly` with this module's error type.
    func exactly(_ count: Int, at offset: Int64, _ what: @autoclosure () -> String) throws -> [UInt8] {
        try readExactly(count, at: offset, what(), failing: BinaryError.self)
    }
}

extension Array where Element == UInt8 {
    /// Fixed-offset reads that return nil when out of range (signature probes).
    func be32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(self[offset + $1]) }
    }

    func le32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[offset + $1]) << (8 * UInt32($1)) }
    }

    func be64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(self[offset + $1]) }
    }

    /// A NUL-terminated string starting at `offset` and never reading past `limit` (or the end): load command
    /// strings and fixed-width name fields. Invalid UTF-8 is replaced, never trusted.
    func cString(at offset: Int, limit: Int? = nil) -> String? {
        let end = Swift.min(limit ?? count, count)
        guard offset >= 0, offset < end else { return nil }
        var stop = offset
        while stop < end, self[stop] != 0 { stop += 1 }
        return String(decoding: self[offset..<stop], as: UTF8.self)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
