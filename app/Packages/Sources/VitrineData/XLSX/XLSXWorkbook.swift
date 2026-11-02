import Foundation
import VitrineArchive
import VitrineSupport

/// An Excel workbook (.xlsx: ECMA-376 Office Open XML SpreadsheetML, a zip of XML parts). The package relationships
/// (`_rels/.rels`, `xl/_rels/workbook.xml.rels`) lead to the workbook (sheet names, the 1904 date system), the shared
/// strings, the styles (which number formats are dates) and each worksheet. Parts are inflated from the zip in
/// memory by VitrineArchive and parsed with Foundation's XMLParser (no DTDs: a part declaring one is refused, so no
/// entity can expand). Formulas show their cached values; a sheet is parsed when it is opened, bounded by
/// `ColumnarLimits.maxSheetXMLBytes` and `maxSheetCells`. roadmap: S-21
public final class XLSXWorkbook: ColumnarDataset, @unchecked Sendable {
    public let format = ColumnarFormat.xlsx
    let source: any ByteSource
    let limits: ColumnarLimits
    let listing: ArchiveListing
    let archiveLimits: ArchiveLimits
    let sheets: [Sheet]
    let date1904: Bool
    let sharedStringsPath: String?
    let stylesPath: String?
    let application: String?
    private let lock = NSLock()
    private var sharedStrings: [String]?
    private var dateStyles: [XLSXParts.NumberStyle]?
    private var opened: [Int: XLSXSheetTable] = [:]

    struct Sheet: Sendable {
        var name: String
        var path: String?
        var hidden: Bool
        var isChart: Bool
        var dimension: String?
    }

    public init(source: any ByteSource, limits: ColumnarLimits = ColumnarLimits()) throws {
        self.source = source
        self.limits = limits
        let archiveLimits = ArchiveLimits(maxEntries: 20_000, maxDecompressedBytes: Int64(limits.maxSheetXMLBytes), timeBudget: 30)
        self.archiveLimits = archiveLimits
        let listing: ArchiveListing
        do { listing = try VitrineArchive.list(source: source, fileName: "book.xlsx", limits: archiveLimits) } catch {
            throw ColumnarError.malformed(String(localized: "the workbook's zip cannot be read (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        self.listing = listing
        func read(_ path: String, limit: Int) throws -> Data? {
            try XLSXWorkbook.member(path, listing: listing, source: source, limit: limit, archiveLimits: archiveLimits)
        }
        let rootRels = try read("_rels/.rels", limit: 1 << 20).map { XLSXParts.relationships($0) } ?? []
        let workbookPath = rootRels.first { $0.type.hasSuffix("/officeDocument") }.map { XLSXParts.resolve($0.target, base: "") } ?? "xl/workbook.xml"
        guard let workbookXML = try read(workbookPath, limit: 32 << 20) else {
            throw ColumnarError.malformed(String(localized: "the zip has no workbook part (\(workbookPath)): not an Excel workbook", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        let base = (workbookPath as NSString).deletingLastPathComponent
        let relsPath = (base.isEmpty ? "" : base + "/") + "_rels/" + (workbookPath as NSString).lastPathComponent + ".rels"
        let rels = try read(relsPath, limit: 8 << 20).map { XLSXParts.relationships($0) } ?? []
        let book = try XLSXParts.workbook(workbookXML)
        date1904 = book.date1904
        var sheets: [Sheet] = []
        let limits = self.limits
        for s in book.sheets.prefix(limits.maxChunks) {
            let rel = rels.first { $0.id == s.relationship }
            let path = rel.map { XLSXParts.resolve($0.target, base: base) }
            sheets.append(Sheet(name: s.name, path: path, hidden: s.hidden, isChart: rel?.type.hasSuffix("/chartsheet") ?? false))
        }
        let sharedStringsPath = rels.first { $0.type.hasSuffix("/sharedStrings") }.map { XLSXParts.resolve($0.target, base: base) }
        let stylesPath = rels.first { $0.type.hasSuffix("/styles") }.map { XLSXParts.resolve($0.target, base: base) }
        // The first bytes of each worksheet name its used range (`<dimension ref="A1:H120"/>`), for the sheet list.
        for k in sheets.indices.prefix(256) where !sheets[k].isChart {
            guard let path = sheets[k].path,
                  let head = try? XLSXWorkbook.member(path, listing: listing, source: source, limit: 4_096, archiveLimits: archiveLimits, partial: true)
            else { continue }
            sheets[k].dimension = XLSXParts.dimension(head)
        }
        self.sheets = sheets
        self.sharedStringsPath = sharedStringsPath
        self.stylesPath = stylesPath
        let appXML = rootRels.first { $0.type.hasSuffix("/extended-properties") }.flatMap { try? read(XLSXParts.resolve($0.target, base: ""), limit: 1 << 20) }
        application = appXML.flatMap { XLSXParts.application($0) }
        guard !self.sheets.isEmpty else { throw ColumnarError.malformed(String(localized: "the workbook lists no sheets", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
    }

    /// A part's bytes; nil when the zip has no such part. `partial` allows a cut read of the first `limit` bytes.
    static func member(_ path: String, listing: ArchiveListing, source: any ByteSource, limit: Int, archiveLimits: ArchiveLimits,
                       partial: Bool = false) throws -> Data? {
        let wanted = ArchivePath.normalized(path).lowercased()
        guard let index = listing.entries.lastIndex(where: { ArchivePath.normalized($0.path).lowercased() == wanted && $0.type == .file }) else { return nil }
        if let size = listing.entries[index].uncompressedSize, size > Int64(limit), !partial {
            throw ColumnarError.tooLarge(String(localized: "the part \(path) is \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        let data: MemberData
        do {
            data = try VitrineArchive.memberData(source: source, listing: listing, entryIndex: index, limit: limit, limits: archiveLimits)
        } catch {
            throw ColumnarError.malformed(String(localized: "the part \(path) cannot be read (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        if !data.isComplete, !partial { throw ColumnarError.tooLarge(String(localized: "the part \(path) is larger than \(limit / 1_048_576) MB", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        return Data(data.bytes)
    }

    public var parts: [ColumnarPart] {
        sheets.map { s in
            var note: String?
            if s.isChart { note = String(localized: "chart sheet", bundle: .module, comment: "Note on a workbook sheet that holds a chart, not cells.") } else if s.hidden { note = String(localized: "hidden", bundle: .module, comment: "Note on a hidden workbook sheet.") }
            let rows = s.dimension.flatMap(XLSXParts.rows(inDimension:))
            return ColumnarPart(name: s.name, rows: rows, rowsAreEstimate: true, note: note)
        }
    }

    public var facts: [ColumnarFact] {
        var out = [ColumnarFact(key: "sheets", String(localized: "Sheets", bundle: .module, comment: "Fact label: the number of sheets in a workbook."), sheets.count.formatted())]
        let hidden = sheets.filter(\.hidden).count
        if hidden > 0 { out.append(ColumnarFact(key: "hiddensheets", String(localized: "Hidden sheets", bundle: .module, comment: "Fact label: the number of hidden sheets in a workbook."), hidden.formatted())) }
        if date1904 { out.append(ColumnarFact(key: "dates", String(localized: "Dates", bundle: .module, comment: "Fact label: the workbook's date system."), String(localized: "1904 date system", bundle: .module, comment: "Dates fact value: the workbook counts dates from 1904 (old Mac Excel)."))) }
        if let application { out.append(ColumnarFact(key: "writtenby", String(localized: "Written by", bundle: .module, comment: "Fact label: the program that wrote the file."), application)) }
        out.append(ColumnarFact(key: "format", String(localized: "Format", bundle: .module, comment: "Fact label in a column file's (Parquet, Arrow, Excel) File tab."), String(localized: "Office Open XML spreadsheet (.xlsx)", bundle: .module, comment: "Format fact value for an Excel workbook.")))
        return out
    }

    public func table(_ part: Int) throws -> any ColumnarTable {
        guard sheets.indices.contains(part) else { throw ColumnarError.malformed(String(localized: "no sheet \(part + 1)", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        lock.lock()
        defer { lock.unlock() }
        if let t = opened[part] { return t }
        let sheet = sheets[part]
        if sheet.isChart { throw ColumnarError.unsupported(String(localized: "“\(sheet.name)” is a chart sheet: it holds a chart, not cells", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are.")) }
        guard let path = sheet.path, let xml = try XLSXWorkbook.member(path, listing: listing, source: source,
                                                                       limit: limits.maxSheetXMLBytes, archiveLimits: archiveLimits) else {
            throw ColumnarError.malformed(String(localized: "the sheet “\(sheet.name)” has no part in the zip", bundle: .module, comment: "Detail of a column-file (Parquet, Arrow, Excel) error, lower-case and without a final period; it fills the gap in a sentence such as 'The file is damaged: …'. Format and encoding names in capitals stay as they are."))
        }
        if sharedStrings == nil {
            sharedStrings = try sharedStringsPath.flatMap {
                try XLSXWorkbook.member($0, listing: listing, source: source, limit: limits.maxSheetXMLBytes, archiveLimits: archiveLimits)
            }.map { try XLSXParts.sharedStrings($0, limit: limits.maxSharedStrings) } ?? []
        }
        if dateStyles == nil {
            dateStyles = try stylesPath.flatMap {
                try XLSXWorkbook.member($0, listing: listing, source: source, limit: 64 << 20, archiveLimits: archiveLimits)
            }.map { try XLSXParts.dateStyles($0) } ?? []
        }
        let cells = try XLSXSheetParser.parse(xml, sharedStrings: sharedStrings ?? [], dateStyles: dateStyles ?? [], limits: limits)
        let table = XLSXSheetTable(cells, date1904: date1904, limits: limits)
        // Only the open sheet is kept; another sheet's cells are parsed again when it is picked again.
        opened = [part: table]
        return table
    }
}
