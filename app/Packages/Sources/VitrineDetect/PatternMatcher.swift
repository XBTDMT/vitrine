// VitrineDetect — the matcher abstraction and its ICU implementation (ARCHITECTURE.md §7), and the bound on its work
// (security scan 2026-10-28 F9, F14, F23).
public import Foundation

/// One hit: the whole match plus the named `secret` group when the pattern has one.
public struct PatternMatch: Sendable, Hashable {
    public let range: NSRange
    public let secretRange: NSRange?

    public init(range: NSRange, secretRange: NSRange?) {
        self.range = range
        self.secretRange = secretRange
    }

    /// The part to black out: the named group, else the whole match (§1 principle 4).
    public var redactRange: NSRange { secretRange ?? range }
}

public protocol PatternMatcher: Sendable {
    init(pattern: String) throws
    /// All non-overlapping matches in `text`; ranges are UTF-16 offsets into `text`.
    func matches(in text: String) -> [PatternMatch]
}

/// How much regex work one scan may do. ICU is a backtracking engine without memoisation, so a pattern can take time
/// polynomial or exponential in the line's length; a bound is the only way a hostile line (OCR of an attacker's page,
/// text copied beside an image, a user rule imported from a file) cannot hold the engine.
///
/// NSRegularExpression's `.reportProgress` calls back while a search runs: as the search moves its start position and
/// once per fixed number of backtracking steps (10,000 in ICU's matcher). Each call is one unit of `work`: the count is
/// deterministic for a pattern and a text (about two units per character for a linear pattern), which is how the tests
/// prove a pattern linear, and each call is where a search is stopped: when it has run longer than
/// `Limits.searchTime` (one pattern on one text: a per-rule budget), when everything charged to this budget has run
/// longer than `Limits.totalTime`, or when the running task is cancelled. A stopped search reports nothing (`nil`),
/// never a partial list, so its caller knows the text was not checked.
///
/// One budget belongs to one synchronous scan on one thread; it is not shared.
public final class MatchBudget {
    public struct Limits: Sendable, Hashable {
        /// Wall-clock time one pattern may take on one search of one text.
        public var searchTime: Duration
        /// Wall-clock time for every search charged to one budget; nil for none.
        public var totalTime: Duration?

        public init(searchTime: Duration, totalTime: Duration?) {
            self.searchTime = searchTime
            self.totalTime = totalTime
        }

        /// What a scan runs under. One linear pattern on the longest line a scan reads (`Scanner.Limits.maxLineLength`)
        /// takes well under a millisecond (`RegexWorkTests`), so 100 ms per search is three orders of magnitude of
        /// headroom for an honest pattern on a loaded Mac and stops a catastrophic one (a cubic pattern on a 2,000-
        /// character line took 4 s; an exponential one never ends). 5 s for a whole scan is far above any real one (a
        /// few milliseconds per line) and bounds how long any one check can hold its caller.
        public static let standard = Limits(searchTime: .milliseconds(100), totalTime: .seconds(5))
        /// No time limit, only cancellation: for measuring work (tests).
        public static let unlimited = Limits(searchTime: .seconds(1_000_000), totalTime: nil)
    }

    /// How many progress calls pass between two clock reads (the clock is read before a search starts and on every 32nd
    /// call), so a 100 ms search limit is checked to within microseconds at a fraction of the cost.
    static let clockStride = 32

    public let limits: Limits
    private let deadline: ContinuousClock.Instant?
    /// Progress units charged so far, over every search (see the type's comment).
    public private(set) var work = 0
    /// Searches stopped for taking longer than `searchTime`.
    public private(set) var searchesOverTime = 0
    /// The last search was stopped for taking longer than `searchTime` (its pattern is too slow on that text).
    public private(set) var lastSearchOverTime = false
    /// The total time passed or the task was cancelled: every later search is refused.
    public private(set) var isExhausted = false

    public init(_ limits: Limits = .standard) {
        self.limits = limits
        deadline = limits.totalTime.map { ContinuousClock.now + $0 }
    }

    /// Whether a search may start or go on; marks the budget exhausted when its time ran out or the task was cancelled.
    func mayContinue(now: ContinuousClock.Instant = .now) -> Bool {
        if isExhausted { return false }
        if Task.isCancelled || deadline.map({ now >= $0 }) == true { isExhausted = true }
        return !isExhausted
    }

    fileprivate func charge(_ units: Int, overTime: Bool) {
        let (sum, overflow) = work.addingReportingOverflow(units)
        work = overflow ? .max : sum
        lastSearchOverTime = overTime
        if overTime { searchesOverTime += 1 }
    }
}

/// NSRegularExpression with options `[]` — case-insensitivity is always inline `(?i)` (§1 principle 5).
/// NSRegularExpression is immutable and documented thread-safe, hence the unchecked conformance.
public struct ICURegexMatcher: PatternMatcher, @unchecked Sendable {
    public static let secretGroupName = "secret"

    private let regex: NSRegularExpression
    public var pattern: String { regex.pattern }

    public init(pattern: String) throws {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            throw PatternError.invalidRegex(pattern)
        }
    }

    /// The matches in `text`, under a budget of its own (`MatchBudget.Limits.standard`). A search stopped by the
    /// budget returns no matches; callers that must know whether `text` was checked use `matches(in:budget:)`.
    public func matches(in text: String) -> [PatternMatch] {
        matches(in: text, budget: MatchBudget()) ?? []
    }

    /// The matches in `text`, charged to `budget`; nil when the search was stopped (too much work, the time limit, a
    /// cancelled task) or the budget was already exhausted. Never a partial list.
    public func matches(in text: String, budget: MatchBudget) -> [PatternMatch]? {
        let started = ContinuousClock.now
        guard budget.mayContinue(now: started) else {
            budget.charge(0, overTime: false)
            return nil
        }
        let searchDeadline = started + budget.limits.searchTime
        let whole = NSRange(location: 0, length: text.utf16.count)
        var found: [PatternMatch] = []
        var units = 0
        var overTime = false
        var stopped = false
        regex.enumerateMatches(in: text, options: [.reportProgress], range: whole) { result, flags, stop in
            if let result, result.range.length > 0 {   // never report an empty match
                let group = result.range(withName: Self.secretGroupName)
                let secret: NSRange? = (group.location != NSNotFound && group.length > 0) ? group : nil
                found.append(PatternMatch(range: result.range, secretRange: secret))
            }
            guard flags.contains(.progress) else { return }
            units += 1
            guard units % MatchBudget.clockStride == 0 else { return }
            let now = ContinuousClock.now
            if now >= searchDeadline {
                overTime = true
                stopped = true
                stop.pointee = true
            } else if !budget.mayContinue(now: now) {
                stopped = true
                stop.pointee = true
            }
        }
        budget.charge(units, overTime: overTime)
        return stopped ? nil : found
    }
}
