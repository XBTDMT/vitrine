import XCTest
@testable import VitrinePreviewKit

/// The Claude app's connector entry (X-9, G-22), edited as text in a temporary file: never the real settings.
/// roadmap: S-11
final class ClaudeAppConnectorTests: XCTestCase {
    let command = "/Applications/Vitrine.app/Contents/Helpers/vitrine"

    func connector(_ text: String?) throws -> ClaudeAppConnector {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("claude_desktop_config.json")
        if let text { try Data(text.utf8).write(to: file) }
        return ClaudeAppConnector(command: command, configFile: file)
    }

    func testAnEmptyOrMissingFileGetsTheOneEntry() throws {
        let c = try connector(nil)
        let plan = try XCTUnwrap(try c.planConnect())
        XCTAssertFalse(plan.exists)
        XCTAssertEqual(ClaudeAppConnector.registeredCommand(in: plan.updated), command)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(plan.updated.utf8)) as? [String: Any])
        let entry = try XCTUnwrap((root["mcpServers"] as? [String: Any])?["vitrine"] as? [String: Any])
        XCTAssertEqual(entry["args"] as? [String], ["mcp"])
        try c.apply(plan)
        XCTAssertEqual(c.registeredCommand, command)
        XCTAssertNil(try c.planConnect(), "connecting twice changes nothing")
    }

    func testOtherServersAndSettingsKeepTheirExactText() throws {
        let original = """
        {
          "mcpServers": {
            "notes": {
              "command": "/usr/local/bin/notes-mcp",
              "args": ["--read-only"]
            }
          },
          "preferences": { "quickEntryShortcut": "off", "ratio": 1.0 }
        }

        """
        let c = try connector(original)
        let plan = try XCTUnwrap(try c.planConnect())
        XCTAssertTrue(plan.updated.contains(#""args": ["--read-only"]"#))
        XCTAssertTrue(plan.updated.contains(#""ratio": 1.0"#), "numbers are not rewritten")
        XCTAssertEqual(ClaudeAppConnector.registeredCommand(in: plan.updated), command)
        let (back, removed) = try XCTUnwrap(try ClaudeAppConnector.disconnecting(plan.updated))
        XCTAssertEqual(back, original, "disconnecting takes out exactly what connecting put in")
        XCTAssertTrue(removed.contains("\"vitrine\""))
    }

    func testAMovedCopyIsReplaced() throws {
        let c = try connector(#"{"mcpServers": {"vitrine": {"command": "/Users/x/Downloads/Vitrine.app/Contents/Helpers/vitrine", "args": ["mcp"]}}}"#)
        let plan = try XCTUnwrap(try c.planConnect())
        XCTAssertEqual(ClaudeAppConnector.registeredCommand(in: plan.updated), command)
        XCTAssertFalse(plan.updated.contains("Downloads"))
    }

    func testDisconnectingTheOnlyServerLeavesTheRestAndNoEmptyList() throws {
        let c = try connector("{\n  \"globalShortcut\": \"\",\n  \"mcpServers\": {\n    \(ClaudeAppConnector(command: command).entry)\n  }\n}\n")
        let plan = try XCTUnwrap(try c.planDisconnect())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(plan.updated.utf8)) as? [String: Any])
        XCTAssertNil(root["mcpServers"])
        XCTAssertEqual(root["globalShortcut"] as? String, "")
        XCTAssertNil(try connector("{}").planDisconnect(), "nothing to take out")
    }

    func testAFileThatChangedAfterThePlanIsLeftAlone() throws {
        let c = try connector("{}")
        let plan = try XCTUnwrap(try c.planConnect())
        try Data(#"{"other": true}"#.utf8).write(to: c.configFile)
        XCTAssertThrowsError(try c.apply(plan)) { XCTAssertEqual($0 as? ClaudeAppConnector.Failure, .changedSinceShown) }
        XCTAssertEqual(c.read().text, #"{"other": true}"#)
    }

    func testAFileThatIsNotAnObjectIsRefused() throws {
        XCTAssertThrowsError(try connector("[1, 2]").planConnect()) { XCTAssertEqual($0 as? ClaudeAppConnector.Failure, .notJSONObject) }
        XCTAssertThrowsError(try connector(#"{"mcpServers": []}"#).planConnect()) { XCTAssertEqual($0 as? ClaudeAppConnector.Failure, .unexpectedShape) }
    }
}
