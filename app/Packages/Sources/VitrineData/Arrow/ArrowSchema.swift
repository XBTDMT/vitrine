import Foundation

/// Arrow's logical types and fields as `format/Schema.fbs` defines them (the `Type` union and its tables, `Field`,
/// `DictionaryEncoding`, `Schema`), with the buffer layout each type has in a record batch (the Arrow Columnar
/// Format, "Buffer Listing for Each Layout"). roadmap: S-21
indirect enum ArrowType: Sendable, Equatable {
    case null
    case int(bits: Int, signed: Bool)
    /// 0 half, 1 single, 2 double.
    case float(precision: Int)
    case binary, utf8, largeBinary, largeUtf8, binaryView, utf8View
    case bool
    case decimal(precision: Int, scale: Int, bits: Int)
    /// Day (0) or millisecond (1).
    case date(unit: Int)
    case time(unit: ColumnarTimeUnit, bits: Int)
    case timestamp(unit: ColumnarTimeUnit, zone: String?)
    /// 0 year-month, 1 day-time, 2 month-day-nano.
    case interval(unit: Int)
    case duration(unit: ColumnarTimeUnit)
    case fixedSizeBinary(width: Int)
    case list, largeList, listView, largeListView
    case fixedSizeList(size: Int)
    case structure
    case map
    /// 0 sparse, 1 dense.
    case union(mode: Int)
    case runEndEncoded
    case unknown(Int)

    func name(children: [ArrowField]) -> String {
        func child(_ i: Int) -> String { i < children.count ? children[i].typeName : "?" }
        switch self {
        case .null: return "Null"
        case .int(let b, let s): return "\(s ? "Int" : "UInt")\(b)"
        case .float(let p): return ["Float16", "Float32", "Float64"][min(max(p, 0), 2)]
        case .binary: return "Binary"
        case .utf8: return "Utf8"
        case .largeBinary: return "LargeBinary"
        case .largeUtf8: return "LargeUtf8"
        case .binaryView: return "BinaryView"
        case .utf8View: return "Utf8View"
        case .bool: return "Bool"
        case .decimal(let p, let s, let b): return "Decimal\(b)(\(p), \(s))"
        case .date(let u): return u == 0 ? "Date32" : "Date64"
        case .time(let u, let b): return "Time\(b)(\(u.name))"
        case .timestamp(let u, let z): return "Timestamp(\(u.name)\(z.map { ", \($0)" } ?? ""))"
        case .interval(let u): return ["Interval(year-month)", "Interval(day-time)", "Interval(month-day-nano)"][min(max(u, 0), 2)]
        case .duration(let u): return "Duration(\(u.name))"
        case .fixedSizeBinary(let w): return "FixedSizeBinary(\(w))"
        case .list: return "List<\(child(0))>"
        case .largeList: return "LargeList<\(child(0))>"
        case .listView: return "ListView<\(child(0))>"
        case .largeListView: return "LargeListView<\(child(0))>"
        case .fixedSizeList(let n): return "FixedSizeList<\(child(0)), \(n)>"
        case .structure: return "Struct<" + children.map { "\($0.name): \($0.typeName)" }.joined(separator: ", ") + ">"
        case .map: return "Map<\(children.first?.children.first?.typeName ?? "?"), \(children.first.flatMap { $0.children.count > 1 ? $0.children[1].typeName : nil } ?? "?")>"
        case .union(let m): return m == 0 ? "SparseUnion" : "DenseUnion"
        case .runEndEncoded: return "RunEndEncoded<\(children.count > 1 ? children[1].typeName : "?")>"
        case .unknown(let t): return "type \(t)"
        }
    }
}

struct ArrowDictionaryEncoding: Sendable, Equatable {
    var id: Int64
    var indexBits: Int
    var indexSigned: Bool
}

struct ArrowField: Sendable, Equatable {
    var name: String
    var nullable: Bool
    var type: ArrowType
    var children: [ArrowField]
    var dictionary: ArrowDictionaryEncoding?
    var extensionName: String?

    var typeName: String {
        let value = type.name(children: children)
        guard let d = dictionary else { return value }
        return "Dictionary<\(d.indexSigned ? "Int" : "UInt")\(d.indexBits), \(value)>"
    }
}

enum ArrowSchemaReader {
    static func unit(_ v: Int16) -> ColumnarTimeUnit {
        switch v { case 0: .seconds; case 1: .millis; case 2: .micros; default: .nanos }
    }

    /// The fields of a Schema table.
    static func fields(_ schema: FlatTable, limits: ColumnarLimits) throws -> [ArrowField] {
        guard try schema.int16(0) == 0 else { throw ColumnarError.unsupported(String(localized: "big-endian Arrow data", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var count = 0
        return try schema.tables(1).map { try field($0, depth: 1, count: &count, limits: limits) }
    }

    static func field(_ t: FlatTable, depth: Int, count: inout Int, limits: ColumnarLimits) throws -> ArrowField {
        guard depth <= limits.maxDepth else { throw ColumnarError.malformed(String(localized: "the schema is nested more than \(limits.maxDepth) deep", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        count += 1
        guard count <= limits.maxColumns * 4 else { throw ColumnarError.tooLarge(String(localized: "more than \(limits.maxColumns * 4) fields", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let name = try t.string(0) ?? ""
        let nullable = try t.bool(1)
        let typeType = Int(try t.uint8(2))
        let typeTable = try t.table(3)
        let children = try t.tables(5).map { try field($0, depth: depth + 1, count: &count, limits: limits) }
        var dictionary: ArrowDictionaryEncoding?
        if let d = try t.table(4) {
            var bits = 32, signed = true
            if let index = try d.table(1) { bits = Int(try index.int32(0)); signed = try index.bool(1) }
            guard [8, 16, 32, 64].contains(bits) else { throw ColumnarError.malformed(String(localized: "a dictionary index of \(bits) bits", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            dictionary = ArrowDictionaryEncoding(id: try d.int64(0), indexBits: bits, indexSigned: signed)
        }
        var extensionName: String?
        for kv in try t.tables(6) where try kv.string(0) == "ARROW:extension:name" { extensionName = try kv.string(1) }
        let type = try self.type(typeType, typeTable)
        return ArrowField(name: name, nullable: nullable, type: type, children: children, dictionary: dictionary, extensionName: extensionName)
    }

    static func type(_ kind: Int, _ t: FlatTable?) throws -> ArrowType {
        func i16(_ slot: Int, _ d: Int16) throws -> Int16 { try t?.int16(slot, default: d) ?? d }
        func i32(_ slot: Int, _ d: Int32) throws -> Int32 { try t?.int32(slot, default: d) ?? d }
        switch kind {
        case 1: return .null
        case 2:
            let bits = Int(try i32(0, 32))
            guard [8, 16, 32, 64].contains(bits) else { throw ColumnarError.malformed(String(localized: "an Int of \(bits) bits", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            return .int(bits: bits, signed: try t?.bool(1) ?? false)
        case 3: return .float(precision: Int(try i16(0, 0)))
        case 4: return .binary
        case 5: return .utf8
        case 6: return .bool
        case 7:
            let bits = Int(try i32(2, 128))
            guard [32, 64, 128, 256].contains(bits) else { throw ColumnarError.malformed(String(localized: "a Decimal of \(bits) bits", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            return .decimal(precision: Int(try i32(0, 0)), scale: Int(try i32(1, 0)), bits: bits)
        case 8: return .date(unit: Int(try i16(0, 1)))
        case 9:
            let bits = Int(try i32(1, 32))
            guard bits == 32 || bits == 64 else { throw ColumnarError.malformed(String(localized: "a Time of \(bits) bits", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            return .time(unit: unit(try i16(0, 1)), bits: bits)
        case 10: return .timestamp(unit: unit(try i16(0, 0)), zone: try t?.string(1))
        case 11: return .interval(unit: Int(try i16(0, 0)))
        case 12: return .list
        case 13: return .structure
        case 14: return .union(mode: Int(try i16(0, 0)))
        case 15:
            let w = Int(try i32(0, 0))
            guard w >= 0 else { throw ColumnarError.malformed(String(localized: "a FixedSizeBinary of width \(w)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            return .fixedSizeBinary(width: w)
        case 16:
            let n = Int(try i32(0, 0))
            guard n >= 0 else { throw ColumnarError.malformed(String(localized: "a FixedSizeList of size \(n)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            return .fixedSizeList(size: n)
        case 17: return .map
        case 18: return .duration(unit: unit(try i16(0, 1)))
        case 19: return .largeBinary
        case 20: return .largeUtf8
        case 21: return .largeList
        case 22: return .runEndEncoded
        case 23: return .binaryView
        case 24: return .utf8View
        case 25: return .listView
        case 26: return .largeListView
        default: return .unknown(kind)
        }
    }

    /// How a top-level column reads.
    static func column(_ f: ArrowField) -> ColumnarColumn {
        var note: String?
        var omitted = false
        let kind: ColumnarKind
        switch f.type {
        case .null: kind = .null
        case .int(let b, let s): kind = .integer(bits: b, signed: s)
        case .float(let p): kind = .float(bits: [16, 32, 64][min(max(p, 0), 2)])
        case .utf8, .largeUtf8, .utf8View: kind = .string
        case .binary, .largeBinary, .binaryView: kind = .binary
        case .fixedSizeBinary(let w): kind = (w == 16 && f.extensionName == "arrow.uuid") ? .uuid : .binary
        case .bool: kind = .boolean
        case .decimal(let p, let s, _):
            kind = .decimal(precision: p, scale: s)
            if s < 0 || s > 76 || p < 0 || p > 76 { omitted = true; note = String(localized: "decimal with precision \(p) and scale \(s): not shown", bundle: .module, comment: "Note on a decimal column the preview does not show.") }
        case .date(let u): kind = u == 0 ? .date : .dateMillis
        case .time(let u, _): kind = .time(u)
        case .timestamp(let u, let z): kind = .timestamp(u, zone: z)
        case .duration(let u): kind = .duration(u)
        case .interval: kind = .string
        case .list, .largeList, .fixedSizeList, .structure, .map:
            kind = .nested; note = String(localized: "nested: each value shown as text", bundle: .module, comment: "Note on a nested Arrow column.")
        case .union, .runEndEncoded, .listView, .largeListView, .unknown:
            kind = .nested; omitted = true; note = String(localized: "\(f.type.name(children: f.children)) values: not shown", bundle: .module, comment: "Note on an Arrow column the preview does not show; the argument is an Arrow type name.")
        }
        return ColumnarColumn(name: f.name, kind: kind, typeDescription: f.typeName, note: note, isOmitted: omitted, nullable: f.nullable)
    }
}
