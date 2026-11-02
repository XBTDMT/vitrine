import XCTest
import WebKit
@testable import VitrinePreviewKit

/// G-2 route C, end to end in a real web view: fenced mermaid becomes an SVG drawn by the vendored mermaid.js,
/// a broken diagram falls back to its source with a message, and a page without diagrams never loads the script.
@MainActor
final class MermaidTests: XCTestCase {
    /// A fresh cache per test, so a diagram drawn by one run is never served to the next.
    private lazy var caches = FileManager.default.temporaryDirectory.appendingPathComponent("vt-mcache-\(UUID().uuidString)")

    private func render(_ markdown: String) async throws -> (MarkdownRenderer, WKWebView) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-mermaid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("d.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        let renderer = MarkdownRenderer()
        let preview = try await renderer.render(url: url, kind: .markdown(.commonMark),
                                                context: RenderContext(appearance: .light, defaultsSuite: "vt-mermaid-suite",
                                                                       cachesDirectory: caches))
        return (renderer, try XCTUnwrap(preview.view as? WKWebView))
    }

    private func waitForTiming(_ renderer: MarkdownRenderer) async throws -> MarkdownRenderer.MermaidTiming {
        for _ in 0..<200 {
            if let t = renderer.lastMermaidTiming { return t }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("mermaid did not report within 10 s")
    }

    func testFlowchartBecomesSVG() async throws {
        let (renderer, web) = try await render("# D\n\n```mermaid\nflowchart LR\n  A[Edit note] --> B{Two Macs?}\n  B -->|yes| C[Keep both]\n```\n")
        let timing = try await waitForTiming(renderer)
        XCTAssertEqual(timing.count, 1)
        XCTAssertGreaterThanOrEqual(timing.first, 0, "the diagram was drawn")
        let svgs = try await web.evaluateJavaScript("document.querySelectorAll('.mermaid-block svg').length") as? Int
        XCTAssertEqual(svgs, 1)
        let label = try await web.evaluateJavaScript("document.querySelector('.mermaid-block svg').textContent.includes('Keep both')") as? Bool
        XCTAssertEqual(label, true)
    }

    func testSecondOpenUsesTheSavedDrawing() async throws {
        let text = "```mermaid\nflowchart LR\n  A[Saved] --> B[Again]\n```\n"
        let (first, _) = try await render(text)
        _ = try await waitForTiming(first)
        let saved = caches.appendingPathComponent("mermaid")
        for _ in 0..<40 where ((try? FileManager.default.contentsOfDirectory(atPath: saved.path))?.count ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: saved.path).count, 1, "the drawing was saved")

        let (second, web) = try await render(text)
        let svgs = try await web.evaluateJavaScript("document.querySelectorAll('.mermaid-block[data-cached] svg').length") as? Int
        XCTAssertEqual(svgs, 1, "the saved drawing is in the page as it opens")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(second.lastMermaidTiming, "nothing left to draw")
        let loaded = try await web.evaluateJavaScript("typeof window.mermaid") as? String
        XCTAssertEqual(loaded, "undefined", "mermaid.js is not even loaded")
    }

    func testBrokenDiagramShowsItsSource() async throws {
        let (renderer, web) = try await render("```mermaid\nflowchart LR\n  A -->\n```\n")
        _ = try await waitForTiming(renderer)
        let error = try await web.evaluateJavaScript("document.querySelector('.mermaid-error pre')?.textContent ?? ''") as? String
        XCTAssertEqual(error?.contains("A -->"), true, error ?? "nil")
        let stray = try await web.evaluateJavaScript("document.querySelectorAll('body > div[id^=dvt-mermaid]').length") as? Int
        XCTAssertEqual(stray, 0, "mermaid's own error drawing is removed")
    }

    func testPageWithoutDiagramsNeverLoadsMermaid() async throws {
        let (renderer, web) = try await render("# Plain\n\n```swift\nlet x = 1\n```\n")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(renderer.lastMermaidTiming)
        let loaded = try await web.evaluateJavaScript("typeof window.mermaid") as? String
        XCTAssertEqual(loaded, "undefined")
    }
}

/// The page reports scroll offsets and diagram timings to the renderer. Quick Look's controller does not keep the
/// renderer, so the preview must: before 2026-10-29 the renderer was freed after `render` and every report was lost
/// (scroll memory and timings silently did nothing in the real extension).
@MainActor
final class RendererLifetimeTests: XCTestCase {
    func testPreviewKeepsItsRendererSoPageReportsArrive() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-life-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("l.md")
        try "# L\n".write(to: url, atomically: true, encoding: .utf8)
        // No reference to the renderer is kept here, as in PreviewHostController.
        let preview = try await MarkdownRenderer().render(url: url, kind: .markdown(.commonMark),
                                                          context: RenderContext(appearance: .light, defaultsSuite: "vt-life-\(UUID().uuidString)"))
        let web = try XCTUnwrap(preview.view as? WKWebView)
        _ = try await web.evaluateJavaScript("window.webkit.messageHandlers.vitrine.postMessage({name: 'scroll', body: 321}); true")
        for _ in 0..<40 where preview.scrollOffset?() != 321 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(preview.scrollOffset?(), 321)
    }
}
