import AppKit
import VitrinePreviewKit
import WebKit

/// Draws the Vitrine window to a PNG without putting anything on the person's screen: the windows sit far outside
/// every display, are never made key and the app is never brought forward. The proof for "does the window look
/// right" (`Vitrine --window-snapshot <out.png> [dark] [--compare] [file…]`), and what the tests use.
/// roadmap: S-10 (H-3)
@MainActor
enum WindowSnapshot {
    static let offscreen = NSPoint(x: -30000, y: -30000)

    /// A window manager whose windows never reach the screen.
    static func offscreenWindows(recents: @escaping () -> [RecentPreviews.Entry] = { [] }, dark: Bool? = nil) -> PreviewWindows {
        _ = NSApplication.shared
        let windows = PreviewWindows()
        windows.activates = false
        windows.keepsOffscreen = true
        windows.recents = recents
        if let dark { windows.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
        windows.present = presentOffscreen
        return windows
    }

    static func presentOffscreen(_ controller: PreviewWindowController) {
        guard let window = controller.window as? PreviewWindow else { return }
        window.allowsOffscreenFrame = true
        if window.tabGroup?.windows.first === window || window.tabGroup == nil { window.setFrameOrigin(offscreen) }
        window.orderFrontRegardless()
    }

    /// One line per window, in tab-group order: what each shows and whether it floats. The `--window-probe` report.
    static func describe(_ windows: PreviewWindows) -> String {
        var groups: [[PreviewWindowController]] = []
        for c in windows.controllers {
            if groups.contains(where: { $0.contains { $0 === c } }) { continue }
            groups.append(c.window?.tabbedWindows?.compactMap { ($0 as? PreviewWindow)?.controller } ?? [c])
        }
        var lines: [String] = []
        for (g, group) in groups.enumerated() {
            for c in group {
                let what: String
                switch c.content {
                case .empty: what = "empty"
                case .file(let u): what = "file \(u.lastPathComponent)"
                case .comparison(let a, let b): what = "compare \(a.lastPathComponent) \(b.lastPathComponent)"
                case .failed(let u, _): what = "failed \(u.lastPathComponent)"
                }
                lines.append("window \(g + 1)\t\(what)\t\(c.keepsOnTop ? "on top" : "normal")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Opens `files` (or compares the first two) in an off-screen window and writes the selected tab as a PNG.
    static func write(files: [URL], compare: Bool, dark: Bool, to output: URL,
                      recents: @escaping () -> [RecentPreviews.Entry] = { [] }, settle: Double = 1.0) async throws {
        let windows = offscreenWindows(recents: recents, dark: dark)
        defer { windows.closeAll() }
        if compare, files.count == 2 {
            windows.handle(.compare(old: files[0], new: files[1]), activate: false)
        } else if files.isEmpty {
            windows.newEmptyWindow()
        } else {
            windows.handle(.open(files: files), activate: false)
        }
        guard let controller = windows.controllers.last, let window = controller.window else { throw RenderError.cancelled }
        await controller.waitForLoad()
        try await Task.sleep(for: .seconds(settle))
        try await png(of: window, to: output)
    }

    /// The whole window, title bar and toolbar included, with any web view's page painted into its frame.
    static func png(of window: NSWindow, to output: URL) async throws {
        guard let frameView = window.contentView?.superview else { throw RenderError.cancelled }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { throw RenderError.cancelled }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        for web in webViews(in: frameView) where !web.isHidden && web.window != nil && !hiddenAncestor(web) {
            let config = WKSnapshotConfiguration(); config.rect = web.bounds
            let page = try await web.takeSnapshot(configuration: config)
            let frame = web.convert(web.bounds, to: frameView)
            image.lockFocusFlipped(frameView.isFlipped)
            page.draw(in: frame)
            image.unlockFocus()
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.cancelled }
        try data.write(to: output)
    }

    private static func hiddenAncestor(_ view: NSView) -> Bool {
        var v: NSView? = view
        while let current = v { if current.isHidden { return true }; v = current.superview }
        return false
    }

    private static func webViews(in view: NSView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { webViews(in: $0) }
    }
}
