import Foundation

/// Rows ready to draw, for the unified view and the split (side-by-side) view, with the "N unchanged lines" fold
/// rows between hunks and the intra-line highlights on paired lines. Both views are made from the same `DiffFile`,
/// so a patch and a two-file compare draw alike.
public enum DiffLayout {
    /// Unchanged lines a hunk does not show: "lines 1–11 unchanged · import Foundation".
    public struct Fold: Sendable, Equatable, Hashable {
        /// 1-based, inclusive ranges in each file.
        public var old: ClosedRange<Int>
        public var new: ClosedRange<Int>
        /// The section heading of the hunk after the fold (git's function context), when it has one.
        public var section: String?
        /// The hunk that follows, or nil for the fold after the last hunk.
        public var hunkIndex: Int?

        public var lineCount: Int { old.count }

        public var label: String {
            let text = old.count == 1 ? String(localized: "line \(old.lowerBound) unchanged", bundle: .module, comment: "Folded region in a diff: one unchanged line; the argument is its number.")
                : String(localized: "lines \(old.lowerBound)–\(old.upperBound) unchanged", bundle: .module, comment: "Folded region in a diff: a range of unchanged lines.")
            return text + (section.map { " · \($0)" } ?? "")
        }
    }

    public enum UnifiedRow: Sendable, Equatable, Hashable {
        case fold(Fold)
        /// One hunk line; `highlights` are changed UTF-16 ranges when the line is half of an intra-line pair.
        case line(hunk: Int, line: Int, highlights: [Range<Int>])
    }

    /// One side of a split row.
    public struct SplitCell: Sendable, Equatable, Hashable {
        public var hunk: Int
        public var line: Int
        public var number: Int?
        public var kind: DiffLine.Kind
        public var highlights: [Range<Int>]
    }

    public enum SplitRow: Sendable, Equatable, Hashable {
        case fold(Fold)
        /// A nil side is a gap (drawn hatched): the other side's line has no counterpart.
        case pair(left: SplitCell?, right: SplitCell?)
    }

    /// The folds before each hunk (nil where the hunk follows on directly) and after the last one when the file's
    /// length is known. Ranges come from the hunk headers, so they hold even for a hunk that arrived short.
    public static func folds(_ file: DiffFile) -> (before: [Fold?], after: Fold?) {
        var before: [Fold?] = []
        var oldEnd = 0, newEnd = 0
        for (k, hunk) in file.hunks.enumerated() {
            let oldStop = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
            let newStop = hunk.newCount == 0 ? hunk.newStart : hunk.newStart - 1
            if oldStop >= oldEnd + 1, newStop >= newEnd + 1 {
                before.append(Fold(old: oldEnd + 1...oldStop, new: newEnd + 1...newStop, section: hunk.section, hunkIndex: k))
            } else {
                before.append(nil)
            }
            oldEnd = max(oldEnd, hunk.declaredOldEnd); newEnd = max(newEnd, hunk.declaredNewEnd)
        }
        var after: Fold?
        if let oldCount = file.oldLineCount, let newCount = file.newLineCount, !file.hunks.isEmpty,
           oldCount > oldEnd, newCount > newEnd {
            after = Fold(old: oldEnd + 1...oldCount, new: newEnd + 1...newCount, section: nil, hunkIndex: nil)
        }
        return (before, after)
    }

    /// Pairs per hunk, keyed by line index, for the views.
    private static func highlightMap(_ file: DiffFile, _ options: Intraline.Options?) -> [[Int: (partner: Int, ranges: [Range<Int>])]] {
        file.hunks.map { hunk in
            var map: [Int: (partner: Int, ranges: [Range<Int>])] = [:]
            guard let options else { return map }
            for pair in Intraline.pairs(in: hunk, options: options) {
                map[pair.deleted] = (pair.added, pair.oldRanges)
                map[pair.added] = (pair.deleted, pair.newRanges)
            }
            return map
        }
    }

    /// Unified rows. Pass nil for `intraline` to skip highlights.
    public static func unified(_ file: DiffFile, intraline: Intraline.Options? = .default) -> [UnifiedRow] {
        let (before, after) = folds(file)
        let maps = highlightMap(file, intraline)
        var rows: [UnifiedRow] = []
        for (k, hunk) in file.hunks.enumerated() {
            if let fold = before[k] { rows.append(.fold(fold)) }
            for i in hunk.lines.indices {
                rows.append(.line(hunk: k, line: i, highlights: maps[k][i]?.ranges ?? []))
            }
        }
        if let after { rows.append(.fold(after)) }
        return rows
    }

    /// Split rows: context on both sides; in each change block, paired lines share a row, the unpaired lines
    /// between pairs fill rows side by side, and whichever side runs out first shows gaps.
    public static func split(_ file: DiffFile, intraline: Intraline.Options? = .default) -> [SplitRow] {
        let (before, after) = folds(file)
        let maps = highlightMap(file, intraline)
        var rows: [SplitRow] = []
        for (k, hunk) in file.hunks.enumerated() {
            if let fold = before[k] { rows.append(.fold(fold)) }
            let lines = hunk.lines
            func cell(_ i: Int) -> SplitCell {
                let line = lines[i]
                return SplitCell(hunk: k, line: i, number: line.kind == .added ? line.newNumber : (line.oldNumber ?? line.newNumber),
                                 kind: line.kind, highlights: maps[k][i]?.ranges ?? [])
            }
            var i = 0
            while i < lines.count {
                if lines[i].kind == .context {
                    let left = SplitCell(hunk: k, line: i, number: lines[i].oldNumber, kind: .context, highlights: [])
                    let right = SplitCell(hunk: k, line: i, number: lines[i].newNumber, kind: .context, highlights: [])
                    rows.append(.pair(left: left, right: right))
                    i += 1
                    continue
                }
                var deleted: [Int] = [], added: [Int] = []
                while i < lines.count, lines[i].kind != .context {
                    if lines[i].kind == .deleted { deleted.append(i) } else { added.append(i) }
                    i += 1
                }
                // Anchors: each paired deleted line with its added partner, in order.
                var anchors: [(Int, Int)] = []
                let addedPosition = Dictionary(uniqueKeysWithValues: added.enumerated().map { ($1, $0) })
                for (d, index) in deleted.enumerated() {
                    if let partner = maps[k][index]?.partner, let a = addedPosition[partner] { anchors.append((d, a)) }
                }
                var di = 0, ai = 0
                for (d, a) in anchors + [(deleted.count, added.count)] {
                    let n = max(d - di, a - ai)
                    for step in 0..<n {
                        let left = di + step < d ? cell(deleted[di + step]) : nil
                        let right = ai + step < a ? cell(added[ai + step]) : nil
                        rows.append(.pair(left: left, right: right))
                    }
                    if d < deleted.count, a < added.count {
                        rows.append(.pair(left: cell(deleted[d]), right: cell(added[a])))
                    }
                    di = d + 1; ai = a + 1
                }
            }
        }
        if let after { rows.append(.fold(after)) }
        return rows
    }
}
