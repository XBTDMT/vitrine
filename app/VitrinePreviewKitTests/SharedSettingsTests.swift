import XCTest
@testable import VitrinePreviewKit

/// Settings between the app and its extensions without an app-group container (G-19 route B): an extension's own
/// changes layered over the app's snapshot, newest first; the app publishing into every container and folding the
/// extensions' changes back. Temporary folders stand in for the containers; private defaults suites only.
/// roadmap: S-10
@MainActor
final class SharedSettingsTests: XCTestCase {
    private var dir: URL!
    private var suites: [String] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for s in suites { UserDefaults(suiteName: s)?.removePersistentDomain(forName: s) }
        try? FileManager.default.removeItem(at: dir)
    }

    private func suite(_ name: String) -> String {
        let s = "vt-shared-\(name)-\(UUID().uuidString)"
        suites.append(s)
        return s
    }

    private func layered(snapshot: URL) throws -> LayeredDefaults {
        try XCTUnwrap(LayeredDefaults(snapshotURL: snapshot, localSuite: suite("local")))
    }

    func testTheNewerOfTheAppsValueAndTheExtensionsOwnWins() throws {
        let snap = dir.appendingPathComponent(SettingsSnapshot.fileName)
        let now = Date().timeIntervalSince1970
        try SettingsSnapshot(values: ["markdown.theme": "harbor", "markdown.toc": false], times: ["markdown.theme": now - 100, "markdown.toc": now - 100]).write(to: snap)
        let d = try layered(snapshot: snap)
        XCTAssertEqual(d.string(forKey: "markdown.theme"), "harbor", "the app's value when the extension set none")
        XCTAssertFalse(d.bool(forKey: "markdown.toc"))
        XCTAssertNil(d.object(forKey: "never.set"))

        d.set("ember", forKey: "markdown.theme")
        XCTAssertEqual(d.string(forKey: "markdown.theme"), "ember", "the extension's own, newer change")
        XCTAssertNotNil(d.persistentDomain(forName: suites[0])?[LayeredDefaults.changedPrefix + "markdown.theme"], "with when it changed")

        // The app changes it later: the app's value applies again.
        Thread.sleep(forTimeInterval: 0.6)
        try SettingsSnapshot(values: ["markdown.theme": "porcelain"], times: ["markdown.theme": Date().timeIntervalSince1970 + 1]).write(to: snap)
        XCTAssertEqual(d.string(forKey: "markdown.theme"), "porcelain")
    }

    func testTypedWritesAndReadsGoThroughTheLayers() throws {
        let d = try layered(snapshot: dir.appendingPathComponent("none.plist"))
        d.set(3, forKey: "n"); d.set(true, forKey: "b"); d.set(1.5, forKey: "x")
        XCTAssertEqual(d.integer(forKey: "n"), 3)
        XCTAssertTrue(d.bool(forKey: "b"))
        XCTAssertEqual(d.double(forKey: "x"), 1.5)
        d.removeObject(forKey: "n")
        XCTAssertEqual(d.integer(forKey: "n"), 0)
    }

    /// Two "extensions" (folders) and the app's master suite, end to end.
    func testTheAppPublishesAndFoldsBackTheNewestChange() throws {
        let masterSuite = suite("master")
        let master = try XCTUnwrap(UserDefaults(suiteName: masterSuite))
        master.set("harbor", forKey: "markdown.theme")
        master.set(["/tmp/a.md": 120.0], forKey: ScrollMemory.defaultsKey)
        let exts = ["markdown", "code"].map { ContainerBridge.Extension(id: "io.test.\($0)", containerData: dir.appendingPathComponent($0)) }
        let bridge = SettingsBridge(master: master, domain: masterSuite, extensions: exts, stateDirectory: dir.appendingPathComponent("app"))

        let snapshot = bridge.publish(now: 1000)
        XCTAssertEqual(snapshot.values["markdown.theme"] as? String, "harbor")
        XCTAssertNil(snapshot.values[ScrollMemory.defaultsKey], "per-extension state is never published")
        for ext in exts {
            XCTAssertEqual(SettingsSnapshot.read(ext.supportDirectory.appendingPathComponent(SettingsSnapshot.fileName))?.values["markdown.theme"] as? String, "harbor")
        }
        XCTAssertEqual(bridge.publish(now: 2000).times["markdown.theme"], 1000, "an unchanged value keeps its time")

        // The Markdown extension picked another theme at t=3000 (its own preferences file, as cfprefsd writes it).
        let prefs: [String: Any] = ["markdown.theme": "ember", LayeredDefaults.changedPrefix + "markdown.theme": 3000.0,
                                    ScrollMemory.defaultsKey: ["/tmp/b.md": 9.0], LayeredDefaults.changedPrefix + ScrollMemory.defaultsKey: 3000.0]
        try FileManager.default.createDirectory(at: exts[0].preferencesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0).write(to: exts[0].preferencesFile)
        XCTAssertEqual(bridge.collect(), ["markdown.theme"], "scroll positions stay the extension's own")
        XCTAssertEqual(master.string(forKey: "markdown.theme"), "ember", "folded into the app's settings")
        let code = SettingsSnapshot.read(exts[1].supportDirectory.appendingPathComponent(SettingsSnapshot.fileName))
        XCTAssertEqual(code?.values["markdown.theme"] as? String, "ember", "and passed on to the other extensions")
        XCTAssertEqual(code?.times["markdown.theme"], 3000, "with the time it was made, so nothing ping-pongs")
        XCTAssertEqual(bridge.collect(), [], "an old change is not taken twice")

        // An older change in an extension never beats a newer one in the app.
        master.set("graphite", forKey: "markdown.theme")
        bridge.publish(now: 5000)
        XCTAssertEqual(bridge.collect(), [])
        XCTAssertEqual(master.string(forKey: "markdown.theme"), "graphite")
    }

    func testExtensionsAreFoundByTheirBundleIDs() throws {
        let app = dir.appendingPathComponent("Vitrine.app")
        for (name, id) in [("VitrineCode", "io.test.code"), ("VitrineMarkdown", "io.test.markdown")] {
            let contents = app.appendingPathComponent("Contents/PlugIns/\(name).appex/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundlePackageType": "XPC!"], format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        let found = ContainerBridge.extensions(of: app, home: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(found.map(\.id), ["io.test.code", "io.test.markdown"])
        XCTAssertEqual(found[0].supportDirectory.path, "/Users/someone/Library/Containers/io.test.code/Data/Library/Application Support/Vitrine")
        XCTAssertEqual(found[0].preferencesFile.path, "/Users/someone/Library/Containers/io.test.code/Data/Library/Preferences/io.test.code.plist")
    }
}
