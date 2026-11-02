import Foundation

/// A text file too large to load, read as windows of lines (code design state 14, C-6, R-4): a background pass counts
/// the lines and keeps the byte offset of every `stride`-th one, so any window is one seek and a short skip; until the
/// pass ends the total is an estimate from the bytes counted so far. Find streams over the file in chunks and says how
/// far it got. Nothing holds more than one chunk of the file in memory. roadmap: S-5
public actor LargeTextFile {
    public nonisolated let url: URL
    public nonisolated let size: Int64
    /// Lines between two kept offsets.
    public static let stride = 1_024
    /// Bytes read per step of the line pass and of find.
    static let chunk = 8 * 1024 * 1024
    /// A line longer than this is cut in a window, with a note of how much was left out.
    public static let longLine = 20_000

    /// anchors[k] is the byte offset of line k × stride + 1.
    private var anchors: [Int64] = [0]
    /// Newlines counted, and how far into the file the count has reached.
    public private(set) var newlinesCounted = 0
    public private(set) var bytesCounted: Int64 = 0
    public private(set) var isIndexed = false
    /// Whether the file ends without a newline (the last line still counts).
    private var endsWithNewline = true

    public init(url: URL) throws {
        self.url = url
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        size = Int64(values.fileSize ?? 0)
    }

    // MARK: Counting lines

    /// The line count once the pass has ended, else an estimate from the density counted so far.
    public var lineCount: (count: Int, exact: Bool) {
        if isIndexed { return (newlinesCounted + (endsWithNewline || size == 0 ? 0 : 1), true) }
        guard bytesCounted > 0 else { return (max(1, newlinesCounted), false) }
        let density = Double(newlinesCounted) / Double(bytesCounted)
        return (max(newlinesCounted, Int((density * Double(size)).rounded())), false)
    }

    /// Lines known to exist (fully counted) so far.
    public var linesKnown: Int { isIndexed ? lineCount.count : newlinesCounted }

    /// Counts every line, keeping the anchors; `progress` hears (newlines, bytes) after each chunk. Cancellable.
    public func index(progress: (@Sendable (Int, Int64) -> Void)? = nil) async throws {
        guard !isIndexed else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(bytesCounted))
        var last: UInt8 = 0x0A
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: Self.chunk), !data.isEmpty else { break }
            let base = bytesCounted
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let start = raw.baseAddress else { return }
                var p = start
                let end = start + raw.count
                while p < end, let hit = memchr(p, 0x0A, end - p) {
                    newlinesCounted += 1
                    if newlinesCounted % Self.stride == 0 {
                        anchors.append(base + Int64(start.distance(to: hit)) + 1)
                    }
                    p = UnsafeRawPointer(hit) + 1
                }
            }
            last = data.last ?? last
            bytesCounted += Int64(data.count)
            progress?(newlinesCounted, bytesCounted)
            await Task.yield()
        }
        endsWithNewline = last == 0x0A
        isIndexed = true
    }

    // MARK: Windows

    /// One window: `count` lines from line `first` (1-based), as text joined by newlines.
    public struct Window: Sendable, Equatable {
        public let first: Int
        public let count: Int
        public let text: String
        public let byteRange: Range<Int64>
        /// Lines cut at `longLine` characters.
        public let cutLines: Int
    }

    /// Up to `count` lines from line `first`, stopping early at `maxBytes`. A line past what has been counted is
    /// clamped to the last counted line (callers wait for the pass when they need further).
    public func window(from first: Int, count: Int, maxBytes: Int = 4 * 1024 * 1024) throws -> Window {
        let known = max(1, linesKnown)
        let first = max(1, min(first, known))
        let k = min((first - 1) / Self.stride, anchors.count - 1)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset = anchors[k]
        try handle.seek(toOffset: UInt64(offset))
        // Skip to `first`.
        var line = k * Self.stride + 1
        var buffer = Data()
        while line < first {
            if buffer.isEmpty {
                guard let d = try handle.read(upToCount: 1 << 20), !d.isEmpty else { break }
                buffer = d
            }
            if let nl = buffer.firstIndex(of: 0x0A) {
                let used = buffer.distance(from: buffer.startIndex, to: nl) + 1
                offset += Int64(used)
                buffer = buffer.subdata(in: buffer.index(buffer.startIndex, offsetBy: used)..<buffer.endIndex)
                line += 1
            } else {
                offset += Int64(buffer.count)
                buffer = Data()
            }
        }
        // Read the lines.
        var lines: [String] = []
        var cut = 0
        var taken: Int64 = 0
        var pending = Data()
        func emit(_ bytes: Data) {
            var s = String(decoding: bytes, as: UTF8.self)
            if s.hasSuffix("\r") { s.removeLast() }
            if s.count > Self.longLine {
                s = String(localized: "\(String(s.prefix(Self.longLine))) … (\((s.count - Self.longLine).formatted()) more characters)", bundle: .module, comment: "A very long line cut short: its start, then how many more characters it has.")
                cut += 1
            }
            lines.append(s)
        }
        var data = buffer
        while lines.count < count && taken < maxBytes {
            if data.isEmpty {
                guard let d = try handle.read(upToCount: 1 << 20), !d.isEmpty else { break }
                data = d
            }
            if let nl = data.firstIndex(of: 0x0A) {
                let part = data[data.startIndex..<nl]
                pending.append(part)
                taken += Int64(pending.count + 1)
                emit(pending)
                pending = Data()
                data = data.subdata(in: data.index(after: nl)..<data.endIndex)
            } else {
                pending.append(data)
                data = Data()
                // A single line far longer than a window: keep only what a cut line shows.
                if pending.count > Self.longLine * 4 + maxBytes { break }
            }
        }
        if lines.count < count, !pending.isEmpty { taken += Int64(pending.count); emit(pending) }
        return Window(first: first, count: lines.count, text: lines.joined(separator: "\n"),
                      byteRange: offset..<(offset + taken), cutLines: cut)
    }

    // MARK: Find

    /// One streaming find's progress: the lines that match so far (each line once), how far it read.
    public struct FindProgress: Sendable, Equatable {
        public var lines: [Int]
        public var bytesSearched: Int64
        public var done: Bool
        /// Stopped at `matchLimit` lines.
        public var capped: Bool
    }

    public static let matchLimit = 100_000

    /// Every line containing `query` (case and accent folded, as the native finder does), streaming in chunks that
    /// end at a newline; `progress` hears each step. Cancellable.
    public func find(_ query: String, progress: @Sendable (FindProgress) -> Void) async throws -> FindProgress {
        var state = FindProgress(lines: [], bytesSearched: 0, done: false, capped: false)
        guard !query.isEmpty else { state.done = true; return state }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var line = 1
        var carry = Data()
        // Fold the query and each chunk the same way (case, accents), then search bytes: about 900 MB/s on this Mac
        // against 13 for String.range(of:options:) (measured 2026-10-30). Folding keeps every newline, so lines
        // counted in the folded text are the file's lines.
        let needleBytes = Array(Self.fold(query).utf8)
        while true {
            try Task.checkCancellation()
            let d = try handle.read(upToCount: Self.chunk) ?? Data()
            var block = carry + d
            if !d.isEmpty, let nl = block.lastIndex(of: 0x0A) {
                carry = block.subdata(in: block.index(after: nl)..<block.endIndex)
                block = block.subdata(in: block.startIndex..<block.index(after: nl))
            } else {
                carry = Data()
            }
            if block.isEmpty && d.isEmpty { break }
            var folded = Self.fold(String(decoding: block, as: UTF8.self))
            folded.withUTF8 { hay in
                guard let base = hay.baseAddress else { return }
                var p = base
                var counted = base
                let end = base + hay.count
                var lastLine = 0
                needleBytes.withUnsafeBytes { q in
                    while p < end, let hit = memmem(p, end - p, q.baseAddress!, q.count) {
                        let at = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self))
                        line += Self.newlines(from: counted, to: at)
                        counted = at
                        if line != lastLine {
                            state.lines.append(line)
                            lastLine = line
                            if state.lines.count >= Self.matchLimit { state.capped = true; return }
                        }
                        p = at + q.count
                    }
                }
                if !state.capped { line += Self.newlines(from: counted, to: end) }
            }
            state.bytesSearched += Int64(block.count)
            if state.capped { break }
            progress(state)
            await Task.yield()
            if d.isEmpty { break }
        }
        state.done = !state.capped
        state.bytesSearched = state.capped ? state.bytesSearched : size
        progress(state)
        return state
    }

    /// Case and accent folded, as the native finder compares.
    static func fold(_ s: String) -> String {
        (s as NSString).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func newlines(from a: UnsafePointer<UInt8>, to b: UnsafePointer<UInt8>) -> Int {
        var n = 0
        var p = UnsafeRawPointer(a)
        let end = UnsafeRawPointer(b)
        while p < end, let hit = memchr(p, 0x0A, end - p) { n += 1; p = UnsafeRawPointer(hit) + 1 }
        return n
    }
}
