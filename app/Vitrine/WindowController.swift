import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VitrinePreviewKit
import VitrineUI

/// One tab of the Vitrine window (window.html r3-a "Tabbed viewer"): a native window whose toolbar carries the file's
/// name with its facts as the subtitle, Open with <your editor>, Compare, Info and Actions; under it the real preview
/// engine, the same `PreviewHostController` the Quick Look extensions use, with its Glass Capsule in the gutter.
/// Tabs are macOS's own window tabs, so one file reads like Quick Look (no tab bar, state 9) and a second file grows
/// the Safari-style bar (state 2). With no file it shows the empty window (state 10). roadmap: S-10 (H-3)
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    enum Content: Equatable {
        case empty
        case file(URL)
        case comparison(old: URL, new: URL)
        case failed(URL, String)
    }

    private(set) var content: Content = .empty
    let preview = PreviewHostController()
    private let body = WindowDropView()
    private var emptyHost: NSView?
    private var messageHost: NSView?
    private var loadTask: Task<Void, Never>?
    private var loadedModification: Date?
    private lazy var toolbarController = WindowToolbar(owner: self)
    /// Recents for the empty window; the app reads the menu's list (read-only), tests and snapshots pass their own.
    let recents: () -> [RecentPreviews.Entry]
    /// Told when the window closes, so the window list lets go of it.
    var onClose: ((PreviewWindowController) -> Void)?
    /// Files dropped on the window or picked from its empty state: the manager opens them (the first replaces an
    /// empty window, the rest become tabs).
    var onOpenFiles: (([URL], PreviewWindowController) -> Void)?

    static let tabbingIdentifier = "io.github.xbtdmt.vitrine.window"
    static let fileSize = NSSize(width: 980, height: 640)     // "Markdown opens at 980 × 640" (state 7, B1)
    static let emptySize = NSSize(width: 860, height: 520)    // state 10
    static let floatSize = NSSize(width: 560, height: 380)    // the small on-top window (state 1, 8)
    static let minimumSize = NSSize(width: 480, height: 320)

    init(size: NSSize = PreviewWindowController.emptySize,
         recents: @escaping () -> [RecentPreviews.Entry] = { RecentPreviews.forApp().existingEntries() }) {
        self.recents = recents
        let window = PreviewWindow(contentRect: NSRect(origin: .zero, size: size),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.minSize = Self.minimumSize
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .automatic
        window.isRestorable = false
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.backgroundColor = .token("win")
        super.init(window: window)
        window.delegate = self
        window.controller = self

        let root = NSViewController()
        root.view = body
        root.addChild(preview)
        preview.hostsInWindow = true   // the toolbar carries Open with and Info (V7)
        preview.loadView()
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        preview.view.isHidden = true
        body.addSubview(preview.view)
        pin(preview.view)
        body.onDrop = { [weak self] urls in
            guard let self else { return }
            self.onOpenFiles?(urls, self)
        }
        window.contentViewController = root
        window.setContentSize(size)
        window.toolbar = toolbarController.toolbar
        showEmpty()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a nib") }

    var url: URL? {
        switch content {
        case .file(let u), .failed(let u, _): return u
        case .comparison(_, let new): return new
        case .empty: return nil
        }
    }

    // MARK: Showing things

    /// Shows a file through the real preview engine. A file that cannot be shown keeps the window with a message.
    func show(_ url: URL) {
        let url = url.standardizedFileURL
        loadTask?.cancel()
        content = .file(url)
        loadedModification = Self.modificationDate(url)
        applyChrome()
        guard FileManager.default.fileExists(atPath: url.path) else { return fail(url, Self.gone(url)) }
        showPreviewView()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.preview.preparePreviewOfFile(at: url)
            } catch is CancellationError {
            } catch {
                guard self.content == .file(url) else { return }
                self.fail(url, Self.message(for: error, url: url))
            }
        }
    }

    /// Two files side by side in one tab (Compare With… ⌘\, `vitrine compare`): the diff design's two-file compare.
    func showComparison(old: URL, new: URL) {
        let old = old.standardizedFileURL, new = new.standardizedFileURL
        loadTask?.cancel()
        content = .comparison(old: old, new: new)
        loadedModification = nil
        applyChrome()
        for file in [old, new] where !FileManager.default.fileExists(atPath: file.path) {
            return fail(new, Self.gone(file))
        }
        showPreviewView()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.preview.showComparison(old: old, new: new) }
            catch is CancellationError {}
            catch {
                guard self.content == .comparison(old: old, new: new) else { return }
                self.fail(new, Self.message(for: error, url: new))
            }
        }
    }

    /// Waits for the current load (tests and snapshots).
    func waitForLoad() async { await loadTask?.value }

    private func fail(_ url: URL, _ message: String) {
        content = .failed(url, message)
        applyChrome()
        preview.view.isHidden = true
        emptyHost?.removeFromSuperview(); emptyHost = nil
        messageHost?.removeFromSuperview()
        let app = Self.defaultApp(for: url)
        let view = NSHostingView(rootView: WindowMessageView(
            title: message,
            detail: url.deletingLastPathComponent().path,
            actionTitle: app.map { Self.openWith($0.name) },
            action: { [weak self] in self?.openInDefaultApp() }))
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        pin(view)
        messageHost = view
    }

    private func showEmpty() {
        content = .empty
        applyChrome()
        preview.view.isHidden = true
        messageHost?.removeFromSuperview(); messageHost = nil
        let view = NSHostingView(rootView: WindowEmptyView(entries: recents(), open: { [weak self] url in
            guard let self else { return }
            self.onOpenFiles?([url], self)
        }))
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        pin(view)
        emptyHost = view
    }

    private func showPreviewView() {
        emptyHost?.removeFromSuperview(); emptyHost = nil
        messageHost?.removeFromSuperview(); messageHost = nil
        preview.view.isHidden = false
    }

    private func pin(_ v: NSView) {
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            v.topAnchor.constraint(equalTo: body.safeAreaLayoutGuide.topAnchor),
            v.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }

    // MARK: Title, subtitle, toolbar

    private func applyChrome() {
        guard let window else { return }
        switch content {
        case .empty:
            window.title = "Vitrine"
            window.subtitle = String(localized: "No file open", comment: "Vitrine window: subtitle of an empty window")
            window.representedURL = nil
        case .file(let url), .failed(let url, _):
            window.title = url.lastPathComponent
            window.subtitle = Self.facts(for: url)
            window.representedURL = url
        case .comparison(let old, let new):
            window.title = "\(old.lastPathComponent) ⇄ \(new.lastPathComponent)"
            window.subtitle = Self.compareSubtitle(old: old, new: new)
            window.representedURL = nil
        }
        window.tab.title = window.title
        toolbarController.update()
    }

    /// The design's subtitle: where it lives, then the kind and the size ("harbor-sync · Markdown · 6.2 KB").
    static func facts(for url: URL) -> String {
        var parts = [url.deletingLastPathComponent().lastPathComponent]
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey])
        if let kind = values?.localizedTypeDescription { parts.append(kind) }
        if values?.isDirectory != true, let size = values?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func compareSubtitle(old: URL, new: URL) -> String {
        let a = old.deletingLastPathComponent().lastPathComponent, b = new.deletingLastPathComponent().lastPathComponent
        return a == b ? String(localized: "\(a) · side by side", comment: "Vitrine window subtitle when comparing two files in one folder; the folder's name")
                      : String(localized: "\(a) ⇄ \(b) · side by side", comment: "Vitrine window subtitle when comparing two files; the two folders' names")
    }

    static func message(for error: Error, url: URL) -> String {
        if let render = error as? RenderError {
            let name = url.lastPathComponent
            switch render {
            case .unsupported: return String(localized: "Vitrine has no preview for this kind of file yet.", comment: "Vitrine window: message instead of a preview")
            case .tooLarge: return render.errorDescription ?? String(localized: "This file is too large to preview.", comment: "Vitrine window: message instead of a preview")
            case .unreadable: return String(localized: "Vitrine cannot read \(name).", comment: "Vitrine window: message instead of a preview; the file's name")
            case .cancelled: return String(localized: "The preview was stopped.", comment: "Vitrine window: message instead of a preview")
            }
        }
        return error.localizedDescription
    }

    /// "README.md is not there any more."
    static func gone(_ url: URL) -> String {
        let name = url.lastPathComponent
        return String(localized: "\(name) is not there any more.", comment: "Vitrine window: message when the file was deleted or moved; the file's name")
    }

    /// "Open with Visual Studio Code": the toolbar button and the message view's button.
    static func openWith(_ app: String) -> String {
        String(localized: "Open with \(app)", comment: "Vitrine window: button that opens the file in its default app; the app's name")
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Actions (toolbar, Actions menu, keys)

    /// The app that opens this file by default, never Vitrine itself (the design's "Open with VS Code").
    static func defaultApp(for url: URL) -> (url: URL, name: String)? {
        let me = Bundle.main.bundleIdentifier
        let candidates = [NSWorkspace.shared.urlForApplication(toOpen: url)].compactMap { $0 } + NSWorkspace.shared.urlsForApplications(toOpen: url)
        guard let app = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier != me }) else { return nil }
        return (app, FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
    }

    @objc func openInDefaultApp() {
        guard let url, let app = Self.defaultApp(for: url) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func revealInFinder() {
        let files: [URL]
        switch content {
        case .comparison(let old, let new): files = [old, new]
        case .empty: files = []
        default: files = url.map { [$0] } ?? []
        }
        if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
    }

    @objc func copyPath() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc func toggleKeepOnTop() {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
        toolbarController.update()
    }

    var keepsOnTop: Bool { window?.level == .floating }

    /// Compare With… (⌘\): pick a second file; the tab becomes the side-by-side compare of this file and it.
    @objc func compareWith() {
        guard let window, case .file(let current) = content else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = current.deletingLastPathComponent()
        let name = current.lastPathComponent
        panel.message = String(localized: "Compare \(name) with…", comment: "Open panel message for Compare With…; the current file's name")
        panel.prompt = String(localized: "Compare", comment: "Open panel button for Compare With…")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let other = panel.url else { return }
            MainActor.assumeIsolated { self?.showComparison(old: current, new: other) }
        }
    }

    @objc func showInfo() { toolbarController.showInfo() }

    @objc func openFile() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onOpenFiles?(urls, self)
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        onClose?(self)
    }

    /// A background tab stops watching its file when it is ordered out; coming back, it reloads a file that changed
    /// meanwhile, so a tab never shows an old copy as current.
    func windowDidBecomeKey(_ notification: Notification) {
        guard case .file(let url) = content, let seen = loadedModification,
              let now = Self.modificationDate(url), now != seen else { return }
        show(url)
    }
}

/// The window itself: hands the Actions menu's key equivalents (⌘\, ⌘I, ⌥⌘T, ⇧⌘R, ⌥⌘C, ⌘↓) to the menu, since a
/// toolbar's menu is not part of the main menu and would not see them otherwise.
@MainActor
final class PreviewWindow: NSWindow {
    weak var controller: PreviewWindowController?

    /// Set only by the off-screen snapshot: lets the frame sit outside every screen.
    var allowsOffscreenFrame = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let menu = controller?.actionsMenu, menu.performKeyEquivalent(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffscreenFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

extension PreviewWindowController {
    var actionsMenu: NSMenu { toolbarController.actionsMenu }
    var toolbarForTesting: WindowToolbar { toolbarController }
}

/// The window's body: takes files dropped on it ("Drop a file here", state 10) anywhere in the window.
final class WindowDropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    // The page colour, resolved again whenever light and dark change.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.layer?.backgroundColor = NSColor.token("page").cgColor }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a nib") }

    private func files(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { files(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
