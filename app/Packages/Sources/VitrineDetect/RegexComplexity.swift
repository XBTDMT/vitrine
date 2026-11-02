// VitrineDetect — the static half of the bound on a regular expression's work (security scan 2026-10-28 F23). The
// dynamic half is `MatchBudget`, which stops any search that runs too long; this half refuses, before a pattern is
// ever run, the shape that makes a backtracking engine exponential on ordinary text: a group repeated without bound
// that itself holds a repeat without bound (`(\w+\s?)*`, `(a+)+`, `(?:x*y?)+`). It also refuses a pattern longer
// than any honest one.
import Foundation

enum RegexComplexity {
    /// The longest regular expression accepted, in UTF-16 units. The longest built-in pattern is 315 (2026-10-28); a
    /// rule a person writes is far shorter. A longer source is refused rather than compiled.
    static let maxLength = 1_024

    /// Throws `PatternError.regexTooLong` or `.regexTooComplex` for a source of the shapes above; returns otherwise.
    /// The scan is a conservative reading of ICU syntax: escapes (`\x`, `\p{…}`, `\Q…\E`), character classes (nested
    /// sets included) and comments are skipped as single atoms, so their characters are never read as groups or
    /// quantifiers.
    static func check(_ source: String) throws {
        let units = Array(source.utf16)
        guard units.count <= maxLength else { throw PatternError.regexTooLong(maximum: maxLength) }
        // One frame per open group: whether an unbounded repeat occurs anywhere inside it.
        var frames: [Bool] = [false]
        // Whether the atom just read is a group, and whether that group held an unbounded repeat.
        var lastAtomGroupUnbounded: Bool? = nil
        var i = 0
        func at(_ k: Int) -> UInt16? { k < units.count ? units[k] : nil }
        let backslash: UInt16 = 0x5C, open: UInt16 = 0x28, close: UInt16 = 0x29, bracketOpen: UInt16 = 0x5B
        let star: UInt16 = 0x2A, plus: UInt16 = 0x2B, question: UInt16 = 0x3F, braceOpen: UInt16 = 0x7B, braceClose: UInt16 = 0x7D
        let hash: UInt16 = 0x23, comma: UInt16 = 0x2C
        while i < units.count {
            let c = units[i]
            switch c {
            case backslash:
                i += skipEscape(units, from: i)
                lastAtomGroupUnbounded = nil
            case bracketOpen:
                i = skipClass(units, from: i)
                lastAtomGroupUnbounded = nil
            case open:
                if at(i + 1) == question, at(i + 2) == hash {   // (?# comment )
                    while i < units.count, units[i] != close { i += 1 }
                    i += 1
                    continue
                }
                frames.append(false)
                lastAtomGroupUnbounded = nil
                i += 1
            case close:
                let inner = frames.count > 1 ? frames.removeLast() : false
                if inner { frames[frames.count - 1] = true }
                lastAtomGroupUnbounded = inner
                i += 1
            case star, plus, question, braceOpen:
                // A quantifier: `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`, then an optional `?` (lazy) or `+` (possessive).
                var unbounded = c == star || c == plus
                var j = i + 1
                if c == braceOpen {
                    var k = i + 1
                    var sawComma = false, sawUpper = false, valid = true
                    while let u = at(k), u != braceClose {
                        if u == comma { sawComma = true } else if (0x30...0x39).contains(u) { if sawComma { sawUpper = true } } else { valid = false; break }
                        k += 1
                    }
                    guard valid, at(k) == braceClose else { lastAtomGroupUnbounded = nil; i += 1; continue }   // a literal `{`
                    unbounded = sawComma && !sawUpper
                    j = k + 1
                }
                if let next = at(j), next == question || next == plus { j += 1 }
                if unbounded {
                    if lastAtomGroupUnbounded == true { throw PatternError.regexTooComplex }
                    frames[frames.count - 1] = true
                }
                lastAtomGroupUnbounded = nil
                i = j
            default:
                lastAtomGroupUnbounded = nil
                i += 1
            }
        }
    }

    /// Units taken by the escape at `from` (`units[from]` is a backslash).
    static func skipEscape(_ units: [UInt16], from: Int) -> Int {
        guard from + 1 < units.count else { return 1 }
        let next = units[from + 1]
        switch next {
        case 0x51:   // \Q … \E: a literal run
            var k = from + 2
            while k + 1 < units.count, !(units[k] == 0x5C && units[k + 1] == 0x45) { k += 1 }
            return min(units.count, k + 2) - from
        case 0x70, 0x50, 0x78, 0x4E:   // \p{…} \P{…} \x{…} \N{…}
            if from + 2 < units.count, units[from + 2] == 0x7B {
                var k = from + 3
                while k < units.count, units[k] != 0x7D { k += 1 }
                return min(units.count, k + 1) - from
            }
            return 2
        default:
            return 2
        }
    }

    /// The index just after the character class that opens at `from`, nested sets included.
    static func skipClass(_ units: [UInt16], from: Int) -> Int {
        var depth = 0
        var k = from
        while k < units.count {
            let u = units[k]
            if u == 0x5C { k += skipEscape(units, from: k); continue }
            if u == 0x5B { depth += 1 }
            if u == 0x5D {
                // A `]` straight after `[` or `[^` is a literal.
                let first = k > 0 && (units[k - 1] == 0x5B || (k > 1 && units[k - 1] == 0x5E && units[k - 2] == 0x5B))
                if !first {
                    depth -= 1
                    if depth == 0 { return k + 1 }
                }
            }
            k += 1
        }
        return units.count
    }
}
