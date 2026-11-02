import XCTest
import WebKit
import Darwin
@testable import VitrinePreviewKit

/// S-16, lane 2, the parts the fixes added: the export allowlist on its own, the exported page still drawn as on
/// screen (maths, diagrams, code colours) under its Content-Security-Policy, the confined file read, and the Mermaid
/// tickets. All inputs are invented here. roadmap: S-16
@MainActor
final class S16WebExportTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() {
        for f in folders { try? FileManager.default.removeItem(at: f) }
        folders = []
        super.tearDown()
    }

    private func folder(_ tag: String = "doc") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-s16x-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folders.append(dir)
        return dir
    }

    private let sanitize = MarkdownExportHTML.sanitize

    // MARK: The allowlist (F1)

    func testHandlersScriptURLsAndActiveElementsGo() {
        XCTAssertEqual(sanitize("<p onclick=\"x()\" class=\"a\">Hi <b onmouseover=y>there</b></p>"), "<p class=\"a\">Hi <b>there</b></p>")
        XCTAssertEqual(sanitize("<img src=\"data:image/png;base64,iVBORw0=\" onerror=\"alert(1)\" alt=\"t\">"), "<img src=\"data:image/png;base64,iVBORw0=\" alt=\"t\">")
        XCTAssertEqual(sanitize("<img src=\"x\" onerror=\"alert(1)\" alt=\"chart\">"), "<img alt=\"chart\">", "an image that cannot be carried keeps its words")
        XCTAssertEqual(sanitize("<a href=\"javascript:alert(1)\">a</a><a href=\" Java\tScript:alert(2)\">b</a><a href=\"data:text/html,x\">c</a>"), "<a>a</a><a>b</a><a>c</a>")
        XCTAssertEqual(sanitize("<a href=\"vitrine://doc/x\">v</a><a href=\"file:///etc/passwd\">f</a>"), "<a>v</a><a>f</a>")
        XCTAssertEqual(sanitize("<a href=\"https://x.invalid/a?b=1&amp;c=2\">w</a><a href=\"#fn-1\">j</a><a href=\"notes.md\">r</a><a href=\"mailto:a@b.invalid\">m</a>"),
                       "<a href=\"https://x.invalid/a?b=1&amp;c=2\">w</a><a href=\"#fn-1\">j</a><a href=\"notes.md\">r</a><a href=\"mailto:a@b.invalid\">m</a>")
        XCTAssertEqual(sanitize("a<script>alert(1)</script>b<iframe src=x></iframe>c<object data=x></object>d"), "abcd")
        XCTAssertEqual(sanitize("<form action=x><input type=\"text\" value=\"v\"><button formaction=y>go</button></form>t"), "t", "no form, no text field, no button")
        XCTAssertEqual(sanitize("<details open=\"\" ontoggle=\"x\"><summary>s</summary>d</details>"), "<details open=\"\"><summary>s</summary>d</details>")
        XCTAssertEqual(sanitize("<li><input type=\"checkbox\" checked=\"\" disabled=\"\" onclick=\"x\"> done</li>"), "<li><input type=\"checkbox\" checked=\"\" disabled=\"\"> done</li>")
        XCTAssertEqual(sanitize("<link rel=stylesheet href=x.css><meta http-equiv=refresh content=0><base href=x>t"), "t")
    }

    func testStylesCannotFetchOrHideScript() {
        XCTAssertEqual(sanitize("<span style=\"height:0.68em;vertical-align:-0.15em;\">k</span>"), "<span style=\"height:0.68em;vertical-align:-0.15em;\">k</span>")
        XCTAssertEqual(sanitize("<span style=\"color:#d73a49\">let</span>"), "<span style=\"color:#d73a49\">let</span>")
        for bad in ["background:url(https://x.invalid/p.gif)", "background:url( 'x.png')", "background:image-set(\"x.png\" 1x)",
                    "x:expression(alert(1))", "background:u\\72l(x)", "behavior:url(x.htc)", "@import 'x'"] {
            XCTAssertEqual(sanitize("<div style=\"\(bad)\">t</div>"), "<div>t</div>", bad)
        }
        XCTAssertEqual(sanitize("<svg><path style=\"fill:url(#grad)\" marker-end=\"url(#arrow)\" d=\"M0 0L1 1\"></path></svg>"),
                       "<svg><path style=\"fill:url(#grad)\" marker-end=\"url(#arrow)\" d=\"M0 0L1 1\"></path></svg>")
        XCTAssertEqual(sanitize("<svg><path fill=\"url(https://x.invalid/#g)\" d=\"M0 0\"></path></svg>"), "<svg><path d=\"M0 0\"></path></svg>")
    }

    func testSVGKeepsItsDrawingAndLosesItsActiveParts() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\" width=\"100%\" onload=\"x\" role=\"graphics-document document\" aria-roledescription=\"flowchart-v2\">"
            + "<style>#m .node rect{fill:#eee;stroke:#333}#m .a>b{x:1}</style>"
            + "<g class=\"node\" transform=\"translate(1,2)\" data-id=\"A\"><rect x=\"0\" y=\"0\" width=\"4\" height=\"4\" rx=\"1\"></rect>"
            + "<foreignObject width=\"4\" height=\"4\"><div xmlns=\"http://www.w3.org/1999/xhtml\" style=\"display: table-cell;\"><span class=\"nodeLabel\"><p>Plan</p></span></div></foreignObject></g>"
            + "<use href=\"#a\"></use><use href=\"https://x.invalid/s.svg#a\"></use><a href=\"javascript:alert(1)\"><text>t</text></a>"
            + "<animate attributeName=\"href\" to=\"javascript:alert(1)\"></animate><set attributeName=\"onclick\" to=\"x\"></set>"
            + "<image href=\"https://x.invalid/p.png\"></image><script>alert(1)</script></svg>"
        let out = sanitize(svg)
        XCTAssertTrue(out.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\" viewbox=\"0 0 10 10\" width=\"100%\" role=\"graphics-document document\" aria-roledescription=\"flowchart-v2\">"), out)
        XCTAssertTrue(out.contains("<style>#m .node rect{fill:#eee;stroke:#333}#m .a&gt;b{x:1}</style>"), out)
        XCTAssertTrue(out.contains("<foreignobject width=\"4\" height=\"4\"><div xmlns=\"http://www.w3.org/1999/xhtml\" style=\"display: table-cell;\"><span class=\"nodeLabel\"><p>Plan</p></span></div></foreignobject>"), out)
        XCTAssertTrue(out.contains("<use href=\"#a\"></use><use></use><a><text>t</text></a>"), out)
        for gone in ["onload", "animate", "<set", "<image", "<script", "alert", "javascript", "x.invalid"] { XCTAssertFalse(out.contains(gone), "\(gone): \(out)") }
    }

    /// The `<style>` inside an SVG is text only: markup in it is escaped, never parsed, and outside an SVG it goes.
    func testAnSVGStyleIsTextOnly() {
        let out = sanitize("<svg><style>a{}</style><img src=x onerror=alert(1)><b>x</b></style></svg>")
        XCTAssertFalse(out.contains("onerror"), out)
        XCTAssertEqual(sanitize("<svg><style>p{} <img src=x onerror=alert(1)> &amp; &x</style></svg>"),
                       "<svg><style>p{} &lt;img src=x onerror=alert(1)&gt; &amp; &amp;x</style></svg>", "escaped, so it is text whichever way it is read")
        XCTAssertEqual(sanitize("<style>body{display:none}</style>t"), "t", "a style outside a drawing goes with its rules")
        XCTAssertEqual(sanitize("<svg><style>a{}"), "<svg><style>a{}</style></svg>", "an unclosed one still closes")
    }

    func testMathMLForScreenReadersStaysAndHTMLIslandsGo() {
        let math = "<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"block\"><semantics><mrow><mi>h</mi><mo>=</mo><mn>2.5</mn></mrow>"
            + "<annotation encoding=\"application/x-tex\">h = 2.5</annotation></semantics></math>"
        XCTAssertEqual(sanitize(math), math)
        XCTAssertEqual(sanitize("<math><mi href=\"javascript:x\">a</mi><annotation-xml encoding=\"text/html\"><img src=x onerror=y></annotation-xml></math>"),
                       "<math><mi>a</mi></math>")
    }

    func testOnlyBase64PicturesAreCarried() {
        XCTAssertTrue(MarkdownExportHTML.isDataImage("data:image/png;base64,iVBORw0KGgo="))
        XCTAssertTrue(MarkdownExportHTML.isDataImage("data:image/svg+xml;base64,PHN2Zz4="))
        XCTAssertFalse(MarkdownExportHTML.isDataImage("data:image/svg+xml,<svg onload=alert(1)>"))
        XCTAssertFalse(MarkdownExportHTML.isDataImage("data:text/html;base64,PHNjcmlwdD4="))
        XCTAssertFalse(MarkdownExportHTML.isDataImage("data:image/png;base64,iVBOR\"onerror=x"))
        XCTAssertFalse(MarkdownExportHTML.isDataImage("https://x.invalid/p.png"))
    }

    /// The rebuild runs after pictures are embedded, so it reads them too: a picture at the embedding limit must
    /// not make the export crawl.
    func testAPictureAtTheEmbeddingLimitIsRebuiltQuickly() {
        let base64 = Data(repeating: 0xA5, count: MarkdownRenderer.embeddedImageLimit).base64EncodedString()
        let body = "<article id=\"body\" class=\"md\"><p><img src=\"data:image/png;base64,\(base64)\" alt=\"big\"></p></article>"
        let start = Date()
        let out = sanitize(body)
        let seconds = Date().timeIntervalSince(start)
        XCTAssertTrue(out.contains("alt=\"big\"") && out.utf8.count > base64.utf8.count, "the picture stays")
        XCTAssertLessThan(seconds, 10, "rebuilt in \(seconds) s (1.5 s measured in Debug)")
    }

    func testTheCollectedStyleSheetsCannotEndTheirElement() {
        XCTAssertEqual(MarkdownExportHTML.styleSheet("a{} </STYLE><script>x</script>"), "a{} <\\/style><script>x</script>")
        XCTAssertEqual(MarkdownExportHTML.escape("<b>\"&"), "&lt;b&gt;&quot;&amp;")
    }

    /// The notebook's rebuild did not change when it became a policy (the notebook's own tests pin it too).
    func testTheNotebookPolicyIsUnchanged() {
        XCTAssertEqual(NotebookHTML.sanitize("<img src=\"https://t.invalid/p.gif\" alt=\"p\">"), "")
        XCTAssertEqual(NotebookHTML.sanitize("<svg><style>x</style></svg>t<span style=\"color:red\" class=\"c\">s</span>"), "t<span>s</span>")
        XCTAssertEqual(NotebookHTML.sanitize("<x-widget>w</x-widget><button>b</button>"), "wb")
    }

    // MARK: The exported page, drawn (F1: still looks right)

    private func png() throws -> Data {
        let pixel = NSImage(size: NSSize(width: 4, height: 4))
        pixel.lockFocus(); NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); pixel.unlockFocus()
        let rep = NSBitmapImageRep(data: try XCTUnwrap(pixel.tiffRepresentation))
        return try XCTUnwrap(rep?.representation(using: .png, properties: [:]))
    }

    private func window(for view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?.resume(); done = nil }
    }

    /// Element and attribute counts under #body, from the live page's own export clone and from the exported file
    /// parsed (never run) by DOMParser: the allowlist must not have dropped anything the page drew.
    private static let signature = """
        const count = (root) => { const tags = {}, attrs = {};
          root.querySelectorAll('*').forEach((e) => { const t = e.localName; tags[t] = (tags[t] || 0) + 1;
            for (const a of e.attributes) { const k = t + '@' + a.name; attrs[k] = (attrs[k] || 0) + 1; } });
          return { tags, attrs }; };
        const live = document.getElementById('body').cloneNode(true);
        live.querySelectorAll('.copy, .vt-ruler').forEach((n) => n.remove());
        const exported = new DOMParser().parseFromString(html, 'text/html').getElementById('body');
        return JSON.stringify({ live: count(live), exported: count(exported) });
        """

    func testTheExportedPageKeepsMathsDiagramsAndCodeColoursUnderItsPolicy() async throws {
        let dir = try folder()
        try png().write(to: dir.appendingPathComponent("tide.png"))
        let text = """
        # Tidepool

        A [jump](#notes), *emphasis*, `code`, <kbd>⌘</kbd> and a footnote.[^1]

        > [!NOTE]
        > Height $h = 2.5$ m at noon.

        $$\\int_0^1 x^2\\,dx = \\frac{1}{3} \\qquad \\sqrt{2}$$

        | Left | Centre |
        |:-----|:------:|
        | a    | b      |

        - [x] measured
        - [ ] charted

        ![tide chart](tide.png)

        ```swift
        let height = 2.5 // metres
        print("tide \\(height)")
        ```

        ```mermaid
        flowchart LR
          A[Measure] --> B{High?}
          B -->|yes| C[Log it]
        ```

        ```mermaid
        sequenceDiagram
          Alice->>Bob: Tide is high
          Bob-->>Alice: Noted
        ```

        ```mermaid
        pie title Readings
          "High" : 3
          "Low" : 5
        ```

        ```mermaid
        classDiagram
          class Gauge {
            +Double height
            +read() Double
          }
          Gauge <|-- TideGauge
        ```

        ```mermaid
        stateDiagram-v2
          [*] --> Ebb
          Ebb --> Flood
          Flood --> [*]
        ```

        ```mermaid
        gantt
          dateFormat YYYY-MM-DD
          section Survey
          Measure :a1, 2026-01-01, 3d
          Chart   :after a1, 2d
        ```

        ```mermaid
        erDiagram
          GAUGE ||--o{ READING : records
        ```

        <details><summary>More</summary>Hidden words.</details>

        ## Notes

        [^1]: Measured at Cascais.
        """
        let url = dir.appendingPathComponent("Tidepool.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let renderer = MarkdownRenderer()
        let preview = try await renderer.render(url: url, kind: .markdown(.commonMark),
            context: RenderContext(appearance: .light, defaultsSuite: "vt-s16x-suite", cachesDirectory: dir.appendingPathComponent("caches")))
        let liveWindow = window(for: preview.view)
        defer { liveWindow.orderOut(nil) }
        let live = try XCTUnwrap(preview.view as? WKWebView)
        // Both diagrams drawn and the code coloured before the export is taken.
        for _ in 0..<300 {
            let ready = try await live.evaluateJavaScript("document.querySelectorAll('.mermaid-block').length === 7 && !document.querySelector('.mermaid-block.pending') && !!document.querySelector('.cb pre code span[style]')") as? Bool
            if ready == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let html = try await renderer.exportHTML(title: "Tidepool.md")

        // Nothing the page drew was dropped (beyond what is meant to go).
        let raw = try await live.callAsyncJavaScript(Self.signature, arguments: ["html": html], contentWorld: .page) as? String
        let both = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(raw).utf8)) as? [String: [String: [String: Int]]])
        let liveTags = try XCTUnwrap(both["live"]?["tags"]), exportedTags = try XCTUnwrap(both["exported"]?["tags"])
        let liveAttrs = try XCTUnwrap(both["live"]?["attrs"]), exportedAttrs = try XCTUnwrap(both["exported"]?["attrs"])
        XCTAssertGreaterThan(liveTags["svg"] ?? 0, 2, "the diagrams and the square root are drawn as SVG")
        let tagDiff = Set(liveTags.keys).union(exportedTags.keys).filter { liveTags[$0] != exportedTags[$0] }
            .sorted().map { "\($0): \(liveTags[$0] ?? 0) → \(exportedTags[$0] ?? 0)" }
        XCTAssertEqual(tagDiff, [], "every element the page drew is in the export")
        let attrDiff = Set(liveAttrs.keys).union(exportedAttrs.keys).filter { liveAttrs[$0] != exportedAttrs[$0] }
            .sorted().map { "\($0): \(liveAttrs[$0] ?? 0) → \(exportedAttrs[$0] ?? 0)" }
        XCTAssertEqual(attrDiff, [], "every attribute the page drew is in the export")

        // The file, opened on its own (with its policy), looks as the page did: maths in KaTeX's fonts at the same
        // width, the diagrams at the same size, the code coloured.
        let exported = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let loaded = Loaded()
        exported.navigationDelegate = loaded
        let exportedWindow = window(for: exported)
        defer { exportedWindow.orderOut(nil) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in loaded.done = c; exported.loadHTMLString(html, baseURL: nil) }
        let measure = """
            await document.fonts.ready;
            const box = (s) => { const e = document.querySelector(s); if (!e) return null; const r = e.getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)]; };
            return JSON.stringify({ math: box('.math-display .katex-html'), flow: box('.mermaid-block svg'),
              fonts: Array.from(document.fonts).filter((f) => f.family.includes('KaTeX') && f.status === 'loaded').length,
              coloured: document.querySelectorAll('.cb pre code span[style*="color"]').length,
              katexFont: getComputedStyle(document.querySelector('.katex')).fontFamily });
            """
        try await Task.sleep(for: .milliseconds(300))
        let liveRaw = try await live.callAsyncJavaScript(measure, arguments: [:], contentWorld: .page) as? String
        let exportedRaw = try await exported.callAsyncJavaScript(measure, arguments: [:], contentWorld: .page) as? String
        let a = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(liveRaw).utf8)) as? [String: Any])
        let b = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(exportedRaw).utf8)) as? [String: Any])
        XCTAssertGreaterThan(b["fonts"] as? Int ?? 0, 0, "KaTeX's fonts load from the data: URLs the policy allows")
        XCTAssertEqual(b["math"] as? [Int], a["math"] as? [Int], "the display maths is laid out at the same size")
        XCTAssertEqual(b["flow"] as? [Int], a["flow"] as? [Int], "the flowchart is drawn at the same size")
        XCTAssertEqual(b["coloured"] as? Int, a["coloured"] as? Int, "the code keeps its colours")
        XCTAssertGreaterThan(b["coloured"] as? Int ?? 0, 0)
        XCTAssertTrue((b["katexFont"] as? String ?? "").contains("KaTeX"), "maths uses KaTeX's font")
        let stillScripted = try await exported.evaluateJavaScript("document.scripts.length") as? Int
        XCTAssertEqual(stillScripted, 0)
    }

    // MARK: The confined read (F10, F14)

    func testTheReadHonoursTheLimitAndRefusesAFileSwappedForALink() throws {
        let doc = try folder(), outside = try folder("outside")
        let file = doc.appendingPathComponent("p.png")
        try Data(repeating: 7, count: 2048).write(to: file)
        let secret = outside.appendingPathComponent("secret")
        try Data("INVENTED".utf8).write(to: secret)
        let h = PreviewSchemeHandler(documentRoot: doc)
        let u = URL(string: "vitrine://doc/p.png")!
        XCTAssertEqual(h.read(u)?.data.count, 2048)
        XCTAssertNil(h.read(u, limit: 1024), "larger than the limit: not read (the size of the file itself, not of a link)")

        // Checked, then swapped for a link before the read: the read refuses it.
        let real = try XCTUnwrap(ConfinedFile.realDirectory(doc))
        let checked = try XCTUnwrap(ConfinedFile.check(file.path, inside: real))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        XCTAssertNil(ConfinedFile.read(checked.real, identity: checked.identity, limit: .max), "a link put in place after the check is not followed")
        // Swapped for another regular file: not the file that was checked.
        try FileManager.default.removeItem(at: file)
        try Data("other".utf8).write(to: file)
        XCTAssertNil(ConfinedFile.read(checked.real, identity: checked.identity, limit: .max), "a different file is not read")
    }

    func testARootReachedThroughALinkStillServesItsOwnFiles() throws {
        let real = try folder("real"), links = try folder("links")
        try Data("ok".utf8).write(to: real.appendingPathComponent("a.txt"))
        let linked = links.appendingPathComponent("doc")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        let h = PreviewSchemeHandler(documentRoot: linked)
        XCTAssertEqual(h.read(URL(string: "vitrine://doc/a.txt")!)?.data, Data("ok".utf8))
        XCTAssertNil(h.read(URL(string: "vitrine://doc/../links/doc/a.txt")!))
    }

    func testAPercentInAFileNameIsDecodedOnce() throws {
        let doc = try folder()
        try Data("x".utf8).write(to: doc.appendingPathComponent("a%20b.txt"))
        let h = PreviewSchemeHandler(documentRoot: doc)
        XCTAssertNotNil(h.read(URL(string: "vitrine://doc/a%2520b.txt")!), "%25 is a percent sign")
        XCTAssertNil(h.read(URL(string: "vitrine://doc/a%20b.txt")!), "a%20b means a space, and no such file exists")
    }

    // MARK: Mermaid tickets (F52)

    func testTicketsBindAKeyToItsSource() {
        var t = MermaidTickets()
        XCTAssertFalse(t.accepts(key: "k", source: "a"))
        t.issue(key: "k", source: "graph LR\r\n  A-->B\r\n")
        XCTAssertTrue(t.accepts(key: "k", source: "graph LR\n  A-->B\n"), "the page reads line breaks back as LF")
        XCTAssertFalse(t.accepts(key: "k", source: "graph LR\n  A-->C\n"))
        XCTAssertFalse(t.accepts(key: "other", source: "graph LR\n  A-->B\n"))
        t.revoke(key: "k")
        XCTAssertFalse(t.accepts(key: "k", source: "graph LR\n  A-->B\n"))
        let cache = MermaidCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("vt-s16x-mc-\(UUID().uuidString)"))
        let key = String(repeating: "b", count: 64)
        t.issue(key: key, source: "s")
        XCTAssertFalse(cache.store("<svg></svg>", for: key, source: "t", tickets: t))
        XCTAssertTrue(cache.store("<svg></svg>", for: key, source: "s", tickets: t))
        try? FileManager.default.removeItem(at: cache.directory)
    }

    func testPageIntegersAreChecked() {
        XCTAssertEqual(PageNumbers.integer(250.4, in: 160...360), 250)
        XCTAssertEqual(PageNumbers.integer(NSNumber(value: 300), in: 160...360), 300)
        for bad: Any in [Double.nan, Double.infinity, 1e23, -1e300, 159.0, 361.0, "250", NSNull()] {
            XCTAssertNil(PageNumbers.integer(bad, in: 160...360), "\(bad)")
        }
    }
}
