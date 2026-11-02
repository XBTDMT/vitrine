import Foundation

/// The AI data readers (A-5 JSONL, A-10 chat exports, A-11 evals and traces, the array half of A-7): one entry point
/// that recognises the file from its name and its first bytes and returns a summary a card or a table can draw.
/// Untrusted input: at most `maxBytes` are read, every list and every recursion is bounded, and nothing here touches
/// the network, a process or any file beyond the bytes it is given. roadmap: S-21
public enum AIDataReader {
    /// The most bytes any reader looks at; the rest of a larger file is left unread and the summary says so.
    public static let maxBytes = 32 * 1024 * 1024

    /// Reads `data` (the file's bytes, or its first bytes) named `fileName`. nil when the file is none of the formats
    /// these readers know (a plain JSON document, an ordinary zip), so the caller falls back to its generic preview.
    public static func read(data: Data, fileName: String) -> AIDataDocument? {
        read(data: data, fileName: fileName, totalFileSize: nil)
    }

    /// As `read(data:fileName:)`, for a caller that passed only the file's first bytes: `totalFileSize` is the whole
    /// file's size, so a JSONL record count can be estimated past the bytes read.
    public static func read(data: Data, fileName: String, totalFileSize: Int64?) -> AIDataDocument? {
        let wasCut = data.count > maxBytes || (totalFileSize.map { $0 > Int64(min(data.count, maxBytes)) } ?? false)
        let bytes = [UInt8](data.prefix(maxBytes))
        let total = max(Int64(bytes.count), totalFileSize ?? Int64(data.count))
        let context = AIReadContext(fileName: fileName, wasCut: wasCut, totalSize: total)
        let ext = (fileName as NSString).pathExtension.lowercased()

        // Binary formats are recognised by their magic numbers whatever the name says.
        if AINumpyReader.hasMagic(bytes) { return .numpyArray(AINumpyReader.readNPY(bytes, context: context)) }
        if let offset = AIHDF5Reader.superblockOffset(bytes) {
            return .hdf5(AIHDF5Reader.read(bytes, superblockAt: offset, context: context))
        }
        if bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 0x03 || bytes[2] == 0x05 {
            return readZip(bytes, ext: ext, context: context)
        }
        if ["npy", "npz", "h5", "hdf5", "he5", "eval"].contains(ext) { return nil }
        return readText(bytes, ext: ext, context: context)
    }

    private static func readZip(_ bytes: [UInt8], ext: String, context: AIReadContext) -> AIDataDocument? {
        guard let listing = AIZip.listing(bytes) else { return nil }
        let files = listing.entries.filter { !$0.isDirectory }
        let paths = files.map(\.path)
        let looksInspect = paths.contains("header.json") || paths.contains { $0.hasPrefix("_journal/") }
        if ext == "eval" || (looksInspect && paths.contains { $0.hasPrefix("samples/") || $0 == "summaries.json" }) {
            return AIInspectReader.readZip(bytes, listing: listing, context: context).map(AIDataDocument.inspectEval)
        }
        let npyCount = paths.filter { $0.lowercased().hasSuffix(".npy") }.count
        if ext == "npz" || (npyCount > 0 && npyCount == paths.count) {
            return .numpyArchive(AINumpyReader.readNPZ(bytes, listing: listing, context: context))
        }
        return nil
    }

    private static func readText(_ bytes: [UInt8], ext: String, context: AIReadContext) -> AIDataDocument? {
        let lineFormats: Set<String> = ["jsonl", "ndjson", "jsonlines", "ldjson"]
        if lineFormats.contains(ext) {
            if let trace = AITraceReader.readLines(bytes, context: context) { return .trace(trace) }
            return .jsonLines(AIJSONLReader.read(bytes, context: context))
        }
        guard let first = AIJSONParser.firstSignificantByte(bytes) else { return nil }
        if first == UInt8(ascii: "[") {
            if let chat = AIChatExportReader.read(bytes, context: context) { return .chatExport(chat) }
            return nil
        }
        guard first == UInt8(ascii: "{") else { return nil }
        switch AIJSONParser.parseDocument(bytes, limits: .document) {
        case .success(let parsed):
            if let trace = AITraceReader.read(parsed.value, budgetHit: parsed.budgetHit, context: context) {
                return .trace(trace)
            }
            if let eval = AIPromptfooReader.read(parsed.value, budgetHit: parsed.budgetHit, context: context) {
                return .promptfoo(eval)
            }
            if let log = AIInspectReader.readJSONLog(parsed.value, budgetHit: parsed.budgetHit, context: context) {
                return .inspectEval(log)
            }
            return nil
        case .failure:
            // A `.json` that is really JSON Lines: the first line is a whole object and more lines follow.
            guard AIJSONLReader.looksLikeLines(bytes) else { return nil }
            if let trace = AITraceReader.readLines(bytes, context: context) { return .trace(trace) }
            return .jsonLines(AIJSONLReader.read(bytes, context: context))
        }
    }
}

/// What one AI data file turned out to be, with the summary its card and table draw from. roadmap: S-21
public enum AIDataDocument: Sendable, Equatable {
    /// JSONL / NDJSON records (A-5), including known shapes such as batch files and fine-tuning sets.
    case jsonLines(JSONLSummary)
    /// A ChatGPT or Claude `conversations.json` export (A-10).
    case chatExport(ChatExportSummary)
    /// A promptfoo results file (A-11).
    case promptfoo(PromptfooSummary)
    /// An Inspect evaluation log, `.eval` zip or JSON (A-11).
    case inspectEval(InspectEvalSummary)
    /// OpenTelemetry traces in OTLP JSON, with GenAI span details (A-11).
    case trace(OTLPTraceSummary)
    /// A NumPy `.npy` array (A-7).
    case numpyArray(NPYSummary)
    /// A NumPy `.npz` archive of arrays (A-7).
    case numpyArchive(NPZSummary)
    /// An HDF5 file's group tree and datasets (A-7).
    case hdf5(HDF5Summary)

    /// One line naming what the file is and its size in its own terms.
    public var headline: String {
        switch self {
        case .jsonLines(let s): s.headline
        case .chatExport(let s): s.headline
        case .promptfoo(let s): s.headline
        case .inspectEval(let s): s.headline
        case .trace(let s): s.headline
        case .numpyArray(let s): s.headline
        case .numpyArchive(let s): s.headline
        case .hdf5(let s): s.headline
        }
    }

    /// Label and value pairs for the card, in display order.
    public var facts: [AIDataFact] {
        switch self {
        case .jsonLines(let s): s.facts
        case .chatExport(let s): s.facts
        case .promptfoo(let s): s.facts
        case .inspectEval(let s): s.facts
        case .trace(let s): s.facts
        case .numpyArray(let s): s.facts
        case .numpyArchive(let s): s.facts
        case .hdf5(let s): s.facts
        }
    }

    /// What deserves attention, most serious first.
    public var warnings: [AIDataWarning] {
        let list: [AIDataWarning] = switch self {
        case .jsonLines(let s): s.warnings
        case .chatExport(let s): s.warnings
        case .promptfoo(let s): s.warnings
        case .inspectEval(let s): s.warnings
        case .trace(let s): s.warnings
        case .numpyArray(let s): s.warnings
        case .numpyArchive(let s): s.warnings
        case .hdf5(let s): s.warnings
        }
        return list.filter { $0.level == .danger } + list.filter { $0.level == .caution }
    }

    /// The rows a table shows, when the format has them.
    public var table: AIDataTable? {
        switch self {
        case .jsonLines(let s): s.table
        case .chatExport(let s): s.table
        case .promptfoo(let s): s.table
        case .inspectEval(let s): s.samples
        case .trace(let s): s.table
        case .numpyArray: nil
        case .numpyArchive(let s): s.table
        case .hdf5(let s): s.table
        }
    }
}

/// One label and value on a card ("Records", "1,204"). roadmap: S-21
public struct AIDataFact: Sendable, Equatable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Something a person should know before trusting or opening the data, in plain English. roadmap: S-21
public struct AIDataWarning: Sendable, Equatable {
    /// How serious it is. roadmap: S-21
    public enum Level: String, Sendable, Equatable {
        /// Worth knowing: damaged lines, a partial read, failed tests.
        case caution
        /// Could hurt: loading the file can run code.
        case danger
    }

    public var level: Level
    public var reason: String

    public init(_ level: Level, _ reason: String) {
        self.level = level
        self.reason = reason
    }
}

/// Display rows for a table: every cell is a string of at most `AIDataTable.maxCellCharacters` characters.
/// roadmap: S-21
public struct AIDataTable: Sendable, Equatable {
    /// The most characters one cell holds; longer values end with "…".
    public static let maxCellCharacters = 200
    /// The most rows a table carries.
    public static let maxRows = 500

    public var columns: [String]
    /// Each row has exactly `columns.count` cells; a missing value is "".
    public var rows: [[String]]
    /// Rows in the source, when known; more than `rows.count` when the table was cut.
    public var totalRows: Int?
    /// Rows or columns were left out (row cap, column cap, partial read).
    public var isTruncated: Bool

    public init(columns: [String], rows: [[String]], totalRows: Int?, isTruncated: Bool) {
        self.columns = columns
        self.rows = rows
        self.totalRows = totalRows
        self.isTruncated = isTruncated
    }

    public static let empty = AIDataTable(columns: [], rows: [], totalRows: 0, isTruncated: false)
}

/// What every reader knows about the read itself.
struct AIReadContext: Sendable {
    var fileName: String
    /// Fewer bytes were read than the file holds.
    var wasCut: Bool
    /// The whole file's size, or the bytes given when nothing better is known.
    var totalSize: Int64

    var readCapWarning: AIDataWarning {
        let megabytes = AIDataReader.maxBytes / (1024 * 1024)
        return AIDataWarning(.caution, String(localized: "Only the first \(megabytes) MB of this file were read; what is shown covers that part.", bundle: .module, comment: "Warning on an AI data card. The argument is a size in megabytes."))
    }

    /// The fact label used by several readers.
    static var formatLabel: String { String(localized: "Format", bundle: .module, comment: "Fact label: what kind of file this is.") }
}

/// Small shared helpers for display strings.
enum AIText {
    /// `text` cut to `limit` characters, ending with "…" when cut. Newlines and tabs become spaces when `oneLine`.
    static func cap(_ text: String, _ limit: Int = AIDataTable.maxCellCharacters, oneLine: Bool = true) -> String {
        var value = text
        if oneLine, value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            value = String(value.map { $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == "\r\n" ? " " : $0 })
        }
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 1))) + "…"
    }

    static func number(_ value: Double, digits: Int = 3) -> String {
        guard value.isFinite else { return "\(value)" }
        if value == value.rounded(), abs(value) < 1e15 { return Int64(value).formatted() }
        return value.formatted(.number.precision(.fractionLength(0...digits)))
    }

    static func milliseconds(_ ms: Double) -> String {
        if ms >= 1000 {
            let seconds = number(ms / 1000, digits: 2)
            return String(localized: "\(seconds) s", bundle: .module, comment: "A duration in seconds. The argument is a formatted number.")
        }
        let value = number(ms, digits: 2)
        return String(localized: "\(value) ms", bundle: .module, comment: "A duration in milliseconds. The argument is a formatted number.")
    }

    static func date(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    /// Unique values in first-seen order, at most `limit`.
    static func unique(_ values: [String], limit: Int = 50) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where !value.isEmpty && seen.insert(value).inserted {
            out.append(value)
            if out.count >= limit { break }
        }
        return out
    }

    /// "a (3), b (1)" for counted names, most first, at most `limit` names.
    static func counted(_ counts: [String: Int], limit: Int = 5) -> String {
        let sorted = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var parts = sorted.prefix(limit).map { "\($0.key) (\($0.value.formatted()))" }
        let more = sorted.count - limit
        if more > 0 { parts.append(String(localized: "+\(more) more", bundle: .module, comment: "End of a list of names that was cut. The argument is how many were left out.")) }
        return parts.joined(separator: ", ")
    }
}

/// Dates as these formats write them: ISO 8601 strings and Unix epoch numbers.
enum AIDates {
    /// `2024-05-01T12:34:56.789012Z`, `2024-05-01 12:34:56+02:00`, `2024-05-01`. Fractions of any length.
    static func iso8601(_ text: String) -> Date? {
        let b = Array(text.utf8)
        var i = 0
        func digits(_ n: Int) -> Int? {
            guard i + n <= b.count else { return nil }
            var v = 0
            for k in 0..<n {
                let c = b[i + k]
                guard c >= 0x30, c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            i += n
            return v
        }
        func expect(_ c: UInt8) -> Bool {
            guard i < b.count, b[i] == c else { return false }
            i += 1
            return true
        }
        guard let year = digits(4), expect(0x2D), let month = digits(2), expect(0x2D), let day = digits(2),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var seconds = 0.0
        if i < b.count, b[i] == 0x54 || b[i] == 0x20 || b[i] == 0x74 {
            i += 1
            guard let hour = digits(2), expect(0x3A), let minute = digits(2), hour < 25, minute < 60 else { return nil }
            seconds = Double(hour * 3600 + minute * 60)
            if expect(0x3A) {
                guard let second = digits(2), second <= 60 else { return nil }
                seconds += Double(second)
                if i < b.count, b[i] == 0x2E || b[i] == 0x2C {
                    i += 1
                    var scale = 0.1
                    var any = false
                    while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                        if scale > 1e-12 { seconds += Double(b[i] - 0x30) * scale }
                        scale /= 10
                        i += 1
                        any = true
                    }
                    guard any else { return nil }
                }
            }
            if i < b.count {
                if b[i] == 0x5A || b[i] == 0x7A {
                    i += 1
                } else if b[i] == 0x2B || b[i] == 0x2D {
                    let sign = b[i] == 0x2B ? 1.0 : -1.0
                    i += 1
                    guard let oh = digits(2) else { return nil }
                    _ = expect(0x3A)
                    let om = digits(2) ?? 0
                    seconds -= sign * Double(oh * 3600 + om * 60)
                }
            }
        }
        guard i == b.count else { return nil }
        // Days from 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's days_from_civil).
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Date(timeIntervalSince1970: Double(days) * 86_400 + seconds)
    }

    /// A Unix time in seconds (or milliseconds when it is too large to be seconds), or an ISO 8601 string.
    static func date(_ value: AIJSON?) -> Date? {
        guard let value else { return nil }
        if let text = value.string { return iso8601(text) ?? Double(text).flatMap { epoch($0) } }
        return value.double.flatMap { epoch($0) }
    }

    static func epoch(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 1e11 ? value / 1000 : value
        guard seconds < 1e10 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
