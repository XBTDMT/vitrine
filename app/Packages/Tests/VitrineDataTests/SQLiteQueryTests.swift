import Foundation
import SQLite3
import Testing
@testable import VitrineData

/// The read-only query engine (I-8, G-13): every write, ATTACH, PRAGMA write and second statement is refused with a
/// clear message and the file stays byte-for-byte the same; an endless query is stopped by the budget and by Cancel;
/// results are capped honestly; a CSV copy queries with typed numbers. All content is invented here. roadmap: S-6
@Suite struct SQLiteQueryTests {
    private func siblings(_ url: URL) -> [String] {
        let dir = url.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func refusesEveryWriteAndLeavesTheFileUnchanged() throws {
        let f = try SQLiteFixture(SQLiteFixture.notes)
        f.close()
        let before = try Data(contentsOf: f.url)
        let filesBefore = siblings(f.url)
        let dir = f.url.deletingLastPathComponent()
        let attachTarget = dir.appendingPathComponent("other.sqlite").path
        let vacuumTarget = dir.appendingPathComponent("copy.sqlite").path
        let engine = try SQLiteQueryEngine.open(f.url)

        let refused: [(String, String)] = [
            ("INSERT INTO folders VALUES (3, 'Trips')", "INSERT"),
            ("REPLACE INTO folders VALUES (1, 'Trips')", "REPLACE"),
            ("UPDATE notes SET title = 'x'", "UPDATE"),
            ("DELETE FROM notes", "DELETE"),
            ("CREATE TABLE z (a)", "CREATE"),
            ("CREATE TEMP VIEW v AS SELECT 1", "CREATE"),
            ("DROP TABLE notes", "DROP"),
            ("ALTER TABLE notes ADD COLUMN extra", "ALTER"),
            ("ATTACH DATABASE '\(attachTarget)' AS other", "ATTACH"),
            ("DETACH DATABASE main", "DETACH"),
            ("VACUUM INTO '\(vacuumTarget)'", "VACUUM"),
            ("BEGIN", "BEGIN"),
            ("REINDEX", "REINDEX"),
            ("ANALYZE", "ANALYZE"),
            ("PRAGMA user_version = 7", "PRAGMA user_version"),
            ("PRAGMA query_only = OFF", "PRAGMA query_only"),
            ("PRAGMA journal_mode = DELETE", "PRAGMA journal_mode"),
            ("PRAGMA writable_schema", "PRAGMA writable_schema"),
            ("WITH x AS (SELECT 1) DELETE FROM notes", "DELETE"),
            ("WITH x AS (SELECT 1) INSERT INTO folders SELECT 9, 'x' FROM x", "INSERT"),
            ("WITH x AS (SELECT 1) UPDATE notes SET title = 'x'", "UPDATE"),
            ("WITH x AS (SELECT 1) REPLACE INTO folders VALUES (1, 'x')", "INSERT"),
        ]
        for (sql, word) in refused {
            do {
                _ = try engine.run(sql)
                Issue.record("ran: \(sql)")
            } catch let error as SQLiteQueryError {
                let message = error.localizedDescription
                #expect(message.contains(word) && message.contains("Read-only"), "\(sql) → \(message)")
            }
        }
        // Functions with side effects: refused by the authorizer, or absent from this SQLite build altogether.
        for sql in ["SELECT load_extension('/tmp/none')", "SELECT fts3_tokenizer('simple')"] {
            do {
                _ = try engine.run(sql)
                Issue.record("ran: \(sql)")
            } catch let error as SQLiteQueryError {
                let message = error.localizedDescription
                #expect(message.contains("Read-only") || message.lowercased().contains("no such function"), "\(sql) → \(message)")
            }
        }
        // The authorizer itself, for statements the first-word list already refuses by name.
        let gate = QueryGate()
        for action in [SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE, SQLITE_CREATE_TABLE, SQLITE_DROP_TABLE, SQLITE_ATTACH,
                       SQLITE_DETACH, SQLITE_ALTER_TABLE, SQLITE_TRANSACTION, SQLITE_SAVEPOINT, SQLITE_REINDEX, SQLITE_ANALYZE,
                       SQLITE_CREATE_VTABLE] {
            #expect(gate.decide(action, "notes", nil) == SQLITE_DENY, "action \(action)")
        }
        #expect(gate.decide(SQLITE_SELECT, nil, nil) == SQLITE_OK && gate.decide(SQLITE_READ, "notes", "title") == SQLITE_OK)
        #expect(gate.decide(SQLITE_PRAGMA, "table_info", "notes") == SQLITE_OK)
        #expect(gate.decide(SQLITE_PRAGMA, "user_version", nil) == SQLITE_OK)
        #expect(gate.decide(SQLITE_PRAGMA, "user_version", "7") == SQLITE_DENY)
        #expect(gate.decide(SQLITE_FUNCTION, nil, "load_extension") == SQLITE_DENY)
        #expect(gate.decide(SQLITE_FUNCTION, nil, "sum") == SQLITE_OK)
        // Two statements: the second never runs, whatever it is.
        for sql in ["SELECT 1; DELETE FROM notes", "SELECT 1; SELECT 2", "SELECT 1;;  DROP TABLE notes -- x"] {
            #expect(throws: SQLiteQueryError.multipleStatements) { try engine.run(sql) }
        }
        #expect(SQLiteQueryError.multipleStatements.localizedDescription.contains("One statement"))
        // A trailing semicolon or comment is still one statement.
        #expect(try engine.run("SELECT count(*) FROM notes; -- all of them").rows == [[.integer(3)]])

        #expect(try Data(contentsOf: f.url) == before, "byte-for-byte unchanged")
        #expect(siblings(f.url) == filesBefore, "no journal, -wal, -shm, attached or vacuumed file appeared")
        #expect(!FileManager.default.fileExists(atPath: vacuumTarget))
        #expect(!FileManager.default.fileExists(atPath: attachTarget))
    }

    @Test func readsRowsColumnsAndReadOnlyPragmas() throws {
        let f = try SQLiteFixture(SQLiteFixture.notes)
        f.close()
        let engine = try SQLiteQueryEngine.open(f.url)
        #expect(engine.tables == ["folders", "notes", "pinned_notes", "tags"])
        let r = try engine.run("SELECT title, word_count, score, length(title) AS n FROM notes ORDER BY id")
        #expect(r.columns.map(\.name) == ["title", "word_count", "score", "n"])
        #expect(r.columns.map(\.declaredType) == ["TEXT", "INTEGER", "REAL", nil])
        #expect(r.rows.count == 3 && r.totalRows == 3 && !r.isCapped)
        #expect(r.rows[0][0] == .text("Q4 launch checklist", truncated: false))
        #expect(r.rows[2][2] == .real(3.25))
        #expect(r.rows[1][2] == .null)

        #expect(try engine.run("SELECT * FROM pinned_notes").rows.count == 2, "views read")
        #expect(try engine.run("PRAGMA table_info(notes)").rows.count == 7)
        #expect(try engine.run("SELECT name FROM pragma_table_info('folders')").rows.count == 2)
        #expect(try engine.run("PRAGMA user_version").rows == [[.integer(0)]])
        #expect(try engine.run("VALUES (1, 'a'), (2, 'b')").rows.count == 2)
        #expect(try engine.run("EXPLAIN QUERY PLAN SELECT * FROM notes WHERE folder_id = 1").rows.count >= 1)

        #expect(throws: SQLiteQueryError.empty) { try engine.run("  -- nothing\n ") }
        do {
            _ = try engine.run("SELEC title FROM notes")
            Issue.record("a typo ran")
        } catch let error as SQLiteQueryError {
            #expect(error.localizedDescription.contains("SELEC"), "named by the first word: \(error.localizedDescription)")
        }
        do {
            _ = try engine.run("SELECT * FROM ordrs")
            Issue.record("a missing table ran")
        } catch let error as SQLiteQueryError {
            #expect(error.localizedDescription == "No such table: ordrs")
        }
        do {
            _ = try engine.run("SELECT title FROM notes WHERE AND 1")
            Issue.record("a syntax error ran")
        } catch let error as SQLiteQueryError {
            #expect(error.localizedDescription == "Near \"AND\": syntax error")
        }
        // A query cut short gets SQLite's own word for it.
        #expect(throws: SQLiteQueryError.failed("incomplete input")) { try engine.run("SELECT title FROM notes WHERE") }
        #expect(throws: SQLiteQueryError.self) { try engine.run("SELECT length(randomblob(1000000000))") }
        #expect(SQLiteQueryEngine.isPlainName("orders") && !SQLiteQueryEngine.isPlainName("order")
                && !SQLiteQueryEngine.isPlainName("my data") && !SQLiteQueryEngine.isPlainName("2026_sales"))
    }

    private static let endless = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"

    @Test func anEndlessQueryIsStoppedByTheBudget() throws {
        let f = try SQLiteFixture(SQLiteFixture.notes)
        f.close()
        var limits = SQLiteQueryLimits()
        limits.budget = 0.3
        let engine = try SQLiteQueryEngine.open(f.url, limits: limits)
        let start = Date()
        #expect(throws: SQLiteQueryError.timedOut(budget: 0.3)) { try engine.run(Self.endless) }
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(SQLiteQueryError.timedOut(budget: 0.3).localizedDescription == "The query ran past 0.3 s and was stopped.")
        // The connection is usable afterwards.
        #expect(try engine.run("SELECT count(*) FROM folders").rows == [[.integer(2)]])
    }

    @Test func anEndlessQueryIsStoppedByCancel() async throws {
        let f = try SQLiteFixture(SQLiteFixture.notes)
        f.close()
        var limits = SQLiteQueryLimits()
        limits.budget = 120
        let engine = try SQLiteQueryEngine.open(f.url, limits: limits)
        let flag = Flag()
        let start = Date()
        let task = Task.detached { () -> SQLiteQueryError? in
            do { _ = try engine.run(Self.endless, isCancelled: { flag.value }); return nil } catch let e as SQLiteQueryError { return e } catch { return nil }
        }
        try await Task.sleep(for: .milliseconds(200))
        flag.set()
        let error = await task.value
        #expect(error == .cancelled)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func capsTheRowsHeldAndCountsTheRest() throws {
        let f = try SQLiteFixture(SQLiteFixture.notes)
        f.close()
        var limits = SQLiteQueryLimits()
        limits.maxRows = 1_000
        let engine = try SQLiteQueryEngine.open(f.url, limits: limits)
        let r = try engine.run("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 2500) SELECT x, 'row ' || x FROM c")
        #expect(r.rows.count == 1_000 && r.isCapped && r.totalRows == 2_500)
        #expect(r.rows[0] == [.integer(1), .text("row 1", truncated: false)])
        #expect(r.rows[999] == [.integer(1_000), .text("row 1000", truncated: false)])
        let all = try SQLiteQueryEngine.open(f.url).run("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 2500) SELECT x FROM c")
        #expect(all.rows.count == 2_500 && !all.isCapped && all.rows[2_499] == [.integer(2_500)])
    }

    // MARK: CSV

    private static let orders = """
    order_id,customer,country,qty,total
    100241,Sofia Lindqvist,GB,2,534.00
    100242,Dev Patel,US,1,96.00
    100243,Mara Lindgren,GB,3,
    100244,Tomás Ruiz,ES,1,1290.50
    100245,Ilse Lindgren,US,4,48.25

    """

    private func csvEngine(_ text: String, name: String = "orders.csv", limits: SQLiteQueryLimits = SQLiteQueryLimits()) async throws -> (SQLiteQueryEngine, URL, TemporaryDirectory) {
        let dir = try TemporaryDirectory()
        let url = try dir.write(text, name: name)
        let table = try CSVTable.open(url)
        let engine = try await SQLiteQueryEngine.csv(table, index: nil, types: table.inferColumnTypes(sample: table.firstPage.rows),
                                                     name: name, limits: limits)
        return (engine, url, dir)
    }

    @Test func csvQueriesWithTypedNumbers() async throws {
        let (engine, url, dir) = try await csvEngine(Self.orders)
        _ = dir
        let before = try Data(contentsOf: url)
        #expect(engine.tables == ["orders", "t"])
        let sum = try engine.run("SELECT sum(total), sum(qty), count(total), count(*) FROM orders")
        #expect(sum.rows == [[.real(1968.75), .integer(11), .integer(4), .integer(5)]], "empty cells are NULL; numbers are numbers")
        let types = try engine.run("SELECT typeof(order_id), typeof(qty), typeof(total), typeof(customer) FROM t LIMIT 1")
        #expect(types.rows == [[.text("integer", truncated: false), .text("integer", truncated: false),
                                .text("real", truncated: false), .text("text", truncated: false)]])
        let grouped = try engine.run("SELECT country, count(*) AS orders, sum(total) AS revenue FROM t GROUP BY country ORDER BY revenue DESC")
        #expect(grouped.rows.map { $0[0] } == [.text("ES", truncated: false), .text("GB", truncated: false), .text("US", truncated: false)])
        #expect(grouped.columns.map(\.name) == ["country", "orders", "revenue"])
        // Numbers compare as numbers, not text.
        #expect(try engine.run("SELECT count(*) FROM orders WHERE total > 100").rows == [[.integer(2)]])
        // The copy is as read-only as a file.
        for sql in ["INSERT INTO orders (qty) VALUES (1)", "DROP VIEW t", "DELETE FROM t", "CREATE TABLE x (a)"] {
            #expect(throws: SQLiteQueryError.self) { try engine.run(sql) }
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func csvBeyondTheFirstPageAndAwkwardHeaders() async throws {
        var text = "id,id,Amount (EUR),\n"
        for i in 0..<5_000 { text += "\(i),\(i * 2),\"1.234,\(i % 10)\",x\n" }
        let (engine, _, dir) = try await csvEngine(text, name: "order.csv")
        _ = dir
        let r = try engine.run("SELECT count(*), max(id), max(id_2) FROM t")
        #expect(r.rows == [[.integer(5_000), .integer(4_999), .integer(9_998)]], "the loader built its own index past the first page")
        let names = try engine.run("SELECT * FROM t LIMIT 1").columns.map(\.name)
        #expect(names == ["id", "id_2", "Amount (EUR)", "Column 4"])
        #expect(try engine.run("SELECT count(*) FROM \"order\"").rows == [[.integer(5_000)]], "a keyword name works quoted")
        #expect(SQLiteQueryEngine.tableName(for: "sqlite_master.csv") == "t")
    }

    /// Evidence for the copy bound (G-13): the time and memory to copy an invented 8 MB CSV, printed to the log.
    @Test func csvCopySpeed() async throws {
        var text = "id,placed_at,customer,country,qty,unit_price,total,status\n"
        var i = 0
        while text.utf8.count < 8 * 1024 * 1024 {
            text += "\(100_000 + i),2026-09-03 08:\(10 + i % 50),Customer \(i % 997),\(["US", "GB", "DE", "FR"][i % 4]),\(i % 7 + 1),\(Double(i % 300) + 0.5),\(Double(i % 2100) + 0.25),paid\n"
            i += 1
        }
        let start = Date()
        let (engine, url, dir) = try await csvEngine(text)
        _ = dir
        let copied = Date().timeIntervalSince(start)
        let r = try engine.run("SELECT count(*), sum(qty) FROM orders")
        #expect(r.rows.first?.first == .integer(Int64(i)))
        let grouped = try engine.run("SELECT country, sum(total) FROM orders GROUP BY country ORDER BY 2 DESC")
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let pages = try engine.run("PRAGMA page_count").rows.first?.first
        let pageSize = try engine.run("PRAGMA page_size").rows.first?.first
        print("csv-copy-evidence: \(bytes) bytes, \(i) rows copied in \(Int(copied * 1000)) ms; group-by in \(Int(grouped.elapsed * 1000)) ms; copy is \(pages?.display ?? "?") pages of \(pageSize?.display ?? "?") bytes")
        #expect(copied < 30)
    }

    @Test func csvOverTheBoundSaysSo() async throws {
        let dir = try TemporaryDirectory()
        let url = try dir.write(Self.orders, name: "orders.csv")
        let table = try CSVTable.open(url)
        var limits = SQLiteQueryLimits()
        limits.csvMaxBytes = 100
        do {
            _ = try await SQLiteQueryEngine.csv(table, index: nil, types: [], name: "orders.csv", limits: limits)
            Issue.record("copied a file over the bound")
        } catch let error as SQLiteQueryError {
            #expect(error == .tooLarge(fileBytes: table.fileSize, limit: 100))
            #expect(error.localizedDescription.hasPrefix("SQL runs on files up to 100 bytes; this one is"))
            #expect(error.localizedDescription.hasSuffix("Filter still searches every row."))
        }
    }
}

/// A thread-safe switch for cancelling from another task.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool { lock.withLock { on } }
    func set() { lock.withLock { on = true } }
}
