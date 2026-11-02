import Foundation

/// Decides a file's dialect from its first bytes only (64 KB by default), so a 10 GB file costs the same to sniff as a
/// 10 KB one. Every decision is a vote over the sample's records, never a guess from the first line alone.
public enum CSVDialectSniffer {
    /// How many records the delimiter and header votes look at.
    static let voteRecords = 500
    static let headerRecords = 50

    /// - Parameters:
    ///   - sample: the first bytes of the file.
    ///   - isWholeFile: true when `sample` is the entire file. Otherwise the sample's last record may be cut short and
    ///     is left out of every vote.
    ///   - delimiterHint: what the file name promises (`.tsv` → tab). Kept unless the sample clearly disagrees.
    public static func sniff(_ sample: Data, isWholeFile: Bool, delimiterHint: CSVDelimiter? = nil) throws -> CSVDialect {
        try sample.withUnsafeBytes { raw in
            try sniff(raw.bindMemory(to: UInt8.self), isWholeFile: isWholeFile, delimiterHint: delimiterHint)
        }
    }

    static func sniff(_ all: UnsafeBufferPointer<UInt8>, isWholeFile: Bool, delimiterHint: CSVDelimiter?) throws -> CSVDialect {
        if all.starts(with: [0xFF, 0xFE]) || all.starts(with: [0xFE, 0xFF]) {
            throw CSVError.unsupportedEncoding(all.starts(with: [0xFF, 0xFE, 0, 0]) ? "UTF-32" : "UTF-16")
        }
        let hasBOM = all.starts(with: [0xEF, 0xBB, 0xBF])
        let bytes = UnsafeBufferPointer(rebasing: all[(hasBOM ? 3 : 0)...])
        if let base = bytes.baseAddress, memchr(base, 0, bytes.count) != nil { throw CSVError.binaryContent }

        let encoding = detectEncoding(bytes, isWholeFile: isWholeFile)
        let quote = detectQuote(bytes)
        let (delimiter, overrode) = detectDelimiter(bytes, quote: quote, isWholeFile: isWholeFile, hint: delimiterHint)

        var scanner = CSVScanner(delimiter: delimiter.rawValue, quote: quote.rawValue)
        var collector = CSVRecordCollector(encoding: encoding, maxFieldBytes: 4096, limit: headerRecords)
        let stopped = scanner.scan(bytes, into: &collector)
        // A cut-off sample's last record may be half a row, so it is completed only when it is the whole file or the
        // only record there is.
        if !stopped && (isWholeFile || collector.rows.isEmpty) { scanner.finish(into: &collector) }
        let records = collector.rows.map(\.fields)
        var dialect = CSVDialect(delimiter: delimiter, quote: quote, hasHeader: false,
                                 lineEnding: scanner.dominantLineEnding, hasBOM: hasBOM, encoding: encoding,
                                 overrodeHint: overrode)
        dialect.hasHeader = detectHeader(records, dialect: dialect)
        return dialect
    }

    // MARK: Encoding

    /// UTF-8 when the whole sample validates (allowing a character cut in half at the sample's end), else Latin-1.
    static func detectEncoding(_ bytes: UnsafeBufferPointer<UInt8>, isWholeFile: Bool) -> CSVTextEncoding {
        if CSVTextDecoder.isValidUTF8(bytes) { return .utf8 }
        if !isWholeFile {
            for cut in 1...3 where bytes.count > cut {
                if CSVTextDecoder.isValidUTF8(UnsafeBufferPointer(rebasing: bytes[..<(bytes.count - cut)])) { return .utf8 }
            }
        }
        return .latin1
    }

    // MARK: Quote

    /// Double quotes unless the sample wraps fields in single quotes and never in double quotes. A field counts as
    /// wrapped when the quote opens it (line start or after a candidate delimiter) and a matching quote closes it
    /// before the next delimiter or line break, so apostrophes inside words (`O'Neil`) never vote.
    static func detectQuote(_ bytes: UnsafeBufferPointer<UInt8>) -> CSVQuote {
        func wrappedFields(_ q: UInt8) -> Int {
            var found = 0
            var i = 0
            let n = bytes.count
            while i < n {
                if bytes[i] == q, i == 0 || isSeparator(bytes[i - 1]) {
                    var j = i + 1
                    while j < n, bytes[j] != q, bytes[j] != CSVScanner.lf, bytes[j] != CSVScanner.cr { j += 1 }
                    if j < n, bytes[j] == q, j + 1 == n || isSeparator(bytes[j + 1]) { found += 1 }
                    i = j + 1
                } else {
                    i += 1
                }
            }
            return found
        }
        if wrappedFields(CSVQuote.double.rawValue) > 0 { return .double }
        return wrappedFields(CSVQuote.single.rawValue) >= 2 ? .single : .double
    }

    private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == CSVScanner.lf || byte == CSVScanner.cr || CSVDelimiter(rawValue: byte) != nil
    }

    // MARK: Delimiter

    struct DelimiterScore: Equatable {
        var delimiter: CSVDelimiter
        /// The most common fields-per-record count.
        var mode: Int
        /// The share of records with exactly `mode` fields; 0 when the delimiter never splits a record.
        var score: Double
    }

    /// Margin by which another delimiter must beat the hint to overrule it.
    static let overrideMargin = 0.25

    /// Each candidate parses the sample; the one that splits records into the same number of fields most consistently
    /// wins. The hint stands unless it never splits anything or another candidate is clearly more consistent.
    static func detectDelimiter(_ bytes: UnsafeBufferPointer<UInt8>, quote: CSVQuote, isWholeFile: Bool,
                                hint: CSVDelimiter?) -> (CSVDelimiter, overrodeHint: Bool) {
        let order = (hint.map { [$0] } ?? []) + CSVDelimiter.allCases.filter { $0 != hint }
        let scores = order.map { score($0, bytes: bytes, quote: quote, isWholeFile: isWholeFile) }
        var best = scores[0]
        for candidate in scores.dropFirst() where (candidate.score, candidate.mode) > (best.score, best.mode) {
            best = candidate
        }
        guard let hint else { return (best.score > 0 ? best.delimiter : .comma, false) }
        let hinted = scores[0]
        if hinted.score > 0, best.score - hinted.score < overrideMargin { return (hint, false) }
        if best.score > 0 { return (best.delimiter, best.delimiter != hint) }
        return (hint, false)   // a single-column file: nothing splits, the name is all we have
    }

    static func score(_ delimiter: CSVDelimiter, bytes: UnsafeBufferPointer<UInt8>, quote: CSVQuote,
                      isWholeFile: Bool) -> DelimiterScore {
        var scanner = CSVScanner(delimiter: delimiter.rawValue, quote: quote.rawValue)
        var sink = CSVFieldCountSink(limit: voteRecords)
        let stopped = scanner.scan(bytes, into: &sink)
        if isWholeFile && !stopped { scanner.finish(into: &sink) }
        var counts = sink.counts
        if counts.isEmpty, !isWholeFile {
            // One record longer than the sample: let its visible part vote rather than nothing.
            scanner.finish(into: &sink)
            counts = sink.counts
        }
        guard !counts.isEmpty else { return DelimiterScore(delimiter: delimiter, mode: 1, score: 0) }
        var frequency: [Int: Int] = [:]
        for count in counts { frequency[count, default: 0] += 1 }
        let mode = frequency.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 1
        let share = Double(frequency[mode] ?? 0) / Double(counts.count)
        // The first line (usually the header) splits like the rest under the right delimiter. A European export's
        // decimal commas ("89,00") make comma look consistent across the data rows while the header has none, so a
        // delimiter that splits the first line differently counts for half.
        let firstAgrees = counts.first == mode
        return DelimiterScore(delimiter: delimiter, mode: mode, score: mode > 1 ? share * (firstAgrees ? 1 : 0.5) : 0)
    }

    // MARK: Header

    /// Whether record 1 names the columns. Each column votes: when the rows below share a type (numbers, dates,
    /// booleans) a first value that does not fit is a label (+1) and one that fits is data (−1); in a text column
    /// whose values all have one length, a first value of another length is a label (+1). With no votes either way,
    /// a first row of distinct, non-empty, non-numeric values is taken as a header: most delimited files have one,
    /// and a wrong "no header" costs the reader the column names.
    static func detectHeader(_ records: [[String]], dialect: CSVDialect) -> Bool {
        guard let first = records.first, !first.isEmpty else { return false }
        let style = CSVValueStyle(decimalComma: dialect.allowsDecimalComma)
        let labelsLookLikeLabels: Bool = {
            let trimmed = first.map { $0.trimmingCharacters(in: .whitespaces) }
            guard !trimmed.contains(where: \.isEmpty), Set(trimmed).count == trimmed.count else { return false }
            return !trimmed.contains { CSVValueClassifier.classify($0, style: style) != .text }
        }()
        let body = records.dropFirst()
        guard !body.isEmpty else { return labelsLookLikeLabels }

        var votes = 0
        for column in first.indices {
            let values = body.compactMap { column < $0.count ? $0[column] : nil }
            let info = CSVColumnInference.infer(values, index: column, style: style)
            guard info.nonEmpty > 0 else { continue }
            let label = first[column]
            switch info.type {
            case .empty:
                continue
            case .text:
                let lengths = Set(values.lazy.filter { !$0.isEmpty }.map(\.count))
                if lengths.count == 1, info.nonEmpty > 1, let length = lengths.first, label.count != length { votes += 1 }
            case .boolean, .integer, .decimal, .date, .dateTime:
                votes += (info.accepts(label) && !label.trimmingCharacters(in: .whitespaces).isEmpty) ? -1 : 1
            }
        }
        if votes != 0 { return votes > 0 }
        return labelsLookLikeLabels
    }
}
