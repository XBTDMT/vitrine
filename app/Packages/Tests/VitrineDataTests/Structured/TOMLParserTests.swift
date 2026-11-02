import XCTest
@testable import VitrineData

/// TOML 1.0: tables, arrays of tables, inline tables, dotted keys, every value type, and the definition rules.
final class TOMLParserTests: XCTestCase {
    private func toml(_ text: String) -> StructuredParseResult { ST.parse(text, .toml) }

    func testDocumentInOrder() {
        let result = toml("""
        # A sample config with invented values.
        title = "Example"

        [owner]
        name = "Sam Placeholder"
        dob = 1979-05-27T07:32:00-08:00

        [database]
        enabled = true
        ports = [ 8000, 8001, 8002 ]
        data = [ ["delta", "phi"], [3.14] ]
        temp_targets = { cpu = 79.5, case = 72.0 }

        [servers.alpha]
        ip = "10.0.0.1"

        [[products]]
        name = "Hammer"
        sku = 738594937

        [[products]]

        [[products]]
        name = "Nail"
        color = "gray"
        """)
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(result.tree.children(of: 0).map { result.tree[$0].name }, ["title", "owner", "database", "servers", "products"])
        XCTAssertEqual(ST.node(result, "$.owner.dob")?.kind, .date)
        XCTAssertEqual(ST.node(result, "$.owner.dob")?.preview, "1979-05-27T07:32:00-08:00")
        XCTAssertEqual(ST.node(result, "$.database.data[0][1]")?.preview, "phi")
        XCTAssertEqual(ST.node(result, "$.database.temp_targets.case")?.preview, "72.0")
        XCTAssertEqual(ST.node(result, "$.servers.alpha.ip")?.preview, "10.0.0.1")
        XCTAssertEqual(ST.node(result, "$.products")?.childCount, 3)
        XCTAssertEqual(ST.node(result, "$.products[1]")?.childCount, 0)
        XCTAssertEqual(ST.node(result, "$.products[2].color")?.preview, "gray")
        XCTAssertEqual(ST.node(result, "$.owner")?.span.line, 4)
        XCTAssertEqual(ST.problems(result.tree), [])
    }

    func testEveryValueType() {
        let result = toml(#"""
        str = "tab\there \u00e9 \U0001F600 \"q\""
        lit = 'C:\Users\nobody'
        ml = """
        Roses \
          are red
        violets"""
        mll = '''
        raw \n text'''
        quotes = """two "" inside"""""
        int = +1_000
        neg = -17
        hex = 0xDEAD_beef
        oct = 0o755
        bin = 0b1101
        flt = 6.626e-34
        und = 224_617.445_991
        inf = -inf
        nan = nan
        odt = 1979-05-27 07:32:00Z
        ldt = 1979-05-27T00:32:00.999999
        ld = 1979-05-27
        lt = 00:32:00.5
        yes = true
        """#)
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(ST.node(result, "$.str")?.preview, "tab\there é 😀 \"q\"")
        XCTAssertEqual(ST.node(result, "$.lit")?.preview, "C:\\Users\\nobody")
        XCTAssertEqual(ST.node(result, "$.ml")?.preview, "Roses are red\nviolets")
        XCTAssertEqual(ST.node(result, "$.mll")?.preview, "raw \\n text")
        XCTAssertEqual(ST.node(result, "$.quotes")?.preview, "two \"\" inside\"\"")
        for key in ["int", "neg", "hex", "oct", "bin", "flt", "und", "inf", "nan"] {
            XCTAssertEqual(ST.node(result, "$.\(key)")?.kind, .number, key)
        }
        XCTAssertEqual(ST.node(result, "$.int")?.preview, "+1_000")
        for key in ["odt", "ldt", "ld", "lt"] { XCTAssertEqual(ST.node(result, "$.\(key)")?.kind, .date, key) }
        XCTAssertEqual(ST.node(result, "$.odt")?.preview, "1979-05-27 07:32:00Z")
        XCTAssertEqual(ST.node(result, "$.yes")?.kind, .bool)
    }

    func testKeysDottedAndQuoted() {
        let result = toml("""
        a.b.c = 1
        a.b.d = 2
        "quoted key" = 3
        'lit.key' = 4
        site."google.com" = true
        3.14 = "pi"
        [x . y]
        z = 1
        """)
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(ST.node(result, "$.a.b.d")?.preview, "2")
        XCTAssertEqual(ST.node(result, "$[\"quoted key\"]")?.preview, "3")
        XCTAssertEqual(ST.node(result, "$[\"lit.key\"]")?.preview, "4")
        XCTAssertEqual(ST.node(result, "$.site[\"google.com\"]")?.kind, .bool)
        XCTAssertEqual(ST.node(result, "$[\"3\"][\"14\"]")?.preview, "pi")
        XCTAssertEqual(ST.node(result, "$.x.y.z")?.preview, "1")
    }

    func testArraysMayBeMultiLineWithCommentsAndTrailingCommas() {
        let result = toml("list = [\n  1, # one\n  2,\n\n  # three is next\n  3,\n]\nempty = []\nmixed = [1, \"a\", {b = 2}]\n")
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(ST.node(result, "$.list")?.childCount, 3)
        XCTAssertEqual(ST.node(result, "$.empty")?.childCount, 0)
        XCTAssertEqual(ST.node(result, "$.mixed[2].b")?.preview, "2")
    }

    func testDefinitionRulesAndSyntaxErrors() {
        let cases: [(String, String, String)] = [
            ("a = 1\na = 2\n", "2:1", "duplicate key 'a'"),
            ("[t]\n[t]\n", "2:1", "table [t] is defined more than once"),
            ("a.b = 1\n[a.b]\n", "2:1", "'a.b' is already defined as a value"),
            ("[fruit]\napple.color = 'red'\n[fruit.apple]\n", "3:1", "table [fruit.apple] was already defined with dotted keys"),
            ("t = {a = 1}\nt.b = 2\n", "2:1", "'t' is an inline table and cannot be extended"),
            ("[[a]]\n[a]\n", "2:1", "'a' is already defined as a value"),
            ("a = [1]\n[[a]]\n", "2:1", "'a' is already defined and is not an array of tables"),
            ("x = { a = 1, }\n", "1:14", "a trailing comma is not allowed in an inline table"),
            ("x = { a = 1,\n b = 2 }\n", "1:13", "an inline table must be on one line"),
            ("x = 01\n", "1:5", "leading zeros are not allowed in an integer"),
            ("x = 1979-13-01\n", "1:5", "invalid date or time '1979-13-01'"),
            ("x = 9223372036854775808\n", "1:5", "integer out of range"),
            ("x = \"a\\qb\"\n", "1:7", "invalid escape '\\q'"),
            ("x = \"open\n", "1:10", "a single-line string cannot contain a line break"),
            ("x = 1 y = 2\n", "1:7", "expected a new line after the value, found 'y'"),
            ("x =\n", "1:4", "expected a value, found a line break"),
            ("= 1\n", "1:1", "expected a key, found '='"),
            ("x = [1 2]\n", "1:8", "expected ',' or ']' in the array, found '2'"),
            ("x = yes\n", "1:5", "invalid value 'yes'"),
            ("[t\n", "1:3", "expected ']' to close the table header"),
            ("x = 1 # bell \u{07}\n", "1:14", "control character in a comment"),
        ]
        for (text, location, reason) in cases {
            let error = toml(text).error
            XCTAssertEqual(error?.reason, reason, text.debugDescription)
            XCTAssertEqual(error?.location?.description, location, text.debugDescription)
        }
    }

    func testErrorKeepsEarlierValues() {
        let result = toml("a = 1\n[b]\nc = 'x'\nd = \n")
        XCTAssertEqual(result.error?.location?.line, 4)
        XCTAssertEqual(ST.node(result, "$.b.c")?.preview, "x")
        XCTAssertEqual(ST.problems(result.tree), [])
    }

    func testCRLFAndBOM() {
        let result = toml("\u{FEFF}a = 1\r\n[t]\r\nb = \"x\"\r\n")
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(ST.node(result, "$.t.b")?.span.line, 3)
    }
}
