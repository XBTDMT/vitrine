import XCTest
@testable import VitrineData

/// RFC 8259 JSON, the lenient JSONC/JSON5 mode, and the automatic choice between them.
final class JSONParserTests: XCTestCase {
    private func strict(_ text: String) -> StructuredParseResult { ST.parse(text) { $0.jsonSyntax = .strict } }
    private func lenient(_ text: String) -> StructuredParseResult { ST.parse(text) { $0.jsonSyntax = .lenient } }

    func testEveryValueKind() {
        let result = strict(#"{"s":"x","n":-1.50e+3,"t":true,"f":false,"z":null,"a":[],"o":{}}"#)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.dialect, .json)
        XCTAssertEqual(ST.summary(result.tree), [
            "$ object", "$.s string=x", "$.n number=-1.50e+3", "$.t bool=true", "$.f bool=false", "$.z null=null",
            "$.a array", "$.o object",
        ])
        XCTAssertTrue(result.coverage.isComplete)
    }

    func testNumbersKeepTheirExactText() {
        let result = strict("[0, -0, 1.10, 1e400, 12345678901234567890123, 2E-7]")
        XCTAssertEqual(result.tree.children(of: 0).map { result.tree[$0].preview },
                       ["0", "-0", "1.10", "1e400", "12345678901234567890123", "2E-7"])
    }

    func testStringEscapesDecode() {
        let result = strict(#"["a\"b\\c\/d\b\f\n\r\t", "\u00e9\u4e2d", "\ud83d\ude00", "\ud800x"]"#)
        let values = result.tree.children(of: 0).map { result.tree[$0].preview }
        XCTAssertEqual(values, ["a\"b\\c/d\u{8}\u{C}\n\r\t", "é中", "😀", "\u{FFFD}x"])
    }

    func testTopLevelScalarsAndWhitespace() {
        XCTAssertEqual(strict(" \n\t 42 \r\n").tree[0].preview, "42")
        XCTAssertEqual(strict("\"only\"").tree[0].kind, .string)
        XCTAssertNil(strict("\u{FEFF}{}").error, "a UTF-8 BOM is skipped")
    }

    /// The first error, its line:column (in characters) and a short reason.
    func testStrictErrorsReportLocationAndReason() {
        let cases: [(String, String, String)] = [
            ("{\"a\" 1}", "1:6", "expected ':' after the key"),
            ("{\n  \"a\": 1\n  \"b\": 2\n}", "3:3", "expected ',' or '}' after an object member"),
            ("[1, 2,]", "1:7", "trailing comma before ']'"),
            ("{\"a\":1,}", "1:8", "trailing comma before '}'"),
            ("{a:1}", "1:2", "object keys must be double-quoted strings"),
            ("['x']", "1:2", "strings must use double quotes"),
            ("[01]", "1:2", "leading zeros are not allowed"),
            ("[1.]", "1:4", "expected a digit after '.'"),
            ("[1e]", "1:4", "expected a digit in the exponent"),
            ("[-]", "1:3", "expected a digit, found ']'"),
            ("[tru]", "1:2", "invalid literal 'tru'"),
            ("[undefined]", "1:2", "unexpected 'undefined': expected a value"),
            ("// c\n{}", "1:1", "comments are not allowed in strict JSON"),
            ("\"a\nb\"", "1:3", "unescaped line break in a string"),
            ("\"a\u{01}\"", "1:3", "control character U+0001 in a string must be escaped"),
            (#""\q""#, "1:2", "invalid escape '\\q' in a string"),
            (#""\u12G4""#, "1:6", "expected 4 hex digits in an escape"),
            ("{} {}", "1:4", "unexpected '{' after the top-level value"),
            ("[1, 2", "1:6", "unexpected end of input: expected ',' or a closing bracket (an array is not closed)"),
            ("{\"a\":", "1:6", "unexpected end of input: expected a value (an object is not closed)"),
            ("\"open", "1:1", "unterminated string"),
            ("", "1:1", "empty document: expected a value"),
            ("[1}", "1:3", "expected ',' or ']' after an array item"),
            ("{\"é\":1 x}", "1:8", "expected ',' or '}' after an object member"),
        ]
        for (text, location, reason) in cases {
            let error = strict(text).error
            XCTAssertEqual(error?.location?.description, location, "location for \(text.debugDescription)")
            XCTAssertEqual(error?.reason, reason, "reason for \(text.debugDescription)")
        }
    }

    func testInvalidUTF8IsAnError() {
        let bytes: [UInt8] = Array("[\"a".utf8) + [0xC3, 0x28] + Array("\"]".utf8)
        let result = StructuredParser.parse(Data(bytes), format: .json, options: { var o = StructuredOptions(); o.jsonSyntax = .strict; return o }())
        XCTAssertEqual(result.error?.reason, "invalid UTF-8 sequence")
        XCTAssertEqual(result.error?.location?.description, "1:4")
        let overlong: [UInt8] = [0x22, 0xC0, 0xAF, 0x22]
        XCTAssertNotNil(StructuredParser.parse(Data(overlong), format: .json).error)
    }

    func testErrorKeepsThePartialTree() {
        let result = strict(#"{"a":1,"b":[true,"x"],"c":oops}"#)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(ST.node(result, "$.b[1]")?.preview, "x")
        XCTAssertEqual(result.tree[0].childrenOmitted, true)
        XCTAssertEqual(result.coverage.reasons, [.syntaxError])
        XCTAssertNil(ST.node(result, "$.c"))
        XCTAssertEqual(ST.problems(result.tree), [])
    }

    func testLenientJSON5() {
        let text = """
        // settings
        {
          unquoted: 'single \\' quote',
          $id_2: 0x1F,
          plus: +5, lead: .5, trail: 5.,
          inf: -Infinity, nan: NaN,
          "line": "a\\
        b",
          tab: "\\v\\x41\\0",
          /* block
             comment */
          list: [1, 2, ],
        }
        """
        let result = lenient(text)
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(result.dialect, .json5)
        XCTAssertEqual(ST.node(result, "$.unquoted")?.preview, "single ' quote")
        XCTAssertEqual(ST.node(result, "$[\"$id_2\"]")?.preview, "0x1F")
        XCTAssertEqual(ST.node(result, "$.plus")?.preview, "+5")
        XCTAssertEqual(ST.node(result, "$.lead")?.kind, .number)
        XCTAssertEqual(ST.node(result, "$.trail")?.preview, "5.")
        XCTAssertEqual(ST.node(result, "$.inf")?.preview, "-Infinity")
        XCTAssertEqual(ST.node(result, "$.nan")?.kind, .number)
        XCTAssertEqual(ST.node(result, "$.line")?.preview, "ab")
        XCTAssertEqual(ST.node(result, "$.tab")?.preview, "\u{B}A\u{0}")
        XCTAssertEqual(ST.node(result, "$.list")?.childCount, 2)
        XCTAssertEqual(ST.node(result, "$.list")?.span.line, 12)
    }

    func testCommentsAndTrailingCommasAloneAreJSONC() {
        let result = lenient("{\n  // editor settings\n  \"tabSize\": 4, /* spaces */\n  \"rulers\": [80, 120,],\n}")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.dialect, .jsonc)
        XCTAssertEqual(ST.node(result, "$.rulers[1]")?.preview, "120")
    }

    func testLenientStillRejectsGarbage() {
        XCTAssertEqual(lenient("{a: 1 b: 2}").error?.reason, "expected ',' or '}' after an object member")
        XCTAssertEqual(lenient("/* open").error?.reason, "unterminated block comment")
        XCTAssertEqual(lenient("[\"\\1\"]").error?.reason, "invalid escape '\\1' in a string")
    }

    func testAutomaticFallsBackAndSaysWhy() {
        let result = ST.parse("{\n  // comment\n  \"a\": 1,\n}")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.dialect, .jsonc)
        let warning = result.diagnostics.first { $0.severity == .warning }
        XCTAssertEqual(warning?.reason, "not strict JSON (comments are not allowed in strict JSON); read as JSONC")
        XCTAssertEqual(warning?.location?.description, "2:3")
    }

    func testAutomaticReportsTheStrictErrorWhenNeitherReads() {
        let result = ST.parse("{\"a\": 1 \"b\": 2}")
        XCTAssertEqual(result.error?.description, "1:9: expected ',' or '}' after an object member")
    }

    func testAutomaticRecognisesJSONLinesInADotJSONFile() {
        let result = ST.parse("{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.dialect, .jsonLines)
        XCTAssertEqual(result.tree.roots.count, 3)
    }

    func testUTF16InputIsTranscoded() throws {
        let text = "{\"name\": \"Zoë\"}"
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf16] {
            let data = try XCTUnwrap(text.data(using: encoding))
            let result = StructuredParser.parse(data, format: .json)
            XCTAssertNil(result.error, "\(encoding)")
            XCTAssertEqual(ST.node(result, "$.name")?.preview, "Zoë")
            XCTAssertEqual(result.diagnostics.first?.severity, .warning)
        }
    }

    func testTruncatedInputIsPartialNotAnError() {
        let full = #"{"list":[1,2,3,4,5,6,7,8,9],"name":"tail"}"#
        let cut = Data(full.utf8.prefix(20))
        let result = StructuredParser.parse(cut, format: .json, fileSize: Int64(full.utf8.count))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.coverage.reasons, [.inputByteLimit(readBytes: 20, fileSize: Int64(full.utf8.count))])
        XCTAssertEqual(ST.node(result, "$.list")?.childrenOmitted, true)
        XCTAssertEqual(ST.problems(result.tree), [])
    }

    func testFileIsReadOnlyUpToTheInputLimit() throws {
        let directory = try TemporaryDirectory()
        let body = (0..<2000).map { "{\"id\":\($0)}" }.joined(separator: ",")
        let url = try directory.write("[" + body + "]", name: "big.json")
        var options = StructuredOptions()
        options.maxInputBytes = 4096
        let result = try StructuredParser.parse(contentsOf: url, options: options)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.parsedBytes, 4096)
        XCTAssertFalse(result.coverage.isComplete)
        XCTAssertGreaterThan(result.tree.count, 100)
    }

    func testExtensionPicksLenientForJSON5Files() throws {
        let directory = try TemporaryDirectory()
        let url = try directory.write("{a: 1}", name: "config.json5")
        let result = try StructuredParser.parse(contentsOf: url)
        XCTAssertEqual(result.format, .json)
        XCTAssertEqual(result.dialect, .json5)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }
}
