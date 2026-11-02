import SQLite3
import XCTest
@testable import VitrinePreviewKit
import VitrineSupport

/// SQLite in the data design (r3-a Inspector, D-2): the first table's rows in the grid, the Database tab listing
/// tables and views with their counts, the Schema view, table switching, and rowid-anchored paging (G-11). All
/// content is invented here. roadmap: S-6
@MainActor
final class SQLiteRendererTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func database(_ name: String, _ sql: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        sqlite3_close(db)
        return url
    }

    private func render(_ url: URL) async throws -> (RenderedPreview, DataView, SQLiteDataModel) {
        let preview = try await DataRenderer().render(url: url, kind: .sqlite, context: RenderContext(appearance: .light, defaultsSuite: "vt-sqlite"))
        let view = try XCTUnwrap(preview.view as? DataView)
        return (preview, view, try XCTUnwrap(view.grid.model as? SQLiteDataModel))
    }

    private let notes = """
    CREATE TABLE notes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
      title TEXT NOT NULL,
      word_count INTEGER,
      cover BLOB
    );
    CREATE TABLE folders (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
    CREATE INDEX idx_notes_folder ON notes(folder_id);
    CREATE VIEW long_notes AS SELECT id, title FROM notes WHERE word_count > 1000;
    INSERT INTO folders VALUES (1, 'Work'), (2, 'Home');
    INSERT INTO notes (folder_id, title, word_count, cover) VALUES
      (1, 'Q4 launch checklist', 2015, x'89504E470D0A1A0A'),
      (2, 'Grocery run', 'n/a', NULL),
      (1, 'Packing list: Kyoto', 697, NULL);
    """

    func testRegistryPicksDataForSQLite() {
        XCTAssertTrue(RendererRegistry.renderer(for: .sqlite) is DataRenderer)
    }

    func testOpensOnTheFirstTableWithTheDatabaseTab() async throws {
        let (preview, view, model) = try await render(try database("acme-notes.sqlite", notes))
        let table = view.grid.table
        XCTAssertEqual(table.tableColumns.map(\.title), ["", "id", "folder_id", "title", "word_count", "cover"])
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(preview.document.fact("headline")?.value, "notes · 3 rows")
        XCTAssertEqual(preview.document.viewTitles, ["Rows", "Schema"])
        guard case .code(let schema, "sql")? = preview.document.views.last else { return XCTFail("schema view") }
        XCTAssertTrue(schema.contains("CREATE TABLE notes") && schema.contains("CREATE INDEX idx_notes_folder"))

        let cover = try XCTUnwrap(table.view(atColumn: 5, row: 0, makeIfNecessary: true) as? DataCell)
        XCTAssertEqual(cover.label.stringValue, "PNG · 8 bytes")
        let empty = try XCTUnwrap(table.view(atColumn: 5, row: 1, makeIfNecessary: true) as? DataCell)
        XCTAssertEqual(empty.label.stringValue, "—")
        XCTAssertEqual(empty.label.textColor, NSColor.token("t3"), "NULL is drawn dim")
        let words = try XCTUnwrap(table.view(atColumn: 4, row: 1, makeIfNecessary: true) as? DataCell)
        XCTAssertTrue(words.misfit, "text in an INTEGER column is a misfit")
        XCTAssertEqual(words.label.alignment, .right)
        XCTAssertEqual((table.tableColumns[4].headerCell as? DataHeaderCell)?.quality, true)
        XCTAssertEqual((table.tableColumns[3].headerCell as? DataHeaderCell)?.quality, false)

        await model.waitForBackground()
        XCTAssertEqual(view.inspector.tabs.label(forSegment: 0), "Database")
        XCTAssertEqual(model.parts.map(\.name), ["notes", "folders", "long_notes", "sqlite_sequence"])
        XCTAssertEqual(model.parts.map(\.detail), ["3", "2", "view", "1"])
        XCTAssertEqual(model.parts.first?.isSelected, true)
        let file = Dictionary(uniqueKeysWithValues: view.inspector.entries.map { ($0.label, $0.value) })
        XCTAssertTrue(file["File"]?.hasPrefix("SQLite 3.") ?? false)
        XCTAssertEqual(file["Tables"], "2")
        XCTAssertEqual(file["Views"], "1")
        XCTAssertEqual(file["Indexes"], "1")

        view.grid.selectColumn(1) // folder_id
        let column = Dictionary(uniqueKeysWithValues: view.inspector.entries.map { ($0.label, $0.value) })
        XCTAssertEqual(column["Type"], "INTEGER")
        XCTAssertEqual(column["Links to"], "folders.id")
        XCTAssertEqual(column["On delete"], "cascade")
        XCTAssertEqual(column["Indexed"], "Yes")
        XCTAssertEqual(column["Distinct"], "2")
        XCTAssertEqual(model.profileNote, "Profiled all 3 rows")
    }

    func testPickingAnotherTableRebuildsTheGridAndThePill() async throws {
        let (preview, view, model) = try await render(try database("acme-notes.sqlite", notes))
        await model.waitForBackground()
        model.selectPart(1)
        XCTAssertEqual(view.grid.table.tableColumns.map(\.title), ["", "id", "name"])
        XCTAssertEqual(view.grid.table.numberOfRows, 2)
        XCTAssertEqual(preview.document.fact("headline")?.value, "folders · 2 rows")
        XCTAssertEqual(model.parts.map(\.isSelected), [false, true, false, false])
        model.selectPart(2)
        XCTAssertEqual(view.grid.table.tableColumns.map(\.title), ["", "id", "title"])
        // SQLite ranks any text above every number, so the 'n/a' row passes `word_count > 1000` too.
        XCTAssertEqual(view.grid.table.numberOfRows, 2)
        let row = Dictionary(uniqueKeysWithValues: model.rowEntries(0).map { ($0.label, $0.value) })
        XCTAssertEqual(row["title"], "Q4 launch checklist")
    }

    func testDeepRowsAreReadThroughRowIDAnchors() async throws {
        let url = try database("events.sqlite", """
        CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT);
        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 5000)
        INSERT INTO events SELECT x * 2, 'event ' || x FROM c;
        """)
        let (_, view, model) = try await render(url)
        await model.waitForBackground()
        XCTAssertEqual(model.anchors?.count, 25)
        XCTAssertEqual(view.grid.table.numberOfRows, 5000)
        XCTAssertEqual(model.cell(row: 4_321, column: 1).text, "event 4322")
        XCTAssertEqual(model.cell(row: 4_999, column: 0).text, "10000")
    }

    func testAFileThatIsNotSQLiteThrows() async throws {
        let url = dir.appendingPathComponent("Thumbs.db")
        try Data(repeating: 7, count: 4096).write(to: url)
        do {
            _ = try await DataRenderer().render(url: url, kind: .sqlite, context: RenderContext(appearance: .light, defaultsSuite: "vt-sqlite"))
            XCTFail("rendered a file that is not SQLite")
        } catch {}
    }

    func testALargeCSVPillBecomesExactWhenTheIndexIsBuilt() async throws {
        let url = dir.appendingPathComponent("big.csv")
        let row = "2026-10-29,lantern,12.50,a fairly long invented description to make the file larger than eight megabytes\n"
        let count = DataRenderer.exactCountLimit / row.utf8.count + 1_000
        try ("day,item,price,note\n" + String(repeating: row, count: count)).write(to: url, atomically: true, encoding: .utf8)
        let preview = try await DataRenderer().render(url: url, kind: .csv(delimiter: ","), context: RenderContext(appearance: .light, defaultsSuite: "vt-sqlite"))
        XCTAssertEqual(preview.document.fact("headline")?.value.hasPrefix("≥"), true)
        var changed: String?
        preview.documentChanged = { changed = $0.fact("headline")?.value }
        let model = try XCTUnwrap((preview.view as? DataView)?.grid.model as? DataModel)
        await model.waitForIndex()
        XCTAssertEqual(preview.document.fact("headline")?.value, "\(count.formatted()) rows × 4 columns")
        XCTAssertEqual(changed, preview.document.fact("headline")?.value, "the host is told, so the pill follows")
    }
}
