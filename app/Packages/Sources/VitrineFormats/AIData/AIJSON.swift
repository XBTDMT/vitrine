import Foundation

/// The JSON value kinds a JSONL schema reports for a field. roadmap: S-21
public enum AIJSONType: String, Sendable, Equatable, Hashable, CaseIterable {
    case object, array, string, integer, number, boolean, null
}

/// A JSON value as these readers need it: object members keep their order (a table's columns follow the file),
/// numbers keep their text (an id of 20 digits stays exact), and long strings are stored cut (see `AIJSONParser`).
enum AIJSON: Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([AIJSON])
    case object([AIJSONMember])
}

struct AIJSONMember: Sendable {
    let key: String
    let value: AIJSON
}

extension AIJSON {
    subscript(key: String) -> AIJSON? {
        guard case .object(let members) = self else { return nil }
        for member in members where member.key == key { return member.value }
        return nil
    }

    /// The value at a path of keys, nil when any step is missing.
    func at(_ keys: String...) -> AIJSON? {
        var current: AIJSON? = self
        for key in keys { current = current?[key] }
        return current
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var array: [AIJSON]? { if case .array(let a) = self { a } else { nil } }
    var members: [AIJSONMember]? { if case .object(let m) = self { m } else { nil } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var isNull: Bool { if case .null = self { true } else { false } }
    var isObject: Bool { members != nil }

    /// A number, or a string that holds one (OTLP writes 64-bit integers as strings).
    var double: Double? {
        switch self {
        case .number(let raw): Double(raw)
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// An integer, from an integral number or a string that holds one.
    var int: Int? {
        switch self {
        case .number(let raw):
            if let v = Int(raw) { return v }
            if let d = Double(raw), d == d.rounded(), abs(d) < 9e15 { return Int(d) }
            return nil
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// An unsigned 64-bit integer from a number or a numeric string (nanosecond timestamps).
    var uint64: UInt64? {
        switch self {
        case .number(let raw):
            if let v = UInt64(raw) { return v }
            if let d = Double(raw), d >= 0, d < 1.8e19 { return UInt64(d) }
            return nil
        case .string(let s): return UInt64(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// A non-empty string, else nil.
    var text: String? {
        guard let s = string, !s.isEmpty else { return nil }
        return s
    }

    var type: AIJSONType {
        switch self {
        case .null: .null
        case .bool: .boolean
        case .number(let raw): raw.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) ? .number : .integer
        case .string: .string
        case .array: .array
        case .object: .object
        }
    }

    /// How a table cell shows the value: strings as they are, numbers and literals as written, containers as compact
    /// JSON; at most `limit` characters.
    func display(limit: Int = AIDataTable.maxCellCharacters) -> String {
        switch self {
        case .string(let s): AIText.cap(s, limit)
        case .number(let raw): AIText.cap(raw, limit)
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        case .array, .object: AIText.cap(compact(limit: limit + 1), limit)
        }
    }

    /// Compact JSON text, stopping once `limit` characters are written.
    func compact(limit: Int) -> String {
        var out = ""
        var budget = max(1, limit)
        write(into: &out, budget: &budget)
        return out
    }

    private func write(into out: inout String, budget: inout Int) {
        func emit(_ s: String) {
            guard budget > 0 else { return }
            if s.count <= budget {
                out += s
                budget -= s.count
            } else {
                out += s.prefix(budget)
                budget = 0
            }
        }
        guard budget > 0 else { return }
        switch self {
        case .null: emit("null")
        case .bool(let b): emit(b ? "true" : "false")
        case .number(let raw): emit(raw)
        case .string(let s): emit("\"" + String(s.prefix(budget)) + "\"")
        case .array(let items):
            emit("[")
            for (index, item) in items.enumerated() {
                guard budget > 0 else { return }
                if index > 0 { emit(",") }
                item.write(into: &out, budget: &budget)
            }
            emit("]")
        case .object(let members):
            emit("{")
            for (index, member) in members.enumerated() {
                guard budget > 0 else { return }
                if index > 0 { emit(",") }
                emit("\"" + String(member.key.prefix(budget)) + "\":")
                member.value.write(into: &out, budget: &budget)
            }
            emit("}")
        }
    }
}

/// A strict, bounded JSON parser (RFC 8259) over untrusted bytes: nesting deeper than `maxDepth` is refused, strings
/// are stored up to `stringCap` UTF-8 bytes (the rest is still checked, and the stored text ends with "…"), and once
/// `nodeBudget` values have been built it keeps validating without building, so a huge document yields its first part
/// and `budgetHit` instead of exhausting memory.
struct AIJSONParser {
    enum Failure: Error, Equatable {
        /// Not JSON at this byte offset.
        case syntax(Int)
        /// Nesting deeper than the limit at this byte offset.
        case tooDeep(Int)
        /// The bytes ended inside a value.
        case unexpectedEnd

        var offset: Int? {
            switch self {
            case .syntax(let o), .tooDeep(let o): o
            case .unexpectedEnd: nil
            }
        }
    }

    struct Limits: Sendable {
        var stringCap: Int
        var maxDepth: Int
        var nodeBudget: Int

        /// A whole JSON document (traces, eval results).
        static let document = Limits(stringCap: 8_192, maxDepth: 128, nodeBudget: 1_500_000)
        /// One JSONL record.
        static let record = Limits(stringCap: 1_024, maxDepth: 128, nodeBudget: 200_000)
        /// One conversation in an export.
        static let conversation = Limits(stringCap: 4_096, maxDepth: 128, nodeBudget: 400_000)
    }

    struct Parsed: Sendable {
        let value: AIJSON
        /// The node budget ran out: containers past that point were left out.
        let budgetHit: Bool
    }

    /// The outcome of walking a top-level array element by element.
    struct Stream: Sendable {
        /// Elements seen (built or only validated).
        var count = 0
        /// The closing bracket was reached.
        var complete = false
        var failure: Failure?
        var budgetHit = false
    }

    private let p: UnsafeBufferPointer<UInt8>
    private(set) var i: Int
    private let end: Int
    private let limits: Limits
    private var nodes = 0
    private(set) var budgetHit = false

    private init(_ p: UnsafeBufferPointer<UInt8>, start: Int, end: Int, limits: Limits) {
        self.p = p
        self.i = start
        self.end = end
        self.limits = limits
    }

    // MARK: Entry points

    /// The whole of `range` (default all of `bytes`) as one JSON value with nothing after it but whitespace.
    static func parseDocument(_ bytes: [UInt8], range: Range<Int>? = nil, limits: Limits) -> Result<Parsed, Failure> {
        bytes.withUnsafeBufferPointer { buffer in
            parseDocument(buffer, range: range ?? 0..<buffer.count, limits: limits)
        }
    }

    static func parseDocument(_ buffer: UnsafeBufferPointer<UInt8>, range: Range<Int>, limits: Limits) -> Result<Parsed, Failure> {
        var start = range.lowerBound
        // A UTF-8 byte order mark is tolerated at the start.
        if range.count >= 3, buffer[start] == 0xEF, buffer[start + 1] == 0xBB, buffer[start + 2] == 0xBF { start += 3 }
        var parser = AIJSONParser(buffer, start: start, end: range.upperBound, limits: limits)
        do {
            let value = try parser.value(depth: 0, build: true) ?? .null
            parser.skipWhitespace()
            guard parser.i == parser.end else { return .failure(.syntax(parser.i)) }
            return .success(Parsed(value: value, budgetHit: parser.budgetHit))
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.unexpectedEnd)
        }
    }

    /// Checks `range` is one JSON value without building it.
    static func validate(_ buffer: UnsafeBufferPointer<UInt8>, range: Range<Int>, limits: Limits) -> Failure? {
        var parser = AIJSONParser(buffer, start: range.lowerBound, end: range.upperBound, limits: limits)
        do {
            _ = try parser.value(depth: 0, build: false)
            parser.skipWhitespace()
            return parser.i == parser.end ? nil : .syntax(parser.i)
        } catch let failure as Failure {
            return failure
        } catch {
            return .unexpectedEnd
        }
    }

    /// Walks a top-level array: the first `maxBuilt` elements are built and handed to `body` (which returns false to
    /// stop early), the rest are only validated and counted. Each element has its own node budget.
    static func forEachElement(_ bytes: [UInt8], limits: Limits, maxBuilt: Int,
                               _ body: (AIJSON, Int) -> Bool) -> Stream {
        bytes.withUnsafeBufferPointer { buffer in
            var stream = Stream()
            var parser = AIJSONParser(buffer, start: 0, end: buffer.count, limits: limits)
            if buffer.count >= 3, buffer[0] == 0xEF, buffer[1] == 0xBB, buffer[2] == 0xBF { parser.i = 3 }
            parser.skipWhitespace()
            guard parser.i < parser.end, buffer[parser.i] == UInt8(ascii: "[") else {
                stream.failure = .syntax(parser.i)
                return stream
            }
            parser.i += 1
            do {
                parser.skipWhitespace()
                if parser.i < parser.end, buffer[parser.i] == UInt8(ascii: "]") {
                    stream.complete = true
                    return stream
                }
                while true {
                    parser.nodes = 0
                    parser.budgetHit = false
                    let build = stream.count < maxBuilt
                    let value = try parser.value(depth: 1, build: build)
                    if parser.budgetHit { stream.budgetHit = true }
                    let index = stream.count
                    stream.count += 1
                    if build, let value, !body(value, index) { return stream }
                    parser.skipWhitespace()
                    guard parser.i < parser.end else { throw Failure.unexpectedEnd }
                    if buffer[parser.i] == UInt8(ascii: ",") { parser.i += 1; continue }
                    if buffer[parser.i] == UInt8(ascii: "]") { parser.i += 1; break }
                    throw Failure.syntax(parser.i)
                }
                parser.skipWhitespace()
                if parser.i == parser.end { stream.complete = true } else { stream.failure = .syntax(parser.i) }
            } catch let failure as Failure {
                stream.failure = failure
            } catch {
                stream.failure = .unexpectedEnd
            }
            return stream
        }
    }

    /// The first byte that is not whitespace or a byte order mark.
    static func firstSignificantByte(_ bytes: [UInt8]) -> UInt8? {
        var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        while index < bytes.count {
            let c = bytes[index]
            if c != 0x20, c != 0x09, c != 0x0A, c != 0x0D { return c }
            index += 1
        }
        return nil
    }

    // MARK: Grammar

    mutating func skipWhitespace() {
        while i < end {
            let c = p[i]
            guard c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 else { return }
            i += 1
        }
    }

    /// One value; nil when it was not built (validation only, or the node budget ran out).
    private mutating func value(depth: Int, build requested: Bool) throws -> AIJSON? {
        skipWhitespace()
        guard i < end else { throw Failure.unexpectedEnd }
        var build = requested && !budgetHit
        if build {
            nodes += 1
            if nodes > limits.nodeBudget {
                budgetHit = true
                build = false
            }
        }
        switch p[i] {
        case UInt8(ascii: "{"):
            guard depth < limits.maxDepth else { throw Failure.tooDeep(i) }
            i += 1
            var members: [AIJSONMember] = []
            skipWhitespace()
            if i < end, p[i] == UInt8(ascii: "}") { i += 1; return build ? .object([]) : nil }
            while true {
                skipWhitespace()
                guard i < end else { throw Failure.unexpectedEnd }
                guard p[i] == UInt8(ascii: "\"") else { throw Failure.syntax(i) }
                let key = try string(build: build)
                skipWhitespace()
                guard i < end else { throw Failure.unexpectedEnd }
                guard p[i] == UInt8(ascii: ":") else { throw Failure.syntax(i) }
                i += 1
                let member = try value(depth: depth + 1, build: build)
                if build, let member { members.append(AIJSONMember(key: key ?? "", value: member)) }
                skipWhitespace()
                guard i < end else { throw Failure.unexpectedEnd }
                if p[i] == UInt8(ascii: ",") { i += 1; continue }
                if p[i] == UInt8(ascii: "}") { i += 1; break }
                throw Failure.syntax(i)
            }
            return build ? .object(members) : nil
        case UInt8(ascii: "["):
            guard depth < limits.maxDepth else { throw Failure.tooDeep(i) }
            i += 1
            var items: [AIJSON] = []
            skipWhitespace()
            if i < end, p[i] == UInt8(ascii: "]") { i += 1; return build ? .array([]) : nil }
            while true {
                let item = try value(depth: depth + 1, build: build)
                if build, let item { items.append(item) }
                skipWhitespace()
                guard i < end else { throw Failure.unexpectedEnd }
                if p[i] == UInt8(ascii: ",") { i += 1; continue }
                if p[i] == UInt8(ascii: "]") { i += 1; break }
                throw Failure.syntax(i)
            }
            return build ? .array(items) : nil
        case UInt8(ascii: "\""):
            let s = try string(build: build)
            return build ? .string(s ?? "") : nil
        case UInt8(ascii: "t"):
            try literal("true")
            return build ? .bool(true) : nil
        case UInt8(ascii: "f"):
            try literal("false")
            return build ? .bool(false) : nil
        case UInt8(ascii: "n"):
            try literal("null")
            return build ? .null : nil
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            let start = i
            try number()
            guard build else { return nil }
            return .number(String(decoding: UnsafeBufferPointer(rebasing: p[start..<i]), as: UTF8.self))
        default:
            throw Failure.syntax(i)
        }
    }

    private mutating func literal(_ word: StaticString) throws {
        let count = word.utf8CodeUnitCount
        guard i + count <= end else { throw Failure.unexpectedEnd }
        let expected = UnsafeBufferPointer(start: word.utf8Start, count: count)
        for k in 0..<count where p[i + k] != expected[k] { throw Failure.syntax(i + k) }
        i += count
    }

    private mutating func number() throws {
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        if p[i] == UInt8(ascii: "-") { i += 1 }
        guard i < end else { throw Failure.unexpectedEnd }
        if p[i] == UInt8(ascii: "0") {
            i += 1
        } else if isDigit(p[i]) {
            while i < end, isDigit(p[i]) { i += 1 }
        } else {
            throw Failure.syntax(i)
        }
        if i < end, p[i] == UInt8(ascii: ".") {
            i += 1
            guard i < end else { throw Failure.unexpectedEnd }
            guard isDigit(p[i]) else { throw Failure.syntax(i) }
            while i < end, isDigit(p[i]) { i += 1 }
        }
        if i < end, p[i] == UInt8(ascii: "e") || p[i] == UInt8(ascii: "E") {
            i += 1
            if i < end, p[i] == UInt8(ascii: "+") || p[i] == UInt8(ascii: "-") { i += 1 }
            guard i < end else { throw Failure.unexpectedEnd }
            guard isDigit(p[i]) else { throw Failure.syntax(i) }
            while i < end, isDigit(p[i]) { i += 1 }
        }
    }

    /// A string starting at the opening quote; nil when not built.
    private mutating func string(build: Bool) throws -> String? {
        i += 1
        var out: [UInt8] = []
        var truncated = false
        let cap = limits.stringCap
        func append(_ bytes: UnsafeBufferPointer<UInt8>) {
            guard build else { return }
            let room = cap - out.count
            if room <= 0 { if !bytes.isEmpty { truncated = true }; return }
            if bytes.count <= room {
                out.append(contentsOf: bytes)
            } else {
                out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[0..<room]))
                truncated = true
            }
        }
        func appendScalar(_ scalar: Unicode.Scalar) {
            var utf8: [UInt8] = []
            utf8.reserveCapacity(4)
            UTF8.encode(scalar) { utf8.append($0) }
            utf8.withUnsafeBufferPointer { append($0) }
        }
        while true {
            let runStart = i
            while i < end {
                let c = p[i]
                if c == UInt8(ascii: "\"") || c == UInt8(ascii: "\\") || c < 0x20 { break }
                i += 1
            }
            if i > runStart { append(UnsafeBufferPointer(rebasing: p[runStart..<i])) }
            guard i < end else { throw Failure.unexpectedEnd }
            let c = p[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c < 0x20 { throw Failure.syntax(i) }
            // A backslash escape.
            i += 1
            guard i < end else { throw Failure.unexpectedEnd }
            let e = p[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): appendScalar("\"")
            case UInt8(ascii: "\\"): appendScalar("\\")
            case UInt8(ascii: "/"): appendScalar("/")
            case UInt8(ascii: "b"): appendScalar("\u{08}")
            case UInt8(ascii: "f"): appendScalar("\u{0C}")
            case UInt8(ascii: "n"): appendScalar("\n")
            case UInt8(ascii: "r"): appendScalar("\r")
            case UInt8(ascii: "t"): appendScalar("\t")
            case UInt8(ascii: "u"):
                var unit = try hex4()
                if (0xD800...0xDBFF).contains(unit) {
                    // A high surrogate wants a low one right after it.
                    if i + 1 < end, p[i] == UInt8(ascii: "\\"), p[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                            appendScalar(Unicode.Scalar(unit) ?? "\u{FFFD}")
                        } else {
                            appendScalar("\u{FFFD}")
                            appendScalar(Unicode.Scalar(low) ?? "\u{FFFD}")
                        }
                    } else {
                        appendScalar("\u{FFFD}")
                    }
                } else {
                    appendScalar(Unicode.Scalar(unit) ?? "\u{FFFD}")
                }
            default:
                throw Failure.syntax(i - 1)
            }
        }
        guard build else { return nil }
        var text = String(decoding: out, as: UTF8.self)
        if truncated {
            // A cut in the middle of a UTF-8 sequence decodes as a replacement character; drop it.
            if text.last == "\u{FFFD}" { text.removeLast() }
            text += "…"
        }
        return text
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= end else { throw Failure.unexpectedEnd }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = p[i]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw Failure.syntax(i)
            }
            v = v << 4 | d
            i += 1
        }
        return v
    }
}
