import Foundation
import VitrineSupport

// The shared shape of the three column-file readers (B-4, A-7, G-20): Parquet, Arrow IPC / Feather and xlsx. Each
// reader turns its file into the same thing: named parts (one for Parquet and Arrow, one per sheet for xlsx), each a
// table of typed columns whose rows are read a window at a time, never the whole file. Values stay in compact typed
// arrays; the text a cell shows is made when it is drawn (`ColumnarFormat`). Everything here reads untrusted bytes
// and is bounded by `ColumnarLimits`. roadmap: S-21, S-22

/// Why a column file could not be shown, worded to show as is.
public enum ColumnarError: Error, Sendable, Equatable, LocalizedError, ByteReadFailure {
    /// The file could not be opened or read.
    case unreadable(String)
    /// The bytes end before a structure they declare.
    case truncated(String)
    /// A structure contradicts itself.
    case malformed(String)
    /// A feature the reader does not decode, named: "BROTLI compression", "encrypted Parquet".
    case unsupported(String)
    /// A declared size past a preview's bounds.
    case tooLarge(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreadable(let s): return String(localized: "Cannot read the file: \(s).", bundle: .module, comment: "Error shown instead of a column file preview; the argument is a lower-case detail.")
        case .truncated(let s): return String(localized: "The file is cut short: \(s).", bundle: .module, comment: "Error shown instead of a column file preview; the argument is a lower-case detail.")
        case .malformed(let s): return String(localized: "The file is damaged: \(s).", bundle: .module, comment: "Error shown instead of a column file preview; the argument is a lower-case detail.")
        case .unsupported(let s): return String(localized: "Not supported: \(s).", bundle: .module, comment: "Error shown instead of a column file preview; the argument names the unsupported feature.")
        case .tooLarge(let s): return String(localized: "Too large to preview: \(s).", bundle: .module, comment: "Error shown instead of a column file preview; the argument says what is too large.")
        case .cancelled: return String(localized: "Cancelled.", bundle: .module, comment: "Shown when reading a column file was cancelled.")
        }
    }
}

/// Bounds on everything a column file can claim. Hostile files are refused by these, never trusted.
public struct ColumnarLimits: Sendable, Equatable {
    /// Largest Parquet footer or Arrow footer/schema message read.
    public var maxMetadataBytes = 64 * 1024 * 1024
    /// Columns shown (Parquet leaves, Arrow top-level fields, sheet columns).
    public var maxColumns = 4_096
    /// Row groups, record batches or dictionary batches listed.
    public var maxChunks = 200_000
    /// Nesting depth of a schema (Parquet groups, Arrow children) and of the Thrift/FlatBuffers structures read.
    public var maxDepth = 48
    /// Largest one page or buffer may claim, compressed or not.
    public var maxPageBytes = 256 * 1024 * 1024
    /// Bytes decompressed or read for one window of rows.
    public var maxWindowBytes = 512 * 1024 * 1024
    /// Rows one window read may return.
    public var maxWindowRows = 100_000
    /// Bytes a decoded Parquet dictionary or Arrow dictionary batch may hold.
    public var maxDictionaryBytes = 128 * 1024 * 1024
    /// Characters of text made for one nested value ("[1, 2, 3]"); longer text ends with "…".
    public var maxNestedText = 2_000
    /// Elements shown inside one nested value.
    public var maxNestedElements = 64
    /// xlsx: the largest sheet, shared-strings or styles part inflated.
    public var maxSheetXMLBytes = 256 * 1024 * 1024
    /// xlsx: cells kept per sheet.
    public var maxSheetCells = 4_000_000
    /// xlsx: shared strings kept.
    public var maxSharedStrings = 4_000_000
    /// Cells copied into memory for SQL (rows × columns).
    public var maxQueryCells = 16_000_000

    public init() {}
}

/// A unit of time in a time, timestamp or duration column.
public enum ColumnarTimeUnit: Sendable, Equatable {
    case seconds, millis, micros, nanos

    public var name: String {
        switch self { case .seconds: "s"; case .millis: "ms"; case .micros: "µs"; case .nanos: "ns" }
    }
    /// Units per second.
    public var perSecond: Int64 {
        switch self { case .seconds: 1; case .millis: 1_000; case .micros: 1_000_000; case .nanos: 1_000_000_000 }
    }
}

/// What a column's values mean, which decides how a stored value reads.
public enum ColumnarKind: Sendable, Equatable {
    case boolean
    /// Stored in `ints`; `signed` false for unsigned 64-bit values kept as their bit pattern.
    case integer(bits: Int, signed: Bool)
    case float(bits: Int)
    /// Stored in `ints` (unscaled) when it fits 64 bits, else as text cells.
    case decimal(precision: Int, scale: Int)
    case string
    case binary
    /// Days since 1970-01-01.
    case date
    /// Milliseconds since 1970-01-01 (Arrow's Date64).
    case dateMillis
    /// Time of day since midnight.
    case time(ColumnarTimeUnit)
    /// Since 1970-01-01T00:00:00Z. `zone` is "UTC", an Olson name or an offset; nil when the writer said the value
    /// is local time with no zone (shown as written).
    case timestamp(ColumnarTimeUnit, zone: String?)
    case duration(ColumnarTimeUnit)
    /// 16 bytes shown as a UUID.
    case uuid
    /// A list, struct or map: each value is already text.
    case nested
    /// Values of several kinds in one column (an xlsx column): each cell carries its own text and number.
    case mixed
    /// A column with no values (Arrow's Null type, an all-empty sheet column).
    case null

    public var isNumeric: Bool {
        switch self {
        case .integer, .float, .decimal, .duration: return true
        default: return false
        }
    }

    public var isTemporal: Bool {
        switch self {
        case .date, .dateMillis, .time, .timestamp: return true
        default: return false
        }
    }
}

/// One stored value, as a reader hands it out. `text` is a value already made into words (a nested list, a decimal
/// wider than 64 bits, an xlsx cell in a mixed column) with the number it stands for when it is one.
public enum ColumnarCell: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case bytes([UInt8])
    case text(String, number: Double?)

    public var isNull: Bool { if case .null = self { return true } else { return false } }
}

/// The values of one column for a run of rows. Arrays are dense: a null row holds a placeholder in the storage and
/// `true` in `nulls`.
public struct ColumnVector: Sendable, Equatable {
    public enum Storage: Sendable, Equatable {
        case bools([Bool])
        case ints([Int64])
        case doubles([Double])
        case strings([String])
        case bytes([[UInt8]])
        case cells([ColumnarCell])
    }

    public var storage: Storage
    /// nil when no row is null.
    public var nulls: [Bool]?

    public init(storage: Storage, nulls: [Bool]? = nil) {
        self.storage = storage
        self.nulls = nulls.flatMap { $0.contains(true) ? $0 : nil }
    }

    public var count: Int {
        switch storage {
        case .bools(let v): v.count
        case .ints(let v): v.count
        case .doubles(let v): v.count
        case .strings(let v): v.count
        case .bytes(let v): v.count
        case .cells(let v): v.count
        }
    }

    public subscript(i: Int) -> ColumnarCell {
        guard i >= 0, i < count else { return .null }
        if let nulls, i < nulls.count, nulls[i] { return .null }
        switch storage {
        case .bools(let v): return .bool(v[i])
        case .ints(let v): return .int(v[i])
        case .doubles(let v): return .double(v[i])
        case .strings(let v): return .string(v[i])
        case .bytes(let v): return .bytes(v[i])
        case .cells(let v): return v[i]
        }
    }

    /// A vector of `count` nulls.
    public static func nulls(_ count: Int) -> ColumnVector {
        ColumnVector(storage: .cells(Array(repeating: .null, count: count)))
    }

    /// The rows `range` of this vector.
    public func slice(_ range: Range<Int>) -> ColumnVector {
        let r = range.clamped(to: 0..<count)
        let n = nulls.map { Array($0[r]) }
        switch storage {
        case .bools(let v): return ColumnVector(storage: .bools(Array(v[r])), nulls: n)
        case .ints(let v): return ColumnVector(storage: .ints(Array(v[r])), nulls: n)
        case .doubles(let v): return ColumnVector(storage: .doubles(Array(v[r])), nulls: n)
        case .strings(let v): return ColumnVector(storage: .strings(Array(v[r])), nulls: n)
        case .bytes(let v): return ColumnVector(storage: .bytes(Array(v[r])), nulls: n)
        case .cells(let v): return ColumnVector(storage: .cells(Array(v[r])), nulls: n)
        }
    }

    /// This vector followed by `other`; storages that differ fall back to cells.
    public func appending(_ other: ColumnVector) -> ColumnVector {
        let nulls: [Bool]? = (self.nulls == nil && other.nulls == nil) ? nil
            : (self.nulls ?? Array(repeating: false, count: count)) + (other.nulls ?? Array(repeating: false, count: other.count))
        switch (storage, other.storage) {
        case (.bools(let a), .bools(let b)): return ColumnVector(storage: .bools(a + b), nulls: nulls)
        case (.ints(let a), .ints(let b)): return ColumnVector(storage: .ints(a + b), nulls: nulls)
        case (.doubles(let a), .doubles(let b)): return ColumnVector(storage: .doubles(a + b), nulls: nulls)
        case (.strings(let a), .strings(let b)): return ColumnVector(storage: .strings(a + b), nulls: nulls)
        case (.bytes(let a), .bytes(let b)): return ColumnVector(storage: .bytes(a + b), nulls: nulls)
        default:
            return ColumnVector(storage: .cells((0..<count).map { self[$0] } + (0..<other.count).map { other[$0] }))
        }
    }
}

/// Footer statistics of a column, already made into words.
public struct ColumnarStatistics: Sendable, Equatable {
    public var min: String?
    public var max: String?
    public var nullCount: Int?
    public var distinctCount: Int?
    public init(min: String? = nil, max: String? = nil, nullCount: Int? = nil, distinctCount: Int? = nil) {
        self.min = min; self.max = max; self.nullCount = nullCount; self.distinctCount = distinctCount
    }
    public var isEmpty: Bool { min == nil && max == nil && nullCount == nil && distinctCount == nil }
}

/// One column of a table.
public struct ColumnarColumn: Sendable, Equatable {
    public var name: String
    public var kind: ColumnarKind
    /// The stored type as the format names it: "INT64 · TIMESTAMP(µs, UTC)", "Utf8", "dictionary<Int32, Utf8>".
    public var typeDescription: String
    /// Said beside the type when the values are shown in a reduced form or not at all: "list, shown as text".
    public var note: String?
    /// The column has no readable values (an unsupported type); every cell reads as `note`.
    public var isOmitted: Bool
    /// Summed over the file's row groups (Parquet) when the footer has them.
    public var statistics: ColumnarStatistics?
    public var nullable: Bool

    public init(name: String, kind: ColumnarKind, typeDescription: String, note: String? = nil, isOmitted: Bool = false,
                statistics: ColumnarStatistics? = nil, nullable: Bool = true) {
        self.name = name; self.kind = kind; self.typeDescription = typeDescription; self.note = note
        self.isOmitted = isOmitted; self.statistics = statistics; self.nullable = nullable
    }
}

/// A row group, record batch or sheet: a run of rows stored together.
public struct ColumnarChunk: Sendable, Equatable {
    public var rows: Int
    /// Bytes on disk (compressed), when known.
    public var bytes: Int64?
    /// Bytes once decompressed, when known.
    public var uncompressedBytes: Int64?
    public init(rows: Int, bytes: Int64? = nil, uncompressedBytes: Int64? = nil) {
        self.rows = rows; self.bytes = bytes; self.uncompressedBytes = uncompressedBytes
    }
}

/// A label and a value for the File tab and the pill's tooltip. `key` is stable across languages (`rows`, `rowgroups`,
/// `writtenby`: the English label lower-cased without spaces), for `vitrine describe`, MCP and lookups; `label` is
/// localized for people.
public struct ColumnarFact: Sendable, Equatable {
    public var key: String
    public var label: String
    public var value: String
    public init(key: String, _ label: String, _ value: String) { self.key = key; self.label = label; self.value = value }
}

/// A part of a file: the one table of a Parquet or Arrow file, or one sheet of a workbook.
public struct ColumnarPart: Sendable, Equatable {
    public var name: String
    /// Rows when known before the part is opened (xlsx gives an estimate from the sheet's dimension).
    public var rows: Int?
    public var rowsAreEstimate: Bool
    /// "hidden", "chart sheet".
    public var note: String?
    public init(name: String, rows: Int?, rowsAreEstimate: Bool = false, note: String? = nil) {
        self.name = name; self.rows = rows; self.rowsAreEstimate = rowsAreEstimate; self.note = note
    }
}

/// Rows `start ..< start + count` of every column.
public struct ColumnarWindow: Sendable, Equatable {
    public var start: Int
    public var count: Int
    public var columns: [ColumnVector]
    public init(start: Int, count: Int, columns: [ColumnVector]) { self.start = start; self.count = count; self.columns = columns }
}

/// A table whose rows are read a window at a time. Implementations are safe to call from any thread.
public protocol ColumnarTable: AnyObject, Sendable {
    var columns: [ColumnarColumn] { get }
    var rowCount: Int { get }
    /// Row groups, record batches, or one chunk for a sheet.
    var chunks: [ColumnarChunk] { get }
    /// Rows `rows` (clamped to the table, at most `ColumnarLimits.maxWindowRows`). Throws `.cancelled` when
    /// `isCancelled` turns true between pages.
    func read(rows: Range<Int>, isCancelled: @Sendable () -> Bool) throws -> ColumnarWindow
    /// Problems found while reading that do not stop it, in order: "Row group 3 could not be read: …".
    var warnings: [String] { get }
    /// The number the first row shows (a sheet's own row number; 1 elsewhere).
    var firstRowNumber: Int { get }
    /// Facts of this part alone (a sheet's cells, formulas, used range).
    var facts: [ColumnarFact] { get }
}

extension ColumnarTable {
    public func read(rows: Range<Int>) throws -> ColumnarWindow { try read(rows: rows, isCancelled: { false }) }
    public var warnings: [String] { [] }
    public var firstRowNumber: Int { 1 }
    public var facts: [ColumnarFact] { [] }
}

/// A file of one format, opened: its facts and parts.
public protocol ColumnarDataset: AnyObject, Sendable {
    var format: ColumnarFormat { get }
    /// File facts from the metadata alone (rows, row groups, compression, writer, format version, metadata keys).
    var facts: [ColumnarFact] { get }
    var parts: [ColumnarPart] { get }
    /// Opens a part. For xlsx this parses the sheet (bounded); for the others it is free.
    func table(_ part: Int) throws -> any ColumnarTable
}

/// The formats read.
public enum ColumnarFormat: String, Sendable, Equatable {
    case parquet, arrowFile, arrowStream, feather, xlsx

    public var displayName: String {
        switch self {
        case .parquet: "Parquet"
        case .arrowFile: "Arrow"
        case .arrowStream: String(localized: "Arrow stream", bundle: .module, comment: "File format name: an Apache Arrow IPC stream.")
        case .feather: "Feather"
        case .xlsx: String(localized: "Excel workbook", bundle: .module, comment: "File format name: an .xlsx spreadsheet.")
        }
    }
}

/// Opens a column file by its first and last bytes (the extension only breaks a tie). roadmap: S-21
public enum ColumnarOpener {
    public static func open(_ url: URL, limits: ColumnarLimits = ColumnarLimits()) throws -> any ColumnarDataset {
        let source = try BoundedFileSource<ColumnarError>(url: url)
        return try open(source: source, fileExtension: url.pathExtension.lowercased(), limits: limits)
    }

    public static func open(source: any ByteSource, fileExtension: String = "", limits: ColumnarLimits = ColumnarLimits()) throws -> any ColumnarDataset {
        let head = try source.read(at: 0, count: 8)
        func starts(_ s: String) -> Bool { head.starts(with: Array(s.utf8)) }
        if starts("PAR1") || starts("PARE") { return try ParquetFile(source: source, limits: limits) }
        if starts("ARROW1") {
            return try ArrowFile.open(source: source, limits: limits, format: fileExtension == "feather" ? .feather : .arrowFile)
        }
        if starts("FEA1") { throw ColumnarError.unsupported(String(localized: "Feather version 1 (the 2016 format; Feather 2 is Arrow's file format)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return try XLSXWorkbook(source: source, limits: limits) }
        if head.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            throw ColumnarError.unsupported(String(localized: "an OLE compound file: a legacy .xls workbook or a password-protected .xlsx", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        if head.count >= 4, head[0] == 0xFF, head[1] == 0xFF, head[2] == 0xFF, head[3] == 0xFF {
            return try ArrowFile.open(source: source, limits: limits, format: fileExtension == "feather" ? .feather : .arrowStream)
        }
        if ["arrows", "arrow", "ipc", "stream"].contains(fileExtension), head.count >= 4 {
            // The stream format before Arrow 0.15 starts with the message length, without the 0xFFFFFFFF marker.
            return try ArrowFile.open(source: source, limits: limits, format: .arrowStream)
        }
        if source.size == 0 { throw ColumnarError.truncated(String(localized: "the file is empty", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        throw ColumnarError.malformed(String(localized: "the first bytes are not Parquet's PAR1, Arrow's ARROW1 or a zip", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
    }
}
