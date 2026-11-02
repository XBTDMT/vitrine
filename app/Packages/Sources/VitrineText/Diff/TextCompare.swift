import Foundation

/// How a two-file compare treats whitespace and line endings.
public struct CompareOptions: Sendable, Equatable {
    public enum Whitespace: String, Sendable, Equatable, Codable {
        /// Every byte counts.
        case exact
        /// Spaces and tabs at the end of a line are ignored (`git diff --ignore-space-at-eol`).
        case ignoreTrailing
        /// Runs of whitespace compare equal to one space, trailing whitespace is ignored (`diff -b`).
        case ignoreChanges
        /// All whitespace is ignored (`diff -w`).
        case ignoreAll
    }

    public var whitespace: Whitespace
    /// CRLF, LF and a missing final newline compare equal.
    public var ignoreLineEndings: Bool
    public var algorithm: LineDiff.Algorithm
    /// Unchanged lines kept around each change; nil puts the whole file in one hunk (the view folds it).
    public var contextLines: Int?
    public var budget: LineDiff.Budget
    /// Bytes of one line kept for display; the comparison itself always uses the whole line.
    public var maxLineBytes: Int

    public init(whitespace: Whitespace = .exact, ignoreLineEndings: Bool = false,
                algorithm: LineDiff.Algorithm = .histogram, contextLines: Int? = 3,
                budget: LineDiff.Budget = .default, maxLineBytes: Int = 8_192) {
        self.whitespace = whitespace; self.ignoreLineEndings = ignoreLineEndings; self.algorithm = algorithm
        self.contextLines = contextLines.map { max(0, $0) }; self.budget = budget
        self.maxLineBytes = max(16, maxLineBytes)
    }

    public static let `default` = CompareOptions()
}

/// The answer to "what changed between these two files", in the shapes the diff view draws: hunks (as a
/// `DiffFile`, so the patch view's summary, layout and highlights apply unchanged), the "what changed" list, and
/// the calm states for identical and whitespace-only files.
public struct TextComparison: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable, Codable {
        /// Byte for byte the same.
        case identical
        /// The same text once whitespace and line endings are set aside; `whitespace` says what differs.
        case whitespaceOnly
        case different
        /// At least one side has a NUL byte in its first 8,000 bytes (git's rule); no line diff is made.
        case binary
    }

    /// One change region: the "what changed" list's row.
    public struct Change: Sendable, Equatable, Hashable {
        /// 0-based line indices in each file; an empty range sits where the other side's lines go.
        public var old: Range<Int>
        public var new: Range<Int>
        public var additions: Int { new.count }
        public var deletions: Int { old.count }
        /// "Line 5", "Lines 10–11", or "Removed lines 7–9" for a pure deletion.
        public var label: String
        /// The first non-blank changed line, trimmed and cut to 60 characters: a hint at what the change is.
        public var preview: String
    }

    public var status: Status
    public var file: DiffFile
    public var changes: [Change]
    public var whitespace: WhitespaceReport?
    /// A cap was hit; the diff is correct but parts of it are plain replacements.
    public var isSimplified: Bool
    public var oldLineCount: Int
    public var newLineCount: Int
    public var oldLineEnding: LineEndingStyle
    public var newLineEnding: LineEndingStyle
    public var oldSize: Int
    public var newSize: Int
    /// Lines on either side decoded as Latin-1 because they were not UTF-8 (Data input only).
    public var latin1Lines: Int

    public var additions: Int { file.additions }
    public var deletions: Int { file.deletions }
}

/// The line endings a file uses as a whole.
public enum LineEndingStyle: String, Sendable, Equatable, Codable {
    case lf, crlf, mixed
    /// One line, or no line ending at all.
    case none

    public var label: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .mixed: String(localized: "Mixed", bundle: .module, comment: "Line ending style: a file mixes LF and CRLF.")
        case .none: String(localized: "None", bundle: .module, comment: "Line ending style: the file has no line break at all.")
        }
    }
}

/// What differs between two files that are the same text apart from whitespace: the "Same text, different
/// whitespace" state ("412 line endings CRLF → LF · 37 trailing spaces").
public struct WhitespaceReport: Sendable, Equatable, Hashable {
    /// Lines whose terminator changed between CRLF and LF.
    public var lineEndingChanges: Int
    /// The style each side uses, for "CRLF → LF".
    public var oldEnding: LineEndingStyle
    public var newEnding: LineEndingStyle
    /// Lines whose trailing spaces or tabs changed.
    public var trailingWhitespaceChanges: Int
    /// Lines whose indentation or inner spacing changed.
    public var otherWhitespaceChanges: Int
    /// The final newline was added or removed.
    public var finalNewlineChanged: Bool

    /// "412 line endings CRLF → LF · 37 trailing spaces".
    public var summary: String {
        var parts: [String] = []
        if lineEndingChanges > 0 {
            parts.append(lineEndingChanges == 1
                ? String(localized: "1 line ending \(oldEnding.label) → \(newEnding.label)", bundle: .module, comment: "Whitespace summary part: one line's ending changed, for example CRLF → LF.")
                : String(localized: "\(lineEndingChanges.formatted()) line endings \(oldEnding.label) → \(newEnding.label)", bundle: .module, comment: "Whitespace summary part: how many line endings changed, for example 412 line endings CRLF → LF."))
        }
        if trailingWhitespaceChanges > 0 {
            parts.append(trailingWhitespaceChanges == 1 ? String(localized: "1 trailing space", bundle: .module, comment: "Whitespace summary part: one line's trailing spaces changed.")
                : String(localized: "\(trailingWhitespaceChanges.formatted()) trailing spaces", bundle: .module, comment: "Whitespace summary part: how many lines' trailing spaces changed."))
        }
        if otherWhitespaceChanges > 0 {
            parts.append(otherWhitespaceChanges == 1 ? String(localized: "1 line with spacing changes", bundle: .module, comment: "Whitespace summary part: one line's indentation or inner spacing changed.")
                : String(localized: "\(otherWhitespaceChanges.formatted()) lines with spacing changes", bundle: .module, comment: "Whitespace summary part: how many lines' indentation or inner spacing changed."))
        }
        if finalNewlineChanged { parts.append(String(localized: "final newline", bundle: .module, comment: "Whitespace summary part: the newline at the end of the file was added or removed.")) }
        return parts.joined(separator: " · ")
    }
}

/// Two-file comparison.
public enum TextCompare {
    /// Compares two texts. Equality is by UTF-8 bytes, never by Swift's canonical equivalence, so a precomposed
    /// "é" and a decomposed one are a change, as they are on disk.
    public static func compare(old: String, new: String, oldName: String = "old", newName: String = "new",
                               options: CompareOptions = .default) -> TextComparison {
        compare(oldBytes: Array(old.utf8), newBytes: Array(new.utf8), oldName: oldName, newName: newName,
                options: options, sniffBinary: false)
    }

    /// Compares two files' bytes: binary when either has a NUL in its first 8,000 bytes; text lines are UTF-8 when
    /// valid and Latin-1 otherwise.
    public static func compare(old: Data, new: Data, oldName: String = "old", newName: String = "new",
                               options: CompareOptions = .default) -> TextComparison {
        compare(oldBytes: [UInt8](old), newBytes: [UInt8](new), oldName: oldName, newName: newName,
                options: options, sniffBinary: true)
    }

    static func isBinary(_ bytes: [UInt8]) -> Bool { bytes.prefix(8_000).contains(0) }

    private static func compare(oldBytes: [UInt8], newBytes: [UInt8], oldName: String, newName: String,
                                options: CompareOptions, sniffBinary: Bool) -> TextComparison {
        let identical = oldBytes == newBytes
        if sniffBinary, isBinary(oldBytes) || isBinary(newBytes) {
            var file = DiffFile(oldPath: oldName, newPath: newName, binary: DiffBinary(source: .marker, newSize: newBytes.count, oldSize: oldBytes.count))
            if identical { file.binary = nil }
            return TextComparison(status: identical ? .identical : .binary, file: file, changes: [], whitespace: nil,
                                  isSimplified: false, oldLineCount: 0, newLineCount: 0, oldLineEnding: .none,
                                  newLineEnding: .none, oldSize: oldBytes.count, newSize: newBytes.count, latin1Lines: 0)
        }
        let oldLines = PatchLines(bytes: oldBytes), newLines = PatchLines(bytes: newBytes)
        let oldSide = Side(oldLines), newSide = Side(newLines)
        var file = DiffFile(oldPath: oldName, newPath: newName, oldLineCount: oldLines.count, newLineCount: newLines.count)
        var result = TextComparison(status: identical ? .identical : .different, file: file, changes: [],
                                    whitespace: nil, isSimplified: false, oldLineCount: oldLines.count,
                                    newLineCount: newLines.count, oldLineEnding: oldSide.style,
                                    newLineEnding: newSide.style, oldSize: oldBytes.count, newSize: newBytes.count,
                                    latin1Lines: 0)
        if identical { return result }

        result.whitespace = whitespaceReport(oldSide, newSide)
        if result.whitespace != nil { result.status = .whitespaceOnly }

        // Intern normalised lines to dense ids shared by both sides.
        var table: [[UInt8]: Int] = [:]
        table.reserveCapacity(oldLines.count + newLines.count)
        func ids(_ side: Side) -> [Int] {
            (0..<side.lines.count).map { i in
                let key = side.key(i, options)
                if let id = table[key] { return id }
                let id = table.count
                table[key] = id
                return id
            }
        }
        let a = ids(oldSide), b = ids(newSide)
        let diff = LineDiff.diff(ids: a, ids: b, idCount: table.count, algorithm: options.algorithm,
                                 budget: options.budget, blankA: oldSide.blanks(), blankB: newSide.blanks())
        result.isSimplified = diff.isSimplified

        func line(_ side: Side, _ i: Int) -> (String, Bool) {
            let t = side.lines.text(i, maxBytes: options.maxLineBytes)
            return (t.text, t.truncated)
        }
        file.hunks = hunks(diff.ops, old: oldSide, new: newSide, context: options.contextLines, text: line)
        file.additions = diff.additions
        file.deletions = diff.deletions
        file.hunkCount = file.hunks.count
        result.file = file
        result.latin1Lines = oldSide.latin1Lines + newSide.latin1Lines
        result.changes = changes(diff.ops, new: newSide, old: oldSide, text: line)
        return result
    }

    // MARK: - Lines

    /// One file's lines with the views a comparison needs.
    struct Side {
        let lines: PatchLines
        let bytesEndWithNewline: Bool

        init(_ lines: PatchLines) {
            self.lines = lines
            bytesEndWithNewline = lines.bytes.last == 0x0A
        }

        /// Lines that are not valid UTF-8 (shown as Latin-1). One validation pass when the whole file is valid.
        var latin1Lines: Int {
            if String(validating: lines.bytes, as: UTF8.self) != nil { return 0 }
            return (0..<lines.count).reduce(0) { n, i in
                n + (String(validating: lines.bytes[lines.starts[i]..<lines.ends[i]], as: UTF8.self) == nil ? 1 : 0)
            }
        }

        func ending(_ i: Int) -> DiffLineEnding {
            if i == lines.count - 1, !bytesEndWithNewline { return .none }
            return lines.crlf[i] ? .crlf : .lf
        }

        var style: LineEndingStyle {
            var lf = 0, crlf = 0
            for i in 0..<lines.count {
                switch ending(i) {
                case .lf: lf += 1
                case .crlf: crlf += 1
                case .none: break
                }
            }
            if lf > 0 && crlf > 0 { return .mixed }
            return crlf > 0 ? .crlf : lf > 0 ? .lf : .none
        }

        static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0B || b == 0x0C }

        /// The bytes a line compares by under the options, with a terminator tag unless endings are ignored.
        func key(_ i: Int, _ options: CompareOptions) -> [UInt8] {
            let s = lines.starts[i], e = lines.ends[i]
            var key: [UInt8]
            switch options.whitespace {
            case .exact:
                key = Array(lines.bytes[s..<e])
            case .ignoreTrailing:
                var end = e
                while end > s, Self.isSpace(lines.bytes[end - 1]) { end -= 1 }
                key = Array(lines.bytes[s..<end])
            case .ignoreChanges:
                key = []
                var inSpace = false
                for k in s..<e {
                    let b = lines.bytes[k]
                    if Self.isSpace(b) || b == 0x0D { inSpace = true; continue }
                    if inSpace { key.append(0x20) }                // a run (leading too) is one space; trailing is dropped
                    inSpace = false
                    key.append(b)
                }
            case .ignoreAll:
                key = lines.bytes[s..<e].filter { !Self.isSpace($0) && $0 != 0x0D }
            }
            if !options.ignoreLineEndings {
                key.append(0xFF)                                   // never valid UTF-8, so never content
                switch ending(i) {
                case .lf: key.append(0)
                case .crlf: key.append(1)
                case .none: key.append(2)
                }
            }
            return key
        }

        func blanks() -> [Bool] {
            (0..<lines.count).map { i in
                (lines.starts[i]..<lines.ends[i]).allSatisfy { Self.isSpace(lines.bytes[$0]) || lines.bytes[$0] == 0x0D }
            }
        }
    }

    /// Non-nil when the two sides have the same lines once all whitespace and line endings are set aside.
    static func whitespaceReport(_ old: Side, _ new: Side) -> WhitespaceReport? {
        guard old.lines.count == new.lines.count else { return nil }
        let loose = CompareOptions(whitespace: .ignoreAll, ignoreLineEndings: true)
        let trailing = CompareOptions(whitespace: .ignoreTrailing, ignoreLineEndings: true)
        var report = WhitespaceReport(lineEndingChanges: 0, oldEnding: old.style, newEnding: new.style,
                                      trailingWhitespaceChanges: 0, otherWhitespaceChanges: 0, finalNewlineChanged: false)
        for i in 0..<old.lines.count {
            guard old.key(i, loose) == new.key(i, loose) else { return nil }
            let eo = old.ending(i), en = new.ending(i)
            if eo != en {
                if eo == .none || en == .none { report.finalNewlineChanged = true } else { report.lineEndingChanges += 1 }
            }
            let so = old.lines.bytes[old.lines.starts[i]..<old.lines.ends[i]]
            let sn = new.lines.bytes[new.lines.starts[i]..<new.lines.ends[i]]
            guard !so.elementsEqual(sn) else { continue }
            if old.key(i, trailing) == new.key(i, trailing) { report.trailingWhitespaceChanges += 1 }
            else { report.otherWhitespaceChanges += 1 }
        }
        return report
    }

    // MARK: - Hunks

    /// Hunks in `diff -u` form: change regions with `context` unchanged lines around them, merged when their
    /// context would touch. Numbers follow `diff -u`: an empty side's start is the line before the gap. Context
    /// lines carry the new file's text, which differs from the old only when whitespace options are on.
    static func hunks(_ ops: [LineDiff.Op], old: Side, new: Side, context: Int?,
                      text: (Side, Int) -> (String, Bool)) -> [DiffHunk] {
        guard ops.contains(where: { $0.kind != .equal }) else { return [] }
        let ctx = context ?? Int.max / 4
        let spans = regions(ops)
        var groups: [[(old: Range<Int>, new: Range<Int>)]] = []
        for span in spans {
            if let last = groups.last?.last, span.old.lowerBound - last.old.upperBound <= 2 * ctx {
                groups[groups.count - 1].append(span)
            } else {
                groups.append([span])
            }
        }
        var result: [DiffHunk] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let lead = min(ctx, first.old.lowerBound, first.new.lowerBound)
            let trail = min(ctx, old.lines.count - last.old.upperBound, new.lines.count - last.new.upperBound)
            var o = first.old.lowerBound - lead, n = first.new.lowerBound - lead
            var lines: [DiffLine] = []
            func context(_ count: Int) {
                for _ in 0..<count {
                    let (t, cut) = text(new, n)
                    lines.append(DiffLine(kind: .context, text: t, oldNumber: o + 1, newNumber: n + 1,
                                          ending: new.ending(n), isTruncated: cut))
                    o += 1; n += 1
                }
            }
            context(lead)
            for span in group {
                context(span.old.lowerBound - o)
                for i in span.old {
                    let (t, cut) = text(old, i)
                    lines.append(DiffLine(kind: .deleted, text: t, oldNumber: i + 1, newNumber: nil,
                                          ending: old.ending(i), isTruncated: cut))
                }
                for j in span.new {
                    let (t, cut) = text(new, j)
                    lines.append(DiffLine(kind: .added, text: t, oldNumber: nil, newNumber: j + 1,
                                          ending: new.ending(j), isTruncated: cut))
                }
                o = span.old.upperBound; n = span.new.upperBound
            }
            context(trail)
            let oldStart = first.old.lowerBound - lead, newStart = first.new.lowerBound - lead
            let oldCount = o - oldStart, newCount = n - newStart
            result.append(DiffHunk(oldStart: oldCount == 0 ? oldStart : oldStart + 1, oldCount: oldCount,
                                   newStart: newCount == 0 ? newStart : newStart + 1, newCount: newCount, lines: lines))
        }
        return result
    }

    /// Change regions as old/new spans: after `LineDiff.normalize`, a deletion directly followed by an insertion
    /// is one replacement.
    static func regions(_ ops: [LineDiff.Op]) -> [(old: Range<Int>, new: Range<Int>)] {
        var spans: [(old: Range<Int>, new: Range<Int>)] = []
        var k = 0
        while k < ops.count {
            switch ops[k].kind {
            case .equal:
                k += 1
            case .delete:
                if k + 1 < ops.count, ops[k + 1].kind == .insert {
                    spans.append((ops[k].old, ops[k + 1].new)); k += 2
                } else {
                    spans.append((ops[k].old, ops[k].new)); k += 1
                }
            case .insert:
                spans.append((ops[k].old, ops[k].new)); k += 1
            }
        }
        return spans
    }

    static func changes(_ ops: [LineDiff.Op], new: Side, old: Side, text: (Side, Int) -> (String, Bool)) -> [TextComparison.Change] {
        var out: [TextComparison.Change] = []
        for (o, n) in regions(ops) {
            let label: String
            if n.isEmpty {
                label = o.count == 1 ? String(localized: "Removed line \(o.lowerBound + 1)", bundle: .module, comment: "Label of a change: one line removed; the argument is its line number.")
                    : String(localized: "Removed lines \(o.lowerBound + 1)–\(o.upperBound)", bundle: .module, comment: "Label of a change: a range of removed lines.")
            } else {
                label = n.count == 1 ? String(localized: "Line \(n.lowerBound + 1)", bundle: .module, comment: "Label of a change at one line; the argument is its line number.")
                    : String(localized: "Lines \(n.lowerBound + 1)–\(n.upperBound)", bundle: .module, comment: "Label of a change over a range of lines.")
            }
            var preview = ""
            for (side, range) in [(new, n), (old, o)] where preview.isEmpty {
                for i in range.prefix(20) {
                    let t = text(side, i).0.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { preview = t.count > 60 ? String(t.prefix(59)) + "…" : t; break }
                }
            }
            out.append(.init(old: o, new: n, label: label, preview: preview))
        }
        return out
    }
}
