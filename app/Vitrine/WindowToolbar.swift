import AppKit
import SwiftUI

/// The window's toolbar (window.html `.tbx`, drawn natively): the title and subtitle on the left (macOS draws them),
/// then Open with <your editor>, Compare, Info and Actions ⌘K. The capsule in the gutter keeps the pill, the viewer
/// switch, find and copy (system V7). A two-file compare hides Open with and Info: two files have no single editor
/// (V7, "The diff case"). roadmap: S-10 (H-3)
@MainActor
final class WindowToolbar: NSObject, NSToolbarDelegate {
    private weak var owner: PreviewWindowController?
    let toolbar: NSToolbar
    let actionsMenu = NSMenu(title: "Actions")
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private var popover: NSPopover?

    static let openWith = NSToolbarItem.Identifier("vitrine.openWith")
    static let compare = NSToolbarItem.Identifier("vitrine.compare")
    static let info = NSToolbarItem.Identifier("vitrine.info")
    static let actions = NSToolbarItem.Identifier("vitrine.actions")

    init(owner: PreviewWindowController) {
        self.owner = owner
        toolbar = NSToolbar(identifier: "vitrine.window")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        actionsMenu.autoenablesItems = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.openWith, Self.compare, Self.info, Self.actions]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch id {
        case Self.openWith:
            item = NSToolbarItem(itemIdentifier: id)
            item.title = Self.openTitle
            item.isBordered = true
            item.action = #selector(PreviewWindowController.openInDefaultApp)
            item.target = owner
        case Self.compare:
            item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: Self.compareWithTitle)
            item.label = String(localized: "Compare", comment: "Vitrine window: toolbar button label")
            item.toolTip = String(localized: "Compare With… ⌘\\", comment: "Vitrine window: toolbar button tooltip, with its shortcut")
            item.isBordered = true
            item.action = #selector(PreviewWindowController.compareWith)
            item.target = owner
        case Self.info:
            item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: Self.infoTitle)
            item.label = Self.infoTitle
            item.toolTip = String(localized: "Info ⌘I", comment: "Vitrine window: toolbar button tooltip, with its shortcut")
            item.isBordered = true
            item.action = #selector(PreviewWindowController.showInfo)
            item.target = owner
        case Self.actions:
            let menuItem = NSMenuToolbarItem(itemIdentifier: id)
            menuItem.title = Self.actionsTitle
            menuItem.label = Self.actionsTitle
            menuItem.showsIndicator = true
            menuItem.menu = actionsMenu
            item = menuItem
        default:
            return nil
        }
        items[id] = item
        return item
    }

    /// Brings every item and the Actions menu in step with what the window shows.
    func update() {
        guard let owner else { return }
        let content = owner.content
        let hasFile: Bool, isCompare: Bool
        switch content {
        case .file: hasFile = true; isCompare = false
        case .failed: hasFile = false; isCompare = false
        case .comparison: hasFile = false; isCompare = true
        case .empty: hasFile = false; isCompare = false
        }
        let app = owner.url.flatMap(PreviewWindowController.defaultApp(for:))
        if let open = items[Self.openWith] {
            open.title = app.map { PreviewWindowController.openWith($0.name) } ?? Self.openTitle
            open.isHidden = isCompare || app == nil || content == .empty
            open.isEnabled = app != nil
        }
        items[Self.compare]?.isEnabled = hasFile
        items[Self.compare]?.isHidden = content == .empty
        items[Self.info]?.isHidden = isCompare || content == .empty
        rebuildActions(hasFile: hasFile, isCompare: isCompare, app: app?.name)
    }

    /// The Actions list (window.html state 2, "Open, switch, compare, follow, pin…"), as a native menu with the
    /// design's shortcuts. Only what this build does is listed.
    private func rebuildActions(hasFile: Bool, isCompare: Bool, app: String?) {
        guard let owner else { return }
        actionsMenu.removeAllItems()
        func add(_ title: String, _ symbol: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ action: Selector, enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = owner
            item.isEnabled = enabled
            actionsMenu.addItem(item)
        }
        func header(_ title: String) {
            if #available(macOS 14.0, *) { actionsMenu.addItem(.sectionHeader(title: title)) }
        }
        header(String(localized: "This tab", comment: "Vitrine window › Actions menu: section heading"))
        add(Self.compareWithTitle, "rectangle.split.2x1", "\\", .command, #selector(PreviewWindowController.compareWith), enabled: hasFile)
        add(String(localized: "Keep Window on Top", comment: "Vitrine window › Actions menu item"), "pin", "t", [.command, .option],
            #selector(PreviewWindowController.toggleKeepOnTop), enabled: true)
        actionsMenu.items.last?.state = owner.keepsOnTop ? .on : .off
        add(Self.infoTitle, "info.circle", "i", .command, #selector(PreviewWindowController.showInfo), enabled: hasFile)
        actionsMenu.addItem(.separator())
        header(String(localized: "Go", comment: "Vitrine window › Actions menu: section heading for opening and revealing"))
        let openIn = app.map { name in String(localized: "Open in \(name)", comment: "Vitrine window › Actions menu item; the default app's name") }
            ?? String(localized: "Open in Default App", comment: "Vitrine window › Actions menu item")
        add(openIn, "arrow.up.forward.app", String(UnicodeScalar(NSDownArrowFunctionKey)!), .command,
            #selector(PreviewWindowController.openInDefaultApp), enabled: hasFile && app != nil)
        add(String(localized: "Reveal in Finder", comment: "Vitrine window › Actions menu item"), "folder", "r", [.command, .shift],
            #selector(PreviewWindowController.revealInFinder), enabled: hasFile || isCompare)
        add(String(localized: "Copy Path", comment: "Vitrine window › Actions menu item and Info button"), "doc.on.doc", "c", [.command, .option],
            #selector(PreviewWindowController.copyPath), enabled: hasFile || isCompare)
    }

    static var openTitle: String { String(localized: "Open", comment: "Vitrine window: toolbar button when the default app has no name") }
    static var compareWithTitle: String { String(localized: "Compare With…", comment: "Vitrine window: compare this file with another") }
    static var infoTitle: String { String(localized: "Info", comment: "Vitrine window: toolbar button and Actions menu item showing the file's facts") }
    static var actionsTitle: String { String(localized: "Actions", comment: "Vitrine window: toolbar menu of actions") }

    /// Info (⌘I): the file's facts, Keep on top and the actions, in a popover under the toolbar button (state 7).
    func showInfo() {
        guard let owner, let url = owner.url, let item = items[Self.info], owner.content != .empty else { return }
        if let popover, popover.isShown { popover.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: WindowInfoView(
            url: url,
            app: PreviewWindowController.defaultApp(for: url)?.name,
            keepOnTop: owner.keepsOnTop,
            toggleKeepOnTop: { [weak owner] in owner?.toggleKeepOnTop() },
            openInApp: { [weak owner] in owner?.openInDefaultApp() },
            reveal: { [weak owner] in owner?.revealInFinder() },
            copyPath: { [weak owner] in owner?.copyPath() }))
        popover.show(relativeTo: item)
        self.popover = popover
    }
}
