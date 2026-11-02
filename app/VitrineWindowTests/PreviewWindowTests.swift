import AppKit
import XCTest
import VitrinePreviewKit

/// The Vitrine window (S-10, H-3; window.html r3-a): requests land as tabs of the frontmost window through the real
/// preview engine. Windows sit far off every screen (WindowSnapshot.offscreenWindows) and are never made key; the
/// files are invented ones in a temporary folder.
@MainActor
final class PreviewWindowTests: XCTestCase {
    var folder: URL!
    var windows: PreviewWindows!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        windows = WindowSnapshot.offscreenWindows()
    }

    override func tearDown() async throws {
        // No test window ever reaches a display: tabbing and centring must not pull one back on screen.
        for c in windows.controllers {
            guard let frame = c.window?.frame else { continue }
            XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(frame) }, "a test window landed on screen at \(frame)")
        }
        windows.closeAll()
        try? FileManager.default.removeItem(at: folder)
    }

    private func make(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url.standardizedFileURL
    }

    private func settle() async {
        for c in windows.controllers { await c.waitForLoad() }
    }

    private func tabs(of controller: PreviewWindowController) -> [PreviewWindowController] {
        controller.window?.tabbedWindows?.compactMap { ($0 as? PreviewWindow)?.controller } ?? [controller]
    }

    func testFilesOpenAsTabsOfOneWindowWithTheirNamesAndFacts() async throws {
        let readme = try make("harbor-sync/README.md", "# harbor-sync\n\nInvented notes.\n")
        let orders = try make("harbor-sync/data/orders.csv", "id,total\n1,2.50\n2,3.75\n")
        windows.handle(.open(files: [readme, orders]), activate: false)
        await settle()
        XCTAssertEqual(windows.controllers.count, 2)
        let first = windows.controllers[0], second = windows.controllers[1]
        XCTAssertEqual(first.content, .file(readme))
        XCTAssertEqual(second.content, .file(orders))
        XCTAssertEqual(Set(tabs(of: first).map(ObjectIdentifier.init)), Set([first, second].map(ObjectIdentifier.init)), "one window, two tabs")
        XCTAssertEqual(first.window?.title, "README.md")
        XCTAssertTrue(first.window?.subtitle.hasPrefix("harbor-sync · ") == true, first.window?.subtitle ?? "")
        XCTAssertEqual(second.window?.subtitle.hasPrefix("data · "), true)
        XCTAssertEqual(first.window?.representedURL, readme)
        XCTAssertFalse(first.preview.view.isHidden, "the real preview engine shows the file")
    }

    func testASecondRequestAddsTabsAndNeverOpensAFileTwice() async throws {
        let a = try make("a.md", "# A\n"), b = try make("b.txt", "bee\n")
        windows.handle(.open(files: [a]), activate: false)
        windows.handle(.open(files: [a, b]), activate: false)
        await settle()
        XCTAssertEqual(windows.controllers.count, 2, "a.md was already open; only b.txt is new")
        XCTAssertEqual(tabs(of: windows.controllers[0]).count, 2)
    }

    func testNewTabsGoAtTheEndOfTheBar() async throws {
        let a = try make("a.md", "# A\n"), b = try make("b.txt", "bee\n"), c = try make("c.txt", "sea\n")
        windows.handle(.open(files: [a, b]), activate: false)
        windows.handle(.open(files: [c]), activate: false)
        await settle()
        let order = tabs(of: windows.controllers[0]).map(\.url?.lastPathComponent)
        XCTAssertEqual(order, ["a.md", "b.txt", "c.txt"])
    }

    func testAnEmptyWindowTakesTheFirstFile() async throws {
        let empty = windows.newEmptyWindow()
        XCTAssertEqual(empty.content, .empty)
        XCTAssertEqual(empty.window?.title, "Vitrine")
        XCTAssertEqual(empty.window?.subtitle, "No file open")
        let a = try make("a.md", "# A\n")
        windows.handle(.open(files: [a]), activate: false)
        await settle()
        XCTAssertEqual(windows.controllers.count, 1)
        XCTAssertEqual(empty.content, .file(a))
    }

    func testNewWindowAndFloatDoNotJoinTheFrontWindow() async throws {
        let a = try make("a.md", "# A\n"), b = try make("b.md", "# B\n"), log = try make("app.log", "14:06:13 INFO started\n")
        windows.handle(.open(files: [a]), activate: false)
        windows.handle(.open(files: [b], newWindow: true), activate: false)
        windows.handle(.open(files: [log], float: true), activate: false)
        await settle()
        XCTAssertEqual(windows.controllers.count, 3)
        for c in windows.controllers { XCTAssertEqual(tabs(of: c).count, 1, "each in its own window") }
        let floating = windows.controllers[2]
        XCTAssertEqual(floating.window?.level, .floating)
        XCTAssertEqual(floating.window?.tabbingMode, .disallowed)
        XCTAssertTrue(floating.keepsOnTop)
        // A later plain request never tabs into the floating window.
        let c = try make("c.md", "# C\n")
        windows.handle(.open(files: [c]), activate: false)
        XCTAssertEqual(windows.controllers.count, 4)
        XCTAssertEqual(tabs(of: floating).count, 1)
    }

    func testCompareShowsBothFilesInOneTabWithoutTheSingleFileButtons() async throws {
        let old = try make("config/staging.yaml", "service: harbor-sync\ninterval: 2s\n")
        let new = try make("config/production.yaml", "service: harbor-sync\ninterval: 5s\n")
        windows.handle(.compare(old: old, new: new), activate: false)
        await settle()
        let c = try XCTUnwrap(windows.controllers.first)
        XCTAssertEqual(c.content, .comparison(old: old, new: new))
        XCTAssertEqual(c.window?.title, "staging.yaml ⇄ production.yaml")
        XCTAssertEqual(c.window?.subtitle, "config · side by side")
        let toolbar = try XCTUnwrap(c.window?.toolbar)
        let items = Dictionary(uniqueKeysWithValues: toolbar.items.map { ($0.itemIdentifier, $0) })
        XCTAssertEqual(items[WindowToolbar.openWith]?.isHidden, true, "two files have no single Open with (system V7)")
        XCTAssertEqual(items[WindowToolbar.info]?.isHidden, true)
    }

    func testAMissingFileKeepsTheWindowWithAMessage() async throws {
        let gone = folder.appendingPathComponent("gone.md").standardizedFileURL
        windows.handle(.open(files: [gone]), activate: false)
        await settle()
        let c = try XCTUnwrap(windows.controllers.first)
        guard case .failed(let url, let message) = c.content else { return XCTFail("\(c.content)") }
        XCTAssertEqual(url, gone)
        XCTAssertTrue(message.contains("gone.md"))
        XCTAssertTrue(c.preview.view.isHidden)
    }

    func testActionsMenuCarriesTheDesignsShortcuts() async throws {
        let a = try make("a.md", "# A\n")
        windows.handle(.open(files: [a]), activate: false)
        await settle()
        let menu = try XCTUnwrap(windows.controllers.first?.actionsMenu)
        func item(_ title: String) -> NSMenuItem? { menu.items.first { $0.title == title } }
        XCTAssertEqual(item("Compare With…")?.keyEquivalent, "\\")
        XCTAssertEqual(item("Keep Window on Top")?.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(item("Info")?.keyEquivalent, "i")
        XCTAssertEqual(item("Reveal in Finder")?.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(item("Copy Path")?.keyEquivalentModifierMask, [.command, .option])
        XCTAssertTrue(item("Compare With…")?.isEnabled == true)
    }

    func testTheWindowRecordsNoRecents() async throws {
        // The app and the tests have no recorder; only the Quick Look extensions write the menu's recents.
        XCTAssertNil(RecentPreviews.processRecorder)
    }

    func testKeepOnTopTogglesTheWindowLevel() async throws {
        let a = try make("a.md", "# A\n")
        windows.handle(.open(files: [a]), activate: false)
        let c = try XCTUnwrap(windows.controllers.first)
        XCTAssertFalse(c.keepsOnTop)
        c.toggleKeepOnTop()
        XCTAssertTrue(c.keepsOnTop)
        XCTAssertEqual(c.actionsMenu.items.first { $0.title == "Keep Window on Top" }?.state, .on)
        c.toggleKeepOnTop()
        XCTAssertFalse(c.keepsOnTop)
    }

    /// Proof pictures for review: runs only when `TEST_RUNNER_VITRINE_WINDOW_PNG_DIR` names a folder (xcodebuild passes
    /// `TEST_RUNNER_`-prefixed variables to the tests without the prefix). Invented sample files, as in the design.
    func testWritesProofPicturesWhenAsked() async throws {
        guard let dir = ProcessInfo.processInfo.environment["VITRINE_WINDOW_PNG_DIR"] else { throw XCTSkip("no picture folder named") }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        let readme = try make("harbor-sync/README.md", """
        # harbor-sync

        Keep a folder of Markdown notes in step with a shared bucket: two-way, offline-first and careful with conflicts.

        ## Install

        ```sh
        brew install example/tap/harbor-sync
        harbor-sync init ~/Notes --bucket notes-archive
        ```

        ## How it works

        harbor-sync watches the folder, batches changes every 2 seconds and uploads only the blocks that changed.

        | key | default | meaning |
        |---|---|---|
        | interval | 2s | how often changes are batched |
        | bucket | none | the bucket to sync with |
        """)
        let orders = try make("harbor-sync/data/orders.csv", "order_id,date,customer,region,items,total,status\n"
            + "HS-10421,2026-10-01,Northwind Florals,West,3,184.20,shipped\nHS-10422,2026-10-01,Bay Street Bikes,Northeast,1,1240.00,paid\n"
            + "HS-10423,2026-10-02,Copper Kettle Café,Midwest,6,96.75,shipped\nHS-10424,2026-10-02,Juniper & Pine,South,2,312.40,refunded\n")
        let staging = try make("harbor-sync/config/staging.yaml", "service: harbor-sync\nenvironment: staging\nsync:\n  interval: 2s\n  batch_limit: 200\nlog:\n  level: debug\n")
        let production = try make("harbor-sync/config/production.yaml", "service: harbor-sync\nenvironment: production\nsync:\n  interval: 5s\n  batch_limit: 200\nlog:\n  level: info\n")
        let recents = [
            RecentPreviews.Entry(path: readme.path, kind: "Markdown", facts: "", time: Date().addingTimeInterval(-120)),
            RecentPreviews.Entry(path: orders.path, kind: "CSV", facts: "", time: Date().addingTimeInterval(-3600)),
        ]
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            try await WindowSnapshot.write(files: [readme], compare: false, dark: dark, to: out.appendingPathComponent("window-file-\(mode).png"))
            try await WindowSnapshot.write(files: [readme, orders], compare: false, dark: dark, to: out.appendingPathComponent("window-tabs-\(mode).png"))
            try await WindowSnapshot.write(files: [staging, production], compare: true, dark: dark, to: out.appendingPathComponent("window-compare-\(mode).png"))
            try await WindowSnapshot.write(files: [], compare: false, dark: dark, to: out.appendingPathComponent("window-empty-\(mode).png"), recents: { recents })
        }
    }

    func testSnapshotWritesTheWholeWindowInBothAppearances() async throws {
        let readme = try make("harbor-sync/README.md", "# harbor-sync\n\nKeep a folder of invented notes in step.\n")
        for dark in [false, true] {
            let out = folder.appendingPathComponent(dark ? "dark.png" : "light.png")
            try await WindowSnapshot.write(files: [readme], compare: false, dark: dark, to: out, settle: 0.5)
            let image = try XCTUnwrap(NSImage(contentsOf: out))
            XCTAssertGreaterThan(image.size.height, PreviewWindowController.fileSize.height, "title bar and toolbar are in the picture")
            XCTAssertEqual(image.size.width, PreviewWindowController.fileSize.width, accuracy: 1)
        }
        let empty = folder.appendingPathComponent("empty.png")
        let entry = RecentPreviews.Entry(path: readme.path, kind: "Markdown", facts: "Markdown · 1 KB", time: Date().addingTimeInterval(-120))
        try await WindowSnapshot.write(files: [], compare: false, dark: false, to: empty, recents: { [entry] }, settle: 0.3)
        XCTAssertNotNil(NSImage(contentsOf: empty))
    }
}
