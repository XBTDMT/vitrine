import AppKit
import VitrineUI

/// The folder page (browse r3-a): the 34 pt path row (breadcrumbs back out, the arrangement button, the Overview
/// chip, a repository's tag), the 3 pt kinds hairline that opens the storage overview in place, a skill's header
/// card, then the list, the icon grid or a repository's page, with the peek drawer sliding in beside them. Sizes
/// are counted in the background for the place on screen, bounded and cancellable; nothing here waits for them.
/// roadmap: S-9
@MainActor
final class FolderView: NSView {
    let scroll = NSScrollView()
    let outline: FolderOutline
    let icons = FolderIcons()
    let pathRow = BrowsePathRow()
    let hairline = HairlineStrip()
    let overview = FolderOverview()
    let drawer = PeekDrawer()
    private(set) var repository: RepositoryPanel?
    private(set) var readme: ReadmeCard?
    private(set) var skillCard: SkillCard?
    private(set) var read: RepositoryRead?

    /// The previewed folder and the folders navigated into below it.
    let root: FolderNode
    private(set) var trail: [FolderNode] = []
    var place: FolderNode { trail.last ?? root }
    var atRepositoryRoot: Bool { trail.isEmpty && read != nil }
    private(set) var sizes: FolderSizes?
    private(set) var viewIndex = 0
    private(set) var overviewOpen = false
    private(set) var peeking: FolderNode?

    /// The place changed (the pill and the copy text follow).
    var onPlaceChange: (() -> Void)?
    /// A new count arrived for the place on screen.
    var onSizes: ((FolderSizes) -> Void)?
    var onGutter: ((GutterStatus?) -> Void)?
    static var sizerBudget = FolderSizer.Budget()

    private let content = NSView()
    private let body = NSLayoutGuide()
    private var repoPage: NSView?
    private var outlineCard: CardBox?
    private var outlineHeight: NSLayoutConstraint?
    private var bodyCollapsed: NSLayoutConstraint!
    private var bodyExpanded: NSLayoutConstraint!
    private var contentUnderSkill: NSLayoutConstraint?
    private var contentAtBody: NSLayoutConstraint!
    private var contentTrailing: NSLayoutConstraint!
    private var drawerWidth: NSLayoutConstraint!
    private var placed: [NSLayoutConstraint] = []
    private let arrangeButton = BrowseButton(style: .small, symbol: "arrow.up.arrow.down", title: FolderArrangement.Key.name.title)
    private let overviewChip = BrowseButton(style: .chip, symbol: "chart.bar.xaxis",
                                             title: String(localized: "Overview", bundle: .previewKit, comment: "Button: the folder's storage overview (sizes by kind)."),
                                             trailingSymbol: "chevron.up")
    private var tagBadge: PillLabel?
    private var tagBadgeText: String?
    private var sizingWork: Task<Void, Never>?
    private var sizingFeed: Task<Void, Never>?
    private var lastGutter: GutterStatus?

    init(root: FolderNode, outline: FolderOutline, repository read: RepositoryRead? = nil, skill: SkillInfo? = nil) {
        self.root = root
        self.outline = outline
        self.read = read
        super.init(frame: .zero)
        wantsLayer = true
        scroll.documentView = outline.table
        scroll.drawsBackground = false
        outline.ruler = RulerScroller.install(on: scroll)
        overview.isHidden = true
        drawer.isHidden = true
        addLayoutGuide(body)
        for v in [pathRow, hairline, overview, content, drawer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        bodyCollapsed = body.topAnchor.constraint(equalTo: hairline.bottomAnchor)
        bodyExpanded = body.topAnchor.constraint(equalTo: overview.bottomAnchor)
        contentAtBody = content.topAnchor.constraint(equalTo: body.topAnchor)
        contentTrailing = content.trailingAnchor.constraint(equalTo: trailingAnchor)
        drawerWidth = drawer.widthAnchor.constraint(equalToConstant: 430)
        // The list keeps three rows before the overview (490) and the skill card (485) give way; all below the
        // window's own size (500), so a short panel cuts them instead of growing.
        let listMinimum = content.heightAnchor.constraint(greaterThanOrEqualToConstant: 66)
        listMinimum.priority = .init(495)
        var constraints = [
            listMinimum,
            pathRow.topAnchor.constraint(equalTo: topAnchor), pathRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            pathRow.trailingAnchor.constraint(equalTo: trailingAnchor), pathRow.heightAnchor.constraint(equalToConstant: Metric.value("h-strip")),
            hairline.topAnchor.constraint(equalTo: pathRow.bottomAnchor), hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor), hairline.heightAnchor.constraint(equalToConstant: HairlineStrip.height),
            overview.topAnchor.constraint(equalTo: pathRow.bottomAnchor), overview.leadingAnchor.constraint(equalTo: leadingAnchor),
            overview.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyCollapsed!, body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor), contentTrailing!, content.bottomAnchor.constraint(equalTo: bottomAnchor),
            drawer.topAnchor.constraint(equalTo: body.topAnchor), drawer.bottomAnchor.constraint(equalTo: bottomAnchor),
            drawer.trailingAnchor.constraint(equalTo: trailingAnchor), drawerWidth!,
        ]
        if let skill, read == nil {
            let card = SkillCard(info: skill)
            skillCard = card
            card.translatesAutoresizingMaskIntoConstraints = false
            addSubview(card, positioned: .below, relativeTo: drawer)
            constraints += [card.topAnchor.constraint(equalTo: body.topAnchor), card.leadingAnchor.constraint(equalTo: leadingAnchor),
                            card.trailingAnchor.constraint(equalTo: trailingAnchor)]
            let under = content.topAnchor.constraint(equalTo: card.bottomAnchor)
            contentUnderSkill = under
            constraints.append(under)
        } else {
            constraints.append(contentAtBody)
        }
        NSLayoutConstraint.activate(constraints)
        if let read { buildRepositoryPage(read) }

        hairline.onToggle = { [weak self] in self?.toggleOverview() }
        overview.onOpenFolder = { [weak self] in self?.open($0) }
        overview.onPeek = { [weak self] in self?.peek($0) }
        overviewChip.onPress = { [weak self] in self?.toggleOverview() }
        overviewChip.toolTip = String(localized: "Hide the storage overview", bundle: .previewKit, comment: "Tooltip of the Overview button.")
        arrangeButton.toolTip = String(localized: "Sort and group", bundle: .previewKit, comment: "Tooltip of the button that sorts and groups the folder list.")
        outline.onActivate = { [weak self] in self?.activate($0) }
        outline.onSelect = { [weak self] in self?.selectionChanged($0) }
        outline.onArrangementChange = { [weak self] _ in self?.arrangementChanged() }
        outline.table.onEscape = { [weak self] in self?.escape() ?? false }
        outline.table.onBack = { [weak self] in self?.goBack() }
        icons.onActivate = { [weak self] in self?.activate($0) }
        icons.onSelect = { [weak self] in self?.selectionChanged($0) }
        icons.grid.onEscape = { [weak self] in self?.escape() ?? false }
        drawer.onStep = { [weak self] in self?.step($0) }
        drawer.onClose = { [weak self] in self?.closePeek() }
        arrangementChanged()
        placeContent()
        refreshChrome()
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("page").cgColor }

    override func layout() {
        let width = PeekDrawer.width(for: bounds.width)
        if drawerWidth.constant != width { drawerWidth.constant = width }
        let inset = peeking == nil ? 0 : -width
        if contentTrailing.constant != inset { contentTrailing.constant = inset }
        super.layout()
    }

    // MARK: The repository page

    /// The band with the repository card, the outline in a card sized to its rows, and the README card taking the
    /// rest. All three rank below a window's own size (500, `windowSizeStayPut`): above it, a short Quick Look
    /// panel let the content grow past its top and hid the path row, instead of shrinking the cards.
    private func buildRepositoryPage(_ read: RepositoryRead) {
        let page = NSView()
        let panel = RepositoryPanel(read: read)
        repository = panel
        let card = CardBox()
        card.fill = "page"
        outlineCard = card
        for v in [panel, card] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; page.addSubview(v) }
        var constraints = [
            panel.topAnchor.constraint(equalTo: page.topAnchor), panel.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            card.topAnchor.constraint(equalTo: panel.bottomAnchor, constant: 8),
            card.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 12), card.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -12),
        ]
        if let blocks = read.readme, let info = read.summary.readme {
            let readmeCard = ReadmeCard(name: info.name, blocks: blocks, truncated: info.truncated)
            readme = readmeCard
            readmeCard.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(readmeCard)
            let fit = card.heightAnchor.constraint(equalToConstant: 66)
            fit.priority = .init(460)
            outlineHeight = fit
            let readmeMin = readmeCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
            readmeMin.priority = .init(470)
            let outlineMin = card.heightAnchor.constraint(greaterThanOrEqualToConstant: min(66, outline.contentHeight))
            outlineMin.priority = .init(480)
            constraints += [
                fit, readmeMin, outlineMin,
                readmeCard.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 8),
                readmeCard.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 12),
                readmeCard.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -12),
                readmeCard.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -12),
            ]
            outline.contentHeightChanged = { [weak self] in self?.fitOutline() }
        } else {
            constraints.append(card.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -12))
        }
        page.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(page)
        constraints += [page.topAnchor.constraint(equalTo: content.topAnchor), page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                        page.trailingAnchor.constraint(equalTo: content.trailingAnchor), page.bottomAnchor.constraint(equalTo: content.bottomAnchor)]
        NSLayoutConstraint.activate(constraints)
        repoPage = page
        fitOutline()
    }

    /// The outline card is as tall as its rows (until the README's minimum pushes back).
    private func fitOutline() {
        guard let outlineHeight else { return }
        outlineHeight.constant = outline.contentHeight
    }

    /// The full repository read arrived after the first paint.
    func updateRepository(_ read: RepositoryRead) {
        self.read = read
        repository?.update(read)
        refreshChrome()
    }

    // MARK: What the body shows

    /// The viewer switch: 0 the list (or the repository page at its root), 1 the icon grid.
    func showView(_ index: Int) -> Bool {
        guard index != viewIndex else { return true }
        viewIndex = index
        closePeek()
        placeContent()
        refreshChrome()
        return true
    }

    private func placeContent() {
        NSLayoutConstraint.deactivate(placed)
        placed = []
        scroll.removeFromSuperview()
        icons.scroll.removeFromSuperview()
        if viewIndex == 1 {
            repoPage?.isHidden = true
            icons.show(outline.arrangement.sorted(place.children(), size: { [weak outline] in outline?.size(of: $0) }))
            pin(icons.scroll, in: content)
        } else if atRepositoryRoot, let card = outlineCard {
            repoPage?.isHidden = false
            outline.setMode(.repository)
            pin(scroll, in: card)
        } else {
            repoPage?.isHidden = true
            outline.setMode(.plain)
            pin(scroll, in: content)
        }
        if let under = contentUnderSkill {
            let skillShown = trail.isEmpty
            skillCard?.isHidden = !skillShown
            under.isActive = skillShown
            contentAtBody.isActive = !skillShown
        }
    }

    private func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        placed = [view.topAnchor.constraint(equalTo: container.topAnchor), view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                  view.trailingAnchor.constraint(equalTo: container.trailingAnchor), view.bottomAnchor.constraint(equalTo: container.bottomAnchor)]
        NSLayoutConstraint.activate(placed)
    }

    // MARK: Navigation (N-10: into subfolders, back out by the path row or ⌘↑)

    func open(_ folder: FolderNode) {
        guard folder.isFolder else { peek(folder); return }
        trail.append(folder)
        placeChanged()
    }

    /// Back to `depth` folders below the root (0 = the root).
    func back(to depth: Int) {
        guard depth < trail.count else { return }
        trail = Array(trail.prefix(depth))
        placeChanged()
    }

    func goBack() { if !trail.isEmpty { back(to: trail.count - 1) } }

    private func placeChanged() {
        closePeek()
        outline.show(root: place)
        sizes = nil
        placeContent()
        refreshChrome()
        startSizing()
        onPlaceChange?()
        window?.makeFirstResponder(viewIndex == 1 ? icons.grid : outline.table)
    }

    private func activate(_ node: FolderNode) {
        if node.isFolder { open(node) } else { peek(node) }
    }

    // MARK: The path row and the hairline

    private func refreshChrome() {
        var crumbs: [BrowsePathRow.Crumb] = []
        let fm = FileManager.default
        let rootIcon = NSWorkspace.shared.icon(forFile: root.url.path)
        if trail.isEmpty {
            let parent = root.url.deletingLastPathComponent()
            if Self.showsParent(parent) {
                crumbs.append(.init(title: fm.displayName(atPath: parent.path), icon: NSWorkspace.shared.icon(forFile: parent.path), action: nil))
                crumbs.append(.init(title: fm.displayName(atPath: root.url.path), icon: nil, action: nil))
            } else {
                crumbs.append(.init(title: fm.displayName(atPath: root.url.path), icon: rootIcon, action: nil))
            }
        } else {
            crumbs.append(.init(title: fm.displayName(atPath: root.url.path), icon: rootIcon, action: { [weak self] in self?.back(to: 0) }))
            if trail.count >= 2 {
                if trail.count >= 3 { crumbs.append(.init(title: "…", icon: nil, action: nil)) }
                let depth = trail.count - 1
                crumbs.append(.init(title: trail[depth - 1].name, icon: nil, action: { [weak self] in self?.back(to: depth) }))
            }
            crumbs.append(.init(title: place.name, icon: nil, action: nil))
        }
        pathRow.setCrumbs(crumbs)

        var accessories: [NSView] = []
        if overviewOpen {
            accessories.append(overviewChip)
        } else if !(viewIndex == 0 && atRepositoryRoot) {
            accessories.append(arrangeButton)
        }
        if atRepositoryRoot, let tag = read?.summary.nearestTag {
            // The nearest tag sits at the right end of the path row (`.gb .opts`); rebuilt when the full read differs.
            if tagBadge == nil || tagBadgeText != tag {
                let badge = PillLabel(symbol: "tag", text: tag, textToken: "t2", height: Metric.value("h-badge"), radius: Metric.value("r-badge"),
                                      font: .systemFont(ofSize: Metric.value("fs-caption"), weight: .semibold), padding: 6)
                badge.toolTip = read?.summary.tagOnHead == true
                    ? String(localized: "Tag on the current commit", bundle: .previewKit, comment: "Tooltip of a git tag badge.")
                    : String(localized: "Nearest tag in this branch's history", bundle: .previewKit, comment: "Tooltip of a git tag badge.")
                tagBadge = badge
                tagBadgeText = tag
            }
            if let tagBadge { accessories.append(tagBadge) }
        }
        pathRow.setAccessories(accessories)
        refreshHairline()
        sendGutter()
    }

    /// Context above the previewed folder: its parent, unless that is the disk or the home folder (the design's
    /// "Projects › lumen-site", but "Downloads" alone).
    static func showsParent(_ parent: URL) -> Bool {
        let path = parent.standardizedFileURL.path
        guard path != "/", !path.isEmpty else { return false }
        if let pw = getpwuid(getuid()), let home = String(validatingCString: pw.pointee.pw_dir), path == home { return false }
        return true
    }

    /// A repository's root shows its languages; elsewhere the place's bytes by kind (counted, or its own files
    /// until the count arrives).
    private func refreshHairline() {
        if atRepositoryRoot, let languages = read?.languages, !languages.isEmpty {
            hairline.set(shares: languages.map { ($0.token, $0.share) },
                         help: languages.map { "\($0.name) \($0.share.formatted(.percent.precision(.fractionLength(0))))" }.joined(separator: " · "))
            return
        }
        let shares: [(token: String, share: Double)]
        if let sizes, !sizes.byKind.isEmpty {
            let total = Double(max(1, sizes.byKind.values.reduce(Int64(0)) { $0 + $1.bytes }))
            shares = sizes.byKind.sorted { $0.value.bytes > $1.value.bytes }.map { ($0.key, Double($0.value.bytes) / total) }
        } else {
            shares = FolderRenderer.shares(place.children())
        }
        hairline.set(shares: shares, help: shares.map { "\(FolderSizer.kindName($0.token)) \($0.share.formatted(.percent.precision(.fractionLength(0))))" }.joined(separator: " · "))
    }

    // MARK: Arrangement (O-2)

    private func arrangementChanged() {
        let a = outline.arrangement
        arrangeButton.title = (a.group ?? a.sort).title
        arrangeButton.popUpMenu = arrangementMenu()
        if viewIndex == 1 { icons.show(a.sorted(place.children(), size: { [weak outline] in outline?.size(of: $0) })) }
    }

    private func arrangementMenu() -> NSMenu {
        let menu = NSMenu()
        let a = outline.arrangement
        menu.addItem(.sectionHeader(title: String(localized: "Group By", bundle: .previewKit, comment: "Sort and group menu: section header.")))
        menu.addItem(ClosureMenuItem(String(localized: "None", bundle: .previewKit, comment: "Sort and group menu: no grouping."), on: a.group == nil) { [weak self] in self?.outline.arrangement.group = nil })
        for key in FolderArrangement.Key.allCases {
            menu.addItem(ClosureMenuItem(key.title, on: a.group == key) { [weak self] in
                guard let self else { return }
                var next = self.outline.arrangement
                next.group = key
                if next.sort != key, [.modified, .added, .size].contains(key) { next.sort = key; next.ascending = key.defaultAscending }
                self.outline.arrangement = next
            })
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Sort By", bundle: .previewKit, comment: "Sort and group menu: section header.")))
        for key in FolderArrangement.Key.allCases {
            menu.addItem(ClosureMenuItem(key.title, on: a.sort == key) { [weak self] in
                guard let self else { return }
                var next = self.outline.arrangement
                if next.sort == key { next.ascending.toggle() } else { next.sort = key; next.ascending = key.defaultAscending }
                self.outline.arrangement = next
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Ascending", bundle: .previewKit, comment: "Sort and group menu: sort order."), on: a.ascending) { [weak self] in self?.outline.arrangement.ascending = true })
        menu.addItem(ClosureMenuItem(String(localized: "Descending", bundle: .previewKit, comment: "Sort and group menu: sort order."), on: !a.ascending) { [weak self] in self?.outline.arrangement.ascending = false })
        return menu
    }

    // MARK: The storage overview (N-10)

    func toggleOverview() {
        overviewOpen.toggle()
        overview.isHidden = !overviewOpen
        hairline.isHidden = overviewOpen
        bodyCollapsed.isActive = !overviewOpen
        bodyExpanded.isActive = overviewOpen
        if overviewOpen { refreshOverview() }
        refreshChrome()
    }

    private func refreshOverview() {
        guard overviewOpen else { return }
        overview.update(sizes: sizes ?? FolderSizes(), nodes: place.children(), limit: Self.sizerBudget.maxItems,
                        folderSize: { [weak outline] in outline?.size(of: $0) })
    }

    // MARK: Sizes (bounded, cancellable, never before the first paint)

    func startSizing() {
        sizingWork?.cancel()
        sizingFeed?.cancel()
        let url = place.url
        let budget = Self.sizerBudget
        let (stream, feed) = AsyncStream<FolderSizes>.makeStream(bufferingPolicy: .bufferingNewest(1))
        sizes = FolderSizes()
        outline.sizes = sizes
        sendGutter()
        sizingWork = Task.detached(priority: .utility) {
            _ = FolderSizer.measure(url, budget: budget, isCancelled: { Task.isCancelled }, progress: { feed.yield($0) })
            feed.finish()
        }
        sizingFeed = Task { @MainActor [weak self] in
            for await s in stream {
                guard let self, !Task.isCancelled, self.place.url == url else { return }
                self.apply(s)
            }
        }
    }

    /// The gutter's Cancel: the count stops where it is and every total says "at least".
    func stopSizing() { sizingWork?.cancel() }

    /// Waits until the count for the place on screen has delivered its last snapshot (tests).
    func waitForSizing() async { await sizingFeed?.value }

    private func apply(_ s: FolderSizes) {
        sizes = s
        outline.sizes = s
        if viewIndex == 1 { icons.show(outline.arrangement.sorted(place.children(), size: { [weak outline] in outline?.size(of: $0) })) }
        refreshHairline()
        refreshOverview()
        sendGutter()
        onSizes?(s)
    }

    // MARK: Peek

    func peek(_ node: FolderNode) {
        let wasOpen = peeking != nil
        peeking = node
        drawer.isHidden = false
        needsLayout = true
        drawer.show(node)
        if viewIndex == 1 { if icons.selected !== node { icons.select(node) } }
        else if outline.selectedNode !== node { outline.select(node) }
        if !wasOpen {
            layoutSubtreeIfNeeded()
            drawer.animateIn()
        }
        sendGutter()
    }

    func closePeek() {
        guard peeking != nil else { return }
        peeking = nil
        drawer.stopLoading()
        drawer.isHidden = true
        needsLayout = true
        window?.makeFirstResponder(viewIndex == 1 ? icons.grid : outline.table)
        sendGutter()
    }

    private func escape() -> Bool {
        guard peeking != nil else { return false }
        closePeek()
        return true
    }

    /// ↑↓ in the drawer: the list moves its selection and the drawer follows it.
    private func step(_ delta: Int) {
        if viewIndex == 1 {
            guard let current = icons.selected ?? peeking, let i = icons.nodes.firstIndex(where: { $0 === current }),
                  icons.nodes.indices.contains(i + delta) else { return }
            icons.select(icons.nodes[i + delta])
            selectionChanged(icons.nodes[i + delta])
        } else {
            outline.step(delta)
        }
    }

    private func selectionChanged(_ node: FolderNode?) {
        guard peeking != nil, let node, node !== peeking else { return }
        peeking = node
        drawer.show(node)
        sendGutter()
    }

    // MARK: The gutter (R-4: always say how much is shown and counted)

    func gutterStatus() -> GutterStatus? {
        var leading: String?
        if place.truncated {
            let shown = place.children().count.formatted(), total = place.totalCount.formatted()
            leading = String(localized: "\(shown) of \(total) items", bundle: .previewKit, comment: "Status line: the list shows only part of a large folder. Arguments: items listed, all items.")
        } else if viewIndex == 1, icons.cloudOnlyCount > 0 {
            let count = icons.cloudOnlyCount.formatted()
            leading = String(localized: "\(count) in iCloud only, never downloaded", bundle: .previewKit, comment: "Status line: how many items are only in iCloud (Vitrine never downloads them).")
        }
        var trailing: String?, busy = false
        if peeking != nil {
            trailing = String(localized: "esc back to the list", bundle: .previewKit, comment: "Status line while peeking at an item: press Escape to return to the list.")
        } else if let s = sizes, !s.finished {
            let count = s.totalItems.formatted()
            trailing = String(localized: "Sizing \(count) items…", bundle: .previewKit, comment: "Status line while folder sizes are counted; the argument is the items counted so far.")
            busy = true
        } else if let s = sizes, s.finished, !s.complete {
            let stop = min(s.totalItems, Self.sizerBudget.maxItems).formatted()
            trailing = String(localized: "Sizes are at least: counting stopped at \(stop) items", bundle: .previewKit, comment: "Status line: folder sizes are floors because counting hit its limit.")
        }
        guard leading != nil || trailing != nil else { return nil }
        return GutterStatus(leading: leading, trailing: trailing, busy: busy)
    }

    private func sendGutter() {
        let status = gutterStatus()
        guard status != lastGutter else { return }
        lastGutter = status
        onGutter?(status)
    }
}

/// The 3 pt kinds hairline under the path row (`.hairwrap`: the line, 6 pt under it), the collapsed storage
/// overview: a click opens the overview in its place. roadmap: S-9
@MainActor
final class HairlineStrip: NSView {
    static let height: CGFloat = 9
    var onToggle: (() -> Void)?
    private var line: KindsHairline?
    private(set) var shares: [(token: String, share: Double)] = []

    func set(shares: [(token: String, share: Double)], help: String) {
        self.shares = shares
        line?.removeFromSuperview()
        let l = KindsHairline(shares: shares)
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([l.topAnchor.constraint(equalTo: topAnchor), l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                                     l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), l.heightAnchor.constraint(equalToConstant: 3)])
        line = l
        let click = String(localized: "Click for the storage overview", bundle: .previewKit, comment: "Tooltip of the kinds hairline under the path.")
        toolTip = help.isEmpty ? click : help + "\n" + click
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(help.isEmpty
            ? String(localized: "Storage overview", bundle: .previewKit, comment: "Accessibility label of the folder's storage overview panel.")
            : String(localized: "Storage overview: \(help)", bundle: .previewKit, comment: "Accessibility label of the kinds hairline; the argument lists kinds and their shares."))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onToggle?() }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
}

/// A menu item that runs a closure, checked when `on`. roadmap: S-9
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, on: Bool, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = on ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}
