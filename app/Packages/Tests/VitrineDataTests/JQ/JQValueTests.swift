import XCTest
@testable import VitrineData

/// The value model: printing as jq does, reading JSON, objects, ordering, and values from the structured tree.
final class JQValueTests: XCTestCase {
    func testPrettyPrintMatchesJQ() throws {
        let value = try JQValue(json: #"{"a":[1,{"b":null}],"c":{},"d":[],"e":"x\ny"}"#)
        XCTAssertEqual(value.prettyJSON(), """
        {
          "a": [
            1,
            {
              "b": null
            }
          ],
          "c": {},
          "d": [],
          "e": "x\\ny"
        }
        """)
        XCTAssertEqual(value.prettyJSON(indent: 4).split(separator: "\n")[1], #"    "a": ["#)
        XCTAssertEqual(value.prettyJSON(indent: 0), value.compactJSON())
        XCTAssertEqual(value.compactJSON(), #"{"a":[1,{"b":null}],"c":{},"d":[],"e":"x\ny"}"#)
    }

    func testStringEscapes() {
        XCTAssertEqual(JQValue.string("q\"b\\s/\u{1}\u{7F}\t\u{8}\u{C}é😀").compactJSON(), #""q\"b\\s/\u0001\u007f\t\b\fé😀""#)
    }

    func testNumberFormatting() {
        let cases: [(Double, String)] = [
            (0, "0"), (-0.0, "-0"), (1, "1"), (-12, "-12"), (1.5, "1.5"), (0.1, "0.1"), (100, "100"),
            (1e15, "1000000000000000"), (9999999999999998, "9999999999999998"), (1e16, "1e+16"), (1e17, "1e+17"), (1.5e17, "1.5e+17"),
            (123456789012345680, "123456789012345680"), (0.001, "0.001"), (0.0001, "0.0001"), (0.00001, "1e-05"),
            (1.25e-10, "1.25e-10"), (.infinity, "1.7976931348623157e+308"), (-.infinity, "-1.7976931348623157e+308"),
            (.nan, "null"), (3.14159, "3.14159"), (2.5e-5, "2.5e-05"), (1e300, "1e+300"),
        ]
        for (value, text) in cases {
            XCTAssertEqual(JQNumberFormat.format(value), text, "\(value)")
        }
    }

    func testJSONReader() throws {
        XCTAssertEqual(try JQValue(json: " [1, -2.5e3, true, false, null, \"\\u00e9\\ud83d\\ude00\"] "),
                       .array([.number(1), .number(-2500), .bool(true), .bool(false), .null, .string("é😀")]))
        XCTAssertEqual(try JQValue(json: #"{"a":1,"a":2,"b":3}"#).compactJSON(), #"{"a":2,"b":3}"#)
        XCTAssertThrowsError(try JQValue(json: "[1,]"))
        XCTAssertThrowsError(try JQValue(json: "{} {}"))
        XCTAssertThrowsError(try JQValue(json: "[1"))
        XCTAssertThrowsError(try JQValue(json: "01x"))
        XCTAssertThrowsError(try JQValue(json: String(repeating: "[", count: 2000) + String(repeating: "]", count: 2000)))
        XCTAssertNoThrow(try JQValue(json: String(repeating: "[", count: 1000) + String(repeating: "]", count: 1000)))
    }

    func testObjectsKeepInsertionOrderAndCompareByContent() throws {
        var object = JQObject([("b", .number(1)), ("a", .number(2))])
        object["c"] = .number(3)
        object["b"] = .number(9)
        XCTAssertEqual(object.keys, ["b", "a", "c"])
        XCTAssertEqual(object.sortedKeys, ["a", "b", "c"])
        object["b"] = nil
        object["b"] = .number(4)
        XCTAssertEqual(object.keys, ["a", "c", "b"])
        XCTAssertEqual(JQValue.object(object), try JQValue(json: #"{"c":3,"b":4,"a":2}"#))

        // Many keys use the hash index; byte-different but canonically equal keys stay distinct, as in jq.
        var big = JQObject()
        for i in 0..<100 { big["k\(i)"] = .number(Double(i)) }
        big["\u{E9}"] = .string("composed")
        big["e\u{301}"] = .string("decomposed")
        XCTAssertEqual(big.count, 102)
        XCTAssertEqual(big["\u{E9}"], .string("composed"))
        XCTAssertEqual(big["e\u{301}"], .string("decomposed"))
        XCTAssertEqual(big["k42"], .number(42))
        XCTAssertNotEqual(JQValue.string("\u{E9}"), JQValue.string("e\u{301}"))
    }

    func testOrderingIsJQs() throws {
        let sorted = try JQT.outputs("sort", #"["b","a","B","é","aa",""]"#)
        XCTAssertEqual(sorted, [#"["","B","a","aa","b","é"]"#])
    }

    func testValuesFromTheStructuredTree() throws {
        let yaml = ST.parse("""
        name: demo
        count: 0x1F
        ratio: .5
        tags: [a, b]
        enabled: True
        nothing: ~
        nested:
          inf: -.inf
        """, .yaml)
        let fromYAML = JQValue(tree: yaml.tree, node: yaml.tree.roots[0])
        XCTAssertEqual(try JQ.compile("[.name, .count, .ratio, .tags[1], .enabled, .nothing, .nested.inf]").run(fromYAML).outputs
                        .map { $0.compactJSON() }, [#"["demo",31,0.5,"b",true,null,-1.7976931348623157e+308]"#])
        XCTAssertTrue(JQValue.isLossless(tree: yaml.tree, node: yaml.tree.roots[0]))

        let toml = ST.parse("""
        title = "T"
        big = 1_000_000
        [server]
        ports = [80, 443]
        when = 1979-05-27T07:32:00Z
        """, .toml)
        let fromTOML = JQValue(tree: toml.tree, node: toml.tree.roots[0])
        XCTAssertEqual(try JQ.compile("[.big, .server.ports[1], .server.when, (keys | length)]").run(fromTOML).outputs.map { $0.compactJSON() },
                       [#"[1000000,443,"1979-05-27T07:32:00Z",3]"#])

        let lines = ST.parse("{\"n\":1}\n{\"n\":2}\n", .jsonLines)
        let total = try lines.tree.roots.reduce(0.0) { sum, root in
            guard case .number(let n) = try JQ.compile(".n").run(JQValue(tree: lines.tree, node: root)).outputs[0] else { return sum }
            return sum + n
        }
        XCTAssertEqual(total, 3)

        let long = ST.parse(#"{"s":"\#(String(repeating: "x", count: 1000))"}"#)
        XCTAssertFalse(JQValue.isLossless(tree: long.tree, node: 0), "previews are cut to 256 bytes")
    }

    func testBuiltinsListIsConsistent() throws {
        let names = try JQT.run("builtins", "null").outputs[0]
        guard case .array(let list) = names else { return XCTFail("builtins is not an array") }
        XCTAssertGreaterThan(list.count, 150)
        XCTAssertTrue(list.contains(.string("map/1")))
        XCTAssertTrue(list.contains(.string("test/2")))
        XCTAssertFalse(list.contains(.string("input/0")))
    }

    func testRunsFromASmallStackThread() throws {
        // The engine runs on its own large-stack thread, so a deep program is safe from any caller.
        let expectation = expectation(description: "ran")
        let thread = Thread {
            let run = try? JQ.compile("def f: if . == 0 then 0 else (. - 1 | f) + 1 end; f").run(.number(500))
            XCTAssertEqual(run?.outputs, [.number(500)])
            expectation.fulfill()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        wait(for: [expectation], timeout: 30)
    }
}
