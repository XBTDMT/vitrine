import Foundation

/// One record as the preview shows it.
public struct CSVRow: Sendable, Equatable, Codable {
    /// The decoded fields, as many as the record had: ragged rows keep their own count.
    public var fields: [String]
    /// Byte offset of the record's first byte, for lint evidence and "reveal in source".
    public var offset: Int64
    /// A field was longer than `CSVOptions.maxFieldBytes` and ends in "…".
    public var hasTruncatedField: Bool

    public init(fields: [String], offset: Int64 = 0, hasTruncatedField: Bool = false) {
        self.fields = fields; self.offset = offset; self.hasTruncatedField = hasTruncatedField
    }

    /// The field at `column`, or "" past the end of a short row.
    public subscript(column: Int) -> String { column >= 0 && column < fields.count ? fields[column] : "" }
}

/// Every bound the engine works within. The defaults fit ARCHITECTURE §7: a first page well inside 300 ms at any file
/// size and nothing that grows with the file except the index's offsets.
public struct CSVOptions: Sendable, Equatable {
    /// Bytes the dialect is sniffed from.
    public var sampleBytes = 64 * 1024
    /// Data rows in the first page.
    public var firstPageRows = 200
    /// The first page stops early past this many bytes (a few enormous rows must not stall the first paint).
    public var firstPageByteLimit = 16 * 1024 * 1024
    /// A checkpoint every this many rows. 512 keeps a seek within half a millisecond of parsing of any row.
    public var indexStride = 512
    /// Indexing stops here and reports partial coverage.
    public var indexByteLimit: Int64 = 4 * 1024 * 1024 * 1024
    /// Bytes per FileHandle read while indexing.
    public var readChunkBytes = 1024 * 1024
    /// Bytes per FileHandle read while paging, which only ever needs a few hundred rows.
    public var pageChunkBytes = 128 * 1024
    /// How often `buildIndex` reports progress.
    public var progressIntervalBytes: Int64 = 16 * 1024 * 1024
    /// Longer fields are cut to this many bytes and end in "…", so one 100 MB cell cannot exhaust the extension.
    public var maxFieldBytes = 64 * 1024

    public init() {}
}

/// The first rows of a file, read before any index exists.
public struct CSVPage: Sendable, Equatable {
    public var rows: [CSVRow]
    /// True when these are all the file's data rows.
    public var reachesEndOfFile: Bool
    /// Rows here whose field count differs from the column count.
    public var raggedRows: Int
}

/// A delimited file opened for preview: dialect, header and first page at once, everything else on demand. A value
/// type that holds no file handle, so it crosses actors freely; each read opens its own handle.
public struct CSVTable: Sendable {
    public let url: URL
    public let fileSize: Int64
    public let dialect: CSVDialect
    /// The column names, when the file has a header row.
    public let header: [String]?
    /// The header's width, or without a header the most common field count in the first page.
    public let columnCount: Int
    public let firstPage: CSVPage
    /// Where data row 0 starts (after the BOM and the header).
    public let dataStartOffset: Int64
    let options: CSVOptions

    /// Opens `url`: sniffs the first `options.sampleBytes` and parses the first page. The cost is bounded by the
    /// options, never by the file size.
    /// - Parameter delimiterHint: the delimiter the caller expects; nil uses the file extension (`.tsv` → tab).
    public static func open(_ url: URL, delimiterHint: CSVDelimiter? = nil, options: CSVOptions = CSVOptions()) throws -> CSVTable {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let sample = try handle.read(upToCount: max(1024, options.sampleBytes)) ?? Data()
        let dialect = try CSVDialectSniffer.sniff(sample, isWholeFile: Int64(sample.count) >= fileSize,
                                                  delimiterHint: delimiterHint ?? CSVDelimiter(fileExtension: url.pathExtension))

        let headerRecords = dialect.hasHeader ? 1 : 0
        // One row more than the page, so a file of exactly `firstPageRows` rows is known to have ended.
        var collector = CSVRecordCollector(encoding: dialect.encoding, maxFieldBytes: options.maxFieldBytes,
                                           limit: headerRecords + options.firstPageRows + 1)
        let reachedEnd = try parse(handle, from: dialect.contentOffset, dialect: dialect, collector: &collector,
                                   chunkBytes: options.pageChunkBytes,
                                   byteLimit: Int64(max(options.sampleBytes, options.firstPageByteLimit)))

        var records = collector.rows
        var header: [String]?
        var dataStart = dialect.contentOffset
        if dialect.hasHeader, !records.isEmpty {
            header = records.removeFirst().fields
            dataStart = records.first?.offset ?? collector.lastRecordEnd
        } else if let first = records.first {
            dataStart = first.offset
        }
        let complete = reachedEnd && records.count <= options.firstPageRows
        if records.count > options.firstPageRows { records.removeLast(records.count - options.firstPageRows) }

        let columnCount = header?.count ?? mostCommonFieldCount(records)
        let ragged = records.reduce(0) { $0 + ($1.fields.count != columnCount ? 1 : 0) }
        return CSVTable(url: url, fileSize: fileSize, dialect: dialect, header: header, columnCount: columnCount,
                        firstPage: CSVPage(rows: records, reachesEndOfFile: complete, raggedRows: ragged),
                        dataStartOffset: dataStart, options: options)
    }

    /// The name of column `index`: its header, or "Column N" (1-based) when there is none or it is blank.
    public func columnTitle(_ index: Int) -> String {
        if let header, index < header.count {
            let name = header[index].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return header[index] }
        }
        return String(localized: "Column \(index + 1)", bundle: .module, comment: "Name of a CSV column that has no header; the argument is its 1-based number.")
    }

    /// Row count as far as is known: exact when the first page held the whole file or the index is complete.
    public func rowCount(index: CSVRowIndex?) -> CSVRowCount {
        if firstPage.reachesEndOfFile { return .exactly(firstPage.rows.count) }
        guard let index else { return .atLeast(firstPage.rows.count) }
        if index.isComplete { return .exactly(index.indexedRows) }
        return .atLeast(max(index.indexedRows, firstPage.rows.count))
    }

    /// What the preview can account for, in ARCHITECTURE §4 terms.
    public func coverage(index: CSVRowIndex?) -> CSVCoverage {
        if firstPage.reachesEndOfFile { return .complete(rows: firstPage.rows.count) }
        guard let index else { return .partial(shownRows: firstPage.rows.count, totalRows: nil, reason: .firstPageOnly) }
        return index.coverage
    }

    /// Data rows `range` (0-based, header excluded). Seeks to the nearest known row start at or before the range (a
    /// first-page row or an index checkpoint) and parses forward only as far as the range needs. Returns fewer rows
    /// when the file ends first. Without an index, rows past the first page are reached by scanning from the first
    /// page's end, so callers should page beyond it only with an index (a progress snapshot is enough).
    public func rows(in range: Range<Int>, index: CSVRowIndex? = nil) throws -> [CSVRow] {
        let lower = max(0, range.lowerBound)
        guard range.upperBound > lower else { return [] }
        let page = firstPage.rows
        if range.upperBound <= page.count { return Array(page[lower..<range.upperBound]) }
        if firstPage.reachesEndOfFile { return lower < page.count ? Array(page[lower...]) : [] }

        var start = (row: 0, offset: dataStartOffset)
        if lower < page.count { start = (lower, page[lower].offset) } else if let last = page.last { start = (page.count - 1, last.offset) }
        if let checkpoint = index?.checkpoint(atOrBefore: lower), checkpoint.row > start.row { start = checkpoint }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var collector = CSVRecordCollector(encoding: dialect.encoding, maxFieldBytes: options.maxFieldBytes,
                                           skip: lower - start.row, limit: range.upperBound - lower)
        _ = try Self.parse(handle, from: start.offset, dialect: dialect, collector: &collector,
                           chunkBytes: options.pageChunkBytes, byteLimit: nil)
        return collector.rows
    }

    /// Rows for type inference and the profile, spread over the file rather than only its top (files are often
    /// sorted, and the first 200 rows of a sorted file describe one corner of it). With an index, takes `spread`
    /// equal runs evenly spaced from the first indexed row to the last, each reached through the nearest checkpoint;
    /// otherwise the first page.
    public func sampleRows(index: CSVRowIndex?, maxRows: Int = 2000, spread: Int = 8) throws -> [CSVRow] {
        let total = rowCount(index: index).known
        guard let index, total > firstPage.rows.count else { return Array(firstPage.rows.prefix(maxRows)) }
        if total <= maxRows { return try rows(in: 0..<total, index: index) }
        let runs = max(1, min(spread, maxRows))
        let perRun = maxRows / runs
        var sample: [CSVRow] = []
        sample.reserveCapacity(maxRows)
        for run in 0..<runs {
            let first = runs == 1 ? 0 : (total - perRun) * run / (runs - 1)
            sample += try rows(in: first..<(first + perRun), index: index)
        }
        return sample
    }

    /// The column types of a sample (by default `sampleRows(index:)`).
    public func inferColumnTypes(sample: [CSVRow]) -> [CSVColumnTypeInfo] {
        CSVColumnInference.infer(rows: sample, columnCount: columnCount, dialect: dialect)
    }

    // MARK: Reading

    /// Runs the scanner over the file from `offset` until the collector is full, the file ends or `byteLimit` bytes
    /// have been read. Returns true when the file ended (every record up to it was delivered).
    static func parse(_ handle: FileHandle, from offset: Int64, dialect: CSVDialect, collector: inout CSVRecordCollector,
                      chunkBytes: Int, byteLimit: Int64?) throws -> Bool {
        try handle.seek(toOffset: UInt64(offset))
        var scanner = CSVScanner(dialect: dialect, startOffset: offset)
        var read: Int64 = 0
        while !collector.isFull {
            if let byteLimit, read >= byteLimit { return false }
            guard let chunk = try handle.read(upToCount: max(4096, chunkBytes)), !chunk.isEmpty else {
                scanner.finish(into: &collector)
                return true
            }
            read += Int64(chunk.count)
            let stopped = chunk.withUnsafeBytes { raw in scanner.scan(raw.bindMemory(to: UInt8.self), into: &collector) }
            if stopped { return false }
        }
        return false
    }

    static func mostCommonFieldCount(_ rows: [CSVRow]) -> Int {
        var frequency: [Int: Int] = [:]
        for row in rows { frequency[row.fields.count, default: 0] += 1 }
        return frequency.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 0
    }
}
