import XCTest
@testable import VitrineData

/// The YAML subset: block and flow collections, every scalar style, anchors and aliases, documents, tags, and honest
/// reports of what is not modelled.
final class YAMLParserTests: XCTestCase {
    private func yaml(_ text: String, configure: (inout StructuredOptions) -> Void = { _ in }) -> StructuredParseResult {
        ST.parse(text, .yaml, configure: configure)
    }

    func testBlockCollections() {
        let result = yaml("""
        # service
        name: web
        ports:
          - 80
          - 443
        env:
          DEBUG: false
          nested:
            - a: 1
              b: two
            -
              - deep
        indentless:
        - x
        - y
        """)
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(ST.summary(result.tree), [
            "$ object", "$.name string=web", "$.ports array", "$.ports[0] number=80", "$.ports[1] number=443",
            "$.env object", "$.env.DEBUG bool=false", "$.env.nested array", "$.env.nested[0] object",
            "$.env.nested[0].a number=1", "$.env.nested[0].b string=two", "$.env.nested[1] array",
            "$.env.nested[1][0] string=deep", "$.indentless array", "$.indentless[0] string=x", "$.indentless[1] string=y",
        ])
        XCTAssertEqual(result.documentCount, 1)
        XCTAssertEqual(ST.problems(result.tree), [])
    }

    func testFlowCollectionsAndJSONIsYAML() {
        let result = yaml(#"{"a": [1, 2.5, {"b": null}], c: [x, y, ], 'd':e, url: http://x.y/z, pair: [k: v]}"#)
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(ST.node(result, "$.a[1]")?.kind, .number)
        XCTAssertEqual(ST.node(result, "$.a[2].b")?.kind, .null)
        XCTAssertEqual(ST.node(result, "$.c")?.childCount, 2)
        XCTAssertEqual(ST.node(result, "$.d")?.preview, "e")
        XCTAssertEqual(ST.node(result, "$.url")?.preview, "http://x.y/z")
        XCTAssertEqual(ST.node(result, "$.pair[0].k")?.preview, "v")
    }

    func testScalarResolutionFollowsTheCoreSchema() {
        let result = yaml("""
        null1: ~
        null2:
        bool: True
        yes: yes
        int: -42
        hex: 0x1F
        octal: 0o17
        float: 6.02e23
        inf: -.inf
        nan: .NaN
        date: 2026-10-29
        stamp: 2001-12-14t21:59:43.10-05:00
        spaced: 2001-12-14 21:59:43.10 -5
        version: 1.2.3
        quoted: "42"
        tagged: !!str 42
        number: !!int "7"
        custom: !thing value
        blob: !!binary R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7
        """)
        XCTAssertNil(result.error, result.error?.description ?? "")
        let kinds = ["null1": StructuredNodeKind.null, "null2": .null, "bool": .bool, "yes": .string, "int": .number,
                     "hex": .number, "octal": .number, "float": .number, "inf": .number, "nan": .number, "date": .date,
                     "stamp": .date, "spaced": .date, "version": .string, "quoted": .string, "tagged": .string,
                     "number": .number, "custom": .string, "blob": .data]
        for (key, kind) in kinds { XCTAssertEqual(ST.node(result, "$.\(key)")?.kind, kind, key) }
        XCTAssertEqual(ST.node(result, "$.blob")?.preview, "42 bytes")
        XCTAssertEqual(ST.node(result, "$.null2")?.preview, "null")
        let tagged = ST.index(result, "$.custom")!
        XCTAssertEqual(result.tree.tag(of: tagged), "!thing")
    }

    func testQuotedScalars() {
        let result = yaml(#"""
        single: 'it''s "x"'
        double: "tab\there \u00e9 \x41 \"q\" \\"
        folded: "one
          two

          three"
        continued: "ab\
          cd"
        """#)
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(ST.node(result, "$.single")?.preview, "it's \"x\"")
        XCTAssertEqual(ST.node(result, "$.double")?.preview, "tab\there é A \"q\" \\")
        XCTAssertEqual(ST.node(result, "$.folded")?.preview, "one two\nthree")
        XCTAssertEqual(ST.node(result, "$.continued")?.preview, "abcd")
    }

    func testBlockScalars() {
        let result = yaml("""
        literal: |
          line 1
            indented
          line 3

        folded: >
          a
          b

          c
        strip: |-
          x

        keep: |+
          y

        explicit: |2
            two extra
        plain: multi
          line
          plain
        last: end
        """)
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(ST.node(result, "$.literal")?.preview, "line 1\n  indented\nline 3\n")
        XCTAssertEqual(ST.node(result, "$.folded")?.preview, "a b\nc\n")
        XCTAssertEqual(ST.node(result, "$.strip")?.preview, "x")
        XCTAssertEqual(ST.node(result, "$.keep")?.preview, "y\n\n")
        XCTAssertEqual(ST.node(result, "$.explicit")?.preview, "  two extra\n")
        XCTAssertEqual(ST.node(result, "$.plain")?.preview, "multi line plain")
        XCTAssertEqual(ST.node(result, "$.last")?.preview, "end")
    }

    func testAnchorsAndAliasesExpand() throws {
        let result = yaml("""
        defaults: &defaults
          adapter: postgres
          host: localhost
        development:
          <<: *defaults
          database: dev
        list: &items [1, 2]
        again: *items
        scalar: &s hello
        copy: *s
        *s : aliased key
        """)
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(ST.node(result, "$.development[\"<<\"].host")?.preview, "localhost")
        XCTAssertEqual(ST.node(result, "$.again[1]")?.preview, "2")
        XCTAssertEqual(ST.node(result, "$.copy")?.preview, "hello")
        XCTAssertEqual(ST.node(result, "$[\"*s\"]")?.preview, "aliased key")
        let defaults = try XCTUnwrap(ST.index(result, "$.defaults"))
        XCTAssertEqual(result.tree.anchor(of: defaults), "defaults")
        XCTAssertEqual(ST.problems(result.tree), [])
    }

    func testBillionLaughsStopsAtTheAliasBudget() {
        var text = "a: &a [\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\",\"lol\"]\n"
        for (level, previous) in zip("bcdefghi", "abcdefgh") {
            text += "\(level): &\(level) [" + Array(repeating: "*\(previous)", count: 9).joined(separator: ",") + "]\n"
        }
        let clock = ContinuousClock()
        var result: StructuredParseResult?
        let elapsed = clock.measure { result = yaml(text) { $0.maxAliasExpansionNodes = 50_000 } }
        let parsed = result!
        XCTAssertNil(parsed.error)
        XCTAssertLessThan(parsed.tree.count, 60_000)
        XCTAssertTrue(parsed.coverage.reasons.contains(.aliasExpansionLimit(50_000)))
        XCTAssertTrue(parsed.tree.nodes.contains { $0.role == .alias })
        XCTAssertLessThan(elapsed, .seconds(10))
        XCTAssertEqual(ST.problems(parsed.tree), [])
    }

    func testMultipleDocuments() {
        let result = yaml("%YAML 1.2\n---\na: 1\n...\n---\n- x\n--- plain\n---\n")
        XCTAssertNil(result.error, result.error?.description ?? "")
        XCTAssertEqual(result.documentCount, 4)
        XCTAssertEqual(result.tree.roots.map { result.tree[$0].kind }, [.object, .array, .string, .null])
        XCTAssertEqual(result.facts.topLevelSize, 4)
        XCTAssertEqual(yaml("").documentCount, 0)
        XCTAssertEqual(yaml("# only a comment\n").tree.count, 0)
    }

    func testUnsupportedConstructsAreReportedNotGuessed() {
        let result = yaml("? [a, b]\n: complex\nrecursive: &r [*r]\nmissing: *nope\n")
        XCTAssertEqual(ST.node(result, "$[\"<complex key>\"]")?.preview, "complex")
        let unsupported = result.diagnostics.filter { $0.severity == .unsupported }.map(\.reason)
        XCTAssertTrue(unsupported.contains { $0.contains("collection used as a mapping key") })
        XCTAssertTrue(unsupported.contains { $0.contains("recursive alias '*r'") })
        XCTAssertEqual(result.error?.reason, "undefined alias '*nope'")
        XCTAssertEqual(result.error?.location?.line, 4)
        XCTAssertEqual(ST.node(result, "$.missing")?.role, .alias)
        let tag = yaml("%TAG !e! tag:example.com,2000:\n---\nx: !e!thing 1\n")
        XCTAssertTrue(tag.diagnostics.contains { $0.severity == .unsupported })
        XCTAssertEqual(tag.tree.tag(of: ST.index(tag, "$.x")!), "!e!thing")
    }

    func testErrorsHaveLocations() {
        let cases: [(String, String, String)] = [
            ("a: 1\n b: 2\n", "2:3", "a mapping value is not allowed here"),
            ("key: [1, 2\nnext: 3\n", "2:5", "expected ',' or ']', found ':'"),
            ("a: 1\n- b\n", "2:1", "expected a key ('key: value') or the end of the mapping, found '-'"),
            ("a:\n\t- b\n", "2:1", "tab characters cannot be used for indentation"),
            ("x: \"open\n", "1:4", "unterminated quoted scalar"),
            ("x: \"bad \\q\"\n", "1:10", "unknown escape '\\q'"),
            ("- a\nb\n", "2:1", "could not find the ':' for this key"),
            ("x: @y\n", "1:4", "'@' is reserved and cannot start a plain scalar"),
            ("x: \"a\u{0}b\"\n", "1:6", "unexpected NUL character"),
            ("x: \u{0}\n", "1:4", "unexpected NUL character"),
        ]
        for (text, location, reason) in cases {
            let error = yaml(text).error
            XCTAssertEqual(error?.reason, reason, text.debugDescription)
            XCTAssertEqual(error?.location?.description, location, text.debugDescription)
        }
    }

    func testErrorKeepsWhatCameBefore() {
        let result = yaml("ok: 1\nlist:\n  - a\n  - b\nbad: [\n")
        XCTAssertNotNil(result.error)
        XCTAssertEqual(ST.node(result, "$.list[1]")?.preview, "b")
        XCTAssertEqual(ST.problems(result.tree), [])
    }

    func testSpansAndCharacterColumns() throws {
        let result = yaml("título: café\nlist:\n  - ñandú\n")
        let item = try XCTUnwrap(ST.node(result, "$.list[0]"))
        XCTAssertEqual(item.span.line, 3)
        XCTAssertEqual(item.span.column, 5)
        XCTAssertEqual(ST.node(result, "$.título")?.preview, "café")
        let error = yaml("título: [x\n").error
        XCTAssertEqual(error?.location?.line, 2)
    }

    func testTruncatedYAMLIsPartial() {
        let full = "a: 1\nb:\n  - x\n  - y\nc: \"long"
        let result = StructuredParser.parse(Data(full.utf8), format: .yaml, fileSize: 10_000)
        XCTAssertNil(result.error)
        XCTAssertEqual(ST.node(result, "$.b[1]")?.preview, "y")
        XCTAssertFalse(result.coverage.isComplete)
    }
}
