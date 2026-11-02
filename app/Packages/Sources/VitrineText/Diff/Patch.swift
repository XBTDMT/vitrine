import Foundation

/// A parsed `.patch` / `.diff` file: a plain `diff -u`, a `git diff`, a `git format-patch` email (or a series of
/// them in one mbox), or `git log -p` / `git show` output. Parsing never fails: whatever could not be read is in
/// `issues`, and whatever the caps left out is in `coverage`.
public struct Patch: Sendable, Equatable {
    public enum Format: String, Sendable, Equatable, Codable {
        /// `diff -u` output: `---`/`+++` headers, no git extended headers.
        case unified
        /// `git diff`: `diff --git` headers.
        case git
        /// `git format-patch`: one or more emails, each a commit.
        case formatPatch
        /// `git log -p` / `git show`: `commit <sha>` headers.
        case gitLog
        /// Nothing that parses as a diff.
        case none
    }

    public var format: Format
    public var commits: [PatchCommit]
    /// Every file listed, in patch order (up to `PatchLimits.maxFiles`).
    public var files: [DiffFile]
    /// Text before the first diff that belongs to no commit (a cover note, a pasted explanation).
    public var preamble: String
    public var issues: [PatchIssue]
    public var coverage: PatchCoverage
    /// Totals over the whole input, including files past the listing cap.
    public var totals: Totals
    /// Lines of the patch that ended in CRLF, and all lines: a Windows-saved patch says so in the facts.
    public var crlfLineCount: Int
    public var lineCount: Int

    public struct Totals: Sendable, Equatable {
        public var files: Int
        public var additions: Int
        public var deletions: Int
        public var hunks: Int
        public init(files: Int = 0, additions: Int = 0, deletions: Int = 0, hunks: Int = 0) {
            self.files = files; self.additions = additions; self.deletions = deletions; self.hunks = hunks
        }
    }

    public init(format: Format, commits: [PatchCommit], files: [DiffFile], preamble: String, issues: [PatchIssue],
                coverage: PatchCoverage, totals: Totals, crlfLineCount: Int, lineCount: Int) {
        self.format = format; self.commits = commits; self.files = files; self.preamble = preamble
        self.issues = issues; self.coverage = coverage; self.totals = totals
        self.crlfLineCount = crlfLineCount; self.lineCount = lineCount
    }

    /// The worst problem found, for the lead's state dot.
    public var worstIssue: PatchIssue.Severity? { issues.map(\.severity).max() }

    /// True when the patch ends in the middle of a hunk or a header: the "This patch is cut off" state.
    public var isTruncated: Bool { issues.contains { $0.kind == .truncated } }

    public func files(inCommit index: Int) -> [DiffFile] { files.filter { $0.commitIndex == index } }
}

/// The caps that keep a patch inside the preview budgets (ARCHITECTURE §7). Past a cap the parser keeps counting,
/// so totals stay exact while the kept detail stops growing.
public struct PatchLimits: Sendable, Equatable {
    /// Bytes read at all; the rest of a bigger file is not read and coverage says so.
    public var maxBytes: Int
    /// Files listed. Later files are counted in `Patch.totals` only.
    public var maxFiles: Int
    /// Hunk lines kept across the patch. Later hunks are counted, their lines not kept.
    public var maxDetailedLines: Int
    /// Hunks kept across the patch.
    public var maxDetailedHunks: Int
    /// Bytes of one line kept; a longer line is cut (on a character boundary) and flagged.
    public var maxLineBytes: Int

    public init(maxBytes: Int = 64 << 20, maxFiles: Int = 20_000, maxDetailedLines: Int = 100_000,
                maxDetailedHunks: Int = 10_000, maxLineBytes: Int = 8_192) {
        self.maxBytes = max(0, maxBytes); self.maxFiles = max(0, maxFiles)
        self.maxDetailedLines = max(0, maxDetailedLines); self.maxDetailedHunks = max(0, maxDetailedHunks)
        self.maxLineBytes = max(16, maxLineBytes)
    }

    public static let `default` = PatchLimits()
}

/// How much of the patch the parsed value holds. `isComplete` is the one bit the view needs; the counts make the
/// "Showing 40 of 1,284 files" note.
public struct PatchCoverage: Sendable, Equatable {
    public var bytesRead: Int
    public var totalBytes: Int
    public var filesListed: Int
    public var filesSeen: Int
    /// Listed files whose hunks were all kept.
    public var filesWithDetail: Int
    public var linesKept: Int
    public var linesSeen: Int
    public var hunksKept: Int
    public var hunksSeen: Int
    /// Lines cut at `maxLineBytes`.
    public var truncatedLines: Int

    public init(bytesRead: Int = 0, totalBytes: Int = 0, filesListed: Int = 0, filesSeen: Int = 0,
                filesWithDetail: Int = 0, linesKept: Int = 0, linesSeen: Int = 0, hunksKept: Int = 0,
                hunksSeen: Int = 0, truncatedLines: Int = 0) {
        self.bytesRead = bytesRead; self.totalBytes = totalBytes; self.filesListed = filesListed
        self.filesSeen = filesSeen; self.filesWithDetail = filesWithDetail; self.linesKept = linesKept
        self.linesSeen = linesSeen; self.hunksKept = hunksKept; self.hunksSeen = hunksSeen
        self.truncatedLines = truncatedLines
    }

    public var isComplete: Bool {
        bytesRead >= totalBytes && filesListed == filesSeen && linesKept == linesSeen && hunksKept == hunksSeen
            && truncatedLines == 0
    }

    /// The sentence the view shows when coverage is partial; nil when complete.
    public var note: String? {
        if bytesRead < totalBytes {
            return String(localized: "Showing the first \(ByteCountFormatter.string(fromByteCount: Int64(bytesRead), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))", bundle: .module, comment: "Coverage note for a large patch; the arguments are byte sizes.")
        }
        if filesWithDetail < filesSeen {
            return String(localized: "Showing \(filesWithDetail.formatted()) of \(filesSeen.formatted()) files", bundle: .module, comment: "Coverage note for a large patch.")
        }
        if linesKept < linesSeen { return String(localized: "Showing \(linesKept.formatted()) of \(linesSeen.formatted()) lines", bundle: .module, comment: "Coverage note for a large patch.") }
        if truncatedLines > 0 {
            return truncatedLines == 1 ? String(localized: "1 long line is cut short", bundle: .module, comment: "Coverage note for a patch with one very long line.")
                : String(localized: "\(truncatedLines.formatted()) long lines are cut short", bundle: .module, comment: "Coverage note for a patch with several very long lines.")
        }
        return nil
    }
}
