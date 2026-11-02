// VitrineDetect — the shortest text a pattern can report as a secret (G-40, route D). Pure: a regex source in, a count
// of characters out.
//
// The bound must never be MORE than the truth: G-40's opt-in "Skip spots too small to hold a secret" lets a spot no
// reading could read go unflagged only when the spot's largest possible glyph count is below the shortest secret any
// enabled detector or custom rule can report. So every construct this reader does not fully understand counts as 0
// characters (a lookaround, a backreference, an unknown escape, a group that may not take part), which can only lower the
// bound, making the switch skip fewer spots, never more.
import Foundation

public enum RegexLength {
    /// The fewest characters (UTF-16 units of ordinary text, one per glyph) that a match of `pattern` can REDACT: the
    /// named `secret` group's content when the pattern has one (what `PatternMatch.redactRange` covers), never more than
    /// the whole match's minimum (a match in which the group did not take part redacts the whole match). A lower bound:
    /// 0 when the source cannot be read.
    public static func minimumRedactLength(of pattern: String) -> Int {
        let units = Array(pattern.unicodeScalars)
        var parser = Parser(units: units)
        let whole = parser.alternation(depth: 0)
        guard parser.isAtEnd, !parser.failed else { return 0 }
        guard let secret = parser.secretMinimum else { return whole }
        return min(secret, whole)
    }

    /// Recursive-descent reader over ICU regex syntax, computing each piece's minimum length.
    private struct Parser {
        let units: [Unicode.Scalar]
        var i = 0
        var failed = false
        /// The minimum of the `secret` group's content, when the pattern has one.
        var secretMinimum: Int?

        init(units: [Unicode.Scalar]) { self.units = units }

        var isAtEnd: Bool { i >= units.count }
        func peek(_ offset: Int = 0) -> Unicode.Scalar? { i + offset < units.count ? units[i + offset] : nil }

        /// `a|b|c` at this depth: the shortest branch.
        mutating func alternation(depth: Int) -> Int {
            var best = sequence(depth: depth)
            while peek() == "|" {
                i += 1
                best = min(best, sequence(depth: depth))
            }
            return best
        }

        /// Pieces until `|`, `)` or the end: their minimums add.
        mutating func sequence(depth: Int) -> Int {
            var total = 0
            while let c = peek(), c != "|", !(c == ")" && depth > 0) {
                if c == ")" { failed = true; return total }
                let atom = self.atom(depth: depth)
                total = saturatingAdd(total, quantified(atom))
                if failed { return total }
            }
            return total
        }

        /// One atom's minimum length (before its quantifier).
        mutating func atom(depth: Int) -> Int {
            guard let c = peek() else { return 0 }
            switch c {
            case "(":
                return group(depth: depth)
            case "[":
                skipClass()
                return 1
            case "\\":
                return escape()
            case "^", "$":
                i += 1
                return 0
            case ".":
                i += 1
                return 1
            case "*", "+", "?", "{":
                // A quantifier with nothing before it (ICU rejects it; a literal `{` is read as itself below).
                if c == "{" { i += 1; return 1 }
                failed = true
                return 0
            default:
                i += 1
                return 1
            }
        }

        /// `(…)`, `(?:…)`, `(?<name>…)`, `(?'name'…)`, flags `(?i)` / `(?i:…)`, lookarounds, atomic `(?>…)`, comments.
        mutating func group(depth: Int) -> Int {
            i += 1   // "("
            var isLookaround = false
            var name: String?
            if peek() == "?" {
                i += 1
                switch peek() {
                case ":", ">", "|":
                    i += 1
                case "=", "!":
                    i += 1
                    isLookaround = true
                case "<" where peek(1) == "=" || peek(1) == "!":
                    i += 2
                    isLookaround = true
                case "<", "'", "P":
                    if peek() == "P" { i += 1 }   // (?P<name>…)
                    let close: Unicode.Scalar = peek() == "'" ? "'" : ">"
                    i += 1
                    var text = ""
                    while let c = peek(), c != close { text.unicodeScalars.append(c); i += 1 }
                    guard peek() == close else { failed = true; return 0 }
                    i += 1
                    name = text
                case "#":
                    while let c = peek(), c != ")" { i += 1; _ = c }
                    guard peek() == ")" else { failed = true; return 0 }
                    i += 1
                    return 0
                default:
                    // Flags: `(?i)`, `(?-i)`, `(?ix:…)`.
                    while let c = peek(), c.properties.isAlphabetic || c == "-" { i += 1 }
                    if peek() == ")" { i += 1; return 0 }
                    guard peek() == ":" else { failed = true; return 0 }
                    i += 1
                }
            }
            let inner = alternation(depth: depth + 1)
            guard peek() == ")" else { failed = true; return 0 }
            i += 1
            if name == ICURegexMatcher.secretGroupName {
                secretMinimum = min(secretMinimum ?? .max, inner)
            }
            return isLookaround ? 0 : inner
        }

        /// `\d`, `\w`, `\p{…}`, `\x{…}`, `￿`, `\Q…\E`, anchors `\b \B \A \z \Z \G`, backreferences (0: what they repeat
        /// is not known here), and an escaped literal.
        mutating func escape() -> Int {
            i += 1   // "\"
            guard let c = peek() else { failed = true; return 0 }
            i += 1
            switch c {
            case "b", "B", "A", "z", "Z", "G":
                return 0
            case "Q":
                var count = 0
                while let d = peek() {
                    if d == "\\" && peek(1) == "E" { i += 2; return count }
                    count += 1
                    i += 1
                }
                return count
            case "p", "P", "x", "N":
                if peek() == "{" {
                    while let d = peek(), d != "}" { i += 1 }
                    guard peek() == "}" else { failed = true; return 0 }
                    i += 1
                } else if c == "x" {
                    i = min(units.count, i + 2)
                } else {
                    i = min(units.count, i + 1)
                }
                return 1
            case "u":
                i = min(units.count, i + 4)
                return 1
            case "U":
                i = min(units.count, i + 8)
                return 1
            case "k":
                // Named backreference `\k<name>`: 0.
                if peek() == "<" { while let d = peek(), d != ">" { i += 1 }; i += 1 }
                return 0
            default:
                if c.properties.numericType != nil, c != "0" {
                    // A backreference: it may repeat an empty capture.
                    while let d = peek(), d.properties.numericType != nil { i += 1 }
                    return 0
                }
                return 1
            }
        }

        /// Skips a character class, nested classes and escapes included.
        mutating func skipClass() {
            i += 1   // "["
            var depth = 1
            if peek() == "^" { i += 1 }
            if peek() == "]" { i += 1 }   // a leading "]" is literal
            while let c = peek(), depth > 0 {
                i += 1
                switch c {
                case "\\": i += 1
                case "[": depth += 1
                case "]": depth -= 1
                default: break
                }
            }
            if depth > 0 { failed = true }
        }

        /// Applies the quantifier after an atom, if any: `*` and `?` make it 0, `+` keeps it, `{n}` / `{n,}` / `{n,m}`
        /// multiply by n. A lazy (`?`) or possessive (`+`) suffix does not change the minimum.
        mutating func quantified(_ atom: Int) -> Int {
            guard let c = peek() else { return atom }
            var result = atom
            switch c {
            case "*", "?":
                i += 1
                result = 0
            case "+":
                i += 1
            case "{":
                var j = i + 1
                var digits = ""
                while j < units.count, units[j].properties.numericType != nil { digits.unicodeScalars.append(units[j]); j += 1 }
                guard !digits.isEmpty, j < units.count, units[j] == "," || units[j] == "}" else { return atom }   // a literal "{"
                while j < units.count, units[j] != "}" { j += 1 }
                guard j < units.count else { return atom }
                i = j + 1
                let n = Int(digits) ?? 0
                result = atom == 0 || n == 0 ? 0 : (atom > Int.max / n ? Int.max : atom * n)
            default:
                return atom
            }
            if let next = peek(), next == "?" || next == "+" { i += 1 }
            return result
        }

        func saturatingAdd(_ a: Int, _ b: Int) -> Int {
            let (sum, overflow) = a.addingReportingOverflow(b)
            return overflow ? .max : sum
        }
    }
}

public extension CompiledCatalogue {
    /// G-40 route D: the fewest characters any enabled detector or custom rule in this catalogue can report as a secret
    /// (`RegexLength.minimumRedactLength` over every compiled pattern). Nil when the catalogue has no detector at all.
    var shortestSecretLength: Int? {
        detectors.flatMap { $0.matchers.map { RegexLength.minimumRedactLength(of: $0.pattern) } }.min()
    }
}
