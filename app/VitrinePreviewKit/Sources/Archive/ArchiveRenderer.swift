import AppKit
import UniformTypeIdentifiers
import VitrineArchive
import VitrineDocument
import VitrineSupport
import VitrineUI

/// Archives in the picked browse design (r3-a Quiet outline, design/mockups/unified/browse.html): a 34 pt path row
/// with the kinds hairline under it, then a Finder-grade outline (Name, Size, Packed, Ratio, Kind, Modified; 22 pt
/// zebra rows; danger and caution rows tinted). Nothing is extracted: the list comes from the archive's own
/// directory (VitrineArchive). The counts and the verdict live in the capsule's pill. An archive inside the archive
/// opens in place (double-click or Return): it is read into memory, never to disk, up to the nested limit (64 MB),
/// the path row's breadcrumbs name each level ("outer.zip › inner.tar.gz › docs") and go back to it, and ⌘↑ or
/// Delete steps out one level. roadmap: S-8
@MainActor
public final class ArchiveRenderer: NSObject, Renderer {
    /// Every archive, except the app packages that open on their card (BinaryCardRenderer shows their contents
    /// one switch away).
    public static func canRender(_ kind: FileKind) -> Bool {
        if case .archive(let format) = kind { return format != .ipa && format != .apk }
        return false
    }

    public override required init() { super.init() }

    private var outline: ArchiveOutline?

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        let model = try FamilyFacts.archiveModel(url: url, kind: kind)
        let source = try? FileByteSource(url: url)
        let view = ArchiveView(model: model, archiveName: url.lastPathComponent, source: source, kind: kind)
        view.archiveURL = url
        outline = view.outline
        let preview = RenderedPreview(view: view, document: model.document, owner: self,
                                      scrollOffset: { [weak view] in view.map { Double($0.scroll.contentView.bounds.origin.y) } },
                                      restoreScroll: { [weak view] y in
                                          guard let scroll = view?.scroll else { return }
                                          scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                                          scroll.reflectScrolledClipView(scroll.contentView)
                                      },
                                      find: { [weak view] q, forward in view?.outline.find(q, forward: forward) ?? FindResult(count: 0, index: -1) },
                                      clearFind: { [weak view] in view?.outline.clearFind() })
        view.onDocumentChange = { [weak preview] document in preview?.updateDocument(document) }
        view.onStatus = { [weak preview] status in preview?.updateGutter(status) }
        return preview
    }
}

/// The path row, the kinds hairline and the outline, for the archive and for every archive opened inside it. The
/// levels form a stack: the file's own listing first, then each nested archive with the bytes it was read from.
/// roadmap: S-8
@MainActor
final class ArchiveView: NSView {
    /// One archive on the stack: its name in the breadcrumbs, the bytes its members are read from (nil when there
    /// are none to read, as for a torrent's file list), and what was drawn from its listing.
    struct Level {
        let name: String
        let source: (any ArchiveByteSource)?
        let model: FamilyFacts.ArchiveModel
    }

    let scroll = NSScrollView()
    /// The peek drawer beside the list (browse r3-a): a member read into memory up to its bound, never to disk.
    let drawer = PeekDrawer()
    private(set) var peeking: Int?
    private var drawerWidth: NSLayoutConstraint!
    private var scrollTrailing: NSLayoutConstraint!
    private(set) var outline: ArchiveOutline
    private(set) var levels: [Level]
    /// The archive on disk: members of its own listing can be extracted through VitrineHelper (X-3); members of a
    /// nested archive live only in memory, so the button is hidden for them.
    var archiveURL: URL?
    private(set) var pathRow: PathRow!
    private let kind: FileKind
    private let pathHost = NSView()
    private let kindsHost = NSView()
    private var opening: Task<Void, Never>?
    /// The level shown changed: the pill follows the archive on screen.
    var onDocumentChange: ((PreviewDocument) -> Void)?
    /// What the gutter says while a nested archive opens, or why it could not.
    var onStatus: ((GutterStatus?) -> Void)?

    init(model: FamilyFacts.ArchiveModel, archiveName: String, source: (any ArchiveByteSource)?, kind: FileKind) {
        levels = [Level(name: archiveName, source: source, model: model)]
        self.kind = kind
        outline = ArchiveOutline(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        drawer.isHidden = true
        for v in [pathHost, kindsHost, scroll, drawer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        drawerWidth = drawer.widthAnchor.constraint(equalToConstant: 430)
        scrollTrailing = scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        drawer.onStep = { [weak self] delta in self?.step(delta) }
        drawer.onClose = { [weak self] in self?.closePeek() }
        NSLayoutConstraint.activate([
            drawer.topAnchor.constraint(equalTo: scroll.topAnchor), drawer.bottomAnchor.constraint(equalTo: bottomAnchor),
            drawer.trailingAnchor.constraint(equalTo: trailingAnchor), drawerWidth, scrollTrailing,
            pathHost.topAnchor.constraint(equalTo: topAnchor), pathHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            pathHost.trailingAnchor.constraint(equalTo: trailingAnchor), pathHost.heightAnchor.constraint(equalToConstant: Metric.value("h-strip")),
            kindsHost.topAnchor.constraint(equalTo: pathHost.bottomAnchor), kindsHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            kindsHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), kindsHost.heightAnchor.constraint(equalToConstant: 3),
            scroll.topAnchor.constraint(equalTo: kindsHost.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        showTopLevel()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        let width = PeekDrawer.width(for: bounds.width)
        if drawerWidth.constant != width { drawerWidth.constant = width }
        let inset = peeking == nil ? 0 : -width
        if scrollTrailing.constant != inset { scrollTrailing.constant = inset }
        super.layout()
    }

    /// Draws the top level of the stack: its breadcrumbs, its kinds and its outline.
    private func showTopLevel() {
        closePeek()
        let level = levels[levels.count - 1]
        outline = ArchiveOutline(model: level.model)
        outline.table.target = self
        outline.table.doubleAction = #selector(openClicked)
        outline.onKey = { [weak self] key in self?.handle(key) ?? false }
        outline.onSelection = { [weak self] entry in
            guard let self, self.peeking != nil, let entry, entry != self.peeking else { return }
            self.peek(entryIndex: entry)
        }
        let top = outline.listsTopFolder ? level.model.summary.singleTopFolder : nil
        let row = PathRow(segments: levels.map(\.name) + (top.map { [$0] } ?? []), icon: Self.icon(for: kind)) { [weak self] i in
            self?.back(to: i)
        }
        row.clickableCount = levels.count - 1
        replace(in: pathHost, with: row)
        pathRow = row
        replace(in: kindsHost, with: KindsHairline(shares: KindsHairline.shares(level.model)))
        scroll.documentView = outline.table
        outline.ruler = RulerScroller.install(on: scroll)
        outline.expandDefault()
    }

    private func replace(in host: NSView, with view: NSView) {
        host.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: host.leadingAnchor), view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                                     view.topAnchor.constraint(equalTo: host.topAnchor), view.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
    }

    static func icon(for kind: FileKind) -> NSImage {
        switch kind {
        case .archive(.iso): NSWorkspace.shared.icon(for: UTType("public.iso-image") ?? .diskImage)
        default: NSWorkspace.shared.icon(for: .zip)
        }
    }

    // MARK: Peek

    /// Shows a member in the drawer: its first bytes read into memory (text, an image or its facts).
    func peek(entryIndex: Int) {
        let level = levels[levels.count - 1]
        guard let source = level.source, level.model.listing.entries.indices.contains(entryIndex) else { return }
        let entry = level.model.listing.entries[entryIndex]
        guard entry.type == .file || entry.type == .hardlink else { return }
        let wasOpen = peeking != nil
        peeking = entryIndex
        drawer.isHidden = false
        needsLayout = true
        drawer.show(ArchiveMemberPeek(source: source, archiveName: level.name, listing: level.model.listing, entryIndex: entryIndex))
        if levels.count == 1, let archive = archiveURL {
            let member = entry.path
            drawer.onExtract = { [weak self] in
                Task { @MainActor in
                    let result = await HelperClient.extract(member: member, from: archive)
                    let line = result.destination.map {
                        String(localized: "Saved to Downloads as \($0.lastPathComponent)", bundle: .previewKit,
                               comment: "Gutter after extracting one file from an archive; the argument is the file's name.")
                    } ?? result.error
                    self?.onStatus?(GutterStatus(leading: line))
                }
            }
        } else {
            drawer.onExtract = nil
        }
        if !wasOpen {
            layoutSubtreeIfNeeded()
            drawer.animateIn()
        }
        onStatus?(GutterStatus(trailing: String(localized: "esc back to the list", bundle: .previewKit,
                                                comment: "Gutter while the peek drawer is open: Escape returns to the list ('esc' is the key).")))
    }

    func closePeek() {
        guard peeking != nil else { return }
        peeking = nil
        drawer.stopLoading()
        drawer.isHidden = true
        needsLayout = true
        window?.makeFirstResponder(outline.table)
        onStatus?(nil)
    }

    /// ↑↓ in the drawer: the list moves its selection to the next member and the drawer follows it.
    private func step(_ delta: Int) {
        var row = outline.table.selectedRow
        repeat {
            row += delta
            guard row >= 0, row < outline.table.numberOfRows else { return }
        } while outline.entryIndex(atRow: row) == nil
        outline.table.selectRowIndexes([row], byExtendingSelection: false)
        outline.table.scrollRowToVisible(row)
    }

    // MARK: Nested archives

    /// Whether the member at `entryIndex` of the level on screen is an archive this view can open in place.
    func canOpen(entryIndex: Int) -> Bool {
        let level = levels[levels.count - 1]
        guard level.source != nil, level.model.listing.entries.indices.contains(entryIndex) else { return false }
        let entry = level.model.listing.entries[entryIndex]
        // A disk image's files need mounting, which a preview never does.
        let ext = (entry.path as NSString).pathExtension.lowercased()
        return entry.type == .file && !["dmg", "sparseimage", "sparsebundle"].contains(ext)
            && ArchiveOutline.kindToken(path: entry.path) == "kind-archive"
    }

    @objc private func openClicked() {
        guard let entry = outline.entryIndex(atRow: outline.table.clickedRow) else { return }
        if canOpen(entryIndex: entry) { open(entryIndex: entry) } else { peek(entryIndex: entry) }
    }

    private func handle(_ key: ArchiveOutline.Key) -> Bool {
        switch key {
        case .open:
            guard let entry = outline.entryIndex(atRow: outline.table.selectedRow) else { return false }
            if canOpen(entryIndex: entry) { open(entryIndex: entry) } else { peek(entryIndex: entry) }
            return true
        case .back:
            guard levels.count > 1 else { return false }
            back(to: levels.count - 2)
            return true
        }
    }

    /// Reads the member into memory off the main thread and shows it as the next level. A member past the nested
    /// limit, an encrypted one or one that is not an archive after all says why in the gutter and changes nothing.
    func open(entryIndex: Int) {
        guard canOpen(entryIndex: entryIndex), opening == nil, let source = levels.last?.source else { return }
        let parent = levels[levels.count - 1]
        let listing = parent.model.listing
        let name = ArchivePath.components(listing.entries[entryIndex].path).last ?? listing.entries[entryIndex].path
        let kind = self.kind
        onStatus?(GutterStatus(leading: String(localized: "Opening \(name)…", bundle: .previewKit, comment: "Gutter while an archive inside the archive opens."),
                               busy: true))
        opening = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(NestedArchive, FamilyFacts.ArchiveModel), Error> in
                Result {
                    let nested = try VitrineArchive.openNested(source: source, fileName: parent.name, listing: listing, entryIndex: entryIndex)
                    let model = FamilyFacts.archiveModel(listing: nested.listing, fileSize: nested.source.size, kind: kind)
                    return (nested, model)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.opening = nil
            switch result {
            case .success(let (nested, model)):
                self.push(Level(name: nested.name, source: nested.source, model: model))
            case .failure(let error):
                let reason = (error as? ArchiveError)?.reason ?? error.localizedDescription
                self.onStatus?(GutterStatus(leading: String(localized: "\(name) did not open: \(reason)", bundle: .previewKit,
                                                            comment: "Gutter when an archive inside the archive fails to open: its name, then the reason.")))
            }
        }
    }

    /// Shows `level` above the current one (also used by tests, which open levels directly).
    func push(_ level: Level) {
        levels.append(level)
        showTopLevel()
        onStatus?(nil)
        onDocumentChange?(level.model.document)
    }

    /// Back to the level at `index` in the breadcrumbs (0 = the file itself).
    func back(to index: Int) {
        guard index >= 0, index < levels.count - 1 else { return }
        opening?.cancel()
        opening = nil
        levels.removeSubrange((index + 1)...)
        showTopLevel()
        onStatus?(nil)
        onDocumentChange?(levels[levels.count - 1].model.document)
    }

    // A layer colour is resolved once; drawing it here follows light and dark.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("page").cgColor }
}

/// "orbit-sdk-2.4.0.zip › orbit-sdk-2.4.0": where you are. Shared by the archive and folder outlines. In an archive
/// opened inside another, the earlier segments are buttons that go back to that level. roadmap: S-8
@MainActor
final class PathRow: NSView {
    /// The segments as shown.
    let segments: [String]
    /// The first `clickableCount` segments go back to their level when clicked.
    var clickableCount = 0 { didSet { rebuild() } }
    private let onSelect: ((Int) -> Void)?
    private let iconView: NSImageView
    private var segmentViews: [NSView] = []
    private(set) var buttons: [NSButton] = []

    convenience init(archiveName: String, topFolder: String?, icon image: NSImage = NSWorkspace.shared.icon(for: .zip)) {
        self.init(segments: [archiveName] + (topFolder.map { [$0] } ?? []), icon: image, onSelect: nil)
    }

    init(segments: [String], icon image: NSImage = NSWorkspace.shared.icon(for: .zip), onSelect: ((Int) -> Void)?) {
        self.segments = segments
        self.onSelect = onSelect
        iconView = NSImageView(image: image)
        super.init(frame: .zero)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14), iconView.heightAnchor.constraint(equalToConstant: 14),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    /// One label for the segments nobody can click (truncating in the middle as before); a borderless button for
    /// each one that goes back to its level.
    private func rebuild() {
        segmentViews.forEach { $0.removeFromSuperview() }
        segmentViews = []
        buttons = []
        let size = Metric.value("fs-control")
        let separator = NSAttributedString(string: "  ›  ", attributes: [.foregroundColor: NSColor.token("t3"), .font: NSFont.systemFont(ofSize: size)])
        var views: [NSView] = []
        for i in 0..<min(clickableCount, segments.count) {
            let button = NSButton(title: segments[i], target: self, action: #selector(select(_:)))
            button.isBordered = false
            button.tag = i
            button.attributedTitle = NSAttributedString(string: segments[i], attributes: [
                .foregroundColor: NSColor.token("accent-text"), .font: NSFont.systemFont(ofSize: size),
            ])
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.toolTip = String(localized: "Back to \(segments[i])", bundle: .previewKit, comment: "Tooltip of a path crumb: go back to that folder.")
            buttons.append(button)
            views.append(button)
            views.append(NSTextField(labelWithAttributedString: separator))
        }
        let rest = segments.dropFirst(min(clickableCount, segments.count))
        let text = NSMutableAttributedString()
        for (j, part) in rest.enumerated() {
            if j > 0 { text.append(separator) }
            let last = j == rest.count - 1
            text.append(NSAttributedString(string: part, attributes: [
                .foregroundColor: NSColor.token(last ? "t1" : "t2"),
                .font: NSFont.systemFont(ofSize: size, weight: last ? .semibold : .regular),
            ]))
        }
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        views.append(label)
        var leading = iconView.trailingAnchor
        var gap: CGFloat = 6
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: leading, constant: gap), v.centerYAnchor.constraint(equalTo: centerYAnchor)])
            leading = v.trailingAnchor
            gap = 0
        }
        views.last?.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14).isActive = true
        segmentViews = views
    }

    @objc private func select(_ sender: NSButton) { onSelect?(sender.tag) }
}

/// The 3 pt bar under the path: the archive's bytes by kind, in the kind tokens (G19).
@MainActor
final class KindsHairline: NSView {
    private let shares: [(token: String, share: Double)]

    init(shares: [(token: String, share: Double)]) {
        self.shares = shares.filter { $0.share > 0 }
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    static func shares(_ model: FamilyFacts.ArchiveModel) -> [(token: String, share: Double)] {
        var bytes: [String: Int64] = [:]
        for e in model.listing.entries where e.type == .file {
            bytes[ArchiveOutline.kindToken(path: e.path), default: 0] += max(0, e.uncompressedSize ?? 0)
        }
        let total = Double(bytes.values.reduce(0, +))
        guard total > 0 else { return [] }
        return bytes.sorted { $0.value > $1.value }.map { ($0.key, Double($0.value) / total) }
    }

    override func draw(_ dirtyRect: NSRect) {
        var x = bounds.minX
        for (i, part) in shares.enumerated() {
            let w = i == shares.count - 1 ? bounds.maxX - x : (bounds.width * part.share).rounded()
            NSColor.token(part.token).setFill()
            NSBezierPath(rect: NSRect(x: x, y: 0, width: max(0, w - 1), height: bounds.height)).fill()
            x += w
        }
    }
}

/// The outline: one row per tree node, folders first, sizes on the right, danger and caution rows tinted.
@MainActor
final class ArchiveOutline: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Item: NSObject { let index: Int; init(_ i: Int) { index = i } }

    /// The keys the outline hands to its archive view: Return opens a nested archive, ⌘↑ or Delete steps out.
    enum Key { case open, back }

    /// Return the key was used; false lets the outline handle it as usual.
    var onKey: ((Key) -> Bool)? {
        get { (table as? KeyedOutlineView)?.onKey }
        set { (table as? KeyedOutlineView)?.onKey = newValue }
    }

    let table: NSOutlineView = KeyedOutlineView()

    /// The listing index of the entry on `row`; nil for a folder only implied by paths, or no row.
    func entryIndex(atRow row: Int) -> Int? {
        guard row >= 0, let item = table.item(atRow: row) as? Item else { return nil }
        return model.tree.nodes[item.index].entryIndex
    }
    var rootNodeName: String { model.tree.nodes[rootIndex].name }
    var listsTopFolder: Bool { rootIndex != model.tree.root.index }
    private let model: FamilyFacts.ArchiveModel
    private var items: [Int: Item] = [:]
    /// The node the outline lists: the archive's root, or its single top folder (named in the path row instead).
    private let rootIndex: Int
    private var packed: [Int: Int64] = [:]
    /// Entries a safety finding names (by index in the listing), with the most serious finding for each.
    private var flagged: [Int: SafetyFinding] = [:]

    init(model: FamilyFacts.ArchiveModel) {
        self.model = model
        let top = model.tree.children(of: model.tree.root)
        // Only a calm archive is listed from inside its top folder; with any danger finding the true top level
        // shows (a lone `..` folder must never become the outline's root).
        let calm = !model.safety.findings.contains { $0.level == .danger }
        rootIndex = calm && model.summary.singleTopFolder != nil && top.count == 1 && top[0].isFolder ? top[0].index : model.tree.root.index
        super.init()
        var byPath: [String: [Int]] = [:]
        for (i, e) in model.listing.entries.enumerated() { byPath[e.path, default: []].append(i) }
        for finding in model.safety.findings where finding.level != .info {
            for path in finding.paths {
                for i in byPath[path] ?? [] where (flagged[i]?.level ?? .info) < finding.level { flagged[i] = finding }
            }
        }
        computePacked(model.tree.root.index)
        let columns: [(String, String, Double, Bool)] = [
            ("name", String(localized: "Name", bundle: .previewKit, comment: "Archive list column."), 260, false),
            ("size", String(localized: "Size", bundle: .previewKit, comment: "Archive list column: the unpacked size."), 74, true),
            ("packed", Self.packedWord, 74, true),
            ("ratio", String(localized: "Ratio", bundle: .previewKit, comment: "Archive list column: packed size as a share of the size."), 54, true),
            ("kind", String(localized: "Kind", bundle: .previewKit, comment: "Archive list column: the file's kind."), 150, false),
            ("modified", Self.modifiedWord, 110, false),
        ]
        for (id, title, width, right) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.headerCell.alignment = right ? .right : .left
            table.addTableColumn(column)
            if id == "name" { table.outlineTableColumn = column }
        }
        table.rowHeight = Metric.value("h-row")
        // Zebra on real rows only (the `zebra` token), not on the empty space below the last row.
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.style = .fullWidth
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.reloadData()
    }

    private func item(_ index: Int) -> Item {
        if let i = items[index] { return i }
        let i = Item(index); items[index] = i; return i
    }

    private func node(_ item: Any?) -> ArchiveTree.Node {
        (item as? Item).map { model.tree.nodes[$0.index] } ?? model.tree.nodes[rootIndex]
    }

    @discardableResult
    private func computePacked(_ index: Int) -> Int64 {
        let n = model.tree.nodes[index]
        var total = n.entryIndex.flatMap { model.listing.entries[$0].compressedSize } ?? 0
        for child in n.children { total += computePacked(child) }
        packed[index] = total
        return total
    }

    /// The single top folder is already the outline's root, so the first screen shows real files. Folders holding a
    /// flagged entry open by themselves: a problem is never hidden behind a closed disclosure triangle.
    func expandDefault() {
        let nodeOfEntry = Dictionary(model.tree.nodes.compactMap { n in n.entryIndex.map { ($0, n.index) } }, uniquingKeysWith: { a, _ in a })
        for entry in flagged.keys.sorted() {
            guard var n = nodeOfEntry[entry].map({ model.tree.nodes[$0] }) else { continue }
            var chain: [Int] = []
            while let p = n.parent, p != rootIndex { chain.append(p); n = model.tree.nodes[p] }
            for folder in chain.reversed() { table.expandItem(item(folder)) }
        }
    }

    /// Archives VitrineArchive opens whose extensions the system does not declare as archives (or declares as
    /// something else, like an app package).
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "tzst", "lz4",
                                                 "lzma", "tlz", "lz", "z", "taz", "cpio", "rpm", "deb", "xar", "cab", "lha",
                                                 "lzh", "iso", "jar", "war", "ear", "ipa", "apk", "txz", "tbz", "tbz2"]

    static func kindToken(path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "kind-other" }
        if type.conforms(to: .archive) || archiveExtensions.contains(ext) { return "kind-archive" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "kind-code" }
        if type.conforms(to: .image) { return "kind-image" }
        if type.conforms(to: .audiovisualContent) { return "kind-media" }
        if ["json", "csv", "tsv", "yaml", "yml", "toml", "xml", "plist", "sqlite", "db"].contains(ext) { return "kind-data" }
        if type.conforms(to: .text) { return "kind-text" }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return "kind-app" }
        return "kind-other"
    }

    // MARK: Find (the capsule's find, S-24)

    private var findQuery = ""
    private var matches: [Int] = []
    /// The list's ruler (B-7): each match at its place in the whole archive, collapsed folders included.
    weak var ruler: RulerScroller?

    private func placeMarks() {
        let total = Double(max(1, model.tree.nodes.count))
        ruler?.marks = matches.enumerated().map { i, node in (Double(node) / total, i == findIndex ? .current : .match) }
    }
    private var findIndex = -1

    /// Every entry whose name contains the query, in outline order, open folders or not; the current one is
    /// revealed (its folders opened) and selected, as Finder's list view does.
    func find(_ q: String, forward: Bool) -> FindResult {
        if q != findQuery {
            findQuery = q
            findIndex = -1
            matches = []
            if !q.isEmpty {
                var stack = model.tree.nodes[rootIndex].children.reversed() as [Int]
                while let i = stack.popLast() {
                    let n = model.tree.nodes[i]
                    if n.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { matches.append(i) }
                    stack.append(contentsOf: n.children.reversed())
                }
            }
        }
        guard !matches.isEmpty else { table.deselectAll(nil); return FindResult(count: 0, index: -1) }
        findIndex = forward ? (findIndex + 1) % matches.count : (findIndex - 1 + matches.count) % matches.count
        reveal(matches[findIndex])
        placeMarks()
        return FindResult(count: matches.count, index: findIndex)
    }

    func clearFind() { findQuery = ""; matches = []; findIndex = -1; table.deselectAll(nil); ruler?.marks = [] }

    private func reveal(_ index: Int) {
        var chain: [Int] = []
        var n = model.tree.nodes[index]
        while let p = n.parent, p != rootIndex { chain.append(p); n = model.tree.nodes[p] }
        for folder in chain.reversed() { table.expandItem(item(folder)) }
        let row = table.row(forItem: item(index))
        guard row >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { node(item).children.count }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        self.item(node(item).children[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !node(item).children.isEmpty }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let n = node(item)
        let entry = n.entryIndex.map { model.listing.entries[$0] }
        let id = tableColumn?.identifier.rawValue ?? "name"
        let size = n.isFolder ? n.totalSize : (entry?.uncompressedSize ?? 0)
        let packedSize = packed[n.index] ?? 0
        let text: String
        switch id {
        case "name": text = n.name
        case "size": text = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        case "packed": text = model.listing.entries.contains { $0.compressedSize != nil } ? ByteCountFormatter.string(fromByteCount: packedSize, countStyle: .file) : "—"
        case "ratio": text = size > 0 && packedSize > 0 ? (Double(Int((Double(packedSize) / Double(size) * 100).rounded())) / 100).formatted(.percent) : "—"
        case "kind": text = n.isFolder ? String(localized: "Folder", bundle: .previewKit, comment: "Archive list kind: a folder.") : Self.kindName(n.name, entry: entry)
        // Time 0 is how archivers write "no date"; showing 1 January 1970 would be a made-up fact.
        default: text = entry?.modified?.date(in: .current).flatMap { $0.timeIntervalSince1970 == 0 ? nil : $0 }
            .map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.font = id == "name" ? .systemFont(ofSize: Metric.value("fs-control")) : .monospacedDigitSystemFont(ofSize: Metric.value("fs-control"), weight: .regular)
        let finding = n.entryIndex.flatMap { flagged[$0] }
        label.textColor = NSColor.token(id == "name" ? (finding?.level == .danger ? "danger-text" : "t1") : "t2")
        if let finding { cell.toolTip = CapsuleModel.labelled(finding.title, finding.detail) }
        label.alignment = ["size", "packed", "ratio"].contains(id) ? .right : .left
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        var leading = label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if id == "name" {
            let icon = NSImageView(image: n.isFolder ? NSWorkspace.shared.icon(for: .folder)
                                   : NSWorkspace.shared.icon(for: UTType(filenameExtension: (n.name as NSString).pathExtension) ?? .data))
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
            leading = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5)
        }
        NSLayoutConstraint.activate([leading, label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                                     label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    /// The member selected (nil for a folder row or none): the peek drawer follows it.
    var onSelection: ((Int?) -> Void)?

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelection?(entryIndex(atRow: table.selectedRow))
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = FlaggedRow()
        row.level = node(item).entryIndex.flatMap { flagged[$0]?.level }
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        (rowView as? FlaggedRow)?.isOdd = row % 2 == 1
    }

    static func kindName(_ name: String, entry: ArchiveEntry?) -> String {
        if entry?.type == .symlink { return String(localized: "Alias", bundle: .previewKit, comment: "Archive list kind: a symbolic link.") }
        let ext = (name as NSString).pathExtension
        if let described = UTType(filenameExtension: ext)?.localizedDescription?.capitalizedFirst { return described }
        return ext.isEmpty ? String(localized: "Document", bundle: .previewKit, comment: "Archive list kind: a file with no extension.")
            : String(localized: "\(ext.uppercased()) file", bundle: .previewKit, comment: "Archive list kind of an unknown extension, e.g. 'XYZ file'.")
    }

    nonisolated static var packedWord: String {
        String(localized: "Packed", bundle: .previewKit, comment: "Archive list column and peek fact: the packed (compressed) size.")
    }
    nonisolated static var modifiedWord: String {
        String(localized: "Modified", bundle: .previewKit, comment: "Archive list column and peek fact: when the member was last changed.")
    }
}

/// A member of the archive on screen, for the peek drawer: its start read into memory off the main thread, bounded by
/// the drawer and by the archive limits; nothing is written to disk. roadmap: S-8
@MainActor
struct ArchiveMemberPeek: PeekItem {
    let source: any ArchiveByteSource
    let archiveName: String
    let listing: ArchiveListing
    let entryIndex: Int

    private var entry: ArchiveEntry { listing.entries[entryIndex] }
    var peekName: String { ArchivePath.components(entry.path).last ?? entry.path }
    var peekKind: String { ArchiveOutline.kindName(peekName, entry: entry) }
    var peekSize: Int64? { entry.uncompressedSize }
    var peekFacts: [(label: String, value: String)] {
        var facts: [(label: String, value: String)] = [(String(localized: "In", bundle: .previewKit, comment: "Peek fact label: the archive a member is in."),
                                                        archiveName)]
        if let packed = entry.compressedSize {
            facts.append((ArchiveOutline.packedWord, ByteCountFormatter.string(fromByteCount: packed, countStyle: .file)))
        }
        if let date = entry.modified?.date(in: .current) {
            facts.append((ArchiveOutline.modifiedWord, date.formatted(date: .abbreviated, time: .shortened)))
        }
        return facts
    }
    var peekLine: String? {
        String(localized: "in \(archiveName)", bundle: .previewKit, comment: "Peek drawer header (lower case, after the size): the archive a member is in.")
    }

    func loadPeek(maxBytes: Int) async throws -> PeekPayload {
        let (source, name, listing, index) = (self.source, archiveName, listing, entryIndex)
        let data = try await Task.detached(priority: .userInitiated) {
            try VitrineArchive.memberData(source: source, fileName: name, listing: listing, entryIndex: index, limit: maxBytes)
        }.value
        return .data(Data(data.bytes), total: data.memberSize)
    }
}

/// The outline with the archive view's keys: Return and Enter open, ⌘↑ and Delete go back. roadmap: S-8
final class KeyedOutlineView: NSOutlineView {
    var onKey: ((ArchiveOutline.Key) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        let key: ArchiveOutline.Key?
        switch event.keyCode {
        case 36, 76: key = .open                                                 // Return, Enter
        case 126: key = command ? .back : nil                                    // ⌘↑
        case 51: key = .back                                                     // Delete
        default: key = nil
        }
        if let key, onKey?(key) == true { return }
        super.keyDown(with: event)
    }
}

/// Danger rows on `danger-soft`, caution rows on `caution-soft`, zebra on odd rows (browse 4).
final class FlaggedRow: NSTableRowView {
    var level: SafetyFinding.Level?
    var isOdd = false { didSet { needsDisplay = true } }

    override func drawBackground(in dirtyRect: NSRect) {
        switch level {
        case .danger?: NSColor.token("danger-soft").setFill(); bounds.fill()
        case .caution?: NSColor.token("caution-soft").setFill(); bounds.fill()
        default:
            if isOdd { NSColor.token("zebra").setFill(); bounds.fill() }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
