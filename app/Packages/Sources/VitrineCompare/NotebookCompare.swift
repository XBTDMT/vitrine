import Foundation
import VitrineText

/// Bounds for one notebook compare. roadmap: S-7
public struct NotebookCompareLimits: Sendable, Equatable {
    /// Bytes of each notebook; a larger one is refused (`CompareError.tooLarge`).
    public var maxInputBytes: Int
    /// Cells compared on each side; past it the rest are left out and the result says so.
    public var maxCells: Int
    /// Base64 characters of one image output carried in the result for the page to draw; larger images are
    /// described but not carried.
    public var maxImageCharacters: Int
    /// Characters of one text output carried in the result.
    public var maxOutputCharacters: Int
    /// Wall-clock time for the source diffs; past it, changed sources show as whole replacements.
    public var timeLimit: Duration

    public init(maxInputBytes: Int = 64 * 1024 * 1024, maxCells: Int = 5_000, maxImageCharacters: Int = 4 * 1024 * 1024,
                maxOutputCharacters: Int = 20_000, timeLimit: Duration = .seconds(2)) {
        self.maxInputBytes = max(0, maxInputBytes); self.maxCells = max(1, maxCells)
        self.maxImageCharacters = max(0, maxImageCharacters); self.maxOutputCharacters = max(16, maxOutputCharacters)
        self.timeLimit = timeLimit
    }

    public static let `default` = NotebookCompareLimits()
}

/// Two Jupyter notebooks (nbformat 4) compared cell by cell (design/mockups/unified/diff.html, "Two notebooks: cell
/// diff"): cells matched by id when both notebooks have ids, otherwise by source; source and outputs compared
/// separately; execution counts and metadata-only changes hidden by default but counted. roadmap: S-7
public struct NotebookComparison: Sendable, Equatable, Codable {
    public enum CellKind: String, Sendable, Equatable, Codable { case code, markdown, raw }

    public enum CellStatus: String, Sendable, Equatable, Codable {
        case same, sourceChanged, outputChanged, both, added, removed
    }

    public enum RowKind: String, Sendable, Equatable, Codable { case context, added, deleted }

    /// A changed span inside a source row, in UTF-16 units (what JavaScript indexes by).
    public struct Highlight: Sendable, Equatable, Codable {
        public var start: Int
        public var length: Int
    }

    /// One source line as the cell's line diff draws it.
    public struct SourceRow: Sendable, Equatable, Codable {
        public var kind: RowKind
        public var oldNumber: Int?
        public var newNumber: Int?
        public var text: String
        public var highlights: [Highlight]
    }

    public enum OutputType: String, Sendable, Equatable, Codable { case text, stream, image, error, html, other }

    public enum OutputStatus: String, Sendable, Equatable, Codable { case same, changed, added, removed }

    /// One output of a cell, matched across the two versions.
    public struct Output: Sendable, Equatable, Codable {
        public var type: OutputType
        public var status: OutputStatus
        /// The MIME type shown ("image/png", "text/plain"), or the stream name ("stdout").
        public var mime: String?
        /// Text of a text, stream, error or HTML output (cut at the limit), or "image/png · 12 KB" for an image.
        public var old: String?
        public var new: String?
        /// Base64 of an image output, when within the limit.
        public var oldImage: String?
        public var newImage: String?
    }

    public struct Cell: Sendable, Equatable, Codable {
        /// 1-based position in the merged list (removed cells where they stood).
        public var index: Int
        public var kind: CellKind
        public var status: CellStatus
        public var oldExecutionCount: Int?
        public var newExecutionCount: Int?
        /// Hidden by default: the count moved while nothing else about the cell did, or along with it.
        public var executionCountChanged: Bool
        /// Hidden by default: the cell's metadata differs.
        public var metadataChanged: Bool
        public var rows: [SourceRow]
        public var outputs: [Output]
        /// "Output changed", "Output changed (image)"; nil when the outputs are the same.
        public var outputDescription: String?
    }

    /// One entry of the "what changed" list: "4 Code cell · Output changed (image)".
    public struct Item: Sendable, Equatable, Codable {
        /// The cell's `index`.
        public var index: Int
        /// "Code cell", "Markdown cell", "Raw cell".
        public var title: String
        /// "Source changed", "Output changed (image)", "Source and output changed", "Added", "Removed".
        public var detail: String
    }

    public struct Counts: Sendable, Equatable, Codable {
        public var cells: Int
        /// Cells whose status is not `same`.
        public var changed: Int
        public var sourceChanges: Int
        public var outputChanges: Int
        public var added: Int
        public var removed: Int
        /// Matched cells whose execution count differs.
        public var hiddenExecutionCounts: Int
        /// Matched cells whose metadata differs, plus 1 when the notebook's own metadata differs.
        public var hiddenMetadataChanges: Int
    }

    public var cells: [Cell]
    public var changes: [Item]
    public var counts: Counts
    /// "6 cells · 5 changed".
    public var lead: String
    /// "1 source change, 2 output changes, 1 cell added, 1 removed"; "No differences" when equal.
    public var summary: String
    /// "Execution counts and 1 metadata change hidden"; nil when nothing is hidden.
    public var hiddenNote: String?
    /// Cells were matched by their ids (nbformat 4.5) rather than by source.
    public var matchedByID: Bool
    /// Equal apart from what is hidden.
    public var isEqual: Bool
    public var isComplete: Bool
    public var incompleteReason: String?
}

/// The notebook compare engine. roadmap: S-7
public enum NotebookCompare {
    public static func compare(old: Data, new: Data, limits: NotebookCompareLimits = .default) throws -> NotebookComparison {
        let a = try NotebookReader.read(old, side: .old, limits: limits)
        let b = try NotebookReader.read(new, side: .new, limits: limits)
        var reasons: [String] = []
        if a.cut { reasons.append(String(localized: "the old notebook is compared through its first \(limits.maxCells.formatted()) cells", bundle: .module, comment: "Why a notebook compare is incomplete; lower-case, no final period.")) }
        if b.cut { reasons.append(String(localized: "the new notebook is compared through its first \(limits.maxCells.formatted()) cells", bundle: .module, comment: "Why a notebook compare is incomplete; lower-case, no final period.")) }

        let byID = !a.cells.isEmpty && !b.cells.isEmpty && (a.cells + b.cells).allSatisfy { $0.id != nil }
        let steps: [Alignment.Step]
        if byID {
            steps = Alignment.align(a.cells.map { $0.id ?? "" }, b.cells.map { $0.id ?? "" }, threshold: 2) { _, _ in 0 }
        } else {
            let oldTokens = a.cells.map { WordToken.tokenize($0.source) }, newTokens = b.cells.map { WordToken.tokenize($0.source) }
            steps = Alignment.align(a.cells.map { "\($0.kind.rawValue)\u{1}\($0.source)" },
                                    b.cells.map { "\($0.kind.rawValue)\u{1}\($0.source)" }, threshold: 0.5) { i, j in
                a.cells[i].kind == b.cells[j].kind ? WordToken.similarity(oldTokens[i], newTokens[j]) : 0
            }
        }

        let deadline = Deadline(limits.timeLimit)
        var simplified = false
        var cells: [NotebookComparison.Cell] = []
        var counts = NotebookComparison.Counts(cells: 0, changed: 0, sourceChanges: 0, outputChanges: 0, added: 0,
                                               removed: 0, hiddenExecutionCounts: 0, hiddenMetadataChanges: 0)
        for step in steps {
            let index = cells.count + 1
            switch step {
            case .deleted(let i):
                let c = a.cells[i]
                cells.append(.init(index: index, kind: c.kind, status: .removed, oldExecutionCount: c.executionCount,
                                   newExecutionCount: nil, executionCountChanged: false, metadataChanged: false,
                                   rows: rows(c.source, .deleted), outputs: c.outputs.map { output($0, nil, .removed, limits) },
                                   outputDescription: nil))
                counts.removed += 1
            case .inserted(let j):
                let c = b.cells[j]
                cells.append(.init(index: index, kind: c.kind, status: .added, oldExecutionCount: nil,
                                   newExecutionCount: c.executionCount, executionCountChanged: false, metadataChanged: false,
                                   rows: rows(c.source, .added), outputs: c.outputs.map { output(nil, $0, .added, limits) },
                                   outputDescription: nil))
                counts.added += 1
            case .equal(let i, let j), .paired(let i, let j):
                let o = a.cells[i], n = b.cells[j]
                let sourceChanged = o.source != n.source || o.kind != n.kind
                var sourceRows: [NotebookComparison.SourceRow]
                if !sourceChanged {
                    sourceRows = rows(n.source, .context)
                } else if deadline.passed {
                    simplified = true
                    sourceRows = rows(o.source, .deleted) + rows(n.source, .added)
                } else {
                    sourceRows = diffRows(o.source, n.source)
                }
                let outputs = compareOutputs(o.outputs, n.outputs, limits)
                let outputChanged = outputs.contains { $0.status != .same }
                let status: NotebookComparison.CellStatus = sourceChanged
                    ? (outputChanged ? .both : .sourceChanged) : (outputChanged ? .outputChanged : .same)
                let countChanged = o.executionCount != n.executionCount
                let metadataChanged = o.metadata != n.metadata
                if countChanged { counts.hiddenExecutionCounts += 1 }
                if metadataChanged { counts.hiddenMetadataChanges += 1 }
                if sourceChanged { counts.sourceChanges += 1 }
                if outputChanged { counts.outputChanges += 1 }
                var description: String?
                if outputChanged {
                    let first = outputs.first { $0.status != .same }?.type
                    switch first {
                    case .image?: description = String(localized: "Output changed (image)", bundle: .module, comment: "What changed in a notebook cell.")
                    case .error?: description = String(localized: "Output changed (error)", bundle: .module, comment: "What changed in a notebook cell.")
                    case .html?: description = String(localized: "Output changed (HTML)", bundle: .module, comment: "What changed in a notebook cell.")
                    default: description = String(localized: "Output changed", bundle: .module, comment: "What changed in a notebook cell.")
                    }
                }
                cells.append(.init(index: index, kind: n.kind, status: status, oldExecutionCount: o.executionCount,
                                   newExecutionCount: n.executionCount, executionCountChanged: countChanged,
                                   metadataChanged: metadataChanged, rows: sourceRows, outputs: outputs,
                                   outputDescription: description))
            }
        }
        if a.metadata != b.metadata { counts.hiddenMetadataChanges += 1 }
        if simplified { reasons.append(String(localized: "the time limit was reached; later changed sources show as whole replacements", bundle: .module, comment: "Why a notebook compare is incomplete; lower-case, no final period.")) }
        counts.cells = cells.count
        counts.changed = cells.filter { $0.status != .same }.count

        let changes: [NotebookComparison.Item] = cells.compactMap { cell in
            let title: String
            switch cell.kind {
            case .code: title = String(localized: "Code cell", bundle: .module, comment: "Kind of a notebook cell.")
            case .markdown: title = String(localized: "Markdown cell", bundle: .module, comment: "Kind of a notebook cell; Markdown is a format name.")
            case .raw: title = String(localized: "Raw cell", bundle: .module, comment: "Kind of a notebook cell.")
            }
            switch cell.status {
            case .same: return nil
            case .sourceChanged: return .init(index: cell.index, title: title, detail: String(localized: "Source changed", bundle: .module, comment: "What changed in a notebook cell."))
            case .outputChanged: return .init(index: cell.index, title: title, detail: cell.outputDescription ?? String(localized: "Output changed", bundle: .module, comment: "What changed in a notebook cell."))
            case .both: return .init(index: cell.index, title: title, detail: String(localized: "Source and output changed", bundle: .module, comment: "What changed in a notebook cell."))
            case .added: return .init(index: cell.index, title: title, detail: String(localized: "Added", bundle: .module, comment: "A notebook cell was added."))
            case .removed: return .init(index: cell.index, title: title, detail: String(localized: "Removed", bundle: .module, comment: "A notebook cell was removed."))
            }
        }

        var parts: [String] = []
        let s = counts.sourceChanges, o = counts.outputChanges, added = counts.added, removed = counts.removed
        if s > 0 { parts.append(s == 1 ? String(localized: "1 source change", bundle: .module, comment: "Notebook compare summary part.") : String(localized: "\(s) source changes", bundle: .module, comment: "Notebook compare summary part (not 1).")) }
        if o > 0 { parts.append(o == 1 ? String(localized: "1 output change", bundle: .module, comment: "Notebook compare summary part.") : String(localized: "\(o) output changes", bundle: .module, comment: "Notebook compare summary part (not 1).")) }
        if added > 0 { parts.append(added == 1 ? String(localized: "1 cell added", bundle: .module, comment: "Notebook compare summary part.") : String(localized: "\(added) cells added", bundle: .module, comment: "Notebook compare summary part (not 1).")) }
        if removed > 0 {
            parts.append(added > 0 ? String(localized: "\(removed) removed", bundle: .module, comment: "Notebook compare summary part after cells added: how many cells were removed.")
                : removed == 1 ? String(localized: "1 cell removed", bundle: .module, comment: "Notebook compare summary part.") : String(localized: "\(removed) cells removed", bundle: .module, comment: "Notebook compare summary part (not 1)."))
        }
        let m = counts.hiddenMetadataChanges
        let hiddenNote: String? = switch (counts.hiddenExecutionCounts > 0, m) {
        case (false, 0): nil
        case (true, 0): String(localized: "Execution counts hidden", bundle: .module, comment: "Notebook compare note: changed execution counts are not shown as changes.")
        case (false, 1): String(localized: "1 metadata change hidden", bundle: .module, comment: "Notebook compare note: a metadata change is not shown.")
        case (false, _): String(localized: "\(m) metadata changes hidden", bundle: .module, comment: "Notebook compare note: metadata changes are not shown (not 1).")
        case (true, 1): String(localized: "Execution counts and 1 metadata change hidden", bundle: .module, comment: "Notebook compare note.")
        case (true, _): String(localized: "Execution counts and \(m) metadata changes hidden", bundle: .module, comment: "Notebook compare note (not 1).")
        }
        let lead = counts.cells == 1 ? String(localized: "1 cell · \(counts.changed) changed", bundle: .module, comment: "Notebook compare lead: one cell, and how many changed.")
            : String(localized: "\(counts.cells) cells · \(counts.changed) changed", bundle: .module, comment: "Notebook compare lead: how many cells, and how many changed.")
        return NotebookComparison(cells: cells, changes: changes, counts: counts,
                                  lead: lead,
                                  summary: parts.isEmpty ? String(localized: "No differences", bundle: .module, comment: "Compare summary: the two files have no differences.") : parts.joined(separator: ", "),
                                  hiddenNote: hiddenNote,
                                  matchedByID: byID, isEqual: counts.changed == 0, isComplete: reasons.isEmpty,
                                  incompleteReason: reasons.isEmpty ? nil : reasons.joined(separator: "; "))
    }

    // MARK: Source

    private static func lines(_ source: String) -> [String] {
        guard !source.isEmpty else { return [] }
        var parts = source.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func rows(_ source: String, _ kind: NotebookComparison.RowKind) -> [NotebookComparison.SourceRow] {
        lines(source).enumerated().map { k, text in
            .init(kind: kind, oldNumber: kind == .added ? nil : k + 1, newNumber: kind == .deleted ? nil : k + 1,
                  text: text, highlights: [])
        }
    }

    /// The source line diff (TextCompare, whole cell in one hunk) with intra-line highlights.
    private static func diffRows(_ old: String, _ new: String) -> [NotebookComparison.SourceRow] {
        let result = TextCompare.compare(old: old, new: new, options: CompareOptions(contextLines: nil))
        var out: [NotebookComparison.SourceRow] = []
        for hunk in result.file.hunks {
            let base = out.count
            for line in hunk.lines {
                let kind: NotebookComparison.RowKind = switch line.kind {
                case .context: .context
                case .added: .added
                case .deleted: .deleted
                }
                out.append(.init(kind: kind, oldNumber: line.oldNumber, newNumber: line.newNumber, text: line.text, highlights: []))
            }
            for pair in Intraline.pairs(in: hunk) {
                out[base + pair.deleted].highlights = pair.oldRanges.map { .init(start: $0.lowerBound, length: $0.count) }
                out[base + pair.added].highlights = pair.newRanges.map { .init(start: $0.lowerBound, length: $0.count) }
            }
        }
        return out
    }

    // MARK: Outputs

    private static func compareOutputs(_ a: [NotebookReader.Output], _ b: [NotebookReader.Output],
                                       _ limits: NotebookCompareLimits) -> [NotebookComparison.Output] {
        let steps = Alignment.align(a.map(\.key), b.map(\.key), threshold: 1) { i, j in a[i].type == b[j].type ? 1 : 0 }
        return steps.map { step in
            switch step {
            case .equal(let i, let j): output(a[i], b[j], .same, limits)
            case .paired(let i, let j): output(a[i], b[j], .changed, limits)
            case .deleted(let i): output(a[i], nil, .removed, limits)
            case .inserted(let j): output(nil, b[j], .added, limits)
            }
        }
    }

    private static func output(_ o: NotebookReader.Output?, _ n: NotebookReader.Output?, _ status: NotebookComparison.OutputStatus,
                               _ limits: NotebookCompareLimits) -> NotebookComparison.Output {
        let any = (n ?? o)!
        func text(_ x: NotebookReader.Output?) -> String? {
            guard let x else { return nil }
            if x.type == .image { return "\(x.mime ?? "image") · " + ByteCountFormatter.string(fromByteCount: Int64(x.text.count * 3 / 4), countStyle: .file) }
            return CompareText.truncate(x.text, limits.maxOutputCharacters)
        }
        func image(_ x: NotebookReader.Output?) -> String? {
            guard let x, x.type == .image, x.text.count <= limits.maxImageCharacters else { return nil }
            return x.text
        }
        return .init(type: any.type, status: status, mime: any.mime, old: text(o), new: text(n), oldImage: image(o),
                     newImage: image(n))
    }
}

/// Reads an nbformat 4 notebook: the parts the compare needs (S-7) and, for the notebook preview (S-21), the kernel,
/// language, timings, attachments and every text form of each output. One reader serves both, so a notebook is read
/// the same way wherever it is shown. roadmap: S-7, S-21
public enum NotebookReader {
    public struct Output: Sendable {
        public var type: NotebookComparison.OutputType
        public var mime: String?
        /// The text, or the base64 of an image.
        public var text: String
        /// What two outputs must share to be the same: type, MIME and content (never the execution count).
        var key: String { "\(type.rawValue)\u{1}\(mime ?? "")\u{1}\(text)" }
        /// nbformat's own name: "execute_result", "display_data", "stream", "error".
        public var outputType: String = ""
        /// An error's name and value ("KeyError", "'regoin'") and its traceback lines as the kernel wrote them.
        public var errorName: String?
        public var errorValue: String?
        public var traceback: [String] = []
        /// Every text form in a rich output's bundle (text/plain, text/markdown, text/latex, text/html, and JSON types
        /// as JSON text), so the preview can choose; images are not repeated here.
        public var bundle: [String: String] = [:]
    }

    /// An image attached to a Markdown cell (`![](attachment:plot.png)`).
    public struct Attachment: Sendable {
        public var mime: String
        public var base64: String
    }

    public struct Cell: Sendable {
        public var kind: NotebookComparison.CellKind
        public var id: String?
        public var source: String
        public var executionCount: Int?
        /// Canonical JSON (sorted keys) of the cell's metadata.
        public var metadata: Data
        public var outputs: [Output]
        /// When the kernel took the cell and replied, when the notebook recorded them (`metadata.execution`, written
        /// by JupyterLab's record-timing setting).
        public var started: Date?
        public var finished: Date?
        public var attachments: [String: Attachment] = [:]

        public init(kind: NotebookComparison.CellKind, id: String? = nil, source: String, executionCount: Int? = nil,
                    metadata: Data = Data(), outputs: [Output] = [], started: Date? = nil, finished: Date? = nil,
                    attachments: [String: Attachment] = [:]) {
            self.kind = kind; self.id = id; self.source = source; self.executionCount = executionCount; self.metadata = metadata
            self.outputs = outputs; self.started = started; self.finished = finished; self.attachments = attachments
        }

        /// Seconds the cell ran, when both times are recorded.
        public var duration: Double? {
            guard let started, let finished, finished >= started else { return nil }
            return finished.timeIntervalSince(started)
        }
    }

    public struct Notebook: Sendable {
        public var cells: [Cell]
        public var metadata: Data
        /// More cells than the limit; `cells` holds the first `maxCells`.
        public var cut: Bool
        public var totalCells: Int = 0
        /// "4.5"; nil when the file does not say.
        public var format: String?
        /// The kernel's own name for itself ("Python 3 (ipykernel)") and its id ("python3").
        public var kernelDisplayName: String?
        public var kernelName: String?
        /// The language as the kernel reports it ("python", "3.12.4"); the kernelspec's language when there is no
        /// language_info.
        public var language: String?
        public var languageVersion: String?
        /// A title the notebook carries in its metadata.
        public var title: String?
    }

    public static func read(_ data: Data, side: CompareSide?, limits: NotebookCompareLimits = .default) throws -> Notebook {
        guard data.count <= limits.maxInputBytes else {
            throw CompareError(.tooLarge, side: side, reason: String(localized: "the notebook is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limits.maxInputBytes), countStyle: .file))", bundle: .module, comment: "A compare could not start: lower-case reason; the argument is a file size."))
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let message = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            let (line, column) = location(in: message)
            throw CompareError(.malformed, side: side, reason: String(localized: "not valid JSON: \(message)", bundle: .module, comment: "A compare could not start: lower-case reason; the argument is the JSON parser's message."), line: line, column: column)
        }
        guard let root = object as? [String: Any] else {
            throw CompareError(.malformed, side: side, reason: String(localized: "not a Jupyter notebook (the top level is not an object)", bundle: .module, comment: "A compare could not start: lower-case reason."))
        }
        if let format = root["nbformat"] as? Int, format < 4 {
            throw CompareError(.unsupported, side: side, reason: String(localized: "nbformat \(format) notebooks are not compared; nbformat 4 is", bundle: .module, comment: "A compare could not start: lower-case reason; nbformat is the notebook format version field and stays as is."))
        }
        guard let rawCells = root["cells"] as? [Any] else {
            throw CompareError(.malformed, side: side, reason: String(localized: "not a Jupyter notebook (no cells list)", bundle: .module, comment: "A compare could not start: lower-case reason."))
        }
        var cells: [Cell] = []
        for (k, raw) in rawCells.prefix(limits.maxCells).enumerated() {
            guard let cell = raw as? [String: Any] else {
                throw CompareError(.malformed, side: side, reason: String(localized: "cell \(k + 1) is not an object", bundle: .module, comment: "A compare could not start: lower-case reason; the argument is a 1-based cell number."))
            }
            let kind: NotebookComparison.CellKind = switch cell["cell_type"] as? String {
            case "code": .code
            case "markdown": .markdown
            default: .raw
            }
            let outputs = (cell["outputs"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).map(output) }
            let execution = (cell["metadata"] as? [String: Any])?["execution"] as? [String: Any]
            var attachments: [String: Attachment] = [:]
            for (name, value) in cell["attachments"] as? [String: Any] ?? [:] {
                guard let bundle = value as? [String: Any],
                      let mime = ["image/png", "image/jpeg", "image/gif", "image/webp"].first(where: { bundle[$0] != nil }) else { continue }
                attachments[name] = Attachment(mime: mime, base64: multiline(bundle[mime]).filter { !$0.isWhitespace })
            }
            cells.append(Cell(kind: kind, id: (cell["id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              source: multiline(cell["source"]), executionCount: cell["execution_count"] as? Int,
                              metadata: canonical(cell["metadata"]), outputs: outputs,
                              started: date(execution?["iopub.execute_input"]) ?? date(execution?["shell.execute_request"]),
                              finished: date(execution?["shell.execute_reply"]) ?? date(execution?["iopub.status.idle"]),
                              attachments: attachments))
        }
        let meta = root["metadata"] as? [String: Any] ?? [:]
        let kernel = meta["kernelspec"] as? [String: Any], info = meta["language_info"] as? [String: Any]
        func text(_ v: Any?) -> String? { (v as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let format = (root["nbformat"] as? Int).map { major in "\(major)" + ((root["nbformat_minor"] as? Int).map { ".\($0)" } ?? "") }
        return Notebook(cells: cells, metadata: canonical(root["metadata"]), cut: rawCells.count > limits.maxCells,
                        totalCells: rawCells.count, format: format, kernelDisplayName: text(kernel?["display_name"]),
                        kernelName: text(kernel?["name"]), language: text(info?["name"]) ?? text(kernel?["language"]),
                        languageVersion: text(info?["version"]), title: text(meta["title"]))
    }

    /// An ISO 8601 time as Jupyter writes them ("2026-10-12T14:05:09.118Z", fraction optional).
    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// nbformat writes text as a string or as a list of lines.
    static func multiline(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let list = value as? [Any] { return list.compactMap { $0 as? String }.joined() }
        return ""
    }

    static func canonical(_ value: Any?) -> Data {
        guard let value, JSONSerialization.isValidJSONObject(value) else { return Data() }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
    }

    static func output(_ o: [String: Any]) -> Output {
        var out = chosen(o)
        out.outputType = o["output_type"] as? String ?? ""
        if out.type == .error {
            out.errorName = o["ename"] as? String ?? "Error"
            out.errorValue = o["evalue"] as? String ?? ""
            out.traceback = (o["traceback"] as? [Any] ?? []).compactMap { $0 as? String }
        }
        for (mime, value) in o["data"] as? [String: Any] ?? [:] where !mime.hasPrefix("image/") {
            out.bundle[mime] = mime.hasSuffix("json") ? String(decoding: canonical(value), as: UTF8.self) : multiline(value)
        }
        return out
    }

    /// The one form the compare looks at: an image, else HTML, else plain text, else the first other type.
    private static func chosen(_ o: [String: Any]) -> Output {
        switch o["output_type"] as? String {
        case "stream":
            return Output(type: .stream, mime: o["name"] as? String, text: multiline(o["text"]))
        case "error":
            let name = o["ename"] as? String ?? "Error", value = o["evalue"] as? String ?? ""
            let trace = (o["traceback"] as? [Any] ?? []).compactMap { $0 as? String }.joined(separator: "\n")
            return Output(type: .error, mime: name, text: value.isEmpty ? name : "\(name): \(value)" + (trace.isEmpty ? "" : "\n" + trace))
        default:
            let bundle = o["data"] as? [String: Any] ?? [:]
            for mime in ["image/png", "image/jpeg", "image/gif", "image/webp"] where bundle[mime] != nil {
                let base64 = multiline(bundle[mime]).filter { !$0.isWhitespace }
                return Output(type: .image, mime: mime, text: base64)
            }
            if bundle["image/svg+xml"] != nil {
                let svg = multiline(bundle["image/svg+xml"])
                return Output(type: .image, mime: "image/svg+xml", text: Data(svg.utf8).base64EncodedString())
            }
            if bundle["text/html"] != nil { return Output(type: .html, mime: "text/html", text: multiline(bundle["text/html"])) }
            if bundle["text/plain"] != nil { return Output(type: .text, mime: "text/plain", text: multiline(bundle["text/plain"])) }
            if let mime = bundle.keys.sorted().first {
                let value = bundle[mime]
                let text = (value as? String) ?? String(decoding: canonical(value), as: UTF8.self)
                return Output(type: .other, mime: mime, text: text)
            }
            return Output(type: .other, mime: nil, text: "")
        }
    }

    /// "… around line 4, column 9." in Foundation's JSON error text.
    static func location(in message: String) -> (Int?, Int?) {
        guard let match = message.firstMatch(of: /line (\d+), column (\d+)/) else { return (nil, nil) }
        return (Int(match.1), Int(match.2))
    }
}
