import SQLite3
import XCTest
@testable import VitrinePreviewKit
import VitrineSupport

/// The data table's remaining tools (S-6): header type tags and tooltips (G12, D-2), the column profile's chart
/// (I-5), the record view and the selection's aggregates (I-4), Copy as (I-7), the lint banner (I-6) and SQLite's
/// drawn schema (D-2). All content is invented here. roadmap: S-6
@MainActor
final class DataToolsTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func render(_ name: String, _ text: String) async throws -> (RenderedPreview, DataView) {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let preview = try await DataRenderer().render(url: url, kind: .csv(delimiter: ","), context: RenderContext(appearance: .light, defaultsSuite: "vt-tools"))
        let view = try XCTUnwrap(preview.view as? DataView)
        if let model = view.model as? DataModel { await model.waitForIndex() }
        return (preview, view)
    }

    /// 40 invented orders: a category country, emails, a few bad quantities.
    private var orders: String {
        var text = "order_id,customer,country,qty,total,email\n"
        let countries = ["US", "GB", "FR", "DE"]
        for i in 0..<40 {
            let qty = i == 9 ? "two" : (i == 22 ? "—" : String(1 + i % 4))
            text += "\(100_240 + i),Customer \(i),\(countries[i % 4]),\(qty),\(Double(8 * (1 + i % 5))),c\(i)@example.com\n"
        }
        return text
    }

    func testHeaderTagsAndTooltips() async throws {
        let (_, view) = try await render("orders.csv", orders)
        let model = view.model
        XCTAssertEqual((0..<model.columnCount).map(model.typeTag), ["123", "Aa", "≡", "123", "1.5", "@"])
        let qtyHeader = try XCTUnwrap(view.grid.table.tableColumns[4].headerCell as? DataHeaderCell)
        XCTAssertEqual(qtyHeader.typeTag, "123")
        XCTAssertEqual(view.grid.table.tableColumns[4].headerToolTip, "qty · Integer · 2 of 40 sampled values don't fit")
        XCTAssertEqual(view.grid.table.tableColumns.first?.headerToolTip, nil, "the row-number gutter has none")
    }

    func testColumnProfileChartAndRecordView() async throws {
        let (preview, view) = try await render("orders.csv", orders)
        let chart = try XCTUnwrap(view.model.columnChart(3))
        XCTAssertEqual(chart.histogram.reduce(0, +), 38, "every value that fits is in a bin")
        XCTAssertEqual(chart.low, "1")
        XCTAssertEqual(chart.high, "4")
        XCTAssertEqual(chart.valid, 38)
        XCTAssertEqual(chart.misfit, 2)
        XCTAssertEqual(chart.note, "2 values are not numbers: “two”, “—”")
        XCTAssertEqual(chart.top.first?.count, 10)

        view.grid.selectColumn(3)
        XCTAssertFalse(view.inspector.isHidden)
        let column = Dictionary(uniqueKeysWithValues: view.inspector.entries.map { ($0.label, $0.value) })
        XCTAssertEqual(column["Median"], "2.5", "38 values: the middle two are 2 and 3")
        XCTAssertEqual(preview.gutter?.trailing, "Column qty")

        view.inspector.show(.row(4))
        XCTAssertEqual(view.inspector.entries.first?.value, "100244")
        XCTAssertEqual(view.inspector.entries.count, 6, "the record view lists every field")
    }

    func testSelectionAggregatesAndCopyAs() async throws {
        let (preview, view) = try await render("orders.csv", orders)
        view.grid.selectColumn(4)                                  // total
        view.grid.table.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
        view.updateGutter()
        XCTAssertEqual(preview.gutter?.trailing, "3 cells · Sum 48 · Average 16 · Min 8 · Max 24")

        let offer = try XCTUnwrap(preview.copyFormats?())
        XCTAssertEqual(offer.heading, "Copy 3 cells as")
        XCTAssertEqual(offer.formats.map(\.title), ["CSV", "TSV", "Markdown table", "JSON", "SQL INSERT"])
        let text = Dictionary(uniqueKeysWithValues: offer.formats.map { ($0.title, $0.text()) })
        XCTAssertEqual(text["CSV"], "total\n8.0\n16.0\n24.0\n")
        XCTAssertEqual(text["Markdown table"], "| total |\n|---:|\n| 8.0 |\n| 16.0 |\n| 24.0 |\n")
        XCTAssertEqual(text["SQL INSERT"]?.components(separatedBy: "\n").first, "INSERT INTO \"orders\" (\"total\") VALUES (8);")
        XCTAssertTrue(text["JSON"]?.contains("\"total\" : 16") ?? false, text["JSON"] ?? "")

        // The corner header clears the column: rows alone copy every column.
        view.grid.tableView(view.grid.table, didClick: view.grid.table.tableColumns[0])
        XCTAssertNil(view.grid.selectedColumn)
        view.grid.table.deselectAll(nil)
        view.grid.table.selectRowIndexes(IndexSet([9]), byExtendingSelection: false)
        let rowOffer = try XCTUnwrap(preview.copyFormats?())
        XCTAssertEqual(rowOffer.heading, "Copy 1 row as")
    }

    func testLintBannerStepsThroughRaggedRows() async throws {
        var text = "a,b,c,d\n"
        for i in 0..<30 { text += i == 4 || i == 17 ? "\(i),x,y,z,extra\n" : "\(i),x,y,z\n" }
        let (preview, view) = try await render("ragged.csv", text)
        let lint = try XCTUnwrap(view.model.lint)
        XCTAssertEqual(lint.message, "2 of 30 rows have 5 fields instead of 4.")
        XCTAssertEqual(lint.rows, [4, 17])
        XCTAssertFalse(view.banner.isHidden)
        view.nextIssue()
        XCTAssertEqual(view.grid.table.selectedRow, 4)
        view.nextIssue()
        XCTAssertEqual(view.grid.table.selectedRow, 17)
        XCTAssertTrue(view.banner.detail.stringValue.contains("2 of 2"))
        let file = Dictionary(uniqueKeysWithValues: view.model.fileEntries().map { ($0.label, $0.value) })
        XCTAssertEqual(file["Wrong field count"], "5 · 18")
        XCTAssertEqual(preview.document.viewTitles, ["Table", "Text"])
        var requested: Int?
        preview.viewRequested = { requested = $0 }
        view.onTextView?()
        XCTAssertEqual(requested, 1, "Text view asks the frame for the file as stored")

        let (_, clean) = try await render("clean.csv", "a,b\n1,2\n")
        XCTAssertNil(clean.model.lint)
        XCTAssertTrue(clean.banner.isHidden)
    }

    func testSQLiteSchemaViewTooltipsAndTags() async throws {
        let url = dir.appendingPathComponent("acme-notes.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE folders (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
          title TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, cover BLOB);
        CREATE INDEX idx_notes_folder ON notes(folder_id);
        CREATE TRIGGER notes_touch AFTER UPDATE ON notes BEGIN SELECT 1; END;
        INSERT INTO folders VALUES (1, 'Work');
        INSERT INTO notes (folder_id, title) VALUES (1, 'Q4 launch checklist'), (1, 'Grocery run');
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let preview = try await DataRenderer().render(url: url, kind: .sqlite, context: RenderContext(appearance: .light, defaultsSuite: "vt-tools"))
        let view = try XCTUnwrap(preview.view as? DataView)
        let model = try XCTUnwrap(view.model as? SQLiteDataModel)
        model.selectPart(1)                                        // notes
        XCTAssertEqual((0..<model.columnCount).map(model.typeTag), ["123", "123", "Aa", "date", "BIN"])
        XCTAssertEqual(model.headerTooltip(1), "folder_id · INTEGER · not null · → folders.id, on delete cascade · indexed")

        XCTAssertEqual(preview.showView?(1), true)
        let schema = try XCTUnwrap(view.schema)
        XCTAssertFalse(schema.isHidden)
        XCTAssertTrue(view.scroll.isHidden)
        XCTAssertEqual(schema.lines.first, "id INTEGER PRIMARY KEY AUTOINCREMENT")
        XCTAssertTrue(schema.lines.contains("folder_id INTEGER NOT NULL → folders.id CASCADE indexed"), "\(schema.lines)")
        XCTAssertTrue(schema.lines.contains("idx_notes_folder on folder_id"))
        XCTAssertTrue(schema.lines.contains("notes_touch trigger · after update"))
        XCTAssertEqual(preview.showView?(0), true)
        XCTAssertTrue(schema.isHidden)
        XCTAssertFalse(view.scroll.isHidden)
    }
}
