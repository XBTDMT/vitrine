import Foundation

/// JSON Lines / NDJSON: every non-blank line is one strict JSON value and one root of the tree. A line that does not
/// parse becomes an `.invalid` root holding its text, with an error diagnostic naming its line and column, and the
/// lines after it still parse: one bad record must not hide a million good ones.
enum JSONLinesReader {
    static func read(_ data: Data, options: StructuredOptions, truncated: Bool) -> ReaderOutput {
        data.withUnsafeBytes { read($0.bindMemory(to: UInt8.self), options: options, truncated: truncated) }
    }

    /// - Parameters:
    ///   - baseOffset: file offset of `bytes[0]`.
    ///   - firstLine: the 1-based line number of the first line in `bytes`.
    ///   - truncated: `bytes` stops before the end of the file, so an unterminated last line may be cut and is skipped.
    static func read(_ bytes: UnsafeBufferPointer<UInt8>, options: StructuredOptions, truncated: Bool,
                     baseOffset: Int64 = 0, firstLine: Int = 1) -> ReaderOutput {
        var output = ReaderOutput(builder: StructuredTreeBuilder(options: options, pathStyle: .jsonPath), dialect: .jsonLines)
        output.documentCount = 0
        var start = 0
        var lineNumber = firstLine
        let count = bytes.count
        if count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { start = 3 }
        while start < count {
            var end = start
            while end < count, bytes[end] != 0x0A { end += 1 }
            let terminated = end < count
            if !terminated && truncated { output.endedEarly = true; break }
            var contentEnd = end
            if contentEnd > start, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            if !isBlank(bytes, start..<contentEnd) {
                output.documentCount += 1
                readLine(bytes, start..<contentEnd, line: lineNumber, baseOffset: baseOffset, options: options, into: &output)
            }
            start = end + 1
            lineNumber += 1
        }
        return output
    }

    private static func readLine(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, line: Int, baseOffset: Int64,
                                 options: StructuredOptions, into output: inout ReaderOutput) {
        let span = StructuredSpan(byteOffset: baseOffset + Int64(range.lowerBound), byteLength: Int64(range.count),
                                  line: line, column: 1)
        if range.count > options.maxLineBytes {
            output.note(StructuredDiagnostic(.error, String(localized: "line is longer than \(options.maxLineBytes.formatted()) bytes; not parsed", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."),
                                             at: StructuredLocation(line: line, column: 1, byteOffset: span.byteOffset)),
                        cap: options.maxDiagnostics)
            placeholder(bytes, range, span: span, options: options, into: &output)
            return
        }
        let mark = output.builder.mark()
        var parser = JSONParser(bytes: bytes, range: range, lenient: false, baseOffset: baseOffset, baseLine: line, options: options)
        let outcome = parser.parse(into: &output.builder, inputTruncated: false)
        guard let error = outcome.error else { return }
        output.builder.rollback(to: mark)
        output.note(error, cap: options.maxDiagnostics)
        placeholder(bytes, range, span: span, options: options, into: &output)
    }

    private static func placeholder(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, span: StructuredSpan,
                                    options: StructuredOptions, into output: inout ReaderOutput) {
        let cut = min(range.count, options.maxPreviewBytes)
        var raw = Array(bytes[range.lowerBound..<(range.lowerBound + cut)])
        if cut < range.count { trimIncompleteUTF8(&raw) }
        output.builder.leaf(.string, role: .invalid, name: nil, preview: String(decoding: raw, as: UTF8.self),
                            truncated: cut < range.count, span: span)
    }

    private static func isBlank(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Bool {
        for i in range where bytes[i] != 0x20 && bytes[i] != 0x09 && bytes[i] != 0x0D { return false }
        return true
    }
}

/// Line-start checkpoints for a JSON Lines file of any size: one offset every `stride` lines, built in a single
/// newline-counting pass, so a page anywhere in a 10 GB log is a seek plus at most `stride` skipped lines. Holds no
/// record data: 50 million lines cost about 200k offsets.
public struct JSONLinesIndex: Sendable, Equatable {
    public let stride: Int
    /// `checkpoints[k]` is the file offset of physical line `k * stride` (0-based).
    public let checkpoints: [Int64]
    /// Physical lines seen (blank ones included, so numbers match an editor's).
    public let lineCount: Int
    public let scannedBytes: Int64
    public let fileSize: Int64

    /// Every line of the file is counted.
    public var isComplete: Bool { scannedBytes >= fileSize }

    func checkpoint(atOrBefore line: Int) -> (line: Int, offset: Int64) {
        let k = max(0, min(line / stride, checkpoints.count - 1))
        return (k * stride, checkpoints[k])
    }
}

/// A JSON Lines file opened for paged preview: the index up front, records parsed a page at a time.
public struct JSONLinesFile: Sendable {
    public let url: URL
    public let index: JSONLinesIndex
    let options: StructuredOptions

    /// Counts the lines of `url` (up to `options.lineIndexByteLimit`); costs one sequential read and no parsing.
    public static func open(_ url: URL, options: StructuredOptions = StructuredOptions()) throws -> JSONLinesFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let stride = max(1, options.lineIndexStride)
        var checkpoints: [Int64] = [0]
        var newlines = 0
        var offset: Int64 = 0
        var lastByte: UInt8 = 0x0A
        while offset < min(fileSize, options.lineIndexByteLimit) {
            let want = Int(min(Int64(1 << 20), min(fileSize, options.lineIndexByteLimit) - offset))
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { break }
            chunk.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var p = 0
                while p < raw.count, let hit = memchr(base + p, 0x0A, raw.count - p) {
                    let at = base.distance(to: UnsafeRawPointer(hit))
                    newlines += 1
                    if newlines % stride == 0 { checkpoints.append(offset + Int64(at) + 1) }
                    p = at + 1
                }
                lastByte = raw[raw.count - 1]
            }
            offset += Int64(chunk.count)
        }
        let lines = newlines + (offset > 0 && lastByte != 0x0A ? 1 : 0)
        let index = JSONLinesIndex(stride: stride, checkpoints: checkpoints, lineCount: lines, scannedBytes: offset,
                                   fileSize: fileSize)
        return JSONLinesFile(url: url, index: index, options: options)
    }

    /// Physical lines `lines` (0-based) as a tree with one root per non-blank line; spans and diagnostics carry the
    /// file's own offsets and line numbers. Reads from the nearest checkpoint and stops after the range or after
    /// `options.maxInputBytes`.
    public func page(_ lines: Range<Int>) throws -> StructuredParseResult {
        let lower = max(0, lines.lowerBound)
        let upper = max(lower, lines.upperBound)
        let start = index.checkpoint(atOrBefore: lower)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start.offset))

        let skip = lower - start.line
        let wanted = upper - lower
        var buffer = Data()
        var cursor = 0
        var newlines = 0
        var begin: Int? = skip == 0 ? 0 : nil
        var end: Int? = wanted == 0 ? begin : nil
        var reachedEnd = false
        while end == nil {
            while cursor < buffer.count, end == nil {
                guard let newline = buffer[cursor...].firstIndex(of: 0x0A) else { cursor = buffer.count; break }
                newlines += 1
                cursor = newline + 1
                if newlines == skip { begin = cursor; if wanted == 0 { end = cursor } }
                if newlines == skip + wanted { end = cursor }
            }
            if end != nil { break }
            if let begin, Int64(buffer.count - begin) > options.maxInputBytes { break }
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { reachedEnd = true; break }
            buffer.append(chunk)
        }
        let from = min(begin ?? buffer.count, buffer.count)
        var to = max(from, end ?? buffer.count)
        // Stopped by the byte cap rather than by the range or the end of the file: the last line may be cut.
        var cut = end == nil && !reachedEnd
        if Int64(to - from) > options.maxInputBytes { to = from + Int(options.maxInputBytes); cut = true }
        let slice = buffer[from..<to]
        let baseOffset = start.offset + Int64(from)
        let output = slice.withUnsafeBytes { raw in
            JSONLinesReader.read(raw.bindMemory(to: UInt8.self), options: options, truncated: cut,
                                 baseOffset: baseOffset, firstLine: lower + 1)
        }
        let layout = StructuredLayout(lineCount: wanted, longestLineBytes: 0, isMinified: false)
        return output.result(format: .jsonLines, options: options, layout: layout, parsedBytes: Int64(slice.count),
                             fileSize: index.fileSize, inputTruncated: false)
    }
}
