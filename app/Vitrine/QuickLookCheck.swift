import AppKit
import Quartz

/// `Vitrine --quicklook <file> [seconds]` opens the file in the system Quick Look panel, the same machinery Finder's
/// Space bar uses (not `qlmanage`, which can pick a different previewer), keeps it up for a few seconds and quits.
/// With `pgrep` beside it this shows which extension really serves a type: the check behind Diagnostics' "check a
/// file" (S-10) and the CSV type fight (redman 2026-10-29). roadmap: S-6, S-10
@MainActor
final class QuickLookCheck: NSObject, QLPreviewPanelDataSource {
    private let url: URL
    private static var current: QuickLookCheck?

    private init(url: URL) { self.url = url }

    static func run(file: URL, seconds: Double) {
        let check = QuickLookCheck(url: file)
        current = check
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate()
        guard let panel = QLPreviewPanel.shared() else {
            FileHandle.standardError.write(Data("no Quick Look panel\n".utf8)); exit(1)
        }
        panel.dataSource = check
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        print("quicklook: showing \(file.lastPathComponent)")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            panel.orderOut(nil)
            exit(0)
        }
        // The deadline must not depend on the main thread: if the extension serving the preview stops or hangs,
        // the panel can block it and the timer above never runs (2026-10-29: a check stayed on screen 6 minutes).
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds + 2) { exit(0) }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL }
    }
}
