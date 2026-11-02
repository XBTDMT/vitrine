import Network
import WebKit
import XCTest
@testable import VitrinePreviewKit
import VitrineData
import VitrineDocument
import VitrineSupport
import VitrineUI

/// SVG in the data design (D-4, G-12): the picture drawn by WebKit as an image on the checkerboard, Picture and
/// Source in the switch, the facts in the pill and the Inspector, warnings as badges; a script inside never runs and
/// nothing the file points at is ever fetched (a 127.0.0.1 listener stands in for the internet, nothing leaves the
/// Mac); a malformed or too-deep file opens on its source with a badge. All content is invented. roadmap: S-6
@MainActor
final class SVGRendererTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-svg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private final class Listener: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        let ready = XCTestExpectation(description: "listener ready")

        init() throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.lock.withLock { self?._count += 1 }
                connection.cancel()
            }
            listener.stateUpdateHandler = { [ready] state in if case .ready = state { ready.fulfill() } }
            listener.start(queue: .global())
        }

        var port: UInt16 { listener.port?.rawValue ?? 0 }
        deinit { listener.cancel() }
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let suite = "vt-svg-\(UUID().uuidString)"

    private func render(_ url: URL) async throws -> (RenderedPreview, SVGView) {
        let preview = try await SVGRenderer().render(url: url, kind: .svg, context: RenderContext(appearance: .light, defaultsSuite: suite))
        return (preview, try XCTUnwrap(preview.view as? SVGView))
    }

    /// A glass badge like the design's `badge-glass.svg`: 14 elements, gradients, no scripts, nothing outside.
    private let badge = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
      <title>Glass badge</title>
      <defs>
        <linearGradient id="bg1" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5AC8FA"/><stop offset="1" stop-color="#0A60D8"/></linearGradient>
        <linearGradient id="gl1" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".85"/><stop offset="1" stop-color="#fff" stop-opacity=".25"/></linearGradient>
      </defs>
      <rect x="10" y="10" width="108" height="108" rx="26" fill="url(#bg1)"/>
      <rect x="30" y="34" width="68" height="62" rx="9" fill="none" stroke="url(#gl1)" stroke-width="5"/>
      <path d="M30 52h68" stroke="url(#gl1)" stroke-width="4"/>
      <circle cx="64" cy="74" r="10" fill="#fff" fill-opacity=".9"/>
      <path d="M22 22c18-8 50-8 84 0" stroke="#fff" stroke-opacity=".35" stroke-width="3" fill="none"/>
    </svg>
    """

    func testRegistryPicksSVGRenderer() {
        XCTAssertTrue(RendererRegistry.renderer(for: .svg) is SVGRenderer)
        XCTAssertEqual(FileSniffer.kind(of: URL(fileURLWithPath: "/nonexistent/badge.svg")), .svg)
    }

    func testDrawsThePictureWithItsFacts() async throws {
        let (preview, view) = try await render(try write("badge-glass.svg", badge))
        let doc = preview.document
        XCTAssertEqual(doc.viewTitles, ["Picture", "Source"])
        XCTAssertTrue(view.showsPicture)
        XCTAssertNotNil(view.picture?.webView, "the picture is drawn")
        XCTAssertEqual(doc.fact("headline")?.value, "128 × 128 · no scripts")
        XCTAssertEqual(doc.fact("viewBox")?.value, "128 × 128")
        XCTAssertEqual(doc.fact("elements")?.value, "14")
        XCTAssertEqual(doc.fact("scripts")?.value, "0")
        XCTAssertEqual(doc.fact("externalRefs")?.value, "0")
        XCTAssertTrue(doc.badges.isEmpty)
        XCTAssertEqual(preview.gutter?.leading, "14 elements · 0 external refs")

        let capsule = CapsuleModel()
        capsule.show(doc, canToggleInspector: true, canFind: true)
        XCTAssertTrue(capsule.pillText.hasPrefix("SVG · 128 × 128 · no scripts · "), capsule.pillText)
        XCTAssertEqual(capsule.viewTitles, ["Picture", "Source"])

        XCTAssertEqual(view.inspector.rows.map(\.label), ["viewBox", "Size", "Elements", "Scripts", "External refs"])
        XCTAssertEqual(view.picture?.canvas.background, .checker)
    }

    func testThePageIsLockedDown() async throws {
        let (_, view) = try await render(try write("badge.svg", badge))
        let web = try XCTUnwrap(view.picture?.webView)
        XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript, "the page's JavaScript is off")
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
        let page = SVGPicture.page(for: Data(badge.utf8), padding: 32)
        XCTAssertTrue(page.contains("default-src 'none'; img-src data:;"), "the CSP allows only inline data images")
        XCTAssertTrue(page.contains("<img alt=\"\" src=\"data:image/svg+xml;base64,"), "the file is drawn as an image, never as a page")
    }

    /// Every way an SVG can reach out — a script, an onload handler, `<image href>` and `xlink:href`, `<use>` of
    /// another file, `<foreignObject>` HTML, `<feImage>`, CSS `@import` and `url()`, an `xml-stylesheet` instruction —
    /// aimed at a local listener. Controls first: the listener hears a direct request, and it hears WebKit when the same
    /// file is opened as an unlocked page with JavaScript on. Then Vitrine's preview of it must leave it silent.
    func testAScriptNeverRunsAndNothingIsFetched() async throws {
        let sink = try Listener()
        await fulfillment(of: [sink.ready], timeout: 5)
        let base = "http://127.0.0.1:\(sink.port)"
        let hostile = """
        <?xml version="1.0"?>
        <?xml-stylesheet type="text/css" href="\(base)/pi.css"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="200" height="200" viewBox="0 0 200 200"
             onload="fetch('\(base)/onload')">
          <style>@import url("\(base)/import.css"); rect.bg { fill: url("\(base)/paint.svg#p"); }</style>
          <script>new Image().src = "\(base)/script"; fetch("\(base)/script-fetch");</script>
          <rect width="200" height="200" fill="#E9E9EE"/>
          <rect class="bg" x="10" y="10" width="40" height="40"/>
          <image href="\(base)/image.png" x="60" y="10" width="60" height="60"/>
          <image xlink:href="\(base)/image-xlink.png" x="130" y="10" width="60" height="60"/>
          <use href="\(base)/sprite.svg#icon" x="10" y="80"/>
          <foreignObject x="10" y="120" width="180" height="70"><div xmlns="http://www.w3.org/1999/xhtml"><img src="\(base)/fo.png"/>hello</div></foreignObject>
          <filter id="fi"><feImage href="\(base)/feimage.png"/></filter>
          <circle cx="150" cy="150" r="30" fill="#0A60D8" filter="url(#fi)" onclick="fetch('\(base)/click')"/>
          <a href="javascript:fetch('\(base)/link')"><circle cx="100" cy="100" r="10" fill="#FF3B30"/></a>
        </svg>
        """
        let url = try write("hostile.svg", hostile)

        // Control 1: the listener accepts a direct connection.
        _ = try? await URLSession.shared.data(from: URL(string: "\(base)/control")!)
        for _ in 0..<40 where sink.count == 0 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertGreaterThanOrEqual(sink.count, 1, "control: the listener must accept a direct connection")
        try await Task.sleep(for: .milliseconds(300))
        var baseline = sink.count

        // Control 2: the same bytes opened as an unlocked page, JavaScript on, do reach it.
        let open = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: WKWebViewConfiguration())
        open.load(Data(hostile.utf8), mimeType: "image/svg+xml", characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
        for _ in 0..<120 where sink.count == baseline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertGreaterThan(sink.count, baseline, "control: an unlocked page must be heard, or this test proves nothing")
        open.stopLoading()
        try await Task.sleep(for: .milliseconds(800))
        baseline = sink.count

        // The preview: drawn, warned about, and silent.
        let (preview, view) = try await render(url)
        XCTAssertEqual(preview.document.viewTitles, ["Picture", "Source"])
        XCTAssertNotNil(view.picture?.webView)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(sink.count, baseline, "the preview must not run the script or fetch anything the file points at")

        let titles = preview.document.badges.map(\.title)
        XCTAssertEqual(titles, ["Script inside · not run", "External references · not loaded", "Embedded HTML"])
        XCTAssertEqual(preview.document.badges.first?.level, .danger)
        XCTAssertEqual(preview.document.fact("scripts")?.value, "4")       // <script>, onload, onclick, javascript:
        // pi.css, import.css, paint.svg, image.png, image-xlink.png, sprite.svg, fo.png, feimage.png
        XCTAssertEqual(preview.document.fact("externalRefs")?.value, "8")
        XCTAssertEqual(preview.document.fact("headline")?.value, "200 × 200 · scripts not run")
        XCTAssertEqual(view.inspector.warningTitles, titles)
        let capsule = CapsuleModel()
        capsule.show(preview.document, canToggleInspector: true, canFind: true)
        XCTAssertEqual(capsule.dotToken, "danger")
    }

    func testAMalformedFileOpensOnSourceWithABadge() async throws {
        let (preview, view) = try await render(try write("broken.svg", """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
          <rect x="10" y="10" width="80" height="80" fill="#13A38C">
          <circle cx="50" cy="50" r="20"/>
        </svg>
        """))
        XCTAssertEqual(preview.document.viewTitles, ["Source"])
        XCTAssertFalse(view.showsPicture)
        XCTAssertNil(view.picture)
        let badge = try XCTUnwrap(preview.document.badges.first)
        XCTAssertEqual(badge.title, "Not well-formed XML")
        XCTAssertEqual(badge.level, .caution)
        XCTAssertTrue(badge.detail.hasPrefix("Line 4, column 1: </svg> where </rect> was expected"), badge.detail)
        XCTAssertNotNil(view.sourceTextViewForTesting, "the source is on screen")
        XCTAssertEqual(preview.showView?(0), true)
    }

    func testANonSVGRootIsSaidSo() async throws {
        let (preview, _) = try await render(try write("page.svg", "<html><body>not a picture</body></html>"))
        XCTAssertEqual(preview.document.viewTitles, ["Source"])
        XCTAssertEqual(preview.document.badges.first?.title, "Not an SVG")
    }

    func testTooDeepOpensOnSourceWithoutWaiting() async throws {
        let depth = 20_000
        let deep = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\">" + String(repeating: "<g>", count: depth)
            + "<rect width=\"5\" height=\"5\"/>" + String(repeating: "</g>", count: depth) + "</svg>"
        let start = Date()
        let (preview, view) = try await render(try write("deep.svg", deep))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "a deep file must not hold up the first paint")
        XCTAssertEqual(preview.document.viewTitles, ["Source"])
        XCTAssertNil(view.picture)
        XCTAssertEqual(preview.document.badges.first?.title, "Nested too deeply to draw")
    }

    func testManyElementsStillDrawWithinTheBudget() async throws {
        var many = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1000 1000\">"
        for i in 0..<100_000 { many += "<rect x=\"\(i % 1000)\" y=\"\((i / 1000) * 10)\" width=\"1\" height=\"8\" fill=\"#13A38C\"/>" }
        many += "</svg>"
        let start = Date()
        let (preview, _) = try await render(try write("many.svg", many))
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        XCTAssertEqual(preview.document.fact("elements")?.value, 100_001.formatted())
    }

    func testViewBoxOnlyAndMissingNamespaceStillDraw() async throws {
        let (preview, view) = try await render(try write("bare.svg", ##"<svg viewBox="0 0 300 150"><use xlink:href="#c"/><circle id="c" cx="75" cy="75" r="40" fill="#B07A2A"/></svg>"##))
        XCTAssertEqual(preview.document.viewTitles, ["Picture", "Source"])
        XCTAssertNotNil(view.picture?.webView, "the namespaces a browser needs are added for drawing")
        XCTAssertEqual(preview.document.fact("headline")?.value, "300 × 150 · no scripts")
    }

    func testSourceIsColouredAsXML() async throws {
        let (preview, view) = try await render(try write("badge.svg", badge))
        XCTAssertEqual(preview.showView?(1), true)
        XCTAssertFalse(view.showsPicture)
        let textView = try XCTUnwrap(view.sourceTextViewForTesting)
        let text = textView.string as NSString
        let storage = try XCTUnwrap(textView.textStorage)
        // Dynamic colours compare by what they resolve to.
        func rgba(_ c: NSColor?) -> [Int] {
            var out: [Int] = []
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                if let s = c?.usingColorSpace(.sRGB) { out = [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent].map { Int(($0 * 255).rounded()) } }
            }
            return out
        }
        func colour(of piece: String) -> [Int] {
            rgba(storage.attribute(.foregroundColor, at: text.range(of: piece).location, effectiveRange: nil) as? NSColor)
        }
        XCTAssertEqual(colour(of: "linearGradient"), rgba(NSColor.token("syn-kw")))
        XCTAssertEqual(colour(of: "viewBox"), rgba(NSColor.token("syn-attr")))
        XCTAssertEqual(colour(of: "\"0 0 128 128\""), rgba(NSColor.token("syn-str")))
        XCTAssertNotEqual(rgba(NSColor.token("syn-kw")), rgba(NSColor.token("syn-str")))

        // Find searches the source.
        let found = await preview.find?("rect", true)
        XCTAssertEqual(found?.count, 2)
        XCTAssertEqual(preview.showView?(0), true)
        XCTAssertTrue(view.showsPicture)
    }

    func testBackgroundChoiceIsRememberedAndInspectorToggles() async throws {
        let (preview, view) = try await render(try write("badge.svg", badge))
        view.inspector.select(.dark)
        XCTAssertEqual(view.picture?.canvas.background, .dark)
        XCTAssertEqual(VitrineDefaults.defaults(suite: suite).integer(forKey: SVGBackground.key), SVGBackground.dark.rawValue)
        let (_, again) = try await render(try write("again.svg", badge))
        XCTAssertEqual(again.picture?.canvas.background, .dark, "the next SVG opens on the picked ground")

        XCTAssertTrue(view.inspectorShown)
        preview.toggleInspector?()
        XCTAssertFalse(view.inspectorShown)
        XCTAssertTrue(view.inspector.isHidden)
        preview.toggleInspector?()
        XCTAssertTrue(view.inspectorShown)
        VitrineDefaults.defaults(suite: suite).removePersistentDomain(forName: suite)
    }
}
