import Foundation

/// How many data rows a file has, as far as Vitrine knows. Until the index finishes the honest answer is "at least".
public enum CSVRowCount: Sendable, Equatable, Codable {
    case exactly(Int)
    case atLeast(Int)

    /// The number known so far: exact, or a lower bound.
    public var known: Int {
        switch self {
        case .exactly(let n), .atLeast(let n): n
        }
    }

    public var isExact: Bool { if case .exactly = self { true } else { false } }

    /// `12,345` or `≥ 12,345`.
    public func formatted(locale: Locale = .current) -> String {
        let number = known.formatted(.number.locale(locale))
        return isExact ? number : String(localized: "≥ \(number)", bundle: .module, comment: "A lower bound: at least this many; the argument is a formatted number.")
    }
}

/// Why the rows shown are not known to be all of them.
public enum CSVPartialReason: Sendable, Equatable, Codable {
    /// The index is still running (a progress snapshot).
    case indexing(scannedBytes: Int64, fileSize: Int64)
    /// The index stopped at `CSVOptions.indexByteLimit`.
    case byteLimit(scannedBytes: Int64, fileSize: Int64)
    /// Only the first page was read (no index yet), and it was not the whole file.
    case firstPageOnly

    /// What the preview says on screen.
    public var description: String {
        func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }
        switch self {
        case .indexing(let scanned, let total): return String(localized: "Counting rows: \(size(scanned)) of \(size(total)) read", bundle: .module, comment: "Progress while counting CSV rows; the arguments are byte sizes such as 12 MB.")
        case .byteLimit(let scanned, let total): return String(localized: "Rows counted in the first \(size(scanned)) of \(size(total))", bundle: .module, comment: "Coverage note when row counting stopped at a limit; the arguments are byte sizes.")
        case .firstPageOnly: return String(localized: "Showing the first rows; the rest are still being counted", bundle: .module, comment: "Coverage note while a large CSV is still being indexed.")
        }
    }
}

/// How much of the table the preview can account for: the engine's side of ARCHITECTURE §4
/// `Coverage.partial(shown:total:unit: .rows, reason:)`, which the document layer maps it to.
public enum CSVCoverage: Sendable, Equatable, Codable {
    case complete(rows: Int)
    /// `shownRows` are known and reachable; `totalRows` is nil while the total is unknown.
    case partial(shownRows: Int, totalRows: Int?, reason: CSVPartialReason)

    public var isComplete: Bool { if case .complete = self { true } else { false } }
}

/// Byte offsets of every `stride`-th data row, built in one quote-aware pass, so `rows(in:)` can seek near any row
/// and parse only a few hundred records. The index holds no field data: a 10 GB file with 50 million rows costs about
/// 100k offsets (800 KB).
public struct CSVRowIndex: Sendable, Equatable, Codable {
    public enum State: Sendable, Equatable, Codable {
        /// A progress snapshot; more rows may follow.
        case indexing
        /// Every row of the file is counted.
        case complete
        /// Scanning stopped at the configured byte limit; rows past it exist but are not counted.
        case stoppedAtByteLimit
    }

    public let stride: Int
    /// `checkpoints[k]` is the byte offset where data row `k * stride` starts.
    public internal(set) var checkpoints: [Int64]
    /// Data rows fully scanned.
    public internal(set) var indexedRows: Int
    /// Absolute offset scanning has reached.
    public internal(set) var scannedBytes: Int64
    public let fileSize: Int64
    public internal(set) var state: State
    /// Rows whose field count differs from the table's column count.
    public internal(set) var raggedRows: Int
    /// The first few ragged rows (data row numbers, 0-based), for the lint banner.
    public internal(set) var raggedRowSamples: [Int]
    /// The most fields any row had: more than the column count means some rows carry extra cells.
    public internal(set) var maxFieldCount: Int
    /// The file ends inside an open quote, so the last row ran to the end of the file.
    public internal(set) var endsInsideQuotes: Bool

    static let raggedSampleLimit = 8

    public var isComplete: Bool { state == .complete }

    public var rowCount: CSVRowCount { isComplete ? .exactly(indexedRows) : .atLeast(indexedRows) }

    /// Ragged rows found so far: exact once the index is complete.
    public var raggedRowCount: CSVRowCount { isComplete ? .exactly(raggedRows) : .atLeast(raggedRows) }

    public var coverage: CSVCoverage {
        switch state {
        case .complete: .complete(rows: indexedRows)
        case .indexing: .partial(shownRows: indexedRows, totalRows: nil,
                                 reason: .indexing(scannedBytes: scannedBytes, fileSize: fileSize))
        case .stoppedAtByteLimit: .partial(shownRows: indexedRows, totalRows: nil,
                                           reason: .byteLimit(scannedBytes: scannedBytes, fileSize: fileSize))
        }
    }

    /// The nearest checkpoint at or before `row`.
    func checkpoint(atOrBefore row: Int) -> (row: Int, offset: Int64)? {
        guard !checkpoints.isEmpty, row >= 0 else { return nil }
        let k = min(row / stride, checkpoints.count - 1)
        return (k * stride, checkpoints[k])
    }
}

/// The indexer's view of the scan: record starts and field counts, never field content.
struct CSVIndexSink: CSVScanSink {
    var index: CSVRowIndex
    let expectedFields: Int
    private var fieldsInRecord = 0

    init(index: CSVRowIndex, expectedFields: Int) { self.index = index; self.expectedFields = expectedFields }

    mutating func recordStarted(at offset: Int64) {
        if index.indexedRows % index.stride == 0 { index.checkpoints.append(offset) }
        fieldsInRecord = 0
    }

    mutating func fieldBytes(_ bytes: UnsafeBufferPointer<UInt8>) {}

    mutating func fieldEnded() { fieldsInRecord += 1 }

    mutating func recordEnded(at endOffset: Int64) -> Bool {
        if expectedFields > 0, fieldsInRecord != expectedFields {
            index.raggedRows += 1
            if index.raggedRowSamples.count < CSVRowIndex.raggedSampleLimit { index.raggedRowSamples.append(index.indexedRows) }
        }
        index.maxFieldCount = max(index.maxFieldCount, fieldsInRecord)
        index.indexedRows += 1
        return true
    }
}

extension CSVTable {
    /// Builds the row index in one pass from the first data row, reading `options.readChunkBytes` at a time through a
    /// FileHandle. Checks for cancellation before every chunk (throwing `CancellationError`), and hands `progress` a
    /// snapshot (state `.indexing`) every `options.progressIntervalBytes`, so the preview can say "at least N rows"
    /// and page into what is indexed while the rest is counted. Stops at `options.indexByteLimit` with state
    /// `.stoppedAtByteLimit`. `options` defaults to the ones the table was opened with.
    public func buildIndex(options: CSVOptions? = nil,
                           progress: (@Sendable (CSVRowIndex) -> Void)? = nil) async throws -> CSVRowIndex {
        let options = options ?? self.options
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(dataStartOffset))

        let stride = max(1, options.indexStride)
        let empty = CSVRowIndex(stride: stride, checkpoints: [], indexedRows: 0, scannedBytes: dataStartOffset,
                                fileSize: fileSize, state: .indexing, raggedRows: 0, raggedRowSamples: [],
                                maxFieldCount: 0, endsInsideQuotes: false)
        var sink = CSVIndexSink(index: empty, expectedFields: columnCount)
        var scanner = CSVScanner(dialect: dialect, startOffset: dataStartOffset)
        let limit = max(options.indexByteLimit, dataStartOffset)
        let chunkBytes = max(4096, options.readChunkBytes)
        var nextProgress = dataStartOffset + max(1, options.progressIntervalBytes)

        while true {
            try Task.checkCancellation()
            let room = limit - scanner.position
            if room <= 0 {
                sink.index.state = .stoppedAtByteLimit
                break
            }
            guard let chunk = try handle.read(upToCount: Int(min(Int64(chunkBytes), room))), !chunk.isEmpty else {
                scanner.finish(into: &sink)
                sink.index.state = .complete
                break
            }
            chunk.withUnsafeBytes { raw in _ = scanner.scan(raw.bindMemory(to: UInt8.self), into: &sink) }
            sink.index.scannedBytes = scanner.position
            if let progress, scanner.position >= nextProgress {
                nextProgress = scanner.position + max(1, options.progressIntervalBytes)
                progress(sink.index)
            }
        }
        var index = sink.index
        index.scannedBytes = scanner.position
        index.endsInsideQuotes = scanner.endedInsideQuotes
        if index.state == .stoppedAtByteLimit, scanner.position >= fileSize {
            // The limit fell exactly at the end of the file: nothing was left out.
            scanner.finish(into: &sink)
            index = sink.index
            index.state = .complete
            index.endsInsideQuotes = scanner.endedInsideQuotes
        }
        return index
    }
}
