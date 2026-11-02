import AppKit
import UniformTypeIdentifiers
import VitrineDocument
import VitrineGit
import VitrineSupport
import VitrineUI

/// Folders in the picked browse design (r3-a Quiet outline), the archive outline's sibling: path row, kinds hairline,
/// then a Finder-grade list (Name, Date, Size, Kind) sorted and grouped like Finder, or an icon grid (the viewer
/// switch's List and Icons). Each folder is read only when it is opened, so a folder of any size opens at once;
/// apps and other packages stay closed, as in Finder; hidden items are counted, not listed. Sizes are counted in
/// the background after the first paint; the hairline opens the storage overview; folders can be entered and left
/// by the path row; a file can be peeked at beside the list. The counts live in the capsule's pill. roadmap: S-9
///
/// A git repository (a `.git` folder or `gitdir:` file, or a bare repository) adds the design's repository card
/// (E-6): the band with branch, commits to push, the latest commit and the uncommitted changes, the outline in a
/// card whose columns become each item's last commit and when, and the README card. Everything comes from the
/// files in `.git` (VitrineGit); no git process runs. The first paint waits a moment for the whole read and
/// otherwise shows the quick part (HEAD, commits, README) and fills in the rest when it lands. roadmap: S-9
@MainActor
public final class FolderRenderer: NSObject, Renderer {
    public static func canRender(_ kind: FileKind) -> Bool { kind == .folder }
    public override required init() { super.init() }
    private var outline: FolderOutline?
    private var fill: Task<Void, Never>?
    var outlineForTesting: FolderOutline? { outline }
    private(set) var viewForTesting: FolderView?
    /// How long the first paint waits for the full repository read before showing the quick part.
    static var firstPaintWait: Duration = .milliseconds(250)
    /// How often a running count may refresh the pill.
    static let pillRefresh: Duration = .milliseconds(700)

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        let root = FolderNode(url: url, isFolder: true)
        _ = root.children()
        var read: RepositoryRead?
        var pending: Task<RepositoryRead, Never>?
        if let repo = GitRepository(folder: url) {
            let full = Task.detached(priority: .userInitiated) { RepositoryRead.read(repo, parts: .all) }
            if Self.firstPaintWait > .zero, let done = await Self.value(of: full, within: Self.firstPaintWait) {
                read = done
            } else {
                read = await Task.detached(priority: .userInitiated) { RepositoryRead.read(repo, parts: []) }.value
                pending = full
            }
        }
        // A skill's or agent's instructions get the header card (P-5); a repository keeps its own page.
        let skill = read == nil ? await Task.detached(priority: .userInitiated) { SkillInfo.read(url) }.value : nil
        let outline = FolderOutline(root: root, git: read.map { FolderOutline.GitColumns(read: $0, root: url) })
        self.outline = outline
        let view = FolderView(root: root, outline: outline, repository: read, skill: skill)
        viewForTesting = view
        let preview = RenderedPreview(view: view, document: Self.document(view: view), owner: self,
                               reload: { [weak outline, weak view] url in
                                   outline?.reload()
                                   if let repo = GitRepository(folder: url) {
                                       let fresh = await Task.detached(priority: .userInitiated) { RepositoryRead.read(repo, parts: .all) }.value
                                       outline?.git = FolderOutline.GitColumns(read: fresh, root: url)
                                       view?.updateRepository(fresh)
                                   }
                                   view?.startSizing()
                                   guard let view else { return PreviewDocument(kind: .folder, views: [.text("")]) }
                                   return Self.document(view: view)
                               },
                               scrollOffset: { [weak view] in view.map { Double($0.scroll.contentView.bounds.origin.y) } },
                               restoreScroll: { [weak view] y in
                                   guard let scroll = view?.scroll else { return }
                                   scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                                   scroll.reflectScrolledClipView(scroll.contentView)
                               },
                               find: { [weak outline] q, forward in outline?.find(q, forward: forward) ?? FindResult(count: 0, index: -1) },
                               clearFind: { [weak outline] in outline?.clearFind() },
                               showView: { [weak view] index in view?.showView(index) ?? false })
        preview.cancelWork = { [weak view] in view?.stopSizing() }
        view.onGutter = { [weak preview] in preview?.updateGutter($0) }
        view.onPlaceChange = { [weak preview, weak view] in
            guard let preview, let view else { return }
            preview.updateDocument(Self.document(view: view))
        }
        // A plain folder's pill shows the size as it is counted (a repository's root shows its tracked bytes).
        var lastPill = ContinuousClock.now.advanced(by: .seconds(-10))
        view.onSizes = { [weak preview, weak view] sizes in
            guard let preview, let view, !view.atRepositoryRoot else { return }
            let now = ContinuousClock.now
            guard sizes.finished || now - lastPill >= Self.pillRefresh else { return }
            lastPill = now
            preview.updateDocument(Self.document(view: view))
        }
        if let pending {
            fill = Task { @MainActor [weak outline, weak view, weak preview] in
                let full = await pending.value
                guard !Task.isCancelled, let outline, let view, let preview else { return }
                outline.git = FolderOutline.GitColumns(read: full, root: url)
                view.updateRepository(full)
                preview.updateDocument(Self.document(view: view))
            }
        }
        view.startSizing()
        return preview
    }

    /// The task's value if it finishes within `wait`, else nil (the task keeps running).
    private static func value(of task: Task<RepositoryRead, Never>, within wait: Duration) async -> RepositoryRead? {
        await withTaskGroup(of: RepositoryRead?.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: wait); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Waits for the background read started by `render` (tests).
    func waitForRepositoryFill() async { await fill?.value }

    /// The document for the place on screen: the previewed folder, or a subfolder navigated into.
    static func document(view: FolderView) -> PreviewDocument {
        let place = view.place
        return document(url: place.url, top: place.children(), hidden: place.hiddenCount, truncated: place.truncated, total: place.totalCount,
                        git: view.atRepositoryRoot ? view.read?.summary : nil, sizes: view.sizes)
    }

    static func document(url: URL, top: [FolderNode], hidden: Int, truncated: Bool, total: Int? = nil, git: GitSummary? = nil,
                         sizes: FolderSizes? = nil) -> PreviewDocument {
        let folders = top.filter(\.isFolder).count, files = top.count - folders
        let bytes = top.filter { !$0.isFolder }.reduce(Int64(0)) { $0 + $1.size }
        let shown = truncated ? (total ?? top.count) : top.count
        let itemCount = shown.formatted(), folderCount = folders.formatted(), hiddenCount = hidden.formatted()
        var parts = [shown == 1
            ? String(localized: "\(itemCount) item", bundle: .previewKit, comment: "Folder summary: one item.")
            : String(localized: "\(itemCount) items", bundle: .previewKit, comment: "Folder summary: how many items the folder shows.")]
        if folders > 0 {
            switch (folders == 1, truncated) {
            case (true, false): parts.append(String(localized: "\(folderCount) folder", bundle: .previewKit, comment: "Folder summary: one subfolder."))
            case (false, false): parts.append(String(localized: "\(folderCount) folders", bundle: .previewKit, comment: "Folder summary: how many subfolders."))
            case (true, true): parts.append(String(localized: "\(folderCount) folder+", bundle: .previewKit, comment: "Folder summary: at least one subfolder (the list was cut short; the plus says the count is a floor)."))
            case (false, true): parts.append(String(localized: "\(folderCount) folders+", bundle: .previewKit, comment: "Folder summary: at least this many subfolders (the list was cut short; the plus says the count is a floor)."))
            }
        }
        if hidden > 0 { parts.append(String(localized: "\(hiddenCount) hidden", bundle: .previewKit, comment: "Folder summary: how many hidden items.")) }
        let headline = parts.joined(separator: " · ")
        var facts = [Fact(key: "headline", label: String(localized: "Summary", bundle: .previewKit, comment: "Fact label: the one-line summary of the file."), value: git.map(GitText.headline) ?? headline),
                     Fact(key: "items", label: String(localized: "Items", bundle: .previewKit, comment: "Fact label: number of items in the folder."), value: shown.formatted()),
                     Fact(key: "folders", label: String(localized: "Folders", bundle: .previewKit, comment: "Fact label: number of subfolders."), value: folders.formatted() + (truncated ? "+" : "")),
                     Fact(key: "files", label: String(localized: "Files", bundle: .previewKit, comment: "Fact label: number of files."), value: files.formatted() + (truncated ? "+" : "")),
                     Fact(key: "hidden", label: String(localized: "Hidden items", bundle: .previewKit, comment: "Fact label: number of hidden items."), value: hidden.formatted()),
                     Fact(key: "filesSize", label: String(localized: "Files at this level", bundle: .previewKit, comment: "Fact label: the total size of the files directly in this folder."),
                          value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))]
        if git == nil, let sizes, sizes.totalItems > 0 || sizes.finished {
            facts.append(Fact(key: "size", label: String(localized: "Size", bundle: .previewKit, comment: "Fact label: the file size."), value: sizeText(sizes)))
            let inside = sizes.totalItems.formatted()
            facts.append(Fact(key: "deepItems", label: String(localized: "Items inside", bundle: .previewKit, comment: "Fact label: how many items the folder holds at every depth."),
                              value: sizes.complete ? inside : String(localized: "at least \(inside)", bundle: .previewKit, comment: "A count that is a floor (counting stopped early); the argument is a formatted number.")))
        }
        if let git { facts += GitText.facts(git) }
        let listing = top.map { $0.name + ($0.isFolder ? "/" : "") }.joined(separator: "\n")
        var document = PreviewDocument(kind: .folder, dialect: git == nil ? nil : "git", facts: facts, views: [.text(listing), .text(listing)],
                                       coverage: truncated ? .partial(shown: Int64(top.count), total: total.map(Int64.init), unit: .members, reason: String(localized: "Large folder", bundle: .previewKit, comment: "Coverage note: the folder has more items than the list shows.")) : .complete)
        document.viewTitles = ["List",
                                "Icons"]
        return document
    }

    /// "48.2 GB", "412 MB so far" while counting, "at least 412 MB" when the count stopped early.
    static func sizeText(_ s: FolderSizes) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: s.totalBytes, countStyle: .file)
        if s.complete { return bytes }
        return s.finished
            ? String(localized: "at least \(bytes)", bundle: .previewKit, comment: "A folder size that is a floor (counting stopped early); the argument is a size.")
            : String(localized: "\(bytes) so far", bundle: .previewKit, comment: "A folder size while it is still being counted; the argument is a size.")
    }

    static func shares(_ top: [FolderNode]) -> [(token: String, share: Double)] {
        var bytes: [String: Int64] = [:]
        for n in top where !n.isFolder { bytes[FolderSizer.kindToken(name: n.name, isPackage: n.isPackage), default: 0] += n.size }
        let total = Double(bytes.values.reduce(0, +))
        guard total > 0 else { return [] }
        return bytes.sorted { $0.value > $1.value }.map { ($0.key, Double($0.value) / total) }
    }
}

/// One item of the folder, read lazily. roadmap: S-9
@MainActor
final class FolderNode: NSObject {
    /// Items listed per folder; the rest are counted, not listed (tests lower it).
    static var cap = 5_000
    let url: URL
    let name: String
    let isFolder: Bool
    /// An app or other bundle: shown closed, as a file.
    let isPackage: Bool
    let size: Int64
    let kind: String
    let modified: Date?
    /// When the item was put in its folder (Finder's Date Added).
    let added: Date?
    let tags: [FinderTag]
    /// An iCloud item whose content is not on this Mac: never read, never thumbnailed (R-5).
    let isCloudOnly: Bool
    private(set) var hiddenCount = 0
    private(set) var truncated = false
    /// Every item that is not hidden, listed or not (the list stops at `cap`).
    private(set) var totalCount = 0
    private var loaded: [FolderNode]?

    init(url: URL, isFolder: Bool, isPackage: Bool = false, size: Int64 = 0, kind: String = FolderNode.folderKind, modified: Date? = nil,
         added: Date? = nil, tags: [FinderTag] = [], isCloudOnly: Bool = false) {
        self.url = url; name = url.lastPathComponent; self.isFolder = isFolder; self.isPackage = isPackage; self.size = size; self.kind = kind
        self.modified = modified; self.added = added; self.tags = tags; self.isCloudOnly = isCloudOnly
    }

    /// The Kind column's word for a folder, and for an item macOS gives no kind.
    static let folderKind = String(localized: "Folder", bundle: .previewKit, comment: "Kind column: the item is a folder.")
    static let documentKind = String(localized: "Document", bundle: .previewKit, comment: "Kind column: an item macOS names no kind for.")

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .localizedTypeDescriptionKey,
                                         .contentModificationDateKey, .addedToDirectoryDateKey, .tagNamesKey, .isUbiquitousItemKey,
                                         .ubiquitousItemDownloadingStatusKey]

    func children() -> [FolderNode] {
        if let loaded { return loaded }
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Self.keys, options: [])) ?? []
        var out: [FolderNode] = []
        hiddenCount = 0
        totalCount = 0
        for u in urls {
            let v = try? u.resourceValues(forKeys: Set(Self.keys))
            if v?.isHidden == true || u.lastPathComponent.hasPrefix(".") { hiddenCount += 1; continue }
            totalCount += 1
            // Past the cap the rest is only counted, so the list can say how much it does not show (R-4).
            if out.count == Self.cap { truncated = true; continue }
            let package = v?.isDirectory == true && v?.isPackage == true
            let folder = v?.isDirectory == true && !package
            let cloudOnly = v?.isUbiquitousItem == true && v?.ubiquitousItemDownloadingStatus.map { $0 != .current } == true
            out.append(FolderNode(url: u, isFolder: folder, isPackage: package, size: Int64(v?.fileSize ?? 0),
                                  kind: folder ? Self.folderKind : (v?.localizedTypeDescription ?? Self.documentKind), modified: v?.contentModificationDate,
                                  added: v?.addedToDirectoryDate, tags: FinderTag.read(u, names: v?.tagNames), isCloudOnly: cloudOnly && !folder))
        }
        out.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        loaded = out
        return out
    }

    func forget() { loaded = nil; hiddenCount = 0; truncated = false; totalCount = 0 }
}

/// A folder's item in the peek drawer: read from disk by the drawer, bounded; never an iCloud item that is not
/// downloaded. roadmap: S-9
extension FolderNode: PeekItem {
    struct NotDownloaded: LocalizedError {
        var errorDescription: String? {
            String(localized: "In iCloud only: Vitrine never downloads it", bundle: .previewKit, comment: "Peek message for an item that is only in iCloud.")
        }
    }

    var peekName: String { name }
    var peekKind: String { kind }
    var peekSize: Int64? { isFolder ? nil : size }
    var peekFacts: [(label: String, value: String)] {
        var facts: [(String, String)] = []
        if let modified {
            facts.append((String(localized: "Modified", bundle: .previewKit, comment: "Peek fact label: when the item was last changed."), modified.formatted(date: .abbreviated, time: .shortened)))
        }
        if let added {
            facts.append((String(localized: "Added", bundle: .previewKit, comment: "Peek fact label: when the item was added to its folder."), added.formatted(date: .abbreviated, time: .shortened)))
        }
        if !tags.isEmpty {
            facts.append((String(localized: "Tags", bundle: .previewKit, comment: "Peek fact label: the item's Finder tags."), tags.map(\.name).formatted(.list(type: .and))))
        }
        return facts
    }

    func loadPeek(maxBytes: Int) async throws -> PeekPayload {
        if isCloudOnly { throw NotDownloaded() }
        return .file(url)
    }
}
