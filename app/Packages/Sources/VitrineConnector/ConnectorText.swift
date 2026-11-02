import Foundation
import VitrineDetect
import VitrineMCP
import VitrineDocument
import VitrineSupport

// What the connector's tools say (X-9, G-22), made from the same PreviewDocument the previews draw. Plain functions
// of their inputs, so every answer is tested without the app. English on purpose: the worker runs in English, and
// what Claude reads stays one vocabulary. roadmap: S-11

public enum ConnectorText {
    // MARK: describe_file

    public static func describe(_ document: PreviewDocument, name: String, path: String) -> String {
        var lines = ["Vitrine · \(name)", "path: \(path)"]
        var kind = "kind: \(document.kind.displayName) (\(document.kind.identifier))"
        if let dialect = document.dialect { kind += " · format: \(dialect)" }
        lines.append(kind)
        lines.append("coverage: \(coverage(document.coverage))")
        if !document.facts.isEmpty {
            lines.append("facts:")
            for fact in document.facts { lines.append("  \(fact.label): \(fact.value)") }
        }
        if !document.badges.isEmpty {
            lines.append("notes:")
            for badge in document.badges.sorted(by: { $0.level > $1.level }) {
                lines.append("  [\(badge.level.rawValue)] \(badge.title)\(badge.detail.isEmpty ? "" : ": \(badge.detail)")")
            }
        }
        lines.append("views: \((document.viewTitles ?? document.views.map(\.title)).joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    public static func coverage(_ coverage: Coverage) -> String {
        switch coverage {
        case .complete: return "the whole file"
        case .partial(let shown, let total, let unit, let reason):
            let of = total.map { " of \($0.formatted())" } ?? ""
            return "partial: \(shown.formatted())\(of) \(unit.rawValue) shown (\(reason))"
        }
    }

    // MARK: render (text)

    /// One page of the text, numbered from 1 as an editor numbers lines, with a header that says which lines these
    /// are and whether more follow; capped at `maxCharacters` whatever the line count.
    public static func page(_ text: String, name: String, kind: String, offset: Int, limit: Int,
                            maxCharacters: Int = ConnectorLimits.maxCharacters, maskedCount: Int, coverage: Coverage) -> String {
        let all = lines(of: text)
        guard !all.isEmpty else { return "\(name) · \(kind) · no text: Vitrine reads no words from this file. render with format \"image\" shows it as drawn." }
        let start = min(offset, all.count)
        var end = min(all.count, start + limit)
        let width = String(end).count
        var body: [String] = []
        var used = 0
        for i in start..<end {
            let line = "\(String(i + 1).leftPadded(to: width))  \(all[i])"
            if used + line.count + 1 > maxCharacters, !body.isEmpty { end = i; break }
            body.append(line); used += line.count + 1
        }
        var header = "\(name) · \(kind) · lines \(start + 1)–\(end) of \(all.count)"
        if start >= all.count { header = "\(name) · \(kind) · offset \(offset) is past the last line (\(all.count))" }
        if maskedCount > 0 { header += " · \(maskedCount) secret value\(maskedCount == 1 ? "" : "s") masked" }
        if !coverage.isComplete { header += " · Vitrine read part of the file: \(ConnectorText.coverage(coverage))" }
        var out = header + "\n" + body.joined(separator: "\n")
        if end < all.count { out += "\n… \(all.count - end) more line\(all.count - end == 1 ? "" : "s"); call render with offset \(end) for the next page." }
        return out
    }

    static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { parts.removeLast() }
        return parts
    }

    // MARK: secrets

    public static func scanner() throws -> VitrineDetect.Scanner { VitrineDetect.Scanner(catalogue: try Catalogue.resolved(), input: .exact) }

    /// The text with every secret the scanner finds replaced by bullets (the previews' masker, VitrineDetect).
    public static func masked(_ text: String, scanner: VitrineDetect.Scanner) -> (text: String, count: Int) {
        SecretRedaction.mask(text, scanner: scanner)
    }

    static func mask(_ line: String, _ findings: [Finding]) -> String {
        if findings.contains(where: \.wholeLine) { return bullets(line.count) }
        let ns = NSMutableString(string: line)
        for finding in findings.sorted(by: { $0.secretRange.location > $1.secretRange.location })
        where finding.secretRange.location != NSNotFound && NSMaxRange(finding.secretRange) <= ns.length {
            ns.replaceCharacters(in: finding.secretRange, with: bullets(finding.secretRange.length))
        }
        return ns as String
    }

    /// scan_secrets' report: each finding's line, kind, category and severity, with the line shown masked.
    public static func secretsReport(_ text: String, name: String, scanner: VitrineDetect.Scanner, coverage: Coverage) -> String {
        let all = lines(of: text)
        let result = scanner.check(all.enumerated().map { ScanLine(index: $0.offset, text: $0.element) })
        let titles = Dictionary(Catalogue.builtIn.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        let found = result.findings.count
        var header = "Secrets in \(name): \(found == 0 ? "none found" : "\(found) found") in \(all.count) line\(all.count == 1 ? "" : "s")"
        header += result.isComplete ? " (every line checked)" : " (\(result.uncheckedLines.count) line\(result.uncheckedLines.count == 1 ? "" : "s") not checked: too long)"
        if !coverage.isComplete { header += " · Vitrine read part of the file: \(ConnectorText.coverage(coverage))" }
        out.append(header)
        let byLine = Dictionary(grouping: result.findings, by: \.lineIndex)
        for finding in result.findings.sorted(by: { ($0.lineIndex, $0.secretRange.location) < ($1.lineIndex, $1.secretRange.location) }) {
            let title = finding.detectorIDs.first.flatMap { titles[$0] } ?? finding.category.rawValue
            let shown = all.indices.contains(finding.lineIndex) ? clip(mask(all[finding.lineIndex], byLine[finding.lineIndex] ?? [finding])) : ""
            var line = "- line \(finding.lineIndex + 1) · \(title) (\(finding.category.rawValue), \(finding.severity.rawValue))"
            if finding.unverified { line += " · unverified" }
            out.append(line + (shown.isEmpty ? "" : ": \(shown)"))
        }
        for index in result.uncheckedLines { out.append("- line \(index + 1) · not checked (longer than the scanner reads)") }
        out.append("Values are masked; render with secrets \"show\" returns the text as it is.")
        return out.joined(separator: "\n")
    }

    /// 8 to 24 bullets, so a masked value's length is only roughly said (the previews' rule, VitrineText.SecretMask).
    public static func bullets(_ length: Int) -> String { String(repeating: "•", count: min(24, max(8, length))) }

    static func clip(_ line: String, to limit: Int = 160) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "…"
    }

    // MARK: token_count

    public static func tokens(_ text: String, name: String, fileBytes: Int64?, coverage: Coverage) -> String {
        let bytes = text.utf8.count
        let estimate = bytes == 0 ? 0 : max(1, (bytes + 2) / 4)
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        var out = [
            "\(name): about \(estimate.formatted()) tokens (estimate: about four bytes a token; Claude's tokenizer is not public)",
            "characters: \(text.count.formatted()) · words: \(words.formatted()) · lines: \(lines(of: text).count.formatted()) · bytes of text: \(bytes.formatted())",
        ]
        if let fileBytes, Int64(bytes) != fileBytes {
            out.append("the file is \(fileBytes.formatted()) bytes; the count is of the text Vitrine reads from it")
        }
        if !coverage.isComplete { out.append("Vitrine read part of the file: \(ConnectorText.coverage(coverage))") }
        return out.joined(separator: "\n")
    }
}

extension String {
    func leftPadded(to width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}
