import XCTest
import WebKit
@testable import VitrinePreviewKit
import VitrineDocument

/// The picked Markdown design (r3-a Clear Sidebar) as the page actually draws it: the column with contents and
/// facts, the active heading, code cards with their language, remote images as chips, alerts, task boxes.
@MainActor
final class MarkdownPageTests: XCTestCase {
    private func page(_ markdown: String, files: [String] = []) async throws -> WKWebView {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files { try "x".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }
        let url = dir.appendingPathComponent("README.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        let preview = try await MarkdownRenderer().render(url: url, kind: .markdown(.commonMark),
            context: RenderContext(appearance: .light, defaultsSuite: "vt-page-suite",
                                   cachesDirectory: dir.appendingPathComponent("caches")))
        let web = try XCTUnwrap(preview.view as? WKWebView)
        web.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        try await Task.sleep(for: .milliseconds(250))
        return web
    }

    private func js<T>(_ web: WKWebView, _ script: String) async throws -> T? {
        try await web.evaluateJavaScript(script) as? T
    }

    func testColumnCarriesContentsAndFacts() async throws {
        let web = try await page("""
        # Tidepool

        ![build](https://ci.example.com/build.svg)

        See [ok](here.md) and [gone](gone.md).

        ## Install

        ```shell
        brew install tidepool
        ```

        ## Use

        - [x] done
        - [ ] open
        """, files: ["here.md"])
        let toc: [String]? = try await js(web, "Array.from(document.querySelectorAll('.sa-side .toc li')).map(l => l.className)")
        XCTAssertEqual(toc, ["l1 on", "l2", "l2"], "the first heading is active at the top")
        let facts: [String]? = try await js(web, "Array.from(document.querySelectorAll('.sa-foot > .sa-f > span')).map(s => s.textContent)")
        XCTAssertEqual(facts?.count, 4, facts?.description ?? "nil")
        XCTAssertEqual(facts?[2], "1 image · 1 remote")
        XCTAssertEqual(facts?[3], "2 links · 1 missing")
        // The token count is the context-fit meter under the facts (A-4): the count, two windows, the method.
        let meterRows: Int? = try await js(web, "document.querySelectorAll('.sa-foot .sa-tok .sa-m').length")
        XCTAssertEqual(meterRows, 2)
        let head: String? = try await js(web, "document.querySelector('.sa-tok .sa-th span').textContent")
        XCTAssertTrue(head?.hasSuffix("Claude tokens, estimate") == true, head ?? "nil")
        let missing: String? = try await js(web, "document.querySelector('.sa-f .sa-w').textContent")
        XCTAssertEqual(missing, "1 missing", "the missing link is called out")
        let chip: String? = try await js(web, "document.querySelector('.rghost').textContent")
        XCTAssertEqual(chip, "buildci.example.com", "the remote image is a chip, never loaded")
        let imgs: Int? = try await js(web, "document.querySelectorAll('article img').length")
        XCTAssertEqual(imgs, 0)
        let lang: String? = try await js(web, "document.querySelector('.cb.has-lang .lang').textContent")
        XCTAssertEqual(lang, "shell")
        let boxes: Int? = try await js(web, "document.querySelectorAll('article input[type=checkbox]:checked').length")
        XCTAssertEqual(boxes, 1)
    }

    /// The shared ruler (B-7, C-8): the page's scrollbar marks every find match, the current one stronger.
    func testTheRulerMarksFindMatches() async throws {
        let body = (1...40).map { "Paragraph \($0) about the tide." + ($0 % 10 == 0 ? " Lisbon harbour." : "") }.joined(separator: "\n\n")
        let web = try await page("# Tides\n\n" + body)
        let count: Int? = try await js(web, "window.vitrine.find('Lisbon', true).count")
        XCTAssertEqual(count, 4)
        let marks: [String] = try await js(web, "window.vitrine.rulerMarks()") ?? []
        XCTAssertEqual(marks.filter { $0 == "fc" }.count, 1)
        XCTAssertEqual(marks.filter { $0 == "f" }.count, 3)
        _ = try await web.evaluateJavaScript("window.vitrine.clearFind()")
        let cleared: [String] = try await js(web, "window.vitrine.rulerMarks()") ?? ["x"]
        XCTAssertEqual(cleared, [])
        let rulers: Int? = try await js(web, "document.querySelectorAll('.vt-ruler').length")
        XCTAssertEqual(rulers, 1)
    }

    /// Diagrams (H-1): fixed to dark, a light page's diagrams take the theme's dark colours and their own cache key.
    func testTheDiagramsSettingFixesTheirColours() throws {
        let suite = "vt-diagrams-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let light = RenderContext(appearance: .light, defaultsSuite: suite)
        XCTAssertEqual(MarkdownRenderer.diagramAppearance(light), .light, "follows the page by default")
        d.set("dark", forKey: MarkdownRenderer.Keys.diagramTheme)
        XCTAssertEqual(MarkdownRenderer.diagramAppearance(light), .dark)
        let theme = MarkdownRenderer.theme(light)
        let page = MarkdownRenderer.buildPage(for: PreviewDocument(kind: .markdown(.commonMark), facts: [], views: [.markdown(MarkdownContent(html: "<p>x</p>", headings: []))]), context: light)
        XCTAssertTrue(page.contains("--dg-bg: \(theme.spec.colors(for: .dark).bg)"), "the dark colours")
        XCTAssertTrue(page.contains("--bg: \(theme.spec.colors(for: .light).bg)"), "the page stays light")
    }

    /// I-2: every code card has a Copy button that says Copied for a moment. The click is not sent to the clipboard here
    /// (the renderer is gone and the test must not overwrite the person's clipboard); the label and state are checked.
    func testCodeCardsHaveACopyButton() async throws {
        let web = try await page("# Setup\n\n```sh\nbrew install tidepool\n```\n\n```\nplain block\n```\n")
        let count: Int? = try await js(web, "document.querySelectorAll('.cb .copy').length")
        XCTAssertEqual(count, 2, "a card with and without a language each get one")
        let label: String? = try await js(web, "document.querySelector('.cb .copy span').textContent")
        XCTAssertEqual(label, "Copy")
        let hidden: String? = try await js(web, "getComputedStyle(document.querySelector('.cb .copy')).display")
        XCTAssertEqual(hidden, "none", "hidden until the pointer is over the card")
        let after: String? = try await js(web, "var b = document.querySelector('.cb .copy'); b.click(); b.className + '|' + b.textContent")
        XCTAssertEqual(after, "copy on|Copied")
    }

    func testShortNoteHasNoColumn() async throws {
        let web = try await page("# Note\n\nJust a line.\n")
        let side: Int? = try await js(web, "document.querySelectorAll('.sa-side').length")
        XCTAssertEqual(side, 0, "the column steps aside on short notes")
    }

    func testAlertsTakeTheirKindsColours() async throws {
        let web = try await page("> [!WARNING]\n> Mind the gap.\n")
        let colour: String? = try await js(web, "getComputedStyle(document.querySelector('.alert-warning .alert-title')).color")
        XCTAssertEqual(colour, "rgb(158, 84, 0)", "Warning uses --v-caution-text #9E5400")
    }

    func testAaChangesThemeAndTextSizeAndRemembersThem() async throws {
        let suite = "vt-aa-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.md")
        try "# A\n\n## B\n\n## C\n\nText.\n".write(to: url, atomically: true, encoding: .utf8)
        let renderer = MarkdownRenderer()
        let preview = try await renderer.render(url: url, kind: .markdown(.commonMark),
            context: RenderContext(appearance: .light, defaultsSuite: suite, cachesDirectory: dir.appendingPathComponent("c")))
        let web = try XCTUnwrap(preview.view as? WKWebView)
        web.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        try await Task.sleep(for: .milliseconds(250))

        let tiles: Int? = try await js(web, "document.getElementById('vt-aa').click(); document.querySelectorAll('.aa-pop .tt').length")
        XCTAssertEqual(tiles, 15, "every theme of the Collection")
        let current: String? = try await js(web, "document.querySelector('.aa-pop .tt.on span').textContent")
        XCTAssertEqual(current, "Vitrine")

        _ = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.aa-pop .tt')).find(t => t.title === 'Paper').click(); true")
        let defaults = VitrineDefaults.defaults(suite: suite)
        for _ in 0..<40 where defaults.string(forKey: MarkdownRenderer.Keys.theme) != "paper" { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(defaults.string(forKey: MarkdownRenderer.Keys.theme), "paper", "the choice is saved")
        try await Task.sleep(for: .milliseconds(400))
        let bg: String? = try await js(web, "getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()")
        XCTAssertEqual(bg?.uppercased(), MarkdownTheme.theme(id: "paper").spec.light.bg, "the page redrew in Paper")

        _ = try await web.evaluateJavaScript("window.webkit.messageHandlers.vitrine.postMessage({name: 'textScale', body: 1}); true")
        for _ in 0..<40 where defaults.object(forKey: MarkdownRenderer.Keys.textScale) == nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(defaults.double(forKey: MarkdownRenderer.Keys.textScale), 1.1, accuracy: 0.001)
        try await Task.sleep(for: .milliseconds(400))
        let fs: String? = try await js(web, "getComputedStyle(document.documentElement).getPropertyValue('--fs').trim()")
        XCTAssertEqual(fs, "15.95px", "Paper's 14.5 px at 110 %")
        _ = try await web.evaluateJavaScript("window.webkit.messageHandlers.vitrine.postMessage({name: 'textScale', body: 0}); true")
        for _ in 0..<40 where defaults.double(forKey: MarkdownRenderer.Keys.textScale) != 1 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(defaults.double(forKey: MarkdownRenderer.Keys.textScale), 1, "⌘0 resets")
        defaults.removePersistentDomain(forName: suite)
    }

    func testTextScaleSnapsToASteps() {
        XCTAssertEqual(MarkdownTheme.textScale(nil), 1)
        XCTAssertEqual(MarkdownTheme.textScale(1.13), 1.1)
        XCTAssertEqual(MarkdownTheme.textScale(9), 1.5)
    }
}
