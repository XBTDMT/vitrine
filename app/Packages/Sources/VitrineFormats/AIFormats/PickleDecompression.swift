import Compression
import Foundation
import zlib

/// A compressed pickle, decompressed the way Python reads it. roadmap: S-16
///
/// The scan is only worth its verdict when it reads the bytes Python's loader would unpickle, so the followers here
/// mirror Python's own readers byte for byte instead of looking for a plausible stream: `gzip.GzipFile` (every member,
/// each header parsed field by field, zero padding between members), joblib's `BinaryZlibFile` (consecutive zlib
/// streams), joblib's pre-0.10 `ZF` header with one `zlib.decompress`, and one xz stream that must fill the file.
/// DEFLATE goes through the system zlib, the library Python itself uses, because it reports exactly where a stream
/// ends; Apple's Compression decoder reads ahead and swallows what follows (measured 2026-11-02: 34 KB of trailing
/// bytes vanished after a 22-byte stream), which is how a scanner and Python come to read different streams.
/// Whenever the bytes cannot be followed to their end exactly, `problem` says why and the card treats the file as
/// unsafe; it never reports a clean scan of a stream it could not follow.
struct PickleDecompression: Equatable {
    /// "gzip", "zlib" or "xz".
    var name: String
    /// The decompressed bytes, possibly only the part before `problem`.
    var bytes: [UInt8]
    /// Why the file could not be followed to its end exactly as Python reads it (technical, English); nil when it was.
    var problem: String?

    /// The compressions this reader opens, by the first bytes of the file (joblib picks its decompressor the same
    /// way: any file starting with `x` is zlib to it, any file starting with 1F 8B is gzip).
    static func supported(_ head: [UInt8]) -> String? {
        if head.starts(with: Array("ZF".utf8)) && head.count > 2 && head[2] == 0x30 { return "zlib" }   // joblib < 0.10
        if head.first == 0x78 { return "zlib" }
        if head.starts(with: [0x1F, 0x8B]) { return "gzip" }
        if head.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return "xz" }
        return nil
    }

    /// Decompresses `input`, the first bytes of a file of `fileSize` bytes, producing at most `limit` bytes.
    /// Nil when the file does not start with a compression this reader opens.
    static func decompress(_ input: [UInt8], fileSize: Int64, limit: Int) -> PickleDecompression? {
        guard let name = supported(Array(input.prefix(16))) else { return nil }
        let fileIsLonger = Int64(input.count) < fileSize
        var out: [UInt8] = []
        var problem: String?
        // Whether Python reads to the end of the file (true for all but the old ZF format, which ignores what follows
        // its one stream), so that a file longer than what was read cannot be called followed.
        var readsToTheEnd = true
        switch name {
        case "gzip": problem = followGzip(input, into: &out, limit: limit)
        case "xz": problem = followXZ(input, into: &out, limit: limit)
        default:
            if input.starts(with: Array("ZF".utf8)) {
                problem = followOldJoblib(input, into: &out, limit: limit)
                readsToTheEnd = false
            } else {
                problem = followZlibStreams(input, into: &out, limit: limit)
            }
        }
        if fileIsLonger, readsToTheEnd || problem != nil {
            let note = "only the first \(input.count) of \(fileSize) bytes of the file were read"
            problem = problem.map { "\($0); \(note)" } ?? note
        }
        return PickleDecompression(name: name, bytes: out, problem: problem)
    }

    static let inputEnded = "the compressed data ends before its end-of-stream marker"

    // MARK: gzip (Python's gzip.GzipFile)

    /// Every member in turn, as `gzip._GzipReader` reads them: the fixed 10-byte header (method must be 8, the
    /// reserved flag bits are ignored), then FEXTRA (a 2-byte little-endian length and that many bytes), FNAME and
    /// FCOMMENT (zero-terminated), FHCRC (2 bytes, not checked by Python), the raw DEFLATE data, the 8-byte trailer,
    /// and any run of zero bytes. Anything else after a member makes Python raise, so it is reported, not skipped.
    static func followGzip(_ input: [UInt8], into out: inout [UInt8], limit: Int) -> String? {
        var pos = 0
        var members = 0
        while pos < input.count {
            let ordinal = members + 1
            guard input.count - pos >= 2, input[pos] == 0x1F, input[pos + 1] == 0x8B else {
                return "\(input.count - pos) bytes after gzip member \(members) are not another gzip member"
            }
            guard input.count - pos >= 10 else { return "gzip member \(ordinal) ends inside its header" }
            let method = input[pos + 2], flags = input[pos + 3]
            guard method == 8 else { return "gzip member \(ordinal) uses compression method \(method), not deflate" }
            var i = pos + 10
            if flags & 0x04 != 0 {                                   // FEXTRA
                guard input.count - i >= 2 else { return "gzip member \(ordinal) ends inside its extra field" }
                let xlen = Int(input[i]) | (Int(input[i + 1]) << 8)
                i += 2
                guard xlen <= input.count - i else { return "gzip member \(ordinal) ends inside its extra field" }
                i += xlen
            }
            for (flag, field) in [(UInt8(0x08), "file name"), (UInt8(0x10), "comment")] where flags & flag != 0 {   // FNAME, FCOMMENT
                guard let zero = input[i...].firstIndex(of: 0) else { return "gzip member \(ordinal) ends inside its \(field)" }
                i = zero + 1
            }
            if flags & 0x02 != 0 {                                   // FHCRC
                guard input.count - i >= 2 else { return "gzip member \(ordinal) ends inside its header checksum" }
                i += 2
            }
            switch inflate(input[i...], windowBits: -MAX_WBITS, into: &out, limit: limit) {
            case .ended(let consumed): i += consumed
            case .stopped(let why): return why
            }
            guard input.count - i >= 8 else { return "gzip member \(ordinal) ends before its 8-byte trailer" }
            i += 8
            members += 1
            while i < input.count, input[i] == 0 { i += 1 }
            pos = i
        }
        return members == 0 ? "the gzip data is empty" : nil
    }

    // MARK: zlib (joblib)

    /// joblib's BinaryZlibFile: one zlib stream after another until the data ends.
    static func followZlibStreams(_ input: [UInt8], into out: inout [UInt8], limit: Int) -> String? {
        var pos = 0
        repeat {
            switch inflate(input[pos...], windowBits: MAX_WBITS, into: &out, limit: limit) {
            case .ended(let consumed): pos += consumed
            case .stopped(let why): return pos == 0 ? why : "after zlib stream ends at byte \(pos): \(why)"
            }
        } while pos < input.count
        return nil
    }

    /// joblib before 0.10: "ZF", the decompressed length as a hex literal padded to 19 bytes, perhaps one more space,
    /// then a zlib stream that `zlib.decompress` reads to its end and past which it ignores everything.
    static func followOldJoblib(_ input: [UInt8], into out: inout [UInt8], limit: Int) -> String? {
        let headerLength = 21
        guard input.count > headerLength else { return "the joblib ZF header is cut short" }
        let field = String(decoding: input[2..<headerLength], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let digits = field.lowercased().hasPrefix("0x") ? String(field.dropFirst(2)) : field
        guard !digits.isEmpty, UInt64(digits, radix: 16) != nil else { return "the joblib ZF header's length is not a hex number" }
        let start = input[headerLength] == 0x20 ? headerLength + 1 : headerLength
        switch inflate(input[start...], windowBits: MAX_WBITS, into: &out, limit: limit) {
        case .ended: return nil
        case .stopped(let why): return why
        }
    }

    // MARK: DEFLATE through zlib

    enum InflateEnd: Equatable {
        /// The stream's end-of-stream marker (and, for zlib, its checksum) was reached after `consumed` input bytes.
        case ended(consumed: Int)
        /// The stream could not be followed to its end, and why.
        case stopped(String)
    }

    /// Inflates one stream from the start of `input`, appending to `out` but never past `limit` bytes in all.
    /// `windowBits` is -15 for raw DEFLATE (gzip members) and 15 for a zlib stream with its header and Adler-32.
    static func inflate(_ input: ArraySlice<UInt8>, windowBits: Int32, into out: inout [UInt8], limit: Int) -> InflateEnd {
        guard !input.isEmpty else { return .stopped(inputEnded) }
        guard input.count <= Int(UInt32.max) else { return .stopped("the compressed data is too large to follow") }
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return .stopped("zlib did not start")
        }
        defer { inflateEnd(&stream) }
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        return input.withUnsafeBufferPointer { src -> InflateEnd in
            guard let base = src.baseAddress else { return .stopped(inputEnded) }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(src.count)
            while true {
                // One byte more room than the cap allows, so reaching the cap and passing it can be told apart.
                let room = min(chunk, limit - out.count + 1)
                let (status, produced) = buffer.withUnsafeMutableBufferPointer { dst -> (Int32, Int) in
                    stream.next_out = dst.baseAddress
                    stream.avail_out = uInt(room)
                    let status = zlib.inflate(&stream, Z_NO_FLUSH)
                    return (status, room - Int(stream.avail_out))
                }
                let allowed = min(produced, limit - out.count)
                out.append(contentsOf: buffer[0..<allowed])
                if produced > allowed { return .stopped("the decompressed data passes the \(limit)-byte reading cap") }
                switch status {
                case Z_STREAM_END: return .ended(consumed: src.count - Int(stream.avail_in))
                case Z_OK: continue
                case Z_BUF_ERROR: return .stopped(inputEnded)
                case Z_NEED_DICT: return .stopped("the zlib stream needs a preset dictionary")
                default:
                    let message = stream.msg.map { String(cString: $0) } ?? "zlib error \(status)"
                    return .stopped("the compressed data is damaged (\(message))")
                }
            }
        }
    }

    // MARK: xz

    /// One xz stream that fills the file exactly, decoded with the system LZMA decoder. That decoder reads ahead and
    /// cannot say where the stream ends, so the stream's own index proves it instead: the footer at the end of the
    /// file names an index whose block sizes put the stream's header at byte 0, and whose uncompressed sizes add up
    /// to what was decoded. A second stream, stream padding or trailing bytes fail that proof and are reported.
    static func followXZ(_ input: [UInt8], into out: inout [UInt8], limit: Int) -> String? {
        let decoded = lzmaDecode(input, into: &out, limit: limit)
        if let why = decoded { return why }
        return xzSingleStreamProblem(input, decodedCount: out.count)
    }

    static func lzmaDecode(_ input: [UInt8], into out: inout [UInt8], limit: Int) -> String? {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            return "the system xz decoder did not start"
        }
        defer { compression_stream_destroy(stream) }
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        return input.withUnsafeBufferPointer { src -> String? in
            guard let base = src.baseAddress else { return inputEnded }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = src.count
            while true {
                let room = min(chunk, limit - out.count + 1)
                let status: compression_status = buffer.withUnsafeMutableBufferPointer { dst in
                    stream.pointee.dst_ptr = dst.baseAddress!
                    stream.pointee.dst_size = room
                    return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = room - stream.pointee.dst_size
                let allowed = min(produced, limit - out.count)
                out.append(contentsOf: buffer[0..<allowed])
                if produced > allowed { return "the decompressed data passes the \(limit)-byte reading cap" }
                if status == COMPRESSION_STATUS_END { return nil }
                if status == COMPRESSION_STATUS_ERROR { return "the xz data is damaged" }
                if produced == 0 && stream.pointee.src_size == 0 { return inputEnded }
            }
        }
    }

    /// Nil when `input` is exactly one xz stream whose index accounts for `decodedCount` uncompressed bytes.
    static func xzSingleStreamProblem(_ input: [UInt8], decodedCount: Int) -> String? {
        let notOne = "the xz data is not exactly one stream filling the file"
        let n = input.count
        guard n >= 32, input[(n - 2)...].elementsEqual(Array("YZ".utf8)) else { return notOne }
        // The footer: CRC32, backward size, stream flags (must equal the header's), "YZ".
        guard input[n - 4] == input[6], input[n - 3] == input[7] else { return notOne }
        let stored = Int(input[n - 8]) | Int(input[n - 7]) << 8 | Int(input[n - 6]) << 16 | Int(input[n - 5]) << 24
        let indexSize = (stored + 1) * 4
        guard indexSize <= n - 24 else { return notOne }
        let indexStart = n - 12 - indexSize
        guard input[indexStart] == 0 else { return notOne }
        var p = indexStart + 1
        let recordsEnd = n - 12 - 4                                 // the index's own CRC32
        func varint() -> Int? {
            // Eight bytes at most (56 bits): far past any real size, and the value can never reach the sign bit.
            var value = 0
            for shift in stride(from: 0, to: 56, by: 7) {
                guard p < recordsEnd else { return nil }
                let byte = input[p]; p += 1
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return byte == 0 && shift > 0 ? nil : value }
            }
            return nil
        }
        guard let records = varint(), records <= (recordsEnd - p) / 2 else { return notOne }
        var blocks = 0, uncompressed = 0
        for _ in 0..<records {
            guard let unpadded = varint(), let size = varint(), unpadded > 0 else { return notOne }
            let padded = (unpadded + 3) & ~3
            let (b, o1) = blocks.addingReportingOverflow(padded)
            let (u, o2) = uncompressed.addingReportingOverflow(size)
            guard !o1, !o2 else { return notOne }
            blocks = b; uncompressed = u
        }
        guard input[p..<recordsEnd].allSatisfy({ $0 == 0 }), (recordsEnd - indexStart) % 4 == 0 else { return notOne }
        guard blocks == indexStart - 12, uncompressed == decodedCount else { return notOne }
        return nil
    }
}
