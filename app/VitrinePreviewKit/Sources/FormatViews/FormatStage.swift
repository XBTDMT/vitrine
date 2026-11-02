import AppKit

/// The shared shapes the format views draw (S-21, S-22, S-23; format views F8 and F9, both picked A): a timeline of
/// spans or requests for the waterfall, and nodes with edges for the dependency graph. Readers' own summaries are
/// mapped into these by ReaderCard, so one view serves several formats. roadmap: S-22
struct WaterfallRow: Equatable {
    var name: String
    /// Milliseconds from the first row's start.
    var startMs: Double
    var durationMs: Double
    /// Nesting depth (a child span is one deeper than its parent).
    var depth: Int = 0
    /// Short trailing facts: "1,240 → 380 tokens", "200 · 14 KB".
    var detail: String?
    var isError = false
}

struct StageGraph: Equatable {
    struct Node: Equatable {
        var id: String
        var title: String
        var subtitle: String?
        /// The node has a warning (a privileged service, an unpinned action): drawn with the caution or danger mark.
        var warning: Warning?
    }
    struct Edge: Equatable {
        var from: String
        var to: String
        var label: String?
    }
    enum Warning: Equatable { case caution, danger }
    var nodes: [Node]
    var edges: [Edge]
}

/// How a card puts a format view on its stage: a factory the card calls on the main actor when it builds itself.
typealias StageFactory = @MainActor () -> NSView
