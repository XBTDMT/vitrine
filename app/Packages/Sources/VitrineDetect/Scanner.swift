// VitrineDetect — the scan: fold → allow ranges → block scope → ranged detectors → validators → allow protection → merge.
// DETECTORS.md §6 (allow), §7 (block), §8 (merge); ARCHITECTURE.md §4 rows 8–12.
public import Foundation

public struct Scanner: Sendable {
    /// Where the text came from (fail-open #20).
    public enum Input: Sendable, Hashable {
        /// The text is exactly what was written (text copied beside an image, the Settings line tester, the text
        /// fixtures): a validator's rejection is the truth and drops the match.
        case exact
        /// The text is what OCR read, which can differ from the pixels by a misread. A match a vendor-format validator
        /// rejects (`Validator.checksVendorFormat`) is kept as an unverified finding.
        case recognized
    }

    /// How much one scan may read and do (security scan 2026-10-28 F9, F14, F23).
    public struct Limits: Sendable, Hashable {
        /// The longest line, in UTF-16 units, that is searched. A longer line is not searched at all and is reported
        /// unchecked (`ScanResult.uncheckedLines`): never cut, so nothing past a cut is called clean. OCR never makes a
        /// line this long (the working copy's long side is 4,096 px, and a glyph is several pixels wide); text copied
        /// beside an image can, and the caller treats it as not checked.
        public var maxLineLength: Int
        /// The regex budget of one scan (`MatchBudget`): per search, per scan, and the running task's cancellation.
        public var matching: MatchBudget.Limits

        public init(maxLineLength: Int, matching: MatchBudget.Limits) {
            self.maxLineLength = maxLineLength
            self.matching = matching
        }

        public static let standard = Limits(maxLineLength: 4_096, matching: .standard)
    }

    public let catalogue: CompiledCatalogue
    public let allowRuleMode: AllowRuleMode
    public let input: Input
    public let limits: Limits

    public init(catalogue: CompiledCatalogue, allowRuleMode: AllowRuleMode = .trim, input: Input = .exact, limits: Limits = .standard) {
        self.catalogue = catalogue
        self.allowRuleMode = allowRuleMode
        self.input = input
        self.limits = limits
    }

    /// This scanner for text from `input`.
    public func reading(_ input: Input) -> Scanner {
        Scanner(catalogue: catalogue, allowRuleMode: allowRuleMode, input: input, limits: limits)
    }

    struct AllowRange {
        let range: NSRange
        let suppressPartialOverlap: Bool
    }

    /// What one scan found, and which lines it could not finish.
    public struct Result: Sendable {
        public let findings: [Finding]
        /// `ScanLine.index` of every line not fully searched: longer than `Limits.maxLineLength`, or a search on it was
        /// stopped by the budget. Its findings so far are in `findings`; the line itself is not checked.
        public let uncheckedLines: [Int]
        /// Detectors with a search stopped for taking too long (ids only, for the log and the problem a caller raises).
        public let slowDetectorIDs: [String]
        /// Every line was searched to the end.
        public var isComplete: Bool { uncheckedLines.isEmpty }
    }

    /// The findings of `check(_:)` alone. For assertions and callers that use findings without giving a verdict; a
    /// caller that calls text clean, covered or safe uses `check(_:)` and its `isComplete`.
    public func scan(_ lines: [ScanLine]) -> [Finding] { check(lines).findings }

    /// Scans `lines` under `limits`: lines too long are not searched, and every regex search is charged to one budget.
    public func check(_ lines: [ScanLine]) -> Result {
        let ordered = lines.sorted { $0.index < $1.index }
        let folded = ordered.map { ConfusableFold.fold($0.text) }
        let budget = MatchBudget(limits.matching)
        var unchecked = Set<Int>()   // positions in `ordered`
        var slow = Set<String>()
        for (position, text) in folded.enumerated() where text.utf16.count > limits.maxLineLength { unchecked.insert(position) }
        // A stopped allow-rule search drops that rule's protection on the line: more is covered, never less.
        let allow = folded.enumerated().map { unchecked.contains($0.offset) ? [] : allowRanges(in: $0.element, budget: budget) }

        var findings: [Finding] = []
        var consumed = Set<Int>()   // positions in `ordered`

        // Pass 1: block-scope detectors (§7). Their lines are consumed before any ranged detector runs.
        for compiled in catalogue.detectors {
            guard case .block(let endMarkers) = compiled.detector.scope else { continue }
            var position = 0
            while position < folded.count {
                defer { position += 1 }
                guard !consumed.contains(position), !unchecked.contains(position) else { continue }
                var triggered = false
                for matcher in compiled.matchers {
                    guard let hits = matcher.matches(in: folded[position], budget: budget) else {
                        unchecked.insert(position)
                        if budget.lastSearchOverTime { slow.insert(compiled.detector.id) }
                        break
                    }
                    if !hits.isEmpty { triggered = true; break }
                }
                guard triggered else { continue }
                // The block runs to the first line holding every end marker, inclusive, and with no such line to the end of
                // the text (security scan F20). There is no line cap: past the trigger, nothing but the footer says where
                // the key ends (a cropped, misread or very long key has none in view), and stopping at a count or at a
                // line that does not look like key text (OCR misreads key text) would leave key lines visible. Covering
                // to the end at worst covers more than the key, which the person can undo in the viewer.
                let blockID = UUID()
                var cursor = position
                while cursor < folded.count {
                    consumed.insert(cursor)
                    let text = folded[cursor]
                    let whole = NSRange(location: 0, length: text.utf16.count)
                    let lineAllowed = allow[cursor].contains { $0.suppressPartialOverlap && NSEqualRanges(NSUnionRange($0.range, whole), $0.range) }
                    if !lineAllowed {
                        findings.append(Finding(
                            lineIndex: ordered[cursor].index, range: whole, secretRange: whole,
                            detectorIDs: [compiled.detector.id], category: compiled.detector.category,
                            severity: compiled.detector.severity, wholeLine: true, blockID: blockID,
                            textForLogs: Finding.logDigest(of: text)
                        ))
                        unchecked.remove(cursor)   // covered whole: nothing on it is left to check
                    }
                    let ended = endMarkers.allSatisfy { text.contains($0) }
                    cursor += 1
                    if ended { break }
                }
                position = cursor - 1
            }
        }

        // Pass 2: ranged detectors, per line, in catalogue order; union-merge (§8). Then G-12 route C: the line's
        // bounded misread variants, through the same matchers and validators.
        for (position, text) in folded.enumerated() where !consumed.contains(position) && !unchecked.contains(position) {
            var lineFindings: [Finding] = []
            var complete = true
            for hit in rangedMatches(in: text, budget: budget, complete: &complete, slow: &slow) {
                for protected in applyAllow(hit.match, allow[position]) {
                    merge(finding(hit, protected, lineIndex: ordered[position].index, text: text), into: &lineFindings)
                }
            }
            if complete, needsVariants(text, findings: lineFindings) {
                for variant in MisreadCandidates.lineVariants(text) {
                    for hit in rangedMatches(in: variant.text, budget: budget, complete: &complete, slow: &slow) where variant.repairs(hit.match.redactRange) {
                        let match = PatternMatch(range: variant.originalRange(of: hit.match.range),
                                                 secretRange: hit.match.secretRange.map { variant.originalRange(of: $0) })
                        guard match.redactRange.length > 0 else { continue }
                        let known = lineFindings.contains { $0.detectorIDs.contains(hit.detector.detector.id)
                            && NSIntersectionRange($0.secretRange, match.redactRange).length > 0 }
                        if known { continue }
                        for protected in applyAllow(match, allow[position]) {
                            let mapped = RangedHit(detector: hit.detector, match: protected, subkind: hit.subkind, unverified: hit.unverified)
                            merge(finding(mapped, protected, lineIndex: ordered[position].index, text: text), into: &lineFindings)
                        }
                    }
                }
            }
            findings.append(contentsOf: lineFindings)
            if !complete { unchecked.insert(position) }
        }

        Log.detect.debug("scan: \(Count(lines.count), privacy: .public) lines, \(Count(findings.count), privacy: .public) findings")
        if !unchecked.isEmpty {
            let ids = slow.sorted().joined(separator: ",")
            Log.detect.error("scan: \(Count(unchecked.count), privacy: .public) of \(Count(lines.count), privacy: .public) lines not checked (too long or over the regex budget), slow detectors: \(ids, privacy: .public)")
        }
        return Result(findings: findings, uncheckedLines: unchecked.map { ordered[$0].index }.sorted(), slowDetectorIDs: slow.sorted())
    }

    // MARK: ranged matching and route C

    struct RangedHit {
        let detector: CompiledDetector
        let match: PatternMatch
        let subkind: String?
        var unverified = false
    }

    /// Every ranged detector's validated matches on `text`, in catalogue order. A match its validator rejects is kept
    /// when one measured single-character misread (MisreadCandidates.singleSwaps) makes the UNCHANGED validator pass and
    /// the same pattern still matches the same range with that character in place (G-12 route C). Otherwise, on
    /// recognized text, a match a vendor-format validator rejects is kept unverified (fail-open #20): the pattern already
    /// matched the vendor's prefix and exact shape, and two misread characters (which no single swap undoes) fail a
    /// checksum or a JWT header just as a made-up token does; on screen it may be a real one.
    ///
    /// Every search is charged to `budget`; a stopped one sets `complete` to false (and names its detector in `slow`
    /// when it ran out of its own time) and contributes nothing, while the other detectors' hits are still returned.
    func rangedMatches(in text: String, budget: MatchBudget, complete: inout Bool, slow: inout Set<String>) -> [RangedHit] {
        var hits: [RangedHit] = []
        for compiled in catalogue.detectors {
            guard case .match = compiled.detector.scope else { continue }
            for (patternIndex, matcher) in compiled.matchers.enumerated() {
                guard let matches = matcher.matches(in: text, budget: budget) else {
                    complete = false
                    if budget.lastSearchOverTime { slow.insert(compiled.detector.id) }
                    continue
                }
                for match in matches {
                    guard compiled.detector.validatorApplies(toPatternAt: patternIndex) else {
                        hits.append(RangedHit(detector: compiled, match: match, subkind: nil)); continue
                    }
                    let validator = compiled.detector.validator
                    let secretText = substring(text, match.redactRange)
                    switch Validators.run(validator, on: secretText) {
                    case .pass: hits.append(RangedHit(detector: compiled, match: match, subkind: nil))
                    case .passAnnotated(let kind): hits.append(RangedHit(detector: compiled, match: match, subkind: kind))
                    case .reject:
                        if MisreadCandidates.swapsCanRepair(validator),
                           let subkind = repairedBySwap(match, in: text, matcher: matcher, validator: validator, budget: budget, complete: &complete) {
                            hits.append(RangedHit(detector: compiled, match: match, subkind: subkind))
                        } else if input == .recognized, validator.checksVendorFormat {
                            hits.append(RangedHit(detector: compiled, match: match, subkind: nil, unverified: true))
                        }
                    }
                }
            }
        }
        return hits
    }

    /// The subkind (or "" for none) when one swap in the secret passes `validator` and `matcher` still matches the
    /// same ranges on the swapped line; nil when no swap does. A stopped search sets `complete` to false.
    func repairedBySwap(_ match: PatternMatch, in text: String, matcher: ICURegexMatcher, validator: Validator,
                        budget: MatchBudget, complete: inout Bool) -> String?? {
        let secret = match.redactRange
        let ns = text as NSString
        for candidate in MisreadCandidates.singleSwaps(substring(text, secret)) {
            let result = Validators.run(validator, on: candidate)
            guard result.passes else { continue }
            let line = ns.replacingCharacters(in: secret, with: candidate)
            guard let swapped = matcher.matches(in: line, budget: budget) else {
                complete = false
                return nil
            }
            guard swapped.contains(where: { NSEqualRanges($0.redactRange, secret) && NSEqualRanges($0.range, match.range) }) else { continue }
            if case .passAnnotated(let kind) = result { return .some(kind) }
            return .some(nil)
        }
        return nil
    }

    /// Variants are worth their cost only on a line with a long letter-digit fragment no vendor finding covers yet,
    /// a `<` run, or two secret-shaped runs one space apart.
    func needsVariants(_ text: String, findings: [Finding]) -> Bool {
        let units = Array(text.utf16)
        let vendor = findings.filter { $0.category != .config }.map(\.secretRange)
        let uncovered = MisreadCandidates.fragments(units).contains { fragment in
            fragment.count >= MisreadCandidates.longFragment
                && !vendor.contains { NSLocationInRange(fragment.lowerBound, $0) && NSMaxRange($0) >= fragment.upperBound }
        }
        return uncovered || units.filter({ $0 == 0x3C }).count >= 3
    }

    func finding(_ hit: RangedHit, _ protected: PatternMatch, lineIndex: Int, text: String) -> Finding {
        Finding(lineIndex: lineIndex, range: protected.range, secretRange: protected.redactRange,
                detectorIDs: [hit.detector.detector.id], category: hit.detector.detector.category,
                severity: hit.detector.detector.severity, subkind: hit.subkind,
                textForLogs: Finding.logDigest(of: substring(text, protected.redactRange)), unverified: hit.unverified)
    }

    // MARK: allow rules (§6)

    /// The allow ranges on `text`. A rule whose search is stopped by `budget` protects nothing on this line, so the
    /// line is covered as if the rule were off (the safe direction).
    func allowRanges(in text: String, budget: MatchBudget) -> [AllowRange] {
        catalogue.allowRules.flatMap { compiled in
            (compiled.matcher.matches(in: text, budget: budget) ?? []).map {
                AllowRange(range: $0.redactRange, suppressPartialOverlap: compiled.rule.suppressPartialOverlap)
            }
        }
    }

    /// Applies allow protection to one match. Returns zero, one or (trim mode, allow range strictly inside) two matches.
    func applyAllow(_ match: PatternMatch, _ allows: [AllowRange]) -> [PatternMatch] {
        var pieces = [match]
        for a in allows {
            var next: [PatternMatch] = []
            for m in pieces {
                let secret = m.redactRange
                let overlap = NSIntersectionRange(a.range, secret)
                guard overlap.length > 0 else { next.append(m); continue }
                if NSEqualRanges(NSUnionRange(a.range, secret), a.range) { continue }           // fully contained → drop
                if a.suppressPartialOverlap { continue }                                         // opt-in partial suppression
                switch allowRuleMode {
                case .containedOnly:
                    next.append(m)
                case .trim:
                    let secretEnd = NSMaxRange(secret), allowEnd = NSMaxRange(a.range)
                    if secret.location < a.range.location {
                        let left = NSRange(location: secret.location, length: a.range.location - secret.location)
                        next.append(PatternMatch(range: NSUnionRange(m.range, left), secretRange: left))
                    }
                    if allowEnd < secretEnd {
                        let right = NSRange(location: allowEnd, length: secretEnd - allowEnd)
                        next.append(PatternMatch(range: NSUnionRange(m.range, right), secretRange: right))
                    }
                }
            }
            pieces = next
        }
        return pieces
    }

    // MARK: merge (§8)

    /// Union-merges `new` into any existing finding whose secretRange it intersects; the existing finding keeps its
    /// label owner, appends the new detector ids and takes the max severity. Adjacent ranges are not merged.
    static func merge(_ new: Finding, into findings: inout [Finding]) {
        var merged = new
        var survivors: [Finding] = []
        var absorbedOne = false
        for existing in findings {
            guard NSIntersectionRange(existing.secretRange, merged.secretRange).length > 0 else {
                survivors.append(existing)
                continue
            }
            // The earliest existing finding (catalogue order) is the base and keeps its id and label owner;
            // a cascade (new match bridging two existing findings) appends the later one's ids.
            let base = absorbedOne ? merged : existing
            let other = absorbedOne ? existing : merged
            var ids = base.detectorIDs
            for id in other.detectorIDs where !ids.contains(id) { ids.append(id) }
            merged = Finding(
                id: base.id, lineIndex: base.lineIndex,
                range: NSUnionRange(base.range, other.range),
                secretRange: NSUnionRange(base.secretRange, other.secretRange),
                detectorIDs: ids, category: base.category, severity: max(base.severity, other.severity),
                wholeLine: false, blockID: nil, subkind: base.subkind ?? other.subkind,
                textForLogs: base.textForLogs, unverified: base.unverified && other.unverified
            )
            absorbedOne = true
        }
        survivors.append(merged)
        findings = survivors
    }

    func merge(_ new: Finding, into findings: inout [Finding]) { Self.merge(new, into: &findings) }

    static func substring(_ text: String, _ range: NSRange) -> String {
        guard let r = Range(range, in: text) else { return "" }
        return String(text[r])
    }

    func substring(_ text: String, _ range: NSRange) -> String { Self.substring(text, range) }
}
