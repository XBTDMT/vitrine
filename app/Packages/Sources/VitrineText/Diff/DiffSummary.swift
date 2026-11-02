import Foundation

/// The glance answer the picked design leads with (r3-b "Summary sibling", design/mockups/unified/CHANGES.md): a
/// one-line lead, the commit's subject and message, and the "what changed" list, largest files first, at most five
/// rows then "and N more". Words are plain English; numbers use the current locale's grouping.
public struct DiffSummary: Sendable, Equatable {
    /// One row of the files list.
    public struct FileRow: Sendable, Equatable, Hashable {
        /// Index into `Patch.files` (or 0 for a compare).
        public var index: Int
        public var path: String
        /// The folder part with its trailing slash (`Sources/Sync/`), empty at the top level.
        public var directory: String
        public var name: String
        public var kind: DiffChangeKind
        public var additions: Int
        public var deletions: Int
        /// What the counts cannot say: "← syncing.md · 91% similar", "4.1 KB → 4.5 KB", "now executable".
        public var detail: String?
    }

    /// Files grouped by leading folders, for a huge patch ("vendor/swift-nio/ · 612 files").
    public struct FolderGroup: Sendable, Equatable, Hashable {
        public var path: String
        public var fileCount: Int
        public var additions: Int
        public var deletions: Int
    }

    /// Files largest first: most changed lines, then path, so the order is stable.
    public var files: [FileRow]
    /// Totals over the whole input (files past the listing cap included).
    public var fileCount: Int
    public var additions: Int
    public var deletions: Int
    /// Listed files per kind, in the lead's order.
    public var kindCounts: [(kind: DiffChangeKind, count: Int)]
    /// "3 files changed: 2 edited, 1 renamed; 41 lines added, 12 removed".
    public var lead: String
    /// The commit's subject, author, date and message when the patch carries them (the first commit of a series).
    public var subject: String?
    public var author: String?
    public var date: Date?
    public var message: String?
    public var commitCount: Int
    /// "Showing 40 of 1,284 files" when the patch was capped.
    public var coverageNote: String?

    public static func == (a: DiffSummary, b: DiffSummary) -> Bool {
        a.files == b.files && a.fileCount == b.fileCount && a.additions == b.additions && a.deletions == b.deletions
            && a.kindCounts.map(\.kind) == b.kindCounts.map(\.kind) && a.kindCounts.map(\.count) == b.kindCounts.map(\.count)
            && a.lead == b.lead && a.subject == b.subject && a.author == b.author && a.date == b.date
            && a.message == b.message && a.commitCount == b.commitCount && a.coverageNote == b.coverageNote
    }

    static let kindOrder: [DiffChangeKind] = [.modified, .added, .deleted, .renamed, .copied, .modeChanged, .binary]

    public init(patch: Patch) {
        files = Self.rows(patch.files)
        fileCount = patch.totals.files
        additions = patch.totals.additions
        deletions = patch.totals.deletions
        kindCounts = Self.kinds(patch.files)
        commitCount = patch.commits.count
        let commit = patch.commits.first
        subject = commit?.subject
        author = commit?.authorName ?? commit?.author
        date = commit?.date
        message = commit.flatMap { $0.body.isEmpty ? nil : $0.body }
        coverageNote = patch.coverage.note
        let complete = patch.files.count == patch.totals.files
        lead = Self.lead(files: patch.files, fileCount: fileCount, kinds: complete ? kindCounts : [],
                         additions: additions, deletions: deletions,
                         emptyText: patch.preamble.isEmpty && !patch.issues.contains { $0.severity == .error && $0.kind != .noDiffFound }
                             ? String(localized: "No changes", bundle: .module, comment: "Lead sentence of a diff summary. The patch changes nothing.") : String(localized: "No diff found", bundle: .module, comment: "Lead sentence of a diff summary. The file holds no diff."))
    }

    public init(comparison: TextComparison) {
        let file = comparison.file
        files = comparison.status == .identical ? [] : Self.rows([file])
        fileCount = comparison.status == .identical ? 0 : 1
        additions = comparison.additions
        deletions = comparison.deletions
        kindCounts = files.isEmpty ? [] : [(file.kind, 1)]
        commitCount = 0
        coverageNote = comparison.isSimplified ? String(localized: "Simplified: the compare hit its time or size limit", bundle: .module, comment: "Coverage note for a two-file compare.") : nil
        switch comparison.status {
        case .identical:
            lead = String(localized: "These files are identical", bundle: .module, comment: "Lead sentence of a diff summary.")
        case .whitespaceOnly where additions == 0 && deletions == 0:
            lead = String(localized: "Same text, different whitespace", bundle: .module, comment: "Lead sentence of a diff summary.")
        case .whitespaceOnly:
            let summary = comparison.whitespace?.summary ?? ""
            lead = String(localized: "Same text, different whitespace: \(summary)", bundle: .module, comment: "Lead sentence of a diff summary. The argument lists what whitespace differs.")
        case .binary:
            let sizes = file.binary.flatMap(Self.binaryDetail)
            lead = sizes.map { String(localized: "Binary files differ: \($0)", bundle: .module, comment: "Lead sentence of a diff summary. The argument gives the sizes, such as 12 KB → 14 KB.") }
                ?? String(localized: "Binary files differ", bundle: .module, comment: "Lead sentence of a diff summary.")
        case .different:
            let n = comparison.changes.count
            let counts = Self.lineCounts(additions: additions, deletions: deletions)
            lead = n == 1 ? String(localized: "1 change: \(counts)", bundle: .module, comment: "Lead sentence of a diff summary. The argument counts the lines added and removed.")
                : String(localized: "\(n.formatted()) changes: \(counts)", bundle: .module, comment: "Lead sentence of a diff summary. The last argument counts the lines added and removed.")
        }
    }

    /// At most `limit` rows and how many more there are ("and N more").
    public func topFiles(_ limit: Int = 5) -> (rows: [FileRow], more: Int) {
        (Array(files.prefix(limit)), max(0, files.count - limit))
    }

    /// Files grouped by their first `depth` folders, biggest group first. A file at a shallower level is its own
    /// group under its path.
    public func folders(depth: Int = 2) -> [FolderGroup] {
        var groups: [String: FolderGroup] = [:]
        var order: [String] = []
        for row in files {
            let parts = row.path.split(separator: "/", omittingEmptySubsequences: false)
            let key = parts.count > depth ? parts.prefix(max(1, depth)).joined(separator: "/") + "/" : row.path
            if groups[key] == nil { order.append(key); groups[key] = FolderGroup(path: key, fileCount: 0, additions: 0, deletions: 0) }
            groups[key]?.fileCount += 1
            groups[key]?.additions += row.additions
            groups[key]?.deletions += row.deletions
        }
        return order.compactMap { groups[$0] }.sorted {
            let (sa, sb) = ($0.additions + $0.deletions, $1.additions + $1.deletions)
            return sa != sb ? sa > sb : $0.path < $1.path
        }
    }

    // MARK: - Building

    static func rows(_ files: [DiffFile]) -> [FileRow] {
        files.enumerated().map { index, file in
            let path = file.path
            let slash = path.lastIndex(of: "/")
            return FileRow(index: index, path: path,
                           directory: slash.map { String(path[...$0]) } ?? "",
                           name: slash.map { String(path[path.index(after: $0)...]) } ?? path,
                           kind: file.kind, additions: file.additions, deletions: file.deletions, detail: detail(file))
        }.sorted {
            let (sa, sb) = ($0.additions + $0.deletions, $1.additions + $1.deletions)
            return sa != sb ? sa > sb : ($0.path != $1.path ? $0.path < $1.path : $0.index < $1.index)
        }
    }

    static func kinds(_ files: [DiffFile]) -> [(kind: DiffChangeKind, count: Int)] {
        var counts: [DiffChangeKind: Int] = [:]
        for file in files { counts[file.kind, default: 0] += 1 }
        return kindOrder.compactMap { kind in counts[kind].map { (kind, $0) } }
    }

    static func detail(_ file: DiffFile) -> String? {
        var parts: [String] = []
        if file.isRenamed || file.isCopied, let old = file.oldPath, old != file.newPath {
            parts.append(file.similarity.map { String(localized: "← \(old) · \($0)% similar", bundle: .module, comment: "File detail in a diff summary: the old name of a renamed or copied file and how similar the two are.") } ?? "← \(old)")
        }
        if let binary = file.binary, let sizes = binaryDetail(binary) { parts.append(sizes) }
        if let mode = modeDetail(file) { parts.append(mode) }
        if file.isCombined { parts.append(String(localized: "merge of \(file.parentCount) parents", bundle: .module, comment: "File detail in a diff summary: a merge's combined diff.")) }
        if file.isDetailOmitted { parts.append(String(localized: "counted, not shown", bundle: .module, comment: "File detail in a diff summary: the file's lines are counted but not drawn.")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func binaryDetail(_ binary: DiffBinary) -> String? {
        func size(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
        switch (binary.oldSize, binary.newSize) {
        case let (old?, new?) where old > 0 && new > 0: return "\(size(old)) → \(size(new))"
        case let (_, new?) where new > 0: return size(new)
        case let (old?, _) where old > 0: return size(old)
        default: return nil
        }
    }

    static func modeDetail(_ file: DiffFile) -> String? {
        if file.isNewFile, let mode = file.newMode {
            switch mode.kind {
            case .symlink: return String(localized: "symlink", bundle: .module, comment: "File detail in a diff summary: a new symbolic link.")
            case .submodule: return String(localized: "submodule", bundle: .module, comment: "File detail in a diff summary: a new git submodule.")
            case .executable: return String(localized: "executable", bundle: .module, comment: "File detail in a diff summary: a new executable file.")
            default: return nil
            }
        }
        guard file.isModeChange, let old = file.oldMode, let new = file.newMode else { return nil }
        switch (old.kind, new.kind) {
        case (.regular, .executable): return String(localized: "now executable", bundle: .module, comment: "File detail in a diff summary: the file became executable.")
        case (.executable, .regular): return String(localized: "no longer executable", bundle: .module, comment: "File detail in a diff summary.")
        case (_, .symlink): return String(localized: "now a symlink", bundle: .module, comment: "File detail in a diff summary.")
        case (.symlink, _): return String(localized: "no longer a symlink", bundle: .module, comment: "File detail in a diff summary.")
        default: return String(localized: "mode \(old.octal) → \(new.octal)", bundle: .module, comment: "File detail in a diff summary: the file's permission bits changed, in octal.")
        }
    }

    static func lineCounts(additions: Int, deletions: Int) -> String {
        switch (additions, deletions) {
        case (0, 0): return String(localized: "no lines changed", bundle: .module, comment: "Line counts in a diff summary.")
        case (1, 0): return String(localized: "1 line added", bundle: .module, comment: "Line counts in a diff summary.")
        case (_, 0): return String(localized: "\(additions.formatted()) lines added", bundle: .module, comment: "Line counts in a diff summary.")
        case (0, 1): return String(localized: "1 line removed", bundle: .module, comment: "Line counts in a diff summary.")
        case (0, _): return String(localized: "\(deletions.formatted()) lines removed", bundle: .module, comment: "Line counts in a diff summary.")
        case (1, _): return String(localized: "1 line added, \(deletions.formatted()) removed", bundle: .module, comment: "Line counts in a diff summary: one line added and some removed.")
        default: return String(localized: "\(additions.formatted()) lines added, \(deletions.formatted()) removed", bundle: .module, comment: "Line counts in a diff summary.")
        }
    }

    static func lead(files: [DiffFile], fileCount: Int, kinds: [(kind: DiffChangeKind, count: Int)], additions: Int,
                     deletions: Int, emptyText: String) -> String {
        guard fileCount > 0 else { return emptyText }
        let counts = lineCounts(additions: additions, deletions: deletions)
        if fileCount == 1, let file = files.first, kinds.count == 1 {
            let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
            let headline = Self.headline(name, file.kind)
            return additions == 0 && deletions == 0 ? headline
                : String(localized: "\(headline); \(counts)", bundle: .module, comment: "Lead sentence of a diff summary. The first argument says what happened to a file, the second counts the lines.")
        }
        let head = fileCount == 1 ? String(localized: "1 file changed", bundle: .module, comment: "Lead sentence of a diff summary.") : String(localized: "\(fileCount.formatted()) files changed", bundle: .module, comment: "Lead sentence of a diff summary.")
        guard !kinds.isEmpty else { return String(localized: "\(head); \(counts)", bundle: .module, comment: "Lead sentence of a diff summary. The first argument counts the files, the second the lines.") }
        let breakdown = kinds.map { Self.count($0.count, $0.kind) }.joined(separator: ", ")
        return String(localized: "\(head): \(breakdown); \(counts)", bundle: .module, comment: "Lead sentence of a diff summary. The arguments: files changed, then a list such as 2 edited, 1 added, then the line counts.")
    }

    /// "README.md edited": one file's name and what happened to it, as one phrase per kind.
    static func headline(_ name: String, _ kind: DiffChangeKind) -> String {
        switch kind {
        case .added: return String(localized: "\(name) added", bundle: .module, comment: "Lead sentence of a diff summary for a single file; the argument is the file name.")
        case .deleted: return String(localized: "\(name) deleted", bundle: .module, comment: "Lead sentence of a diff summary for a single file; the argument is the file name.")
        case .renamed: return String(localized: "\(name) renamed", bundle: .module, comment: "Lead sentence of a diff summary for a single file; the argument is the file name.")
        case .copied: return String(localized: "\(name) copied", bundle: .module, comment: "Lead sentence of a diff summary for a single file; the argument is the file name.")
        case .binary: return String(localized: "\(name) changed (binary)", bundle: .module, comment: "Lead sentence of a diff summary for a single binary file; the argument is the file name.")
        case .modeChanged: return String(localized: "\(name) mode changed", bundle: .module, comment: "Lead sentence of a diff summary for a single file whose permissions changed; the argument is the file name.")
        case .modified: return String(localized: "\(name) edited", bundle: .module, comment: "Lead sentence of a diff summary for a single file; the argument is the file name.")
        }
    }

    /// "2 edited": how many files had one kind of change.
    static func count(_ n: Int, _ kind: DiffChangeKind) -> String {
        let n = n.formatted()
        switch kind {
        case .added: return String(localized: "\(n) added", bundle: .module, comment: "Part of a list in a diff summary: how many files were added.")
        case .deleted: return String(localized: "\(n) deleted", bundle: .module, comment: "Part of a list in a diff summary: how many files were deleted.")
        case .renamed: return String(localized: "\(n) renamed", bundle: .module, comment: "Part of a list in a diff summary: how many files were renamed.")
        case .copied: return String(localized: "\(n) copied", bundle: .module, comment: "Part of a list in a diff summary: how many files were copied.")
        case .binary: return String(localized: "\(n) binary", bundle: .module, comment: "Part of a list in a diff summary: how many binary files changed.")
        case .modeChanged: return String(localized: "\(n) mode changed", bundle: .module, comment: "Part of a list in a diff summary: how many files had their permissions changed.")
        case .modified: return String(localized: "\(n) edited", bundle: .module, comment: "Part of a list in a diff summary: how many files were edited.")
        }
    }
}
