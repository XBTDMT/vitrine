import Foundation

/// The hidden-Unicode lens (T-5, trust r3-a state 12): characters a reader cannot see but a program reads. Unicode
/// tag characters (U+E0000–E007F) can spell whole sentences an AI agent will follow; zero-width characters hide or
/// split words; direction overrides (U+202A–202E, U+2066–2069) show text in a different order than it is stored,
/// which can disguise a file name. Loudest on rules files and configs, where an agent reads every character.
/// roadmap: S-20
public enum HiddenText {
    /// Files an agent reads as instructions: a hidden character here is danger, elsewhere caution.
    public static func isRulesFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["claude.md", "agents.md", "gemini.md", "skill.md", ".cursorrules", ".windsurfrules", "copilot-instructions.md",
                ".clinerules", "rules.md", "system-prompt.md"].contains(lower) || lower.hasSuffix(".mdc") || lower.hasSuffix(".prompt")
    }

    static func isTag(_ v: UInt32) -> Bool { (0xE0000...0xE007F).contains(v) }
    static func isZeroWidth(_ v: UInt32) -> Bool { [0x200B, 0x200C, 0x200D, 0x2060, 0x180E, 0xFEFF].contains(v) }
    static func isDirection(_ v: UInt32) -> Bool { (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) }

    /// The report, or nil when the text holds none of these characters. A byte-order mark at the very start is the
    /// file's own and not counted.
    public static func scan(_ text: String, fileName: String) -> LensReport? {
        var findings: [LensReport.Finding] = []
        var tagged = 0, zeroWidth = 0, direction = 0
        for (index, line) in Lines.of(text).enumerated() {
            var tagsHere = 0, spelled = "", zwHere = 0, dirHere: [String] = []
            for (position, scalar) in line.unicodeScalars.enumerated() {
                let v = scalar.value
                if isTag(v) {
                    tagsHere += 1
                    // Tags shadow ASCII: U+E0041 is a hidden "A".
                    if (0xE0020...0xE007E).contains(v), let ascii = Unicode.Scalar(v - 0xE0000) { spelled.unicodeScalars.append(ascii) }
                } else if isZeroWidth(v), !(index == 0 && position == 0 && v == 0xFEFF) {
                    zwHere += 1
                } else if isDirection(v) {
                    dirHere.append(name(v))
                }
            }
            if tagsHere > 0 {
                tagged += tagsHere
                let words = spelled.trimmingCharacters(in: .whitespaces)
                findings.append(.init(title: String(localized: "\(tagsHere) invisible characters on line \(index + 1)", bundle: .module,
                                                    comment: "Trust lens finding: how many hidden tag characters, and the line."),
                                      line: index + 1,
                                      detail: words.isEmpty ? nil : String(localized: "hidden: “\(ScriptLens.quote(words))”", bundle: .module,
                                                                           comment: "Trust lens finding detail: the words the hidden characters spell."),
                                      level: .danger))
            }
            if zwHere > 0 {
                zeroWidth += zwHere
                findings.append(.init(title: String(localized: "\(zwHere) zero-width characters on line \(index + 1)", bundle: .module,
                                                    comment: "Trust lens finding: how many zero-width characters, and the line."),
                                      line: index + 1, level: .caution))
            }
            if !dirHere.isEmpty {
                direction += dirHere.count
                findings.append(.init(title: String(localized: "Text direction flipped on line \(index + 1)", bundle: .module,
                                                    comment: "Trust lens finding: a direction override reorders what is shown on this line."),
                                      line: index + 1, detail: dirHere.joined(separator: " · "), level: .caution))
            }
        }
        guard !findings.isEmpty else { return nil }
        let rules = isRulesFile(fileName)
        let level: LensReport.Level = tagged > 0 || rules ? .danger : .caution
        let headline: String
        if tagged > 0 {
            headline = String(localized: "Hidden instructions: \(tagged) invisible characters spell a command for AI agents", bundle: .module,
                              comment: "Trust lens headline: hidden tag characters spell text an AI agent would read.")
        } else if direction > 0 {
            headline = String(localized: "Text that reads differently than it is stored", bundle: .module,
                              comment: "Trust lens headline: direction-override characters reorder what is shown.")
        } else {
            headline = String(localized: "\(zeroWidth) invisible characters hide inside words", bundle: .module,
                              comment: "Trust lens headline: zero-width characters inside the text.")
        }
        return LensReport(level: level, headline: headline,
                          chip: String(localized: "Hidden text", bundle: .module, comment: "Trust lens verdict chip when a file hides characters."),
                          findings: findings.sorted { ($0.level, -($0.line ?? 0)) > ($1.level, -($1.line ?? 0)) })
    }

    /// The control's short name, as the design marks it in the text ("RLO", "PDF").
    static func name(_ v: UInt32) -> String {
        switch v {
        case 0x202A: "LRE"; case 0x202B: "RLE"; case 0x202C: "PDF"; case 0x202D: "LRO"; case 0x202E: "RLO"
        case 0x2066: "LRI"; case 0x2067: "RLI"; case 0x2068: "FSI"; case 0x2069: "PDI"
        default: String(format: "U+%04X", v)
        }
    }
}
