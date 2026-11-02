import Foundation
import SQLite3

/// A CSV or TSV copied into an in-memory SQLite database so the query box can run SQL on it (I-8, G-13). The table
/// is named after the file ("orders" for orders.csv) and is also reachable as `t`. Columns get the types the profile
/// inferred: Integer → INTEGER, Decimal → REAL (numbers in the file's own style, "1.234,5" with a decimal comma), the
/// rest TEXT as written. An empty cell is NULL; a value that does not fit its column's type is kept as text; fields
/// past the column count are dropped and missing ones are NULL. Files over `SQLiteQueryLimits.csvMaxBytes` are not
/// copied and say so. The copy is filled once, then locked down like a file connection: query-only, the authorizer,
/// no attached databases. roadmap: S-6
extension SQLiteQueryEngine {
    /// Copies `table` into memory and returns a query engine on the copy. `index` is the row index when the caller has
    /// one; without it one is built. `progress` gets the share of rows copied (0...1) every 4,096 rows. Throws
    /// `SQLiteQueryError.tooLarge` over the bound and `.cancelled` when `isCancelled` turns true.
    public static func csv(_ table: CSVTable, index: CSVRowIndex?, types: [CSVColumnTypeInfo], name: String,
                           limits: SQLiteQueryLimits = SQLiteQueryLimits(), isCancelled: (@Sendable () -> Bool)? = nil,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> SQLiteQueryEngine {
        guard table.fileSize <= limits.csvMaxBytes else {
            throw SQLiteQueryError.tooLarge(fileBytes: table.fileSize, limit: limits.csvMaxBytes)
        }
        var index = index
        if index == nil, !table.firstPage.reachesEndOfFile {
            do { index = try await table.buildIndex() } catch is CancellationError { throw SQLiteQueryError.cancelled }
        }
        if isCancelled?() == true { throw SQLiteQueryError.cancelled }
        let total = max(1, table.rowCount(index: index).known)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_MEMORY
        guard sqlite3_open_v2(":memory:", &handle, flags, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close_v2(handle)
            throw SQLiteQueryError.failed(String(localized: "Cannot make the in-memory copy", bundle: .module, comment: "Shown when the SQL engine cannot create its in-memory table."))
        }
        do {
            let tableName = Self.tableName(for: name)
            let columns = Self.columnNames(table)
            let kinds: [ColumnKind] = (0..<table.columnCount).map { c in
                switch c < types.count ? types[c].type : .text {
                case .integer: return .integer
                case .decimal: return .real
                default: return .text
                }
            }
            let definitions = zip(columns, kinds).map { "\(SQLiteDatabase.quote($0)) \($1.declared)" }.joined(separator: ", ")
            try exec(db, "CREATE TABLE \(SQLiteDatabase.quote(tableName)) (\(definitions))")
            if tableName.lowercased() != "t" { try exec(db, "CREATE VIEW t AS SELECT * FROM \(SQLiteDatabase.quote(tableName))") }
            try exec(db, "BEGIN")
            var stmt: OpaquePointer?
            let marks = (1...max(1, columns.count)).map { "?\($0)" }.joined(separator: ", ")
            guard sqlite3_prepare_v2(db, "INSERT INTO \(SQLiteDatabase.quote(tableName)) VALUES (\(marks))", -1, &stmt, nil) == SQLITE_OK,
                  let insert = stmt else {
                sqlite3_finalize(stmt)
                throw SQLiteQueryError.failed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(insert) }
            let step = 4_096
            var start = 0
            while true {
                if isCancelled?() == true || Task.isCancelled { throw SQLiteQueryError.cancelled }
                let rows = try table.rows(in: start..<(start + step), index: index)
                for row in rows {
                    for c in 0..<columns.count {
                        bind(insert, Int32(c + 1), row[c], kind: kinds[c], info: c < types.count ? types[c] : nil)
                    }
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteQueryError.failed(String(cString: sqlite3_errmsg(db))) }
                    sqlite3_reset(insert)
                }
                start += rows.count
                progress?(min(1, Double(start) / Double(total)))
                if rows.count < step { break }
            }
            try exec(db, "COMMIT")
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
        // The engine closes the connection if it cannot lock it down.
        return try SQLiteQueryEngine(handle: db, sourceName: name, limits: limits)
    }

    /// The table's name: the file's name without its extension; `t` when that is empty or reserved by SQLite.
    public static func tableName(for fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        if base.isEmpty || base.lowercased().hasPrefix("sqlite_") { return "t" }
        return base
    }

    /// The header's names made unique ("id", "id_2"); "Column N" where there is none.
    static func columnNames(_ table: CSVTable) -> [String] {
        var seen = Set<String>()
        return (0..<table.columnCount).map { c in
            let title = table.columnTitle(c)
            var name = title
            var k = 2
            while seen.contains(name.lowercased()) { name = "\(title)_\(k)"; k += 1 }
            seen.insert(name.lowercased())
            return name
        }
    }

    fileprivate enum ColumnKind {
        case integer, real, text
        var declared: String {
            switch self { case .integer: "INTEGER"; case .real: "REAL"; case .text: "TEXT" }
        }
    }

    private static func bind(_ stmt: OpaquePointer, _ position: Int32, _ value: String, kind: ColumnKind, info: CSVColumnTypeInfo?) {
        if value.trimmingCharacters(in: .whitespaces).isEmpty { sqlite3_bind_null(stmt, position); return }
        if kind != .text, let number = info?.number(value) {
            // Whole numbers up to 2^53 go in as integers; a larger "number" (a long id) stays text, not a rounded double.
            if kind == .integer {
                if number.rounded() == number, abs(number) < 9_007_199_254_740_992 { sqlite3_bind_int64(stmt, position, Int64(number)); return }
            } else if number.isFinite {
                sqlite3_bind_double(stmt, position, number); return
            }
        }
        sqlite3_bind_text(stmt, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteQueryError.failed(String(cString: sqlite3_errmsg(db))) }
    }
}
