import AppKit
import SwiftUI

/// `Vitrine --settings-snapshot <pane> <out.png> [dark]`: one Settings pane drawn off-screen to a PNG, the way
/// `--diagnostics-snapshot` draws Diagnostics, so a pane is checked without opening or clicking anything (S-24 proof
/// tool). `<pane>` is a SettingsPane name: general, fileTypes, appearance, markdown, code, folders, privacy, about.
/// roadmap: S-24
@MainActor
enum SettingsSnapshotWriter {
    static func write(pane: SettingsPane, to url: URL, dark: Bool) {
        let size = NSSize(width: 960, height: 760)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: SettingsView(page: .pane(pane), searchable: false))
        window.contentView = host
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        Task { @MainActor in
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(400))
            }
            let view = window.contentView?.superview ?? host
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            do {
                try rep.representation(using: .png, properties: [:])?.write(to: url)
                print("wrote \(url.path)"); exit(0)
            } catch {
                FileHandle.standardError.write(Data("settings snapshot failed: \(error)\n".utf8)); exit(1)
            }
        }
    }
}
