import Foundation

/// The sequence diff under two-file compares and intra-line highlights.
///
/// **Histogram by default, and why.** Myers finds a *shortest* edit script, but on code the shortest script is
/// often not the readable one: it happily matches the frequent lines (`}`, blank lines, `return nil`) and so
/// splits one rewritten function into confetti that interleaves the old and new bodies. Histogram diff (git's
/// `--histogram`, an extension of patience diff) anchors on the *rarest* lines that the two sides share (a
/// function signature, a unique statement), recurses on either side of each anchor, and only falls back to Myers
/// inside a region where nothing is rare. The result keeps moved or rewritten blocks whole and lines up on the
/// lines a reader recognises, which is what a preview is for; on inputs with no repeated lines both algorithms give
/// the same answer. Myers stays available (`.myers`) and is used for tokens inside a line, where minimality is what
/// reads best.
///
/// **Caps.** Work is bounded by a deadline and a size cap. When either runs out, the region still being worked on
/// is emitted as "these old lines were replaced by these new lines" after trimming what the two share at its
/// edges. That is always a *correct* diff (applying it turns old into new), just not a minimal one, and
/// `Result.isSimplified` says so.
public enum LineDiff {
    public enum Algorithm: String, Sendable, Equatable, Codable { case histogram, myers }

    public struct Budget: Sendable, Equatable {
        /// Wall-clock time for the whole diff.
        public var timeLimit: Duration
        /// Elements (both sides together) above which no search is made: only common prefix and suffix are found.
        public var maxElements: Int

        public init(timeLimit: Duration = .seconds(2), maxElements: Int = 4_000_000) {
            self.timeLimit = timeLimit; self.maxElements = maxElements
        }

        public static let `default` = Budget()
    }

    /// One run of the edit script. `old` and `new` are index ranges into the two sequences; for an insertion `old`
    /// is the empty range where it happens, for a deletion `new` is.
    public struct Op: Sendable, Equatable, Hashable {
        public enum Kind: String, Sendable, Equatable, Hashable { case equal, delete, insert }
        public var kind: Kind
        public var old: Range<Int>
        public var new: Range<Int>
        public init(_ kind: Kind, old: Range<Int>, new: Range<Int>) { self.kind = kind; self.old = old; self.new = new }
    }

    public struct Result: Sendable, Equatable {
        /// Ops in order; within one change region the deletion comes before the insertion.
        public var ops: [Op]
        /// A cap was hit and part of the script is a plain replacement rather than a searched one.
        public var isSimplified: Bool

        public var additions: Int { ops.reduce(0) { $0 + ($1.kind == .insert ? $1.new.count : 0) } }
        public var deletions: Int { ops.reduce(0) { $0 + ($1.kind == .delete ? $1.old.count : 0) } }
    }

    /// Diffs two sequences of any hashable element (lines, normalised lines, tokens).
    public static func diff<T: Hashable>(_ a: [T], _ b: [T], algorithm: Algorithm = .histogram,
                                          budget: Budget = .default) -> Result {
        var table: [T: Int] = [:]
        table.reserveCapacity(a.count + b.count)
        func intern(_ x: T) -> Int {
            if let id = table[x] { return id }
            let id = table.count
            table[x] = id
            return id
        }
        let ia = a.map(intern), ib = b.map(intern)
        return diff(ids: ia, ids: ib, idCount: table.count, algorithm: algorithm, budget: budget)
    }

    /// Diffs sequences already interned to dense ids `0..<idCount`.
    static func diff(ids a: [Int], ids b: [Int], idCount: Int, algorithm: Algorithm, budget: Budget,
                     blankA: [Bool]? = nil, blankB: [Bool]? = nil) -> Result {
        var engine = Engine(a: a, b: b, idCount: idCount, budget: budget)
        engine.run(algorithm: algorithm)
        var ops = engine.ops()
        if let blankA, let blankB { ops = compact(ops, a: a, b: b, blankA: blankA, blankB: blankB) }
        return Result(ops: normalize(ops), isSimplified: engine.simplified)
    }

    // MARK: - Engine

    private struct Engine {
        let a: [Int], b: [Int]
        let deadline: ContinuousClock.Instant
        let budget: Budget
        var simplified = false
        private(set) var matches: [(a: Int, b: Int, length: Int)] = []
        // Histogram scratch, reused across regions: per-id occurrence count and first position in A, and a chain
        // of later positions with the same id.
        private var countA: [Int]
        private var firstA: [Int]
        private var nextA: [Int]
        private static let maxChain = 64

        init(a: [Int], b: [Int], idCount: Int, budget: Budget) {
            self.a = a; self.b = b; self.budget = budget
            deadline = ContinuousClock.now.advanced(by: budget.timeLimit)
            countA = [Int](repeating: 0, count: idCount)
            firstA = [Int](repeating: -1, count: idCount)
            nextA = [Int](repeating: -1, count: a.count)
        }

        private enum Task {
            case region(aLo: Int, aHi: Int, bLo: Int, bHi: Int, myers: Bool)
            case match(a: Int, b: Int, length: Int)
        }

        /// An explicit stack, not recursion: a pathological input cannot overflow the thread's stack.
        mutating func run(algorithm: Algorithm) {
            let tooBig = a.count + b.count > budget.maxElements
            var stack: [Task] = [.region(aLo: 0, aHi: a.count, bLo: 0, bHi: b.count, myers: algorithm == .myers)]
            while let task = stack.popLast() {
                switch task {
                case .match(let ai, let bi, let length):
                    if length > 0 { matches.append((ai, bi, length)) }
                case .region(var aLo, var aHi, var bLo, var bHi, let myers):
                    let p0aLo = aLo, p0bLo = bLo
                    while aLo < aHi, bLo < bHi, a[aLo] == b[bLo] { aLo += 1; bLo += 1 }
                    let prefix = aLo - p0aLo
                    var suffix = 0
                    while aHi > aLo, bHi > bLo, a[aHi - 1] == b[bHi - 1] { aHi -= 1; bHi -= 1; suffix += 1 }
                    if suffix > 0 { stack.append(.match(a: aHi, b: bHi, length: suffix)) }
                    if aLo < aHi, bLo < bHi {
                        if tooBig || ContinuousClock.now > deadline {
                            simplified = true                           // replace: nothing to push
                        } else if myers {
                            if let (x, y) = bisect(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi) {
                                stack.append(.region(aLo: x, aHi: aHi, bLo: y, bHi: bHi, myers: true))
                                stack.append(.region(aLo: aLo, aHi: x, bLo: bLo, bHi: y, myers: true))
                            }
                        } else {
                            switch histogramAnchor(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi) {
                            case .anchor(let ai, let bi, let length):
                                stack.append(.region(aLo: ai + length, aHi: aHi, bLo: bi + length, bHi: bHi, myers: false))
                                stack.append(.match(a: ai, b: bi, length: length))
                                stack.append(.region(aLo: aLo, aHi: ai, bLo: bLo, bHi: bi, myers: false))
                            case .onlyFrequent:
                                stack.append(.region(aLo: aLo, aHi: aHi, bLo: bLo, bHi: bHi, myers: true))
                            case .nothingShared:
                                break
                            }
                        }
                    }
                    if prefix > 0 { stack.append(.match(a: p0aLo, b: p0bLo, length: prefix)) }
                }
            }
        }

        private enum Anchor { case anchor(Int, Int, Int), onlyFrequent, nothingShared }

        /// The longest run of shared lines whose rarest line is rarest in A (JGit's histogram rule). Lines that
        /// occur more than `maxChain` times in the region are never anchors.
        private mutating func histogramAnchor(aLo: Int, aHi: Int, bLo: Int, bHi: Int) -> Anchor {
            for i in stride(from: aHi - 1, through: aLo, by: -1) {
                let id = a[i]
                nextA[i] = firstA[id]
                firstA[id] = i
                countA[id] += 1
            }
            defer {
                for i in aLo..<aHi { firstA[a[i]] = -1; countA[a[i]] = 0 }
            }
            var bestA = -1, bestB = -1, bestLength = 0
            var bestCount = Self.maxChain + 1
            var sawShared = false
            var bi = bLo
            while bi < bHi {
                var nextB = bi + 1
                let id = b[bi]
                let count = countA[id]
                if count > 0 {
                    sawShared = true
                    if count <= bestCount {
                        var ai = firstA[id]
                        while ai != -1 {
                            var aStart = ai, bStart = bi, aEnd = ai + 1, bEnd = bi + 1
                            var rarest = count
                            while aStart > aLo, bStart > bLo, a[aStart - 1] == b[bStart - 1] {
                                aStart -= 1; bStart -= 1
                                rarest = min(rarest, countA[a[aStart]])
                            }
                            while aEnd < aHi, bEnd < bHi, a[aEnd] == b[bEnd] {
                                rarest = min(rarest, countA[a[aEnd]])
                                aEnd += 1; bEnd += 1
                            }
                            if aEnd - aStart > bestLength || rarest < bestCount {
                                bestA = aStart; bestB = bStart; bestLength = aEnd - aStart; bestCount = rarest
                            }
                            if nextB < bEnd { nextB = bEnd }
                            var next = nextA[ai]
                            while next != -1, next < aEnd { next = nextA[next] }
                            ai = next
                        }
                    }
                }
                bi = nextB
            }
            if bestLength > 0 { return .anchor(bestA, bestB, bestLength) }
            return sawShared ? .onlyFrequent : .nothingShared
        }

        /// Myers' middle snake (linear space), as in Myers 1986 §4b and Fraser's diff-match-patch: the point where
        /// the forward and reverse D-paths meet, to split the region in two. nil when the deadline passes first or
        /// when the split would not shrink the region; the caller then replaces the region.
        private mutating func bisect(aLo: Int, aHi: Int, bLo: Int, bHi: Int) -> (Int, Int)? {
            let n = aHi - aLo, m = bHi - bLo
            let maxD = (n + m + 1) / 2
            let vOffset = maxD, vLength = 2 * maxD + 2
            var v1 = [Int](repeating: -1, count: vLength), v2 = [Int](repeating: -1, count: vLength)
            v1[vOffset + 1] = 0; v2[vOffset + 1] = 0
            let delta = n - m
            let front = delta % 2 != 0
            var k1start = 0, k1end = 0, k2start = 0, k2end = 0
            for d in 0..<maxD {
                if d & 15 == 0, ContinuousClock.now > deadline { simplified = true; return nil }
                var k1 = -d + k1start
                while k1 <= d - k1end {
                    let k1Offset = vOffset + k1
                    var x1 = k1 == -d || (k1 != d && v1[k1Offset - 1] < v1[k1Offset + 1]) ? v1[k1Offset + 1] : v1[k1Offset - 1] + 1
                    var y1 = x1 - k1
                    while x1 < n, y1 < m, a[aLo + x1] == b[bLo + y1] { x1 += 1; y1 += 1 }
                    v1[k1Offset] = x1
                    if x1 > n { k1end += 2 }
                    else if y1 > m { k1start += 2 }
                    else if front {
                        let k2Offset = vOffset + delta - k1
                        if k2Offset >= 0, k2Offset < vLength, v2[k2Offset] != -1, x1 >= n - v2[k2Offset] {
                            return split(x1, y1, n: n, m: m, aLo: aLo, bLo: bLo)
                        }
                    }
                    k1 += 2
                }
                var k2 = -d + k2start
                while k2 <= d - k2end {
                    let k2Offset = vOffset + k2
                    var x2 = k2 == -d || (k2 != d && v2[k2Offset - 1] < v2[k2Offset + 1]) ? v2[k2Offset + 1] : v2[k2Offset - 1] + 1
                    var y2 = x2 - k2
                    while x2 < n, y2 < m, a[aLo + n - x2 - 1] == b[bLo + m - y2 - 1] { x2 += 1; y2 += 1 }
                    v2[k2Offset] = x2
                    if x2 > n { k2end += 2 }
                    else if y2 > m { k2start += 2 }
                    else if !front {
                        let k1Offset = vOffset + delta - k2
                        if k1Offset >= 0, k1Offset < vLength, v1[k1Offset] != -1 {
                            let x1 = v1[k1Offset]
                            let y1 = vOffset + x1 - k1Offset
                            if x1 >= n - x2 { return split(x1, y1, n: n, m: m, aLo: aLo, bLo: bLo) }
                        }
                    }
                    k2 += 2
                }
            }
            return nil                                   // nothing shared: the region is a replacement
        }

        private func split(_ x: Int, _ y: Int, n: Int, m: Int, aLo: Int, bLo: Int) -> (Int, Int)? {
            guard x >= 0, y >= 0, x <= n, y <= m, !(x == 0 && y == 0), !(x == n && y == m) else { return nil }
            return (aLo + x, bLo + y)
        }

        /// The matches turned into equal / delete / insert runs.
        func ops() -> [Op] {
            var ops: [Op] = []
            var ai = 0, bi = 0
            for match in matches + [(a: a.count, b: b.count, length: 0)] {
                if match.a > ai { ops.append(Op(.delete, old: ai..<match.a, new: bi..<bi)) }
                if match.b > bi { ops.append(Op(.insert, old: match.a..<match.a, new: bi..<match.b)) }
                if match.length > 0 {
                    ops.append(Op(.equal, old: match.a..<match.a + match.length, new: match.b..<match.b + match.length))
                }
                ai = match.a + match.length; bi = match.b + match.length
            }
            return ops
        }
    }

    // MARK: - Readability

    /// Slides each pure insertion or deletion (one bounded by unchanged lines on both sides) to the position a
    /// reader expects, as git's compaction heuristic does: when a block of new lines could sit at several places
    /// because its edges repeat (`}` and blank lines), it is moved down as far as it goes, then up to the lowest
    /// place where it ends with a blank line. "Added a function" then reads as the function and its trailing
    /// blank, not as the previous function's closing brace plus most of the new one.
    static func compact(_ ops: [Op], a: [Int], b: [Int], blankA: [Bool], blankB: [Bool]) -> [Op] {
        var ops = ops
        var k = 1
        while k + 1 < ops.count {
            let before = ops[k - 1], block = ops[k], after = ops[k + 1]
            guard before.kind == .equal, after.kind == .equal, block.kind != .equal else { k += 1; continue }
            let insert = block.kind == .insert
            let seq = insert ? b : a
            let blank = insert ? blankB : blankA
            let r = insert ? block.new : block.old
            var down = 0
            while down < after.old.count, r.upperBound + down < seq.count, seq[r.lowerBound + down] == seq[r.upperBound + down] {
                down += 1
            }
            var up = 0
            while up < before.old.count, r.lowerBound - up - 1 >= 0, seq[r.lowerBound - up - 1] == seq[r.upperBound - up - 1] {
                up += 1
            }
            guard up > 0 || down > 0 else { k += 1; continue }
            var shift = down
            var s = down
            while s >= -up {
                if blank[r.upperBound - 1 + s] { shift = s; break }
                s -= 1
            }
            if shift != 0 {
                ops[k - 1].old = before.old.lowerBound..<before.old.upperBound + shift
                ops[k - 1].new = before.new.lowerBound..<before.new.upperBound + shift
                if insert {
                    ops[k].new = block.new.lowerBound + shift..<block.new.upperBound + shift
                    ops[k].old = block.old.lowerBound + shift..<block.old.upperBound + shift
                } else {
                    ops[k].old = block.old.lowerBound + shift..<block.old.upperBound + shift
                    ops[k].new = block.new.lowerBound + shift..<block.new.upperBound + shift
                }
                ops[k + 1].old = after.old.lowerBound + shift..<after.old.upperBound
                ops[k + 1].new = after.new.lowerBound + shift..<after.new.upperBound
            }
            k += 2
        }
        return ops.filter { !($0.old.isEmpty && $0.new.isEmpty) }
    }

    /// Merges adjacent runs so each change region is one deletion followed by one insertion.
    static func normalize(_ ops: [Op]) -> [Op] {
        var out: [Op] = []
        var i = 0
        while i < ops.count {
            if ops[i].kind == .equal {
                if let last = out.last, last.kind == .equal, last.old.upperBound == ops[i].old.lowerBound {
                    out[out.count - 1].old = last.old.lowerBound..<ops[i].old.upperBound
                    out[out.count - 1].new = last.new.lowerBound..<ops[i].new.upperBound
                } else if !ops[i].old.isEmpty {
                    out.append(ops[i])
                }
                i += 1
                continue
            }
            var oldLo = Int.max, oldHi = Int.min, newLo = Int.max, newHi = Int.min
            while i < ops.count, ops[i].kind != .equal {
                oldLo = min(oldLo, ops[i].old.lowerBound); oldHi = max(oldHi, ops[i].old.upperBound)
                newLo = min(newLo, ops[i].new.lowerBound); newHi = max(newHi, ops[i].new.upperBound)
                i += 1
            }
            if oldHi > oldLo { out.append(Op(.delete, old: oldLo..<oldHi, new: newLo..<newLo)) }
            if newHi > newLo { out.append(Op(.insert, old: oldHi..<oldHi, new: newLo..<newHi)) }
        }
        return out
    }
}
