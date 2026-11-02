import Foundation

/// One fact for the metadata strip. VitrineData does not depend on VitrineDocument, so this mirrors `Fact` (stable
/// key, label, display value) and the document layer maps it one to one.
public struct CSVFact: Sendable, Equatable {
    public var key: String
    public var label: String
    public var value: String
}

/// The facts a data preview shows about a delimited file. Typed values first, display strings on request, so the
/// lint banner can reason on `raggedRows` while the strip just prints.
public struct CSVFacts: Sendable, Equatable {
    public var rows: CSVRowCount
    public var columns: Int
    public var delimiter: CSVDelimiter
    public var hasHeader: Bool
    public var encoding: CSVTextEncoding
    public var hasBOM: Bool
    /// Rows whose field count differs from the column count: from the index when there is one (exact once it is
    /// complete), else from the first page.
    public var raggedRows: CSVRowCount

    /// Keys: `rows`, `columns`, `delimiter`, `header`, `encoding`, `raggedRows`.
    public func entries(locale: Locale = .current) -> [CSVFact] {
        [
            CSVFact(key: "rows", label: String(localized: "Rows", bundle: .module, comment: "Fact label: number of data rows."), value: rows.formatted(locale: locale)),
            CSVFact(key: "columns", label: String(localized: "Columns", bundle: .module, comment: "Fact label: number of columns."), value: columns.formatted(.number.locale(locale))),
            CSVFact(key: "delimiter", label: String(localized: "Delimiter", bundle: .module, comment: "Fact label: the CSV field separator."), value: delimiter.name),
            CSVFact(key: "header", label: String(localized: "Header row", bundle: .module, comment: "Fact label: whether the first row holds column names."),
                    value: hasHeader ? String(localized: "Yes", bundle: .module, comment: "Fact value: the file has a header row.") : String(localized: "No", bundle: .module, comment: "Fact value: the file has no header row.")),
            CSVFact(key: "encoding", label: String(localized: "Encoding", bundle: .module, comment: "Fact label: the text encoding."),
                    value: hasBOM ? String(localized: "\(encoding.displayName) with BOM", bundle: .module, comment: "Encoding fact value; the argument is an encoding name such as UTF-8; BOM = byte order mark.") : encoding.displayName),
            CSVFact(key: "raggedRows", label: String(localized: "Ragged rows", bundle: .module, comment: "Fact label: rows whose field count differs from the column count."), value: raggedRows.formatted(locale: locale)),
        ]
    }
}

extension CSVTable {
    public func facts(index: CSVRowIndex?) -> CSVFacts {
        let ragged: CSVRowCount
        if firstPage.reachesEndOfFile {
            ragged = .exactly(firstPage.raggedRows)
        } else if let index {
            ragged = index.isComplete ? .exactly(index.raggedRows) : .atLeast(max(index.raggedRows, firstPage.raggedRows))
        } else {
            ragged = .atLeast(firstPage.raggedRows)
        }
        return CSVFacts(rows: rowCount(index: index), columns: columnCount, delimiter: dialect.delimiter,
                        hasHeader: dialect.hasHeader, encoding: dialect.encoding, hasBOM: dialect.hasBOM,
                        raggedRows: ragged)
    }
}
