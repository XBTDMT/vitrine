import Foundation
import SQLite3

/// The read-only query box (I-8, G-13): a SELECT the user types runs against an untrusted file on a connection of its
/// own that can only read. The layers, each enough on its own for the common case and together for the rest:
/// - the connection: `immutable=1` read-only for a file (an in-memory copy for CSV), `query_only=ON`,
///   `trusted_schema=OFF`, no attached databases (`SQLITE_LIMIT_ATTACHED` 0), bounded value and SQL lengths;
/// - an authorizer that allows only reading (SELECT, column reads, recursive CTEs, a read-only PRAGMA allowlist and
///   every function but a denylist with side effects) and names what it refused;
/// - exactly one statement, which SQLite itself must call read-only (`sqlite3_stmt_readonly`);
/// - a time budget and a cancel check through the progress handler, and a cap on the rows and bytes held.
/// roadmap: S-6
public final class SQLiteQueryEngine: @unchecked Sendable {
    /// What the queried thing is called in messages ("acme-notes.sqlite", "orders.csv").
    public let sourceName: String
    /// The tables and views a query can name, in schema order.
    public let tables: [String]
    public let limits: SQLiteQueryLimits

    private let db: OpaquePointer
    private let lock = NSLock()
    private let watchdog: Watchdog
    private let gate = QueryGate()

    /// Opens a read-only query connection on a SQLite file; throws `SQLiteError.notSQLite` for anything else.
    public static func open(_ url: URL, limits: SQLiteQueryLimits = SQLiteQueryLimits()) throws -> SQLiteQueryEngine {
        _ = try SQLiteHeader.read(url)
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
        return try SQLiteQueryEngine(handle: handle, sourceName: url.lastPathComponent, limits: limits)
    }

    /// Takes over an open connection (a file's, or the in-memory copy of a CSV once it is filled) and locks it down.
    /// The connection is closed if this throws.
    init(handle: OpaquePointer, sourceName: String, limits: SQLiteQueryLimits) throws {
        let db = handle
        let watchdog = Watchdog()
        self.db = db
        self.watchdog = watchdog
        self.sourceName = sourceName
        self.limits = limits
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 0 }
            return Unmanaged<Watchdog>.fromOpaque(context).takeUnretainedValue().shouldStop() ? 1 : 0
        }, Unmanaged.passUnretained(watchdog).toOpaque())
        sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(clamping: limits.maxValueBytes))
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, Int32(clamping: limits.maxSQLBytes))
        var names: [String] = []
        do {
            for pragma in ["PRAGMA trusted_schema = OFF", "PRAGMA query_only = ON"] {
                guard sqlite3_exec(db, pragma, nil, nil, nil) == SQLITE_OK else { throw SQLiteError.open(String(cString: sqlite3_errmsg(db))) }
            }
            // Loads the schema before the authorizer is in place, and lists what a query can name.
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY rowid"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw SQLiteError.open(String(cString: sqlite3_errmsg(db)))
            }
            watchdog.arm(budget: 2, isCancelled: nil)
            defer { watchdog.disarm() }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(stmt, 0))); continue }
                if rc == SQLITE_DONE { break }
                throw SQLiteError.open(String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
        tables = names
        sqlite3_set_authorizer(db, { context, action, first, second, _, _ in
            guard let context else { return SQLITE_DENY }
            let gate = Unmanaged<QueryGate>.fromOpaque(context).takeUnretainedValue()
            return gate.decide(action, first.map { String(cString: $0) }, second.map { String(cString: $0) })
        }, Unmanaged.passUnretained(gate).toOpaque())
    }

    deinit { sqlite3_close_v2(db) }

    /// True when `name` can be typed bare in a query: an identifier that is not an SQL keyword ("orders" yes,
    /// "order", "my data" and "2026-sales" no).
    public static func isPlainName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
        guard name.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }) else { return false }
        return sqlite3_keyword_check(name, Int32(name.utf8.count)) == 0
    }

    /// Runs one read-only statement and returns its rows, up to `limits.maxRows` rows and `limits.maxBytes` bytes held;
    /// past the cap the rest are counted, not held. Throws `SQLiteQueryError` with a message fit to show as is.
    public func run(_ sql: String, isCancelled: (@Sendable () -> Bool)? = nil) throws -> SQLiteQueryResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Self.stripLeading(text).isEmpty else { throw SQLiteQueryError.empty }
        guard text.utf8.count <= limits.maxSQLBytes else { throw SQLiteQueryError.tooLong(limit: limits.maxSQLBytes) }
        let keyword = Self.firstKeyword(text)
        // A statement that writes is named by its first word; any other word (a typo) gets SQLite's own message.
        guard !Self.writingKeywords.contains(keyword) else { throw SQLiteQueryError.notAllowed(keyword) }

        lock.lock(); defer { lock.unlock() }
        let stmt = try prepareOne(text)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_stmt_readonly(stmt) != 0 else { throw SQLiteQueryError.notReadOnly }

        let n = sqlite3_column_count(stmt)
        let columns = (0..<n).map { i in
            SQLiteQueryResult.Column(name: sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? String(localized: "column \(i + 1)", bundle: .module, comment: "Name of an SQL result column that has none; the argument is its 1-based number."),
                                     declaredType: sqlite3_column_decltype(stmt, i).map { String(cString: $0) })
        }
        var rows: [[SQLiteValue]] = []
        var produced = 0
        var bytes = 0
        var capped = false
        var counted = true
        watchdog.arm(budget: limits.budget, isCancelled: isCancelled)
        defer { watchdog.disarm() }
        loop: while true {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW:
                produced += 1
                if capped { continue loop }
                let row = (0..<n).map { SQLiteDatabase.value(stmt, $0) }
                bytes += row.reduce(16) { $0 + Self.cost($1) }
                if rows.count >= limits.maxRows || bytes > limits.maxBytes { capped = true; continue loop }
                rows.append(row)
            case SQLITE_DONE:
                break loop
            case SQLITE_INTERRUPT:
                if watchdog.wasCancelled { throw SQLiteQueryError.cancelled }
                // Past the cap the rows held are good; only the total is unknown.
                if capped { counted = false; break loop }
                throw SQLiteQueryError.timedOut(budget: limits.budget)
            default:
                throw SQLiteQueryError.failed(String(cString: sqlite3_errmsg(db)))
            }
        }
        let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        return SQLiteQueryResult(columns: columns, rows: rows, isCapped: capped, totalRows: counted ? produced : nil, elapsed: elapsed)
    }

    /// Prepares the first statement and refuses anything after it.
    private func prepareOne(_ text: String) throws -> OpaquePointer {
        try text.withCString { base -> OpaquePointer in
            var stmt: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            gate.reset()
            let rc = sqlite3_prepare_v2(db, base, -1, &stmt, &tail)
            guard rc == SQLITE_OK, let stmt else {
                sqlite3_finalize(stmt)
                if let denied = gate.denied { throw SQLiteQueryError.notAllowed(denied) }
                throw SQLiteQueryError.failed(String(cString: sqlite3_errmsg(db)))
            }
            if let tail, !Self.stripLeading(String(cString: tail)).isEmpty {
                sqlite3_finalize(stmt)
                throw SQLiteQueryError.multipleStatements
            }
            return stmt
        }
    }

    /// Statements that begin with these words write or change the connection; they are refused before SQLite parses
    /// them, by name ("INSERT is not allowed"). The authorizer and `sqlite3_stmt_readonly` are what enforce reading
    /// (a `WITH … DELETE` passes this list and is refused there); this only gives the common refusals a clear name.
    static let writingKeywords: Set<String> = ["INSERT", "REPLACE", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER", "ATTACH",
                                               "DETACH", "VACUUM", "BEGIN", "COMMIT", "END", "ROLLBACK", "SAVEPOINT",
                                               "RELEASE", "REINDEX", "ANALYZE"]

    /// The first word after any whitespace, comments and semicolons, upper-cased.
    static func firstKeyword(_ sql: String) -> String {
        String(stripLeading(sql).prefix { $0.isLetter }).uppercased()
    }

    /// `sql` without its leading whitespace, `--` and `/* */` comments and stray semicolons.
    static func stripLeading(_ sql: String) -> Substring {
        var s = Substring(sql)
        while true {
            let before = s.count
            s = s.drop { $0.isWhitespace || $0 == ";" }
            if s.hasPrefix("--") { s = s.drop { $0 != "\n" } }
            if s.hasPrefix("/*") {
                if let end = s.range(of: "*/") { s = s[end.upperBound...] } else { s = s.dropFirst(s.count) }
            }
            if s.count == before { return s }
        }
    }

    private static func cost(_ value: SQLiteValue) -> Int {
        switch value {
        case .text(let s, _): return 16 + s.utf8.count
        default: return 16
        }
    }
}

/// Bounds on one query and on the CSV copy it may run on (G-13). roadmap: S-6
public struct SQLiteQueryLimits: Sendable, Equatable {
    /// Time one statement may run before it is stopped.
    public var budget: TimeInterval = 15
    /// Rows held for the grid; past this the rest are counted and the result says "first N rows".
    public var maxRows = 100_000
    /// Bytes held across all result cells (text is already cut to `SQLiteDatabase.textLimit` per cell).
    public var maxBytes = 64 * 1024 * 1024
    /// Longest SQL text accepted.
    public var maxSQLBytes = 100_000
    /// Longest string or BLOB a query may build or read (`SQLITE_LIMIT_LENGTH`): stops `randomblob(1e9)`.
    public var maxValueBytes = 64 * 1024 * 1024
    /// Largest CSV/TSV file copied into memory to query: the copy is about 1.2× the file and takes about 0.1 s per MB
    /// (measured 2026-10-29: 8 MB, 139,832 rows → 9.7 MB in 0.9–1.2 s), so 32 MB is a ~40 MB copy in ~5 s inside
    /// the preview extension's memory.
    public var csvMaxBytes: Int64 = 32 * 1024 * 1024
    public init() {}
}

/// The rows of one query.
public struct SQLiteQueryResult: Sendable, Equatable {
    public struct Column: Sendable, Equatable {
        public var name: String
        /// The declared type when the column reads a table column directly; nil for expressions.
        public var declaredType: String?
        public init(name: String, declaredType: String?) { self.name = name; self.declaredType = declaredType }
    }
    public var columns: [Column]
    public var rows: [[SQLiteValue]]
    /// More rows came than were held (`SQLiteQueryLimits.maxRows` or `maxBytes`).
    public var isCapped: Bool
    /// Every row the statement produced; nil when counting past the cap ran out of time.
    public var totalRows: Int?
    public var elapsed: TimeInterval

    public init(columns: [Column], rows: [[SQLiteValue]], isCapped: Bool, totalRows: Int?, elapsed: TimeInterval) {
        self.columns = columns; self.rows = rows; self.isCapped = isCapped; self.totalRows = totalRows; self.elapsed = elapsed
    }
}

/// Why a query did not run, worded to show as is under the query field.
public enum SQLiteQueryError: Error, Sendable, Equatable, LocalizedError {
    case empty
    case tooLong(limit: Int)
    /// The authorizer or the first word refused something: "INSERT", "ATTACH", "PRAGMA journal_mode = …".
    case notAllowed(String)
    case multipleStatements
    case notReadOnly
    /// SQLite's own message: `near "SELEC": syntax error`, `no such table: ordrs`.
    case failed(String)
    case timedOut(budget: TimeInterval)
    case cancelled
    /// A CSV larger than the copy bound.
    case tooLarge(fileBytes: Int64, limit: Int64)

    public var errorDescription: String? {
        switch self {
        case .empty: return String(localized: "Type a SELECT query, then press Return.", bundle: .module, comment: "Message under the SQL query box. SELECT is an SQL keyword and stays as is.")
        case .tooLong(let limit): return String(localized: "The query is longer than \(limit.formatted()) characters.", bundle: .module, comment: "Message under the SQL query box.")
        case .notAllowed(let what): return String(localized: "Read-only: \(what) is not allowed. Only SELECT queries run, and the file is never written.", bundle: .module, comment: "Message under the SQL query box. The argument is the refused SQL statement, such as INSERT.")
        case .multipleStatements: return String(localized: "One statement at a time: remove everything after the first semicolon.", bundle: .module, comment: "Message under the SQL query box.")
        case .notReadOnly: return String(localized: "Read-only: only SELECT queries run, and the file is never written.", bundle: .module, comment: "Message under the SQL query box.")
        case .failed(let message): return message.prefix(1).uppercased() + message.dropFirst()
        case .timedOut(let budget): return String(localized: "The query ran past \(budget.formatted(.number.precision(.fractionLength(0...1)))) s and was stopped.", bundle: .module, comment: "Message under the SQL query box. The argument is a number of seconds.")
        case .cancelled: return String(localized: "Query cancelled.", bundle: .module, comment: "Message under the SQL query box.")
        case .tooLarge(let bytes, let limit):
            let f = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
            return String(localized: "SQL runs on files up to \(f(limit)); this one is \(f(bytes)). Filter still searches every row.", bundle: .module, comment: "Message under the SQL query box. The arguments are file sizes; Filter is the name of the search box.")
        }
    }
}

/// The authorizer's rules (G-13). Allowed: SELECT, reading columns, recursive CTEs, read-only PRAGMAs from the
/// allowlist, and every function except those with side effects. Everything else is denied and named. roadmap: S-6
final class QueryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var firstDenied: String?
    var denied: String? { lock.withLock { firstDenied } }
    func reset() { lock.withLock { firstDenied = nil } }

    /// PRAGMAs that read and take an argument naming what to read (`table_info(notes)`).
    static let readPragmasWithArgument: Set<String> = ["table_info", "table_xinfo", "table_list", "index_list", "index_info",
                                                       "index_xinfo", "foreign_key_list", "foreign_key_check",
                                                       "integrity_check", "quick_check"]
    /// PRAGMAs that only read when they are given no value (`PRAGMA user_version`, never `= 7`).
    static let readPragmasWithoutValue: Set<String> = ["page_count", "page_size", "encoding", "user_version", "application_id",
                                                       "freelist_count", "schema_version", "data_version", "compile_options",
                                                       "collation_list", "function_list", "module_list", "pragma_list",
                                                       "auto_vacuum", "journal_mode", "foreign_keys", "max_page_count",
                                                       "table_list", "integrity_check", "quick_check", "foreign_key_check"]
    /// Functions with side effects or that hand out pointers: never allowed.
    static let deniedFunctions: Set<String> = ["load_extension", "fts3_tokenizer", "readfile", "writefile", "edit",
                                               "sqlite_dbpage", "sqlite_dbdata", "sqlite_dbptr", "fts5"]

    func decide(_ action: Int32, _ first: String?, _ second: String?) -> Int32 {
        switch action {
        case SQLITE_SELECT, SQLITE_READ, SQLITE_RECURSIVE:
            return SQLITE_OK
        case SQLITE_FUNCTION:
            let name = (second ?? "").lowercased()
            return Self.deniedFunctions.contains(name) ? deny("\(name)()") : SQLITE_OK
        case SQLITE_PRAGMA:
            let name = (first ?? "").lowercased()
            if Self.readPragmasWithArgument.contains(name) { return SQLITE_OK }
            if second == nil, Self.readPragmasWithoutValue.contains(name) { return SQLITE_OK }
            return deny(second == nil ? "PRAGMA \(name)" : "PRAGMA \(name) = …")
        default:
            return deny(Self.label(action))
        }
    }

    private func deny(_ what: String) -> Int32 {
        lock.withLock { if firstDenied == nil { firstDenied = what } }
        return SQLITE_DENY
    }

    static func label(_ action: Int32) -> String {
        switch action {
        case SQLITE_INSERT: return "INSERT"
        case SQLITE_UPDATE: return "UPDATE"
        case SQLITE_DELETE: return "DELETE"
        case SQLITE_CREATE_INDEX, SQLITE_CREATE_TABLE, SQLITE_CREATE_TEMP_INDEX, SQLITE_CREATE_TEMP_TABLE,
             SQLITE_CREATE_TEMP_TRIGGER, SQLITE_CREATE_TEMP_VIEW, SQLITE_CREATE_TRIGGER, SQLITE_CREATE_VIEW, SQLITE_CREATE_VTABLE:
            return "CREATE"
        case SQLITE_DROP_INDEX, SQLITE_DROP_TABLE, SQLITE_DROP_TEMP_INDEX, SQLITE_DROP_TEMP_TABLE,
             SQLITE_DROP_TEMP_TRIGGER, SQLITE_DROP_TEMP_VIEW, SQLITE_DROP_TRIGGER, SQLITE_DROP_VIEW, SQLITE_DROP_VTABLE:
            return "DROP"
        case SQLITE_ATTACH: return "ATTACH"
        case SQLITE_DETACH: return "DETACH"
        case SQLITE_ALTER_TABLE: return "ALTER TABLE"
        case SQLITE_REINDEX: return "REINDEX"
        case SQLITE_ANALYZE: return "ANALYZE"
        case SQLITE_TRANSACTION: return String(localized: "BEGIN, COMMIT and ROLLBACK", bundle: .module, comment: "Refused SQL statements, named in 'Read-only: %@ is not allowed.'; the keywords stay as they are.")
        case SQLITE_SAVEPOINT: return "SAVEPOINT"
        default: return String(localized: "this statement", bundle: .module, comment: "A refused SQL statement with no name, in 'Read-only: %@ is not allowed.'")
        }
    }
}
