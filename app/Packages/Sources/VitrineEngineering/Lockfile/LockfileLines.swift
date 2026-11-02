import Foundation

/// One non-blank, non-comment line of an indentation-structured lockfile (pnpm-lock.yaml, yarn.lock, Podfile.lock,
/// Gemfile.lock): how far it is indented and its text without the indent or trailing spaces. roadmap: S-22
struct LockLine {
    let indent: Int
    let text: Substring

    /// The lines of a document, skipping blank lines and lines whose first character is `#`.
    static func lines(_ s: String) -> [LockLine] {
        var out: [LockLine] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: true) {
            var indent = 0
            var start = raw.startIndex
            while start < raw.endIndex, raw[start] == " " || raw[start] == "\t" {
                indent += 1
                start = raw.index(after: start)
            }
            var end = raw.endIndex
            while end > start, raw[raw.index(before: end)] == " " || raw[raw.index(before: end)] == "\t" {
                end = raw.index(before: end)
            }
            guard start < end, raw[start] != "#" else { continue }
            out.append(LockLine(indent: indent, text: raw[start..<end]))
        }
        return out
    }
}

/// The few YAML shapes the lockfiles use, read by hand: `key: value` with plain, single- or double-quoted keys and
/// values, and one-level flow maps like `{integrity: sha512-…, tarball: https://…}`. roadmap: S-22
enum LockYAML {
    /// Splits `key: value` (or `key:` with nothing after it). The separator is the first colon followed by a space
    /// or the end of the line, so plain keys like `name@https://host/x` keep their own colons.
    static func keyValue(_ line: Substring) -> (key: String, value: Substring?)? {
        var keyEnd: Substring.Index
        var key: String
        if let q = line.first, q == "'" || q == "\"" {
            guard let close = closingQuote(line, q) else { return nil }
            key = unquote(line[line.startIndex...close])
            keyEnd = line.index(after: close)
            while keyEnd < line.endIndex, line[keyEnd] == " " { keyEnd = line.index(after: keyEnd) }
            guard keyEnd < line.endIndex, line[keyEnd] == ":" else { return nil }
        } else {
            var j = line.startIndex
            var found: Substring.Index?
            while j < line.endIndex {
                if line[j] == ":" {
                    let next = line.index(after: j)
                    if next == line.endIndex || line[next] == " " { found = j; break }
                }
                j = line.index(after: j)
            }
            guard let colon = found else { return nil }
            key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            keyEnd = colon
        }
        let afterColon = line.index(after: keyEnd)
        let rest = line[afterColon...].drop { $0 == " " }
        return (key, rest.isEmpty ? nil : rest)
    }

    private static func closingQuote(_ s: Substring, _ q: Character) -> Substring.Index? {
        var j = s.index(after: s.startIndex)
        while j < s.endIndex {
            if s[j] == q {
                let next = s.index(after: j)
                if q == "'", next < s.endIndex, s[next] == "'" { j = s.index(after: next); continue }   // '' escape
                return j
            }
            if q == "\"", s[j] == "\\" { j = s.index(after: j); if j == s.endIndex { break } }
            j = s.index(after: j)
        }
        return nil
    }

    /// A scalar without its quotes: '…' with '' for a quote, "…" with backslash escapes, plain text trimmed.
    static func unquote(_ s: Substring) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, let first = t.first, let last = t.last, first == last, first == "'" || first == "\"" else { return t }
        let inner = t.dropFirst().dropLast()
        if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var out = ""
        var escaped = false
        for c in inner {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// `{a: b, c: d}` as a dictionary (values unquoted). A value with a comma inside quotes is kept whole.
    static func flowMap(_ s: Substring) -> [String: String] {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("{"), t.hasSuffix("}") else { return [:] }
        var parts: [Substring] = []
        let inner = t.dropFirst().dropLast()
        var start = inner.startIndex
        var quote: Character?
        var j = inner.startIndex
        while j < inner.endIndex {
            let c = inner[j]
            if let q = quote { if c == q { quote = nil } }
            else if c == "'" || c == "\"" { quote = c }
            else if c == "," { parts.append(inner[start..<j]); start = inner.index(after: j) }
            j = inner.index(after: j)
        }
        parts.append(inner[start...])
        var out: [String: String] = [:]
        for part in parts {
            let p = part.drop { $0 == " " }
            if let kv = keyValue(p) { out[kv.key] = kv.value.map(unquote) ?? "" }
        }
        return out
    }
}
