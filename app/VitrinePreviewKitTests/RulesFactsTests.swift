import XCTest
import WebKit
@testable import VitrinePreviewKit
import VitrineDocument

/// Rules and skills files in the Markdown preview (A-3, ai r3-b sections 5 and 7): the facts lead the strip, the
/// warnings and missing imports become badges, and the Agent view sits between Rendered and Source and swaps the
/// page's body in place. Invented files only. roadmap: S-21
@MainActor
final class RulesFactsTests: XCTestCase {
    private func folder(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-rules-\(UUID().uuidString)")
        for (path, text) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    private let claudeMD = """
    # Tidepool

    Order-management web app. TypeScript, Node 22, Postgres 16.

    See @docs/STYLE.md and @docs/DEPLOY.md before shipping.

    ## Commands

    ```bash
    # start the dev server
    $ npm run dev
    npm test
    npm test
    ```

    ```ts
    const notACommand = 1
    ```

    Read the [runbook](https://example.invalid/runbook) and [notes](notes.md).
    """

    private func context(_ dir: URL) -> RenderContext {
        RenderContext(appearance: .light, defaultsSuite: "vt-rules-suite", cachesDirectory: dir.appendingPathComponent("caches"))
    }

    func testClaudeMDGetsFactsBadgesAndAgentView() throws {
        let dir = try folder(["CLAUDE.md": claudeMD, "docs/STYLE.md": String(repeating: "x", count: 400)])
        let url = dir.appendingPathComponent("CLAUDE.md")
        let doc = try MarkdownRenderer.document(url: url, kind: .markdown(.commonMark), context: context(dir))

        XCTAssertEqual(doc.fact("kindName")?.value, "Claude Code memory (CLAUDE.md)")
        XCTAssertEqual(doc.fact("fires")?.value, "Always: loaded into every conversation in this folder.")
        XCTAssertNotNil(doc.fact("headline"))
        XCTAssertEqual(doc.fact("imports")?.value, "2 imports, 1 not found")
        // The found import's 400 bytes count as ≈ 100 tokens on top of the file's own estimate.
        let own = (claudeMD.utf8.count + 3) / 4
        XCTAssertEqual(doc.fact("loadedTokens")?.value, "≈ " + (own + 100).formatted())
        XCTAssertNotNil(doc.fact("contextShare"))
        XCTAssertNotNil(doc.fact("words"), "the Markdown facts stay")

        let missing = try XCTUnwrap(doc.badges.first { $0.title == "1 import not found" })
        XCTAssertEqual(missing.level, .caution)
        XCTAssertEqual(missing.detail, "@docs/DEPLOY.md")

        XCTAssertEqual(doc.viewTitles, ["Rendered", "Agent view", "Source"])
        let agent = try XCTUnwrap(MarkdownRenderer.agentView(in: doc)).html
        XCTAssertTrue(agent.contains("When it fires"))
        XCTAssertTrue(agent.contains("<code>@docs/DEPLOY.md</code>"))
        XCTAssertTrue(agent.contains("Not found"))
        XCTAssertTrue(agent.contains("Commands it tells the agent to run (2)"))
        XCTAssertTrue(agent.contains("npm run dev\nnpm test</code>"), "prompts and comments dropped, repeats merged, other languages ignored")
        XCTAssertFalse(agent.contains("notACommand"))
        XCTAssertTrue(agent.contains("Links (2)"))
        XCTAssertTrue(agent.contains("<li><code>https://example.invalid/runbook</code></li>"), "links listed as text")
        XCTAssertFalse(agent.contains("<a "), "nothing in the Agent view is a live link")
        // The rendered body is still the first view, untouched.
        guard case .markdown(let rendered) = doc.views[0] else { return XCTFail("rendered first") }
        XCTAssertTrue(rendered.html.contains("Tidepool"))
    }

    func testCursorRuleSaysWhenItFiresAndWarnsOnCommaGlobs() throws {
        let dir = try folder([".cursor/rules/deploy.mdc": """
        ---
        description: Deploy rules
        globs: infra/**, *.tf
        alwaysApply: false
        ---
        # Deploy rules

        Always run `terraform plan` before apply.
        """])
        let url = dir.appendingPathComponent(".cursor/rules/deploy.mdc")
        let doc = try MarkdownRenderer.document(url: url, kind: .markdown(.commonMark), context: context(dir))
        XCTAssertEqual(doc.fact("kindName")?.value, "Cursor rule (.mdc)")
        XCTAssertEqual(doc.fact("globs")?.value, "infra/**, *.tf")
        XCTAssertTrue(doc.fact("fires")?.value.contains("infra/**") == true)
        let agent = try XCTUnwrap(MarkdownRenderer.agentView(in: doc)).html
        XCTAssertTrue(agent.contains("Front matter"))
        XCTAssertTrue(agent.contains("alwaysApply"))
    }

    func testOrdinaryMarkdownIsUntouched() throws {
        let dir = try folder(["README.md": "# Hello\n\nSee @docs/x.md.\n"])
        let url = dir.appendingPathComponent("README.md")
        let doc = try MarkdownRenderer.document(url: url, kind: .markdown(.commonMark), context: context(dir))
        XCTAssertNil(doc.viewTitles)
        XCTAssertNil(doc.fact("fires"))
        XCTAssertEqual(doc.views.count, 2)
        XCTAssertNil(MarkdownRenderer.agentView(in: doc))
    }

    func testAgentViewSwapsTheBodyAndBack() async throws {
        let dir = try folder(["CLAUDE.md": claudeMD])
        let url = dir.appendingPathComponent("CLAUDE.md")
        let renderer = MarkdownRenderer()
        let preview = try await renderer.render(url: url, kind: .markdown(.commonMark), context: context(dir))
        let web = try XCTUnwrap(preview.view as? WKWebView)
        web.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let show = try XCTUnwrap(preview.showView, "a rules file offers the Agent view")
        func text() async throws -> String { try await web.evaluateJavaScript("document.querySelector('article').textContent") as? String ?? "" }

        let first = try await text()
        XCTAssertTrue(first.contains("Order-management"))
        XCTAssertTrue(show(1), "the renderer draws the Agent view itself")
        try await Task.sleep(for: .milliseconds(300))
        let agent = try await text()
        XCTAssertTrue(agent.contains("When it fires"))
        // A picture of the Agent view for review, in the temporary folder.
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        let image = try await web.takeSnapshot(configuration: nil)
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("vt-rules-agent-view.png")
            try png.write(to: out)
            print("agent view picture:", out.path)
        }
        XCTAssertFalse(show(2), "Source is the controller's")
        XCTAssertFalse(show(0), "Rendered is the renderer's own view")
        try await Task.sleep(for: .milliseconds(300))
        let back = try await text()
        XCTAssertTrue(back.contains("Order-management"))
        XCTAssertFalse(back.contains("When it fires"))
    }

    func testOrdinaryMarkdownHasNoViewHook() async throws {
        let dir = try folder(["README.md": "# Hello\n"])
        let preview = try await MarkdownRenderer().render(url: dir.appendingPathComponent("README.md"), kind: .markdown(.commonMark), context: context(dir))
        XCTAssertNil(preview.showView)
    }
}
