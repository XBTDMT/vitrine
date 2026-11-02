import XCTest
@testable import VitrineData

/// Formatted text: re-indentation that keeps every token as written, and minified detection.
final class StructuredFormatterTests: XCTestCase {
    func testJSONReindentKeepsOrderAndNumberText() {
        let input = "{\"z\":1.10,\"a\":[1e400,-0,{}],\"e\":[],\"s\":\"x\\u0041,{\"}"
        let formatted = StructuredFormatter.json(Data(input.utf8))
        XCTAssertTrue(formatted.isComplete)
        XCTAssertEqual(formatted.text, """
        {
          "z": 1.10,
          "a": [
            1e400,
            -0,
            {}
          ],
          "e": [],
          "s": "x\\u0041,{"
        }

        """)
    }

    func testJSONIndentWidthAndTopLevelScalar() {
        XCTAssertEqual(StructuredFormatter.json(Data("[1,[2]]".utf8), indent: 4).text, "[\n    1,\n    [\n        2\n    ]\n]\n")
        XCTAssertEqual(StructuredFormatter.json(Data("  42  ".utf8)).text, "42\n")
    }

    func testJSONCCommentsStayPut() {
        let text = "{\"a\":1, // trailing note\n/* own line */\n\"b\":[ ], 'c': .5}"
        let formatted = StructuredFormatter.json(Data(text.utf8))
        XCTAssertTrue(formatted.isComplete)
        XCTAssertEqual(formatted.text, "{\n  \"a\": 1, // trailing note\n  /* own line */\n  \"b\": [],\n  'c': .5\n}\n")
    }

    func testFormattingStopsAtUntokenizableInput() {
        let formatted = StructuredFormatter.json(Data("{\"a\": \"open".utf8))
        XCTAssertFalse(formatted.isComplete)
        XCTAssertEqual(formatted.stoppedAt?.reason, "unterminated string")
        XCTAssertEqual(formatted.stoppedAt?.location?.description, "1:7")
        XCTAssertEqual(StructuredFormatter.json(Data("[1, @]".utf8)).stoppedAt?.reason, "unexpected '@'")
    }

    func testFormattedOutputIsCapped() {
        var options = StructuredOptions()
        options.maxFormattedBytes = 100
        let big = "[" + (0..<1000).map(String.init).joined(separator: ",") + "]"
        let formatted = StructuredFormatter.json(Data(big.utf8), options: options)
        XCTAssertFalse(formatted.isComplete)
        XCTAssertLessThan(formatted.text.utf8.count, 200)
    }

    func testFormattedJSONParsesToTheSameTree() {
        var random = SeededGenerator(seed: 77)
        let text = StructuredFuzzTests.randomJSON(depth: 0, &random)
        let minified = ST.parse(text)
        let formatted = StructuredFormatter.json(Data(text.utf8))
        let reparsed = ST.parse(formatted.text)
        XCTAssertNil(reparsed.error)
        XCTAssertEqual(ST.summary(minified.tree), ST.summary(reparsed.tree))
    }

    func testXMLReindent() {
        let input = #"<?xml version="1.0"?><!-- c --><feed b="2" a='1'><title>Hi &amp; bye</title><e/><entry><p>  text  </p><x></x></entry>loose</feed>"#
        let formatted = StructuredFormatter.xml(Data(input.utf8))
        XCTAssertTrue(formatted.isComplete)
        XCTAssertEqual(formatted.text, """
        <?xml version="1.0"?>
        <!-- c -->
        <feed b="2" a='1'>
          <title>Hi &amp; bye</title>
          <e/>
          <entry>
            <p>text</p>
            <x></x>
          </entry>
          loose
        </feed>

        """)
    }

    func testXMLFormatterIsTolerant() {
        let formatted = StructuredFormatter.xml(Data("<a><b attr=\"x>y\"><!-- open".utf8))
        XCTAssertFalse(formatted.isComplete)
        XCTAssertEqual(formatted.text, "<a>\n  <b attr=\"x>y\">\n    <!-- open\n")
        XCTAssertNil(StructuredFormatter.format(Data("a: 1".utf8), as: .yaml))
    }

    func testMinifiedDetection() {
        let minified = "[" + (0..<500).map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
        XCTAssertTrue(StructuredLayout.measure(Data(minified.utf8)).isMinified)
        XCTAssertTrue(ST.parse(minified).layout.isMinified)
        XCTAssertTrue(StructuredFormatter.json(Data(minified.utf8)).inputWasMinified)
        let pretty = StructuredFormatter.json(Data(minified.utf8)).text
        XCTAssertFalse(StructuredLayout.measure(Data(pretty.utf8)).isMinified)
        XCTAssertFalse(StructuredLayout.measure(Data("{\"a\": 1}".utf8)).isMinified, "short files are never minified")
        let oneLongValue = "{\n  \"blob\": \"" + String(repeating: "A", count: 1200) + "\",\n" +
            (0..<200).map { "  \"k\($0)\": \($0)," }.joined(separator: "\n") + "\n  \"end\": 0\n}"
        XCTAssertFalse(StructuredLayout.measure(Data(oneLongValue.utf8)).isMinified, "one long line in a laid-out file is not minified")
        let lines = (0..<100).map { "{\"id\":\($0),\"text\":\"" + String(repeating: "x", count: 1100) + "\"}" }.joined(separator: "\n")
        XCTAssertFalse(ST.parse(lines, .jsonLines).layout.isMinified, "JSON Lines is one record per line by design")
    }
}
