import XCTest
@testable import VitrineDocument
import VitrineSupport

final class PreviewDocumentTests: XCTestCase {
    private func sample() -> PreviewDocument {
        PreviewDocument(
            kind: .markdown(.commonMark),
            facts: [Fact(key: "size", label: "Size", value: "2 KB"), Fact(key: "words", label: "Words", value: "312")],
            badges: [Badge(level: .caution, title: "Remote images", detail: "3 images load from the web", evidence: 120..<180)],
            views: [.markdown(MarkdownContent(html: "<h1 id=\"a\">A</h1><p>Hello <b>there</b></p>",
                                              headings: [.init(level: 1, text: "A", id: "a")])),
                    .text("# A\n\nHello **there**")],
            coverage: .complete)
    }

    func testJSONRoundTrip() throws {
        let doc = sample()
        let data = try JSONEncoder().encode(doc)
        XCTAssertEqual(try JSONDecoder().decode(PreviewDocument.self, from: data), doc)
        let partial = PreviewDocument(kind: .plainText, views: [.text("x")],
                                      coverage: .partial(shown: 1_048_576, total: nil, unit: .bytes, reason: "Large file"))
        XCTAssertEqual(try JSONDecoder().decode(PreviewDocument.self, from: JSONEncoder().encode(partial)), partial)
    }

    func testJSONCarriesTheKindIdentifier() throws {
        let json = String(decoding: try JSONEncoder().encode(sample()), as: UTF8.self)
        XCTAssertTrue(json.contains(#""kind":"markdown.commonMark""#), json)
    }

    func testSearchTextPrefersSource() {
        XCTAssertEqual(sample().searchText, "# A\n\nHello **there**")
        let renderedOnly = PreviewDocument(kind: .markdown(.commonMark),
                                           views: [.markdown(MarkdownContent(html: "<p>Hello <b>there</b></p>", headings: []))])
        XCTAssertEqual(renderedOnly.searchText, "Hello there")
    }

    func testFactsAndLevels() {
        XCTAssertEqual(sample().fact("words")?.value, "312")
        XCTAssertNil(sample().fact("rows"))
        XCTAssertLessThan(Badge.Level.info, .caution)
        XCTAssertLessThan(Badge.Level.caution, .danger)
        XCTAssertEqual(sample().primaryView.title, "Rendered")
    }
}
