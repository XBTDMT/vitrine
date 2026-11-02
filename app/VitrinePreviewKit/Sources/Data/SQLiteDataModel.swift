import Foundation
import VitrineData
import VitrineDocument
import VitrineSupport

/// A SQLite file in the data Inspector (data r3-a, D-2): its tables and views on the Database tab, the picked one's
/// rows in the grid, read a page at a time on the main connection under a time budget; row counts and the rowid
/// anchors that make any page a seek (G-11) are built on a second connection in the background. roadmap: S-6
@MainActor
final class SQLiteDataModel: TabularModel {
    let db: SQLiteDatabase
    /// A second connection for counts and anchors, so a page read never waits behind them.
    private let background: SQLiteDatabase
    let objects: [SQLiteObject]
    let fileSize: Int64
    let modified: Date?
    private(set) var selected: Int
    private(set) var columns: [SQLiteColumn] = []
    private(set) var rowID: String?
    private(set) var anchors: [Int64]?
    /// Exact row counts by object name; a name in `uncounted` ran past its budget.
    private(set) var counts: [String: Int] = [:]
    private(set) var uncounted: Set<String> = []
    private var pages: [Int: [[SQLiteValue]]] = [:]
    private var misfitColumns: Set<Int> = []
    private var summaries: [Int: SQLiteDatabase.ColumnSummary] = [:]
    private var charts: [Int: DataColumnChart] = [:]
    private(set) var layoutVersion = 0
    let pageSize = SQLiteDatabase.anchorStride
    static let profileSample = 10_000

    var onChange: (() -> Void)?
    /// Called when what the pill says changed (a count arrived, another table was picked).
    var onDocumentChange: (() -> Void)?

    init(url: URL) throws {
        db = try SQLiteDatabase.open(url)
        background = try SQLiteDatabase.open(url)
        objects = db.browsable
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        fileSize = Int64(values?.fileSize ?? 0)
        modified = values?.contentModificationDate
        // Open on the first user table (the design's notes), else the first view, else SQLite's own tables.
        selected = 0
        if !objects.isEmpty { load(0) }
    }

    var current: SQLiteObject? { objects.indices.contains(selected) ? objects[selected] : nil }

    private func load(_ index: Int) {
        selected = index
        let object = objects[index]
        columns = ((try? db.columns(of: object.name)) ?? []).filter { $0.hidden == 0 || $0.isGenerated }
        rowID = db.rowIDName(for: object, columns: columns)
        anchors = nil
        pages = [:]
        summaries = [:]
        charts = [:]
        cancelArrange()
        arrangement = DataArrangement()
        arrangedIDs = nil
        arrangedCount = nil
        layoutVersion += 1
        if counts[object.name] == nil, !uncounted.contains(object.name) {
            // Counted before the first paint when it is quick (most tables: milliseconds); else in the background.
            if let n = try? db.rowCount(object, budget: 0.15) { counts[object.name] = n }
        }
        if let first = try? db.rows(object, columns: columns, start: 0, limit: pageSize, rowID: rowID, anchors: nil) {
            pages[0] = first
            misfitColumns = Set(columns.indices.filter { c in first.contains { c < $0.count && $0[c].misfits(columns[c].affinity) } })
        } else {
            misfitColumns = []
        }
    }

    // MARK: TabularModel

    var columnCount: Int { columns.count }
    var rowCount: Int {
        guard let object = current else { return 0 }
        if let n = counts[object.name] { return n }
        // Not counted (yet): what has been read so far.
        return pages.values.reduce(0) { $0 + $1.count }
    }

    func title(_ column: Int) -> String { columns.indices.contains(column) ? columns[column].name : "" }
    func isNumeric(_ column: Int) -> Bool { columns.indices.contains(column) && columns[column].affinity.isNumeric }
    func hasMisfits(_ column: Int) -> Bool { misfitColumns.contains(column) }

    func value(row: Int, column: Int) -> SQLiteValue? {
        guard let object = current else { return nil }
        let page = row / pageSize, offset = row % pageSize
        if pages[page] == nil {
            // A read that runs past its budget is not cached; the row is drawn again once anchors make it a seek.
            let start = page * pageSize
            let rows: [[SQLiteValue]]?
            if let ids = arrangedIDs, let rowID {
                rows = try? db.rows(object, columns: columns, rowIDs: ids[min(start, ids.count)..<min(start + pageSize, ids.count)], rowID: rowID)
            } else if !arrangement.isEmpty {
                rows = try? db.rows(object, columns: columns, arrangement: sqlArrangement(arrangement), start: start, limit: pageSize)
            } else {
                rows = try? db.rows(object, columns: columns, start: start, limit: pageSize, rowID: rowID, anchors: anchors)
            }
            guard let rows else { return nil }
            pages[page] = rows
        }
        guard let rows = pages[page], offset < rows.count, column < rows[offset].count else { return nil }
        return rows[offset][column]
    }

    func cell(row: Int, column: Int) -> DataCellValue {
        guard let value = value(row: row, column: column) else { return DataCellValue(text: "", style: .missing) }
        if value.isNull { return DataCellValue(text: value.display, style: .missing) }
        return DataCellValue(text: value.display, style: value.misfits(columns[column].affinity) ? .misfit : .plain)
    }

    func sampleValues(column: Int) -> [String] {
        (pages[0] ?? []).prefix(50).compactMap { column < $0.count ? $0[column].display : nil }
    }

    let fileTabTitle = String(localized: "Database", bundle: .previewKit, comment: "Inspector tab: facts about the whole SQLite database.")

    var parts: [DataPart] {
        objects.enumerated().map { i, o in
            let detail: String
            if o.kind == .view { detail = String(localized: "view", bundle: .previewKit, comment: "A database part that is a view (not a table); shown in place of its row count.") }
            else if let n = counts[o.name] { detail = n.formatted() }
            else if uncounted.contains(o.name) { detail = "—" }
            else { detail = String(localized: "counting…", bundle: .previewKit, comment: "A table's row count is still being counted.") }
            return DataPart(name: o.name, detail: detail, isSelected: i == selected)
        }
    }

    func selectPart(_ index: Int) {
        guard objects.indices.contains(index), index != selected else { return }
        load(index)
        startAnchors()
        onChange?()
        onDocumentChange?()
    }

    func fileEntries() -> [DataEntry] { keyedFileEntries().map { ($0.label, $0.value) } }

    /// The Database tab's facts, each with a stable key for the document (labels are translated, keys are not).
    private func keyedFileEntries() -> [Fact] {
        let h = db.header
        var out = [Fact(key: "file", label: String(localized: "File", bundle: .previewKit, comment: "Inspector fact label: the database file's format and version."), value: "SQLite \(h.writerVersionName)" + (h.isWAL ? " · WAL" : "")),
                   Fact(key: "size", label: Self.sizeLabel, value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)),
                   Fact(key: "tables", label: String(localized: "Tables", bundle: .previewKit, comment: "Inspector fact label: number of tables."),
                        value: objects.filter { $0.kind == .table && !$0.isInternal }.count.formatted()),
                   Fact(key: "views", label: String(localized: "Views", bundle: .previewKit, comment: "Inspector fact label: number of views."), value: db.count(of: .view).formatted()),
                   Fact(key: "indexes", label: String(localized: "Indexes", bundle: .previewKit, comment: "Inspector fact label: number of indexes."), value: db.count(of: .index).formatted()),
                   Fact(key: "triggers", label: String(localized: "Triggers", bundle: .previewKit, comment: "Inspector fact label: number of triggers."), value: db.count(of: .trigger).formatted()),
                   Fact(key: "pagesize", label: String(localized: "Page size", bundle: .previewKit, comment: "Inspector fact label: the database page size."),
                        value: ByteCountFormatter.string(fromByteCount: Int64(h.pageSize), countStyle: .memory)),
                   Fact(key: "encoding", label: String(localized: "Encoding", bundle: .previewKit, comment: "Inspector fact label: the database text encoding."), value: h.textEncoding)]
        if h.userVersion != 0 {
            out.append(Fact(key: "userversion", label: String(localized: "User version", bundle: .previewKit, comment: "Inspector fact label: the app-defined version number stored in the database."), value: String(h.userVersion)))
        }
        if h.isWAL {
            let value = modified.map { date in
                let when = date.formatted(date: .abbreviated, time: .shortened)
                return String(localized: "Rows as of \(when)", bundle: .previewKit, comment: "The rows shown are as of this date and time (the file's last change).")
            } ?? String(localized: "Unknown", bundle: .previewKit, comment: "A value that is not known.")
            out.append(Fact(key: "lastcheckpoint", label: String(localized: "Last checkpoint", bundle: .previewKit, comment: "Inspector fact label: when the write-ahead log was last folded into the database."), value: value))
        }
        return out
    }

    func columnEntries(_ column: Int) -> [DataEntry] {
        guard columns.indices.contains(column), let object = current else { return [] }
        let c = columns[column]
        var out: [DataEntry] = [(String(localized: "Type", bundle: .previewKit, comment: "Column fact label: the column's data type."), c.declaredType.isEmpty ? String(localized: "Any", bundle: .previewKit, comment: "A SQLite column with no declared type: it takes any type.") : c.declaredType)]
        if c.primaryKeyPosition > 0 {
            out.append((String(localized: "Key", bundle: .previewKit, comment: "Column fact label: the column's key role."), String(localized: "Primary key", bundle: .previewKit, comment: "Column fact value: the column is the table's primary key.")))
        }
        if c.notNull { out.append((String(localized: "Not null", bundle: .previewKit, comment: "Column fact label: the column refuses empty (NULL) values."), Self.yes)) }
        if let d = c.defaultValue { out.append((String(localized: "Default", bundle: .previewKit, comment: "Column fact label: the column's default value."), d)) }
        if let ref = c.references {
            out.append((String(localized: "Links to", bundle: .previewKit, comment: "Column fact label: the table and column this column refers to."), "\(ref.table).\(ref.column ?? Self.keyWord)"))
            if ref.onDelete != "NO ACTION" {
                out.append((String(localized: "On delete", bundle: .previewKit, comment: "Column fact label: what happens to this row when the referenced row is deleted (an SQL action)."), ref.onDelete.lowercased()))
            }
        }
        if c.isIndexed { out.append((String(localized: "Indexed", bundle: .previewKit, comment: "Column fact label: the column has an index."), Self.yes)) }
        if c.isGenerated { out.append((String(localized: "Generated", bundle: .previewKit, comment: "Column fact label: the column is computed by the database."), Self.yes)) }
        if summaries[column] == nil { summaries[column] = try? db.summary(of: c.name, in: object, sample: Self.profileSample) }
        if let s = summaries[column] {
            out.append((String(localized: "Values", bundle: .previewKit, comment: "Column fact label: number of non-empty values profiled."), s.nonNull.formatted()))
            out.append(("NULL", (s.rows - s.nonNull).formatted()))
            out.append((String(localized: "Distinct", bundle: .previewKit, comment: "Column fact label: number of different values."), s.distinct.formatted()))
            if !s.minimum.isNull { out.append((String(localized: "Min", bundle: .previewKit, comment: "Column fact label: the smallest value."), s.minimum.display)) }
            if !s.maximum.isNull { out.append((String(localized: "Max", bundle: .previewKit, comment: "Column fact label: the largest value."), s.maximum.display)) }
        }
        let referencedBy = db.references(to: object.name).filter { _ in c.primaryKeyPosition > 0 }
        if !referencedBy.isEmpty {
            out.append((String(localized: "Referenced by", bundle: .previewKit, comment: "Column fact label: the tables whose columns refer to this one."), referencedBy.joined(separator: ", ")))
        }
        return out
    }

    var profileNote: String {
        guard let s = summaries.values.first else { return "" }
        if let n = current.flatMap({ counts[$0.name] }), n <= s.rows {
            let count = n.formatted()
            return String(localized: "Profiled all \(count) rows", bundle: .previewKit, comment: "Inspector note: the column profile covers every row; the argument is their count.")
        }
        let count = s.rows.formatted()
        return String(localized: "Profiled the first \(count) rows", bundle: .previewKit, comment: "Inspector note: the column profile covers the first rows only; the argument is their count.")
    }

    func rowEntries(_ row: Int) -> [DataEntry] {
        columns.indices.compactMap { c in value(row: row, column: c).map { (columns[c].name, $0.isNull ? "" : $0.display) } }
    }

    // MARK: Header tags, chart, selection numbers (G12, D-2, I-4, I-5)

    func typeTag(_ column: Int) -> String {
        guard columns.indices.contains(column) else { return "Aa" }
        let c = columns[column]
        let declared = c.declaredType.uppercased()
        if declared.contains("BOOL") { return "0|1" }
        if declared.contains("DATE") || declared.contains("TIME") {
            return "date"
        }
        switch c.affinity {
        case .integer: return "123"
        case .real, .numeric: return "1.5"
        case .blob: return declared.isEmpty ? "Aa" : String(localized: "BIN", bundle: .previewKit, comment: "Column header type tag for a binary column; keep very short.")
        case .text: return DataModel.textTag(sampleValues(column: column))
        }
    }

    /// "folder_id · INTEGER · not null · → folders.id, on delete cascade · indexed" (D-2).
    func headerTooltip(_ column: Int) -> String {
        guard columns.indices.contains(column) else { return "" }
        let c = columns[column]
        var parts = [c.name, c.declaredType.isEmpty ? String(localized: "any type", bundle: .previewKit, comment: "Column header tooltip: the column has no declared type.") : c.declaredType]
        if c.primaryKeyPosition > 0 { parts.append(String(localized: "primary key", bundle: .previewKit, comment: "Column header tooltip: the column is the primary key.")) }
        if c.notNull { parts.append(String(localized: "not null", bundle: .previewKit, comment: "Column header tooltip: the column refuses NULL values.")) }
        if let d = c.defaultValue { parts.append(String(localized: "default \(d)", bundle: .previewKit, comment: "Column header tooltip: the column's default value (SQL text).")) }
        if let ref = c.references {
            let target = "\(ref.table).\(ref.column ?? Self.keyWord)"
            let action = ref.onDelete.lowercased()
            parts.append(ref.onDelete == "NO ACTION"
                ? String(localized: "→ \(target)", bundle: .previewKit, comment: "Column header tooltip: the table.column this column refers to.")
                : String(localized: "→ \(target), on delete \(action)", bundle: .previewKit, comment: "Column header tooltip: the table.column this column refers to, and the SQL action on delete."))
        }
        if c.isIndexed { parts.append(String(localized: "indexed", bundle: .previewKit, comment: "Column header tooltip: the column has an index.")) }
        if c.isGenerated { parts.append(String(localized: "generated", bundle: .previewKit, comment: "Column header tooltip: the column is computed by the database.")) }
        return parts.joined(separator: " · ")
    }

    /// Profiled over the first `profileSample` rows, like the Column tab's counts.
    func columnChart(_ column: Int) -> DataColumnChart? {
        if let cached = charts[column] { return cached }
        guard columns.indices.contains(column), let object = current,
              let values = try? db.values(of: columns[column].name, in: object, sample: Self.profileSample) else { return nil }
        let affinity = columns[column].affinity
        var chart = DataColumnChart()
        var numbers: [Double] = []
        var counts: [String: Int] = [:]
        var misfits: [String] = []
        for v in values {
            if v.isNull { chart.empty += 1; continue }
            if v.misfits(affinity) {
                chart.misfit += 1
                if misfits.count < 3, !misfits.contains(v.display) { misfits.append(v.display) }
            } else {
                chart.valid += 1
            }
            if let n = v.number { numbers.append(n) }
            if case .blob = v { continue }
            if counts.count < 10_000 || counts[v.display] != nil { counts[v.display, default: 0] += 1 }
        }
        if affinity.isNumeric, let lo = numbers.min(), let hi = numbers.max() {
            let bins = hi > lo ? 16 : 1
            var histogram = Array(repeating: 0, count: bins)
            for n in numbers { histogram[min(max(hi > lo ? Int((n - lo) / (hi - lo) * Double(bins)) : 0, 0), bins - 1)] += 1 }
            chart.histogram = histogram
            chart.low = SQLiteValue.real(lo).display
            chart.high = SQLiteValue.real(hi).display
        }
        chart.misfitKind = affinity.isNumeric ? .notNumbers : .other
        if !misfits.isEmpty {
            chart.note = chart.misfitKind.note(count: chart.misfit, inSample: false,
                                               examples: misfits.map { "“\($0)”" }.joined(separator: ", "))
        }
        if affinity == .text || counts.values.contains(where: { $0 > 1 }) {
            chart.top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5)
                .map { DataTopValue(value: $0.key, count: $0.value) }
        }
        chart.topTotal = chart.valid + chart.misfit
        charts[column] = chart
        return chart
    }

    func number(row: Int, column: Int) -> Double? { value(row: row, column: column)?.number }

    /// SQLite files have no shape problems the banner shows.
    var lint: DataLint? { nil }

    func shownRow(forSource source: Int) -> Int? { arrangement.isEmpty && source < rowCount ? source : nil }

    // MARK: Filter and sort

    private(set) var arrangement = DataArrangement()
    /// A rowid table's rows in shown order; nil without an arrangement or for a view.
    private var arrangedIDs: [Int64]?
    /// A view's or WITHOUT ROWID table's row count under the filter.
    private var arrangedCount: Int?
    private var arrangeFlag: CancelFlag?
    private var arrangeGeneration = 0

    var shownCount: Int { arrangedIDs?.count ?? arrangedCount ?? rowCount }
    /// SQLite has no file-order numbers once sorted or filtered: the gutter counts the result.
    func rowNumber(_ row: Int) -> Int { row + 1 }

    private func sqlArrangement(_ a: DataArrangement) -> SQLiteDatabase.Arrangement {
        SQLiteDatabase.Arrangement(filter: a.filter, sortColumn: a.sortColumn.flatMap { columns.indices.contains($0) ? columns[$0].name : nil },
                                   ascending: a.ascending)
    }

    func arrange(_ next: DataArrangement) async -> Bool {
        cancelArrange()
        arrangeGeneration += 1
        let generation = arrangeGeneration
        guard let object = current else { return false }
        if next.isEmpty {
            arrangement = next; arrangedIDs = nil; arrangedCount = nil; pages = [:]; onChange?(); return true
        }
        let flag = CancelFlag()
        arrangeFlag = flag
        let background = self.background, columns = self.columns, rowID = self.rowID, sql = sqlArrangement(next)
        // A rowid table keeps the arranged rowids (one pass, then any page is a lookup); a view or WITHOUT ROWID table
        // counts the filter's rows and reads each page with ORDER BY … OFFSET.
        let result = await Task.detached(priority: .userInitiated) { () -> ([Int64]?, Int)? in
            if let rowID {
                guard let ids = try? background.rowIDs(object, rowID: rowID, columns: columns, arrangement: sql,
                                                       isCancelled: { flag.isCancelled }) else { return nil }
                return (ids, ids.count)
            }
            guard let n = try? background.rowCount(object, columns: columns, arrangement: sql,
                                                   isCancelled: { flag.isCancelled }) else { return nil }
            return (nil, n)
        }.value
        guard generation == arrangeGeneration, !flag.isCancelled, let result, object == current else { return false }
        arrangement = next
        arrangedIDs = result.0
        arrangedCount = result.0 == nil ? result.1 : nil
        pages = [:]
        onChange?()
        return true
    }

    /// Stops a running arrangement, and one still waiting to start (the generation moves on, so it returns false).
    func cancelArrange() { arrangeGeneration += 1; arrangeFlag?.cancel(); arrangeFlag = nil }

    // MARK: The document

    /// "notes · 12,408 rows", or "≥ 200 rows" before an uncounted table's count arrives.
    var headline: String {
        guard let object = current else { return String(localized: "No tables", bundle: .previewKit, comment: "Summary of a SQLite file with no tables or views.") }
        let name = object.name
        if let n = counts[object.name] {
            let count = n.formatted()
            return n == 1
                ? String(localized: "\(name) · \(count) row", bundle: .previewKit, comment: "Summary: the table shown and its one row. Arguments: table name, formatted count.")
                : String(localized: "\(name) · \(count) rows", bundle: .previewKit, comment: "Summary: the table shown and its row count. Arguments: table name, formatted count.")
        }
        let count = rowCount.formatted()
        return String(localized: "\(name) · ≥ \(count) rows", bundle: .previewKit, comment: "Summary: the table shown and at least this many rows (still counting). Arguments: table name, formatted count.")
    }

    /// The picked table's CREATE statement with its indexes and triggers, for the Schema view.
    var schemaSQL: String {
        guard let object = current else { return "" }
        return ([object] + db.dependents(of: object.name)).compactMap { $0.sql.map { $0 + ";" } }.joined(separator: "\n\n")
    }

    /// The tables and their row counts as text: what Copy copies and what find and Spotlight read.
    var outlineText: String {
        objects.map { o in "\(o.name)\t\(counts[o.name].map { $0.formatted() } ?? (o.kind == .view ? Self.viewWord : ""))" }.joined(separator: "\n")
    }

    func document() -> PreviewDocument {
        var facts = [Fact(key: "headline", label: String(localized: "Summary", bundle: .previewKit, comment: "Fact label: the one-line summary of the file."), value: headline),
                     Fact(key: "size", label: Self.sizeLabel, value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))]
        facts += keyedFileEntries().filter { $0.key != "size" }
        var badges: [Badge] = []
        if db.header.isWAL {
            badges.append(Badge(level: .info, title: String(localized: "WAL mode", bundle: .previewKit, comment: "Badge title: the SQLite database uses a write-ahead log (WAL)."),
                                detail: String(localized: "Newer changes may sit in the -wal file beside it, which Quick Look does not read.", bundle: .previewKit, comment: "Badge detail for a WAL-mode database; “-wal” is the log file's name ending, keep it.")))
        }
        let schema = schemaSQL
        let views: [DocumentView] = schema.isEmpty ? [.text(outlineText)] : [.text(outlineText), .code(schema, language: "sql")]
        var doc = PreviewDocument(kind: .sqlite, facts: facts, badges: badges, views: views)
        let rowsTitle = "Rows"
        doc.viewTitles = schema.isEmpty ? [rowsTitle]
            : [rowsTitle, "Schema"]
        return doc
    }

    private static let sizeLabel = String(localized: "Size", bundle: .previewKit, comment: "Fact label: the file size.")
    private static let yes = String(localized: "Yes", bundle: .previewKit, comment: "Column fact value: the property holds.")
    private static let viewWord = String(localized: "view", bundle: .previewKit, comment: "A database part that is a view (not a table); shown in place of its row count.")
    /// Stands for the referenced table's primary key when a foreign key names no column: "folders.key".
    private static let keyWord = String(localized: "key", bundle: .previewKit, comment: "Stands for a referenced table's primary key in “table.key”, when the reference names no column.")

    // MARK: Background work

    // Tasks are Sendable; they are only cancelled from deinit, after the last main-actor use. The work runs in
    // detached tasks, which do not inherit cancellation, so a flag stops their statements through the watchdog.
    nonisolated(unsafe) private var countTask: Task<Void, Never>?
    nonisolated(unsafe) private var anchorTask: Task<Void, Never>?
    private let stopCounts = CancelFlag()
    nonisolated(unsafe) private var stopAnchors = CancelFlag()

    deinit { stopCounts.cancel(); stopAnchors.cancel(); countTask?.cancel(); anchorTask?.cancel() }

    /// Counts every table and view the first paint did not, then builds the picked table's anchors.
    func start() {
        startAnchors()
        guard countTask == nil else { return }
        let pending = objects.filter { counts[$0.name] == nil }
        guard !pending.isEmpty else { return }
        let background = self.background, stop = stopCounts
        countTask = Task { [weak self] in
            for object in pending {
                guard !stop.isCancelled else { return }
                let result = await Task.detached(priority: .utility) { () -> Int? in
                    try? background.rowCount(object, budget: object.kind == .view ? 2 : 30, isCancelled: { stop.isCancelled })
                }.value
                guard let self else { return }
                if let result { self.counts[object.name] = result } else { self.uncounted.insert(object.name) }
                self.onChange?()
                if object == self.current { self.onDocumentChange?() }
            }
        }
    }

    private func startAnchors() {
        stopAnchors.cancel()
        anchorTask?.cancel()
        guard let object = current, let rowID, (counts[object.name] ?? .max) > pageSize else { return }
        let background = self.background, stop = CancelFlag()
        stopAnchors = stop
        anchorTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                try? background.rowIDAnchors(object, rowID: rowID, isCancelled: { stop.isCancelled })
            }.value
            guard let self, let built, object == self.current, !stop.isCancelled else { return }
            self.anchors = built
            // Pages that timed out on OFFSET can now be read as seeks.
            self.onChange?()
        }
    }

    /// Waits for counts and anchors (tests).
    func waitForBackground() async {
        await countTask?.value
        await anchorTask?.value
    }
}

/// A cancel switch a detached task's statements can read from any thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}
