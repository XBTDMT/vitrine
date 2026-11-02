import Foundation

/// A promptfoo results file (A-11; `promptfoo eval -o results.json`, versions 2 to 4): the prompts and providers
/// compared, how many tests ran, how many passed, failed or errored, the scores, and the result rows. roadmap: S-21
public struct PromptfooSummary: Sendable, Equatable {
    public var headline: String
    public var evalID: String?
    /// The results format version the file states.
    public var version: Int?
    public var created: Date?
    /// The config's description, when it has one.
    public var evalDescription: String?
    /// Prompt labels (or their raw text, cut), first seen first.
    public var prompts: [String]
    /// Provider ids or labels, first seen first.
    public var providers: [String]
    /// Distinct test cases (by test index, else by variables).
    public var testCount: Int
    /// Result rows: one per test, prompt and provider.
    public var resultCount: Int
    public var passCount: Int
    public var failCount: Int
    public var errorCount: Int
    public var meanScore: Double?
    public var minScore: Double?
    public var maxScore: Double?
    public var totalTokens: Int?
    /// Provider, prompt, variables, output, result, score and latency for the first `AIDataTable.maxRows` results.
    public var table: AIDataTable
    public var facts: [AIDataFact]
    public var warnings: [AIDataWarning]

    public init(headline: String, evalID: String?, version: Int?, created: Date?, evalDescription: String?,
                prompts: [String], providers: [String], testCount: Int, resultCount: Int, passCount: Int,
                failCount: Int, errorCount: Int, meanScore: Double?, minScore: Double?, maxScore: Double?,
                totalTokens: Int?, table: AIDataTable, facts: [AIDataFact], warnings: [AIDataWarning]) {
        self.headline = headline
        self.evalID = evalID
        self.version = version
        self.created = created
        self.evalDescription = evalDescription
        self.prompts = prompts
        self.providers = providers
        self.testCount = testCount
        self.resultCount = resultCount
        self.passCount = passCount
        self.failCount = failCount
        self.errorCount = errorCount
        self.meanScore = meanScore
        self.minScore = minScore
        self.maxScore = maxScore
        self.totalTokens = totalTokens
        self.table = table
        self.facts = facts
        self.warnings = warnings
    }
}

enum AIPromptfooReader {
    static func read(_ root: AIJSON, budgetHit: Bool, context: AIReadContext) -> PromptfooSummary? {
        // Version 3 and later nest the results object under "results"; version 2 keeps them at the top.
        let container: AIJSON
        let results: [AIJSON]
        if let inner = root["results"], inner.isObject, let list = inner["results"]?.array,
           root["evalId"] != nil || inner["stats"] != nil || inner["prompts"] != nil || inner["version"] != nil {
            container = inner
            results = list
        } else if let list = root["results"]?.array, root["version"]?.int != nil, root["table"] != nil || root["stats"] != nil {
            container = root
            results = list
        } else {
            return nil
        }
        guard results.isEmpty || results.contains(where: { $0["provider"] != nil || $0["prompt"] != nil || $0["success"] != nil }) else {
            return nil
        }

        func name(_ value: AIJSON?) -> String? {
            guard let value else { return nil }
            if let s = value.text { return s }
            return value["label"]?.text ?? value["id"]?.text
        }
        var prompts: [String] = []
        for prompt in (container["prompts"]?.array ?? []).prefix(200) {
            if let label = prompt["label"]?.text ?? prompt["raw"]?.text { prompts.append(AIText.cap(label)) }
        }
        var providers: [String] = []
        for prompt in (container["prompts"]?.array ?? []).prefix(200) { if let p = name(prompt["provider"]) { providers.append(p) } }
        for p in (root.at("config", "providers")?.array ?? []).prefix(200) { if let p = name(p) { providers.append(p) } }

        var pass = 0, fail = 0, errors = 0
        var scores: [Double] = []
        var tests = Set<String>()
        var rows: [[String]] = []
        for r in results {
            if let p = name(r["provider"]) { providers.append(p) }
            if prompts.count < 200, let label = r.at("prompt", "label")?.text ?? r.at("prompt", "raw")?.text {
                prompts.append(AIText.cap(label))
            }
            if tests.count < 100_000 {
                if let index = r["testIdx"]?.int { tests.insert("#\(index)") } else if let vars = r["vars"] { tests.insert(vars.compact(limit: 2_000)) }
            }
            let outcome = outcome(r)
            switch outcome {
            case "pass": pass += 1
            case "error": errors += 1
            default: fail += 1
            }
            if let score = r["score"]?.double ?? r.at("gradingResult", "score")?.double { scores.append(score) }
            if rows.count < AIDataTable.maxRows {
                let output = r.at("response", "output") ?? r["output"]
                rows.append([
                    AIText.cap(name(r["provider"]) ?? ""),
                    AIText.cap(r.at("prompt", "label")?.string ?? r.at("prompt", "raw")?.string ?? ""),
                    r["vars"]?.display() ?? "",
                    output?.display() ?? (r["error"]?.text.map { AIText.cap($0) } ?? ""),
                    outcomeLabel(outcome),
                    (r["score"]?.double ?? r.at("gradingResult", "score")?.double).map { AIText.number($0) } ?? "",
                    r["latencyMs"]?.double.map { AIText.number($0) } ?? "",
                ])
            }
        }
        // The stats the file states win over the counts made here (they cover rows the file may have dropped).
        // A negative count is not a count and is ignored; the sum saturates, as the file's numbers can be anything.
        if let stats = container["stats"] {
            func count(_ key: String) -> Int? { stats[key]?.int.flatMap { $0 >= 0 ? $0 : nil } }
            pass = count("successes") ?? pass
            fail = count("failures") ?? fail
            errors = count("errors") ?? errors
        }
        let total = FormatMath.saturatingSum([pass, fail, errors])
        let testCount = tests.isEmpty ? results.count : tests.count
        prompts = AIText.unique(prompts, limit: 200)
        providers = AIText.unique(providers, limit: 200)
        let tokens = container.at("stats", "tokenUsage", "total")?.int
        let mean = scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)

        var facts: [AIDataFact] = [
            AIDataFact(String(localized: "Tests", bundle: .module, comment: "Fact label: test cases in an eval."), testCount.formatted()),
            AIDataFact(String(localized: "Passed", bundle: .module, comment: "Fact label: eval results that passed."),
                       String(localized: "\(pass) of \(total)", bundle: .module, comment: "A part of a whole: passed of judged.")),
        ]
        if fail > 0 { facts.append(AIDataFact(String(localized: "Failed", bundle: .module, comment: "Fact label: eval results that failed."), fail.formatted())) }
        if errors > 0 { facts.append(AIDataFact(String(localized: "Errors", bundle: .module, comment: "Fact label: eval results that errored."), errors.formatted())) }
        if !prompts.isEmpty { facts.append(AIDataFact(String(localized: "Prompts", bundle: .module, comment: "Fact label: prompts compared in an eval."), prompts.count.formatted())) }
        if !providers.isEmpty { facts.append(AIDataFact(String(localized: "Providers", bundle: .module, comment: "Fact label: model providers compared in an eval."), AIText.cap(providers.joined(separator: ", ")))) }
        if let mean { facts.append(AIDataFact(String(localized: "Mean score", bundle: .module, comment: "Fact label."), AIText.number(mean))) }
        if let tokens { facts.append(AIDataFact(String(localized: "Tokens", bundle: .module, comment: "Fact label: tokens used."), tokens.formatted())) }
        let created = AIDates.date(container["timestamp"]) ?? AIDates.date(root["createdAt"])
        if let created { facts.append(AIDataFact(String(localized: "Run", bundle: .module, comment: "Fact label: the date an eval ran."), AIText.date(created))) }

        var warnings: [AIDataWarning] = []
        if fail > 0 { warnings.append(AIDataWarning(.caution, String(localized: "\(fail) of \(total) results failed an assertion.", bundle: .module, comment: "promptfoo warning. The arguments are counts."))) }
        if errors > 0 { warnings.append(AIDataWarning(.caution, String(localized: "\(errors) results ended in an error (the provider or a grader failed).", bundle: .module, comment: "promptfoo warning. The argument is a count."))) }
        if budgetHit || context.wasCut { warnings.append(context.readCapWarning) }

        let headline: String
        if total > 0 {
            let percent = Int((Double(pass) / Double(total) * 100).rounded())
            headline = String(localized: "promptfoo results · \(testCount) tests · \(percent)% passed", bundle: .module, comment: "promptfoo headline; promptfoo is a product name. The arguments are a test count and a percentage.")
        } else {
            headline = String(localized: "promptfoo results · \(testCount) tests", bundle: .module, comment: "promptfoo headline; promptfoo is a product name. The argument is a test count.")
        }
        return PromptfooSummary(
            headline: headline,
            evalID: root["evalId"]?.text, version: container["version"]?.int ?? root["version"]?.int,
            created: created, evalDescription: root.at("config", "description")?.text, prompts: prompts,
            providers: providers, testCount: testCount, resultCount: results.count, passCount: pass,
            failCount: fail, errorCount: errors, meanScore: mean, minScore: scores.min(), maxScore: scores.max(),
            totalTokens: tokens,
            table: AIDataTable(columns: [String(localized: "Provider", bundle: .module, comment: "Table column."),
                                         String(localized: "Prompt", bundle: .module, comment: "Table column."),
                                         String(localized: "Variables", bundle: .module, comment: "Table column: a test's input variables."),
                                         String(localized: "Output", bundle: .module, comment: "Table column."),
                                         String(localized: "Result", bundle: .module, comment: "Table column: pass, fail or error."),
                                         String(localized: "Score", bundle: .module, comment: "Table column."),
                                         String(localized: "Latency ms", bundle: .module, comment: "Table column: latency in milliseconds.")],
                               rows: rows, totalRows: results.count, isTruncated: results.count > rows.count || budgetHit),
            facts: facts, warnings: warnings)
    }

    /// The table's word for an outcome code.
    private static func outcomeLabel(_ code: String) -> String {
        switch code {
        case "pass": String(localized: "pass", bundle: .module, comment: "An eval result that passed (table cell).")
        case "error": String(localized: "error", bundle: .module, comment: "An eval result that errored (table cell).")
        default: String(localized: "fail", bundle: .module, comment: "An eval result that failed (table cell).")
        }
    }

    /// pass, fail or error for one result row.
    private static func outcome(_ r: AIJSON) -> String {
        if r["success"]?.bool == true { return "pass" }
        // promptfoo's ResultFailureReason: 1 is an assertion, 2 an error.
        if r["failureReason"]?.int == 2 { return "error" }
        if r["failureReason"]?.int == 1 { return "fail" }
        if let error = r["error"]?.text, !error.isEmpty, r["gradingResult"] == nil { return "error" }
        if r["success"] == nil, r.at("gradingResult", "pass")?.bool == true { return "pass" }
        return "fail"
    }
}
