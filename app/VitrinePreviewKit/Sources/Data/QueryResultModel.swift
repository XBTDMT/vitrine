import Foundation
import VitrineData

/// The rows of a read-only query (I-8, G-13), drawn by the same grid and Inspector as the file's own rows: the
/// query's column names in the header, numbers right-aligned (a declared numeric type, or every value a number),
/// NULL dim, row numbers counting the result. The rows are held in memory, capped by the engine; a header click
/// sorts them in memory. The Inspector's first tab is "Query": the SQL, the count, the time and that it is read-only.
/// roadmap: S-6
@MainActor
final class QueryResultModel: TabularModel {
    let sql: String
    let result: SQLiteQueryResult
    /// "orders = this file", "acme-notes.sqlite".
    let source: String
    private let numeric: [Bool]
    private let misfit: [Bool]
    private var summaries: [Int: Summary] = [:]

    var onChange: (() -> Void)?

    /// A column's profile over the held rows.
    struct Summary {
        var rows: Int
        var nonNull: Int
        var distinct: Int
        var minimum: SQLiteValue
        var maximum: SQLiteValue
    }

    init(sql: String, result: SQLiteQueryResult, source: String) {
        self.sql = sql
        self.result = result
        self.source = source
        let rows = result.rows
        numeric = result.columns.indices.map { c in
            if let declared = result.columns[c].declaredType, !declared.isEmpty { return SQLiteAffinity(declaredType: declared).isNumeric }
            var any = false
            for row in rows where c < row.count {
                switch row[c] {
                case .integer, .real: any = true
                case .null: continue
                default: return false
                }
            }
            return any
        }
        misfit = result.columns.indices.map { c in
            guard let declared = result.columns[c].declaredType, !declared.isEmpty else { return false }
            let affinity = SQLiteAffinity(declaredType: declared)
            return rows.prefix(1_000).contains { c < $0.count && $0[c].misfits(affinity) }
        }
    }

    // MARK: TabularModel

    var columnCount: Int { result.columns.count }
    var rowCount: Int { result.rows.count }
    var shownCount: Int { order?.count ?? result.rows.count }
    func rowNumber(_ row: Int) -> Int { row + 1 }
    let layoutVersion = 0

    func title(_ column: Int) -> String { result.columns.indices.contains(column) ? result.columns[column].name : "" }
    func isNumeric(_ column: Int) -> Bool { numeric.indices.contains(column) && numeric[column] }
    func hasMisfits(_ column: Int) -> Bool { misfit.indices.contains(column) && misfit[column] }

    func value(row: Int, column: Int) -> SQLiteValue? {
        let source = order.map { row < $0.count ? $0[row] : row } ?? row
        guard result.rows.indices.contains(source), column >= 0, column < result.rows[source].count else { return nil }
        return result.rows[source][column]
    }

    func cell(row: Int, column: Int) -> DataCellValue {
        guard let value = value(row: row, column: column) else { return DataCellValue(text: "", style: .missing) }
        if value.isNull { return DataCellValue(text: value.display, style: .missing) }
        let declared = result.columns[column].declaredType ?? ""
        let wrong = !declared.isEmpty && value.misfits(SQLiteAffinity(declaredType: declared))
        return DataCellValue(text: value.display, style: wrong ? .misfit : .plain)
    }

    func sampleValues(column: Int) -> [String] {
        result.rows.prefix(50).compactMap { column < $0.count ? $0[column].display : nil }
    }

    // MARK: Sort and filter, in memory

    private(set) var arrangement = DataArrangement()
    /// Result rows in shown order; nil = the query's own order.
    private var order: [Int]?
    private var arrangeGeneration = 0

    func arrange(_ next: DataArrangement) async -> Bool {
        arrangeGeneration += 1
        let generation = arrangeGeneration
        if next.isEmpty { arrangement = next; order = nil; onChange?(); return true }
        let rows = result.rows, numeric = self.numeric
        let sorted = await Task.detached(priority: .userInitiated) { Self.order(rows, numeric: numeric, arrangement: next) }.value
        guard generation == arrangeGeneration else { return false }
        arrangement = next
        order = sorted
        onChange?()
        return true
    }

    func cancelArrange() { arrangeGeneration += 1 }

    /// Rows whose cells contain the filter (case- and accent-insensitive), sorted by one column: numbers by value,
    /// text as Finder sorts names, NULL last either way, ties in the query's order.
    nonisolated static func order(_ rows: [[SQLiteValue]], numeric: [Bool], arrangement: DataArrangement) -> [Int] {
        var kept = Array(rows.indices)
        let query = arrangement.filter
        if !query.isEmpty {
            kept = kept.filter { i in rows[i].contains { $0.display.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        }
        guard let column = arrangement.sortColumn else { return kept }
        let ascending = arrangement.ascending
        func number(_ v: SQLiteValue) -> Double? {
            switch v { case .integer(let n): Double(n); case .real(let d): d; default: nil }
        }
        return kept.sorted { a, b in
            let x = column < rows[a].count ? rows[a][column] : .null
            let y = column < rows[b].count ? rows[b][column] : .null
            if x.isNull || y.isNull { return x.isNull == y.isNull ? a < b : !x.isNull }
            if let p = number(x), let q = number(y) { return p == q ? a < b : (ascending ? p < q : p > q) }
            let r = x.display.localizedStandardCompare(y.display)
            return r == .orderedSame ? a < b : (ascending ? r == .orderedAscending : r == .orderedDescending)
        }
    }

    // MARK: Inspector

    // MARK: Header tags, chart, selection numbers (G12, D-2, I-4, I-5): a result has no shape problems to lint.

    func typeTag(_ column: Int) -> String {
        guard result.columns.indices.contains(column) else { return "Aa" }
        let declared = (result.columns[column].declaredType ?? "").uppercased()
        if declared.contains("BOOL") { return "0|1" }
        if declared.contains("DATE") || declared.contains("TIME") {
            return "date"
        }
        if isNumeric(column) {
            let whole = result.rows.prefix(200).allSatisfy { r in
                guard column < r.count else { return true }
                if case .real(let d) = r[column] { return d.rounded() == d }
                return true
            }
            return whole && !declared.contains("REAL") && !declared.contains("FLOA") && !declared.contains("DOUB") ? "123" : "1.5"
        }
        if declared.contains("BLOB") { return String(localized: "BIN", bundle: .previewKit, comment: "Column header type tag for a binary column; keep very short.") }
        return DataModel.textTag(sampleValues(column: column))
    }

    func headerTooltip(_ column: Int) -> String {
        guard result.columns.indices.contains(column) else { return "" }
        let declared = result.columns[column].declaredType ?? ""
        return [title(column), declared.isEmpty ? String(localized: "computed", bundle: .previewKit, comment: "Column header tooltip: a query result column computed by the query, with no declared type.") : declared].joined(separator: " · ")
    }

    /// The result is in memory: the chart covers every row of it.
    func columnChart(_ column: Int) -> DataColumnChart? {
        guard result.columns.indices.contains(column) else { return nil }
        var chart = DataColumnChart()
        var numbers: [Double] = []
        var counts: [String: Int] = [:]
        for r in result.rows {
            let v = column < r.count ? r[column] : .null
            if v.isNull { chart.empty += 1; continue }
            chart.valid += 1
            if let n = v.number { numbers.append(n) }
            if case .blob = v { continue }
            if counts.count < 10_000 || counts[v.display] != nil { counts[v.display, default: 0] += 1 }
        }
        if isNumeric(column), let lo = numbers.min(), let hi = numbers.max() {
            let bins = hi > lo ? 16 : 1
            var histogram = Array(repeating: 0, count: bins)
            for n in numbers { histogram[min(max(hi > lo ? Int((n - lo) / (hi - lo) * Double(bins)) : 0, 0), bins - 1)] += 1 }
            chart.histogram = histogram
            chart.low = SQLiteValue.real(lo).display
            chart.high = SQLiteValue.real(hi).display
        }
        if !isNumeric(column) || counts.values.contains(where: { $0 > 1 }) {
            chart.top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5)
                .map { DataTopValue(value: $0.key, count: $0.value) }
        }
        chart.topTotal = chart.valid
        return chart
    }

    func number(row: Int, column: Int) -> Double? { value(row: row, column: column)?.number }
    var lint: DataLint? { nil }
    func shownRow(forSource source: Int) -> Int? { order.map { $0.firstIndex(of: source) } ?? source }

    let fileTabTitle = String(localized: "Query", bundle: .previewKit, comment: "Inspector tab: facts about the SQL query that made these rows.")
    let parts: [DataPart] = []
    func selectPart(_ index: Int) {}

    /// The outcome as the capsule says it.
    var outcome: QueryOutcome {
        QueryOutcome(rows: result.rows.count, total: result.isCapped ? result.totalRows : nil, isCapped: result.isCapped,
                     milliseconds: Int((result.elapsed * 1_000).rounded()))
    }

    func fileEntries() -> [DataEntry] {
        var out: [DataEntry] = [(String(localized: "Query", bundle: .previewKit, comment: "Inspector fact label: the SQL query."), sql),
                                (String(localized: "Result", bundle: .previewKit, comment: "Inspector fact label: how many rows the query returned and how long it took."), outcome.summary),
                                (String(localized: "Source", bundle: .previewKit, comment: "Inspector fact label: the file or table the query ran on."), source),
                                (String(localized: "Access", bundle: .previewKit, comment: "Inspector fact label: whether the file can be changed."), String(localized: "Read-only · the file is never written", bundle: .previewKit, comment: "Inspector fact value: queries only read the file."))]
        if result.isCapped {
            let held = result.rows.count.formatted()
            out.append((String(localized: "Held", bundle: .previewKit, comment: "Inspector fact label: how many result rows are kept in memory."), String(localized: "The first \(held) rows; refine the query to see the rest", bundle: .previewKit, comment: "Inspector fact value: only the first rows of a large result are kept; the argument is their count.")))
        }
        return out
    }

    func columnEntries(_ column: Int) -> [DataEntry] {
        guard result.columns.indices.contains(column) else { return [] }
        var out: [DataEntry] = [(String(localized: "Type", bundle: .previewKit, comment: "Column fact label: the column's data type."), typeName(column))]
        if summaries[column] == nil { summaries[column] = summary(column) }
        if let s = summaries[column] {
            out.append((String(localized: "Values", bundle: .previewKit, comment: "Column fact label: number of non-empty values profiled."), s.nonNull.formatted()))
            out.append(("NULL", (s.rows - s.nonNull).formatted()))
            out.append((String(localized: "Distinct", bundle: .previewKit, comment: "Column fact label: number of different values."), s.distinct.formatted()))
            if !s.minimum.isNull { out.append((String(localized: "Min", bundle: .previewKit, comment: "Column fact label: the smallest value."), s.minimum.display)) }
            if !s.maximum.isNull { out.append((String(localized: "Max", bundle: .previewKit, comment: "Column fact label: the largest value."), s.maximum.display)) }
        }
        return out
    }

    var profileNote: String {
        let count = result.rows.count.formatted()
        return result.rows.count == 1
            ? String(localized: "Computed from the \(count) result row", bundle: .previewKit, comment: "Inspector note: the column profile covers the one result row.")
            : String(localized: "Computed from the \(count) result rows", bundle: .previewKit, comment: "Inspector note: the column profile covers every result row; the argument is their count.")
    }

    func rowEntries(_ row: Int) -> [DataEntry] {
        result.columns.indices.compactMap { c in value(row: row, column: c).map { (result.columns[c].name, $0.isNull ? "" : $0.display) } }
    }

    private func typeName(_ column: Int) -> String {
        if let declared = result.columns[column].declaredType, !declared.isEmpty { return declared }
        var kinds = Set<String>()
        for row in result.rows.prefix(10_000) where column < row.count {
            switch row[column] {
            case .integer: kinds.insert("Integer")
            case .real: kinds.insert("Real")
            case .text: kinds.insert("Text")
            case .blob: kinds.insert("BLOB")
            case .null: break
            }
        }
        if kinds == ["Integer", "Real"] { return String(localized: "Number", bundle: .previewKit, comment: "A result column's type: whole and decimal numbers.") }
        guard kinds.count == 1, let kind = kinds.first else {
            return kinds.isEmpty ? "NULL" : String(localized: "Mixed", bundle: .previewKit, comment: "A result column's type: values of several types.")
        }
        switch kind {
        case "Integer": return String(localized: "Integer", bundle: .previewKit, comment: "A result column's type: whole numbers.")
        case "Real": return String(localized: "Real", bundle: .previewKit, comment: "A result column's type: decimal numbers (SQLite REAL).")
        case "Text": return String(localized: "Text", bundle: .previewKit, comment: "A column's data type: text.")
        default: return kind
        }
    }

    /// Count, non-NULL, distinct, min and max over the held rows; min and max compare numbers before text, as SQLite does.
    private func summary(_ column: Int) -> Summary {
        var nonNull = 0
        var distinct = Set<String>()
        var minimum: SQLiteValue = .null, maximum: SQLiteValue = .null
        func rank(_ v: SQLiteValue) -> Int { switch v { case .null: 0; case .integer, .real: 1; case .text: 2; case .blob: 3 } }
        func less(_ a: SQLiteValue, _ b: SQLiteValue) -> Bool {
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            switch (a, b) {
            case (.integer(let x), .integer(let y)): return x < y
            case (.integer(let x), .real(let y)): return Double(x) < y
            case (.real(let x), .integer(let y)): return x < Double(y)
            case (.real(let x), .real(let y)): return x < y
            default: return a.display < b.display
            }
        }
        for row in result.rows where column < row.count {
            let v = row[column]
            guard !v.isNull else { continue }
            nonNull += 1
            distinct.insert(v.display)
            if minimum.isNull || less(v, minimum) { minimum = v }
            if maximum.isNull || less(maximum, v) { maximum = v }
        }
        return Summary(rows: result.rows.count, nonNull: nonNull, distinct: distinct.count, minimum: minimum, maximum: maximum)
    }
}
