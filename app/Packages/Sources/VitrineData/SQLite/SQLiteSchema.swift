import Foundation

/// What a SQLite file is made of, read without SQLite: the 100-byte header (format, page size, journal mode, the
/// library version that last wrote it) and, through the connection, the schema's tables, views, indexes and triggers
/// with their columns. roadmap: S-6

public struct SQLiteHeader: Sendable, Equatable {
    /// "SQLite format 3" and a NUL: the first 16 bytes of every SQLite 3 database.
    public static let magic = Array("SQLite format 3\u{0}".utf8)

    public var pageSize: Int
    /// Pages in the file, from the header when it is current; nil when the header's count is stale (old writers).
    public var pageCount: Int?
    /// The file is in WAL mode (read and write versions 2): changes not yet checkpointed live in a `-wal` file.
    public var isWAL: Bool
    public var textEncoding: String
    public var userVersion: Int32
    public var applicationID: UInt32
    /// The SQLite library that last wrote the file, as its number (3046001) and as "3.46".
    public var writerVersion: Int
    public var writerVersionName: String {
        guard writerVersion > 3_000_000 else { return "3" }
        return "3.\((writerVersion / 1000) % 1000)"
    }

    /// Reads and checks the header; throws `notSQLite` for anything that is not a SQLite 3 database.
    public static func read(_ url: URL) throws -> SQLiteHeader {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw SQLiteError.open(String(localized: "Cannot read the file", bundle: .module, comment: "Why a database cannot be opened.")) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 100), data.count == 100 else { throw SQLiteError.notSQLite }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> SQLiteHeader {
        let b = [UInt8](data.prefix(100))
        guard b.count == 100, Array(b[0..<16]) == magic else { throw SQLiteError.notSQLite }
        func u16(_ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
        let rawPage = u16(16)
        let pageSize = rawPage == 1 ? 65_536 : rawPage
        guard pageSize >= 512, pageSize & (pageSize - 1) == 0 else { throw SQLiteError.notSQLite }
        // The in-header page count is valid only when "version-valid-for" matches the change counter.
        let count = u32(24) == u32(92) && u32(28) > 0 ? Int(u32(28)) : nil
        let encoding: String
        switch u32(56) { case 2: encoding = "UTF-16 LE"; case 3: encoding = "UTF-16 BE"; default: encoding = "UTF-8" }
        return SQLiteHeader(pageSize: pageSize, pageCount: count, isWAL: b[18] == 2 || b[19] == 2, textEncoding: encoding,
                            userVersion: Int32(bitPattern: u32(60)), applicationID: u32(68), writerVersion: Int(u32(96)))
    }
}

/// One row of `sqlite_master`.
public struct SQLiteObject: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable { case table, view, index, trigger }
    public var kind: Kind
    public var name: String
    /// The table an index or trigger belongs to; the object's own name for tables and views.
    public var table: String
    /// The CREATE statement as stored; nil for automatic indexes.
    public var sql: String?

    public init(kind: Kind, name: String, table: String, sql: String?) {
        self.kind = kind; self.name = name; self.table = table; self.sql = sql
    }

    /// SQLite's own bookkeeping tables (`sqlite_sequence`, `sqlite_stat1`).
    public var isInternal: Bool { name.lowercased().hasPrefix("sqlite_") }
    public var isVirtual: Bool {
        sql?.range(of: #"^\s*CREATE\s+VIRTUAL\s+TABLE"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// Tables and views a user can read rows from.
    public var hasRows: Bool { kind == .table || kind == .view }
}

/// A column's type affinity, by the rules of SQLite's datatype documentation §3.1 (the declared type's spelling).
public enum SQLiteAffinity: String, Sendable, Equatable {
    case integer, real, numeric, text, blob

    public init(declaredType: String) {
        let t = declaredType.uppercased()
        if t.contains("INT") { self = .integer }
        else if t.contains("CHAR") || t.contains("CLOB") || t.contains("TEXT") { self = .text }
        else if t.contains("BLOB") || t.isEmpty { self = .blob }
        else if t.contains("REAL") || t.contains("FLOA") || t.contains("DOUB") { self = .real }
        else { self = .numeric }
    }

    public var isNumeric: Bool { self == .integer || self == .real || self == .numeric }
}

public struct SQLiteForeignKey: Sendable, Equatable {
    public var table: String
    /// The referenced column; nil means the referenced table's primary key.
    public var column: String?
    public var onDelete: String
    public var onUpdate: String
}

public struct SQLiteColumn: Sendable, Equatable {
    public var name: String
    public var declaredType: String
    public var notNull: Bool
    public var defaultValue: String?
    /// 1-based position in the primary key; 0 when the column is not part of it.
    public var primaryKeyPosition: Int
    /// `pragma table_xinfo`'s hidden flag: 0 ordinary, 1 hidden (virtual tables), 2 and 3 generated columns.
    public var hidden: Int
    public var references: SQLiteForeignKey?
    /// The column leads at least one index (or is the rowid alias), so lookups by it are fast.
    public var isIndexed: Bool

    public var affinity: SQLiteAffinity { SQLiteAffinity(declaredType: declaredType) }
    public var isGenerated: Bool { hidden == 2 || hidden == 3 }
}

/// A cell, as much of it as a preview needs: long text is cut, a BLOB is described by its size and kind, never
/// loaded beyond its first bytes into the cell.
public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String, truncated: Bool)
    case blob(byteCount: Int, kind: String?)

    /// "PNG · 48 KB", "BLOB · 12 bytes", "3.25", "—" for NULL.
    public var display: String {
        switch self {
        case .null: return "—"
        case .integer(let n): return String(n)
        case .real(let d): return d.formatted(.number.precision(.significantDigits(1...15)).grouping(.never))
        case .text(let s, let truncated): return truncated ? s + "…" : s
        case .blob(let n, let kind): return "\(kind ?? "BLOB") · \(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file))"
        }
    }

    public var isNull: Bool { self == .null }

    /// An INTEGER or REAL as a number; nil for text, BLOBs and NULL.
    public var number: Double? {
        switch self {
        case .integer(let n): return Double(n)
        case .real(let d): return d
        default: return nil
        }
    }

    /// The value does not fit a numeric column (text or a BLOB stored where numbers were declared).
    public func misfits(_ affinity: SQLiteAffinity) -> Bool {
        guard affinity.isNumeric else { return false }
        switch self {
        case .text(let s, _): return !s.trimmingCharacters(in: .whitespaces).isEmpty
        case .blob: return true
        default: return false
        }
    }

    /// The kind of a BLOB from its first bytes.
    public static func blobKind(_ head: [UInt8]) -> String? {
        func starts(_ p: [UInt8], at o: Int = 0) -> Bool { head.count >= o + p.count && Array(head[o..<(o + p.count)]) == p }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "PNG" }
        if starts([0xFF, 0xD8, 0xFF]) { return "JPEG" }
        if starts(Array("GIF8".utf8)) { return "GIF" }
        if starts(Array("%PDF".utf8)) { return "PDF" }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return "ZIP" }
        if starts([0x1F, 0x8B]) { return "gzip" }
        if starts(Array("bplist".utf8)) { return String(localized: "Property list", bundle: .module, comment: "Kind of a binary value stored in a database cell (an Apple property list).") }
        if starts(Array("SQLite format 3".utf8)) { return "SQLite" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "WebP" }
        if starts(Array("ftyp".utf8), at: 4) {
            let brand = head.count >= 12 ? String(decoding: head[8..<12], as: UTF8.self) : ""
            return brand.hasPrefix("hei") || brand.hasPrefix("mif") ? "HEIC" : "MP4"
        }
        return nil
    }
}

public enum SQLiteError: Error, Sendable, Equatable, LocalizedError {
    case notSQLite
    case open(String)
    case query(String)
    /// A statement ran past its time budget and was stopped.
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notSQLite: return String(localized: "Not a SQLite database", bundle: .module, comment: "Shown instead of a database preview.")
        case .open(let m): return String(localized: "Cannot open the database: \(m)", bundle: .module, comment: "Shown instead of a database preview; the argument is the reason.")
        case .query(let m): return String(localized: "Cannot read the database: \(m)", bundle: .module, comment: "Shown instead of a database preview; the argument is SQLite's message.")
        case .timedOut: return String(localized: "Reading took too long and was stopped", bundle: .module, comment: "Shown instead of a database preview.")
        case .cancelled: return String(localized: "Cancelled", bundle: .module, comment: "Shown when reading a database was cancelled.")
        }
    }
}
