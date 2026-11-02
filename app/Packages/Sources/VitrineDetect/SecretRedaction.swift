import Foundation

/// Text with the secrets the scanner finds replaced by bullets (8 to 24, so a value's length is only roughly said).
/// A line the scanner could not finish is withheld whole: it cannot be called clean. Shared by the previews (T-4,
/// G-23) and the Claude connector (X-9). roadmap: S-11, S-20
public enum SecretRedaction {
    public static func bullets(_ length: Int) -> String { String(repeating: "•", count: min(24, max(8, length))) }

    public static func mask(_ text: String, scanner: Scanner) -> (text: String, count: Int) {
        guard !text.isEmpty else { return (text, 0) }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trailing = text.hasSuffix("\n")
        if trailing { lines.removeLast() }
        let result = scanner.check(lines.enumerated().map { ScanLine(index: $0.offset, text: $0.element) })
        guard !result.findings.isEmpty || !result.uncheckedLines.isEmpty else { return (text, 0) }
        var count = 0
        for (index, findings) in Dictionary(grouping: result.findings, by: \.lineIndex) where lines.indices.contains(index) {
            lines[index] = mask(lines[index], findings)
            count += findings.count
        }
        for index in result.uncheckedLines where lines.indices.contains(index) {
            lines[index] = String(localized: "[line not checked for secrets (too long), withheld: \(lines[index].count) characters]", bundle: .module,
                                  comment: "Stands in for a line too long for the secret scanner; the number of characters it had.")
            count += 1
        }
        return (lines.joined(separator: "\n") + (trailing ? "\n" : ""), count)
    }

    static func mask(_ line: String, _ findings: [Finding]) -> String {
        if findings.contains(where: \.wholeLine) { return bullets(line.count) }
        let ns = NSMutableString(string: line)
        for f in findings.sorted(by: { $0.secretRange.location > $1.secretRange.location })
        where f.secretRange.location != NSNotFound && NSMaxRange(f.secretRange) <= ns.length {
            ns.replaceCharacters(in: f.secretRange, with: bullets(f.secretRange.length))
        }
        return ns as String
    }
}
