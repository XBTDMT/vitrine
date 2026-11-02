import XCTest
@testable import VitrineCompare
import VitrineSupport

/// marimo notebooks read from their Python text (A-8): cells in file order, Markdown cells, hide_code, the closing
/// return, nested triple quotes, function, setup and unparsable cells, and the app's options. Every notebook here is
/// invented in the test; nothing is run. roadmap: S-21
final class MarimoReaderTests: XCTestCase {
    static let q3 = "\"\"\""

    /// A notebook as marimo 0.9 writes one.
    static let orders = """
    import marimo

    __generated_with = "0.9.14"
    app = marimo.App(width="medium", app_title="Orders explorer")


    @app.cell
    def __():
        import marimo as mo
        return (mo,)


    @app.cell(hide_code=True)
    def __(mo):
        mo.md(
            r\(q3)
            # Orders by week

            Invented sample: *orders.parquet*.
            \(q3)
        )
        return


    @app.cell
    def load_orders(pl):
        orders = pl.read_parquet("orders.parquet")
        orders.head()
        return (orders,)


    @app.cell(hide_code=True)
    def slider(mo):
        days = mo.ui.slider(1, 30, label="Days")
        days
        return days,


    @app.cell
    def __(days, orders):
        def summary(frame):
            return frame.tail(days.value)

        summary(orders)
        return (summary,)


    if __name__ == "__main__":
        app.run()
    """

    func testCellsInFileOrderWithNamesAndCode() throws {
        let nb = try MarimoReader.read(Data(Self.orders.utf8))
        XCTAssertEqual(nb.version, "0.9.14")
        XCTAssertEqual(nb.width, "medium")
        XCTAssertEqual(nb.title, "Orders explorer")
        XCTAssertEqual(nb.cells.map(\.kind), [.code, .markdown, .code, .code, .code])
        XCTAssertEqual(nb.cells.map(\.name), ["__", "__", "load_orders", "slider", "__"])
        XCTAssertEqual(nb.cells.map(\.isNamed), [false, false, true, true, false])
        XCTAssertEqual(nb.cells[0].code, "import marimo as mo", "the re-export return is dropped")
        XCTAssertEqual(nb.cells[2].code, "orders = pl.read_parquet(\"orders.parquet\")\norders.head()")
        XCTAssertEqual(nb.cells[3].code, "days = mo.ui.slider(1, 30, label=\"Days\")\ndays", "a bare tuple return is dropped too")
        // A return inside a nested function stays; the cell's own closing return goes.
        XCTAssertEqual(nb.cells[4].code, "def summary(frame):\n    return frame.tail(days.value)\n\nsummary(orders)")
        XCTAssertEqual(nb.totalCells, 5)
        XCTAssertFalse(nb.cut)
    }

    func testMarkdownCellsAreCleanedAsMoMdCleansThem() throws {
        let nb = try MarimoReader.read(Data(Self.orders.utf8))
        XCTAssertEqual(nb.cells[1].markdown, "# Orders by week\n\nInvented sample: *orders.parquet*.")
        XCTAssertEqual(MarimoReader.markdownCall("mo.md(\"Plain *one* line\\nand an escape\")"), "Plain *one* line\nand an escape")
        XCTAssertEqual(MarimoReader.markdownCall("mo.md(r'A raw \\n stays')"), "A raw \\n stays")
        XCTAssertEqual(MarimoReader.markdownCall("mo.md(f\"Total: {total} {{literal}}\")"), "Total: {total} {literal}", "f-string fields kept as written")
        XCTAssertEqual(MarimoReader.markdownCall("mo.md(\"a \" \"b\")"), "a b", "adjacent literals join")
        XCTAssertNil(MarimoReader.markdownCall("mo.md(f\"x\").center()"), "anything more than the call is code")
        XCTAssertNil(MarimoReader.markdownCall("mo.md(text)"), "a variable is code")
        XCTAssertNil(MarimoReader.markdownCall("x = 1"))
    }

    func testHideCode() throws {
        let nb = try MarimoReader.read(Data(Self.orders.utf8))
        XCTAssertEqual(nb.cells.map(\.hideCode), [false, true, false, true, false])
    }

    /// Strings that hold marimo's own markers, quotes of the other kind and lines at the left margin do not end or
    /// start cells.
    func testNestedTripleQuotesDoNotSplitCells() throws {
        let q = Self.q3
        let text = """
        import marimo

        app = marimo.App()


        @app.cell
        def __():
            sql = \(q)
        select *
        @app.cell
        def fake():
            from 'orders' -- it's ''' here
        \(q)
            note = '''single "\(q)" inside'''
            return


        @app.cell
        def __(mo):
            mo.md(r'''
            A quote: \(q)not the end\(q)
            ''')
            return


        if __name__ == "__main__":
            app.run()
        """
        let nb = try MarimoReader.read(Data(text.utf8))
        XCTAssertEqual(nb.cells.count, 2, "\(nb.cells.map(\.name))")
        XCTAssertEqual(nb.cells[0].kind, .code)
        XCTAssertTrue(nb.cells[0].code.contains("@app.cell\ndef fake():"), nb.cells[0].code)
        XCTAssertTrue(nb.cells[0].code.hasSuffix("note = '''single \"\(q)\" inside'''"), nb.cells[0].code)
        XCTAssertEqual(nb.cells[1].kind, .markdown)
        XCTAssertEqual(nb.cells[1].markdown, "A quote: \(q)not the end\(q)")
    }

    func testFunctionSetupAndUnparsableCells() throws {
        let q = Self.q3
        let text = """
        import marimo

        __generated_with = "0.13.0"
        app = marimo.App(width="full")

        with app.setup:
            import polars as pl


        @app.function
        def double(x):
            return x * 2


        @app.class_definition
        class Point:
            x: int


        app._unparsable_cell(
            r\(q)
            total = (
            \(q),
            name="broken"
        )


        @app.cell
        def _():
            return
        """
        let nb = try MarimoReader.read(Data(text.utf8))
        XCTAssertEqual(nb.cells.map(\.origin), [.setup, .function, .classDefinition, .unparsable, .cell])
        XCTAssertEqual(nb.cells.map(\.name), ["setup", "double", "Point", "broken", "_"])
        XCTAssertEqual(nb.cells[0].code, "import polars as pl")
        XCTAssertEqual(nb.cells[1].code, "def double(x):\n    return x * 2", "a function cell is the definition itself")
        XCTAssertEqual(nb.cells[2].code, "class Point:\n    x: int")
        XCTAssertEqual(nb.cells[3].code, "total = (")
        XCTAssertEqual(nb.cells[4].code, "", "an empty cell")
        XCTAssertEqual(nb.width, "full")
        XCTAssertNil(nb.title)
    }

    func testOptionsAndLimits() throws {
        let opts = MarimoReader.keywordArguments("app = marimo.App(width=\"compact\", css_file='a, b.css', layout_file=None, extra=[1, (2, 3)])")
        XCTAssertEqual(opts.map(\.key), ["width", "css_file", "layout_file", "extra"])
        XCTAssertEqual(opts.map(\.value), ["compact", "a, b.css", "None", "[1, (2, 3)]"])

        var many = "import marimo\napp = marimo.App()\n"
        for i in 0..<12 { many += "\n@app.cell\ndef c\(i)():\n    x = \(i)\n    return\n" }
        let nb = MarimoReader.read(many, limits: MarimoReader.Limits(maxCells: 10))
        XCTAssertTrue(nb.cut)
        XCTAssertEqual(nb.cells.count, 10)
        XCTAssertEqual(nb.totalCells, 12)
        XCTAssertNil(nb.version, "__generated_with is optional")
        XCTAssertThrowsError(try MarimoReader.read(Data(many.utf8), limits: MarimoReader.Limits(maxInputBytes: 10)))
    }

    func testPlainPythonIsNotAMarimoNotebook() {
        let plain = "import os\n\ndef main():\n    print(os.getcwd())\n\nif __name__ == \"__main__\":\n    main()\n"
        XCTAssertThrowsError(try MarimoReader.read(Data(plain.utf8))) { error in
            XCTAssertEqual((error as? CompareError)?.kind, .malformed)
        }
        XCTAssertFalse(FileSniffer.looksLikeMarimo(Data(plain.utf8)))
    }

    func testReturnReExportRule() {
        XCTAssertTrue(MarimoReader.Source.onlyReExports("return"))
        XCTAssertTrue(MarimoReader.Source.onlyReExports("return (a, b,)"))
        XCTAssertTrue(MarimoReader.Source.onlyReExports("return (\n    a,\n    b,\n)"))
        XCTAssertTrue(MarimoReader.Source.onlyReExports("return x,  # names"))
        XCTAssertFalse(MarimoReader.Source.onlyReExports("return mo.md(\"x\")"))
        XCTAssertFalse(MarimoReader.Source.onlyReExports("return_value = 3"))
        XCTAssertFalse(MarimoReader.Source.onlyReExports("return a + b"))
    }

    func testCleandoc() {
        XCTAssertEqual(MarimoReader.cleandoc("\n    # T\n\n      indented\n    "), "# T\n\n  indented")
        XCTAssertEqual(MarimoReader.cleandoc("first\n    second"), "first\nsecond")
    }
}
