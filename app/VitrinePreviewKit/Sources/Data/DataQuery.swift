import AppKit
import ObjectiveC
import VitrineData

/// The read-only query box in a data preview (I-8, G-13; data 1: the capsule's find switches from Filter to SQL).
/// Return runs the SELECT off the main thread on a query connection of its own (`SQLiteQueryEngine`: read-only,
/// authorizer, one statement, time budget, capped rows); the result's rows cover the file's in the same native grid
/// and Inspector (a second `DataView` on a `QueryResultModel`), and the gutter reads "8 rows · 41 ms". A CSV/TSV is
/// copied into an in-memory database on the first run, named after the file and `t`, with its progress in the gutter.
/// Cancel (the gutter's, or esc) stops the run; an error is a calm line in the gutter and the grid stays as it was;
/// Done or Escape in the field shows the file's own rows again. roadmap: S-6
@MainActor
final class DataQueryController {
    enum Source {
        case sqlite(URL)
        case csv(DataModel)
        /// A Parquet, Arrow or sheet table, copied into memory on the first run (B-4).
        case columnar(ColumnarDataModel)
    }

    private weak var view: DataView?
    private weak var preview: RenderedPreview?
    let source: Source
    /// "orders.csv", "acme-notes.sqlite"; a workbook's picked sheet.
    private(set) var fileName: String
    /// The sheet the engine copied (a workbook queries the sheet in view).
    private var engineSheet: Int?
    /// Bounds for the engine; read when it is first made.
    var limits = SQLiteQueryLimits()
    private var engine: SQLiteQueryEngine?
    /// The result's rows, over the file's; nil shows the file's own rows.
    private(set) var resultView: DataView?
    private(set) var resultModel: QueryResultModel?
    private(set) var running = false
    private var flag: CancelFlag?
    private var generation = 0
    /// The file view's own gutter line, passed through while no query owns the gutter.
    private var fileGutter: ((GutterStatus?) -> Void)?
    /// What the query shows in the gutter (running, the result, an error); nil gives the gutter back to the file.
    private(set) var queryGutter: GutterStatus?

    private init(view: DataView, preview: RenderedPreview, source: Source, fileName: String) {
        self.view = view; self.preview = preview; self.source = source; self.fileName = fileName
    }

    /// Adds the Query mode to a data preview: SQLite files and CSV/TSV; any other model is left as it is.
    static func install(on preview: RenderedPreview, view: DataView) {
        let source: Source
        let fileName: String
        let placeholder: String
        if let csv = view.model as? DataModel {
            source = .csv(csv)
            fileName = csv.table.url.lastPathComponent
            let name = SQLiteQueryEngine.tableName(for: fileName)
            placeholder = "SELECT * FROM \(SQLiteQueryEngine.isPlainName(name) ? name : "t")"
        } else if let sqlite = view.model as? SQLiteDataModel {
            source = .sqlite(sqlite.db.url)
            fileName = sqlite.db.url.lastPathComponent
            let table = sqlite.current?.name
            placeholder = table.map { "SELECT * FROM \(SQLiteQueryEngine.isPlainName($0) ? $0 : SQLiteDatabase.quote($0))" }
                ?? "SELECT name FROM sqlite_master"
        } else if let columnar = view.model as? ColumnarDataModel {
            source = .columnar(columnar)
            fileName = columnar.format == .xlsx ? columnar.dataset.parts[columnar.selected].name : columnar.url.lastPathComponent
            let name = SQLiteQueryEngine.tableName(for: columnar.format == .xlsx ? fileName + ".sheet" : fileName)
            placeholder = "SELECT * FROM \(SQLiteQueryEngine.isPlainName(name) ? name : "t")"
        } else {
            return
        }
        let controller = DataQueryController(view: view, preview: preview, source: source, fileName: fileName)
        view.queryController = controller
        controller.fileGutter = view.onGutter
        view.onGutter = { [weak controller] status in controller?.fileGutterChanged(status) }
        let fileCancel = preview.cancelWork
        preview.cancelWork = { [weak controller] in
            if controller?.cancelIfBusy() != true { fileCancel?() }
        }
        preview.findModes = [preview.findStyle, .query]
        preview.query = { [weak controller] sql in
            await controller?.run(sql) ?? .failed(String(localized: "This preview cannot run queries.", bundle: .previewKit, comment: "Error when SQL is asked of a preview that has no query engine."))
        }
        preview.clearQuery = { [weak controller] in controller?.clear() }
        preview.queryPlaceholder = placeholder
    }

    // MARK: Running

    /// Runs one read-only query; a newer run or `clear` supersedes it, Cancel stops it.
    func run(_ sql: String) async -> QueryOutcome {
        flag?.cancel()
        generation += 1
        let generation = self.generation
        let flag = CancelFlag()
        self.flag = flag
        running = true
        show(GutterStatus(leading: resultModel?.outcome.summary,
                          trailing: String(localized: "Running query…", bundle: .previewKit, comment: "Status line while a SQL query runs."), busy: true))
        do {
            let engine = try await engine(flag: flag, generation: generation)
            let result = try await Task.detached(priority: .userInitiated) {
                try engine.run(sql, isCancelled: { flag.isCancelled })
            }.value
            guard generation == self.generation else { return .failed(SQLiteQueryError.cancelled.localizedDescription) }
            running = false
            let model = QueryResultModel(sql: sql, result: result, source: sourceLabel)
            showResult(model)
            let outcome = model.outcome
            show(GutterStatus(leading: outcome.summary, trailing: Self.readOnly))
            return outcome
        } catch {
            guard generation == self.generation else { return .failed(SQLiteQueryError.cancelled.localizedDescription) }
            running = false
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // A calm line; whatever the grid showed (the file's rows or the last result) stays.
            show(GutterStatus(leading: message, trailing: String(localized: "Read-only", bundle: .previewKit, comment: "Status line: the file is opened read-only (after a query error).")))
            return .failed(message)
        }
    }

    static let readOnly = String(localized: "Read-only · the file is never written", bundle: .previewKit, comment: "Status line beside a query result: queries only read the file.")

    /// The connection to query: the file's own (read-only) for SQLite, the in-memory copy for CSV, made on first use.
    private func engine(flag: CancelFlag, generation: Int) async throws -> SQLiteQueryEngine {
        if case .columnar(let model) = source, model.format == .xlsx, engineSheet != model.selected {
            engine = nil
            engineSheet = model.selected
            fileName = model.dataset.parts[model.selected].name
        }
        if let engine { return engine }
        let limits = self.limits
        let made: SQLiteQueryEngine
        switch source {
        case .sqlite(let url):
            made = try await Task.detached(priority: .userInitiated) { try SQLiteQueryEngine.open(url, limits: limits) }.value
        case .csv(let model):
            let table = model.table, index = model.index, types = model.types, name = fileName
            guard table.fileSize <= limits.csvMaxBytes else {
                throw SQLiteQueryError.tooLarge(fileBytes: table.fileSize, limit: limits.csvMaxBytes)
            }
            show(GutterStatus(trailing: Self.loadingText(name), busy: true))
            made = try await Task.detached(priority: .userInitiated) {
                try await SQLiteQueryEngine.csv(table, index: index, types: types, name: name, limits: limits,
                                                isCancelled: { flag.isCancelled },
                                                progress: { fraction in
                                                    Task { @MainActor [weak self] in self?.loading(fraction, generation: generation) }
                                                })
            }.value
        case .columnar(let model):
            guard let table = model.table else {
                throw SQLiteQueryError.failed(String(localized: "This part has no rows to query.", bundle: .previewKit, comment: "Query error: the picked sheet or part has no table to query."))
            }
            let name = model.format == .xlsx ? fileName + ".sheet" : fileName
            show(GutterStatus(trailing: Self.loadingText(fileName), busy: true))
            made = try await Task.detached(priority: .userInitiated) {
                try SQLiteQueryEngine.columnar(table, name: name, limits: limits, isCancelled: { flag.isCancelled },
                                               progress: { fraction in
                                                   Task { @MainActor [weak self] in self?.loading(fraction, generation: generation) }
                                               })
            }.value
        }
        engine = made
        return made
    }

    private func loading(_ fraction: Double, generation: Int) {
        guard generation == self.generation, running, fraction < 1 else { return }
        let name = fileName, percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        show(GutterStatus(trailing: String(localized: "Loading \(name) for SQL… \(percent)", bundle: .previewKit, comment: "Status line while a file is copied into memory for SQL. Arguments: file name, formatted percentage."), busy: true))
    }

    /// "Loading orders.csv for SQL…"
    private static func loadingText(_ name: String) -> String {
        String(localized: "Loading \(name) for SQL…", bundle: .previewKit, comment: "Status line while a file is copied into memory for SQL; the argument is the file name.")
    }

    /// "orders = this file, copied read-only into memory"; the SQLite file's name.
    private var sourceLabel: String {
        switch source {
        case .sqlite: return fileName
        case .csv:
            let name = SQLiteQueryEngine.tableName(for: fileName), file = fileName
            return Self.copiedText(table: name, file: file)
        case .columnar(let model):
            let name = SQLiteQueryEngine.tableName(for: model.format == .xlsx ? fileName + ".sheet" : fileName)
            return Self.copiedText(table: name, file: fileName)
        }
    }

    /// "orders (and t) = orders.csv, copied into memory": the SQL table names and the file they hold.
    private static func copiedText(table: String, file: String) -> String {
        String(localized: "\(table) (and t) = \(file), copied into memory", bundle: .previewKit, comment: "Inspector fact: the SQL table names (the first argument, and the short name t) hold a copy of the file (second argument). Keep “t” as is.")
    }

    // MARK: The result over the file's rows

    private func showResult(_ model: QueryResultModel) {
        guard let view else { return }
        resultView?.removeFromSuperview()
        let result = DataView(model: model)
        result.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(result)
        NSLayoutConstraint.activate([
            result.topAnchor.constraint(equalTo: view.topAnchor), result.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            result.leadingAnchor.constraint(equalTo: view.leadingAnchor), result.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        // A sort of the result says so on the gutter's right, beside the result's count.
        result.onGutter = { [weak self] status in self?.resultGutterChanged(status) }
        resultView = result
        resultModel = model
        result.tableName = "result"
        view.overlay = result
    }

    private func resultGutterChanged(_ status: GutterStatus?) {
        guard let model = resultModel, !running else { return }
        show(GutterStatus(leading: model.outcome.summary, trailing: status?.trailing ?? Self.readOnly, busy: status?.busy ?? false))
    }

    /// Done or Escape: stops a run and shows the file's own rows and gutter again.
    func clear() {
        generation += 1
        flag?.cancel()
        flag = nil
        running = false
        view?.overlay = nil
        resultView?.removeFromSuperview()
        resultView = nil
        resultModel = nil
        guard queryGutter != nil else { return }
        queryGutter = nil
        view?.updateGutter()
    }

    /// The gutter's Cancel while a query (or a sort of its result) runs; false when nothing of the query's is busy.
    func cancelIfBusy() -> Bool {
        if running { flag?.cancel(); return true }
        if let result = resultView, result.busy != nil { result.cancel(); return true }
        return false
    }

    // MARK: Gutter

    private func show(_ status: GutterStatus) {
        queryGutter = status
        preview?.updateGutter(status)
    }

    private func fileGutterChanged(_ status: GutterStatus?) {
        guard queryGutter == nil else { return }
        fileGutter?(status)
    }
}

/// The key the controller hangs on its data view by.
nonisolated(unsafe) private var queryControllerKey: UInt8 = 0

extension DataView {
    /// The view's Query mode (I-8); the view keeps it alive. roadmap: S-6
    var queryController: DataQueryController? {
        get { objc_getAssociatedObject(self, &queryControllerKey) as? DataQueryController }
        set { objc_setAssociatedObject(self, &queryControllerKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
