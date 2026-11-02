import AppKit
import VitrineUI

/// How the capsule's find field works for a preview: `search` marks matches and steps through them; `filter`
/// (tables, data 1) keeps only the rows that match, says how many, and ends with Done; `query` (I-8, the badge reads
/// SQL) runs a read-only SELECT on Return and shows its rows in the same grid. roadmap: S-6
public enum FindStyle: Sendable, Equatable { case search, filter, query }

/// What a query run reports to the capsule: "8 rows · 41 ms", or why it did not run (a calm message the gutter
/// shows in full). roadmap: S-6
public struct QueryOutcome: Sendable, Equatable {
    /// Rows the result holds; nil when the query did not run.
    public var rows: Int?
    /// Every row the query produced when more came than are held; nil when not capped or not counted.
    public var total: Int?
    public var isCapped: Bool
    public var milliseconds: Int
    /// Why the query did not run; nil on success.
    public var message: String?
    /// What the count counts: rows for SQL, results for jq. Each full phrase is one localized sentence (H-6).
    public var unit: Unit
    /// A line after the time on success ("1 line is not JSON", "stopped: the output limit … was reached").
    public var note: String?

    public enum Unit: Sendable, Equatable {
        case rows, results

        /// "8 rows", "1 result".
        func count(_ n: Int) -> String {
            switch self {
            case .rows: String(localized: "\(n) rows", bundle: .previewKit, comment: "Query outcome: how many rows a SQL query returned.")
            case .results: String(localized: "\(n) results", bundle: .previewKit, comment: "Query outcome: how many results a jq query returned.")
            }
        }

        /// "First 1,000 of 2,500 rows": the result was capped and the total counted.
        func firstOf(_ n: Int, total: Int) -> String {
            switch self {
            case .rows: String(localized: "First \(n) of \(total) rows", bundle: .previewKit,
                               comment: "Query outcome when capped: the first N rows held of a counted total.")
            case .results: String(localized: "First \(n) of \(total) results", bundle: .previewKit,
                                  comment: "Query outcome when capped: the first N jq results held of a counted total.")
            }
        }

        /// "First 100,000 rows": the result was capped and the total not counted.
        func first(_ n: Int) -> String {
            switch self {
            case .rows: String(localized: "First \(n) rows", bundle: .previewKit,
                               comment: "Query outcome when capped and the total was not counted.")
            case .results: String(localized: "First \(n) results", bundle: .previewKit,
                                  comment: "jq query outcome when capped and the total was not counted.")
            }
        }
    }

    public init(rows: Int?, total: Int? = nil, isCapped: Bool = false, milliseconds: Int = 0, message: String? = nil,
                unit: Unit = .rows, note: String? = nil) {
        self.rows = rows; self.total = total; self.isCapped = isCapped; self.milliseconds = milliseconds; self.message = message
        self.unit = unit; self.note = note
    }

    public static func failed(_ message: String) -> QueryOutcome { QueryOutcome(rows: nil, message: message) }

    /// "8 rows · 41 ms", "First 100,000 of 3,214,880 rows · 2.4 s", "First 100,000 rows · 15 s" (total not counted).
    public var summary: String {
        guard let rows else { return message ?? "" }
        let time = milliseconds < 1_000
            ? String(localized: "\(milliseconds) ms", bundle: .previewKit, comment: "A query's run time in milliseconds.")
            : String(localized: "\(Double(milliseconds) / 1_000, format: .number.precision(.fractionLength(1))) s",
                     bundle: .previewKit, comment: "A query's run time in seconds, one decimal.")
        let count: String
        if isCapped {
            count = total.map { unit.firstOf(rows, total: $0) } ?? unit.first(rows)
        } else {
            count = unit.count(rows)
        }
        return ["\(count) · \(time)", note].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What a preview says in the gutter beside the capsule (data 2): its own left text (the position readout, "1,206 of
/// 48,120 rows match") in place of the coverage line, and on the right a state ("Sorted by total ↓"), with a spinner
/// and Cancel while long work runs ("Sorting by ts…"). roadmap: S-24
public struct GutterStatus: Sendable, Equatable {
    public var leading: String?
    public var trailing: String?
    public var busy: Bool
    public init(leading: String? = nil, trailing: String? = nil, busy: Bool = false) {
        self.leading = leading; self.trailing = trailing; self.busy = busy
    }
}

/// One entry of the capsule's Copy-as menu (I-7): "CSV", "Markdown table"; `text` builds what is copied when picked.
/// An entry with `perform` copies something other than text (an image of the selected lines) or does something
/// (open at a line, reveal in Finder, code state 2); it returns whether something was copied, for the tick.
public struct CopyFormat {
    public var title: String
    public var text: @MainActor () -> String
    public var perform: (@MainActor (NSPasteboard) async -> Bool)?
    /// A picture of the preview: the shared menu then offers no second Copy as Image (I-10).
    public var isImage = false
    public init(title: String, text: @escaping @MainActor () -> String) { self.title = title; self.text = text }
    public init(title: String, perform: @escaping @MainActor (NSPasteboard) async -> Bool) {
        self.title = title; self.text = { "" }; self.perform = perform
    }
}

/// One find result for the capsule: how many matches, and which is current (0-based; -1 when none).
public struct FindResult: Sendable, Equatable {
    public let count: Int
    public let index: Int
    /// False when the search stopped at a bound (a very large folder): the count is a floor, and the capsule says so.
    public let searchedAll: Bool
    /// The search is still reading (a huge file): the count is what it has found so far.
    public let inProgress: Bool
    /// Said in place of the count when a prefix changed what find does ("Line 42", "2 of 3 symbols").
    public let label: String?
    public init(count: Int, index: Int, searchedAll: Bool = true, inProgress: Bool = false, label: String? = nil) {
        self.count = count; self.index = index; self.searchedAll = searchedAll; self.inProgress = inProgress; self.label = label
    }
}

/// A find prefix (code state 1): typed at the start of the field it becomes a badge and changes what find does —
/// ":" goes to a line, "@" finds symbols, "." a path in a tree, "level:" a log level. roadmap: S-5
public struct FindPrefix: Sendable, Equatable {
    public let token: String
    public let title: String
    public init(token: String, title: String) { self.token = token; self.title = title }

    public static let line = FindPrefix(token: ":", title: String(localized: "Go to line", bundle: .previewKit,
                                                                   comment: "Find prefix badge tooltip: ':' jumps to a line number."))
    public static let symbol = FindPrefix(token: "@", title: String(localized: "Symbol", bundle: .previewKit,
                                                                     comment: "Find prefix badge tooltip: '@' finds a symbol in code."))
    public static let path = FindPrefix(token: ".", title: String(localized: "Path in a tree", bundle: .previewKit,
                                                                   comment: "Find prefix badge tooltip: '.' finds a path in a JSON/YAML tree."))
    public static let level = FindPrefix(token: "level:", title: String(localized: "Log level", bundle: .previewKit,
                                                                         comment: "Find prefix badge tooltip: 'level:' filters a log by level."))
}

/// Find in a native text view (plain text, code until S-5, and every Source view): case-insensitive, every match
/// marked with the `find` token and the current one with `find-cur`, scrolled into view. Marks are temporary
/// attributes, so the text itself never changes. roadmap: S-24
@MainActor
final class TextFinder {
    private weak var textView: NSTextView?
    private var query = ""
    private var ranges: [NSRange] = []
    private var index = -1

    /// The scroll view's ruler (B-7), which maps the matches.
    private weak var ruler: RulerScroller?

    init(_ textView: NSTextView) {
        self.textView = textView
        if let scroll = textView.enclosingScrollView { ruler = RulerScroller.install(on: scroll) }
    }

    /// Each match's place in the whole text, for the ruler.
    private func placeMarks(in tv: NSTextView) {
        guard let ruler, let lm = tv.layoutManager, let container = tv.textContainer else { return }
        let height = max(1, tv.bounds.height)
        var last = -1.0
        ruler.marks = ranges.enumerated().compactMap { i, range in
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let at = Double(lm.boundingRect(forGlyphRange: glyphs, in: container).minY / height)
            if i != index, abs(at - last) < 0.001 { return nil }
            last = at
            return (at, i == index ? .current : .match)
        }
    }

    func find(_ q: String, forward: Bool) -> FindResult {
        guard let tv = textView else { return FindResult(count: 0, index: -1) }
        if q != query {
            clear()
            query = q
            if !q.isEmpty {
                let text = tv.string as NSString
                var r = NSRange(location: 0, length: text.length)
                while true {
                    let found = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: r)
                    if found.location == NSNotFound { break }
                    ranges.append(found)
                    r = NSRange(location: found.upperBound, length: text.length - found.upperBound)
                }
            }
        }
        guard !ranges.isEmpty, let lm = tv.layoutManager else { return FindResult(count: 0, index: -1) }
        index = forward ? (index + 1) % ranges.count : (index - 1 + ranges.count) % ranges.count
        for (i, range) in ranges.enumerated() {
            lm.addTemporaryAttribute(.backgroundColor, value: NSColor.token(i == index ? "find-cur" : "find"), forCharacterRange: range)
        }
        tv.scrollRangeToVisible(ranges[index])
        placeMarks(in: tv)
        return FindResult(count: ranges.count, index: index)
    }

    func clear() {
        if let tv = textView, let lm = tv.layoutManager {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
        }
        ranges = []; index = -1; query = ""
        ruler?.marks = []
    }
}
