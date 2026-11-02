import Foundation

/// What the scanner reports while it walks the bytes. Field content arrives as one or more segments (a field split
/// across read chunks, or around a doubled quote, arrives in pieces); sinks that only count rows ignore it.
protocol CSVScanSink {
    mutating func recordStarted(at offset: Int64)
    mutating func fieldBytes(_ bytes: UnsafeBufferPointer<UInt8>)
    mutating func fieldEnded()
    /// `endOffset` is just past the terminator byte (or the end of input). Return false to stop after this record.
    mutating func recordEnded(at endOffset: Int64) -> Bool
}

/// The one RFC 4180 state machine. The sniffer, the first page, `rows(in:)` and the row index all run this same
/// code, so a checkpoint the index records is always a place where the parser would start a record: an index built
/// by a different, "faster" scanner is exactly how newlines inside quotes end up splitting rows.
///
/// The grammar, including the lenient parts every real-world reader needs:
/// - A quote opens a quoted section only at the start of a field. Inside it, a doubled quote is one literal quote and
///   delimiters and line breaks are content. A quote in the middle of an unquoted field (`5" screw`) is literal.
/// - After a closing quote, anything up to the next delimiter or line break is kept literally (`"ab"cd` → `abcd`).
/// - LF, CRLF and CR all end a record, so mixed files parse.
/// - Blank lines are not records (this also covers the empty trailing line). A line holding only `""` is one record
///   with one empty field.
/// - Input that ends inside quotes ends the record there and is reported (`endedInsideQuotes`): one stray quote can
///   swallow the rest of a file, and the lint banner should say why the last row is enormous.
struct CSVScanner: Sendable {
    enum State: Sendable { case recordStart, fieldStart, unquoted, quoted, quoteInQuoted }

    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D

    let delimiter: UInt8
    let quote: UInt8
    private(set) var state = State.recordStart
    /// The absolute offset of the next byte to scan.
    private(set) var position: Int64
    private(set) var endedInsideQuotes = false
    /// Terminators seen, blank lines included; quoted line breaks are content and are not counted.
    private(set) var lfCount = 0, crlfCount = 0, crCount = 0
    private var pendingCR = false

    init(delimiter: UInt8, quote: UInt8, startOffset: Int64 = 0) {
        self.delimiter = delimiter; self.quote = quote; self.position = startOffset
    }

    init(dialect: CSVDialect, startOffset: Int64) {
        self.init(delimiter: dialect.delimiter.rawValue, quote: dialect.quote.rawValue, startOffset: startOffset)
    }

    /// True between records: nothing of a record has been seen since the last terminator.
    var isBetweenRecords: Bool { state == .recordStart }

    /// The terminator used most, or nil when none was seen.
    var dominantLineEnding: CSVLineEnding? {
        let counts: [(CSVLineEnding, Int)] = [(.lf, lfCount), (.crlf, crlfCount), (.cr, crCount + (pendingCR ? 1 : 0))]
        guard let best = counts.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    /// Scans `bytes`, which sit at `position` in the input. Returns true when the sink asked to stop; `position` is
    /// then just past the terminator of the last record, the place to resume from.
    @discardableResult
    mutating func scan<Sink: CSVScanSink>(_ bytes: UnsafeBufferPointer<UInt8>, into sink: inout Sink) -> Bool {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return false }
        let count = bytes.count
        let start = position
        let delimiter = self.delimiter, quote = self.quote
        let lf = Self.lf, cr = Self.cr
        var i = 0
        var segmentStart = 0

        func endRecord(on terminator: UInt8, at index: Int, sink: inout Sink) -> Bool {
            if terminator == lf { lfCount += 1 } else { pendingCR = true }
            state = .recordStart
            return sink.recordEnded(at: start + Int64(index) + 1)
        }

        while i < count {
            switch state {
            case .recordStart:
                let byte = base[i]
                if byte == lf {
                    if pendingCR { crlfCount += 1; pendingCR = false } else { lfCount += 1 }
                    i += 1
                } else if byte == cr {
                    if pendingCR { crCount += 1 }
                    pendingCR = true
                    i += 1
                } else {
                    if pendingCR { crCount += 1; pendingCR = false }
                    sink.recordStarted(at: start + Int64(i))
                    state = .fieldStart   // the same byte is read again as the start of field 1
                }

            case .fieldStart:
                let byte = base[i]
                if byte == quote {
                    state = .quoted; segmentStart = i + 1
                } else if byte == delimiter {
                    sink.fieldEnded()
                } else if byte == lf || byte == cr {
                    sink.fieldEnded()
                    if !endRecord(on: byte, at: i, sink: &sink) { position = start + Int64(i) + 1; return true }
                } else {
                    state = .unquoted; segmentStart = i
                }
                i += 1

            case .unquoted:
                var byte: UInt8 = 0
                while i < count {
                    byte = base[i]
                    if byte == delimiter || byte == lf || byte == cr { break }
                    i += 1
                }
                guard i < count else { break }
                if i > segmentStart { sink.fieldBytes(UnsafeBufferPointer(start: base + segmentStart, count: i - segmentStart)) }
                sink.fieldEnded()
                if byte == delimiter {
                    state = .fieldStart
                } else if !endRecord(on: byte, at: i, sink: &sink) {
                    position = start + Int64(i) + 1; return true
                }
                i += 1

            case .quoted:
                // Inside quotes only the quote matters; memchr skips long quoted text without a per-byte switch.
                guard let hit = memchr(base + i, Int32(quote), count - i) else { i = count; break }
                i = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                if i > segmentStart { sink.fieldBytes(UnsafeBufferPointer(start: base + segmentStart, count: i - segmentStart)) }
                state = .quoteInQuoted
                i += 1

            case .quoteInQuoted:
                let byte = base[i]
                if byte == quote {
                    state = .quoted; segmentStart = i   // a doubled quote: keep the second as content
                } else if byte == delimiter {
                    sink.fieldEnded(); state = .fieldStart
                } else if byte == lf || byte == cr {
                    sink.fieldEnded()
                    if !endRecord(on: byte, at: i, sink: &sink) { position = start + Int64(i) + 1; return true }
                } else {
                    state = .unquoted; segmentStart = i   // text after the closing quote is kept literally
                }
                i += 1
            }
        }
        if (state == .unquoted || state == .quoted), segmentStart < count {
            sink.fieldBytes(UnsafeBufferPointer(start: base + segmentStart, count: count - segmentStart))
        }
        position = start + Int64(count)
        return false
    }

    /// Ends the input: a record still open (a final line with no line break, a trailing delimiter, an unclosed quote)
    /// is completed here.
    mutating func finish<Sink: CSVScanSink>(into sink: inout Sink) {
        switch state {
        case .recordStart:
            if pendingCR { crCount += 1; pendingCR = false }
            return
        case .quoted:
            endedInsideQuotes = true
        case .fieldStart, .unquoted, .quoteInQuoted:
            break
        }
        sink.fieldEnded()
        _ = sink.recordEnded(at: position)
        state = .recordStart
    }
}

/// Collects decoded records: the first page, `rows(in:)`, the sniffer's header check.
struct CSVRecordCollector: CSVScanSink {
    let encoding: CSVTextEncoding
    let maxFieldBytes: Int
    /// Records to pass over (not decoded) before collecting starts.
    var skip: Int
    /// Records to collect before asking the scanner to stop.
    let limit: Int

    private(set) var rows: [CSVRow] = []
    private(set) var lastRecordEnd: Int64 = 0
    private var fields: [String] = []
    private var field: [UInt8] = []
    private var fieldTruncated = false
    private var rowTruncated = false
    private var recordOffset: Int64 = 0

    init(encoding: CSVTextEncoding, maxFieldBytes: Int, skip: Int = 0, limit: Int) {
        self.encoding = encoding; self.maxFieldBytes = max(4, maxFieldBytes); self.skip = skip; self.limit = limit
        rows.reserveCapacity(min(limit, 4096))
    }

    var isFull: Bool { rows.count >= limit }

    mutating func recordStarted(at offset: Int64) {
        recordOffset = offset
        fields.removeAll(keepingCapacity: true)
        rowTruncated = false
    }

    mutating func fieldBytes(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard skip == 0, !fieldTruncated else { return }
        let room = maxFieldBytes - field.count
        if bytes.count <= room {
            field.append(contentsOf: bytes)
        } else {
            field.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[..<room]))
            fieldTruncated = true
        }
    }

    mutating func fieldEnded() {
        guard skip == 0 else { return }
        var value: String
        if fieldTruncated {
            if encoding == .utf8 { trimPartialUTF8(&field) }
            value = CSVTextDecoder.decode(field, encoding: encoding)
            value.append("…")
            rowTruncated = true
        } else {
            value = CSVTextDecoder.decode(field, encoding: encoding)
        }
        fields.append(value)
        field.removeAll(keepingCapacity: true)
        fieldTruncated = false
    }

    mutating func recordEnded(at endOffset: Int64) -> Bool {
        lastRecordEnd = endOffset
        if skip > 0 { skip -= 1; return true }
        rows.append(CSVRow(fields: fields, offset: recordOffset, hasTruncatedField: rowTruncated))
        return rows.count < limit
    }

    /// Drops the bytes of a UTF-8 sequence that the field cap cut in half, so truncation never turns valid text
    /// into a Latin-1 fallback.
    private func trimPartialUTF8(_ bytes: inout [UInt8]) {
        var lead = bytes.count - 1
        while lead >= 0, lead >= bytes.count - 4, bytes[lead] & 0xC0 == 0x80 { lead -= 1 }
        guard lead >= 0 else { return }
        let byte = bytes[lead]
        let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
        if bytes.count - lead < length { bytes.removeSubrange(lead...) }
    }
}

/// Counts fields per record without decoding anything: the sniffer's delimiter vote.
struct CSVFieldCountSink: CSVScanSink {
    let limit: Int
    private(set) var counts: [Int] = []
    private var current = 0

    init(limit: Int) { self.limit = limit }

    mutating func recordStarted(at offset: Int64) { current = 0 }
    mutating func fieldBytes(_ bytes: UnsafeBufferPointer<UInt8>) {}
    mutating func fieldEnded() { current += 1 }
    mutating func recordEnded(at endOffset: Int64) -> Bool {
        counts.append(current)
        return counts.count < limit
    }
}

/// Field bytes → String. UTF-8 fields that turn out not to be UTF-8 (the sample said UTF-8, a later row disagrees)
/// fall back to Latin-1 for that field alone, so one bad byte never blanks a cell.
enum CSVTextDecoder {
    static func decode(_ bytes: [UInt8], encoding: CSVTextEncoding) -> String {
        bytes.withUnsafeBufferPointer { decode($0, encoding: encoding) }
    }

    static func decode(_ bytes: UnsafeBufferPointer<UInt8>, encoding: CSVTextEncoding) -> String {
        if bytes.isEmpty { return "" }
        if encoding == .utf8, let text = String(validating: bytes, as: UTF8.self) { return text }
        return decodeWindows1252(bytes)
    }

    static func isValidUTF8(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        String(validating: bytes, as: UTF8.self) != nil
    }

    /// Windows-1252 for 0x80–0x9F; the five bytes it leaves undefined map to the same code point, as WHATWG does.
    static func decodeWindows1252(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte >= 0x80 && byte < 0xA0 {
                scalars.append(windows1252High[Int(byte - 0x80)])
            } else {
                scalars.append(Unicode.Scalar(byte))
            }
        }
        return String(scalars)
    }

    private static let windows1252High: [Unicode.Scalar] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D,
        0x017D, 0x008F, 0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A,
        0x0153, 0x009D, 0x017E, 0x0178,
    ].map { Unicode.Scalar(UInt16($0)) ?? "\u{FFFD}" }
}
