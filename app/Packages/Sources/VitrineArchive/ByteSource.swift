import Foundation
import VitrineSupport

// The byte sources and the cursor live in VitrineSupport (`ByteSource.swift`), shared with VitrineBinary, so the code
// that reads untrusted bytes exists once and cannot drift. The names below keep this module's API as it was; errors
// still arrive as `ArchiveError`, because the shared readers throw the error type they are given.

/// Random-access bytes of one archive (the shared `ByteSource`). Readers ask for small windows (an end record, a
/// central directory, a tar header) and never for the whole file.
public typealias ArchiveByteSource = ByteSource
/// An archive file read with `pread`; refuses anything but a regular file and throws `ArchiveError`.
public typealias FileByteSource = BoundedFileSource<ArchiveError>
/// Archive bytes already in memory: an attachment, a member of another archive, a test fixture.
public typealias DataByteSource = MemoryByteSource
/// Bounds-checked little-endian reads over untrusted bytes that throw `ArchiveError`.
typealias ByteCursor = BoundedByteCursor<ArchiveError>

/// The shared readers raise `ArchiveError` through these cases (`unreadable`, `truncated`, `malformed`).
extension ArchiveError: ByteReadFailure {}

/// A cached window over a source, so readers that walk forward in small steps (central directory records, tar
/// headers) make one system call per window instead of one per field. Not shared across threads: one per listing.
final class WindowedReader {
    let source: any ArchiveByteSource
    private let windowSize: Int
    private var windowStart: Int64 = 0
    private var window: [UInt8] = []

    init(_ source: any ArchiveByteSource, windowSize: Int = 64 * 1024) {
        self.source = source
        self.windowSize = max(windowSize, 512)
    }

    var size: Int64 { source.size }

    /// Up to `count` bytes at `offset`; fewer only at the end of the source.
    func bytes(at offset: Int64, count: Int) throws -> [UInt8] {
        guard count > 0, offset >= 0, offset < source.size else { return [] }
        let end = offset + Int64(count)
        if offset >= windowStart, end <= windowStart + Int64(window.count) {
            let lo = Int(offset - windowStart)
            return Array(window[lo..<(lo + count)])
        }
        if count >= windowSize { return try source.read(at: offset, count: count) }
        window = try source.read(at: offset, count: windowSize)
        windowStart = offset
        let available = min(count, window.count)
        return Array(window[0..<available])
    }

    /// Exactly `count` bytes at `offset`, or `ArchiveError.truncated` naming `what`. A negative count is
    /// `ArchiveError.malformed` and zero is an empty read, the same rule as the shared `ByteSource.readExactly`.
    func exactly(_ count: Int, at offset: Int64, _ what: @autoclosure () -> String) throws -> [UInt8] {
        guard count >= 0 else { throw ArchiveError.malformed("\(what()) has a negative length") }
        let got = try bytes(at: offset, count: count)
        guard got.count == count else { throw ArchiveError.truncated("the file ends inside \(what())") }
        return got
    }
}

extension Array where Element == UInt8 {
    /// Little-endian reads at a fixed offset, nil when out of range (for signature probes).
    func le32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[offset + $1]) << (8 * UInt32($1)) }
    }

    func le16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
}
