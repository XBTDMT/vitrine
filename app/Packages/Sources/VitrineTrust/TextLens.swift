import Foundation
import VitrineDetect

/// The secrets and personal-data banner (T-4, trust r3-a state 11): Obscura's detectors (VitrineDetect) over a text
/// file, reported as counts and kinds only. Values are never shown, quoted, logged or kept. roadmap: S-20
public enum TextLens {
    /// Counts by kind; the line of each finding for the numbered list.
    /// `masked`: the preview shows these values masked (code, Markdown, plain text), so the headline says so.
    public static func scan(_ text: String, scanner: VitrineDetect.Scanner, masked: Bool = false) -> LensReport? {
        let lines = Lines.of(text)
        let result = scanner.check(lines.enumerated().map { ScanLine(index: $0.offset, text: $0.element) })
        guard !result.findings.isEmpty else { return nil }
        let titles = Dictionary(Catalogue.builtIn.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let personal = result.findings.filter { $0.category == .personal }
        let secrets = result.findings.filter { $0.category != .personal }
        var findings: [LensReport.Finding] = []
        for f in result.findings.sorted(by: { $0.lineIndex < $1.lineIndex }).prefix(50) {
            let title = f.detectorIDs.first.flatMap { titles[$0] } ?? f.category.displayTitle
            findings.append(.init(title: title, line: f.lineIndex + 1, level: f.category == .personal ? .caution : (f.severity >= .high ? .danger : .caution)))
        }
        var headline: String
        switch (secrets.count, personal.count) {
        case (let s, 0):
            headline = String(localized: "\(s) secrets in this file", bundle: .module,
                              comment: "Trust lens headline: how many secrets (keys, tokens, passwords) the detectors found; values are never shown.")
        case (0, let p):
            headline = String(localized: "\(p) personal details in this file", bundle: .module,
                              comment: "Trust lens headline: how many personal details (card numbers, phone numbers…) the detectors found.")
        case (let s, let p):
            headline = String(localized: "\(s) secrets and \(p) personal details in this file", bundle: .module,
                              comment: "Trust lens headline: how many secrets and personal details the detectors found.")
        }
        if masked {
            headline = String(localized: "\(headline), shown masked", bundle: .module,
                              comment: "Trust lens headline when the preview masks the values: the count sentence, then that the values are masked.")
        }
        return LensReport(level: .caution, headline: headline,
                          chip: secrets.isEmpty
                              ? String(localized: "Contains personal details", bundle: .module, comment: "Trust lens chip on a file with personal details.")
                              : String(localized: "Contains secrets", bundle: .module, comment: "Trust lens chip on a file with secrets."),
                          findings: findings)
    }

    /// Text is read up to this size; a larger file is checked in its first part (the report says so through its caller).
    public static let maxBytes = 8 << 20
}
