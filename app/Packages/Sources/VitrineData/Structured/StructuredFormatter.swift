import Foundation

/// Tidy text for a "Formatted" view.
public struct StructuredFormattedText: Sendable, Equatable {
    public var text: String
    /// False when formatting stopped early: at input it could not tokenize, or at `maxFormattedBytes`.
    public var isComplete: Bool
    /// Why it stopped, when it did.
    public var stoppedAt: StructuredDiagnostic?
    /// The input was minified (see `StructuredLayout.isMinified`), so this is the view worth showing first.
    public var inputWasMinified: Bool
}

/// Re-indents structured text. JSON and XML are re-laid at the token level, never rebuilt from a parsed value: every
/// string, number and tag is copied byte for byte, so `1.10` stays `1.10`, `1e400` does not overflow, keys keep
/// their order, attribute order and quoting survive, and JSONC/JSON5 comments stay where they were. Formatting is not
/// validation (the parse reports errors); it goes as far as it can tokenize. Iterative throughout.
public enum StructuredFormatter {
    /// Indentation stops growing past this many levels. Nothing that deep is read by indentation, and without the
    /// bound a hostile file of 200,000 nested brackets would format to tens of gigabytes of spaces (output quadratic
    /// in depth); with it, output stays linear in the input.
    public static let maxIndentLevels = 128

    /// Formatted text for any format that has one: JSON (JSONC, JSON5), XML and property lists (as XML). nil for JSON
    /// Lines, YAML and TOML, whose source layout is already the readable one.
    public static func format(_ data: Data, as format: StructuredFormat, indent: Int = 2,
                              options: StructuredOptions = StructuredOptions()) -> StructuredFormattedText? {
        switch format {
        case .json: json(data, indent: indent, options: options)
        case .xml: xml(data, indent: indent, options: options)
        case .propertyList: propertyListXML(data, indent: indent, options: options)
        case .jsonLines, .yaml, .toml: nil
        }
    }

    // MARK: JSON

    public static func json(_ data: Data, indent: Int = 2, options: StructuredOptions = StructuredOptions()) -> StructuredFormattedText {
        let minified = StructuredLayout.measure(data).isMinified
        var input = data
        if let (utf8, _) = StructuredText.transcodeIfNeeded(input) { input = utf8 }
        return input.withUnsafeBytes { raw in
            var formatter = JSONFormatter(bytes: raw.bindMemory(to: UInt8.self), indent: max(0, indent),
                                          limit: max(1, options.maxFormattedBytes))
            formatter.run()
            return StructuredFormattedText(text: String(decoding: formatter.out, as: UTF8.self), isComplete: formatter.stopped == nil,
                                           stoppedAt: formatter.stopped, inputWasMinified: minified)
        }
    }

    private struct JSONFormatter {
        let b: UnsafeBufferPointer<UInt8>
        let indent: Int
        let limit: Int
        var out: [UInt8] = []
        var stopped: StructuredDiagnostic?
        private var pos = 0
        private var line = 1
        private var lineStart = 0
        private var depth = 0
        private var needsBreak = false
        private var lastWasOpen = false
        private var newlineSinceToken = false

        init(bytes: UnsafeBufferPointer<UInt8>, indent: Int, limit: Int) {
            b = bytes
            self.indent = indent
            self.limit = limit
            out.reserveCapacity(min(limit, bytes.count + bytes.count / 2))
            if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { pos = 3; lineStart = 3 }
        }

        private mutating func lead() {
            if needsBreak {
                out.append(0x0A)
                out.append(contentsOf: repeatElement(0x20, count: min(depth, StructuredFormatter.maxIndentLevels) * indent))
                needsBreak = false
            }
        }

        private mutating func copy(_ start: Int, _ end: Int) {
            out.append(contentsOf: UnsafeBufferPointer(rebasing: b[start..<end]))
        }

        private mutating func stop(_ reason: String, at position: Int) {
            var column = 1
            if position > lineStart { for i in lineStart..<min(position, b.count) where b[i] & 0xC0 != 0x80 { column += 1 } }
            stopped = StructuredDiagnostic(.error, reason, at: StructuredLocation(line: line, column: column, byteOffset: Int64(position)))
        }

        mutating func run() {
            while pos < b.count {
                if out.count > limit {
                    stopped = StructuredDiagnostic(.warning, String(localized: "formatted text stopped at \(limit.formatted()) bytes", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."))
                    return
                }
                let c = b[pos]
                switch c {
                case 0x20, 0x09, 0x0D:
                    pos += 1
                case 0x0A:
                    pos += 1; line += 1; lineStart = pos; newlineSinceToken = true
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    lead()
                    out.append(c)
                    depth += 1
                    needsBreak = true
                    lastWasOpen = true
                    token()
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth = max(0, depth - 1)
                    if lastWasOpen {
                        needsBreak = false
                    } else {
                        out.append(0x0A)
                        out.append(contentsOf: repeatElement(0x20, count: min(depth, StructuredFormatter.maxIndentLevels) * indent))
                        needsBreak = false
                    }
                    out.append(c)
                    lastWasOpen = false
                    token()
                case UInt8(ascii: ","):
                    out.append(c)
                    needsBreak = true
                    lastWasOpen = false
                    token()
                case UInt8(ascii: ":"):
                    out.append(c)
                    out.append(0x20)
                    token()
                case UInt8(ascii: "\""), UInt8(ascii: "'"):
                    let start = pos
                    pos += 1
                    while pos < b.count, b[pos] != c, b[pos] != 0x0A {
                        pos += b[pos] == UInt8(ascii: "\\") ? 2 : 1
                    }
                    guard pos < b.count, b[pos] == c else { return stop(String(localized: "unterminated string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), at: start) }
                    pos += 1
                    lead()
                    copy(start, pos)
                    lastWasOpen = false
                    newlineSinceToken = false
                case UInt8(ascii: "/") where pos + 1 < b.count && (b[pos + 1] == UInt8(ascii: "/") || b[pos + 1] == UInt8(ascii: "*")):
                    let start = pos
                    let isLine = b[pos + 1] == UInt8(ascii: "/")
                    if isLine {
                        while pos < b.count, b[pos] != 0x0A { pos += 1 }
                    } else {
                        pos += 2
                        while pos + 1 < b.count, !(b[pos] == UInt8(ascii: "*") && b[pos + 1] == UInt8(ascii: "/")) {
                            if b[pos] == 0x0A { line += 1; lineStart = pos + 1 }
                            pos += 1
                        }
                        guard pos + 1 < b.count else { return stop(String(localized: "unterminated block comment", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), at: start) }
                        pos += 2
                    }
                    var end = pos
                    while end > start, b[end - 1] == 0x20 || b[end - 1] == 0x0D || b[end - 1] == 0x09 { end -= 1 }
                    let ownLine = newlineSinceToken || out.isEmpty
                    if ownLine {
                        if !out.isEmpty { needsBreak = true }
                        lead()
                        copy(start, end)
                    } else {
                        // A comment on the same line as the previous token stays on that line.
                        out.append(0x20)
                        copy(start, end)
                    }
                    // After a line comment, or a comment that had a line to itself, the next token starts a new line.
                    if isLine || ownLine { needsBreak = true }
                    lastWasOpen = false
                    newlineSinceToken = false
                default:
                    let start = pos
                    while pos < b.count, isScalarByte(b[pos]) { pos += 1 }
                    guard pos > start else {
                        let what = c >= 0x21 && c < 0x7F ? "'\(Character(Unicode.Scalar(c)))'" : String(format: "byte 0x%02X", c)
                        return stop(String(localized: "unexpected \(what)", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), at: start)
                    }
                    lead()
                    copy(start, pos)
                    lastWasOpen = false
                    newlineSinceToken = false
                }
            }
            if !out.isEmpty, out.last != 0x0A { out.append(0x0A) }
        }

        private mutating func token() {
            pos += 1
            newlineSinceToken = false
        }

        private func isScalarByte(_ c: UInt8) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 36 || c == 43 || c == 45
                || c == 46 || c >= 0x80
        }
    }

    // MARK: XML

    /// Re-indents XML: one tag per line, an element whose only content is text or CDATA kept on one line
    /// (`<title>Hello</title>`), whitespace-only text dropped and other text trimmed of surrounding whitespace. Tags
    /// are copied verbatim. Mixed content (text beside elements) is laid out line by line, which changes its
    /// whitespace; this is a reading view, the Source view keeps the original.
    public static func xml(_ data: Data, indent: Int = 2, options: StructuredOptions = StructuredOptions()) -> StructuredFormattedText {
        let minified = StructuredLayout.measure(data).isMinified
        let limit = max(1, options.maxFormattedBytes)
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lexer = XMLLexer(bytes: bytes)
            var out: [UInt8] = []
            out.reserveCapacity(min(limit, bytes.count + bytes.count / 2))
            var depth = 0
            var stopped: StructuredDiagnostic?

            func newline() {
                if !out.isEmpty { out.append(0x0A) }
                out.append(contentsOf: repeatElement(0x20, count: min(depth, StructuredFormatter.maxIndentLevels) * max(0, indent)))
            }
            func copy(_ range: Range<Int>) { out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[range])) }
            func trimmed(_ range: Range<Int>) -> Range<Int> {
                var lo = range.lowerBound, hi = range.upperBound
                while lo < hi, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[lo]) { lo += 1 }
                while hi > lo, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[hi - 1]) { hi -= 1 }
                return lo..<hi
            }
            func isEndTag(_ token: XMLToken?) -> Bool { if case .endTag = token?.kind { true } else { false } }

            while let token = lexer.next() {
                if out.count > limit {
                    stopped = StructuredDiagnostic(.warning, String(localized: "formatted text stopped at \(limit.formatted()) bytes", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."))
                    break
                }
                if token.unterminated, stopped == nil {
                    stopped = StructuredDiagnostic(.error, String(localized: "unterminated markup", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), at: StructuredLocation(line: token.line, column: token.column,
                                                                                                    byteOffset: Int64(token.range.lowerBound)))
                }
                switch token.kind {
                case .startTag(_, _, let selfClosing):
                    newline()
                    copy(token.range)
                    if selfClosing || token.unterminated { continue }
                    var ahead = lexer
                    let next = ahead.next()
                    if isEndTag(next), let next {
                        copy(next.range)
                        lexer = ahead
                        continue
                    }
                    if let next, next.kind == .text || next.kind == .cdata {
                        var further = ahead
                        let after = further.next()
                        if isEndTag(after), let after {
                            copy(next.kind == .text ? trimmed(next.range) : next.range)
                            copy(after.range)
                            lexer = further
                            continue
                        }
                    }
                    depth += 1
                case .endTag:
                    depth = max(0, depth - 1)
                    newline()
                    copy(token.range)
                case .text:
                    let range = trimmed(token.range)
                    guard !range.isEmpty else { continue }
                    newline()
                    copy(range)
                case .comment, .cdata, .processingInstruction, .declaration:
                    newline()
                    copy(token.range)
                }
            }
            if !out.isEmpty, out.last != 0x0A { out.append(0x0A) }
            let complete = stopped == nil
            return StructuredFormattedText(text: String(decoding: out, as: UTF8.self), isComplete: complete, stoppedAt: stopped,
                                           inputWasMinified: minified)
        }
    }

    // MARK: Property lists

    /// Any property list as XML plist text: an XML plist is re-indented (keeping its order); binary and OpenStep are
    /// read by PropertyListSerialization and written back out as XML.
    public static func propertyListXML(_ data: Data, indent: Int = 2, options: StructuredOptions = StructuredOptions()) -> StructuredFormattedText {
        let first = data.first { ![0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }
        if !data.starts(with: Array("bplist".utf8)), first == UInt8(ascii: "<") { return xml(data, indent: indent, options: options) }
        func failed(_ reason: String) -> StructuredFormattedText {
            StructuredFormattedText(text: "", isComplete: false, stoppedAt: StructuredDiagnostic(.error, reason), inputWasMinified: false)
        }
        guard Int64(data.count) <= options.maxInputBytes else { return failed(String(localized: "the property list is larger than the read limit", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
        if !data.starts(with: Array("bplist".utf8)), let depth = PlistReader.openStepDepth(data), depth > options.maxDepth {
            return failed(String(localized: "nesting deeper than \(options.maxDepth) levels is not read", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."))
        }
        do {
            let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            // Shared references are written out once per reference: refuse what would expand past the budgets (F39).
            guard PlistExpansion.fits(value, maxValues: PlistExpansion.maxValues(inputBytes: data.count),
                                      maxTextBytes: PlistExpansion.maxTextBytes(inputBytes: data.count)) else {
                return failed(PlistExpansion.tooLargeReason)
            }
            let xml = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            let text = String(decoding: xml, as: UTF8.self)
            if indent == 1 || indent == 0 { return StructuredFormattedText(text: text, isComplete: true, stoppedAt: nil, inputWasMinified: false) }
            // CF writes one tab per level; the house indent is spaces.
            let spaced = text.split(separator: "\n" as Character, omittingEmptySubsequences: false).map { (line: Substring) -> String in
                let tabs = line.prefix { $0 == "\t" }.count
                return String(repeating: " ", count: tabs * indent) + line.dropFirst(tabs)
            }.joined(separator: "\n")
            return StructuredFormattedText(text: spaced, isComplete: true, stoppedAt: nil, inputWasMinified: false)
        } catch {
            return failed(String(localized: "not a valid property list", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."))
        }
    }
}

/// How far a parsed property list expands when it is walked or written out (S-16, the class of F39). A binary property
/// list can point to one object from many places, and Core Foundation hands that one shared object back for every
/// reference, so anything that follows each reference does the work again: a few hundred bytes stand for 14^12
/// values, and a 20 KB file for hundreds of megabytes of XML (Core Foundation's XML writer refuses about 1,600 nested
/// collections, but not one string shared a million times). Walk or re-serialize a parsed property list only after
/// `fits` says it stays within the budgets. roadmap: S-16
public enum PlistExpansion {
    /// The values a walk may visit: the 500,000 floor `PlistValue` uses (VitrineBinary), raised to one value per byte
    /// of input. A property list that shares no container describes at most one value per byte (every value but the
    /// top is a reference of at least one byte), so no ordinary file is refused, however large.
    public static func maxValues(inputBytes: Int) -> Int { max(500_000, inputBytes) }

    /// The text its XML form may take, as `fits` estimates it: 64 MB, or eight times the input when that is more (the
    /// XML of an ordinary binary plist is a few times its size: base64 for data, tags around every value).
    public static func maxTextBytes(inputBytes: Int) -> Int {
        let (scaled, overflow) = inputBytes.multipliedReportingOverflow(by: 8)
        return overflow ? Int.max : max(64 << 20, scaled)
    }

    /// Why a property list was refused.
    public static var tooLargeReason: String {
        String(localized: "the property list is too large to show: its shared parts expand past what a preview can hold", bundle: .module,
               comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
    }

    /// The parsed value (what `PropertyListSerialization` returns) expands to at most `maxValues` values and about
    /// `maxTextBytes` of XML text. The walk uses an explicit stack and stops at the first budget it passes, so its own
    /// work is bounded by the budgets, never by the expansion. Text is estimated: the UTF-16 length of strings and
    /// keys, 4/3 of data (base64), and 16 bytes of tags per value.
    public static func fits(_ root: Any, maxValues: Int, maxTextBytes: Int = .max) -> Bool {
        var values = 0
        var text = 0
        var stack: [Any] = [root]
        func add(_ bytes: Int) -> Bool {
            let (sum, overflow) = text.addingReportingOverflow(bytes)
            text = overflow ? Int.max : sum
            return text <= maxTextBytes
        }
        while let value = stack.popLast() {
            values += 1
            guard values <= maxValues, add(16) else { return false }
            switch value {
            case let string as NSString:
                guard add(string.length) else { return false }
            case let data as NSData:
                guard add(data.length / 3 * 4 + 4) else { return false }
            case let array as NSArray:
                for element in array { stack.append(element) }
            case let dictionary as NSDictionary:
                for (key, element) in dictionary {
                    guard add((key as? NSString)?.length ?? 16) else { return false }
                    stack.append(element)
                }
            default:
                break
            }
        }
        return true
    }
}
