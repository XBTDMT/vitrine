import Foundation
import VitrineData
import VitrineSupport

/// Rows of one table, read for Extract Table (X-6) by the readers the data previews use: CSVTable for delimited text,
/// SQLiteDatabase (read-only) for databases, ColumnarOpener for Parquet, Arrow, Feather and Excel workbooks. Cells read
/// as the preview's Copy as reads them: NULL is empty, column-file values in ColumnarText's form. roadmap: S-10
struct ExtractedTable: Sendable, Equatable {
    /// The table, view or sheet the rows came from.
    var name: String
    var columns: [String]
    var rows: [[String]]
    /// The table's row count when the reader knows it.
    var totalRows: Int?
    /// More rows follow the ones read (the row limit stopped the read).
    var hasMore: Bool

    /// RFC 4180: a field with a comma, a quote or a line break is quoted, quotes doubled (the data view's CSV copy).
    func csv() -> String {
        func field(_ s: String) -> String {
            guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = [columns.map(field).joined(separator: ",")]
        for row in rows { lines.append(row.map(field).joined(separator: ",")) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A Markdown table: `|` escaped, line breaks as spaces, short rows padded to the header's width.
    func markdown() -> String {
        func cell(_ s: String) -> String {
            s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        let width = max(columns.count, rows.map(\.count).max() ?? 0)
        let header = (0..<width).map { $0 < columns.count ? cell(columns[$0]) : "" }
        var lines = ["| " + header.joined(separator: " | ") + " |", "|" + String(repeating: "---|", count: max(1, width))]
        for row in rows {
            lines.append("| " + (0..<width).map { $0 < row.count ? cell(row[$0]) : "" }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum TableExtraction {
    /// The most rows one call returns: a column file's largest window (ColumnarLimits.maxWindowRows).
    static let maximumRows = 100_000
    static let defaultRows = 1_000

    /// Reads up to `limit` rows of the table named `requested` (any table when nil or blank; names match without
    /// regard to case). Throws VitrineIntentError with the reader's reason.
    static func extract(url: URL, name: String, table requested: String?, limit: Int) throws -> ExtractedTable {
        let limit = min(max(1, limit), maximumRows)
        let wanted = requested?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let kind = FileSniffer.kind(of: url)
        do {
            switch kind {
            case .csv(let delimiter):
                return try csv(url: url, name: name, delimiter: CSVDelimiter(delimiter), wanted: wanted, limit: limit)
            case .sqlite:
                return try sqlite(url: url, name: name, wanted: wanted, limit: limit)
            case .dataset:
                return try columnar(url: url, name: name, wanted: wanted, limit: limit)
            default:
                throw VitrineIntentError.notATable(name: name)
            }
        } catch let error as VitrineIntentError {
            throw error
        } catch CSVError.binaryContent {
            throw VitrineIntentError.notATable(name: name)
        } catch CSVError.unsupportedEncoding(let encoding) {
            throw VitrineIntentError.failed(name: name, reason: String(localized: "its text is in \(encoding), which the table reader does not read.",
                                                                       comment: "Extract Table error reason, lower-case, ending with a period; the argument is an encoding name such as UTF-16."))
        } catch {
            throw VitrineIntentError.wrapping(error, name: name)
        }
    }

    /// The one table of a single-table file is called by the file's name, with or without its extension.
    static func singleTableName(_ name: String) -> String { (name as NSString).deletingPathExtension.nilIfEmpty ?? name }

    static func pick(_ wanted: String?, from names: [String], file: String) throws -> Int {
        guard !names.isEmpty else { throw VitrineIntentError.noTables(name: file) }
        guard let wanted else { return 0 }
        if let index = names.firstIndex(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { return index }
        throw VitrineIntentError.tableNotFound(name: file, requested: wanted, available: names)
    }

    // MARK: CSV and TSV

    static func csv(url: URL, name: String, delimiter: CSVDelimiter?, wanted: String?, limit: Int) throws -> ExtractedTable {
        let tableName = singleTableName(name)
        if let wanted, wanted.caseInsensitiveCompare(tableName) != .orderedSame, wanted.caseInsensitiveCompare(name) != .orderedSame {
            throw VitrineIntentError.tableNotFound(name: name, requested: wanted, available: [tableName])
        }
        let table = try CSVTable.open(url, delimiterHint: delimiter)
        // One row past the limit says whether more follow, without counting the whole file.
        let read = try table.rows(in: 0..<(limit + 1))
        let total: Int? = table.firstPage.reachesEndOfFile ? table.firstPage.rows.count : nil
        return ExtractedTable(name: tableName, columns: (0..<table.columnCount).map(table.columnTitle),
                              rows: read.prefix(limit).map(\.fields), totalRows: total, hasMore: read.count > limit)
    }

    // MARK: SQLite

    /// The longest a statement may run before SQLite is stopped (the preview's own budget is a quarter second).
    static let sqliteBudget: TimeInterval = 30

    static func sqlite(url: URL, name: String, wanted: String?, limit: Int) throws -> ExtractedTable {
        let db = try SQLiteDatabase.open(url)
        let objects = db.browsable
        let object = objects[try pick(wanted, from: objects.map(\.name), file: name)]
        // As the data view reads them: hidden columns of virtual tables stay out, generated ones are shown.
        let columns = try db.columns(of: object.name).filter { $0.hidden == 0 || $0.isGenerated }
        let rows = try db.rows(object, columns: columns, start: 0, limit: limit + 1, rowID: nil, anchors: nil, budget: sqliteBudget)
        let total = try? db.rowCount(object, budget: 1)
        return ExtractedTable(name: object.name, columns: columns.map(\.name),
                              rows: rows.prefix(limit).map { $0.map(text) }, totalRows: total, hasMore: rows.count > limit)
    }

    /// A cell as text: NULL empty, numbers as SQLite stored them, text whole up to the reader's cell limit, a BLOB
    /// described by its kind and size.
    static func text(_ value: SQLiteValue) -> String {
        switch value {
        case .null: return ""
        case .text(let s, _): return s
        default: return value.display
        }
    }

    // MARK: Parquet, Arrow, Feather, Excel

    static func columnar(url: URL, name: String, wanted: String?, limit: Int) throws -> ExtractedTable {
        let dataset = try ColumnarOpener.open(url)
        var names = dataset.parts.map(\.name)
        // A single-table file answers to its own name as well as its part's.
        if names.count == 1, let wanted, wanted.caseInsensitiveCompare(names[0]) != .orderedSame,
           wanted.caseInsensitiveCompare(singleTableName(name)) == .orderedSame || wanted.caseInsensitiveCompare(name) == .orderedSame {
            names = [wanted]
        }
        let index = try pick(wanted, from: names, file: name)
        let table = try dataset.table(index)
        let count = min(limit, table.rowCount)
        let window = try table.read(rows: 0..<count)
        let columns = table.columns
        var rows: [[String]] = []
        rows.reserveCapacity(window.count)
        for r in 0..<window.count {
            rows.append(columns.indices.map { c in
                c < window.columns.count && r < window.columns[c].count ? ColumnarText.text(window.columns[c][r], kind: columns[c].kind) : ""
            })
        }
        return ExtractedTable(name: dataset.parts[index].name, columns: columns.map(\.name), rows: rows,
                              totalRows: table.rowCount, hasMore: table.rowCount > count)
    }
}

fileprivate extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
