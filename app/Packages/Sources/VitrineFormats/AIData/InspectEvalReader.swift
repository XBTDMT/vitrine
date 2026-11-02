import Foundation
import VitrineArchive

/// An Inspect evaluation log (A-11): the `.eval` zip (`header.json`, `summaries.json`, `samples/…`, or only
/// `_journal/` while a run is going) or the older single JSON log. Task, model, dataset, sample counts, scores with
/// their metrics, token use, the run's status and a table of samples. roadmap: S-21
public struct InspectEvalSummary: Sendable, Equatable {
    /// How the log is stored. roadmap: S-21
    public enum Container: String, Sendable, Equatable {
        /// The `.eval` zip.
        case evalZip
        /// One JSON document.
        case json
    }

    /// One scorer's result. roadmap: S-21
    public struct Score: Sendable, Equatable {
        public var name: String
        public var scorer: String?
        /// Metric name → value (accuracy, stderr, mean …), in file order.
        public var metrics: [Metric]

        public init(name: String, scorer: String?, metrics: [Metric]) {
            self.name = name
            self.scorer = scorer
            self.metrics = metrics
        }
    }

    /// One metric of a score. roadmap: S-21
    public struct Metric: Sendable, Equatable {
        public var name: String
        public var value: Double

        public init(name: String, value: Double) {
            self.name = name
            self.value = value
        }
    }

    /// Tokens one model used. roadmap: S-21
    public struct Usage: Sendable, Equatable {
        public var model: String
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var totalTokens: Int?

        public init(model: String, inputTokens: Int?, outputTokens: Int?, totalTokens: Int?) {
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.totalTokens = totalTokens
        }
    }

    public var container: Container
    public var headline: String
    public var task: String?
    public var model: String?
    public var dataset: String?
    /// Samples the run planned (the dataset's count, else the results' total, else the sample members).
    public var sampleCount: Int?
    public var completedSamples: Int?
    /// started, success, cancelled or error, as the log states it.
    public var status: String?
    public var created: Date?
    public var started: Date?
    public var completed: Date?
    /// The run's error message, first line, when it failed.
    public var errorMessage: String?
    public var scores: [Score]
    public var usage: [Usage]
    /// ID, epoch, input, target, one column per scorer, and error, for the first `AIDataTable.maxRows` samples.
    public var samples: AIDataTable
    public var facts: [AIDataFact]
    public var warnings: [AIDataWarning]

    public init(container: Container, headline: String, task: String?, model: String?, dataset: String?,
                sampleCount: Int?, completedSamples: Int?, status: String?, created: Date?, started: Date?,
                completed: Date?, errorMessage: String?, scores: [Score], usage: [Usage], samples: AIDataTable,
                facts: [AIDataFact], warnings: [AIDataWarning]) {
        self.container = container
        self.headline = headline
        self.task = task
        self.model = model
        self.dataset = dataset
        self.sampleCount = sampleCount
        self.completedSamples = completedSamples
        self.status = status
        self.created = created
        self.started = started
        self.completed = completed
        self.errorMessage = errorMessage
        self.scores = scores
        self.usage = usage
        self.samples = samples
        self.facts = facts
        self.warnings = warnings
    }
}

enum AIInspectReader {
    static let memberLimit = 16 * 1024 * 1024
    static let maxScoreColumns = 8

    static func readZip(_ bytes: [UInt8], listing: ArchiveListing, context: AIReadContext) -> InspectEvalSummary? {
        var warnings: [AIDataWarning] = []
        var partial = context.wasCut
        func json(_ path: String) -> AIJSON? {
            guard let member = AIZip.member(bytes, listing: listing, path: path, limit: memberLimit) else { return nil }
            if !member.isComplete { partial = true }
            guard case .success(let parsed) = AIJSONParser.parseDocument(member.bytes, limits: .document) else {
                warnings.append(AIDataWarning(.caution, String(localized: "\(path) inside the log is not valid JSON.", bundle: .module, comment: "Inspect eval warning. The argument is a member path such as header.json.")))
                return nil
            }
            if parsed.budgetHit { partial = true }
            return parsed.value
        }
        let header = json("header.json") ?? json("_journal/start.json")
        var sampleRows = json("summaries.json")?.array ?? []
        if sampleRows.isEmpty {
            // While a run is going, sample summaries are written in numbered journal files.
            let journal = listing.entries.filter { $0.path.hasPrefix("_journal/summaries/") && !$0.isDirectory }
            for entry in journal.prefix(50) {
                sampleRows += json(entry.path)?.array ?? []
                if sampleRows.count >= AIDataTable.maxRows { break }
            }
        }
        let sampleMembers = listing.entries.filter { $0.path.hasPrefix("samples/") && $0.path.hasSuffix(".json") }.count
        if header == nil {
            warnings.append(AIDataWarning(.caution, String(localized: "The log has no header.json (or journal start), so the task, model and scores are unknown.", bundle: .module, comment: "Inspect eval warning; header.json is a file name, keep it as is.")))
        }
        if partial { warnings.append(context.readCapWarning) }
        return summary(header: header ?? .object([]), samples: sampleRows, sampleMembers: sampleMembers,
                       container: .evalZip, extraWarnings: warnings)
    }

    /// The JSON log: an object with `eval` naming a task and a model.
    static func readJSONLog(_ root: AIJSON, budgetHit: Bool, context: AIReadContext) -> InspectEvalSummary? {
        guard let eval = root["eval"], eval["task"]?.string != nil, eval["model"] != nil else { return nil }
        let warnings = budgetHit || context.wasCut ? [context.readCapWarning] : []
        return summary(header: root, samples: root["samples"]?.array ?? [], sampleMembers: 0, container: .json,
                       extraWarnings: warnings)
    }

    private static func summary(header: AIJSON, samples: [AIJSON], sampleMembers: Int, container: InspectEvalSummary.Container,
                                extraWarnings: [AIDataWarning]) -> InspectEvalSummary {
        let eval = header["eval"]
        let results = header["results"]
        let task = eval?["task"]?.text
        let model = eval?["model"]?.text
        let dataset = eval?.at("dataset", "name")?.text ?? eval?.at("dataset", "location")?.text
        let planned = eval?.at("dataset", "samples")?.int ?? results?["total_samples"]?.int
            ?? (sampleMembers > 0 ? sampleMembers : (samples.isEmpty ? nil : samples.count))
        let completed = results?["completed_samples"]?.int
        let status = header["status"]?.text

        var scores: [InspectEvalSummary.Score] = []
        func metrics(_ value: AIJSON?) -> [InspectEvalSummary.Metric] {
            (value?.members ?? []).prefix(50).compactMap { member in
                let v = member.value["value"]?.double ?? member.value.double
                return v.map { InspectEvalSummary.Metric(name: member.value["name"]?.text ?? member.key, value: $0) }
            }
        }
        for score in (results?["scores"]?.array ?? []).prefix(50) {
            scores.append(InspectEvalSummary.Score(name: score["name"]?.text ?? score["scorer"]?.text ?? "score",
                                                   scorer: score["scorer"]?.text, metrics: metrics(score["metrics"])))
        }
        if scores.isEmpty, let legacy = results?["metrics"], legacy.isObject {
            scores.append(InspectEvalSummary.Score(name: "score", scorer: nil, metrics: metrics(legacy)))
        }
        var usage: [InspectEvalSummary.Usage] = []
        for member in (header.at("stats", "model_usage")?.members ?? []).prefix(20) {
            usage.append(InspectEvalSummary.Usage(model: member.key, inputTokens: member.value["input_tokens"]?.int,
                                                  outputTokens: member.value["output_tokens"]?.int,
                                                  totalTokens: member.value["total_tokens"]?.int))
        }
        let errorMessage = (header.at("error", "message")?.text ?? header["error"]?.text)
            .map { AIText.cap($0.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? $0, 300) }
        let created = AIDates.date(eval?["created"])
        let started = AIDates.date(header.at("stats", "started_at"))
        let ended = AIDates.date(header.at("stats", "completed_at"))

        // Sample rows.
        var scorerNames: [String] = []
        for sample in samples.prefix(AIDataTable.maxRows) {
            for member in sample["scores"]?.members ?? [] where !scorerNames.contains(member.key) && scorerNames.count < maxScoreColumns {
                scorerNames.append(member.key)
            }
        }
        let hasErrors = samples.prefix(AIDataTable.maxRows).contains { $0["error"]?.text != nil }
        var columns = [String(localized: "ID", bundle: .module, comment: "Table column: a sample's id."),
                       String(localized: "Epoch", bundle: .module, comment: "Table column: an eval sample's epoch number."),
                       String(localized: "Input", bundle: .module, comment: "Table column."),
                       String(localized: "Target", bundle: .module, comment: "Table column: the expected answer.")] + scorerNames
        if hasErrors { columns.append(String(localized: "Error", bundle: .module, comment: "Table column.")) }
        let rows: [[String]] = samples.prefix(AIDataTable.maxRows).map { s in
            var row = [s["id"]?.display() ?? "", s["epoch"]?.display() ?? "", AIText.cap(inputText(s["input"])),
                       AIText.cap(targetText(s["target"]))]
            for name in scorerNames {
                let score = s.at("scores", name)
                row.append(score.map { ($0["value"] ?? $0).display() } ?? "")
            }
            if hasErrors { row.append(AIText.cap(s["error"]?.text ?? s.at("error", "message")?.text ?? "")) }
            return row
        }

        var facts: [AIDataFact] = []
        if let task { facts.append(AIDataFact(String(localized: "Task", bundle: .module, comment: "Fact label: an eval's task."), task)) }
        if let model { facts.append(AIDataFact(String(localized: "Model", bundle: .module, comment: "Fact label."), model)) }
        if let dataset { facts.append(AIDataFact(String(localized: "Dataset", bundle: .module, comment: "Fact label."), dataset)) }
        if let planned {
            let value = completed.map { done in String(localized: "\(done) of \(planned)", bundle: .module, comment: "A part of a whole: completed samples of planned samples.") } ?? planned.formatted()
            facts.append(AIDataFact(String(localized: "Samples", bundle: .module, comment: "Fact label: eval samples."), value))
        }
        if let status { facts.append(AIDataFact(String(localized: "Status", bundle: .module, comment: "Fact label: an eval run's status."), status)) }
        for score in scores.prefix(6) {
            let shown = score.metrics.prefix(4).map { "\($0.name) \(AIText.number($0.value))" }.joined(separator: ", ")
            if !shown.isEmpty { facts.append(AIDataFact(score.name, shown)) }
        }
        for u in usage.prefix(3) {
            if let total = u.totalTokens ?? (u.inputTokens.map { FormatMath.saturatingAdd($0, u.outputTokens ?? 0) }) {
                let modelName = u.model
                facts.append(AIDataFact(String(localized: "Tokens (\(modelName))", bundle: .module, comment: "Fact label: tokens one model used. The argument is the model name."), total.formatted()))
            }
        }
        if let started, let ended, ended >= started {
            facts.append(AIDataFact(String(localized: "Duration", bundle: .module, comment: "Fact label."), AIText.milliseconds(ended.timeIntervalSince(started) * 1000)))
        }

        var warnings: [AIDataWarning] = []
        switch status {
        case "error":
            if let errorMessage {
                warnings.append(AIDataWarning(.caution, String(localized: "The run stopped with an error: \(errorMessage)", bundle: .module, comment: "Inspect eval warning. The argument is the error message from the log.")))
            } else {
                warnings.append(AIDataWarning(.caution, String(localized: "The run stopped with an error.", bundle: .module, comment: "Inspect eval warning.")))
            }
        case "cancelled": warnings.append(AIDataWarning(.caution, String(localized: "The run was cancelled before it finished; results cover the samples it completed.", bundle: .module, comment: "Inspect eval warning.")))
        case "started": warnings.append(AIDataWarning(.caution, String(localized: "The run had not finished when this log was written; scores may be missing.", bundle: .module, comment: "Inspect eval warning.")))
        default: break
        }
        warnings += extraWarnings

        var headline = String(localized: "Inspect eval", bundle: .module, comment: "Headline for an Inspect evaluation log; Inspect is a product name.")
        if let task { headline += " · \(task)" }
        if let model { headline += " · \(model)" }
        return InspectEvalSummary(
            container: container, headline: headline, task: task, model: model, dataset: dataset,
            sampleCount: planned, completedSamples: completed, status: status, created: created, started: started,
            completed: ended, errorMessage: errorMessage, scores: scores, usage: usage,
            samples: AIDataTable(columns: columns, rows: rows, totalRows: samples.count,
                                 isTruncated: samples.count > rows.count),
            facts: facts, warnings: warnings)
    }

    /// A sample's input: a string, or a list of chat messages (the last user message's text).
    static func inputText(_ input: AIJSON?) -> String {
        guard let input else { return "" }
        if let s = input.string { return s }
        if let messages = input.array {
            let chosen = messages.last { $0["role"]?.string == "user" } ?? messages.last
            if let chosen { return messageText(chosen) }
        }
        return input.display()
    }

    static func targetText(_ target: AIJSON?) -> String {
        guard let target else { return "" }
        if let s = target.string { return s }
        if let list = target.array, list.allSatisfy({ $0.string != nil }) { return list.compactMap(\.string).joined(separator: " | ") }
        return target.display()
    }

    private static func messageText(_ message: AIJSON) -> String {
        if let s = message["content"]?.string { return s }
        if let parts = message["content"]?.array {
            return parts.compactMap { $0["text"]?.string }.joined(separator: "\n")
        }
        return message.display()
    }
}
