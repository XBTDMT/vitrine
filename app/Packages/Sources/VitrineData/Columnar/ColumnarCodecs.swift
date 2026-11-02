import Compression
import CLZ4
import CZstd
import Foundation

/// The block decompressors the column readers need, each bounded by the size the file declares for the result (and
/// that size by `ColumnarLimits.maxPageBytes`): Snappy and LZ4 blocks are decoded here in Swift; GZIP goes through
/// the system's Compression framework (raw DEFLATE, after the gzip header is read here); Zstandard and LZ4 frames
/// through the vendored CZstd and CLZ4 (G-15). A result that is not exactly the declared size is an error, never a
/// short or padded value. roadmap: S-21
enum ColumnarCodecs {
    enum Codec: Sendable, Equatable {
        case snappy, gzip, zstd, lz4Raw, lz4Hadoop, lz4Frame
    }

    static func decompress(_ input: ArraySlice<UInt8>, codec: Codec, expected: Int) throws -> [UInt8] {
        guard expected >= 0 else { throw ColumnarError.malformed(String(localized: "a negative uncompressed size", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        if expected == 0 { return [] }
        switch codec {
        case .snappy: return try snappy(input, expected: expected)
        case .gzip: return try gzip(input, expected: expected)
        case .zstd: return try zstd(input, expected: expected)
        case .lz4Raw: return try lz4Block(input, expected: expected)
        case .lz4Hadoop: return try lz4Hadoop(input, expected: expected)
        case .lz4Frame: return try lz4Frame(input, expected: expected)
        }
    }

    // MARK: Snappy (format_description.txt in google/snappy: a varint length, then literals and back-references)

    static func snappy(_ input: ArraySlice<UInt8>, expected: Int) throws -> [UInt8] {
        var i = input.startIndex
        let end = input.endIndex
        var length = 0, shift = 0
        while true {
            guard i < end, shift <= 28 else { throw ColumnarError.malformed(String(localized: "a Snappy block's length is unreadable", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let b = input[i]; i += 1
            length |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        guard length == expected else { throw ColumnarError.malformed(String(localized: "a Snappy block says \(length) bytes where \(expected) were declared", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var out = [UInt8]()
        out.reserveCapacity(length)
        func little(_ n: Int) throws -> Int {
            guard end - i >= n else { throw ColumnarError.truncated(String(localized: "a Snappy block ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            var v = 0
            for k in 0..<n { v |= Int(input[i + k]) << (8 * k) }
            i += n
            return v
        }
        while i < end {
            let tag = input[i]; i += 1
            switch tag & 3 {
            case 0:
                var len = Int(tag >> 2)
                if len >= 60 { len = try little(len - 59) }
                len += 1
                guard end - i >= len, out.count + len <= length else { throw ColumnarError.malformed(String(localized: "a Snappy literal runs past its block", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                out.append(contentsOf: input[i..<(i + len)])
                i += len
            default:
                let len: Int, offset: Int
                switch tag & 3 {
                case 1: len = 4 + Int((tag >> 2) & 7); offset = (Int(tag >> 5) << 8) | (try little(1))
                case 2: len = 1 + Int(tag >> 2); offset = try little(2)
                default: len = 1 + Int(tag >> 2); offset = try little(4)
                }
                guard offset > 0, offset <= out.count, out.count + len <= length else {
                    throw ColumnarError.malformed(String(localized: "a Snappy copy points outside its block", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                }
                let start = out.count - offset
                for k in 0..<len { out.append(out[start + k]) }
            }
        }
        guard out.count == length else { throw ColumnarError.truncated(String(localized: "a Snappy block ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return out
    }

    // MARK: LZ4 block (lz4_Block_format.md: sequences of literals and matches)

    static func lz4Block(_ input: ArraySlice<UInt8>, expected: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(expected)
        try lz4Block(input, into: &out, limit: expected)
        guard out.count == expected else { throw ColumnarError.malformed(String(localized: "an LZ4 block holds \(out.count) bytes where \(expected) were declared", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return out
    }

    /// Appends one block's output to `out` (earlier output stays reachable by matches, as in a linked frame).
    static func lz4Block(_ input: ArraySlice<UInt8>, into out: inout [UInt8], limit: Int) throws {
        var i = input.startIndex
        let end = input.endIndex
        func extended(_ base: Int) throws -> Int {
            var n = base
            guard base == 15 else { return n }
            while true {
                guard i < end else { throw ColumnarError.truncated(String(localized: "an LZ4 block ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                let b = input[i]; i += 1
                n += Int(b)
                guard n <= limit + 15 else { throw ColumnarError.malformed(String(localized: "an LZ4 length runs past the block", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                if b != 255 { return n }
            }
        }
        while i < end {
            let token = input[i]; i += 1
            let literals = try extended(Int(token >> 4))
            guard end - i >= literals, out.count + literals <= limit else { throw ColumnarError.malformed(String(localized: "an LZ4 literal runs past its block", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            out.append(contentsOf: input[i..<(i + literals)])
            i += literals
            if i == end { break }        // the last sequence has literals only
            guard end - i >= 2 else { throw ColumnarError.truncated(String(localized: "an LZ4 block ends inside a match", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let offset = Int(input[i]) | Int(input[i + 1]) << 8
            i += 2
            let length = try extended(Int(token & 15)) + 4
            guard offset > 0, offset <= out.count, out.count + length <= limit else {
                throw ColumnarError.malformed(String(localized: "an LZ4 match points outside its block", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
            }
            let start = out.count - offset
            for k in 0..<length { out.append(out[start + k]) }
        }
    }

    /// Parquet's deprecated LZ4 codec: Hadoop's framing (big-endian uncompressed and compressed sizes before each
    /// block) when the sizes fit, else one raw block, as other readers fall back.
    static func lz4Hadoop(_ input: ArraySlice<UInt8>, expected: Int) throws -> [UInt8] {
        var out = [UInt8]()
        var i = input.startIndex
        var framed = true
        while i < input.endIndex {
            guard input.endIndex - i >= 8 else { framed = false; break }
            func be(_ at: Int) -> Int { Int(input[at]) << 24 | Int(input[at + 1]) << 16 | Int(input[at + 2]) << 8 | Int(input[at + 3]) }
            let raw = be(i), packed = be(i + 4)
            guard packed <= input.endIndex - i - 8, out.count + raw <= expected else { framed = false; break }
            var block = [UInt8]()
            do { try lz4Block(input[(i + 8)..<(i + 8 + packed)], into: &block, limit: raw) } catch { framed = false; break }
            guard block.count == raw else { framed = false; break }
            out += block
            i += 8 + packed
        }
        if framed, out.count == expected { return out }
        return try lz4Block(input, expected: expected)
    }

    // MARK: GZIP (RFC 1952 header and trailer around raw DEFLATE, RFC 1951)

    static func gzip(_ input: ArraySlice<UInt8>, expected: Int) throws -> [UInt8] {
        var out = [UInt8]()
        var i = input.startIndex
        // A page may hold several concatenated members.
        while i < input.endIndex, out.count < expected {
            let start = try gzipBodyStart(input, at: i)
            let member = try inflate(input[start...], limit: expected - out.count)
            out += member.bytes
            i = start + member.consumed + 8           // CRC32 and ISIZE
            if member.consumed == 0 { break }
        }
        guard out.count == expected else { throw ColumnarError.malformed(String(localized: "a GZIP page holds \(out.count) bytes where \(expected) were declared", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return out
    }

    static func gzipBodyStart(_ b: ArraySlice<UInt8>, at start: Int) throws -> Int {
        guard b.endIndex - start >= 2 else { throw ColumnarError.truncated(String(localized: "a GZIP header ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        if b[start] == 0x78, (Int(b[start]) << 8 | Int(b[start + 1])) % 31 == 0 { return start + 2 }   // a zlib header
        guard b.endIndex - start >= 10, b[start] == 0x1F, b[start + 1] == 0x8B, b[start + 2] == 8 else {
            throw ColumnarError.malformed(String(localized: "a GZIP page does not start with a gzip header", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        let flags = b[start + 3]
        var i = start + 10
        if flags & 4 != 0 {
            guard b.endIndex - i >= 2 else { throw ColumnarError.truncated(String(localized: "a GZIP header ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8)
        }
        for bit: UInt8 in [8, 16] where flags & bit != 0 {
            while i < b.endIndex, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 2 != 0 { i += 2 }
        guard i <= b.endIndex else { throw ColumnarError.truncated(String(localized: "a GZIP header ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return i
    }

    /// Raw DEFLATE with the stream API, so the bytes the stream used are known (the next member follows them).
    static func inflate(_ input: ArraySlice<UInt8>, limit: Int) throws -> (bytes: [UInt8], consumed: Int) {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ColumnarError.malformed(String(localized: "cannot start the DEFLATE decoder", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        defer { compression_stream_destroy(streamPointer) }
        var out = [UInt8](repeating: 0, count: limit + 1)
        let input = Array(input)
        return try input.withUnsafeBufferPointer { src in
            try out.withUnsafeMutableBufferPointer { dst in
                streamPointer.pointee.src_ptr = src.baseAddress ?? UnsafePointer(bitPattern: 1)!
                streamPointer.pointee.src_size = src.count
                streamPointer.pointee.dst_ptr = dst.baseAddress!
                streamPointer.pointee.dst_size = dst.count
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status == COMPRESSION_STATUS_END || status == COMPRESSION_STATUS_OK else {
                    throw ColumnarError.malformed(String(localized: "the DEFLATE data is damaged", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                }
                let produced = dst.count - streamPointer.pointee.dst_size
                guard produced <= limit else { throw ColumnarError.malformed(String(localized: "a GZIP page inflates past its declared size", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                guard status == COMPRESSION_STATUS_END else { throw ColumnarError.truncated(String(localized: "the DEFLATE data ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                return (Array(dst[0..<produced]), src.count - streamPointer.pointee.src_size)
            }
        }
    }

    // MARK: Zstandard (RFC 8878), through the vendored decoder

    static func zstd(_ input: ArraySlice<UInt8>, expected: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: expected)
        let input = Array(input)
        let written = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in ZSTD_decompress(dst.baseAddress, dst.count, src.baseAddress, src.count) }
        }
        if ZSTD_isError(written) != 0 {
            throw ColumnarError.malformed(String(localized: "the ZSTD data is damaged (\(String(cString: ZSTD_getErrorName(written))))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        guard written == expected else { throw ColumnarError.malformed(String(localized: "a ZSTD page holds \(written) bytes where \(expected) were declared", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return out
    }

    // MARK: LZ4 frame (lz4_Frame_format.md), through the vendored decoder

    static func lz4Frame(_ input: ArraySlice<UInt8>, expected: Int) throws -> [UInt8] {
        var context: OpaquePointer?
        guard LZ4F_isError(LZ4F_createDecompressionContext(&context, UInt32(LZ4F_VERSION))) == 0, let context else {
            throw ColumnarError.malformed(String(localized: "cannot start the LZ4 decoder", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        defer { LZ4F_freeDecompressionContext(context) }
        var out = [UInt8](repeating: 0, count: expected)
        let input = Array(input)
        var produced = 0, consumed = 0
        try out.withUnsafeMutableBytes { dst in
            try input.withUnsafeBytes { src in
                while consumed < src.count {
                    var dstSize = dst.count - produced
                    var srcSize = src.count - consumed
                    let hint = LZ4F_decompress(context, dst.baseAddress! + produced, &dstSize, src.baseAddress! + consumed, &srcSize, nil)
                    if LZ4F_isError(hint) != 0 {
                        throw ColumnarError.malformed(String(localized: "the LZ4 frame is damaged (\(String(cString: LZ4F_getErrorName(hint))))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                    }
                    produced += dstSize
                    consumed += srcSize
                    if hint == 0 { break }
                    if dstSize == 0, srcSize == 0 {
                        if produced == dst.count { throw ColumnarError.malformed(String(localized: "an LZ4 frame inflates past its declared size", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                        throw ColumnarError.truncated(String(localized: "the LZ4 frame ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                    }
                }
            }
        }
        guard produced == expected else { throw ColumnarError.malformed(String(localized: "an LZ4 frame holds \(produced) bytes where \(expected) were declared", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return out
    }
}
