import XCTest
import WebKit
@testable import VitrinePreviewKit
import VitrineDocument

/// D1: the Glass Capsule frame under every preview — the pill, coverage, copy, the viewer switch and the column toggle.
@MainActor
final class CapsuleTests: XCTestCase {
    private func doc(views: [DocumentView] = [.text("hello")], coverage: Coverage = .complete) -> PreviewDocument {
        PreviewDocument(kind: .markdown(.commonMark),
                        facts: [Fact(key: "size", label: "Size", value: "4 KB"), Fact(key: "tokens", label: "Tokens", value: "≈ 890")],
                        views: views, coverage: coverage)
    }

    func testPillAndCoverage() {
        let m = CapsuleModel()
        m.show(doc(), canToggleInspector: false, canFind: false)
        XCTAssertEqual(m.pillText, "Markdown · 4 KB · ≈ 890 tok")
        XCTAssertEqual(m.pillDetail, "Size: 4 KB\nTokens: ≈ 890")
        XCTAssertNil(m.coverageText, "a complete document says nothing in the gutter")
        m.show(doc(coverage: .partial(shown: 1_048_576, total: 12_582_912, unit: .bytes, reason: "Large file")), canToggleInspector: false, canFind: false)
        XCTAssertEqual(m.coverageText, "Showing 1 MB of 12.6 MB")
        m.show(doc(coverage: .partial(shown: 50_000, total: nil, unit: .rows, reason: "Large table")), canToggleInspector: false, canFind: false)
        XCTAssertEqual(m.coverageText, "Showing the first 50,000 rows")
    }

    func testCopyPutsTheTextOnThePasteboard() {
        let m = CapsuleModel()
        m.pasteboard = NSPasteboard(name: NSPasteboard.Name("vt-test-\(UUID().uuidString)"))
        m.show(doc(views: [.markdown(MarkdownContent(html: "<p>x</p>", headings: [])), .text("# Source")]), canToggleInspector: false, canFind: false)
        m.copy()
        XCTAssertEqual(m.pasteboard.string(forType: .string), "# Source", "Markdown copies its source")
        XCTAssertTrue(m.copied)
        m.pasteboard.releaseGlobally()
    }

    func testViewerSwitchShowsTheSourceInTheController() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.md")
        try "# One\n\n## Two\n\n## Three\n".write(to: url, atomically: true, encoding: .utf8)
        let c = PreviewHostController()
        c.loadView()
        c.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        try await c.preparePreviewOfFile(at: url)
        c.view.layoutSubtreeIfNeeded()
        let web = try XCTUnwrap(c.view.allSubviews.compactMap { $0 as? WKWebView }.first)
        XCTAssertEqual(c.capsuleForTesting.viewTitles, ["Rendered", "Source"])
        XCTAssertTrue(c.capsuleForTesting.canToggleInspector, "three headings: the column can be toggled")
        XCTAssertEqual(web.frame.maxY, 600 - 56, accuracy: 1, "the preview ends where the 56 pt gutter starts")

        c.capsuleForTesting.selectView(1)
        XCTAssertTrue(web.isHidden)
        let source = try XCTUnwrap(c.view.allSubviews.compactMap { $0 as? NSTextView }.first { !$0.enclosingScrollView!.isHidden })
        XCTAssertEqual(source.string, "# One\n\n## Two\n\n## Three\n")
        c.capsuleForTesting.selectView(0)
        XCTAssertFalse(web.isHidden)
        XCTAssertNil(c.view.allSubviews.compactMap { $0 as? NSTextView }.first, "the source view is gone again")
    }

    func testNarrowPanelGetsTheCompactGutter() async throws {
        let c = PreviewHostController()
        c.loadView()
        c.view.frame = NSRect(x: 0, y: 0, width: 300, height: 500)
        c.view.layoutSubtreeIfNeeded()
        c.viewDidLayout()
        c.view.layoutSubtreeIfNeeded()
        let gutter = try XCTUnwrap(c.view.subviews.last)
        XCTAssertEqual(gutter.frame.height, 40, accuracy: 0.5)
    }

    func testFindInTheRenderedPageAndTheSource() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-find-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("f.md")
        try "# Sync\n\nSync once, **sync** twice.\n\n```\nsync()\n```\n".write(to: url, atomically: true, encoding: .utf8)
        let c = PreviewHostController()
        c.loadView()
        c.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        try await c.preparePreviewOfFile(at: url)
        try await Task.sleep(for: .milliseconds(250))
        let m = c.capsuleForTesting
        XCTAssertTrue(m.canFind)
        m.openFind()
        m.findQuery = "sync"
        await m.find()
        XCTAssertEqual(m.findResult, FindResult(count: 4, index: 0), "heading, two in the paragraph, one in code")
        XCTAssertEqual(m.findCountText, "1 of 4")
        await m.find(forward: false)
        XCTAssertEqual(m.findCountText, "4 of 4", "back from the first wraps to the last")
        let web = try XCTUnwrap(c.view.allSubviews.compactMap { $0 as? WKWebView }.first)
        let marks = try await web.evaluateJavaScript("document.querySelectorAll('mark.vt-find').length") as? Int
        XCTAssertEqual(marks, 4)
        m.closeFind()
        try await Task.sleep(for: .milliseconds(100))
        let after = try await web.evaluateJavaScript("document.querySelectorAll('mark.vt-find').length") as? Int
        XCTAssertEqual(after, 0, "closing find removes every mark")
        let text = try await web.evaluateJavaScript("document.getElementById('body').innerText.includes('Sync once, sync twice.')") as? Bool
        XCTAssertEqual(text, true, "the page text is unchanged")

        m.selectView(1)
        m.openFind()
        m.findQuery = "SYNC"
        await m.find()
        XCTAssertEqual(m.findResult?.count, 4, "the source: # Sync, Sync, **sync**, sync() — case-insensitive")
        m.findQuery = "nothing here"
        await m.find()
        XCTAssertEqual(m.findCountText, "No matches")
    }
}
