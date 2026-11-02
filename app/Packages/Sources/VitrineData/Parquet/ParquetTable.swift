import Foundation
import VitrineSupport

/// The rows of a Parquet file. A read of rows `a..<b` finds the row groups that hold them and, for each column chunk,
/// walks its page headers (remembered once read) to the pages that cover the rows: data pages v1 and v2, the
/// dictionary page decoded once per chunk, levels and values by `ParquetDecode`, pages decompressed by
/// `ColumnarCodecs`. A column chunk that cannot be decoded gives empty cells and a warning naming the reason; the
/// rest of the table still reads. roadmap: S-21
final class ParquetTable: ColumnarTable, @unchecked Sendable {
    let source: any ByteSource
    let metadata: ParquetFileMetadata
    let leaves: [ParquetLeaf]
    let limits: ColumnarLimits
    let columns: [ColumnarColumn]
    let rowCount: Int
    let chunks: [ColumnarChunk]
    /// First row of each row group.
    private let starts: [Int]
    private let lock = NSLock()
    private var states: [ChunkKey: ChunkState] = [:]
    /// Row groups whose chunk states are kept, most recent last.
    private var recentGroups: [Int] = []
    private var warningList: [String] = []

    struct ChunkKey: Hashable { var group: Int; var column: Int }

    /// What is known of one column chunk: its pages so far and its decoded dictionary.
    final class ChunkState {
        var pages: [Page] = []
        /// Where the next page header is, and the values seen before it.
        var nextOffset: Int64
        var valuesSeen: Int64 = 0
        var rowsSeen = 0
        var finished = false
        var dictionary: ColumnVector?
        var dictionaryRead = false
        /// The page decoded last: windows read one after another (scrolling, a filter's pass) reuse it.
        var lastPage: (index: Int, rows: ColumnVector)?
        init(start: Int64) { nextOffset = start }
    }

    struct Page {
        var header: ParquetPageHeader
        var dataOffset: Int64
        var firstRow: Int
        /// Rows in the page; nil until a repeated column's v1 page is decoded.
        var rows: Int?
    }

    init(source: any ByteSource, metadata: ParquetFileMetadata, leaves: [ParquetLeaf], limits: ColumnarLimits) {
        self.source = source
        self.metadata = metadata
        self.leaves = leaves
        self.limits = limits
        var starts: [Int] = []
        var total = 0
        for g in metadata.rowGroups { starts.append(total); total += Int(clamping: g.numRows) }
        self.starts = starts
        rowCount = total
        chunks = metadata.rowGroups.map { g in
            ColumnarChunk(rows: Int(clamping: g.numRows),
                          bytes: g.totalCompressedSize ?? g.columns.reduce(Int64(0)) { $0 &+ ($1.meta?.totalCompressed ?? 0) },
                          uncompressedBytes: g.totalByteSize)
        }
        columns = ParquetTable.withStatistics(leaves: leaves, metadata: metadata)
    }

    var warnings: [String] { lock.withLock { warningList } }

    func read(rows wanted: Range<Int>, isCancelled: @Sendable () -> Bool) throws -> ColumnarWindow {
        let lower = max(0, min(wanted.lowerBound, rowCount))
        let upper = max(lower, min(wanted.upperBound, rowCount, lower + limits.maxWindowRows))
        lock.lock()
        defer { lock.unlock() }
        var vectors: [ColumnVector]? = nil
        var budget = limits.maxWindowBytes
        var group = Self.groupIndex(of: lower, starts: starts)
        while group < starts.count, starts[group] < upper {
            let groupRows = Int(clamping: metadata.rowGroups[group].numRows)
            let a = max(lower, starts[group]) - starts[group]
            let b = min(upper, starts[group] + groupRows) - starts[group]
            if b > a {
                touch(group)
                var part: [ColumnVector] = []
                for c in leaves.indices {
                    if isCancelled() { throw ColumnarError.cancelled }
                    part.append(try column(group: group, column: c, rows: a..<b, budget: &budget, isCancelled: isCancelled))
                }
                vectors = vectors.map { zip($0, part).map { $0.appending($1) } } ?? part
            }
            group += 1
        }
        return ColumnarWindow(start: lower, count: upper - lower, columns: vectors ?? leaves.map { _ in .nulls(0) })
    }

    static func groupIndex(of row: Int, starts: [Int]) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= row { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }

    /// Keeps the chunk states of the two most recent row groups (their page lists and dictionaries).
    private func touch(_ group: Int) {
        recentGroups.removeAll { $0 == group }
        recentGroups.append(group)
        while recentGroups.count > 2 {
            let old = recentGroups.removeFirst()
            states = states.filter { $0.key.group != old }
        }
    }

    private func warn(_ text: String) {
        if !warningList.contains(text), warningList.count < 100 { warningList.append(text) }
    }

    // MARK: One column chunk

    private func column(group: Int, column c: Int, rows: Range<Int>, budget: inout Int, isCancelled: () -> Bool) throws -> ColumnVector {
        let leaf = leaves[c]
        if leaf.column.isOmitted { return .nulls(rows.count) }
        do {
            let vector = try readChunk(group: group, column: c, rows: rows, budget: &budget, isCancelled: isCancelled)
            if vector.count < rows.count {
                warn(String(localized: "Column \(leaf.name) in row group \(group + 1) holds fewer rows than the row group says", bundle: .module, comment: "Warning shown above a Parquet table; the arguments are a column name and a 1-based row group number."))
                return vector.appending(.nulls(rows.count - vector.count))
            }
            return vector
        } catch ColumnarError.cancelled {
            throw ColumnarError.cancelled
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            warn(String(localized: "Column \(leaf.name) in row group \(group + 1) could not be read. \(reason)", bundle: .module, comment: "Warning shown above a Parquet table; the arguments are a column name, a 1-based row group number and the error sentence."))
            return .nulls(rows.count)
        }
    }

    private func state(group: Int, column c: Int) throws -> ChunkState {
        let key = ChunkKey(group: group, column: c)
        if let s = states[key] { return s }
        guard let meta = metadata.rowGroups[group].columns[c].meta else { throw ColumnarError.malformed(String(localized: "the column chunk has no metadata", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var start = meta.dataPageOffset
        if let d = meta.dictionaryPageOffset, d > 0, d < start { start = d }
        guard start >= 4, start < source.size else { throw ColumnarError.malformed(String(localized: "a column chunk starts outside the file", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let s = ChunkState(start: start)
        states[key] = s
        return s
    }

    private func readChunk(group: Int, column c: Int, rows: Range<Int>, budget: inout Int, isCancelled: () -> Bool) throws -> ColumnVector {
        let leaf = leaves[c]
        guard let meta = metadata.rowGroups[group].columns[c].meta else { throw ColumnarError.malformed(String(localized: "the column chunk has no metadata", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        let codec = try ParquetThrift.codec(meta.codec)
        let state = try state(group: group, column: c)
        var result: ColumnVector?
        var pageIndex = 0
        while true {
            if isCancelled() { throw ColumnarError.cancelled }
            // Make sure the page list reaches page `pageIndex`.
            while pageIndex >= state.pages.count, !state.finished {
                try nextPage(state, meta: meta, leaf: leaf, codec: codec, budget: &budget)
            }
            guard pageIndex < state.pages.count else { break }
            var page = state.pages[pageIndex]
            var cached: ColumnVector?
            if page.rows == nil {
                // A repeated column's v1 page: its rows are known once its levels are decoded.
                let decoded = try decodePage(page, meta: meta, leaf: leaf, codec: codec, state: state, budget: &budget)
                cached = decoded
                state.pages[pageIndex].rows = decoded.count
                state.rowsSeen += decoded.count
                for k in (pageIndex + 1)..<state.pages.count {
                    state.pages[k].firstRow = state.pages[k - 1].firstRow + (state.pages[k - 1].rows ?? 0)
                }
                page = state.pages[pageIndex]
            }
            let pageRows = page.rows ?? 0
            let pageRange = page.firstRow..<(page.firstRow + pageRows)
            if pageRange.lowerBound >= rows.upperBound { break }
            if pageRange.overlaps(rows) {
                let decoded: ColumnVector
                if let cached { decoded = cached }
                else if let last = state.lastPage, last.index == pageIndex { decoded = last.rows }
                else { decoded = try decodePage(page, meta: meta, leaf: leaf, codec: codec, state: state, budget: &budget) }
                state.lastPage = (pageIndex, decoded)
                let from = max(rows.lowerBound, pageRange.lowerBound) - page.firstRow
                let to = min(rows.upperBound, pageRange.upperBound) - page.firstRow
                let piece = decoded.slice(from..<to)
                result = result.map { $0.appending(piece) } ?? piece
            }
            pageIndex += 1
        }
        return result ?? .nulls(0)
    }

    /// Reads the next page header of a chunk; dictionary pages are decoded on the spot.
    private func nextPage(_ state: ChunkState, meta: ParquetColumnMeta, leaf: ParquetLeaf, codec: ColumnarCodecs.Codec?, budget: inout Int) throws {
        guard state.valuesSeen < meta.numValues, state.nextOffset < source.size else { state.finished = true; return }
        guard state.pages.count < 4_000_000 else { throw ColumnarError.tooLarge(String(localized: "a column chunk with more than \(4_000_000.formatted()) pages", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var window = 16 * 1024
        var header = ParquetPageHeader()
        var headerLength = 0
        while true {
            let bytes = try source.read(at: state.nextOffset, count: window)
            var reader = ThriftReader(bytes: bytes, maxDepth: limits.maxDepth)
            do {
                header = try ParquetThrift.pageHeader(&reader)
                headerLength = reader.position
                break
            } catch ColumnarError.truncated(let why) {
                if bytes.count < window { throw ColumnarError.truncated(String(localized: "a page header (\(why))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                guard window < 16 * 1024 * 1024 else { throw ColumnarError.tooLarge(String(localized: "a page header over 16 MB", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                window *= 4
            }
        }
        guard header.compressedSize >= 0, header.uncompressedSize >= 0 else { throw ColumnarError.malformed(String(localized: "a page with a negative size", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        guard Int(header.compressedSize) <= limits.maxPageBytes, Int(header.uncompressedSize) <= limits.maxPageBytes else {
            throw ColumnarError.tooLarge(String(localized: "a page claims \(ByteCountFormatter.string(fromByteCount: Int64(max(header.compressedSize, header.uncompressedSize)), countStyle: .file))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        let dataOffset = state.nextOffset + Int64(headerLength)
        guard dataOffset + Int64(header.compressedSize) <= source.size else { throw ColumnarError.truncated(String(localized: "a page runs past the end of the file", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        state.nextOffset = dataOffset + Int64(header.compressedSize)
        switch ParquetPageType(rawValue: header.type) {
        case .dictionary?:
            guard !state.dictionaryRead else { throw ColumnarError.malformed(String(localized: "a column chunk with two dictionary pages", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            state.dictionaryRead = true
            state.dictionary = try decodeDictionary(header, dataOffset: dataOffset, leaf: leaf, codec: codec, budget: &budget)
        case .data?, .dataV2?:
            guard header.numValues >= 0 else { throw ColumnarError.malformed(String(localized: "a page with a negative value count", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            let firstRow = state.rowsSeen
            var rows: Int?
            if leaf.maxRepetition == 0 { rows = Int(header.numValues) }
            else if header.type == ParquetPageType.dataV2.rawValue { rows = Int(header.numRows) }
            state.pages.append(Page(header: header, dataOffset: dataOffset, firstRow: firstRow, rows: rows))
            state.rowsSeen += rows ?? 0
            state.valuesSeen += Int64(header.numValues)
        case .index?, nil:
            break   // index pages and unknown kinds are skipped by their size
        }
    }

    // MARK: Pages

    private func payload(offset: Int64, compressed: Int, uncompressed: Int, codec: ColumnarCodecs.Codec?, budget: inout Int) throws -> [UInt8] {
        let raw = try source.read(at: offset, count: compressed)
        guard raw.count == compressed else { throw ColumnarError.truncated(String(localized: "a page ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        guard let codec else { return raw }
        budget -= uncompressed
        guard budget >= 0 else { throw ColumnarError.tooLarge(String(localized: "the rows asked for decompress to more than \(limits.maxWindowBytes / 1_048_576) MB", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return try ColumnarCodecs.decompress(raw[...], codec: codec, expected: uncompressed)
    }

    private func decodeDictionary(_ header: ParquetPageHeader, dataOffset: Int64, leaf: ParquetLeaf, codec: ColumnarCodecs.Codec?, budget: inout Int) throws -> ColumnVector {
        guard Int(header.uncompressedSize) <= limits.maxDictionaryBytes else {
            throw ColumnarError.tooLarge(String(localized: "a dictionary of \(ByteCountFormatter.string(fromByteCount: Int64(header.uncompressedSize), countStyle: .file))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        guard header.dictionaryEncoding == 0 || header.dictionaryEncoding == 2 else {
            throw ColumnarError.unsupported(String(localized: "a dictionary page in \(ParquetThrift.encodingName(header.dictionaryEncoding))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        let bytes = try payload(offset: dataOffset, compressed: Int(header.compressedSize), uncompressed: Int(header.uncompressedSize),
                                codec: codec, budget: &budget)
        guard header.dictionaryValues >= 0 else { throw ColumnarError.malformed(String(localized: "a dictionary with a negative size", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        var reader = ParquetBytes(bytes)
        let values = try ParquetValues.plain(&reader, leaf: leaf, count: Int(header.dictionaryValues))
        return ColumnVector(storage: ParquetValues.storage(values, leaf: leaf, limits: limits))
    }

    /// One data page's rows (one entry per row; a repeated column's rows as list text).
    private func decodePage(_ page: Page, meta: ParquetColumnMeta, leaf: ParquetLeaf, codec: ColumnarCodecs.Codec?,
                            state: ChunkState, budget: inout Int) throws -> ColumnVector {
        let h = page.header
        let count = Int(h.numValues)
        let defWidth = Self.bitWidth(leaf.maxDefinition), repWidth = Self.bitWidth(leaf.maxRepetition)
        var repetition: [UInt64] = [], definition: [UInt64] = []
        var values: ParquetBytes
        if h.type == ParquetPageType.dataV2.rawValue {
            // v2: levels first, never compressed; the values after them compressed when `isCompressed`.
            let levelBytes = Int(h.repetitionLength) + Int(h.definitionLength)
            guard h.repetitionLength >= 0, h.definitionLength >= 0, levelBytes <= Int(h.compressedSize), levelBytes <= Int(h.uncompressedSize) else {
                throw ColumnarError.malformed(String(localized: "a v2 page's level lengths exceed the page", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
            }
            let raw = try source.read(at: page.dataOffset, count: Int(h.compressedSize))
            guard raw.count == Int(h.compressedSize) else { throw ColumnarError.truncated(String(localized: "a page ends early", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
            var levels = ParquetBytes(raw, start: 0, end: Int(h.repetitionLength))
            if leaf.maxRepetition > 0 { repetition = try ParquetDecode.hybrid(&levels, width: repWidth, count: count) }
            levels = ParquetBytes(raw, start: Int(h.repetitionLength), end: levelBytes)
            if leaf.maxDefinition > 0 { definition = try ParquetDecode.hybrid(&levels, width: defWidth, count: count) }
            let body = raw[levelBytes...]
            if let codec, h.isCompressed {
                let expected = Int(h.uncompressedSize) - levelBytes
                budget -= expected
                guard budget >= 0 else { throw ColumnarError.tooLarge(String(localized: "the rows asked for decompress to more than \(limits.maxWindowBytes / 1_048_576) MB", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
                values = ParquetBytes(try ColumnarCodecs.decompress(body, codec: codec, expected: expected))
            } else {
                values = ParquetBytes(Array(body))
            }
        } else {
            let bytes = try payload(offset: page.dataOffset, compressed: Int(h.compressedSize), uncompressed: Int(h.uncompressedSize),
                                    codec: codec, budget: &budget)
            values = ParquetBytes(bytes)
            if leaf.maxRepetition > 0 { repetition = try Self.levelsV1(&values, encoding: h.repetitionEncoding, width: repWidth, count: count) }
            if leaf.maxDefinition > 0 { definition = try Self.levelsV1(&values, encoding: h.definitionEncoding, width: defWidth, count: count) }
        }
        let maxDef = UInt64(leaf.maxDefinition)
        let present = leaf.maxDefinition > 0 ? definition.reduce(0) { $0 + ($1 == maxDef ? 1 : 0) } : count
        let decoded = try ParquetValues.decode(&values, encoding: h.encoding, leaf: leaf, count: present,
                                               dictionary: state.dictionary, limits: limits)
        if leaf.maxRepetition == 0 {
            guard leaf.maxDefinition > 0 else { return ColumnVector(storage: decoded) }
            return ParquetValues.scatter(decoded, present: definition.map { $0 == maxDef })
        }
        return ParquetValues.lists(decoded, repetition: repetition, definition: definition, leaf: leaf, limits: limits)
    }

    static func levelsV1(_ reader: inout ParquetBytes, encoding: Int32, width: Int, count: Int) throws -> [UInt64] {
        switch encoding {
        case 3:
            let length = Int(try reader.u32())
            let r = try reader.take(length, String(localized: "levels", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
            var levels = ParquetBytes(reader.bytes, start: r.lowerBound, end: r.upperBound)
            return try ParquetDecode.hybrid(&levels, width: width, count: count)
        case 4: return try ParquetDecode.bitPackedLevels(&reader, width: width, count: count)
        default: throw ColumnarError.unsupported(String(localized: "levels in \(ParquetThrift.encodingName(encoding))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
    }

    static func bitWidth(_ maxLevel: Int) -> Int {
        maxLevel <= 0 ? 0 : (Int.bitWidth - maxLevel.leadingZeroBitCount)
    }

    // MARK: Statistics

    /// Each column's footer statistics over every row group: the smallest min, the largest max, the summed null
    /// count. The deprecated min/max fields are used only where their sort order was right (signed numbers).
    static func withStatistics(leaves: [ParquetLeaf], metadata: ParquetFileMetadata) -> [ColumnarColumn] {
        leaves.enumerated().map { c, leaf in
            var column = leaf.column
            guard leaf.maxRepetition == 0, !column.isOmitted else { return column }
            var low: ColumnarCell?, high: ColumnarCell?
            var nulls: Int64? = 0
            var distinct: Int64?
            for group in metadata.rowGroups {
                guard let stats = group.columns[c].meta?.statistics else { nulls = nil; continue }
                if let n = stats.nullCount, let sum = nulls { nulls = sum &+ n } else { nulls = nil }
                if metadata.rowGroups.count == 1 { distinct = stats.distinctCount }
                let legacyOK = ParquetValues.legacyStatisticsUsable(leaf)
                if let bytes = stats.minValue ?? (legacyOK ? stats.min : nil), let v = ParquetValues.statistic(bytes, leaf: leaf),
                   low.map({ ParquetValues.less(v, $0, kind: leaf.valueKind) }) ?? true { low = v }
                if let bytes = stats.maxValue ?? (legacyOK ? stats.max : nil), let v = ParquetValues.statistic(bytes, leaf: leaf),
                   high.map({ ParquetValues.less($0, v, kind: leaf.valueKind) }) ?? true { high = v }
            }
            let s = ColumnarStatistics(min: low.map { ColumnarText.summary($0, kind: column.kind) },
                                       max: high.map { ColumnarText.summary($0, kind: column.kind) },
                                       nullCount: nulls.map { Int(clamping: $0) }, distinctCount: distinct.map { Int(clamping: $0) })
            column.statistics = s.isEmpty || metadata.rowGroups.isEmpty ? nil : s
            return column
        }
    }
}
