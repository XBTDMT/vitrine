import Foundation

/// Random-access bytes of one file: an archive, a binary, a package or a disk image. Readers ask for small windows
/// (an end record, a header, a trailer) and never for the whole file, so a 20 GB file costs what its directory
/// costs. One implementation serves every engine that reads untrusted bytes, so the bounds and refusals below are
/// written once and cannot drift between engines. Implementations must be safe to call from any thread: a preview
/// may read on a background queue while the UI asks for the size.
public protocol ByteSource: Sendable {
    /// The total length in bytes.
    var size: Int64 { get }
    /// Up to `count` bytes starting at `offset`. Fewer only when the range runs past the end; empty at or past the
    /// end, for a negative offset and for a count of zero or less. Throws only for I/O failures, never for a range
    /// outside the file.
    func read(at offset: Int64, count: Int) throws -> [UInt8]
}

/// The errors a byte reader raises, expressed in the reading engine's own error type. Each engine (archives,
/// binaries) keeps its own error enum with its own wording on screen; conforming it here lets the shared readers
/// throw that type directly, so nothing has to be caught and translated at the edge. An enum's cases satisfy these
/// requirements as written (`case unreadable(String)` is `static func unreadable(_:)`).
public protocol ByteReadFailure: Error {
    /// The file could not be opened or read (permissions, I/O, not a regular file).
    static func unreadable(_ reason: String) -> Self
    /// The bytes end before a structure they declare.
    static func truncated(_ reason: String) -> Self
    /// A structure contradicts itself (a negative length, an offset outside its own bytes).
    static func malformed(_ reason: String) -> Self
}

/// A file read with `pread`, so concurrent reads need no shared position and no lock. The descriptor is opened
/// read-only, non-blocking (a FIFO never stalls the preview) and close-on-exec, and is closed when the source goes
/// away; nothing is ever written, executed or mapped. Anything but a regular file (a FIFO, a folder, a device) is
/// refused at open, because its size is meaningless and reading it could block or never end. Errors are raised as
/// `Failure`, the calling engine's own error type.
public final class BoundedFileSource<Failure: ByteReadFailure>: ByteSource {
    public let size: Int64
    private let descriptor: Int32

    public init(url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)   // never block on a FIFO
        guard fd >= 0 else { throw Failure.unreadable("cannot open the file (errno \(errno))") }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw Failure.unreadable("cannot read the file's size (errno \(code))")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw Failure.unreadable("not a regular file")
        }
        descriptor = fd
        size = Int64(info.st_size)
    }

    deinit { close(descriptor) }

    public func read(at offset: Int64, count: Int) throws -> [UInt8] {
        guard offset >= 0, count > 0, offset < size else { return [] }
        let wanted = Int(min(Int64(count), size - offset))
        var bytes = [UInt8](repeating: 0, count: wanted)
        var filled = 0
        try bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while filled < wanted {
                let n = pread(descriptor, base + filled, wanted - filled, off_t(offset + Int64(filled)))
                if n > 0 { filled += n; continue }
                if n == 0 { break }                      // the file shrank under us: return what exists
                if errno == EINTR { continue }
                throw Failure.unreadable("read failed at offset \(offset + Int64(filled)) (errno \(errno))")
            }
        }
        if filled < wanted { bytes.removeSubrange(filled...) }
        return bytes
    }
}

/// Bytes already in memory: an attachment, a member of another archive, a test fixture. Reads never fail.
public struct MemoryByteSource: ByteSource {
    public let bytes: [UInt8]
    public var size: Int64 { Int64(bytes.count) }

    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public init(_ data: Data) { self.bytes = [UInt8](data) }

    public func read(at offset: Int64, count: Int) throws -> [UInt8] {
        guard offset >= 0, count > 0, offset < size else { return [] }
        let start = Int(offset)
        let end = start + min(count, bytes.count - start)
        return Array(bytes[start..<end])
    }
}

/// A window of another source: one architecture of a universal binary, one member of a container. Offsets are
/// relative to the window's start and reads never cross its end, so a header that lies about its extent cannot make
/// a reader look at a neighbour.
public struct SliceByteSource: ByteSource {
    public let base: any ByteSource
    public let start: Int64
    public let size: Int64

    /// The part of `base` from `start` for `length` bytes, clipped to the end of `base`.
    public init(_ base: any ByteSource, start: Int64, length: Int64) {
        self.base = base
        self.start = max(0, min(start, base.size))
        self.size = max(0, min(length, base.size - self.start))
    }

    public func read(at offset: Int64, count: Int) throws -> [UInt8] {
        guard offset >= 0, count > 0, offset < size else { return [] }
        let wanted = Int(min(Int64(count), size - offset))
        return try base.read(at: start + offset, count: wanted)
    }
}

extension ByteSource {
    /// Exactly `count` bytes at `offset`, or a `Failure` naming `what`: `malformed` for a negative count (a declared
    /// length that went negative is a damaged structure, not a short file) and `truncated` when the file ends first.
    /// A count of zero is an empty read, not an error.
    public func readExactly<Failure: ByteReadFailure>(_ count: Int, at offset: Int64, _ what: @autoclosure () -> String,
                                                      failing: Failure.Type) throws -> [UInt8] {
        guard count >= 0 else { throw Failure.malformed("\(what()) has a negative length") }
        if count == 0 { return [] }
        let got = try read(at: offset, count: count)
        guard got.count == count else { throw Failure.truncated("the file ends inside \(what())") }
        return got
    }
}

/// Bounds-checked reads over a byte array in either byte order. Every input is untrusted, so a read past either end
/// throws a `Failure` instead of trapping; callers turn that into a reason on screen. The position may be set
/// anywhere (even negative) without a trap; each read checks it before touching memory.
public struct BoundedByteCursor<Failure: ByteReadFailure>: Sendable {
    public let bytes: [UInt8]
    public private(set) var index: Int
    public let bigEndian: Bool
    private let what: String

    /// A cursor over `bytes` starting at `index`. `what` names the structure in errors ("the xar header ends
    /// early"). Little-endian unless `bigEndian` is set.
    public init(_ bytes: [UInt8], at index: Int = 0, bigEndian: Bool = false, what: String) {
        self.bytes = bytes; self.index = index; self.bigEndian = bigEndian; self.what = what
    }

    /// Bytes left after the position; zero when the position is past the end.
    public var remaining: Int { max(0, bytes.count - index) }

    private func endsEarly() -> Failure { Failure.truncated("\(what) ends early") }

    private mutating func unsigned(_ width: Int) throws -> UInt64 {
        guard index >= 0, remaining >= width else { throw endsEarly() }
        defer { index += width }
        var value: UInt64 = 0
        for i in 0..<width {
            let byte = UInt64(bytes[index + i])
            value |= bigEndian ? byte << (8 * UInt64(width - 1 - i)) : byte << (8 * UInt64(i))
        }
        return value
    }

    public mutating func u8() throws -> UInt8 { UInt8(try unsigned(1)) }
    public mutating func u16() throws -> UInt16 { UInt16(try unsigned(2)) }
    public mutating func u32() throws -> UInt32 { UInt32(try unsigned(4)) }
    public mutating func u64() throws -> UInt64 { try unsigned(8) }

    /// An unsigned integer of 1 to 8 bytes in the cursor's byte order (Info-ZIP's variable-width uid and gid). Any
    /// other width is `malformed`: the width came from the file.
    public mutating func uint(width: Int) throws -> UInt64 {
        guard (1...8).contains(width) else { throw Failure.malformed("\(what) has a \(width)-byte number") }
        return try unsigned(width)
    }

    public mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, index >= 0, remaining >= count else { throw endsEarly() }
        defer { index += count }
        return Array(bytes[index..<(index + count)])
    }

    public mutating func skip(_ count: Int) throws {
        guard count >= 0, index >= 0, remaining >= count else { throw endsEarly() }
        index += count
    }

    /// Moves to `position`, which may be the end itself but not past it; anything else is `malformed` (an offset the
    /// structure declared points outside its own bytes).
    public mutating func seek(_ position: Int) throws {
        guard position >= 0, position <= bytes.count else { throw Failure.malformed("\(what) points outside itself") }
        index = position
    }
}
