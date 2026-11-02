import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import VitrineUI

/// The folder's Icons view (O-1): a grid of 118 × 88 tiles with names under them, in the list's order. Images,
/// movies and PDFs get a Quick Look thumbnail, bounded (the first `maxThumbnails` such items, files under
/// `maxThumbnailBytes`, generated only when a tile is shown, cancelled when the grid changes); everything else
/// shows its system icon. An iCloud item that is not downloaded gets a cloud tile and is never downloaded (R-5).
/// roadmap: S-9
@MainActor
final class FolderIcons: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let scroll = NSScrollView()
    let grid = IconGridView()
    private(set) var nodes: [FolderNode] = []
    var onActivate: ((FolderNode) -> Void)?
    var onSelect: ((FolderNode?) -> Void)?

    static let tile = NSSize(width: 118, height: 88)
    static let maxThumbnails = 400
    static let maxThumbnailBytes: Int64 = 512 << 20
    /// Off in tests that only count tiles.
    static var thumbnailsEnabled = true

    private var thumbnails: [URL: NSImage] = [:]
    private var requests: [URL: QLThumbnailGenerator.Request] = [:]
    private var allowed = Set<URL>()

    override init() {
        super.init()
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: Self.tile.width, height: Self.tile.height + 24)
        layout.minimumInteritemSpacing = 18
        layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.backgroundColors = [.clear]
        grid.register(FolderIconItem.self, forItemWithIdentifier: FolderIconItem.id)
        grid.dataSource = self
        grid.delegate = self
        grid.onActivate = { [weak self] index in
            guard let self, self.nodes.indices.contains(index) else { return }
            self.onActivate?(self.nodes[index])
        }
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
    }

    /// Whether a tile may ask Quick Look for a thumbnail: a downloaded image, movie or PDF under the size bound.
    static func wantsThumbnail(_ n: FolderNode) -> Bool {
        guard !n.isFolder, !n.isCloudOnly, n.size <= maxThumbnailBytes,
              let type = UTType(filenameExtension: (n.name as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
    }

    func show(_ nodes: [FolderNode]) {
        for r in requests.values { QLThumbnailGenerator.shared.cancel(r) }
        requests = [:]
        self.nodes = nodes
        allowed = Set(nodes.filter(Self.wantsThumbnail).prefix(Self.maxThumbnails).map(\.url))
        grid.reloadData()
    }

    /// Items in iCloud only, for the gutter.
    var cloudOnlyCount: Int { nodes.filter(\.isCloudOnly).count }

    func select(_ node: FolderNode) {
        guard let i = nodes.firstIndex(where: { $0 === node }) else { return }
        let path = IndexPath(item: i, section: 0)
        grid.selectionIndexPaths = [path]
        grid.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
    }

    var selected: FolderNode? { grid.selectionIndexPaths.first.map { nodes[$0.item] } }

    func cancelThumbnails() {
        for r in requests.values { QLThumbnailGenerator.shared.cancel(r) }
        requests = [:]
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { nodes.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FolderIconItem.id, for: indexPath)
        guard let tile = item as? FolderIconItem else { return item }
        let n = nodes[indexPath.item]
        tile.configure(n, thumbnail: thumbnails[n.url])
        if thumbnails[n.url] == nil, Self.thumbnailsEnabled, allowed.contains(n.url) { requestThumbnail(n) }
        return tile
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { onSelect?(selected) }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { onSelect?(selected) }

    private func requestThumbnail(_ n: FolderNode) {
        guard requests[n.url] == nil else { return }
        let scale = grid.window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: n.url, size: Self.tile, scale: scale, representationTypes: .thumbnail)
        requests[n.url] = request
        let url = n.url
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let cg = rep?.cgImage else { return }
            let image = PeekImage(cg)
            Task { @MainActor [weak self] in
                guard let self, self.requests[url] != nil else { return }
                self.requests[url] = nil
                self.thumbnails[url] = NSImage(cgImage: image.cgImage, size: .zero)
                if let i = self.nodes.firstIndex(where: { $0.url == url }),
                   let tile = self.grid.item(at: IndexPath(item: i, section: 0)) as? FolderIconItem {
                    tile.configure(self.nodes[i], thumbnail: self.thumbnails[url])
                }
            }
        }
    }
}

/// The grid; a double click (or Return) opens a folder or peeks at a file.
@MainActor
final class IconGridView: NSCollectionView {
    var onActivate: ((Int) -> Void)?
    var onEscape: (() -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A recognizer, not a mouseDown override: overriding it turns off the collection view's own gestures.
        let double = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
        double.numberOfClicksRequired = 2
        double.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(double)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func doubleClicked(_ g: NSClickGestureRecognizer) {
        if let i = indexPathForItem(at: g.location(in: self))?.item { onActivate?(i) }
    }

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), let i = selectionIndexPaths.first?.item { onActivate?(i); return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() != true { super.cancelOperation(sender) }
    }
}

/// One tile: the thumbnail (`.th`, radius 6, the card shadow), the icon, or the cloud placeholder (`.th.cloud`),
/// with the name under it on the selection tint when selected.
@MainActor
final class FolderIconItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("FolderIconItem")
    private let picture = NSImageView()
    private let frameView = TileFrame()
    private let name = NSTextField(labelWithString: "")

    override func loadView() {
        let v = NSView()
        picture.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: Metric.value("fs-sub"))
        name.textColor = NSColor.token("t1")
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle
        name.wantsLayer = true
        name.layer?.cornerRadius = 4
        for s in [frameView, name] as [NSView] { s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s) }
        picture.translatesAutoresizingMaskIntoConstraints = false
        frameView.addSubview(picture)
        NSLayoutConstraint.activate([
            frameView.topAnchor.constraint(equalTo: v.topAnchor), frameView.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            frameView.widthAnchor.constraint(equalToConstant: FolderIcons.tile.width), frameView.heightAnchor.constraint(equalToConstant: FolderIcons.tile.height),
            picture.topAnchor.constraint(equalTo: frameView.topAnchor), picture.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: frameView.leadingAnchor), picture.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            name.topAnchor.constraint(equalTo: frameView.bottomAnchor, constant: 5), name.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: FolderIcons.tile.width),
        ])
        view = v
    }

    func configure(_ n: FolderNode, thumbnail: NSImage?) {
        name.stringValue = n.name
        view.toolTip = n.name
        view.setAccessibilityLabel(n.name)
        if let thumbnail {
            frameView.style = .thumbnail
            picture.imageScaling = .scaleProportionallyUpOrDown
            picture.image = thumbnail
        } else if n.isCloudOnly {
            frameView.style = .cloud
            picture.imageScaling = .scaleNone
            let cloud = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: String(localized: "In iCloud only", bundle: .previewKit, comment: "Accessibility description of the cloud icon: the item is in iCloud and not downloaded."))
            picture.image = cloud?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
            picture.contentTintColor = NSColor.token("t3")
            let itemName = n.name
            view.toolTip = String(localized: "\(itemName) — in iCloud only, not downloaded", bundle: .previewKit, comment: "Tooltip of an item kept only in iCloud; the argument is its name.")
        } else {
            frameView.style = .icon
            picture.imageScaling = .scaleProportionallyDown
            let icon = NSWorkspace.shared.icon(forFile: n.url.path)
            icon.size = NSSize(width: 64, height: 64)
            picture.image = icon
            picture.contentTintColor = nil
        }
        updateSelection()
    }

    override var isSelected: Bool { didSet { updateSelection() } }

    private func updateSelection() {
        name.layer?.backgroundColor = isSelected ? NSColor.token("sel").cgColor : NSColor.clear.cgColor
    }
}

/// The tile's frame: a rounded thumbnail with the card shadow, a cloud placeholder on `fill` with a hairline, or
/// nothing behind a plain icon.
@MainActor
final class TileFrame: NSView {
    enum Style { case thumbnail, cloud, icon }
    var style: Style = .icon { didSet { needsDisplay = true; updateLayer() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        switch style {
        case .thumbnail:
            layer?.backgroundColor = NSColor.token("fill").cgColor
            layer?.borderColor = NSColor.token("hair").cgColor
            layer?.borderWidth = 0.5
        case .cloud:
            layer?.backgroundColor = NSColor.token("fill").cgColor
            layer?.borderColor = NSColor.token("hair").cgColor
            layer?.borderWidth = 1
        case .icon:
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
        }
    }
}
