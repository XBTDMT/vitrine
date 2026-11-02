import Compression
import CryptoKit
import Foundation
import VitrineSupport

/// Why a part of a repository could not be read. Every reader in this library degrades to fewer facts on one of
/// these; none of them reaches the screen as a failure of the whole preview. roadmap: S-9
public enum GitError: Error, Sendable, Equatable, ByteReadFailure {
    case unreadable(String)
    case truncated(String)
    case malformed(String)
    case unsupported(String)
    /// The time or size budget ran out first.
    case overBudget(String)
}

/// A SHA-1 object name: 20 bytes. SHA-256 repositories are detected at open and never reach this type.
/// roadmap: S-9
public struct GitObjectID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 20 else { return nil }
        self.bytes = bytes
    }

    /// From 40 hex digits (either case); nil for anything else.
    public init?(hex: some StringProtocol) {
        let u = Array(hex.utf8)
        guard u.count == 40 else { return nil }
        var out = [UInt8](repeating: 0, count: 20)
        for i in 0..<20 {
            guard let hi = Self.nibble(u[2 * i]), let lo = Self.nibble(u[2 * i + 1]) else { return nil }
            out[i] = hi << 4 | lo
        }
        bytes = out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 97...102: c - 87
        case 65...70: c - 55
        default: nil
        }
    }

    public var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8](); out.reserveCapacity(40)
        for b in bytes { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// The 7-digit form git prints.
    public var short: String { String(hex.prefix(7)) }
    public var description: String { hex }

    public static func < (a: GitObjectID, b: GitObjectID) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }

    /// The name git gives `type size\0content`.
    public static func hash(type: String, content: [UInt8]) -> GitObjectID {
        var h = Insecure.SHA1()
        h.update(data: Array("\(type) \(content.count)\0".utf8))
        h.update(data: content)
        return GitObjectID(bytes: Array(h.finalize()))!
    }
}

/// Every bound the reader keeps, so a huge or hostile repository costs a known amount. roadmap: S-9
public struct GitLimits: Sendable, Equatable {
    /// Wall time for one whole read; past it each stage stops and says so.
    public var timeBudget: Duration
    /// Largest inflated commit, tree or tag object.
    public var maxObjectBytes: Int
    /// Largest blob hashed or read (README, line counts).
    public var maxBlobBytes: Int
    /// Longest delta chain followed in a pack.
    public var maxDeltaDepth: Int
    /// Commits in the recent list.
    public var recentCommits: Int
    /// Commits counted on the branch; past it the count is a floor.
    public var maxCountedCommits: Int
    /// Commits looked at for ahead/behind and for each top-level item's last commit.
    public var maxHistoryWalk: Int
    /// Largest index file read, and the most entries taken from it.
    public var maxIndexBytes: Int
    public var maxIndexEntries: Int
    /// Tree entries expanded when comparing the index with HEAD.
    public var maxTreeEntries: Int
    /// Working files hashed because their size matched but their time did not.
    public var maxHashedFiles: Int
    /// Directory entries visited looking for untracked files.
    public var maxUntrackedVisits: Int
    /// Largest packed-refs, config or .gitignore file read.
    public var maxSmallFileBytes: Int
    /// Tags considered for the nearest tag.
    public var maxTags: Int
    /// Paths kept in the change list (the count goes on past it).
    public var maxListedChanges: Int

    public init(timeBudget: Duration = .seconds(2), maxObjectBytes: Int = 4 << 20, maxBlobBytes: Int = 4 << 20,
                maxDeltaDepth: Int = 64, recentCommits: Int = 8, maxCountedCommits: Int = 10_000, maxHistoryWalk: Int = 2_000,
                maxIndexBytes: Int = 128 << 20, maxIndexEntries: Int = 500_000, maxTreeEntries: Int = 500_000,
                maxHashedFiles: Int = 2_000, maxUntrackedVisits: Int = 50_000, maxSmallFileBytes: Int = 8 << 20,
                maxTags: Int = 2_000, maxListedChanges: Int = 500) {
        self.timeBudget = timeBudget; self.maxObjectBytes = maxObjectBytes; self.maxBlobBytes = maxBlobBytes
        self.maxDeltaDepth = maxDeltaDepth; self.recentCommits = recentCommits; self.maxCountedCommits = maxCountedCommits
        self.maxHistoryWalk = maxHistoryWalk; self.maxIndexBytes = maxIndexBytes; self.maxIndexEntries = maxIndexEntries
        self.maxTreeEntries = maxTreeEntries; self.maxHashedFiles = maxHashedFiles; self.maxUntrackedVisits = maxUntrackedVisits
        self.maxSmallFileBytes = maxSmallFileBytes; self.maxTags = maxTags; self.maxListedChanges = maxListedChanges
    }

    public static let standard = GitLimits()
}

/// The wall-clock end of one read. Loops ask `expired` and stop, so a slow disk or a giant repository ends in
/// fewer facts, never a hang.
struct GitDeadline: Sendable {
    let end: ContinuousClock.Instant
    init(_ budget: Duration) { end = .now + budget }
    var expired: Bool { ContinuousClock.now >= end }
}

/// Small whole-file reads with a size cap; nil for a missing, unreadable, oversized or non-regular file.
enum SmallFile {
    static func bytes(_ url: URL, max: Int) -> [UInt8]? {
        guard let source = try? BoundedFileSource<GitError>(url: url), source.size <= Int64(max) else { return nil }
        return try? source.read(at: 0, count: Int(source.size))
    }

    static func text(_ url: URL, max: Int) -> String? {
        bytes(url, max: max).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// zlib streams (RFC 1950) as git writes them: a two-byte header, raw deflate, an Adler-32 trailer. Apple's
/// `COMPRESSION_ZLIB` decodes the raw deflate part only, so the header is checked and skipped here and the trailer
/// is never needed (the declared object size says where the data ends). roadmap: S-9
enum GitZlib {
    /// Inflates the stream that starts at `offset` in `source` until `expected` bytes came out (an object's
    /// declared size) or the stream ended. Input is read in windows, so a pack of any size costs only what this
    /// object costs. Anything past `expected` is refused as malformed.
    static func inflate(_ source: any ByteSource, at offset: Int64, expected: Int) throws -> [UInt8] {
        guard expected >= 0 else { throw GitError.malformed("negative object size") }
        let head = try source.read(at: offset, count: 2)
        guard head.count == 2 else { throw GitError.truncated("the object ends before its zlib header") }
        let cmf = Int(head[0]), flg = Int(head[1])
        guard cmf & 0x0F == 8, (cmf << 8 | flg) % 31 == 0, flg & 0x20 == 0 else { throw GitError.malformed("not a zlib stream") }
        if expected == 0 { return [] }

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { throw GitError.unreadable("the system decompressor did not start") }
        defer { compression_stream_destroy(stream) }

        // One byte more than expected, so a stream that runs long is caught rather than cut silently.
        var out = [UInt8](repeating: 0, count: expected + 1)
        var produced = 0
        var position = offset + 2
        let window = max(4096, min(1 << 20, expected / 2 + 64))
        while true {
            let chunk = try source.read(at: position, count: window)
            guard !chunk.isEmpty else { throw GitError.truncated("the compressed object ends early") }
            let last = chunk.count < window
            var consumed = 0
            let status: compression_status = chunk.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    stream.pointee.src_ptr = src.baseAddress!
                    stream.pointee.src_size = src.count
                    stream.pointee.dst_ptr = dst.baseAddress! + produced
                    stream.pointee.dst_size = dst.count - produced
                    let s = compression_stream_process(stream, last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    produced = dst.count - stream.pointee.dst_size
                    consumed = src.count - stream.pointee.src_size
                    return s
                }
            }
            position += Int64(consumed)
            if status == COMPRESSION_STATUS_END { break }
            guard status == COMPRESSION_STATUS_OK else { throw GitError.malformed("the compressed object is corrupt") }
            if produced > expected { break }           // longer than declared: refused below
            if last { throw GitError.truncated("the compressed object ends early") }
        }
        guard produced == expected else {
            throw produced > expected ? GitError.malformed("the object is longer than it declares") : GitError.truncated("the object is shorter than it declares")
        }
        out.removeLast(out.count - expected)
        return out
    }

    /// Inflates a whole zlib stream held in memory, producing at most `limit` bytes; nil when it is corrupt or
    /// longer than `limit` (loose objects, whose size is only known after the header inflates).
    static func inflateAll(_ bytes: [UInt8], limit: Int) -> [UInt8]? {
        guard bytes.count >= 2 else { return nil }
        let cmf = Int(bytes[0]), flg = Int(bytes[1])
        guard cmf & 0x0F == 8, (cmf << 8 | flg) % 31 == 0, flg & 0x20 == 0 else { return nil }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        var out = [UInt8](repeating: 0, count: min(limit + 1, max(64, bytes.count * 4)))
        var produced = 0
        return bytes.withUnsafeBufferPointer { src -> [UInt8]? in
            stream.pointee.src_ptr = src.baseAddress! + 2
            stream.pointee.src_size = src.count - 2
            while true {
                if produced == out.count {
                    guard out.count <= limit else { return nil }
                    out.append(contentsOf: [UInt8](repeating: 0, count: min(out.count, limit + 1 - out.count)))
                }
                let status: compression_status = out.withUnsafeMutableBufferPointer { dst in
                    stream.pointee.dst_ptr = dst.baseAddress! + produced
                    stream.pointee.dst_size = dst.count - produced
                    let s = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    produced = dst.count - stream.pointee.dst_size
                    return s
                }
                if produced > limit { return nil }
                switch status {
                case COMPRESSION_STATUS_END:
                    out.removeLast(out.count - produced)
                    return out
                case COMPRESSION_STATUS_OK:
                    if stream.pointee.dst_size > 0 { return nil }   // input ran out before the stream ended
                default: return nil
                }
            }
        }
    }
}

/// Git's two variable-length integers.
enum GitVarint {
    /// Little-endian base-128 (object sizes in pack headers' continuation, delta headers).
    static func size(_ bytes: [UInt8], _ i: inout Int) throws -> Int {
        var value = 0, shift = 0
        while true {
            guard i < bytes.count else { throw GitError.truncated("a size ends early") }
            guard shift <= 56 else { throw GitError.malformed("a size is too long") }
            let b = bytes[i]; i += 1
            value |= Int(b & 0x7F) << shift
            shift += 7
            if b & 0x80 == 0 { return value }
        }
    }

    /// The big-endian "offset" encoding with +1 per continuation (OFS_DELTA distances, index v4 path prefixes),
    /// read from `bytes[i..<end]` (`end` defaults to the whole array). The value is never negative: one that would
    /// not fit in an Int is `GitError.malformed`, never wrapped by a shift that drops its high bits.
    static func offset(_ bytes: [UInt8], _ i: inout Int, end: Int? = nil) throws -> Int {
        let end = min(end ?? bytes.count, bytes.count)
        guard i < end else { throw GitError.truncated("an offset ends early") }
        var b = bytes[i]; i += 1
        var value = Int(b & 0x7F)
        var steps = 0
        while b & 0x80 != 0 {
            steps += 1
            guard steps < 9, i < end else { throw GitError.malformed("an offset is too long") }
            b = bytes[i]; i += 1
            let (next, nextOverflow) = value.addingReportingOverflow(1)
            let (shifted, shiftOverflow) = next.multipliedReportingOverflow(by: 128)
            guard !nextOverflow, !shiftOverflow else { throw GitError.malformed("an offset is too large") }
            value = shifted | Int(b & 0x7F)
        }
        return value
    }
}
