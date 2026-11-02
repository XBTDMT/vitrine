import AppKit
import VitrinePreviewKit

/// Every Vitrine window, and the one place requests land: `vitrine` commands and `vitrine://` links
/// (`application(_:open:)` with a URL), files from Finder's Open With, ⌘O, File › New Window, drops.
///
/// The rule from window.html state 8: named files open as tabs of the frontmost Vitrine window, as real tabs (the
/// italic preview tab belongs to Quick Look's pin, not to named files). A file already open in that window is
/// brought forward instead of opened twice. `--float` puts each file in its own small window kept on top; `--new-window`
/// starts a fresh window. roadmap: S-10 (H-3)
@MainActor
final class PreviewWindows {
    static let shared = PreviewWindows()

    private(set) var controllers: [PreviewWindowController] = []
    /// Whether a request brings Vitrine forward (`vitrine -g` leaves it behind).
    var activates = true
    /// Recents for empty windows; replaced in tests.
    var recents: () -> [RecentPreviews.Entry] = { RecentPreviews.forApp().existingEntries() }
    /// Off-screen mode (snapshots, tests, `--window-probe`): every window is placed outside all displays from the
    /// moment it exists, before a tab group or centring can pull it back onto a screen.
    var keepsOffscreen = false
    /// Told after every request is handled (the `--window-probe` report).
    var onChange: (() -> Void)?
    /// A fixed appearance for every new window (the snapshot's light or dark); nil follows the system.
    var appearance: NSAppearance?
    /// Puts each new window on screen; the off-screen snapshot and the tests replace it.
    var present: (PreviewWindowController) -> Void = { controller in
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Requests

    func handle(_ request: VitrineRequest, activate: Bool? = nil) {
        switch request {
        case .open(let files, let float, _, let newWindow):
            if float {
                for file in files { openFloating(file) }
            } else {
                open(files, newWindow: newWindow)
            }
        case .compare(let old, let new):
            let controller = target(newWindow: false).flatMap { $0.content == .empty ? $0 : nil } ?? addTab(to: target(newWindow: false))
            controller.showComparison(old: old, new: new)
            focus(controller)
        }
        if activate ?? activates { NSApplication.shared.activate() }
        onChange?()
    }

    /// Files from Finder (Open With, dropped on the Dock icon) and from `open -a Vitrine <files>`.
    func open(_ files: [URL], newWindow: Bool = false, into window: PreviewWindowController? = nil) {
        guard !files.isEmpty else { return }
        var last: PreviewWindowController?
        var host = window ?? target(newWindow: newWindow)
        for file in files.prefix(VitrineRequest.maxFiles) {
            let file = file.standardizedFileURL
            if let existing = host.flatMap({ tab(showing: file, in: $0) }) {
                last = existing
                continue
            }
            let controller: PreviewWindowController
            if let h = host, h.content == .empty {
                controller = h
            } else {
                controller = addTab(to: host)
            }
            controller.show(file)
            host = host ?? controller
            last = controller
        }
        if let last { focus(last) }
        onChange?()
    }

    /// An empty window (File › New Window ⌘N, or Vitrine opened with nothing to show).
    @discardableResult
    func newEmptyWindow() -> PreviewWindowController {
        let controller = make(size: PreviewWindowController.emptySize)
        center(controller)
        present(controller)
        return controller
    }

    /// File › Open… (⌘O): a sheet on the key Vitrine window, or a free panel when none is open.
    func openWithPanel() {
        if let key = keyController { key.openFile(); return }
        NSApplication.shared.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { self?.open(urls) }
        }
    }

    // MARK: Windows and tabs

    /// The frontmost Vitrine window that takes tabs (not a floating one), unless a new window was asked for.
    func target(newWindow: Bool) -> PreviewWindowController? {
        guard !newWindow else { return nil }
        let ordered = NSApplication.shared.orderedWindows.compactMap { ($0 as? PreviewWindow)?.controller }
        let candidates = ordered.isEmpty ? controllers.reversed() : ordered
        return candidates.first { $0.window?.level != .floating && controllers.contains($0) }
    }

    /// The tab in `window`'s group that shows `file`.
    func tab(showing file: URL, in window: PreviewWindowController) -> PreviewWindowController? {
        let group = window.window?.tabbedWindows?.compactMap { ($0 as? PreviewWindow)?.controller } ?? [window]
        return group.first { if case .file(let u) = $0.content { return u == file } else { return false } }
    }

    private func addTab(to host: PreviewWindowController?) -> PreviewWindowController {
        let controller = make(size: host?.window?.frame.size ?? PreviewWindowController.fileSize)
        if let hostWindow = host?.window, let window = controller.window {
            // New tabs go at the end of the bar, as in Safari.
            let anchor = hostWindow.tabGroup?.windows.last ?? hostWindow
            anchor.addTabbedWindow(window, ordered: .above)
        } else {
            center(controller)
        }
        present(controller)
        return controller
    }

    private func openFloating(_ file: URL) {
        let controller = make(size: PreviewWindowController.floatSize)
        controller.window?.tabbingMode = .disallowed
        center(controller)
        controller.show(file)
        controller.toggleKeepOnTop()
        present(controller)
    }

    private func make(size: NSSize) -> PreviewWindowController {
        let controller = PreviewWindowController(size: size, recents: recents)
        if let appearance { controller.window?.appearance = appearance }
        if keepsOffscreen, let window = controller.window as? PreviewWindow {
            window.allowsOffscreenFrame = true
            window.setFrameOrigin(WindowSnapshot.offscreen)
        }
        controller.onClose = { [weak self] closed in self?.controllers.removeAll { $0 === closed } }
        controller.onOpenFiles = { [weak self] files, from in self?.open(files, into: from) }
        controllers.append(controller)
        return controller
    }

    private func center(_ controller: PreviewWindowController) {
        if !keepsOffscreen { controller.window?.center() }
    }

    private func focus(_ controller: PreviewWindowController) {
        guard let window = controller.window else { return }
        if window.tabGroup?.selectedWindow !== window { window.tabGroup?.selectedWindow = window }
        present(controller)
    }

    /// The key Vitrine window's controller, for the app's menu commands.
    var keyController: PreviewWindowController? {
        (NSApplication.shared.keyWindow as? PreviewWindow)?.controller ?? (NSApplication.shared.mainWindow as? PreviewWindow)?.controller
    }

    /// Closes every window (tests).
    func closeAll() {
        for controller in controllers { controller.window?.close() }
        controllers.removeAll()
    }
}
