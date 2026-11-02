import Foundation
import VitrineEngineering
import VitrineFormats

/// The readers' summaries as the shapes the picked stage views draw (F8 waterfall, F9 graph): HAR requests and
/// OpenTelemetry spans become waterfall rows; Compose services and Actions jobs become graph nodes, with a reader
/// warning about a service or job marked on its node. roadmap: S-22
enum StageAdapters {
    /// The waterfall draws every row it is given; past this many a capture is cut (the text view still lists all).
    static let maxRows = 2_000

    // MARK: Waterfall (F8)

    static func waterfall(_ s: HARSummary) -> [WaterfallRow] {
        s.entries.prefix(maxRows).map { e in
            let size = e.responseSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            let detail = ([e.status > 0 ? String(e.status) : nil, size].compactMap { $0 }).joined(separator: " · ")
            return WaterfallRow(name: "\(e.method) \(e.host)\(e.path)", startMs: e.startOffsetMs ?? 0, durationMs: e.durationMs ?? 0,
                                detail: detail.isEmpty ? nil : detail, isError: e.status == 0 || e.status >= 400)
        }
    }

    static func waterfall(_ t: OTLPTraceSummary) -> [WaterfallRow] {
        t.rows.prefix(maxRows).map { span in
            var name = span.name
            if let model = span.genAI?.responseModel ?? span.genAI?.requestModel, !name.contains(model) { name += " · " + model }
            var detail: String?
            if let input = span.genAI?.inputTokens, let output = span.genAI?.outputTokens {
                detail = String(localized: "\(input.formatted()) → \(output.formatted()) tokens", bundle: .previewKit,
                                comment: "A model call's tokens on a trace waterfall row: input, then output. The numbers arrive formatted.")
            } else if let service = span.service {
                detail = service
            }
            return WaterfallRow(name: name, startMs: span.startOffsetMs, durationMs: span.durationMs, depth: span.depth,
                                detail: detail, isError: span.status == .error)
        }
    }

    // MARK: Graph (F9)

    /// Services left to right in the order a request travels: a service sits left of what it depends on.
    static func graph(_ s: ComposeSummary) -> StageGraph {
        let marks = warningMarks(s.warnings)
        var nodes = s.services.map { service in
            StageGraph.Node(id: service.name, title: service.name,
                            subtitle: service.image?.reference ?? service.build.map { "build " + $0 },
                            warning: marks[service.name])
        }
        nodes += missingNodes(s.graph, known: Set(nodes.map(\.id)))
        return StageGraph(nodes: nodes, edges: s.graph.edges.map { StageGraph.Edge(from: $0.from, to: $0.to, label: $0.label.map(conditionLabel)) })
    }

    /// Jobs left to right in the order they run: a job sits right of the jobs it needs.
    static func graph(_ s: WorkflowSummary) -> StageGraph {
        let marks = warningMarks(s.warnings)
        var nodes = s.jobs.map { job in
            StageGraph.Node(id: job.id, title: job.name ?? job.id, subtitle: job.runsOn ?? job.uses, warning: marks[job.id])
        }
        nodes += missingNodes(s.graph, known: Set(nodes.map(\.id)))
        return StageGraph(nodes: nodes, edges: s.graph.edges.map { StageGraph.Edge(from: $0.to, to: $0.from, label: $0.label) })
    }

    /// Compose's `depends_on` condition in a word that fits on an edge: `service_healthy` → `healthy`,
    /// `service_completed_successfully` → `completed`; anything else as written.
    static func conditionLabel(_ condition: String) -> String {
        switch condition {
        case "service_healthy": "healthy"
        case "service_started": "started"
        case "service_completed_successfully": "completed"
        default: condition
        }
    }

    /// The loudest warning about each subject (a service or job name).
    static func warningMarks(_ warnings: [InfraWarning]) -> [String: StageGraph.Warning] {
        var marks: [String: StageGraph.Warning] = [:]
        for w in warnings {
            guard let subject = w.subject else { continue }
            if w.level == .danger { marks[subject] = .danger } else if marks[subject] == nil { marks[subject] = .caution }
        }
        return marks
    }

    /// A dependency the file names but never defines, drawn so its edge has an end, marked caution.
    static func missingNodes(_ g: InfraGraph, known: Set<String>) -> [StageGraph.Node] {
        g.missing.filter { !known.contains($0) }.map {
            StageGraph.Node(id: $0, title: $0,
                            subtitle: String(localized: "not defined in this file", bundle: .previewKit,
                                             comment: "Under a name in a Compose or workflow graph: something depended on that the file never defines."),
                            warning: .caution)
        }
    }
}
