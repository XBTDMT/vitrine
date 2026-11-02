import Compression
import Foundation

// Writers for invented column files, used by the package tests and (compiled into it by project.yml) the app tests.
// Written from the format specifications, not from any implementation: Parquet's parquet.thrift and Encodings.md
// with Thrift's compact protocol; Arrow's Schema.fbs, Message.fbs and File.fbs with the FlatBuffers binary layout;
// ECMA-376 SpreadsheetML inside a stored zip (APPNOTE.TXT). Only Foundation and Compression, so both test targets
// build it. Every value is invented. roadmap: S-21

/// A value for a test column.
indirect enum TestValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case string(String)
    case bool(Bool)
    case bytes([UInt8])
    case list([TestValue])
}

enum TestBytes {
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func uleb(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat { var b = UInt8(v & 0x7F); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
        return out
    }
    static func zigzag(_ v: Int64) -> [UInt8] { uleb(UInt64(bitPattern: (v << 1) ^ (v >> 63))) }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

// MARK: Codecs for writing

enum TestCodecs {
    /// A valid Snappy block (google/snappy format_description.txt) with literals and 2-byte-offset copies found by a
    /// simple hash of 4-byte sequences.
    static func snappy(_ input: [UInt8]) -> [UInt8] {
        var out = TestBytes.uleb(UInt64(input.count))
        var table = [UInt32: Int]()
        var literalStart = 0
        var i = 0
        func literal(_ from: Int, _ to: Int) {
            var p = from
            while p < to {
                let n = min(to - p, 60)
                out.append(UInt8((n - 1) << 2))
                out.append(contentsOf: input[p..<(p + n)])
                p += n
            }
        }
        while i + 4 <= input.count {
            let key = UInt32(input[i]) | UInt32(input[i + 1]) << 8 | UInt32(input[i + 2]) << 16 | UInt32(input[i + 3]) << 24
            if let prev = table[key], i - prev < 65_536, i - prev > 0 {
                var length = 4
                while i + length < input.count, input[prev + length] == input[i + length], length < 64 { length += 1 }
                literal(literalStart, i)
                out.append(UInt8((length - 1) << 2 | 2))
                out += TestBytes.le16(UInt16(i - prev))
                table[key] = i
                i += length
                literalStart = i
            } else {
                table[key] = i
                i += 1
            }
        }
        literal(literalStart, input.count)
        return out
    }

    /// RFC 1952 gzip around raw DEFLATE from the Compression framework.
    static func gzip(_ input: [UInt8]) -> [UInt8] {
        var deflated = [UInt8](repeating: 0, count: input.count + 1_024)
        let n = input.withUnsafeBufferPointer { src in
            deflated.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress ?? UnsafePointer(bitPattern: 1)!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(n > 0 || input.isEmpty)
        return [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3] + deflated.prefix(n) + TestBytes.le32(TestBytes.crc32(input)) + TestBytes.le32(UInt32(input.count))
    }

    /// A Zstandard frame (RFC 8878) of raw blocks: no entropy coding, but a real frame the decoder must walk.
    static func zstdRawFrame(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = TestBytes.le32(0xFD2F_B528)
        out += [0xA0]   // single segment, 4-byte content size
        out += TestBytes.le32(UInt32(input.count))
        var p = 0
        repeat {
            let n = min(input.count - p, 100_000)
            let last: UInt32 = p + n == input.count ? 1 : 0
            let header = last | (0 << 1) | UInt32(n) << 3
            out += [UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF), UInt8((header >> 16) & 0xFF)]
            out += input[p..<(p + n)]
            p += n
        } while p < input.count
        return out
    }

    /// An LZ4 block (lz4_Block_format.md) with literals only.
    static func lz4Literals(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        let n = input.count
        if n < 15 { out.append(UInt8(n << 4)) } else {
            out.append(0xF0)
            var rest = n - 15
            while rest >= 255 { out.append(255); rest -= 255 }
            out.append(UInt8(rest))
        }
        return out + input
    }
}

// MARK: Thrift compact writer

struct TestThrift {
    var bytes: [UInt8] = []
    private var last: [Int16] = [0]

    mutating func header(_ id: Int16, _ type: UInt8) {
        let delta = id - last[last.count - 1]
        if delta > 0, delta <= 15 { bytes.append(UInt8(delta) << 4 | type) } else { bytes.append(type); bytes += TestBytes.zigzag(Int64(id)) }
        last[last.count - 1] = id
    }
    mutating func i32(_ id: Int16, _ v: Int32) { header(id, 5); bytes += TestBytes.zigzag(Int64(v)) }
    mutating func i64(_ id: Int16, _ v: Int64) { header(id, 6); bytes += TestBytes.zigzag(v) }
    mutating func byte(_ id: Int16, _ v: Int8) { header(id, 3); bytes.append(UInt8(bitPattern: v)) }
    mutating func bool(_ id: Int16, _ v: Bool) { header(id, v ? 1 : 2) }
    mutating func binary(_ id: Int16, _ v: [UInt8]) { header(id, 8); bytes += TestBytes.uleb(UInt64(v.count)) + v }
    mutating func string(_ id: Int16, _ v: String) { binary(id, Array(v.utf8)) }
    mutating func begin(_ id: Int16) { header(id, 12); last.append(0) }
    mutating func beginElement() { last.append(0) }
    mutating func end() { bytes.append(0); last.removeLast() }
    mutating func listHeader(_ id: Int16, type: UInt8, count: Int) {
        header(id, 9)
        if count < 15 { bytes.append(UInt8(count) << 4 | type) } else { bytes.append(0xF0 | type); bytes += TestBytes.uleb(UInt64(count)) }
    }
    mutating func i32List(_ id: Int16, _ values: [Int32]) {
        listHeader(id, type: 5, count: values.count)
        for v in values { bytes += TestBytes.zigzag(Int64(v)) }
    }
    mutating func stringList(_ id: Int16, _ values: [String]) {
        listHeader(id, type: 8, count: values.count)
        for v in values { bytes += TestBytes.uleb(UInt64(v.utf8.count)) + Array(v.utf8) }
    }
    /// An empty struct as a union member.
    mutating func emptyStruct(_ id: Int16) { begin(id); end() }
}

// MARK: Parquet writer

/// A column of an invented Parquet file.
struct TestParquetColumn {
    enum Physical: Int32 { case boolean = 0, int32 = 1, int64 = 2, int96 = 3, float = 4, double = 5, byteArray = 6, fixed = 7 }
    enum Logical { case string, date, timestamp(utc: Bool, unit: Int), decimal(precision: Int32, scale: Int32), integer(bits: Int8, signed: Bool), uuid }
    enum Encoding { case plain, dictionary, delta, deltaByteArray, byteStreamSplit, rle }

    var name: String
    var physical: Physical
    var typeLength: Int32 = 0
    var logical: Logical?
    var convertedType: Int32?
    var optional = true
    /// A legacy two-level list: `repeated <type> name` (values are `.list`).
    var repeated = false
    var encoding = Encoding.plain
    var values: [TestValue]
}

struct TestParquetOptions {
    var rowGroupRows = 1_000_000
    var pageRows = 1_000_000
    /// 0 none, 1 snappy, 2 gzip, 6 zstd (raw-block frames), 7 lz4 raw.
    var codec: Int32 = 0
    var pageVersion = 1
    var createdBy = "vitrine-test-writer 1.0"
    var keyValues: [(String, String)] = []
    /// Written as the deprecated min/max fields only (old writers).
    var legacyStatistics = false
}

enum TestParquet {
    static func file(_ columns: [TestParquetColumn], _ options: TestParquetOptions = TestParquetOptions()) -> [UInt8] {
        let rows = columns.first?.values.count ?? 0
        var out: [UInt8] = Array("PAR1".utf8)
        typealias Chunk = (dataOffset: Int64, dictionaryOffset: Int64?, size: Int64, raw: Int64, values: Int64, encodings: [Int32], stats: [UInt8]?)
        var groups: [(rows: Int, chunks: [Chunk])] = []
        var start = 0
        repeat {
            let end = min(rows, start + options.rowGroupRows)
            var chunks: [Chunk] = []
            for column in columns {
                let chunkStart = Int64(out.count)
                var dictionaryOffset: Int64?
                var raw: Int64 = 0
                var valueCount: Int64 = 0
                let slice = Array(column.values[start..<end])
                var dictionary: [TestValue] = []
                if column.encoding == .dictionary {
                    for v in slice.flatMap(flat) where !dictionary.contains(v) { dictionary.append(v) }
                    dictionaryOffset = Int64(out.count)
                    let payload = plain(dictionary, column)
                    let page = compress(payload, options.codec)
                    var h = TestThrift()
                    h.i32(1, 2); h.i32(2, Int32(payload.count)); h.i32(3, Int32(page.count))
                    h.begin(7); h.i32(1, Int32(dictionary.count)); h.i32(2, 0); h.end()
                    h.bytes.append(0)
                    out += h.bytes + page
                    raw += Int64(h.bytes.count + payload.count)
                }
                let dataOffset = Int64(out.count)
                var p = 0
                repeat {
                    let pageValues = Array(slice[p..<min(slice.count, p + options.pageRows)])
                    let (header, body, levelCount, rawSize) = dataPage(pageValues, column, dictionary: dictionary, options: options)
                    out += header + body
                    raw += Int64(rawSize)
                    valueCount += Int64(levelCount)
                    p += options.pageRows
                } while p < slice.count
                var encodings: [Int32] = [0, 3]
                switch column.encoding {
                case .dictionary: encodings = [0, 3, 8]
                case .delta: encodings = [3, column.physical == .byteArray ? 6 : 5]
                case .deltaByteArray: encodings = [3, 7]
                case .byteStreamSplit: encodings = [3, 9]
                default: break
                }
                chunks.append((dataOffset, dictionaryOffset, Int64(out.count) - chunkStart, raw, valueCount,
                               encodings, statistics(slice, column, legacy: options.legacyStatistics)))
            }
            groups.append((end - start, chunks))
            start = end
        } while start < rows
        // The footer.
        var t = TestThrift()
        t.i32(1, options.pageVersion == 2 ? 2 : 1)
        t.listHeader(2, type: 12, count: columns.count + 1)
        t.beginElement(); t.string(4, "schema"); t.i32(5, Int32(columns.count)); t.end()
        for c in columns {
            t.beginElement()
            t.i32(1, c.physical.rawValue)
            if c.physical == .fixed { t.i32(2, c.typeLength) }
            t.i32(3, c.repeated ? 2 : (c.optional ? 1 : 0))
            t.string(4, c.name)
            if let ct = c.convertedType { t.i32(6, ct) }
            if case .decimal(let p, let s)? = c.logical { t.i32(7, s); t.i32(8, p) }
            if let l = c.logical {
                t.begin(10)
                switch l {
                case .string: t.emptyStruct(1)
                case .date: t.emptyStruct(6)
                case .timestamp(let utc, let unit):
                    t.begin(8); t.bool(1, utc); t.begin(2); t.emptyStruct(Int16(unit)); t.end(); t.end()
                case .decimal(let p, let s): t.begin(5); t.i32(1, s); t.i32(2, p); t.end()
                case .integer(let bits, let signed): t.begin(10); t.byte(1, bits); t.bool(2, signed); t.end()
                case .uuid: t.emptyStruct(14)
                }
                t.end()
            }
            t.end()
        }
        t.i64(3, Int64(rows))
        t.listHeader(4, type: 12, count: groups.count)
        for g in groups {
            t.beginElement()
            t.listHeader(1, type: 12, count: g.chunks.count)
            for (k, c) in g.chunks.enumerated() {
                t.beginElement()
                t.i64(2, c.dictionaryOffset ?? c.dataOffset)
                t.begin(3)
                t.i32(1, columns[k].physical.rawValue)
                t.i32List(2, c.encodings)
                t.stringList(3, [columns[k].name])
                t.i32(4, options.codec)
                t.i64(5, c.values)
                t.i64(6, c.raw)
                t.i64(7, c.size)
                t.i64(9, c.dataOffset)
                if let d = c.dictionaryOffset { t.i64(11, d) }
                if let stats = c.stats { t.header(12, 12); t.bytes += stats }
                t.end()
                t.end()
            }
            t.i64(2, g.chunks.reduce(0) { $0 + $1.raw })
            t.i64(3, Int64(g.rows))
            t.end()
        }
        if !options.keyValues.isEmpty {
            t.listHeader(5, type: 12, count: options.keyValues.count)
            for (k, v) in options.keyValues { t.beginElement(); t.string(1, k); t.string(2, v); t.end() }
        }
        t.string(6, options.createdBy)
        t.bytes.append(0)
        out += t.bytes + TestBytes.le32(UInt32(t.bytes.count)) + Array("PAR1".utf8)
        return out
    }

    static func flat(_ v: TestValue) -> [TestValue] {
        switch v {
        case .null: return []
        case .list(let items): return items.flatMap(flat)
        default: return [v]
        }
    }

    static func compress(_ payload: [UInt8], _ codec: Int32) -> [UInt8] {
        switch codec {
        case 1: return TestCodecs.snappy(payload)
        case 2: return TestCodecs.gzip(payload)
        case 6: return TestCodecs.zstdRawFrame(payload)
        case 7: return TestCodecs.lz4Literals(payload)
        default: return payload
        }
    }

    /// RLE runs of the hybrid encoding.
    static func rle(_ values: [UInt64], width: Int) -> [UInt8] {
        var out: [UInt8] = []
        let byteWidth = (width + 7) / 8
        var i = 0
        while i < values.count {
            var j = i
            while j < values.count, values[j] == values[i] { j += 1 }
            out += TestBytes.uleb(UInt64(j - i) << 1)
            for k in 0..<byteWidth { out.append(UInt8(truncatingIfNeeded: values[i] >> (8 * UInt64(k)))) }
            i = j
        }
        return out
    }

    /// Bit-packed runs of the hybrid encoding (groups of 8, padded).
    static func bitPacked(_ values: [UInt64], width: Int) -> [UInt8] {
        let groups = (values.count + 7) / 8
        var out = TestBytes.uleb(UInt64(groups) << 1 | 1)
        var bits = [UInt8](repeating: 0, count: groups * width)
        var bit = 0
        for v in values + Array(repeating: 0, count: groups * 8 - values.count) {
            for k in 0..<width {
                if v >> UInt64(k) & 1 == 1 { bits[bit >> 3] |= 1 << UInt8(bit & 7) }
                bit += 1
            }
        }
        out += bits
        return out
    }

    static func plain(_ values: [TestValue], _ c: TestParquetColumn) -> [UInt8] {
        var out: [UInt8] = []
        switch c.physical {
        case .boolean:
            var bytes = [UInt8](repeating: 0, count: (values.count + 7) / 8)
            for (i, v) in values.enumerated() where v == .bool(true) { bytes[i >> 3] |= 1 << UInt8(i & 7) }
            out = bytes
        case .int32: for case .int(let n) in values { out += TestBytes.le32(UInt32(truncatingIfNeeded: n)) }
        case .int64: for case .int(let n) in values { out += TestBytes.le64(UInt64(bitPattern: n)) }
        case .int96:
            for case .int(let nanos) in values {
                let days = nanos / 86_400_000_000_000, rest = nanos % 86_400_000_000_000
                out += TestBytes.le64(UInt64(rest)) + TestBytes.le32(UInt32(days + 2_440_588))
            }
        case .float: for case .double(let d) in values { out += TestBytes.le32(Float(d).bitPattern) }
        case .double: for case .double(let d) in values { out += TestBytes.le64(d.bitPattern) }
        case .byteArray:
            for v in values {
                let b: [UInt8] = { if case .string(let s) = v { return Array(s.utf8) }; if case .bytes(let x) = v { return x }; return [] }()
                out += TestBytes.le32(UInt32(b.count)) + b
            }
        case .fixed:
            for v in values {
                if case .bytes(let x) = v { out += x } else if case .string(let s) = v { out += Array(s.utf8) }
            }
        }
        return out
    }

    /// DELTA_BINARY_PACKED with one miniblock width per block of 128 (4 miniblocks of 32).
    static func deltaBinaryPacked(_ values: [Int64]) -> [UInt8] {
        var out = TestBytes.uleb(128) + TestBytes.uleb(4) + TestBytes.uleb(UInt64(values.count)) + TestBytes.zigzag(values.first ?? 0)
        guard values.count > 1 else { return out }
        let deltas = zip(values.dropFirst(), values).map { $0 &- $1 }
        var b = 0
        while b < deltas.count {
            let block = Array(deltas[b..<min(deltas.count, b + 128)])
            let minDelta = block.min()!
            out += TestBytes.zigzag(minDelta)
            let adjusted = block.map { UInt64(bitPattern: $0 &- minDelta) }
            var widths: [UInt8] = []
            var minis: [[UInt64]] = []
            for m in 0..<4 {
                let part = Array(adjusted.dropFirst(m * 32).prefix(32))
                minis.append(part)
                let maxValue = part.max() ?? 0
                widths.append(UInt8(maxValue == 0 ? 0 : 64 - maxValue.leadingZeroBitCount))
            }
            out += widths
            for m in 0..<4 where !minis[m].isEmpty {
                let w = Int(widths[m])
                var bits = [UInt8](repeating: 0, count: 32 * w / 8)
                var bit = 0
                for v in minis[m] + Array(repeating: 0, count: 32 - minis[m].count) {
                    for k in 0..<w { if v >> UInt64(k) & 1 == 1 { bits[bit >> 3] |= 1 << UInt8(bit & 7) }; bit += 1 }
                }
                out += bits
            }
            b += 128
        }
        return out
    }

    static func valuesBytes(_ present: [TestValue], _ c: TestParquetColumn, dictionary: [TestValue]) -> [UInt8] {
        switch c.encoding {
        case .plain: return plain(present, c)
        case .dictionary:
            let width = max(1, dictionary.count <= 1 ? 1 : 64 - UInt64(dictionary.count - 1).leadingZeroBitCount)
            let indices = present.map { v in UInt64(dictionary.firstIndex(of: v)!) }
            return [UInt8(width)] + (indices.isEmpty ? [] : bitPacked(indices, width: width))
        case .delta:
            if c.physical == .byteArray {
                let bytes = present.map { v -> [UInt8] in if case .string(let s) = v { return Array(s.utf8) }; return [] }
                return deltaBinaryPacked(bytes.map { Int64($0.count) }) + bytes.flatMap { $0 }
            }
            return deltaBinaryPacked(present.map { if case .int(let n) = $0 { return n }; return 0 })
        case .deltaByteArray:
            let bytes = present.map { v -> [UInt8] in if case .string(let s) = v { return Array(s.utf8) }; return [] }
            var prefixes: [Int64] = [], suffixes: [[UInt8]] = []
            var previous: [UInt8] = []
            for b in bytes {
                var p = 0
                while p < b.count, p < previous.count, b[p] == previous[p] { p += 1 }
                prefixes.append(Int64(p)); suffixes.append(Array(b[p...])); previous = b
            }
            return deltaBinaryPacked(prefixes) + deltaBinaryPacked(suffixes.map { Int64($0.count) }) + suffixes.flatMap { $0 }
        case .byteStreamSplit:
            let raw = plain(present, c)
            let w = c.physical == .double ? 8 : 4
            let n = present.count
            return (0..<(n * w)).map { k in raw[(k % n) * w + k / n] }
        case .rle:
            let bits = present.map { $0 == .bool(true) ? UInt64(1) : 0 }
            let body = rle(bits, width: 1)
            return TestBytes.le32(UInt32(body.count)) + body
        }
    }

    static func dataPage(_ values: [TestValue], _ c: TestParquetColumn, dictionary: [TestValue], options: TestParquetOptions)
        -> (header: [UInt8], body: [UInt8], levels: Int, raw: Int) {
        var rep: [UInt64] = [], def: [UInt64] = []
        var present: [TestValue] = []
        for v in values {
            if c.repeated {
                if case .list(let items) = v, !items.isEmpty {
                    for (j, item) in items.enumerated() { rep.append(j == 0 ? 0 : 1); def.append(1); present.append(item) }
                } else { rep.append(0); def.append(0) }
            } else if c.optional {
                if v == .null { def.append(0) } else { def.append(1); present.append(v) }
            } else {
                present.append(v)
            }
        }
        let levelCount = c.repeated ? rep.count : values.count
        let repBytes = c.repeated ? rle(rep, width: 1) : []
        let defBytes = (c.optional || c.repeated) ? (c.encoding == .dictionary ? bitPacked(def, width: 1) : rle(def, width: 1)) : []
        let valueBytes = valuesBytes(present, c, dictionary: dictionary)
        let encoding: Int32 = {
            switch c.encoding {
            case .plain: 0; case .dictionary: 8; case .delta: c.physical == .byteArray ? 6 : 5; case .deltaByteArray: 7
            case .byteStreamSplit: 9; case .rle: 3
            }
        }()
        var h = TestThrift()
        if options.pageVersion == 2 {
            let compressed = compress(valueBytes, options.codec)
            let body = repBytes + defBytes + compressed
            h.i32(1, 3); h.i32(2, Int32(repBytes.count + defBytes.count + valueBytes.count)); h.i32(3, Int32(body.count))
            h.begin(8)
            h.i32(1, Int32(levelCount)); h.i32(2, Int32(def.filter { $0 == 0 }.count)); h.i32(3, Int32(values.count)); h.i32(4, encoding)
            h.i32(5, Int32(defBytes.count)); h.i32(6, Int32(repBytes.count))
            if options.codec == 0 { h.bool(7, false) }
            h.end()
            h.bytes.append(0)
            return (h.bytes, body, levelCount, h.bytes.count + repBytes.count + defBytes.count + valueBytes.count)
        }
        var payload: [UInt8] = []
        if c.repeated { payload += TestBytes.le32(UInt32(repBytes.count)) + repBytes }
        if c.optional || c.repeated { payload += TestBytes.le32(UInt32(defBytes.count)) + defBytes }
        payload += valueBytes
        let body = compress(payload, options.codec)
        h.i32(1, 0); h.i32(2, Int32(payload.count)); h.i32(3, Int32(body.count))
        h.begin(5); h.i32(1, Int32(levelCount)); h.i32(2, encoding); h.i32(3, 3); h.i32(4, 3); h.end()
        h.bytes.append(0)
        return (h.bytes, body, levelCount, h.bytes.count + payload.count)
    }

    static func statistics(_ values: [TestValue], _ c: TestParquetColumn, legacy: Bool) -> [UInt8]? {
        guard !c.repeated else { return nil }
        let present = values.filter { $0 != .null }
        let nulls = values.count - present.count
        var minBytes: [UInt8]?, maxBytes: [UInt8]?
        let ints = present.compactMap { v -> Int64? in if case .int(let n) = v { return n }; return nil }
        let doubles = present.compactMap { v -> Double? in if case .double(let d) = v { return d }; return nil }
        let strings = present.compactMap { v -> String? in if case .string(let s) = v { return s }; return nil }
        switch c.physical {
        case .int32: if let lo = ints.min(), let hi = ints.max() { minBytes = TestBytes.le32(UInt32(truncatingIfNeeded: lo)); maxBytes = TestBytes.le32(UInt32(truncatingIfNeeded: hi)) }
        case .int64: if let lo = ints.min(), let hi = ints.max() { minBytes = TestBytes.le64(UInt64(bitPattern: lo)); maxBytes = TestBytes.le64(UInt64(bitPattern: hi)) }
        case .double: if let lo = doubles.min(), let hi = doubles.max() { minBytes = TestBytes.le64(lo.bitPattern); maxBytes = TestBytes.le64(hi.bitPattern) }
        case .byteArray:
            if let lo = strings.min(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }),
               let hi = strings.max(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) { minBytes = Array(lo.utf8); maxBytes = Array(hi.utf8) }
        default: break
        }
        // Field order matters in compact delta encoding: write ids in rising order.
        var ordered = TestThrift()
        ordered.beginElement()
        if legacy {
            if let maxBytes { ordered.binary(1, maxBytes) }
            if let minBytes { ordered.binary(2, minBytes) }
            ordered.i64(3, Int64(nulls))
        } else {
            ordered.i64(3, Int64(nulls))
            if let maxBytes { ordered.binary(5, maxBytes) }
            if let minBytes { ordered.binary(6, minBytes) }
        }
        ordered.end()
        return ordered.bytes
    }
}

// MARK: FlatBuffers builder (front to back: every offset points forward)

indirect enum TestFlat {
    case table([TestFlatField?])
    case vector([TestFlat])
    /// A vector of structs (or scalars) of `size` bytes each.
    case structs([UInt8], size: Int)
    case string(String)
}

enum TestFlatField {
    case u8(UInt8), i16(Int16), i32(Int32), i64(Int64), bool(Bool)
    case offset(TestFlat)
}

enum TestFlatWriter {
    static func build(_ root: TestFlat) -> [UInt8] {
        var out: [UInt8] = [0, 0, 0, 0]
        let at = write(root, into: &out)
        out.replaceSubrange(0..<4, with: TestBytes.le32(UInt32(at)))
        while out.count % 8 != 0 { out.append(0) }
        return out
    }

    static func align(_ out: inout [UInt8], _ n: Int) { while out.count % n != 0 { out.append(0) } }

    /// Writes `node`, then whatever it points to, and returns the node's position.
    static func write(_ node: TestFlat, into out: inout [UInt8]) -> Int {
        switch node {
        case .string(let s):
            align(&out, 4)
            let at = out.count
            out += TestBytes.le32(UInt32(s.utf8.count)) + Array(s.utf8) + [0]
            return at
        case .structs(let bytes, let size):
            align(&out, 4)
            let at = out.count
            out += TestBytes.le32(UInt32(bytes.count / max(size, 1))) + bytes
            return at
        case .vector(let items):
            align(&out, 4)
            let at = out.count
            out += TestBytes.le32(UInt32(items.count))
            let slots = items.indices.map { k in at + 4 + 4 * k }
            out += Array(repeating: 0, count: 4 * items.count)
            for (k, item) in items.enumerated() {
                let target = write(item, into: &out)
                out.replaceSubrange(slots[k]..<(slots[k] + 4), with: TestBytes.le32(UInt32(target - slots[k])))
            }
            return at
        case .table(let fields):
            // The vtable first, then the table; the table's soffset is positive (vtable before it).
            align(&out, 2)
            let vtableAt = out.count
            let vtableSize = 4 + 2 * fields.count
            out += Array(repeating: 0, count: vtableSize)
            align(&out, 8)
            let tableAt = out.count
            out += TestBytes.le32(UInt32(tableAt - vtableAt))
            var pending: [(slot: Int, node: TestFlat)] = []
            var offsets: [Int] = []
            for field in fields {
                guard let field else { offsets.append(0); continue }
                func put(_ bytes: [UInt8]) {
                    while (out.count - tableAt) % bytes.count != 0 { out.append(0) }
                    offsets.append(out.count - tableAt)
                    out += bytes
                }
                switch field {
                case .u8(let v): put([v])
                case .bool(let v): put([v ? 1 : 0])
                case .i16(let v): put(TestBytes.le16(UInt16(bitPattern: v)))
                case .i32(let v): put(TestBytes.le32(UInt32(bitPattern: v)))
                case .i64(let v): put(TestBytes.le64(UInt64(bitPattern: v)))
                case .offset(let n): put([0, 0, 0, 0]); pending.append((out.count - 4, n))
                }
            }
            let tableSize = out.count - tableAt
            out.replaceSubrange(vtableAt..<(vtableAt + 2), with: TestBytes.le16(UInt16(vtableSize)))
            out.replaceSubrange((vtableAt + 2)..<(vtableAt + 4), with: TestBytes.le16(UInt16(tableSize)))
            for (k, o) in offsets.enumerated() {
                out.replaceSubrange((vtableAt + 4 + 2 * k)..<(vtableAt + 6 + 2 * k), with: TestBytes.le16(UInt16(o)))
            }
            for (slot, n) in pending {
                let target = write(n, into: &out)
                out.replaceSubrange(slot..<(slot + 4), with: TestBytes.le32(UInt32(target - slot)))
            }
            return tableAt
        }
    }
}

// MARK: Arrow writer

struct TestArrowColumn {
    enum Kind {
        case int64, int32, uint8, float64, utf8, bool, date32, timestampMicros(zone: String?), decimal128(precision: Int32, scale: Int32)
        case listInt32, structIntUtf8, dictionaryUtf8, fixedSizeBinary(Int32), utf8View
    }
    var name: String
    var kind: Kind
    var values: [TestValue]
}

enum TestArrow {
    /// Compression for record batch buffers: (codec id, function). nil writes plain buffers.
    typealias Compressor = (codec: Int8, compress: ([UInt8]) -> [UInt8])

    static func typeFields(_ kind: TestArrowColumn.Kind) -> (UInt8, TestFlat) {
        switch kind {
        case .int64: return (2, .table([.i32(64), .bool(true)]))
        case .int32: return (2, .table([.i32(32), .bool(true)]))
        case .uint8: return (2, .table([.i32(8), .bool(false)]))
        case .float64: return (3, .table([.i16(2)]))
        case .utf8, .dictionaryUtf8: return (5, .table([]))
        case .utf8View: return (24, .table([]))
        case .bool: return (6, .table([]))
        case .date32: return (8, .table([.i16(0)]))
        case .timestampMicros(let zone): return (10, .table([.i16(2), zone.map { .offset(.string($0)) }]))
        case .decimal128(let p, let s): return (7, .table([.i32(p), .i32(s), .i32(128)]))
        case .listInt32: return (12, .table([]))
        case .structIntUtf8: return (13, .table([]))
        case .fixedSizeBinary(let w): return (15, .table([.i32(w)]))
        }
    }

    static func field(_ c: TestArrowColumn) -> TestFlat {
        let (typeType, type) = typeFields(c.kind)
        var children: [TestFlat] = []
        switch c.kind {
        case .listInt32: children = [field(TestArrowColumn(name: "item", kind: .int32, values: []))]
        case .structIntUtf8:
            children = [field(TestArrowColumn(name: "a", kind: .int32, values: [])), field(TestArrowColumn(name: "b", kind: .utf8, values: []))]
        default: break
        }
        var dictionary: TestFlatField?
        if case .dictionaryUtf8 = c.kind {
            dictionary = .offset(.table([.i64(7), .offset(.table([.i32(32), .bool(true)]))]))
        }
        return .table([.offset(.string(c.name)), .bool(true), .u8(typeType), .offset(type), dictionary, .offset(.vector(children))])
    }

    static func schema(_ columns: [TestArrowColumn]) -> TestFlat {
        .table([.i16(0), .offset(.vector(columns.map(field)))])
    }

    static func message(type: UInt8, header: TestFlat, bodyLength: Int) -> [UInt8] {
        TestFlatWriter.build(.table([.i16(4), .u8(type), .offset(header), .i64(Int64(bodyLength))]))
    }

    /// A body under construction: buffers padded to 8 bytes.
    struct Body {
        var bytes: [UInt8] = []
        var buffers: [(Int64, Int64)] = []
        var nodes: [(Int64, Int64)] = []
        var compressor: Compressor?
        mutating func add(_ raw: [UInt8]) {
            var data = raw
            if let compressor, !raw.isEmpty { data = TestBytes.le64(UInt64(raw.count)) + compressor.compress(raw) }
            buffers.append((Int64(bytes.count), Int64(data.count)))
            bytes += data
            while bytes.count % 8 != 0 { bytes.append(0) }
        }
        mutating func validity(_ values: [TestValue]) {
            let nulls = values.filter { $0 == .null }.count
            if nulls == 0 { add([]); return }
            var bits = [UInt8](repeating: 0, count: (values.count + 7) / 8)
            for (i, v) in values.enumerated() where v != .null { bits[i >> 3] |= 1 << UInt8(i & 7) }
            add(bits)
        }
    }

    static func ints(_ values: [TestValue]) -> [Int64] { values.map { if case .int(let n) = $0 { return n }; return 0 } }

    static func encode(_ c: TestArrowColumn, _ values: [TestValue], into body: inout Body, dictionary: [String]) {
        body.nodes.append((Int64(values.count), Int64(values.filter { $0 == .null }.count)))
        switch c.kind {
        case .int64, .timestampMicros:
            body.validity(values); body.add(ints(values).flatMap { TestBytes.le64(UInt64(bitPattern: $0)) })
        case .int32, .date32:
            body.validity(values); body.add(ints(values).flatMap { TestBytes.le32(UInt32(truncatingIfNeeded: $0)) })
        case .uint8:
            body.validity(values); body.add(ints(values).map { UInt8(truncatingIfNeeded: $0) })
        case .float64:
            body.validity(values); body.add(values.flatMap { v -> [UInt8] in if case .double(let d) = v { return TestBytes.le64(d.bitPattern) }; return TestBytes.le64(0) })
        case .bool:
            body.validity(values)
            var bits = [UInt8](repeating: 0, count: (values.count + 7) / 8)
            for (i, v) in values.enumerated() where v == .bool(true) { bits[i >> 3] |= 1 << UInt8(i & 7) }
            body.add(bits)
        case .decimal128(_, _):
            body.validity(values)
            body.add(ints(values).flatMap { n in TestBytes.le64(UInt64(bitPattern: n)) + TestBytes.le64(n < 0 ? .max : 0) })
        case .utf8:
            body.validity(values)
            var offsets: [UInt8] = TestBytes.le32(0), data: [UInt8] = []
            for v in values { if case .string(let s) = v { data += Array(s.utf8) }; offsets += TestBytes.le32(UInt32(data.count)) }
            body.add(offsets); body.add(data)
        case .utf8View:
            body.validity(values)
            var views: [UInt8] = [], data: [UInt8] = []
            for v in values {
                let s: [UInt8] = { if case .string(let x) = v { return Array(x.utf8) }; return [] }()
                if s.count <= 12 { views += TestBytes.le32(UInt32(s.count)) + s + Array(repeating: 0, count: 12 - s.count) } else {
                    views += TestBytes.le32(UInt32(s.count)) + Array(s.prefix(4)) + TestBytes.le32(0) + TestBytes.le32(UInt32(data.count))
                    data += s
                }
            }
            body.add(views); body.add(data)
        case .fixedSizeBinary(let w):
            body.validity(values)
            body.add(values.flatMap { v -> [UInt8] in if case .bytes(let b) = v { return b }; return Array(repeating: 0, count: Int(w)) })
        case .dictionaryUtf8:
            body.validity(values)
            body.add(values.flatMap { v -> [UInt8] in
                if case .string(let s) = v { return TestBytes.le32(UInt32(dictionary.firstIndex(of: s)!)) }; return TestBytes.le32(0)
            })
        case .listInt32:
            body.validity(values)
            var offsets: [UInt8] = TestBytes.le32(0), items: [TestValue] = []
            for v in values { if case .list(let l) = v { items += l }; offsets += TestBytes.le32(UInt32(items.count)) }
            body.add(offsets)
            encode(TestArrowColumn(name: "item", kind: .int32, values: []), items, into: &body, dictionary: [])
        case .structIntUtf8:
            body.validity(values)
            let a = values.map { v -> TestValue in if case .list(let l) = v { return l[0] }; return .null }
            let b = values.map { v -> TestValue in if case .list(let l) = v { return l[1] }; return .null }
            encode(TestArrowColumn(name: "a", kind: .int32, values: []), a, into: &body, dictionary: [])
            encode(TestArrowColumn(name: "b", kind: .utf8, values: []), b, into: &body, dictionary: [])
        }
    }

    /// `variadic`: variadicBufferCounts, one data buffer per view column (every long view goes in one buffer).
    static func recordBatch(rows: Int, body: Body, compressor: Compressor?, variadic: [Int64] = []) -> TestFlat {
        let nodes = body.nodes.flatMap { TestBytes.le64(UInt64($0.0)) + TestBytes.le64(UInt64($0.1)) }
        let buffers = body.buffers.flatMap { TestBytes.le64(UInt64($0.0)) + TestBytes.le64(UInt64($0.1)) }
        return .table([.i64(Int64(rows)), .offset(.structs(nodes, size: 16)), .offset(.structs(buffers, size: 16)),
                       compressor.map { .offset(.table([.u8(UInt8(bitPattern: $0.codec)), .u8(0)])) },
                       variadic.isEmpty ? nil : .offset(.structs(variadic.flatMap { TestBytes.le64(UInt64($0)) }, size: 8))])
    }

    /// Messages framed with the 0xFFFFFFFF continuation; returns the bytes and each message's (offset, metadata
    /// length with prefix and padding, body length).
    static func frame(_ metadata: [UInt8], _ body: [UInt8], into out: inout [UInt8]) -> (Int64, Int32, Int64) {
        let offset = Int64(out.count)
        var meta = metadata
        while (meta.count + 8) % 8 != 0 { meta.append(0) }
        out += TestBytes.le32(0xFFFF_FFFF) + TestBytes.le32(UInt32(meta.count)) + meta + body
        return (offset, Int32(meta.count + 8), Int64(body.count))
    }

    /// An Arrow IPC stream (or, with `file`, the file format with its footer) holding `columns` in batches.
    static func ipc(_ columns: [TestArrowColumn], batchRows: Int, file: Bool, compressor: Compressor? = nil) -> [UInt8] {
        var out: [UInt8] = file ? Array("ARROW1".utf8) + [0, 0] : []
        let schema = schema(columns)
        _ = frame(TestFlatWriter.build(.table([.i16(4), .u8(1), .offset(schema), .i64(0)])), [], into: &out)
        var dictionaryBlocks: [(Int64, Int32, Int64)] = []
        var batchBlocks: [(Int64, Int32, Int64)] = []
        // One dictionary per dictionary column (id 7).
        var dictionary: [String] = []
        for c in columns { if case .dictionaryUtf8 = c.kind { for case .string(let s) in c.values where !dictionary.contains(s) { dictionary.append(s) } } }
        if !dictionary.isEmpty {
            var body = Body(compressor: compressor)
            encode(TestArrowColumn(name: "d", kind: .utf8, values: []), dictionary.map { .string($0) }, into: &body, dictionary: [])
            let header: TestFlat = .table([.i64(7), .offset(recordBatch(rows: dictionary.count, body: body, compressor: compressor)), .bool(false)])
            dictionaryBlocks.append(frame(message(type: 2, header: header, bodyLength: body.bytes.count), body.bytes, into: &out))
        }
        let rows = columns.first?.values.count ?? 0
        var start = 0
        while start < rows {
            let end = min(rows, start + batchRows)
            var body = Body(compressor: compressor)
            for c in columns { encode(c, Array(c.values[start..<end]), into: &body, dictionary: dictionary) }
            let viewCounts: [Int64] = columns.filter { if case .utf8View = $0.kind { return true }; return false }.map { _ in 1 }
            let header = recordBatch(rows: end - start, body: body, compressor: compressor, variadic: viewCounts)
            batchBlocks.append(frame(message(type: 3, header: header, bodyLength: body.bytes.count), body.bytes, into: &out))
            start = end
        }
        out += TestBytes.le32(0xFFFF_FFFF) + TestBytes.le32(0)
        if file {
            func blocks(_ list: [(Int64, Int32, Int64)]) -> [UInt8] {
                list.flatMap { TestBytes.le64(UInt64($0.0)) + TestBytes.le32(UInt32($0.1)) + [0, 0, 0, 0] + TestBytes.le64(UInt64($0.2)) }
            }
            let footer = TestFlatWriter.build(.table([.i16(4), .offset(schema), .offset(.structs(blocks(dictionaryBlocks), size: 24)),
                                                      .offset(.structs(blocks(batchBlocks), size: 24))]))
            out += footer + TestBytes.le32(UInt32(footer.count)) + Array("ARROW1".utf8)
        }
        return out
    }
}

// MARK: xlsx writer

enum TestXLSX {
    /// A stored (uncompressed) zip of `parts` (APPNOTE.TXT §4.3: local headers, central directory, end record).
    static func zip(_ parts: [(String, [UInt8])]) -> [UInt8] {
        var out: [UInt8] = []
        var central: [UInt8] = []
        for (name, data) in parts {
            let offset = out.count
            let crc = TestBytes.crc32(data)
            let n = Array(name.utf8)
            let common = TestBytes.le16(20) + TestBytes.le16(0) + TestBytes.le16(0) + TestBytes.le16(0) + TestBytes.le16(0x21)
                + TestBytes.le32(crc) + TestBytes.le32(UInt32(data.count)) + TestBytes.le32(UInt32(data.count)) + TestBytes.le16(UInt16(n.count)) + TestBytes.le16(0)
            out += TestBytes.le32(0x0403_4B50) + common + n + data
            central += TestBytes.le32(0x0201_4B50) + TestBytes.le16(20) + common + TestBytes.le16(0) + TestBytes.le16(0) + TestBytes.le16(0)
                + TestBytes.le32(0) + TestBytes.le32(UInt32(offset)) + n
        }
        let centralOffset = out.count
        out += central
        out += TestBytes.le32(0x0605_4B50) + TestBytes.le16(0) + TestBytes.le16(0) + TestBytes.le16(UInt16(parts.count)) + TestBytes.le16(UInt16(parts.count))
            + TestBytes.le32(UInt32(central.count)) + TestBytes.le32(UInt32(centralOffset)) + TestBytes.le16(0)
        return out
    }

    /// A workbook of sheets given as rows of cell XML (`<c r="A1" t="s"><v>0</v></c>` …).
    static func workbook(sheets: [(name: String, xml: String)], sharedStrings: [String], styles: String? = nil, date1904: Bool = false,
                         hidden: Set<String> = []) -> [UInt8] {
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var parts: [(String, [UInt8])] = []
        parts.append(("[Content_Types].xml", Array("<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>".utf8)))
        parts.append(("_rels/.rels", Array("""
        <?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="\(rel)/extended-properties" Target="docProps/app.xml"/></Relationships>
        """.utf8)))
        parts.append(("docProps/app.xml", Array("<?xml version=\"1.0\"?><Properties><Application>Vitrine Test Writer</Application><AppVersion>1.0</AppVersion></Properties>".utf8)))
        let sheetList = sheets.enumerated().map { k, s in
            "<sheet name=\"\(s.name)\" sheetId=\"\(k + 1)\"\(hidden.contains(s.name) ? " state=\"hidden\"" : "") r:id=\"rId\(k + 1)\"/>"
        }.joined()
        parts.append(("xl/workbook.xml", Array("""
        <?xml version="1.0"?><workbook xmlns="\(ns)" xmlns:r="\(rel)"><workbookPr\(date1904 ? " date1904=\"1\"" : "")/><sheets>\(sheetList)</sheets></workbook>
        """.utf8)))
        var rels = sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined()
        rels += "<Relationship Id=\"rIdS\" Type=\"\(rel)/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        if styles != nil { rels += "<Relationship Id=\"rIdT\" Type=\"\(rel)/styles\" Target=\"styles.xml\"/>" }
        parts.append(("xl/_rels/workbook.xml.rels", Array("<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>".utf8)))
        let sst = sharedStrings.map { "<si><t>\(escape($0))</t></si>" }.joined()
        parts.append(("xl/sharedStrings.xml", Array("<?xml version=\"1.0\"?><sst xmlns=\"\(ns)\" count=\"\(sharedStrings.count)\">\(sst)</sst>".utf8)))
        if let styles { parts.append(("xl/styles.xml", Array("<?xml version=\"1.0\"?><styleSheet xmlns=\"\(ns)\">\(styles)</styleSheet>".utf8))) }
        for (k, s) in sheets.enumerated() {
            parts.append(("xl/worksheets/sheet\(k + 1).xml", Array("<?xml version=\"1.0\"?><worksheet xmlns=\"\(ns)\">\(s.xml)</worksheet>".utf8)))
        }
        return zip(parts)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
