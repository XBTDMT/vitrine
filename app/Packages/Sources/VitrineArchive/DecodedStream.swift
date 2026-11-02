import CLZ4
import CZstd
import Foundation

/// A Zstandard or LZ4-frame stream decoded in the process (G-15 correction): the system libarchive would start an
/// outside `zstd` or `lz4` program for these, which Vitrine never does, so libarchive is handed the decoded bytes
/// through its read callback and sees a plain tar, cpio or single file. Compressed input is read forward from the
/// source in 64 KB steps; nothing is written anywhere. Not shared across threads: one per listing or member read.
/// roadmap: S-8
final class DecodedStream {
    enum Codec: String { case zstd, lz4 }

    let codec: Codec
    private let source: any ArchiveByteSource
    private var inputOffset: Int64 = 0
    private var input: [UInt8] = []
    private var inputUsed = 0
    private var finished = false
    private var atFrameEnd = false
    private var zstd: OpaquePointer?
    private var lz4: OpaquePointer?

    static let inputStep = 64 * 1024

    /// The codec a stream starts with, when it is one this type decodes. The LZ4 legacy format (`02 21 4C 18`) is not.
    static func codec(forHead head: [UInt8]) -> Codec? {
        if head.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) { return .zstd }
        if head.starts(with: [0x04, 0x22, 0x4D, 0x18]) { return .lz4 }
        return nil
    }

    init(source: any ArchiveByteSource, codec: Codec) throws {
        self.source = source
        self.codec = codec
        switch codec {
        case .zstd:
            guard let ds = ZSTD_createDStream() else { throw ArchiveError.unreadable("the Zstandard decoder did not start") }
            zstd = ds
            // At most a 128 MB window (Zstandard's own default ceiling): a stream that asks for more is refused.
            _ = ZSTD_DCtx_setParameter(ds, ZSTD_d_windowLogMax, 27)
        case .lz4:
            var ctx: OpaquePointer?
            let code = LZ4F_createDecompressionContext(&ctx, UInt32(LZ4F_VERSION))
            guard LZ4F_isError(code) == 0, let ctx else { throw ArchiveError.unreadable("the LZ4 decoder did not start") }
            lz4 = ctx
        }
    }

    deinit {
        if let zstd { ZSTD_freeDStream(zstd) }
        if let lz4 { LZ4F_freeDecompressionContext(lz4) }
    }

    /// Up to `capacity` decoded bytes into `out`; 0 at the end of the stream. Throws on corrupt or cut input.
    func read(into out: UnsafeMutableRawPointer, capacity: Int) throws -> Int {
        while true {
            if inputUsed == input.count, !finished {
                input = try source.read(at: inputOffset, count: Self.inputStep)
                inputOffset += Int64(input.count)
                inputUsed = 0
                if input.isEmpty { finished = true }
            }
            let (used, made, done) = try step(out: out, capacity: capacity)
            inputUsed += used
            if used > 0 || made > 0 { atFrameEnd = done }
            if made > 0 { return made }
            if inputUsed == input.count, finished {
                // The input is spent: a stream that stopped between frames has ended, one inside a frame was cut.
                if atFrameEnd { return 0 }
                throw ArchiveError.truncated("the \(codec == .zstd ? "Zstandard" : "LZ4") stream ends early")
            }
            if used == 0, inputUsed < input.count { throw ArchiveError.malformed("the \(codec.rawValue) decoder made no progress") }
        }
    }

    /// One decoder call over the unread input: bytes consumed, bytes produced, whether a frame just ended.
    private func step(out: UnsafeMutableRawPointer, capacity: Int) throws -> (Int, Int, Bool) {
        try input.withUnsafeBytes { raw in
            let src = raw.baseAddress.map { $0 + inputUsed }
            let available = input.count - inputUsed
            switch codec {
            case .zstd:
                var inBuf = ZSTD_inBuffer(src: src, size: available, pos: 0)
                var outBuf = ZSTD_outBuffer(dst: out, size: capacity, pos: 0)
                let code = ZSTD_decompressStream(zstd, &outBuf, &inBuf)
                if ZSTD_isError(code) != 0 { throw ArchiveError.malformed("Zstandard: " + String(cString: ZSTD_getErrorName(code))) }
                return (inBuf.pos, outBuf.pos, code == 0)
            case .lz4:
                var srcSize = available
                var dstSize = capacity
                let code = LZ4F_decompress(lz4, out, &dstSize, src, &srcSize, nil)
                if LZ4F_isError(code) != 0 { throw ArchiveError.malformed("LZ4: " + String(cString: LZ4F_getErrorName(code))) }
                return (srcSize, dstSize, code == 0)
            }
        }
    }
}
