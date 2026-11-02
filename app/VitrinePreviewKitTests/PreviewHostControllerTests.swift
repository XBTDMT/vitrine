import XCTest
import WebKit
@testable import VitrinePreviewKit

/// End-to-end through the real controller: sniff → renderer → embedded view, on real files.
@MainActor
final class PreviewHostControllerTests: XCTestCase {
    private func sample(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testMarkdownRendersIntoWebView() async throws {
        let url = try sample("doc.md", "---\ntitle: hidden\n---\n# Heading One\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n")
        let controller = PreviewHostController()
        controller.loadView()
        try await controller.preparePreviewOfFile(at: url)
        let web = controller.view.allSubviews.compactMap { $0 as? WKWebView }.first
        let webView = try XCTUnwrap(web, "Markdown must embed a WKWebView")
        try await Task.sleep(for: .milliseconds(300))   // the veil lifts on the next turn; innerText skips hidden nodes
        let text = try await webView.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertTrue(text?.contains("Heading One") == true, text ?? "nil")
        XCTAssertFalse(text?.contains("title: hidden") == true)
        let tables = try await webView.evaluateJavaScript("document.querySelectorAll('table').length") as? Int
        XCTAssertEqual(tables, 1)
        let checks = try await webView.evaluateJavaScript("document.querySelectorAll('input[type=checkbox]').length") as? Int
        XCTAssertEqual(checks, 1)
        let bg = try await webView.evaluateJavaScript("getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()") as? String
        XCTAssertFalse(bg?.isEmpty ?? true, "design tokens must reach the page")
    }

    /// Plain text draws in the native text view; source code draws in the code view (S-5, G-14).
    func testPlainTextRendersIntoTextViewAndCodeIntoTheCodeView() async throws {
        let text = try sample("notes.txt", "let answer = 42\n")
        let plain = PreviewHostController()
        plain.loadView()
        try await plain.preparePreviewOfFile(at: text)
        let scroll = try XCTUnwrap(plain.view.allSubviews.compactMap { $0 as? NSScrollView }.first)
        let textView = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertEqual(textView.string, "let answer = 42\n")

        CodeRenderer.readyTimeout = .seconds(10)
        defer { CodeRenderer.readyTimeout = .seconds(3) }
        let code = try sample("main.swift", "let answer = 42\n")
        let host = PreviewHostController()
        host.loadView()
        try await host.preparePreviewOfFile(at: code)
        XCTAssertNotNil(host.view.allSubviews.first { $0 is WKWebView }, "Swift opens in the code view")
    }

    func testSecondOpenOfSameFileHitsCache() async throws {
        let url = try sample("cached.md", "# Same\n")
        let a = PreviewHostController(); a.loadView()
        try await a.preparePreviewOfFile(at: url)
        let before = PreviewHostController.cache.count
        let b = PreviewHostController(); b.loadView()
        try await b.preparePreviewOfFile(at: url)
        XCTAssertEqual(PreviewHostController.cache.count, before)
        XCTAssertNotNil(b.view.subviews.first)
    }

    /// An unknown binary opens in the hex inspector (S-5, E-8); it used to have no preview.
    func testUnknownBinaryOpensInTheHexView() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("blob.bin")
        try Data([0, 1, 2, 3]).write(to: url)
        let controller = PreviewHostController(); controller.loadView()
        try await controller.preparePreviewOfFile(at: url)
        XCTAssertNotNil(controller.view.allSubviews.first { $0 is HexView }, "a binary opens in the hex view")
    }
}

@MainActor
final class MarkdownWebFeaturesTests: XCTestCase {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("vt-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Math renders through the vendored KaTeX, a local image next to the file loads, the alert is styled, and the
    /// veil is lifted after load.
    func testKaTeXLocalImageAlertAndReveal() async throws {
        let d = try dir()
        let png = NSImage(size: NSSize(width: 8, height: 8))
        png.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); png.unlockFocus()
        let rep = NSBitmapImageRep(data: png.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: d.appendingPathComponent("pic.png"))
        let url = d.appendingPathComponent("doc.md")
        try "# T\n\n> [!NOTE]\n> hi\n\n$$\\frac{a}{b}$$\n\n![p](pic.png)\n\n:rocket:\n".write(to: url, atomically: true, encoding: .utf8)
        let c = PreviewHostController(); c.loadView()
        c.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        try await c.preparePreviewOfFile(at: url)
        let web = try XCTUnwrap(c.view.allSubviews.compactMap { $0 as? WKWebView }.first)
        try await Task.sleep(for: .milliseconds(400))
        let katex = try await web.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int
        XCTAssertEqual(katex, 1, "KaTeX must have rendered the display block")
        let imgOK = try await web.evaluateJavaScript("(function(){var i=document.querySelector('img');return i&&i.complete&&i.naturalWidth;})()") as? Int
        XCTAssertTrue((imgOK ?? 0) >= 8, "local image beside the file must load (naturalWidth \(imgOK ?? 0))")
        let alert = try await web.evaluateJavaScript("document.querySelectorAll('.alert-note .alert-title').length") as? Int
        XCTAssertEqual(alert, 1)
        let veiled = try await web.evaluateJavaScript("document.getElementById('body').classList.contains('veiled')") as? Bool
        XCTAssertEqual(veiled, false, "article must be revealed after load")
        let text = try await web.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertTrue(text?.contains("\u{1F680}") == true, text ?? "")
    }

    func testThemeSettingReachesPage() async throws {
        let suite = "vt-test-theme-\(UUID().uuidString)"
        let defaults = VitrineDefaults.defaults(suite: suite)
        defaults.set("paper", forKey: MarkdownRenderer.Keys.theme)
        let url = try dir().appendingPathComponent("t.md")
        try "# A\n".write(to: url, atomically: true, encoding: .utf8)
        let r = MarkdownRenderer()
        let preview = try await r.render(url: url, kind: .markdown(.commonMark), context: RenderContext(appearance: .light, defaultsSuite: suite))
        let web = try XCTUnwrap(preview.view as? WKWebView)
        let bg = try await web.evaluateJavaScript("getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()") as? String
        XCTAssertEqual(bg?.uppercased(), MarkdownTheme.theme(id: "paper").spec.light.bg)
        defaults.removePersistentDomain(forName: suite)
    }

    func testSnapshotWritesPNG() async throws {
        let url = try dir().appendingPathComponent("s.md")
        try "# Snapshot\n\nBody text.\n".write(to: url, atomically: true, encoding: .utf8)
        let out = url.deletingLastPathComponent().appendingPathComponent("s.png")
        try await PreviewSnapshot.write(file: url, to: out, size: NSSize(width: 400, height: 300), settleFor: 0.2)
        let data = try Data(contentsOf: out)
        XCTAssertTrue(data.count > 1000)
        XCTAssertEqual([UInt8](data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}

extension NSView {
    /// Every view below this one, depth first: previews sit inside the frame's content area.
    var allSubviews: [NSView] { subviews.flatMap { [$0] + $0.allSubviews } }
}
