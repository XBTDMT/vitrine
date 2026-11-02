import Foundation
import VitrineArchive
import VitrineCompare
import VitrineData
import VitrineSupport

/// What Spotlight should find inside the files it cannot read itself (X-8, S-19): SQLite tables (names, columns and the
/// first rows' text), Parquet / Arrow / Feather / xlsx (sheets, columns, first rows), Jupyter notebooks (every cell's
/// source) and archives (every member's path). Markdown and source code are text types Apple's own importers index, so
/// they are not here. Every read is bounded in rows, characters and time, never writes, and never runs anything: the
/// importer runs inside Spotlight's worker while the person is busy. roadmap: S-19
public enum SpotlightText {
    public struct Record: Sendable, Equatable {
        public var text: String
        public var title: String?
        /// Table, sheet and column names: Spotlight weighs keywords above body text.
        public var keywords: [String]
    }

    public struct Limits: Sendable, Equatable {
        public var maxCharacters = 512_000
        public var rowsPerTable = 200
        public var maxTables = 64
        public var maxCellCharacters = 200
        public var maxEntries = 20_000
        /// Notebook input larger than this is skipped (VitrineCompare's own cap applies too).
        public var maxNotebookBytes = 32 << 20
        public var seconds: TimeInterval = 3
        public init() {}
    }

    /// The record for one file, or nil when the file is not one of these formats or cannot be read.
    public static func record(for url: URL, limits: Limits = Limits()) -> Record? {
        let deadline = Date().addingTimeInterval(limits.seconds)
        var out = Collector(limits: limits, deadline: deadline)
        switch FileSniffer.kind(of: url) {
        case .sqlite: sqlite(url, into: &out)
        case .dataset: columnar(url, into: &out)
        case .archive: archive(url, into: &out)
        case .code(let language) where language == "ipynb": notebook(url, into: &out)
        default: return nil
        }
        guard !out.text.isEmpty || !out.keywords.isEmpty else { return nil }
        return Record(text: out.text, title: out.title, keywords: out.keywords)
    }

    /// Gathers text up to the character cap and the deadline; `full` stops the readers early.
    struct Collector {
        let limits: Limits
        let deadline: Date
        var text = ""
        var title: String?
        var keywords: [String] = []

        var full: Bool { text.count >= limits.maxCharacters || Date() >= deadline }

        mutating func line(_ s: String) {
            guard !full else { return }
            let room = limits.maxCharacters - text.count
            text += (s.count > room ? String(s.prefix(room)) : s) + "\n"
        }

        mutating func keyword(_ s: String) {
            let k = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty, !keywords.contains(k) { keywords.append(k) }
        }

        func cell(_ s: String) -> String {
            let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            return flat.count > limits.maxCellCharacters ? String(flat.prefix(limits.maxCellCharacters)) : flat
        }
    }

    // MARK: SQLite

    static func sqlite(_ url: URL, into out: inout Collector) {
        guard let db = try? SQLiteDatabase.open(url) else { return }
        for object in db.browsable.prefix(out.limits.maxTables) where !out.full {
            out.keyword(object.name)
            guard let columns = try? db.columns(of: object.name) else { continue }
            columns.forEach { out.keyword($0.name) }
            out.line("\(object.name): " + columns.map(\.name).joined(separator: ", "))
            let rows = (try? db.rows(object, columns: columns, start: 0, limit: out.limits.rowsPerTable, rowID: nil, anchors: nil)) ?? []
            for row in rows where !out.full {
                let texts = row.compactMap { value -> String? in
                    switch value {
                    case .text(let s, _): s.isEmpty ? nil : out.cell(s)
                    case .integer(let n): String(n)
                    case .real(let d): String(d)
                    case .null, .blob: nil
                    }
                }
                if !texts.isEmpty { out.line(texts.joined(separator: "\t")) }
            }
        }
    }

    // MARK: Parquet, Arrow, Feather, xlsx

    static func columnar(_ url: URL, into out: inout Collector) {
        guard let dataset = try? ColumnarOpener.open(url) else { return }
        for (index, part) in dataset.parts.prefix(out.limits.maxTables).enumerated() where !out.full {
            if dataset.parts.count > 1 { out.keyword(part.name) }
            guard let table = try? dataset.table(index) else { continue }
            table.columns.forEach { out.keyword($0.name) }
            out.line((dataset.parts.count > 1 ? "\(part.name): " : "") + table.columns.map(\.name).joined(separator: ", "))
            let count = min(table.rowCount, out.limits.rowsPerTable)
            guard count > 0, let window = try? table.read(rows: 0..<count) else { continue }
            for row in 0..<window.count where !out.full {
                var texts: [String] = []
                for (c, vector) in window.columns.enumerated() where c < table.columns.count && row < vector.count {
                    if vector.nulls?[row] == true { continue }
                    let s = ColumnarText.text(vector[row], kind: table.columns[c].kind)
                    if !s.isEmpty { texts.append(out.cell(s)) }
                }
                if !texts.isEmpty { out.line(texts.joined(separator: "\t")) }
            }
        }
    }

    // MARK: Archives

    static func archive(_ url: URL, into out: inout Collector) {
        guard let listing = try? VitrineArchive.list(contentsOf: url) else { return }
        for entry in listing.entries.prefix(out.limits.maxEntries) where !out.full { out.line(entry.path) }
    }

    // MARK: Jupyter notebooks

    static func notebook(_ url: URL, into out: inout Collector) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size <= out.limits.maxNotebookBytes, let data = try? Data(contentsOf: url),
              let notebook = try? NotebookReader.read(data, side: nil) else { return }
        out.title = notebook.title
        for cell in notebook.cells where !out.full {
            out.line(cell.source)
            out.line("")
        }
    }
}
