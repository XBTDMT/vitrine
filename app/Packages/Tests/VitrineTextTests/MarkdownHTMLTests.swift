import XCTest
@testable import VitrineText

final class MarkdownHTMLTests: XCTestCase {
    func testHeadingAndParagraph() {
        let html = MarkdownHTML.render("# Title\n\nHello *world*.")
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<em>world</em>"))
    }

    func testGFMTable() {
        let html = MarkdownHTML.render("| a | b |\n|---|---|\n| 1 | 2 |")
        XCTAssertTrue(html.contains("<table>"), html)
        XCTAssertTrue(html.contains("<td>1</td>"), html)
    }

    func testTaskListAndStrikethrough() {
        let html = MarkdownHTML.render("- [x] done\n- [ ] todo\n\n~~gone~~")
        XCTAssertTrue(html.contains("type=\"checkbox\""), html)
        XCTAssertTrue(html.contains("<del>gone</del>"), html)
    }

    func testAutolink() {
        let html = MarkdownHTML.render("see https://example.com now")
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">"), html)
    }

    func testFootnotes() {
        let html = MarkdownHTML.render("Text[^1]\n\n[^1]: The note")
        XCTAssertTrue(html.contains("footnote"), html)
    }

    func testFrontMatterHidden() {
        let html = MarkdownHTML.render("---\ntitle: x\n---\n# Body")
        XCTAssertFalse(html.contains("title: x"))
        XCTAssertTrue(html.contains("<h1>Body</h1>"))
    }

    func testFrontMatterKeptWhenOptionOff() {
        var o = MarkdownHTML.Options(); o.hideFrontMatter = false
        let html = MarkdownHTML.render("---\ntitle: x\n---\n# Body", options: o)
        XCTAssertTrue(html.contains("title: x"))
    }

    func testHeadingIDsAndTOC() {
        let html = MarkdownHTML.addHeadingIDs(MarkdownHTML.render("# One\n\n## Two words\n\n## Two words"))
        XCTAssertTrue(html.contains("<h1 id=\"one\">"), html)
        XCTAssertTrue(html.contains("<h2 id=\"two-words\">"), html)
        XCTAssertTrue(html.contains("<h2 id=\"two-words-1\">"), html)
        let toc = MarkdownHTML.headings(in: html)
        XCTAssertEqual(toc.map(\.id), ["one", "two-words", "two-words-1"])
        XCTAssertEqual(toc.map(\.level), [1, 2, 2])
    }

    func testRawHTMLPassesThroughForImages() {
        let html = MarkdownHTML.render("<img src=\"a.png\">")
        XCTAssertTrue(html.contains("<img src=\"a.png\">"))
    }
}
