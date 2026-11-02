import Foundation

/// Word-level highlights inside changed lines: `count` → `pendingCount` is found at a glance instead of reading as a
/// whole-line rewrite (Sublime Merge / delta cue in design/mockups/diff/NOTES.md).
///
/// Two steps. First, deleted and added lines in one change block are *paired*: an alignment that keeps both sides
/// in order and maximises how much text the pairs share, so a block that deletes three lines and adds four pairs
/// the ones that are edits of each other and leaves the genuinely new line alone. A pair needs a real overlap
/// (`minSimilarity` of their non-space characters, in shared tokens); lines that share nothing are never paired,
/// so no highlight ever claims a relationship that is not there. Second, each pair is diffed token by token
/// (Myers, where the shortest script is the readable one) and the changed tokens become ranges.
///
/// Ranges are UTF-16 offsets into the line's text, the unit both `NSAttributedString` and JavaScript use.
public enum Intraline {
    public struct Options: Sendable, Equatable {
        /// Share of non-space characters two lines must have in common (0…1) to be paired.
        public var minSimilarity: Double
        /// A block with more lines than this on either side is paired by position instead of aligned.
        public var maxAlignedLines: Int
        /// Lines longer than this (UTF-16 units) get no highlight: a minified line's token diff is noise.
        public var maxLineLength: Int

        public init(minSimilarity: Double = 0.4, maxAlignedLines: Int = 64, maxLineLength: Int = 2_000) {
            self.minSimilarity = min(1, max(0.01, minSimilarity))
            self.maxAlignedLines = max(1, maxAlignedLines); self.maxLineLength = max(1, maxLineLength)
        }

        public static let `default` = Options()
    }

    /// A deleted line and the added line it became, with what changed in each.
    public struct Pair: Sendable, Equatable, Hashable {
        /// Indices into `DiffHunk.lines`.
        public var deleted: Int
        public var added: Int
        /// Shared non-space characters over all non-space characters, after the token diff (0…1).
        public var similarity: Double
        /// Changed UTF-16 ranges in the deleted line's text and in the added line's.
        public var oldRanges: [Range<Int>]
        public var newRanges: [Range<Int>]
    }

    /// The pairs in one hunk, in hunk order.
    public static func pairs(in hunk: DiffHunk, options: Options = .default) -> [Pair] {
        var out: [Pair] = []
        var i = 0
        let lines = hunk.lines
        while i < lines.count {
            guard lines[i].kind != .context else { i += 1; continue }
            var deleted: [Int] = [], added: [Int] = []
            while i < lines.count, lines[i].kind != .context {
                if lines[i].kind == .deleted { deleted.append(i) } else { added.append(i) }
                i += 1
            }
            guard !deleted.isEmpty, !added.isEmpty else { continue }
            out += pairBlock(deleted: deleted, added: added, lines: lines, options: options)
        }
        return out
    }

    /// Highlights for two lines taken as a pair; nil when they share too little to be called an edit.
    public static func highlight(old: String, new: String, options: Options = .default) -> (old: [Range<Int>], new: [Range<Int>], similarity: Double)? {
        guard old.utf16.count <= options.maxLineLength, new.utf16.count <= options.maxLineLength else { return nil }
        let a = tokenize(old), b = tokenize(new)
        let result = LineDiff.diff(a.map(\.text), b.map(\.text), algorithm: .myers,
                                   budget: .init(timeLimit: .milliseconds(20), maxElements: 20_000))
        var changedA = [Bool](repeating: false, count: a.count), changedB = [Bool](repeating: false, count: b.count)
        var shared = 0, sharedWords = 0
        for op in result.ops {
            switch op.kind {
            case .equal:
                for k in op.old where !a[k].isSpace {
                    shared += a[k].weight
                    if a[k].isWord { sharedWords += 1 }
                }
            case .delete: for k in op.old { changedA[k] = true }
            case .insert: for k in op.new { changedB[k] = true }
            }
        }
        let total = a.reduce(0) { $0 + ($1.isSpace ? 0 : $1.weight) } + b.reduce(0) { $0 + ($1.isSpace ? 0 : $1.weight) }
        let similarity = total == 0 ? 0 : Double(2 * shared) / Double(total)
        // Shared punctuation alone (`.`, `(`) is not a relationship, unless neither line has a word at all (`}` → `})`).
        let anyWords = a.contains(where: \.isWord) || b.contains(where: \.isWord)
        guard shared > 0, similarity >= options.minSimilarity, sharedWords > 0 || !anyWords else { return nil }
        return (ranges(a, changedA), ranges(b, changedB), similarity)
    }

    // MARK: - Pairing

    private static func pairBlock(deleted: [Int], added: [Int], lines: [DiffLine], options: Options) -> [Pair] {
        let bagsA = deleted.map { bag(lines[$0].text) }, bagsB = added.map { bag(lines[$0].text) }
        var candidates: [(Int, Int)] = []
        if deleted.count > options.maxAlignedLines || added.count > options.maxAlignedLines {
            for k in 0..<min(deleted.count, added.count) where score(bagsA[k], bagsB[k]) >= options.minSimilarity {
                candidates.append((k, k))
            }
        } else {
            candidates = align(bagsA, bagsB, threshold: options.minSimilarity)
        }
        return candidates.compactMap { d, a in
            guard let h = highlight(old: lines[deleted[d]].text, new: lines[added[a]].text, options: options) else { return nil }
            return Pair(deleted: deleted[d], added: added[a], similarity: h.similarity, oldRanges: h.old, newRanges: h.new)
        }
    }

    /// Order-keeping alignment maximising the summed scores of pairable lines (a weighted LCS).
    private static func align(_ a: [Bag], _ b: [Bag], threshold: Double) -> [(Int, Int)] {
        let n = a.count, m = b.count
        var best = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var scores = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
        for i in 0..<n { for j in 0..<m { scores[i][j] = score(a[i], b[j]) } }
        for i in 1...n {
            for j in 1...m {
                var v = max(best[i - 1][j], best[i][j - 1])
                let s = scores[i - 1][j - 1]
                if s >= threshold { v = max(v, best[i - 1][j - 1] + s) }
                best[i][j] = v
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0, j > 0 {
            let s = scores[i - 1][j - 1]
            if s >= threshold, best[i][j] == best[i - 1][j - 1] + s { pairs.append((i - 1, j - 1)); i -= 1; j -= 1 }
            else if best[i][j] == best[i - 1][j] { i -= 1 }
            else { j -= 1 }
        }
        return pairs.reversed()
    }

    /// Non-space tokens with their character weight, for a fast upper bound on how much two lines share.
    struct Bag { var counts: [Substring: Int]; var weight: Int; var hasWords: Bool }

    static func bag(_ text: String) -> Bag {
        var counts: [Substring: Int] = [:]
        var weight = 0
        var hasWords = false
        for token in tokenize(text) where !token.isSpace {
            counts[token.text, default: 0] += 1
            weight += token.weight
            hasWords = hasWords || token.isWord
        }
        return Bag(counts: counts, weight: weight, hasWords: hasWords)
    }

    static func score(_ a: Bag, _ b: Bag) -> Double {
        guard a.weight + b.weight > 0 else { return 0 }
        var shared = 0, sharedWords = false
        let (small, large) = a.counts.count <= b.counts.count ? (a, b) : (b, a)
        for (token, count) in small.counts {
            if let other = large.counts[token] {
                shared += min(count, other) * token.count
                if !sharedWords, let first = token.first, first == "_" || first.isLetter || first.isNumber { sharedWords = true }
            }
        }
        guard sharedWords || !(a.hasWords || b.hasWords) else { return 0 }
        return Double(2 * shared) / Double(a.weight + b.weight)
    }

    // MARK: - Tokens

    struct Token {
        var text: Substring
        var utf16: Range<Int>
        var isSpace: Bool
        var isWord: Bool { text.first.map { $0 == "_" || $0.isLetter || $0.isNumber } ?? false }
        var weight: Int { text.count }
    }

    /// Words (letters, digits, `_`), runs of whitespace, and every other character on its own, so `a.b(c)` diffs
    /// as `a` `.` `b` `(` `c` `)`.
    static func tokenize(_ s: String) -> [Token] {
        enum Class { case word, space, other }
        func cls(_ c: Character) -> Class {
            if c == "_" || c.isLetter || c.isNumber { return .word }
            if c.isWhitespace { return .space }
            return .other
        }
        var tokens: [Token] = []
        var start = s.startIndex
        var startOffset = 0, offset = 0
        var current: Class?
        var index = s.startIndex
        while index < s.endIndex {
            let c = s[index]
            let k = cls(c)
            if let cur = current, cur != k || k == .other {
                tokens.append(Token(text: s[start..<index], utf16: startOffset..<offset, isSpace: cur == .space))
                start = index; startOffset = offset
            }
            current = k
            offset += c.utf16.count
            index = s.index(after: index)
        }
        if let cur = current {
            tokens.append(Token(text: s[start..<s.endIndex], utf16: startOffset..<offset, isSpace: cur == .space))
        }
        return tokens
    }

    /// Changed tokens as ranges; two ranges with only whitespace between them become one, which reads as one edit.
    private static func ranges(_ tokens: [Token], _ changed: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var lastChanged = -1
        for (k, token) in tokens.enumerated() where changed[k] {
            if let last = out.last, lastChanged >= 0, (lastChanged + 1..<k).allSatisfy({ tokens[$0].isSpace }) {
                out[out.count - 1] = last.lowerBound..<token.utf16.upperBound
            } else {
                out.append(token.utf16)
            }
            lastChanged = k
        }
        return out
    }
}
