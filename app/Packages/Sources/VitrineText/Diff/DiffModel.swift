import Foundation

// The diff family's value types (roadmap S-7). A `.patch` file and a two-file compare both end up as `DiffFile`s
// made of `DiffHunk`s made of `DiffLine`s, so the summary, the split layout, the intra-line highlights and the facts
// are written once and serve both. Everything here is a plain `Sendable` value: parsing happens off the main
// thread and the result crosses to the view unchanged.

/// How a line ended in its file. A diff that drops the terminator from the text still has to say whether the line
/// had one, because "no newline at end of file" and CRLF → LF are real, visible changes.
public enum DiffLineEnding: String, Sendable, Equatable, Hashable, Codable {
    case lf
    case crlf
    /// The last line of a file that ends without a newline (`\ No newline at end of file` in a patch).
    case none
}

/// One line of a hunk, without its `+`/`-`/space prefix and without its terminator.
public struct DiffLine: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable, Codable {
        case context, added, deleted
    }

    public var kind: Kind
    public var text: String
    /// 1-based line number in the old file; nil for added lines (and for every line of a combined diff, which has
    /// several old files).
    public var oldNumber: Int?
    /// 1-based line number in the new file; nil for deleted lines.
    public var newNumber: Int?
    public var ending: DiffLineEnding
    /// The text was cut at `PatchLimits.maxLineBytes` (or the compare's equivalent); the view says so.
    public var isTruncated: Bool
    /// For a combined diff (`diff --cc`), the per-parent marker columns exactly as written (`"+ "`, `" -"`); nil
    /// for ordinary diffs.
    public var combinedMarkers: String?

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?, ending: DiffLineEnding = .lf,
                isTruncated: Bool = false, combinedMarkers: String? = nil) {
        self.kind = kind; self.text = text; self.oldNumber = oldNumber; self.newNumber = newNumber
        self.ending = ending; self.isTruncated = isTruncated; self.combinedMarkers = combinedMarkers
    }
}

/// One `@@ -a,b +c,d @@ section` block. The declared ranges are kept as written, because the view's
/// "lines 1–11 unchanged" fold rows and the malformed-patch message ("the hunk header says 12 lines; 9 arrived")
/// both need what the header claimed, not only what arrived.
public struct DiffHunk: Sendable, Equatable, Hashable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// The text after the closing `@@`: usually the enclosing function or type (`extension SyncQueue {`).
    public var section: String?
    public var lines: [DiffLine]
    /// For a combined diff, every parent's declared range in order; empty otherwise.
    public var parentRanges: [ClosedRangeCount]
    /// Fewer lines arrived than the header declared (cut-off or hand-edited patch).
    public var isShort: Bool
    /// More hunk-looking lines followed than the header declared; they were kept and flagged.
    public var isLong: Bool

    /// A declared `start,count` pair, kept as written (count 0 means "nothing on this side").
    public struct ClosedRangeCount: Sendable, Equatable, Hashable {
        public var start: Int
        public var count: Int
        public init(start: Int, count: Int) { self.start = start; self.count = count }
    }

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String? = nil,
                lines: [DiffLine] = [], parentRanges: [ClosedRangeCount] = [], isShort: Bool = false,
                isLong: Bool = false) {
        self.oldStart = oldStart; self.oldCount = oldCount; self.newStart = newStart; self.newCount = newCount
        self.section = section; self.lines = lines; self.parentRanges = parentRanges
        self.isShort = isShort; self.isLong = isLong
    }

    public var additions: Int { lines.reduce(0) { $0 + ($1.kind == .added ? 1 : 0) } }
    public var deletions: Int { lines.reduce(0) { $0 + ($1.kind == .deleted ? 1 : 0) } }

    /// The header as git writes it, rebuilt from the parsed numbers (a single-line range drops its `,1`).
    public var header: String {
        func range(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
        if !parentRanges.isEmpty {
            let marks = String(repeating: "@", count: parentRanges.count + 1)
            let olds = parentRanges.map { "-" + range($0.start, $0.count) }.joined(separator: " ")
            return "\(marks) \(olds) +\(range(newStart, newCount)) \(marks)" + (section.map { " " + $0 } ?? "")
        }
        return "@@ -\(range(oldStart, oldCount)) +\(range(newStart, newCount)) @@" + (section.map { " " + $0 } ?? "")
    }

    /// The last old line the header covers (for a pure insertion, the line the new lines follow).
    var declaredOldEnd: Int { oldCount == 0 ? oldStart : oldStart + oldCount - 1 }
    var declaredNewEnd: Int { newCount == 0 ? newStart : newStart + newCount - 1 }
}

/// A git file mode (`100644`, `100755`, `120000`, `160000`), parsed from untrusted octal text.
public struct DiffFileMode: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable, Codable {
        case regular, executable, symlink, submodule, directory, other
    }

    public var rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Parses octal digits only, at most seven of them, so `"100755"` works and `"9z"` or a 40-digit run do not.
    public init?(octal text: some StringProtocol) {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.count <= 7, let value = UInt32(digits, radix: 8) else { return nil }
        rawValue = value
    }

    public var kind: Kind {
        switch rawValue & 0o170000 {
        case 0o120000: return .symlink
        case 0o160000: return .submodule
        case 0o040000: return .directory
        case 0o100000: return rawValue & 0o111 != 0 ? .executable : .regular
        default: return .other
        }
    }

    public var isExecutable: Bool { kind == .executable }
    public var octal: String { String(rawValue, radix: 8) }
}

/// What a patch says about a binary file. The data itself is never decoded: the preview shows that it changed and
/// the sizes git recorded, nothing more.
public struct DiffBinary: Sendable, Equatable, Hashable {
    public enum Source: String, Sendable, Equatable, Hashable, Codable {
        /// `Binary files a/x and b/x differ`: git or diff without `--binary`.
        case marker
        /// `GIT binary patch` with base-85 literal or delta blocks.
        case gitBinaryPatch
    }

    public enum Method: String, Sendable, Equatable, Hashable, Codable { case literal, delta }

    public var source: Source
    /// The new file's size, when the forward block is a literal (`literal 4567`); a delta block records only the
    /// delta's size, so the new size is unknown.
    public var newSize: Int?
    /// The old file's size, from a literal reverse block.
    public var oldSize: Int?
    public var forward: Method?
    public var reverse: Method?

    public init(source: Source, newSize: Int? = nil, oldSize: Int? = nil, forward: Method? = nil,
                reverse: Method? = nil) {
        self.source = source; self.newSize = newSize; self.oldSize = oldSize
        self.forward = forward; self.reverse = reverse
    }
}

/// The one-word kind of a file's change, the letter tile in the files list (`.ck.m/.a/.d/.r/.b`). A file can be
/// renamed and edited and made executable at once; `kind` names the most informative one and the other facts stay
/// on `DiffFile` (`isRenamed`, `isModeChange`, counts).
public enum DiffChangeKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case added, deleted, renamed, copied, binary, modeChanged, modified

    /// The tile letter. Mode-only changes use `M`, as `git diff --name-status` does.
    public var letter: String {
        switch self {
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .binary: "B"
        case .modeChanged, .modified: "M"
        }
    }

    /// The past-tense word the lead sentence uses: "2 edited, 1 renamed".
    public var verb: String {
        switch self {
        case .added: String(localized: "added", bundle: .module, comment: "Kind of change to a file in a patch.")
        case .deleted: String(localized: "deleted", bundle: .module, comment: "Kind of change to a file in a patch.")
        case .renamed: String(localized: "renamed", bundle: .module, comment: "Kind of change to a file in a patch.")
        case .copied: String(localized: "copied", bundle: .module, comment: "Kind of change to a file in a patch.")
        case .binary: String(localized: "binary", bundle: .module, comment: "Kind of change to a file in a patch: a binary file changed.")
        case .modeChanged: String(localized: "mode changed", bundle: .module, comment: "Kind of change to a file in a patch: its permissions changed.")
        case .modified: String(localized: "edited", bundle: .module, comment: "Kind of change to a file in a patch.")
        }
    }
}

/// One file in a patch or a compare.
public struct DiffFile: Sendable, Equatable, Hashable {
    /// The old path without git's `a/` prefix; nil when the file is new (`/dev/null`).
    public var oldPath: String?
    /// The new path without `b/`; nil when the file was deleted.
    public var newPath: String?
    public var oldMode: DiffFileMode?
    public var newMode: DiffFileMode?
    public var isNewFile: Bool
    public var isDeletedFile: Bool
    public var isRenamed: Bool
    public var isCopied: Bool
    /// `similarity index 91%` for a rename or copy.
    public var similarity: Int?
    /// `dissimilarity index N%` for a rewrite.
    public var dissimilarity: Int?
    /// Abbreviated blob ids from the `index` line.
    public var oldIndex: String?
    public var newIndex: String?
    public var binary: DiffBinary?
    public var hunks: [DiffHunk]
    /// Lines added and removed. Counted for every file, including files past the detail cap whose `hunks` were not
    /// kept, so the lead's totals are right on a huge patch.
    public var additions: Int
    public var deletions: Int
    /// Hunks in the file, kept or not.
    public var hunkCount: Int
    /// Past the detail caps: counts are exact but `hunks` holds only what fit (possibly nothing).
    public var isDetailOmitted: Bool
    /// `diff --cc` / `diff --combined`: a merge shown against several parents.
    public var isCombined: Bool
    public var parentCount: Int
    /// The commit this file belongs to (index into `Patch.commits`), for a format-patch series or `git log -p`.
    public var commitIndex: Int?
    /// 1-based line in the patch where this file's header starts (0 for a compare).
    public var patchLine: Int
    /// Total lines on each side when known (a two-file compare); nil for a patch, which shows only hunks.
    public var oldLineCount: Int?
    public var newLineCount: Int?

    public init(oldPath: String?, newPath: String?, oldMode: DiffFileMode? = nil, newMode: DiffFileMode? = nil,
                isNewFile: Bool = false, isDeletedFile: Bool = false, isRenamed: Bool = false, isCopied: Bool = false,
                similarity: Int? = nil, dissimilarity: Int? = nil, oldIndex: String? = nil, newIndex: String? = nil,
                binary: DiffBinary? = nil, hunks: [DiffHunk] = [], additions: Int? = nil, deletions: Int? = nil,
                hunkCount: Int? = nil, isDetailOmitted: Bool = false, isCombined: Bool = false, parentCount: Int = 1,
                commitIndex: Int? = nil, patchLine: Int = 0, oldLineCount: Int? = nil, newLineCount: Int? = nil) {
        self.oldPath = oldPath; self.newPath = newPath; self.oldMode = oldMode; self.newMode = newMode
        self.isNewFile = isNewFile; self.isDeletedFile = isDeletedFile; self.isRenamed = isRenamed
        self.isCopied = isCopied; self.similarity = similarity; self.dissimilarity = dissimilarity
        self.oldIndex = oldIndex; self.newIndex = newIndex; self.binary = binary; self.hunks = hunks
        self.additions = additions ?? hunks.reduce(0) { $0 + $1.additions }
        self.deletions = deletions ?? hunks.reduce(0) { $0 + $1.deletions }
        self.hunkCount = hunkCount ?? hunks.count
        self.isDetailOmitted = isDetailOmitted; self.isCombined = isCombined; self.parentCount = parentCount
        self.commitIndex = commitIndex; self.patchLine = patchLine
        self.oldLineCount = oldLineCount; self.newLineCount = newLineCount
    }

    /// The path the files list shows: the new one, or the old one for a deletion.
    public var path: String { newPath ?? oldPath ?? String(localized: "(unnamed file)", bundle: .module, comment: "Name shown for a file in a patch that names none.") }

    public var isBinary: Bool { binary != nil }

    /// Both modes are known and differ (`old mode 100644` / `new mode 100755`).
    public var isModeChange: Bool {
        guard let oldMode, let newMode, !isNewFile, !isDeletedFile else { return false }
        return oldMode != newMode
    }

    public var kind: DiffChangeKind {
        if isNewFile { return .added }
        if isDeletedFile { return .deleted }
        if isRenamed { return .renamed }
        if isCopied { return .copied }
        if isBinary { return .binary }
        if isModeChange && additions == 0 && deletions == 0 { return .modeChanged }
        return .modified
    }
}

/// One commit's message in a patch: a `git format-patch` email or a `git log -p` / `git show` header.
public struct PatchCommit: Sendable, Equatable, Hashable {
    public enum Source: String, Sendable, Equatable, Hashable, Codable { case email, gitLog }

    public var source: Source
    /// The commit id from the mbox `From <sha>` line or `commit <sha>`.
    public var hash: String?
    /// `Dana Reyes <dana@example.com>` as written (RFC 2047 words decoded).
    public var author: String?
    public var authorName: String?
    public var authorEmail: String?
    /// The date exactly as written, and parsed when it is in a format git or mail writes.
    public var dateText: String?
    public var date: Date?
    /// The subject without its `[PATCH 2/5]` prefix.
    public var subject: String?
    /// The bracketed prefix as written (`[PATCH v2 2/5]`), and its position in the series when it has one.
    public var subjectPrefix: String?
    public var seriesIndex: Int?
    public var seriesTotal: Int?
    /// The commit message after the subject, trimmed.
    public var body: String
    /// The git version from the `-- ` signature git appends (`2.43.0`).
    public var gitVersion: String?
    /// Parents listed on a `Merge:` line.
    public var mergeParents: [String]

    public init(source: Source, hash: String? = nil, author: String? = nil, authorName: String? = nil,
                authorEmail: String? = nil, dateText: String? = nil, date: Date? = nil, subject: String? = nil,
                subjectPrefix: String? = nil, seriesIndex: Int? = nil, seriesTotal: Int? = nil, body: String = "",
                gitVersion: String? = nil, mergeParents: [String] = []) {
        self.source = source; self.hash = hash; self.author = author; self.authorName = authorName
        self.authorEmail = authorEmail; self.dateText = dateText; self.date = date; self.subject = subject
        self.subjectPrefix = subjectPrefix; self.seriesIndex = seriesIndex; self.seriesTotal = seriesTotal
        self.body = body; self.gitVersion = gitVersion; self.mergeParents = mergeParents
    }
}

/// Something the parser could not take at face value. Every problem is reported, never thrown: a damaged patch
/// still previews what is there, with the problem said once, in words.
public struct PatchIssue: Sendable, Equatable, Hashable {
    public enum Severity: String, Sendable, Equatable, Hashable, Codable, Comparable {
        case info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
        private var rank: Int { switch self { case .info: 0; case .warning: 1; case .error: 2 } }
    }

    public enum Kind: Sendable, Equatable, Hashable {
        /// `@@` line that does not parse; the lines after it up to the next header were skipped.
        case badHunkHeader(skippedLines: Int)
        /// The header promised more lines than arrived.
        case hunkTooShort(declaredOld: Int, declaredNew: Int, foundOld: Int, foundNew: Int)
        /// More hunk lines followed than the header declared; they were kept.
        case hunkTooLong(extraLines: Int)
        /// The file ends in the middle of a hunk or a header.
        case truncated
        /// A hunk with no `---`/`+++` or `diff --git` header above it.
        case missingFileHeader
        /// Lines between files that are not part of any diff.
        case unrecognizedLines(count: Int)
        /// A `*** / ---` context diff, which this parser does not read.
        case contextDiffUnsupported
        /// A merge's combined diff; lines are shown against the merge result only.
        case combinedDiff(parents: Int)
        /// `GIT binary patch` data is noted, never decoded.
        case binaryNotDecoded
        /// A mode that is not octal (`old mode 9z`).
        case invalidMode(String)
        /// `\ No newline at end of file` with no line before it.
        case orphanNoNewlineMarker
        /// `Only in old: name` from `diff -r`: a file on one side only, with no content shown.
        case onlyInOneSide(String)
        /// Lines cut at the line-length cap.
        case longLinesTruncated(count: Int)
        /// Detail caps reached: later files are counted, not kept.
        case limitReached
        /// The input was longer than `PatchLimits.maxBytes`; the rest was not read.
        case inputCut(readBytes: Int, totalBytes: Int)
        /// Lines that were not valid UTF-8 and were read as Latin-1.
        case latin1Lines(count: Int)
        /// The email body was quoted-printable or base64 and was decoded before parsing.
        case transferEncodingDecoded(String)
        /// No diff at all was found.
        case noDiffFound
    }

    public var kind: Kind
    public var severity: Severity
    /// 1-based line in the patch where the problem starts (0 when it concerns the whole input).
    public var line: Int

    public init(_ kind: Kind, line: Int) {
        self.kind = kind; self.line = line
        switch kind {
        case .badHunkHeader, .hunkTooShort, .truncated, .inputCut, .noDiffFound, .contextDiffUnsupported:
            severity = .error
        case .hunkTooLong, .missingFileHeader, .unrecognizedLines, .invalidMode, .orphanNoNewlineMarker,
             .limitReached, .longLinesTruncated:
            severity = .warning
        case .combinedDiff, .binaryNotDecoded, .onlyInOneSide, .latin1Lines, .transferEncodingDecoded:
            severity = .info
        }
    }

    /// One plain sentence for the view's inline error row.
    public var message: String {
        switch kind {
        case .badHunkHeader(let skipped):
            switch skipped {
            case 0: return String(localized: "Line \(line) is not a valid hunk header.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
            case 1: return String(localized: "Line \(line) is not a valid hunk header; 1 line after it was skipped.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
            default: return String(localized: "Line \(line) is not a valid hunk header; \(skipped.formatted()) lines after it were skipped.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
            }
        case .hunkTooShort(let dOld, let dNew, let fOld, let fNew):
            if dOld == dNew && fOld == fNew {
                return dOld == 1 ? String(localized: "The hunk header says 1 line; \(fOld.formatted()) arrived. Showing what is there.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
                    : String(localized: "The hunk header says \(dOld.formatted()) lines; \(fOld.formatted()) arrived. Showing what is there.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
            }
            return String(localized: "The hunk header says \(dOld.formatted()) old and \(dNew.formatted()) new lines; \(fOld.formatted()) and \(fNew.formatted()) arrived. Showing what is there.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        case .hunkTooLong(let extra):
            return extra == 1 ? String(localized: "The hunk at line \(line) has 1 line more than its header says; it is shown.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
                : String(localized: "The hunk at line \(line) has \(extra.formatted()) lines more than its header says; they are shown.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        case .truncated:
            return String(localized: "This patch is cut off at line \(line).", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        case .missingFileHeader:
            return String(localized: "The hunk at line \(line) has no file header above it.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        case .unrecognizedLines(let count):
            return count == 1 ? String(localized: "1 line from line \(line) is not part of any diff.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
                : String(localized: "\(count.formatted()) lines from line \(line) are not part of any diff.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        case .contextDiffUnsupported:
            return String(localized: "Line \(line) starts a context diff (*** / ---), which is not shown; only unified diffs are.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        case .combinedDiff(let parents):
            return String(localized: "This is a merge's combined diff against \(parents) parents; lines are shown against the merge result.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        case .binaryNotDecoded:
            return String(localized: "Binary patch data is noted, not decoded.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        case .invalidMode(let text):
            return String(localized: "Line \(line) has a file mode that is not octal (\(text)).", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        case .orphanNoNewlineMarker:
            return String(localized: "Line \(line) says \"no newline at end of file\" but follows no line.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view. The quoted phrase is git's marker text.")
        case .onlyInOneSide(let text):
            return text
        case .longLinesTruncated(let count):
            return count == 1 ? String(localized: "1 line was too long and is shown cut short.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
                : String(localized: "\(count.formatted()) lines were too long and are shown cut short.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        case .limitReached:
            return String(localized: "This patch is large: files from line \(line) on are counted, not shown.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        case .inputCut(let read, let total):
            return String(localized: "Only the first \(ByteCountFormatter.string(fromByteCount: Int64(read), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)) were read.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view. The arguments are byte sizes.")
        case .latin1Lines(let count):
            return count == 1 ? String(localized: "1 line was not UTF-8 and was read as Latin-1.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
                : String(localized: "\(count.formatted()) lines were not UTF-8 and were read as Latin-1.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        case .transferEncodingDecoded(let encoding):
            return String(localized: "The email body was \(encoding) and was decoded.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view. The argument is a transfer encoding such as quoted-printable or base64.")
        case .noDiffFound:
            return String(localized: "No diff was found in this file.", bundle: .module, comment: "One sentence about a problem found while reading a patch, shown in the diff view.")
        }
    }
}
