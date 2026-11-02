import AppKit
import WebKit
import XCTest
@testable import VitrinePreviewKit
import VitrineCompare
import VitrineSupport
import VitrineUI

/// The notebook preview (A-8, parity B-3; design/mockups/unified/ai.html state 11): the header card, the out-of-order
/// inset, Markdown, code coloured by Shiki, outputs (text, tables, an image, an error), the viewer switch, find, and
/// outputs that never run. Every notebook here is invented in the test. roadmap: S-21
@MainActor
final class NotebookRendererTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-nb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NotebookRenderer.readyTimeout = .seconds(10)
    }

    override func tearDownWithError() throws {
        NotebookRenderer.readyTimeout = .seconds(3)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Invented notebooks

    static func markdown(_ text: String, attachments: [String: Any]? = nil) -> [String: Any] {
        var c: [String: Any] = ["cell_type": "markdown", "metadata": [:], "source": text]
        if let attachments { c["attachments"] = attachments }
        return c
    }

    static func code(_ source: String, count: Int?, outputs: [[String: Any]] = [], ran: (String, String)? = nil) -> [String: Any] {
        var meta: [String: Any] = [:]
        if let ran { meta["execution"] = ["iopub.execute_input": ran.0, "shell.execute_reply": ran.1] }
        return ["cell_type": "code", "metadata": meta, "source": source, "execution_count": count.map { $0 as Any } ?? NSNull(), "outputs": outputs]
    }

    static func result(_ data: [String: Any], count: Int? = nil) -> [String: Any] {
        ["output_type": count == nil ? "display_data" : "execute_result", "data": data, "metadata": [:],
         "execution_count": count.map { $0 as Any } ?? NSNull()]
    }

    static func notebook(_ cells: [[String: Any]], language: String = "python", version: String = "3.12.4") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "nbformat": 4, "nbformat_minor": 5,
            "metadata": ["kernelspec": ["name": "python3", "display_name": "Python 3 (ipykernel)", "language": language],
                         "language_info": ["name": language, "version": version]],
            "cells": cells,
        ], options: [.sortedKeys])
    }

    /// A small bar chart drawn here, as matplotlib would save one.
    static func chartPNG() -> String {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 120, height: 60).fill()
        NSColor.systemBlue.setFill()
        for (i, h) in [36, 22, 50, 31].enumerated() { NSRect(x: 8 + i * 28, y: 4, width: 20, height: h).fill() }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!.base64EncodedString()
    }

    /// The design's notebook: a title cell, the churn table, the chart that ran after the cell below it, and the
    /// misspelt column's KeyError with IPython's coloured traceback.
    static func churnNotebook() throws -> Data {
        let table = """
        <div><style scoped>.dataframe tbody tr th { vertical-align: top; }</style>
        <table border="1" class="dataframe"><thead><tr style="text-align: right;"><th>region</th><th>churn %</th></tr></thead>
        <tbody><tr><td>North</td><td>18.2</td></tr><tr><td>South</td><td>11.4</td></tr><tr><td>East</td><td>24.9</td></tr><tr><td>West</td><td>15.7</td></tr></tbody></table></div>
        """
        let traceback = [
            "\u{1B}[0;31m---------------------------------------------------------------------------\u{1B}[0m",
            "\u{1B}[0;31mKeyError\u{1B}[0m                                  Traceback (most recent call last)",
            "Cell \u{1B}[0;32mIn[4], line 1\u{1B}[0m\n\u{1B}[0;32m----> 1\u{1B}[0m df\u{1B}[38;5;241m.\u{1B}[39mgroupby(\u{1B}[38;5;124m\"\u{1B}[39m\u{1B}[38;5;124mregoin\u{1B}[39m\u{1B}[38;5;124m\"\u{1B}[39m)",
            "\u{1B}[0;31mKeyError\u{1B}[0m: 'regoin'",
        ]
        return try notebook([
            markdown("# Churn by region, Q3\n\nMonthly churn per sales region. Data from `orders.parquet`, invented sample."),
            code("df = load(\"orders.parquet\")\nchurn = df.groupby(\"region\").churned.mean() * 100\nchurn.round(1)", count: 3,
                 outputs: [result(["text/html": table, "text/plain": "region  churn %\nNorth  18.2"], count: 3)],
                 ran: ("2026-10-12T14:05:09.100Z", "2026-10-12T14:05:09.500Z")),
            code("churn.plot.bar(title=\"Churn %\")", count: 7,
                 outputs: [result(["image/png": chartPNG(), "text/plain": "<Figure size 640x480 with 1 Axes>"])],
                 ran: ("2026-10-12T14:19:00.000Z", "2026-10-12T14:19:00.200Z")),
            code("df.groupby(\"regoin\").size()", count: 4,
                 outputs: [["output_type": "error", "ename": "KeyError", "evalue": "'regoin'", "traceback": traceback]]),
        ])
    }

    private func write(_ data: Data, _ name: String = "churn-analysis.ipynb") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func render(_ url: URL, appearance: DesignTokens.Appearance = .light) async throws -> (NotebookRenderer, RenderedPreview, WKWebView) {
        let renderer = NotebookRenderer()
        let preview = try await renderer.render(url: url, kind: FileSniffer.kind(of: url),
                                                context: RenderContext(appearance: appearance, defaultsSuite: "vt-nb"))
        return (renderer, preview, try XCTUnwrap(preview.view as? WKWebView, "\(renderer.pageErrors)"))
    }

    private func js(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.callAsyncJavaScript(script, contentWorld: .page)
    }

    private func until(_ what: String, _ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<300 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: The design's state

    func testSniffedAndRegisteredAsANotebook() throws {
        let url = try write(Self.churnNotebook())
        XCTAssertEqual(FileSniffer.kind(of: url), .code(language: "ipynb"))
        XCTAssertTrue(RendererRegistry.renderer(for: .code(language: "ipynb")) is NotebookRenderer)
        XCTAssertEqual(FileKind.code(language: "ipynb").displayName, "Jupyter notebook")
        XCTAssertFalse(RendererRegistry.renderer(for: .code(language: "json")) is NotebookRenderer, "plain JSON stays with its own view")
    }

    func testTheChurnNotebookReadsAsTheDesign() async throws {
        let (renderer, preview, web) = try await render(try write(Self.churnNotebook()))
        XCTAssertTrue(renderer.pageErrors.isEmpty, "\(renderer.pageErrors)")
        XCTAssertEqual(preview.document.viewTitles, ["Notebook", "Code only", "Source"])
        XCTAssertEqual(preview.document.fact("headline")?.value, "Ran out of order")
        XCTAssertEqual(preview.document.badges.first?.level, .caution)
        XCTAssertEqual(preview.document.fact("kernel")?.value, "Python 3 (ipykernel)")
        XCTAssertEqual(preview.document.fact("language")?.value, "Python 3.12")

        let title = try await js(web, "return document.querySelector('.ht').textContent;") as? String
        XCTAssertEqual(title, "Churn by region, Q3")
        let line = try await js(web, "return document.querySelector('.hs').textContent;") as? String ?? ""
        XCTAssertTrue(line.hasPrefix("Jupyter notebook · Python 3.12 · 4 cells · 3 code, 1 text · 3 outputs · 1 image, 1 error · "), line)
        let kv = try await js(web, "return Array.from(document.querySelectorAll('.hkv .k')).map(e => e.textContent).join(',');") as? String
        XCTAssertEqual(kv, "Kernel,Format,Ran")

        // The inset and the stale count: cell [7] ran after cell [4] below it.
        let inset = try await js(web, "return document.querySelector('.ginset.cg .gsub').textContent;") as? String
        XCTAssertEqual(inset, "Cell [7] ran after cell [4] below it; the outputs may not match the code above them.")
        let stale = try await js(web, "return Array.from(document.querySelectorAll('.nbg.stale')).map(e => e.textContent);") as? [String]
        XCTAssertEqual(stale, ["[7]"])
        let gutters = try await js(web, "return Array.from(document.querySelectorAll('.nbc:not(.md) .nbg')).map(e => e.textContent).join(' ');") as? String
        XCTAssertEqual(gutters, "[3] [7] [4]")

        // Statuses: the recorded run time, and the failed cell's error tag and red ring.
        let times = try await js(web, "return Array.from(document.querySelectorAll('.nbst.ok')).map(e => e.textContent.trim());") as? [String]
        XCTAssertEqual(times, ["0.4 s", "0.2 s"])
        let failed = try await js(web, "const c = document.querySelector('.nbc.bad'); return [c.querySelector('.nbst.err').textContent.trim(), c.querySelector('code').textContent];") as? [String]
        XCTAssertEqual(failed, ["error", "df.groupby(\"regoin\").size()"])

        // Outputs: the DataFrame as a table, the chart as a data: image, the error without terminal codes.
        let heads = try await js(web, "return Array.from(document.querySelectorAll('.nbhtml th')).map(e => e.textContent).join('|');") as? String
        XCTAssertEqual(heads, "region|churn %")
        let rows = try await js(web, "return document.querySelectorAll('.nbhtml tbody tr').length;") as? Int
        XCTAssertEqual(rows, 4)
        let image = try await js(web, "const i = document.querySelector('.nbout img'); return [i.getAttribute('src').slice(0, 22), i.naturalWidth];") as? [Any]
        XCTAssertEqual(image?[0] as? String, "data:image/png;base64,")
        try await until("the chart decoded") { (try await self.js(web, "return document.querySelector('.nbout img').naturalWidth;") as? Int ?? 0) == 120 }
        let error = try await js(web, "return document.querySelector('.nberr').textContent;") as? String ?? ""
        XCTAssertTrue(error.hasPrefix("KeyError: 'regoin'"), error)
        XCTAssertFalse(error.contains("\u{1B}"), "terminal codes are removed")
        XCTAssertTrue(error.contains("----> 1 df.groupby(\"regoin\")"), error)
        XCTAssertFalse(error.contains("-----------"), "IPython's rule line is dropped")

        // Markdown rendered; every code block coloured by Shiki in the system's syntax colours.
        let h1 = try await js(web, "return document.querySelector('.nbmd h1').textContent;") as? String
        XCTAssertEqual(h1, "Churn by region, Q3")
        try await until("Shiki colours") {
            (try await self.js(web, "return document.querySelectorAll('code[data-vt-coloured]').length;") as? Int ?? 0) == 3
        }
        let kwColour = try await js(web, """
            const want = getComputedStyle(document.documentElement).getPropertyValue('--v-syn-str').trim().toLowerCase();
            const spans = Array.from(document.querySelectorAll('code[data-vt-coloured] span'));
            const probe = document.createElement('i'); probe.style.color = want; document.body.append(probe);
            const rgb = getComputedStyle(probe).color; probe.remove();
            return spans.some(s => s.textContent.includes('orders.parquet') && getComputedStyle(s).color === rgb);
            """) as? Bool
        XCTAssertEqual(kwColour, true, "a string takes the system's string colour")
    }

    func testDarkAppearanceUsesTheDarkTokens() async throws {
        let (_, _, web) = try await render(try write(Self.churnNotebook()), appearance: .dark)
        let theme = try await js(web, "return document.documentElement.dataset.theme;") as? String
        XCTAssertEqual(theme, "dark")
        let card = try await js(web, "return getComputedStyle(document.querySelector('.hcard')).backgroundColor;") as? String
        XCTAssertNotEqual(card, "rgb(255, 255, 255)")
    }

    // MARK: Safety

    func testOutputsAndCellsNeverRunScriptOrLoadAnything() async throws {
        let hostile = """
        <script>window.__ran = 'script'</script><img src="x" onerror="window.__ran='onerror'">
        <iframe src="https://example.invalid/frame"></iframe><style>body { display: none }</style>
        <a href="javascript:window.__ran='link'" onclick="window.__ran='click'">a link</a>
        <img src="https://example.invalid/pixel.png"><table onmouseover="x()"><tr><td style="position:fixed">kept text</td></tr></table>
        <svg><script>window.__ran='svg'</script></svg><form action="https://example.invalid"><input value="v"><button>Go</button></form>
        """
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><script>window.__ran='svgimg'</script><rect width=\"10\" height=\"10\"/></svg>"
        let url = try write(try Self.notebook([
            Self.markdown("Raw HTML in a cell: <script>window.__ran='md'</script><img src=\"y\" onerror=\"window.__ran='md-onerror'\">\n\n![remote](https://example.invalid/r.png)"),
            Self.code("display(HTML(page))", count: 1, outputs: [Self.result(["text/html": hostile, "text/plain": "<HTML>"])]),
            Self.code("display(SVG(s))", count: 2, outputs: [Self.result(["image/svg+xml": svg])]),
            Self.code("plotly.show()", count: 3, outputs: [Self.result(["text/html": "<script>window.__ran='plotly'</script>"])]),
        ]), "hostile.ipynb")
        let (renderer, _, web) = try await render(url)
        try await Task.sleep(for: .milliseconds(400))
        let ran = try await js(web, "return window.__ran === undefined ? null : window.__ran;")
        XCTAssertTrue(ran == nil || ran is NSNull, "nothing in the notebook ran: \(String(describing: ran))")
        let html = try await js(web, "return document.querySelector('.nbhtml').innerHTML;") as? String ?? ""
        for banned in ["<script", "onerror", "onclick", "onmouseover", "<iframe", "<style", "javascript:", "<form", "<input", "<svg", "style=", "href="] {
            XCTAssertFalse(html.contains(banned), "\(banned) survived: \(html)")
        }
        XCTAssertTrue(html.contains("a link") && html.contains("kept text") && html.contains("<table>"), html)
        let elements = try await js(web, "return document.querySelectorAll('main iframe, main form, main script').length;") as? Int
        XCTAssertEqual(elements, 0)
        // The SVG output is an <img> (WebKit never runs an image's scripts); the script-only output says so.
        let svgSrc = try await js(web, "return document.querySelector('.nbimg').getAttribute('src').slice(0, 26);") as? String
        XCTAssertEqual(svgSrc, "data:image/svg+xml;base64,")
        let note = try await js(web, "return Array.from(document.querySelectorAll('.nbnote')).map(e => e.textContent).join('|');") as? String
        XCTAssertEqual(note, "Interactive output: its scripts are not run in a preview.")
        // The remote images became chips; nothing tried to load them.
        let chips = try await js(web, "return document.querySelectorAll('.rghost').length;") as? Int
        XCTAssertEqual(chips, 1)
        XCTAssertTrue(renderer.pageErrors.isEmpty, "\(renderer.pageErrors)")
    }

    func testTheAllowlistRebuildsHTML() {
        XCTAssertEqual(NotebookHTML.sanitize("<p onclick=x>Hi <b>there</b></p>"), "<p>Hi <b>there</b></p>")
        XCTAssertEqual(NotebookHTML.sanitize("<td colspan=\"2\" align=right style=\"x\">1</td>"), "<td colspan=\"2\" align=\"right\">1</td>")
        XCTAssertEqual(NotebookHTML.sanitize("a<script>alert(1)</script>b"), "ab")
        XCTAssertEqual(NotebookHTML.sanitize("<SCRIPT >x</ScRiPt >c"), "c")
        XCTAssertEqual(NotebookHTML.sanitize("<div title=\"a>b\">t</div>"), "<div>t</div>", "a quoted > does not end the tag")
        XCTAssertEqual(NotebookHTML.sanitize("<table><tr><td>open"), "<table><tr><td>open</td></tr></table>", "balanced")
        XCTAssertEqual(NotebookHTML.sanitize("</b>stray</div>"), "stray")
        XCTAssertEqual(NotebookHTML.sanitize("1 < 2 & 3 > 2 &amp; &lt;"), "1 &lt; 2 &amp; 3 &gt; 2 &amp; &lt;")
        XCTAssertEqual(NotebookHTML.sanitize("<!-- c --><!doctype html>x"), "x")
        XCTAssertEqual(NotebookHTML.sanitize("<img src=\"data:image/png;base64,iVBORw0=\" onerror=y>"), "<img src=\"data:image/png;base64,iVBORw0=\">")
        XCTAssertEqual(NotebookHTML.sanitize("<img src=\"https://t.invalid/p.gif\" alt=\"p\">"), "", "an image with no source it may show goes")
        XCTAssertEqual(NotebookHTML.sanitize("<img src=\"data:image/svg+xml;base64,PHN2Zz4=\">"), "", "only bitmap data images")
        XCTAssertEqual(NotebookHTML.sanitize("<a href=\"https://x.invalid\">t</a>"), "<a>t</a>")
        XCTAssertEqual(NotebookHTML.sanitize("<x-widget>w</x-widget><button>b</button>"), "wb")
        XCTAssertFalse(NotebookHTML.hasVisibleContent(NotebookHTML.sanitize("<script>a()</script><div> </div>")))
    }

    func testTerminalTextDropsColourCodesAndKeepsTheLastProgressState() {
        XCTAssertEqual(NotebookHTML.terminalText("\u{1B}[0;31mKeyError\u{1B}[0m: 'x'"), "KeyError: 'x'")
        XCTAssertEqual(NotebookHTML.terminalText("  0%\r 50%\r100%\ndone\r\n"), "100%\ndone\n")
        XCTAssertEqual(NotebookHTML.terminalText("\u{1B}]8;;https://x.invalid\u{07}link\u{1B}]8;;\u{07}"), "link")
    }

    func testImagesAreCheckedAndReencoded() throws {
        let fake = Data("<html>not a png</html>".utf8).base64EncodedString()
        XCTAssertEqual(NotebookPage.imageHTML(mime: "image/png", base64: fake, alt: nil, limits: .standard),
                       "<p class=\"nbnote\">An image/png output that could not be read.</p>")
        let real = NotebookPage.imageHTML(mime: "image/png", base64: Self.chartPNG(), alt: "<Figure \"x\">", limits: .standard)
        XCTAssertTrue(real.hasPrefix("<img class=\"nbimg\" alt=\"&lt;Figure &quot;x&quot;&gt;\" src=\"data:image/png;base64,iVBOR"), real)
        var small = NotebookPage.Limits.standard
        small.maxImageBase64 = 10
        XCTAssertTrue(NotebookPage.imageHTML(mime: "image/png", base64: Self.chartPNG(), alt: nil, limits: small).contains("too large"))
    }

    // MARK: Run order and the facts

    func testRunOrderMarksCellsThatRanAfterACellBelowThem() {
        func cells(_ counts: [Int?]) -> [NotebookReader.Cell] {
            counts.map { NotebookReader.Cell(kind: .code, id: nil, source: "", executionCount: $0, metadata: Data(), outputs: []) }
        }
        XCTAssertEqual(NotebookPage.runOrder(cells([1, 2, 3])).stale, [])
        XCTAssertNil(NotebookPage.runOrder(cells([1, nil, 3])).first, "a cell never run says nothing about order")
        let design = NotebookPage.runOrder(cells([3, 7, 4]))
        XCTAssertEqual(design.stale, [1])
        XCTAssertEqual(design.first?.above, 7)
        XCTAssertEqual(design.first?.below, 4)
        let two = NotebookPage.runOrder(cells([9, 2, 8, 5]))
        XCTAssertEqual(two.stale, [0, 2])
        XCTAssertEqual(two.first?.above, 9)
        XCTAssertEqual(two.first?.below, 2)
    }

    func testAnUnrunNotebookHasNoStatusesAndNoBadge() async throws {
        let url = try write(try Self.notebook([
            Self.markdown("Notes without a heading"),
            Self.code("import math\nmath.tau", count: nil),
            ["cell_type": "raw", "metadata": [:], "source": "raw text kept as written"],
        ], language: "python", version: ""), "unrun.ipynb")
        let (_, preview, web) = try await render(url)
        XCTAssertEqual(preview.document.fact("headline")?.value, "3 cells")
        XCTAssertTrue(preview.document.badges.isEmpty)
        let found = try await js(web, """
            return [document.querySelector('.ht').textContent, document.querySelector('.nbc:not(.md):not(.raw) .nbg').textContent,
                    String(document.querySelectorAll('.nbst, .ginset').length), document.querySelector('.nbraw').textContent];
            """) as? [String]
        XCTAssertEqual(found, ["unrun", "[ ]", "0", "raw text kept as written"], "the file name when there is no heading; no statuses")
    }

    func testAnEmptyNotebookSaysSo() throws {
        let page = try NotebookPage.make(data: try Self.notebook([]), fileName: "blank.ipynb", fileSize: 120)
        XCTAssertTrue(page.body.contains("This notebook has no cells."))
        XCTAssertEqual(page.document.fact("headline")?.value, "0 cells")
        XCTAssertEqual(page.document.fact("cells")?.value, "none")
        XCTAssertEqual(NotebookPage.duration(0.04), "< 0.1 s")
        XCTAssertEqual(NotebookPage.duration(252), "4 min 12 s")
    }

    // MARK: The switch, find, reload

    func testCodeOnlyFoldsProseAndOutputsAndSourceIsTheHostsTextView() async throws {
        let (_, preview, web) = try await render(try write(Self.churnNotebook()))
        let show = try XCTUnwrap(preview.showView)
        XCTAssertTrue(show(1))
        try await until("Code only") { (try await self.js(web, "return document.body.classList.contains('code-only');") as? Bool) == true }
        let folded = try await js(web, "return Array.from(document.querySelectorAll('.nbout, .nbc.md')).every(e => e.getClientRects().length === 0);") as? Bool
        XCTAssertEqual(folded, true)
        XCTAssertFalse(show(2), "Source is the JSON in the host's text view")
        if case .text(let source) = preview.document.views[2] { XCTAssertTrue(source.contains("\"nbformat\"")) } else { XCTFail("Source is text") }
        XCTAssertTrue(show(0))
        try await until("Notebook again") { (try await self.js(web, "return document.body.classList.contains('code-only');") as? Bool) == false }
    }

    func testFindMarksVisibleMatchesOnly() async throws {
        let (_, preview, web) = try await render(try write(Self.churnNotebook()))
        let find = try XCTUnwrap(preview.find)
        // Colouring rewrites a block's text, so find after Shiki has finished (as a reader would).
        try await until("Shiki colours") {
            (try await self.js(web, "return document.querySelectorAll('code[data-vt-coloured]').length;") as? Int ?? 0) == 3
        }
        let all = await find("region", true)
        XCTAssertEqual(all.count, 5, "title, the markdown sentence, the code, the table header, and the header card")
        _ = preview.showView?(1)
        try await until("Code only") { (try await self.js(web, "return document.body.classList.contains('code-only');") as? Bool) == true }
        let codeOnly = await find("North", true)
        XCTAssertEqual(codeOnly.count, 0, "the table is folded away in Code only")
    }

    func testReloadRedrawsInPlace() async throws {
        let url = try write(Self.churnNotebook())
        let (_, preview, web) = try await render(url)
        try Self.notebook([Self.markdown("# Churn by region, Q4")]).write(to: url)
        let fresh = try await XCTUnwrap(preview.reload)(url)
        XCTAssertEqual(fresh.fact("headline")?.value, "1 cell")
        let title = try await js(web, "return document.querySelector('.ht').textContent;") as? String
        XCTAssertEqual(title, "Churn by region, Q4")
    }

    // MARK: Not a notebook

    func testANotebookVitrineCannotReadOpensAsJSONWithTheReason() async throws {
        for (name, text) in [("broken.ipynb", "{\"cells\": [,]}"), ("old.ipynb", "{\"nbformat\": 3, \"worksheets\": []}")] {
            let url = dir.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            let preview = try await NotebookRenderer().render(url: url, kind: .code(language: "ipynb"),
                                                              context: RenderContext(appearance: .light, defaultsSuite: "vt-nb"))
            XCTAssertEqual(preview.document.badges.first?.title, "Not drawn as a notebook", name)
            XCTAssertEqual(preview.document.kind, .code(language: "json"), name)
        }
    }

    func testMarkdownAttachmentsMathAndRichOutputs() async throws {
        let url = try write(try Self.notebook([
            Self.markdown("![plot](attachment:plot.png) and $e^{i\\pi}+1=0$", attachments: ["plot.png": ["image/png": Self.chartPNG()]]),
            Self.code("print('a'); print('b')", count: 1, outputs: [
                ["output_type": "stream", "name": "stdout", "text": ["a\n"]], ["output_type": "stream", "name": "stdout", "text": "b\n"],
                Self.result(["text/markdown": "**bold** result", "text/plain": "<Markdown>"]),
                Self.result(["text/latex": "$$x^2$$", "text/plain": "x**2"]),
            ]),
        ]), "rich.ipynb")
        let (renderer, _, web) = try await render(url)
        XCTAssertTrue(renderer.pageErrors.isEmpty, "\(renderer.pageErrors)")
        let found = try await js(web, """
            return [document.querySelector('.nbmd img').getAttribute('src').slice(0, 22), String(document.querySelectorAll('.nbtext').length),
                    document.querySelector('.nbtext').textContent, document.querySelector('.nbout .nbmd strong').textContent,
                    String(document.querySelectorAll('.katex').length)];
            """) as? [String]
        // The attachment drawn from the cell; two stdout writes as one block; Markdown and LaTeX outputs rendered.
        XCTAssertEqual(found, ["data:image/png;base64,", "1", "a\nb\n", "bold", "2"])
    }
}
