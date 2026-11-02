import Foundation

/// Values of one physical type as stored, before they are given their logical meaning.
enum ParquetPhysicalValues {
    case bools([Bool])
    case int32([Int32])
    case int64([Int64])
    case floats([Float])
    case doubles([Double])
    case bytes([[UInt8]])
}

/// Turning a page's value bytes into a column's values (Encodings.md for the encodings, LogicalTypes.md for what
/// the values mean), and a repeated column's levels into one list per row. roadmap: S-21
enum ParquetValues {
    // MARK: Encodings

    static func decode(_ reader: inout ParquetBytes, encoding: Int32, leaf: ParquetLeaf, count: Int,
                       dictionary: ColumnVector?, limits: ColumnarLimits) throws -> ColumnVector.Storage {
        switch encoding {
        case 0:
            return storage(try plain(&reader, leaf: leaf, count: count), leaf: leaf, limits: limits)
        case 2, 8:
            guard let dictionary else { throw ColumnarError.malformed(String(localized: "a dictionary-encoded page without a dictionary page", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            if count == 0 { return empty(dictionary.storage) }
            let at = try reader.take(1, String(localized: "the dictionary index width", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'.")).lowerBound
            let indices = try ParquetDecode.hybrid(&reader, width: Int(reader.bytes[at]), count: count)
            return try gather(dictionary.storage, indices: indices)
        case 3:
            guard leaf.physical == .boolean else { throw ColumnarError.unsupported(String(localized: "RLE values for \(leaf.physical.name)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let length = Int(try reader.u32())
            let r = try reader.take(length, String(localized: "RLE booleans", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
            var sub = ParquetBytes(reader.bytes, start: r.lowerBound, end: r.upperBound)
            return .bools(try ParquetDecode.hybrid(&sub, width: 1, count: count).map { $0 == 1 })
        case 5:
            let values = try ParquetDecode.deltaBinaryPacked(&reader, maxCount: max(count, 1))
            guard values.count >= count else { throw ColumnarError.truncated(String(localized: "DELTA_BINARY_PACKED holds fewer values than the page", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            switch leaf.physical {
            case .int32: return storage(.int32(values.prefix(count).map { Int32(truncatingIfNeeded: $0) }), leaf: leaf, limits: limits)
            case .int64: return storage(.int64(Array(values.prefix(count))), leaf: leaf, limits: limits)
            default: throw ColumnarError.unsupported(String(localized: "DELTA_BINARY_PACKED values for \(leaf.physical.name)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
            }
        case 6:
            guard leaf.physical == .byteArray else { throw ColumnarError.unsupported(String(localized: "DELTA_LENGTH_BYTE_ARRAY for \(leaf.physical.name)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            return storage(.bytes(try ParquetDecode.deltaLengthByteArray(&reader, count: count)), leaf: leaf, limits: limits)
        case 7:
            guard leaf.physical == .byteArray || leaf.physical == .fixedLenByteArray else {
                throw ColumnarError.unsupported(String(localized: "DELTA_BYTE_ARRAY for \(leaf.physical.name)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
            }
            return storage(.bytes(try ParquetDecode.deltaByteArray(&reader, count: count, maxBytes: limits.maxPageBytes)), leaf: leaf, limits: limits)
        case 9:
            return storage(try byteStreamSplit(&reader, leaf: leaf, count: count), leaf: leaf, limits: limits)
        default:
            throw ColumnarError.unsupported(String(localized: "values in \(ParquetThrift.encodingName(encoding))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
    }

    /// PLAIN: booleans bit-packed, fixed-width little-endian numbers, BYTE_ARRAY as a 4-byte length and the bytes,
    /// FIXED_LEN_BYTE_ARRAY as `type_length` bytes, INT96 as 12 bytes.
    static func plain(_ reader: inout ParquetBytes, leaf: ParquetLeaf, count: Int) throws -> ParquetPhysicalValues {
        let b = reader.bytes
        switch leaf.physical {
        case .boolean:
            let r = try reader.take((count + 7) / 8, String(localized: "PLAIN booleans", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
            return .bools((0..<count).map { b[r.lowerBound + $0 >> 3] >> UInt8($0 & 7) & 1 == 1 })
        case .int32:
            let r = try reader.take(count * 4, String(localized: "PLAIN INT32 values", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
            return .int32((0..<count).map { Int32(bitPattern: UInt32(truncatingIfNeeded: reader.le(r.lowerBound + 4 * $0, 4))) })
        case .int64:
            let r = try reader.take(count * 8, String(localized: "PLAIN INT64 values", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
            return .int64((0..<count).map { Int64(bitPattern: reader.le(r.lowerBound + 8 * $0, 8)) })
        case .int96:
            let r = try reader.take(count * 12, String(localized: "PLAIN INT96 values", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
            return .int64((0..<count).map { k in
                let at = r.lowerBound + 12 * k
                let nanos = Int64(bitPattern: reader.le(at, 8))
                let julian = Int64(reader.le(at + 8, 4))
                let (dayNanos, overflow) = (julian - 2_440_588).multipliedReportingOverflow(by: 86_400_000_000_000)
                return overflow ? 0 : dayNanos &+ nanos
            })
        case .float:
            let r = try reader.take(count * 4, String(localized: "PLAIN FLOAT values", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
            return .floats((0..<count).map { Float(bitPattern: UInt32(truncatingIfNeeded: reader.le(r.lowerBound + 4 * $0, 4))) })
        case .double:
            let r = try reader.take(count * 8, String(localized: "PLAIN DOUBLE values", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
            return .doubles((0..<count).map { Double(bitPattern: reader.le(r.lowerBound + 8 * $0, 8)) })
        case .byteArray:
            var out: [[UInt8]] = []
            out.reserveCapacity(min(count, reader.remaining / 4 + 1))
            for _ in 0..<count {
                let n = Int(try reader.u32())
                let r = try reader.take(n, String(localized: "a PLAIN byte array", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
                out.append(Array(b[r]))
            }
            return .bytes(out)
        case .fixedLenByteArray:
            let w = Int(leaf.element.typeLength)
            guard w > 0 else { throw ColumnarError.malformed(String(localized: "a FIXED_LEN_BYTE_ARRAY of length \(w)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let r = try reader.take(count * w, String(localized: "PLAIN fixed-length values", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
            return .bytes((0..<count).map { Array(b[(r.lowerBound + $0 * w)..<(r.lowerBound + ($0 + 1) * w)]) })
        }
    }

    /// BYTE_STREAM_SPLIT: byte k of every value in stream k.
    static func byteStreamSplit(_ reader: inout ParquetBytes, leaf: ParquetLeaf, count: Int) throws -> ParquetPhysicalValues {
        let width: Int
        switch leaf.physical {
        case .float, .int32: width = 4
        case .double, .int64: width = 8
        case .fixedLenByteArray: width = Int(leaf.element.typeLength)
        default: throw ColumnarError.unsupported(String(localized: "BYTE_STREAM_SPLIT for \(leaf.physical.name)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        guard width > 0 else { throw ColumnarError.malformed(String(localized: "a value width of \(width)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let r = try reader.take(count * width, String(localized: "BYTE_STREAM_SPLIT values", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
        let b = reader.bytes
        let values: [[UInt8]] = (0..<count).map { i in (0..<width).map { k in b[r.lowerBound + k * count + i] } }
        func le(_ v: [UInt8]) -> UInt64 { v.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }
        switch leaf.physical {
        case .float: return .floats(values.map { Float(bitPattern: UInt32(truncatingIfNeeded: le($0))) })
        case .int32: return .int32(values.map { Int32(bitPattern: UInt32(truncatingIfNeeded: le($0))) })
        case .double: return .doubles(values.map { Double(bitPattern: le($0)) })
        case .int64: return .int64(values.map { Int64(bitPattern: le($0)) })
        default: return .bytes(values)
        }
    }

    // MARK: Meaning

    /// The column's storage for values of its physical type, read as its kind says.
    static func storage(_ values: ParquetPhysicalValues, leaf: ParquetLeaf, limits: ColumnarLimits) -> ColumnVector.Storage {
        let kind = leaf.valueKind
        switch values {
        case .bools(let v): return .bools(v)
        case .int32(let v):
            if case .integer(let bits, false) = kind, bits <= 32 { return .ints(v.map { Int64(UInt32(bitPattern: $0)) }) }
            return .ints(v.map(Int64.init))
        case .int64(let v): return .ints(v)
        case .floats(let v): return .doubles(v.map(Double.init))
        case .doubles(let v): return .doubles(v)
        case .bytes(let v):
            switch kind {
            case .string:
                if leaf.physical == .fixedLenByteArray, leaf.element.typeLength == 12 {
                    // INTERVAL: months, days and milliseconds, each a little-endian unsigned 32-bit number.
                    return .strings(v.map { b in
                        func u(_ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
                        return String(localized: "\(u(0)) months, \(u(4)) days, \(u(8)) ms", bundle: .module, comment: "An interval value in a table cell: months, days and milliseconds.")
                    })
                }
                return .strings(v.map { String(decoding: $0, as: UTF8.self) })
            case .decimal(_, let scale):
                if v.allSatisfy({ $0.count <= 8 }) { return .ints(v.map(signExtended)) }
                return .cells(v.map { b in
                    let (digits, negative) = ColumnarText.bigEndianInteger(b)
                    let text = ColumnarText.decimal(unscaled: digits, negative: negative, scale: scale)
                    return .text(text, number: Double(text))
                })
            case .float(16): return .doubles(v.map { $0.count == 2 ? half(UInt16($0[0]) | UInt16($0[1]) << 8) : .nan })
            default: return .bytes(v)
            }
        }
    }

    /// A big-endian two's complement value of up to 8 bytes as an Int64.
    static func signExtended(_ b: [UInt8]) -> Int64 {
        guard let first = b.first else { return 0 }
        var v: UInt64 = first & 0x80 != 0 ? .max : 0
        for byte in b { v = v << 8 | UInt64(byte) }
        return Int64(bitPattern: v)
    }

    /// IEEE 754 half precision.
    static func half(_ h: UInt16) -> Double {
        let sign: Double = h & 0x8000 != 0 ? -1 : 1
        let exponent = Int((h >> 10) & 0x1F), fraction = Double(h & 0x3FF)
        if exponent == 0 { return sign * fraction * pow(2, -24) }
        if exponent == 31 { return fraction == 0 ? sign * .infinity : .nan }
        return sign * (1 + fraction / 1024) * pow(2, Double(exponent - 15))
    }

    static func empty(_ storage: ColumnVector.Storage) -> ColumnVector.Storage {
        switch storage {
        case .bools: .bools([]); case .ints: .ints([]); case .doubles: .doubles([]); case .strings: .strings([])
        case .bytes: .bytes([]); case .cells: .cells([])
        }
    }

    static func gather(_ storage: ColumnVector.Storage, indices: [UInt64]) throws -> ColumnVector.Storage {
        func pick<T>(_ v: [T]) throws -> [T] {
            try indices.map { i in
                guard i < UInt64(v.count) else { throw ColumnarError.malformed(String(localized: "a dictionary index \(i) past its \(v.count)-entry dictionary", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                return v[Int(i)]
            }
        }
        switch storage {
        case .bools(let v): return .bools(try pick(v))
        case .ints(let v): return .ints(try pick(v))
        case .doubles(let v): return .doubles(try pick(v))
        case .strings(let v): return .strings(try pick(v))
        case .bytes(let v): return .bytes(try pick(v))
        case .cells(let v): return .cells(try pick(v))
        }
    }

    /// Present values spread over the rows: a row that is not present is null, holding a placeholder.
    static func scatter(_ storage: ColumnVector.Storage, present: [Bool]) -> ColumnVector {
        let nulls = present.map { !$0 }
        func spread<T>(_ v: [T], _ blank: T) -> [T] {
            var out: [T] = []
            out.reserveCapacity(present.count)
            var k = 0
            for p in present {
                if p, k < v.count { out.append(v[k]); k += 1 } else { out.append(blank) }
            }
            return out
        }
        switch storage {
        case .bools(let v): return ColumnVector(storage: .bools(spread(v, false)), nulls: nulls)
        case .ints(let v): return ColumnVector(storage: .ints(spread(v, 0)), nulls: nulls)
        case .doubles(let v): return ColumnVector(storage: .doubles(spread(v, 0)), nulls: nulls)
        case .strings(let v): return ColumnVector(storage: .strings(spread(v, "")), nulls: nulls)
        case .bytes(let v): return ColumnVector(storage: .bytes(spread(v, [])), nulls: nulls)
        case .cells(let v): return ColumnVector(storage: .cells(spread(v, .null)), nulls: nulls)
        }
    }

    /// A one-level repeated column as one list per row (Dremel levels, as the format's README describes them): a
    /// repetition level of 0 starts a row; a definition level at the maximum is a value, at or above the repeated
    /// node's level a null element, one below it an empty list, lower a null list.
    static func lists(_ storage: ColumnVector.Storage, repetition: [UInt64], definition: [UInt64], leaf: ParquetLeaf,
                      limits: ColumnarLimits) -> ColumnVector {
        let values = ColumnVector(storage: storage)
        let maxDef = UInt64(leaf.maxDefinition), repDef = UInt64(leaf.repeatedDefinition)
        var rows: [ColumnarCell] = []
        var items: [String] = []
        var itemCount = 0
        var isNull = false
        var started = false
        var v = 0
        func finish() {
            guard started else { return }
            if isNull { rows.append(.null); return }
            var text = "[" + items.joined(separator: ", ") + (itemCount > items.count ? ", …" : "") + "]"
            if text.count > limits.maxNestedText { text = String(text.prefix(limits.maxNestedText)) + "…" }
            rows.append(.text(text, number: nil))
        }
        for i in 0..<repetition.count {
            if repetition[i] == 0 {
                finish()
                started = true; isNull = false; items.removeAll(keepingCapacity: true); itemCount = 0
            }
            let d = i < definition.count ? definition[i] : maxDef
            if d == maxDef {
                let cell = values[v]
                v += 1
                itemCount += 1
                if items.count < limits.maxNestedElements { items.append(element(cell, kind: leaf.valueKind)) }
            } else if d >= repDef {
                itemCount += 1
                if items.count < limits.maxNestedElements { items.append("null") }
            } else if repDef > 0, d == repDef - 1 {
                continue   // an empty list
            } else {
                isNull = true
            }
        }
        finish()
        return ColumnVector(storage: .cells(rows))
    }

    /// One element of a nested value: strings quoted, the rest as their cells read.
    static func element(_ cell: ColumnarCell, kind: ColumnarKind) -> String {
        if case .string(let s) = cell { return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        if cell.isNull { return "null" }
        return ColumnarText.text(cell, kind: kind)
    }

    // MARK: Statistics

    static func legacyStatisticsUsable(_ leaf: ParquetLeaf) -> Bool {
        switch leaf.physical {
        case .boolean, .int32, .int64, .float, .double:
            if case .integer(_, false) = leaf.valueKind { return false }
            if case .decimal = leaf.valueKind { return false }
            return true
        default: return false
        }
    }

    /// A statistics value (stored PLAIN without a length prefix) as a cell.
    static func statistic(_ bytes: [UInt8], leaf: ParquetLeaf) -> ColumnarCell? {
        var reader = ParquetBytes(bytes)
        switch leaf.physical {
        case .byteArray, .fixedLenByteArray:
            if leaf.physical == .fixedLenByteArray, bytes.count != Int(leaf.element.typeLength) { return nil }
            let s = storage(.bytes([bytes]), leaf: leaf, limits: ColumnarLimits())
            return ColumnVector(storage: s)[0]
        case .int96: return nil
        default:
            guard let values = try? plain(&reader, leaf: leaf, count: 1) else { return nil }
            let cell = ColumnVector(storage: storage(values, leaf: leaf, limits: ColumnarLimits()))[0]
            if case .double(let d) = cell, d.isNaN { return nil }
            return cell
        }
    }

    static func less(_ a: ColumnarCell, _ b: ColumnarCell, kind: ColumnarKind) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)):
            if case .integer(64, false) = kind { return UInt64(bitPattern: x) < UInt64(bitPattern: y) }
            return x < y
        case (.double(let x), .double(let y)): return x < y
        case (.bool(let x), .bool(let y)): return !x && y
        case (.string(let x), .string(let y)): return Array(x.utf8).lexicographicallyPrecedes(Array(y.utf8))
        case (.bytes(let x), .bytes(let y)): return x.lexicographicallyPrecedes(y)
        case (.text(_, let x?), .text(_, let y?)): return x < y
        default: return false
        }
    }
}
