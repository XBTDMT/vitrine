import XCTest
@testable import VitrineCompare

/// S-16 hardening (F57): marimo headers, app calls and Markdown cells written to make the reader's text handling
/// quadratic. Each pathological notebook used to run for minutes; each must now finish within a tight budget and
/// still read ordinary notebooks the same. Every notebook is invented here. roadmap: S-16
final class S16ParsersCompareTests: XCTestCase {
    private let head = "import marimo\napp = marimo.App()\n\n"

    private func timed(_ body: () throws -> Void) rethrows -> Duration {
        let clock = ContinuousClock(), start = clock.now
        try body()
        return clock.now - start
    }

    func testDefHeaderOfManyParenthesesAndNoColonIsLinear() {
        // `def _()` then 1.2 MB of ")->" with no colon: every ")" restarted the old pattern over the whole header.
        let text = head + "@app.cell\ndef _()" + String(repeating: ")->", count: 400_000) + "\n"
        var notebook: MarimoReader.Notebook?
        let took = timed { notebook = MarimoReader.read(text) }
        XCTAssertLessThan(took, .seconds(2))
        XCTAssertEqual(notebook?.cells.count, 1)
        XCTAssertEqual(notebook?.cells.first?.code, "", "no colon, so no inline body")
    }

    func testManyLiteralsInTheAppCallAndInAMarkdownCellAreLinear() {
        let call = "app = marimo.App(" + String(repeating: "x=\"\", ", count: 100_000) + "width=\"full\")\n"
        let markdown = "@app.cell\ndef _():\n    mo.md(" + String(repeating: "\"a\" ", count: 100_000) + ")\n    return\n"
        var notebook: MarimoReader.Notebook?
        let took = timed { notebook = MarimoReader.read("import marimo\n" + call + "\n" + markdown) }
        XCTAssertLessThan(took, .seconds(2))
        XCTAssertEqual(notebook?.width, "full")
        XCTAssertEqual(notebook?.cells.first?.kind, .markdown)
        XCTAssertEqual(notebook?.cells.first?.markdown?.count, 100_000)
    }

    func testTheHeaderScanMatchesThePatternItReplaces() {
        let pattern = #"\)\s*(->[^:]*)?:"#
        let headers = [
            "def _(): return x", "def _():", "def _()", "def _(a: int) -> dict[str, int]: x = 1",
            "def _(x=f()):  y", "def _(a, b) ->  T : z", "def _() -> : w", "def _()) : v", "def _() - > : u",
            "def f(a=(1, 2)): pass", "def _(\n    a,\n    b,\n): return a", "def _() -> \"x\": q", "def _(): a: int = 1",
            "def _()\t:\tt", "(:)", "):", ") ->", "", ")", ":",
        ]
        for header in headers {
            let expected = header.range(of: pattern, options: [.regularExpression, .backwards]).map { String(header[$0.upperBound...]) }
            XCTAssertEqual(MarimoReader.Source.textAfterHeaderColon(header), expected, header)
        }
    }

    func testOrdinaryCellsKeepTheirInlineBodiesAndLiterals() {
        let text = head + "@app.cell\ndef _(): return\n\n@app.cell\ndef _():\n    mo.md(r\"\"\"# Title\"\"\" \"more\")\n    return\n"
        let notebook = MarimoReader.read(text)
        XCTAssertEqual(notebook.cells.count, 2)
        XCTAssertEqual(notebook.cells[1].markdown, "# Titlemore")
        XCTAssertEqual(MarimoReader.keywordArguments("marimo.App(width=\"medium\", app_title='A, b', n=[1, 2])").map(\.value),
                       ["medium", "A, b", "[1, 2]"])
    }
}
