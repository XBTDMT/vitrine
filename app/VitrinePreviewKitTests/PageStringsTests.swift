import XCTest
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineSupport

/// The web previews' words come from Swift (H-6): one JSON data block per page, read by the page's own script, and
/// every key a page asks for exists in Swift's table. Tests run in English. roadmap: S-12
@MainActor
final class PageStringsTests: XCTestCase {
    /// Counted phrases reach the page as one template per plural category, from the framework's own catalog: the
    /// English singular proves the lookup went through VitrinePreviewKit's String Catalog, not the host's.
    func testCountedPhrasesArriveAsPluralTemplates() throws {
        let lines = try XCTUnwrap(PageStrings.code["code.linesWithoutMatch"] as? [String: String])
        XCTAssertEqual(lines["one"], "{n} line without a match")
        XCTAssertEqual(lines["other"], "{n} lines without a match")
        let images = try XCTUnwrap(PageStrings.markdown["md.imagesNotLoaded"] as? [String: String])
        XCTAssertEqual(images["one"], "{n} image is not loaded")
        XCTAssertEqual(images["other"], "{n} images are not loaded")
    }

    /// Swift's own count phrases take the English singular from the catalog too.
    func testSwiftCountPhrasesUseTheCatalogsPluralForms() {
        XCTAssertEqual(FamilyFacts.items(1), "1 item")
        XCTAssertEqual(FamilyFacts.items(1_204), "1,204 items")
        XCTAssertEqual(QueryOutcome(rows: 1, milliseconds: 5).summary, "1 row · 5 ms")
        XCTAssertEqual(QueryOutcome(rows: 1, milliseconds: 5, unit: .results).summary, "1 result · 5 ms")
    }

    /// A data block, never a script that runs (the pages' CSP refuses inline scripts); nothing in it can end it early.
    func testTheBlockIsAJSONDataBlockThatCannotEndEarly() throws {
        let block = PageStrings.block(["x": "</script><script>alert(1)</script>"])
        XCTAssertTrue(block.hasPrefix("<script type=\"application/json\" id=\"vt-strings\">"), block)
        XCTAssertTrue(block.hasSuffix("</script>"))
        let json = block.dropFirst("<script type=\"application/json\" id=\"vt-strings\">".count).dropLast("</script>".count)
        XCTAssertFalse(json.contains("<"), "every < is escaped")
        let table = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(table["x"] as? String, "</script><script>alert(1)</script>")
        XCTAssertEqual(table["_lang"] as? String, "en")
        XCTAssertNotNil(table["_locale"] as? String)
    }

    /// Each page carries its block before the scripts that read it.
    func testEveryPageCarriesItsStrings() throws {
        let code = CodeRenderer.page(text: "let a = 1\n", language: "swift", context: RenderContext(appearance: .light))
        XCTAssertLessThan(try XCTUnwrap(code.range(of: "id=\"vt-strings\"")).lowerBound, try XCTUnwrap(code.range(of: "code/code.js")).lowerBound)
        XCTAssertTrue(code.contains("\"code.reopenAs\""))

        let document = PreviewDocument(kind: .markdown(.commonMark), views: [.markdown(MarkdownContent(html: "<p>hi</p>", headings: []))])
        let markdown = MarkdownRenderer.buildPage(for: document, context: RenderContext(appearance: .light))
        XCTAssertFalse(markdown.contains("<!--VT_STRINGS-->"))
        XCTAssertLessThan(try XCTUnwrap(markdown.range(of: "id=\"vt-strings\"")).lowerBound,
                          try XCTUnwrap(markdown.range(of: "vitrine://app/markdown.js")).lowerBound)
        XCTAssertTrue(markdown.contains("script-src vitrine: 'wasm-unsafe-eval'"), "the page CSP still refuses inline scripts")
    }

    /// Every key a page script asks for (`t('key'`, `tn('key'`) is in the table Swift gives that page, so no page
    /// silently falls back to English.
    func testEveryKeyThePagesAskForIsInSwiftsTable() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let pages: [(files: [String], table: PageStrings.Table)] = [
            (["web-src/code/code-entry.js", "web-src/code/appearance.js", "web-src/code/log.js"], PageStrings.code),
            (["web-src/code/diff-entry.js"], PageStrings.diff),
            (["VitrinePreviewKit/Resources/web/markdown.js"], PageStrings.markdown),
            (["VitrinePreviewKit/Resources/web/notebook.js"], PageStrings.notebook),
        ]
        let pattern = try NSRegularExpression(pattern: #"\btn?\('([a-zA-Z.]+)'"#)
        var asked = 0
        for page in pages {
            for file in page.files {
                let source = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
                for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    let key = String(source[Range(match.range(at: 1), in: source)!])
                    asked += 1
                    XCTAssertNotNil(page.table[key], "\(file) asks for \(key), which Swift does not send")
                }
            }
        }
        XCTAssertGreaterThan(asked, 60, "the scan found the pages' lookups")
    }
}
