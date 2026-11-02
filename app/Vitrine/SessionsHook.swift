import AppKit
import VitrinePreviewKit

/// The person's action behind Settings › Integrations › "Track Claude Code sessions" (design settings.html): shows
/// exactly what will be written to Claude Code's settings file and where, writes it only on "Add Hook", and takes
/// out exactly that line on "Remove Hook". Nothing calls this on its own; the Settings row (and only a click on it)
/// does. roadmap: S-11
@MainActor
enum SessionsHook {
    /// Asks, then adds the hook. Returns whether the hook is installed afterwards.
    @discardableResult
    static func confirmInstall(hook: ClaudeSessionHook = ClaudeSessionHook(), defaults: UserDefaults = VitrineDefaults.shared) -> Bool {
        do {
            guard let plan = try hook.planInstall() else {
                defaults.set(true, forKey: SessionLibrary.Keys.trackClaudeCode)
                return true
            }
            let alert = NSAlert()
            let file = display(plan.file), log = ClaudeSessionHook.logPath
            alert.messageText = String(localized: "Add one hook line to Claude Code’s settings?", comment: "Alert title before Vitrine edits Claude Code's settings file")
            alert.informativeText = String(localized: """
            Vitrine adds the line below to the SessionStart hooks in \(file). When a Claude Code session \
            starts, it appends the session’s id, transcript path and folder to ~/\(log), so the menu \
            bar lists the session. It prints nothing, reads nothing else and sends nothing anywhere. Remove Hook takes out \
            exactly this line.
            """, comment: "Alert text; the settings file's path, then the log file's path; SessionStart is Claude Code's hook name, keep it")
            alert.accessoryView = textBox(plan.change)
            alert.addButton(withTitle: String(localized: "Add Hook", comment: "Alert button that writes the hook line"))
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            try hook.apply(plan)
            defaults.set(true, forKey: SessionLibrary.Keys.trackClaudeCode)
            SessionsMenu.shared.refresh()
            return true
        } catch {
            show(error)
            return hook.isInstalled
        }
    }

    /// Asks, then takes the hook out. Returns whether the hook is gone afterwards.
    @discardableResult
    static func confirmRemove(hook: ClaudeSessionHook = ClaudeSessionHook(), defaults: UserDefaults = VitrineDefaults.shared) -> Bool {
        do {
            guard let plan = try hook.planRemove() else {
                defaults.set(false, forKey: SessionLibrary.Keys.trackClaudeCode)
                return true
            }
            let alert = NSAlert()
            let file = display(plan.file)
            alert.messageText = String(localized: "Remove Vitrine’s hook from Claude Code’s settings?", comment: "Alert title before Vitrine edits Claude Code's settings file")
            alert.informativeText = String(localized: "Vitrine takes this text out of \(file) and changes nothing else. The menu bar stops listing Claude Code sessions.",
                                           comment: "Alert text; the settings file's path")
            alert.accessoryView = textBox(plan.change.trimmingCharacters(in: .whitespacesAndNewlines))
            alert.addButton(withTitle: String(localized: "Remove Hook", comment: "Alert button that takes the hook line out"))
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            try hook.apply(plan)
            defaults.set(false, forKey: SessionLibrary.Keys.trackClaudeCode)
            SessionsMenu.shared.refresh()
            return true
        } catch {
            show(error)
            return !hook.isInstalled
        }
    }

    private static func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// The exact text, selectable, in the system monospaced font.
    private static func textBox(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 96))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        view.string = text
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = [.width]
        scroll.documentView = view
        return scroll
    }

    private static func show(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Claude Code’s settings were not changed", comment: "Alert title when adding or removing the hook failed")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
