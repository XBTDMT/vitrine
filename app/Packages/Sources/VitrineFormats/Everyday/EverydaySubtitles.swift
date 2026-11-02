import Foundation
import VitrineData

/// What a subtitle or timed-lyrics file holds (N-3): its cues with timings, text and style or speaker, how long it
/// runs, its languages, and timing problems a viewer would notice (overlapping cues, long silences, lines shown too
/// briefly to read). Times are seconds from the start of the media. roadmap: S-23
public struct SubtitleSummary: Sendable, Equatable {
    /// The subtitle format the file is written in. roadmap: S-23
    public enum Format: String, Sendable, Equatable {
        case srt, webVTT, ass, ssa, ttml, lrc

        public var displayName: String {
            switch self {
            case .srt: "SubRip"
            case .webVTT: "WebVTT"
            case .ass: "Advanced SubStation Alpha"
            case .ssa: "SubStation Alpha"
            case .ttml: "TTML"
            case .lrc: String(localized: "LRC lyrics", bundle: .module, comment: "Name of the LRC timed-lyrics format on a subtitle card.")
            }
        }
    }

    /// One timed piece of text. roadmap: S-23
    public struct Cue: Sendable, Equatable {
        /// 1-based position in the file (after sorting, for LRC).
        public var index: Int
        /// The cue's own identifier when the format has one (an SRT number, a WebVTT cue id, a TTML xml:id).
        public var identifier: String?
        public var start: TimeInterval
        /// For LRC, the next line's start (the last line ends where it starts).
        public var end: TimeInterval
        /// The text as a viewer sees it: markup and override tags removed, line breaks kept as "\n".
        public var text: String
        /// The style name (ASS style, TTML style, WebVTT class).
        public var style: String?
        /// The speaker (ASS Name, WebVTT `<v>` voice, TTML agent).
        public var speaker: String?
        /// WebVTT cue settings as written (`line:0 align:start`), ASS layer and margins are not kept.
        public var settings: String?

        public var duration: TimeInterval { max(0, end - start) }

        public init(index: Int, identifier: String? = nil, start: TimeInterval, end: TimeInterval, text: String,
                    style: String? = nil, speaker: String? = nil, settings: String? = nil) {
            self.index = index
            self.identifier = identifier
            self.start = start
            self.end = end
            self.text = text
            self.style = style
            self.speaker = speaker
            self.settings = settings
        }
    }

    /// A stretch with no cue on screen, longer than `SubtitleSummary.longGapSeconds`. roadmap: S-23
    public struct Gap: Sendable, Equatable {
        /// The cue the silence follows (its `index`).
        public var afterCue: Int
        public var start: TimeInterval
        public var length: TimeInterval
    }

    /// A named style the file declares (ASS styles, TTML styles, WebVTT STYLE blocks). roadmap: S-23
    public struct Style: Sendable, Equatable {
        public var name: String
        /// The font family when the style names one.
        public var font: String?
        /// The font size as written.
        public var size: String?
    }

    /// Silences at least this long are listed in `longGaps`.
    public static let longGapSeconds: TimeInterval = 60
    /// Above this many characters per second a line is hard to read (a common subtitling guideline).
    public static let readableCharactersPerSecond: Double = 20
    /// The most cues kept in `cues`; the rest are still counted and timed.
    public static let maxCues = 20_000

    public var format: Format
    public var title: String?
    /// Header facts as written: LRC tags (`ar`, `ti`, `al`, `by`, `offset`), ASS [Script Info] keys, WebVTT header
    /// lines, TTML metadata.
    public var metadata: [EverydayFact]
    /// Language tags the file states (TTML xml:lang, WebVTT `Language:` header, LRC `la`, ASS `Language`).
    public var languages: [String]
    public var cues: [Cue]
    /// Every cue counted, even past `maxCues`.
    public var cueCount: Int
    /// The last moment any cue is on screen.
    public var totalDuration: TimeInterval
    public var styles: [Style]
    /// WebVTT NOTE blocks (comments), at most 100.
    public var notes: [String]
    /// Pairs of consecutive cues (in start order) whose times overlap.
    public var overlapCount: Int
    public var longGaps: [Gap]
    /// The highest characters per second over cues with a duration, and which cue it is; nil for LRC (lyrics are
    /// sung, not read) and when no cue has a duration.
    public var maxCharactersPerSecond: Double?
    public var maxCharactersPerSecondCue: Int?
    /// Blocks or lines that looked like cues but could not be read.
    public var skippedCount: Int
    public var warnings: [EverydayWarning]
    public var truncated: Bool

    public init(format: Format, title: String? = nil, metadata: [EverydayFact] = [], languages: [String] = [],
                cues: [Cue] = [], cueCount: Int = 0, totalDuration: TimeInterval = 0, styles: [Style] = [],
                notes: [String] = [], overlapCount: Int = 0, longGaps: [Gap] = [], maxCharactersPerSecond: Double? = nil,
                maxCharactersPerSecondCue: Int? = nil, skippedCount: Int = 0, warnings: [EverydayWarning] = [],
                truncated: Bool = false) {
        self.format = format
        self.title = title
        self.metadata = metadata
        self.languages = languages
        self.cues = cues
        self.cueCount = cueCount
        self.totalDuration = totalDuration
        self.styles = styles
        self.notes = notes
        self.overlapCount = overlapCount
        self.longGaps = longGaps
        self.maxCharactersPerSecond = maxCharactersPerSecond
        self.maxCharactersPerSecondCue = maxCharactersPerSecondCue
        self.skippedCount = skippedCount
        self.warnings = warnings
        self.truncated = truncated
    }

    public var headline: String {
        title ?? String(localized: "\(format.displayName) subtitles", bundle: .module,
                                comment: "Headline of a subtitle card with no title; the argument is the format name (SubRip, WebVTT…).")
    }

    public var facts: [EverydayFact] {
        var facts = [EverydayFact(String(localized: "Format", bundle: .module, comment: "Fact label on a subtitle card."), format.displayName),
                     EverydayFact(format == .lrc
                                    ? String(localized: "Lines", bundle: .module, comment: "Fact label on a timed-lyrics card: number of timed lines.")
                                    : String(localized: "Cues", bundle: .module, comment: "Fact label on a subtitle card: number of cues."),
                                  "\(cueCount)"),
                     EverydayFact(String(localized: "Duration", bundle: .module, comment: "Fact label on a subtitle card: when the last cue ends."),
                                  SubtitleSummary.clock(totalDuration))]
        if !languages.isEmpty {
            facts.append(EverydayFact(String(localized: "Language", bundle: .module, comment: "Fact label on a subtitle card: language tags."),
                                      languages.joined(separator: ", ")))
        }
        if !styles.isEmpty {
            facts.append(EverydayFact(String(localized: "Styles", bundle: .module, comment: "Fact label on a subtitle card: declared styles."), "\(styles.count)"))
        }
        if let cps = maxCharactersPerSecond {
            let value = cps.formatted(.number.precision(.fractionLength(1)))
            facts.append(EverydayFact(String(localized: "Fastest cue", bundle: .module, comment: "Fact label on a subtitle card: the highest reading speed."),
                                      String(localized: "\(value) characters/s", bundle: .module,
                                             comment: "Reading speed of a subtitle cue; the argument is a decimal number.")))
        }
        if overlapCount > 0 {
            facts.append(EverydayFact(String(localized: "Overlaps", bundle: .module, comment: "Fact label on a subtitle card: overlapping cues."), "\(overlapCount)"))
        }
        if !longGaps.isEmpty {
            facts.append(EverydayFact(String(localized: "Long gaps", bundle: .module, comment: "Fact label on a subtitle card: silences over a minute."), "\(longGaps.count)"))
        }
        return facts
    }

    /// `h:mm:ss` (or `m:ss` under an hour) for a card; "—" for a time no clock can show (a file can write any number
    /// of hours, past what an Int holds).
    public static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, let total = FormatMath.int(rounding: max(0, seconds)) else { return "—" }
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The subtitle parsers behind `SubtitleSummary`.
enum EverydaySubtitles {
    static func read(_ bytes: [UInt8], format: SubtitleSummary.Format?) -> SubtitleSummary? {
        let text = EverydayText.decode(bytes)
        let chosen = format ?? detect(text)
        var summary: SubtitleSummary
        switch chosen {
        case .srt: summary = readSRT(text)
        case .webVTT: summary = readVTT(text)
        case .ass, .ssa: summary = readASS(text, declared: chosen)
        case .ttml:
            guard let ttml = readTTML(bytes) else { return nil }
            summary = ttml
        case .lrc: summary = readLRC(text)
        }
        finish(&summary)
        return summary
    }

    static func detect(_ text: String) -> SubtitleSummary.Format {
        let head = text.prefix(2048)
        if head.uppercased().contains("[SCRIPT INFO]") {
            return head.contains("[V4+ Styles]") || head.contains("ScriptType: v4.00+") ? .ass : .ssa
        }
        return .srt
    }

    static func looksLikeSRT(_ head: String) -> Bool {
        let lines = EverydayText.lines(head).prefix(4)
        return lines.contains { $0.contains("-->") && parseTimingLine($0) != nil }
    }

    // MARK: Shared finishing: counts, overlaps, gaps, reading speed, warnings

    static func finish(_ s: inout SubtitleSummary) {
        if s.format != .lrc { s.cues.sort { ($0.start, $0.index) < ($1.start, $1.index) } }
        if s.cues.count > SubtitleSummary.maxCues {
            s.cues.removeSubrange(SubtitleSummary.maxCues...)
            s.truncated = true
        }
        var overlaps = 0, gaps: [SubtitleSummary.Gap] = [], maxEnd: TimeInterval = 0
        var bestCPS: Double?, bestCue: Int?, backwards = 0
        for (i, cue) in s.cues.enumerated() {
            if cue.end < cue.start { backwards += 1 }
            if i > 0 {
                if cue.start < maxEnd - 0.0005 { overlaps += 1 }
                if cue.start - maxEnd >= SubtitleSummary.longGapSeconds, gaps.count < 100 {
                    gaps.append(.init(afterCue: s.cues[i - 1].index, start: maxEnd, length: cue.start - maxEnd))
                }
            }
            maxEnd = max(maxEnd, cue.end, cue.start)
            if s.format != .lrc, cue.duration > 0 {
                let characters = cue.text.filter { $0 != "\n" }.count
                let cps = Double(characters) / cue.duration
                if cps > (bestCPS ?? -1) { bestCPS = cps; bestCue = cue.index }
            }
        }
        if s.format == .lrc { overlaps = 0 }
        s.overlapCount = overlaps
        s.longGaps = gaps
        s.totalDuration = max(s.totalDuration, maxEnd)
        s.maxCharactersPerSecond = bestCPS.map { ($0 * 10).rounded() / 10 }
        s.maxCharactersPerSecondCue = bestCue
        if s.cueCount < s.cues.count { s.cueCount = s.cues.count }

        if let cps = bestCPS, cps > SubtitleSummary.readableCharactersPerSecond, let cue = bestCue {
            let speed = ((cps * 10).rounded() / 10).formatted(.number.precision(.fractionLength(1)))
            s.warnings.append(EverydayWarning(.caution, code: "subtitles.hardToRead",
                reason: String(localized: "Cue \(cue) shows \(speed) characters a second, which is hard to read (above 20).", bundle: .module,
                               comment: "Warning on a subtitle card; the first argument is the cue number, the second a decimal reading speed.")))
        }
        if overlaps > 0, s.format == .srt || s.format == .webVTT {
            s.warnings.append(EverydayWarning(.caution, code: "subtitles.overlap",
                reason: String(localized: "\(overlaps) cues start before the one before them has ended.", bundle: .module,
                               comment: "Warning on a subtitle card; the argument is a count of cues.")))
        }
        if backwards > 0 {
            s.warnings.append(EverydayWarning(.caution, code: "subtitles.endBeforeStart",
                reason: String(localized: "\(backwards) cues end before they start.", bundle: .module,
                               comment: "Warning on a subtitle card; the argument is a count of cues.")))
        }
        if s.skippedCount > 0 {
            s.warnings.append(EverydayWarning(.caution, code: "subtitles.unreadable",
                reason: String(localized: "\(s.skippedCount) blocks could not be read as cues.", bundle: .module,
                               comment: "Warning on a subtitle card; the argument is a count of text blocks.")))
        }
        if s.cueCount == 0 {
            s.warnings.append(EverydayWarning(.caution, code: "subtitles.empty",
                reason: String(localized: "The file has no cues.", bundle: .module, comment: "Warning on a subtitle card.")))
        }
    }

    // MARK: Time stamps

    /// `hh:mm:ss,ttt`, `hh:mm:ss.ttt`, `mm:ss.ttt`, `h:mm:ss.cc`; nil when not a time.
    static func parseClock<S: StringProtocol>(_ raw: S) -> TimeInterval? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for (i, part) in parts.enumerated() {
            let isLast = i == parts.count - 1
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isNumber || (isLast && $0 == ".")) }),
                  let value = Double(part), value >= 0 else { return nil }
            if !isLast, value != value.rounded() { return nil }
            total = total * 60 + value
        }
        return total.isFinite ? total : nil
    }

    /// The start, end and anything after the end time (WebVTT cue settings) of a `start --> end` line.
    static func parseTimingLine<S: StringProtocol>(_ line: S) -> (TimeInterval, TimeInterval, String?)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = line[..<arrow.lowerBound]
        let right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let endToken = right.prefix { !$0.isWhitespace }
        let rest = right.dropFirst(endToken.count).trimmingCharacters(in: .whitespaces)
        guard let start = parseClock(left), let end = parseClock(endToken) else { return nil }
        return (start, end, rest.isEmpty ? nil : rest)
    }

    // MARK: Markup

    /// HTML-like tags (`<i>`, `<font …>`, `<c.class>`, `<00:01.000>`) and SRT/ASS `{\an8}` codes removed.
    static func stripTags(_ text: String, speaker: inout String?, classes: inout String?) -> String {
        var out = ""
        var i = text.startIndex
        // Once a search finds no closing ">" or "}", none is looked for again (keeps unclosed text linear).
        var noMoreAngle = false, noMoreBrace = false
        while i < text.endIndex {
            let c = text[i]
            if c == "<", !noMoreAngle {
                guard let close = text[i...].firstIndex(of: ">") else {
                    noMoreAngle = true
                    out.append(c)
                    i = text.index(after: i)
                    continue
                }
                let tag = text[text.index(after: i)..<close]
                if tag.hasPrefix("v ") || tag.hasPrefix("v.") {
                    let body = tag.drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
                    if speaker == nil, !body.isEmpty { speaker = body }
                } else if tag.hasPrefix("c."), classes == nil {
                    classes = tag.dropFirst(2).split(separator: ".").joined(separator: " ")
                }
                i = text.index(after: close)
                continue
            }
            if c == "{", !noMoreBrace, text[text.index(after: i)...].hasPrefix("\\") {
                if let close = text[i...].firstIndex(of: "}") {
                    i = text.index(after: close)
                    continue
                }
                noMoreBrace = true
            }
            out.append(c)
            i = text.index(after: i)
        }
        return decodeEntities(out)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lrm;", with: "")
            .replacingOccurrences(of: "&rlm;", with: "").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Blank-line separated blocks of non-empty lines.
    static func blocks(_ text: String) -> [[Substring]] {
        var result: [[Substring]] = []
        var current: [Substring] = []
        for line in EverydayText.lines(text) {
            if line.allSatisfy({ $0.isWhitespace }) {
                if !current.isEmpty { result.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: SubRip

    static func readSRT(_ text: String) -> SubtitleSummary {
        var s = SubtitleSummary(format: .srt)
        for block in blocks(text) {
            guard let timingAt = block.prefix(3).firstIndex(where: { $0.contains("-->") }),
                  let (start, end, _) = parseTimingLine(block[timingAt]) else {
                s.skippedCount += 1
                continue
            }
            s.cueCount += 1
            guard s.cues.count < SubtitleSummary.maxCues + 1 else { continue }
            let identifier = timingAt > 0 ? block[timingAt - 1].trimmingCharacters(in: .whitespaces) : nil
            var speaker: String?, classes: String?
            let raw = block[(timingAt + 1)...].joined(separator: "\n")
            let text = stripTags(raw, speaker: &speaker, classes: &classes)
            s.cues.append(.init(index: s.cueCount, identifier: identifier, start: start, end: end, text: text))
        }
        return s
    }

    // MARK: WebVTT

    static func readVTT(_ text: String) -> SubtitleSummary {
        var s = SubtitleSummary(format: .webVTT)
        var all = blocks(text)
        if let header = all.first, header.first?.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("WEBVTT") == true {
            all.removeFirst()
            let firstLine = header[0].trimmingCharacters(in: .whitespaces)
            let label = firstLine.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: " \t-"))
            if !label.isEmpty { s.title = label }
            for line in header.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), !line.contains("-->") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                s.metadata.append(EverydayFact(key, value))
                if key.lowercased() == "language", !value.isEmpty { s.languages.append(value) }
            }
        } else {
            s.warnings.append(EverydayWarning(.caution, code: "subtitles.missingHeader",
                reason: String(localized: "The file does not start with WEBVTT, so players may refuse it.", bundle: .module,
                               comment: "Warning on a subtitle card. WEBVTT is the required header word and stays as it is.")))
        }
        for block in all {
            let first = block[0].trimmingCharacters(in: .whitespaces)
            if first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t") {
                if s.notes.count < 100 {
                    let body = ([first.dropFirst(4).trimmingCharacters(in: .whitespaces)] + block.dropFirst().map(String.init))
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                    s.notes.append(body)
                }
                continue
            }
            if first == "STYLE" {
                let css = block.dropFirst().joined(separator: "\n")
                for name in cssSelectors(css) where s.styles.count < 500 {
                    s.styles.append(.init(name: name, font: nil, size: nil))
                }
                continue
            }
            if first == "REGION" { continue }
            guard let timingAt = block.prefix(2).firstIndex(where: { $0.contains("-->") }),
                  let (start, end, settings) = parseTimingLine(block[timingAt]) else {
                s.skippedCount += 1
                continue
            }
            s.cueCount += 1
            guard s.cues.count < SubtitleSummary.maxCues + 1 else { continue }
            var speaker: String?, classes: String?
            let raw = block[(timingAt + 1)...].joined(separator: "\n")
            for tag in languageTags(raw) {
                if !s.languages.contains(tag), s.languages.count < 50 { s.languages.append(tag) }
            }
            let text = stripTags(raw, speaker: &speaker, classes: &classes)
            let identifier = timingAt > 0 ? block[0].trimmingCharacters(in: .whitespaces) : nil
            s.cues.append(.init(index: s.cueCount, identifier: identifier, start: start, end: end, text: text,
                                style: classes, speaker: speaker, settings: settings))
        }
        return s
    }

    /// The tags of `<lang xx>` spans in cue text, in order: what the regex `<lang ([^>]+)>` matched, in one pass.
    /// The regex looked for the closing ">" again from every `<lang `, so text made of `<lang ` with no ">" cost
    /// O(n²); here the search for ">" stops for good once it has failed, and a found ">" ends the match.
    static func languageTags(_ text: String) -> [String] {
        var tags: [String] = []
        var from = text.startIndex
        while let open = text[from...].firstRange(of: "<lang ") {
            guard let close = text[open.upperBound...].firstIndex(of: ">") else { break }   // no ">" anywhere after
            if close > open.upperBound {
                tags.append(String(text[open.upperBound..<close]))
                from = text.index(after: close)
            } else {
                from = open.upperBound                                // `<lang >`: no tag; look further on
            }
        }
        return tags
    }

    /// `::cue(.yellow)` → "yellow", `::cue(v[voice="Ana"])` → `v[voice="Ana"]`, plain `::cue` → "cue".
    ///
    /// What the regex `::cue(\(([^)]*)\))?\s*\{` matched, in one pass. The regex ran to the end of the block
    /// looking for ")" from every `::cue(`, so a STYLE block of repeated `::cue(` cost O(n²). Here the position of
    /// the next ")" is remembered: every `::cue(` before it shares it, and once none is found none is looked for.
    static func cssSelectors(_ css: String) -> [String] {
        var names: [String] = []
        var nextClose: (after: String.Index, at: String.Index?)?   // the first ")" at or after `after`, if any
        func firstClose(from position: String.Index) -> String.Index? {
            if let known = nextClose, known.after <= position, known.at.map({ position <= $0 }) ?? true { return known.at }
            let found = css[position...].firstIndex(of: ")")
            nextClose = (position, found)
            return found
        }
        var from = css.startIndex
        while let cue = css[from...].firstRange(of: "::cue") {
            var i = cue.upperBound
            var inside: Range<String.Index>?
            if i < css.endIndex, css[i] == "(" {
                // A "(" with no ")" after it leaves "::cue" followed by "(", which `\s*\{` cannot match either.
                guard let close = firstClose(from: css.index(after: i)) else { from = cue.upperBound; continue }
                inside = css.index(after: i)..<close
                i = css.index(after: close)
            }
            while i < css.endIndex, css[i].isWhitespace { i = css.index(after: i) }
            guard i < css.endIndex, css[i] == "{" else { from = cue.upperBound; continue }
            // Copied only once the selector is known to match, so failed candidates cost nothing.
            var name = inside.map { String(css[$0]) } ?? "cue"
            if name.hasPrefix(".") { name.removeFirst() }
            if !names.contains(name) { names.append(name) }
            from = css.index(after: i)
        }
        return names
    }

    // MARK: SubStation Alpha / Advanced SubStation Alpha

    static func readASS(_ text: String, declared: SubtitleSummary.Format) -> SubtitleSummary {
        var s = SubtitleSummary(format: declared)
        var section = ""
        var styleFormat: [String] = []
        var eventFormat: [String] = []
        for rawLine in EverydayText.lines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("!:") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.lowercased()
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch section {
            case "[script info]":
                if s.metadata.count < 100 { s.metadata.append(EverydayFact(key, value)) }
                switch key.lowercased() {
                case "title": if !value.isEmpty, value != "<untitled>" { s.title = value }
                case "language": if !value.isEmpty { s.languages.append(value) }
                case "scripttype":
                    if value.lowercased().contains("v4.00+") { s.format = .ass } else if value.lowercased() == "v4.00" { s.format = .ssa }
                default: break
                }
            case "[v4+ styles]", "[v4 styles]", "[v4 styles+]":
                if key.lowercased() == "format" {
                    styleFormat = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                } else if key.lowercased() == "style", s.styles.count < 500 {
                    let fields = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    func field(_ name: String, _ fallback: Int) -> String? {
                        let i = styleFormat.firstIndex(of: name) ?? fallback
                        return i < fields.count && !fields[i].isEmpty ? fields[i] : nil
                    }
                    if let name = field("name", 0) {
                        s.styles.append(.init(name: name, font: field("fontname", 1), size: field("fontsize", 2)))
                    }
                }
            case "[events]":
                let lower = key.lowercased()
                if lower == "format" {
                    eventFormat = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                } else if lower == "dialogue" {
                    let format = eventFormat.isEmpty
                        ? ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
                        : eventFormat
                    let fields = value.split(separator: ",", maxSplits: max(0, format.count - 1), omittingEmptySubsequences: false)
                        .map(String.init)
                    func field(_ name: String) -> String? {
                        guard let i = format.firstIndex(of: name), i < fields.count else { return nil }
                        return i == format.count - 1 ? fields[i] : fields[i].trimmingCharacters(in: .whitespaces)
                    }
                    guard let start = field("start").flatMap(parseClock), let end = field("end").flatMap(parseClock),
                          let raw = field("text") else {
                        s.skippedCount += 1
                        continue
                    }
                    s.cueCount += 1
                    guard s.cues.count < SubtitleSummary.maxCues + 1 else { continue }
                    s.cues.append(.init(index: s.cueCount, start: start, end: end, text: assText(raw),
                                        style: field("style").flatMap { $0.isEmpty ? nil : $0 },
                                        speaker: field("name").flatMap { $0.isEmpty ? nil : $0 }))
                }
            default: break
            }
        }
        return s
    }

    /// ASS dialogue text for display: `{…}` override blocks removed, `\N` and `\n` as line breaks, `\h` as a space.
    static func assText(_ raw: String) -> String {
        var out = ""
        var depth = 0
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "{" { depth += 1 } else if c == "}", depth > 0 { depth -= 1 } else if depth == 0 {
                if c == "\\", raw.index(after: i) < raw.endIndex {
                    let next = raw[raw.index(after: i)]
                    if next == "N" || next == "n" { out.append("\n"); i = raw.index(i, offsetBy: 2); continue }
                    if next == "h" { out.append(" "); i = raw.index(i, offsetBy: 2); continue }
                }
                out.append(c)
            }
            i = raw.index(after: i)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: LRC

    static func readLRC(_ text: String) -> SubtitleSummary {
        var s = SubtitleSummary(format: .lrc)
        var offset: TimeInterval = 0
        var timed: [(TimeInterval, Int, String)] = []
        var order = 0
        for rawLine in EverydayText.lines(text) {
            var line = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            guard line.hasPrefix("[") else { continue }
            var stamps: [TimeInterval] = []
            var sawTag = false
            while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let inside = line[line.index(after: line.startIndex)..<close]
                if let time = parseClock(inside) {
                    stamps.append(time)
                } else if let colon = inside.firstIndex(of: ":") {
                    let key = inside[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = inside[inside.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    sawTag = true
                    if s.metadata.count < 100 { s.metadata.append(EverydayFact(key, value)) }
                    switch key {
                    case "ti": if !value.isEmpty { s.title = value }
                    case "la", "lang": if !value.isEmpty { s.languages.append(value) }
                    case "offset": offset = (Double(value.replacingOccurrences(of: "+", with: "")) ?? 0) / 1000
                    case "length": if let length = parseClock(value) { s.totalDuration = length }
                    default: break
                    }
                } else {
                    break
                }
                line = line[line.index(after: close)...]
            }
            if stamps.isEmpty {
                if !sawTag { s.skippedCount += 1 }
                continue
            }
            let words = String(line).replacing(/<\d+:\d+(?:[.:]\d+)?>/, with: "").trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                order += 1
                timed.append((max(0, stamp - offset), order, words))
            }
        }
        timed.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        s.cueCount = timed.count
        for (i, entry) in timed.prefix(SubtitleSummary.maxCues + 1).enumerated() {
            let end = i + 1 < timed.count ? timed[i + 1].0 : entry.0
            s.cues.append(.init(index: i + 1, start: entry.0, end: end, text: entry.2))
        }
        return s
    }

    // MARK: TTML / DFXP

    static func readTTML(_ bytes: [UInt8]) -> SubtitleSummary? {
        var options = StructuredOptions()
        options.maxPreviewBytes = 16 * 1024
        options.maxNodes = 1_000_000
        options.maxInputBytes = Int64(EverydayReader.maxBytes)
        let result = StructuredParser.parse(Data(bytes), format: .xml, options: options)
        let tree = result.tree
        guard let root = tree.roots.first(where: { tree[$0].role == .element }),
              localName(tree[root].name) == "tt" else { return nil }
        var s = SubtitleSummary(format: .ttml)
        if !result.coverage.isComplete { s.truncated = true }
        if result.error != nil {
            s.warnings.append(EverydayWarning(.caution, code: "subtitles.xmlError",
                reason: String(localized: "The XML is not well formed; only the part before the error was read.", bundle: .module,
                               comment: "Warning on a TTML subtitle card.")))
        }

        func attributes(_ node: Int) -> [String: String] {
            var map: [String: String] = [:]
            for child in tree.children(of: node) where tree[child].role == .attribute {
                if let name = tree[child].name { map[name] = tree[child].preview }
            }
            return map
        }
        func attr(_ map: [String: String], _ local: String) -> String? {
            if let v = map[local] { return v }
            return map.first { localName($0.key) == local && $0.key.contains(":") }?.value
        }
        let rootAttrs = attributes(root)
        let timing = TTMLTiming(frameRate: attr(rootAttrs, "frameRate").flatMap(Double.init) ?? 30,
                                multiplier: attr(rootAttrs, "frameRateMultiplier").flatMap(TTMLTiming.multiplier) ?? 1,
                                subFrameRate: attr(rootAttrs, "subFrameRate").flatMap(Double.init) ?? 1,
                                tickRate: attr(rootAttrs, "tickRate").flatMap(Double.init))
        func addLanguage(_ map: [String: String]) {
            if let lang = map["xml:lang"], !lang.isEmpty, !s.languages.contains(lang), s.languages.count < 50 {
                s.languages.append(lang)
            }
        }
        addLanguage(rootAttrs)

        // Walk the flat pre-order tree with an explicit stack of (node, inherited begin, inherited style).
        var stack: [(Int, TimeInterval, TimeInterval?)] = [(root, 0, nil)]
        var unreadableTimes = 0
        while let (node, parentBegin, parentEnd) = stack.popLast() {
            let name = localName(tree[node].name)
            let map = attributes(node)
            switch name {
            case "style":
                if let id = map["xml:id"] ?? map["id"], s.styles.count < 500 {
                    s.styles.append(.init(name: id, font: attr(map, "fontFamily"), size: attr(map, "fontSize")))
                }
                continue
            case "title":
                let text = textContent(tree, node)
                if !text.isEmpty { s.title = text; s.metadata.append(EverydayFact("title", text)) }
                continue
            case "desc", "copyright", "agent":
                let text = textContent(tree, node)
                if !text.isEmpty, s.metadata.count < 100 { s.metadata.append(EverydayFact(name, text)) }
                if name != "agent" { continue }
            default: break
            }
            addLanguage(map)
            var begin = parentBegin
            var end = parentEnd
            if let b = attr(map, "begin") {
                if let value = timing.parse(b) { begin = parentBegin + value } else { unreadableTimes += 1 }
            }
            if let e = attr(map, "end") {
                if let value = timing.parse(e) { end = parentBegin + value } else { unreadableTimes += 1 }
            } else if let d = attr(map, "dur") {
                if let value = timing.parse(d) { end = begin + value } else { unreadableTimes += 1 }
            }
            if name == "p" {
                s.cueCount += 1
                guard s.cues.count < SubtitleSummary.maxCues + 1 else { continue }
                if attr(map, "begin") == nil && parentBegin == 0 && end == nil { s.skippedCount += 1; continue }
                let style = attr(map, "style") ?? firstDescendantAttribute(tree, node, "style", attributes)
                let speaker = attr(map, "agent") ?? firstDescendantAttribute(tree, node, "agent", attributes)
                s.cues.append(.init(index: s.cueCount, identifier: map["xml:id"], start: begin, end: end ?? begin,
                                    text: textContent(tree, node), style: style, speaker: speaker))
                continue
            }
            if tree[node].depth > 64 { s.truncated = true; continue }
            for child in tree.children(of: node).reversed() where tree[child].role == .element {
                stack.append((child, begin, end))
            }
        }
        s.skippedCount += unreadableTimes
        return s
    }

    static func localName(_ name: String?) -> String {
        guard let name else { return "" }
        if let colon = name.lastIndex(of: ":") { return String(name[name.index(after: colon)...]) }
        return name
    }

    /// The text a viewer sees in a TTML element: text and CDATA in order, `<br/>` as a line break.
    static func textContent(_ tree: StructuredTree, _ node: Int) -> String {
        var out = ""
        let end = tree[node].subtreeEnd
        guard end > node else { return "" }
        for i in (node + 1)..<end {
            let n = tree[i]
            switch n.role {
            case .text, .cdata: out += n.preview
            case .element where localName(n.name) == "br": out += "\n"
            default: break
            }
        }
        return EverydayText.lines(out).map { EverydayText.collapse($0) }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstDescendantAttribute(_ tree: StructuredTree, _ node: Int, _ local: String,
                                         _ attributes: (Int) -> [String: String]) -> String? {
        let end = tree[node].subtreeEnd
        guard end > node + 1 else { return nil }
        for i in (node + 1)..<end where tree[i].role == .attribute && localName(tree[i].name) == local {
            return tree[i].preview
        }
        return nil
    }
}

/// TTML time expressions: clock times (`00:00:01.5`, `00:00:01:12` with frames, `00:00:01:12.1` with sub-frames)
/// and offset times (`1.5s`, `1500ms`, `2m`, `1h`, `25f`, `9000t`).
struct TTMLTiming {
    var frameRate: Double
    var multiplier: Double
    var subFrameRate: Double
    var tickRate: Double?

    static func multiplier(_ text: String) -> Double? {
        let parts = text.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0 else { return nil }
        return parts[0] / parts[1]
    }

    var effectiveFrameRate: Double { max(1, frameRate * multiplier) }

    func parse(_ raw: String) -> TimeInterval? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3 || parts.count == 4,
                  let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
            var total = h * 3600 + m * 60 + sec
            if parts.count == 4 {
                let frameParts = parts[3].split(separator: ".")
                guard let frames = frameParts.first.flatMap({ Double($0) }) else { return nil }
                var f = frames
                if frameParts.count > 1, let sub = Double(frameParts[1]) { f += sub / max(1, subFrameRate) }
                total += f / effectiveFrameRate
            }
            return total.isFinite && total >= 0 ? total : nil
        }
        let units: [(String, Double?)] = [("ms", 0.001), ("h", 3600), ("m", 60), ("s", 1), ("f", nil), ("t", nil)]
        for (unit, scale) in units where text.hasSuffix(unit) {
            guard let value = Double(text.dropLast(unit.count)), value.isFinite, value >= 0 else { return nil }
            switch unit {
            case "f": return value / effectiveFrameRate
            case "t": return value / (tickRate ?? effectiveFrameRate)
            default: return value * (scale ?? 1)
            }
        }
        return nil
    }
}
