import WebKit
import XCTest
@testable import VitrinePreviewKit
import VitrineSupport

/// The session preview (S-11; ai.html states 1, 3, 4): the conversation page, the viewer switch, find run from
/// outside a page that allows no script, Changes through the diff page, and every other JSON Lines file left to
/// the renderer it had. Every transcript is invented. roadmap: S-11
@MainActor
final class SessionRendererTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionRenderer.readyTimeout = .seconds(10)
        DiffRenderer.readyTimeout = .seconds(10)
    }

    override func tearDownWithError() throws {
        SessionRenderer.readyTimeout = .seconds(3)
        DiffRenderer.readyTimeout = .seconds(3)
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    var context: RenderContext { RenderContext(appearance: .light, defaultsSuite: nil) }

    func testRegistrySendsJSONLinesHereAndNothingElse() {
        XCTAssertTrue(RendererRegistry.renderer(for: .code(language: "jsonl")) is SessionRenderer)
        // Every other kind goes where it went before this family.
        XCTAssertTrue(RendererRegistry.renderer(for: .code(language: "json")) is StructuredRenderer)
        XCTAssertTrue(RendererRegistry.renderer(for: .plainText) is PlainTextRenderer)
        XCTAssertTrue(RendererRegistry.renderer(for: .code(language: "swift")) is CodeRenderer)
        XCTAssertFalse(SessionRenderer.canRender(.plainText))
        XCTAssertFalse(SessionRenderer.canRender(.code(language: "json")))
        XCTAssertFalse(SessionRenderer.canRender(.code(language: "swift")))
        XCTAssertFalse(SessionRenderer.canRender(.markdown(.commonMark)))
    }

    func testConversationPreview() async throws {
        let url = try write("3f9c2a71.jsonl", SessionFixtures.claudeCode())
        let renderer = SessionRenderer()
        let preview = try await renderer.render(url: url, kind: .plainText, context: context)
        XCTAssertEqual(preview.document.kind, .code(language: "claude-code-session"))
        XCTAssertEqual(preview.document.viewTitles, ["Conversation", "Changes", "Source"])
        XCTAssertEqual(preview.document.fact("changes")?.value, "3 files · +11 −2")
        XCTAssertEqual(preview.document.badges.map(\.level), [.danger, .caution])
        if case .code(let source, _) = preview.document.views[2] { XCTAssertTrue(source.contains("\"summary\"")) } else { XCTFail("Source is the file") }

        let web = try XCTUnwrap(renderer.conversation)
        let html = try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
        XCTAssertTrue(html.contains("Fix flaky export test and add a CSV header option"))
        XCTAssertTrue(html.contains("Subagent · Explore"))
        XCTAssertTrue(html.contains("errrow"), "the failed Bash call sits on the danger inset")
        XCTAssertTrue(html.contains("1 secret in this session"))
        XCTAssertTrue(html.contains("x-telemetry ×1"))
        XCTAssertFalse(html.contains("abcdefghijklmnop"), "a masked secret never reaches the page")
        XCTAssertFalse(html.contains("<script"), "the page carries no script")

        // Find runs from outside the page (its CSP allows no script) and opens the folded row it lands in.
        let found = await renderer.find("runs failed", forward: true)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.index, 0)
        let open = try await web.evaluateJavaScript("document.querySelector('mark.vt-find.cur').closest('details').open") as? Bool
        XCTAssertEqual(open, true)
        renderer.clearFind()
        try await Task.sleep(for: .milliseconds(200))
        let marks = try await web.evaluateJavaScript("document.querySelectorAll('mark.vt-find').length") as? Int
        XCTAssertEqual(marks, 0)
    }

    func testChangesViewIsTheDiffPage() async throws {
        let url = try write("s.jsonl", SessionFixtures.claudeCode())
        let renderer = SessionRenderer()
        let preview = try await renderer.render(url: url, kind: .plainText, context: context)
        XCTAssertEqual(preview.showView?(1), true)
        await renderer.changesReady()
        let changes = try XCTUnwrap(renderer.changes)
        XCTAssertEqual(changes.document.kind, .diff)
        XCTAssertFalse(changes.view.isHidden)
        XCTAssertTrue(renderer.conversation?.isHidden ?? false)
        let found = await preview.find?("includeHeader", true)
        XCTAssertGreaterThan(found?.count ?? 0, 0, "find follows the view that is shown")
        XCTAssertEqual(preview.showView?(2), false, "Source is the host's text view")
        XCTAssertEqual(preview.showView?(0), true)
        XCTAssertFalse(renderer.conversation?.isHidden ?? true)
    }

    func testCodexPreview() async throws {
        let url = try write("rollout-2026-10-28T09-00-00-0199.jsonl", SessionFixtures.codex())
        let preview = try await SessionRenderer().render(url: url, kind: .plainText, context: context)
        XCTAssertEqual(preview.document.kind, .code(language: "codex-session"))
        XCTAssertEqual(preview.document.viewTitles, ["Conversation", "Changes", "Source"])
    }

    func testOtherFilesGoWhereTheyWent() async throws {
        let jsonl = try write("events.jsonl", SessionFixtures.plainJSONL)
        let a = try await SessionRenderer().render(url: jsonl, kind: .plainText, context: context)
        XCTAssertEqual(a.document.kind, .plainText)
        let text = try write("notes.txt", SessionFixtures.claudeCode())
        let b = try await SessionRenderer().render(url: text, kind: .plainText, context: context)
        XCTAssertEqual(b.document.kind, .plainText, "only .jsonl and .ndjson are read as sessions")
        let json = try write("a.json", "{\"a\": 1}")
        let c = try await SessionRenderer().render(url: json, kind: .code(language: "json"), context: context)
        XCTAssertEqual(c.document.kind, .code(language: "json"))
        // A JSON Lines file that is not a session, sent here by kind, goes on to the structured tree.
        let d = try await SessionRenderer().render(url: jsonl, kind: .code(language: "jsonl"), context: context)
        XCTAssertEqual(d.document.kind, .code(language: "json"))
        XCTAssertEqual(d.document.viewTitles?.first, "Tree")
    }

    func testNoChangesMeansNoChangesView() async throws {
        let url = try write("q.jsonl", SessionFixtures.jsonl([SessionFixtures.cc("user", "10:00:00", ["role": "user", "content": "What does this do?"]),
                                                             SessionFixtures.assistant("m1", "10:00:05", [["type": "text", "text": "It exports orders."]])]))
        let preview = try await SessionRenderer().render(url: url, kind: .plainText, context: context)
        XCTAssertEqual(preview.document.viewTitles, ["Conversation", "Source"])
        XCTAssertEqual(preview.showView?(1), false)
    }

    /// For pictures of the Changes view: with `TEST_RUNNER_VT_SESSION_SAMPLE=<invented transcript>` set, writes the
    /// patch the Changes view draws beside it (`<name>.changes.patch`), for `Vitrine --snapshot`. Skipped otherwise.
    func testWritesTheChangesPatchOfASampleWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["VT_SESSION_SAMPLE"] else { throw XCTSkip("no sample named") }
        let url = URL(fileURLWithPath: path)
        let session = try XCTUnwrap(SessionParser.parse(url: url))
        let out = url.deletingPathExtension().appendingPathExtension("changes.patch")
        try Data(SessionChanges.patch(session, mail: true).utf8).write(to: out)
    }
}
