import CryptoKit
import Foundation
import VitrineSupport
import VitrineText

/// What the diff page draws (diff design r3-b Summary sibling, G-16), made from the engine's patch: the lead (state
/// dot, sentence, commit subject, author and date, message), the Checks group, the "what changed" list, a notice for
/// a damaged or cut patch, and each file's rows — unified and split, numbered on both sides, with intra-line marks
/// and the folds between hunks. Rows are made per file when the page asks for them, so a huge patch costs only what
/// is on screen. Secrets the checks find are masked in the rows before they leave Swift. roadmap: S-7
struct DiffPage: Encodable {
    struct Lead: Encodable {
        /// "calm", "caution", "danger" (the dot's colour).
        let state: String
        let sentence: String
        let subject: String?
        let meta: String?
        let message: String?
        let additions: Int
        let deletions: Int
    }

    struct FileItem: Encodable {
        let index: Int
        /// M, A, D, R, C, B.
        let letter: String
        let kind: String
        let directory: String
        let name: String
        /// For a rename or copy: where it came from, and how similar.
        let from: String?
        let similarity: Int?
        let additions: Int
        let deletions: Int
        /// "4.1 KB → 4.5 KB" for a binary file.
        let binary: String?
        /// Shiki's language for the file's path; nil = no colours.
        let lang: String?
        /// The patch names this file but its lines were not kept (the detail cap): counted, not drawn.
        let omitted: Bool
        let modeChange: String?
    }

    struct Notice: Encodable { let title: String; let detail: String }

    /// A two-file compare: its names and its "what changed" list, which here holds changes, not files; `hidden`
    /// keeps the detail closed (identical files have none; whitespace-only shows it on request).
    struct Compare: Encodable {
        struct Item: Encodable { let title: String; let detail: String?; let line: Int?; let additions: Int; let deletions: Int }
        let oldName: String
        let newName: String
        let items: [Item]
        let hidden: Bool
        let reveal: String?
    }

    var lead: Lead
    let checks: [DiffChecks.Finding]
    let files: [FileItem]
    var notice: Notice?
    /// "Showing the first 40 of 1,284 files"; nil when every file is here.
    let coverage: String?
    let shownFiles: Int
    let totalFiles: Int
    var compare: Compare?
    /// A compare by meaning (structure, prose, notebook, image); nil = rows only.
    var rich: RichCompare?

    /// One row of the detail. `t`: "fold" or "line"; `k`: "a" added, "d" deleted, "c" context.
    struct Row: Encodable, Equatable {
        var t: String
        var label: String?
        var k: String?
        var o: Int?
        var n: Int?
        var s: String?
        var h: [[Int]]?
    }

    struct Cell: Encodable, Equatable {
        var k: String
        var n: Int?
        var s: String
        var h: [[Int]]?
    }

    struct SplitRow: Encodable, Equatable {
        var t: String
        var label: String?
        var l: Cell?
        var r: Cell?
    }

    struct FileRows: Encodable {
        let index: Int
        let unified: [Row]
        let split: [SplitRow]
    }

    // MARK: Building

    static func make(patch: Patch, fileName: String, checks: DiffChecks.Result) -> DiffPage {
        let summary = DiffSummary(patch: patch)
        let files = patch.files.enumerated().map { i, file in item(i, file) }
        let worst = checks.findings.map(\.level)
        let state = worst.contains(.danger) ? "danger" : (worst.contains(.caution) || patch.worstIssue == .error) ? "caution" : "calm"
        let sentence: String
        if !checks.findings.isEmpty {
            sentence = String(localized: "\(checks.findings.count) things to check before applying", bundle: .previewKit,
                              comment: "Patch lead sentence: how many safety findings to look at before applying it.")
        } else if let subject = summary.subject, !subject.isEmpty {
            sentence = subject
        } else {
            sentence = summary.lead
        }
        var meta: [String] = []
        if !checks.findings.isEmpty { meta.append(fileName) }
        if let author = summary.author { meta.append(author) }
        if let date = summary.date { meta.append(date.formatted(.dateTime.day().month(.abbreviated))) }
        meta.append(String(localized: "\(summary.fileCount) files", bundle: .previewKit, comment: "Patch meta line: how many files it changes."))
        let lead = Lead(state: state, sentence: sentence,
                        subject: checks.findings.isEmpty ? nil : summary.subject,
                        meta: meta.joined(separator: " · "), message: summary.message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        additions: summary.additions, deletions: summary.deletions)
        let total = max(patch.coverage.filesSeen, patch.files.count)
        let coverage = patch.coverage.isComplete || total <= patch.files.count ? nil
            : String(localized: "Showing the first \(patch.files.count) of \(total) files", bundle: .previewKit,
                     comment: "Under a very long patch's file list: how many files are drawn.")
        return DiffPage(lead: lead, checks: checks.findings, files: files, notice: notice(patch), coverage: coverage,
                        shownFiles: patch.files.count, totalFiles: total)
    }

    static func item(_ i: Int, _ file: DiffFile) -> FileItem {
        let path = file.path
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent
        let kind = changeKind(file)
        var binary: String?
        if let b = file.binary {
            let fmt = { (n: Int?) in n.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } }
            switch (fmt(b.oldSize), fmt(b.newSize)) {
            case let (old?, new?): binary = "\(old) → \(new)"
            case let (nil, new?): binary = new
            case let (old?, nil): binary = old
            default: binary = String(localized: "binary", bundle: .previewKit, comment: "A binary file in a patch whose sizes are unknown (lower case).")
            }
        }
        var mode: String?
        if let o = file.oldMode, let n = file.newMode, o != n {
            mode = n.isExecutable && !o.isExecutable
                ? String(localized: "made executable", bundle: .previewKit, comment: "A patch made a file executable (lower case).")
                : o.isExecutable && !n.isExecutable
                ? String(localized: "no longer executable", bundle: .previewKit, comment: "A patch made a file no longer executable (lower case).")
                : String(localized: "mode \(o.octal) → \(n.octal)", bundle: .previewKit,
                         comment: "A patch changed a file's Unix mode; the arguments are octal modes such as 100644.")
        }
        let ext = ns.pathExtension.lowercased()
        let language = LanguageMap.language(forFileName: ns.lastPathComponent) ?? LanguageMap.language(for: ext, type: nil)
        return FileItem(index: i, letter: kind.letter, kind: kind.verb, directory: dir.isEmpty ? "" : dir + "/", name: ns.lastPathComponent,
                        from: file.isRenamed || file.isCopied ? file.oldPath : nil, similarity: file.similarity,
                        additions: file.additions, deletions: file.deletions, binary: binary,
                        lang: language == "plaintext" ? nil : CodeRenderer.shikiLanguage(language),
                        omitted: file.isDetailOmitted, modeChange: mode)
    }

    static func changeKind(_ file: DiffFile) -> DiffChangeKind {
        if file.binary != nil { return .binary }
        if file.isNewFile { return .added }
        if file.isDeletedFile { return .deleted }
        if file.isRenamed { return .renamed }
        if file.isCopied { return .copied }
        if file.hunks.isEmpty, file.oldMode != file.newMode { return .modeChanged }
        return .modified
    }

    /// A cut or damaged patch says so once, above the files ("This patch is cut off · The hunk header says 12 lines;
    /// 9 arrived. Showing what is there.").
    static func notice(_ patch: Patch) -> Notice? {
        for issue in patch.issues where issue.severity == .error {
            switch issue.kind {
            case .hunkTooShort(let dOld, let dNew, let fOld, let fNew):
                let declared = max(dOld, dNew), found = max(fOld, fNew)
                return Notice(title: cutOff,
                              detail: String(localized: "The hunk header says \(declared) lines; \(found) arrived. Showing what is there.", bundle: .previewKit,
                                             comment: "Notice detail for a cut-off patch: the lines a hunk declares and the lines that arrived."))
            case .truncated:
                return Notice(title: cutOff, detail: String(localized: "It ends in the middle of a change. Showing what is there.", bundle: .previewKit,
                                                            comment: "Notice detail for a patch that stops mid-change."))
            case .noDiffFound:
                return Notice(title: String(localized: "No changes found", bundle: .previewKit, comment: "Notice title: a patch file holds no diff."),
                              detail: String(localized: "This file has no diff in a form Vitrine reads.", bundle: .previewKit,
                                             comment: "Notice detail: a patch file holds no diff."))
            default:
                return Notice(title: String(localized: "Part of this patch could not be read", bundle: .previewKit,
                                            comment: "Notice title: a part of a patch is malformed."),
                              detail: String(localized: "\(issue.message) Showing what is there.", bundle: .previewKit,
                                             comment: "Notice detail: the parser's own message, then that the rest is shown."))
            }
        }
        return nil
    }

    private static var cutOff: String {
        String(localized: "This patch is cut off", bundle: .previewKit, comment: "Notice title: a patch file ends early.")
    }

    /// "12 lines": how many lines a whitespace change touches.
    private static func lines(_ n: Int) -> String {
        String(localized: "\(n) lines", bundle: .previewKit, comment: "How many lines a whitespace change touches.")
    }

    static func make(comparison c: TextComparison, oldName: String, newName: String, oldBytes: Data, newBytes: Data) -> DiffPage {
        let summary = DiffSummary(comparison: c)
        var sentence = summary.lead
        var meta = "\(oldName) ⇄ \(newName)"
        var items: [Compare.Item] = []
        var hidden = false
        var reveal: String?
        switch c.status {
        case .identical:
            let same = SHA256.hash(data: oldBytes) == SHA256.hash(data: newBytes)
            meta = same
                ? String(localized: "Byte for byte · \(c.newSize) bytes each · SHA-256 match · Nothing to show.", bundle: .previewKit,
                         comment: "Compare meta line for identical files whose checksums match.")
                : String(localized: "Byte for byte · \(c.newSize) bytes each · Nothing to show.", bundle: .previewKit,
                         comment: "Compare meta line for identical files.")
            hidden = true
        case .whitespaceOnly:
            sentence = String(localized: "Same text, different whitespace", bundle: .previewKit, comment: "Compare lead: only whitespace differs.")
            meta = c.whitespace?.summary ?? meta
            if let w = c.whitespace {
                if w.lineEndingChanges > 0 {
                    // Line ending labels (LF, CRLF) are identifiers.
                    items.append(.init(title: String(localized: "Line endings \(w.oldEnding.label) → \(w.newEnding.label)", bundle: .previewKit,
                                                     comment: "Compare change: the line endings changed, e.g. CRLF → LF."),
                                       detail: lines(w.lineEndingChanges), line: nil, additions: 0, deletions: 0))
                }
                if w.trailingWhitespaceChanges > 0 {
                    items.append(.init(title: String(localized: "Trailing spaces changed", bundle: .previewKit, comment: "Compare change."),
                                       detail: lines(w.trailingWhitespaceChanges), line: nil, additions: 0, deletions: 0))
                }
                if w.otherWhitespaceChanges > 0 {
                    items.append(.init(title: String(localized: "Spacing inside lines changed", bundle: .previewKit, comment: "Compare change."),
                                       detail: lines(w.otherWhitespaceChanges), line: nil, additions: 0, deletions: 0))
                }
                if w.finalNewlineChanged {
                    items.append(.init(title: String(localized: "Final newline", bundle: .previewKit, comment: "Compare change: the newline at the end of the file."),
                                       detail: String(localized: "added or removed", bundle: .previewKit, comment: "Detail of the Final newline change."),
                                       line: nil, additions: 0, deletions: 0))
                }
            }
            hidden = true
            reveal = String(localized: "Show whitespace changes", bundle: .previewKit, comment: "Button: draw the whitespace changes of a compare.")
        case .binary:
            meta = String(localized: "\(oldName) ⇄ \(newName) · not text, so no lines to compare", bundle: .previewKit,
                          comment: "Compare meta line for two binary files; the arguments are their names.")
            hidden = true
        case .different:
            items = c.changes.map { .init(title: $0.label, detail: $0.preview, line: $0.new.lowerBound + 1, additions: $0.additions, deletions: $0.deletions) }
        }
        let lead = Lead(state: "calm", sentence: sentence, subject: nil, meta: meta, message: nil,
                        additions: c.additions, deletions: c.deletions)
        let file = FileItem(index: 0, letter: "M", kind: "edited", directory: "", name: "\(oldName) ⇄ \(newName)", from: nil, similarity: nil,
                            additions: c.additions, deletions: c.deletions, binary: nil,
                            lang: language(for: newName), omitted: false, modeChange: nil)
        var page = DiffPage(lead: lead, checks: [], files: c.status == .identical || c.status == .binary ? [] : [file],
                            notice: c.isSimplified
                                ? Notice(title: String(localized: "Simplified", bundle: .previewKit, comment: "Notice title: a compare gave up on the smallest diff."),
                                         detail: String(localized: "The compare reached its time or size limit; the changes are correct but not minimal.",
                                                        bundle: .previewKit, comment: "Notice detail for a simplified compare."))
                                : nil,
                            coverage: nil, shownFiles: 1, totalFiles: 1)
        page.compare = Compare(oldName: oldName, newName: newName, items: items, hidden: hidden, reveal: reveal)
        return page
    }

    static func language(for name: String) -> String? {
        let ns = name as NSString
        let id = LanguageMap.language(forFileName: ns.lastPathComponent) ?? LanguageMap.language(for: ns.pathExtension.lowercased(), type: nil)
        return id == "plaintext" ? nil : CodeRenderer.shikiLanguage(id)
    }

    // MARK: Rows

    static func rows(_ file: DiffFile, index: Int, checks: DiffChecks.Result) -> FileRows {
        func text(_ hunk: Int, _ line: Int) -> String {
            checks.maskedText(file: index, hunk: hunk, line: line) ?? file.hunks[hunk].lines[line].text
        }
        func code(_ k: DiffLine.Kind) -> String {
            switch k { case .added: "a"; case .deleted: "d"; case .context: "c" }
        }
        func ranges(_ r: [Range<Int>]) -> [[Int]]? { r.isEmpty ? nil : r.map { [$0.lowerBound, $0.upperBound] } }
        // A masked line keeps no intra-line marks: they would point into the hidden value.
        func marks(_ hunk: Int, _ line: Int, _ r: [Range<Int>]) -> [[Int]]? {
            checks.maskedText(file: index, hunk: hunk, line: line) == nil ? ranges(r) : nil
        }
        let unified: [Row] = DiffLayout.unified(file).map { row in
            switch row {
            case .fold(let fold):
                return Row(t: "fold", label: fold.label)
            case .line(let h, let l, let hl):
                let line = file.hunks[h].lines[l]
                return Row(t: "line", k: code(line.kind), o: line.oldNumber, n: line.newNumber, s: text(h, l), h: marks(h, l, hl))
            }
        }
        let split: [SplitRow] = DiffLayout.split(file).map { row in
            switch row {
            case .fold(let fold):
                return SplitRow(t: "fold", label: fold.label)
            case .pair(let left, let right):
                func cell(_ c: DiffLayout.SplitCell?) -> Cell? {
                    c.map { Cell(k: code($0.kind), n: $0.number, s: text($0.hunk, $0.line), h: marks($0.hunk, $0.line, $0.highlights)) }
                }
                return SplitRow(t: "pair", l: cell(left), r: cell(right))
            }
        }
        return FileRows(index: index, unified: unified, split: split)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
