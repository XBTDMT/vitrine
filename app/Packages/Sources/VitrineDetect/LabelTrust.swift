// VitrineDetect — G-12 route D's shared half: the secret-looking labels are the ones the generic config detectors
// (config.env.secret, config.labelled.password, config.yaml.secret, and since G-16 config.labelled.secret for labels in
// plain words) already match. Their own patterns are the lexicon,
// so the label trigger for the zoomed re-read (route A) and the covers can never disagree about what a label is.
public import Foundation

public enum LabelTrust {
    /// The built-in detectors whose patterns define "a value after a secret-looking key name".
    public static let labelDetectorIDs: Set<String> = ["config.env.secret", "config.labelled.password", "config.yaml.secret", "config.labelled.secret"]

    /// Their compiled patterns, from the built-in catalogue (whatever the user's enable state: this is a trigger, not a finding).
    static var matchers: [ICURegexMatcher] { labelled.map(\.matcher) }

    /// The same patterns, each with the id of the detector it belongs to.
    static let labelled: [(id: String, matcher: ICURegexMatcher)] = BuiltInCatalogue.all
        .filter { labelDetectorIDs.contains($0.id) }
        .flatMap { detector in detector.patterns.compactMap { spec in (try? ICURegexMatcher(pattern: try spec.compiledPattern())).map { (detector.id, $0) } } }

    /// The labelled value ranges on `text` (folded first, like the Scanner): each pattern's `secret` group.
    public static func labelledValues(in text: String) -> [NSRange] {
        let folded = ConfusableFold.fold(text)
        return matchers.flatMap { $0.matches(in: folded) }.map(\.redactRange)
    }

    /// A value on a line whose reading fell short of its ink (G-22) that is covered although no detector reported it.
    public struct ShortReadCandidate: Sendable, Hashable {
        /// UTF-16 range on the line's text: where the cover starts (it then runs to the end of the line's ink).
        public let range: NSRange
        public let detectorID: String
        public let category: Detector.Category
    }

    /// G-22's rule for a short-read line with no finding: a short read can cut a value below its detector's minimum
    /// length or break its checksum, so the line is judged by how a secret STARTS, not by the whole value:
    /// 1. every labelled value (this lexicon: the config detectors' patterns, whatever their enable state, like the
    ///    re-read trigger), from the value's first unit;
    /// 2. every token that begins with a literal vendor prefix (a `.prefix` pattern of an enabled detector in
    ///    `catalogue`, built-in or custom, with that pattern's case rule), from the prefix's first unit. A token begins
    ///    where the text starts or after a character that is not a letter, digit, `_` or `-`.
    /// Ranges run from that start to the end of the token (the next whitespace); the caller covers on to the ink's end.
    public static func shortReadCandidates(in text: String, catalogue: CompiledCatalogue) -> [ShortReadCandidate] {
        let folded = ConfusableFold.fold(text)
        var result: [ShortReadCandidate] = []
        for (id, matcher) in labelled {
            for match in matcher.matches(in: folded) where match.redactRange.length > 0 {
                result.append(ShortReadCandidate(range: tokenRange(from: match.redactRange.location, in: folded), detectorID: id, category: .config))
            }
        }
        let units = Array(folded.utf16)
        for compiled in catalogue.detectors {
            for spec in compiled.detector.patterns where spec.kind == .prefix {
                let prefix = spec.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prefix.isEmpty else { continue }
                let options: String.CompareOptions = spec.caseSensitive ? [] : [.caseInsensitive]
                var searchStart = folded.startIndex
                while let found = folded.range(of: prefix, options: options, range: searchStart..<folded.endIndex) {
                    let location = folded.utf16.distance(from: folded.utf16.startIndex, to: found.lowerBound)
                    if location == 0 || !isTokenUnit(units[location - 1]) {
                        result.append(ShortReadCandidate(range: tokenRange(from: location, in: folded), detectorID: compiled.detector.id,
                                                         category: compiled.detector.category))
                    }
                    searchStart = found.upperBound
                }
            }
        }
        return result
    }

    /// From `location` to the next whitespace (or the end of `text`).
    static func tokenRange(from location: Int, in text: String) -> NSRange {
        let units = Array(text.utf16)
        var end = location
        while end < units.count, !(Unicode.Scalar(units[end]).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false) { end += 1 }
        return NSRange(location: location, length: end - location)
    }

    static func isTokenUnit(_ unit: UTF16.CodeUnit) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
    }

    /// `index` of every line that carries a labelled value no vendor detector recognized: no finding outside the
    /// `.config` category intersects the value. These are the lines worth reading again, zoomed (route A).
    public static func unrecognizedLabelLines(_ lines: [ScanLine], findings: [Finding]) -> Set<Int> {
        var vendor: [Int: [NSRange]] = [:]
        for finding in findings where finding.category != .config && !finding.wholeLine {
            vendor[finding.lineIndex, default: []].append(finding.secretRange)
        }
        var result = Set<Int>()
        for line in lines {
            let values = labelledValues(in: line.text)
            guard !values.isEmpty else { continue }
            let recognized = vendor[line.index] ?? []
            if values.contains(where: { value in !recognized.contains { NSIntersectionRange($0, value).length > 0 } }) {
                result.insert(line.index)
            }
        }
        return result
    }
}
