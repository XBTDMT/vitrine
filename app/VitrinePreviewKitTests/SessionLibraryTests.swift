import XCTest
@testable import VitrinePreviewKit

/// The Agent Sessions list and the session hook (S-11, H-5). Every folder is a temporary one made here with
/// invented transcripts; the hook is planned, applied and removed only on a settings file in that folder, and its
/// command runs only with HOME pointed there. Nothing under the real home folder is read or written. roadmap: S-11
final class SessionLibraryTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("vt-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    @discardableResult
    func put(_ relative: String, _ text: String, modified: Date? = nil) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    func settings(track: Bool = true, codex: Bool = true) -> SessionLibrary.Settings {
        SessionLibrary.Settings(tracksClaudeCode: track, claudeFolder: SessionLibrary.defaultClaudeFolder(home: home),
                                hookLog: SessionLibrary.hookLog(home: home), watchesCodex: codex, codexFolder: SessionLibrary.defaultCodexFolder(home: home))
    }

    // MARK: The list

    func testRecentSessionsNewestFirstWithinTheWindow() throws {
        let now = Date()
        try put(".claude/projects/-Users-example-tidepool/a.jsonl", SessionFixtures.claudeCode(), modified: now.addingTimeInterval(-24 * 60))
        try put(".claude/projects/-Users-example-tidepool/old.jsonl", SessionFixtures.claudeCode(), modified: now.addingTimeInterval(-30 * 86_400))
        try put(".claude/projects/-Users-example-other/b.jsonl", SessionFixtures.jsonl([
            SessionFixtures.cc("user", "10:00:00", ["role": "user", "content": "Add CSV export"])]), modified: now.addingTimeInterval(-3 * 3600))
        try put(".claude/projects/-Users-example-other/notes.jsonl", SessionFixtures.plainJSONL, modified: now)
        try put(".claude/projects/-Users-example-other/readme.txt", "x", modified: now)
        let list = SessionLibrary(settings: settings()).recent(.claudeCode, now: now)
        XCTAssertEqual(list.map(\.url.lastPathComponent), ["a.jsonl", "b.jsonl"])
        XCTAssertEqual(list[0].title, "Fix flaky export test and add a CSV header option")
        XCTAssertEqual(list[0].subtitle(now: now), "tidepool · 14 turns · 3 files changed · 24 min")
        XCTAssertEqual(list[1].changedFiles, [])
    }

    func testSwitchedOffAgentsListNothing() throws {
        try put(".claude/projects/p/a.jsonl", SessionFixtures.claudeCode())
        let lib = SessionLibrary(settings: settings(track: false, codex: false))
        XCTAssertEqual(lib.recent(.claudeCode), [])
        XCTAssertEqual(lib.recent(.codex), [])
    }

    func testHookLoggedTranscriptsAreListed() throws {
        let elsewhere = try put("Work/config-two/projects/p/live.jsonl", SessionFixtures.claudeCode())
        // The log holds one compact line and one pretty-printed payload; both are read.
        let pretty = "{\n  \"session_id\": \"s2\",\n  \"transcript_path\": \"\(home.path)/missing.jsonl\"\n}\n"
        try put(ClaudeSessionHook.logPath, SessionFixtures.line(["session_id": "s1", "transcript_path": elsewhere.path, "hook_event_name": "SessionStart"]) + "\n" + pretty)
        XCTAssertEqual(ClaudeSessionHook.loggedTranscripts(log: SessionLibrary.hookLog(home: home)).count, 2)
        let list = SessionLibrary(settings: settings()).recent(.claudeCode)
        XCTAssertEqual(list.map(\.url.lastPathComponent), ["live.jsonl"])
    }

    func testCodexDateFolders() throws {
        let now = Date()
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: now)
        let day = String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!)
        try put(".codex/sessions/\(day)/rollout-1.jsonl", SessionFixtures.codex(), modified: now)
        try put(".codex/sessions/rollout-flat.jsonl", SessionFixtures.codex(), modified: now.addingTimeInterval(-60))
        let list = SessionLibrary(settings: settings()).recent(.codex, now: now)
        XCTAssertEqual(list.map(\.url.lastPathComponent), ["rollout-1.jsonl", "rollout-flat.jsonl"])
        XCTAssertEqual(list[0].subtitle(now: now), "harbor-api · 2 turns · 2 files changed · just now")
        XCTAssertEqual(SessionLibrary(settings: settings()).recent(.claudeCode, now: now), [], "a Codex file is never a Claude Code row")
    }

    func testBoundsCapTheList() throws {
        var s = settings()
        s.maxSessions = 2
        for i in 0..<5 { try put(".claude/projects/p/s\(i).jsonl", SessionFixtures.claudeCode(), modified: Date().addingTimeInterval(Double(-i * 60))) }
        XCTAssertEqual(SessionLibrary(settings: s).recent(.claudeCode).map(\.url.lastPathComponent), ["s0.jsonl", "s1.jsonl"])
        s.maxEntries = 1
        XCTAssertLessThanOrEqual(SessionLibrary(settings: s).recent(.claudeCode).count, 1)
    }

    func testSettingsFromDefaults() {
        let defaults = UserDefaults(suiteName: "vt-sessions-\(UUID().uuidString)")!
        var s = SessionLibrary.settings(from: defaults, hookInstalled: false, home: home)
        XCTAssertFalse(s.tracksClaudeCode); XCTAssertFalse(s.watchesCodex)
        XCTAssertEqual(s.claudeFolder.path, home.appendingPathComponent(".claude/projects").path)
        XCTAssertTrue(SessionLibrary.settings(from: defaults, hookInstalled: true, home: home).tracksClaudeCode)
        defaults.set("~/Elsewhere/projects", forKey: SessionLibrary.Keys.claudeFolder)
        defaults.set(true, forKey: SessionLibrary.Keys.watchCodex)
        s = SessionLibrary.settings(from: defaults, hookInstalled: false, home: home)
        XCTAssertTrue(s.claudeFolder.path.hasSuffix("/Elsewhere/projects"))
        XCTAssertTrue(s.watchesCodex)
    }

    func testAge() {
        let now = Date()
        XCTAssertEqual(SessionLibrary.age(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(SessionLibrary.age(now.addingTimeInterval(-24 * 60), now: now), "24 min")
    }

    // MARK: The hook

    static let shapes: [String] = [
        "",
        "{}\n",
        "{\n  \"model\": \"opus\",\n  \"permissions\": {\"allow\": [\"Bash(ls:*)\"]}\n}\n",
        "{\n  \"hooks\": {\n    \"Stop\": [\n      {\"hooks\": [{\"type\": \"command\", \"command\": \"say done\"}]}\n    ]\n  }\n}\n",
        "{\n  \"hooks\": {\n    \"SessionStart\": [\n      {\"matcher\": \"startup\", \"hooks\": [{\"type\": \"command\", \"command\": \"echo hi\"}]}\n    ]\n  },\n  \"env\": {}\n}\n",
        "{\n\t\"hooks\": {\n\t\t\"SessionStart\": []\n\t}\n}",
    ]

    func testInstallThenRemoveRestoresTheFile() throws {
        for original in Self.shapes {
            let installed = try XCTUnwrap(ClaudeSessionHook.installing(into: original), original)
            XCTAssertTrue(ClaudeSessionHook.isInstalled(in: installed))
            XCTAssertEqual(installed.components(separatedBy: ClaudeSessionHook.marker).count - 1, 1, "one line added")
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(installed.utf8)) as? [String: Any])
            XCTAssertNil(try ClaudeSessionHook.installing(into: installed), "never added twice")
            let (restored, removed) = try XCTUnwrap(ClaudeSessionHook.removing(from: installed))
            XCTAssertTrue(removed.contains(ClaudeSessionHook.entry))
            XCTAssertFalse(ClaudeSessionHook.isInstalled(in: restored))
            switch original {
            case "": XCTAssertEqual(restored, "{}\n")
            // Lists and objects the removal empties go with it: exact for everything an install adds; an empty
            // `hooks` that was there before (it does nothing) goes too.
            case "{\n\t\"hooks\": {\n\t\t\"SessionStart\": []\n\t}\n}": XCTAssertEqual(restored, "{}")
            default: XCTAssertEqual(restored, original, "byte for byte")
            }
        }
    }

    func testInstallKeepsEverythingElseInPlace() throws {
        let original = Self.shapes[4]
        let installed = try XCTUnwrap(ClaudeSessionHook.installing(into: original))
        XCTAssertTrue(installed.hasPrefix("{\n  \"hooks\": {\n    \"SessionStart\": [\n      {\"matcher\": \"startup\", \"hooks\": [{\"type\": \"command\", \"command\": \"echo hi\"}]},\n      {\"hooks\""))
        XCTAssertTrue(installed.hasSuffix("  },\n  \"env\": {}\n}\n"))
        let obj = try JSONSerialization.jsonObject(with: Data(installed.utf8)) as! [String: Any]
        let starts = (obj["hooks"] as! [String: Any])["SessionStart"] as! [[String: Any]]
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(((starts[1]["hooks"] as! [[String: Any]])[0]["command"] as! String), ClaudeSessionHook.command)
        XCTAssertNil(starts[1]["matcher"])
    }

    func testRefusesFilesItDoesNotUnderstand() {
        XCTAssertThrowsError(try ClaudeSessionHook.installing(into: "[1, 2]"))
        XCTAssertThrowsError(try ClaudeSessionHook.installing(into: "{ not json"))
        XCTAssertThrowsError(try ClaudeSessionHook.installing(into: "{\"hooks\": [1]}"))
        XCTAssertThrowsError(try ClaudeSessionHook.installing(into: "{\"hooks\": {\"SessionStart\": {}}}"))
        XCTAssertNil(try? ClaudeSessionHook.removing(from: "{\"hooks\": {}}") ?? nil)
    }

    func testPlanApplyAndRemoveOnATemporaryFile() throws {
        let file = try put(".claude/settings.json", Self.shapes[2])
        let hook = ClaudeSessionHook(settingsFile: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertFalse(hook.isInstalled)
        let plan = try XCTUnwrap(try hook.planInstall())
        XCTAssertEqual(plan.change, ClaudeSessionHook.entry)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), Self.shapes[2], "planning writes nothing")
        try hook.apply(plan)
        XCTAssertTrue(hook.isInstalled)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNil(try hook.planInstall())
        let removal = try XCTUnwrap(try hook.planRemove())
        try hook.apply(removal)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), Self.shapes[2])
    }

    func testApplyRefusesAFileThatChangedAfterThePlan() throws {
        let file = try put(".claude/settings.json", "{}\n")
        let hook = ClaudeSessionHook(settingsFile: file)
        let plan = try XCTUnwrap(try hook.planInstall())
        try Data("{\"model\": \"x\"}\n".utf8).write(to: file)
        XCTAssertThrowsError(try hook.apply(plan)) { XCTAssertEqual($0 as? ClaudeSessionHook.Failure, .changedSinceShown) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{\"model\": \"x\"}\n")
    }

    func testNoSettingsFolderNoWrite() throws {
        let hook = ClaudeSessionHook(settingsFile: home.appendingPathComponent("absent/settings.json"))
        let plan = try XCTUnwrap(try hook.planInstall())
        XCTAssertThrowsError(try hook.apply(plan)) { XCTAssertEqual($0 as? ClaudeSessionHook.Failure, .noSettingsFolder) }
    }

    /// The command as Claude Code would run it, with HOME pointed at the temporary folder: it prints nothing (a
    /// SessionStart hook's output would enter the session's context) and appends the payload the menu reads.
    func testHookCommandPrintsNothingAndLogsThePayload() throws {
        let payload = SessionFixtures.line(["session_id": "s1", "transcript_path": "/tmp/x.jsonl", "cwd": "/tmp", "hook_event_name": "SessionStart", "source": "startup"])
        for _ in 0..<2 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", ClaudeSessionHook.command]
            p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let input = Pipe(), output = Pipe()
            p.standardInput = input; p.standardOutput = output; p.standardError = output
            try p.run()
            input.fileHandleForWriting.write(Data(payload.utf8))
            try input.fileHandleForWriting.close()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
            XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), Data())
        }
        XCTAssertEqual(ClaudeSessionHook.loggedTranscripts(log: SessionLibrary.hookLog(home: home)), ["/tmp/x.jsonl", "/tmp/x.jsonl"])
    }
}
