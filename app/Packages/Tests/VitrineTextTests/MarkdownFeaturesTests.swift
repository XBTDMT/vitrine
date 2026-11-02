import XCTest
@testable import VitrineText

/// S-4: alerts, emoji and math, through the pure HTML pipeline.
final class MarkdownFeaturesTests: XCTestCase {
    func testAlertBlockBecomesTitledDiv() {
        let html = MarkdownHTML.render("> [!WARNING]\n> Mind the gap.\n")
        XCTAssertTrue(html.contains("<div class=\"alert alert-warning\""), html)
        XCTAssertTrue(html.contains("<p class=\"alert-title\">Warning</p>"), html)
        XCTAssertTrue(html.contains("Mind the gap."), html)
        XCTAssertFalse(html.contains("[!WARNING]"), html)
        XCTAssertFalse(html.contains("<blockquote>"), html)
    }

    func testAlertWithMarkerOnItsOwnLine() {
        let html = MarkdownHTML.render("> [!TIP]\n>\n> Two paragraphs.\n>\n> Second.\n")
        XCTAssertTrue(html.contains("alert-tip"), html)
        XCTAssertTrue(html.contains("<p>Two paragraphs.</p>"), html)
        XCTAssertTrue(html.contains("<p>Second.</p>"), html)
    }

    func testOrdinaryBlockquoteUntouched() {
        let html = MarkdownHTML.render("> just a quote\n")
        XCTAssertTrue(html.contains("<blockquote>"), html)
    }

    func testEmojiShortcodesOutsideCodeOnly() {
        let html = MarkdownHTML.render("I :heart: it `:heart:`\n\n```\n:tada:\n```\n")
        XCTAssertTrue(html.contains("I \u{2764}\u{FE0F} it"), html)
        XCTAssertTrue(html.contains("<code>:heart:</code>"), html)
        XCTAssertTrue(html.contains(":tada:\n</code>"), html)
    }

    func testUnknownShortcodeLeftAlone() {
        XCTAssertTrue(MarkdownHTML.render("time 10:30:45 :not_a_real_code:").contains(":not_a_real_code:"))
    }

    func testInlineAndDisplayMath() {
        let html = MarkdownHTML.render("Euler: $e^{i\\pi}+1=0$ and\n\n$$\n\\int_0^1 x_1 * x_2\\,dx\n$$\n")
        XCTAssertTrue(html.contains("<span class=\"math math-inline\">e^{i\\pi}+1=0</span>"), html)
        XCTAssertTrue(html.contains("<div class=\"math math-display\">"), html)
        XCTAssertTrue(html.contains("x_1 * x_2"), html)          // underscores and star survived cmark
        XCTAssertFalse(html.contains("<p><div"), html)
    }

    func testDollarsThatAreNotMath() {
        let html = MarkdownHTML.render("costs $5 and $10 today; `$x$` in code\n\n```\n$$ not math $$\n```\n")
        XCTAssertFalse(html.contains("class=\"math"), html)
        XCTAssertTrue(html.contains("costs $5 and $10"), html)
        XCTAssertTrue(html.contains("<code>$x$</code>"), html)
    }

    func testMathOff() {
        var o = MarkdownHTML.Options(); o.math = false
        XCTAssertFalse(MarkdownHTML.render("$a_b$", options: o).contains("class=\"math"))
    }

    func testUnicodeHeadingSlug() {
        let html = MarkdownHTML.addHeadingIDs(MarkdownHTML.render("## Café résumé 2"))
        XCTAssertTrue(html.contains("id=\"café-résumé-2\""), html)
    }
}
