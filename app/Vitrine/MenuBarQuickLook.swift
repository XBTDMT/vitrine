import AppKit
import Quartz

/// Opens a file in the system Quick Look panel from the menu: the same machinery as Finder's Space bar, so Vitrine's
/// extension draws it. The design opens recents in the Vitrine window (Pin); that window is not built yet (S-10), so
/// choosing a row Quick Looks it instead. roadmap: S-10 (H-2)
@MainActor
final class MenuBarQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = MenuBarQuickLook()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        NSApp.activate()
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let item: NSURL? = MainActor.assumeIsolated { url.map { $0 as NSURL } }
        return item
    }
}
