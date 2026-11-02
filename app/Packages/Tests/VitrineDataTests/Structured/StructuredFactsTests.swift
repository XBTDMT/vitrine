import XCTest
@testable import VitrineData

/// The facts helper: typed values and the strip's display strings.
final class StructuredFactsTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    private func entries(_ result: StructuredParseResult) -> [String: String] {
        Dictionary(uniqueKeysWithValues: result.facts.entries(locale: locale).map { ($0.key, $0.value) })
    }

    func testJSONFacts() {
        let result = ST.parse(#"{"a":[1,2,{"b":null}],"c":"x"}"#)
        let facts = result.facts
        XCTAssertEqual(facts.format, .json)
        XCTAssertEqual(facts.dialect, .json)
        XCTAssertEqual(facts.nodeCount, 7)
        XCTAssertEqual(facts.maxDepth, 3)
        XCTAssertEqual(facts.topLevelKind, .object)
        XCTAssertEqual(facts.topLevelSize, 2)
        XCTAssertNil(facts.error)
        XCTAssertEqual(entries(result), ["format": "JSON", "nodes": "7", "depth": "3", "topLevel": "Object, 2 keys"])
        XCTAssertEqual(result.facts.entries(locale: locale).map(\.key), ["format", "nodes", "depth", "topLevel"])
    }

    func testErrorAndCoverageFacts() {
        let result = ST.parse("[1, 2,\n 3 4]") { $0.jsonSyntax = .strict }
        let values = entries(result)
        XCTAssertEqual(values["error"], "Line 2, column 4: expected ',' or ']' after an array item")
        XCTAssertEqual(values["coverage"], "Showing 4 nodes: the parse stopped at a syntax error.")
        XCTAssertEqual(values["nodes"], "4 shown")
        XCTAssertEqual(result.facts.error?.location?.line, 2)
    }

    func testDialectsAndDocuments() {
        XCTAssertEqual(entries(ST.parse("{a: 1}"))["format"], "JSON5")
        let yaml = ST.parse("a: 1\n---\n- 1\n- 2\n", .yaml)
        XCTAssertEqual(entries(yaml)["documents"], "2")
        XCTAssertNil(yaml.facts.topLevelKind)
        XCTAssertEqual(entries(yaml)["topLevel"], "2 documents")
        let single = ST.parse("- 1\n- 2\n", .yaml)
        XCTAssertEqual(entries(single)["topLevel"], "Array, 2 items")
        let lines = ST.parse("{}\n{}\nbad\n", .jsonLines)
        XCTAssertEqual(entries(lines)["format"], "JSON Lines")
        XCTAssertEqual(entries(lines)["documents"], "3")
        XCTAssertEqual(entries(lines)["topLevel"], "3 records")
        XCTAssertEqual(entries(lines)["error"], "Line 3, column 1: unexpected 'bad': expected a value")
        XCTAssertEqual(entries(ST.parse("x = 1", .toml))["topLevel"], "Object, 1 key")
        XCTAssertEqual(entries(ST.parse("\"s\""))["topLevel"], "String")
    }

    func testXMLAndMinifiedFacts() {
        let body = (0..<100).map { "<item n=\"\($0)\">value \($0)</item>" }.joined()
        let result = ST.parse("<list>\(body)</list>", .xml)
        let values = entries(result)
        XCTAssertEqual(values["format"], "XML")
        XCTAssertEqual(values["topLevel"], "<list>, 100 children")
        XCTAssertEqual(values["layout"], "Minified")
        XCTAssertEqual(values["depth"], "2")
    }

    func testLimitFactsSayOfHowMany() {
        let result = ST.parse("[" + (0..<50).map(String.init).joined(separator: ",") + "]") { $0.maxNodes = 5 }
        XCTAssertEqual(entries(result)["nodes"], "5 of 51")
        XCTAssertEqual(entries(result)["topLevel"], "Array, 50 items")
    }

    func testFormatDetection() {
        XCTAssertEqual(StructuredFormat(fileExtension: "YML"), .yaml)
        XCTAssertEqual(StructuredFormat(fileExtension: "jsonc"), .json)
        XCTAssertEqual(StructuredFormat(fileExtension: "toml"), .toml)
        XCTAssertEqual(StructuredFormat(fileExtension: "entitlements"), .propertyList)
        XCTAssertEqual(StructuredFormat(fileExtension: "rss"), .xml)
        XCTAssertNil(StructuredFormat(fileExtension: "swift"))
        XCTAssertEqual(StructuredFormat.sniff(Data("  {\"a\":1}".utf8)), .json)
        XCTAssertEqual(StructuredFormat.sniff(Data("{\"a\":1}\n{\"a\":2}\n".utf8)), .jsonLines)
        XCTAssertEqual(StructuredFormat.sniff(Data("<?xml version=\"1.0\"?><plist>".utf8)), .propertyList)
        XCTAssertEqual(StructuredFormat.sniff(Data("\u{FEFF}<rss>".utf8)), .xml)
        XCTAssertEqual(StructuredFormat.sniff(Data("---\na: 1".utf8)), .yaml)
        XCTAssertNil(StructuredFormat.sniff(Data("plain words".utf8)))
    }
}
