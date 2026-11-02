import SwiftUI
import ImageIO
import VitrinePreviewKit
import VitrineThumbnail

/// The host app: Settings, a menu bar extra with recent files, diagnostics, and the window the command-line tool
/// opens previews into. The Quick Look extensions live in its PlugIns folder; macOS registers them when the app
/// is first launched from /Applications. Started by VitrineMain.
struct VitrineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(Text(verbatim: "Vitrine"), id: "main") {
            WelcomeView()
                .frame(minWidth: 520, minHeight: 380)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 620, height: 440)
        // SwiftUI presents this first window at every launch; AppDelegate closes it again when the launch came with
        // files or a `vitrine` request (`.defaultLaunchBehavior(.suppressed)` did not stop it, measured 2026-11-01).

        // Diagnostics (S-10, B-8, H-4): which previewer answers for each type, the extensions, and repair tools.
        // Titled from MenuBarController.diagnosticsTitle, the string the menu bar looks the window up by.
        Window(Text(MenuBarController.diagnosticsTitle), id: "diagnostics") {
            DiagnosticsView(store: DiagnosticsStore.shared)
        }
        .defaultSize(width: 880, height: 660)
        .commands {
            CommandGroup(after: .windowArrangement) { DiagnosticsMenuItem() }
        }

        // The vitrine command's install controls (S-10, H-3) until the Settings › Integrations row hosts them.
        Window("Command Line Tool", id: "command-line") {
            CommandLineInstallView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appSettings) { CommandLineMenuItem() }
            // Vitrine › Check for Updates… (H-8, G-21): says "not set up" until the release key and feed exist.
            CommandGroup(after: .appInfo) { Button("Check for Updates…") { UpdateCoordinator.shared.checkNowAndTell() } }
            // The Vitrine window (S-10, H-3): File › New Window and Open… put files in it.
            CommandGroup(replacing: .newItem) {
                Button("New Window") { PreviewWindows.shared.newEmptyWindow(); NSApp.activate() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { PreviewWindows.shared.openWithPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// Vitrine › Command Line Tool…: the install controls for the vitrine command.
struct CommandLineMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Command Line Tool…") { openWindow(id: "command-line"); NSApp.activate() }
    }
}

/// Window › Diagnostics (⌥⌘D).
struct DiagnosticsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Diagnostics") { openWindow(id: "diagnostics") }
            .keyboardShortcut("d", modifiers: [.command, .option])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `Vitrine.app/Contents/MacOS/Vitrine --diagnose` prints the extension table and exits: the same check
        // the Welcome window shows, usable from a terminal or a bug report.
        if CommandLine.arguments.contains("--diagnose") {
            for line in Diagnostics.pluginkitMatches() where line.contains("xbtdmt") { print(line) }
            for e in Diagnostics.statuses(from: Diagnostics.pluginkitMatches()) { print("\(e.name): \(e.state.rawValue)") }
            // The Diagnostics window's File Types and Extensions panes as text (S-10, B-8): which previewer answers
            // for each claimed type, measured the same way the window measures it. `--diagnose types` lists every type.
            let snapshot = DiagnosticsProbe.snapshot()
            print("")
            print(DiagnosticsReportText.make(appVersion: Diagnostics.appVersion, macOS: Diagnostics.macOSVersion, generated: snapshot.date,
                                             fileTypes: snapshot.fileTypes, extensions: snapshot.extensions))
            if CommandLine.arguments.contains("types") {
                for c in snapshot.claimed { print("\(c.uti)\t\(c.family)\t\(snapshot.owners[c.uti].map(Diagnostics.describe) ?? "?")") }
            }
            exit(0)
        }
        // `Vitrine --diagnostics` opens the Diagnostics window; `--diagnostics-snapshot <out.png> [dark] [types|extensions]`
        // draws it offscreen to a PNG from a live check (S-10).
        // (`--diagnostics` itself is read by DiagnosticsStore.openOnLaunch; the Welcome window opens the scene.)
        if let i = CommandLine.arguments.firstIndex(of: "--diagnostics-snapshot"), CommandLine.arguments.count > i + 1 {
            let args = CommandLine.arguments
            let out = URL(fileURLWithPath: args[i + 1])
            let dark = args.dropFirst(i + 2).contains("dark")
            let pane: DiagnosticsPane = args.dropFirst(i + 2).contains("extensions") ? .extensions : .fileTypes
            DiagnosticsSnapshotWriter.write(to: out, pane: pane, dark: dark)
            return
        }
        // `Vitrine --settings-snapshot <pane> <out.png> [dark]`: one Settings pane drawn off-screen (SettingsSnapshot.swift).
        if let i = CommandLine.arguments.firstIndex(of: "--settings-snapshot"), CommandLine.arguments.count > i + 2,
           let pane = SettingsPane(rawValue: CommandLine.arguments[i + 1]) {
            let args = CommandLine.arguments
            SettingsSnapshotWriter.write(pane: pane, to: URL(fileURLWithPath: args[i + 2]), dark: args.dropFirst(i + 3).contains("dark"))
            return
        }
        // `Vitrine --window-snapshot <out.png> [dark] [--compare] [file…]`: the Vitrine window drawn off-screen to a PNG
        // (S-10, H-3): no file draws the empty window, two files with --compare the side-by-side compare. Read before
        // --snapshot and --compare, whose names it can carry.
        if let i = CommandLine.arguments.firstIndex(of: "--window-snapshot"), CommandLine.arguments.count > i + 1 {
            let rest = Array(CommandLine.arguments.dropFirst(i + 1))
            let out = URL(fileURLWithPath: rest[0])
            let dark = rest.contains("dark"), compare = rest.contains("--compare")
            let files = rest.dropFirst().filter { $0 != "dark" && $0 != "--compare" }.map { URL(fileURLWithPath: $0).standardizedFileURL }
            Task { @MainActor in
                do { try await WindowSnapshot.write(files: files, compare: compare, dark: dark, to: out); print("wrote \(out.path)"); exit(0) }
                catch { FileHandle.standardError.write(Data("window snapshot failed: \(error)\n".utf8)); exit(1) }
            }
            return
        }
        // `Vitrine --window-probe <report.txt> [seconds]`: proves the command path without touching the screen or the
        // person's settings. The app starts with none of its background parts (menu bar, settings bridge, services,
        // folder icons), keeps every Vitrine window off-screen, rewrites the report after each request that reaches
        // `application(_:open:)`, and quits after the given seconds (default 30).
        if let i = CommandLine.arguments.firstIndex(of: "--window-probe"), CommandLine.arguments.count > i + 1 {
            let args = CommandLine.arguments
            let report = URL(fileURLWithPath: args[i + 1])
            let seconds = args.count > i + 2 ? Double(args[i + 2]) ?? 30 : 30
            let windows = PreviewWindows.shared
            windows.present = WindowSnapshot.presentOffscreen
            windows.keepsOffscreen = true
            windows.recents = { [] }
            windows.onChange = { try? Data((WindowSnapshot.describe(windows) + "\n").utf8).write(to: report) }
            try? Data("ready\n".utf8).write(to: report)
            // Known gap: SwiftUI still opens the app's first scene (the Welcome window) on screen at launch, as it does
            // for --snapshot; closing it from here did not work (measured 2026-10-30).
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
            return
        }
        // `Vitrine --thumbnail <file> <out.png> [dark]`: the file's Finder thumbnail at every size from 16 to 512 pt on
        // Finder's light (or dark) backdrop, drawn by the Thumbnails extension's own code (S-18).
        if let i = CommandLine.arguments.firstIndex(of: "--thumbnail"), CommandLine.arguments.count > i + 2 {
            let args = CommandLine.arguments
            let file = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            let dark = args.count > i + 3 && args[i + 3] == "dark"
            do {
                let page = try ThumbnailPage.make(url: file)
                guard let image = ThumbnailRenderer.proof(page, backdrop: dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 1, alpha: 1)),
                      let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
                CGImageDestinationAddImage(dest, image, nil)
                exit(CGImageDestinationFinalize(dest) ? 0 : 1)
            } catch {
                FileHandle.standardError.write(Data("thumbnail failed: \(error)\n".utf8)); exit(1)
            }
        }
        // `Vitrine --helper register|unregister|status|ping` (X-3): VitrineHelper's registration and a call to it.
        if let i = CommandLine.arguments.firstIndex(of: "--helper"), CommandLine.arguments.count > i + 1 {
            let command = CommandLine.arguments[i + 1]
            Task { @MainActor in HelperControl.run(command) }
            return
        }
        // `Vitrine --snapshot <file> <out.png> [dark] [--query <program>]` renders a file through the real preview controller offscreen
        // and writes a PNG: the way to prove a renderer looks right without a Quick Look panel on screen.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 2 {
            let args = CommandLine.arguments
            let file = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            let dark = args.count > i + 3 && args[i + 3] == "dark"
            Task { @MainActor in
                do {
                    if let q = args.firstIndex(of: "--query"), args.count > q + 1 {
                        try await PreviewSnapshot.write(file: file, query: args[q + 1], to: out, appearance: dark ? .darkAqua : .aqua)
                    } else {
                        try await PreviewSnapshot.write(file: file, to: out, appearance: dark ? .darkAqua : .aqua)
                    }
                    print("wrote \(out.path)"); exit(0)
                }
                catch { FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8)); exit(1) }
            }
            return
        }
        // `Vitrine --compare <old> <new> <out.png> [dark]`: two files compared in the diff design (S-7), offscreen.
        if let i = CommandLine.arguments.firstIndex(of: "--compare"), CommandLine.arguments.count > i + 3 {
            let args = CommandLine.arguments
            let old = URL(fileURLWithPath: args[i + 1]), new = URL(fileURLWithPath: args[i + 2]), out = URL(fileURLWithPath: args[i + 3])
            let dark = args.count > i + 4 && args[i + 4] == "dark"
            Task { @MainActor in
                do { try await PreviewSnapshot.write(comparing: old, with: new, to: out, appearance: dark ? .darkAqua : .aqua); print("wrote \(out.path)"); exit(0) }
                catch { FileHandle.standardError.write(Data("compare failed: \(error)\n".utf8)); exit(1) }
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--quicklook"), CommandLine.arguments.count > i + 1 {
            let args = CommandLine.arguments
            let seconds = args.count > i + 2 ? Double(args[i + 2]) ?? 6 : 6
            QuickLookCheck.run(file: URL(fileURLWithPath: args[i + 1]), seconds: seconds)
            return
        }
        // `Vitrine --settings sync`: folds the extensions' own changes into the app's settings and publishes them into
        // every extension's container (G-19 route B), as the running app does on every change.
        // `Vitrine --settings set <key> <text>` · `unset <key>`: changes one setting in the app's own store and publishes
        // it to the extensions, as the Settings window does.
        if let i = CommandLine.arguments.firstIndex(of: "--settings"), CommandLine.arguments.count > i + 2,
           ["set", "unset"].contains(CommandLine.arguments[i + 1]) {
            let a = CommandLine.arguments, key = a[i + 2]
            if a[i + 1] == "set", a.count > i + 3 { VitrineDefaults.shared.set(a[i + 3], forKey: key) } else { VitrineDefaults.shared.removeObject(forKey: key) }
            SettingsBridge.shared.publish()
            print("\(key): \(VitrineDefaults.shared.object(forKey: key).map { "\($0)" } ?? "unset")")
            exit(0)
        }
        // `Vitrine --settings show <key>`: the app's value for one key and what each extension's snapshot holds.
        if let i = CommandLine.arguments.firstIndex(of: "--settings"), CommandLine.arguments.count > i + 2, CommandLine.arguments[i + 1] == "show" {
            let key = CommandLine.arguments[i + 2]
            print("app: \(VitrineDefaults.shared.object(forKey: key).map { "\($0)" } ?? "unset")")
            for ext in ContainerBridge.extensions() {
                let snap = SettingsSnapshot.read(ext.supportDirectory.appendingPathComponent(SettingsSnapshot.fileName))
                print("\(ext.id): \(snap == nil ? "no snapshot" : snap!.values[key].map { "\($0)" } ?? "unset")")
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--settings"), CommandLine.arguments.count > i + 1, CommandLine.arguments[i + 1] == "sync" {
            let taken = SettingsBridge.shared.collect()
            print("synced; taken from the extensions: \(taken.isEmpty ? "nothing" : taken.joined(separator: ", "))")
            exit(0)
        }
        // `Vitrine --recents has|forget <path>` · `count`: checks the menu's recents (H-2) for one path without printing
        // any other entry, since the list is the person's own; `forget` takes one test entry out again.
        if let i = CommandLine.arguments.firstIndex(of: "--recents"), CommandLine.arguments.count > i + 1 {
            let args = CommandLine.arguments, recents = RecentPreviews.forApp()
            let path = args.count > i + 2 ? URL(fileURLWithPath: args[i + 2]).standardizedFileURL.path : nil
            switch (args[i + 1], path) {
            case ("has", let p?): print(recents.entries().contains { $0.path == p } ? "yes" : "no")
            case ("forget", let p?): recents.forget(path: p); print("forgot")
            case ("count", _): print(recents.entries().count)
            default: FileHandle.standardError.write(Data("usage: --recents has|forget <path> | count\n".utf8)); exit(2)
            }
            exit(0)
        }
        // `Vitrine --folder-icon add|remove <folder>` · `refresh` · `list`: folder contents on Finder's icon (O-3, G-18).
        if let i = CommandLine.arguments.firstIndex(of: "--folder-icon"), CommandLine.arguments.count > i + 1 {
            let args = CommandLine.arguments, verb = args[i + 1]
            let folder = args.count > i + 2 ? URL(fileURLWithPath: args[i + 2]).standardizedFileURL : nil
            MainActor.assumeIsolated {
                do {
                    switch (verb, folder) {
                    case ("add", let f?): try FolderContentIcons.choose(f); print("showing contents on \(f.path)")
                    case ("remove", let f?): FolderContentIcons.unchoose(f); print("plain icon on \(f.path)")
                    case ("refresh", _): for f in FolderContentIcons.refresh() { print("redrew \(f.path)") }
                    case ("list", _): for f in FolderContentIcons.chosen() { print(f.path) }
                    case ("draw", let f?) where args.count > i + 4:
                        // `--folder-icon draw <folder> <style> <out.png> [pixels]`: draws a look to a PNG; the folder is only read.
                        guard let style = FolderThumbnail.Style(rawValue: args[i + 3]) else { throw FolderContentIcons.Failure.notAFolder(args[i + 3]) }
                        let px = args.count > i + 5 ? Int(args[i + 5]) ?? 256 : 256
                        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                        let items = FolderThumbnail.items(in: f, limit: style.itemCount, pixelSize: max(64, px))
                        FolderThumbnail.draw(items, in: NSGraphicsContext(bitmapImageRep: rep)!.cgContext, size: CGSize(width: px, height: px), style: style)
                        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 4]))
                    default: FileHandle.standardError.write(Data("usage: --folder-icon add|remove <folder> | refresh | list | draw <folder> fan|front|grid <out.png> [pixels]\n".utf8)); exit(2)
                    }
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
                }
            }
        }
        Diagnostics.shared.refreshExtensionStatus()
        // Settings reach the extensions through their own containers (G-19 route B), both ways, while the app runs.
        SettingsBridge.shared.start()
        // At most once a day, only when allowed in Settings and only when this build has a release key and feed (G-21).
        Task { @MainActor in await UpdateCoordinator.shared.scheduledCheck() }
        // The menu bar menu (H-2, menubar r3-a) is AppKit: it follows general.showMenuBarIcon itself.
        MenuBarController.shared.openDiagnostics = { MenuBarController.showWindow(id: "diagnostics", menuTitle: MenuBarController.diagnosticsTitle) }
        MenuBarController.shared.start()
        // Finder's Services menu (right-click a folder) reaches the two folder-icon actions below.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        FolderContentIcons.refresh()
        folderIconWatcher.start()
        // Spotlight re-reads the types Vitrine's importer claims, once per build (S-19, X-8).
        SpotlightReimport.runIfNeeded()
        // Vulnerability hints (G-26): a weekly refresh only when the person turned it on.
        AdvisoryUpdater.shared.runWeeklyIfDue()
        // VitrineHelper (X-3): re-registered when an update replaced it (SP-3); left off if the person never turned it on.
        Task { @MainActor in await HelperLifecycle.shared.reconcileAtLaunch() }
        // The Welcome window belongs to a plain launch. Files and `vitrine` requests arrive in application(_:open:)
        // around now, so it is checked on the next turn of the run loop and again a moment later.
        for delay in [0.0, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if self.openedAtLaunch || !PreviewWindows.shared.controllers.isEmpty {
                    for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true { window.close() }
                } else if delay > 0 {
                    Self.showWelcome()
                }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: The Vitrine window (S-10, H-3)

    /// Everything that asks Vitrine to show files arrives here: `vitrine://` requests from the `vitrine` command (and
    /// Raycast or Alfred links), files from Finder's Open With, the Dock icon or `open -a Vitrine <file>`. A running
    /// Vitrine gets them as an Apple event, so they land in its existing window as tabs. Bringing Vitrine forward is
    /// Launch Services' part (the command asks it to unless `-g`), so nothing here activates the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        var files: [URL] = []
        for url in urls {
            if url.isFileURL { files.append(url); continue }
            do { PreviewWindows.shared.handle(try VitrineRequest(url: url), activate: false) }
            catch { NSLog("Vitrine ignored a request it could not read: %@", "\(error)") }
        }
        if !files.isEmpty { PreviewWindows.shared.open(files) }
    }

    /// Set when files or a `vitrine` request arrive, so the Welcome window stays closed for that launch.
    private var openedAtLaunch = false

    /// The Dock icon with no window open brings the Welcome window back, as SwiftUI's first scene used to.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.showWelcome() }
        return true
    }

    static func showWelcome() { MenuBarController.showWindow(id: "main", menuTitle: "Vitrine") }

    // MARK: Folder contents on Finder's icon (O-3, G-18)

    private lazy var folderIconWatcher = FolderIconWatcher()

    /// Folders on the services pasteboard: file URLs only, through the reader the Quick Action Services use.
    private func folders(on pboard: NSPasteboard) -> [URL] {
        ServicesPasteboard.fileURLs(on: pboard).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    /// Any app can call a Service, so Vitrine (unsandboxed) changes a folder's icon only after the person says yes
    /// in Vitrine's own window (S-16, G-35: a Service acts only with the person's grant).
    private func confirm(_ folders: [URL], show: Bool) -> Bool {
        guard !folders.isEmpty else { return false }
        NSApp.activate()
        let alert = NSAlert()
        let names = folders.prefix(5).map { "“\($0.lastPathComponent)”" }.joined(separator: ", ")
            + (folders.count > 5 ? " …" : "")
        alert.messageText = show
            ? String(localized: "Show the contents on the icon of \(names)?", comment: "Folder-icon Service confirmation; names are quoted folder names")
            : String(localized: "Remove the contents from the icon of \(names)?", comment: "Folder-icon Service confirmation; names are quoted folder names")
        alert.informativeText = String(localized: "Vitrine was asked through the Services menu to change this folder icon. Go ahead only if you chose this yourself.",
                                       comment: "Folder-icon Service confirmation detail")
        alert.addButton(withTitle: show ? String(localized: "Show Contents", comment: "Folder-icon Service confirm button")
                                        : String(localized: "Remove", comment: "Folder-icon Service confirm button"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Folder-icon Service cancel button"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func showContentsOnFolderIcon(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let chosen = folders(on: pboard)
        guard confirm(chosen, show: true) else { return }
        var failures: [String] = []
        for folder in chosen {
            do { try FolderContentIcons.choose(folder) } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { error.pointee = failures.joined(separator: "\n") as NSString }
    }

    @objc func removeContentsFromFolderIcon(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let chosen = folders(on: pboard)
        guard confirm(chosen, show: false) else { return }
        for folder in chosen { FolderContentIcons.unchoose(folder) }
    }
}
