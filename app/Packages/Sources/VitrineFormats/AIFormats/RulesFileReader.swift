import Foundation
import VitrineData

/// Which agent instructions file this is: the name and folder decide how and when an agent loads it. roadmap: S-21
public enum RulesFlavor: String, Sendable, Equatable, CaseIterable {
    case claudeMD, agentsMD, geminiMD, skill, claudeRule, claudeCommand, claudeAgent
    case cursorRules, cursorMDC, windsurfRules, windsurfRule, clineRules, clineRule
    case copilotInstructions, copilotScopedInstructions, copilotPrompt

    /// From a lower-cased file name and lower-cased path; nil for any other file.
    init?(fileName name: String, path: String) {
        let path = "/" + path
        switch name {
        case "claude.md", "claude.local.md": self = .claudeMD; return
        case "agents.md", "agent.md": self = .agentsMD; return
        case "gemini.md": self = .geminiMD; return
        case "skill.md": self = .skill; return
        case ".cursorrules": self = .cursorRules; return
        case ".windsurfrules": self = .windsurfRules; return
        case ".clinerules": self = .clineRules; return
        case "copilot-instructions.md": self = .copilotInstructions; return
        default: break
        }
        if name.hasSuffix(".mdc") { self = .cursorMDC; return }
        if name.hasSuffix(".prompt.md") { self = .copilotPrompt; return }
        if name.hasSuffix(".instructions.md") { self = .copilotScopedInstructions; return }
        guard name.hasSuffix(".md") else { return nil }
        if path.contains("/.claude/rules/") { self = .claudeRule; return }
        if path.contains("/.claude/commands/") { self = .claudeCommand; return }
        if path.contains("/.claude/agents/") { self = .claudeAgent; return }
        if path.contains("/.windsurf/rules/") { self = .windsurfRule; return }
        if path.contains("/.clinerules/") { self = .clineRule; return }
        return nil
    }

    /// The tool and file kind, as a card's title says it.
    public var displayName: String {
        switch self {
        case .claudeMD: return String(localized: "Claude Code memory (CLAUDE.md)", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .agentsMD: return String(localized: "Agent instructions (AGENTS.md)", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .geminiMD: return String(localized: "Gemini CLI context (GEMINI.md)", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .skill: return String(localized: "Agent skill (SKILL.md)", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .claudeRule: return String(localized: "Claude Code rule", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .claudeCommand: return String(localized: "Claude Code slash command", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .claudeAgent: return String(localized: "Claude Code subagent", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .cursorRules: return String(localized: "Cursor rules (legacy .cursorrules)", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .cursorMDC: return String(localized: "Cursor rule (.mdc)", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .windsurfRules: return String(localized: "Windsurf rules (.windsurfrules)", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .windsurfRule: return String(localized: "Windsurf rule", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .clineRules: return String(localized: "Cline rules (.clinerules)", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .clineRule: return String(localized: "Cline rule", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .copilotInstructions: return String(localized: "GitHub Copilot instructions", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .copilotScopedInstructions: return String(localized: "GitHub Copilot scoped instructions", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        case .copilotPrompt: return String(localized: "GitHub Copilot prompt file", bundle: .module, comment: "The kind of an AI agent instructions file, shown on its card. Product and file names stay as they are.")
        }
    }
}

/// When an agent pulls the file into its context. roadmap: S-21
public enum RulesActivation: Sendable, Equatable {
    /// In every conversation in this folder.
    case always
    /// When a file the agent works on matches one of these globs.
    case whenFilesMatch([String])
    /// When the agent decides, from the description, that it is relevant.
    case whenAgentDecides(description: String?)
    /// Only when someone invokes it by name (a slash command, an @-mention).
    case whenInvokedByName(String?)

    /// The plain-English answer to "when does this fire?".
    public var explanation: String {
        switch self {
        case .always:
            return String(localized: "Always: loaded into every conversation in this folder.", bundle: .module, comment: "When an AI agent rules file fires.")
        case .whenFilesMatch(let globs):
            let list = globs.joined(separator: ", ")
            return String(localized: "When the agent works on files matching \(list).", bundle: .module, comment: "When an AI agent rules file fires. The argument is a list of file patterns such as *.ts, *.tsx.")
        case .whenAgentDecides(let description):
            if let description {
                let quoted = AIFormat.clip(description, 200)
                return String(localized: "When the agent decides it is relevant, from its description: “\(quoted)”.", bundle: .module, comment: "When an AI agent skill or rule fires. The argument is the file's own description, untranslated.")
            }
            return String(localized: "When the agent decides it is relevant (no description is given, so it has little to go on).", bundle: .module, comment: "When an AI agent skill or rule fires.")
        case .whenInvokedByName(let name):
            if let name {
                return String(localized: "Only when invoked by name (\(name)).", bundle: .module, comment: "When an AI agent command or rule fires. The argument is how to invoke it, such as /review or @rule.")
            }
            return String(localized: "Only when someone invokes it by name.", bundle: .module, comment: "When an AI agent command or rule fires.")
        }
    }
}

/// One front matter key and its value as display text. roadmap: S-21
public struct RulesFrontMatterEntry: Sendable, Equatable {
    public var key: String
    public var value: String
}

/// A Markdown heading: its level (1–6), text and 1-based line. roadmap: S-21
public struct RulesHeading: Sendable, Equatable {
    public var level: Int
    public var text: String
    public var line: Int
}

/// An `@path` import (Claude Code's memory imports, Cursor's file references) and the line it is on. roadmap: S-21
public struct RulesImport: Sendable, Equatable {
    public var path: String
    public var line: Int

    public init(path: String, line: Int) { self.path = path; self.line = line }
}

/// An import with the file it names and whether that file exists. roadmap: S-21
public struct ResolvedImport: Sendable, Equatable {
    public var source: RulesImport
    public var resolvedPath: String
    public var exists: Bool
}

/// A section's size: the heading (nil for the text before the first heading), its bytes and estimated tokens.
/// roadmap: S-21
public struct RulesSection: Sendable, Equatable {
    public var heading: String?
    public var line: Int
    public var bytes: Int
    public var estimatedTokens: Int
}

/// A rules, skills, prompt or instructions file for a coding agent: front matter, when it fires, its outline,
/// imports, and how much context it costs. roadmap: S-21
public struct RulesFileSummary: Sendable, Equatable {
    public var flavor: RulesFlavor
    public var frontMatter: [RulesFrontMatterEntry]
    public var hasFrontMatter: Bool
    public var name: String?
    public var description: String?
    public var globs: [String]
    public var alwaysApply: Bool?
    public var allowedTools: [String]
    public var model: String?
    public var activation: RulesActivation
    public var headings: [RulesHeading]
    public var headingsTruncated: Bool
    public var imports: [RulesImport]
    public var importsTruncated: Bool
    /// UTF-8 bytes of the file (of what was read, when only its start was).
    public var byteCount: Int
    public var lineCount: Int
    /// An estimate: UTF-8 bytes divided by four. Real tokenizers differ by model.
    public var estimatedTokens: Int
    /// The largest sections, biggest first (at most five).
    public var largestSections: [RulesSection]
    /// Only the first 8 MB was read.
    public var truncated: Bool
    public var headline: String
    public var facts: [AIFact]
    public var warnings: [AIWarning]
}

enum RulesFileReader {
    static let maxHeadings = 300
    static let maxImports = 200

    static func read(bytes input: [UInt8], fileName: String, flavor: RulesFlavor, fileSize: Int64) -> RulesFileSummary {
        var bytes = input[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let text = AIFormat.text(bytes)
        // Lines without their terminators, plus each line's byte offset for section sizes.
        var lines: [Substring] = []
        var lineOffsets: [Int] = []
        var offset = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineOffsets.append(offset)
            offset += raw.utf8.count + 1
            lines.append(raw.hasSuffix("\r") ? raw.dropLast() : raw)
        }
        let totalBytes = bytes.count
        var warnings: [AIWarning] = []

        // Front matter: YAML between a first line `---` and the next `---` (or `...`).
        var entries: [RulesFrontMatterEntry] = []
        var values: [String: FrontValue] = [:]
        var bodyStart = 0
        var hasFrontMatter = false
        if lines.first.map({ $0.trimmingCharacters(in: .whitespaces) == "---" }) == true {
            if let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) }) {
                hasFrontMatter = true
                bodyStart = end + 1
                let yaml = lines[1..<end].joined(separator: "\n")
                (entries, values) = frontMatter(yaml, warnings: &warnings)
            } else {
                warnings.append(AIWarning(.caution, String(localized: "The front matter starts with --- but never closes, so agents may read the settings as ordinary text.", bundle: .module, comment: "Warning on an AI agent rules file card.")))
            }
        }

        func string(_ key: String...) -> String? {
            for k in key { if case .scalar(let s)? = values[k], !s.isEmpty { return s } }
            return nil
        }
        func list(_ key: String...) -> [String] {
            for k in key {
                switch values[k] {
                case .scalar(let s)?:
                    // Cursor writes `globs: *.ts, *.tsx`; Copilot writes `applyTo: "**/*.ts,**/*.tsx"`.
                    let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if !parts.isEmpty { return parts }
                case .list(let items)?: if !items.isEmpty { return items }
                case nil: continue
                }
            }
            return []
        }
        func bool(_ key: String) -> Bool? {
            guard case .scalar(let s)? = values[key] else { return nil }
            switch s.lowercased() { case "true", "yes", "on": return true; case "false", "no", "off": return false; default: return nil }
        }

        let name = string("name")
        let description = string("description")
        let alwaysApply = bool("alwaysApply")
        let allowedTools = list("allowed-tools", "allowed_tools", "allowedTools", "tools")
        let model = string("model")
        var globs: [String] = []
        let activation: RulesActivation
        let invokeName = name ?? baseName(fileName)
        switch flavor {
        case .claudeMD, .agentsMD, .geminiMD, .cursorRules, .windsurfRules, .clineRules, .copilotInstructions,
             .claudeRule, .clineRule:
            globs = list("paths", "globs", "applyTo")
            activation = globs.isEmpty ? .always : .whenFilesMatch(globs)
        case .skill:
            activation = bool("disable-model-invocation") == true ? .whenInvokedByName("/" + invokeName)
                : .whenAgentDecides(description: description)
        case .claudeAgent:
            activation = .whenAgentDecides(description: description)
        case .claudeCommand, .copilotPrompt:
            activation = .whenInvokedByName("/" + invokeName)
        case .cursorMDC:
            globs = list("globs")
            if alwaysApply == true { activation = .always }
            else if !globs.isEmpty { activation = .whenFilesMatch(globs) }
            else if let description { activation = .whenAgentDecides(description: description) }
            else { activation = .whenInvokedByName("@" + invokeName) }
        case .windsurfRule:
            globs = list("globs")
            switch string("trigger")?.lowercased() {
            case "glob": activation = globs.isEmpty ? .whenInvokedByName("@" + invokeName) : .whenFilesMatch(globs)
            case "model_decision": activation = .whenAgentDecides(description: description)
            case "manual": activation = .whenInvokedByName("@" + invokeName)
            default: activation = globs.isEmpty ? .always : .whenFilesMatch(globs)
            }
        case .copilotScopedInstructions:
            globs = list("applyTo")
            if globs.contains(where: { ["**", "**/*", "*"].contains($0) }) { activation = .always }
            else if !globs.isEmpty { activation = .whenFilesMatch(globs) }
            else { activation = .whenInvokedByName(nil) }
        }

        // Outline, imports and sections, skipping fenced code.
        var headings: [RulesHeading] = []
        var headingIndices: [(line: Int, level: Int, text: String)] = []
        var imports: [RulesImport] = []
        var importsTruncated = false
        var fence: (char: Character, length: Int)?
        for i in bodyStart..<lines.count {
            let line = lines[i]
            let trimmed = line.drop(while: { $0 == " " })
            if line.count - trimmed.count <= 3, let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix(while: { $0 == first }).count
                if run >= 3 {
                    if let open = fence {
                        if open.char == first, run >= open.length,
                           trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) { fence = nil }
                    } else {
                        fence = (first, run)
                    }
                    continue
                }
            }
            if fence != nil { continue }
            if let heading = heading(line) {
                headingIndices.append((i, heading.level, heading.text))
                if headings.count < maxHeadings { headings.append(RulesHeading(level: heading.level, text: heading.text, line: i + 1)) }
            }
            for path in importPaths(in: line) {
                if imports.count >= maxImports { importsTruncated = true; break }
                imports.append(RulesImport(path: path, line: i + 1))
            }
        }

        var sections: [RulesSection] = []
        let bodyOffset = bodyStart < lineOffsets.count ? lineOffsets[bodyStart] : totalBytes
        let firstHeadingOffset = headingIndices.first.map { lineOffsets[$0.line] } ?? totalBytes
        let preamble = AIFormat.text(bytes.dropFirst(bodyOffset).prefix(max(0, firstHeadingOffset - bodyOffset)))
        if !preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let size = firstHeadingOffset - bodyOffset
            sections.append(RulesSection(heading: nil, line: bodyStart + 1, bytes: size, estimatedTokens: tokens(size)))
        }
        for (k, h) in headingIndices.enumerated() {
            let start = lineOffsets[h.line]
            let next = headingIndices[(k + 1)...].first { $0.level <= h.level }
            let end = min(totalBytes, next.map { lineOffsets[$0.line] } ?? totalBytes)
            let size = max(0, end - start)
            sections.append(RulesSection(heading: h.text, line: h.line + 1, bytes: size, estimatedTokens: tokens(size)))
        }
        let largest = Array(sections.sorted { $0.bytes > $1.bytes }.prefix(5))

        // Warnings.
        let estimated = tokens(totalBytes)
        if activation == .always, estimated > 10_000 {
            warnings.append(AIWarning(.caution, String(localized: "About \(estimated) tokens (estimate) are loaded into every conversation, which crowds out room for the actual work.", bundle: .module, comment: "Warning on an AI agent rules file card. The argument is an estimated token count.")))
        }
        if flavor == .skill || flavor == .claudeAgent {
            if name == nil {
                warnings.append(AIWarning(.caution, String(localized: "No name in the front matter, so the agent may not list or invoke it.", bundle: .module, comment: "Warning on an AI agent skill card.")))
            }
            if description == nil {
                warnings.append(AIWarning(.caution, String(localized: "No description in the front matter, so the agent cannot tell when to use it.", bundle: .module, comment: "Warning on an AI agent skill card.")))
            } else if let description, description.count > 1024 {
                let length = description.count
                warnings.append(AIWarning(.caution, String(localized: "The description is \(length) characters; skills allow 1,024, so it may be cut or rejected.", bundle: .module, comment: "Warning on an AI agent skill card. The argument is a character count.")))
            }
            if let name, flavor == .skill,
               name.count > 64 || !name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) {
                let shown = AIFormat.clip(name, 80)
                warnings.append(AIWarning(.caution, String(localized: "The name “\(shown)” is not lower-case letters, digits and hyphens (64 at most), which skills require.", bundle: .module, comment: "Warning on an AI agent skill card. The argument is the skill's name."), subject: name))
            }
        }
        for tool in allowedTools {
            let t = tool.replacingOccurrences(of: " ", with: "")
            if ["bash", "bash(*)", "bash(*:*)", "bash(:*)", "shell", "*"].contains(t.lowercased()) {
                warnings.append(AIWarning(.caution, String(localized: "It may run any shell command without asking (\(tool)).", bundle: .module, comment: "Warning on an AI agent skill card. The argument is a tool permission such as Bash."), subject: tool))
            }
        }
        for item in imports where sensitiveImport(item.path) {
            let line = item.line, path = item.path
            warnings.append(AIWarning(.danger, String(localized: "Line \(line) imports \(path), a file that usually holds secrets, into the agent's context.", bundle: .module, comment: "Warning on an AI agent rules file card. A line number, then a file path."), subject: item.path))
        }

        let truncated = fileSize > Int64(input.count)
        var facts: [AIFact] = [
            AIFact(String(localized: "Kind", bundle: .module, comment: "Fact label on an AI agent rules file card."), flavor.displayName),
            AIFact(String(localized: "Fires", bundle: .module, comment: "Fact label on an AI agent rules file card: when the file is loaded."), activation.explanation),
        ]
        if let name { facts.append(AIFact(String(localized: "Name", bundle: .module, comment: "Fact label on an AI agent rules file card."), name)) }
        if let description {
            facts.append(AIFact(String(localized: "Description", bundle: .module, comment: "Fact label on an AI agent rules file card."), AIFormat.clip(description, 300)))
        }
        if !globs.isEmpty {
            facts.append(AIFact(String(localized: "Globs", bundle: .module, comment: "Fact label on an AI agent rules file card: the file patterns it applies to."), globs.joined(separator: ", ")))
        }
        if !allowedTools.isEmpty {
            facts.append(AIFact(String(localized: "Allowed tools", bundle: .module, comment: "Fact label on an AI agent skill card."), allowedTools.joined(separator: ", ")))
        }
        if let model { facts.append(AIFact(String(localized: "Model", bundle: .module, comment: "Fact label on an AI agent rules file card: the AI model it asks for."), model)) }
        let lineCount = lines.count
        facts.append(AIFact(String(localized: "Size", bundle: .module, comment: "Fact label on an AI agent rules file card."),
                            String(localized: "\(lineCount) lines, about \(estimated) tokens (estimate: bytes ÷ 4)", bundle: .module, comment: "Size of an AI agent rules file. A line count, then an estimated token count.")))
        if !headingIndices.isEmpty {
            facts.append(AIFact(String(localized: "Headings", bundle: .module, comment: "Fact label on an AI agent rules file card."), AIFormat.count(headingIndices.count)))
        }
        if !imports.isEmpty {
            facts.append(AIFact(String(localized: "Imports", bundle: .module, comment: "Fact label on an AI agent rules file card: @path references to other files."), AIFormat.count(imports.count) + (importsTruncated ? "+" : "")))
        }
        if truncated {
            let read = AIFormat.bytes(Int64(input.count)), total = AIFormat.bytes(fileSize)
            facts.append(AIFact(String(localized: "Read", bundle: .module, comment: "Fact label: how much of a large file was read."),
                                String(localized: "the first \(read) of \(total)", bundle: .module, comment: "How much of a large file was read. Two sizes such as 8 MB and 12 MB.")))
        }

        let headline: String
        let kind = flavor.displayName
        switch activation {
        case .always:
            headline = String(localized: "\(kind): always on", bundle: .module, comment: "Headline of an AI agent rules file card. The argument is the file's kind.")
        case .whenFilesMatch:
            headline = String(localized: "\(kind): fires on matching files", bundle: .module, comment: "Headline of an AI agent rules file card. The argument is the file's kind.")
        case .whenAgentDecides:
            let title = name ?? kind
            headline = String(localized: "\(title): the agent decides when", bundle: .module, comment: "Headline of an AI agent skill card. The argument is the skill's name or kind.")
        case .whenInvokedByName(let n):
            if let n {
                headline = String(localized: "\(kind): invoked as \(n)", bundle: .module, comment: "Headline of an AI agent command card. The file's kind, then how to invoke it, such as /review.")
            } else {
                headline = String(localized: "\(kind): invoked by name", bundle: .module, comment: "Headline of an AI agent rules file card. The argument is the file's kind.")
            }
        }

        return RulesFileSummary(
            flavor: flavor, frontMatter: entries, hasFrontMatter: hasFrontMatter, name: name, description: description,
            globs: globs, alwaysApply: alwaysApply, allowedTools: allowedTools, model: model, activation: activation,
            headings: headings, headingsTruncated: headingIndices.count > headings.count, imports: imports,
            importsTruncated: importsTruncated, byteCount: totalBytes, lineCount: lines.count, estimatedTokens: estimated,
            largestSections: largest, truncated: truncated, headline: headline, facts: facts, warnings: warnings)
    }

    static func tokens(_ bytes: Int) -> Int { (bytes + 3) / 4 }

    private static func baseName(_ fileName: String) -> String {
        var name = (fileName as NSString).lastPathComponent
        for suffix in [".prompt.md", ".instructions.md", ".mdc", ".md"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)); break
        }
        return name
    }

    enum FrontValue: Equatable { case scalar(String), list([String]) }

    /// The front matter's top-level keys, read with VitrineData's YAML parser; a line-by-line reading covers what YAML
    /// refuses (Cursor's unquoted `globs: *.ts` is a YAML alias).
    static func frontMatter(_ yaml: String, warnings: inout [AIWarning]) -> ([RulesFrontMatterEntry], [String: FrontValue]) {
        var entries: [RulesFrontMatterEntry] = []
        var values: [String: FrontValue] = [:]
        let (root, result) = AIJSONView.parse(Array(yaml.utf8), format: .yaml, maxDepth: 16, maxNodes: 5_000)
        let lineValues = lineByLine(yaml)
        if let root, root.isObject, result.isValid {
            for child in root.children {
                guard let key = child.name else { continue }
                if let text = child.scalarText {
                    values[key] = .scalar(text)
                } else if child.isArray {
                    values[key] = .list(child.children.compactMap(\.scalarText))
                } else if child.node.role == .alias, let raw = lineValues.first(where: { $0.0 == key })?.1 {
                    values[key] = raw
                } else if child.isObject {
                    let count = child.count
                    entries.append(RulesFrontMatterEntry(key: key, value: String(localized: "\(count) keys", bundle: .module, comment: "A front matter value that is a nested object. The argument is its number of keys.")))
                    continue
                }
                if let v = values[key] { entries.append(RulesFrontMatterEntry(key: key, value: display(v))) }
            }
        } else {
            if !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, lineValues.isEmpty {
                warnings.append(AIWarning(.caution, String(localized: "The front matter is not valid YAML, so agents may ignore its settings.", bundle: .module, comment: "Warning on an AI agent rules file card.")))
            }
            for (key, value) in lineValues where values[key] == nil {
                values[key] = value
                entries.append(RulesFrontMatterEntry(key: key, value: display(value)))
            }
        }
        return (entries, values)
    }

    private static func display(_ value: FrontValue) -> String {
        switch value {
        case .scalar(let s): AIFormat.clip(s, 300)
        case .list(let items): items.joined(separator: ", ")
        }
    }

    /// `key: value` and `key:` followed by `- item` lines, nothing more.
    private static func lineByLine(_ yaml: String) -> [(String, FrontValue)] {
        var out: [(String, FrontValue)] = []
        var listKey: String?
        var items: [String] = []
        func unquote(_ s: String) -> String {
            var s = s.trimmingCharacters(in: .whitespaces)
            if s.count >= 2, let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                s = String(s.dropFirst().dropLast())
            }
            return s
        }
        func flush() {
            if let key = listKey { out.append((key, .list(items))) }
            listKey = nil; items = []
        }
        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if listKey != nil, trimmed.hasPrefix("- ") { items.append(unquote(String(trimmed.dropFirst(2)))); continue }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { continue }
            flush()
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { continue }
            let value = unquote(String(line[line.index(after: colon)...]))
            if value.isEmpty { listKey = key } else { out.append((key, .scalar(value))) }
        }
        flush()
        return out
    }

    /// An ATX heading's level and text.
    private static func heading(_ line: Substring) -> (level: Int, text: String)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3, trimmed.first == "#" else { return nil }
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return (level, closingSequenceRemoved(rest.trimmingCharacters(in: .whitespaces)))
    }

    /// The heading text without its closing run of #s, which counts only when whitespace comes before it (or when the
    /// text is nothing but #s). One backward pass: the regex `\s+#+$` this replaces was quadratic on a long run of
    /// spaces not followed by #s, and a heading line can be megabytes long.
    static func closingSequenceRemoved(_ text: String) -> String {
        var hashes = text.endIndex
        while hashes > text.startIndex, text[text.index(before: hashes)] == "#" { hashes = text.index(before: hashes) }
        guard hashes < text.endIndex else { return text }          // no closing #s
        guard hashes > text.startIndex else { return "" }          // nothing but #s
        var spaces = hashes
        while spaces > text.startIndex, text[text.index(before: spaces)].isWhitespace { spaces = text.index(before: spaces) }
        return spaces < hashes ? String(text[..<spaces]) : text
    }

    /// `@path` references on one line, outside inline code: a path has a slash or a dot, or starts with `~`.
    static func importPaths(in line: Substring) -> [String] {
        guard line.contains("@") else { return [] }
        // Blank out inline code spans.
        var chars = Array(line)
        var inCode = false
        for i in chars.indices {
            if chars[i] == "`" { inCode.toggle(); chars[i] = " "; continue }
            if inCode { chars[i] = " " }
        }
        var out: [String] = []
        var i = 0
        while i < chars.count {
            defer { i += 1 }
            guard chars[i] == "@" else { continue }
            if i > 0, !(chars[i - 1].isWhitespace || "([{<\"'".contains(chars[i - 1])) { continue }
            var j = i + 1
            while j < chars.count, !chars[j].isWhitespace, !")]}<>\"'`,;|*".contains(chars[j]) { j += 1 }
            var path = String(chars[(i + 1)..<j])
            while let last = path.last, ".:!?".contains(last) { path.removeLast() }
            i = j - 1
            guard !path.isEmpty, path.contains("/") || path.contains(".") || path.hasPrefix("~") else { continue }
            guard !path.allSatisfy({ $0.isNumber || $0 == "." }) else { continue }   // a version like @1.2.3
            guard path.first.map({ $0.isLetter || $0.isNumber || "~./_-".contains($0) }) == true else { continue }
            out.append(path)
        }
        return out
    }

    private static func sensitiveImport(_ path: String) -> Bool {
        let p = path.lowercased()
        let markers = ["/.ssh/", "~/.ssh", ".ssh/", "id_rsa", "id_ed25519", "id_ecdsa", "/.aws/", ".aws/credentials", "/.gnupg",
                       ".netrc", ".npmrc", ".pypirc", "/.kube/config", ".docker/config.json", "keychains/", ".pem", ".p12",
                       "credentials.json", "secrets.", ".git-credentials"]
        if markers.contains(where: { p.contains($0) }) { return true }
        let last = (p as NSString).lastPathComponent
        return last == ".env" || last.hasPrefix(".env.")
    }

    static func resolve(imports: [RulesImport], relativeTo base: URL) -> [ResolvedImport] {
        let home: String = {
            if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
            return NSHomeDirectory()
        }()
        return imports.map { item in
            let path: String
            if item.path == "~" { path = home }
            else if item.path.hasPrefix("~/") { path = (home as NSString).appendingPathComponent(String(item.path.dropFirst(2))) }
            else if item.path.hasPrefix("/") { path = item.path }
            else { path = base.appendingPathComponent(item.path).path }
            let standardized = (path as NSString).standardizingPath
            return ResolvedImport(source: item, resolvedPath: standardized, exists: FileManager.default.fileExists(atPath: standardized))
        }
    }
}
