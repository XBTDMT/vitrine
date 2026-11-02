import Foundation
import VitrineDocument

/// The metadata strip's facts for a patch or a compare, in the document model's `Fact` form (ARCHITECTURE §4), and
/// the patch's coverage as the model's `Coverage`. Keys are stable (`files`, `additions` …) because `vitrine
/// describe` and MCP print them; a fact that does not apply is left out rather than shown as zero or "unknown".
public enum DiffFacts {
    public static func facts(for patch: Patch) -> [Fact] {
        var facts: [Fact] = []
        let formatLabel: String? = switch patch.format {
        case .unified: String(localized: "Unified diff", bundle: .module, comment: "Format fact value: a patch in unified diff format.")
        case .git: "git diff"
        case .formatPatch: "git format-patch"
        case .gitLog: "git log"
        case .none: nil
        }
        if let formatLabel { facts.append(Fact(key: "format", label: String(localized: "Format", bundle: .module, comment: "Fact label for a patch or a two-file compare."), value: formatLabel)) }
        if patch.commits.count > 1 {
            facts.append(Fact(key: "commits", label: String(localized: "Commits", bundle: .module, comment: "Fact label for a patch or a two-file compare."), value: patch.commits.count.formatted()))
        }
        if let commit = patch.commits.first {
            if let subject = commit.subject, !subject.isEmpty { facts.append(Fact(key: "subject", label: String(localized: "Subject", bundle: .module, comment: "Fact label: the commit's subject line."), value: subject)) }
            if let author = commit.author, !author.isEmpty { facts.append(Fact(key: "author", label: String(localized: "Author", bundle: .module, comment: "Fact label: the commit's author."), value: author)) }
            if let date = commit.dateText, !date.isEmpty { facts.append(Fact(key: "date", label: String(localized: "Date", bundle: .module, comment: "Fact label: the commit's date."), value: date)) }
        }
        let t = patch.totals
        facts.append(Fact(key: "files", label: String(localized: "Files", bundle: .module, comment: "Fact label: how many files the patch changes."), value: t.files.formatted()))
        facts.append(Fact(key: "additions", label: String(localized: "Lines added", bundle: .module, comment: "Fact label for a patch or a two-file compare."), value: t.additions.formatted()))
        facts.append(Fact(key: "deletions", label: String(localized: "Lines removed", bundle: .module, comment: "Fact label for a patch or a two-file compare."), value: t.deletions.formatted()))
        facts.append(Fact(key: "hunks", label: String(localized: "Hunks", bundle: .module, comment: "Fact label: the number of hunks (changed regions) in a patch."), value: t.hunks.formatted()))
        let binary = patch.files.filter(\.isBinary).count
        if binary > 0 { facts.append(Fact(key: "binaryFiles", label: String(localized: "Binary files", bundle: .module, comment: "Fact label for a patch or a two-file compare."), value: binary.formatted())) }
        let renames = patch.files.filter(\.isRenamed).count
        if renames > 0 { facts.append(Fact(key: "renames", label: String(localized: "Renames", bundle: .module, comment: "Fact label: the number of renamed files."), value: renames.formatted())) }
        let copies = patch.files.filter(\.isCopied).count
        if copies > 0 { facts.append(Fact(key: "copies", label: String(localized: "Copies", bundle: .module, comment: "Fact label: the number of copied files."), value: copies.formatted())) }
        let modes = patch.files.filter(\.isModeChange).count
        if modes > 0 { facts.append(Fact(key: "modeChanges", label: String(localized: "Mode changes", bundle: .module, comment: "Fact label: files whose permissions (mode) changed."), value: modes.formatted())) }
        if patch.files.contains(where: \.isCombined) {
            facts.append(Fact(key: "combined", label: String(localized: "Combined diff", bundle: .module, comment: "Fact label: the patch is a merge's combined diff."), value: String(localized: "Merge", bundle: .module, comment: "Combined diff fact value: the patch shows a merge commit.")))
        }
        if patch.crlfLineCount > 0 {
            let value = patch.crlfLineCount == patch.lineCount ? "CRLF"
                : String(localized: "Mixed (\(patch.crlfLineCount.formatted()) CRLF)", bundle: .module, comment: "Line endings fact value: some lines end in CRLF; the argument is how many.")
            facts.append(Fact(key: "lineEndings", label: String(localized: "Line endings", bundle: .module, comment: "Fact label for a patch or a two-file compare."), value: value))
        }
        let problems = patch.issues.filter { $0.severity != .info }.count
        if problems > 0 { facts.append(Fact(key: "problems", label: String(localized: "Problems", bundle: .module, comment: "Fact label: the number of problems found while reading the patch."), value: problems.formatted())) }
        if let note = patch.coverage.note { facts.append(Fact(key: "coverage", label: String(localized: "Coverage", bundle: .module, comment: "Fact label: how much of the file is shown."), value: note)) }
        facts.append(DocumentFacts.size(Int64(patch.coverage.totalBytes)))
        return facts
    }

    /// The patch's coverage for `PreviewDocument.coverage`: bytes when the input was cut, lines when detail was
    /// capped; the reason is the sentence the view shows.
    public static func coverage(for patch: Patch) -> Coverage {
        let c = patch.coverage
        guard !c.isComplete, let note = c.note else { return .complete }
        if c.bytesRead < c.totalBytes {
            return .partial(shown: Int64(c.bytesRead), total: Int64(c.totalBytes), unit: .bytes, reason: note)
        }
        return .partial(shown: Int64(c.linesKept), total: Int64(c.linesSeen), unit: .rows, reason: note)
    }

    public static func facts(for comparison: TextComparison) -> [Fact] {
        var facts: [Fact] = []
        let status: String = switch comparison.status {
        case .identical: String(localized: "Identical", bundle: .module, comment: "Compare status: the two files are the same.")
        case .whitespaceOnly: String(localized: "Whitespace only", bundle: .module, comment: "Compare status: the files differ only in spaces, tabs or line endings.")
        case .different: String(localized: "Different", bundle: .module, comment: "Compare status: the files differ.")
        case .binary: String(localized: "Binary, different", bundle: .module, comment: "Compare status: two binary files that differ.")
        }
        facts.append(Fact(key: "status", label: String(localized: "Status", bundle: .module, comment: "Fact label: whether the two compared files differ."), value: status))
        if comparison.status != .binary {
            facts.append(Fact(key: "changes", label: String(localized: "Changes", bundle: .module, comment: "Fact label: the number of changed regions."), value: comparison.changes.count.formatted()))
            facts.append(Fact(key: "additions", label: String(localized: "Lines added", bundle: .module, comment: "Fact label for a patch or a two-file compare."), value: comparison.additions.formatted()))
            facts.append(Fact(key: "deletions", label: String(localized: "Lines removed", bundle: .module, comment: "Fact label for a patch or a two-file compare."), value: comparison.deletions.formatted()))
            facts.append(Fact(key: "lines", label: String(localized: "Lines", bundle: .module, comment: "Fact label for a patch or a two-file compare."), value: "\(comparison.oldLineCount.formatted()) → \(comparison.newLineCount.formatted())"))
            if comparison.oldLineEnding != comparison.newLineEnding {
                facts.append(Fact(key: "lineEndings", label: String(localized: "Line endings", bundle: .module, comment: "Fact label for a patch or a two-file compare."),
                                  value: "\(comparison.oldLineEnding.label) → \(comparison.newLineEnding.label)"))
            } else if comparison.oldLineEnding == .crlf || comparison.oldLineEnding == .mixed {
                facts.append(Fact(key: "lineEndings", label: String(localized: "Line endings", bundle: .module, comment: "Fact label for a patch or a two-file compare."), value: comparison.oldLineEnding.label))
            }
        }
        if let report = comparison.whitespace, !report.summary.isEmpty {
            facts.append(Fact(key: "whitespace", label: String(localized: "Whitespace", bundle: .module, comment: "Fact label: what whitespace differs between the files."), value: report.summary))
        }
        let sizes = "\(ByteCountFormatter.string(fromByteCount: Int64(comparison.oldSize), countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: Int64(comparison.newSize), countStyle: .file))"
        facts.append(Fact(key: "size", label: String(localized: "Size", bundle: .module, comment: "Fact label for a patch or a two-file compare."), value: sizes))
        if comparison.isSimplified {
            facts.append(Fact(key: "coverage", label: String(localized: "Coverage", bundle: .module, comment: "Fact label: how much of the file is shown."), value: String(localized: "Simplified: the compare hit its time or size limit", bundle: .module, comment: "Coverage note for a two-file compare.")))
        }
        return facts
    }
}
