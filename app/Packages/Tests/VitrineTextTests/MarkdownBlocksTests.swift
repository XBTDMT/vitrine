import XCTest
@testable import VitrineText

/// Markdown as values, for the README in a repository card. roadmap: S-9
final class MarkdownBlocksTests: XCTestCase {
    func testBlocksAndInlines() {
        let md = """
        ---
        title: hidden
        ---
        # Lumen *site*

        Run `npm install` then [read](https://example.com) **this**~~not~~.

        ```sh
        $ npm run dev
        ```

        > [!NOTE]
        > Keys here are examples.

        > plain quote

        1. one
        2. two

        - [x] done
        - [ ] todo

        | a | b |
        |---|---|
        | 1 | 2 |

        ---
        """
        let blocks = MarkdownBlocks.parse(md)
        XCTAssertEqual(blocks.first, .heading(level: 1, [.text("Lumen "), .emphasis([.text("site")])]), "front matter dropped")
        XCTAssertEqual(blocks[1], .paragraph([.text("Run "), .code("npm install"), .text(" then "), .link([.text("read")], url: "https://example.com"),
                                              .text(" "), .strong([.text("this")]), .strikethrough([.text("not")]), .text(".")]))
        XCTAssertEqual(blocks[2], .code(language: "sh", text: "$ npm run dev"))
        XCTAssertEqual(blocks[3], .alert(kind: "Note", [.paragraph([.text("Keys here are examples.")])]))
        XCTAssertEqual(blocks[4], .quote([.paragraph([.text("plain quote")])]))
        XCTAssertEqual(blocks[5], .list(ordered: true, start: 1, items: [([.paragraph([.text("one")])], nil), ([.paragraph([.text("two")])], nil)]))
        XCTAssertEqual(blocks[6], .list(ordered: false, start: 0, items: [([.paragraph([.text("done")])], true), ([.paragraph([.text("todo")])], false)]))
        XCTAssertEqual(blocks[7], .table(rows: [[[.text("a")], [.text("b")]], [[.text("1")], [.text("2")]]]))
        XCTAssertEqual(blocks[8], .rule)
        XCTAssertEqual(MarkdownBlocks.parse(md, maxBlocks: 2).count, 2)
        XCTAssertEqual(MarkdownBlocks.parse("").count, 0)
    }
}
