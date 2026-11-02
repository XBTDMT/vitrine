import XCTest
@testable import VitrineText
import VitrineDocument

final class MarkdownDocumentTests: XCTestCase {
    private func file(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testMarkdownDocumentHasRenderedThenSource() throws {
        let text = "# Title\n\nSome words here.\n\n## Part\n"
        let doc = try MarkdownDocument.make(url: try file("a.md", text), kind: .markdown(.commonMark), options: .init())
        XCTAssertEqual(doc.views.count, 2)
        guard case .markdown(let m) = doc.views[0] else { return XCTFail("rendered view first") }
        XCTAssertEqual(m.headings.map(\.text), ["Title", "Part"])
        XCTAssertTrue(m.html.contains("<h2 id=\"part\">"), m.html)
        XCTAssertEqual(doc.views[1], .text(text))
        XCTAssertEqual(doc.fact("words")?.value, "5", "Title, Some, words, here., Part; the # marks are not words")
        XCTAssertEqual(doc.fact("readingTime")?.value, "1 min")
        XCTAssertNotNil(doc.fact("size"))
        XCTAssertTrue(doc.coverage.isComplete)
    }

    func testWordCountIgnoresMarkup() {
        XCTAssertEqual(MarkdownDocument.wordCount(html: "<table><tr><td>a</td><td>|</td></tr></table><p>- b — c</p>"), 3)
        XCTAssertEqual(MarkdownDocument.wordCount(html: ""), 0)
    }

    func testLatin1MarkdownStillPreviews() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("l.md")
        try Data([0x23, 0x20, 0x43, 0x61, 0x66, 0xE9]).write(to: url)   // "# Café" in Latin-1
        let doc = try MarkdownDocument.make(url: url, kind: .markdown(.commonMark), options: .init())
        XCTAssertEqual(doc.searchText, "# Café")
    }

    func testImageLinkAndTokenFacts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-refs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("here.md"), atomically: true, encoding: .utf8)
        let text = """
        # Refs

        ![local](pic.png) ![remote](https://ci.example.com/badge.svg)

        [ok](here.md) [ok with anchor](here.md#part) [gone](gone.md) [space](my%20notes.md) [web](https://example.com)
        [mail](mailto:a@example.com) [jump](#refs)
        """
        let url = dir.appendingPathComponent("readme.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let doc = try MarkdownDocument.make(url: url, kind: .markdown(.commonMark), options: .init())
        XCTAssertEqual(doc.fact("images")?.value, "2")
        XCTAssertEqual(doc.fact("remoteImages")?.value, "1")
        XCTAssertEqual(doc.fact("links")?.value, "6", "the in-page anchor is not a link out")
        XCTAssertEqual(doc.fact("missingLinks")?.value, "2", "gone.md and my notes.md")
        XCTAssertEqual(doc.fact("encoding")?.value, "UTF-8")
        XCTAssertEqual(doc.fact("tokens")?.value, "≈ \((text.utf8.count + 2) / 4)")
        XCTAssertEqual(doc.facts.map(\.key), ["words", "readingTime", "size", "encoding", "images", "remoteImages",
                                               "links", "missingLinks", "tokens"])
    }
}
