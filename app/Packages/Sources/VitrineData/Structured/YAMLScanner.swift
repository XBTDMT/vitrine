import Foundation

/// A position in YAML input. Line and column are 0-based here (as libyaml keeps them); the column counts characters.
struct YAMLMark: Equatable {
    var offset = 0
    var line = 0
    var column = 0
}

struct YAMLError: Error {
    var reason: String
    var mark: YAMLMark
    /// The input ended where more was needed (in a cut-short file this is truncation, not an error).
    var atEnd = false
}

enum YAMLScalarStyle: Equatable { case plain, singleQuoted, doubleQuoted, literal, folded }

enum YAMLTokenKind: Equatable {
    case streamStart, streamEnd
    case directive(name: String, value: String)
    case documentStart, documentEnd
    case blockSequenceStart, blockMappingStart, blockEnd
    case flowSequenceStart, flowSequenceEnd, flowMappingStart, flowMappingEnd
    case blockEntry, flowEntry, key, value
    case alias(String), anchor(String), tag(String)
    case scalar(String, YAMLScalarStyle)

    var label: String {
        switch self {
        case .streamStart: String(localized: "the start of the stream", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'.")
        case .streamEnd: String(localized: "the end of the stream", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'.")
        case .directive: String(localized: "a directive", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'. A YAML %directive.")
        case .documentStart: "'---'"
        case .documentEnd: "'...'"
        case .blockSequenceStart, .blockMappingStart: String(localized: "an indented block", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'.")
        case .blockEnd: String(localized: "the end of an indented block", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'.")
        case .flowSequenceStart: "'['"
        case .flowSequenceEnd: "']'"
        case .flowMappingStart: "'{'"
        case .flowMappingEnd: "'}'"
        case .blockEntry: "'-'"
        case .flowEntry: "','"
        case .key: "'?'"
        case .value: "':'"
        case .alias: String(localized: "an alias", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'. A YAML *alias.")
        case .anchor: String(localized: "an anchor", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'. A YAML &anchor.")
        case .tag: String(localized: "a tag", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'. A YAML !tag.")
        case .scalar: String(localized: "a scalar", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'. A YAML plain or quoted value.")
        }
    }
}

struct YAMLToken {
    var kind: YAMLTokenKind
    var start: YAMLMark
    var end: YAMLMark
}

/// The YAML tokenizer, after libyaml's scanner (which PyYAML ports): indentation becomes block-start/end tokens, and
/// a "simple key" (`key: value` with no `?`) is recognised after the fact by inserting a KEY token when its `:`
/// turns up. Entirely iterative: the indentation and flow levels are heap arrays.
///
/// Works on UTF-8 bytes; only ASCII is structural in YAML, so other characters pass through scalars untouched.
/// Columns count characters (continuation bytes do not advance them).
struct YAMLScanner {
    private let b: UnsafeBufferPointer<UInt8>
    private var pos = 0
    private var line = 0
    private var column = 0

    private var tokens: [YAMLToken] = []
    private var head = 0
    private var tokensTaken = 0
    private var done = false
    private var flowLevel = 0
    private var indent = -1
    private var indents: [Int] = []
    private var allowSimpleKey = true
    /// Possible simple keys, one per flow level at most, in increasing level order. A key at a deeper level was always
    /// saved after every key at a shallower one (closing a level removes its key), so offsets and token numbers rise
    /// along the array and staleness is monotonic: stale keys are always a prefix, and the earliest key is the first.
    /// That keeps every check O(1) amortized where a per-level scan is O(depth): 200,000 nested `[` would otherwise be
    /// quadratic.
    private var simpleKeys: [SimpleKey] = []
    private var simpleKeysHead = 0
    /// After a quoted scalar or a flow collection's end inside a flow collection, `:` is a value indicator even with no
    /// space after it, which is what lets JSON (`{"a":1}`) read as YAML.
    private var adjacentValueAllowedAt = -1
    private(set) var directives: [(name: String, value: String)] = []

    private struct SimpleKey {
        var level: Int
        var tokenNumber: Int
        var required: Bool
        var mark: YAMLMark
    }

    init(bytes: UnsafeBufferPointer<UInt8>) {
        b = bytes
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { pos = 3 }
        tokens.append(YAMLToken(kind: .streamStart, start: mark, end: mark))
    }

    var mark: YAMLMark { YAMLMark(offset: pos, line: line, column: column) }

    // MARK: Token queue

    mutating func peekToken() throws -> YAMLToken? {
        while try needMoreTokens() { try fetchMoreTokens() }
        return head < tokens.count ? tokens[head] : nil
    }

    mutating func nextToken() throws -> YAMLToken? {
        guard let token = try peekToken() else { return nil }
        head += 1
        tokensTaken += 1
        if head > 4096, head * 2 > tokens.count {
            tokens.removeFirst(head)
            head = 0
        }
        return token
    }

    private var queued: Int { tokens.count - head }

    private mutating func needMoreTokens() throws -> Bool {
        if done { return false }
        if queued == 0 { return true }
        try staleSimpleKeys()
        return nextPossibleSimpleKey() == tokensTaken
    }

    private func nextPossibleSimpleKey() -> Int? { simpleKeysHead < simpleKeys.count ? simpleKeys[simpleKeysHead].tokenNumber : nil }

    /// The possible simple key at the current flow level (always the last one, when there is one).
    private var currentSimpleKey: SimpleKey? {
        guard simpleKeys.count > simpleKeysHead, let last = simpleKeys.last, last.level == flowLevel else { return nil }
        return last
    }

    private mutating func append(_ kind: YAMLTokenKind, from start: YAMLMark) {
        tokens.append(YAMLToken(kind: kind, start: start, end: mark))
    }

    private mutating func insert(_ kind: YAMLTokenKind, at number: Int, mark: YAMLMark) {
        tokens.insert(YAMLToken(kind: kind, start: mark, end: mark), at: head + (number - tokensTaken))
    }

    // MARK: Characters

    @inline(__always) private func peek(_ k: Int = 0) -> UInt8 { pos + k < b.count ? b[pos + k] : 0 }
    private var atEnd: Bool { pos >= b.count }

    private mutating func forward(_ n: Int = 1) {
        for _ in 0..<n where pos < b.count {
            let c = b[pos]
            pos += 1
            if c == 0x0A { line += 1; column = 0 } else if c & 0xC0 != 0x80 { column += 1 }
        }
    }

    @inline(__always) private func isBreak(_ c: UInt8) -> Bool { c == 0x0A || c == 0x0D }
    @inline(__always) private func isBlank(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }
    @inline(__always) private func isBlankOrBreakOrEnd(_ c: UInt8) -> Bool { c == 0 || isBlank(c) || isBreak(c) }
    @inline(__always) private func isFlowIndicator(_ c: UInt8) -> Bool {
        c == UInt8(ascii: ",") || c == UInt8(ascii: "[") || c == UInt8(ascii: "]") || c == UInt8(ascii: "{") || c == UInt8(ascii: "}")
    }

    /// Consumes one line break; returns false when there is none here.
    @discardableResult
    private mutating func scanLineBreak() -> Bool {
        if peek() == 0x0D { forward(peek(1) == 0x0A ? 2 : 1); if b[pos - 1] == 0x0D { line += 1; column = 0 }; return true }
        if peek() == 0x0A { forward(); return true }
        return false
    }

    private func error(_ reason: String, at mark: YAMLMark? = nil) -> YAMLError {
        YAMLError(reason: reason, mark: mark ?? self.mark, atEnd: atEnd)
    }

    private func text(_ start: Int, _ end: Int) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: b[start..<end]), as: UTF8.self)
    }

    // MARK: Fetching

    private mutating func fetchMoreTokens() throws {
        try scanToNextToken()
        try staleSimpleKeys()
        unwindIndent(column)
        if atEnd { return try fetchStreamEnd() }
        let c = peek()
        if c == 0 { throw error(String(localized: "unexpected NUL character", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
        if column == 0, c == UInt8(ascii: "%") { return try fetchDirective() }
        if column == 0, checkMarker(UInt8(ascii: "-")) { return try fetchDocumentIndicator(.documentStart) }
        if column == 0, checkMarker(UInt8(ascii: ".")) { return try fetchDocumentIndicator(.documentEnd) }
        switch c {
        case UInt8(ascii: "["): return try fetchFlowCollectionStart(.flowSequenceStart)
        case UInt8(ascii: "{"): return try fetchFlowCollectionStart(.flowMappingStart)
        case UInt8(ascii: "]"): return try fetchFlowCollectionEnd(.flowSequenceEnd)
        case UInt8(ascii: "}"): return try fetchFlowCollectionEnd(.flowMappingEnd)
        case UInt8(ascii: ","): return try fetchFlowEntry()
        default: break
        }
        if c == UInt8(ascii: "-"), isBlankOrBreakOrEnd(peek(1)) { return try fetchBlockEntry() }
        if c == UInt8(ascii: "?"), flowLevel > 0 || isBlankOrBreakOrEnd(peek(1)) { return try fetchKey() }
        if c == UInt8(ascii: ":"), checkValue() { return try fetchValue() }
        switch c {
        case UInt8(ascii: "*"): return try fetchAnchor(alias: true)
        case UInt8(ascii: "&"): return try fetchAnchor(alias: false)
        case UInt8(ascii: "!"): return try fetchTag()
        case UInt8(ascii: "|") where flowLevel == 0: return try fetchBlockScalar(folded: false)
        case UInt8(ascii: ">") where flowLevel == 0: return try fetchBlockScalar(folded: true)
        case UInt8(ascii: "'"): return try fetchFlowScalar(double: false)
        case UInt8(ascii: "\""): return try fetchFlowScalar(double: true)
        default: break
        }
        if checkPlain() { return try fetchPlain() }
        if c == UInt8(ascii: "@") || c == UInt8(ascii: "`") {
            throw error(String(localized: "'\(String(Character(Unicode.Scalar(c))))' is reserved and cannot start a plain scalar", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."))
        }
        throw error(String(localized: "found a character that cannot start any token", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."))
    }

    private func checkMarker(_ c: UInt8) -> Bool {
        peek() == c && peek(1) == c && peek(2) == c && isBlankOrBreakOrEnd(peek(3))
    }

    private func checkValue() -> Bool {
        if isBlankOrBreakOrEnd(peek(1)) { return true }
        guard flowLevel > 0 else { return false }
        return isFlowIndicator(peek(1)) || pos == adjacentValueAllowedAt
    }

    private func checkPlain() -> Bool {
        let c = peek()
        let indicators = "-?:,[]{}#&*!|>'\"%@`".utf8
        if !indicators.contains(c) && !isBlankOrBreakOrEnd(c) { return true }
        let next = peek(1)
        if isBlankOrBreakOrEnd(next) { return false }
        if c == UInt8(ascii: "-") { return true }
        if c == UInt8(ascii: "?") || c == UInt8(ascii: ":") { return flowLevel == 0 || !isFlowIndicator(next) }
        return false
    }

    private mutating func scanToNextToken() throws {
        while true {
            while peek() == 0x20 { forward() }
            if peek() == 0x09 {
                // Tabs separate tokens but never indent: a tab in a block line's leading whitespace, before content,
                // is an error (on a blank or comment-only line it is harmless).
                var k = 0
                while isBlank(peek(k)) { k += 1 }
                let after = peek(k)
                if flowLevel == 0, lineIsBlankBefore(pos), !(after == 0 || isBreak(after) || after == UInt8(ascii: "#")) {
                    throw error(String(localized: "tab characters cannot be used for indentation", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."))
                }
                forward(k)
                continue
            }
            if peek() == UInt8(ascii: "#") { while !atEnd, !isBreak(peek()) { forward() } }
            if scanLineBreak() {
                if flowLevel == 0 { allowSimpleKey = true }
                continue
            }
            break
        }
    }

    private func lineIsBlankBefore(_ p: Int) -> Bool {
        var i = p - 1
        while i >= 0, b[i] != 0x0A, b[i] != 0x0D {
            if !isBlank(b[i]) { return false }
            i -= 1
        }
        return true
    }

    private mutating func staleSimpleKeys() throws {
        while simpleKeysHead < simpleKeys.count {
            let key = simpleKeys[simpleKeysHead]
            guard key.mark.line != line || pos - key.mark.offset > 1024 else { break }
            if key.required { throw error(String(localized: "could not find the ':' for this key", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), at: key.mark) }
            simpleKeysHead += 1
        }
        if simpleKeysHead == simpleKeys.count {
            simpleKeys.removeAll(keepingCapacity: true)
            simpleKeysHead = 0
        } else if simpleKeysHead > 1024, simpleKeysHead * 2 > simpleKeys.count {
            simpleKeys.removeFirst(simpleKeysHead)
            simpleKeysHead = 0
        }
    }

    private mutating func savePossibleSimpleKey() throws {
        let required = flowLevel == 0 && indent == column
        guard allowSimpleKey else { return }
        try removePossibleSimpleKey()
        simpleKeys.append(SimpleKey(level: flowLevel, tokenNumber: tokensTaken + queued, required: required, mark: mark))
    }

    private mutating func removePossibleSimpleKey() throws {
        guard let key = currentSimpleKey else { return }
        if key.required { throw error(String(localized: "could not find the ':' for this key", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), at: key.mark) }
        simpleKeys.removeLast()
    }

    private mutating func unwindIndent(_ column: Int) {
        guard flowLevel == 0 else { return }
        while indent > column {
            append(.blockEnd, from: mark)
            indent = indents.popLast() ?? -1
        }
    }

    private mutating func addIndent(_ column: Int) -> Bool {
        guard indent < column else { return false }
        indents.append(indent)
        indent = column
        return true
    }

    private mutating func fetchStreamEnd() throws {
        unwindIndent(-1)
        try removePossibleSimpleKey()
        allowSimpleKey = false
        simpleKeys.removeAll()
        simpleKeysHead = 0
        append(.streamEnd, from: mark)
        done = true
    }

    private mutating func fetchDirective() throws {
        unwindIndent(-1)
        try removePossibleSimpleKey()
        allowSimpleKey = false
        let start = mark
        forward()
        let nameStart = pos
        while !isBlankOrBreakOrEnd(peek()) { forward() }
        let name = text(nameStart, pos)
        while isBlank(peek()) { forward() }
        let valueStart = pos
        while !atEnd, !isBreak(peek()), peek() != UInt8(ascii: "#") { forward() }
        let value = text(valueStart, pos).trimmingCharacters(in: .whitespaces)
        directives.append((name, value))
        append(.directive(name: name, value: value), from: start)
    }

    private mutating func fetchDocumentIndicator(_ kind: YAMLTokenKind) throws {
        unwindIndent(-1)
        try removePossibleSimpleKey()
        allowSimpleKey = false
        let start = mark
        forward(3)
        append(kind, from: start)
    }

    private mutating func fetchFlowCollectionStart(_ kind: YAMLTokenKind) throws {
        try savePossibleSimpleKey()
        flowLevel += 1
        allowSimpleKey = true
        let start = mark
        forward()
        append(kind, from: start)
    }

    private mutating func fetchFlowCollectionEnd(_ kind: YAMLTokenKind) throws {
        try removePossibleSimpleKey()
        if flowLevel > 0 { flowLevel -= 1 }
        allowSimpleKey = false
        let start = mark
        forward()
        adjacentValueAllowedAt = pos
        append(kind, from: start)
    }

    private mutating func fetchFlowEntry() throws {
        allowSimpleKey = true
        try removePossibleSimpleKey()
        let start = mark
        forward()
        append(.flowEntry, from: start)
    }

    private mutating func fetchBlockEntry() throws {
        if flowLevel == 0 {
            guard allowSimpleKey else { throw error(String(localized: "a sequence entry is not allowed here", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
            if addIndent(column) { append(.blockSequenceStart, from: mark) }
        }
        allowSimpleKey = true
        try removePossibleSimpleKey()
        let start = mark
        forward()
        append(.blockEntry, from: start)
    }

    private mutating func fetchKey() throws {
        if flowLevel == 0 {
            guard allowSimpleKey else { throw error(String(localized: "a mapping key is not allowed here", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
            if addIndent(column) { append(.blockMappingStart, from: mark) }
        }
        allowSimpleKey = flowLevel == 0
        try removePossibleSimpleKey()
        let start = mark
        forward()
        append(.key, from: start)
    }

    private mutating func fetchValue() throws {
        if let key = currentSimpleKey {
            simpleKeys.removeLast()
            insert(.key, at: key.tokenNumber, mark: key.mark)
            if flowLevel == 0, addIndent(key.mark.column) {
                insert(.blockMappingStart, at: key.tokenNumber, mark: key.mark)
            }
            allowSimpleKey = false
        } else {
            if flowLevel == 0 {
                guard allowSimpleKey else { throw error(String(localized: "a mapping value is not allowed here", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
                if addIndent(column) { append(.blockMappingStart, from: mark) }
            }
            allowSimpleKey = flowLevel == 0
            try removePossibleSimpleKey()
        }
        let start = mark
        forward()
        append(.value, from: start)
    }

    private mutating func fetchAnchor(alias: Bool) throws {
        try savePossibleSimpleKey()
        allowSimpleKey = false
        let start = mark
        forward()
        let nameStart = pos
        while !isBlankOrBreakOrEnd(peek()), !isFlowIndicator(peek()) { forward() }
        guard pos > nameStart else { throw error(alias ? String(localized: "an alias needs a name after '*'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.") : String(localized: "an anchor needs a name after '&'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
        let name = text(nameStart, pos)
        append(alias ? .alias(name) : .anchor(name), from: start)
    }

    private mutating func fetchTag() throws {
        try savePossibleSimpleKey()
        allowSimpleKey = false
        let start = mark
        let tagStart = pos
        if peek(1) == UInt8(ascii: "<") {
            while !atEnd, peek() != UInt8(ascii: ">"), !isBreak(peek()) { forward() }
            guard peek() == UInt8(ascii: ">") else { throw error(String(localized: "a verbatim tag needs a closing '>'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
            forward()
        } else {
            while !isBlankOrBreakOrEnd(peek()), !(flowLevel > 0 && isFlowIndicator(peek())) { forward() }
        }
        append(.tag(text(tagStart, pos)), from: start)
    }

    private mutating func fetchBlockScalar(folded: Bool) throws {
        allowSimpleKey = true
        try removePossibleSimpleKey()
        let start = mark
        let value = try scanBlockScalar(folded: folded)
        append(.scalar(value, folded ? .folded : .literal), from: start)
    }

    private mutating func fetchFlowScalar(double: Bool) throws {
        try savePossibleSimpleKey()
        allowSimpleKey = false
        let start = mark
        let value = try scanFlowScalar(double: double)
        adjacentValueAllowedAt = pos
        append(.scalar(value, double ? .doubleQuoted : .singleQuoted), from: start)
    }

    private mutating func fetchPlain() throws {
        try savePossibleSimpleKey()
        allowSimpleKey = false
        let start = mark
        let value = try scanPlain()
        append(.scalar(value, .plain), from: start)
    }

    // MARK: Scalars

    private mutating func scanPlain() throws -> String {
        var out: [UInt8] = []
        var spaces: [UInt8] = []
        let minIndent = indent + 1
        while true {
            if peek() == UInt8(ascii: "#") { break }
            var length = 0
            while true {
                let c = peek(length)
                if isBlankOrBreakOrEnd(c) { break }
                if c == UInt8(ascii: ":") {
                    let next = peek(length + 1)
                    if isBlankOrBreakOrEnd(next) || (flowLevel > 0 && isFlowIndicator(next)) { break }
                }
                if flowLevel > 0, isFlowIndicator(c) { break }
                length += 1
            }
            if length == 0 { break }
            allowSimpleKey = false
            out += spaces
            out += b[pos..<(pos + length)]
            forward(length)
            guard let more = scanPlainSpaces() else { break }
            spaces = more
            if spaces.isEmpty || peek() == UInt8(ascii: "#") || (flowLevel == 0 && column < minIndent) { break }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The whitespace after a plain chunk, folded: one line break becomes a space, more become "\n"s. nil when a
    /// document marker ends the scalar.
    private mutating func scanPlainSpaces() -> [UInt8]? {
        let start = pos
        while isBlank(peek()) { forward() }
        let whitespace = Array(b[start..<pos])
        guard isBreak(peek()) else { return whitespace }
        scanLineBreak()
        allowSimpleKey = true
        if column == 0, checkMarker(UInt8(ascii: "-")) || checkMarker(UInt8(ascii: ".")) { return nil }
        var breaks = 0
        while peek() == 0x20 || peek() == 0x09 || isBreak(peek()) {
            if isBreak(peek()) {
                scanLineBreak()
                breaks += 1
                if column == 0, checkMarker(UInt8(ascii: "-")) || checkMarker(UInt8(ascii: ".")) { return nil }
            } else {
                forward()
            }
        }
        return breaks == 0 ? [0x20] : [UInt8](repeating: 0x0A, count: breaks)
    }

    private mutating func scanFlowScalar(double: Bool) throws -> String {
        let quote = peek()
        let open = mark
        forward()
        var out: [UInt8] = []
        while true {
            try scanFlowScalarNonSpaces(double: double, into: &out)
            if peek() == quote { break }
            try scanFlowScalarSpaces(into: &out, open: open)
        }
        forward()
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func scanFlowScalarNonSpaces(double: Bool, into out: inout [UInt8]) throws {
        while true {
            var length = 0
            while true {
                let c = peek(length)
                if c == 0 || isBlank(c) || isBreak(c) || c == UInt8(ascii: "'") || c == UInt8(ascii: "\"") || c == UInt8(ascii: "\\") { break }
                length += 1
            }
            if length > 0 { out += b[pos..<(pos + length)]; forward(length) }
            let c = peek()
            if !double, c == UInt8(ascii: "'"), peek(1) == UInt8(ascii: "'") {
                out.append(c); forward(2)
            } else if (double && c == UInt8(ascii: "'")) || (!double && (c == UInt8(ascii: "\"") || c == UInt8(ascii: "\\"))) {
                out.append(c); forward()
            } else if double, c == UInt8(ascii: "\\") {
                forward()
                let e = peek()
                let simple: [UInt8: UInt8] = [
                    UInt8(ascii: "0"): 0, UInt8(ascii: "a"): 7, UInt8(ascii: "b"): 8, UInt8(ascii: "t"): 9, 0x09: 9,
                    UInt8(ascii: "n"): 10, UInt8(ascii: "v"): 11, UInt8(ascii: "f"): 12, UInt8(ascii: "r"): 13,
                    UInt8(ascii: "e"): 27, 0x20: 0x20, UInt8(ascii: "\""): 0x22, UInt8(ascii: "/"): 0x2F,
                    UInt8(ascii: "\\"): 0x5C,
                ]
                if let byte = simple[e] {
                    out.append(byte); forward()
                } else if e == UInt8(ascii: "N") || e == UInt8(ascii: "_") || e == UInt8(ascii: "L") || e == UInt8(ascii: "P") {
                    let scalar: Unicode.Scalar = e == UInt8(ascii: "N") ? "\u{85}" : e == UInt8(ascii: "_") ? "\u{A0}"
                        : e == UInt8(ascii: "L") ? "\u{2028}" : "\u{2029}"
                    out += Array(String(scalar).utf8); forward()
                } else if e == UInt8(ascii: "x") || e == UInt8(ascii: "u") || e == UInt8(ascii: "U") {
                    let n = e == UInt8(ascii: "x") ? 2 : e == UInt8(ascii: "u") ? 4 : 8
                    forward()
                    var value: UInt32 = 0
                    for k in 0..<n {
                        guard let digit = hexValue(peek(k)) else { throw error(String(localized: "expected \(n) hex digits in an escape", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
                        value = value << 4 | digit
                    }
                    guard let scalar = Unicode.Scalar(value) else { throw error(String(localized: "the escape is not a valid character", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
                    out += Array(String(scalar).utf8)
                    forward(n)
                } else if isBreak(e) {
                    scanLineBreak()
                    try scanFlowScalarBreaks(into: &out)
                } else {
                    throw error(String(localized: "unknown escape '\\\(e < 0x80 && e > 0x20 ? String(Character(Unicode.Scalar(e))) : "?")'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."))
                }
            } else {
                return
            }
        }
    }

    private func hexValue(_ c: UInt8) -> UInt32? {
        switch c {
        case 48...57: UInt32(c - 48)
        case 65...70: UInt32(c - 55)
        case 97...102: UInt32(c - 87)
        default: nil
        }
    }

    private mutating func scanFlowScalarSpaces(into out: inout [UInt8], open: YAMLMark) throws {
        let start = pos
        while isBlank(peek()) { forward() }
        let whitespace = b[start..<pos]
        if atEnd { throw YAMLError(reason: String(localized: "unterminated quoted scalar", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), mark: open, atEnd: true) }
        // `peek()` reads a real NUL like the end of input; YAML forbids it, and the loop above would not advance past it.
        if peek() == 0 { throw error(String(localized: "unexpected NUL character", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
        if isBreak(peek()) {
            scanLineBreak()
            let before = out.count
            try scanFlowScalarBreaks(into: &out)
            if out.count == before { out.append(0x20) }
        } else {
            out += whitespace
        }
    }

    private mutating func scanFlowScalarBreaks(into out: inout [UInt8]) throws {
        while true {
            if column == 0, checkMarker(UInt8(ascii: "-")) || checkMarker(UInt8(ascii: ".")) {
                throw error(String(localized: "a document marker inside a quoted scalar", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."))
            }
            while isBlank(peek()) { forward() }
            if isBreak(peek()) { scanLineBreak(); out.append(0x0A) } else { return }
        }
    }

    private mutating func scanBlockScalar(folded: Bool) throws -> String {
        forward()
        var chomping: Bool?   // true keep (+), false strip (-), nil clip
        var increment: Int?
        for _ in 0..<2 {
            let c = peek()
            if c == UInt8(ascii: "+") || c == UInt8(ascii: "-") {
                guard chomping == nil else { break }
                chomping = c == UInt8(ascii: "+"); forward()
            } else if c >= UInt8(ascii: "1"), c <= UInt8(ascii: "9") {
                guard increment == nil else { break }
                increment = Int(c - 48); forward()
            } else if c == UInt8(ascii: "0") {
                throw error(String(localized: "a block scalar's indentation indicator must be 1 to 9", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."))
            }
        }
        while isBlank(peek()) { forward() }
        if peek() == UInt8(ascii: "#") { while !atEnd, !isBreak(peek()) { forward() } }
        guard isBreak(peek()) || atEnd else { throw error(String(localized: "expected a comment or a line break after the block scalar indicator", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
        scanLineBreak()

        let minIndent = max(1, indent + 1)
        var blockIndent: Int
        var breaks = 0
        if let increment {
            blockIndent = minIndent + increment - 1
            breaks = scanBlockScalarBreaks(blockIndent)
        } else {
            var maxIndent = 0
            while peek() == 0x20 || isBreak(peek()) {
                if peek() == 0x20 { forward(); maxIndent = max(maxIndent, column) } else { scanLineBreak(); breaks += 1 }
            }
            blockIndent = max(minIndent, maxIndent)
        }
        var out: [UInt8] = []
        var lineBreak = false
        while column == blockIndent, !atEnd {
            out += [UInt8](repeating: 0x0A, count: breaks)
            let leadingNonSpace = !isBlank(peek())
            let start = pos
            while !atEnd, !isBreak(peek()) { forward() }
            out += b[start..<pos]
            lineBreak = scanLineBreak()
            breaks = scanBlockScalarBreaks(blockIndent)
            guard column == blockIndent, !atEnd else { break }
            if folded, lineBreak, leadingNonSpace, !isBlank(peek()) {
                if breaks == 0 { out.append(0x20) }
            } else if lineBreak {
                out.append(0x0A)
            }
        }
        if chomping != false, lineBreak { out.append(0x0A) }
        if chomping == true { out += [UInt8](repeating: 0x0A, count: breaks) }
        return String(decoding: out, as: UTF8.self)
    }

    private mutating func scanBlockScalarBreaks(_ blockIndent: Int) -> Int {
        var breaks = 0
        while column < blockIndent, peek() == 0x20 { forward() }
        while isBreak(peek()) {
            scanLineBreak()
            breaks += 1
            while column < blockIndent, peek() == 0x20 { forward() }
        }
        return breaks
    }
}
