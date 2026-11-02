import Foundation
import SQLite3

/// A read-only connection to a SQLite file for previewing it (G-11). Opened with `immutable=1`, so SQLite never
/// locks the file, never looks for or creates `-wal`/`-shm` siblings (Quick Look's sandbox grants the file alone),
/// and never writes. A schema from the file is not trusted (`trusted_schema=OFF`) and the connection is query-only.
/// Every statement runs under a time budget enforced by a progress handler, so a hostile or huge file cannot hold the
/// caller. One instance serialises its own calls; use a second instance for background work. roadmap: S-6
public final class SQLiteDatabase: @unchecked Sendable {
    public let url: URL
    public let header: SQLiteHeader
    /// Every row of `sqlite_master`, in stored order.
    public let objects: [SQLiteObject]

    /// Rows per anchor in a rowid index, and the page size callers read in.
    public static let anchorStride = 200
    /// Text is cut to this many UTF-8 bytes in a cell.
    public static let textLimit = 2_048
    /// Default time budget for one statement on the caller's thread.
    public static let defaultBudget: TimeInterval = 0.25

    private let db: OpaquePointer
    private let lock = NSLock()
    private let watchdog = Watchdog()

    public static func open(_ url: URL) throws -> SQLiteDatabase { try SQLiteDatabase(url: url) }

    private init(url: URL) throws {
        self.url = url
        header = try SQLiteHeader.read(url)
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.standardizedFileURL.path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        guard let uri = components.string else { throw SQLiteError.open(String(localized: "Bad path", bundle: .module, comment: "Why a database cannot be opened: its path cannot be made into a URL.")) }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE
        let rc = sqlite3_open_v2(uri, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(localized: "error \(rc)", bundle: .module, comment: "Why a database cannot be opened when SQLite gives no message; the argument is SQLite's error code.")
            sqlite3_close_v2(handle)
            throw SQLiteError.open(message)
        }
        db = handle
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 0 }
            return Unmanaged<Watchdog>.fromOpaque(context).takeUnretainedValue().shouldStop() ? 1 : 0
        }, Unmanaged.passUnretained(watchdog).toOpaque())
        do {
            for pragma in ["PRAGMA trusted_schema = OFF", "PRAGMA query_only = ON"] {
                guard sqlite3_exec(db, pragma, nil, nil, nil) == SQLITE_OK else { throw SQLiteError.open(Self.message(db)) }
            }
            var found: [SQLiteObject] = []
            try Self.run(db, watchdog, "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY rowid", budget: 2) { stmt in
                if let kind = SQLiteObject.Kind(rawValue: Self.string(stmt, 0)) {
                    found.append(SQLiteObject(kind: kind, name: Self.string(stmt, 1), table: Self.string(stmt, 2),
                                              sql: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Self.string(stmt, 3)))
                }
                return true
            }
            objects = found
        } catch {
            sqlite3_close_v2(db)
            // An encrypted or damaged file has a valid header but no readable schema.
            if case SQLiteError.query(let m) = error { throw SQLiteError.open(m) }
            throw error
        }
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: Schema

    /// Tables and views a user reads rows from: user tables, then views, then SQLite's own tables.
    public var browsable: [SQLiteObject] {
        let rows = objects.filter(\.hasRows)
        return rows.filter { !$0.isInternal && $0.kind == .table } + rows.filter { $0.kind == .view } + rows.filter { $0.isInternal && $0.kind == .table }
    }

    public func count(of kind: SQLiteObject.Kind) -> Int { objects.filter { $0.kind == kind && !($0.kind == .table && $0.isInternal) }.count }

    /// Indexes and triggers that belong to `table`.
    public func dependents(of table: String) -> [SQLiteObject] {
        objects.filter { ($0.kind == .index || $0.kind == .trigger) && $0.table.caseInsensitiveCompare(table) == .orderedSame }
    }

    /// The columns of a table or view with their constraints, foreign keys and whether an index leads with them.
    public func columns(of name: String) throws -> [SQLiteColumn] {
        try locked {
            var columns: [SQLiteColumn] = []
            try Self.run(db, watchdog, #"SELECT name, type, "notnull", dflt_value, pk, hidden FROM pragma_table_xinfo(?1)"#,
                         text: [name], budget: 1) { stmt in
                columns.append(SQLiteColumn(name: Self.string(stmt, 0), declaredType: Self.string(stmt, 1),
                                            notNull: sqlite3_column_int(stmt, 2) != 0,
                                            defaultValue: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Self.string(stmt, 3),
                                            primaryKeyPosition: Int(sqlite3_column_int(stmt, 4)), hidden: Int(sqlite3_column_int(stmt, 5)),
                                            references: nil, isIndexed: false))
                return true
            }
            var keys: [String: SQLiteForeignKey] = [:]
            try? Self.run(db, watchdog, #"SELECT "from", "table", "to", on_update, on_delete FROM pragma_foreign_key_list(?1)"#,
                          text: [name], budget: 1) { stmt in
                keys[Self.string(stmt, 0).lowercased()] = SQLiteForeignKey(
                    table: Self.string(stmt, 1), column: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Self.string(stmt, 2),
                    onDelete: Self.string(stmt, 4), onUpdate: Self.string(stmt, 3))
                return true
            }
            var indexed = Set<String>()
            try? Self.run(db, watchdog, "SELECT ii.name FROM pragma_index_list(?1) AS il, pragma_index_info(il.name) AS ii WHERE ii.seqno = 0",
                          text: [name], budget: 1) { stmt in
                indexed.insert(Self.string(stmt, 0).lowercased())
                return true
            }
            let singleIntegerKey = columns.filter { $0.primaryKeyPosition > 0 }.count == 1
            for i in columns.indices {
                let key = columns[i].name.lowercased()
                columns[i].references = keys[key]
                let rowidAlias = singleIntegerKey && columns[i].primaryKeyPosition == 1 && columns[i].declaredType.uppercased() == "INTEGER"
                columns[i].isIndexed = indexed.contains(key) || rowidAlias
            }
            return columns
        }
    }

    /// Columns in other tables whose foreign keys point at `table`: "note_tags.note_id".
    public func references(to table: String) -> [String] {
        var out: [String] = []
        for other in objects where other.kind == .table && !other.isInternal {
            guard let columns = try? columns(of: other.name) else { continue }
            for c in columns where c.references?.table.caseInsensitiveCompare(table) == .orderedSame {
                out.append("\(other.name).\(c.name)")
            }
        }
        return out
    }

    /// The name that reaches the true rowid of `table` (`rowid`, `_rowid_` or `oid`, whichever no column shadows);
    /// nil for views, virtual tables and WITHOUT ROWID tables.
    public func rowIDName(for table: SQLiteObject, columns: [SQLiteColumn]) -> String? {
        guard table.kind == .table, !table.isVirtual else { return nil }
        let names = Set(columns.map { $0.name.lowercased() })
        guard let alias = ["rowid", "_rowid_", "oid"].first(where: { !names.contains($0) }) else { return nil }
        return locked {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            return sqlite3_prepare_v2(db, "SELECT \(alias) FROM \(Self.quote(table.name)) LIMIT 0", -1, &stmt, nil) == SQLITE_OK ? alias : nil
        }
    }

    // MARK: Rows

    /// Rows in a table or view; a view or a slow count may run past `budget` and throw `timedOut`.
    public func rowCount(_ object: SQLiteObject, budget: TimeInterval = defaultBudget, isCancelled: (@Sendable () -> Bool)? = nil) throws -> Int {
        try locked {
            var n = 0
            try Self.run(db, watchdog, "SELECT count(*) FROM \(Self.quote(object.name))", budget: budget, isCancelled: isCancelled) { stmt in
                n = Int(sqlite3_column_int64(stmt, 0)); return false
            }
            return n
        }
    }

    /// Every `anchorStride`-th rowid in rowid order: anchor k is the rowid of row k × stride. One pass over the
    /// table's rowids (about 18 ms per 3 M rows, G-11).
    public func rowIDAnchors(_ table: SQLiteObject, rowID: String, isCancelled: (@Sendable () -> Bool)? = nil) throws -> [Int64] {
        try locked {
            var anchors: [Int64] = []
            var i = 0
            try Self.run(db, watchdog, "SELECT \(rowID) FROM \(Self.quote(table.name)) ORDER BY \(rowID)",
                         budget: 120, isCancelled: isCancelled) { stmt in
                if i % Self.anchorStride == 0 { anchors.append(sqlite3_column_int64(stmt, 0)) }
                i += 1
                return true
            }
            return anchors
        }
    }

    /// Up to `limit` rows from row `start` (0-based). With a rowid name the rows are in rowid order; with anchors
    /// and a `start` on an anchor boundary the read seeks straight to it; otherwise it skips with OFFSET.
    public func rows(_ object: SQLiteObject, columns: [SQLiteColumn], start: Int, limit: Int, rowID: String?,
                     anchors: [Int64]?, budget: TimeInterval = defaultBudget) throws -> [[SQLiteValue]] {
        let list = columns.isEmpty ? "*" : columns.map { Self.quote($0.name) }.joined(separator: ", ")
        var sql = "SELECT \(list) FROM \(Self.quote(object.name))"
        var integers: [Int64] = []
        if let rowID, let anchors, start % Self.anchorStride == 0 {
            let k = start / Self.anchorStride
            guard k < anchors.count else { return [] }
            sql += " WHERE \(rowID) >= ?1 ORDER BY \(rowID) LIMIT ?2"
            integers = [anchors[k], Int64(limit)]
        } else {
            if let rowID { sql += " ORDER BY \(rowID)" }
            sql += " LIMIT ?1 OFFSET ?2"
            integers = [Int64(limit), Int64(start)]
        }
        return try locked {
            var out: [[SQLiteValue]] = []
            try Self.run(db, watchdog, sql, integers: integers, budget: budget) { stmt in
                let n = sqlite3_column_count(stmt)
                out.append((0..<n).map { Self.value(stmt, $0) })
                return true
            }
            return out
        }
    }

    // MARK: Sort and filter (I-4)

    /// A filter and a sort for one table or view: rows where any non-BLOB cell contains `filter` (SQLite's LIKE: case
    /// folds ASCII only), ordered by one column.
    public struct Arrangement: Sendable, Equatable {
        public var filter: String
        public var sortColumn: String?
        public var ascending: Bool
        public init(filter: String = "", sortColumn: String? = nil, ascending: Bool = true) {
            self.filter = filter; self.sortColumn = sortColumn; self.ascending = ascending
        }
        public var isEmpty: Bool { filter.isEmpty && sortColumn == nil }

        /// " WHERE …" and " ORDER BY …" with `?1` as the LIKE pattern when there is a filter.
        func clauses(columns: [SQLiteColumn], rowID: String?) -> (sql: String, pattern: String?) {
            var sql = ""
            var pattern: String?
            if !filter.isEmpty {
                let tests = columns.map { "(typeof(\(SQLiteDatabase.quote($0.name))) != 'blob' AND \(SQLiteDatabase.quote($0.name)) LIKE ?1 ESCAPE '\\')" }
                sql += " WHERE " + (tests.isEmpty ? "0" : tests.joined(separator: " OR "))
                let escaped = filter.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                pattern = "%" + escaped + "%"
            }
            var order: [String] = []
            if let sortColumn { order.append("\(SQLiteDatabase.quote(sortColumn)) \(ascending ? "ASC" : "DESC")") }
            if let rowID { order.append(rowID) }
            if !order.isEmpty { sql += " ORDER BY " + order.joined(separator: ", ") }
            return (sql, pattern)
        }
    }

    /// The rowids of a rowid table's rows under an arrangement, in order: one pass, cancellable, no time budget beyond
    /// `budget` (a sort of millions of rows takes seconds).
    public func rowIDs(_ table: SQLiteObject, rowID: String, columns: [SQLiteColumn], arrangement: Arrangement,
                       budget: TimeInterval = 300, isCancelled: (@Sendable () -> Bool)? = nil) throws -> [Int64] {
        let (clauses, pattern) = arrangement.clauses(columns: columns, rowID: rowID)
        return try locked {
            var ids: [Int64] = []
            try Self.run(db, watchdog, "SELECT \(rowID) FROM \(Self.quote(table.name))\(clauses)", text: pattern.map { [$0] } ?? [],
                         budget: budget, isCancelled: isCancelled) { stmt in
                ids.append(sqlite3_column_int64(stmt, 0)); return true
            }
            return ids
        }
    }

    /// The rows with these rowids, in the order given.
    public func rows(_ table: SQLiteObject, columns: [SQLiteColumn], rowIDs ids: ArraySlice<Int64>, rowID: String,
                     budget: TimeInterval = defaultBudget) throws -> [[SQLiteValue]] {
        guard !ids.isEmpty else { return [] }
        let list = columns.map { Self.quote($0.name) }.joined(separator: ", ")
        let sql = "SELECT \(rowID), \(list) FROM \(Self.quote(table.name)) WHERE \(rowID) IN (\(ids.map(String.init).joined(separator: ",")))"
        return try locked {
            var byID: [Int64: [SQLiteValue]] = [:]
            try Self.run(db, watchdog, sql, budget: budget) { stmt in
                let n = sqlite3_column_count(stmt)
                byID[sqlite3_column_int64(stmt, 0)] = (1..<n).map { Self.value(stmt, $0) }
                return true
            }
            return ids.compactMap { byID[$0] }
        }
    }

    /// Rows of a view or WITHOUT ROWID table under an arrangement, skipped to with OFFSET.
    public func rows(_ object: SQLiteObject, columns: [SQLiteColumn], arrangement: Arrangement, start: Int, limit: Int,
                     budget: TimeInterval = defaultBudget) throws -> [[SQLiteValue]] {
        let (clauses, pattern) = arrangement.clauses(columns: columns, rowID: nil)
        let list = columns.isEmpty ? "*" : columns.map { Self.quote($0.name) }.joined(separator: ", ")
        // ?1 is the pattern when there is one; the limit and offset follow it.
        let base = pattern == nil ? 1 : 2
        let sql = "SELECT \(list) FROM \(Self.quote(object.name))\(clauses) LIMIT ?\(base) OFFSET ?\(base + 1)"
        return try locked {
            var out: [[SQLiteValue]] = []
            try Self.run(db, watchdog, sql, text: pattern.map { [$0] } ?? [], integers: [Int64(limit), Int64(start)], budget: budget) { stmt in
                let n = sqlite3_column_count(stmt)
                out.append((0..<n).map { Self.value(stmt, $0) })
                return true
            }
            return out
        }
    }

    /// How many rows pass an arrangement's filter.
    public func rowCount(_ object: SQLiteObject, columns: [SQLiteColumn], arrangement: Arrangement,
                         budget: TimeInterval = 300, isCancelled: (@Sendable () -> Bool)? = nil) throws -> Int {
        var filterOnly = arrangement
        filterOnly.sortColumn = nil
        let (clauses, pattern) = filterOnly.clauses(columns: columns, rowID: nil)
        return try locked {
            var n = 0
            try Self.run(db, watchdog, "SELECT count(*) FROM \(Self.quote(object.name))\(clauses)", text: pattern.map { [$0] } ?? [],
                         budget: budget, isCancelled: isCancelled) { stmt in
                n = Int(sqlite3_column_int64(stmt, 0)); return false
            }
            return n
        }
    }

    /// Profile of one column over its first `sample` rows: rows seen, non-NULL, distinct, and min/max.
    public struct ColumnSummary: Sendable, Equatable {
        public var rows: Int
        public var nonNull: Int
        public var distinct: Int
        public var minimum: SQLiteValue
        public var maximum: SQLiteValue
    }

    public func summary(of column: String, in object: SQLiteObject, sample: Int = 10_000,
                        budget: TimeInterval = defaultBudget) throws -> ColumnSummary {
        let c = Self.quote(column)
        let sql = "SELECT count(*), count(v), count(DISTINCT v), min(v), max(v) FROM (SELECT \(c) AS v FROM \(Self.quote(object.name)) LIMIT ?1)"
        return try locked {
            var s = ColumnSummary(rows: 0, nonNull: 0, distinct: 0, minimum: .null, maximum: .null)
            try Self.run(db, watchdog, sql, integers: [Int64(sample)], budget: budget) { stmt in
                s = ColumnSummary(rows: Int(sqlite3_column_int64(stmt, 0)), nonNull: Int(sqlite3_column_int64(stmt, 1)),
                                  distinct: Int(sqlite3_column_int64(stmt, 2)), minimum: Self.value(stmt, 3), maximum: Self.value(stmt, 4))
                return false
            }
            return s
        }
    }

    /// The values of one column over its first `sample` rows, for the column profile's histogram and top values.
    public func values(of column: String, in object: SQLiteObject, sample: Int = 10_000,
                       budget: TimeInterval = defaultBudget) throws -> [SQLiteValue] {
        let sql = "SELECT \(Self.quote(column)) FROM \(Self.quote(object.name)) LIMIT ?1"
        return try locked {
            var out: [SQLiteValue] = []
            try Self.run(db, watchdog, sql, integers: [Int64(sample)], budget: budget) { stmt in
                out.append(Self.value(stmt, 0)); return true
            }
            return out
        }
    }

    // MARK: Plumbing

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    /// `"name"` with inner quotes doubled.
    public static func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private static func message(_ db: OpaquePointer) -> String { String(cString: sqlite3_errmsg(db)) }

    private static func string(_ stmt: OpaquePointer, _ i: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, i) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(stmt, i))), as: UTF8.self)
    }

    static func value(_ stmt: OpaquePointer, _ i: Int32) -> SQLiteValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT:
            guard let p = sqlite3_column_text(stmt, i) else { return .text("", truncated: false) }
            let n = Int(sqlite3_column_bytes(stmt, i))
            var cut = min(n, textLimit)
            // Never cut inside a UTF-8 sequence.
            while cut < n, cut > 0, p[cut] & 0xC0 == 0x80 { cut -= 1 }
            return .text(String(decoding: UnsafeBufferPointer(start: p, count: cut), as: UTF8.self), truncated: cut < n)
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, i))
            guard n > 0, let raw = sqlite3_column_blob(stmt, i) else { return .blob(byteCount: 0, kind: nil) }
            let head = [UInt8](UnsafeRawBufferPointer(start: raw, count: min(n, 16)))
            return .blob(byteCount: n, kind: SQLiteValue.blobKind(head))
        default: return .null
        }
    }

    /// Prepares, binds and steps one statement under a time budget; `row` returns false to stop early.
    private static func run(_ db: OpaquePointer, _ watchdog: Watchdog, _ sql: String, text: [String] = [], integers: [Int64] = [],
                            budget: TimeInterval, isCancelled: (@Sendable () -> Bool)? = nil,
                            row: (OpaquePointer) throws -> Bool) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            throw SQLiteError.query(message(db))
        }
        defer { sqlite3_finalize(stmt) }
        var position: Int32 = 1
        for t in text {
            // SQLITE_TRANSIENT is a C cast macro Swift cannot import; -1 is its value.
            sqlite3_bind_text(stmt, position, t, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            position += 1
        }
        for n in integers { sqlite3_bind_int64(stmt, position, n); position += 1 }
        watchdog.arm(budget: budget, isCancelled: isCancelled)
        defer { watchdog.disarm() }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { if try !row(stmt) { return }; continue }
            if rc == SQLITE_DONE { return }
            if rc == SQLITE_INTERRUPT { throw watchdog.wasCancelled ? SQLiteError.cancelled : SQLiteError.timedOut }
            throw SQLiteError.query(message(db))
        }
    }
}

/// The progress handler's state: a deadline and an optional cancel check for the statement now running. Shared with
/// the read-only query engine (`SQLiteQueryEngine`, G-13).
final class Watchdog: @unchecked Sendable {
    private var deadline: UInt64 = .max
    private var isCancelled: (@Sendable () -> Bool)?
    private(set) var wasCancelled = false

    func arm(budget: TimeInterval, isCancelled: (@Sendable () -> Bool)?) {
        deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(max(0, budget) * 1_000_000_000)
        self.isCancelled = isCancelled
        wasCancelled = false
    }

    func disarm() { deadline = .max; isCancelled = nil }

    func shouldStop() -> Bool {
        if let isCancelled, isCancelled() { wasCancelled = true; return true }
        return DispatchTime.now().uptimeNanoseconds > deadline
    }
}
