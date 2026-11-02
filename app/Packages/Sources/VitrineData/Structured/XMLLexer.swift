import Foundation

/// One lexical piece of XML: a tag, a run of text, a comment, CDATA, a processing instruction or a `<!…>` declaration.
struct XMLToken {
    enum Kind: Equatable {
        case startTag(name: String, attributes: [String], selfClosing: Bool)
        case endTag(name: String)
        case text
        case comment
        case cdata
        case processingInstruction
        /// `<!DOCTYPE …>` and other `<!…>` declarations, internal subset included.
        case declaration
    }

    var kind: Kind
    /// Byte range in the input, delimiters included.
    var range: Range<Int>
    /// 1-based line and byte column of the first byte.
    var line: Int
    var column: Int
    /// The construct was still open at the end of the input.
    var unterminated = false
}

/// A forgiving XML tokenizer: it never fails, never expands entities and never loads anything; malformed input simply
/// becomes text or an unterminated token. Two jobs need exactly that: re-indenting a file (copying each tag verbatim, so
/// attribute order and quoting survive) and giving the tree reader what XMLParser does not (attribute order and the
/// byte offset of each start tag).
struct XMLLexer {
    private let b: UnsafeBufferPointer<UInt8>
    private var pos = 0
    private var line = 1
    private var lineStart = 0

    init(bytes: UnsafeBufferPointer<UInt8>) {
        b = bytes
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { pos = 3; lineStart = 3 }
    }

    mutating func next() -> XMLToken? {
        guard pos < b.count else { return nil }
        let start = pos, startLine = line, startColumn = pos - lineStart + 1
        var kind = XMLToken.Kind.text
        var unterminated = false
        if b[pos] == UInt8(ascii: "<") {
            if matches("<!--") {
                kind = .comment
                unterminated = !scan(to: "-->", from: pos + 4)
            } else if matches("<![CDATA[") {
                kind = .cdata
                unterminated = !scan(to: "]]>", from: pos + 9)
            } else if matches("<!") {
                kind = .declaration
                unterminated = !scanDeclaration()
            } else if matches("<?") {
                kind = .processingInstruction
                unterminated = !scan(to: "?>", from: pos + 2)
            } else if matches("</") {
                var p = pos + 2
                let nameStart = p
                while p < b.count, isNameChar(b[p]) { p += 1 }
                let name = String(decoding: UnsafeBufferPointer(rebasing: b[nameStart..<p]), as: UTF8.self)
                while p < b.count, b[p] != UInt8(ascii: ">") { p += 1 }
                unterminated = p >= b.count
                advance(to: min(b.count, p + 1))
                kind = .endTag(name: name)
            } else if pos + 1 < b.count, isNameStart(b[pos + 1]) {
                (kind, unterminated) = startTag()
            } else {
                advance(to: pos + 1)
                scanText()
            }
        } else {
            scanText()
        }
        return XMLToken(kind: kind, range: start..<pos, line: startLine, column: startColumn, unterminated: unterminated)
    }

    // MARK: Pieces

    private func matches(_ literal: String) -> Bool {
        var p = pos
        for byte in literal.utf8 {
            guard p < b.count, b[p] == byte else { return false }
            p += 1
        }
        return true
    }

    private mutating func advance(to end: Int) {
        while pos < end {
            if b[pos] == 0x0A { line += 1; lineStart = pos + 1 }
            pos += 1
        }
    }

    /// Moves past `terminator`; returns false (at the end of input) when it never comes.
    private mutating func scan(to terminator: String, from start: Int) -> Bool {
        let t = Array(terminator.utf8)
        var p = start
        while p + t.count <= b.count {
            if b[p] == t[0], Array(b[p..<(p + t.count)]) == t { advance(to: p + t.count); return true }
            p += 1
        }
        advance(to: b.count)
        return false
    }

    private mutating func scanText() {
        var p = pos
        while p < b.count, b[p] != UInt8(ascii: "<") { p += 1 }
        advance(to: p)
    }

    private mutating func scanDeclaration() -> Bool {
        var p = pos + 2
        var bracket = 0
        var quote: UInt8 = 0
        while p < b.count {
            let c = b[p]
            if quote != 0 { if c == quote { quote = 0 } }
            else if c == 0x22 || c == 0x27 { quote = c }
            else if c == UInt8(ascii: "[") { bracket += 1 }
            else if c == UInt8(ascii: "]") { bracket = max(0, bracket - 1) }
            else if c == UInt8(ascii: ">"), bracket == 0 { advance(to: p + 1); return true }
            p += 1
        }
        advance(to: b.count)
        return false
    }

    private mutating func startTag() -> (XMLToken.Kind, Bool) {
        var p = pos + 1
        let nameStart = p
        while p < b.count, isNameChar(b[p]) { p += 1 }
        let name = String(decoding: UnsafeBufferPointer(rebasing: b[nameStart..<p]), as: UTF8.self)
        var attributes: [String] = []
        var selfClosing = false
        while p < b.count {
            let c = b[p]
            if c == UInt8(ascii: ">") { p += 1; advance(to: p); return (.startTag(name: name, attributes: attributes, selfClosing: selfClosing), false) }
            if c == UInt8(ascii: "/") { selfClosing = true; p += 1; continue }
            if isNameStart(c) {
                let attrStart = p
                while p < b.count, isNameChar(b[p]) { p += 1 }
                attributes.append(String(decoding: UnsafeBufferPointer(rebasing: b[attrStart..<p]), as: UTF8.self))
                while p < b.count, isSpace(b[p]) { p += 1 }
                if p < b.count, b[p] == UInt8(ascii: "=") {
                    p += 1
                    while p < b.count, isSpace(b[p]) { p += 1 }
                    if p < b.count, b[p] == 0x22 || b[p] == 0x27 {
                        let quote = b[p]
                        p += 1
                        while p < b.count, b[p] != quote { p += 1 }
                        p += 1
                    } else {
                        while p < b.count, !isSpace(b[p]), b[p] != UInt8(ascii: ">") { p += 1 }
                    }
                }
                selfClosing = false
                continue
            }
            selfClosing = false
            p += 1
        }
        advance(to: b.count)
        return (.startTag(name: name, attributes: attributes, selfClosing: selfClosing), true)
    }

    private func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
    private func isNameStart(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 58 || c >= 0x80
    }
    private func isNameChar(_ c: UInt8) -> Bool { isNameStart(c) || (c >= 48 && c <= 57) || c == 45 || c == 46 }
}
