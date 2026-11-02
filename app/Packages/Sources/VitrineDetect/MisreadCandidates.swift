// VitrineDetect — G-12 route C: bounded corrections of the OCR misreads measured on the image suite (2026-10-27,
// knowledge/redman/LEDGER.md): `l`↔`1`↔`I`, `O`↔`0`, letter case, `_` read as a space, `<` runs read short or as
// `^`/space/`C`, and one dropped character. A candidate is only ever a question put to the UNCHANGED matchers and
// validators; nothing here decides that a text is a secret. Every generator has a fixed upper bound.
public import Foundation

public enum MisreadCandidates {
    /// Upper bound on single-position swaps tried for one rejected match (the GitHub body is 36 units, a JWT header
    /// about 36: every one-character swap of either fits well inside).
    public static let maxSwaps = 256
    /// A fragment (run of ASCII letters and digits) this long is secret-shaped enough for the whole-token variants.
    public static let longFragment = 12
    /// At most this many `<` are added to a filler run (the MRZ line read 4 short of its 44 on the 2× re-read).
    public static let maxRunExtension = 16

    /// The validators a swap may be put to: a check strong enough that up to `maxSwaps` wrong guesses cannot pass it by
    /// chance. GitHub's CRC32 (one in 62^6 per guess) and the JWT header (base64 of a JSON object naming `alg`) are.
    /// Luhn (one in 10) and IBAN mod-97 (one in 97) are not: a dozen swaps of a mistyped number pass one of them far
    /// too often (measured: the IBAN negative fixture ending `0130 01` passed). `entropy` and `phoneShape` are not
    /// checks a misread breaks, and a swap that adds a digit would talk a low-entropy value into passing.
    public static func swapsCanRepair(_ validator: Validator) -> Bool {
        switch validator {
        case .jwt, .githubChecksum: return true
        case .none, .luhn, .ibanMod97, .entropy, .awsKeyIdPrefix, .phoneShape: return false
        }
    }

    /// Letters whose capital is the same shape, only larger: the case flips measured (`z`→`Z`, `K`→`k`, `x`→`X`,
    /// `v`→`V`, `s`→`S`). A whole token in the other case is how the text was written, not a misread.
    static let caseAmbiguous: Set<UTF16.CodeUnit> = Set("cksopuvwxzCKSOPUVWXZ".utf16)

    /// The measured single-character confusions: each unit's alternatives.
    static func alternatives(_ unit: UTF16.CodeUnit, caseFlips: Bool) -> [UTF16.CodeUnit] {
        var result: [UTF16.CodeUnit] = []
        switch unit {
        case 0x6C: result = [0x31, 0x49]          // l → 1, I
        case 0x31: result = [0x6C, 0x49]          // 1 → l, I
        case 0x49: result = [0x6C, 0x31]          // I → l, 1
        case 0x4F: result = [0x30]                // O → 0
        case 0x30: result = [0x4F]                // 0 → O
        default: break
        }
        if caseFlips, caseAmbiguous.contains(unit), let scalar = Unicode.Scalar(unit) {
            let flipped = scalar.properties.isUppercase ? Character(scalar).lowercased() : Character(scalar).uppercased()
            if let u = flipped.utf16.first, u != unit, !result.contains(u) { result.append(u) }
        }
        return result
    }

    /// Every text that differs from `text` in exactly one unit by a measured confusion, left to right, at most `limit`.
    public static func singleSwaps(_ text: String, caseFlips: Bool = true, limit: Int = maxSwaps) -> [String] {
        let units = Array(text.utf16)
        var result: [String] = []
        for (i, unit) in units.enumerated() {
            for alternative in alternatives(unit, caseFlips: caseFlips) {
                var copy = units
                copy[i] = alternative
                result.append(String(decoding: copy, as: UTF16.self))
                if result.count >= limit { return result }
            }
        }
        return result
    }

    /// A whole-line candidate. `insertions` are the UTF-16 offsets (in the candidate) of units that were added; every
    /// other unit maps one-to-one onto the original line. `changed` are the candidate offsets that differ.
    public struct Variant: Sendable, Hashable {
        public let text: String
        public let insertions: [Int]
        public let changed: [Int]

        /// `range` in the candidate → the same characters in the original line.
        public func originalRange(of range: NSRange) -> NSRange {
            func map(_ offset: Int) -> Int { offset - insertions.filter { $0 < offset }.count }
            let start = map(range.location), end = map(NSMaxRange(range))
            return NSRange(location: start, length: max(0, end - start))
        }

        /// Whether `range` (candidate offsets) covers a changed unit.
        public func touchesChange(_ range: NSRange) -> Bool {
            changed.contains { NSLocationInRange($0, range) }
        }

        /// Whether a match on `range` is a misread repaired rather than a text rewritten: it covers a changed unit, and
        /// changed units are at most `maxChangedFraction` of it (measured repairs: 1 of 32 for the OTP secret, 1 of 57
        /// for RubyGems, 6 of 44 for the MRZ filler; a digits→letters rewrite of a card number is all of it).
        public func repairs(_ range: NSRange) -> Bool {
            let inside = changed.filter { NSLocationInRange($0, range) }.count
            return inside > 0 && Double(inside) <= MisreadCandidates.maxChangedFraction * Double(range.length)
        }
    }

    /// The largest share of a variant match that may differ from what was read.
    public static let maxChangedFraction = 0.25

    /// The bounded whole-line variants of `line` (folded text), or none when the line has nothing secret-shaped:
    /// - five class mappings applied to every long fragment at once: letters→digits (`O`→0, `I`/`l`→1),
    ///   digits→upper (`0`→O, `1`→I), digits→lower (`0`→o, `1`→l), lower (same-shape capitals lowered, then `o`→0,
    ///   `l`/`I`→1), upper (same-shape small letters raised, then `0`→O, `1`→I);
    /// - `_` for each single space between two secret-shaped runs (all such spaces at once);
    /// - `<` runs: `^`, `C`, `c` and spaces inside a run of `<` become `<`, then the run is extended by 1…16;
    /// - one dropped character: `a`, `A` or `0` appended to each long fragment (at most four fragments).
    public static func lineVariants(_ line: String) -> [Variant] {
        let units = Array(line.utf16)
        let fragments = Self.fragments(units).filter { $0.count >= longFragment }
        var result: [Variant] = []
        var seen: Set<String> = [line]
        func add(_ candidate: [UTF16.CodeUnit], insertions: [Int] = []) {
            let text = String(decoding: candidate, as: UTF16.self)
            guard seen.insert(text).inserted else { return }
            var changed: [Int] = insertions
            if insertions.isEmpty {
                changed = candidate.indices.filter { $0 < units.count && candidate[$0] != units[$0] }
            } else {
                // Units after an insertion are shifted; compare each with its original.
                var o = 0
                for (c, unit) in candidate.enumerated() {
                    if insertions.contains(c) { continue }
                    if o < units.count, unit != units[o] { changed.append(c) }
                    o += 1
                }
            }
            result.append(Variant(text: text, insertions: insertions, changed: changed.sorted()))
        }

        if !fragments.isEmpty {
            for mapping in classMappings {
                var copy = units
                for fragment in fragments { for i in fragment { copy[i] = mapping(copy[i]) } }
                add(copy)
            }
        }

        // `_` read as a space, between two secret-shaped runs.
        let runs = whitespaceRuns(units)
        var joined = units
        var anyJoin = false
        for (left, right) in zip(runs, runs.dropFirst()) where right.lowerBound == left.upperBound + 1 && units[left.upperBound] == 0x20 {
            if secretShaped(Array(units[left])) && secretShaped(Array(units[right])) {
                joined[left.upperBound] = 0x5F
                anyJoin = true
            }
        }
        if anyJoin { add(joined) }

        // `<` runs.
        if units.filter({ $0 == 0x3C }).count >= 3 {
            var repaired = units
            for i in repaired.indices where repaired[i] == 0x5E { repaired[i] = 0x3C }    // ^ → <
            // A lookalike (space, C, c) with `<` on both sides (looking past other lookalikes) becomes `<`.
            let lookalike: Set<UTF16.CodeUnit> = [0x20, 0x43, 0x63]
            for i in repaired.indices where lookalike.contains(repaired[i]) {
                let left = repaired[..<i].lastIndex { !lookalike.contains($0) }
                let right = repaired[(i + 1)...].firstIndex { !lookalike.contains($0) }
                if let left, let right, repaired[left] == 0x3C, repaired[right] == 0x3C { repaired[i] = 0x3C }
            }
            add(repaired)
            // Filler runs read short: extend the last run of three or more `<` by 1…maxRunExtension.
            var end = repaired.count
            while end > 0, repaired[end - 1] != 0x3C { end -= 1 }
            var start = end
            while start > 0, repaired[start - 1] == 0x3C { start -= 1 }
            if end - start >= 3 {
                for k in 1...maxRunExtension {
                    let extended = Array(repaired[..<end]) + [UTF16.CodeUnit](repeating: 0x3C, count: k) + Array(repaired[end...])
                    add(extended, insertions: Array(end..<(end + k)))
                }
            }
        }

        // One dropped character at the end of a long fragment.
        for fragment in fragments.prefix(4) {
            for probe: UTF16.CodeUnit in [0x61, 0x41, 0x30] {
                var copy = units
                copy.insert(probe, at: fragment.upperBound)
                add(copy, insertions: [fragment.upperBound])
            }
        }
        return result
    }

    static let classMappings: [@Sendable (UTF16.CodeUnit) -> UTF16.CodeUnit] = [
        { u in switch u { case 0x4F: 0x30; case 0x49, 0x6C: 0x31; default: u } },                  // letters → digits
        { u in switch u { case 0x30: 0x4F; case 0x31: 0x49; default: u } },                        // digits → upper
        { u in switch u { case 0x30: 0x6F; case 0x31: 0x6C; default: u } },                        // digits → lower
        { u in
            let lower: UTF16.CodeUnit = (0x41...0x5A).contains(u) && caseAmbiguous.contains(u) ? u + 0x20 : u
            switch lower { case 0x6F: return 0x30; case 0x6C, 0x49: return 0x31; default: return lower }
        },                                                                                          // lower (hex)
        { u in
            let upper: UTF16.CodeUnit = (0x61...0x7A).contains(u) && caseAmbiguous.contains(u) ? u - 0x20 : u
            switch upper { case 0x30: return 0x4F; case 0x31: return 0x49; default: return upper }
        },                                                                                          // upper (base32)
    ]

    /// Maximal runs of ASCII letters and digits.
    static func fragments(_ units: [UTF16.CodeUnit]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (i, u) in units.enumerated() {
            let alnum = (0x30...0x39).contains(u) || (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u)
            if alnum, start == nil { start = i }
            if !alnum, let s = start { result.append(s..<i); start = nil }
        }
        if let s = start { result.append(s..<units.count) }
        return result
    }

    /// Maximal runs of non-whitespace units.
    static func whitespaceRuns(_ units: [UTF16.CodeUnit]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (i, u) in units.enumerated() {
            let space = u == 0x20 || u == 0x09
            if !space, start == nil { start = i }
            if space, let s = start { result.append(s..<i); start = nil }
        }
        if let s = start { result.append(s..<units.count) }
        return result
    }

    /// At least 8 units with at least two of upper, lower, digit: what a token fragment looks like and a word does not.
    static func secretShaped(_ units: [UTF16.CodeUnit]) -> Bool {
        guard units.count >= 8 else { return false }
        let upper = units.contains { (0x41...0x5A).contains($0) }
        let lower = units.contains { (0x61...0x7A).contains($0) }
        let digit = units.contains { (0x30...0x39).contains($0) }
        return [upper, lower, digit].filter { $0 }.count >= 2
    }
}
