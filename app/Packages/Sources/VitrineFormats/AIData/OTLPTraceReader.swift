import Foundation

/// OpenTelemetry traces in OTLP JSON (A-11): `resourceSpans` → scope spans → spans, laid out as waterfall rows
/// (trace by trace, parents before children, siblings by start time) with the GenAI semantic-convention attributes
/// read for model calls. One JSON document, or JSON Lines of them (the collector's file exporter). roadmap: S-21
public struct OTLPTraceSummary: Sendable, Equatable {
    /// A span's status. roadmap: S-21
    public enum Status: String, Sendable, Equatable {
        case unset, ok, error

        /// The status as a table shows it.
        public var label: String {
            switch self {
            case .unset: String(localized: "unset", bundle: .module, comment: "A trace span's status: none was set.")
            case .ok: String(localized: "ok", bundle: .module, comment: "A trace span's status: succeeded.")
            case .error: String(localized: "error", bundle: .module, comment: "A trace span's status: failed.")
            }
        }
    }

    /// What a GenAI span says about its model call (`gen_ai.*`). roadmap: S-21
    public struct GenAI: Sendable, Equatable {
        /// `gen_ai.operation.name`: chat, text_completion, embeddings, execute_tool …
        public var operation: String?
        /// `gen_ai.provider.name`, or the older `gen_ai.system`.
        public var provider: String?
        public var requestModel: String?
        public var responseModel: String?
        /// `gen_ai.usage.input_tokens` (or the older `prompt_tokens`).
        public var inputTokens: Int?
        /// `gen_ai.usage.output_tokens` (or the older `completion_tokens`).
        public var outputTokens: Int?

        public init(operation: String?, provider: String?, requestModel: String?, responseModel: String?,
                    inputTokens: Int?, outputTokens: Int?) {
            self.operation = operation
            self.provider = provider
            self.requestModel = requestModel
            self.responseModel = responseModel
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }
    }

    /// One waterfall row. roadmap: S-21
    public struct Span: Sendable, Equatable {
        public var traceID: String
        public var spanID: String
        public var parentSpanID: String?
        public var name: String
        /// The resource's `service.name`.
        public var service: String?
        /// internal, server, client, producer or consumer.
        public var kind: String?
        /// Milliseconds from the start of the span's trace.
        public var startOffsetMs: Double
        public var durationMs: Double
        /// 0 for a root; its parent's depth plus one otherwise.
        public var depth: Int
        public var status: Status
        public var statusMessage: String?
        public var genAI: GenAI?

        public init(traceID: String, spanID: String, parentSpanID: String?, name: String, service: String?,
                    kind: String?, startOffsetMs: Double, durationMs: Double, depth: Int, status: Status,
                    statusMessage: String?, genAI: GenAI?) {
            self.traceID = traceID
            self.spanID = spanID
            self.parentSpanID = parentSpanID
            self.name = name
            self.service = service
            self.kind = kind
            self.startOffsetMs = startOffsetMs
            self.durationMs = durationMs
            self.depth = depth
            self.status = status
            self.statusMessage = statusMessage
            self.genAI = genAI
        }
    }

    public var headline: String
    public var traceCount: Int
    /// Every span read, shown or not.
    public var spanCount: Int
    public var services: [String]
    /// From the earliest start to the latest end across the file.
    public var totalDurationMs: Double?
    public var errorSpanCount: Int
    public var genAISpanCount: Int
    public var inputTokens: Int
    public var outputTokens: Int
    /// Request and response models named by GenAI spans, first seen first.
    public var models: [String]
    /// At most `maxRows` rows.
    public var rows: [Span]
    public var rowsTruncated: Bool
    /// The rows as display strings: name (indented by depth), service, start, duration, status, model, tokens.
    public var table: AIDataTable
    public var facts: [AIDataFact]
    public var warnings: [AIDataWarning]

    public static let maxRows = 2_000
    public static let maxSpans = 50_000
    public static let maxDepth = 64

    public init(headline: String, traceCount: Int, spanCount: Int, services: [String], totalDurationMs: Double?,
                errorSpanCount: Int, genAISpanCount: Int, inputTokens: Int, outputTokens: Int, models: [String],
                rows: [Span], rowsTruncated: Bool, table: AIDataTable, facts: [AIDataFact], warnings: [AIDataWarning]) {
        self.headline = headline
        self.traceCount = traceCount
        self.spanCount = spanCount
        self.services = services
        self.totalDurationMs = totalDurationMs
        self.errorSpanCount = errorSpanCount
        self.genAISpanCount = genAISpanCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.models = models
        self.rows = rows
        self.rowsTruncated = rowsTruncated
        self.table = table
        self.facts = facts
        self.warnings = warnings
    }
}

enum AITraceReader {
    private struct RawSpan {
        var traceID: String
        var spanID: String
        var parentID: String?
        var name: String
        var service: String?
        var kind: String?
        var start: UInt64?
        var end: UInt64?
        var status: OTLPTraceSummary.Status
        var statusMessage: String?
        var genAI: OTLPTraceSummary.GenAI?
    }

    static func read(_ root: AIJSON, budgetHit: Bool, context: AIReadContext) -> OTLPTraceSummary? {
        guard let resourceSpans = root["resourceSpans"]?.array else { return nil }
        return summarise(resourceSpans, partial: budgetHit || context.wasCut, context: context)
    }

    /// JSON Lines whose records each carry `resourceSpans`.
    static func readLines(_ bytes: [UInt8], context: AIReadContext) -> OTLPTraceSummary? {
        var all: [AIJSON] = []
        var partial = context.wasCut
        var first = true
        var isTrace = true
        var start = 0
        bytes.withUnsafeBufferPointer { buffer in
            while start < buffer.count, isTrace {
                var stop = start
                while stop < buffer.count, buffer[stop] != 0x0A { stop += 1 }
                let range = start..<stop
                start = stop + 1
                if buffer[range].allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
                switch AIJSONParser.parseDocument(buffer, range: range, limits: .document) {
                case .success(let parsed):
                    guard let spans = parsed.value["resourceSpans"]?.array else {
                        if first { isTrace = false }
                        continue
                    }
                    if parsed.budgetHit { partial = true }
                    all += spans
                case .failure:
                    if first { isTrace = false }
                    partial = true
                }
                first = false
            }
        }
        guard isTrace, !first else { return nil }
        return summarise(all, partial: partial, context: context)
    }

    private static func summarise(_ resourceSpans: [AIJSON], partial: Bool, context: AIReadContext) -> OTLPTraceSummary {
        var spans: [RawSpan] = []
        var spanCount = 0
        var services: [String] = []
        outer: for rs in resourceSpans {
            let resource = attributes(rs.at("resource", "attributes"))
            let service = resource["service.name"]?.string
            if let service { services.append(service) }
            for scope in rs["scopeSpans"]?.array ?? rs["instrumentationLibrarySpans"]?.array ?? [] {
                for span in scope["spans"]?.array ?? [] {
                    spanCount += 1
                    guard spans.count < OTLPTraceSummary.maxSpans else { continue }
                    spans.append(rawSpan(span, service: service))
                }
            }
            if spanCount > 10 * OTLPTraceSummary.maxSpans { break outer }
        }

        // Group by trace in first-seen order, then lay each trace out parents first.
        var traceOrder: [String] = []
        var byTrace: [String: [Int]] = [:]
        for (index, span) in spans.enumerated() {
            if byTrace[span.traceID] == nil { traceOrder.append(span.traceID) }
            byTrace[span.traceID, default: []].append(index)
        }
        var rows: [OTLPTraceSummary.Span] = []
        for trace in traceOrder {
            let members = byTrace[trace] ?? []
            let traceStart = members.compactMap { spans[$0].start }.min() ?? 0
            var byID: [String: Int] = [:]
            for index in members where byID[spans[index].spanID] == nil { byID[spans[index].spanID] = index }
            var children: [Int: [Int]] = [:]
            var roots: [Int] = []
            for index in members {
                if let parent = spans[index].parentID, let p = byID[parent], p != index {
                    children[p, default: []].append(index)
                } else {
                    roots.append(index)
                }
            }
            func byStart(_ a: Int, _ b: Int) -> Bool { (spans[a].start ?? 0, a) < (spans[b].start ?? 0, b) }
            var placed = Set<Int>()
            func place(_ start: Int, depth: Int) {
                var stack: [(Int, Int)] = [(start, depth)]
                while let (index, d) = stack.popLast() {
                    guard placed.insert(index).inserted else { continue }
                    rows.append(row(spans[index], depth: d, traceStart: traceStart))
                    if d < OTLPTraceSummary.maxDepth {
                        for child in (children[index] ?? []).sorted(by: byStart).reversed() { stack.append((child, d + 1)) }
                    }
                }
            }
            for root in roots.sorted(by: byStart) { place(root, depth: 0) }
            // Spans caught in a parent cycle are never reached from a root; they are shown at the top level.
            for index in members where !placed.contains(index) { place(index, depth: 0) }
        }

        let errorCount = spans.filter { $0.status == .error }.count
        let genAI = spans.compactMap(\.genAI)
        // Each span's counts come from the file and can be anything, so the totals saturate instead of trapping.
        let inputTokens = FormatMath.saturatingSum(genAI.map { $0.inputTokens ?? 0 })
        let outputTokens = FormatMath.saturatingSum(genAI.map { $0.outputTokens ?? 0 })
        let models = AIText.unique(genAI.flatMap { [$0.responseModel, $0.requestModel].compactMap { $0 } })
        let starts = spans.compactMap(\.start), ends = spans.compactMap(\.end)
        var total: Double?
        if let s = starts.min(), let e = ends.max(), e >= s { total = Double(e - s) / 1_000_000 }
        services = AIText.unique(services)

        var facts: [AIDataFact] = [
            AIDataFact(String(localized: "Traces", bundle: .module, comment: "Fact label: OpenTelemetry traces."), traceOrder.count.formatted()),
            AIDataFact(String(localized: "Spans", bundle: .module, comment: "Fact label: OpenTelemetry spans."), spanCount.formatted()),
        ]
        if !services.isEmpty { facts.append(AIDataFact(String(localized: "Services", bundle: .module, comment: "Fact label: service names in a trace."), AIText.cap(services.joined(separator: ", ")))) }
        if let total { facts.append(AIDataFact(String(localized: "Duration", bundle: .module, comment: "Fact label."), AIText.milliseconds(total))) }
        if !genAI.isEmpty { facts.append(AIDataFact(String(localized: "GenAI calls", bundle: .module, comment: "Fact label: spans that are generative AI model calls."), genAI.count.formatted())) }
        if !models.isEmpty { facts.append(AIDataFact(String(localized: "Models", bundle: .module, comment: "Fact label: model names."), AIText.cap(models.joined(separator: ", ")))) }
        if inputTokens > 0 || outputTokens > 0 {
            facts.append(AIDataFact(String(localized: "Tokens", bundle: .module, comment: "Fact label: tokens used."),
                                    String(localized: "\(inputTokens) in · \(outputTokens) out", bundle: .module, comment: "Input and output token counts.")))
        }
        if errorCount > 0 { facts.append(AIDataFact(String(localized: "Errors", bundle: .module, comment: "Fact label: spans with an error status."), errorCount.formatted())) }

        var warnings: [AIDataWarning] = []
        if errorCount > 0 { warnings.append(AIDataWarning(.caution, String(localized: "\(errorCount) spans ended with an error status.", bundle: .module, comment: "Trace warning. The argument is a span count."))) }
        if spanCount > spans.count {
            let laidOut = spans.count
            warnings.append(AIDataWarning(.caution, String(localized: "The file has \(spanCount) spans; the first \(laidOut) are laid out.", bundle: .module, comment: "Trace warning. The arguments are span counts.")))
        }
        if partial { warnings.append(context.readCapWarning) }

        let shown = Array(rows.prefix(OTLPTraceSummary.maxRows))
        let tableRows = shown.prefix(AIDataTable.maxRows).map { s -> [String] in
            let tokens = s.genAI.map { g in [g.inputTokens, g.outputTokens].map { $0.map { $0.formatted() } ?? "–" }.joined(separator: " / ") } ?? ""
            return [AIText.cap(String(repeating: "  ", count: min(s.depth, 20)) + s.name), s.service ?? "",
                    AIText.number(s.startOffsetMs, digits: 2), AIText.number(s.durationMs, digits: 2), s.status.label,
                    AIText.cap(s.genAI?.responseModel ?? s.genAI?.requestModel ?? ""), tokens]
        }
        let traceCount = traceOrder.count
        var headline = traceCount > 1
            ? String(localized: "OpenTelemetry traces · \(traceCount) traces, \(spanCount) spans", bundle: .module, comment: "Trace headline; OpenTelemetry is a product name. The arguments are counts.")
            : String(localized: "OpenTelemetry trace · \(spanCount) spans", bundle: .module, comment: "Trace headline; OpenTelemetry is a product name. The argument is a span count.")
        if !genAI.isEmpty {
            let calls = genAI.count
            headline += " · " + String(localized: "\(calls) GenAI calls", bundle: .module, comment: "Part of a trace headline. The argument is a count of model calls.")
        }
        return OTLPTraceSummary(
            headline: headline, traceCount: traceOrder.count, spanCount: spanCount, services: services,
            totalDurationMs: total, errorSpanCount: errorCount, genAISpanCount: genAI.count, inputTokens: inputTokens,
            outputTokens: outputTokens, models: models, rows: shown, rowsTruncated: rows.count > shown.count || spanCount > spans.count,
            table: AIDataTable(columns: [String(localized: "Span", bundle: .module, comment: "Table column."),
                                         String(localized: "Service", bundle: .module, comment: "Table column."),
                                         String(localized: "Start ms", bundle: .module, comment: "Table column: start offset in milliseconds."),
                                         String(localized: "Duration ms", bundle: .module, comment: "Table column: duration in milliseconds."),
                                         String(localized: "Status", bundle: .module, comment: "Table column."),
                                         String(localized: "Model", bundle: .module, comment: "Table column."),
                                         String(localized: "Tokens in / out", bundle: .module, comment: "Table column.")],
                               rows: Array(tableRows), totalRows: spanCount, isTruncated: spanCount > tableRows.count),
            facts: facts, warnings: warnings)
    }

    private static func rawSpan(_ span: AIJSON, service: String?) -> RawSpan {
        let attrs = attributes(span["attributes"])
        var genAI: OTLPTraceSummary.GenAI?
        if attrs.keys.contains(where: { $0.hasPrefix("gen_ai.") }) {
            genAI = OTLPTraceSummary.GenAI(
                operation: attrs["gen_ai.operation.name"]?.string,
                provider: attrs["gen_ai.provider.name"]?.string ?? attrs["gen_ai.system"]?.string,
                requestModel: attrs["gen_ai.request.model"]?.string,
                responseModel: attrs["gen_ai.response.model"]?.string,
                inputTokens: (attrs["gen_ai.usage.input_tokens"] ?? attrs["gen_ai.usage.prompt_tokens"])?.int,
                outputTokens: (attrs["gen_ai.usage.output_tokens"] ?? attrs["gen_ai.usage.completion_tokens"])?.int)
        }
        var status = OTLPTraceSummary.Status.unset
        let code = span.at("status", "code")
        if let n = code?.int { status = n == 2 ? .error : n == 1 ? .ok : .unset }
        else if let s = code?.string { status = s.hasSuffix("ERROR") ? .error : s.hasSuffix("OK") ? .ok : .unset }
        let kind: String?
        if let n = span["kind"]?.int {
            kind = [1: "internal", 2: "server", 3: "client", 4: "producer", 5: "consumer"][n]
        } else if let s = span["kind"]?.string {
            kind = s.replacingOccurrences(of: "SPAN_KIND_", with: "").lowercased()
        } else {
            kind = nil
        }
        let parent = span["parentSpanId"]?.text
        return RawSpan(traceID: span["traceId"]?.string ?? "", spanID: span["spanId"]?.string ?? "",
                       parentID: parent, name: span["name"]?.text ?? String(localized: "(unnamed)", bundle: .module, comment: "Name shown for a trace span that has none."), service: service, kind: kind,
                       start: span["startTimeUnixNano"]?.uint64, end: span["endTimeUnixNano"]?.uint64, status: status,
                       statusMessage: span.at("status", "message")?.text, genAI: genAI)
    }

    private static func row(_ s: RawSpan, depth: Int, traceStart: UInt64) -> OTLPTraceSummary.Span {
        let start = s.start.map { $0 >= traceStart ? Double($0 - traceStart) / 1_000_000 : 0 } ?? 0
        var duration = 0.0
        if let a = s.start, let b = s.end, b >= a { duration = Double(b - a) / 1_000_000 }
        return OTLPTraceSummary.Span(traceID: s.traceID, spanID: s.spanID, parentSpanID: s.parentID, name: AIText.cap(s.name),
                                     service: s.service, kind: s.kind, startOffsetMs: start, durationMs: duration,
                                     depth: depth, status: s.status, statusMessage: s.statusMessage, genAI: s.genAI)
    }

    /// OTLP key/value attributes as key → plain value (`stringValue`, `intValue`, `doubleValue`, `boolValue`).
    private static func attributes(_ list: AIJSON?) -> [String: AIJSON] {
        var out: [String: AIJSON] = [:]
        for item in (list?.array ?? []).prefix(512) {
            guard let key = item["key"]?.string, let value = item["value"] else { continue }
            if let v = value["stringValue"] { out[key] = v }
            else if let v = value["intValue"] { out[key] = v }
            else if let v = value["doubleValue"] { out[key] = v }
            else if let v = value["boolValue"] { out[key] = v }
            else { out[key] = value }
        }
        return out
    }
}
