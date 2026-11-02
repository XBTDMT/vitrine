import SQLite3
import XCTest
@testable import VitrinePreviewKit
import VitrineSupport

/// Filter and sort in the data table (I-4, data 1 and 2): find keeps the matching rows and marks them, CSV keeps its
/// row numbers, a header click sorts, the gutter says where you are and what is applied, and Cancel stops long work.
/// All content is invented here. roadmap: S-6
@MainActor
final class DataArrangeTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-arrange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func render(_ name: String, _ text: String, _ kind: FileKind) async throws -> (RenderedPreview, DataView) {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let preview = try await DataRenderer().render(url: url, kind: kind, context: RenderContext(appearance: .light, defaultsSuite: "vt-arrange"))
        return (preview, try XCTUnwrap(preview.view as? DataView))
    }

    private let orders = """
    order_id,customer,country,total
    100241,Sofia Lindqvist,GB,534.00
    100242,Dev Patel,US,96.00
    100243,Mara Lindgren,GB,
    100244,Tomás Ruiz,ES,1290.50
    100245,Ilse Lindgren,US,48.00

    """

    private func cellText(_ view: DataView, row: Int, column: Int) throws -> DataCell {
        try XCTUnwrap(view.grid.table.view(atColumn: column, row: row, makeIfNecessary: true) as? DataCell)
    }

    func testFindFiltersRowsKeepsTheirNumbersAndMarksMatches() async throws {
        let (preview, view) = try await render("orders.csv", orders, .csv(delimiter: ","))
        XCTAssertEqual(preview.findStyle, .filter)
        XCTAssertTrue(view.inspector.isHidden, "a file of one table opens with the Inspector closed")

        let result = try await XCTUnwrap(preview.find)("lind", true)
        XCTAssertEqual(result, FindResult(count: 3, index: 0, searchedAll: true))
        XCTAssertEqual(view.grid.table.numberOfRows, 3)
        XCTAssertEqual(try cellText(view, row: 1, column: 0).label.stringValue, "3", "the row keeps its number in the file")
        let name = try cellText(view, row: 1, column: 2)
        XCTAssertEqual(name.label.stringValue, "Mara Lindgren")
        var marked = false
        name.label.attributedStringValue.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: 13)) { value, _, _ in
            if value != nil { marked = true }
        }
        XCTAssertTrue(marked, "the match is marked")
        XCTAssertEqual(preview.gutter?.leading, "3 of 5 rows match")

        // Accents fold: "tomas" finds "Tomás".
        _ = try await XCTUnwrap(preview.find)("tomas", true)
        XCTAssertEqual(view.grid.table.numberOfRows, 1)
        preview.clearFind?()
        _ = await view.filter("")
        XCTAssertEqual(view.grid.table.numberOfRows, 5)
        XCTAssertNotEqual(preview.gutter?.leading, "1 of 5 rows match")
    }

    func testHeaderClicksSortNumbersWithEmptyCellsLast() async throws {
        let (preview, view) = try await render("orders.csv", orders, .csv(delimiter: ","))
        let grid = view.grid
        let total = grid.table.tableColumns[4]
        grid.tableView(grid.table, didClick: total)
        XCTAssertEqual(grid.selectedColumn, 3, "the first click selects the column")
        XCTAssertFalse(view.inspector.isHidden, "and opens the Inspector")
        XCTAssertNil(view.model.arrangement.sortColumn)

        grid.tableView(grid.table, didClick: total)
        XCTAssertEqual(view.sort?.column, 3)
        XCTAssertEqual(view.sort?.ascending, true)
        _ = await view.setSort(column: 3, ascending: true).value
        XCTAssertEqual((0..<5).map { view.model.cell(row: $0, column: 3).text }, ["48.00", "96.00", "534.00", "1290.50", ""])
        XCTAssertEqual((total.headerCell as? DataHeaderCell)?.sort, true)
        XCTAssertEqual(preview.gutter?.trailing, "Sorted by total ↑")

        _ = await view.setSort(column: 3, ascending: false).value
        XCTAssertEqual((0..<5).map { view.model.cell(row: $0, column: 3).text }, ["1290.50", "534.00", "96.00", "48.00", ""],
                       "empty cells stay last either way")
        XCTAssertEqual(try cellText(view, row: 0, column: 0).label.stringValue, "4")
        XCTAssertEqual(preview.gutter?.trailing, "Sorted by total ↓")

        _ = await view.setSort(column: 1, ascending: true).value
        XCTAssertEqual((0..<5).map { view.model.cell(row: $0, column: 1).text },
                       ["Dev Patel", "Ilse Lindgren", "Mara Lindgren", "Sofia Lindqvist", "Tomás Ruiz"])

        _ = await view.setSort(column: 1, ascending: nil).value
        XCTAssertEqual(view.model.cell(row: 0, column: 0).text, "100241", "file order again")
        XCTAssertNil((grid.table.tableColumns[2].headerCell as? DataHeaderCell)?.sort)
    }

    func testSortAndFilterTogetherAndTheRowReadout() async throws {
        var text = "n,label,amount\n"
        for i in 0..<3_000 { text += "\(i),item \(i),\((i * 37) % 1000)\n" }
        let (preview, view) = try await render("big.csv", text, .csv(delimiter: ","))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        view.updateGutter()
        // "Rows 1–N of 3,000" (data 2): the rows in view.
        XCTAssertTrue(preview.gutter?.leading?.hasPrefix("Rows 1–") ?? false, preview.gutter?.leading ?? "")
        XCTAssertTrue(preview.gutter?.leading?.hasSuffix(" of 3,000") ?? false)

        _ = await view.filter("item 1")
        _ = await view.setSort(column: 2, ascending: false).value
        XCTAssertEqual(view.model.shownCount, 1_111, "item 1, item 10…19, item 100…199, item 1000…1999")
        let amounts = (0..<view.model.shownCount).map { Int(view.model.cell(row: $0, column: 2).text)! }
        XCTAssertEqual(amounts, amounts.sorted(by: >))
        XCTAssertEqual(preview.gutter?.leading, "1,111 of 3,000 rows match")
        XCTAssertEqual(preview.gutter?.trailing, "Sorted by amount ↓")
    }

    func testCancelKeepsWhatWasApplied() async throws {
        var text = "n,label\n"
        for i in 0..<20_000 { text += "\(i),item \(i)\n" }
        let (preview, view) = try await render("big.csv", text, .csv(delimiter: ","))
        let task = view.setSort(column: 1, ascending: false)
        XCTAssertEqual(view.busy, "Sorting by label…")
        XCTAssertEqual(preview.gutter?.busy, true)
        preview.cancelWork?()
        let done = await task.value
        XCTAssertFalse(done)
        XCTAssertNil(view.busy)
        XCTAssertNil(view.model.arrangement.sortColumn, "nothing was applied")
        XCTAssertNil(view.sort)
        XCTAssertEqual(view.model.cell(row: 0, column: 0).text, "0")
        XCTAssertEqual(preview.gutter?.busy, false)
    }

    func testSQLiteFilterSortAndAnotherTable() async throws {
        let url = dir.appendingPathComponent("acme-notes.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT, words INTEGER);
        CREATE TABLE folders (id INTEGER PRIMARY KEY, name TEXT);
        CREATE VIEW long_notes AS SELECT title, words FROM notes WHERE words > 100;
        INSERT INTO notes VALUES (1, 'Q4 launch checklist', 2015), (2, 'Grocery run', 40), (3, 'Packing list: Kyoto', 697);
        INSERT INTO folders VALUES (1, 'Work'), (2, 'Home');
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let preview = try await DataRenderer().render(url: url, kind: .sqlite, context: RenderContext(appearance: .light, defaultsSuite: "vt-arrange"))
        let view = try XCTUnwrap(preview.view as? DataView)
        XCTAssertFalse(view.inspector.isHidden, "a file with parts opens with the Database tab showing")

        let result = try await XCTUnwrap(preview.find)("list", true)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(view.grid.table.numberOfRows, 2)
        _ = await view.setSort(column: 2, ascending: true).value
        XCTAssertEqual((0..<2).map { view.model.cell(row: $0, column: 1).text }, ["Packing list: Kyoto", "Q4 launch checklist"])
        XCTAssertEqual(preview.gutter?.leading, "2 of 3 rows match")

        // The view: sorted and filtered pages through ORDER BY … OFFSET.
        let model = try XCTUnwrap(view.model as? SQLiteDataModel)
        model.selectPart(2)
        XCTAssertNil(view.sort, "another table drops the sort")
        _ = await view.filter("list")
        _ = await view.setSort(column: 1, ascending: false).value
        XCTAssertEqual((0..<view.model.shownCount).map { view.model.cell(row: $0, column: 1).text }, ["2015", "697"])
    }
}
