import Foundation
import SQLite3

/// A Parquet, Arrow or sheet table copied into an in-memory SQLite database so the query box runs SQL on it (I-8,
/// G-13, B-4): the table is named after the file (or the sheet) and is also reachable as `t`. Integers and booleans
/// go in as INTEGER, floats and scaled decimals as REAL, dates and times as ISO text (so SQLite's date functions
/// read them), everything else as TEXT as the grid shows it; NULL stays NULL. Tables over
/// `ColumnarLimits.maxQueryCells` are not copied and say so. The copy is filled a window at a time, then locked
/// down like a file connection. roadmap: S-21
extension SQLiteQueryEngine {
    public static func columnar(_ table: any ColumnarTable, name: String, limits: SQLiteQueryLimits = SQLiteQueryLimits(),
                                columnarLimits: ColumnarLimits = ColumnarLimits(), isCancelled: (@Sendable () -> Bool)? = nil,
                                progress: (@Sendable (Double) -> Void)? = nil) throws -> SQLiteQueryEngine {
        let columns = table.columns
        let cells = table.rowCount.multipliedReportingOverflow(by: max(columns.count, 1))
        guard !cells.overflow, cells.partialValue <= columnarLimits.maxQueryCells else {
            throw SQLiteQueryError.failed(String(localized: "SQL runs on tables up to \(columnarLimits.maxQueryCells.formatted()) cells; this one has \(table.rowCount.formatted()) rows × \(columns.count.formatted()) columns. Filter still searches every row.", bundle: .module, comment: "Shown when a table is too large to query with SQL; the arguments are formatted numbers. Filter is the name of the search box."))
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_MEMORY
        guard sqlite3_open_v2(":memory:", &handle, flags, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close_v2(handle)
            throw SQLiteQueryError.failed(String(localized: "Cannot make the in-memory copy", bundle: .module, comment: "Shown when the SQL engine cannot create its in-memory table."))
        }
        do {
            let tableName = Self.tableName(for: name)
            var seen = Set<String>()
            let names: [String] = columns.map { c in
                var n = c.name.isEmpty ? "column" : c.name
                let base = n
                var k = 2
                while seen.contains(n.lowercased()) { n = "\(base)_\(k)"; k += 1 }
                seen.insert(n.lowercased())
                return n
            }
            let declared = columns.map(Self.declaredType)
            let definitions = zip(names, declared).map { "\(SQLiteDatabase.quote($0)) \($1)" }.joined(separator: ", ")
            try columnarExec(db, "CREATE TABLE \(SQLiteDatabase.quote(tableName)) (\(definitions.isEmpty ? "\"empty\" TEXT" : definitions))")
            if tableName.lowercased() != "t" { try columnarExec(db, "CREATE VIEW t AS SELECT * FROM \(SQLiteDatabase.quote(tableName))") }
            try columnarExec(db, "BEGIN")
            if !columns.isEmpty {
                var stmt: OpaquePointer?
                let marks = (1...columns.count).map { "?\($0)" }.joined(separator: ", ")
                guard sqlite3_prepare_v2(db, "INSERT INTO \(SQLiteDatabase.quote(tableName)) VALUES (\(marks))", -1, &stmt, nil) == SQLITE_OK,
                      let insert = stmt else {
                    sqlite3_finalize(stmt)
                    throw SQLiteQueryError.failed(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(insert) }
                let step = 4_096
                var start = 0
                let total = max(1, table.rowCount)
                while start < table.rowCount {
                    if isCancelled?() == true || Task.isCancelled { throw SQLiteQueryError.cancelled }
                    let window: ColumnarWindow
                    do { window = try table.read(rows: start..<(start + step), isCancelled: { isCancelled?() == true }) } catch ColumnarError.cancelled {
                        throw SQLiteQueryError.cancelled
                    }
                    guard window.count > 0 else { break }
                    for r in 0..<window.count {
                        for c in columns.indices {
                            bindColumnar(insert, Int32(c + 1), window.columns[c][r], column: columns[c])
                        }
                        guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteQueryError.failed(String(cString: sqlite3_errmsg(db))) }
                        sqlite3_reset(insert)
                    }
                    start += window.count
                    progress?(min(1, Double(start) / Double(total)))
                }
            }
            try columnarExec(db, "COMMIT")
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
        return try SQLiteQueryEngine(handle: db, sourceName: name, limits: limits)
    }

    static func declaredType(_ column: ColumnarColumn) -> String {
        switch column.kind {
        case .boolean, .integer: return "INTEGER"
        case .float: return "REAL"
        case .decimal(_, let scale): return scale == 0 ? "INTEGER" : "REAL"
        case .duration: return "INTEGER"
        case .date: return "DATE"
        case .dateMillis, .timestamp: return "TIMESTAMP"
        case .time: return "TIME"
        case .binary, .uuid: return column.kind == .uuid ? "TEXT" : "BLOB"
        default: return "TEXT"
        }
    }

    private static func bindColumnar(_ stmt: OpaquePointer, _ position: Int32, _ cell: ColumnarCell, column: ColumnarColumn) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch (cell, column.kind) {
        case (.null, _):
            sqlite3_bind_null(stmt, position)
        case (.bool(let b), _):
            sqlite3_bind_int64(stmt, position, b ? 1 : 0)
        case (.int(let n), .integer(64, false)) where n < 0:
            sqlite3_bind_text(stmt, position, String(UInt64(bitPattern: n)), -1, transient)
        case (.int(let n), .integer), (.int(let n), .duration), (.int(let n), .decimal(_, 0)):
            sqlite3_bind_int64(stmt, position, n)
        case (.int, .decimal):
            sqlite3_bind_double(stmt, position, ColumnarText.number(cell, kind: column.kind) ?? 0)
        case (.double(let d), _):
            if d.isNaN { sqlite3_bind_null(stmt, position) } else { sqlite3_bind_double(stmt, position, d) }
        case (.bytes(let b), .binary):
            _ = b.withUnsafeBytes { sqlite3_bind_blob(stmt, position, $0.baseAddress, Int32(b.count), transient) }
        default:
            sqlite3_bind_text(stmt, position, ColumnarText.text(cell, kind: column.kind), -1, transient)
        }
    }

    private static func columnarExec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteQueryError.failed(String(cString: sqlite3_errmsg(db))) }
    }
}
