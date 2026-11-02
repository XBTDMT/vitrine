import Foundation

/// One cell's value as SpreadsheetML stores it (ECMA-376 Part 1 §18.3.1.4 `c` and its `t` attribute).
enum XLSXValue: Sendable, Equatable {
    case number(Double)
    /// A number in a date or time format: the serial day number, and whether the format shows only a time of day.
    case date(Double, timeOnly: Bool)
    case string(String)
    case bool(Bool)
    case error(String)
}

/// The cells of one worksheet, sparse, in the order they were stored.
struct XLSXCells: Sendable {
    var rows: [Int] = []
    var columns: [Int] = []
    var values: [XLSXValue] = []
    var formulas = 0
    var formulasWithoutValue = 0
    var merged = 0
    var dimension: String?
}

/// Streams a worksheet's `<sheetData>`: rows (`r`), cells (`r`, `t`, `s`), their `<v>`, inline strings (`<is><t>`)
/// and formulas (`<f>`, whose cached `<v>` is the value shown). roadmap: S-21
enum XLSXSheetParser {
    static func parse(_ data: Data, sharedStrings: [String], dateStyles: [XLSXParts.NumberStyle], limits: ColumnarLimits) throws -> XLSXCells {
        var cells = XLSXCells()
        let w = XLSXParts.Walker()
        var row = 0
        var nextColumn = 0
        var cellColumn = 0, cellType = "n", cellStyle = 0
        var value = "", inline = ""
        var inValue = false, inInline = false, inCell = false, hasFormula = false, hasValue = false
        var failure: ColumnarError?
        w.start = { name, a in
            switch name {
            case "row":
                if let r = a["r"].flatMap(Int.init), r > 0, r <= 1_048_576 { row = r } else { row += 1 }
                nextColumn = 0
            case "c":
                inCell = true; hasFormula = false; hasValue = false
                value = ""; inline = ""
                cellType = a["t"] ?? "n"
                cellStyle = a["s"].flatMap(Int.init) ?? 0
                if let ref = a["r"], let parsed = XLSXCellReference.parse(ref) {
                    cellColumn = parsed.column
                    if let r = parsed.row, r > 0 { row = r }
                } else {
                    cellColumn = nextColumn
                }
                nextColumn = cellColumn + 1
            case "v": if inCell { inValue = true; hasValue = true }
            case "f": if inCell { hasFormula = true }
            case "is": if inCell { inInline = true }
            case "t": break
            case "mergeCell": cells.merged += 1
            case "dimension": cells.dimension = a["ref"]
            default: break
            }
        }
        w.text = { s in
            if inValue { value += s } else if inInline { inline += s }
        }
        w.end = { name in
            switch name {
            case "v": inValue = false
            case "is": inInline = false
            case "c":
                inCell = false
                if hasFormula { cells.formulas += 1; if !hasValue && cellType != "inlineStr" { cells.formulasWithoutValue += 1 } }
                guard cellColumn >= 0, cellColumn < 16_384, row > 0 else { return }
                let v: XLSXValue?
                switch cellType {
                case "s":
                    if let i = Int(value.trimmingCharacters(in: .whitespaces)), i >= 0, i < sharedStrings.count { v = .string(sharedStrings[i]) }
                    else { v = hasValue ? .error("#REF! (shared string \(value))") : nil }
                case "str": v = hasValue ? .string(value) : nil
                case "inlineStr": v = .string(inline)
                case "b": v = hasValue ? .bool(value.trimmingCharacters(in: .whitespaces) == "1") : nil
                case "e": v = hasValue ? .error(value) : nil
                case "d":
                    v = hasValue ? (XLSXSheetParser.isoSerial(value).map { .date($0, timeOnly: false) } ?? .string(value)) : nil
                default:
                    if let d = Double(value.trimmingCharacters(in: .whitespaces)) {
                        let style = cellStyle >= 0 && cellStyle < dateStyles.count ? dateStyles[cellStyle] : .number
                        // Excel's dates end at serial 2,958,465 (9999-12-31); anything past that is shown as the number it is.
                        let isDate = style != .number && d.isFinite && d >= 0 && d < 2_958_466
                        v = isDate ? .date(d, timeOnly: style == .time) : .number(XLSXSheetParser.excelPrecision(d))
                    } else { v = nil }
                }
                guard let v else { return }
                if cells.values.count >= limits.maxSheetCells {
                    failure = .tooLarge(String(localized: "the sheet has more than \(limits.maxSheetCells.formatted()) cells", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
                    return
                }
                cells.rows.append(row)
                cells.columns.append(cellColumn)
                cells.values.append(v)
            default: break
            }
        }
        w.stop = { failure != nil }
        try XLSXParts.run(data, w, what: String(localized: "the worksheet", bundle: .module, comment: "Names a part of a column file that ends early or is damaged; it fills the gap in '%@ runs past its page' or '%@ is not well-formed XML (…)'."))
        if let failure { throw failure }
        return cells
    }

    /// Excel keeps 15 significant digits; the stored binary value's tail (0.30000000000000004) is noise it never shows.
    static func excelPrecision(_ d: Double) -> Double {
        guard d.isFinite, d != 0 else { return d }
        return Double(String(format: "%.15g", d)) ?? d
    }

    /// An ISO 8601 date or date-time (`t="d"` cells) as a serial day number in the 1900 system.
    static func isoSerial(_ s: String) -> Double? {
        let parts = s.split(separator: "T", maxSplits: 1)
        let date = parts.first.map { $0.split(separator: "-").compactMap { Int($0) } } ?? []
        guard date.count == 3 else { return nil }
        let days = ColumnarText.days(year: Int64(date[0]), month: date[1], day: date[2])
        var fraction = 0.0
        if parts.count == 2 {
            let clock = parts[1].prefix { $0 != "Z" && $0 != "+" }.split(separator: ":").compactMap { Double($0) }
            if clock.count >= 2 { fraction = (clock[0] * 3_600 + clock[1] * 60 + (clock.count > 2 ? clock[2] : 0)) / 86_400 }
        }
        let serial = Double(days) + 25_569 + fraction
        return serial >= 0 && serial < 2_958_466 ? serial : nil
    }
}

/// A parsed sheet as a table: column A first, rows from the first used row (a header row, when the first row reads
/// like one, becomes the column titles), each column typed when its values agree (numbers, dates, booleans, text) and
/// mixed otherwise. Row numbers are the sheet's own. roadmap: S-21
final class XLSXSheetTable: ColumnarTable, @unchecked Sendable {
    let columns: [ColumnarColumn]
    let rowCount: Int
    let chunks: [ColumnarChunk]
    /// The sheet row number of table row 0.
    let firstRowNumber: Int
    let hasHeader: Bool
    let facts: [ColumnarFact]
    private let vectors: [ColumnVector]
    let limits: ColumnarLimits

    init(_ cells: XLSXCells, date1904: Bool, limits: ColumnarLimits) {
        self.limits = limits
        let minRow = cells.rows.min() ?? 1
        let maxRow = cells.rows.max() ?? 0
        let columnCount = min((cells.columns.max() ?? -1) + 1, limits.maxColumns)
        // The first used row is a header when every value in it is text, no two alike, and rows follow.
        var header: [Int: String] = [:]
        for k in cells.values.indices where cells.rows[k] == minRow {
            if case .string(let s) = cells.values[k] { header[cells.columns[k]] = s } else { header = [:]; break }
        }
        let headerValues = header.values.filter { !$0.isEmpty }
        let isHeader = !header.isEmpty && maxRow > minRow && Set(headerValues).count == headerValues.count
            && header.count == cells.values.indices.filter({ cells.rows[$0] == minRow }).count
        hasHeader = isHeader
        let firstRow = isHeader ? minRow + 1 : minRow
        firstRowNumber = firstRow
        let rows = max(0, maxRow - firstRow + 1)
        rowCount = rows
        chunks = [ColumnarChunk(rows: rows)]
        // Per column: the values by row.
        var byColumn = Array(repeating: [Int: XLSXValue](), count: columnCount)
        for k in cells.values.indices {
            let c = cells.columns[k], r = cells.rows[k]
            guard c < columnCount, r >= firstRow else { continue }
            byColumn[c][r - firstRow] = cells.values[k]
        }
        var columns: [ColumnarColumn] = []
        var vectors: [ColumnVector] = []
        for c in 0..<columnCount {
            let letter = XLSXCellReference.letters(c)
            let title = header[c].flatMap { $0.isEmpty ? nil : $0 } ?? letter
            let (column, vector) = XLSXSheetTable.typed(byColumn[c], rows: rows, title: title, letter: letter, date1904: date1904)
            columns.append(column)
            vectors.append(vector)
        }
        self.columns = columns
        self.vectors = vectors
        var facts = [ColumnarFact(key: "cells", String(localized: "Cells", bundle: .module, comment: "Fact label: the number of non-empty cells in a sheet."), cells.values.count.formatted())]
        if let d = cells.dimension { facts.append(ColumnarFact(key: "usedrange", String(localized: "Used range", bundle: .module, comment: "Fact label: the cell range a sheet uses, such as A1:F20."), d)) }
        if cells.formulas > 0 {
            facts.append(ColumnarFact(key: "formulas", String(localized: "Formulas", bundle: .module, comment: "Fact label in an Excel sheet's File tab."), String(localized: "\(cells.formulas.formatted()) (cached values shown)", bundle: .module, comment: "Formulas fact value; the argument is a formatted count. The preview shows the values Excel saved, it does not recalculate.")))
            if cells.formulasWithoutValue > 0 { facts.append(ColumnarFact(key: "formulaswithoutavalue", String(localized: "Formulas without a value", bundle: .module, comment: "Fact label: formulas with no saved result."), cells.formulasWithoutValue.formatted())) }
        }
        if cells.merged > 0 { facts.append(ColumnarFact(key: "mergedranges", String(localized: "Merged ranges", bundle: .module, comment: "Fact label: the number of merged cell ranges."), cells.merged.formatted())) }
        if isHeader { facts.append(ColumnarFact(key: "header", String(localized: "Header", bundle: .module, comment: "Fact label: which row holds the column names."), String(localized: "row \(minRow) names the columns", bundle: .module, comment: "Header fact value; the argument is the sheet's row number."))) }
        self.facts = facts
    }

    func read(rows wanted: Range<Int>, isCancelled: @Sendable () -> Bool) throws -> ColumnarWindow {
        let lower = max(0, min(wanted.lowerBound, rowCount))
        let upper = max(lower, min(wanted.upperBound, rowCount, lower + limits.maxWindowRows))
        if isCancelled() { throw ColumnarError.cancelled }
        return ColumnarWindow(start: lower, count: upper - lower, columns: vectors.map { $0.slice(lower..<upper) })
    }

    /// Unix days of a serial day number (the 1900 system counts a 29 February 1900 that never was).
    static func unixDays(_ serial: Double, date1904: Bool) -> Double {
        if date1904 { return serial - 24_107 }
        return serial < 61 ? serial - 25_568 : serial - 25_569
    }

    static func typed(_ values: [Int: XLSXValue], rows: Int, title: String, letter: String, date1904: Bool) -> (ColumnarColumn, ColumnVector) {
        var numbers = 0, dates = 0, bools = 0, strings = 0, other = 0
        var whole = true, wholeDays = true, timeOnly = true
        for v in values.values {
            switch v {
            case .number(let d): numbers += 1; if d.rounded() != d || abs(d) >= 9.007e15 { whole = false }
            case .date(let d, let time): dates += 1; if d.rounded() != d { wholeDays = false }; if !time || d >= 1 || d < 0 { timeOnly = false }
            case .bool: bools += 1
            case .string: strings += 1
            case .error: other += 1
            }
        }
        let total = values.count
        let nulls = (0..<rows).map { values[$0] == nil }
        let typeLabel: String
        let kind: ColumnarKind
        let storage: ColumnVector.Storage
        if total == 0 {
            return (ColumnarColumn(name: title, kind: .null, typeDescription: String(localized: "Empty · column \(letter)", bundle: .module, comment: "Type description of an empty workbook column; the argument is the column letter such as C.")), .nulls(rows))
        } else if numbers == total {
            if whole {
                kind = .integer(bits: 64, signed: true); typeLabel = String(localized: "Number (whole)", bundle: .module, comment: "Type of a workbook column, judged from its cells.")
                storage = .ints((0..<rows).map { if case .number(let d)? = values[$0] { Int64(d) } else { 0 } })
            } else {
                kind = .float(bits: 64); typeLabel = String(localized: "Number", bundle: .module, comment: "Type of a workbook column, judged from its cells.")
                storage = .doubles((0..<rows).map { if case .number(let d)? = values[$0] { d } else { 0 } })
            }
        } else if dates == total {
            if timeOnly {
                kind = .time(.millis); typeLabel = String(localized: "Time", bundle: .module, comment: "Type of a workbook column, judged from its cells.")
                storage = .ints((0..<rows).map { if case .date(let d, _)? = values[$0] { Int64((d * 86_400_000).rounded()) } else { 0 } })
            } else if wholeDays {
                kind = .date; typeLabel = String(localized: "Date", bundle: .module, comment: "Type of a workbook column, judged from its cells.")
                storage = .ints((0..<rows).map { if case .date(let d, _)? = values[$0] { Int64(unixDays(d, date1904: date1904)) } else { 0 } })
            } else {
                kind = .timestamp(.millis, zone: nil); typeLabel = String(localized: "Date and time", bundle: .module, comment: "Type of a workbook column, judged from its cells.")
                storage = .ints((0..<rows).map {
                    if case .date(let d, _)? = values[$0] { Int64((unixDays(d, date1904: date1904) * 86_400_000).rounded()) } else { 0 }
                })
            }
        } else if bools == total {
            kind = .boolean; typeLabel = String(localized: "Boolean", bundle: .module, comment: "Type of a workbook column, judged from its cells.")
            storage = .bools((0..<rows).map { if case .bool(let b)? = values[$0] { b } else { false } })
        } else if strings == total {
            kind = .string; typeLabel = String(localized: "Text", bundle: .module, comment: "Type of a workbook column, judged from its cells.")
            storage = .strings((0..<rows).map { if case .string(let s)? = values[$0] { s } else { "" } })
        } else {
            kind = .mixed; typeLabel = String(localized: "Mixed", bundle: .module, comment: "Type of a workbook column whose cells hold different kinds of values.")
            storage = .cells((0..<rows).map { r in
                switch values[r] {
                case .number(let d)?: return .text(ColumnarText.double(d), number: d)
                case .date(let d, _)?:
                    let days = unixDays(d, date1904: date1904)
                    let text = d.rounded() == d ? ColumnarText.date(days: Int64(days))
                        : ColumnarText.timestamp(Int64((days * 86_400_000).rounded()), unit: .millis, zone: nil)
                    return .text(text, number: nil)
                case .bool(let b)?: return .text(b ? "TRUE" : "FALSE", number: nil)
                case .string(let s)?: return .text(s, number: nil)
                case .error(let e)?: return .text(e, number: nil)
                case nil: return .null
                }
            })
        }
        let note: String? = other == 0 || kind == .mixed ? nil
            : other == 1 ? String(localized: "1 error value", bundle: .module, comment: "Note on a workbook column with one Excel error cell such as #DIV/0!.")
            : String(localized: "\(other) error values", bundle: .module, comment: "Note on a workbook column with several Excel error cells; the argument is how many (2 or more).")
        return (ColumnarColumn(name: title, kind: kind, typeDescription: String(localized: "\(typeLabel) · column \(letter)", bundle: .module, comment: "Type description of a workbook column; the arguments are its type, such as Number, and its letter, such as C."), note: note),
                ColumnVector(storage: storage, nulls: nulls))
    }
}
