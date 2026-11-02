import Foundation

/// The parts of Parquet's footer the preview uses, read from the Thrift structures in apache/parquet-format's
/// `src/main/thrift/parquet.thrift` (FileMetaData, SchemaElement, LogicalType, RowGroup, ColumnChunk,
/// ColumnMetaData, Statistics, PageHeader and its three page kinds). Field ids are the ones that file assigns;
/// unknown fields are skipped, so newer writers still read. roadmap: S-21
enum ParquetPhysicalType: Int32, Sendable {
    case boolean = 0, int32 = 1, int64 = 2, int96 = 3, float = 4, double = 5, byteArray = 6, fixedLenByteArray = 7

    var name: String {
        switch self {
        case .boolean: "BOOLEAN"; case .int32: "INT32"; case .int64: "INT64"; case .int96: "INT96"
        case .float: "FLOAT"; case .double: "DOUBLE"; case .byteArray: "BYTE_ARRAY"; case .fixedLenByteArray: "FIXED_LEN_BYTE_ARRAY"
        }
    }
}

enum ParquetRepetition: Int32, Sendable { case required = 0, optional = 1, repeated = 2 }

/// The LogicalType union (parquet.thrift), with the legacy ConvertedType folded in where the logical type is absent.
enum ParquetLogicalType: Sendable, Equatable {
    case string, map, list, enumeration, decimal(precision: Int, scale: Int), date
    case time(utc: Bool, unit: ColumnarTimeUnit), timestamp(utc: Bool, unit: ColumnarTimeUnit)
    case integer(bits: Int, signed: Bool), unknown, json, bson, uuid, float16, variant, geometry, geography, interval

    var name: String {
        switch self {
        case .string: "STRING"; case .map: "MAP"; case .list: "LIST"; case .enumeration: "ENUM"
        case .decimal(let p, let s): "DECIMAL(\(p), \(s))"; case .date: "DATE"
        case .time(let utc, let u): "TIME(\(u.name)\(utc ? ", UTC" : ""))"
        case .timestamp(let utc, let u): "TIMESTAMP(\(u.name)\(utc ? ", UTC" : ""))"
        case .integer(let b, let s): "\(s ? "INT" : "UINT")(\(b))"; case .unknown: "UNKNOWN"; case .json: "JSON"
        case .bson: "BSON"; case .uuid: "UUID"; case .float16: "FLOAT16"; case .variant: "VARIANT"
        case .geometry: "GEOMETRY"; case .geography: "GEOGRAPHY"; case .interval: "INTERVAL"
        }
    }
}

struct ParquetSchemaElement: Sendable {
    var type: ParquetPhysicalType?
    var typeLength: Int32 = 0
    var repetition: ParquetRepetition?
    var name = ""
    var numChildren: Int32?
    var convertedType: Int32?
    var scale: Int32?
    var precision: Int32?
    var logical: ParquetLogicalType?
}

struct ParquetStatistics: Sendable {
    var max: [UInt8]?
    var min: [UInt8]?
    var nullCount: Int64?
    var distinctCount: Int64?
    var maxValue: [UInt8]?
    var minValue: [UInt8]?
}

struct ParquetColumnMeta: Sendable {
    var type: ParquetPhysicalType?
    var encodings: [Int32] = []
    var path: [String] = []
    var codec: Int32 = 0
    var numValues: Int64 = 0
    var totalUncompressed: Int64 = 0
    var totalCompressed: Int64 = 0
    var dataPageOffset: Int64 = 0
    var dictionaryPageOffset: Int64?
    var statistics: ParquetStatistics?
}

struct ParquetColumnChunk: Sendable {
    var filePath: String?
    var meta: ParquetColumnMeta?
    var encrypted = false
}

struct ParquetRowGroup: Sendable {
    var columns: [ParquetColumnChunk] = []
    var totalByteSize: Int64 = 0
    var numRows: Int64 = 0
    var totalCompressedSize: Int64?
}

struct ParquetFileMetadata: Sendable {
    var version: Int32 = 0
    var schema: [ParquetSchemaElement] = []
    var numRows: Int64 = 0
    var rowGroups: [ParquetRowGroup] = []
    var keyValues: [(key: String, value: String?)] = []
    var createdBy: String?
    var encryptedFooter = false
}

enum ParquetPageType: Int32 { case data = 0, index = 1, dictionary = 2, dataV2 = 3 }

struct ParquetPageHeader: Sendable {
    var type: Int32 = -1
    var uncompressedSize: Int32 = 0
    var compressedSize: Int32 = 0
    // DataPageHeader (v1)
    var numValues: Int32 = 0
    var encoding: Int32 = 0
    var definitionEncoding: Int32 = 3
    var repetitionEncoding: Int32 = 3
    // DictionaryPageHeader
    var dictionaryValues: Int32 = 0
    var dictionaryEncoding: Int32 = 0
    // DataPageHeaderV2
    var numNulls: Int32 = 0
    var numRows: Int32 = 0
    var definitionLength: Int32 = 0
    var repetitionLength: Int32 = 0
    var isCompressed = true
}

enum ParquetThrift {
    static func fileMetadata(_ r: inout ThriftReader) throws -> ParquetFileMetadata {
        var m = ParquetFileMetadata()
        try r.readStruct { r, id, t in
            switch (id, t) {
            case (1, .i32): m.version = try r.i32()
            case (2, .list): m.schema = try r.readList { try schemaElement(&$0) }
            case (3, .i64): m.numRows = try r.i64()
            case (4, .list): m.rowGroups = try r.readList { try rowGroup(&$0) }
            case (5, .list): m.keyValues = try r.readList { try keyValue(&$0) }
            case (6, .binary): m.createdBy = try r.string()
            case (8, .structure): m.encryptedFooter = true; try r.skip(t)
            default: try r.skip(t)
            }
        }
        return m
    }

    static func keyValue(_ r: inout ThriftReader) throws -> (key: String, value: String?) {
        var key = "", value: String?
        try r.readStruct { r, id, t in
            switch (id, t) {
            case (1, .binary): key = try r.string()
            case (2, .binary):
                // Values can be large (a serialised Arrow schema); only the start is kept.
                let bytes = try r.binary()
                value = String(decoding: bytes.prefix(4_096), as: UTF8.self)
            default: try r.skip(t)
            }
        }
        return (key, value)
    }

    static func schemaElement(_ r: inout ThriftReader) throws -> ParquetSchemaElement {
        var e = ParquetSchemaElement()
        try r.readStruct { r, id, t in
            switch (id, t) {
            case (1, .i32): e.type = ParquetPhysicalType(rawValue: try r.i32())
            case (2, .i32): e.typeLength = try r.i32()
            case (3, .i32): e.repetition = ParquetRepetition(rawValue: try r.i32())
            case (4, .binary): e.name = try r.string()
            case (5, .i32): e.numChildren = try r.i32()
            case (6, .i32): e.convertedType = try r.i32()
            case (7, .i32): e.scale = try r.i32()
            case (8, .i32): e.precision = try r.i32()
            case (10, .structure): e.logical = try logicalType(&r)
            default: try r.skip(t)
            }
        }
        return e
    }

    static func timeUnit(_ r: inout ThriftReader) throws -> ColumnarTimeUnit {
        var unit = ColumnarTimeUnit.millis
        try r.readStruct { r, id, t in
            switch id {
            case 1: unit = .millis
            case 2: unit = .micros
            case 3: unit = .nanos
            default: break
            }
            try r.skip(t)
        }
        return unit
    }

    static func logicalType(_ r: inout ThriftReader) throws -> ParquetLogicalType? {
        var result: ParquetLogicalType?
        try r.readStruct { r, id, t in
            guard t == .structure else { try r.skip(t); return }
            switch id {
            case 1: result = .string; try r.skip(t)
            case 2: result = .map; try r.skip(t)
            case 3: result = .list; try r.skip(t)
            case 4: result = .enumeration; try r.skip(t)
            case 5:
                var scale = 0, precision = 0
                try r.readStruct { r, id, t in
                    switch (id, t) {
                    case (1, .i32): scale = Int(try r.i32())
                    case (2, .i32): precision = Int(try r.i32())
                    default: try r.skip(t)
                    }
                }
                result = .decimal(precision: precision, scale: scale)
            case 6: result = .date; try r.skip(t)
            case 7, 8:
                var utc = false, unit = ColumnarTimeUnit.millis
                try r.readStruct { r, fid, ft in
                    switch (fid, ft) {
                    case (1, .boolTrue), (1, .boolFalse): utc = ThriftReader.bool(ft)
                    case (2, .structure): unit = try timeUnit(&r)
                    default: try r.skip(ft)
                    }
                }
                result = id == 7 ? .time(utc: utc, unit: unit) : .timestamp(utc: utc, unit: unit)
            case 10:
                var bits = 32, signed = true
                try r.readStruct { r, fid, ft in
                    switch (fid, ft) {
                    case (1, .byte): bits = Int(Int8(bitPattern: try r.byte()))
                    case (2, .boolTrue), (2, .boolFalse): signed = ThriftReader.bool(ft)
                    default: try r.skip(ft)
                    }
                }
                result = .integer(bits: bits, signed: signed)
            case 11: result = .unknown; try r.skip(t)
            case 12: result = .json; try r.skip(t)
            case 13: result = .bson; try r.skip(t)
            case 14: result = .uuid; try r.skip(t)
            case 15: result = .float16; try r.skip(t)
            case 16: result = .variant; try r.skip(t)
            case 17: result = .geometry; try r.skip(t)
            case 18: result = .geography; try r.skip(t)
            default: try r.skip(t)
            }
        }
        return result
    }

    static func rowGroup(_ r: inout ThriftReader) throws -> ParquetRowGroup {
        var g = ParquetRowGroup()
        try r.readStruct { r, id, t in
            switch (id, t) {
            case (1, .list): g.columns = try r.readList { try columnChunk(&$0) }
            case (2, .i64): g.totalByteSize = try r.i64()
            case (3, .i64): g.numRows = try r.i64()
            case (6, .i64): g.totalCompressedSize = try r.i64()
            default: try r.skip(t)
            }
        }
        return g
    }

    static func columnChunk(_ r: inout ThriftReader) throws -> ParquetColumnChunk {
        var c = ParquetColumnChunk()
        try r.readStruct { r, id, t in
            switch (id, t) {
            case (1, .binary): c.filePath = try r.string()
            case (3, .structure): c.meta = try columnMeta(&r)
            case (8, .structure), (9, .binary): c.encrypted = true; try r.skip(t)
            default: try r.skip(t)
            }
        }
        return c
    }

    static func columnMeta(_ r: inout ThriftReader) throws -> ParquetColumnMeta {
        var m = ParquetColumnMeta()
        try r.readStruct { r, id, t in
            switch (id, t) {
            case (1, .i32): m.type = ParquetPhysicalType(rawValue: try r.i32())
            case (2, .list): m.encodings = try r.readI32List()
            case (3, .list): m.path = try r.readStringList()
            case (4, .i32): m.codec = try r.i32()
            case (5, .i64): m.numValues = try r.i64()
            case (6, .i64): m.totalUncompressed = try r.i64()
            case (7, .i64): m.totalCompressed = try r.i64()
            case (9, .i64): m.dataPageOffset = try r.i64()
            case (11, .i64): m.dictionaryPageOffset = try r.i64()
            case (12, .structure): m.statistics = try statistics(&r)
            default: try r.skip(t)
            }
        }
        return m
    }

    static func statistics(_ r: inout ThriftReader) throws -> ParquetStatistics {
        var s = ParquetStatistics()
        try r.readStruct { r, id, t in
            switch (id, t) {
            case (1, .binary): s.max = Array(try r.binary().prefix(256))
            case (2, .binary): s.min = Array(try r.binary().prefix(256))
            case (3, .i64): s.nullCount = try r.i64()
            case (4, .i64): s.distinctCount = try r.i64()
            case (5, .binary): s.maxValue = Array(try r.binary().prefix(256))
            case (6, .binary): s.minValue = Array(try r.binary().prefix(256))
            default: try r.skip(t)
            }
        }
        return s
    }

    static func pageHeader(_ r: inout ThriftReader) throws -> ParquetPageHeader {
        var h = ParquetPageHeader()
        try r.readStruct { r, id, t in
            switch (id, t) {
            case (1, .i32): h.type = try r.i32()
            case (2, .i32): h.uncompressedSize = try r.i32()
            case (3, .i32): h.compressedSize = try r.i32()
            case (5, .structure):
                try r.readStruct { r, id, t in
                    switch (id, t) {
                    case (1, .i32): h.numValues = try r.i32()
                    case (2, .i32): h.encoding = try r.i32()
                    case (3, .i32): h.definitionEncoding = try r.i32()
                    case (4, .i32): h.repetitionEncoding = try r.i32()
                    default: try r.skip(t)
                    }
                }
            case (7, .structure):
                try r.readStruct { r, id, t in
                    switch (id, t) {
                    case (1, .i32): h.dictionaryValues = try r.i32()
                    case (2, .i32): h.dictionaryEncoding = try r.i32()
                    default: try r.skip(t)
                    }
                }
            case (8, .structure):
                try r.readStruct { r, id, t in
                    switch (id, t) {
                    case (1, .i32): h.numValues = try r.i32()
                    case (2, .i32): h.numNulls = try r.i32()
                    case (3, .i32): h.numRows = try r.i32()
                    case (4, .i32): h.encoding = try r.i32()
                    case (5, .i32): h.definitionLength = try r.i32()
                    case (6, .i32): h.repetitionLength = try r.i32()
                    case (7, .boolTrue), (7, .boolFalse): h.isCompressed = ThriftReader.bool(t)
                    default: try r.skip(t)
                    }
                }
            default: try r.skip(t)
            }
        }
        return h
    }

    static func encodingName(_ e: Int32) -> String {
        switch e {
        case 0: "PLAIN"; case 2: "PLAIN_DICTIONARY"; case 3: "RLE"; case 4: "BIT_PACKED"; case 5: "DELTA_BINARY_PACKED"
        case 6: "DELTA_LENGTH_BYTE_ARRAY"; case 7: "DELTA_BYTE_ARRAY"; case 8: "RLE_DICTIONARY"; case 9: "BYTE_STREAM_SPLIT"
        default: "encoding \(e)"
        }
    }

    static func codecName(_ c: Int32) -> String {
        switch c {
        case 0: "UNCOMPRESSED"; case 1: "SNAPPY"; case 2: "GZIP"; case 3: "LZO"; case 4: "BROTLI"; case 5: "LZ4"
        case 6: "ZSTD"; case 7: "LZ4_RAW"; default: "codec \(c)"
        }
    }

    /// The codec to decode with, or a refusal naming it.
    static func codec(_ c: Int32) throws -> ColumnarCodecs.Codec? {
        switch c {
        case 0: return nil
        case 1: return .snappy
        case 2: return .gzip
        case 5: return .lz4Hadoop
        case 6: return .zstd
        case 7: return .lz4Raw
        default: throw ColumnarError.unsupported(String(localized: "\(codecName(c)) compression", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
    }
}
