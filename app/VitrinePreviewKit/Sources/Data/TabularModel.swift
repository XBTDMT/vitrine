import Foundation

/// A label and a value, as the Inspector lists them.
typealias DataEntry = (label: String, value: String)

/// One cell as the grid draws it.
struct DataCellValue: Equatable {
    enum Style: Equatable {
        case plain
        /// The value does not fit its column's type: caution text on caution-soft.
        case misfit
        /// NULL or a missing field: drawn dim.
        case missing
    }
    var text: String
    var style: Style = .plain
}

/// A part of a file with several (a SQLite table or view), listed on the Inspector's first tab; picking one shows
/// its rows.
struct DataPart: Equatable {
    var name: String
    /// "12,408", "view", "counting…".
    var detail: String
    var isSelected: Bool
}

/// One of a column's most common values, for the Column tab's bars.
struct DataTopValue: Equatable {
    var value: String
    var count: Int
}

/// What the Column tab draws around its lines (I-5, data column profile): a histogram of the numbers with the low and
/// high values under it, the share of values that fit, a note quoting the ones that don't, and the most common values
/// with bars.
struct DataColumnChart: Equatable {
    var histogram: [Int] = []
    var low = ""
    var high = ""
    var valid = 0
    var misfit = 0
    var empty = 0
    /// What the values that do not fit are, for the legend and the note.
    var misfitKind: DataMisfitKind = .other
    var note: String?
    var top: [DataTopValue] = []
    /// What the top values' bars are a share of (the non-empty values profiled).
    var topTotal = 0
}

/// Values that do not fit their column's type, by what the column expects: each phrase is whole, for translation.
enum DataMisfitKind: Equatable {
    case notNumbers, notDates, other

    /// The chart legend: "2 not numbers".
    func legend(_ count: Int) -> String {
        let n = count.formatted()
        switch self {
        case .notNumbers: return String(localized: "\(n) not numbers", bundle: .previewKit, comment: "Chart legend: how many values in a numbers column are not numbers.")
        case .notDates: return String(localized: "\(n) not dates", bundle: .previewKit, comment: "Chart legend: how many values in a dates column are not dates.")
        case .other: return String(localized: "\(n) don't fit", bundle: .previewKit, comment: "Chart legend: how many values do not fit the column's type.")
        }
    }

    /// The note under the chart: "2 values are not numbers: “two”, “—”". `examples` is the quoted values, joined.
    func note(count: Int, inSample: Bool, examples: String) -> String {
        let n = count.formatted()
        switch (self, count == 1, inSample) {
        case (.notNumbers, true, false): return String(localized: "1 value is not numbers: \(examples)", bundle: .previewKit, comment: "Column profile note: how many values are not numbers, then quoted examples.")
        case (.notNumbers, false, false): return String(localized: "\(n) values are not numbers: \(examples)", bundle: .previewKit, comment: "Column profile note: how many values are not numbers, then quoted examples.")
        case (.notNumbers, true, true): return String(localized: "1 value is not numbers in the sample: \(examples)", bundle: .previewKit, comment: "Column profile note: how many values are not numbers (in a sample of the file), then quoted examples.")
        case (.notNumbers, false, true): return String(localized: "\(n) values are not numbers in the sample: \(examples)", bundle: .previewKit, comment: "Column profile note: how many values are not numbers (in a sample of the file), then quoted examples.")
        case (.notDates, true, false): return String(localized: "1 value is not dates: \(examples)", bundle: .previewKit, comment: "Column profile note: how many values are not dates, then quoted examples.")
        case (.notDates, false, false): return String(localized: "\(n) values are not dates: \(examples)", bundle: .previewKit, comment: "Column profile note: how many values are not dates, then quoted examples.")
        case (.notDates, true, true): return String(localized: "1 value is not dates in the sample: \(examples)", bundle: .previewKit, comment: "Column profile note: how many values are not dates (in a sample of the file), then quoted examples.")
        case (.notDates, false, true): return String(localized: "\(n) values are not dates in the sample: \(examples)", bundle: .previewKit, comment: "Column profile note: how many values are not dates (in a sample of the file), then quoted examples.")
        case (.other, true, false): return String(localized: "1 value doesn't fit: \(examples)", bundle: .previewKit, comment: "Column profile note: how many values do not fit the column's type, then quoted examples.")
        case (.other, false, false): return String(localized: "\(n) values don't fit: \(examples)", bundle: .previewKit, comment: "Column profile note: how many values do not fit the column's type, then quoted examples.")
        case (.other, true, true): return String(localized: "1 value doesn't fit in the sample: \(examples)", bundle: .previewKit, comment: "Column profile note: how many values do not fit the column's type (in a sample of the file), then quoted examples.")
        case (.other, false, true): return String(localized: "\(n) values don't fit in the sample: \(examples)", bundle: .previewKit, comment: "Column profile note: how many values do not fit the column's type (in a sample of the file), then quoted examples.")
        }
    }
}

/// A problem with the file's shape the table shows as a caution banner (I-6): rows with the wrong field count.
struct DataLint: Equatable {
    var message: String
    /// Source rows to step through with Next issue (the first few the index recorded).
    var rows: [Int]
}

/// A filter and a sort on a table (I-4, data 1): rows where any cell contains `filter`, ordered by one column.
struct DataArrangement: Equatable {
    var filter = ""
    var sortColumn: Int?
    var ascending = true
    var isEmpty: Bool { filter.isEmpty && sortColumn == nil }
}

/// What the data grid and Inspector draw from (data r3-a): CSV/TSV through `DataModel`, SQLite through
/// `SQLiteDataModel`, Parquet, Arrow and xlsx through `ColumnarDataModel` (B-4), later JSONL. Rows are read on demand; nothing here is AppKit. roadmap: S-6
@MainActor
protocol TabularModel: AnyObject {
    var columnCount: Int { get }
    /// Rows in the file (or the picked table).
    var rowCount: Int { get }
    /// Rows shown: those the filter keeps, every row without one. Every `row` below is a shown row.
    var shownCount: Int { get }
    /// The number the row-number column shows for a shown row: its place in the file when the model knows it (a CSV
    /// keeps its numbers under a filter, data 1), else its place in the result.
    func rowNumber(_ row: Int) -> Int
    /// The filter and sort now applied.
    var arrangement: DataArrangement { get }
    /// Applies a filter and sort off the main thread and calls `onChange` when the new order is in. Returns false when
    /// it was cancelled or superseded by a newer call; the previous arrangement then stays.
    func arrange(_ arrangement: DataArrangement) async -> Bool
    func cancelArrange()
    /// Changes whenever the set of columns changes (another table picked), so the grid rebuilds its columns.
    var layoutVersion: Int { get }
    func title(_ column: Int) -> String
    func isNumeric(_ column: Int) -> Bool
    /// Some sampled values do not fit the column's type (the header's quality line turns caution).
    func hasMisfits(_ column: Int) -> Bool
    func cell(row: Int, column: Int) -> DataCellValue
    /// The header's type tag (G12): "123", "1.5", "Aa", "≡" (a category), "@" (email), "0|1", "BIN", "date".
    func typeTag(_ column: Int) -> String
    /// The header's tooltip (D-2): the column's type and, for SQLite, its constraints.
    func headerTooltip(_ column: Int) -> String
    /// The Column tab's chart parts; nil while nothing is profiled.
    func columnChart(_ column: Int) -> DataColumnChart?
    /// A shown cell as a number, for the selection's sum and average; nil when it is not one.
    func number(row: Int, column: Int) -> Double?
    /// The caution banner's content, when the file has a shape problem.
    var lint: DataLint? { get }
    /// Where a source row is shown now (filter and sort move it); nil when the filter hides it.
    func shownRow(forSource source: Int) -> Int?
    /// Values from the first rows, for sizing a column on open.
    func sampleValues(column: Int) -> [String]
    /// Called after the model learned more (an index, a count, a profile, another table) so the views redraw.
    var onChange: (() -> Void)? { get set }

    /// The Inspector's first tab: "File" for one table, "Database" for a file with parts.
    var fileTabTitle: String { get }
    var parts: [DataPart] { get }
    func selectPart(_ index: Int)
    func fileEntries() -> [DataEntry]
    /// The column's type first (the heading shows it), then its profile.
    func columnEntries(_ column: Int) -> [DataEntry]
    /// Footnote under the column profile: how many rows it was computed from.
    var profileNote: String { get }
    func rowEntries(_ row: Int) -> [DataEntry]

    // Defaults in the extension below (B-4).
    var opensInspector: Bool { get }
    var partsHeading: String { get }
    var fileCaption: String? { get }
    func fileSections(visibleRow: Int) -> [DataFileSection]
    func firstShownRow(ofChunk chunk: Int) -> Int?
    func chunk(ofShownRow row: Int) -> Int?
}

/// A drawn part of the File tab under its facts (data design, "Parquet / Arrow, footer first", A-7): the row-group
/// strip with the group in view lit, and the columns' footer ranges. roadmap: S-21
enum DataFileSection: Equatable {
    /// "Row groups · 19": one segment per group (`count`), `selected` lit, `caption` under it.
    case strip(title: String, count: Int, selected: Int, caption: String)
    /// "Columns · min → max": a label and a value per column.
    case entries(title: String, entries: [DataSectionEntry])
}

struct DataSectionEntry: Equatable {
    var label: String
    var value: String
}

/// What a model may add to the shared views; the defaults keep CSV and SQLite as they were. roadmap: S-21
extension TabularModel {
    /// The Inspector is open on the first paint (a file with parts, a Parquet footer).
    var opensInspector: Bool { !parts.isEmpty }
    /// The heading over `parts` on the File tab.
    var partsHeading: String { String(localized: "Tables", bundle: .previewKit, comment: "Inspector heading over the list of a database's tables and views.") }
    /// A line under the tab bar in place of "This file" ("From the footer…").
    var fileCaption: String? { nil }
    /// Sections drawn after the file facts; `visibleRow` is the shown row at the top of the grid.
    func fileSections(visibleRow: Int) -> [DataFileSection] { [] }
    /// The shown row a strip segment leads to.
    func firstShownRow(ofChunk chunk: Int) -> Int? { nil }
    /// Which strip segment holds a shown row (the Inspector redraws when it changes).
    func chunk(ofShownRow row: Int) -> Int? { nil }
}
