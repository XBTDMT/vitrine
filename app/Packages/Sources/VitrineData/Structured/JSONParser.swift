import Foundation

/// Which non-RFC features a lenient parse used, so the facts can name the dialect it really is.
struct JSONFeatures: OptionSet, Sendable {
    let rawValue: UInt8
    /// `//` and `/* */` comments (JSONC).
    static let comments = JSONFeatures(rawValue: 1)
    /// A comma before `]` or `}` (JSONC allows it too).
    static let trailingCommas = JSONFeatures(rawValue: 2)
    /// Anything only JSON5 allows: single quotes, unquoted keys, hex, leading `+`, `.5`, `5.`, Infinity, NaN, extra
    /// escapes and whitespace.
    static let json5 = JSONFeatures(rawValue: 4)
}

/// How one JSON parse ended.
struct JSONOutcome {
    var error: StructuredDiagnostic?
    /// The error is data after a complete top-level value, starting on a later line: the shape of JSON Lines.
    var extraDataOnLaterLine = false
    /// Byte position of the error, to compare how far a strict and a lenient parse got.
    var errorPosition = 0
    /// The input stopped inside the document and the caller said it was cut short (not an error).
    var endedEarly = false
    var features: JSONFeatures = []
    /// Whether any value was seen.
    var sawValue = false
}

/// RFC 8259 JSON, and with `lenient` JSONC and JSON5, parsed byte by byte straight into a `StructuredTreeBuilder`.
/// Iterative: nesting lives in a heap array, so a file of a million `[` costs memory, not stack. Line and column are
/// tracked as it goes so the first error reads "3:14: expected ':' after the key". Numbers are kept exactly as
/// written; strings are decoded only as far as the preview needs, and not at all once the builder stops keeping
/// nodes (it still validates them, so the error and the total count stay true).
struct JSONParser {
    private let b: UnsafeBufferPointer<UInt8>
    private let lenient: Bool
    private let baseOffset: Int64
    private let baseLine: Int
    private let maxKeyBytes: Int
    private let maxPreviewBytes: Int
    private var pos: Int
    private var line = 0
    private var lineStart: Int
    private var features: JSONFeatures = []

    /// - Parameters:
    ///   - range: the bytes to parse (JSON Lines passes one line).
    ///   - baseOffset: file offset of `range.lowerBound`'s byte 0 of `bytes`, so spans are file offsets.
    ///   - baseLine: the 1-based line `range` starts on.
    init(bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>? = nil, lenient: Bool, baseOffset: Int64 = 0, baseLine: Int = 1,
         options: StructuredOptions) {
        let range = range ?? 0..<bytes.count
        b = UnsafeBufferPointer(rebasing: bytes[range])
        self.lenient = lenient
        self.baseOffset = baseOffset + Int64(range.lowerBound)
        self.baseLine = baseLine
        maxKeyBytes = max(1, options.maxKeyBytes)
        maxPreviewBytes = max(1, options.maxPreviewBytes)
        pos = 0
        lineStart = 0
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { pos = 3; lineStart = 3 }
    }

    private struct Failure: Error {
        var reason: String
        var position: Int
        var atEnd = false
        var extraData = false
    }

    private enum Expect { case value, firstValueOrEnd, valueAfterComma, keyOrEnd, keyAfterComma, colon, commaOrEnd, end }

    // MARK: Document

    /// Parses one top-level value (and requires only whitespace and, when lenient, comments after it).
    mutating func parse(into builder: inout StructuredTreeBuilder, inputTruncated: Bool) -> JSONOutcome {
        var outcome = JSONOutcome()
        var frames: [Bool] = []   // true: object
        var expect = Expect.value
        var pendingKey: String?
        var rootEndLine = 0

        func finishValue() {
            if frames.isEmpty { expect = .end; rootEndLine = line } else { expect = .commaOrEnd }
        }

        do {
            while true {
                try skipTrivia()
                guard pos < b.count else {
                    if expect == .end { break }
                    if !outcome.sawValue && frames.isEmpty && !inputTruncated {
                        throw Failure(reason: String(localized: "empty document: expected a value", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos, atEnd: true)
                    }
                    throw Failure(reason: endOfInputReason(expect, inObject: frames.last), position: pos, atEnd: true)
                }
                let c = b[pos]
                switch expect {
                case .end:
                    throw Failure(reason: String(localized: "unexpected \(describe(c)) after the top-level value", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos,
                                  extraData: line > rootEndLine)
                case .colon:
                    guard c == UInt8(ascii: ":") else { throw Failure(reason: String(localized: "expected ':' after the key", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
                    pos += 1
                    expect = .value
                case .commaOrEnd:
                    let inObject = frames[frames.count - 1]
                    if c == UInt8(ascii: ",") {
                        pos += 1
                        expect = inObject ? .keyAfterComma : .valueAfterComma
                    } else if c == (inObject ? UInt8(ascii: "}") : UInt8(ascii: "]")) {
                        frames.removeLast(); pos += 1
                        builder.close(endOffset: baseOffset + Int64(pos))
                        finishValue()
                    } else {
                        throw Failure(reason: inObject ? String(localized: "expected ',' or '}' after an object member", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
                                                       : String(localized: "expected ',' or ']' after an array item", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos)
                    }
                case .keyOrEnd, .keyAfterComma:
                    if c == UInt8(ascii: "}") {
                        if expect == .keyAfterComma { try trailingComma("}") }
                        frames.removeLast(); pos += 1
                        builder.close(endOffset: baseOffset + Int64(pos))
                        finishValue()
                        continue
                    }
                    pendingKey = try key(c)
                    expect = .colon
                case .value, .firstValueOrEnd, .valueAfterComma:
                    if c == UInt8(ascii: "]"), frames.last == false, expect != .value {
                        if expect == .valueAfterComma { try trailingComma("]") }
                        frames.removeLast(); pos += 1
                        builder.close(endOffset: baseOffset + Int64(pos))
                        finishValue()
                        continue
                    }
                    outcome.sawValue = true
                    let name = pendingKey
                    pendingKey = nil
                    let start = pos
                    let span = spanAt(start)
                    switch c {
                    case UInt8(ascii: "{"):
                        builder.open(.object, name: name, span: span)
                        frames.append(true); pos += 1
                        expect = .keyOrEnd
                    case UInt8(ascii: "["):
                        builder.open(.array, name: name, span: span)
                        frames.append(false); pos += 1
                        expect = .firstValueOrEnd
                    case UInt8(ascii: "\""), UInt8(ascii: "'"):
                        if c == UInt8(ascii: "'") {
                            guard lenient else { throw Failure(reason: String(localized: "strings must use double quotes", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
                            features.insert(.json5)
                        }
                        let decode = builder.isStoringNewNodes
                        let (text, cut) = try string(quote: c, decode: decode, limit: maxPreviewBytes)
                        builder.leaf(.string, name: name, preview: text, truncated: cut, span: finished(span, start))
                        finishValue()
                    case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "."):
                        if !lenient, c == UInt8(ascii: "+") || c == UInt8(ascii: ".") {
                            throw Failure(reason: String(localized: "unexpected \(describe(c)): expected a value", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos)
                        }
                        try number()
                        builder.leaf(.number, name: name, preview: text(start, pos, limit: maxPreviewBytes).0,
                                     truncated: pos - start > maxPreviewBytes, span: finished(span, start))
                        finishValue()
                    default:
                        let kind = try literal()
                        builder.leaf(kind, name: name, preview: text(start, pos, limit: 64).0, span: finished(span, start))
                        finishValue()
                    }
                }
            }
        } catch let failure as Failure {
            outcome.errorPosition = failure.position
            if failure.atEnd && inputTruncated {
                outcome.endedEarly = true
            } else {
                outcome.error = StructuredDiagnostic(.error, failure.reason, at: location(failure.position))
                outcome.extraDataOnLaterLine = failure.extraData
            }
        } catch {}
        outcome.features = features
        return outcome
    }

    // MARK: Pieces

    private mutating func trailingComma(_ bracket: String) throws {
        guard lenient else { throw Failure(reason: String(localized: "trailing comma before '\(bracket)'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
        features.insert(.trailingCommas)
    }

    private func endOfInputReason(_ expect: Expect, inObject: Bool?) -> String {
        switch (expect, inObject) {
        case (.colon, nil): return String(localized: "unexpected end of input: expected ':'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
        case (.colon, true?): return String(localized: "unexpected end of input: expected ':' (an object is not closed)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
        case (.colon, false?): return String(localized: "unexpected end of input: expected ':' (an array is not closed)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
        case (.keyOrEnd, nil), (.keyAfterComma, nil): return String(localized: "unexpected end of input: expected a key or '}'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
        case (.keyOrEnd, true?), (.keyAfterComma, true?): return String(localized: "unexpected end of input: expected a key or '}' (an object is not closed)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
        case (.keyOrEnd, false?), (.keyAfterComma, false?): return String(localized: "unexpected end of input: expected a key or '}' (an array is not closed)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
        case (.commaOrEnd, nil): return String(localized: "unexpected end of input: expected ',' or a closing bracket", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
        case (.commaOrEnd, true?): return String(localized: "unexpected end of input: expected ',' or a closing bracket (an object is not closed)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
        case (.commaOrEnd, false?): return String(localized: "unexpected end of input: expected ',' or a closing bracket (an array is not closed)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
        case (_, nil): return String(localized: "unexpected end of input: expected a value", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
        case (_, true?): return String(localized: "unexpected end of input: expected a value (an object is not closed)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
        case (_, false?): return String(localized: "unexpected end of input: expected a value (an array is not closed)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
        }
    }

    private mutating func key(_ c: UInt8) throws -> String {
        if c == UInt8(ascii: "\"") { return try string(quote: c, decode: true, limit: maxKeyBytes).0 }
        guard lenient else {
            if c == UInt8(ascii: "'") || isIdentifierStart(c) {
                throw Failure(reason: String(localized: "object keys must be double-quoted strings", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos)
            }
            throw Failure(reason: String(localized: "unexpected \(describe(c)): expected a key or '}'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos)
        }
        features.insert(.json5)
        if c == UInt8(ascii: "'") { return try string(quote: c, decode: true, limit: maxKeyBytes).0 }
        guard isIdentifierStart(c) else {
            throw Failure(reason: String(localized: "unexpected \(describe(c)): expected a key or '}'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos)
        }
        let start = pos
        while pos < b.count, isIdentifierPart(b[pos]) {
            if b[pos] >= 0x80 { pos += try utf8Length(at: pos) } else { pos += 1 }
        }
        return text(start, pos, limit: maxKeyBytes).0
    }

    private func isIdentifierStart(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c >= 0x80
    }

    private func isIdentifierPart(_ c: UInt8) -> Bool { isIdentifierStart(c) || (c >= 48 && c <= 57) }

    private mutating func literal() throws -> StructuredNodeKind {
        let start = pos
        while pos < b.count, isIdentifierPart(b[pos]), b[pos] < 0x80 { pos += 1 }
        let word = text(start, pos, limit: 32).0
        switch word {
        case "true", "false": return .bool
        case "null": return .null
        case "Infinity" where lenient, "NaN" where lenient:
            features.insert(.json5)
            return .number
        case "":
            pos = start
            throw Failure(reason: String(localized: "unexpected \(describe(b[start])): expected a value", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
        default:
            pos = start
            if word.hasPrefix("tru") || word.hasPrefix("fals") || word.hasPrefix("nul") {
                throw Failure(reason: String(localized: "invalid literal '\(word)'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
            }
            throw Failure(reason: String(localized: "unexpected '\(word)': expected a value", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
        }
    }

    private mutating func number() throws {
        func digits() -> Int {
            let s = pos
            while pos < b.count, b[pos] >= 48, b[pos] <= 57 { pos += 1 }
            return pos - s
        }
        if b[pos] == UInt8(ascii: "-") || b[pos] == UInt8(ascii: "+") {
            if b[pos] == UInt8(ascii: "+") { features.insert(.json5) }
            pos += 1
            if lenient, pos < b.count, b[pos] == UInt8(ascii: "I") || b[pos] == UInt8(ascii: "N") {
                _ = try literal()
                return
            }
        }
        guard pos < b.count else { throw Failure(reason: String(localized: "expected a digit after the sign", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos, atEnd: true) }
        var intDigits = 0
        if b[pos] == UInt8(ascii: "0") {
            pos += 1; intDigits = 1
            if lenient, pos < b.count, b[pos] | 0x20 == UInt8(ascii: "x") {
                pos += 1
                let s = pos
                while pos < b.count, isHex(b[pos]) { pos += 1 }
                guard pos > s else { throw Failure(reason: String(localized: "expected a hex digit after '0x'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos, atEnd: pos >= b.count) }
                features.insert(.json5)
                return
            }
            if pos < b.count, b[pos] >= 48, b[pos] <= 57 { throw Failure(reason: String(localized: "leading zeros are not allowed", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos - 1) }
        } else if b[pos] >= 49, b[pos] <= 57 {
            intDigits = digits()
        } else if !(lenient && b[pos] == UInt8(ascii: ".")) {
            throw Failure(reason: String(localized: "expected a digit, found \(describe(b[pos]))", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos)
        }
        if pos < b.count, b[pos] == UInt8(ascii: ".") {
            pos += 1
            let frac = digits()
            if frac == 0 {
                if !lenient || intDigits == 0 {
                    throw Failure(reason: String(localized: "expected a digit after '.'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos, atEnd: pos >= b.count)
                }
                features.insert(.json5)
            } else if intDigits == 0 {
                features.insert(.json5)
            }
        }
        if pos < b.count, b[pos] | 0x20 == UInt8(ascii: "e") {
            pos += 1
            if pos < b.count, b[pos] == UInt8(ascii: "+") || b[pos] == UInt8(ascii: "-") { pos += 1 }
            if digits() == 0 { throw Failure(reason: String(localized: "expected a digit in the exponent", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos, atEnd: pos >= b.count) }
        }
    }

    /// Scans a string from its opening quote. Returns the decoded text (cut to `limit` bytes) when `decode`.
    private mutating func string(quote: UInt8, decode: Bool, limit: Int) throws -> (String, Bool) {
        let open = pos
        pos += 1
        let contentStart = pos
        var out: [UInt8]?
        var truncated = false

        // Until the first escape, `out` is nil and the text is sliced straight from the source at the end, so
        // appending to a nil buffer is correctly a no-op.
        func append(_ byte: UInt8) {
            guard decode, let count = out?.count else { return }
            if count < limit { out?.append(byte) } else { truncated = true }
        }
        func append(scalar value: UInt32) {
            guard decode else { return }
            for byte in String(Character(Unicode.Scalar(value) ?? "\u{FFFD}")).utf8 { append(byte) }
        }
        func startEscapes() {
            guard decode, out == nil else { return }
            let end = min(pos, contentStart + limit)
            var bytes = Array(b[contentStart..<end])
            bytes.reserveCapacity(limit + 4)
            out = bytes
            if pos - contentStart > limit { truncated = true }
        }

        while true {
            guard pos < b.count else { throw Failure(reason: String(localized: "unterminated string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: open, atEnd: true) }
            let ch = b[pos]
            if ch == quote { break }
            if ch == UInt8(ascii: "\\") {
                startEscapes()
                pos += 1
                guard pos < b.count else { throw Failure(reason: String(localized: "unterminated string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: open, atEnd: true) }
                let e = b[pos]
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): append(e); pos += 1
                case UInt8(ascii: "b"): append(8); pos += 1
                case UInt8(ascii: "f"): append(12); pos += 1
                case UInt8(ascii: "n"): append(10); pos += 1
                case UInt8(ascii: "r"): append(13); pos += 1
                case UInt8(ascii: "t"): append(9); pos += 1
                case UInt8(ascii: "u"):
                    var value = try hex(at: pos + 1, count: 4)
                    pos += 5
                    if (0xD800...0xDBFF).contains(value), pos + 5 < b.count, b[pos] == UInt8(ascii: "\\"), b[pos + 1] == UInt8(ascii: "u"),
                       let low = try? hex(at: pos + 2, count: 4), (0xDC00...0xDFFF).contains(low) {
                        value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                        pos += 6
                    }
                    append(scalar: value)
                default:
                    guard lenient else {
                        throw Failure(reason: String(localized: "invalid escape '\\\(printable(e))' in a string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos - 1)
                    }
                    features.insert(.json5)
                    switch e {
                    case UInt8(ascii: "'"): append(39); pos += 1
                    case UInt8(ascii: "v"): append(11); pos += 1
                    case UInt8(ascii: "0") where !(pos + 1 < b.count && b[pos + 1] >= 48 && b[pos + 1] <= 57):
                        append(0); pos += 1
                    case UInt8(ascii: "x"):
                        append(scalar: try hex(at: pos + 1, count: 2)); pos += 3
                    case 0x0A:
                        pos += 1; line += 1; lineStart = pos
                    case 0x0D:
                        pos += 1
                        if pos < b.count, b[pos] == 0x0A { pos += 1 }
                        line += 1; lineStart = pos
                    case UInt8(ascii: "1")...UInt8(ascii: "9"):
                        throw Failure(reason: String(localized: "invalid escape '\\\(printable(e))' in a string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos - 1)
                    default:
                        let n = e >= 0x80 ? try utf8Length(at: pos) : 1
                        for k in 0..<n { append(b[pos + k]) }
                        pos += n
                    }
                }
                continue
            }
            if ch < 0x20 {
                if lenient && ch == 0x09 { append(ch); pos += 1; continue }
                let code = String(format: "%04X", ch)
                let what = ch == 0x0A || ch == 0x0D ? String(localized: "unescaped line break in a string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
                    : String(localized: "control character U+\(code) in a string must be escaped", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
                throw Failure(reason: what, position: pos)
            }
            if ch >= 0x80 {
                let n = try utf8Length(at: pos)
                if out != nil { for k in 0..<n { append(b[pos + k]) } }
                pos += n
            } else {
                if out != nil { append(ch) }
                pos += 1
            }
        }
        let close = pos
        pos += 1
        guard decode else { return ("", false) }
        if var bytes = out {
            if truncated { trimIncompleteUTF8(&bytes) }
            return (String(decoding: bytes, as: UTF8.self), truncated)
        }
        return text(contentStart, close, limit: limit)
    }

    private func hex(at start: Int, count: Int) throws -> UInt32 {
        guard start + count <= b.count else {
            throw Failure(reason: String(localized: "expected \(count) hex digits in an escape", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start, atEnd: true)
        }
        var value: UInt32 = 0
        for i in start..<(start + count) {
            let c = b[i]
            let d: UInt8
            switch c {
            case 48...57: d = c - 48
            case 65...70: d = c - 55
            case 97...102: d = c - 87
            default: throw Failure(reason: String(localized: "expected \(count) hex digits in an escape", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: i)
            }
            value = value << 4 | UInt32(d)
        }
        return value
    }

    private func isHex(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) }

    /// The length of the well-formed UTF-8 sequence at `i`, or a failure. Overlong forms and surrogates are rejected.
    private func utf8Length(at i: Int) throws -> Int {
        let lead = b[i]
        let n: Int
        var lo: UInt8 = 0x80, hi: UInt8 = 0xBF
        switch lead {
        case 0xC2...0xDF: n = 2
        case 0xE0: n = 3; lo = 0xA0
        case 0xE1...0xEC, 0xEE...0xEF: n = 3
        case 0xED: n = 3; hi = 0x9F
        case 0xF0: n = 4; lo = 0x90
        case 0xF1...0xF3: n = 4
        case 0xF4: n = 4; hi = 0x8F
        default: throw Failure(reason: String(localized: "invalid UTF-8 byte 0x\(String(format: "%02X", lead))", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: i)
        }
        guard i + n <= b.count else { throw Failure(reason: String(localized: "truncated UTF-8 sequence", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: i, atEnd: true) }
        for k in 1..<n {
            let c = b[i + k]
            let (l, h) = k == 1 ? (lo, hi) : (UInt8(0x80), UInt8(0xBF))
            guard c >= l, c <= h else { throw Failure(reason: String(localized: "invalid UTF-8 sequence", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: i) }
        }
        return n
    }

    private mutating func skipTrivia() throws {
        while pos < b.count {
            let c = b[pos]
            switch c {
            case 0x20, 0x09, 0x0D: pos += 1
            case 0x0A: pos += 1; line += 1; lineStart = pos
            case UInt8(ascii: "/") where lenient && pos + 1 < b.count && b[pos + 1] == UInt8(ascii: "/"):
                features.insert(.comments)
                while pos < b.count, b[pos] != 0x0A { pos += 1 }
            case UInt8(ascii: "/") where lenient && pos + 1 < b.count && b[pos + 1] == UInt8(ascii: "*"):
                features.insert(.comments)
                let open = pos
                pos += 2
                while true {
                    guard pos + 1 < b.count else {
                        pos = b.count
                        throw Failure(reason: String(localized: "unterminated block comment", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: open, atEnd: true)
                    }
                    if b[pos] == UInt8(ascii: "*"), b[pos + 1] == UInt8(ascii: "/") { pos += 2; break }
                    if b[pos] == 0x0A { line += 1; lineStart = pos + 1 }
                    pos += 1
                }
            case UInt8(ascii: "/") where !lenient:
                throw Failure(reason: String(localized: "comments are not allowed in strict JSON", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos)
            case 0x0B where lenient, 0x0C where lenient:
                features.insert(.json5); pos += 1
            case 0xC2 where lenient && pos + 1 < b.count && b[pos + 1] == 0xA0:
                features.insert(.json5); pos += 2
            case 0xE2 where lenient && pos + 2 < b.count && b[pos + 1] == 0x80 && (b[pos + 2] == 0xA8 || b[pos + 2] == 0xA9):
                features.insert(.json5); pos += 3
            default:
                return
            }
        }
    }

    // MARK: Positions and text

    private func spanAt(_ start: Int) -> StructuredSpan {
        StructuredSpan(byteOffset: baseOffset + Int64(start), byteLength: nil, line: baseLine + line,
                       column: start - lineStart + 1)
    }

    private func finished(_ span: StructuredSpan, _ start: Int) -> StructuredSpan {
        var span = span
        span.byteLength = Int64(pos - start)
        return span
    }

    /// The error location: line, and column in characters (counted only here, so it never costs a pass over a long
    /// minified line during the parse).
    private func location(_ position: Int) -> StructuredLocation {
        // Positions inside the current line; a failure position before `lineStart` (a string that opened on an
        // earlier line) still reports the current line, which is where the reader noticed.
        let from = min(lineStart, position), to = min(position, b.count)
        var column = 1
        if to > from { for i in from..<to where b[i] & 0xC0 != 0x80 { column += 1 } }
        return StructuredLocation(line: baseLine + line, column: column, byteOffset: baseOffset + Int64(position))
    }

    private func text(_ start: Int, _ end: Int, limit: Int) -> (String, Bool) {
        var stop = min(end, start + limit)
        let cut = end - start > limit
        if cut { while stop > start, b[stop] & 0xC0 == 0x80 { stop -= 1 } }
        return (String(decoding: UnsafeBufferPointer(rebasing: b[start..<stop]), as: UTF8.self), cut)
    }

    private func describe(_ c: UInt8) -> String {
        if c >= 0x21 && c < 0x7F { return "'\(Character(Unicode.Scalar(c)))'" }
        if c >= 0x80 { return String(localized: "character", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'. A non-ASCII character.") }
        let hex = String(format: "%02X", c)
        return String(localized: "byte 0x\(hex)", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'. A byte in hexadecimal.")
    }

    private func printable(_ c: UInt8) -> String {
        c >= 0x21 && c < 0x7F ? String(Character(Unicode.Scalar(c))) : String(format: "x%02X", c)
    }
}

/// Drops a multi-byte sequence the preview cut in half.
func trimIncompleteUTF8(_ bytes: inout [UInt8]) {
    var i = bytes.count - 1
    var continuation = 0
    while i >= 0, bytes[i] & 0xC0 == 0x80, continuation < 3 { i -= 1; continuation += 1 }
    guard i >= 0 else { bytes.removeAll(); return }
    let lead = bytes[i]
    let need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
    if continuation + 1 < need { bytes.removeSubrange(i...) }
}
