import WebKit
import XCTest
@testable import VitrinePreviewKit
import VitrineSupport

/// The code view (S-5, G-14): CodeMirror 6 + Shiki in a locked-down web view. All content is invented here.
/// roadmap: S-5
@MainActor
final class CodeRendererTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CodeRenderer.readyTimeout = .seconds(10)
    }

    override func tearDownWithError() throws {
        CodeRenderer.readyTimeout = .seconds(3)
        try? FileManager.default.removeItem(at: dir)
    }

    private let planner: String = (0..<40).map { n in
        """
        /// An invented orbit planner.
        struct OrbitPlan\(n): Codable {
            var stops: [Double] = [\(n).5, 2.25]
            func total(scale: Double = 1.0) -> Double {
                let kept = stops.filter { $0 >= 0 }
                return kept.reduce(0) { $0 + $1 * scale }
            }
        }

        """
    }.joined()

    private func render(_ name: String, _ text: String, _ language: String) async throws -> (CodeRenderer, RenderedPreview, WKWebView) {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let renderer = CodeRenderer()
        let preview = try await renderer.render(url: url, kind: .code(language: language), context: RenderContext(appearance: .light, defaultsSuite: "vt-code"))
        let web = try XCTUnwrap((preview.view as? CodeContainer)?.web, "the code view, not the plain-text fallback: \(renderer.pageErrors)")
        return (renderer, preview, web)
    }

    private func js(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.callAsyncJavaScript(script, contentWorld: .page)
    }

    func testRegistryPicksTheCodeViewForCodeButNotStructuredFiles() {
        XCTAssertTrue(RendererRegistry.renderer(for: .code(language: "swift")) is CodeRenderer)
        XCTAssertTrue(RendererRegistry.renderer(for: .code(language: "json")) is StructuredRenderer)
        XCTAssertTrue(RendererRegistry.renderer(for: .plainText) is PlainTextRenderer)
    }

    func testSwiftIsColouredByShikiInThePalette() async throws {
        let (renderer, preview, web) = try await render("OrbitPlanner.swift", planner, "swift")
        XCTAssertEqual(renderer.readyReport?.language, "swift")
        XCTAssertTrue(renderer.pageErrors.isEmpty, "\(renderer.pageErrors)")
        let spans = try await js(web, "return window.vitrine.colouredSpans();") as? Int ?? 0
        XCTAssertGreaterThan(spans, 50, "the visible lines carry Shiki colours")
        // `struct` is a keyword: it takes the syn-kw colour (#A23AC7 in light, which WebKit writes as rgb()).
        let keyword = try await js(web, """
            const s = Array.from(document.querySelectorAll('.cm-line span[style]')).find(e => e.textContent === 'struct');
            return s ? s.getAttribute('style') : null;
            """) as? String
        XCTAssertEqual(keyword?.contains("rgb(162, 58, 199)"), true, keyword ?? "no keyword span")
        XCTAssertEqual(preview.document.kind, .code(language: "swift"))
    }

    func testCapsuleFindCountsAndSteps() async throws {
        let (_, preview, _) = try await render("OrbitPlanner.swift", planner, "swift")
        let find = try XCTUnwrap(preview.find)
        let first = await find("OrbitPlan", true)
        XCTAssertEqual(first.count, 40)
        XCTAssertEqual(first.index, 0)
        let second = await find("OrbitPlan", true)
        XCTAssertEqual(second.index, 1)
        let back = await find("OrbitPlan", false)
        XCTAssertEqual(back.index, 0)
        let none = await find("nebula", true)
        XCTAssertEqual(none.count, 0)
    }

    func testStickyScopeLinesFollowTheTopLine() async throws {
        let (_, _, web) = try await render("OrbitPlanner.swift", planner, "swift")
        // Scroll so line 6 ("return kept.reduce…", inside func total inside struct OrbitPlan0) is the top line.
        let sticky = try await js(web, """
            const v = window.vitrine.view;
            const line = v.state.doc.line(6);
            v.scrollDOM.scrollTop = v.lineBlockAt(line.from).top;
            v.scrollDOM.dispatchEvent(new Event('scroll'));
            await new Promise(r => setTimeout(r, 50));
            return window.vitrine.stickyLines();
            """) as? [String]
        XCTAssertEqual(sticky, ["struct OrbitPlan0: Codable {", "    func total(scale: Double = 1.0) -> Double {"])
    }

    func testLineSelectionShowsInTheGutter() async throws {
        let (_, preview, web) = try await render("OrbitPlanner.swift", planner, "swift")
        _ = try await js(web, """
            const v = window.vitrine.view, d = v.state.doc;
            v.dispatch({ selection: { anchor: d.line(4).from, head: d.line(7).to } });
            await new Promise(r => setTimeout(r, 50));
            return true;
            """)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(preview.gutter?.trailing, "Ln 4–7 · 4 lines")
    }

    func testThePageIsLockedDown() async throws {
        let (_, _, web) = try await render("OrbitPlanner.swift", planner, "swift")
        let csp = try await js(web, "return document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]').content;") as? String
        XCTAssertEqual(csp?.hasPrefix("default-src 'none'"), true)
        // A fetch from the page is refused by the policy before any connection (port 9 on this Mac: nothing leaves).
        let outcome = try await js(web, """
            let violated = false;
            document.addEventListener('securitypolicyviolation', () => { violated = true; });
            try { await fetch('http://127.0.0.1:9/probe'); return 'fetched'; } catch (e) { await new Promise(r => setTimeout(r, 50)); return violated ? 'blocked by policy' : 'failed'; }
            """) as? String
        XCTAssertEqual(outcome, "blocked by policy")
    }

    func testAnUnknownLanguageStillOpensUncoloured() async throws {
        let (renderer, _, web) = try await render("notes.zzlang", "plain words\nmore words\n", "zzlang")
        XCTAssertNil(renderer.readyReport?.language)
        let lines = try await js(web, "return window.vitrine.view.state.doc.lines;") as? Int
        XCTAssertEqual(lines, 3)
    }

    // MARK: Hex (state 13)

    func testHexIsOneSwitchAwayAndTakesFindAndCopy() async throws {
        let (_, preview, _) = try await render("OrbitPlanner.swift", planner, "swift")
        XCTAssertEqual(preview.document.viewTitles, ["Code", "Hex"])
        let container = try XCTUnwrap(preview.view as? CodeContainer)
        XCTAssertNil(container.hex, "made only when asked for")
        XCTAssertEqual(preview.showView?(1), true)
        let hex = try XCTUnwrap(container.shownHex)
        XCTAssertTrue(container.web.isHidden)
        // "///" is 2F 2F 2F: find goes to the hex view while it shows.
        let find = try XCTUnwrap(preview.find)
        let found = await find("2F 2F 2F", true)
        XCTAssertEqual(found.count, 40)
        XCTAssertTrue(preview.copyFormats?().formats.contains { $0.title.localizedCaseInsensitiveContains("base64") } ?? false)
        XCTAssertEqual(preview.showView?(0), true)
        XCTAssertTrue(hex.isHidden)
        XCTAssertFalse(container.web.isHidden)
    }

    // MARK: Prefixes, symbols, fold to matches (state 1)

    func testColonGoesToALineAndAtFindsSymbols() async throws {
        let (_, preview, web) = try await render("OrbitPlanner.swift", planner, "swift")
        XCTAssertEqual(preview.findPrefixes, [.line, .symbol])
        let find = try XCTUnwrap(preview.find)
        let line = await find(":30", true)
        XCTAssertEqual(line.label, "Line 30")
        let at = try await js(web, "const v = window.vitrine.view; return v.state.doc.lineAt(v.state.selection.main.from).number;") as? Int
        XCTAssertEqual(at, 30)

        let symbols = await find("@OrbitPlan3", true)
        // OrbitPlan3 and OrbitPlan30…39: eleven types.
        XCTAssertEqual(symbols.count, 11)
        XCTAssertEqual(symbols.label, "1 of 11 symbols")
        let list = try await js(web, "return Array.from(document.querySelectorAll('#vt-syms .vt-sym')).map(r => r.textContent);") as? [String]
        XCTAssertEqual(list?.first, "COrbitPlan3Ln 26")
        let next = await find("@OrbitPlan3", true)
        XCTAssertEqual(next.label, "2 of 11 symbols")
        let methods = try await js(web, "return window.vitrine.symbolList().filter(s => s.kind === 'M').length;") as? Int
        XCTAssertEqual(methods, 40, "func total in each of the 40 structs")
        preview.clearFind?()
        try await Task.sleep(for: .milliseconds(50))
        let gone = try await js(web, "return document.querySelectorAll('#vt-syms').length;") as? Int
        XCTAssertEqual(gone, 0)
    }

    func testFoldToMatchesHidesTheLinesAwayFromEveryMatch() async throws {
        let (_, preview, web) = try await render("OrbitPlanner.swift", planner, "swift")
        XCTAssertNotNil(preview.foldToMatches)
        let find = try XCTUnwrap(preview.find)
        let result = await find("OrbitPlan39", true)
        XCTAssertEqual(result.count, 1)
        let folds = try await js(web, "return window.vitrine.foldToMatches(true);") as? Int
        // The match is on line 314 of 321; lines 312–316 stay, line 1 anchors the run before, line 316 the run after.
        XCTAssertEqual(folds, 2)
        let labels = try await js(web, "return Array.from(document.querySelectorAll('.vt-nomatch')).map(e => e.textContent);") as? [String]
        XCTAssertEqual(labels, ["310 lines without a match", "5 lines without a match"])
        _ = try await js(web, "return window.vitrine.foldToMatches(false);")
        let left = try await js(web, "return document.querySelectorAll('.vt-nomatch').length;") as? Int
        XCTAssertEqual(left, 0)
    }

    func testAPrefixBecomesABadgeInTheFindField() {
        let model = CapsuleModel()
        model.findPrefixes = [.line, .symbol]
        model.findQuery = "@flu"
        model.takePrefix()
        XCTAssertEqual(model.findPrefix, .symbol)
        XCTAssertEqual(model.findQuery, "flu")
        model.findQuery = ""
        XCTAssertTrue(model.dropPrefix())
        XCTAssertNil(model.findPrefix)
        model.findQuery = "level:warn"
        model.takePrefix()
        XCTAssertNil(model.findPrefix, "only the prefixes the preview offers")
    }

    // MARK: Copy a range (state 2)

    func testSelectedLinesCopyAsTextPromptAndImage() async throws {
        let (renderer, preview, web) = try await render("OrbitPlanner.swift", planner, "swift")
        _ = try await js(web, """
            const v = window.vitrine.view, d = v.state.doc;
            v.dispatch({ selection: { anchor: d.line(4).from, head: d.line(6).to } });
            await new Promise(r => setTimeout(r, 50));
            return true;
            """)
        try await Task.sleep(for: .milliseconds(100))
        let offer = try XCTUnwrap(preview.copyFormats?())
        XCTAssertEqual(offer.heading, "Lines 4–6")
        XCTAssertEqual(offer.formats[0].text(), """
                func total(scale: Double = 1.0) -> Double {
                    let kept = stops.filter { $0 >= 0 }
                    return kept.reduce(0) { $0 + $1 * scale }
            """)
        let prompt = offer.formats[1].text()
        XCTAssertTrue(offer.formats[1].title.hasPrefix("Copy as prompt, with path and line numbers · ≈ "))
        XCTAssertTrue(prompt.hasPrefix(renderer.fileURL!.path + ", lines 4–6:\n\n```swift\n4      func total"), prompt)
        XCTAssertTrue(prompt.hasSuffix("6          return kept.reduce(0) { $0 + $1 * scale }\n```\n"), prompt)
        XCTAssertEqual(offer.formats.last?.title, "Reveal in Finder")

        let board = NSPasteboard(name: NSPasteboard.Name("vt-code-test-\(UUID().uuidString)"))
        let image = try XCTUnwrap(offer.formats.first { $0.title == "Copy as image" }?.perform)
        let copied = await image(board)
        XCTAssertTrue(copied)
        XCTAssertNotNil(NSImage(pasteboard: board))
        board.releaseGlobally()
    }

    // MARK: Minified CSS and SQL (C-5, state 4)

    func testMinifiedSQLOpensFormattedWithTheOriginalOneClickAway() async throws {
        let sql = "select id, title from notes where deleted = 0 and title like 'Q4%' order by updated desc limit 20;" + String(repeating: " ", count: 150)
        let (renderer, preview, web) = try await render("recent-notes.sql", sql, "sql")
        let first = try await js(web, "return window.vitrine.view.state.doc.line(1).text;") as? String
        XCTAssertEqual(first, "SELECT id,")
        let note = try await js(web, "return document.querySelector('#vt-note .vt-note-text').textContent;") as? String
        XCTAssertEqual(note, "Formatted from 1 line for reading. The file on disk is untouched.")
        _ = try await js(web, "document.querySelector('#vt-note .vt-btn').click(); return true;")
        let lines = try await js(web, "return window.vitrine.view.state.doc.lines;") as? Int
        XCTAssertEqual(lines, 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(renderer.shownText.text, sql, "copy takes the file's own text while it shows")
        XCTAssertTrue(try String(contentsOf: try XCTUnwrap(renderer.fileURL), encoding: .utf8) == sql, "the file is untouched")
        withExtendedLifetime(preview) {}
    }

    // MARK: Config files (state 16)

    func testSecretsInADotEnvNeverReachThePage() async throws {
        let env = "# Harbor Notes local overrides\nAPP_ENV=development\nSTRIPE_SECRET_KEY=sk_test_00000000000000000000000000\n"
        let url = dir.appendingPathComponent(".env.local")
        try env.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileSniffer.kind(of: url), .code(language: "dotenv"))
        let renderer = CodeRenderer()
        let preview = try await renderer.render(url: url, kind: FileSniffer.kind(of: url), context: RenderContext(appearance: .light, defaultsSuite: "vt-code"))
        let web = try XCTUnwrap((preview.view as? CodeContainer)?.web)
        let page = try await js(web, "return window.vitrine.view.state.doc.toString();") as? String
        XCTAssertEqual(page?.contains("sk_test"), false)
        XCTAssertEqual(page?.contains("APP_ENV=development"), true)
        XCTAssertFalse(preview.document.searchText.contains("sk_test"), "copy takes the masked text")
        XCTAssertEqual(preview.document.fact("headline")?.value, "1 secret masked")
    }

    func testAnNfoIsReadAsDOSText() throws {
        let url = dir.appendingPathComponent("release.nfo")
        try Data([0xC9, 0xCD, 0xBB, 0x0A, 0xBA, 0x41, 0xBA, 0x0A]).write(to: url)
        let document = try PlainTextRenderer.textDocument(url: url, kind: FileSniffer.kind(of: url))
        XCTAssertEqual(PlainTextRenderer.shownText(document), "╔═╗\n║A║\n")
    }

    // MARK: Encoding and #! (state 3)

    func testALegacyEncodedScriptWithoutAnExtensionSaysHowItWasRead() async throws {
        let script = "#!/usr/bin/env bash\n# provision — sets up a fresh Harbor Notes dev box\n# Owner: Zoë Martín – platform team\nset -euo pipefail\n"
        let url = dir.appendingPathComponent("provision")
        try XCTUnwrap(script.data(using: .windowsCP1252)).write(to: url)
        let renderer = CodeRenderer()
        let preview = try await renderer.render(url: url, kind: FileSniffer.kind(of: url),
                                                context: RenderContext(appearance: .light, defaultsSuite: "vt-code"))
        let web = try XCTUnwrap((preview.view as? CodeContainer)?.web)
        XCTAssertEqual(preview.document.kind, .code(language: "shell"))
        XCTAssertEqual(preview.document.fact("encoding")?.value, "Windows-1252")
        let note = try await js(web, "return document.querySelector('#vt-note .vt-note-text').textContent;") as? String
        XCTAssertEqual(note, "Read as Windows-1252, detected. “—”, “ë”, “í”, “–” are intact. Language from the #! line: Shell script.")
        let line3 = try await js(web, "return window.vitrine.view.state.doc.line(3).text;") as? String
        XCTAssertEqual(line3, "# Owner: Zoë Martín – platform team")

        // Reopen as Mac OS Roman: the text changes in place and the pill follows.
        await renderer.reopen(as: .macOSRoman)
        let reread = try await js(web, "return window.vitrine.view.state.doc.line(3).text;") as? String
        XCTAssertNotEqual(reread, "# Owner: Zoë Martín – platform team")
        XCTAssertEqual(preview.document.fact("encoding")?.value, "Mac OS Roman")
    }

    func testUTF8CodeHasNoNotice() async throws {
        let (_, preview, web) = try await render("OrbitPlanner.swift", planner, "swift")
        XCTAssertEqual(preview.document.fact("encoding")?.value, "UTF-8")
        let shown = try await js(web, "return getComputedStyle(document.getElementById('vt-note')).display;") as? String
        XCTAssertEqual(shown, "none")
    }

    // MARK: Huge files (state 14)

    private func renderHuge(lines: Int) async throws -> (CodeRenderer, RenderedPreview, WKWebView) {
        CodeRenderer.windowThreshold = 64 * 1024
        CodeRenderer.windowLines = 400
        addTeardownBlock { @MainActor in
            CodeRenderer.windowThreshold = PlainTextRenderer.streamingThreshold
            CodeRenderer.windowLines = 4_096
        }
        var s = "INSERT INTO notes (id, title) VALUES\n"
        for n in 2...lines { s += n % 5_000 == 0 ? "  (\(n), 'Trip to Lisbon'),\n" : "  (\(n), 'note \(n)'),\n" }
        return try await render("notes-dump.sql", s, "sql")
    }

    private func until(_ what: String, _ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<200 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        XCTFail("timed out waiting for \(what)")
    }

    func testAHugeFileOpensAWindowWithTheFilesLineNumbers() async throws {
        let (_, preview, web) = try await renderHuge(lines: 60_000)
        let w = try await js(web, "return window.vitrine.window();") as? [String: Any]
        XCTAssertEqual(w?["first"] as? Int, 1)
        XCTAssertEqual(w?["lines"] as? Int, 400, "one window, never the whole file")
        if case .partial(_, let total, .bytes, _)? = Optional(preview.document.coverage) {
            XCTAssertNotNil(total)
        } else { XCTFail("coverage says what is shown") }
        // The count finishes in the background; the gutter then names the window.
        try await until("the line count") { preview.gutter?.leading == "Lines 1–400 of 60,000" }

        // A jump far down loads the window around the line, numbered as in the file.
        _ = try await js(web, "window.vitrine.goToLine(41234); return true;")
        try await until("the window at 41,234") {
            let w = try await self.js(web, "return window.vitrine.window();") as? [String: Any]
            return (w?["first"] as? Int) == 41_034 && (w?["pending"] as? Bool) == false
        }
        let gutterNumber = try await js(web, """
            const el = Array.from(document.querySelectorAll('.cm-lineNumbers .cm-gutterElement')).find(e => e.textContent === '41,234');
            return el ? el.textContent : null;
            """) as? String
        XCTAssertEqual(gutterNumber, "41,234")
        let selected = try await js(web, "const v = window.vitrine.view; return v.state.doc.lineAt(v.state.selection.main.from).text;") as? String
        XCTAssertEqual(selected, "  (41234, 'note 41234'),")
        XCTAssertEqual(preview.gutter?.leading, "Lines 41,034–41,433 of 60,000")
    }

    func testFindInAHugeFileStreamsAndStepsThroughWindows() async throws {
        let (_, preview, web) = try await renderHuge(lines: 60_000)
        var streamed: [FindResult] = []
        preview.findResultChanged = { streamed.append($0) }
        let find = try XCTUnwrap(preview.find)
        let first = await find("lisbon", true)
        XCTAssertTrue(first.inProgress, "the count starts while the file is read")
        try await until("the search to finish") { streamed.last.map { !$0.inProgress } ?? false }
        XCTAssertEqual(streamed.last, FindResult(count: 12, index: 0, searchedAll: true, inProgress: false))
        // The first match (line 5,000) was revealed in its window.
        try await until("the first match") {
            let t = try await self.js(web, "const v = window.vitrine.view; return v.state.sliceDoc(v.state.selection.main.from, v.state.selection.main.to);") as? String
            return t == "Lisbon"
        }
        let next = await find("lisbon", true)
        XCTAssertEqual(next, FindResult(count: 12, index: 1))
        try await until("the second match's window") {
            let w = try await self.js(web, "return window.vitrine.window();") as? [String: Any]
            let line = try await self.js(web, "const v = window.vitrine.view; return v.state.doc.lineAt(v.state.selection.main.from).text;") as? String
            return (w?["first"] as? Int).map { $0 <= 10_000 && 10_000 < $0 + 400 } == true && line == "  (10000, 'Trip to Lisbon'),"
        }
    }

    func testAPageThatNeverStartsFallsBackToPlainText() async throws {
        CodeRenderer.readyTimeout = .zero
        let url = dir.appendingPathComponent("OrbitPlanner.swift")
        try planner.write(to: url, atomically: true, encoding: .utf8)
        let preview = try await CodeRenderer().render(url: url, kind: .code(language: "swift"), context: RenderContext(appearance: .light, defaultsSuite: "vt-code"))
        XCTAssertFalse(preview.view is CodeContainer, "the native text view, never a blank page")
    }
}
