import XCTest
@testable import VitrineData

/// XML through XMLParser: elements, attributes in source order, text, CDATA, comments, prefixes, XPath-like paths,
/// and the locks: no external entities, no DTD loading, entity expansion capped.
final class XMLTreeTests: XCTestCase {
    private func xml(_ text: String, configure: (inout StructuredOptions) -> Void = { _ in }) -> StructuredParseResult {
        ST.parse(text, .xml, configure: configure)
    }

    func testFeedTree() throws {
        let result = xml("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- invented feed -->
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/" zeta="1" alpha="2">
          <title>Example &amp; Co</title>
          <entry id="e1"><title>First</title></entry>
          <entry id="e2">
            <title>Second</title>
            <media:thumbnail url="https://example.invalid/t.png"/>
            <summary><![CDATA[<b>raw</b>]]></summary>
          </entry>
          <?render fast?>
        </feed>
        """)
        XCTAssertNil(result.error, result.error?.description ?? "")
        let tree = result.tree
        XCTAssertEqual(tree.roots.map { tree[$0].role }, [.comment, .element])
        let feed = try XCTUnwrap(ST.index(result, "/feed"))
        XCTAssertEqual(tree[feed].role, .element)
        XCTAssertEqual(tree.children(of: feed).prefix(4).map { tree[$0].name }, ["xmlns", "xmlns:media", "zeta", "alpha"])
        XCTAssertEqual(ST.node(result, "/feed/@alpha")?.preview, "2")
        XCTAssertEqual(ST.node(result, "/feed/title")?.preview, "Example & Co")
        XCTAssertEqual(ST.node(result, "/feed/title/text()")?.role, .text)
        XCTAssertEqual(ST.node(result, "/feed/entry[2]/title")?.preview, "Second")
        XCTAssertEqual(ST.node(result, "/feed/entry[2]/media:thumbnail/@url")?.preview, "https://example.invalid/t.png")
        XCTAssertEqual(ST.node(result, "/feed/entry[2]/summary/text()")?.role, .cdata)
        XCTAssertEqual(ST.node(result, "/feed/entry[2]/summary/text()")?.preview, "<b>raw</b>")
        XCTAssertEqual(ST.node(result, "/feed/processing-instruction('render')")?.preview, "fast")
        XCTAssertEqual(ST.node(result, "/comment()")?.preview, "invented feed")
        let second = try XCTUnwrap(ST.node(result, "/feed/entry[2]"))
        XCTAssertEqual(second.span.line, 6)
        XCTAssertEqual(second.span.byteLength, Int64("<entry id=\"e2\">".utf8.count))
        XCTAssertEqual(result.facts.rootElementName, "feed")
        XCTAssertEqual(ST.problems(tree), [])
    }

    func testWhitespaceBetweenTagsIsNotText() {
        let result = xml("<a>\n  <b/>\n  <c> x </c>\n</a>")
        XCTAssertEqual(ST.summary(result.tree), ["/a object", "/a/b object", "/a/c object=x", "/a/c/text() string=x"])
    }

    func testErrorsReportLineAndColumn() {
        let mismatch = xml("<a>\n  <b></c>\n</a>")
        XCTAssertNotNil(mismatch.error)
        XCTAssertEqual(mismatch.error?.location?.line, 2)
        XCTAssertFalse(mismatch.error?.reason.isEmpty ?? true)
        XCTAssertEqual(ST.node(mismatch, "/a/b")?.role, .element, "the tree keeps what came before the error")
        XCTAssertNotNil(xml("<a attr=unquoted/>").error)
        XCTAssertNotNil(xml("").error)
        XCTAssertNotNil(xml("<a></a><b/>").error)
    }

    func testExternalEntitiesAndDTDsAreNeverRead() throws {
        let directory = try TemporaryDirectory()
        let canary = "CANARY-\(UUID().uuidString)"
        let secret = try directory.write(canary, name: "secret.txt")
        let dtd = try directory.write("<!ENTITY fromdtd \"\(canary)\">", name: "external.dtd")
        let text = """
        <?xml version="1.0"?>
        <!DOCTYPE root SYSTEM "\(dtd.absoluteString)" [
          <!ENTITY xxe SYSTEM "\(secret.absoluteString)">
        ]>
        <root><a>&xxe;</a><b>&fromdtd;</b></root>
        """
        let result = xml(text)
        let everything = result.tree.nodes.map { ($0.name ?? "") + $0.preview }.joined()
        XCTAssertFalse(everything.contains(canary), "no file content may reach the tree")
        XCTAssertTrue(result.diagnostics.contains { $0.reason.contains("document type declaration") })
        // The same through the file entry point, which must not hand XMLParser a URL either.
        let file = try directory.write(text, name: "doc.xml")
        let fromFile = try StructuredParser.parse(contentsOf: file)
        XCTAssertFalse(fromFile.tree.nodes.contains { $0.preview.contains(canary) })
    }

    func testBillionLaughsIsCapped() {
        var text = "<?xml version=\"1.0\"?>\n<!DOCTYPE lolz [\n <!ENTITY lol \"lollollollollollollollollollol\">\n"
        var previous = "lol"
        for level in 1...9 {
            let name = "lol\(level)"
            text += " <!ENTITY \(name) \"" + String(repeating: "&\(previous);", count: 10) + "\">\n"
            previous = name
        }
        text += "]>\n<lolz>&\(previous);</lolz>"
        let clock = ContinuousClock()
        var result: StructuredParseResult?
        let elapsed = clock.measure { result = xml(text) }
        let parsed = result!
        XCTAssertLessThan(elapsed, .seconds(10))
        let delivered = parsed.tree.nodes.reduce(0) { $0 + $1.preview.utf8.count }
        XCTAssertLessThan(delivered, 2_000_000)
        XCTAssertTrue(parsed.error != nil || parsed.coverage.reasons.contains(.entityExpansionLimit)
                        || parsed.diagnostics.contains { $0.severity == .unsupported },
                      "libxml2 refuses the amplification, the meter stops it, or the entities are not expanded")
    }

    /// Custom internal entities are not substituted (that needs external resolution switched on, which stays off);
    /// the tree says so instead of dropping them silently. Predefined and character references still decode.
    func testDeclaredEntitiesAreReportedNotExpanded() {
        let result = xml("<!DOCTYPE r [<!ENTITY who \"Ada\">]><r>Hello &who; &amp; &#x41;</r>")
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(ST.node(result, "/r")?.preview, "Hello  & A")
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .unsupported && $0.reason.contains("&who;") })
    }

    func testMixedContentAndRepeatedText() {
        let result = xml("<p>one <b>two</b> three</p>")
        XCTAssertEqual(ST.node(result, "/p/text()[1]")?.preview, "one")
        XCTAssertEqual(ST.node(result, "/p/text()[2]")?.preview, "three")
        XCTAssertEqual(ST.node(result, "/p")?.preview, "one")
    }
}
