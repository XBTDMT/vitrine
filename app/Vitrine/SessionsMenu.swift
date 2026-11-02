import AppKit
import VitrinePreviewKit

/// The menu bar's Agent Sessions submenu (parity H-5; design menubar.html "Agent Sessions submenu"): a "Claude Code"
/// section and a "Codex" section of recent sessions, each row its title with "project · N turns · N files changed ·
/// age" under it, then Session Tracking…. The parent row's badge says "3 today" or "None yet".
///
/// Not in the design, plainest native choice: each session row opens a submenu with Open in Vitrine, Quick Look,
/// the files it changed (choosing one opens it in the Vitrine window, ⌥ turns it into Quick Look) and Reveal
/// Transcript in Finder; a switched-off agent's section says so in one disabled row.
///
/// The lists come from SessionLibrary off the main thread (bounded, read-only); the submenu shows what is cached at
/// once and redraws when the read finishes. While the submenu is open and Codex is watched, it reads again every
/// minute (design: "Reads ~/.codex/sessions every minute while the menu is open"). roadmap: S-11
@MainActor
final class SessionsMenu: NSObject, NSMenuDelegate {
    static let shared = SessionsMenu()

    /// What Session Tracking… does: Settings (the Integrations pane holds the switches).
    var openSettings: @MainActor () -> Void = MenuBarController.openSettingsFromAppMenu
    var defaults: UserDefaults = VitrineDefaults.shared

    private let cache = SummaryCache()
    private(set) var claudeCode: [SessionLibrary.Summary] = []
    private(set) var codex: [SessionLibrary.Summary] = []
    private(set) var settings: SessionLibrary.Settings?
    private var refreshing: Task<Void, Never>?
    private var timer: Timer?
    private weak var parentItem: NSMenuItem?
    private weak var openSubmenu: NSMenu?

    /// The row's title; also the submenu's title, which the delegate methods recognise it by.
    static let title = String(localized: "Agent Sessions", comment: "Menu bar: submenu of recent Claude Code and Codex sessions")

    /// The "Agent Sessions" row for the main menu, with its submenu; starts a read in the background.
    func item() -> NSMenuItem {
        let item = NSMenuItem(title: Self.title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
        let submenu = NSMenu(title: Self.title)
        submenu.autoenablesItems = false
        submenu.delegate = self
        item.submenu = submenu
        parentItem = item
        updateBadge()
        refresh()
        return item
    }

    private func updateBadge() {
        let today = (claudeCode + codex).filter { Calendar.current.isDateInToday($0.modified) }.count
        let badge = today > 0 ? String(localized: "\(today) today", comment: "Menu bar › Agent Sessions badge: how many sessions changed today")
            : (claudeCode + codex).isEmpty ? String(localized: "None yet", comment: "Menu bar › Agent Sessions badge: no session found")
            : String(localized: "None today", comment: "Menu bar › Agent Sessions badge: no session changed today")
        parentItem?.badge = NSMenuItemBadge(string: badge)
    }

    // MARK: Reading

    /// Reads both agents' recent sessions off the main thread, then redraws what is showing.
    func refresh(codexOnly: Bool = false) {
        guard refreshing == nil else { return }
        let base = SessionLibrary.settings(from: defaults, hookInstalled: false), cache = self.cache
        refreshing = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (SessionLibrary.Settings, [SessionLibrary.Summary]?, [SessionLibrary.Summary]) in
                var settings = base
                // Tracking is on when the setting says so or the hook is in Claude Code's settings.
                if !settings.tracksClaudeCode { settings.tracksClaudeCode = ClaudeSessionHook().isInstalled }
                let library = SessionLibrary(settings: settings)
                return (settings, codexOnly ? nil : library.recent(.claudeCode, cache: cache), library.recent(.codex, cache: cache))
            }.value
            guard let self else { return }
            self.settings = result.0
            if let claude = result.1 { self.claudeCode = claude }
            self.codex = result.2
            self.refreshing = nil
            self.updateBadge()
            if let menu = self.openSubmenu { self.build(menu) }
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == Self.title else { return }
        build(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu.title == Self.title else { return }
        openSubmenu = menu
        refresh()
        guard settings?.watchesCodex ?? defaults.bool(forKey: SessionLibrary.Keys.watchCodex) else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { SessionsMenu.shared.refresh(codexOnly: true) } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu.title == Self.title else { return }
        openSubmenu = nil
        timer?.invalidate()
        timer = nil
    }

    // MARK: Building

    func build(_ menu: NSMenu) {
        menu.removeAllItems()
        let tracks = settings?.tracksClaudeCode ?? defaults.bool(forKey: SessionLibrary.Keys.trackClaudeCode)
        let watches = settings?.watchesCodex ?? defaults.bool(forKey: SessionLibrary.Keys.watchCodex)
        section(menu, .claudeCode, claudeCode, on: tracks,
                off: String(localized: "Claude Code sessions are not tracked", comment: "Menu bar › Agent Sessions: disabled row when tracking is off"),
                none: String(localized: "No recent Claude Code sessions", comment: "Menu bar › Agent Sessions: disabled row"))
        menu.addItem(.separator())
        section(menu, .codex, codex, on: watches,
                off: String(localized: "Codex sessions are not watched", comment: "Menu bar › Agent Sessions: disabled row when watching is off"),
                none: String(localized: "No recent Codex sessions", comment: "Menu bar › Agent Sessions: disabled row"))
        menu.addItem(.separator())
        let tracking = NSMenuItem(title: String(localized: "Session Tracking…", comment: "Menu bar › Agent Sessions: opens the settings for session tracking"),
                                  action: #selector(showTracking), keyEquivalent: "")
        tracking.target = self
        tracking.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(tracking)
    }

    private func section(_ menu: NSMenu, _ source: SessionSource, _ rows: [SessionLibrary.Summary], on: Bool, off: String, none: String) {
        menu.addItem(.sectionHeader(title: source.displayName))
        guard on else { menu.addItem(disabled(off)); return }
        guard !rows.isEmpty else {
            menu.addItem(disabled(refreshing != nil && settings == nil
                                  ? String(localized: "Reading…", comment: "Menu bar › Agent Sessions: the sessions are being read") : none))
            return
        }
        let now = Date()
        for summary in rows { menu.addItem(row(summary, now: now)) }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A session: its title, the design's sub-line, and its own submenu.
    func row(_ s: SessionLibrary.Summary, now: Date) -> NSMenuItem {
        let item = NSMenuItem(title: s.title, action: nil, keyEquivalent: "")
        item.subtitle = s.subtitle(now: now)
        item.toolTip = s.url.path
        item.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(command(String(localized: "Open in Vitrine", comment: "Menu bar › a session: opens its transcript in the Vitrine window"),
                            symbol: "macwindow", action: #selector(openInWindow(_:)), path: s.url.path))
        sub.addItem(command(String(localized: "Quick Look", comment: "Menu bar › a session: shows its transcript in Quick Look"),
                            symbol: "eye", action: #selector(quickLook(_:)), path: s.url.path))
        sub.addItem(.separator())
        if s.changedFiles.isEmpty {
            sub.addItem(disabled(String(localized: "No files changed", comment: "Menu bar › a session: the session changed no file")))
        } else {
            sub.addItem(.sectionHeader(title: s.isPartial
                ? String(localized: "Changed files (from the start of the session)", comment: "Menu bar › a session: heading when only the start of a long session was read")
                : String(localized: "Changed files", comment: "Menu bar › a session: heading above the files it changed")))
            let base = s.changedFiles.first.map { _ in commonFolder(s.changedFiles) } ?? ""
            for path in s.changedFiles.prefix(20) {
                let name = (path as NSString).lastPathComponent
                let folder = (path as NSString).deletingLastPathComponent
                let exists = FileManager.default.fileExists(atPath: path)
                let open = command(name, symbol: "doc", action: #selector(openInWindow(_:)), path: path)
                open.subtitle = folder.hasPrefix(base) && folder.count > base.count ? String(folder.dropFirst(base.count + 1)) : nil
                open.toolTip = exists ? path : String(localized: "\(path) is not there any more", comment: "Menu bar › a session: tooltip of a changed file that was deleted or moved")
                open.isEnabled = exists
                sub.addItem(open)
                let look = command(String(localized: "Quick Look “\(name)”", comment: "Menu bar › a session: with Option held, shows the file in Quick Look; the file's name"),
                                   symbol: "eye", action: #selector(quickLook(_:)), path: path)
                look.isAlternate = true
                look.keyEquivalentModifierMask = .option
                look.isEnabled = exists
                sub.addItem(look)
            }
            if s.changedFiles.count > 20 {
                let more = s.changedFiles.count - 20
                sub.addItem(disabled(String(localized: "\(more) more in the session’s Changes",
                                            comment: "Menu bar › a session: how many more changed files the session's Changes view lists")))
            }
        }
        sub.addItem(.separator())
        sub.addItem(command(String(localized: "Reveal Transcript in Finder", comment: "Menu bar › a session: menu item"),
                            symbol: "folder", action: #selector(reveal(_:)), path: s.url.path))
        item.submenu = sub
        return item
    }

    private func command(_ title: String, symbol: String, action: Selector, path: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = path
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    /// The folder every changed file sits under, so rows can say "src/export" rather than a whole path.
    private func commonFolder(_ paths: [String]) -> String {
        let parts = paths.map { ($0 as NSString).deletingLastPathComponent.split(separator: "/", omittingEmptySubsequences: false) }
        guard var common = parts.first else { return "" }
        for p in parts.dropFirst() {
            common = Array(zip(common, p).prefix { $0 == $1 }.map(\.0))
        }
        return common.joined(separator: "/")
    }

    // MARK: Actions

    @objc private func openInWindow(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSApp.activate()
        PreviewWindows.shared.open([URL(fileURLWithPath: path)])
    }

    @objc private func quickLook(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        MenuBarQuickLook.shared.show(URL(fileURLWithPath: path))
    }

    @objc private func reveal(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func showTracking() { openSettings() }
}
