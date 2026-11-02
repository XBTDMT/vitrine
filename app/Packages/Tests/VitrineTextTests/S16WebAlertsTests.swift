import XCTest
@testable import VitrineText

/// S-16 F34: a GitHub alert nested in another alert used to make `Alerts.transform` build a negative-length NSRange
/// and kill the preview. Nested and overlapping alerts now render as alerts inside alerts, every range stays inside
/// the string, and a deep nest stays cheap. roadmap: S-16
final class S16WebAlertsTests: XCTestCase {
    /// The shape of the finding: an alert inside an alert (three lines of ordinary GitHub Markdown).
    func testAnAlertInsideAnAlertRendersBothAndDoesNotCrash() {
        let html = MarkdownHTML.render("> [!NOTE]\n> Outer words.\n> > [!WARNING]\n> > Inner words.\n")
        XCTAssertTrue(html.contains("<div class=\"alert alert-note\""), html)
        XCTAssertTrue(html.contains("<div class=\"alert alert-warning\""), html)
        XCTAssertTrue(html.contains("Outer words.") && html.contains("Inner words."), html)
        XCTAssertFalse(html.contains("[!NOTE]") || html.contains("[!WARNING]"), html)
        XCTAssertFalse(html.contains("blockquote"), "both blockquotes became alerts, none left half-open: \(html)")
        // The warning sits inside the note: the note's div opens first and closes last.
        let note = html.range(of: "alert-note")!, warning = html.range(of: "alert-warning")!
        XCTAssertLessThan(note.lowerBound, warning.lowerBound, html)
        XCTAssertLessThan(html.range(of: "Inner words.")!.lowerBound, html.range(of: "</div>", options: .backwards)!.lowerBound, html)
        XCTAssertEqual(html.components(separatedBy: "<div").count, html.components(separatedBy: "</div>").count, "balanced: \(html)")
    }

    /// An alert that holds a plain quote keeps the quote whole and ends after it, not at the quote's own close.
    func testAnAlertHoldingAPlainQuoteEndsAfterTheQuote() {
        let html = MarkdownHTML.render("> [!TIP]\n> Before.\n> > A plain quote.\n>\n> After.\n\nOutside.\n")
        XCTAssertTrue(html.contains("<div class=\"alert alert-tip\""), html)
        XCTAssertEqual(html.components(separatedBy: "<blockquote>").count, 2, "the plain quote stays one blockquote: \(html)")
        XCTAssertEqual(html.components(separatedBy: "</blockquote>").count, 2, html)
        let tipEnd = html.range(of: "After.")!, outside = html.range(of: "Outside.")!
        let closeAfter = html.range(of: "</div>", range: tipEnd.upperBound..<html.endIndex)!
        XCTAssertLessThan(closeAfter.lowerBound, outside.lowerBound, "the tip closes after its last line, before the next paragraph: \(html)")
    }

    /// A plain quote that holds an alert: the inner alert is rewritten, the outer quote stays a quote.
    func testAPlainQuoteHoldingAnAlert() {
        let html = MarkdownHTML.render("> Said once:\n> > [!CAUTION]\n> > Hot.\n")
        XCTAssertTrue(html.contains("<div class=\"alert alert-caution\""), html)
        XCTAssertEqual(html.components(separatedBy: "<blockquote>").count, 2, html)
        XCTAssertEqual(html.components(separatedBy: "</blockquote>").count, 2, html)
    }

    /// Siblings, a nest three deep, and a stray raw-HTML close tag: every range stays valid and nothing crashes.
    func testOverlappingShapesStayInBounds() {
        let shapes = [
            "> [!NOTE]\n> a\n\n> [!TIP]\n> b\n",
            "> [!NOTE]\n> > [!TIP]\n> > > [!WARNING]\n> > > deep\n",
            "> [!NOTE]\n> > [!TIP]\n> > one\n>\n> > [!IMPORTANT]\n> > two\n",
            "> [!NOTE]\n> </blockquote></blockquote>\n> > [!TIP]\n> > x\n",
            "<blockquote>\n<p>[!NOTE]\nraw, never closed\n",
        ]
        for shape in shapes {
            let html = MarkdownHTML.render(shape)
            XCTAssertFalse(html.isEmpty, shape)
        }
        let deep = MarkdownHTML.render("> [!NOTE]\n> > [!TIP]\n> > > [!WARNING]\n> > > deep\n")
        for kind in ["note", "tip", "warning"] { XCTAssertTrue(deep.contains("alert-\(kind)"), deep) }
    }

    /// The transform on HTML directly, including shapes cmark never writes (a nest whose inner alert has no close).
    func testTheTransformOnHandWrittenHTML() {
        let nested = "<blockquote>\n<p>[!NOTE]\nA</p>\n<blockquote>\n<p>[!TIP]\nB</p>\n</blockquote>\n</blockquote>\n"
        let out = MarkdownHTML.Alerts.transform(nested)
        XCTAssertTrue(out.contains("alert-note") && out.contains("alert-tip"), out)
        XCTAssertFalse(out.contains("blockquote"), out)
        let unclosed = "<blockquote>\n<p>[!NOTE]\nA</p>\n<blockquote>\n<p>[!TIP]\nB</p>\n</blockquote>\n"
        XCTAssertFalse(MarkdownHTML.Alerts.transform(unclosed).isEmpty)
    }

    /// A very deep nest of alerts renders in bounded time (the nesting the rewrite follows is capped).
    func testADeepNestStaysFast() {
        let depth = 400
        var lines: [String] = []
        for level in 1...depth { lines.append(String(repeating: "> ", count: level) + "[!NOTE]") }
        lines.append(String(repeating: "> ", count: depth) + "bottom")
        let start = Date()
        let html = MarkdownHTML.render(lines.joined(separator: "\n") + "\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "a deep nest renders quickly")
        XCTAssertTrue(html.contains("bottom"))
    }
}
