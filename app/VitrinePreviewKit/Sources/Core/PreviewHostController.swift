import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers
import VitrineSupport
import VitrineTrust
import VitrineUI

/// The one Quick Look controller every Vitrine extension subclasses. Each `.appex` is a shell: it declares which
/// content types it owns and otherwise inherits everything here. Lifecycle:
///   preparePreviewOfFile → sniff → renderer → embed → report ready → watch the file → remember scroll on exit.
/// The controller never blocks the main thread on I/O: renderers are async and are cancelled when Finder moves on.
/// Every preview sits above the frame's gutter, which holds the Glass Capsule (D1, `CapsuleModel`).
@MainActor
open class PreviewHostController: NSViewController, QLPreviewingController {
    public static let cache = PreviewCache(capacity: 4)

    private var current: RenderedPreview?
    private var currentURL: URL?
    private var monitor: FileMonitor?
    private var renderTask: Task<Void, Never>?
    private let scrollMemory = ScrollMemory()
    private let capsule = CapsuleModel()
    /// True when the controller sits in the Vitrine window, whose toolbar has Open with and Info (V7).
    public var hostsInWindow = false { didSet { capsule.hidesWindowActions = hostsInWindow; capsule.canExport = hostsInWindow } }
    var capsuleForTesting: CapsuleModel { capsule }
    private let contentHost = NSView()
    /// The trust lens's strip (S-20) above the preview; empty, and no height, when there is nothing to say.
    private let lensHost = NSView()
    /// The strips above the preview, top to bottom: the trust lens's verdict, then the on-device summary (A-9).
    private let stripStack = NSStackView()
    private var lensStrip: NSView?
    private var summaryStrip: NSView?
    /// The lens ran and found nothing: the gutter says so when the preview has nothing of its own there.
    private var lensCalm = false
    private var lensTask: Task<Void, Never>?
    private var gutterHeight: NSLayoutConstraint?
    private var alternate: (index: Int, view: NSView, finder: TextFinder)?
    private var context: RenderContext?
    /// The Details sheet (chrome r3-b: every fact and the token meter, A-4) on the content's right for a text preview
    /// with no side panel of its own; zero wide when hidden or not offered, so the preview narrows rather than being
    /// covered.
    private let detailsHost = NSView()
    private var detailsWidth: NSLayoutConstraint?
    private var details: DetailsInspector?
    /// Whether the person opened Details; kept while Space moves from file to file.
    private var detailsShown = false
    /// Panels narrower than this (Finder's preview pane) never show the sheet: it would leave the file no room.
    static let detailsMinimumPanelWidth: CGFloat = 420
    var detailsForTesting: DetailsInspector? { details?.isHidden == false ? details : nil }

    open override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        let gutter = NSHostingView(rootView: GutterView(model: capsule))
        gutter.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentHost)
        container.addSubview(gutter)
        lensHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(lensHost)
        stripStack.orientation = .vertical
        stripStack.alignment = .leading
        stripStack.spacing = 0
        stripStack.translatesAutoresizingMaskIntoConstraints = false
        lensHost.addSubview(stripStack)
        NSLayoutConstraint.activate([
            stripStack.topAnchor.constraint(equalTo: lensHost.topAnchor),
            stripStack.leadingAnchor.constraint(equalTo: lensHost.leadingAnchor),
            stripStack.trailingAnchor.constraint(equalTo: lensHost.trailingAnchor),
            stripStack.bottomAnchor.constraint(equalTo: lensHost.bottomAnchor),
        ])
        let lensEmpty = lensHost.heightAnchor.constraint(equalToConstant: 0)
        lensEmpty.priority = .defaultLow
        let height = gutter.heightAnchor.constraint(equalToConstant: Metric.value("h-gutter"))
        gutterHeight = height
        detailsHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(detailsHost)
        let detailsWidth = detailsHost.widthAnchor.constraint(equalToConstant: 0)
        self.detailsWidth = detailsWidth
        NSLayoutConstraint.activate([
            detailsHost.topAnchor.constraint(equalTo: lensHost.bottomAnchor),
            detailsHost.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            detailsHost.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            detailsWidth,
        ])
        NSLayoutConstraint.activate([
            contentHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: container.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: gutter.topAnchor),
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gutter.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            height,
            lensHost.topAnchor.constraint(equalTo: contentHost.topAnchor),
            lensHost.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            lensHost.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            lensEmpty,
        ])
        capsule.onShowView = { [weak self] index in self?.showView(at: index) }
        capsule.onToggleInspector = { [weak self] in
            guard let self, let current = self.current else { return }
            if let own = current.toggleInspector { own() } else { self.toggleDetails() }
        }
        capsule.onDisplayOptions = { [weak self] in self?.current?.displayOptions?() }
        capsule.onFoldToMatches = { [weak self] on in self?.current?.foldToMatches?(on) }
        capsule.onFind = { [weak self] query, forward in
            guard let self else { return FindResult(count: 0, index: -1) }
            if let alt = self.alternate { return alt.finder.find(query, forward: forward) }
            return await self.current?.find?(query, forward) ?? FindResult(count: 0, index: -1)
        }
        // X-3: actions that leave the preview go through VitrineHelper (G-31's rules apply there).
        capsule.onOpenIn = { [weak self] app in
            guard let self, let url = self.currentURL else { return }
            Task { @MainActor in self.report(await HelperClient.open(url, with: app.url)) }
        }
        capsule.onReveal = { [weak self] in
            guard let self, let url = self.currentURL else { return }
            Task { @MainActor in self.report(await HelperClient.reveal(url)) }
        }

        capsule.onCancelWork = { [weak self] in self?.current?.cancelWork?() }
        capsule.onClearFind = { [weak self] in
            self?.alternate?.finder.clear()
            self?.current?.clearFind?()
            self?.current?.clearQuery?()
        }
        capsule.onQuery = { [weak self] sql in
            await self?.current?.query?(sql) ?? .failed(String(localized: "This preview cannot run queries.", bundle: .previewKit,
                                                               comment: "Query field message when the preview has no query engine."))
        }
        view = container
    }

    /// The Finder preview pane and other narrow panels get the compact gutter (40 instead of 56).
    open override func viewDidLayout() {
        super.viewDidLayout()
        gutterHeight?.constant = Metric.value(view.bounds.width < 420 ? "h-gutter-compact" : "h-gutter")
        let width = detailsWanted ? DetailsInspector.width : 0
        if detailsWidth?.constant != width { layoutDetails() }
    }

    // MARK: Details (chrome r3-b, A-4)

    /// The host offers Details for a preview that carries a token count and has no side panel of its own (or hands
    /// its toggle on when its own panel is not on screen).
    private func offersDetails(_ preview: RenderedPreview) -> Bool {
        preview.document.tokens != nil && (preview.toggleInspector == nil || preview.defersToHostDetails)
    }

    private func canToggleInspector(_ preview: RenderedPreview) -> Bool {
        preview.toggleInspector != nil || offersDetails(preview)
    }

    private var detailsWanted: Bool {
        guard detailsShown, let current, offersDetails(current) else { return false }
        return view.bounds.width >= Self.detailsMinimumPanelWidth
    }

    func toggleDetails() {
        detailsShown.toggle()
        layoutDetails()
    }

    /// Builds the sheet for the current document when it is wanted, and gives it its width; otherwise zero wide.
    private func layoutDetails(rebuild: Bool = false) {
        let wanted = detailsWanted
        if rebuild || !wanted { details?.removeFromSuperview(); details = nil }
        if wanted, details == nil, let document = current?.document {
            let sheet = DetailsInspector(facts: document.facts, tokens: document.tokens, text: document.searchText, fileURL: currentURL)
            detailsHost.addSubview(sheet)
            NSLayoutConstraint.activate([
                sheet.leadingAnchor.constraint(equalTo: detailsHost.leadingAnchor), sheet.trailingAnchor.constraint(equalTo: detailsHost.trailingAnchor),
                sheet.topAnchor.constraint(equalTo: detailsHost.topAnchor), sheet.bottomAnchor.constraint(equalTo: detailsHost.bottomAnchor),
            ])
            details = sheet
        }
        detailsWidth?.constant = wanted ? DetailsInspector.width : 0
        detailsHost.isHidden = !wanted
    }

    // MARK: Two files compared (S-7, X-11)

    /// Shows two files compared in the diff design (the Vitrine window's Compare; Quick Look shows one file at a time).
    public func showComparison(old: URL, new: URL) async throws {
        renderTask?.cancel()
        rememberScroll()
        stopMonitor()
        currentURL = new
        let context = RenderContext(appearance: DesignTokens.currentAppearance(for: view))
        self.context = context
        let rendered = try await DiffRenderer().compare(old: old, new: new, context: context)
        try Task.checkCancellation()
        embed(rendered)
    }

    // MARK: QLPreviewingController

    open func preparePreviewOfFile(at url: URL) async throws {
        renderTask?.cancel()
        rememberScroll()
        stopMonitor()
        currentURL = url

        let context = RenderContext(appearance: DesignTokens.currentAppearance(for: view))
        self.context = context
        let key = PreviewCache.Key(url: url)
        if let cached = Self.cache.preview(for: key) {
            embed(cached)
            startMonitor(url)
            return
        }

        let kind = FileSniffer.kind(of: url)
        guard let renderer = RendererRegistry.renderer(for: kind) else { throw RenderError.unsupported(kind) }
        let rendered = try await renderer.render(url: url, kind: kind, context: context)
        try Task.checkCancellation()
        Self.cache.store(rendered, for: key)
        embed(rendered)
        if let y = scrollMemory.position(for: url), context.defaults.object(forKey: "general.resumePosition") as? Bool ?? true {
            rendered.restoreScroll?(y)
        }
        startMonitor(url)
    }

    // MARK: Embedding

    private func embed(_ preview: RenderedPreview) {
        current?.view.removeFromSuperview()
        alternate?.view.removeFromSuperview()
        alternate = nil
        current = preview
        place(preview.view)
        // A cached preview may have been left on another of its views; a new embed always opens on the first.
        _ = preview.showView?(0)
        // A cached data preview left on a query's rows opens on the file's own (I-8).
        preview.clearQuery?()
        preview.view.isHidden = false
        capsule.resetViewSwitch()
        preview.toggleDetails = { [weak self, weak preview] in
            guard let self, let preview, preview === self.current, self.offersDetails(preview) else { return }
            self.toggleDetails()
        }
        layoutDetails(rebuild: true)
        capsule.show(preview.document, canToggleInspector: canToggleInspector(preview), canFind: preview.find != nil)
        preview.documentChanged = { [weak self, weak preview] document in
            guard let self, let preview, preview === self.current else { return }
            self.capsule.show(document, canToggleInspector: self.canToggleInspector(preview), canFind: preview.find != nil)
            self.layoutDetails(rebuild: true)
        }
        capsule.findModes = preview.findModes
        capsule.queryPlaceholder = preview.queryPlaceholder
        capsule.queryLanguage = preview.queryLanguage
        capsule.findStyle = preview.findStyle
        capsule.copyFormats = preview.copyFormats
        capsule.canExportHTML = preview.htmlExporter != nil
        capsule.onCopyImage = { [weak preview] in
            guard let view = preview?.view else { return false }
            return await PreviewExport.copyImage(of: view, to: .general)
        }
        capsule.onExport = { [weak self] format in self?.export(format) }
        capsule.canShowDisplayOptions = preview.displayOptions != nil
        capsule.findPrefixes = preview.findPrefixes
        capsule.canFoldToMatches = preview.foldToMatches != nil
        preview.viewRequested = { [weak self, weak preview] index in
            guard let self, let preview, preview === self.current else { return }
            self.capsule.selectView(index)
        }
        runLens(for: preview)
        runSummaryOffer(for: preview)
        capsule.gutter = gutter(for: preview)
        preview.gutterChanged = { [weak self, weak preview] status in
            guard let self, let preview, preview === self.current, self.alternate == nil else { return }
            self.capsule.gutter = status ?? self.gutter(for: preview)
        }
        preview.findResultChanged = { [weak self, weak preview] result in
            guard let self, let preview, preview === self.current else { return }
            self.capsule.streamedFindResult(result)
        }
        capsule.openInApps = currentURL.map { OpenIn.apps(for: $0) } ?? []
        capsule.canReveal = currentURL != nil
        // In the sandbox Launch Services may list nothing; the helper lists the apps (never for a program, G-31).
        if let url = currentURL, HelperClient.isSandboxed {
            Task { @MainActor [weak self, weak preview] in
                let apps = await HelperClient.applications(forOpening: url)
                guard let self, let preview, preview === self.current, !apps.isEmpty else { return }
                self.capsule.openInApps = apps.map { OpenInApp(url: $0.url, name: $0.name, isDefault: $0.isDefault) }
            }
        }
        // The metadata strip (I-13): the person's settings, and the file's date and default app for its two facts.
        capsule.strip = context.map { MetadataStrip.Settings.read($0.defaults) } ?? .standard
        capsule.fileFacts = MetadataStrip.FileFacts(
            modified: currentURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate },
            owner: capsule.openInApps.first(where: \.isDefault)?.name)
        // What each kind opens as (I-3, Settings › File Types): the person's view when this preview offers it.
        if let defaults = context?.defaults,
           let index = OpensAs.preferredIndex(kind: preview.document.kind, titles: preview.document.viewTitles ?? preview.document.views.map(\.title),
                                              defaults: defaults) {
            capsule.selectView(index)
        }
        RecentPreviews.recordShown(currentURL, document: preview.document)   // menu bar recents (H-2); extensions only
    }

    private func place(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: detailsHost.leadingAnchor),
            v.topAnchor.constraint(equalTo: lensHost.bottomAnchor),
            v.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }

    /// The viewer switch: 0 is the renderer's own view; a renderer with `showView` may draw other views natively
    /// inside its own view (a structured file's Tree); any other index is one of the document's text views, shown in
    /// the native text view.
    private func showView(at index: Int) {
        guard let preview = current, let context else { return }
        capsule.closeFind()
        alternate?.view.removeFromSuperview()
        alternate = nil
        // A text view in the switch is searched, whatever the preview's own find does; the gutter is the preview's.
        capsule.findModes = index == 0 ? preview.findModes : [.search]
        capsule.findStyle = index == 0 ? preview.findStyle : .search
        capsule.gutter = index == 0 ? gutter(for: preview) : nil
        if preview.showView?(index) == true {
            preview.view.isHidden = false
            return
        }
        guard index != 0, preview.document.views.indices.contains(index) else {
            preview.view.isHidden = false
            return
        }
        let text: String
        switch preview.document.views[index] {
        case .text(let s), .code(let s, _), .formatted(let s, _): text = s
        case .markdown: preview.view.isHidden = false; return
        }
        let (scroll, textView) = TextPreviewView.make(text: text, context: context)
        preview.view.isHidden = true
        place(scroll)
        alternate = (index, scroll, TextFinder(textView))
    }

    /// A helper action's outcome: nothing when it worked, otherwise its reason in the gutter for a few seconds.
    private func report(_ error: String?) {
        guard let error else { return }
        let previous = capsule.gutter
        capsule.gutter = GutterStatus(leading: error, trailing: nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.capsule.gutter?.leading == error { self?.capsule.gutter = previous }
        }
    }

    // MARK: Live reload

    private func startMonitor(_ url: URL) {
        monitor = FileMonitor(url: url) { [weak self] in
            guard let self, let current = self.current else { return }
            Self.cache.discard(path: url.path)
            if let reload = current.reload {
                Task {
                    guard let document = try? await reload(url) else { return }
                    current.replaceDocument(document)
                    self.capsule.show(document, canToggleInspector: self.canToggleInspector(current), canFind: current.find != nil)
                    self.layoutDetails(rebuild: true)
                    if let alt = self.alternate { self.showView(at: alt.index) }
                }
            } else {
                Task { try? await self.preparePreviewOfFile(at: url) }
            }
        }
    }

    private func stopMonitor() {
        monitor?.stop()
        monitor = nil
    }

    // MARK: Scroll memory

    private func rememberScroll() {
        guard let url = currentURL, let y = current?.scrollOffset?() else { return }
        scrollMemory.remember(y, for: url)
    }

    open override func viewWillDisappear() {
        super.viewWillDisappear()
        rememberScroll()
        stopMonitor()
        renderTask?.cancel()
    }
}

// MARK: Export (I-10)

extension PreviewHostController {
    /// Export as PDF, HTML or PNG from the Vitrine window: a save sheet named after the file, then the file.
    func export(_ format: PreviewExport.Format) {
        guard let preview = current, let window = view.window else { return }
        let panel = NSSavePanel()
        let base = currentURL?.deletingPathExtension().lastPathComponent ?? "Preview"
        panel.nameFieldStringValue = base + "." + format.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.canCreateDirectories = true
        let title = currentURL?.lastPathComponent ?? base
        panel.beginSheetModal(for: window) { [weak preview] response in
            guard response == .OK, let url = panel.url, let preview else { return }
            Task { @MainActor in
                do {
                    switch format {
                    case .pdf: try await PreviewExport.pdf(of: preview.view, to: url)
                    case .png: try await PreviewExport.png(of: preview.view).write(to: url, options: .atomic)
                    case .html:
                        guard let exporter = preview.htmlExporter else { return }
                        try Data(try await exporter.exportHTML(title: title).utf8).write(to: url, options: .atomic)
                    }
                } catch {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = String(localized: "The preview could not be exported", bundle: .previewKit, comment: "Alert title when Export as PDF, HTML or PNG failed.")
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }
}

// MARK: The trust lens (S-20)

extension PreviewHostController {
    /// The preview's own gutter text, or the lens's calm line when the preview has none.
    func gutter(for preview: RenderedPreview) -> GutterStatus? {
        preview.gutter ?? (lensCalm ? GutterStatus(leading: LensReport.nothingFound.headline) : nil)
    }

    /// Runs the lenses for the shown file off the main thread; a strip and a badge when they find something, the
    /// calm line when they ran and found nothing, nothing at all for kinds the lens does not read.
    func runLens(for preview: RenderedPreview) {
        lensTask?.cancel()
        lensStrip?.removeFromSuperview()
        lensStrip = nil
        lensCalm = false
        guard let url = currentURL else { return }
        let kind = preview.document.kind, text = preview.document.searchText
        lensTask = Task { [weak self, weak preview] in
            let report = await Task.detached(priority: .utility) { PreviewLens.report(for: kind, url: url, fallbackText: text) }.value
            guard !Task.isCancelled, let self, let preview, preview === self.current, let report else { return }
            if report.level > .calm {
                let strip = LensStripView(report: report)
                strip.translatesAutoresizingMaskIntoConstraints = false
                self.stripStack.insertArrangedSubview(strip, at: 0)
                strip.widthAnchor.constraint(equalTo: self.stripStack.widthAnchor).isActive = true
                self.lensStrip = strip
                preview.updateDocument(PreviewLens.badged(preview.document, with: report))
            } else {
                self.lensCalm = true
                if self.alternate == nil { self.capsule.gutter = self.gutter(for: preview) }
            }
        }
    }

    /// A-9: offers an on-device summary above text previews, when the person has not turned the offer off and Apple's
    /// model is ready (asked of VitrineHelper). Nothing is summarised until the person asks.
    func runSummaryOffer(for preview: RenderedPreview) {
        summaryStrip?.removeFromSuperview()
        summaryStrip = nil
        guard let context, SummaryModel.offers(preview.document.kind),
              context.defaults.object(forKey: SummaryModel.settingKey) as? Bool ?? true else { return }
        let text = preview.document.searchText
        guard text.count > 200 else { return }
        Task { @MainActor [weak self, weak preview] in
            guard await HelperClient.canSummarize(), let self, let preview, preview === self.current else { return }
            let strip = NSHostingView(rootView: SummaryStripView(model: SummaryModel(text: text, cache: .standard)))
            strip.translatesAutoresizingMaskIntoConstraints = false
            self.stripStack.addArrangedSubview(strip)
            strip.widthAnchor.constraint(equalTo: self.stripStack.widthAnchor).isActive = true
            self.summaryStrip = strip
        }
    }
}
