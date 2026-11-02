import Foundation

/// Per-column statistics for the data preview's column header and inspector. Always computed from a sample and says
/// so: a profile of 2,000 rows from a 40-million-row file is useful, but only if the reader knows that is what it is.
public struct CSVProfile: Sendable, Equatable {
    public var columns: [CSVColumnProfile]
    /// Rows the statistics were computed from.
    public var sampledRows: Int
    /// The table's rows as far as known when profiling.
    public var totalRows: CSVRowCount
    /// True unless the sample was every row of a file whose row count is exact.
    public var isSample: Bool { !(totalRows.isExact && sampledRows >= totalRows.known) }
}

public struct CSVColumnProfile: Sendable, Equatable {
    public struct ValueCount: Sendable, Equatable {
        public var value: String
        public var count: Int
    }

    public struct NumberSummary: Sendable, Equatable {
        public var min: Double
        public var max: Double
        public var mean: Double
    }

    public struct DateSummary: Sendable, Equatable {
        public var earliest: Date
        public var latest: Date
    }

    public var index: Int
    public var title: String
    public var typeInfo: CSVColumnTypeInfo
    public var nonEmpty: Int
    public var empty: Int
    /// Distinct non-empty values, counted up to `CSVProfiler.distinctCap`.
    public var distinct: Int
    /// The distinct count hit the cap: the real number is at least `distinct`.
    public var distinctIsCapped: Bool
    /// Numbers columns only, over the values that fit.
    public var numbers: NumberSummary?
    /// Date and date-time columns only, over the values that fit.
    public var dates: DateSummary?
    /// The most common values, most frequent first (ties alphabetical), up to five: text and boolean columns always,
    /// numbers and dates only when some value repeats (an id column has none worth listing).
    public var topValues: [ValueCount]
    /// Numbers columns: the median and a histogram of the values that fit, for the column profile (I-5).
    public var distribution: NumberDistribution?
    /// Up to three distinct values that do not fit the column's type, as written ("two", "—").
    public var misfitExamples: [String] = []

    public struct NumberDistribution: Sendable, Equatable {
        public var median: Double
        /// Counts in `bins` equal-width bins from the minimum to the maximum (one bin when they are equal).
        public var histogram: [Int]
    }
}

public enum CSVProfiler {
    /// Distinct values tracked per column. Past it the count says "at least" and top values are counted among the
    /// values already seen, which keeps memory flat on high-cardinality columns.
    public static let distinctCap = 10_000
    public static let topValueLimit = 5
    public static let histogramBins = 16

    public static func profile(rows: [CSVRow], columnTitles: [String], dialect: CSVDialect,
                               totalRows: CSVRowCount) -> CSVProfile {
        let infos = CSVColumnInference.infer(rows: rows, columnCount: columnTitles.count, dialect: dialect)
        let columns = infos.map { info in
            profile(values: rows.map { $0[info.index] }, title: columnTitles[info.index], info: info)
        }
        return CSVProfile(columns: columns, sampledRows: rows.count, totalRows: totalRows)
    }

    static func profile(values: [String], title: String, info: CSVColumnTypeInfo) -> CSVColumnProfile {
        var counts: [String: Int] = [:]
        var capped = false
        var nonEmpty = 0
        var minimum = Double.infinity, maximum = -Double.infinity, sum = 0.0, numbers = 0
        var earliest: Date?, latest: Date?
        var fitting: [Double] = []
        var misfits: [String] = []

        for value in values where CSVValueClassifier.isNonEmpty(value) {
            nonEmpty += 1
            if counts[value] != nil {
                counts[value, default: 0] += 1
            } else if counts.count < distinctCap {
                counts[value] = 1
            } else {
                capped = true
            }
            if info.type.isNumeric, info.accepts(value), let number = CSVValueClassifier.number(value, style: info.style),
               number.isFinite {
                minimum = min(minimum, number); maximum = max(maximum, number); sum += number; numbers += 1
                fitting.append(number)
            } else if info.type.isTemporal, info.accepts(value), let date = CSVValueClassifier.date(value, style: info.style)?.date {
                earliest = min(earliest ?? date, date); latest = max(latest ?? date, date)
            }
            if info.type != .text, info.type != .empty, !info.accepts(value), misfits.count < 3, !misfits.contains(value) {
                misfits.append(value)
            }
        }

        var top: [CSVColumnProfile.ValueCount] = []
        if info.type == .text || info.type == .boolean || (counts.values.max() ?? 0) > 1 {
            top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(topValueLimit).map { CSVColumnProfile.ValueCount(value: $0.key, count: $0.value) }
        }
        return CSVColumnProfile(
            index: info.index, title: title, typeInfo: info, nonEmpty: nonEmpty, empty: values.count - nonEmpty,
            distinct: counts.count, distinctIsCapped: capped,
            numbers: numbers > 0 ? .init(min: minimum, max: maximum, mean: sum / Double(numbers)) : nil,
            dates: earliest.flatMap { e in latest.map { .init(earliest: e, latest: $0) } },
            topValues: top, distribution: distribution(fitting, min: minimum, max: maximum), misfitExamples: misfits)
    }

    static func distribution(_ values: [Double], min lo: Double, max hi: Double) -> CSVColumnProfile.NumberDistribution? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
        let bins = hi > lo ? histogramBins : 1
        var histogram = Array(repeating: 0, count: bins)
        for v in values {
            let k = hi > lo ? Int(((v - lo) / (hi - lo)) * Double(bins)) : 0
            histogram[Swift.min(Swift.max(k, 0), bins - 1)] += 1
        }
        return .init(median: median, histogram: histogram)
    }
}

extension CSVTable {
    /// Profiles a sample spread over the file (`sampleRows(index:maxRows:)`).
    public func profile(index: CSVRowIndex?, maxRows: Int = 2000) throws -> CSVProfile {
        let sample = try sampleRows(index: index, maxRows: maxRows)
        return CSVProfiler.profile(rows: sample, columnTitles: (0..<columnCount).map(columnTitle), dialect: dialect,
                                   totalRows: rowCount(index: index))
    }
}
