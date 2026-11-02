import Foundation

/// TOML 1.0 into the tree. TOML cannot stream: `[a.b]` may reopen a table defined above it and `[[a]]` appends to an
/// array declared earlier, so the parse builds an intermediate model first. That model is a flat arena of structs
/// addressed by index (not a graph of objects), so freeing even a hostile, deeply nested one never recurses; values
/// are parsed with an explicit stack for the same reason. The arena is then walked, iteratively, into the builder.
enum TOMLReader {
    static func read(_ data: Data, options: StructuredOptions, truncated: Bool) -> ReaderOutput {
        var input = data
        // A cut-short file ends mid-line; drop the partial line so the cut does not read as a syntax error.
        if truncated, let lastNewline = input.lastIndex(of: 0x0A) { input = input.prefix(upTo: lastNewline + 1) }
        return input.withUnsafeBytes { raw in
            var parser = TOMLParser(bytes: raw.bindMemory(to: UInt8.self), options: options)
            var output = ReaderOutput(builder: StructuredTreeBuilder(options: options, pathStyle: .jsonPath), dialect: .toml)
            do {
                try parser.parseDocument()
            } catch let error as TOMLParser.Failure {
                if error.atEnd && truncated { output.endedEarly = true } else {
                    output.fail(StructuredDiagnostic(.error, error.reason, at: parser.location(error.position)), cap: options.maxDiagnostics)
                }
            } catch {}
            parser.emit(into: &output.builder)
            return output
        }
    }
}

struct TOMLParser {
    struct Failure: Error {
        var reason: String
        var position: Int
        var atEnd = false
    }

    private enum Kind { case table, array, scalar }
    private enum Origin { case root, header, implicit, dotted, inline, staticArray, tableArray, value }

    private struct Node {
        var kind: Kind
        var origin: Origin
        var keys: [String] = []
        var lookup: [String: Int] = [:]
        var items: [Int] = []
        var scalarKind: StructuredNodeKind = .null
        var text = ""
        var truncated = false
        var span: StructuredSpan
    }

    private let b: UnsafeBufferPointer<UInt8>
    private let maxPreviewBytes: Int
    private let maxKeyBytes: Int
    private var pos = 0
    private var line = 1
    private var lineStart = 0
    private var arena: [Node] = []

    init(bytes: UnsafeBufferPointer<UInt8>, options: StructuredOptions) {
        b = bytes
        maxPreviewBytes = max(1, options.maxPreviewBytes)
        maxKeyBytes = max(1, options.maxKeyBytes)
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { pos = 3; lineStart = 3 }
        arena.append(Node(kind: .table, origin: .root, span: StructuredSpan(byteOffset: 0, byteLength: Int64(b.count), line: 1, column: 1)))
    }

    // MARK: Document

    mutating func parseDocument() throws {
        var current = 0
        while true {
            skipBlanks()
            guard pos < b.count else { return }
            let c = b[pos]
            if c == UInt8(ascii: "#") { try comment() }
            else if c == 0x0A || c == 0x0D { try newline(); continue }
            else if c == UInt8(ascii: "[") { current = try header() }
            else {
                let start = pos
                let keys = try key()
                skipBlanks()
                guard peek() == UInt8(ascii: "=") else {
                    throw Failure(reason: pos >= b.count ? String(localized: "expected '=' after the key", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")
                                         : String(localized: "expected '=' after the key, found \(describe(peek()))", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."),
                                  position: pos, atEnd: pos >= b.count)
                }
                pos += 1
                skipBlanks()
                let value = try parseValue()
                try insert(keys, value, into: current, at: start)
            }
            skipBlanks()
            if peek() == UInt8(ascii: "#") { try comment() }
            guard pos >= b.count || b[pos] == 0x0A || b[pos] == 0x0D else {
                throw Failure(reason: String(localized: "expected a new line after the value, found \(describe(b[pos]))", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos)
            }
        }
    }

    private mutating func header() throws -> Int {
        let start = pos
        let span = spanAt(start)
        pos += 1
        let isArray = peek() == UInt8(ascii: "[")
        if isArray { pos += 1 }
        skipBlanks()
        let keys = try key()
        skipBlanks()
        guard peek() == UInt8(ascii: "]") else { throw Failure(reason: String(localized: "expected ']' to close the table header", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos, atEnd: pos >= b.count) }
        pos += 1
        if isArray {
            guard peek() == UInt8(ascii: "]") else { throw Failure(reason: String(localized: "expected ']]' to close the array-of-tables header", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
            pos += 1
        }
        let dotted = keys.joined(separator: ".")
        var table = 0
        for part in keys.dropLast() {
            if let child = arena[table].lookup[part] {
                switch arena[child].origin {
                case .inline: throw Failure(reason: String(localized: "'\(part)' is an inline table and cannot be extended", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
                case .tableArray: table = arena[child].items.last ?? child
                case .staticArray, .value: throw Failure(reason: String(localized: "'\(part)' is already a value, not a table", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
                default: table = child
                }
            } else {
                table = add(Node(kind: .table, origin: .implicit, span: span), key: part, to: table)
            }
        }
        let last = keys[keys.count - 1]
        if isArray {
            let array: Int
            if let existing = arena[table].lookup[last] {
                guard arena[existing].origin == .tableArray else {
                    throw Failure(reason: String(localized: "'\(dotted)' is already defined and is not an array of tables", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
                }
                array = existing
            } else {
                array = add(Node(kind: .array, origin: .tableArray, span: span), key: last, to: table)
            }
            let element = arena.count
            arena.append(Node(kind: .table, origin: .header, span: span))
            arena[array].items.append(element)
            return element
        }
        if let existing = arena[table].lookup[last] {
            switch arena[existing].origin {
            case .implicit:
                arena[existing].origin = .header
                arena[existing].span = span
                return existing
            case .header: throw Failure(reason: String(localized: "table [\(dotted)] is defined more than once", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
            case .dotted: throw Failure(reason: String(localized: "table [\(dotted)] was already defined with dotted keys", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
            case .inline: throw Failure(reason: String(localized: "'\(dotted)' is an inline table and cannot be redefined", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
            default: throw Failure(reason: String(localized: "'\(dotted)' is already defined as a value", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
            }
        }
        return add(Node(kind: .table, origin: .header, span: span), key: last, to: table)
    }

    private mutating func add(_ node: Node, key: String, to table: Int) -> Int {
        let index = arena.count
        arena.append(node)
        arena[table].keys.append(key)
        arena[table].lookup[key] = index
        return index
    }

    private mutating func insert(_ keys: [String], _ value: Int, into current: Int, at start: Int) throws {
        var table = current
        for part in keys.dropLast() {
            if let child = arena[table].lookup[part] {
                switch arena[child].origin {
                case .dotted, .implicit: table = child
                case .inline: throw Failure(reason: String(localized: "'\(part)' is an inline table and cannot be extended", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
                case .header: throw Failure(reason: String(localized: "'\(part)' is a table defined by a header; dotted keys cannot add to it here", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
                default: throw Failure(reason: String(localized: "'\(part)' is already a value, not a table", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
                }
            } else {
                table = add(Node(kind: .table, origin: .dotted, span: spanAt(start)), key: part, to: table)
            }
        }
        let last = keys[keys.count - 1]
        guard arena[table].lookup[last] == nil else {
            throw Failure(reason: String(localized: "duplicate key '\(keys.joined(separator: "."))'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: start)
        }
        arena[table].keys.append(last)
        arena[table].lookup[last] = value
    }

    // MARK: Keys

    private mutating func key() throws -> [String] {
        var parts: [String] = []
        while true {
            skipBlanks()
            guard pos < b.count else { throw Failure(reason: String(localized: "expected a key", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos, atEnd: true) }
            let c = b[pos]
            if c == UInt8(ascii: "\"") {
                if peek(1) == c, peek(2) == c { throw Failure(reason: String(localized: "a key cannot be a multi-line string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
                parts.append(try basicString(limit: maxKeyBytes).0)
            } else if c == UInt8(ascii: "'") {
                if peek(1) == c, peek(2) == c { throw Failure(reason: String(localized: "a key cannot be a multi-line string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
                parts.append(try literalString(limit: maxKeyBytes).0)
            } else {
                let start = pos
                while pos < b.count, isBareKey(b[pos]) { pos += 1 }
                guard pos > start else { throw Failure(reason: String(localized: "expected a key, found \(describe(c))", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
                parts.append(text(start, pos, limit: maxKeyBytes).0)
            }
            skipBlanks()
            guard peek() == UInt8(ascii: ".") else { return parts }
            pos += 1
        }
    }

    private func isBareKey(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 45
    }

    // MARK: Values

    private struct Frame {
        var node: Int
        var isArray: Bool
        var needsValue = true
        var pendingKey: [String] = []
        var keyStart = 0
        var afterComma = false
    }

    /// One value, arrays and inline tables included, without recursion.
    private mutating func parseValue() throws -> Int {
        var stack: [Frame] = []
        while true {
            if let top = stack.last {
                if top.isArray {
                    try skipArrayTrivia()
                    guard pos < b.count else { throw Failure(reason: String(localized: "unterminated array", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos, atEnd: true) }
                    if top.needsValue {
                        if b[pos] == UInt8(ascii: "]") {
                            pos += 1
                            let done = stack.removeLast()
                            if let result = try deliver(finish(done), &stack) { return result }
                            continue
                        }
                    } else {
                        if b[pos] == UInt8(ascii: ",") { pos += 1; stack[stack.count - 1].needsValue = true; continue }
                        if b[pos] == UInt8(ascii: "]") {
                            pos += 1
                            let done = stack.removeLast()
                            if let result = try deliver(finish(done), &stack) { return result }
                            continue
                        }
                        throw Failure(reason: String(localized: "expected ',' or ']' in the array, found \(describe(b[pos]))", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos)
                    }
                } else {
                    skipBlanks()
                    guard pos < b.count else { throw Failure(reason: String(localized: "unterminated inline table", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos, atEnd: true) }
                    let c = b[pos]
                    if c == 0x0A || c == 0x0D { throw Failure(reason: String(localized: "an inline table must be on one line", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
                    if top.needsValue {
                        if c == UInt8(ascii: "}") {
                            if top.afterComma { throw Failure(reason: String(localized: "a trailing comma is not allowed in an inline table", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
                            pos += 1
                            let done = stack.removeLast()
                            if let result = try deliver(finish(done), &stack) { return result }
                            continue
                        }
                        let keyStart = pos
                        let keys = try key()
                        skipBlanks()
                        guard peek() == UInt8(ascii: "=") else { throw Failure(reason: String(localized: "expected '=' after the key", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos, atEnd: pos >= b.count) }
                        pos += 1
                        skipBlanks()
                        stack[stack.count - 1].pendingKey = keys
                        stack[stack.count - 1].keyStart = keyStart
                    } else {
                        if c == UInt8(ascii: ",") {
                            pos += 1
                            stack[stack.count - 1].needsValue = true
                            stack[stack.count - 1].afterComma = true
                            continue
                        }
                        if c == UInt8(ascii: "}") {
                            pos += 1
                            let done = stack.removeLast()
                            if let result = try deliver(finish(done), &stack) { return result }
                            continue
                        }
                        throw Failure(reason: String(localized: "expected ',' or '}' in the inline table, found \(describe(c))", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos)
                    }
                }
            }
            // A value starts here.
            guard pos < b.count else { throw Failure(reason: String(localized: "expected a value", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos, atEnd: true) }
            let c = b[pos]
            if c == UInt8(ascii: "[") || c == UInt8(ascii: "{") {
                let isArray = c == UInt8(ascii: "[")
                let node = arena.count
                arena.append(Node(kind: isArray ? .array : .table, origin: isArray ? .staticArray : .dotted, span: spanAt(pos)))
                pos += 1
                stack.append(Frame(node: node, isArray: isArray))
                continue
            }
            let scalar = try scalarValue()
            if let result = try deliver(scalar, &stack) { return result }
        }
    }

    private mutating func finish(_ frame: Frame) -> Int {
        if let offset = arena[frame.node].span.byteOffset { arena[frame.node].span.byteLength = Int64(pos) - offset }
        if !frame.isArray { arena[frame.node].origin = .inline }
        return frame.node
    }

    /// Hands a finished value to the container it belongs to; returns it when it is the whole value.
    private mutating func deliver(_ node: Int, _ stack: inout [Frame]) throws -> Int? {
        guard let top = stack.indices.last else { return node }
        if stack[top].isArray {
            arena[stack[top].node].items.append(node)
        } else {
            try insert(stack[top].pendingKey, node, into: stack[top].node, at: stack[top].keyStart)
            stack[top].afterComma = false
        }
        stack[top].needsValue = false
        return nil
    }

    private mutating func scalarValue() throws -> Int {
        let start = pos
        var span = spanAt(start)
        let c = b[pos]
        var kind: StructuredNodeKind
        var text: String
        var cut = false
        if c == UInt8(ascii: "\"") {
            kind = .string
            (text, cut) = peek(1) == c && peek(2) == c ? try multilineBasic() : try basicString(limit: maxPreviewBytes)
        } else if c == UInt8(ascii: "'") {
            kind = .string
            (text, cut) = peek(1) == c && peek(2) == c ? try multilineLiteral() : try literalString(limit: maxPreviewBytes)
        } else {
            var end = pos
            while end < b.count, isValueChar(b[end]) { end += 1 }
            // A date and a time may be separated by one space: "1979-05-27 07:32:00Z".
            if end - pos == 10, end + 1 < b.count, b[end] == 0x20, b[end + 1] >= 48, b[end + 1] <= 57,
               TOMLValues.isDate(Array(b[pos..<end])) {
                end += 1
                while end < b.count, isValueChar(b[end]) { end += 1 }
            }
            guard end > pos else { throw Failure(reason: String(localized: "expected a value, found \(describe(c))", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
            let token = Array(b[pos..<end])
            guard let classified = TOMLValues.classify(token) else {
                throw Failure(reason: String(localized: "invalid value '\(self.text(pos, end, limit: 40).0)'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos)
            }
            if case .failure(let reason) = classified { throw Failure(reason: reason, position: pos) }
            guard case .kind(let k) = classified else { throw Failure(reason: String(localized: "invalid value", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
            kind = k
            (text, cut) = self.text(pos, end, limit: maxPreviewBytes)
            pos = end
        }
        span.byteLength = Int64(pos - start)
        var node = Node(kind: .scalar, origin: .value, span: span)
        node.scalarKind = kind
        node.text = text
        node.truncated = cut
        arena.append(node)
        return arena.count - 1
    }

    private func isValueChar(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 43 || c == 45 || c == 46 || c == 58
    }

    // MARK: Strings

    private mutating func basicString(limit: Int) throws -> (String, Bool) {
        let open = pos
        pos += 1
        var out: [UInt8] = []
        var cut = false
        while true {
            guard pos < b.count else { throw Failure(reason: String(localized: "unterminated string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: open, atEnd: true) }
            let c = b[pos]
            if c == UInt8(ascii: "\"") { pos += 1; break }
            if c == 0x0A || c == 0x0D { throw Failure(reason: String(localized: "a single-line string cannot contain a line break", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
            if c == UInt8(ascii: "\\") { try escape(into: &out, limit: limit, cut: &cut); continue }
            try checkControl(c)
            append(c, &out, limit, &cut)
            pos += 1
        }
        return finishText(&out, cut)
    }

    private mutating func multilineBasic() throws -> (String, Bool) {
        let open = pos
        pos += 3
        if peek() == 0x0A { pos += 1; line += 1; lineStart = pos } else if peek() == 0x0D, peek(1) == 0x0A { pos += 2; line += 1; lineStart = pos }
        var out: [UInt8] = []
        var cut = false
        while true {
            guard pos < b.count else { throw Failure(reason: String(localized: "unterminated multi-line string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: open, atEnd: true) }
            let c = b[pos]
            if c == UInt8(ascii: "\""), peek(1) == c, peek(2) == c {
                var quotes = 3
                while peek(quotes) == c, quotes < 5 { quotes += 1 }
                for _ in 0..<(quotes - 3) { append(c, &out, maxPreviewBytes, &cut) }
                pos += quotes
                break
            }
            if c == UInt8(ascii: "\\") {
                // A line-ending backslash trims the break and the whitespace after it.
                var k = pos + 1
                while k < b.count, b[k] == 0x20 || b[k] == 0x09 { k += 1 }
                if k < b.count, b[k] == 0x0A || b[k] == 0x0D {
                    pos = k
                    while pos < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[pos]) {
                        if b[pos] == 0x0A { line += 1; lineStart = pos + 1 }
                        pos += 1
                    }
                    continue
                }
                try escape(into: &out, limit: maxPreviewBytes, cut: &cut)
                continue
            }
            if c == 0x0A { line += 1; lineStart = pos + 1 }
            else if c == 0x0D {
                guard peek(1) == 0x0A else { throw Failure(reason: String(localized: "a carriage return must be followed by a line feed", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
            } else { try checkControl(c) }
            append(c, &out, maxPreviewBytes, &cut)
            pos += 1
        }
        return finishText(&out, cut)
    }

    private mutating func literalString(limit: Int) throws -> (String, Bool) {
        let open = pos
        pos += 1
        let start = pos
        while true {
            guard pos < b.count else { throw Failure(reason: String(localized: "unterminated string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: open, atEnd: true) }
            let c = b[pos]
            if c == UInt8(ascii: "'") { break }
            if c == 0x0A || c == 0x0D { throw Failure(reason: String(localized: "a single-line string cannot contain a line break", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
            try checkControl(c)
            pos += 1
        }
        let result = text(start, pos, limit: limit)
        pos += 1
        return result
    }

    private mutating func multilineLiteral() throws -> (String, Bool) {
        let open = pos
        pos += 3
        if peek() == 0x0A { pos += 1; line += 1; lineStart = pos } else if peek() == 0x0D, peek(1) == 0x0A { pos += 2; line += 1; lineStart = pos }
        let start = pos
        while true {
            guard pos < b.count else { throw Failure(reason: String(localized: "unterminated multi-line string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: open, atEnd: true) }
            let c = b[pos]
            if c == UInt8(ascii: "'"), peek(1) == c, peek(2) == c {
                var quotes = 3
                while peek(quotes) == c, quotes < 5 { quotes += 1 }
                let result = text(start, pos + quotes - 3, limit: maxPreviewBytes)
                pos += quotes
                return result
            }
            if c == 0x0A { line += 1; lineStart = pos + 1 }
            else if c == 0x0D {
                guard peek(1) == 0x0A else { throw Failure(reason: String(localized: "a carriage return must be followed by a line feed", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
            } else { try checkControl(c) }
            pos += 1
        }
    }

    private mutating func escape(into out: inout [UInt8], limit: Int, cut: inout Bool) throws {
        let at = pos
        pos += 1
        guard pos < b.count else { throw Failure(reason: String(localized: "unterminated string", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: at, atEnd: true) }
        let e = b[pos]
        pos += 1
        let simple: UInt8?
        switch e {
        case UInt8(ascii: "b"): simple = 8
        case UInt8(ascii: "t"): simple = 9
        case UInt8(ascii: "n"): simple = 10
        case UInt8(ascii: "f"): simple = 12
        case UInt8(ascii: "r"): simple = 13
        case UInt8(ascii: "\""): simple = 0x22
        case UInt8(ascii: "\\"): simple = 0x5C
        case UInt8(ascii: "u"), UInt8(ascii: "U"):
            let n = e == UInt8(ascii: "u") ? 4 : 8
            guard pos + n <= b.count else { throw Failure(reason: String(localized: "expected \(n) hex digits in an escape", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: at, atEnd: true) }
            var value: UInt32 = 0
            for k in 0..<n {
                let h = b[pos + k]
                let d: UInt8
                switch h {
                case 48...57: d = h - 48
                case 65...70: d = h - 55
                case 97...102: d = h - 87
                default: throw Failure(reason: String(localized: "expected \(n) hex digits in an escape", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos + k)
                }
                value = value << 4 | UInt32(d)
            }
            pos += n
            guard let scalar = Unicode.Scalar(value) else { throw Failure(reason: String(localized: "the escape is not a valid Unicode scalar", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: at) }
            for byte in String(scalar).utf8 { append(byte, &out, limit, &cut) }
            return
        default:
            throw Failure(reason: String(localized: "invalid escape '\\\(describeRaw(e))'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: at)
        }
        if let simple { append(simple, &out, limit, &cut) }
    }

    private func checkControl(_ c: UInt8) throws {
        if (c < 0x20 && c != 0x09) || c == 0x7F {
            throw Failure(reason: String(localized: "control character U+\(String(format: "%04X", c)) must be escaped", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos)
        }
    }

    private func append(_ c: UInt8, _ out: inout [UInt8], _ limit: Int, _ cut: inout Bool) {
        if out.count < limit { out.append(c) } else { cut = true }
    }

    private func finishText(_ out: inout [UInt8], _ cut: Bool) -> (String, Bool) {
        if cut { trimIncompleteUTF8(&out) }
        return (String(decoding: out, as: UTF8.self), cut)
    }

    // MARK: Trivia

    private func peek(_ k: Int = 0) -> UInt8 { pos + k < b.count ? b[pos + k] : 0 }

    private mutating func skipBlanks() { while pos < b.count, b[pos] == 0x20 || b[pos] == 0x09 { pos += 1 } }

    private mutating func comment() throws {
        pos += 1
        while pos < b.count, b[pos] != 0x0A {
            let c = b[pos]
            if c == 0x0D, peek(1) == 0x0A { break }
            if (c < 0x20 && c != 0x09) || c == 0x7F { throw Failure(reason: String(localized: "control character in a comment", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
            pos += 1
        }
    }

    private mutating func newline() throws {
        if b[pos] == 0x0D {
            guard peek(1) == 0x0A else { throw Failure(reason: String(localized: "a carriage return must be followed by a line feed", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."), position: pos) }
            pos += 1
        }
        pos += 1
        line += 1
        lineStart = pos
    }

    private mutating func skipArrayTrivia() throws {
        while pos < b.count {
            let c = b[pos]
            if c == 0x20 || c == 0x09 { pos += 1 }
            else if c == 0x0A || c == 0x0D { try newline() }
            else if c == UInt8(ascii: "#") { try comment() }
            else { return }
        }
    }

    // MARK: Positions

    private func spanAt(_ start: Int) -> StructuredSpan {
        StructuredSpan(byteOffset: Int64(start), byteLength: nil, line: line, column: start - lineStart + 1)
    }

    func location(_ position: Int) -> StructuredLocation {
        let from = min(lineStart, position), to = min(position, b.count)
        var column = 1
        if to > from { for i in from..<to where b[i] & 0xC0 != 0x80 { column += 1 } }
        return StructuredLocation(line: line, column: column, byteOffset: Int64(position))
    }

    private func text(_ start: Int, _ end: Int, limit: Int) -> (String, Bool) {
        var stop = min(end, start + limit)
        let cut = end - start > limit
        if cut { while stop > start, b[stop] & 0xC0 == 0x80 { stop -= 1 } }
        return (String(decoding: UnsafeBufferPointer(rebasing: b[start..<stop]), as: UTF8.self), cut)
    }

    private func describe(_ c: UInt8) -> String {
        if c == 0 && pos >= b.count { return String(localized: "the end of the file", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'.") }
        if c == 0x0A || c == 0x0D { return String(localized: "a line break", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'.") }
        let hex = String(format: "%02X", c)
        return c >= 0x21 && c < 0x7F ? "'\(Character(Unicode.Scalar(c)))'" : String(localized: "byte 0x\(hex)", bundle: .module, comment: "Names what the parser found, filling the gap in a syntax message such as 'expected a value, found …'. A byte in hexadecimal.")
    }

    private func describeRaw(_ c: UInt8) -> String {
        c >= 0x21 && c < 0x7F ? String(Character(Unicode.Scalar(c))) : String(format: "x%02X", c)
    }

    // MARK: Emitting

    /// Walks the arena into the builder in document order, iteratively.
    func emit(into builder: inout StructuredTreeBuilder) {
        var stack: [(node: Int, next: Int)] = []
        func start(_ index: Int, name: String?, builder: inout StructuredTreeBuilder, stack: inout [(node: Int, next: Int)]) {
            let node = arena[index]
            switch node.kind {
            case .table, .array:
                builder.open(node.kind == .table ? .object : .array, name: name, span: node.span)
                stack.append((index, 0))
            case .scalar:
                builder.leaf(node.scalarKind, name: name, preview: node.text, truncated: node.truncated, span: node.span)
            }
        }
        start(0, name: nil, builder: &builder, stack: &stack)
        while let top = stack.last {
            let node = arena[top.node]
            let count = node.kind == .table ? node.keys.count : node.items.count
            if top.next >= count {
                stack.removeLast()
                let end = node.span.byteOffset.flatMap { offset in node.span.byteLength.map { offset + $0 } }
                builder.close(endOffset: end)
                continue
            }
            stack[stack.count - 1].next += 1
            if node.kind == .table {
                let key = node.keys[top.next]
                if let child = node.lookup[key] { start(child, name: key, builder: &builder, stack: &stack) }
            } else {
                start(node.items[top.next], name: nil, builder: &builder, stack: &stack)
            }
        }
    }
}

/// TOML's scalar grammar, checked byte by byte (no regular expressions to build or share across threads).
enum TOMLValues {
    enum Classified { case kind(StructuredNodeKind), failure(String) }

    static func classify(_ s: [UInt8]) -> Classified? {
        switch String(decoding: s, as: UTF8.self) {
        case "true", "false": return .kind(.bool)
        case "inf", "+inf", "-inf", "nan", "+nan", "-nan": return .kind(.number)
        default: break
        }
        if isDateTime(s) { return .kind(.date) }
        if s.contains(UInt8(ascii: ":")) || (s.count >= 10 && s[4] == UInt8(ascii: "-") && s.prefix(4).allSatisfy(isDigit)) {
            return .failure(String(localized: "invalid date or time '\(String(decoding: s.prefix(40), as: UTF8.self))'", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are."))
        }
        if let integer = integer(s) { return integer }
        if isFloat(s) { return .kind(.number) }
        return nil
    }

    static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

    /// `d(_?d)*` over `digit`.
    private static func digitsWithUnderscores(_ s: ArraySlice<UInt8>, _ digit: (UInt8) -> Bool) -> Bool {
        guard let first = s.first, let last = s.last, digit(first), digit(last) else { return false }
        var previousUnderscore = false
        for c in s {
            if c == 95 { if previousUnderscore { return false }; previousUnderscore = true }
            else if digit(c) { previousUnderscore = false } else { return false }
        }
        return true
    }

    private static func integer(_ s: [UInt8]) -> Classified? {
        guard !s.isEmpty else { return nil }
        if s.count > 2, s[0] == 48, [UInt8(ascii: "x"), UInt8(ascii: "o"), UInt8(ascii: "b")].contains(s[1]) {
            let radix: Int
            let digit: (UInt8) -> Bool
            switch s[1] {
            case UInt8(ascii: "x"): radix = 16; digit = { isDigit($0) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }
            case UInt8(ascii: "o"): radix = 8; digit = { $0 >= 48 && $0 <= 55 }
            default: radix = 2; digit = { $0 == 48 || $0 == 49 }
            }
            guard digitsWithUnderscores(s[2...], digit) else { return nil }
            let text = String(decoding: s[2...].filter { $0 != 95 }, as: UTF8.self)
            guard UInt64(text, radix: radix).map({ $0 <= UInt64(Int64.max) }) == true else { return .failure(String(localized: "integer out of range", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
            return .kind(.number)
        }
        var body = s[...]
        if body.first == 43 || body.first == 45 { body = body.dropFirst() }
        guard digitsWithUnderscores(body, isDigit) else { return nil }
        if body.count > 1, body.first == 48 { return .failure(String(localized: "leading zeros are not allowed in an integer", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
        let text = String(decoding: s.filter { $0 != 95 }, as: UTF8.self)
        guard Int64(text) != nil else { return .failure(String(localized: "integer out of range", bundle: .module, comment: "A syntax or reading problem in a structured file (JSON, YAML, TOML, XML, property list), shown in the preview; lower-case, no final period. Quoted characters, tokens and code stay as they are.")) }
        return .kind(.number)
    }

    private static func isFloat(_ s: [UInt8]) -> Bool {
        var body = s[...]
        if body.first == 43 || body.first == 45 { body = body.dropFirst() }
        let expAt = body.firstIndex { $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }
        let mantissa = expAt.map { body[..<$0] } ?? body
        let dotAt = mantissa.firstIndex(of: UInt8(ascii: "."))
        let intPart = dotAt.map { mantissa[..<$0] } ?? mantissa
        guard digitsWithUnderscores(intPart, isDigit) else { return false }
        if intPart.count > 1, intPart.first == 48 { return false }
        if let dotAt { guard digitsWithUnderscores(mantissa[(dotAt + 1)...], isDigit) else { return false } }
        if let expAt {
            var exp = body[(expAt + 1)...]
            if exp.first == 43 || exp.first == 45 { exp = exp.dropFirst() }
            guard digitsWithUnderscores(exp, isDigit) else { return false }
        }
        return dotAt != nil || expAt != nil
    }

    static func isDate(_ s: [UInt8]) -> Bool {
        guard s.count == 10, s[4] == 45, s[7] == 45 else { return false }
        guard let year = number(s[0..<4]), let month = number(s[5..<7]), let day = number(s[8..<10]) else { return false }
        guard (1...12).contains(month), day >= 1 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return day <= days
    }

    private static func isTime(_ s: ArraySlice<UInt8>) -> Bool {
        let t = Array(s)
        guard t.count >= 8, t[2] == 58, t[5] == 58,
              let hour = number(t[0..<2]), let minute = number(t[3..<5]), let second = number(t[6..<8]) else { return false }
        guard hour < 24, minute < 60, second <= 60 else { return false }
        if t.count == 8 { return true }
        guard t[8] == 46, t.count > 9 else { return false }
        return t[9...].allSatisfy(isDigit)
    }

    static func isDateTime(_ s: [UInt8]) -> Bool {
        if isDate(s) { return true }
        if s.count >= 8, s[2] == 58, isTime(s[...]) { return true }
        guard s.count >= 19, isDate(Array(s[0..<10])), [UInt8(ascii: "T"), UInt8(ascii: "t"), 0x20].contains(s[10]) else { return false }
        var rest = s[11...]
        if let last = rest.last, last == UInt8(ascii: "Z") || last == UInt8(ascii: "z") {
            rest = rest.dropLast()
        } else if rest.count >= 14 {
            let offset = rest.suffix(6)
            let o = Array(offset)
            if (o[0] == 43 || o[0] == 45), o[3] == 58, let h = number(o[1..<3]), let m = number(o[4..<6]), h < 24, m < 60 {
                rest = rest.dropLast(6)
            }
        }
        return isTime(rest)
    }

    private static func number(_ s: ArraySlice<UInt8>) -> Int? {
        guard !s.isEmpty, s.allSatisfy(isDigit) else { return nil }
        return s.reduce(0) { $0 * 10 + Int($1 - 48) }
    }
}
