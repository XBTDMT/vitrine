import Foundation
import SQLite3
import Testing
@testable import VitrineData

/// Builds invented databases in a temp folder with a read-write connection the test owns. roadmap: S-6
final class SQLiteFixture {
    let url: URL
    private(set) var db: OpaquePointer?

    init(name: String = "acme-notes.sqlite", _ sql: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SQLiteError.open("fixture") }
        try exec(sql)
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw SQLiteError.query(error.map { String(cString: $0) } ?? "?")
        }
    }

    func close() { sqlite3_close(db); db = nil }
    deinit { close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    static let notes = """
    CREATE TABLE folders (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
    CREATE TABLE notes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
      title TEXT NOT NULL,
      word_count INTEGER,
      score REAL,
      cover BLOB,
      pinned INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0,1))
    );
    CREATE INDEX idx_notes_folder ON notes(folder_id);
    CREATE TRIGGER notes_touch AFTER UPDATE ON notes BEGIN SELECT 1; END;
    CREATE VIEW pinned_notes AS SELECT id, title FROM notes WHERE pinned = 1;
    CREATE TABLE tags (name TEXT PRIMARY KEY, color TEXT) WITHOUT ROWID;
    INSERT INTO folders VALUES (1, 'Work'), (2, 'Home');
    INSERT INTO notes (folder_id, title, word_count, score, cover, pinned) VALUES
      (1, 'Q4 launch checklist', 2015, 4.5, x'89504E470D0A1A0A0000', 1),
      (2, 'Grocery run', 'n/a', NULL, NULL, 0),
      (1, 'Packing list: Kyoto', 697, 3.25, x'00010203', 1);
    INSERT INTO tags VALUES ('urgent', 'red'), ('later', 'grey');
    """
}

@Suite struct SQLiteDatabaseTests {
    @Test func readsHeaderSchemaAndColumns() throws {
        let f = try SQLiteFixture(SQLiteFixture.notes)
        f.close()
        let db = try SQLiteDatabase.open(f.url)
        #expect(db.header.pageSize >= 512)
        #expect(db.header.isWAL == false)
        #expect(db.header.writerVersion > 3_000_000)
        #expect(db.browsable.map(\.name) == ["folders", "notes", "tags", "pinned_notes", "sqlite_sequence"])
        #expect(db.count(of: .index) >= 1)
        #expect(db.count(of: .trigger) == 1)
        #expect(db.dependents(of: "notes").map(\.name).contains("idx_notes_folder"))

        let notes = try #require(db.objects.first { $0.name == "notes" })
        let columns = try db.columns(of: "notes")
        #expect(columns.map(\.name) == ["id", "folder_id", "title", "word_count", "score", "cover", "pinned"])
        let folder = columns[1]
        #expect(folder.notNull && folder.isIndexed && folder.affinity == .integer)
        #expect(folder.references == SQLiteForeignKey(table: "folders", column: "id", onDelete: "CASCADE", onUpdate: "NO ACTION"))
        #expect(columns[0].primaryKeyPosition == 1 && columns[0].isIndexed)
        #expect(columns[6].defaultValue == "0")
        #expect(db.references(to: "folders") == ["notes.folder_id"])
        #expect(db.rowIDName(for: notes, columns: columns) == "rowid")
        let tags = try #require(db.objects.first { $0.name == "tags" })
        #expect(db.rowIDName(for: tags, columns: try db.columns(of: "tags")) == nil)
        let view = try #require(db.objects.first { $0.name == "pinned_notes" })
        #expect(db.rowIDName(for: view, columns: try db.columns(of: "pinned_notes")) == nil)
    }

    @Test func readsValuesWithBlobKindsAndMisfits() throws {
        let f = try SQLiteFixture(SQLiteFixture.notes)
        f.close()
        let db = try SQLiteDatabase.open(f.url)
        let notes = try #require(db.objects.first { $0.name == "notes" })
        let columns = try db.columns(of: "notes")
        let rows = try db.rows(notes, columns: columns, start: 0, limit: 10, rowID: "rowid", anchors: nil)
        #expect(rows.count == 3)
        #expect(rows[0][2] == .text("Q4 launch checklist", truncated: false))
        #expect(rows[0][5].display == "PNG · 10 bytes")
        #expect(rows[2][5].display == "BLOB · 4 bytes")
        #expect(rows[1][4] == .null && rows[1][4].display == "—")
        #expect(rows[2][4].display == "3.25")
        #expect(rows[1][3].misfits(.integer))
        #expect(!rows[0][3].misfits(.integer))
        #expect(try db.rowCount(notes) == 3)
        let view = try #require(db.objects.first { $0.name == "pinned_notes" })
        #expect(try db.rowCount(view) == 2)
        let summary = try db.summary(of: "word_count", in: notes)
        #expect(summary.rows == 3 && summary.nonNull == 3 && summary.distinct == 3)
    }

    @Test func pagesByRowIDAnchorsMatchOffsetPaging() throws {
        let f = try SQLiteFixture("""
        CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT);
        WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000)
        INSERT INTO events SELECT x * 3, 'k' || x FROM c;
        DELETE FROM events WHERE id % 7 = 0;
        """)
        f.close()
        let db = try SQLiteDatabase.open(f.url)
        let events = try #require(db.objects.first { $0.name == "events" })
        let columns = try db.columns(of: "events")
        let anchors = try db.rowIDAnchors(events, rowID: "rowid")
        let total = try db.rowCount(events)
        #expect(anchors.count == (total + SQLiteDatabase.anchorStride - 1) / SQLiteDatabase.anchorStride)
        for start in stride(from: 0, to: total, by: SQLiteDatabase.anchorStride) {
            let seek = try db.rows(events, columns: columns, start: start, limit: 200, rowID: "rowid", anchors: anchors)
            let skip = try db.rows(events, columns: columns, start: start, limit: 200, rowID: "rowid", anchors: nil)
            #expect(seek == skip)
        }
        #expect(try db.rows(events, columns: columns, start: anchors.count * 200, limit: 200, rowID: "rowid", anchors: anchors).isEmpty)
    }

    @Test func cutsLongTextOnACharacterBoundary() throws {
        let long = String(repeating: "é", count: 3_000)
        let f = try SQLiteFixture("CREATE TABLE t (body TEXT); INSERT INTO t VALUES ('\(long)');")
        f.close()
        let db = try SQLiteDatabase.open(f.url)
        let t = try #require(db.objects.first { $0.name == "t" })
        let value = try db.rows(t, columns: try db.columns(of: "t"), start: 0, limit: 1, rowID: "rowid", anchors: nil)[0][0]
        guard case .text(let s, let truncated) = value else { Issue.record("not text"); return }
        #expect(truncated && s.utf8.count <= SQLiteDatabase.textLimit && s.allSatisfy { $0 == "é" })
    }

    @Test func stopsAStatementPastItsBudget() throws {
        // A hostile view that never ends would hold the caller forever without the progress handler.
        let f = try SQLiteFixture("CREATE VIEW endless AS WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x FROM c;")
        f.close()
        let db = try SQLiteDatabase.open(f.url)
        let endless = try #require(db.objects.first { $0.name == "endless" })
        let start = Date()
        #expect(throws: SQLiteError.timedOut) { try db.rowCount(endless, budget: 0.2) }
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(throws: SQLiteError.cancelled) { try db.rowCount(endless, budget: 5, isCancelled: { true }) }
    }

    @Test func refusesFilesThatAreNotSQLite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Thumbs-\(UUID().uuidString).db")
        try Data("not a database at all, just bytes".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SQLiteError.notSQLite) { _ = try SQLiteDatabase.open(url) }
    }

    @Test func neverWritesAndReadsOnlyCheckpointedRowsOfAWALFile() throws {
        let f = try SQLiteFixture("""
        PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;
        CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (1), (2), (3);
        PRAGMA wal_checkpoint(TRUNCATE);
        INSERT INTO t VALUES (4), (5);
        """)
        // The writer stays open, so rows 4 and 5 sit in the -wal file only.
        let before = try Data(contentsOf: f.url)
        let db = try SQLiteDatabase.open(f.url)
        #expect(db.header.isWAL)
        let t = try #require(db.objects.first { $0.name == "t" })
        #expect(try db.rowCount(t) == 3)
        #expect(try Data(contentsOf: f.url) == before)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: f.url.deletingLastPathComponent().path)
        #expect(Set(siblings) == ["acme-notes.sqlite", "acme-notes.sqlite-wal", "acme-notes.sqlite-shm"])
    }

    @Test func sortsAndFiltersByRowIDAndByOffset() throws {
        let f = try SQLiteFixture(SQLiteFixture.notes + """
        INSERT INTO notes (folder_id, title, word_count) VALUES (2, '100% done_ish', 5), (2, '100 percent', 9);
        CREATE VIEW titles AS SELECT title, word_count FROM notes;
        """)
        f.close()
        let db = try SQLiteDatabase.open(f.url)
        let notes = try #require(db.objects.first { $0.name == "notes" })
        let columns = try db.columns(of: "notes")
        typealias A = SQLiteDatabase.Arrangement
        // 'Packing list: Kyoto' and 'Q4 launch checklist' contain "list"; LIKE folds ASCII case.
        #expect(try db.rowIDs(notes, rowID: "rowid", columns: columns, arrangement: A(filter: "LIST")) == [1, 3])
        #expect(try db.rowIDs(notes, rowID: "rowid", columns: columns, arrangement: A(filter: "100%")) == [4])
        #expect(try db.rowIDs(notes, rowID: "rowid", columns: columns, arrangement: A(filter: "_ish")) == [4])
        #expect(try db.rowIDs(notes, rowID: "rowid", columns: columns, arrangement: A(sortColumn: "title", ascending: true)) == [5, 4, 2, 3, 1])
        let byWords = try db.rowIDs(notes, rowID: "rowid", columns: columns, arrangement: A(sortColumn: "word_count", ascending: false))
        #expect(byWords.first == 2, "SQLite ranks the text 'n/a' above every number")
        let rows = try db.rows(notes, columns: columns, rowIDs: [3, 1][...], rowID: "rowid")
        #expect(rows.map { $0[2] } == [.text("Packing list: Kyoto", truncated: false), .text("Q4 launch checklist", truncated: false)])
        #expect(try db.rowCount(notes, columns: columns, arrangement: A(filter: "list")) == 2)

        let view = try #require(db.objects.first { $0.name == "titles" })
        let viewColumns = try db.columns(of: "titles")
        let page = try db.rows(view, columns: viewColumns, arrangement: A(filter: "100", sortColumn: "word_count", ascending: false), start: 0, limit: 10)
        #expect(page.map { $0[1] } == [.integer(9), .integer(5)])
        #expect(try db.rows(view, columns: viewColumns, arrangement: A(filter: "100"), start: 1, limit: 10).count == 1)
    }
}
