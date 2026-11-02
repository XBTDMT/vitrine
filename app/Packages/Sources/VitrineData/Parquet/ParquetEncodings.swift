import Foundation

/// Parquet's value and level encodings, from apache/parquet-format's `Encodings.md`: PLAIN, the RLE/bit-packed
/// hybrid (levels, dictionary indices, RLE booleans), the deprecated BIT_PACKED levels, DELTA_BINARY_PACKED,
/// DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY and BYTE_STREAM_SPLIT. Each decoder takes the count it must produce from
/// the page header and throws when the bytes cannot hold it; no count read from the data allocates by itself.
/// roadmap: S-21
struct ParquetBytes {
    let bytes: [UInt8]
    var position: Int
    let end: Int

    init(_ bytes: [UInt8], start: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        position = start
        self.end = min(end ?? bytes.count, bytes.count)
    }

    var remaining: Int { end - position }

    mutating func take(_ n: Int, _ what: @autoclosure () -> String) throws -> Range<Int> {
        guard n >= 0, n <= remaining else { throw ColumnarError.truncated(String(localized: "\(what()) runs past its page", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        defer { position += n }
        return position..<(position + n)
    }

    mutating func uleb() throws -> UInt64 {
        var value: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard position < end else { throw ColumnarError.truncated(String(localized: "a varint runs past its page", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let b = bytes[position]; position += 1
            value |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return value }
            shift += 7
            guard shift < 64 else { throw ColumnarError.malformed(String(localized: "a varint is too long", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        }
    }

    mutating func zigzag() throws -> Int64 {
        let v = try uleb()
        return Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
    }

    mutating func u32() throws -> UInt32 {
        let r = try take(4, String(localized: "a length", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
        return UInt32(bytes[r.lowerBound]) | UInt32(bytes[r.lowerBound + 1]) << 8 | UInt32(bytes[r.lowerBound + 2]) << 16 | UInt32(bytes[r.lowerBound + 3]) << 24
    }

    func le(_ at: Int, _ width: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<width { v |= UInt64(bytes[at + k]) << (8 * UInt64(k)) }
        return v
    }
}

enum ParquetDecode {
    /// Values bit-packed least significant bit first (the hybrid's bit-packed runs, DELTA_BINARY_PACKED miniblocks).
    static func unpack(_ bytes: [UInt8], at start: Int, count: Int, width: Int, into out: inout [UInt64]) {
        guard width > 0 else { out.append(contentsOf: repeatElement(0, count: count)); return }
        let mask: UInt64 = width == 64 ? .max : (1 << UInt64(width)) - 1
        var bit = 0
        for _ in 0..<count {
            var value: UInt64 = 0
            var got = 0
            while got < width {
                let byteIndex = start + (bit >> 3)
                let offset = bit & 7
                let take = min(8 - offset, width - got)
                let b = byteIndex < bytes.count ? UInt64(bytes[byteIndex]) : 0
                value |= ((b >> UInt64(offset)) & ((1 << UInt64(take)) - 1)) << UInt64(got)
                got += take
                bit += take
            }
            out.append(value & mask)
        }
    }

    /// The RLE/bit-packed hybrid: `count` values of `width` bits from `reader` (which must stop at the encoded
    /// data's end).
    static func hybrid(_ reader: inout ParquetBytes, width: Int, count: Int) throws -> [UInt64] {
        guard (0...32).contains(width) else { throw ColumnarError.malformed(String(localized: "a run-length bit width of \(width)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var out: [UInt64] = []
        out.reserveCapacity(count)
        let byteWidth = (width + 7) / 8
        while out.count < count {
            guard reader.remaining > 0 else { throw ColumnarError.truncated(String(localized: "run-length data ends before its \(count) values", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let header = try reader.uleb()
            if header & 1 == 0 {
                let run = Int(clamping: header >> 1)
                let r = try reader.take(byteWidth, String(localized: "a run-length value", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
                let value = byteWidth == 0 ? 0 : reader.le(r.lowerBound, byteWidth)
                out.append(contentsOf: repeatElement(value, count: min(run, count - out.count)))
            } else {
                let groups = Int(clamping: header >> 1)
                guard groups <= reader.remaining else { throw ColumnarError.truncated(String(localized: "a bit-packed run is longer than its page", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                let values = groups * 8
                let r = try reader.take(groups * width, String(localized: "a bit-packed run", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
                unpack(reader.bytes, at: r.lowerBound, count: min(values, count - out.count), width: width, into: &out)
            }
        }
        return out
    }

    /// Levels in the deprecated BIT_PACKED encoding: packed from the most significant bit, no length prefix.
    static func bitPackedLevels(_ reader: inout ParquetBytes, width: Int, count: Int) throws -> [UInt64] {
        guard width > 0 else { return Array(repeating: 0, count: count) }
        let r = try reader.take((count * width + 7) / 8, String(localized: "bit-packed levels", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
        var out: [UInt64] = []
        out.reserveCapacity(count)
        var bit = 0
        for _ in 0..<count {
            var v: UInt64 = 0
            for _ in 0..<width {
                let b = reader.bytes[r.lowerBound + bit >> 3]
                v = v << 1 | UInt64((b >> (7 - UInt8(bit & 7))) & 1)
                bit += 1
            }
            out.append(v)
        }
        return out
    }

    /// DELTA_BINARY_PACKED: the values it holds (all of them, up to `maxCount`), with wrapping arithmetic.
    static func deltaBinaryPacked(_ reader: inout ParquetBytes, maxCount: Int) throws -> [Int64] {
        let blockSize = try reader.uleb()
        let miniblocks = try reader.uleb()
        let total = try reader.uleb()
        var last = try reader.zigzag()
        guard blockSize > 0, blockSize % 128 == 0, blockSize <= 1 << 20, miniblocks > 0, blockSize % miniblocks == 0,
              (blockSize / miniblocks) % 32 == 0 else {
            throw ColumnarError.malformed(String(localized: "a DELTA_BINARY_PACKED header is invalid", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        guard total <= UInt64(maxCount) else { throw ColumnarError.malformed(String(localized: "DELTA_BINARY_PACKED claims \(total) values where \(maxCount) fit", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let count = Int(total)
        let perMini = Int(blockSize / miniblocks)
        var out: [Int64] = []
        out.reserveCapacity(count)
        if count == 0 { return out }
        out.append(last)
        var packed: [UInt64] = []
        while out.count < count {
            let minDelta = try reader.zigzag()
            let widths = try reader.take(Int(miniblocks), String(localized: "miniblock bit widths", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
            for m in 0..<Int(miniblocks) where out.count < count {
                let width = Int(reader.bytes[widths.lowerBound + m])
                guard width <= 64 else { throw ColumnarError.malformed(String(localized: "a miniblock bit width of \(width)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                let r = try reader.take(perMini * width / 8, String(localized: "a miniblock", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
                packed.removeAll(keepingCapacity: true)
                unpack(reader.bytes, at: r.lowerBound, count: perMini, width: width, into: &packed)
                for p in packed where out.count < count {
                    last = last &+ minDelta &+ Int64(bitPattern: p)
                    out.append(last)
                }
            }
        }
        return out
    }

    /// DELTA_LENGTH_BYTE_ARRAY: lengths as DELTA_BINARY_PACKED, then the bytes one after another.
    static func deltaLengthByteArray(_ reader: inout ParquetBytes, count: Int) throws -> [[UInt8]] {
        let lengths = try deltaBinaryPacked(&reader, maxCount: count)
        guard lengths.count >= count else { throw ColumnarError.truncated(String(localized: "DELTA_LENGTH_BYTE_ARRAY holds fewer lengths than values", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var out: [[UInt8]] = []
        out.reserveCapacity(count)
        for n in lengths.prefix(count) {
            guard n >= 0, n <= Int64(reader.remaining) else { throw ColumnarError.malformed(String(localized: "a byte array length runs past its page", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let r = try reader.take(Int(n), String(localized: "a byte array", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
            out.append(Array(reader.bytes[r]))
        }
        return out
    }

    /// DELTA_BYTE_ARRAY: prefix lengths, then suffixes as DELTA_LENGTH_BYTE_ARRAY; each value is the previous one's
    /// prefix plus its suffix.
    static func deltaByteArray(_ reader: inout ParquetBytes, count: Int, maxBytes: Int) throws -> [[UInt8]] {
        let prefixes = try deltaBinaryPacked(&reader, maxCount: count)
        let suffixes = try deltaLengthByteArray(&reader, count: count)
        guard prefixes.count >= count else { throw ColumnarError.truncated(String(localized: "DELTA_BYTE_ARRAY holds fewer prefixes than values", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var out: [[UInt8]] = []
        out.reserveCapacity(count)
        var previous: [UInt8] = []
        var total = 0
        for k in 0..<count {
            let p = prefixes[k]
            guard p >= 0, p <= Int64(previous.count) else { throw ColumnarError.malformed(String(localized: "a DELTA_BYTE_ARRAY prefix is longer than the value before it", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let value = Array(previous.prefix(Int(p))) + suffixes[k]
            total += value.count
            guard total <= maxBytes else { throw ColumnarError.tooLarge(String(localized: "DELTA_BYTE_ARRAY values exceed \(maxBytes) bytes", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            out.append(value)
            previous = value
        }
        return out
    }
}
