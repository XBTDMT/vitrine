import Foundation
import VitrineText

/// Which of the two inputs a finding or an error belongs to. roadmap: S-7
public enum CompareSide: String, Sendable, Equatable, Hashable, Codable {
    case old, new
}

/// A compare could not start because one side is unreadable: which side, why, and where when the reader knows.
/// Every compare engine throws this one type so the page can say "the new file is not valid JSON (line 4, column
/// 9): …" the same way for each. roadmap: S-7
public struct CompareError: Error, Sendable, Equatable, Codable, CustomStringConvertible {
    public enum Kind: String, Sendable, Equatable, Codable {
        /// The bytes are not valid in the format (the parser's own message is in `reason`).
        case malformed
        /// The format is one this engine does not compare (`reason` says which and what to use instead).
        case unsupported
        /// The input is larger than the engine's limits allow.
        case tooLarge
    }

    public var kind: Kind
    /// nil when the problem is not one side's (an unsupported format for both).
    public var side: CompareSide?
    public var reason: String
    /// 1-based, when the reader knows them.
    public var line: Int?
    public var column: Int?

    public init(_ kind: Kind, side: CompareSide?, reason: String, line: Int? = nil, column: Int? = nil) {
        self.kind = kind; self.side = side; self.reason = reason; self.line = line; self.column = column
    }

    public var description: String {
        let place: String? = line.map { line in
            column.map { String(localized: "line \(line), column \($0)", bundle: .module, comment: "Where a compare error is in a file.") }
                ?? String(localized: "line \(line)", bundle: .module, comment: "Where a compare error is in a file.")
        }
        switch (side, place) {
        case (.old?, let place?): return String(localized: "The old file: \(reason) (\(place))", bundle: .module, comment: "Why a compare cannot start; the arguments are the reason and where it is, such as line 4, column 9.")
        case (.old?, nil): return String(localized: "The old file: \(reason)", bundle: .module, comment: "Why a compare cannot start; the argument is the reason.")
        case (.new?, let place?): return String(localized: "The new file: \(reason) (\(place))", bundle: .module, comment: "Why a compare cannot start; the arguments are the reason and where it is, such as line 4, column 9.")
        case (.new?, nil): return String(localized: "The new file: \(reason)", bundle: .module, comment: "Why a compare cannot start; the argument is the reason.")
        case (nil, let place?): return String(localized: "\(reason) (\(place))", bundle: .module, comment: "Why a compare cannot start, then where in the file, such as line 4, column 9.")
        case (nil, nil): return reason
        }
    }
}

/// An ordered alignment of two sequences: equal elements by a diff of their keys, then, inside each changed region,
/// the elements that are edits of each other paired by similarity (order kept on both sides, total similarity
/// maximised), and the rest left as deleted or inserted. Prose blocks, notebook cells and array elements all use it.
/// roadmap: S-7
enum Alignment {
    enum Step: Equatable {
        /// Same key on both sides.
        case equal(Int, Int)
        /// Different keys, similar enough to be one element edited.
        case paired(Int, Int)
        case deleted(Int)
        case inserted(Int)
    }

    /// - Parameters:
    ///   - similarity: 0…1 for an old and a new index; only called inside changed regions.
    ///   - threshold: pairs below it are never made.
    ///   - maxRegion: a region larger than this on either side is paired by position (when similar enough) instead
    ///     of searched, so a pathological input costs O(n) rather than O(n²).
    static func align<K: Hashable>(_ oldKeys: [K], _ newKeys: [K], threshold: Double, maxRegion: Int = 64,
                                   budget: LineDiff.Budget = .init(timeLimit: .milliseconds(500), maxElements: 400_000),
                                   similarity: (Int, Int) -> Double) -> [Step] {
        let diff = LineDiff.diff(oldKeys, newKeys, algorithm: .histogram, budget: budget)
        var steps: [Step] = []
        var deleted: [Int] = [], inserted: [Int] = []
        func flush() {
            if !deleted.isEmpty || !inserted.isEmpty {
                steps += pairRegion(deleted, inserted, threshold: threshold, maxRegion: maxRegion, similarity: similarity)
            }
            deleted.removeAll(); inserted.removeAll()
        }
        for op in diff.ops {
            switch op.kind {
            case .equal:
                flush()
                for (i, j) in zip(op.old, op.new) { steps.append(.equal(i, j)) }
            case .delete: deleted += Array(op.old)
            case .insert: inserted += Array(op.new)
            }
        }
        flush()
        return steps
    }

    /// Pairs one changed region. Unpaired deletions come before unpaired insertions between two pairs, the order a
    /// tracked-changes reading expects.
    static func pairRegion(_ deleted: [Int], _ inserted: [Int], threshold: Double, maxRegion: Int,
                           similarity: (Int, Int) -> Double) -> [Step] {
        guard !deleted.isEmpty, !inserted.isEmpty else {
            return deleted.map { .deleted($0) } + inserted.map { .inserted($0) }
        }
        var pairs: [(Int, Int)] = []
        if deleted.count > maxRegion || inserted.count > maxRegion {
            for k in 0..<min(deleted.count, inserted.count) where similarity(deleted[k], inserted[k]) >= threshold {
                pairs.append((k, k))
            }
        } else {
            // Weighted LCS: best[i][j] is the best total similarity of deleted[i...] against inserted[j...].
            let n = deleted.count, m = inserted.count
            var sim = [[Double]](repeating: [Double](repeating: 0, count: m), count: n)
            for i in 0..<n { for j in 0..<m { sim[i][j] = similarity(deleted[i], inserted[j]) } }
            var best = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    var value = max(best[i + 1][j], best[i][j + 1])
                    if sim[i][j] >= threshold { value = max(value, sim[i][j] + best[i + 1][j + 1]) }
                    best[i][j] = value
                }
            }
            var i = 0, j = 0
            while i < n, j < m {
                if sim[i][j] >= threshold, best[i][j] == sim[i][j] + best[i + 1][j + 1] {
                    pairs.append((i, j)); i += 1; j += 1
                } else if best[i][j] == best[i + 1][j] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        var steps: [Step] = []
        var i = 0, j = 0
        for (pi, pj) in pairs {
            while i < pi { steps.append(.deleted(deleted[i])); i += 1 }
            while j < pj { steps.append(.inserted(inserted[j])); j += 1 }
            steps.append(.paired(deleted[pi], inserted[pj])); i += 1; j += 1
        }
        while i < deleted.count { steps.append(.deleted(deleted[i])); i += 1 }
        while j < inserted.count { steps.append(.inserted(inserted[j])); j += 1 }
        return steps
    }
}

/// Words, spaces and punctuation as separate tokens, the unit of the prose word diff and of block similarity.
/// roadmap: S-7
struct WordToken: Hashable {
    enum Kind: Hashable { case word, space, punctuation }
    var text: String
    var kind: Kind

    static func tokenize(_ text: String) -> [WordToken] {
        var out: [WordToken] = []
        var current = ""
        var currentKind: Kind?
        func flush() {
            if let kind = currentKind, !current.isEmpty { out.append(WordToken(text: current, kind: kind)) }
            current = ""; currentKind = nil
        }
        for ch in text {
            let kind: Kind = ch.isWhitespace ? .space : (ch.isLetter || ch.isNumber || ch == "_" || ch == "'" || ch == "’") ? .word : .punctuation
            if kind == .punctuation {
                flush()
                out.append(WordToken(text: String(ch), kind: .punctuation))
            } else if kind == currentKind {
                current.append(ch)
            } else {
                flush()
                currentKind = kind; current = String(ch)
            }
        }
        flush()
        return out
    }

    /// Dice similarity of two token multisets, counting words and punctuation, not spaces (0…1).
    static func similarity(_ a: [WordToken], _ b: [WordToken]) -> Double {
        var counts: [String: Int] = [:]
        var totalA = 0, totalB = 0, shared = 0
        for t in a where t.kind != .space { counts[t.text.lowercased(), default: 0] += 1; totalA += 1 }
        for t in b where t.kind != .space {
            totalB += 1
            let key = t.text.lowercased()
            if let c = counts[key], c > 0 { counts[key] = c - 1; shared += 1 }
        }
        guard totalA + totalB > 0 else { return 1 }
        return Double(2 * shared) / Double(totalA + totalB)
    }
}

/// Small text helpers shared by the engines. roadmap: S-7
enum CompareText {
    /// Cuts `text` to `limit` characters, ending in "…" when it was cut.
    static func truncate(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }

    /// A JSON string literal.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// A wall-clock budget checked every few steps. roadmap: S-7
struct Deadline {
    let end: ContinuousClock.Instant
    let limit: Duration
    init(_ limit: Duration) { self.limit = limit; end = .now + limit }
    var passed: Bool { ContinuousClock.now >= end }
}
