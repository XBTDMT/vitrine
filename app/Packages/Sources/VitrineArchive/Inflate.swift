import Compression
import Foundation

/// Raw deflate (RFC 1951) decoding with Apple's Compression framework, whose `COMPRESSION_ZLIB` is raw deflate with
/// no zlib or gzip wrapper. Callers strip the gzip header themselves and read the trailer from the file.
final class RawInflater {
    private let stream: UnsafeMutablePointer<compression_stream>
    private var live = false

    init() throws {
        stream = .allocate(capacity: 1)
        try reset()
    }

    deinit {
        if live { compression_stream_destroy(stream) }
        stream.deallocate()
    }

    /// Starts a fresh deflate stream (the next gzip member).
    func reset() throws {
        if live { compression_stream_destroy(stream) }
        live = false
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { throw ArchiveError.unreadable("the system decompressor did not start") }
        live = true
    }

    struct Step { var consumed: Int; var produced: Int; var finished: Bool }

    /// Decodes from `input` into `output`; `finished` when the deflate stream's final block has ended (input past
    /// that point is left unconsumed: it is the gzip trailer and perhaps another member).
    func step(input: UnsafeBufferPointer<UInt8>, output: UnsafeMutableBufferPointer<UInt8>, last: Bool) throws -> Step {
        guard let inBase = input.baseAddress, let outBase = output.baseAddress
        else { return Step(consumed: 0, produced: 0, finished: false) }
        stream.pointee.src_ptr = inBase
        stream.pointee.src_size = input.count
        stream.pointee.dst_ptr = outBase
        stream.pointee.dst_size = output.count
        let flags = last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        let status = compression_stream_process(stream, flags)
        let consumed = input.count - stream.pointee.src_size
        let produced = output.count - stream.pointee.dst_size
        switch status {
        case COMPRESSION_STATUS_OK: return Step(consumed: consumed, produced: produced, finished: false)
        case COMPRESSION_STATUS_END: return Step(consumed: consumed, produced: produced, finished: true)
        default: throw ArchiveError.malformed("the compressed data is corrupt")
        }
    }

    /// Inflates a small, complete raw deflate buffer (a zip symlink target), producing at most `limit` bytes.
    static func inflate(_ bytes: [UInt8], limit: Int) -> [UInt8]? {
        guard !bytes.isEmpty, limit > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: limit)
        let n = out.withUnsafeMutableBufferPointer { dst in
            bytes.withUnsafeBufferPointer { src -> Int in
                guard let d = dst.baseAddress, let s = src.baseAddress else { return 0 }
                return compression_decode_buffer(d, limit, s, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        out.removeSubrange(n...)
        return out
    }
}

/// A forward-only byte stream the tar walker reads: plain tar bytes from a file, or a gzip stream being inflated.
/// `skip` is the point: over a file it costs nothing, over gzip it inflates and discards.
protocol ForwardReader: AnyObject {
    /// Offset of the next byte in the (decompressed) stream.
    var position: Int64 { get }
    /// Up to `count` bytes; fewer only at the end of the stream or when a cap stops it (`stoppedByCap`).
    func read(_ count: Int) throws -> [UInt8]
    /// Advances by up to `count` bytes, returning how many were actually passed.
    func skip(_ count: Int64) throws -> Int64
    /// The stream stopped because a limit was reached, not because the data ended.
    var stoppedByCap: Bool { get }
    /// Whether any byte exists past the current position, and whether it is all zero (padding), for trailing-data
    /// reports. Over gzip this only looks at what is already decompressed.
    func trailingBytes() throws -> (count: Int64, allZero: Bool)
}

/// Tar bytes in a file: skipping is arithmetic, reads go through a cached window.
final class FileForwardReader: ForwardReader {
    private let reader: WindowedReader
    private(set) var position: Int64

    init(_ reader: WindowedReader, start: Int64 = 0) { self.reader = reader; self.position = start }

    var stoppedByCap: Bool { false }

    func read(_ count: Int) throws -> [UInt8] {
        let bytes = try reader.bytes(at: position, count: count)
        position += Int64(bytes.count)
        return bytes
    }

    func skip(_ count: Int64) throws -> Int64 {
        let n = max(0, min(count, reader.size - position))
        position += n
        return n
    }

    func trailingBytes() throws -> (count: Int64, allZero: Bool) {
        let count = max(0, reader.size - position)
        guard count > 0 else { return (0, true) }
        // Look at a bounded sample: zero padding to a record size is normal, anything else is reported.
        let sample = try reader.bytes(at: position, count: Int(min(count, 64 * 1024)))
        return (count, sample.allSatisfy { $0 == 0 })
    }
}

/// The decompressed bytes of a gzip file (all its members, in order), produced on demand and never all at once.
final class GzipForwardReader: ForwardReader {
    private let source: any ArchiveByteSource
    private let inflater: RawInflater
    private let cap: Int64
    private let inCapacity = 64 * 1024
    private let outCapacity = 256 * 1024
    private let inBuffer: UnsafeMutablePointer<UInt8>
    private let outBuffer: UnsafeMutablePointer<UInt8>
    /// Compressed bytes held in `inBuffer[inStart..<inEnd]`, which begin at file offset `inFileOffset + inStart`.
    private var inStart = 0, inEnd = 0
    private var inFileOffset: Int64
    /// Decompressed bytes not yet handed out: `outBuffer[outStart..<outEnd]`.
    private var outStart = 0, outEnd = 0
    private var produced: Int64 = 0
    /// Decompressed bytes of the current member, matched against its ISIZE trailer to find the member boundary.
    private var memberProduced: Int64 = 0
    /// Where the current member's deflate data starts; the boundary search never looks before it.
    private var memberDataStart: Int64
    /// How far before the reported end the real one can lie. The decoder's read-ahead measured a few KB; the bound
    /// leaves two orders of magnitude of room and costs one read of at most this much per member.
    static let readAheadBound: Int64 = 1024 * 1024
    private var ended = false
    private(set) var position: Int64 = 0
    private(set) var stoppedByCap = false
    private(set) var memberCount = 1
    /// Bytes after the last gzip member that were not another member.
    private(set) var trailingCompressedBytes: Int64 = 0

    /// `start` is where the first member's deflate data begins (after its header).
    init(source: any ArchiveByteSource, start: Int64, cap: Int64) throws {
        self.source = source
        self.inflater = try RawInflater()
        self.cap = cap
        self.inFileOffset = start
        self.memberDataStart = start
        inBuffer = .allocate(capacity: inCapacity)
        outBuffer = .allocate(capacity: outCapacity)
    }

    deinit {
        inBuffer.deallocate()
        outBuffer.deallocate()
    }

    /// Decompressed bytes produced so far (the examined amount).
    var bytesProduced: Int64 { produced }

    func read(_ count: Int) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(count)
        while result.count < count {
            if outStart == outEnd { guard try fill() else { break } }
            let n = min(count - result.count, outEnd - outStart)
            result.append(contentsOf: UnsafeBufferPointer(start: outBuffer + outStart, count: n))
            outStart += n
        }
        position += Int64(result.count)
        return result
    }

    func skip(_ count: Int64) throws -> Int64 {
        var left = count
        while left > 0 {
            if outStart == outEnd { guard try fill() else { break } }
            let n = Int(min(left, Int64(outEnd - outStart)))
            outStart += n
            left -= Int64(n)
        }
        position += count - left
        return count - left
    }

    func trailingBytes() throws -> (count: Int64, allZero: Bool) {
        let pending = Array(UnsafeBufferPointer(start: outBuffer + outStart, count: outEnd - outStart))
        return (Int64(pending.count), pending.allSatisfy { $0 == 0 })
    }

    /// Decodes the next chunk into `outBuffer`; false at the end of the data or when the cap is reached.
    private func fill() throws -> Bool {
        outStart = 0; outEnd = 0
        var stalled = false
        while outEnd == 0 {
            if ended { return false }
            if produced >= cap { stoppedByCap = true; return false }
            if inStart == inEnd || stalled { try refill() }
            let atEOF = inFileOffset + Int64(inEnd) >= source.size
            let room = Int(min(Int64(outCapacity), cap - produced))
            let step = try inflater.step(
                input: UnsafeBufferPointer(start: inBuffer + inStart, count: inEnd - inStart),
                output: UnsafeMutableBufferPointer(start: outBuffer, count: room), last: atEOF)
            inStart += step.consumed
            outEnd = step.produced
            produced += Int64(step.produced)
            memberProduced += Int64(step.produced)
            if step.finished {
                try startNextMember()
                stalled = false
            } else if step.consumed == 0 && step.produced == 0 {
                // No progress: the decoder wants more input than is buffered, or the data simply stops.
                if atEOF { throw ArchiveError.truncated("the compressed data ends before its last block") }
                if inEnd - inStart >= inCapacity { throw ArchiveError.malformed("the compressed data does not decode") }
                stalled = true
            } else {
                stalled = false
            }
        }
        return true
    }

    /// Keeps the unconsumed input, moves it to the front of the buffer and reads more after it.
    private func refill() throws {
        let kept = inEnd - inStart
        if kept > 0, inStart > 0 { inBuffer.update(from: inBuffer + inStart, count: kept) }
        inFileOffset += Int64(inStart)
        inStart = 0
        inEnd = kept
        let bytes = try source.read(at: inFileOffset + Int64(kept), count: inCapacity - kept)
        bytes.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { (inBuffer + kept).update(from: base, count: src.count) }
        }
        inEnd = kept + bytes.count
    }

    /// After a member's final block: find its 8-byte trailer, and carry on into a following member if one is there.
    ///
    /// The system decoder reads ahead: it reports input as consumed before it has decoded it, and reports the end of
    /// the deflate stream after swallowing whatever followed in the same feed (measured 2026-10-29: the trailer and
    /// all 5,000 bytes after it vanished from one 64 KB feed, and END can arrive on a later call given no input at
    /// all). So the boundary is not where it says. It lies
    /// before the reported position, within the decoder's read-ahead: the trailer is the first position there whose
    /// ISIZE matches the bytes this member produced and that is followed by another member or the end of the file
    /// (else the first ISIZE match, with whatever follows reported as trailing data).
    private func startNextMember() throws {
        let consumedEnd = inFileOffset + Int64(inStart)
        let expected = UInt32(truncatingIfNeeded: memberProduced)
        let low = max(memberDataStart, consumedEnd - Self.readAheadBound)
        let high = min(consumedEnd, source.size - 8)
        var trailerAt: Int64?
        var fallback: Int64?
        if high >= low {
            let window = try source.read(at: low, count: Int(high - low) + 8 + 2)
            var i = 0
            while Int64(i) <= high - low {
                defer { i += 1 }
                guard window.le32(at: i + 4) == expected else { continue }
                let next = low + Int64(i) + 8
                if next >= source.size || (window.count >= i + 10 && window[i + 8] == 0x1F && window[i + 9] == 0x8B) {
                    trailerAt = low + Int64(i)
                    break
                }
                if fallback == nil { fallback = low + Int64(i) }
            }
        }
        guard let found = trailerAt ?? fallback else {
            // No trailer matches: the data ends without one, or the ISIZE is wrong. Nothing more can be decoded.
            ended = true
            return
        }
        let next = found + 8
        guard next < source.size else { ended = true; return }
        guard trailerAt != nil else {
            let rest = source.size - next
            let sample = try source.read(at: next, count: Int(min(rest, 64 * 1024)))
            if !sample.allSatisfy({ $0 == 0 }) { trailingCompressedBytes = rest }
            ended = true
            return
        }
        let header = try GzipReader.parseHeader(WindowedReader(source, windowSize: 4096), at: next)
        memberCount += 1
        memberProduced = 0
        try inflater.reset()
        inFileOffset = next + Int64(header.headerLength)
        memberDataStart = inFileOffset
        inStart = 0
        inEnd = 0
    }
}
