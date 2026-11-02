import XCTest
@testable import VitrineData

/// Property lists: XML read in order, binary and OpenStep through PropertyListSerialization, and plist → XML text.
final class PlistTreeTests: XCTestCase {
    private static var sample: [String: Any] { [
        "CFBundleName": "Sample",
        "Version": 3,
        "Ratio": 0.5,
        "Enabled": true,
        "Created": Date(timeIntervalSince1970: 1_700_000_000),
        "Blob": Data(repeating: 7, count: 1024),
        "Items": ["a", 1, false],
        "Nested": ["Inner": ["x": "y"]],
    ] }

    func testXMLPlistKeepsKeyOrderAndLines() throws {
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Zeta</key><string>last letter, first key</string>
          <key>Alpha</key><integer>42</integer>
          <key>Real</key><real>2.50</real>
          <key>Flag</key><true/>
          <key>When</key><date>2026-10-29T12:00:00Z</date>
          <key>Bytes</key><data>
            AAECAwQFBgcICQ==
          </data>
          <key>List</key>
          <array><string>one</string><false/><dict/></array>
        </dict>
        </plist>
        """
        let result = ST.parse(text, .propertyList)
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(result.dialect, .plistXML)
        XCTAssertEqual(result.tree.children(of: 0).map { result.tree[$0].name },
                       ["Zeta", "Alpha", "Real", "Flag", "When", "Bytes", "List"])
        XCTAssertEqual(ST.node(result, "$.Alpha")?.kind, .number)
        XCTAssertEqual(ST.node(result, "$.Real")?.preview, "2.50")
        XCTAssertEqual(ST.node(result, "$.Flag")?.kind, .bool)
        XCTAssertEqual(ST.node(result, "$.When")?.kind, .date)
        XCTAssertEqual(ST.node(result, "$.Bytes")?.kind, .data)
        XCTAssertEqual(ST.node(result, "$.Bytes")?.preview, "10 bytes")
        XCTAssertEqual(ST.node(result, "$.List[2]")?.kind, .object)
        XCTAssertEqual(ST.node(result, "$.Alpha")?.span.line, 6)
        XCTAssertEqual(ST.problems(result.tree), [])
    }

    func testXMLPlistStructureErrors() {
        XCTAssertEqual(ST.parse("<plist><dict><string>no key</string></dict></plist>", .propertyList).error?.reason,
                       "a dictionary value needs a <key> before it")
        XCTAssertEqual(ST.parse("<plist><dict><key>k</key><blob/></dict></plist>", .propertyList).error?.reason,
                       "<blob> is not a property list element")
        XCTAssertNotNil(ST.parse("<plist><dict><key>k</key>", .propertyList).error)
    }

    func testBinaryPlist() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: Self.sample, format: .binary, options: 0)
        let result = StructuredParser.parse(data, format: .propertyList)
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(result.dialect, .plistBinary)
        XCTAssertEqual(result.tree.children(of: 0).map { result.tree[$0].name },
                       ["Blob", "CFBundleName", "Created", "Enabled", "Items", "Nested", "Ratio", "Version"])
        XCTAssertEqual(ST.node(result, "$.Blob")?.preview, "1,024 bytes")
        XCTAssertEqual(ST.node(result, "$.Enabled")?.kind, .bool)
        XCTAssertEqual(ST.node(result, "$.Version")?.kind, .number)
        XCTAssertEqual(ST.node(result, "$.Created")?.preview, "2023-11-14T22:13:20Z")
        XCTAssertEqual(ST.node(result, "$.Items[2]")?.kind, .bool)
        XCTAssertEqual(ST.node(result, "$.Nested.Inner.x")?.preview, "y")
        XCTAssertFalse(result.layout.isMinified)
        XCTAssertEqual(StructuredFormat.sniff(data), .propertyList)
    }

    func testOpenStepPlist() {
        let result = ST.parse("{ Name = \"Sample\"; List = (a, \"b c\", ); Inner = { k = v; }; }", .propertyList)
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(result.dialect, .plistOpenStep)
        XCTAssertEqual(ST.node(result, "$.List[1]")?.preview, "b c")
        XCTAssertEqual(ST.node(result, "$.Inner.k")?.preview, "v")
        let deep = String(repeating: "(", count: 600) + String(repeating: ")", count: 600)
        XCTAssertEqual(ST.parse(deep, .propertyList).error?.reason, "nesting deeper than 512 levels is not read")
        XCTAssertNotNil(ST.parse("{ broken = ; }", .propertyList).error)
    }

    func testTruncatedBinaryPlistSaysWhy() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: Self.sample, format: .binary, options: 0)
        let result = StructuredParser.parse(data.prefix(40), format: .propertyList, fileSize: Int64(data.count))
        XCTAssertEqual(result.error?.reason, "the property list is larger than the read limit and cannot be read in part")
    }

    func testAnyPlistAsXMLText() throws {
        let binary = try PropertyListSerialization.data(fromPropertyList: ["b": [1, 2], "a": "x"], format: .binary, options: 0)
        let formatted = StructuredFormatter.propertyListXML(binary)
        XCTAssertTrue(formatted.isComplete)
        XCTAssertTrue(formatted.text.hasPrefix("<?xml"))
        XCTAssertTrue(formatted.text.contains("  <key>a</key>\n  <string>x</string>"), formatted.text)
        XCTAssertTrue(formatted.text.contains("    <integer>1</integer>"), formatted.text)
        let openStep = StructuredFormatter.format(Data("{ k = v; }".utf8), as: .propertyList)
        XCTAssertEqual(openStep?.isComplete, true)
        XCTAssertTrue(openStep?.text.contains("<key>k</key>") ?? false)
        let ordered = StructuredFormatter.propertyListXML(Data("<plist><dict><key>z</key><true/><key>a</key><false/></dict></plist>".utf8))
        XCTAssertEqual(ordered.text, "<plist>\n  <dict>\n    <key>z</key>\n    <true/>\n    <key>a</key>\n    <false/>\n  </dict>\n</plist>\n")
    }
}
