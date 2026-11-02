import Foundation
import VitrineData
import VitrineSupport

/// Why an AI-format read stopped. Conforms to the shared byte readers' failure protocol so `BoundedFileSource` and
/// `readExactly` raise it directly.
enum AIReadError: Error, ByteReadFailure, Equatable {
    case unreadable(String)
    case truncated(String)
    case malformed(String)
    /// The read budget (64 MB for model headers, 8 MB otherwise) ran out.
    case budget(Int64)

    var reason: String {
        switch self {
        case .unreadable(let why):
            String(localized: "The file could not be read: \(why).", bundle: .module, comment: "Why an AI-format card is partial. The argument is a technical detail in English.")
        case .truncated(let why):
            String(localized: "The file ends early (or only its start was read): \(why).", bundle: .module, comment: "Why an AI-format card is partial. The argument is a technical detail in English.")
        case .malformed(let why):
            String(localized: "The file is damaged: \(why).", bundle: .module, comment: "Why an AI-format card is partial. The argument is a technical detail in English.")
        case .budget(let limit):
            String(localized: "Reading stopped at the \(AIFormat.bytes(limit)) limit for this kind of file.", bundle: .module, comment: "Why an AI-format card is partial. The argument is a size such as 64 MB.")
        }
    }
}

/// Windowed reads over a byte source with a total budget: only bytes actually fetched count, so skipping a tensor's
/// data costs nothing. Local to one read on one thread.
final class AIByteReader {
    let source: any ByteSource
    let size: Int64
    let budget: Int64
    private(set) var bytesFetched: Int64 = 0
    private var window: [UInt8] = []
    private var windowStart: Int64 = 0
    private let windowSize: Int

    init(_ source: any ByteSource, budget: Int64, windowSize: Int = 256 * 1024) {
        self.source = source; self.size = source.size; self.budget = budget; self.windowSize = windowSize
    }

    private func fetch(at offset: Int64, count: Int) throws -> [UInt8] {
        guard bytesFetched + Int64(count) <= budget else { throw AIReadError.budget(budget) }
        let got: [UInt8]
        do { got = try source.read(at: offset, count: count) } catch let error as AIReadError { throw error } catch {
            throw AIReadError.unreadable("\(error)")
        }
        bytesFetched += Int64(got.count)
        return got
    }

    /// Exactly `count` bytes at `offset`, or `truncated` naming `what`.
    func bytes(at offset: Int64, count: Int, _ what: @autoclosure () -> String) throws -> [UInt8] {
        guard count >= 0, offset >= 0 else { throw AIReadError.malformed("\(what()) has a negative length or offset") }
        if count == 0 { return [] }
        guard offset <= size, Int64(count) <= size - offset else { throw AIReadError.truncated("inside \(what())") }
        let windowEnd = windowStart + Int64(window.count)
        if offset >= windowStart, offset + Int64(count) <= windowEnd {
            let start = Int(offset - windowStart)
            return Array(window[start..<(start + count)])
        }
        if count > windowSize { return try fetch(at: offset, count: count) }
        let want = Int(min(Int64(windowSize), size - offset, max(Int64(count), budget - bytesFetched)))
        window = try fetch(at: offset, count: max(want, count))
        windowStart = offset
        guard window.count >= count else { throw AIReadError.truncated("inside \(what())") }
        return Array(window[0..<count])
    }
}

/// A position in an `AIByteReader` with little- or big-endian integer reads.
struct AICursor {
    let reader: AIByteReader
    var offset: Int64
    var bigEndian = false

    init(_ reader: AIByteReader, at offset: Int64 = 0, bigEndian: Bool = false) {
        self.reader = reader; self.offset = offset; self.bigEndian = bigEndian
    }

    var remaining: Int64 { max(0, reader.size - offset) }

    mutating func take(_ count: Int, _ what: @autoclosure () -> String) throws -> [UInt8] {
        let got = try reader.bytes(at: offset, count: count, what())
        offset += Int64(count)
        return got
    }

    mutating func skip(_ count: Int64, _ what: @autoclosure () -> String) throws {
        guard count >= 0, count <= remaining else { throw AIReadError.truncated("inside \(what())") }
        offset += count
    }

    private mutating func unsigned(_ width: Int, _ what: String) throws -> UInt64 {
        let b = try take(width, what)
        var value: UInt64 = 0
        for i in 0..<width {
            value |= UInt64(b[i]) << (8 * UInt64(bigEndian ? width - 1 - i : i))
        }
        return value
    }

    mutating func u8(_ what: String) throws -> UInt8 { UInt8(try unsigned(1, what)) }
    mutating func u16(_ what: String) throws -> UInt16 { UInt16(try unsigned(2, what)) }
    mutating func u32(_ what: String) throws -> UInt32 { UInt32(try unsigned(4, what)) }
    mutating func u64(_ what: String) throws -> UInt64 { try unsigned(8, what) }
}

/// A read-only view of one node of a `StructuredTree` (VitrineData's JSON and YAML parsers), navigated by key.
struct AIJSONView {
    let tree: StructuredTree
    let index: Int

    var node: StructuredNode { tree[index] }
    var kind: StructuredNodeKind { node.kind }
    var name: String? { node.name }
    var isObject: Bool { kind == .object }
    var isArray: Bool { kind == .array }
    /// Kept children.
    var children: [AIJSONView] { tree.children(of: index).map { AIJSONView(tree: tree, index: $0) } }
    /// Children the source holds, counted even past a node or depth limit.
    var count: Int { node.sourceChildCount }

    subscript(key: String) -> AIJSONView? {
        guard isObject else { return nil }
        return tree.children(of: index).last { tree[$0].name == key }.map { AIJSONView(tree: tree, index: $0) }
    }

    /// A string value (an unexpanded YAML alias is not one).
    var string: String? { kind == .string && node.role == .value ? node.preview : nil }
    /// Any scalar as text: strings, numbers, booleans and null as written.
    var scalarText: String? {
        switch kind {
        case .string, .number, .bool, .date: node.role == .value ? node.preview : nil
        case .null: "null"
        default: nil
        }
    }
    var bool: Bool? {
        guard kind == .bool || kind == .string else { return nil }
        switch node.preview.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        default: return nil
        }
    }
    var int64: Int64? { kind == .number ? Int64(node.preview) ?? Double(node.preview).flatMap { Int64(exactly: $0) } : nil }
    /// A string, or each string of an array of strings.
    var strings: [String] {
        if let s = string { return [s] }
        if isArray { return children.compactMap(\.scalarText) }
        return []
    }

    /// Parses JSON (lenient: JSONC and JSON5 too) or YAML into a root view. Nil when nothing parsed.
    static func parse(_ bytes: [UInt8], format: StructuredFormat, maxPreviewBytes: Int = 64 * 1024,
                      maxDepth: Int = 64, maxNodes: Int = 200_000, fileSize: Int64? = nil) -> (AIJSONView?, StructuredParseResult) {
        var options = StructuredOptions()
        options.maxPreviewBytes = maxPreviewBytes
        options.maxDepth = maxDepth
        options.maxNodes = maxNodes
        options.maxDiagnostics = 20
        let result = StructuredParser.parse(Data(bytes), format: format, options: options, fileSize: fileSize)
        guard let root = result.tree.roots.first(where: { result.tree[$0].role == .value || result.tree[$0].kind.isContainer }) else {
            return (nil, result)
        }
        return (AIJSONView(tree: result.tree, index: root), result)
    }
}

/// Small formatting helpers shared by the summaries.
enum AIFormat {
    // Fact labels several cards share, so each has one translation.
    static var formatLabel: String { String(localized: "Format", bundle: .module, comment: "Fact label on an AI model or pickle card: the file format.") }
    static var nameLabel: String { String(localized: "Name", bundle: .module, comment: "Fact label on an AI model card.") }
    static var parametersLabel: String { String(localized: "Parameters", bundle: .module, comment: "Fact label on an AI model card: the number of weights, such as 7.24 B.") }
    static var tensorsLabel: String { String(localized: "Tensors", bundle: .module, comment: "Fact label on an AI model card: the number of weight arrays.") }
    static var licenseLabel: String { String(localized: "License", bundle: .module, comment: "Fact label on an AI model card.") }
    static var descriptionLabel: String { String(localized: "Description", bundle: .module, comment: "Fact label on an AI model card.") }
    static var inputLabel: String { String(localized: "Input", bundle: .module, comment: "Fact label on an AI model card: one of the model's inputs.") }
    static var outputLabel: String { String(localized: "Output", bundle: .module, comment: "Fact label on an AI model card: one of the model's outputs.") }
    static var vocabularyLabel: String { String(localized: "Vocabulary", bundle: .module, comment: "Fact label on an AI model or tokenizer card: the number of tokens.") }
    static var tokenizerLabel: String { String(localized: "Tokenizer", bundle: .module, comment: "Fact label on an AI model card: the tokenizer type.") }
    static var yes: String { String(localized: "yes", bundle: .module, comment: "A fact's value on an AI model card.") }

    static func count(_ n: Int) -> String { n.formatted(.number.grouping(.automatic)) }
    static func count(_ n: Int64) -> String { n.formatted(.number.grouping(.automatic)) }
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// "7.24 B", "135 M", "12.3 K": a parameter count the way model cards say it.
    static func parameters(_ n: Int64) -> String {
        let d = Double(n)
        switch d {
        case 1e12...: return String(format: "%.2f T", d / 1e12)
        case 1e9...: return String(format: "%.2f B", d / 1e9)
        case 1e6...: return String(format: "%.1f M", d / 1e6)
        case 1e3...: return String(format: "%.1f K", d / 1e3)
        default: return "\(n)"
        }
    }

    /// Cuts `s` to `limit` characters with an ellipsis.
    static func clip(_ s: String, _ limit: Int = 160) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }

    /// Bytes as UTF-8 text, the replacement character for invalid sequences.
    static func text(_ bytes: some Collection<UInt8>) -> String { String(decoding: bytes, as: UTF8.self) }

    /// The product of `dims`, nil on overflow or a negative dimension.
    static func product(_ dims: [Int64]) -> Int64? {
        var total: Int64 = 1
        for d in dims {
            guard d >= 0 else { return nil }
            let (v, o) = total.multipliedReportingOverflow(by: d)
            if o { return nil }
            total = v
        }
        return total
    }

    /// "[1, 3, 224, 224]"
    static func shape(_ dims: [String]) -> String { "[" + dims.joined(separator: ", ") + "]" }
}
