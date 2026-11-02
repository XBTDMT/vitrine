import XCTest
@testable import VitrineData

/// Syntax errors with their position, runtime errors in jq's wording, and everything Vitrine refuses by name.
final class JQErrorTests: XCTestCase {
    func testSyntaxErrorsCarryAPosition() {
        let cases: [(String, String, Int)] = [
            (".a |", "syntax error: unexpected end of program at line 1, column 5", 4),
            (".[", "syntax error: unexpected end of program at line 1, column 3", 2),
            ("{a:}", "syntax error: unexpected '}' at line 1, column 4", 3),
            ("1 +", "syntax error: unexpected end of program at line 1, column 4", 3),
            ("if . then 1", "syntax error: expected 'elif', 'else' or 'end', found end of program at line 1, column 12", 11),
            (#""abc"#, "syntax error: unterminated string at line 1, column 1", 0),
            (".a\n| .b )", "syntax error: unexpected ')' at line 2, column 6", 8),
            ("[1, 2", "syntax error: expected ']', found end of program at line 1, column 6", 5),
            (#""\q""#, "syntax error: invalid escape '\\q' in a string at line 1, column 2", 1),
            ("1 == 2 == 3", "syntax error: '==' cannot be chained without parentheses at line 1, column 3", 2),
            ("reduce . as $x (0)", "syntax error: expected ';', found ')' at line 1, column 18", 17),
            ("def f: 1", "syntax error: expected ';' after the function body, found end of program at line 1, column 9", 8),
            ("{1: 2}", "syntax error: object keys must be strings, found the number 1 at line 1, column 2", 1),
            ("@foo", "syntax error: foo is not a valid format at line 1, column 1", 0),
            ("§", "syntax error: unexpected character '§' at line 1, column 1", 0),
        ]
        for (program, message, offset) in cases {
            let error = JQT.error(program)
            XCTAssertEqual(error?.kind, .syntax, program)
            XCTAssertEqual(error?.message, message, program)
            XCTAssertEqual(error?.offset, offset, program)
        }
        XCTAssertEqual(JQT.error(".a |")?.description, "jq: error: syntax error: unexpected end of program at line 1, column 5")
    }

    func testUndefinedNamesAreCompileErrors() {
        XCTAssertEqual(JQT.error("foo")?.message, "foo/0 is not defined at line 1, column 1")
        XCTAssertEqual(JQT.error("map")?.message, "map/0 is not defined at line 1, column 1")
        XCTAssertEqual(JQT.error(". | $x")?.message, "$x is not defined at line 1, column 5")
        XCTAssertEqual(JQT.error("break $out")?.message, "$*label-out is not defined at line 1, column 1")
        XCTAssertEqual(JQT.error("def f: g; 1")?.kind, .syntax)
        XCTAssertNil(JQT.error("def f(g): g; f(1)"))
    }

    func testRuntimeErrorsUseJQWording() {
        let cases: [(String, String, String)] = [
            (".a", "5", #"Cannot index number with "a""#),
            (".a", "[1]", #"Cannot index array with "a""#),
            (".a", #""x""#, #"Cannot index string with "a""#),
            (".[0]", "{}", "Cannot index object with number"),
            (".[]", "5", "Cannot iterate over number (5)"),
            (".[]", "null", "Cannot iterate over null (null)"),
            (".[]", #""abcdefghijklmnop""#, #"Cannot iterate over string ("abcdefghij...)"#),
            (#"1 + "a""#, "null", #"number (1) and string ("a") cannot be added"#),
            ("{} - 1", "null", "object ({}) and number (1) cannot be subtracted"),
            ("[] * 2", "null", "array ([]) and number (2) cannot be multiplied"),
            ("1 / 0", "null", "number (1) and number (0) cannot be divided because the divisor is zero"),
            ("1 % 0", "null", "number (1) and number (0) cannot be divided because the divisor is zero"),
            (#"error("custom")"#, "null", "custom"),
            (#"error({"a":1})"#, "null", #"{"a":1} (not a string)"#),
            ("keys", #""a""#, #"string ("a") has no keys"#),
            ("length", "true", "boolean (true) has no length"),
            (#"has("a")"#, "[1]", "Cannot check whether array has a string key"),
            ("-.", #""a""#, #"string ("a") cannot be negated"#),
            (#"{(1): 2}"#, "null", "Object keys must be strings"),
            ("tonumber", #""abc""#, "Cannot parse 'abc' as JSON"),
            ("fromjson", #""{\"a\":""#, "unfinished JSON term at line 1, column 6 (while parsing '{\"a\":')"),
            ("implode", "[-1]", "Invalid codepoint literal"),
            (#"test("(")"#, #""a""#, "( (at offset 0) is not a valid regex"),
            (#"test("a"; "q")"#, #""a""#, "q is not a valid modifier string"),
            ("test(1)", #""a""#, "number (1) cannot be matched, as it is not a string"),
            (#"split(1)"#, #""a""#, "split input and separator must be strings"),
            ("sort", "{}", "object ({}) cannot be sorted, as it is not an array"),
            (#"@csv"#, "[[1]]", "array ([1]) is not valid in a csv row"),
            (#"@csv"#, "1", "number (1) cannot be csv-formatted, only an array can be"),
            ("path(1)", "null", "Invalid path expression with result 1"),
            (".a = 1 | path(.a + 1)", "{}", "Invalid path expression with result 2"),
            (#"setpath(["a"]; 1)"#, "[]", #"Cannot index array with "a""#),
            ("setpath([-5]; 1)", "[1]", "Out of bounds negative array index"),
            (#"[.[] | join(",")]"#, "[[[1]]]", "Cannot join with array"),
            (#"ltrimstr(1), startswith(1)"#, #""a""#, "startswith() requires string inputs"),
            (#"strptime("%Y")"#, #""x""#, #"date "x" does not match format "%Y""#),
            ("nth(-1; 1)", "null", "Out of bounds negative array index"),
        ]
        for (program, input, message) in cases {
            let error = JQT.error(program, input)
            XCTAssertEqual(error?.kind, .runtime, program)
            XCTAssertEqual(error?.message, message, program)
            XCTAssertNil(error?.offset, program)
        }
        XCTAssertEqual(JQT.error(".a", "5")?.description, #"jq: error: Cannot index number with "a""#)
    }

    func testTryCatchesOnlyItsOwnBody() throws {
        // An error raised after the try (downstream) is not caught by it.
        XCTAssertEqual(JQT.error(#"try 1 catch "no" | error("later")"#)?.message, "later")
        XCTAssertEqual(JQT.error(#"(.a? // 1) | error("after")"#, "{}")?.message, "after")
        XCTAssertEqual(try JQT.outputs(#"[.[] | try error("x\(.)") catch .]"#, "[1,2]"), [#"["x1","x2"]"#])
        XCTAssertEqual(try JQT.outputs(#"try (try error("inner") catch error("outer: " + .)) catch ."#, "null"), [#""outer: inner""#])
        // break and limit pass through try.
        XCTAssertEqual(try JQT.outputs("[label $l | try (1, break $l, 2) catch 9]", "null"), ["[1]"])
        XCTAssertEqual(try JQT.outputs("[limit(2; try (1, 2, 3) catch 9)]", "null"), ["[1,2]"])
    }

    func testUnsupportedFeaturesAreRefusedByName() {
        let cases: [(String, String)] = [
            ("input", "`input` is not supported in Vitrine: a query runs on one value, with no input stream"),
            ("[inputs]", "`inputs` is not supported in Vitrine: a query runs on one value, with no input stream"),
            ("env.HOME", "`env` is not supported: the environment is not available in Vitrine"),
            ("$ENV.PATH", "`$ENV` is not supported: the environment is not available in Vitrine"),
            ("now", "`now` is not supported in Vitrine: results must not depend on the clock"),
            ("localtime", "`localtime` is not supported in Vitrine: results must not depend on the time zone (use `gmtime`)"),
            (#"strflocaltime("%H")"#, "`strflocaltime` is not supported in Vitrine: results must not depend on the time zone (use `strftime`)"),
            ("input_filename", "`input_filename` is not supported in Vitrine: a query does not see file names"),
            ("$__loc__", "`$__loc__` is not supported in Vitrine yet"),
            ("halt", "`halt` is not supported in Vitrine: a query cannot end the process"),
            (#"halt_error("x")"#, "`halt_error` is not supported in Vitrine: a query cannot end the process"),
            (#"import "a" as a; ."#, "modules (`import`) are not supported in Vitrine"),
            (#"include "a"; ."#, "modules (`include`) are not supported in Vitrine"),
            ("a::b", "modules (`a::…`) are not supported in Vitrine"),
            (".[] as [$a] ?// $a | $a", "destructuring alternatives (`?//`) are not supported in Vitrine yet"),
            ("get_search_list", "`get_search_list` is not supported in Vitrine: modules are not supported"),
            ("have_decnum", "`have_decnum` is not supported in Vitrine yet"),
        ]
        for (program, message) in cases {
            let error = JQT.error(program)
            XCTAssertEqual(error?.kind, .unsupported, program)
            XCTAssertEqual(error?.message, message, program)
            XCTAssertNotNil(error?.offset, program)
        }
        XCTAssertEqual(JQT.error("input")?.description,
                       "jq: `input` is not supported in Vitrine: a query runs on one value, with no input stream")
        // A program may define its own function with a refused name.
        XCTAssertNil(JQT.error("def input: 1; input"))
    }

    func testUnsupportedStrftimeDirectiveSaysSo() {
        XCTAssertEqual(JQT.error(#"strftime("%Q")"#, "0")?.message, "strftime/1: the directive %Q is not supported in Vitrine")
    }
}
