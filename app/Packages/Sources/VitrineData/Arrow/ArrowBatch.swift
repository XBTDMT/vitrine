import Foundation
import VitrineSupport

/// One record batch (`format/Message.fbs` RecordBatch: length, FieldNodes, Buffers, BodyCompression,
/// variadicBufferCounts), with each field's place in the flattened node and buffer lists worked out from the
/// buffer layout of its type. Columns are read for a range of rows; nested values become text. roadmap: S-21
final class ArrowBatch {
    struct Node { var length: Int; var nulls: Int }
    struct Buffer { var offset: Int64; var length: Int64 }

    /// Where a field's node, buffers and children are.
    final class Layout {
        let node: Int
        let buffers: [Int]
        let children: [Layout]
        init(node: Int, buffers: [Int], children: [Layout]) { self.node = node; self.buffers = buffers; self.children = children }
    }

    let rows: Int
    let nodes: [Node]
    let buffers: [Buffer]
    let codec: ColumnarCodecs.Codec?
    let bodyOffset: Int64
    let bodyLength: Int64
    let source: any ByteSource
    let fields: [ArrowField]
    let layouts: [Layout]
    let limits: ColumnarLimits
    private var decompressed: [Int: [UInt8]] = [:]

    init(table: FlatTable, bodyOffset: Int64, bodyLength: Int64, source: any ByteSource, fields: [ArrowField], version: Int16,
         limits: ColumnarLimits) throws {
        let declaredRows = try table.int64(0)
        guard declaredRows >= 0, declaredRows <= Int64(Int32.max) else { throw ColumnarError.malformed(String(localized: "a record batch claims \(declaredRows) rows", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        rows = Int(declaredRows)
        let bytes = table.bytes
        if let (n, start) = try table.vector(1, elementSize: 16) {
            nodes = try (0..<n).map { k in
                let length = Int64(bitPattern: try FlatTable.u64(bytes, start + 16 * k))
                let nulls = Int64(bitPattern: try FlatTable.u64(bytes, start + 16 * k + 8))
                guard length >= 0, length <= Int64(Int32.max), nulls >= 0, nulls <= length else {
                    throw ColumnarError.malformed(String(localized: "a field node with \(length) values and \(nulls) nulls", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                }
                return Node(length: Int(length), nulls: Int(nulls))
            }
        } else { nodes = [] }
        if let (n, start) = try table.vector(2, elementSize: 16) {
            buffers = try (0..<n).map { k in
                let offset = Int64(bitPattern: try FlatTable.u64(bytes, start + 16 * k))
                let length = Int64(bitPattern: try FlatTable.u64(bytes, start + 16 * k + 8))
                guard offset >= 0, length >= 0, offset <= bodyLength, length <= bodyLength - offset else {
                    throw ColumnarError.malformed(String(localized: "a buffer lies outside its record batch body", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                }
                return Buffer(offset: offset, length: length)
            }
        } else { buffers = [] }
        if let compression = try table.table(3) {
            guard try compression.int8(1) == 0 else { throw ColumnarError.unsupported(String(localized: "Arrow body compression other than per buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            switch try compression.int8(0) {
            case 0: codec = .lz4Frame
            case 1: codec = .zstd
            case let c: throw ColumnarError.unsupported(String(localized: "Arrow body compression codec \(c)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
            }
        } else { codec = nil }
        var variadic: [Int64] = []
        if let (n, start) = try table.vector(4, elementSize: 8) {
            variadic = try (0..<n).map { Int64(bitPattern: try FlatTable.u64(bytes, start + 8 * $0)) }
        }
        self.bodyOffset = bodyOffset
        self.bodyLength = bodyLength
        self.source = source
        self.fields = fields
        self.limits = limits
        var nodeCursor = 0, bufferCursor = 0, variadicCursor = 0
        let nodeCount = nodes.count, bufferCount = buffers.count
        func layout(_ f: ArrowField, depth: Int) throws -> Layout {
            guard depth <= limits.maxDepth else { throw ColumnarError.malformed(String(localized: "fields nested too deep", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            guard nodeCursor < nodeCount else { throw ColumnarError.malformed(String(localized: "the record batch has fewer field nodes than the schema has fields", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let node = nodeCursor
            nodeCursor += 1
            var count: Int
            var walkChildren = true
            if f.dictionary != nil { count = 2; walkChildren = false } else {
                switch f.type {
                case .null: count = 0
                case .int, .float, .bool, .decimal, .date, .time, .timestamp, .interval, .duration, .fixedSizeBinary: count = 2
                case .binary, .utf8, .largeBinary, .largeUtf8: count = 3
                case .binaryView, .utf8View:
                    guard variadicCursor < variadic.count, variadic[variadicCursor] >= 0, variadic[variadicCursor] <= Int64(bufferCount) else {
                        throw ColumnarError.malformed(String(localized: "a view field without its variadic buffer count", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                    }
                    count = 2 + Int(variadic[variadicCursor])
                    variadicCursor += 1
                case .list, .largeList, .map: count = 2
                case .listView, .largeListView: count = 3
                case .fixedSizeList, .structure: count = 1
                case .union(let mode): count = (mode == 0 ? 1 : 2) + (version < 4 ? 1 : 0)
                case .runEndEncoded: count = 0
                case .unknown(let t): throw ColumnarError.unsupported(String(localized: "Arrow type \(t)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                }
            }
            guard bufferCursor + count <= bufferCount else { throw ColumnarError.malformed(String(localized: "the record batch has fewer buffers than its fields need", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let own = Array(bufferCursor..<(bufferCursor + count))
            bufferCursor += count
            let children = walkChildren ? try f.children.map { try layout($0, depth: depth + 1) } : []
            return Layout(node: node, buffers: own, children: children)
        }
        layouts = try fields.map { try layout($0, depth: 1) }
    }

    // MARK: Buffers

    /// Bytes `range` of buffer `index` (a compressed buffer is decompressed whole once).
    func bytes(_ index: Int, _ range: Range<Int>, budget: inout Int) throws -> [UInt8] {
        guard !range.isEmpty else { return [] }
        let b = buffers[index]
        if let codec {
            let whole = try decompressedBuffer(index, codec: codec, budget: &budget)
            guard range.lowerBound >= 0, range.upperBound <= whole.count else { throw ColumnarError.malformed(String(localized: "a value lies outside its buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            return Array(whole[range])
        }
        guard range.lowerBound >= 0, Int64(range.upperBound) <= b.length else { throw ColumnarError.malformed(String(localized: "a value lies outside its buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        budget -= range.count
        guard budget >= 0 else { throw ColumnarError.tooLarge(String(localized: "the rows asked for hold more than \(limits.maxWindowBytes / 1_048_576) MB", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let got = try source.read(at: bodyOffset + b.offset + Int64(range.lowerBound), count: range.count)
        guard got.count == range.count else { throw ColumnarError.truncated(String(localized: "a buffer ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return got
    }

    func bufferLength(_ index: Int, budget: inout Int) throws -> Int {
        if let codec { return try decompressedBuffer(index, codec: codec, budget: &budget).count }
        return Int(buffers[index].length)
    }

    private func decompressedBuffer(_ index: Int, codec: ColumnarCodecs.Codec, budget: inout Int) throws -> [UInt8] {
        if let d = decompressed[index] { return d }
        let b = buffers[index]
        guard b.length > 0 else { return [] }
        guard b.length >= 8, b.length <= Int64(limits.maxPageBytes) else { throw ColumnarError.malformed(String(localized: "a compressed buffer of \(b.length) bytes", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let raw = try source.read(at: bodyOffset + b.offset, count: Int(b.length))
        guard raw.count == Int(b.length) else { throw ColumnarError.truncated(String(localized: "a buffer ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let declared = Int64(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(raw[$1]) << (8 * UInt64($1)) })
        let out: [UInt8]
        if declared == -1 {
            out = Array(raw[8...])
        } else {
            guard declared >= 0, declared <= Int64(limits.maxPageBytes) else {
                throw ColumnarError.tooLarge(String(localized: "a buffer claims \(ByteCountFormatter.string(fromByteCount: declared, countStyle: .file)) uncompressed", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
            }
            budget -= Int(declared)
            guard budget >= 0 else { throw ColumnarError.tooLarge(String(localized: "the rows asked for decompress to more than \(limits.maxWindowBytes / 1_048_576) MB", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            out = try ColumnarCodecs.decompress(raw[8...], codec: codec, expected: Int(declared))
        }
        decompressed[index] = out
        return out
    }

    // MARK: Columns

    /// Rows `range` of top-level field `index`.
    func column(_ index: Int, rows range: Range<Int>, dictionaries: [Int64: ColumnVector], budget: inout Int) throws -> ColumnVector {
        let field = fields[index], layout = layouts[index]
        let length = nodes[layout.node].length
        let r = range.clamped(to: 0..<length)
        var vector = try values(field, layout, r, dictionaries: dictionaries, budget: &budget, depth: 0)
        if r.count < range.count { vector = vector.appending(.nulls(range.count - r.count)) }
        return vector
    }

    func nulls(_ layout: Layout, _ r: Range<Int>, budget: inout Int) throws -> [Bool]? {
        let node = nodes[layout.node]
        guard node.nulls > 0, let first = layout.buffers.first, buffers[first].length > 0, !r.isEmpty else { return nil }
        let bits = try bytes(first, (r.lowerBound / 8)..<((r.upperBound + 7) / 8), budget: &budget)
        guard !bits.isEmpty else { return nil }
        let base = r.lowerBound / 8 * 8
        return r.map { i in
            let bit = i - base
            return bits[bit >> 3] >> UInt8(bit & 7) & 1 == 0
        }
    }

    static func le(_ b: [UInt8], _ at: Int, _ width: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<width { v |= UInt64(b[at + k]) << (8 * UInt64(k)) }
        return v
    }

    /// Offsets `r.lowerBound ... r.upperBound` of a list or binary array (32- or 64-bit), checked to rise.
    func offsets(_ buffer: Int, _ r: Range<Int>, wide: Bool, budget: inout Int) throws -> [Int] {
        let w = wide ? 8 : 4
        let raw = try bytes(buffer, (r.lowerBound * w)..<((r.upperBound + 1) * w), budget: &budget)
        guard raw.count == (r.count + 1) * w else { throw ColumnarError.malformed(String(localized: "an offsets buffer is too short", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var out: [Int] = []
        out.reserveCapacity(r.count + 1)
        for k in 0...r.count {
            let v = Int64(bitPattern: wide ? Self.le(raw, k * w, 8) : UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(Self.le(raw, k * w, 4))))))
            guard v >= 0, v <= Int64(Int32.max) * 4, out.last.map({ Int64($0) <= v }) ?? true else {
                throw ColumnarError.malformed(String(localized: "offsets that go backwards or below zero", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
            }
            out.append(Int(v))
        }
        return out
    }

    func values(_ f: ArrowField, _ layout: Layout, _ r: Range<Int>, dictionaries: [Int64: ColumnVector], budget: inout Int,
                depth: Int) throws -> ColumnVector {
        let nulls = try self.nulls(layout, r, budget: &budget)
        let n = r.count
        if let d = f.dictionary {
            guard let dictionary = dictionaries[d.id] else { throw ColumnarError.malformed(String(localized: "dictionary \(d.id) is missing", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let w = d.indexBits / 8
            let raw = try bytes(layout.buffers[1], (r.lowerBound * w)..<(r.upperBound * w), budget: &budget)
            var indices: [UInt64] = []
            indices.reserveCapacity(n)
            for k in 0..<n {
                if let nulls, nulls[k] { indices.append(0); continue }
                var v = Self.le(raw, k * w, w)
                if d.indexSigned, w < 8, v & (1 << UInt64(w * 8 - 1)) != 0 { v |= ~UInt64(0) << UInt64(w * 8) }
                guard Int64(bitPattern: v) >= 0, v < UInt64(max(dictionary.count, 1)) else {
                    throw ColumnarError.malformed(String(localized: "a dictionary index \(Int64(bitPattern: v)) past its \(dictionary.count)-entry dictionary", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                }
                indices.append(v)
            }
            if dictionary.count == 0 { return ColumnVector.nulls(n) }
            let picked = try ParquetValues.gather(dictionary.storage, indices: indices)
            let inner = dictionary.nulls.map { dn in indices.map { dn[Int($0)] } }
            let combined: [Bool]? = (nulls == nil && inner == nil) ? nil
                : (0..<n).map { (nulls?[$0] ?? false) || (inner?[$0] ?? false) }
            return ColumnVector(storage: picked, nulls: combined)
        }
        func fixed(_ w: Int) throws -> [UInt8] {
            let raw = try bytes(layout.buffers[1], (r.lowerBound * w)..<(r.upperBound * w), budget: &budget)
            guard raw.count == n * w else { throw ColumnarError.malformed(String(localized: "a values buffer is too short", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            return raw
        }
        switch f.type {
        case .null:
            return .nulls(n)
        case .int(let bits, let signed):
            let w = bits / 8, raw = try fixed(w)
            return ColumnVector(storage: .ints((0..<n).map { k in
                let v = Self.le(raw, k * w, w)
                if signed, w < 8, v & (1 << UInt64(bits - 1)) != 0 { return Int64(bitPattern: v | ~UInt64(0) << UInt64(bits)) }
                return Int64(bitPattern: v)
            }), nulls: nulls)
        case .float(let p):
            let w = [2, 4, 8][min(max(p, 0), 2)], raw = try fixed(w)
            return ColumnVector(storage: .doubles((0..<n).map { k in
                let v = Self.le(raw, k * w, w)
                switch w {
                case 2: return ParquetValues.half(UInt16(v))
                case 4: return Double(Float(bitPattern: UInt32(v)))
                default: return Double(bitPattern: v)
                }
            }), nulls: nulls)
        case .bool:
            let raw = try bytes(layout.buffers[1], (r.lowerBound / 8)..<((r.upperBound + 7) / 8), budget: &budget)
            let base = r.lowerBound / 8 * 8
            return ColumnVector(storage: .bools(r.map { i in raw[(i - base) >> 3] >> UInt8((i - base) & 7) & 1 == 1 }), nulls: nulls)
        case .decimal(_, let scale, let bits):
            let w = bits / 8, raw = try fixed(w)
            var ints: [Int64] = []
            var allFit = true
            for k in 0..<n {
                let be = Array(raw[(k * w)..<((k + 1) * w)].reversed())
                let value = ParquetValues.signExtended(Array(be.suffix(min(w, 8))))
                if w > 8, !be.prefix(w - 8).allSatisfy({ $0 == (value < 0 ? 0xFF : 0) }) { allFit = false }
                ints.append(value)
            }
            if allFit { return ColumnVector(storage: .ints(ints), nulls: nulls) }
            // Wider than 64 bits: the digits as text, with the number they stand for.
            return ColumnVector(storage: .cells((0..<n).map { k in
                let be = Array(raw[(k * w)..<((k + 1) * w)].reversed())
                let (digits, negative) = ColumnarText.bigEndianInteger(be)
                let text = ColumnarText.decimal(unscaled: digits, negative: negative, scale: scale)
                return .text(text, number: Double(text))
            }), nulls: nulls)
        case .date(let unit):
            let w = unit == 0 ? 4 : 8, raw = try fixed(w)
            return ColumnVector(storage: .ints((0..<n).map { k in
                w == 4 ? Int64(Int32(bitPattern: UInt32(Self.le(raw, k * 4, 4)))) : Int64(bitPattern: Self.le(raw, k * 8, 8))
            }), nulls: nulls)
        case .time(_, let bits):
            let w = bits / 8, raw = try fixed(w)
            return ColumnVector(storage: .ints((0..<n).map { k in
                w == 4 ? Int64(Int32(bitPattern: UInt32(Self.le(raw, k * 4, 4)))) : Int64(bitPattern: Self.le(raw, k * 8, 8))
            }), nulls: nulls)
        case .timestamp, .duration:
            let raw = try fixed(8)
            return ColumnVector(storage: .ints((0..<n).map { Int64(bitPattern: Self.le(raw, $0 * 8, 8)) }), nulls: nulls)
        case .interval(let unit):
            let w = [4, 8, 16][min(max(unit, 0), 2)], raw = try fixed(w)
            func i32(_ at: Int) -> Int32 { Int32(bitPattern: UInt32(Self.le(raw, at, 4))) }
            return ColumnVector(storage: .strings((0..<n).map { k in
                let at = k * w
                switch w {
                case 4: return String(localized: "\(i32(at)) months", bundle: .module, comment: "An interval value in a table cell: a number of months.")
                case 8: return String(localized: "\(i32(at)) days, \(i32(at + 4)) ms", bundle: .module, comment: "An interval value in a table cell: days and milliseconds.")
                default: return String(localized: "\(i32(at)) months, \(i32(at + 4)) days, \(Int64(bitPattern: Self.le(raw, at + 8, 8))) ns", bundle: .module, comment: "An interval value in a table cell: months, days and nanoseconds.")
                }
            }), nulls: nulls)
        case .fixedSizeBinary(let w):
            guard w > 0 else { return ColumnVector(storage: .bytes(Array(repeating: [], count: n)), nulls: nulls) }
            let raw = try fixed(w)
            return ColumnVector(storage: .bytes((0..<n).map { Array(raw[($0 * w)..<(($0 + 1) * w)]) }), nulls: nulls)
        case .binary, .utf8, .largeBinary, .largeUtf8:
            let wide = f.type == .largeBinary || f.type == .largeUtf8
            let off = try offsets(layout.buffers[1], r, wide: wide, budget: &budget)
            let data = try bytes(layout.buffers[2], off[0]..<off[n], budget: &budget)
            guard data.count == off[n] - off[0] else { throw ColumnarError.malformed(String(localized: "a data buffer is too short", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let pieces = (0..<n).map { Array(data[(off[$0] - off[0])..<(off[$0 + 1] - off[0])]) }
            if f.type == .utf8 || f.type == .largeUtf8 { return ColumnVector(storage: .strings(pieces.map { String(decoding: $0, as: UTF8.self) }), nulls: nulls) }
            return ColumnVector(storage: .bytes(pieces), nulls: nulls)
        case .binaryView, .utf8View:
            let views = try fixed(16)
            var pieces: [[UInt8]] = []
            pieces.reserveCapacity(n)
            for k in 0..<n {
                let at = k * 16
                let length = Int(Int32(bitPattern: UInt32(Self.le(views, at, 4))))
                guard length >= 0 else { throw ColumnarError.malformed(String(localized: "a view with a negative length", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                if length <= 12 { pieces.append(Array(views[(at + 4)..<(at + 4 + length)])); continue }
                let which = Int(Int32(bitPattern: UInt32(Self.le(views, at + 8, 4))))
                let offset = Int(Int32(bitPattern: UInt32(Self.le(views, at + 12, 4))))
                guard which >= 0, which + 2 < layout.buffers.count, offset >= 0 else { throw ColumnarError.malformed(String(localized: "a view points to a missing buffer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                pieces.append(try bytes(layout.buffers[which + 2], offset..<(offset + length), budget: &budget))
            }
            if f.type == .utf8View { return ColumnVector(storage: .strings(pieces.map { String(decoding: $0, as: UTF8.self) }), nulls: nulls) }
            return ColumnVector(storage: .bytes(pieces), nulls: nulls)
        case .list, .largeList, .fixedSizeList, .structure, .map:
            let texts = try nestedText(f, layout, r, nulls: nulls, dictionaries: dictionaries, budget: &budget, depth: depth)
            return ColumnVector(storage: .cells(texts.map { $0.map { .text($0, number: nil) } ?? .null }))
        case .union, .runEndEncoded, .listView, .largeListView, .unknown:
            return ColumnVector(storage: .cells(Array(repeating: .text(String(localized: "not shown", bundle: .module, comment: "Table cell text for a value the preview does not decode."), number: nil), count: n)))
        }
    }

    /// Nested values as text: lists "[1, 2]", structs and maps "{a: 1, b: "x"}". Bounded by elements and length.
    func nestedText(_ f: ArrowField, _ layout: Layout, _ r: Range<Int>, nulls: [Bool]?, dictionaries: [Int64: ColumnVector],
                    budget: inout Int, depth: Int) throws -> [String?] {
        guard depth < 8 else { return Array(repeating: "…", count: r.count) }
        let cap = limits.maxNestedElements
        func cut(_ s: String) -> String { s.count > limits.maxNestedText ? String(s.prefix(limits.maxNestedText)) + "…" : s }
        func childTexts(_ child: ArrowField, _ childLayout: Layout, _ range: Range<Int>) throws -> [String] {
            let length = nodes[childLayout.node].length
            let cr = range.clamped(to: 0..<length)
            let v = try values(child, childLayout, cr, dictionaries: dictionaries, budget: &budget, depth: depth + 1)
            let kind = child.dictionary == nil ? ArrowSchemaReader.column(child).kind : ArrowSchemaReader.column({ var c = child; c.dictionary = nil; return c }()).kind
            return (0..<v.count).map { ParquetValues.element(v[$0], kind: kind) }
        }
        var out: [String?] = []
        out.reserveCapacity(r.count)
        switch f.type {
        case .list, .largeList, .map:
            guard let childField = f.children.first, let childLayout = layout.children.first else { return Array(repeating: nil, count: r.count) }
            let off = try offsets(layout.buffers[1], r, wide: f.type == .largeList, budget: &budget)
            for k in 0..<r.count {
                if let nulls, nulls[k] { out.append(nil); continue }
                let total = off[k + 1] - off[k]
                let range = off[k]..<(off[k] + min(total, cap))
                if f.type == .map, childField.children.count == 2, childLayout.children.count == 2 {
                    let keys = try childTexts(childField.children[0], childLayout.children[0], range)
                    let vals = try childTexts(childField.children[1], childLayout.children[1], range)
                    let pairs = zip(keys, vals).map { "\($0): \($1)" }
                    out.append(cut("{" + pairs.joined(separator: ", ") + (total > cap ? ", …" : "") + "}"))
                } else {
                    let items = try childTexts(childField, childLayout, range)
                    out.append(cut("[" + items.joined(separator: ", ") + (total > cap ? ", …" : "") + "]"))
                }
            }
        case .fixedSizeList(let size):
            guard let childField = f.children.first, let childLayout = layout.children.first else { return Array(repeating: nil, count: r.count) }
            for (k, row) in r.enumerated() {
                if let nulls, nulls[k] { out.append(nil); continue }
                let (start, overflow) = row.multipliedReportingOverflow(by: size)
                guard !overflow else { throw ColumnarError.malformed(String(localized: "a fixed-size list too large to address", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                let items = try childTexts(childField, childLayout, start..<(start + min(size, cap)))
                out.append(cut("[" + items.joined(separator: ", ") + (size > cap ? ", …" : "") + "]"))
            }
        case .structure:
            let shown = Array(zip(f.children, layout.children).prefix(cap))
            let columns = try shown.map { try childTexts($0.0, $0.1, r) }
            for k in 0..<r.count {
                if let nulls, nulls[k] { out.append(nil); continue }
                let parts = shown.indices.map { c in "\(shown[c].0.name): \(k < columns[c].count ? columns[c][k] : "null")" }
                out.append(cut("{" + parts.joined(separator: ", ") + (f.children.count > cap ? ", …" : "") + "}"))
            }
        default:
            return Array(repeating: "…", count: r.count)
        }
        return out
    }
}

/// The rows of an Arrow file, across its record batches.
final class ArrowTable: ColumnarTable, @unchecked Sendable {
    let source: any ByteSource
    let fields: [ArrowField]
    let batches: [ArrowFile.ArrowBatchLocation]
    let dictionaries: [Int64: ColumnVector]
    let version: Int16
    let limits: ColumnarLimits
    let columns: [ColumnarColumn]
    let rowCount: Int
    let chunks: [ColumnarChunk]
    private let starts: [Int]
    private let lock = NSLock()
    private var cache: [(index: Int, batch: ArrowBatch)] = []
    private var warningList: [String] = []

    init(source: any ByteSource, fields: [ArrowField], batches: [ArrowFile.ArrowBatchLocation], dictionaries: [Int64: ColumnVector],
         version: Int16, limits: ColumnarLimits) {
        self.source = source
        self.fields = fields
        self.batches = batches
        self.dictionaries = dictionaries
        self.version = version
        self.limits = limits
        columns = fields.map(ArrowSchemaReader.column)
        var starts: [Int] = [], total = 0
        for b in batches { starts.append(total); total += b.rows }
        self.starts = starts
        rowCount = total
        chunks = batches.map { ColumnarChunk(rows: $0.rows, bytes: $0.bodyLength) }
    }

    var warnings: [String] { lock.withLock { warningList } }

    var compressionName: String {
        guard !batches.isEmpty else { return String(localized: "none", bundle: .module, comment: "Compression fact value: the data is not compressed.") }
        let names = Set([0, batches.count - 1].compactMap { try? batch($0).codec }.map { $0 == .zstd ? "ZSTD" : "LZ4_FRAME" })
        return names.isEmpty ? String(localized: "none", bundle: .module, comment: "Compression fact value: the data is not compressed.") : names.sorted().joined(separator: ", ")
    }

    func batch(_ index: Int) throws -> ArrowBatch {
        if let hit = cache.first(where: { $0.index == index }) { return hit.batch }
        let location = batches[index]
        let bytes = try source.read(at: location.metadataOffset, count: location.metadataLength)
        guard bytes.count == location.metadataLength else { throw ColumnarError.truncated(String(localized: "a record batch header ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        guard let header = try FlatTable.root(bytes).table(2) else { throw ColumnarError.malformed(String(localized: "a record batch without a header", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let batch = try ArrowBatch(table: header, bodyOffset: location.bodyOffset, bodyLength: location.bodyLength, source: source,
                                   fields: fields, version: version, limits: limits)
        cache.append((index, batch))
        if cache.count > 2 { cache.removeFirst() }
        return batch
    }

    func read(rows wanted: Range<Int>, isCancelled: @Sendable () -> Bool) throws -> ColumnarWindow {
        let lower = max(0, min(wanted.lowerBound, rowCount))
        let upper = max(lower, min(wanted.upperBound, rowCount, lower + limits.maxWindowRows))
        lock.lock()
        defer { lock.unlock() }
        var vectors: [ColumnVector]?
        var budget = limits.maxWindowBytes
        var index = ParquetTable.groupIndex(of: lower, starts: starts)
        while index < starts.count, starts[index] < upper {
            let a = max(lower, starts[index]) - starts[index]
            let b = min(upper, starts[index] + batches[index].rows) - starts[index]
            if b > a {
                var part: [ColumnVector] = []
                let batch: ArrowBatch?
                do { batch = try self.batch(index) } catch {
                    let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    warn(String(localized: "Record batch \(index + 1) could not be read. \(reason)", bundle: .module, comment: "Warning shown above an Arrow table; the arguments are a 1-based batch number and the error sentence."))
                    batch = nil
                }
                for c in fields.indices {
                    if isCancelled() { throw ColumnarError.cancelled }
                    guard let batch, !columns[c].isOmitted else { part.append(.nulls(b - a)); continue }
                    do {
                        part.append(try batch.column(c, rows: a..<b, dictionaries: dictionaries, budget: &budget))
                    } catch {
                        let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                        warn(String(localized: "Column \(fields[c].name) in record batch \(index + 1) could not be read. \(reason)", bundle: .module, comment: "Warning shown above an Arrow table; the arguments are a column name, a 1-based batch number and the error sentence."))
                        part.append(.nulls(b - a))
                    }
                }
                vectors = vectors.map { zip($0, part).map { $0.appending($1) } } ?? part
            }
            index += 1
        }
        return ColumnarWindow(start: lower, count: upper - lower, columns: vectors ?? fields.map { _ in .nulls(0) })
    }

    private func warn(_ text: String) {
        if !warningList.contains(text), warningList.count < 100 { warningList.append(text) }
    }
}
