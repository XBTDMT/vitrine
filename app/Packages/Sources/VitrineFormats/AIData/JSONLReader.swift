import Foundation

/// A JSON Lines / NDJSON file (A-5): how many records, which lines are broken, the inferred schema, the known shape
/// it follows (batch files, fine-tuning sets, eval results) and a table of its first records. roadmap: S-21
public struct JSONLSummary: Sendable, Equatable {
    /// The layout the records follow, recognised from their keys. roadmap: S-21
    public enum Shape: String, Sendable, Equatable, CaseIterable {
        /// OpenAI Batch API input: `custom_id`, `method`, `url`, `body`.
        case openAIBatchInput
        /// OpenAI Batch API output: `custom_id` with `response` or `error`.
        case openAIBatchOutput
        /// OpenAI chat fine-tuning examples: a `messages` array of role and content.
        case openAIFineTuningChat
        /// Anthropic Message Batches requests: `custom_id` and `params`.
        case anthropicBatchRequests
        /// Anthropic Message Batches results: `custom_id` and a typed `result`.
        case anthropicBatchResults
        /// Evaluation records: input, expected, output and score fields (any two of those families, one of them
        /// expected or score).
        case evaluationResults
        /// A Claude Code session transcript (`type` user/assistant with `message` and `sessionId`); it has its own
        /// preview elsewhere, so the main session can route it there.
        case claudeCodeSession
        /// Records of no known shape.
        case generic

        /// The shape's name as a card shows it.
        public var title: String {
            switch self {
            case .openAIBatchInput: String(localized: "OpenAI batch input", bundle: .module, comment: "JSONL shape name.")
            case .openAIBatchOutput: String(localized: "OpenAI batch output", bundle: .module, comment: "JSONL shape name.")
            case .openAIFineTuningChat: String(localized: "OpenAI fine-tuning (chat)", bundle: .module, comment: "JSONL shape name.")
            case .anthropicBatchRequests: String(localized: "Anthropic Message Batches requests", bundle: .module, comment: "JSONL shape name.")
            case .anthropicBatchResults: String(localized: "Anthropic Message Batches results", bundle: .module, comment: "JSONL shape name.")
            case .evaluationResults: String(localized: "Evaluation results", bundle: .module, comment: "JSONL shape name.")
            case .claudeCodeSession: String(localized: "Claude Code session", bundle: .module, comment: "JSONL shape name.")
            case .generic: String(localized: "JSON Lines", bundle: .module, comment: "JSONL shape name for records of no known shape.")
            }
        }
    }

    /// One field of the inferred schema. roadmap: S-21
    public struct Field: Sendable, Equatable {
        /// A top-level key, or `parent.child` one level into an object.
        public var path: String
        /// Every JSON kind seen at this path, in `AIJSONType` order.
        public var types: [AIJSONType]
        /// Sampled records that have this path.
        public var presentCount: Int
        /// `presentCount` over the sampled object records, 0…1.
        public var presence: Double

        public init(path: String, types: [AIJSONType], presentCount: Int, presence: Double) {
            self.path = path
            self.types = types
            self.presentCount = presentCount
            self.presence = presence
        }
    }

    public var headline: String
    public var shape: Shape
    /// Non-blank lines: exact when `recordCountIsExact`, otherwise estimated from the bytes read.
    public var recordCount: Int
    public var recordCountIsExact: Bool
    public var blankLines: Int
    /// 1-based line numbers of lines that are not valid JSON, at most `JSONLSummary.maxListedLines`.
    public var malformedLines: [Int]
    /// Every malformed line within the bytes read, listed or not.
    public var malformedCount: Int
    /// Valid JSON lines that are not objects (a bare number, an array); the table and schema skip them.
    public var nonObjectCount: Int
    /// Object records the schema, shape and facts were computed from (all of them up to `maxSampled`).
    public var sampledRecords: Int
    public var fields: [Field]
    /// More distinct paths existed than `maxFields`.
    public var fieldsTruncated: Bool
    /// Columns are the flattened fields (objects one level deep as `a.b`); rows are the first records.
    public var table: AIDataTable
    public var facts: [AIDataFact]
    public var warnings: [AIDataWarning]

    public static let maxListedLines = 100
    public static let maxSampled = 50_000
    public static let maxFields = 300
    public static let maxColumns = 100

    public init(headline: String, shape: Shape, recordCount: Int, recordCountIsExact: Bool, blankLines: Int,
                malformedLines: [Int], malformedCount: Int, nonObjectCount: Int, sampledRecords: Int, fields: [Field],
                fieldsTruncated: Bool, table: AIDataTable, facts: [AIDataFact], warnings: [AIDataWarning]) {
        self.headline = headline
        self.shape = shape
        self.recordCount = recordCount
        self.recordCountIsExact = recordCountIsExact
        self.blankLines = blankLines
        self.malformedLines = malformedLines
        self.malformedCount = malformedCount
        self.nonObjectCount = nonObjectCount
        self.sampledRecords = sampledRecords
        self.fields = fields
        self.fieldsTruncated = fieldsTruncated
        self.table = table
        self.facts = facts
        self.warnings = warnings
    }
}

enum AIJSONLReader {
    /// Records voted on to pick the shape.
    static let shapeSample = 200

    /// The first non-blank line is a whole JSON object and at least one more non-blank line follows.
    static func looksLikeLines(_ bytes: [UInt8]) -> Bool {
        let lines = lineRanges(bytes, stopAfter: 2)
        guard lines.count >= 2 else { return false }
        return bytes.withUnsafeBufferPointer { buffer in
            guard case .success(let parsed) = AIJSONParser.parseDocument(buffer, range: lines[0], limits: .record) else {
                return false
            }
            return parsed.value.isObject
        }
    }

    /// The ranges of non-blank lines (trimmed of spaces and CR), with their 1-based line numbers dropped.
    private static func lineRanges(_ bytes: [UInt8], stopAfter: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        forEachLine(bytes, end: bytes.count) { _, range in
            if !range.isEmpty { out.append(range) }
            return out.count < stopAfter
        }
        return out
    }

    /// Calls `body` with each line's number and its range trimmed of surrounding whitespace, up to `end`.
    private static func forEachLine(_ bytes: [UInt8], end: Int, _ body: (Int, Range<Int>) -> Bool) {
        var start = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var line = 1
        while start < end {
            var stop = start
            while stop < end, bytes[stop] != 0x0A { stop += 1 }
            var a = start, b = stop
            while a < b, bytes[a] == 0x20 || bytes[a] == 0x09 || bytes[a] == 0x0D { a += 1 }
            while b > a, bytes[b - 1] == 0x20 || bytes[b - 1] == 0x09 || bytes[b - 1] == 0x0D { b -= 1 }
            if !body(line, a..<b) { return }
            line += 1
            start = stop + 1
        }
    }

    static func read(_ bytes: [UInt8], context: AIReadContext) -> JSONLSummary {
        // When the read was cut, the last line is probably partial: stop at the last newline.
        var end = bytes.count
        if context.wasCut, let lastNewline = bytes.lastIndex(of: 0x0A) { end = lastNewline + 1 }

        let shape = voteShape(bytes, end: end)
        var records = 0, blank = 0, malformed = 0, nonObject = 0, sampled = 0
        var malformedLines: [Int] = []
        var schema = SchemaAccumulator()
        var table = TableAccumulator()
        var stats = ShapeStats(shape: shape)

        bytes.withUnsafeBufferPointer { buffer in
            forEachLine(bytes, end: end) { line, range in
                guard !range.isEmpty else { blank += 1; return true }
                records += 1
                if records > JSONLSummary.maxSampled {
                    if AIJSONParser.validate(buffer, range: range, limits: .record) != nil {
                        malformed += 1
                        if malformedLines.count < JSONLSummary.maxListedLines { malformedLines.append(line) }
                    }
                    return true
                }
                switch AIJSONParser.parseDocument(buffer, range: range, limits: .record) {
                case .failure:
                    malformed += 1
                    if malformedLines.count < JSONLSummary.maxListedLines { malformedLines.append(line) }
                case .success(let parsed):
                    guard parsed.value.isObject else { nonObject += 1; return true }
                    sampled += 1
                    schema.add(parsed.value)
                    table.add(parsed.value)
                    stats.add(parsed.value)
                }
                return true
            }
        }

        let exact = !context.wasCut
        var count = records
        if !exact, end > 0 {
            count = Int(min(Double(Int.max / 2), (Double(records) * Double(context.totalSize) / Double(end)).rounded()))
        }
        var warnings: [AIDataWarning] = []
        if records > 0, malformed == records {
            warnings.append(AIDataWarning(.caution, String(localized: "No line in this file is valid JSON.", bundle: .module, comment: "JSONL warning.")))
        } else if malformed > 0, let first = malformedLines.first {
            warnings.append(AIDataWarning(.caution, String(localized: "\(malformed) lines are not valid JSON (the first is line \(first)).", bundle: .module, comment: "JSONL warning. The arguments are a line count and a line number.")))
        }
        if nonObject > 0 {
            warnings.append(AIDataWarning(.caution, String(localized: "\(nonObject) lines hold JSON that is not an object; the table and schema leave them out.", bundle: .module, comment: "JSONL warning. The argument is a line count.")))
        }
        if context.wasCut {
            let megabytes = AIDataReader.maxBytes / (1024 * 1024)
            warnings.append(AIDataWarning(.caution, String(localized: "Only the first \(megabytes) MB were read, so the record count is an estimate.", bundle: .module, comment: "JSONL warning. The argument is a size in megabytes.")))
        }
        if records > JSONLSummary.maxSampled {
            let sampledLimit = JSONLSummary.maxSampled
            warnings.append(AIDataWarning(.caution, String(localized: "The schema and figures describe the first \(sampledLimit) records; the rest were only checked for valid JSON.", bundle: .module, comment: "JSONL warning. The argument is a record count.")))
        }
        warnings += stats.warnings()

        let countText = exact ? count.formatted()
            : String(localized: "about \(count)", bundle: .module, comment: "An estimated record count. The argument is the estimate.")
        var facts: [AIDataFact] = [
            AIDataFact(AIReadContext.formatLabel, shape.title),
            AIDataFact(String(localized: "Records", bundle: .module, comment: "Fact label: JSONL records."), countText),
        ]
        if !malformedLines.isEmpty {
            facts.append(AIDataFact(String(localized: "Malformed lines", bundle: .module, comment: "Fact label: JSONL lines that are not valid JSON."), malformed.formatted()))
        }
        if !schema.order.isEmpty {
            facts.append(AIDataFact(String(localized: "Fields", bundle: .module, comment: "Fact label: distinct field paths in a JSONL schema."),
                                    schema.order.count.formatted() + (schema.truncated ? "+" : "")))
        }
        facts += stats.facts(sampled: sampled, total: records)

        let title = shape.title
        let headline: String = switch (shape == .claudeCodeSession, exact) {
        case (true, true): String(localized: "\(title) · \(count) entries", bundle: .module, comment: "JSONL headline. The arguments are the shape name and an exact entry count.")
        case (true, false): String(localized: "\(title) · about \(count) entries", bundle: .module, comment: "JSONL headline. The arguments are the shape name and an estimated entry count.")
        case (false, true): String(localized: "\(title) · \(count) records", bundle: .module, comment: "JSONL headline. The arguments are the shape name and an exact record count.")
        case (false, false): String(localized: "\(title) · about \(count) records", bundle: .module, comment: "JSONL headline. The arguments are the shape name and an estimated record count.")
        }
        return JSONLSummary(headline: headline, shape: shape, recordCount: count, recordCountIsExact: exact,
                            blankLines: blank, malformedLines: malformedLines, malformedCount: malformed,
                            nonObjectCount: nonObject, sampledRecords: sampled,
                            fields: schema.fields(sampled: sampled), fieldsTruncated: schema.truncated,
                            table: table.table(totalRows: exact ? records - malformed - nonObject : nil),
                            facts: facts, warnings: warnings)
    }

    // MARK: Shape

    /// Classifies the first `shapeSample` object records and keeps the shape most of them follow.
    private static func voteShape(_ bytes: [UInt8], end: Int) -> JSONLSummary.Shape {
        var votes: [JSONLSummary.Shape: Int] = [:]
        var claudeNeutral = 0
        var seen = 0
        bytes.withUnsafeBufferPointer { buffer in
            forEachLine(bytes, end: end) { _, range in
                guard !range.isEmpty else { return true }
                if case .success(let parsed) = AIJSONParser.parseDocument(buffer, range: range, limits: .record),
                   parsed.value.isObject {
                    seen += 1
                    let shape = classify(parsed.value)
                    if shape == .generic, isClaudeCodeNeutral(parsed.value) { claudeNeutral += 1 }
                    votes[shape, default: 0] += 1
                }
                return seen < shapeSample
            }
        }
        guard seen > 0 else { return .generic }
        let claude = votes[.claudeCodeSession] ?? 0
        if claude > 0, Double(claude + claudeNeutral) >= 0.8 * Double(seen) { return .claudeCodeSession }
        let best = JSONLSummary.Shape.allCases.filter { $0 != .generic && $0 != .claudeCodeSession }
            .max { (votes[$0] ?? 0) < (votes[$1] ?? 0) }
        if let best, let n = votes[best], Double(n) >= 0.5 * Double(seen) { return best }
        return .generic
    }

    static func classify(_ record: AIJSON) -> JSONLSummary.Shape {
        let type = record["type"]?.string
        if type == "user" || type == "assistant", record["message"] != nil, record["sessionId"] != nil {
            return .claudeCodeSession
        }
        if record["custom_id"] != nil {
            if record["method"] != nil, record["url"] != nil, record["body"] != nil { return .openAIBatchInput }
            if record["params"]?.isObject == true { return .anthropicBatchRequests }
            if let result = record["result"], result["type"] != nil { return .anthropicBatchResults }
            if record["response"] != nil || record["error"] != nil { return .openAIBatchOutput }
        }
        if let messages = record["messages"]?.array, !messages.isEmpty,
           messages.allSatisfy({ $0["role"]?.string != nil }) {
            return .openAIFineTuningChat
        }
        let families = EvalFamily.present(in: record)
        if families.count >= 3 || (families.count >= 2 && (families.contains(.expected) || families.contains(.score))) {
            return .evaluationResults
        }
        return .generic
    }

    private static func isClaudeCodeNeutral(_ record: AIJSON) -> Bool {
        if record["sessionId"] != nil { return true }
        let type = record["type"]?.string ?? ""
        return ["summary", "system", "file-history-snapshot"].contains(type)
    }

    /// The four families of keys an evaluation record mixes.
    enum EvalFamily: CaseIterable {
        case input, expected, output, score

        var keys: [String] {
            switch self {
            case .input: ["input", "inputs", "prompt", "question", "query"]
            case .expected: ["expected", "expected_output", "target", "ideal", "reference", "ground_truth", "label", "answer"]
            case .output: ["output", "outputs", "completion", "response", "prediction", "generated", "actual", "model_output"]
            case .score: ["score", "scores", "correct", "is_correct", "passed", "pass", "grade", "accuracy", "judgment"]
            }
        }

        static func present(in record: AIJSON) -> Set<EvalFamily> {
            Set(allCases.filter { family in family.keys.contains { record[$0] != nil } })
        }

        /// The first key of this family the record has.
        func key(in record: AIJSON) -> String? { keys.first { record[$0] != nil } }
    }

    // MARK: Accumulators

    private struct SchemaAccumulator {
        var order: [String] = []
        var entries: [String: (types: Set<AIJSONType>, count: Int)] = [:]
        var truncated = false

        mutating func add(_ record: AIJSON) {
            var seen = Set<String>()
            for member in record.members ?? [] {
                note(member.key, member.value.type, &seen)
                if let inner = member.value.members {
                    for child in inner { note(member.key + "." + child.key, child.value.type, &seen) }
                }
            }
        }

        private mutating func note(_ path: String, _ type: AIJSONType, _ seen: inout Set<String>) {
            if entries[path] == nil {
                guard order.count < JSONLSummary.maxFields else { truncated = true; return }
                order.append(path)
                entries[path] = ([], 0)
            }
            entries[path]?.types.insert(type)
            if seen.insert(path).inserted { entries[path]?.count += 1 }
        }

        func fields(sampled: Int) -> [JSONLSummary.Field] {
            order.compactMap { path in
                guard let entry = entries[path] else { return nil }
                let types = AIJSONType.allCases.filter { entry.types.contains($0) }
                return JSONLSummary.Field(path: path, types: types, presentCount: entry.count,
                                          presence: sampled > 0 ? Double(entry.count) / Double(sampled) : 0)
            }
        }
    }

    private struct TableAccumulator {
        var columns: [String] = []
        var columnIndex: [String: Int] = [:]
        var rows: [[Int: String]] = []
        var truncated = false

        mutating func add(_ record: AIJSON) {
            guard rows.count < AIDataTable.maxRows else { truncated = true; return }
            var row: [Int: String] = [:]
            for member in record.members ?? [] {
                if let inner = member.value.members, !inner.isEmpty {
                    for child in inner { set(member.key + "." + child.key, child.value, &row) }
                } else {
                    set(member.key, member.value, &row)
                }
            }
            rows.append(row)
        }

        private mutating func set(_ column: String, _ value: AIJSON, _ row: inout [Int: String]) {
            let index: Int
            if let known = columnIndex[column] {
                index = known
            } else {
                guard columns.count < JSONLSummary.maxColumns else { truncated = true; return }
                index = columns.count
                columns.append(column)
                columnIndex[column] = index
            }
            row[index] = value.display()
        }

        func table(totalRows: Int?) -> AIDataTable {
            let width = columns.count
            let cells = rows.map { row in (0..<width).map { row[$0] ?? "" } }
            return AIDataTable(columns: columns, rows: cells, totalRows: totalRows,
                               isTruncated: truncated || totalRows.map { $0 > cells.count } ?? true)
        }
    }

    /// The figures each known shape adds to the card.
    private struct ShapeStats {
        let shape: JSONLSummary.Shape
        var counts: [String: [String: Int]] = [:]
        var customIDs = Set<String>()
        var duplicateIDs = 0
        var number: [String: Double] = [:]
        var tally: [String: Int] = [:]

        init(shape: JSONLSummary.Shape) { self.shape = shape }

        mutating func count(_ group: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            if counts[group] == nil { counts[group] = [:] }
            if counts[group]!.count < 500 || counts[group]![value] != nil { counts[group]![value, default: 0] += 1 }
        }

        mutating func add(_ r: AIJSON) {
            if let id = r["custom_id"]?.string ?? r["custom_id"]?.int.map(String.init) {
                if customIDs.count < 100_000, !customIDs.insert(id).inserted { duplicateIDs += 1 }
            }
            switch shape {
            case .openAIBatchInput:
                count("endpoint", r["url"]?.string)
                count("model", r.at("body", "model")?.string)
            case .openAIBatchOutput:
                let status = r.at("response", "status_code")?.int
                let failed = (r["error"].map { !$0.isNull } ?? false) || (status.map { $0 >= 400 } ?? false)
                tally[failed ? "failed" : "ok", default: 0] += 1
                count("model", r.at("response", "body", "model")?.string)
                if let usage = r.at("response", "body", "usage") {
                    number["input", default: 0] += usage["prompt_tokens"]?.double ?? usage["input_tokens"]?.double ?? 0
                    number["output", default: 0] += usage["completion_tokens"]?.double ?? usage["output_tokens"]?.double ?? 0
                }
            case .openAIFineTuningChat:
                let messages = r["messages"]?.array ?? []
                tally["messages", default: 0] += messages.count
                for message in messages { count("role", message["role"]?.string) }
                if messages.contains(where: { $0["role"]?.string == "system" }) { tally["withSystem", default: 0] += 1 }
                if !messages.contains(where: { $0["role"]?.string == "assistant" }) { tally["noAssistant", default: 0] += 1 }
                if r["tools"] != nil || r["functions"] != nil || messages.contains(where: { $0["tool_calls"] != nil }) {
                    tally["withTools", default: 0] += 1
                }
            case .anthropicBatchRequests:
                count("model", r.at("params", "model")?.string)
                if let maxTokens = r.at("params", "max_tokens")?.double {
                    number["maxTokensMax"] = max(number["maxTokensMax"] ?? 0, maxTokens)
                }
            case .anthropicBatchResults:
                count("result", r.at("result", "type")?.string)
                count("model", r.at("result", "message", "model")?.string)
                if let usage = r.at("result", "message", "usage") {
                    number["input", default: 0] += usage["input_tokens"]?.double ?? 0
                    number["output", default: 0] += usage["output_tokens"]?.double ?? 0
                }
            case .evaluationResults:
                if let key = EvalFamily.score.key(in: r), let value = r[key] {
                    count("scoreField", key)
                    if let b = value.bool {
                        tally[b ? "passed" : "notPassed", default: 0] += 1
                        number["scoreSum", default: 0] += b ? 1 : 0
                        tally["scored", default: 0] += 1
                    } else if let d = value.double {
                        number["scoreSum", default: 0] += d
                        tally["scored", default: 0] += 1
                    }
                }
            case .claudeCodeSession:
                count("session", r["sessionId"]?.string)
                count("type", r["type"]?.string)
            case .generic:
                break
            }
        }

        func facts(sampled: Int, total: Int) -> [AIDataFact] {
            var out: [AIDataFact] = []
            func list(_ label: String, _ group: String) {
                if let c = counts[group], !c.isEmpty { out.append(AIDataFact(label, AIText.counted(c))) }
            }
            func tokens(_ label: String, _ key: String) {
                if let v = number[key], v > 0 { out.append(AIDataFact(label, AIText.number(v))) }
            }
            let models = String(localized: "Models", bundle: .module, comment: "Fact label: model names and how often each appears.")
            let inputTokens = String(localized: "Input tokens", bundle: .module, comment: "Fact label.")
            let outputTokens = String(localized: "Output tokens", bundle: .module, comment: "Fact label.")
            switch shape {
            case .openAIBatchInput:
                list(String(localized: "Endpoints", bundle: .module, comment: "Fact label: API endpoints a batch calls."), "endpoint")
                list(models, "model")
            case .openAIBatchOutput:
                out.append(AIDataFact(String(localized: "Succeeded", bundle: .module, comment: "Fact label: batch requests that succeeded."), (tally["ok"] ?? 0).formatted()))
                out.append(AIDataFact(String(localized: "Failed", bundle: .module, comment: "Fact label: batch requests that failed."), (tally["failed"] ?? 0).formatted()))
                list(models, "model"); tokens(inputTokens, "input"); tokens(outputTokens, "output")
            case .openAIFineTuningChat:
                let messages = tally["messages"] ?? 0
                out.append(AIDataFact(String(localized: "Messages", bundle: .module, comment: "Fact label: chat messages."), messages.formatted()))
                if sampled > 0 {
                    out.append(AIDataFact(String(localized: "Messages per example", bundle: .module, comment: "Fact label: average messages in a fine-tuning example."),
                                          AIText.number(Double(messages) / Double(sampled), digits: 1)))
                }
                list(String(localized: "Roles", bundle: .module, comment: "Fact label: message roles and their counts."), "role")
                if let n = tally["withSystem"] { out.append(AIDataFact(String(localized: "With a system message", bundle: .module, comment: "Fact label: fine-tuning examples that have a system message."), n.formatted())) }
                if let n = tally["withTools"] { out.append(AIDataFact(String(localized: "With tools", bundle: .module, comment: "Fact label: fine-tuning examples that use tools."), n.formatted())) }
            case .anthropicBatchRequests:
                list(models, "model")
                if let m = number["maxTokensMax"] { out.append(AIDataFact(String(localized: "Largest max_tokens", bundle: .module, comment: "Fact label; max_tokens is an API parameter name, keep it as is."), AIText.number(m))) }
            case .anthropicBatchResults:
                list(String(localized: "Results", bundle: .module, comment: "Fact label: batch result types and their counts."), "result")
                list(models, "model")
                tokens(inputTokens, "input"); tokens(outputTokens, "output")
            case .evaluationResults:
                if let field = counts["scoreField"]?.max(by: { $0.value < $1.value })?.key {
                    out.append(AIDataFact(String(localized: "Score field", bundle: .module, comment: "Fact label: the field that holds an evaluation's score."), field))
                }
                if let scored = tally["scored"], scored > 0, let sum = number["scoreSum"] {
                    out.append(AIDataFact(String(localized: "Mean score", bundle: .module, comment: "Fact label."), AIText.number(sum / Double(scored))))
                }
                if tally["passed"] != nil || tally["notPassed"] != nil {
                    let passed = tally["passed"] ?? 0
                    let judged = passed + (tally["notPassed"] ?? 0)
                    out.append(AIDataFact(String(localized: "Passed", bundle: .module, comment: "Fact label: evaluation records that passed."),
                                          String(localized: "\(passed) of \(judged)", bundle: .module, comment: "A part of a whole: passed of judged.")))
                }
            case .claudeCodeSession:
                if let sessions = counts["session"] { out.append(AIDataFact(String(localized: "Sessions", bundle: .module, comment: "Fact label: Claude Code sessions in a transcript file."), sessions.count.formatted())) }
                list(String(localized: "Entry types", bundle: .module, comment: "Fact label: kinds of transcript entries and their counts."), "type")
            case .generic:
                break
            }
            return out
        }

        func warnings() -> [AIDataWarning] {
            var out: [AIDataWarning] = []
            if duplicateIDs > 0 {
                out.append(AIDataWarning(.caution, String(localized: "\(duplicateIDs) custom_id values repeat an earlier one; batch APIs need every custom_id to be unique.", bundle: .module, comment: "JSONL warning; custom_id is a field name, keep it as is. The argument is a count.")))
            }
            if shape == .openAIFineTuningChat, let n = tally["noAssistant"] {
                out.append(AIDataWarning(.caution, String(localized: "\(n) examples have no assistant message, so there is no reply to learn from.", bundle: .module, comment: "JSONL warning on a fine-tuning file. The argument is a count.")))
            }
            if shape == .openAIBatchOutput, let n = tally["failed"] {
                out.append(AIDataWarning(.caution, String(localized: "\(n) requests in this batch failed.", bundle: .module, comment: "JSONL warning. The argument is a count.")))
            }
            if shape == .anthropicBatchResults, let c = counts["result"] {
                let bad = c.filter { $0.key != "succeeded" }.values.reduce(0, +)
                if bad > 0 { out.append(AIDataWarning(.caution, String(localized: "\(bad) requests did not succeed (errored, canceled or expired).", bundle: .module, comment: "JSONL warning. The argument is a count."))) }
            }
            return out
        }
    }
}
