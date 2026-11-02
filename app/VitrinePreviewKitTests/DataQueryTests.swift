import SQLite3
import XCTest
@testable import VitrinePreviewKit
import VitrineData
import VitrineDocument
import VitrineSupport

/// The read-only query box in data previews (I-8, G-13; data 1): the capsule's find switches from Filter to SQL, a
/// SELECT's rows cover the file's in the same grid with "N rows · 12 ms" in the gutter, an error is a calm line and
/// never a crash, Cancel stops a run, and Done shows the file's own rows. All content is invented here. roadmap: S-6
@MainActor
final class DataQueryTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-query-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let orders = """
    order_id,customer,country,qty,total
    100241,Sofia Lindqvist,GB,2,534.00
    100242,Dev Patel,US,1,96.00
    100243,Mara Lindgren,GB,3,
    100244,Tomás Ruiz,ES,1,1290.50
    100245,Ilse Lindgren,US,4,48.25

    """

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func render(_ url: URL, _ kind: FileKind) async throws -> (RenderedPreview, DataView) {
        let preview = try await DataRenderer().render(url: url, kind: kind, context: RenderContext(appearance: .light, defaultsSuite: "vt-query"))
        return (preview, try XCTUnwrap(preview.view as? DataView))
    }

    private func database(_ name: String, _ sql: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        sqlite3_close(db)
        return url
    }

    private func titles(_ view: DataView) -> [String] { view.grid.table.tableColumns.map(\.title) }

    private func assertSummary(_ text: String?, rows: Int, file: StaticString = #filePath, line: UInt = #line) {
        let pattern = "^\(rows.formatted()) \(rows == 1 ? "row" : "rows") · \\d+ ms$"
        XCTAssertNotNil(text?.range(of: pattern, options: .regularExpression), "\(text ?? "nil") is not “N rows · 12 ms”", file: file, line: line)
    }

    func testCSVQueryShowsTypedResultRowsInTheSameGridThenDoneRestoresTheFile() async throws {
        let url = try write("orders.csv", orders)
        let before = try Data(contentsOf: url)
        let (preview, view) = try await render(url, .csv(delimiter: ","))
        XCTAssertEqual(preview.findModes, [.filter, .query])
        XCTAssertEqual(preview.queryPlaceholder, "SELECT * FROM orders")
        let controller = try XCTUnwrap(view.queryController)

        let outcome = try await XCTUnwrap(preview.query)(
            "SELECT country, count(*) AS orders, sum(total) AS revenue FROM orders GROUP BY country ORDER BY revenue DESC")
        XCTAssertNil(outcome.message)
        XCTAssertEqual(outcome.rows, 3)
        assertSummary(outcome.summary, rows: 3)
        assertSummary(preview.gutter?.leading, rows: 3)
        XCTAssertEqual(preview.gutter?.trailing, "Read-only · the file is never written")

        let result = try XCTUnwrap(controller.resultView)
        XCTAssertTrue(result.superview === view, "the result covers the file's rows")
        XCTAssertEqual(titles(result), ["", "country", "orders", "revenue"])
        XCTAssertEqual(result.grid.table.numberOfRows, 3)
        XCTAssertEqual((0..<3).map { result.model.cell(row: $0, column: 0).text }, ["ES", "GB", "US"])
        XCTAssertEqual((0..<3).map { result.model.cell(row: $0, column: 2).text }, ["1290.5", "534", "144.25"],
                       "sum over a numbers column is a number")
        XCTAssertTrue(result.model.isNumeric(1) && result.model.isNumeric(2) && !result.model.isNumeric(0))
        XCTAssertEqual(result.model.fileTabTitle, "Query")
        XCTAssertEqual(result.model.rowNumber(0), 1)

        // The same table answers to t, and a header click sorts the result in memory.
        _ = try await XCTUnwrap(preview.query)("SELECT customer, qty FROM t ORDER BY order_id")
        let second = try XCTUnwrap(controller.resultView)
        XCTAssertFalse(second === result, "a new result replaces the last")
        XCTAssertNil(result.superview)
        _ = await second.setSort(column: 1, ascending: false).value
        XCTAssertEqual(second.model.cell(row: 0, column: 0).text, "Ilse Lindgren")
        XCTAssertEqual(preview.gutter?.trailing, "Sorted by qty ↓")
        assertSummary(preview.gutter?.leading, rows: 5)

        // Copy as copies the result while it shows (I-7 over I-8), the file's rows once it is gone.
        let resultCopy = try XCTUnwrap(preview.copyFormats?())
        XCTAssertEqual(resultCopy.heading, "Copy all 5 rows as")
        XCTAssertEqual(resultCopy.formats[0].text().components(separatedBy: "\n").first, "customer,qty")

        preview.clearQuery?()
        XCTAssertNil(controller.resultView)
        XCTAssertNil(second.superview)
        XCTAssertEqual(preview.copyFormats?().formats[0].text().components(separatedBy: "\n").first,
                       "order_id,customer,country,qty,total")
        XCTAssertEqual(view.grid.table.numberOfRows, 5, "the file's own rows again")
        XCTAssertNotEqual(preview.gutter?.trailing, "Read-only · the file is never written")
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testErrorsAreCalmLinesAndTheGridStays() async throws {
        let url = try write("orders.csv", orders)
        let (preview, view) = try await render(url, .csv(delimiter: ","))
        let query = try XCTUnwrap(preview.query)

        let refused = await query("DELETE FROM orders")
        XCTAssertNil(refused.rows)
        XCTAssertEqual(refused.message, "Read-only: DELETE is not allowed. Only SELECT queries run, and the file is never written.")
        XCTAssertEqual(preview.gutter?.leading, refused.message)
        XCTAssertNil(view.queryController?.resultView, "nothing covers the file's rows")
        XCTAssertEqual(view.grid.table.numberOfRows, 5)

        let two = await query("SELECT 1; SELECT 2")
        XCTAssertEqual(two.message, "One statement at a time: remove everything after the first semicolon.")
        let typo = await query("SELECT * FROM ordrs")
        XCTAssertEqual(typo.message, "No such table: ordrs")

        // A good query after an error shows its rows; an error after it leaves them.
        _ = await query("SELECT * FROM t WHERE total > 100")
        XCTAssertEqual(view.queryController?.resultView?.grid.table.numberOfRows, 2)
        _ = await query("SELEC")
        XCTAssertEqual(view.queryController?.resultView?.grid.table.numberOfRows, 2)
        XCTAssertFalse(preview.gutter?.leading?.isEmpty ?? true)
    }

    func testSQLiteQueryReadsTheFileAndNeverWritesIt() async throws {
        let url = try database("acme-notes.sqlite", """
        CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL, word_count INTEGER, pinned INTEGER);
        CREATE TABLE "folder list" (id INTEGER PRIMARY KEY, name TEXT);
        INSERT INTO notes VALUES (1, 'Q4 launch checklist', 2015, 1), (2, 'Grocery run', NULL, 0), (3, 'Packing list: Kyoto', 697, 1);
        """)
        let before = try Data(contentsOf: url)
        let (preview, view) = try await render(url, .sqlite)
        XCTAssertEqual(preview.queryPlaceholder, "SELECT * FROM notes")
        let query = try XCTUnwrap(preview.query)

        let outcome = await query("SELECT title, word_count FROM notes WHERE pinned = 1 ORDER BY id")
        XCTAssertEqual(outcome.rows, 2)
        let result = try XCTUnwrap(view.queryController?.resultView)
        XCTAssertEqual(titles(result), ["", "title", "word_count"])
        XCTAssertTrue(result.model.isNumeric(1), "the declared INTEGER keeps numbers right-aligned")
        XCTAssertEqual(result.model.cell(row: 1, column: 0).text, "Packing list: Kyoto")
        XCTAssertEqual(result.model.columnEntries(1).first?.value, "INTEGER")
        XCTAssertEqual(result.model.fileEntries().first?.value, "SELECT title, word_count FROM notes WHERE pinned = 1 ORDER BY id")

        for sql in ["UPDATE notes SET title = 'x'", "DROP TABLE notes", "PRAGMA user_version = 3", "ATTACH 'x.db' AS x"] {
            let r = await query(sql)
            XCTAssertTrue(r.message?.hasPrefix("Read-only:") ?? false, "\(sql) → \(r.message ?? "ran")")
        }
        XCTAssertEqual(try Data(contentsOf: url), before, "byte-for-byte unchanged")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["acme-notes.sqlite"], "no siblings created")
    }

    func testCancelStopsAnEndlessQuery() async throws {
        let url = try write("orders.csv", orders)
        let (preview, view) = try await render(url, .csv(delimiter: ","))
        let controller = try XCTUnwrap(view.queryController)
        let query = try XCTUnwrap(preview.query)
        _ = await query("SELECT 1")
        let run = Task { await query("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c") }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controller.running)
        XCTAssertEqual(preview.gutter?.busy, true, "the gutter shows Cancel while it runs")
        XCTAssertEqual(preview.gutter?.trailing, "Running query…")
        preview.cancelWork?()
        let outcome = await run.value
        XCTAssertEqual(outcome.message, "Query cancelled.")
        XCTAssertFalse(controller.running)
        XCTAssertEqual(preview.gutter?.busy, false)
    }

    func testTheBudgetStopsAnEndlessQuery() async throws {
        let url = try write("orders.csv", orders)
        let (preview, view) = try await render(url, .csv(delimiter: ","))
        view.queryController?.limits.budget = 0.3
        let outcome = try await XCTUnwrap(preview.query)("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c")
        XCTAssertEqual(outcome.message, "The query ran past 0.3 s and was stopped.")
    }

    func testResultsPageAndCapHonestly() async throws {
        let url = try write("orders.csv", orders)
        let (preview, view) = try await render(url, .csv(delimiter: ","))
        view.queryController?.limits.maxRows = 1_000
        let outcome = try await XCTUnwrap(preview.query)(
            "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 2500) SELECT x, 'row ' || x AS label FROM c")
        XCTAssertEqual(outcome.rows, 1_000)
        XCTAssertEqual(outcome.total, 2_500)
        XCTAssertTrue(outcome.summary.hasPrefix("First 1,000 of 2,500 rows · "), outcome.summary)
        let result = try XCTUnwrap(view.queryController?.resultView)
        XCTAssertEqual(result.grid.table.numberOfRows, 1_000)
        XCTAssertEqual(result.model.cell(row: 0, column: 1).text, "row 1")
        XCTAssertEqual(result.model.cell(row: 750, column: 1).text, "row 751")
        XCTAssertEqual(result.model.cell(row: 999, column: 0).text, "1000")
        XCTAssertTrue(result.model.fileEntries().contains { $0.label == "Held" })
    }

    func testACSVOverTheBoundSaysSoHonestly() async throws {
        let url = try write("orders.csv", orders)
        let (preview, view) = try await render(url, .csv(delimiter: ","))
        view.queryController?.limits.csvMaxBytes = 64
        let outcome = try await XCTUnwrap(preview.query)("SELECT count(*) FROM t")
        let message = try XCTUnwrap(outcome.message)
        XCTAssertTrue(message.hasPrefix("SQL runs on files up to 64 bytes; this one is "), message)
        XCTAssertTrue(message.hasSuffix("Filter still searches every row."))
        XCTAssertEqual(preview.gutter?.leading, message)
        XCTAssertEqual(view.grid.table.numberOfRows, 5, "the file's rows stay")
    }

    func testCapsuleSwitchesModesAndRunsOnReturnOnly() async throws {
        let m = CapsuleModel()
        m.show(PreviewDocument(kind: .csv(delimiter: ","), views: [.text("a,b")]), canToggleInspector: true, canFind: true)
        m.findModes = [.filter, .query]
        m.findStyle = .filter
        var ran: [String] = []
        var filtered: [String] = []
        var cleared = 0
        m.onQuery = { sql in ran.append(sql); return QueryOutcome(rows: 8, milliseconds: 41) }
        m.onFind = { q, _ in filtered.append(q); return FindResult(count: 1, index: 0) }
        m.onClearFind = { cleared += 1 }
        m.openFind()
        XCTAssertEqual(m.findModeTitle, "Filter")
        m.findQuery = "GB"
        await m.find()
        XCTAssertEqual(filtered, ["GB"])

        m.setFindMode(.query)
        XCTAssertEqual(m.findStyle, .query)
        XCTAssertEqual(m.findModeTitle, "SQL")
        XCTAssertEqual(cleared, 1, "switching leaves the filter")
        XCTAssertEqual(m.findQuery, "")
        m.findQuery = "SELECT country FROM t"
        await m.find()
        XCTAssertEqual(filtered, ["GB"], "typing never filters in the Query mode")
        XCTAssertTrue(ran.isEmpty, "and never runs: Return does")
        await m.runQuery()
        XCTAssertEqual(ran, ["SELECT country FROM t"])
        XCTAssertEqual(m.findCountText, "8 rows · 41 ms")

        m.onQuery = { _ in .failed("Read-only: INSERT is not allowed.") }
        await m.runQuery()
        XCTAssertEqual(m.findCountText, "Didn't run")
        XCTAssertEqual(m.queryFailure, m.queryOutcome?.message, "the field says why, in the engine's words")
        XCTAssertNotNil(m.queryFailure)

        m.closeFind()
        XCTAssertEqual(cleared, 2)
        XCTAssertEqual(m.findStyle, .filter, "the next ⌘F opens on Filter")
        XCTAssertNil(m.findCountText)
        XCTAssertEqual(QueryOutcome(rows: 100_000, total: nil, isCapped: true, milliseconds: 15_200).summary, "First 100,000 rows · 15.2 s")
    }

    func testTheHostRoutesTheQueryModeAndDoneRestoresTheRows() async throws {
        let url = try write("orders.csv", orders)
        let c = PreviewHostController()
        c.loadView()
        c.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        try await c.preparePreviewOfFile(at: url)
        let m = c.capsuleForTesting
        XCTAssertEqual(m.findModes, [.filter, .query])
        XCTAssertEqual(m.queryPlaceholder, "SELECT * FROM orders")
        let view = try XCTUnwrap(c.view.allSubviews.compactMap { $0 as? DataView }.first)
        m.openFind()
        m.setFindMode(.query)
        m.findQuery = "SELECT sum(qty) AS units FROM orders"
        await m.runQuery()
        assertSummary(m.findCountText, rows: 1)
        assertSummary(m.gutterLeading, rows: 1)
        let result = try XCTUnwrap(view.queryController?.resultView)
        XCTAssertEqual(result.model.cell(row: 0, column: 0).text, "11")
        m.closeFind()
        XCTAssertNil(view.queryController?.resultView, "Done shows the file's own rows")
        XCTAssertEqual(m.findStyle, .filter)
        XCTAssertNotEqual(m.gutter?.trailing, "Read-only · the file is never written")
    }
}
