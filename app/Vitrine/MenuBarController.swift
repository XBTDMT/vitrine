import AppKit
import Combine
import SwiftUI
import VitrinePreviewKit

/// Vitrine's menu bar item and its menu: the picked design r3-a "Quiet native menu" (menubar.html), recent-previews
/// slice (H-2). A real NSMenu, rebuilt each time it opens: the state sentence (needs-you banners when a part is off),
/// the five most recent previews with a rendered thumbnail, their facts and ⌘1–⌘5, More Recent Previews (the rest of
/// the ten, Clear, Pause), then Open File, Settings, Diagnostics and Quit. macOS draws the highlight (design D4).
///
/// AppKit rather than SwiftUI's MenuBarExtra: a `.menu` extra cannot hold a custom view (the wrapped state sentence,
/// banners with a button), set a row's image to a picture that arrives later, or rebuild on open through
/// NSMenuDelegate; a `.window` extra is not a native menu, which the pick is. roadmap: S-10 (H-2)
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    /// The recents the extensions wrote to the app group. Replaced only by the off-screen render harness.
    var recents = RecentPreviews.forApp()
    var diagnostics: Diagnostics = .shared
    /// What Settings… does; the default presses the app menu's own Settings item (⌘,), which SwiftUI's Settings
    /// scene installs, because AppKit has no public call that opens a SwiftUI Settings scene.
    var openSettings: @MainActor () -> Void = MenuBarController.openSettingsFromAppMenu
    /// What Diagnostics… does; the default brings up the Vitrine window (it holds the extension table today).
    var openDiagnostics: @MainActor () -> Void = MenuBarController.showMainWindow

    private var statusItem: NSStatusItem?
    let menu = NSMenu()
    private let thumbnails = MenuBarThumbnails()
    private var statusKnown = false
    private var headerItem: NSMenuItem?
    private var isOpen = false
    private var subscriptions: Set<AnyCancellable> = []

    static let showIconKey = "general.showMenuBarIcon"

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    /// Puts the item in the menu bar (when Settings says so) and keeps it in step with the setting and with the
    /// extension table.
    func start() {
        diagnostics.$extensions.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.statusKnown = true
            if self.isOpen { self.refreshHeader() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.applyVisibility() }
            .store(in: &subscriptions)
        applyVisibility()
    }

    private func applyVisibility() {
        let show = VitrineDefaults.shared.object(forKey: Self.showIconKey) as? Bool ?? true
        if show, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // The picked mark (20 Lens and page) is not in the asset catalog yet; this is the symbol the app used.
            let image = NSImage(systemSymbolName: "rectangle.and.text.magnifyingglass", accessibilityDescription: "Vitrine")
            image?.isTemplate = true
            item.button?.image = image
            item.menu = menu
            statusItem = item
        } else if !show, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuild()
        diagnostics.refreshExtensionStatus()
    }

    func menuWillOpen(_ menu: NSMenu) { if menu === self.menu { isOpen = true } }
    func menuDidClose(_ menu: NSMenu) { if menu === self.menu { isOpen = false } }

    // MARK: Building

    var state: MenuBarState { .make(from: diagnostics.extensions, known: statusKnown) }

    /// Marks the extension table as answered (the render harness, which has no pluginkit round trip).
    func assumeStatusKnown() { statusKnown = true }

    func rebuild() {
        menu.removeAllItems()
        let header = NSMenuItem()
        header.view = hostingView(MenuBarHeader(state: state) { [weak self] fix in self?.perform(fix) })
        headerItem = header
        menu.addItem(header)
        menu.addItem(.separator())
        addRecents()
        menu.addItem(.separator())
        // Agent Sessions (S-11, H-5): the design puts it between Clipboard and Pinned Windows, neither built yet.
        SessionsMenu.shared.openSettings = openSettings
        menu.addItem(SessionsMenu.shared.item())
        menu.addItem(.separator())
        menu.addItem(command(String(localized: "Open File in Vitrine…", comment: "Menu bar menu item"), symbol: "doc", key: "o", action: #selector(openFile)))
        menu.addItem(command(String(localized: "Settings…", comment: "Menu bar menu item"), symbol: "gearshape", key: ",", action: #selector(settings)))
        menu.addItem(command(String(localized: "Diagnostics…", comment: "Opens the Diagnostics window"), symbol: "stethoscope", key: "", action: #selector(showDiagnostics)))
        menu.addItem(.separator())
        menu.addItem(command(String(localized: "Quit Vitrine", comment: "Menu bar menu item"), symbol: "power", key: "q", action: #selector(quit)))
    }

    private func refreshHeader() {
        guard let headerItem else { return }
        headerItem.view = hostingView(MenuBarHeader(state: state) { [weak self] fix in self?.perform(fix) })
        menu.itemChanged(headerItem)
    }

    private func addRecents() {
        let entries = recents.existingEntries()
        menu.addItem(.sectionHeader(title: String(localized: "Recent Previews", comment: "Menu bar: section heading above the recently previewed files")))
        if entries.isEmpty {
            let note = NSMenuItem()
            note.view = hostingView(MenuBarNote(text: recents.isRecording ? Self.firstRunNote : Self.pausedNote))
            menu.addItem(note)
        }
        for (i, entry) in entries.prefix(5).enumerated() {
            menu.addItem(row(for: entry, key: "\(i + 1)"))
        }
        guard !entries.isEmpty || !recents.isRecording else { return }
        let more = NSMenuItem(title: String(localized: "More Recent Previews", comment: "Menu bar: submenu with the older recent files and the recents controls"),
                              action: nil, keyEquivalent: "")
        let rest = entries.dropFirst(5)
        if !rest.isEmpty {
            let n = rest.count
            more.badge = NSMenuItemBadge(string: String(localized: "\(n) more", comment: "Menu bar: badge, how many more recent files the submenu holds"))
        }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for entry in rest { submenu.addItem(row(for: entry, key: "")) }
        if !rest.isEmpty { submenu.addItem(.separator()) }
        let clear = command(String(localized: "Clear Recent Previews", comment: "Menu bar menu item"), symbol: "xmark.circle", key: "", action: #selector(clearRecents))
        clear.isEnabled = !entries.isEmpty
        submenu.addItem(clear)
        let pause = command(String(localized: "Pause Recents", comment: "Menu bar menu item; checked while recent previews are not kept"),
                            symbol: "pause.circle", key: "", action: #selector(togglePause))
        pause.state = recents.isRecording ? .off : .on
        submenu.addItem(pause)
        more.submenu = submenu
        menu.addItem(more)
    }

    static var firstRunNote: String {
        String(localized: "Nothing yet. Press Space on a file in Finder and it lands here, with what it is and how big. Kept on this Mac only; Settings › General turns recents off.",
               comment: "Menu bar: shown before any file was previewed")
    }
    static var pausedNote: String {
        String(localized: "Recents are paused: previews are not kept. More Recent Previews › Pause Recents turns them back on.",
               comment: "Menu bar: shown while recents are paused; More Recent Previews › Pause Recents names the menu items")
    }

    /// A recent row: its picture, its name, its facts as the native subtitle, ⌘1–⌘5 for the first five.
    private func row(for entry: RecentPreviews.Entry, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: entry.name, action: #selector(openRecent(_:)), keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = key.isEmpty ? [] : .command
        item.subtitle = entry.facts
        item.toolTip = entry.path
        item.representedObject = entry.path
        item.image = thumbnails.image(for: entry.url) { [weak item] image in item?.image = image }
        return item
    }

    private func command(_ title: String, symbol: String, key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func hostingView<V: View>(_ view: V) -> NSView {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        return host
    }

    // MARK: Actions

    private func perform(_ fix: MenuBarState.Fix) {
        menu.cancelTracking()
        switch fix {
        case .turnOn: diagnostics.openExtensionsSettings()
        case .diagnostics: openDiagnostics()
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        // In the Vitrine window (H-3), the design's action for a recent preview.
        NSApp.activate()
        PreviewWindows.shared.open([URL(fileURLWithPath: path)])
    }

    @objc private func openFile() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { PreviewWindows.shared.open(panel.urls) }
        }
    }

    @objc private func settings() { openSettings() }
    @objc private func showDiagnostics() { openDiagnostics() }
    @objc private func clearRecents() { recents.clear() }
    @objc private func togglePause() { recents.isRecording.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    static func openSettingsFromAppMenu() {
        NSApp.activate()
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command })
        else { return }
        appMenu.performActionForItem(at: index)
    }

    static func showMainWindow() { showWindow(id: "main", menuTitle: "Vitrine") }

    /// The Diagnostics window's title, as its scene and the Window menu spell it.
    static var diagnosticsTitle: String { String(localized: "Diagnostics", comment: "The Diagnostics window's title and its Window menu item") }

    /// Brings a SwiftUI Window scene forward by its id, or reopens a closed one from its Window-menu item.
    static func showWindow(id: String, menuTitle: String) {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true }) {
            window.makeKeyAndOrderFront(nil)
        } else if let windowMenu = NSApp.windowsMenu,
                  let index = windowMenu.items.firstIndex(where: { $0.title == menuTitle && $0.action != nil }) {
            // A closed SwiftUI Window scene is reopened from the item SwiftUI keeps for it in the Window menu.
            windowMenu.performActionForItem(at: index)
        }
    }
}
