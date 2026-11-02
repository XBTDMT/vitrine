import AppKit
import WebKit

/// Renders a file through the real controller into an offscreen window and writes a PNG: the proof mechanism for
/// "does it look right" that needs no Quick Look panel on screen. Used by `Vitrine --snapshot` and the tests.
/// roadmap: S-4
@MainActor
public enum PreviewSnapshot {
    /// Draw in a window placed off every screen instead of at the screen's corner: the connector's worker (X-9) renders
    /// while the person works, so nothing may appear.
    public static var keepsOffscreen = false

    public static func write(file: URL, to output: URL, size: NSSize = NSSize(width: 1000, height: 760),
                             appearance: NSAppearance.Name = .aqua, settleFor seconds: Double = 0.6) async throws {
        try await write(to: output, size: size, appearance: appearance, settleFor: seconds) { try await $0.preparePreviewOfFile(at: file) }
    }

    /// A file with a query typed into the capsule's query mode and run (I-8): `Vitrine --snapshot <file> <out.png>
    /// [dark] --query <program>`, so the jq or SQL result is seen as drawn, with its badge and outcome line.
    public static func write(file: URL, query: String, to output: URL, size: NSSize = NSSize(width: 1000, height: 760),
                             appearance: NSAppearance.Name = .aqua, settleFor seconds: Double = 0.6) async throws {
        try await write(to: output, size: size, appearance: appearance, settleFor: seconds) { controller in
            try await controller.preparePreviewOfFile(at: file)
            let capsule = controller.capsuleForTesting
            capsule.openFind()
            capsule.setFindMode(.query)
            capsule.findQuery = query
            await capsule.runQuery()
        }
    }

    /// Two files compared (S-7): `Vitrine --compare <old> <new> <out.png> [dark]`.
    public static func write(comparing old: URL, with new: URL, to output: URL, size: NSSize = NSSize(width: 1000, height: 760),
                             appearance: NSAppearance.Name = .aqua, settleFor seconds: Double = 0.8) async throws {
        try await write(to: output, size: size, appearance: appearance, settleFor: seconds) { try await $0.showComparison(old: old, new: new) }
    }

    private static func write(to output: URL, size: NSSize, appearance: NSAppearance.Name, settleFor seconds: Double,
                              show: (PreviewHostController) async throws -> Void) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let controller = PreviewHostController()
        controller.loadView()
        controller.view.frame = NSRect(origin: .zero, size: size)
        window.contentView = controller.view
        if keepsOffscreen { window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000)) }
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await show(controller)
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(seconds))
        // The whole frame (preview and gutter), drawn as the export draws it (I-10).
        try await PreviewExport.png(of: controller.view).write(to: output)
    }
}
