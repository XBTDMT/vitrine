import Foundation
import VitrineDetect

// The trust and safety lens (S-20, trust r3-a): read-only checks that run after a file is parsed and say, in plain
// words, what the file would do or hides. Nothing here runs, decodes into a shell or fetches anything: scripts and
// links are read as text, hidden characters are only counted and spelled out. roadmap: S-20

/// What the lens says about one file: its weight, one headline, an optional verdict chip, and numbered findings.
public struct LensReport: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable {
        case calm, caution, danger
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Finding: Sendable, Equatable {
        public var title: String
        /// 1-based line, when the finding has one.
        public var line: Int?
        /// A short quote or explanation (never a secret's value).
        public var detail: String?
        public var level: Level
        public init(title: String, line: Int? = nil, detail: String? = nil, level: Level) {
            self.title = title; self.line = line; self.detail = detail; self.level = level
        }
    }

    public var level: Level
    public var headline: String
    /// The verdict chip beside the headline ("Do not run", "Check before opening").
    public var chip: String?
    public var findings: [Finding]

    public init(level: Level, headline: String, chip: String? = nil, findings: [Finding] = []) {
        self.level = level; self.headline = headline; self.chip = chip; self.findings = findings
    }

    /// The text every calm text preview carries (trust r3-a state 10).
    public static var nothingFound: LensReport {
        LensReport(level: .calm, headline: String(localized: "Checked on this Mac: no secrets, personal details or hidden text", bundle: .module,
                                                  comment: "Trust lens, calm: the text lens ran on this Mac and found nothing."))
    }

    /// The strongest of several reports, its findings first, the others' after.
    public static func combine(_ reports: [LensReport]) -> LensReport? {
        let loud = reports.filter { $0.level > .calm }.sorted { $0.level > $1.level }
        guard var first = loud.first else { return reports.first }
        for other in loud.dropFirst() { first.findings += other.findings }
        return first
    }
}

/// Lines of a text with their 1-based numbers, the way the lenses quote them.
enum Lines {
    /// The text's lines, ended by LF, CRLF or a lone CR. In Swift "\r\n" is one Character, so splitting on "\n" alone
    /// left a Windows-made file as a single line, and a first-line comment then hid the whole script from the lens
    /// (S-16).
    static func of(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).map(String.init)
    }
}

extension NSRegularExpression {
    func matches(_ s: String) -> Bool { firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }
}
