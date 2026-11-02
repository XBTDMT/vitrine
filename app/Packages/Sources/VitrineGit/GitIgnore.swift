import Foundation

/// `.gitignore` rules, enough to count untracked files the way `git status` does: `info/exclude`, then each
/// directory's `.gitignore` as the walk reaches it (deeper files later, so they win), the last matching rule
/// deciding. Supports `!` negation, a trailing `/` for directories, anchoring by a slash, `*`, `?`, `[...]` and
/// `**`. The user's global excludes file is not read (it lives outside the repository). roadmap: S-9
struct GitIgnore {
    struct Rule {
        let pattern: [UInt8]
        let negated: Bool
        let directoryOnly: Bool
        let anchored: Bool
        /// The directory the rule's file lives in, relative to the work tree ("" for the root).
        let base: String
    }

    private(set) var rules: [Rule] = []

    mutating func add(_ text: String, base: String) {
        for raw in text.split(whereSeparator: \.isNewline).prefix(10_000) {
            var line = Substring(raw)
            if line.hasSuffix("\r") { line = line.dropLast() }
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Trailing spaces are dropped unless escaped.
            while line.hasSuffix(" "), !line.hasSuffix("\\ ") { line = line.dropLast() }
            var negated = false
            if line.hasPrefix("!") { negated = true; line = line.dropFirst() }
            else if line.hasPrefix("\\!") || line.hasPrefix("\\#") { line = line.dropFirst() }
            var directoryOnly = false
            if line.hasSuffix("/") { directoryOnly = true; line = line.dropLast() }
            if line.isEmpty || line.utf8.count > 512 { continue }
            let anchored = line.contains("/")
            if line.hasPrefix("/") { line = line.dropFirst() }
            rules.append(Rule(pattern: Array(line.utf8), negated: negated, directoryOnly: directoryOnly, anchored: anchored, base: base))
        }
    }

    /// Whether `path` (relative to the work tree, no trailing slash) is ignored. Its parent directories are
    /// assumed not ignored: the walk never enters an ignored directory, as git does not.
    func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
        let bytes = Array(path.utf8)
        let name = bytes.lastIndex(of: 0x2F).map { Array(bytes[($0 + 1)...]) } ?? bytes
        for rule in rules.reversed() {
            if rule.directoryOnly && !isDirectory { continue }
            let relative: [UInt8]
            if rule.base.isEmpty { relative = bytes }
            else {
                let prefix = Array((rule.base + "/").utf8)
                guard bytes.starts(with: prefix) else { continue }
                relative = Array(bytes[prefix.count...])
            }
            let subject = rule.anchored ? relative : name
            var steps = 0
            if Self.match(rule.pattern, 0, subject, 0, &steps) { return !rule.negated }
        }
        return false
    }

    /// Wildmatch with pathname semantics: `*` and `?` never cross `/`; `**/` matches any number of directories,
    /// `/**` everything below, other `**` anything. A step budget keeps a hostile pattern from running away, and a
    /// depth cap keeps it off the stack: each `*` group recurses once, and a pattern is the file's to write (12,000
    /// `*a` groups overflowed a 512 KB worker stack inside the step budget). A pattern past either reads as no match.
    static let maxMatchDepth = 256

    static func match(_ p: [UInt8], _ pi0: Int, _ s: [UInt8], _ si0: Int, _ steps: inout Int, depth: Int = 0) -> Bool {
        // A call refused for depth still spends a step, so a caller's loop over positions cannot spin for free.
        steps += 1
        guard depth < maxMatchDepth, steps <= 20_000 else { return false }
        var pi = pi0, si = si0
        while pi < p.count {
            steps += 1
            if steps > 20_000 { return false }
            let c = p[pi]
            switch c {
            case 0x2A:   // *
                var q = pi
                while q < p.count, p[q] == 0x2A { q += 1 }
                if q - pi >= 2 {
                    let atSegmentStart = pi == 0 || p[pi - 1] == 0x2F
                    if atSegmentStart, q < p.count, p[q] == 0x2F {
                        // "**/": zero or more whole directories
                        if match(p, q + 1, s, si, &steps, depth: depth + 1) { return true }
                        var k = si
                        while k < s.count {
                            if s[k] == 0x2F, match(p, q + 1, s, k + 1, &steps, depth: depth + 1) { return true }
                            k += 1
                        }
                        return false
                    }
                    if q == p.count { return true }
                    for k in si...s.count where match(p, q, s, k, &steps, depth: depth + 1) { return true }
                    return false
                }
                if q == p.count { return !s[si...].contains(0x2F) }
                var k = si
                while k <= s.count {
                    if match(p, q, s, k, &steps, depth: depth + 1) { return true }
                    if k < s.count, s[k] == 0x2F { break }
                    k += 1
                }
                return false
            case 0x3F:   // ?
                guard si < s.count, s[si] != 0x2F else { return false }
                pi += 1; si += 1
            case 0x5B:   // [
                guard si < s.count, s[si] != 0x2F else { return false }
                guard let (matched, next) = matchClass(p, pi, s[si]) else {
                    // An unclosed bracket is a literal "[".
                    guard s[si] == c else { return false }
                    pi += 1; si += 1; continue
                }
                guard matched else { return false }
                pi = next; si += 1
            case 0x5C:   // backslash escapes the next character
                pi += 1
                guard pi < p.count, si < s.count, s[si] == p[pi] else { return false }
                pi += 1; si += 1
            default:
                guard si < s.count, s[si] == c else { return false }
                pi += 1; si += 1
            }
        }
        return si == s.count
    }

    /// A bracket expression at `p[at]`; nil when it never closes.
    private static func matchClass(_ p: [UInt8], _ at: Int, _ ch: UInt8) -> (Bool, Int)? {
        var i = at + 1
        var negate = false
        if i < p.count, p[i] == 0x21 || p[i] == 0x5E { negate = true; i += 1 }
        var matched = false
        var first = true
        while i < p.count {
            let c = p[i]
            if c == 0x5D, !first { return (matched != negate, i + 1) }
            first = false
            if i + 2 < p.count, p[i + 1] == 0x2D, p[i + 2] != 0x5D {
                if ch >= c && ch <= p[i + 2] { matched = true }
                i += 3
            } else {
                if c == ch { matched = true }
                i += 1
            }
        }
        return nil
    }
}
