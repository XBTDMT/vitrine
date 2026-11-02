import Foundation
import VitrineSupport

/// An Arrow IPC file (the Arrow Columnar Format, "IPC File Format": `ARROW1`, padding, a stream, the Footer
/// flatbuffer from `format/File.fbs`, its length, `ARROW1`; Feather version 2 is this format) or stream ("IPC
/// Streaming Format": messages, each a 0xFFFFFFFF continuation, a length, a `Message` flatbuffer from
/// `format/Message.fbs` and a body). Opening reads the schema, the dictionaries and each record batch's length; the
/// rows of a batch are read when asked, uncompressed buffers only for the asked rows, compressed buffers (LZ4_FRAME,
/// ZSTD) whole. A file whose footer is missing is read as the stream it contains, and says so. roadmap: S-21
public final class ArrowFile: ColumnarDataset, @unchecked Sendable {
    public let format: ColumnarFormat
    let source: any ByteSource
    let limits: ColumnarLimits
    let fields: [ArrowField]
    let batches: [ArrowBatchLocation]
    let dictionaries: [Int64: ColumnVector]
    let metadataVersion: Int16
    let footerMissing: Bool
    let schemaMetadataKeys: [String]
    private let tableObject: ArrowTable

    struct ArrowBatchLocation: Sendable {
        var metadataOffset: Int64
        var metadataLength: Int
        var bodyOffset: Int64
        var bodyLength: Int64
        var rows: Int
    }

    /// One message: where its flatbuffer and body are.
    struct Message {
        var metadata: [UInt8]
        var metadataOffset: Int64
        var bodyOffset: Int64
        var bodyLength: Int64
        var headerType: UInt8
        var header: FlatTable?
        var version: Int16
        /// Where the next message starts.
        var next: Int64
    }

    static func open(source: any ByteSource, limits: ColumnarLimits, format: ColumnarFormat) throws -> ArrowFile {
        try ArrowFile(source: source, limits: limits, format: format)
    }

    init(source: any ByteSource, limits: ColumnarLimits, format: ColumnarFormat) throws {
        self.source = source
        self.limits = limits
        let size = source.size
        let head = try source.read(at: 0, count: 8)
        var isFile = head.starts(with: Array("ARROW1".utf8))
        var footerMissing = false
        var fields: [ArrowField] = []
        var batches: [ArrowBatchLocation] = []
        var dictionaryBlocks: [(offset: Int64, metadataLength: Int, bodyLength: Int64)] = []
        var version: Int16 = 4
        var keys: [String] = []
        var streamStart: Int64 = 0
        if isFile {
            streamStart = 8
            let tail = size >= 18 ? try source.read(at: size - 10, count: 10) : []
            if tail.count == 10, Array(tail[4..<10]) == Array("ARROW1".utf8) {
                let length = Int(Int32(bitPattern: UInt32(tail[0]) | UInt32(tail[1]) << 8 | UInt32(tail[2]) << 16 | UInt32(tail[3]) << 24))
                guard length > 0, Int64(length) <= size - 18 else {
                    throw ColumnarError.malformed(String(localized: "the footer claims \(length.formatted()) bytes in a \(size.formatted())-byte file", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                }
                guard length <= limits.maxMetadataBytes else { throw ColumnarError.tooLarge(String(localized: "a \(length.formatted())-byte footer", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                let bytes = try source.read(at: size - 10 - Int64(length), count: length)
                guard bytes.count == length else { throw ColumnarError.truncated(String(localized: "the footer ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                let footer = try FlatTable.root(bytes)
                version = try footer.int16(0)
                guard let schema = try footer.table(1) else { throw ColumnarError.malformed(String(localized: "the footer has no schema", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                fields = try ArrowSchemaReader.fields(schema, limits: limits)
                keys = try schema.tables(2).compactMap { try $0.string(0) }
                func blocks(_ slot: Int) throws -> [(Int64, Int, Int64)] {
                    guard let (n, start) = try footer.vector(slot, elementSize: 24) else { return [] }
                    guard n <= limits.maxChunks else { throw ColumnarError.tooLarge(String(localized: "\(n.formatted()) blocks (the preview reads up to \(limits.maxChunks.formatted()))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                    return try (0..<n).map { k in
                        let at = start + 24 * k
                        return (Int64(bitPattern: try FlatTable.u64(bytes, at)), Int(Int32(bitPattern: try FlatTable.u32(bytes, at + 8))),
                                Int64(bitPattern: try FlatTable.u64(bytes, at + 16)))
                    }
                }
                dictionaryBlocks = try blocks(2).map { (offset: $0.0, metadataLength: $0.1, bodyLength: $0.2) }
                for (offset, metadataLength, bodyLength) in try blocks(3) {
                    guard let message = try Self.message(source: source, at: offset, blockMetadataLength: metadataLength, limits: limits),
                          message.headerType == 3, let batch = message.header else { throw ColumnarError.malformed(String(localized: "a record batch block holds another message", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                    guard bodyLength == message.bodyLength else { throw ColumnarError.malformed(String(localized: "a record batch's body length disagrees with its block", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                    batches.append(try Self.location(message, batch: batch, size: size))
                }
            } else {
                footerMissing = true
                isFile = false
            }
        }
        var dictionaries: [Int64: ColumnVector] = [:]
        if isFile {
            for block in dictionaryBlocks {
                guard let message = try Self.message(source: source, at: block.offset, blockMetadataLength: block.metadataLength, limits: limits),
                      message.headerType == 2, let header = message.header else { throw ColumnarError.malformed(String(localized: "a dictionary block holds another message", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                try Self.addDictionary(header, message: message, fields: fields, version: version, source: source, limits: limits, into: &dictionaries)
            }
        } else {
            // The stream: a schema message, then dictionaries and record batches in any order, to the end marker.
            var offset = streamStart
            var sawSchema = false
            var count = 0
            while offset + 4 <= size {
                count += 1
                guard count <= limits.maxChunks * 2 else { throw ColumnarError.tooLarge(String(localized: "more than \((limits.maxChunks * 2).formatted()) messages", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                guard let message = try Self.message(source: source, at: offset, blockMetadataLength: nil, limits: limits) else { break }
                offset = message.next
                switch message.headerType {
                case 1:
                    guard !sawSchema, let schema = message.header else { throw ColumnarError.malformed(String(localized: "a second schema in the stream", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                    sawSchema = true
                    version = message.version
                    fields = try ArrowSchemaReader.fields(schema, limits: limits)
                    keys = try schema.tables(2).compactMap { try $0.string(0) }
                case 2:
                    guard sawSchema, let header = message.header else { throw ColumnarError.malformed(String(localized: "a dictionary before the schema", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                    try Self.addDictionary(header, message: message, fields: fields, version: version, source: source, limits: limits, into: &dictionaries)
                case 3:
                    guard sawSchema, let batch = message.header else { throw ColumnarError.malformed(String(localized: "a record batch before the schema", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                    guard batches.count < limits.maxChunks else { throw ColumnarError.tooLarge(String(localized: "more than \(limits.maxChunks.formatted()) record batches", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                    batches.append(try Self.location(message, batch: batch, size: size))
                default:
                    break   // tensors and unknown messages are skipped by their length
                }
            }
            guard sawSchema else { throw ColumnarError.malformed(String(localized: "no schema message", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        }
        guard fields.count <= limits.maxColumns else { throw ColumnarError.tooLarge(String(localized: "more than \(limits.maxColumns.formatted()) columns", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        self.format = format
        self.fields = fields
        self.batches = batches
        self.dictionaries = dictionaries
        self.metadataVersion = version
        self.footerMissing = footerMissing
        self.schemaMetadataKeys = keys
        tableObject = ArrowTable(source: source, fields: fields, batches: batches, dictionaries: dictionaries,
                                 version: version, limits: limits)
    }

    static func location(_ message: Message, batch: FlatTable, size: Int64) throws -> ArrowBatchLocation {
        let rows = try batch.int64(0)
        guard rows >= 0, rows <= Int64(Int32.max) else { throw ColumnarError.malformed(String(localized: "a record batch claims \(rows.formatted()) rows", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        guard message.bodyLength >= 0, message.bodyOffset + message.bodyLength <= size else {
            throw ColumnarError.truncated(String(localized: "a record batch's body runs past the end of the file", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        return ArrowBatchLocation(metadataOffset: message.metadataOffset, metadataLength: message.metadata.count,
                                  bodyOffset: message.bodyOffset, bodyLength: message.bodyLength, rows: Int(rows))
    }

    /// The message at `offset`; nil at the stream's end marker (or the end of the bytes). `blockMetadataLength` is the
    /// file footer's length for it, prefix and padding included.
    static func message(source: any ByteSource, at offset: Int64, blockMetadataLength: Int?, limits: ColumnarLimits) throws -> Message? {
        guard offset >= 0 else { throw ColumnarError.malformed(String(localized: "a message offset is negative", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let prefix = try source.read(at: offset, count: 8)
        guard prefix.count >= 4 else {
            if blockMetadataLength != nil { throw ColumnarError.truncated(String(localized: "a block points past the end of the file", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            return nil
        }
        let first = UInt32(prefix[0]) | UInt32(prefix[1]) << 8 | UInt32(prefix[2]) << 16 | UInt32(prefix[3]) << 24
        var length: Int
        var start: Int64
        if first == 0xFFFF_FFFF {
            guard prefix.count == 8 else { return nil }
            length = Int(Int32(bitPattern: UInt32(prefix[4]) | UInt32(prefix[5]) << 8 | UInt32(prefix[6]) << 16 | UInt32(prefix[7]) << 24))
            start = offset + 8
        } else {
            length = Int(Int32(bitPattern: first))
            start = offset + 4
        }
        if length == 0 { return nil }
        guard length > 0 else { throw ColumnarError.malformed(String(localized: "a message with a negative length", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        guard length <= limits.maxMetadataBytes else { throw ColumnarError.tooLarge(String(localized: "a \(length.formatted())-byte message header", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let bytes = try source.read(at: start, count: length)
        guard bytes.count == length else { throw ColumnarError.truncated(String(localized: "a message header ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let message = try FlatTable.root(bytes)
        let version = try message.int16(0)
        let headerType = try message.uint8(1)
        let header = try message.table(2)
        let bodyLength = try message.int64(3)
        guard bodyLength >= 0 else { throw ColumnarError.malformed(String(localized: "a message body with a negative length", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var bodyOffset = start + Int64(length)
        if let block = blockMetadataLength {
            guard block >= length else { throw ColumnarError.malformed(String(localized: "a block's metadata length is shorter than its message", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            bodyOffset = offset + Int64(block)
        }
        guard bodyOffset <= source.size, bodyLength <= source.size - bodyOffset else {
            throw ColumnarError.truncated(String(localized: "a message body runs past the end of the file", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        return Message(metadata: bytes, metadataOffset: start, bodyOffset: bodyOffset, bodyLength: bodyLength,
                       headerType: headerType, header: header, version: version, next: bodyOffset + bodyLength)
    }

    /// Decodes a DictionaryBatch (whole: dictionaries are small by design) and keeps it, appending a delta.
    static func addDictionary(_ header: FlatTable, message: Message, fields: [ArrowField], version: Int16, source: any ByteSource,
                              limits: ColumnarLimits, into dictionaries: inout [Int64: ColumnVector]) throws {
        let id = try header.int64(0)
        guard let data = try header.table(1) else { throw ColumnarError.malformed(String(localized: "a dictionary batch without data", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let isDelta = try header.bool(2)
        guard let field = Self.dictionaryField(id, in: fields) else { return }   // a dictionary nothing uses
        guard message.bodyLength <= Int64(limits.maxDictionaryBytes) else {
            throw ColumnarError.tooLarge(String(localized: "a \(ByteCountFormatter.string(fromByteCount: message.bodyLength, countStyle: .file)) dictionary", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        var valueField = field
        valueField.dictionary = nil
        let batch = try ArrowBatch(table: data, bodyOffset: message.bodyOffset, bodyLength: message.bodyLength, source: source,
                                   fields: [valueField], version: version, limits: limits)
        let declared = try data.int64(0)
        guard declared >= 0, declared <= Int64(Int32.max) else { throw ColumnarError.malformed(String(localized: "a dictionary claims \(declared) values", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        // Never more values than the batch's own node holds (the rest would be nulls nothing can point to).
        let rows = min(Int(declared), batch.nodes.first?.length ?? 0)
        var budget = limits.maxDictionaryBytes
        let vector = try batch.column(0, rows: 0..<rows, dictionaries: [:], budget: &budget)
        if isDelta, let old = dictionaries[id] { dictionaries[id] = old.appending(vector) } else { dictionaries[id] = vector }
    }

    static func dictionaryField(_ id: Int64, in fields: [ArrowField]) -> ArrowField? {
        for f in fields {
            if f.dictionary?.id == id { return f }
            if let found = dictionaryField(id, in: f.children) { return found }
        }
        return nil
    }

    public var parts: [ColumnarPart] { [ColumnarPart(name: String(localized: "Rows", bundle: .module, comment: "Name of the single table of a Parquet or Arrow file."), rows: tableObject.rowCount)] }

    public func table(_ part: Int) throws -> any ColumnarTable { tableObject }

    public var facts: [ColumnarFact] {
        var out = [ColumnarFact(key: "rows", String(localized: "Rows", bundle: .module, comment: "Fact label in a column file's (Parquet, Arrow, Excel) File tab."), tableObject.rowCount.formatted()),
                   ColumnarFact(key: "columns", String(localized: "Columns", bundle: .module, comment: "Fact label in a column file's (Parquet, Arrow, Excel) File tab."), fields.count.formatted())]
        let rows = batches.map(\.rows)
        out.append(ColumnarFact(key: "recordbatches", String(localized: "Record batches", bundle: .module, comment: "Fact label: the number of Arrow record batches."), batches.isEmpty ? 0.formatted()
            : (Set(rows).count == 1 ? "\(batches.count.formatted()) × \(rows[0].formatted())"
               : "\(batches.count.formatted()) × ~\((tableObject.rowCount / batches.count).formatted())")))
        if !dictionaries.isEmpty { out.append(ColumnarFact(key: "dictionaries", String(localized: "Dictionaries", bundle: .module, comment: "Fact label: the number of Arrow dictionary batches."), dictionaries.count.formatted())) }
        out.append(ColumnarFact(key: "compression", String(localized: "Compression", bundle: .module, comment: "Fact label in a column file's (Parquet, Arrow, Excel) File tab."), tableObject.compressionName))
        out.append(ColumnarFact(key: "format", String(localized: "Format", bundle: .module, comment: "Fact label in a column file's (Parquet, Arrow, Excel) File tab."), format == .arrowStream || footerMissing
            ? String(localized: "Arrow IPC stream, metadata V\(metadataVersion + 1)", bundle: .module, comment: "Format fact value; the argument is the Arrow metadata version number.")
            : String(localized: "Arrow IPC file, metadata V\(metadataVersion + 1)", bundle: .module, comment: "Format fact value; the argument is the Arrow metadata version number.")))
        if footerMissing { out.append(ColumnarFact(key: "footer", String(localized: "Footer", bundle: .module, comment: "Fact label: the Arrow file footer."), String(localized: "missing: the batches were read in order", bundle: .module, comment: "Footer fact value when an Arrow file has no footer."))) }
        if !schemaMetadataKeys.isEmpty {
            let named = schemaMetadataKeys.map { $0 == "pandas" ? String(localized: "pandas schema", bundle: .module, comment: "A metadata key holding a pandas schema; pandas is a product name.") : $0 }
            let rest = named.count - 1
            out.append(ColumnarFact(key: "metadata", String(localized: "Metadata", bundle: .module, comment: "Fact label: the metadata keys stored in a column file."), rest == 0 ? named[0]
                : rest == 1 ? String(localized: "\(named[0]) · 1 more key", bundle: .module, comment: "Metadata fact value: the first metadata key's name, then one more key.")
                : String(localized: "\(named[0]) · \(rest) more keys", bundle: .module, comment: "Metadata fact value: the first metadata key's name, then how many more keys (2 or more).")))
        }
        return out
    }
}
