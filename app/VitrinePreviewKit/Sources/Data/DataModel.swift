import Foundation
import VitrineData

/// What the data view draws from: the opened table, the row index once it is built in the background, rows read in
/// pages on demand (never all of them), the column types and the profile. No AppKit here, so tests read it directly.
/// roadmap: S-6
@MainActor
final class DataModel: TabularModel {
    let table: CSVTable
    /// Rows per page; the first page is the one `CSVTable.open` already parsed.
    let pageSize: Int
    private(set) var index: CSVRowIndex?
    private(set) var types: [CSVColumnTypeInfo]
    private(set) var profile: CSVProfile?
    /// Pages read so far (page 0 is the table's first page and costs no read).
    private(set) var pages: [Int: [CSVRow]] = [:]
    /// Called after the index or the profile changed, so the view can grow its row count and redraw.
    var onChange: (() -> Void)?
    /// Called once the row index is built, with it, so the pill's row count can become exact.
    var onIndexed: ((CSVRowIndex) -> Void)?

    /// `index` is the row index when the caller already built it (files up to 8 MB are counted before the first
    /// paint), so the grid shows every row from the start, matching the pill.
    init(table: CSVTable, index: CSVRowIndex? = nil) {
        self.table = table
        self.index = index
        pageSize = max(1, CSVOptions().firstPageRows)
        types = table.inferColumnTypes(sample: table.firstPage.rows)
        pages[0] = table.firstPage.rows
    }

    var columnCount: Int { table.columnCount }
    var rowCount: Int { table.rowCount(index: index).known }
    func title(_ column: Int) -> String { table.columnTitle(column) }
    let layoutVersion = 0
    let fileTabTitle = String(localized: "File", bundle: .previewKit, comment: "Inspector tab: facts about the whole file.")
    let parts: [DataPart] = []
    func selectPart(_ index: Int) {}

    func cell(row: Int, column: Int) -> DataCellValue {
        let value = self.row(source(row))?[column] ?? ""
        return DataCellValue(text: value, style: misfits(value, column: column) ? .misfit : .plain)
    }

    // MARK: Filter and sort

    private(set) var arrangement = DataArrangement()
    /// Source rows in shown order; nil = every row in file order.
    private(set) var order: [Int]?
    private var arrangeFlag: CancelFlag?
    private var arrangeGeneration = 0

    var shownCount: Int { order?.count ?? rowCount }
    func source(_ row: Int) -> Int { order.map { row < $0.count ? $0[row] : row } ?? row }
    func rowNumber(_ row: Int) -> Int { source(row) + 1 }

    func arrange(_ next: DataArrangement) async -> Bool {
        cancelArrange()
        arrangeGeneration += 1
        let generation = arrangeGeneration
        if next.isEmpty {
            arrangement = next; order = nil; onChange?(); return true
        }
        // A whole-file pass needs the row index; files up to 8 MB have it before the first paint.
        await waitForIndex()
        guard generation == arrangeGeneration else { return false }
        let flag = CancelFlag()
        arrangeFlag = flag
        let table = self.table, index = self.index, types = self.types
        let result = await Task.detached(priority: .userInitiated) {
            DataModel.order(table: table, index: index, types: types, arrangement: next, flag: flag)
        }.value
        guard generation == arrangeGeneration, !flag.isCancelled, let result else { return false }
        arrangement = next
        order = result
        onChange?()
        return true
    }

    /// Stops a running arrangement, and one still waiting to start (the generation moves on, so it returns false).
    func cancelArrange() { arrangeGeneration += 1; arrangeFlag?.cancel(); arrangeFlag = nil }

    /// One pass over every row, 4,096 at a time: keep the rows whose cells contain the filter (case- and
    /// accent-insensitive), then sort them by one column (numbers as numbers in a numbers column, otherwise as Finder
    /// sorts names; empty cells last either way; ties in file order). nil when cancelled or the file cannot be read.
    nonisolated static func order(table: CSVTable, index: CSVRowIndex?, types: [CSVColumnTypeInfo],
                                  arrangement: DataArrangement, flag: CancelFlag) -> [Int]? {
        let query = arrangement.filter
        let column = arrangement.sortColumn
        let info = column.flatMap { $0 < types.count ? types[$0] : nil }
        var kept: [Int] = []
        var numbers: [Double?] = []
        var texts: [String] = []
        var start = 0
        let step = 4_096
        while true {
            if flag.isCancelled { return nil }
            guard let rows = try? table.rows(in: start..<(start + step), index: index) else { return nil }
            for (k, row) in rows.enumerated() {
                if !query.isEmpty, !row.fields.contains(where: { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                    continue
                }
                kept.append(start + k)
                if let column {
                    let value = row[column]
                    if let info, info.type == .integer || info.type == .decimal { numbers.append(info.number(value)) } else { texts.append(value) }
                }
            }
            if rows.count < step { break }
            start += step
        }
        guard column != nil else { return kept }
        if flag.isCancelled { return nil }
        let ascending = arrangement.ascending
        var positions = Array(kept.indices)
        if !numbers.isEmpty {
            positions.sort { a, b in
                switch (numbers[a], numbers[b]) {
                case let (x?, y?): return x == y ? a < b : (ascending ? x < y : x > y)
                case (nil, nil): return a < b
                case (nil, _): return false
                case (_, nil): return true
                }
            }
        } else if !texts.isEmpty {
            positions.sort { a, b in
                let x = texts[a], y = texts[b]
                if x.isEmpty || y.isEmpty { return x.isEmpty == y.isEmpty ? a < b : !x.isEmpty }
                let r = x.localizedStandardCompare(y)
                return r == .orderedSame ? a < b : (ascending ? r == .orderedAscending : r == .orderedDescending)
            }
        }
        return positions.map { kept[$0] }
    }

    func sampleValues(column: Int) -> [String] { table.firstPage.rows.prefix(50).map { $0[column] } }

    func type(_ column: Int) -> CSVColumnTypeInfo? { column < types.count ? types[column] : nil }
    func isNumeric(_ column: Int) -> Bool { type(column).map { $0.type == .integer || $0.type == .decimal } ?? false }
    /// True when some sampled values do not fit the column's type (the header's quality line turns caution).
    func hasMisfits(_ column: Int) -> Bool { (type(column)?.misfitCount ?? 0) > 0 }
    func misfits(_ value: String, column: Int) -> Bool {
        guard let info = type(column), info.type != .text, info.type != .empty,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !info.accepts(value)
    }

    /// Row `row`, reading its page when it is not loaded yet. nil past the end of what can be read.
    func row(_ row: Int) -> CSVRow? {
        let page = row / pageSize, offset = row % pageSize
        if let rows = pages[page] { return offset < rows.count ? rows[offset] : nil }
        let start = page * pageSize
        guard let rows = try? table.rows(in: start..<(start + pageSize), index: index) else { return nil }
        pages[page] = rows
        return offset < rows.count ? rows[offset] : nil
    }

    // MARK: Background work

    // Tasks are Sendable; they are only cancelled from deinit, after the last main-actor use.
    nonisolated(unsafe) private var work: Task<Void, Never>?
    nonisolated(unsafe) private var job: Task<(CSVRowIndex, CSVProfile?)?, Never>?

    deinit { job?.cancel(); work?.cancel() }

    /// Builds the row index off the main thread, then profiles a sample spread over the file. The first screen is
    /// already painted from the first page by then.
    func start() {
        guard work == nil else { return }
        if table.firstPage.reachesEndOfFile { profile = try? table.profile(index: nil); return }
        let table = self.table, built = self.index
        let job = Task.detached(priority: .userInitiated) { () -> (CSVRowIndex, CSVProfile?)? in
            var index = built
            if index == nil { index = try? await table.buildIndex() }
            guard let index else { return nil }
            return (index, try? table.profile(index: index))
        }
        self.job = job
        work = Task { [weak self] in
            let built = await job.value
            guard let self, let built else { return }
            let (index, profile) = built
            self.index = index
            self.profile = profile
            if let profile { self.types = profile.columns.map(\.typeInfo) }
            self.onChange?()
            self.onIndexed?(index)
        }
    }

    /// Waits for the background index and profile (tests).
    func waitForIndex() async { await work?.value }

    func cancel() { job?.cancel(); work?.cancel() }

    // MARK: Inspector content

    typealias Entry = DataEntry

    /// File: the same facts the pill's tooltip lists.
    func fileEntries() -> [Entry] {
        var out = table.facts(index: index).entries().map { ($0.label, $0.value) }
        if let lint {
            // The File tab explains the banner (I-6): which rows, by their row number.
            out.append((String(localized: "Wrong field count", bundle: .previewKit, comment: "Inspector fact label: the row numbers of rows with the wrong number of fields."), lint.rows.prefix(5).map { ($0 + 1).formatted() }.joined(separator: " · ")
                        + (lint.rows.count > 5 ? " …" : "")))
        }
        return out
    }

    /// Column: its type and what the profile knows (from the first page until the index is built).
    func columnEntries(_ column: Int) -> [Entry] {
        let p = columnProfile(column)
        var out: [Entry] = [(String(localized: "Type", bundle: .previewKit, comment: "Column fact label: the column's data type."), p?.typeInfo.type.displayName ?? type(column)?.type.displayName
                              ?? String(localized: "Text", bundle: .previewKit, comment: "A column's data type: text."))]
        guard let p else { return out }
        out.append((String(localized: "Values", bundle: .previewKit, comment: "Column fact label: number of non-empty values profiled."), p.nonEmpty.formatted()))
        out.append((String(localized: "Empty", bundle: .previewKit, comment: "Column fact label: number of empty values profiled."), p.empty.formatted()))
        out.append((String(localized: "Distinct", bundle: .previewKit, comment: "Column fact label: number of different values."), p.distinctIsCapped
                     ? String(localized: "≥ \(p.distinct.formatted())", bundle: .previewKit, comment: "At least this many (a capped count); the argument is a formatted number.") : p.distinct.formatted()))
        if p.typeInfo.misfitCount > 0 { out.append((String(localized: "Don't fit", bundle: .previewKit, comment: "Column fact label: number of values that do not fit the column's type."), p.typeInfo.misfitCount.formatted())) }
        if let n = p.numbers {
            out.append((String(localized: "Min", bundle: .previewKit, comment: "Column fact label: the smallest value."), Self.number(n.min)))
            out.append((String(localized: "Max", bundle: .previewKit, comment: "Column fact label: the largest value."), Self.number(n.max)))
            out.append((String(localized: "Mean", bundle: .previewKit, comment: "Column fact label: the average value."), Self.number(n.mean)))
            if let d = p.distribution { out.append((String(localized: "Median", bundle: .previewKit, comment: "Column fact label: the middle value."), Self.number(d.median))) }
        }
        if let d = p.dates {
            out.append((String(localized: "Earliest", bundle: .previewKit, comment: "Column fact label: the earliest date."), d.earliest.formatted(date: .abbreviated, time: .omitted)))
            out.append((String(localized: "Latest", bundle: .previewKit, comment: "Column fact label: the latest date."), d.latest.formatted(date: .abbreviated, time: .omitted)))
        }
        return out
    }

    // MARK: Header tags, chart, selection numbers, lint (G12, D-2, I-4, I-5, I-6)

    func typeTag(_ column: Int) -> String {
        switch type(column)?.type {
        case .integer?: return "123"
        case .decimal?: return "1.5"
        case .boolean?: return "0|1"
        case .date?, .dateTime?: return "date"
        case .empty?: return "–"
        default: return Self.textTag(sampleValues(column: column) + table.firstPage.rows.dropFirst(50).prefix(150).map { $0[column] })
        }
    }

    /// Text columns: "@" when nearly every value is an email address, "≡" when a few values repeat (a category).
    static func textTag(_ values: [String]) -> String {
        let sample = values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !sample.isEmpty else { return "Aa" }
        let emails = sample.filter { $0.contains("@") && $0.contains(".") && !$0.contains(" ") }.count
        if emails * 10 >= sample.count * 9 { return "@" }
        if sample.count >= 20, Set(sample).count <= max(2, min(12, sample.count / 5)) { return "≡" }
        return "Aa"
    }

    func headerTooltip(_ column: Int) -> String {
        guard let info = type(column) else { return title(column) }
        var parts = [title(column), info.type.displayName]
        if info.misfitCount > 0 {
            let misfits = info.misfitCount.formatted(), sampled = info.nonEmpty.formatted()
            parts.append(String(localized: "\(misfits) of \(sampled) sampled values don't fit", bundle: .previewKit, comment: "Column header tooltip: how many sampled values do not fit the column's type."))
        }
        return parts.joined(separator: " · ")
    }

    func columnChart(_ column: Int) -> DataColumnChart? {
        guard let p = columnProfile(column) else { return nil }
        var chart = DataColumnChart()
        let info = p.typeInfo
        if let d = p.distribution, let n = p.numbers {
            chart.histogram = d.histogram
            chart.low = Self.number(n.min)
            chart.high = Self.number(n.max)
        }
        chart.valid = info.fitCount
        chart.misfit = info.misfitCount
        chart.empty = p.empty
        chart.misfitKind = info.type == .integer || info.type == .decimal ? .notNumbers
            : (info.type == .date || info.type == .dateTime ? .notDates : .other)
        if !p.misfitExamples.isEmpty {
            let quoted = p.misfitExamples.map { "“\($0)”" }.joined(separator: ", ")
            chart.note = chart.misfitKind.note(count: info.misfitCount, inSample: profile?.isSample == true, examples: quoted)
        }
        chart.top = p.topValues.map { DataTopValue(value: $0.value, count: $0.count) }
        chart.topTotal = p.nonEmpty
        return chart
    }

    func number(row: Int, column: Int) -> Double? {
        guard let info = type(column), let value = self.row(source(row))?[column] else { return nil }
        return info.number(value)
    }

    /// Rows whose field count differs from the header's, from the row index (the first few are kept by row number).
    var lint: DataLint? {
        guard let index, index.raggedRows > 0 else { return nil }
        let expected = columnCount
        let counts = Set(index.raggedRowSamples.compactMap { r in (try? table.rows(in: r..<(r + 1), index: index))?.first?.fields.count })
        let total = index.rowCount.known
        let n = index.raggedRows
        let bad = n.formatted(), all = total.formatted(), want = expected.formatted()
        let message: String
        if counts.count == 1, let got = counts.first, got != expected {
            let fields = got.formatted()
            message = n == 1
                ? String(localized: "\(bad) of \(all) rows has \(fields) fields instead of \(want).", bundle: .previewKit, comment: "Banner: one row has a different number of fields than the header. Arguments: bad rows, all rows, fields found, fields expected.")
                : String(localized: "\(bad) of \(all) rows have \(fields) fields instead of \(want).", bundle: .previewKit, comment: "Banner: some rows have a different number of fields than the header. Arguments: bad rows, all rows, fields found, fields expected.")
        } else {
            message = n == 1
                ? String(localized: "\(bad) of \(all) rows has the wrong number of fields (expected \(want)).", bundle: .previewKit, comment: "Banner: one row has the wrong number of fields. Arguments: bad rows, all rows, fields expected.")
                : String(localized: "\(bad) of \(all) rows have the wrong number of fields (expected \(want)).", bundle: .previewKit, comment: "Banner: some rows have the wrong number of fields. Arguments: bad rows, all rows, fields expected.")
        }
        return DataLint(message: message, rows: index.raggedRowSamples)
    }

    func shownRow(forSource source: Int) -> Int? {
        guard let order else { return source < rowCount ? source : nil }
        return order.firstIndex(of: source)
    }

    func columnProfile(_ column: Int) -> CSVColumnProfile? {
        if profile == nil { profile = try? table.profile(index: index) }
        guard let profile, column >= 0, column < profile.columns.count else { return nil }
        return profile.columns[column]
    }

    /// Footnote under the column profile: how many rows it was computed from.
    var profileNote: String {
        guard let profile else { return "" }
        let rows = profile.sampledRows.formatted()
        return profile.isSample
            ? String(localized: "Profiled a sample of \(rows) rows", bundle: .previewKit, comment: "Inspector note: the column profile covers a sample of rows; the argument is their count.")
            : String(localized: "Profiled all \(rows) rows", bundle: .previewKit, comment: "Inspector note: the column profile covers every row; the argument is their count.")
    }

    /// Row: each field as column title and value.
    func rowEntries(_ row: Int) -> [Entry] {
        guard let r = self.row(source(row)) else { return [] }
        return (0..<max(columnCount, r.fields.count)).map { (title($0), r[$0]) }
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? Int(value).formatted() : value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
