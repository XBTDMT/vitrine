import Foundation
import VitrineData
import VitrineDocument
import VitrineSupport

/// A Parquet, Arrow / Feather or xlsx file in the data grid and Inspector (B-4, G-20; data design "Parquet / Arrow,
/// footer first"). Rows are read in windows of `windowSize` from the reader, the first before the first paint and
/// the rest in the background as they scroll into view (a cell shows a dim "…" until its window is in); at most
/// `keptWindows` stay in memory. Filter and sort read every row once off the main thread, cancellably. A workbook's
/// sheets are its parts, picked on the File tab like SQLite's tables. roadmap: S-21
@MainActor
final class ColumnarDataModel: TabularModel {
    let url: URL
    let dataset: any ColumnarDataset
    let fileSize: Int64
    private(set) var table: (any ColumnarTable)?
    private(set) var selected = 0
    /// Why the picked part could not be opened (a chart sheet), shown in the banner.
    private(set) var openError: String?
    private(set) var layoutVersion = 0
    static let windowSize = 1_000
    static let keptWindows = 32
    static let profileRows = 10_000
    private var windows: [Int: ColumnarWindow] = [:]
    private var recent: [Int] = []
    private var loading: Set<Int> = []
    private var readError: String?
    private var sample: ColumnarWindow?
    private var charts: [Int: DataColumnChart] = [:]

    var onChange: (() -> Void)?
    /// Called when what the pill says changed (another sheet picked).
    var onDocumentChange: (() -> Void)?

    init(url: URL) throws {
        self.url = url
        dataset = try ColumnarOpener.open(url)
        fileSize = Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let first = dataset.parts.firstIndex { $0.note == nil } ?? 0
        open(part: first)
    }

    private func open(part: Int) {
        selected = part
        windows = [:]; recent = []; loading = []; sample = nil; charts = [:]; readError = nil; copied = [:]
        order = nil; arrangement = DataArrangement()
        do {
            let t = try dataset.table(part)
            table = t
            openError = nil
            // The first window before the first paint: the grid never opens on placeholders.
            if t.rowCount > 0, let w = try? t.read(rows: 0..<min(t.rowCount, Self.windowSize)) { store(w, index: 0) }
        } catch {
            table = nil
            openError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        layoutVersion += 1
    }

    var format: ColumnarFormat { dataset.format }
    var columns: [ColumnarColumn] { table?.columns ?? [] }

    // MARK: Rows

    var columnCount: Int { columns.count }
    var rowCount: Int { table?.rowCount ?? 0 }

    private func store(_ window: ColumnarWindow, index: Int) {
        windows[index] = window
        recent.removeAll { $0 == index }
        recent.append(index)
        while recent.count > Self.keptWindows { windows[recent.removeFirst()] = nil }
    }

    /// The window holding source row `row`, starting a background read when it is not in yet.
    private func window(for row: Int) -> (ColumnarWindow, Int)? {
        let index = row / Self.windowSize
        if let w = windows[index] {
            if recent.last != index { recent.removeAll { $0 == index }; recent.append(index) }
            return (w, row - w.start)
        }
        load(index)
        return nil
    }

    private func load(_ index: Int) {
        guard let table, !loading.contains(index) else { return }
        loading.insert(index)
        let start = index * Self.windowSize
        let range = start..<min(table.rowCount, start + Self.windowSize)
        let layout = layoutVersion
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ColumnarWindow, Error> in
                Result { try table.read(rows: range) }
            }.value
            guard let self, self.layoutVersion == layout else { return }
            self.loading.remove(index)
            switch result {
            case .success(let w): self.store(w, index: index)
            case .failure(let error): self.readError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            self.onChange?()
        }
    }

    /// Waits until every window being read is in (tests).
    func waitForWindows() async {
        for _ in 0..<2_500 where !loading.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    /// Rows read for Copy as, by source row: only the rows copied are kept, however many windows they span.
    private var copied: [Int: [ColumnarCell]] = [:]

    /// Reads, now, the shown rows `rows` (Copy as, at most `DataView.copyLimit` rows), a window at a time.
    func prepare(shownRows rows: [Int]) {
        guard let table else { return }
        copied = [:]
        let wanted = Dictionary(grouping: rows.map(source), by: { $0 / Self.windowSize })
        for (index, sources) in wanted {
            let start = index * Self.windowSize
            let w = windows[index] ?? (try? table.read(rows: start..<min(table.rowCount, start + Self.windowSize)))
            guard let w else { continue }
            for r in sources where r - w.start < w.count { copied[r] = w.columns.map { $0[r - w.start] } }
        }
    }

    func value(source row: Int, column: Int) -> ColumnarCell? {
        if let cells = copied[row], column < cells.count { return cells[column] }
        guard column >= 0, column < columnCount, row >= 0, row < rowCount, let (w, offset) = window(for: row),
              column < w.columns.count else { return nil }
        return w.columns[column][offset]
    }

    func source(_ row: Int) -> Int { order.map { row < $0.count ? $0[row] : row } ?? row }

    func cell(row: Int, column: Int) -> DataCellValue {
        guard column < columnCount else { return DataCellValue(text: "", style: .missing) }
        let c = columns[column]
        if c.isOmitted { return DataCellValue(text: String(localized: "not shown", bundle: .previewKit, comment: "Grid cell placeholder: this column's values are not read (an unsupported type)."), style: .missing) }
        guard let value = value(source: source(row), column: column) else { return DataCellValue(text: "…", style: .missing) }
        if value.isNull { return DataCellValue(text: "", style: .missing) }
        return DataCellValue(text: ColumnarText.text(value, kind: c.kind))
    }

    func rowNumber(_ row: Int) -> Int { source(row) + (table?.firstRowNumber ?? 1) }

    func title(_ column: Int) -> String { column < columnCount ? columns[column].name : "" }
    func isNumeric(_ column: Int) -> Bool { column < columnCount && columns[column].kind.isNumeric }
    func hasMisfits(_ column: Int) -> Bool { false }

    func sampleValues(column: Int) -> [String] {
        guard column < columnCount, let w = windows[0] else { return [] }
        return (0..<min(50, w.count)).map { ColumnarText.text(w.columns[column][$0], kind: columns[column].kind) }
    }

    func number(row: Int, column: Int) -> Double? {
        guard column < columnCount, let v = value(source: source(row), column: column) else { return nil }
        return ColumnarText.number(v, kind: columns[column].kind)
    }

    func typeTag(_ column: Int) -> String {
        guard column < columnCount else { return "Aa" }
        switch columns[column].kind {
        case .integer, .duration: return "123"
        case .float, .decimal: return "1.5"
        case .boolean: return "0|1"
        case .date, .dateMillis, .time, .timestamp: return "date"
        case .binary: return String(localized: "BIN", bundle: .previewKit, comment: "Column header type tag for a binary column; keep very short.")
        case .null: return "–"
        case .string: return DataModel.textTag(sampleValues(column: column))
        default: return "Aa"
        }
    }

    func headerTooltip(_ column: Int) -> String {
        guard column < columnCount else { return "" }
        let c = columns[column]
        return ([c.name, c.typeDescription] + (c.note.map { [$0] } ?? [])).joined(separator: " · ")
    }

    // MARK: Filter and sort

    private(set) var arrangement = DataArrangement()
    private var order: [Int]?
    private var arrangeGeneration = 0
    private var arrangeFlag: CancelFlag?

    var shownCount: Int { order?.count ?? rowCount }

    func arrange(_ next: DataArrangement) async -> Bool {
        cancelArrange()
        arrangeGeneration += 1
        let generation = arrangeGeneration
        if next.isEmpty { arrangement = next; order = nil; onChange?(); return true }
        guard let table else { return false }
        let flag = CancelFlag()
        arrangeFlag = flag
        let result = await Task.detached(priority: .userInitiated) {
            ColumnarDataModel.order(table: table, arrangement: next, flag: flag)
        }.value
        guard generation == arrangeGeneration, !flag.isCancelled, let result else { return false }
        arrangement = next
        order = result
        onChange?()
        return true
    }

    func cancelArrange() { arrangeGeneration += 1; arrangeFlag?.cancel(); arrangeFlag = nil }

    /// One pass over every row, 4,096 at a time: rows whose shown text contains the filter (case- and
    /// accent-insensitive), sorted by one column (numbers by value, text as Finder sorts names, empty last, ties in
    /// file order). nil when cancelled or a read fails.
    nonisolated static func order(table: any ColumnarTable, arrangement: DataArrangement, flag: CancelFlag) -> [Int]? {
        let columns = table.columns
        let query = arrangement.filter
        let sortColumn = arrangement.sortColumn.flatMap { $0 < columns.count ? $0 : nil }
        let numeric = sortColumn.map { columns[$0].kind.isNumeric || columns[$0].kind.isTemporal || columns[$0].kind == .boolean } ?? false
        var kept: [Int] = []
        var numbers: [Double?] = []
        var texts: [String] = []
        var start = 0
        while start < table.rowCount {
            if flag.isCancelled { return nil }
            guard let w = try? table.read(rows: start..<(start + 4_096), isCancelled: { flag.isCancelled }), w.count > 0 else { return nil }
            for r in 0..<w.count {
                if !query.isEmpty {
                    let hit = columns.indices.contains { c in
                        let v = w.columns[c][r]
                        return !v.isNull && ColumnarText.text(v, kind: columns[c].kind)
                            .range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    }
                    if !hit { continue }
                }
                kept.append(start + r)
                if let c = sortColumn {
                    let v = w.columns[c][r]
                    if numeric {
                        switch v {
                        case .int(let n) where !columns[c].kind.isNumeric: numbers.append(Double(n))
                        default: numbers.append(v.isNull ? nil : ColumnarText.number(v, kind: columns[c].kind))
                        }
                    } else {
                        texts.append(v.isNull ? "" : ColumnarText.text(v, kind: columns[c].kind))
                    }
                }
            }
            start += w.count
        }
        guard sortColumn != nil else { return kept }
        if flag.isCancelled { return nil }
        let ascending = arrangement.ascending
        var positions = Array(kept.indices)
        if numeric {
            positions.sort { a, b in
                switch (numbers[a], numbers[b]) {
                case let (x?, y?): return x == y ? a < b : (ascending ? x < y : x > y)
                case (nil, nil): return a < b
                case (nil, _): return false
                case (_, nil): return true
                }
            }
        } else {
            positions.sort { a, b in
                let x = texts[a], y = texts[b]
                if x.isEmpty || y.isEmpty { return x.isEmpty == y.isEmpty ? a < b : !x.isEmpty }
                let r = x.localizedStandardCompare(y)
                return r == .orderedSame ? a < b : (ascending ? r == .orderedAscending : r == .orderedDescending)
            }
        }
        return positions.map { kept[$0] }
    }

    func shownRow(forSource source: Int) -> Int? {
        guard let order else { return source < rowCount ? source : nil }
        return order.firstIndex(of: source)
    }

    // MARK: Problems

    var lint: DataLint? {
        if let openError { return DataLint(message: openError, rows: []) }
        var problems = table?.warnings ?? []
        if let readError { problems.insert(readError, at: 0) }
        guard let first = problems.first else { return nil }
        let more = problems.count - 1
        let message: String
        switch more {
        case 0: message = first
        case 1: message = String(localized: "\(first) (and 1 more problem)", bundle: .previewKit, comment: "A read problem, then a count of further problems. The argument is the first problem's text.")
        default: message = String(localized: "\(first) (and \(more.formatted()) more problems)", bundle: .previewKit, comment: "A read problem, then the number of further problems (2 or more).")
        }
        return DataLint(message: message, rows: [])
    }

    // MARK: Parts (a workbook's sheets)

    var parts: [DataPart] {
        guard format == .xlsx else { return [] }
        return dataset.parts.enumerated().map { i, p in
            let detail: String
            if i == selected, let table { detail = table.rowCount.formatted() }
            else if let note = p.note { detail = note }
            else if let rows = p.rows { detail = p.rowsAreEstimate ? String(localized: "≈ \(rows.formatted())", bundle: .previewKit, comment: "An estimated row count; the argument is a formatted number.") : rows.formatted() }
            else { detail = "" }
            return DataPart(name: p.name, detail: detail, isSelected: i == selected)
        }
    }

    var partsHeading: String { String(localized: "Sheets", bundle: .previewKit, comment: "Inspector heading over the list of a workbook's sheets.") }

    func selectPart(_ index: Int) {
        guard index != selected, dataset.parts.indices.contains(index) else { return }
        cancelArrange()
        open(part: index)
        onChange?()
        onDocumentChange?()
        start()
    }

    var fileTabTitle: String {
        format == .xlsx ? String(localized: "Workbook", bundle: .previewKit, comment: "Inspector tab: facts about the whole workbook.")
            : String(localized: "File", bundle: .previewKit, comment: "Inspector tab: facts about the whole file.")
    }
    var opensInspector: Bool { true }

    var fileCaption: String? {
        switch format {
        case .parquet: return String(localized: "From the footer: no data pages read for these", bundle: .previewKit, comment: "Inspector caption under a Parquet file's facts.")
        case .arrowFile, .arrowStream, .feather: return String(localized: "From the schema and batch headers", bundle: .previewKit, comment: "Inspector caption under an Arrow file's facts.")
        case .xlsx: return nil
        }
    }

    func fileEntries() -> [DataEntry] { keyedFileEntries().map { ($0.label, $0.value) } }

    /// The File tab's facts with a stable key each: the sheet, rows and columns by fixed keys (not their translated
    /// labels), the readers' facts by the stable key each reader gives them.
    private func keyedFileEntries() -> [Fact] {
        func keyed(_ facts: [ColumnarFact]) -> [Fact] { facts.map { Fact(key: $0.key, label: $0.label, value: $0.value) } }
        var out = keyed(dataset.facts)
        if format == .xlsx, let table {
            out.insert(Fact(key: "sheet", label: String(localized: "Sheet", bundle: .previewKit, comment: "Fact label: the workbook sheet shown."), value: dataset.parts[selected].name), at: 0)
            out.insert(Fact(key: "rows", label: String(localized: "Rows", bundle: .previewKit, comment: "Fact label: number of rows."), value: table.rowCount.formatted()), at: 1)
            out.insert(Fact(key: "columns", label: String(localized: "Columns", bundle: .previewKit, comment: "Fact label: number of columns."), value: table.columns.count.formatted()), at: 2)
            out += keyed(table.facts)
        }
        out.append(Fact(key: "size", label: Self.sizeLabel, value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)))
        return out
    }

    // MARK: Row groups and footer ranges (A-7)

    /// The strip's title over the row groups or record batches; the argument is their formatted count.
    private func chunkStripTitle(_ count: String) -> String {
        format == .parquet
            ? String(localized: "Row groups · \(count)", bundle: .previewKit, comment: "Inspector strip title over a Parquet file's row groups; the argument is their count.")
            : String(localized: "Record batches · \(count)", bundle: .previewKit, comment: "Inspector strip title over an Arrow file's record batches; the argument is their count.")
    }

    /// The strip's caption for the row group or batch on screen.
    private func chunkCaption(number: String, rows: String) -> String {
        format == .parquet
            ? String(localized: "Showing group \(number) · \(rows) rows", bundle: .previewKit, comment: "Caption: which Parquet row group is on screen (its number) and how many rows it holds.")
            : String(localized: "Showing batch \(number) · \(rows) rows", bundle: .previewKit, comment: "Caption: which Arrow record batch is on screen (its number) and how many rows it holds.")
    }

    private var startsCache: (layout: Int, starts: [Int])?

    /// The first row of each row group or batch (kept per opened part: the strip asks on every scroll).
    private var chunkStarts: [Int] {
        if let cache = startsCache, cache.layout == layoutVersion { return cache.starts }
        var starts: [Int] = [], total = 0
        for c in table?.chunks ?? [] { starts.append(total); total += c.rows }
        startsCache = (layoutVersion, starts)
        return starts
    }

    func chunk(ofShownRow row: Int) -> Int? {
        guard format != .xlsx, let chunks = table?.chunks, !chunks.isEmpty else { return nil }
        let source = self.source(max(0, min(row, max(shownCount - 1, 0))))
        let starts = chunkStarts
        var lo = 0, hi = starts.count
        while lo < hi { let mid = (lo + hi) / 2; if starts[mid] <= source { lo = mid + 1 } else { hi = mid } }
        return max(0, lo - 1)
    }

    func firstShownRow(ofChunk chunk: Int) -> Int? {
        let starts = chunkStarts
        guard starts.indices.contains(chunk) else { return nil }
        return shownRow(forSource: starts[chunk]) ?? order?.firstIndex { $0 >= starts[chunk] }
    }

    func fileSections(visibleRow: Int) -> [DataFileSection] {
        guard format != .xlsx, let table else { return [] }
        var out: [DataFileSection] = []
        let chunks = table.chunks
        if !chunks.isEmpty {
            let k = chunk(ofShownRow: visibleRow) ?? 0
            var caption = chunkCaption(number: (k + 1).formatted(), rows: chunks[k].rows.formatted())
            if let bytes = chunks[k].bytes, bytes > 0 { caption += " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            out.append(.strip(title: chunkStripTitle(chunks.count.formatted()), count: chunks.count, selected: k, caption: caption))
        }
        let ranges = table.columns.compactMap { c -> DataSectionEntry? in
            guard let s = c.statistics, var low = s.min, var high = s.max else { return nil }
            // Timestamps by their dates, so the range fits the Inspector (the Column tab has the full values).
            if case .timestamp = c.kind, let a = low.split(separator: " ").first, let b = high.split(separator: " ").first {
                low = String(a); high = String(b)
            }
            return DataSectionEntry(label: c.name, value: low == high ? low : "\(low) → \(high)")
        }
        if !ranges.isEmpty { out.append(.entries(title: String(localized: "Columns · min → max", bundle: .previewKit, comment: "Inspector section title: each column's smallest and largest value from the file footer."), entries: ranges)) }
        return out
    }

    // MARK: Column profile (from the first rows; ranges and nulls from the footer when it has them)

    func start() {
        guard sample == nil, let table, table.rowCount > 0 else { return }
        let layout = layoutVersion
        let n = min(table.rowCount, Self.profileRows)
        Task { [weak self] in
            let w = await Task.detached(priority: .utility) { try? table.read(rows: 0..<n) }.value
            guard let self, self.layoutVersion == layout, let w else { return }
            self.sample = w
            self.charts = [:]
            self.onChange?()
        }
    }

    /// Waits for the profile sample (tests).
    func waitForSample() async {
        for _ in 0..<2_000 where sample == nil && rowCount > 0 { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    private var profileWindow: ColumnarWindow? { sample ?? windows[0] }

    func columnChart(_ column: Int) -> DataColumnChart? {
        guard column < columnCount, let w = profileWindow, !columns[column].isOmitted else { return nil }
        if let chart = charts[column] { return chart }
        let kind = columns[column].kind
        var chart = DataColumnChart()
        var numbers: [Double] = []
        var counts: [String: Int] = [:]
        for r in 0..<w.count {
            let v = w.columns[column][r]
            if v.isNull { chart.empty += 1; continue }
            chart.valid += 1
            if kind.isNumeric, let n = ColumnarText.number(v, kind: kind) { numbers.append(n) }
            if case .bytes = v { continue }
            let text = ColumnarText.text(v, kind: kind)
            if counts.count < 10_000 || counts[text] != nil { counts[text, default: 0] += 1 }
        }
        if let lo = numbers.min(), let hi = numbers.max(), (hi - lo).isFinite {
            let bins = hi > lo ? 16 : 1
            var histogram = Array(repeating: 0, count: bins)
            for n in numbers { histogram[min(max(hi > lo ? Int((n - lo) / (hi - lo) * Double(bins)) : 0, 0), bins - 1)] += 1 }
            chart.histogram = histogram
            chart.low = ColumnarText.double(lo)
            chart.high = ColumnarText.double(hi)
        }
        if !kind.isNumeric || counts.values.contains(where: { $0 > 1 }) {
            chart.top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5)
                .map { DataTopValue(value: $0.key, count: $0.value) }
        }
        chart.topTotal = chart.valid
        charts[column] = chart
        return chart
    }

    func columnEntries(_ column: Int) -> [DataEntry] {
        guard column < columnCount else { return [] }
        let c = columns[column]
        var out: [DataEntry] = [(String(localized: "Type", bundle: .previewKit, comment: "Column fact label: the column's data type."), c.typeDescription)]
        if let note = c.note { out.append((String(localized: "Note", bundle: .previewKit, comment: "Column fact label: a note about the column."), note)) }
        if let chart = columnChart(column) {
            out.append((String(localized: "Values", bundle: .previewKit, comment: "Column fact label: number of non-empty values profiled."), chart.valid.formatted()))
            out.append((String(localized: "Empty", bundle: .previewKit, comment: "Column fact label: number of empty values profiled."), chart.empty.formatted()))
        }
        if let s = c.statistics {
            if let n = s.nullCount { out.append((String(localized: "Nulls in file", bundle: .previewKit, comment: "Column fact label: null count recorded in the file's metadata."), n.formatted())) }
            if let d = s.distinctCount { out.append((String(localized: "Distinct in file", bundle: .previewKit, comment: "Column fact label: distinct-value count recorded in the file's metadata."), d.formatted())) }
            if let low = s.min { out.append((Self.minLabel, low)) }
            if let high = s.max { out.append((Self.maxLabel, high)) }
        } else if let w = profileWindow, c.kind.isNumeric || c.kind.isTemporal {
            let values = (0..<w.count).map { w.columns[column][$0] }.filter { !$0.isNull }
            let keyed = values.compactMap { v -> (Double, ColumnarCell)? in
                if case .int(let n) = v { return (Double(n), v) }
                return ColumnarText.number(v, kind: c.kind).map { ($0, v) }
            }
            if let low = keyed.min(by: { $0.0 < $1.0 }), let high = keyed.max(by: { $0.0 < $1.0 }) {
                out.append((Self.minLabel, ColumnarText.text(low.1, kind: c.kind)))
                out.append((Self.maxLabel, ColumnarText.text(high.1, kind: c.kind)))
            }
        }
        return out
    }

    var profileNote: String {
        guard let w = profileWindow else { return "" }
        let count = w.count.formatted()
        switch (w.count < rowCount, format == .parquet) {
        case (true, false): return String(localized: "Profiled the first \(count) rows", bundle: .previewKit, comment: "Inspector note: the column profile covers the first rows only; the argument is their count.")
        case (false, false): return String(localized: "Profiled all \(count) rows", bundle: .previewKit, comment: "Inspector note: the column profile covers every row; the argument is their count.")
        case (true, true): return String(localized: "Profiled the first \(count) rows; min, max and nulls in file from the footer", bundle: .previewKit, comment: "Inspector note for Parquet: profile of the first rows, file-wide figures from the footer.")
        case (false, true): return String(localized: "Profiled all \(count) rows; min, max and nulls in file from the footer", bundle: .previewKit, comment: "Inspector note for Parquet: profile of every row, file-wide figures from the footer.")
        }
    }

    func rowEntries(_ row: Int) -> [DataEntry] {
        (0..<columnCount).map { c in
            let v = value(source: source(row), column: c)
            return (title(c), v.map { $0.isNull ? "" : ColumnarText.text($0, kind: columns[c].kind) } ?? "…")
        }
    }

    // MARK: The pill

    var headline: String {
        let r = rowCount.formatted(), c = columnCount.formatted()
        let rows: String
        switch (rowCount == 1, columnCount == 1) {
        case (true, true): rows = String(localized: "\(r) row · \(c) column", bundle: .previewKit, comment: "Summary: one row and one column; the arguments are formatted numbers.")
        case (true, false): rows = String(localized: "\(r) row · \(c) columns", bundle: .previewKit, comment: "Summary: one row, several columns.")
        case (false, true): rows = String(localized: "\(r) rows · \(c) column", bundle: .previewKit, comment: "Summary: several rows, one column.")
        case (false, false): rows = String(localized: "\(r) rows · \(c) columns", bundle: .previewKit, comment: "Summary: row and column counts.")
        }
        return format == .xlsx ? "\(dataset.parts[selected].name) · \(rows)" : rows
    }

    private static let sizeLabel = String(localized: "Size", bundle: .previewKit, comment: "Fact label: the file size.")
    private static let minLabel = String(localized: "Min", bundle: .previewKit, comment: "Column fact label: the smallest value.")
    private static let maxLabel = String(localized: "Max", bundle: .previewKit, comment: "Column fact label: the largest value.")

    var kind: FileKind {
        switch format {
        case .parquet: .dataset(.parquet)
        case .arrowFile: .dataset(.arrow)
        case .arrowStream: .dataset(.arrowStream)
        case .feather: .dataset(.feather)
        case .xlsx: .dataset(.xlsx)
        }
    }

    /// The columns and their types as text: the Schema view and Copy.
    var schemaText: String {
        var lines: [String] = []
        if format == .xlsx { lines.append(String(localized: "Sheet: \(dataset.parts[selected].name)", bundle: .previewKit, comment: "Schema text's first line: the workbook sheet shown.")) }
        let width = min(40, (columns.map(\.name.count).max() ?? 0) + 2)
        for c in columns {
            let name = c.name.padding(toLength: max(width, c.name.count + 2), withPad: " ", startingAt: 0)
            lines.append(name + c.typeDescription + (c.note.map { "  (\($0))" } ?? ""))
        }
        lines.append("")
        lines += dataset.facts.map { "\($0.label): \($0.value)" }
        return lines.joined(separator: "\n")
    }

    func document() -> PreviewDocument {
        var facts = [Fact(key: "headline", label: String(localized: "Summary", bundle: .previewKit, comment: "Fact label: the one-line summary of the file."), value: headline),
                     Fact(key: "size", label: Self.sizeLabel, value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))]
        facts += keyedFileEntries().filter { $0.key != "size" }
        var badges: [Badge] = []
        if let lint { badges.append(Badge(level: .caution, title: String(localized: "Read problem", bundle: .previewKit, comment: "Badge title: part of the file could not be read."), detail: lint.message)) }
        var doc = PreviewDocument(kind: kind, facts: facts, badges: badges, views: [.text(schemaText), .text(schemaText)])
        doc.viewTitles = ["Table",
                         "Schema"]
        return doc
    }
}
