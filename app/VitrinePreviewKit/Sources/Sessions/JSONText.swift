import Foundation

/// A small reader of JSON *text* positions, for changing a person's settings file by inserting and removing exact
/// text instead of re-serialising it (JSONSerialization would reorder their keys and rewrite their formatting).
/// It only finds where values start and end; whether the text is valid JSON is checked separately with
/// JSONSerialization before and after every change. Offsets are UTF-8 byte offsets. roadmap: S-11
struct JSONText {
    let bytes: [UInt8]
    init(_ text: String) { bytes = Array(text.utf8) }

    struct Member { let key: String; let keyStart: Int; let valueStart: Int; let valueEnd: Int }
    struct Element { let start: Int; let end: Int }

    func skipSpace(_ i: Int) -> Int {
        var i = i
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        return i
    }

    /// The offset just past the value that starts at `i`; nil when there is no value there.
    func valueEnd(_ i: Int) -> Int? {
        guard i < bytes.count else { return nil }
        switch bytes[i] {
        case UInt8(ascii: "\""): return stringEnd(i)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0, j = i
            while j < bytes.count {
                let c = bytes[j]
                if c == UInt8(ascii: "\"") { guard let e = stringEnd(j) else { return nil }; j = e; continue }
                if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
                if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") { depth -= 1; if depth == 0 { return j + 1 } }
                j += 1
            }
            return nil
        default:
            var j = i
            while j < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[j]) { j += 1 }
            return j > i ? j : nil
        }
    }

    func stringEnd(_ i: Int) -> Int? {
        var j = i + 1
        while j < bytes.count {
            if bytes[j] == UInt8(ascii: "\\") { j += 2; continue }
            if bytes[j] == UInt8(ascii: "\"") { return j + 1 }
            j += 1
        }
        return nil
    }

    func string(_ start: Int, _ end: Int) -> String? {
        let raw = Data(bytes[start..<end])
        return (try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed)) as? String
    }

    func text(_ start: Int, _ end: Int) -> String { String(decoding: bytes[start..<end], as: UTF8.self) }

    /// The members of the object whose `{` is at `open`, and the offset of its `}`.
    func members(_ open: Int) -> (members: [Member], close: Int)? {
        guard open < bytes.count, bytes[open] == UInt8(ascii: "{") else { return nil }
        var out: [Member] = []
        var i = skipSpace(open + 1)
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "}") { return (out, i) }
            guard bytes[i] == UInt8(ascii: "\""), let keyEnd = stringEnd(i), let key = string(i, keyEnd) else { return nil }
            var j = skipSpace(keyEnd)
            guard j < bytes.count, bytes[j] == UInt8(ascii: ":") else { return nil }
            j = skipSpace(j + 1)
            guard let end = valueEnd(j) else { return nil }
            out.append(Member(key: key, keyStart: i, valueStart: j, valueEnd: end))
            i = skipSpace(end)
            if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i = skipSpace(i + 1) }
        }
        return nil
    }

    /// The elements of the array whose `[` is at `open`, and the offset of its `]`.
    func elements(_ open: Int) -> (elements: [Element], close: Int)? {
        guard open < bytes.count, bytes[open] == UInt8(ascii: "[") else { return nil }
        var out: [Element] = []
        var i = skipSpace(open + 1)
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "]") { return (out, i) }
            guard let end = valueEnd(i) else { return nil }
            out.append(Element(start: i, end: end))
            i = skipSpace(end)
            if i < bytes.count, bytes[i] == UInt8(ascii: ",") { i = skipSpace(i + 1) }
        }
        return nil
    }

    /// The whitespace that starts the line holding offset `i`.
    func lineIndent(_ i: Int) -> String {
        var s = min(i, bytes.count)
        while s > 0, bytes[s - 1] != 0x0A { s -= 1 }
        var e = s
        while e < bytes.count, bytes[e] == 0x20 || bytes[e] == 0x09 { e += 1 }
        return text(s, e)
    }

    /// The file's indent step: the first indented line's leading whitespace, else two spaces.
    var indentUnit: String {
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A, i + 1 < bytes.count, bytes[i + 1] == 0x20 || bytes[i + 1] == 0x09 {
                let w = lineIndent(i + 1)
                if !w.isEmpty { return w }
            }
            i += 1
        }
        return "  "
    }

    /// Every top-level JSON value in a text of values written one after another (a log of hook payloads, pretty or
    /// not), skipping anything between them that is not a value.
    func values() -> [Any] {
        var out: [Any] = []
        var i = skipSpace(0)
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "{"), let end = valueEnd(i) {
                if let v = try? JSONSerialization.jsonObject(with: Data(bytes[i..<end])) { out.append(v) }
                i = skipSpace(end)
            } else {
                i = skipSpace(i + 1)
            }
        }
        return out
    }
}
