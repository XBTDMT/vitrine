import Foundation
import VitrineSupport

/// A Parquet file read footer first (apache/parquet-format README "File Format": `PAR1`, column chunks, the Thrift
/// FileMetaData, its 4-byte length, `PAR1`). Opening reads only the footer; rows are read by `ParquetTable` a window
/// at a time, walking each column chunk's page headers and decoding only the pages that hold the asked rows (a page
/// whose rows are not wanted is skipped by its header's size, never decompressed). roadmap: S-21
public final class ParquetFile: ColumnarDataset, @unchecked Sendable {
    public let format = ColumnarFormat.parquet
    let source: any ByteSource
    let limits: ColumnarLimits
    let metadata: ParquetFileMetadata
    let leaves: [ParquetLeaf]
    let footerLength: Int
    private let tableObject: ParquetTable

    public init(source: any ByteSource, limits: ColumnarLimits = ColumnarLimits()) throws {
        self.source = source
        self.limits = limits
        let size = source.size
        guard size >= 12 else { throw ColumnarError.truncated(String(localized: "a Parquet file is at least 12 bytes; this one is \(size)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let head = try source.read(at: 0, count: 4)
        let tail = try source.read(at: size - 8, count: 8)
        guard tail.count == 8 else { throw ColumnarError.truncated(String(localized: "the footer cannot be read", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let magic = String(decoding: tail[4..<8], as: UTF8.self)
        if magic == "PARE" { throw ColumnarError.unsupported(String(localized: "encrypted Parquet (an encrypted footer)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        guard magic == "PAR1" else {
            throw head == Array("PAR1".utf8) ? ColumnarError.truncated(String(localized: "the file has no Parquet footer at its end (a copy that stopped early?)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                : ColumnarError.malformed(String(localized: "no Parquet footer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        let length = Int(UInt32(tail[0]) | UInt32(tail[1]) << 8 | UInt32(tail[2]) << 16 | UInt32(tail[3]) << 24)
        guard Int64(length) <= size - 12 else {
            throw ColumnarError.malformed(String(localized: "the footer claims \(length.formatted()) bytes in a \(size.formatted())-byte file", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        guard length <= limits.maxMetadataBytes else {
            throw ColumnarError.tooLarge(String(localized: "the footer is \(ByteCountFormatter.string(fromByteCount: Int64(length), countStyle: .file))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        footerLength = length
        let footer = try source.read(at: size - 8 - Int64(length), count: length)
        guard footer.count == length else { throw ColumnarError.truncated(String(localized: "the footer ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var reader = ThriftReader(bytes: footer, maxDepth: limits.maxDepth)
        let meta: ParquetFileMetadata
        do { meta = try ParquetThrift.fileMetadata(&reader) } catch let error as ColumnarError {
            switch error {
            case .truncated(let s), .malformed(let s): throw ColumnarError.malformed(String(localized: "the footer cannot be read (\(s))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
            default: throw error
            }
        }
        metadata = meta
        guard meta.numRows >= 0 else { throw ColumnarError.malformed(String(localized: "the footer gives a negative row count", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        guard meta.rowGroups.count <= limits.maxChunks else {
            throw ColumnarError.tooLarge(String(localized: "\(meta.rowGroups.count.formatted()) row groups (the preview reads up to \(limits.maxChunks.formatted()))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        leaves = try ParquetSchema.leaves(meta.schema, limits: limits)
        for (g, group) in meta.rowGroups.enumerated() {
            guard group.numRows >= 0 else { throw ColumnarError.malformed(String(localized: "row group \(g + 1) has a negative row count", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            guard group.columns.count == leaves.count else {
                throw ColumnarError.malformed(String(localized: "row group \(g + 1) has \(group.columns.count) column chunks for \(leaves.count) columns", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
            }
            if group.columns.contains(where: \.encrypted) { throw ColumnarError.unsupported(String(localized: "encrypted Parquet columns", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            if let path = group.columns.compactMap(\.filePath).first {
                throw ColumnarError.unsupported(String(localized: "column data kept in another file (“\(path)”)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
            }
        }
        var sum: Int64 = 0
        for group in meta.rowGroups {
            let (next, overflow) = sum.addingReportingOverflow(group.numRows)
            guard !overflow, next <= Int64(Int32.max) * 1_024 else { throw ColumnarError.malformed(String(localized: "the row groups claim more rows than a file can hold", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            sum = next
        }
        guard sum == meta.numRows || meta.rowGroups.isEmpty else {
            throw ColumnarError.malformed(String(localized: "the row groups hold \(sum.formatted()) rows but the footer says \(meta.numRows.formatted())", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        tableObject = ParquetTable(source: source, metadata: meta, leaves: leaves, limits: limits)
    }

    public var parts: [ColumnarPart] { [ColumnarPart(name: String(localized: "Rows", bundle: .module, comment: "Name of the single table of a Parquet or Arrow file."), rows: Int(clamping: metadata.numRows))] }

    public func table(_ part: Int) throws -> any ColumnarTable { tableObject }

    public var facts: [ColumnarFact] {
        var out: [ColumnarFact] = []
        let groups = metadata.rowGroups
        out.append(ColumnarFact(key: "rows", String(localized: "Rows", bundle: .module, comment: "Fact label in a column file's (Parquet, Arrow, Excel) File tab."), Int(clamping: metadata.numRows).formatted()))
        out.append(ColumnarFact(key: "columns", String(localized: "Columns", bundle: .module, comment: "Fact label in a column file's (Parquet, Arrow, Excel) File tab."), leaves.count.formatted()))
        if !groups.isEmpty {
            let rows = groups.map(\.numRows)
            let value = Set(rows).count == 1 ? "\(groups.count.formatted()) × \(Int(rows[0]).formatted())"
                : "\(groups.count.formatted()) × ~\(Int(metadata.numRows / Int64(groups.count)).formatted())"
            out.append(ColumnarFact(key: "rowgroups", String(localized: "Row groups", bundle: .module, comment: "Fact label in a column file's (Parquet, Arrow, Excel) File tab."), value))
        } else {
            out.append(ColumnarFact(key: "rowgroups", String(localized: "Row groups", bundle: .module, comment: "Fact label in a column file's (Parquet, Arrow, Excel) File tab."), 0.formatted()))
        }
        var codecs: [String] = [], encodings: [String] = []
        for group in groups { for chunk in group.columns {
            guard let m = chunk.meta else { continue }
            let c = ParquetThrift.codecName(m.codec)
            if !codecs.contains(c) { codecs.append(c) }
            for e in m.encodings.map(ParquetThrift.encodingName) where !encodings.contains(e) { encodings.append(e) }
        } }
        if !codecs.isEmpty { out.append(ColumnarFact(key: "compression", String(localized: "Compression", bundle: .module, comment: "Fact label in a column file's (Parquet, Arrow, Excel) File tab."), codecs.joined(separator: ", "))) }
        if !encodings.isEmpty { out.append(ColumnarFact(key: "encodings", String(localized: "Encodings", bundle: .module, comment: "Fact label in a column file's (Parquet, Arrow, Excel) File tab."), encodings.joined(separator: ", "))) }
        let packed = groups.reduce(Int64(0)) { total, g in
            total &+ (g.totalCompressedSize ?? g.columns.reduce(Int64(0)) { $0 &+ ($1.meta?.totalCompressed ?? 0) })
        }
        let unpacked = groups.reduce(Int64(0)) { $0 &+ $1.totalByteSize }
        if packed > 0 { out.append(ColumnarFact(key: "data", String(localized: "Data", bundle: .module, comment: "Fact label: bytes of column data on disk, compressed."), ByteCountFormatter.string(fromByteCount: packed, countStyle: .file))) }
        if unpacked > 0 { out.append(ColumnarFact(key: "uncompressed", String(localized: "Uncompressed", bundle: .module, comment: "Fact label: bytes of column data once decompressed."), ByteCountFormatter.string(fromByteCount: unpacked, countStyle: .file))) }
        if let by = metadata.createdBy, !by.isEmpty {
            out.append(ColumnarFact(key: "writtenby", String(localized: "Written by", bundle: .module, comment: "Fact label: the program that wrote the file."), by.replacingOccurrences(of: " version ", with: " ")))
        }
        out.append(ColumnarFact(key: "format", String(localized: "Format", bundle: .module, comment: "Fact label in a column file's (Parquet, Arrow, Excel) File tab."), String(localized: "Parquet, file version \(metadata.version)", bundle: .module, comment: "Format fact value; the argument is the Parquet format version number.")))
        let keys = metadata.keyValues.map(\.key)
        if !keys.isEmpty {
            let named = keys.map { key -> String in
                switch key {
                case "pandas": return String(localized: "pandas schema", bundle: .module, comment: "A metadata key holding a pandas schema; pandas is a product name.")
                case "ARROW:schema": return String(localized: "Arrow schema", bundle: .module, comment: "A metadata key holding an Apache Arrow schema.")
                default: return key
                }
            }
            let rest = named.count - 1
            out.append(ColumnarFact(key: "metadata", String(localized: "Metadata", bundle: .module, comment: "Fact label: the metadata keys stored in a column file."), rest == 0 ? named[0]
                : rest == 1 ? String(localized: "\(named[0]) · 1 more key", bundle: .module, comment: "Metadata fact value: the first metadata key's name, then one more key.")
                : String(localized: "\(named[0]) · \(rest) more keys", bundle: .module, comment: "Metadata fact value: the first metadata key's name, then how many more keys (2 or more).")))
        }
        out.append(ColumnarFact(key: "footer", String(localized: "Footer", bundle: .module, comment: "Fact label: the size of the Parquet footer (its metadata block)."), ByteCountFormatter.string(fromByteCount: Int64(footerLength), countStyle: .file)))
        return out
    }
}

/// One leaf column of the schema, with its levels and how its values read.
struct ParquetLeaf: Sendable {
    var name: String
    var element: ParquetSchemaElement
    var physical: ParquetPhysicalType
    var maxDefinition: Int
    var maxRepetition: Int
    /// The definition level at the repeated ancestor (one-level lists): a level at or above it is an element.
    var repeatedDefinition: Int
    var column: ColumnarColumn
    /// How one stored value reads (the column's kind, or a list's element kind).
    var valueKind: ColumnarKind
}

enum ParquetSchema {
    /// The leaves of the flattened schema (parquet.thrift's depth-first SchemaElement list, element 0 the root).
    static func leaves(_ schema: [ParquetSchemaElement], limits: ColumnarLimits) throws -> [ParquetLeaf] {
        guard let root = schema.first else { throw ColumnarError.malformed(String(localized: "the footer has no schema", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var leaves: [ParquetLeaf] = []
        var index = 1
        func walk(children: Int, path: [String], definition: Int, repetition: Int, repeatedDefinition: Int, inList: Bool, depth: Int) throws {
            guard children >= 0, children <= schema.count - index else { throw ColumnarError.malformed(String(localized: "a schema group claims \(children) children", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            guard depth <= limits.maxDepth else { throw ColumnarError.malformed(String(localized: "the schema is nested more than \(limits.maxDepth) deep", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            for _ in 0..<children {
                guard index < schema.count else { throw ColumnarError.malformed(String(localized: "the schema lists fewer elements than its groups claim", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                let element = schema[index]
                index += 1
                let repetitionType = element.repetition ?? .required
                let d = definition + (repetitionType == .required ? 0 : 1)
                let r = repetition + (repetitionType == .repeated ? 1 : 0)
                let rd = repetitionType == .repeated ? d : repeatedDefinition
                let nested = inList || repetitionType == .repeated || element.logical == .list || element.logical == .map
                    || element.convertedType == 1 || element.convertedType == 3
                if let n = element.numChildren, n > 0 {
                    guard Int(n) <= schema.count - index else { throw ColumnarError.malformed(String(localized: "a schema group claims more children than the schema has", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                    try walk(children: Int(n), path: path + [element.name], definition: d, repetition: r, repeatedDefinition: rd,
                             inList: nested, depth: depth + 1)
                } else {
                    guard let physical = element.type else { throw ColumnarError.malformed(String(localized: "column “\(element.name)” has no type", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                    guard leaves.count < limits.maxColumns else {
                        throw ColumnarError.tooLarge(String(localized: "more than \(limits.maxColumns.formatted()) columns", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                    }
                    let name = (path + [element.name]).joined(separator: ".")
                    var column = describe(element, physical: physical, name: name)
                    let valueKind = column.kind
                    column.nullable = d > 0
                    if r > 1 {
                        column.note = String(localized: "nested more than one level deep (lists of lists, maps of lists): not shown", bundle: .module, comment: "Note on a column the preview does not show.")
                        column.isOmitted = true
                        column.kind = .nested
                    } else if r == 1 {
                        column.note = String(localized: "repeated: each row's values shown as a list", bundle: .module, comment: "Note on a repeated Parquet column.")
                        column.typeDescription = "list<\(column.typeDescription)>"
                        column.kind = .nested
                    }
                    leaves.append(ParquetLeaf(name: name, element: element, physical: physical, maxDefinition: d,
                                              maxRepetition: r, repeatedDefinition: rd, column: column, valueKind: valueKind))
                }
            }
        }
        try walk(children: Int(root.numChildren ?? 0), path: [], definition: 0, repetition: 0, repeatedDefinition: 0, inList: false, depth: 1)
        if index < schema.count { throw ColumnarError.malformed(String(localized: "the schema has \(schema.count - index) elements outside its root", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return leaves
    }

    /// The logical type, from LogicalType or the legacy ConvertedType.
    static func logical(_ e: ParquetSchemaElement) -> ParquetLogicalType? {
        if let l = e.logical { return l }
        guard let c = e.convertedType else { return nil }
        switch c {
        case 0: return .string
        case 1, 2: return .map
        case 3: return .list
        case 4: return .enumeration
        case 5: return .decimal(precision: Int(e.precision ?? 0), scale: Int(e.scale ?? 0))
        case 6: return .date
        case 7: return .time(utc: true, unit: .millis)
        case 8: return .time(utc: true, unit: .micros)
        case 9: return .timestamp(utc: true, unit: .millis)
        case 10: return .timestamp(utc: true, unit: .micros)
        case 11: return .integer(bits: 8, signed: false)
        case 12: return .integer(bits: 16, signed: false)
        case 13: return .integer(bits: 32, signed: false)
        case 14: return .integer(bits: 64, signed: false)
        case 15: return .integer(bits: 8, signed: true)
        case 16: return .integer(bits: 16, signed: true)
        case 17: return .integer(bits: 32, signed: true)
        case 18: return .integer(bits: 64, signed: true)
        case 19: return .json
        case 20: return .bson
        case 21: return .interval
        default: return nil
        }
    }

    static func describe(_ e: ParquetSchemaElement, physical: ParquetPhysicalType, name: String) -> ColumnarColumn {
        let logical = logical(e)
        var type = physical.name
        if physical == .fixedLenByteArray { type += "(\(e.typeLength))" }
        if let logical { type += " · " + logical.name }
        let kind: ColumnarKind
        var note: String?
        var omitted = false
        switch (physical, logical) {
        case (.boolean, _): kind = .boolean
        case (.int32, .integer(let b, let s)?), (.int64, .integer(let b, let s)?): kind = .integer(bits: b, signed: s)
        case (.int32, .decimal(let p, let s)?), (.int64, .decimal(let p, let s)?),
             (.fixedLenByteArray, .decimal(let p, let s)?), (.byteArray, .decimal(let p, let s)?):
            kind = .decimal(precision: p, scale: s)
        case (.int32, .date?): kind = .date
        case (.int32, .time(_, let u)?), (.int64, .time(_, let u)?): kind = .time(u)
        case (.int64, .timestamp(let utc, let u)?): kind = .timestamp(u, zone: utc ? "UTC" : nil)
        case (.int32, _): kind = .integer(bits: 32, signed: true)
        case (.int64, _): kind = .integer(bits: 64, signed: true)
        case (.int96, _): kind = .timestamp(.nanos, zone: nil); type = String(localized: "INT96 · legacy timestamp", bundle: .module, comment: "Column type description; INT96 is a Parquet type name and stays as is.")
        case (.float, _): kind = .float(bits: 32)
        case (.double, _): kind = .float(bits: 64)
        case (.fixedLenByteArray, .uuid?): kind = .uuid
        case (.fixedLenByteArray, .float16?): kind = .float(bits: 16)
        case (.fixedLenByteArray, .interval?): kind = .string; note = String(localized: "interval, shown as months, days and milliseconds", bundle: .module, comment: "Note on an interval column.")
        case (.byteArray, .string?), (.byteArray, .enumeration?), (.byteArray, .json?): kind = .string
        case (.byteArray, .variant?), (.byteArray, .geometry?), (.byteArray, .geography?):
            kind = .binary; note = String(localized: "\(logical!.name.lowercased()), shown as bytes", bundle: .module, comment: "Note on a column shown as raw bytes; the argument is a Parquet type name such as variant or geometry.")
        default: kind = .binary
        }
        if case .integer(let b, _) = kind, ![8, 16, 32, 64].contains(b) { omitted = true; note = String(localized: "integer of \(b) bits: not shown", bundle: .module, comment: "Note on an integer column of an unusual width that the preview does not show.") }
        if case .decimal(let p, let s) = kind, s < 0 || s > 76 || p < 0 || p > 76 {
            omitted = true; note = String(localized: "decimal with precision \(p) and scale \(s): not shown", bundle: .module, comment: "Note on a decimal column the preview does not show.")
        }
        return ColumnarColumn(name: name, kind: kind, typeDescription: type, note: note, isOmitted: omitted)
    }
}
