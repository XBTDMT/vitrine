import Foundation
import VitrineDocument
import VitrineFormats
import VitrineSupport

/// Rules and skills files (A-3; ai r3-b sections 5 and 7): CLAUDE.md, AGENTS.md, SKILL.md, `.mdc`, Copilot
/// instructions and the rest stay Markdown previews, rendered first. What an agent makes of the file joins them: its
/// kind and when it fires lead the strip, its warnings and missing imports become badges, and an Agent view between
/// Rendered and Source says when it fires, what it costs in tokens, and what it pulls in, runs and links to.
/// Reads the file once more (bounded by the AI reader's limit) and checks imports for existence and size only;
/// nothing is opened, fetched or run. roadmap: S-21
enum RulesFacts {
    /// The window the share is measured against: the size most agents in the table run with today.
    static let contextWindow = 200_000
    static let agentViewTitle = "Agent view"
    /// Commands and links listed in the Agent view stop here.
    static let maxListed = 50

    /// The file's rules summary, nil when the name and path are not a rules or skills file.
    static func summary(url: URL) -> RulesFileSummary? {
        guard case .rules? = AIFormatsReader.kind(fileName: url.lastPathComponent, path: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Int(AIFormatsLimits.maxOtherBytes)),
              case .rules(let summary)? = AIFormatsReader.read(data: data, fileName: url.lastPathComponent, path: url.path) else { return nil }
        return summary
    }

    /// The import list with each found file's size (existence and size only; nothing is read).
    struct Imports: Equatable {
        var resolved: [ResolvedImport]
        var bytes: [Int64?]
        var missing: [ResolvedImport] { resolved.filter { !$0.exists } }
        var foundBytes: Int64 { bytes.compactMap { $0 }.reduce(0, +) }
    }

    static func imports(_ summary: RulesFileSummary, folder: URL) -> Imports {
        let resolved = AIFormatsReader.resolve(imports: summary.imports, relativeTo: folder)
        let bytes = resolved.map { item -> Int64? in
            guard item.exists, let attributes = try? FileManager.default.attributesOfItem(atPath: item.resolvedPath),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
            return (attributes[.size] as? NSNumber)?.int64Value
        }
        return Imports(resolved: resolved, bytes: bytes)
    }

    /// The Markdown document with the rules facts in front, the warnings as badges and the Agent view inserted
    /// after Rendered. Unchanged when the file is not a rules file.
    static func apply(to document: PreviewDocument, url: URL) -> PreviewDocument {
        guard let summary = summary(url: url) else { return document }
        return apply(summary, imports: imports(summary, folder: url.deletingLastPathComponent()), to: document)
    }

    static func apply(_ summary: RulesFileSummary, imports: Imports, to document: PreviewDocument) -> PreviewDocument {
        var d = document
        let loaded = summary.estimatedTokens + tokens(imports.foundBytes)
        var lead = [
            Fact(key: "kindName", label: String(localized: "Kind", bundle: .previewKit, comment: "Fact label on an AI agent rules file's preview."), value: summary.flavor.displayName),
            Fact(key: "headline", label: String(localized: "Summary", bundle: .previewKit, comment: "Fact label on an AI agent rules file's preview: its kind and when it fires, in a few words."), value: summary.headline),
            Fact(key: "fires", label: String(localized: "Fires", bundle: .previewKit, comment: "Fact label on an AI agent rules file's preview: when an agent loads it."), value: summary.activation.explanation),
        ]
        if !summary.imports.isEmpty {
            lead.append(Fact(key: "loadedTokens", label: String(localized: "With imports", bundle: .previewKit, comment: "Fact label on an AI agent rules file's preview: the estimated tokens of the file and the files it imports."), value: "≈ " + loaded.formatted()))
        }
        lead.append(Fact(key: "contextShare", label: String(localized: "Of a 200K window", bundle: .previewKit, comment: "Fact label on an AI agent rules file's preview: the share of a 200,000-token context window the file takes, as an estimate."), value: share(loaded)))
        if let name = summary.name { lead.append(Fact(key: "ruleName", label: String(localized: "Name", bundle: .previewKit, comment: "Fact label on an AI agent rules file's preview."), value: name)) }
        if !summary.globs.isEmpty { lead.append(Fact(key: "globs", label: String(localized: "Globs", bundle: .previewKit, comment: "Fact label on an AI agent rules file's preview: the file patterns it applies to."), value: summary.globs.joined(separator: ", "))) }
        if !summary.allowedTools.isEmpty { lead.append(Fact(key: "allowedTools", label: String(localized: "Allowed tools", bundle: .previewKit, comment: "Fact label on an AI agent skill's preview."), value: summary.allowedTools.joined(separator: ", "))) }
        if let model = summary.model { lead.append(Fact(key: "model", label: String(localized: "Model", bundle: .previewKit, comment: "Fact label on an AI agent rules file's preview: the AI model it asks for."), value: model)) }
        if !summary.imports.isEmpty {
            lead.append(Fact(key: "imports", label: String(localized: "Imports", bundle: .previewKit, comment: "Fact label on an AI agent rules file's preview: @path references to other files."),
                             value: missingSummary(total: summary.imports.count, missing: imports.missing.count)))
        }
        let leadKeys = Set(lead.map(\.key))
        d.facts = lead + d.facts.filter { !leadKeys.contains($0.key) }

        for warning in summary.warnings {
            d.badges.append(Badge(level: warning.level == .danger ? .danger : .caution, title: warning.reason, detail: warning.subject ?? ""))
        }
        if !imports.missing.isEmpty {
            let count = imports.missing.count
            d.badges.append(Badge(level: .caution,
                                  title: String(localized: "\(count) imports not found", bundle: .previewKit, comment: "Badge on an AI agent rules file: files it imports with @path that are not there, so the agent never sees them."),
                                  detail: imports.missing.map { "@" + $0.source.path }.joined(separator: ", ")))
        }

        let source = d.views.lazy.compactMap { view -> String? in if case .text(let s) = view { return s } else { return nil } }.first ?? ""
        let rendered = d.views.lazy.compactMap { view -> MarkdownContent? in if case .markdown(let m) = view { return m } else { return nil } }.first
        let agent = MarkdownContent(html: agentHTML(summary, imports: imports, loaded: loaded, source: source, renderedHTML: rendered?.html ?? ""), headings: [])
        if let first = d.views.firstIndex(where: { if case .markdown = $0 { return true } else { return false } }) {
            d.views.insert(.markdown(agent), at: first + 1)
            var titles = d.viewTitles ?? d.views.map(\.title)
            titles[first + 1] = agentViewTitle
            d.viewTitles = titles
        }
        return d
    }

    /// The AI reader's estimate (bytes divided by four, rounded up), for files it did not read.
    static func tokens(_ bytes: Int64) -> Int { Int((bytes + 3) / 4) }

    static func share(_ tokens: Int) -> String {
        let fraction = Double(tokens) / Double(contextWindow)
        if fraction < 0.001 {
            return String(localized: "under \(Double(0.001).formatted(.percent.precision(.fractionLength(1))))", bundle: .previewKit,
                          comment: "A rules file's share of a context window when it is tiny. The argument is a percentage such as 0.1%.")
        }
        return fraction.formatted(.percent.precision(.fractionLength(fraction < 0.1 ? 1 : 0)))
    }

    static func missingSummary(total: Int, missing: Int) -> String {
        missing == 0
            ? String(localized: "\(total) found", bundle: .previewKit, comment: "Fact value on an AI agent rules file: how many imported files exist, all of them.")
            : String(localized: "\(total) imports, \(missing) not found", bundle: .previewKit, comment: "Fact value on an AI agent rules file: imported files, then how many of them are missing.")
    }

    // MARK: The Agent view

    static let shellLanguages: Set<String> = ["sh", "bash", "zsh", "shell", "console", "shell-session", "fish", "terminal"]

    /// The commands the file tells the agent to run: the lines of its shell code blocks, without prompts, comments
    /// or blank lines, in order and without repeats.
    static func commands(in source: String) -> [String] {
        var out: [String] = [], seen = Set<String>()
        var inShell = false, fence: String?
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil; inShell = false; continue }
                guard inShell else { continue }
                var command = line
                if command.hasPrefix("$ ") || command.hasPrefix("% ") { command = String(command.dropFirst(2)) }
                guard !command.isEmpty, !command.hasPrefix("#") else { continue }
                if seen.insert(command).inserted { out.append(command) }
                if out.count >= maxListed { break }
            } else if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix(3))
                let info = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                let language = info.split(whereSeparator: { $0 == " " || $0 == "{" }).first.map(String.init) ?? ""
                fence = marker
                inShell = shellLanguages.contains(language)
            }
        }
        return out
    }

    /// The links in the rendered page (web, mail and files beside it), in order and without repeats; in-page
    /// anchors are left out.
    static func links(inHTML html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<a\\b[^>]*\\shref=\"([^\"]*)\"", options: [.caseInsensitive]) else { return [] }
        var out: [String] = [], seen = Set<String>()
        for match in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let href = unescape(String(html[range]))
            guard !href.isEmpty, !href.hasPrefix("#"), seen.insert(href).inserted else { continue }
            out.append(href)
            if out.count >= maxListed { break }
        }
        return out
    }

    static func agentHTML(_ summary: RulesFileSummary, imports: Imports, loaded: Int, source: String, renderedHTML: String) -> String {
        var h = ""
        func section(_ title: String) { h += "<h2>\(escape(title))</h2>" }
        func row(_ label: String, _ value: String) -> String { "<tr><th scope=\"row\">\(escape(label))</th><td>\(escape(value))</td></tr>" }

        h += "<h1>\(escape(summary.flavor.displayName))</h1>"

        section(String(localized: "When it fires", bundle: .previewKit, comment: "Agent view heading on an AI agent rules file: when an agent loads it."))
        h += "<p>\(escape(summary.activation.explanation))</p>"

        section(String(localized: "What it costs", bundle: .previewKit, comment: "Agent view heading on an AI agent rules file: how many tokens it adds to the agent's context."))
        h += "<table><tbody>"
        h += row(String(localized: "This file", bundle: .previewKit, comment: "Agent view row: the estimated tokens of the rules file itself."), "≈ " + summary.estimatedTokens.formatted() + " " + tokensWord)
        if !summary.imports.isEmpty {
            h += row(String(localized: "With its imports", bundle: .previewKit, comment: "Agent view row: the estimated tokens of the rules file and the files it imports."), "≈ " + loaded.formatted() + " " + tokensWord)
        }
        h += row(String(localized: "Of a 200K window", bundle: .previewKit, comment: "Agent view row: the share of a 200,000-token context window."), share(loaded))
        h += "</tbody></table>"
        h += "<p><small>\(escape(String(localized: "Estimates: bytes divided by four. Real tokenizers differ by model.", bundle: .previewKit, comment: "Agent view note under the token estimates.")))</small></p>"

        if !summary.warnings.isEmpty || !imports.missing.isEmpty {
            section(String(localized: "Worth a look", bundle: .previewKit, comment: "Agent view heading on an AI agent rules file: its warnings."))
            h += "<ul>"
            for w in summary.warnings.sorted(by: { $0.level > $1.level }) {
                let subject = w.subject.map { " <code>\(escape($0))</code>" } ?? ""
                h += "<li><strong>\(escape(w.level == .danger ? dangerWord : cautionWord))</strong> \(escape(w.reason))\(subject)</li>"
            }
            for m in imports.missing {
                let line = String(localized: "@\(m.source.path) is referenced on line \(m.source.line) but is not there, so the agent never sees it.", bundle: .previewKit,
                                  comment: "Agent view warning on an AI agent rules file: an imported file that does not exist. The arguments are its path and line number.")
                h += "<li><strong>\(escape(cautionWord))</strong> \(escape(line))</li>"
            }
            h += "</ul>"
        }

        if !summary.imports.isEmpty {
            let count = summary.imports.count
            section(String(localized: "Imports it pulls in (\(count))", bundle: .previewKit, comment: "Agent view heading on an AI agent rules file: the @path files it imports, with their count."))
            h += "<table><thead><tr><th>\(escape(fileWord))</th><th>\(escape(lineWord))</th><th>\(escape(statusWord))</th></tr></thead><tbody>"
            for (item, bytes) in zip(imports.resolved, imports.bytes) {
                let status = item.exists
                    ? bytes.map { "≈ " + tokens($0).formatted() + " " + tokensWord } ?? foundWord
                    : notFoundWord
                h += "<tr><td><code>@\(escape(item.source.path))</code></td><td>\(item.source.line)</td><td>\(escape(status))</td></tr>"
            }
            h += "</tbody></table>"
            if summary.importsTruncated { h += "<p><small>\(escape(moreWord))</small></p>" }
        }

        let commands = commands(in: source)
        if !commands.isEmpty {
            section(String(localized: "Commands it tells the agent to run (\(commands.count))", bundle: .previewKit, comment: "Agent view heading on an AI agent rules file: shell commands from its code blocks, with their count."))
            h += "<pre><code>" + commands.map(escape).joined(separator: "\n") + "</code></pre>"
        }

        let links = links(inHTML: renderedHTML)
        if !links.isEmpty {
            section(String(localized: "Links (\(links.count))", bundle: .previewKit, comment: "Agent view heading on an AI agent rules file: the links it contains, with their count."))
            // Listed as text, never as live links: the Agent view is for reading what the file points at.
            h += "<ul>" + links.map { "<li><code>\(escape($0))</code></li>" }.joined() + "</ul>"
        }

        if !summary.largestSections.isEmpty {
            section(String(localized: "Largest sections", bundle: .previewKit, comment: "Agent view heading on an AI agent rules file: its biggest sections by tokens."))
            h += "<table><tbody>"
            for s in summary.largestSections {
                h += row(s.heading ?? beforeFirstHeadingWord, "≈ " + s.estimatedTokens.formatted() + " " + tokensWord)
            }
            h += "</tbody></table>"
        }

        if !summary.frontMatter.isEmpty {
            section(String(localized: "Front matter", bundle: .previewKit, comment: "Agent view heading on an AI agent rules file: the settings block at its top."))
            h += "<table><tbody>" + summary.frontMatter.map { row($0.key, $0.value) }.joined() + "</tbody></table>"
        }
        if summary.truncated {
            h += "<p><small>\(escape(String(localized: "Only the first 8 MB was read.", bundle: .previewKit, comment: "Agent view note on a very large rules file.")))</small></p>"
        }
        return "<div class=\"agent-view\">" + h + "</div>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static var dangerWord: String { String(localized: "Danger:", bundle: .previewKit, comment: "Agent view: the label before a serious warning.") }
    static var cautionWord: String { String(localized: "Caution:", bundle: .previewKit, comment: "Agent view: the label before a warning.") }
    static var fileWord: String { String(localized: "File", bundle: .previewKit, comment: "Agent view table column: an imported file.") }
    static var lineWord: String { String(localized: "Line", bundle: .previewKit, comment: "Agent view table column: the line number.") }
    static var statusWord: String { String(localized: "Status", bundle: .previewKit, comment: "Agent view table column: whether an imported file exists and its size.") }
    static var foundWord: String { String(localized: "Found", bundle: .previewKit, comment: "Agent view: an imported file exists.") }
    static var notFoundWord: String { String(localized: "Not found", bundle: .previewKit, comment: "Agent view: an imported file does not exist.") }
    static var tokensWord: String { String(localized: "tokens", bundle: .previewKit, comment: "Agent view: the unit after an estimated token count, e.g. '≈ 420 tokens'.") }
    static var moreWord: String { String(localized: "More imports than listed; the list stops at 200.", bundle: .previewKit, comment: "Agent view note when a rules file has very many imports.") }
    static var beforeFirstHeadingWord: String { String(localized: "Before the first heading", bundle: .previewKit, comment: "Agent view: the text of a rules file that comes before its first heading.") }
}
