import XCTest
@testable import VitrineText

/// Minified CSS and SQL laid out for reading (S-5, C-5). All content is invented here. roadmap: S-5
final class CodeFormatterTests: XCTestCase {
    func testMinifiedCSS() throws {
        let min = ".card{color:#1d1d1f;padding:8px 12px}.card:hover,.card:focus{background:url(\"a;b.png\")}/* keep */@media (max-width:600px){.card{padding:4px}}" + String(repeating: " ", count: 80)
        let out = try XCTUnwrap(CodeFormatter.format(min, language: "css"))
        XCTAssertEqual(out, """
        .card {
          color: #1d1d1f;
          padding: 8px 12px
        }

        .card:hover,.card:focus {
          background: url("a;b.png")
        }

        /* keep */
        @media (max-width:600px) {
          .card {
            padding: 4px
          }
        }

        """)
    }

    func testMinifiedSQL() throws {
        let min = "select n.id, n.title, count(t.id) as tags from notes n left join tags t on t.note_id = n.id where n.deleted = 0 and n.title like 'Q4; %' group by n.id order by n.updated desc limit 20;" + String(repeating: " ", count: 40)
        let out = try XCTUnwrap(CodeFormatter.format(min, language: "sql"))
        XCTAssertEqual(out, """
        SELECT n.id,
          n.title,
          COUNT(t.id) AS tags
        FROM notes n
        LEFT JOIN tags t ON t.note_id = n.id
        WHERE n.deleted = 0
          AND n.title LIKE 'Q4; %'
        GROUP BY n.id
        ORDER BY n.updated DESC
        LIMIT 20;

        """)
    }

    func testOrdinaryFilesAreLeftAlone() {
        XCTAssertNil(CodeFormatter.format(".card {\n  color: red;\n}\n", language: "css"))
        XCTAssertNil(CodeFormatter.format(String(repeating: "x", count: 500), language: "swift"))
    }
}
