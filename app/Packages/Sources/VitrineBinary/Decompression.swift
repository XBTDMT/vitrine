import Compression
import Foundation

/// Bounded decompression with Apple's Compression framework, whose `COMPRESSION_ZLIB` is raw deflate (RFC 1951):
/// the zlib (RFC 1950) and gzip (RFC 1952) wrappers are taken off here. Output never exceeds `limit`; a stream that
/// would produce more is reported as cut short, never decoded past the cap (a decompression bomb costs the cap).
enum Decompression {
    struct Output {
        var bytes: [UInt8]
        /// The stream ended inside the limit; false when the output was cut at `limit` or the input ran out.
        var complete: Bool
    }

    /// Inflates a zlib stream (xar's table of contents and its `application/x-gzip` members).
    static func zlib(_ input: [UInt8], limit: Int) throws -> Output {
        guard input.count >= 2 else { throw BinaryError.truncated("the compressed data is empty") }
        let cmf = input[0], flg = input[1]
        guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else {
            throw BinaryError.malformed("the data is not a zlib stream")
        }
        guard flg & 0x20 == 0 else { throw BinaryError.unsupported("a zlib stream with a preset dictionary") }
        return try rawDeflate(input[2...], limit: limit)
    }

    /// Inflates a gzip member (a package's Scripts and Payload archives).
    static func gzip(_ input: [UInt8], limit: Int) throws -> Output {
        guard input.count >= 18, input[0] == 0x1F, input[1] == 0x8B else {
            throw BinaryError.notRecognized("gzip data")
        }
        guard input[2] == 8 else { throw BinaryError.unsupported("gzip compression method \(input[2])") }
        let flags = input[3]
        var i = 10
        if flags & 0x04 != 0 {                                      // FEXTRA
            guard i + 2 <= input.count else { throw BinaryError.truncated("the gzip header ends early") }
            i += 2 + (Int(input[i]) | Int(input[i + 1]) << 8)
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {     // FNAME, FCOMMENT
            while i < input.count, input[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }                             // FHCRC
        guard i < input.count else { throw BinaryError.truncated("the gzip header ends early") }
        return try rawDeflate(input[i...], limit: limit)
    }

    static func rawDeflate(_ input: ArraySlice<UInt8>, limit: Int) throws -> Output {
        guard limit > 0 else { return Output(bytes: [], complete: false) }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw BinaryError.unreadable("the system decompressor did not start")
        }
        defer { compression_stream_destroy(stream) }

        var output: [UInt8] = []
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        return try input.withUnsafeBufferPointer { src -> Output in
            guard let srcBase = src.baseAddress else { return Output(bytes: [], complete: false) }
            stream.pointee.src_ptr = srcBase
            stream.pointee.src_size = src.count
            var lastRemaining = -1
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { dst -> compression_status in
                    guard let dstBase = dst.baseAddress else { return COMPRESSION_STATUS_ERROR }
                    stream.pointee.dst_ptr = dstBase
                    stream.pointee.dst_size = dst.count
                    return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = chunk - stream.pointee.dst_size
                let room = limit - output.count
                output.append(contentsOf: buffer.prefix(min(produced, room)))
                if produced > room { return Output(bytes: output, complete: false) }
                switch status {
                case COMPRESSION_STATUS_END:
                    return Output(bytes: output, complete: true)
                case COMPRESSION_STATUS_OK:
                    if output.count >= limit, stream.pointee.src_size > 0 || produced == chunk {
                        return Output(bytes: output, complete: false)
                    }
                    // No progress at all: the input ended inside the stream (or the decoder is stuck). Stop.
                    if produced == 0, stream.pointee.src_size == 0 || stream.pointee.src_size == lastRemaining {
                        return Output(bytes: output, complete: false)
                    }
                    lastRemaining = stream.pointee.src_size
                default:
                    throw BinaryError.malformed("the compressed data is corrupt")
                }
            }
        }
    }
}
