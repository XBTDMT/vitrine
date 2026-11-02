import XCTest
@testable import VitrineData

/// The SVG scan (D-4): size facts, risk counts, well-formedness with a position, namespace repair and syntax runs.
/// Every sample is invented. roadmap: S-6
final class SVGScannerTests: XCTestCase {
    private func scan(_ s: String, truncated: Bool = false) -> SVGScan { SVGScanner.scan(Data(s.utf8), truncated: truncated) }

    func testSizeFactsAndCounts() {
        let s = scan("""
        <?xml version="1.0"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="240" height="160px" viewBox="0 0 120 80">
          <g><rect width="10" height="10"/><circle r="3"/></g>
          <path d="M0 0h10"/>
        </svg>
        """)
        XCTAssertNil(s.problem)
        XCTAssertTrue(s.isSVG)
        XCTAssertEqual(s.width, "240")
        XCTAssertEqual(s.height, "160px")
        XCTAssertEqual(s.viewBox, [0, 0, 120, 80])
        XCTAssertEqual(s.dimensions, "240 × 160")
        XCTAssertEqual(s.aspectRatio, 1.5)
        XCTAssertEqual(s.elements, 5)
        XCTAssertEqual(s.maxDepth, 3)
        XCTAssertEqual(s.scriptLike, 0)
        XCTAssertEqual(s.externalRefs, 0)
        XCTAssertTrue(s.hasSVGNamespace)
    }

    func testViewBoxOnlyUsesTheViewBoxSize() {
        let s = scan(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0,0,1200,630.5"><rect width="1" height="1"/></svg>"#)
        XCTAssertEqual(s.dimensions, "1,200 × 630.5")
        XCTAssertNil(s.width)
    }

    func testPercentSizesFallBackToTheViewBox() {
        let s = scan(#"<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" viewBox="0 0 64 32"/>"#)
        XCTAssertEqual(s.dimensions, "64 × 32")
        XCTAssertEqual(s.elements, 1)
        XCTAssertNil(s.problem)
    }

    func testCountsEverythingRisky() {
        let s = scan("""
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" onload="go()">
          <style>@import url("https://example.invalid/a.css"); .x { fill: url(#grad); background: url('https://example.invalid/b.png') }</style>
          <script>alert(1)</script>
          <image href="https://example.invalid/c.png"/>
          <image xlink:href="pictures/local.png"/>
          <image href="data:image/png;base64,AAAA"/>
          <use href="#icon"/>
          <a href="javascript:alert(2)"><rect onclick="x()" style="fill: url(https://example.invalid/d.svg#p)"/></a>
          <set attributeName="href" to="javascript:alert(3)"/>
          <foreignObject><div xmlns="http://www.w3.org/1999/xhtml">hi</div></foreignObject>
        </svg>
        """)
        XCTAssertNil(s.problem)
        XCTAssertEqual(s.scripts, 1)
        XCTAssertEqual(s.eventHandlers, 2)
        XCTAssertEqual(s.javascriptURLs, 2)
        XCTAssertEqual(s.foreignObjects, 1)
        // a.css, b.png, c.png, local.png, d.svg — not #grad, #icon or the data: image.
        XCTAssertEqual(s.externalRefs, 5)
        XCTAssertEqual(s.externalExamples.count, 3)
        XCTAssertEqual(s.externalExamples.first, "https://example.invalid/a.css")
    }

    func testStylesheetInstructionIsAnExternalReference() {
        let s = scan(#"<?xml-stylesheet type="text/css" href="https://example.invalid/s.css"?><svg xmlns="http://www.w3.org/2000/svg"/>"#)
        XCTAssertEqual(s.externalRefs, 1)
    }

    func testEntityDeclarationsAreCountedAndAllowed() {
        let s = scan("""
        <?xml version="1.0"?>
        <!DOCTYPE svg [<!ENTITY brand "Harbor"><!ENTITY % p "x"><!ENTITY remote SYSTEM "https://example.invalid/x">]>
        <svg xmlns="http://www.w3.org/2000/svg"><text>&brand; &amp; &#169; &#x2014;</text></svg>
        """)
        XCTAssertNil(s.problem)
        XCTAssertEqual(s.entityDeclarations, 3)
    }

    func testMalformedFilesSayWhereAndWhy() {
        let unclosed = scan("<svg xmlns=\"http://www.w3.org/2000/svg\">\n  <g>\n  <rect/>\n</svg>")
        XCTAssertEqual(unclosed.problem?.message, "</svg> where </g> was expected")
        XCTAssertEqual(unclosed.problem?.line, 4)

        let neverClosed = scan(#"<svg xmlns="http://www.w3.org/2000/svg"><rect>"#)
        XCTAssertEqual(neverClosed.problem?.message, "<rect> is never closed")

        let truncatedTag = scan("<svg xmlns=\"http://www.w3.org/2000/svg\">\n<circle cx=\"5\"")
        XCTAssertEqual(truncatedTag.problem?.message, "the <circle> tag is never finished")
        XCTAssertEqual(truncatedTag.problem?.line, 2)

        XCTAssertEqual(scan(#"<svg><rect width=10/></svg>"#).problem?.message, "an attribute value without quotes")
        XCTAssertEqual(scan(#"<svg><text>fish & chips</text></svg>"#).problem?.message, "a bare & (write &amp;)")
        XCTAssertEqual(scan(#"<svg><text>&nbsp;</text></svg>"#).problem?.message, "the entity &nbsp; is not declared")
        XCTAssertEqual(scan(#"<svg a="1" a="2"/>"#).problem?.message, "the attribute a appears twice")
        XCTAssertEqual(scan(#"<svg/><svg/>"#).problem?.message, "a second root element <svg>")
        XCTAssertEqual(scan("stray <svg/>").problem?.message, "text outside the root element")
        XCTAssertEqual(scan("").problem?.message, "there is no root element")
        XCTAssertEqual(scan(#"<html><body/></html>"#).problem?.message, "the root element is <html>, not <svg>")
    }

    func testATruncatedPrefixIsNotAProblem() {
        let s = scan(#"<svg xmlns="http://www.w3.org/2000/svg"><g><rect/><rect/>"#, truncated: true)
        XCTAssertNil(s.problem)
        XCTAssertEqual(s.elements, 4)
    }

    func testPrefixedRootWithItsNamespace() {
        let s = scan(#"<svg:svg xmlns:svg="http://www.w3.org/2000/svg"><svg:rect/></svg:svg>"#)
        XCTAssertNil(s.problem)
        XCTAssertTrue(s.isSVG)
        XCTAssertTrue(s.hasSVGNamespace)
        XCTAssertEqual(SVGScanner.drawable(Data(#"<svg:svg xmlns:svg="http://www.w3.org/2000/svg"/>"#.utf8), scan: s),
                       Data(#"<svg:svg xmlns:svg="http://www.w3.org/2000/svg"/>"#.utf8))
    }

    func testDrawableAddsOnlyTheMissingNamespaces() {
        let bare = ##"<svg viewBox="0 0 4 4"><use xlink:href="#a"/></svg>"##
        let s = scan(bare)
        XCTAssertFalse(s.hasSVGNamespace)
        XCTAssertTrue(s.usesUndeclaredXLink)
        let fixed = String(decoding: SVGScanner.drawable(Data(bare.utf8), scan: s), as: UTF8.self)
        XCTAssertEqual(fixed, ##"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 4 4"><use xlink:href="#a"/></svg>"##)

        let complete = #"<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>"#
        XCTAssertEqual(SVGScanner.drawable(Data(complete.utf8), scan: scan(complete)), Data(complete.utf8))
    }

    func testDeepAndLargeInputsScanInLinearTime() {
        let depth = 50_000
        let deep = "<svg xmlns=\"http://www.w3.org/2000/svg\">" + String(repeating: "<g>", count: depth) + String(repeating: "</g>", count: depth) + "</svg>"
        var s = scan(deep)
        XCTAssertNil(s.problem)
        XCTAssertEqual(s.maxDepth, depth + 1)

        var many = "<svg xmlns=\"http://www.w3.org/2000/svg\">"
        for i in 0..<100_000 { many += "<rect x=\"\(i)\" width=\"1\" height=\"1\"/>" }
        many += "</svg>"
        let start = Date()
        s = scan(many)
        XCTAssertEqual(s.elements, 100_001)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "a 3 MB file must scan in well under the first-paint budget")
    }

    func testSyntaxSpansColourTagsAttributesAndComments() {
        let text = #"<!-- é --><svg a="1"><t>x &amp; y</t></svg>"#
        let spans = SVGScanner.syntaxSpans(text)
        let ns = text as NSString
        func pieces(_ role: SVGSyntaxSpan.Role) -> [String] {
            spans.filter { $0.role == role }.map { ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
        }
        XCTAssertEqual(pieces(.comment), ["<!-- é -->"])
        XCTAssertEqual(pieces(.tagName), ["svg", "t", "t", "svg"])
        XCTAssertEqual(pieces(.attributeName), ["a"])
        XCTAssertEqual(pieces(.attributeValue), ["\"1\""])
        XCTAssertEqual(pieces(.entity), ["&amp;"])
        XCTAssertEqual(pieces(.punctuation), ["<", "=", ">", "<", ">", "</", ">", "</", ">"])
    }

    func testSyntaxSpansCountUTF16ForAstralCharacters() {
        let text = "<!--😀--><svg/>"
        let spans = SVGScanner.syntaxSpans(text)
        let ns = text as NSString
        let tag = spans.first { $0.role == .tagName }
        XCTAssertEqual(tag.map { ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }, "svg")
    }
}
