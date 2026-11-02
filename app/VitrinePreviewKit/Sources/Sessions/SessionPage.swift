import Foundation
import VitrineUI

/// The conversation view of an agent session, drawn to design/mockups/unified/ai.html states 1 and 4 (pick r3-b
/// "Glass case: header and rail"): a header card with the session's facts and its context meter, a danger group when
/// secrets were masked, the prompt bar, and the rail of prompts (soft bubbles), replies, folded thinking, one-line
/// tool calls (a failed one on the danger inset with Show), subagents and masked-secret notes, then the note about
/// line kinds that were skipped. Static HTML: the page carries no script at all (its CSP allows none); folding is
/// `<details>`, and find and the ⌥↑/⌥↓ prompt jumps are run by the renderer from outside the page. roadmap: S-11
enum SessionPage {
    static func html(_ s: AgentSession, files: [SessionChanges.File], appearance: DesignTokens.Appearance) -> String {
        let mode = appearance == .dark ? "dark" : "light"
        return """
        <!doctype html>
        <html data-appearance="\(mode)"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <style>
        :root { \(DesignTokens.systemCSS(for: appearance)) color-scheme: \(mode); }
        \(css)
        </style></head>
        <body><main id="vt-s">
        \(header(s, files: files))
        \(dangerGroup(s))
        \(jumpBar(s))
        <div class="hbody plain"><div class="rail">
        \(rail(s))
        </div></div>
        \(notes(s))
        </main></body></html>
        """
    }

    // MARK: Header card

    static func header(_ s: AgentSession, files: [SessionChanges.File]) -> String {
        let sourceName = s.source.displayName
        var meta = [String(localized: "\(sourceName) session", bundle: .previewKit, comment: "Session header: the agent that wrote it (“Claude Code”, “Codex”) and the word session.")]
        if let p = s.project { meta.append(p) }
        if let b = s.branch { meta.append(b) }
        if let m = s.model { meta.append(SessionParser.modelName(m)) }
        if let d = s.started { meta.append(d.formatted(.dateTime.month(.abbreviated).day())) }
        if let d = s.duration, d.isFinite { meta.append(durationText(d)) }
        if !s.isComplete { meta.append(readText(s)) }

        var kv: [(String, String)] = []
        let adds = files.reduce(0) { $0 + $1.additions }, dels = files.reduce(0) { $0 + $1.deletions }
        let fileCount = files.count.formatted()
        let filesText = files.count == 1
            ? String(localized: "\(fileCount) file", bundle: .previewKit, comment: "Session header: one file edited.")
            : String(localized: "\(fileCount) files", bundle: .previewKit, comment: "Session header: how many files were edited.")
        kv.append((String(localized: "Edited", bundle: .previewKit, comment: "Session header fact label: the files the session edited."), files.isEmpty
            ? esc(String(localized: "No files", bundle: .previewKit, comment: "Session header: no files were edited."))
            : "\(esc(filesText)) · <span class=\"add\">+\(adds.formatted())</span> <span class=\"del\">−\(dels.formatted())</span>"))
        let failed = s.tools.filter(\.isError).count
        let failedCount = failed.formatted()
        let failedText = String(localized: "\(failedCount) failed", bundle: .previewKit, comment: "Session header: how many tool calls failed.")
        kv.append((String(localized: "Tool calls", bundle: .previewKit, comment: "Session header fact label: how many tools the agent called."), s.tools.isEmpty
            ? esc(String(localized: "None", bundle: .previewKit, comment: "Session header: no tool calls."))
            : "\(s.tools.count.formatted())" + (failed > 0 ? " · <span class=\"c-danger\">\(esc(failedText))</span>" : "")))
        let agents = s.tools.compactMap(\.subagent)
        if !agents.isEmpty {
            let types = Array(NSOrderedSet(array: agents.map(\.type))).compactMap { $0 as? String }.prefix(3).map(esc).joined(separator: ", ")
            let turnCount = s.subagentTurns.formatted()
            let turnsText = s.subagentTurns == 1
                ? String(localized: "\(turnCount) turn", bundle: .previewKit, comment: "Session header: subagents took one turn.")
                : String(localized: "\(turnCount) turns", bundle: .previewKit, comment: "Session header: how many turns the subagents took.")
            kv.append((String(localized: "Subagents", bundle: .previewKit, comment: "Session header fact label: subagents the session started."),
                       "\(agents.count.formatted()) · \(types)" + (s.subagentTurns > 0 ? " · \(esc(turnsText))" : "")))
        }
        let promptCount = s.prompts.formatted()
        let promptsText = s.prompts == 1
            ? String(localized: "\(promptCount) prompt", bundle: .previewKit, comment: "Session header: one prompt from the person.")
            : String(localized: "\(promptCount) prompts", bundle: .previewKit, comment: "Session header: how many prompts the person wrote.")
        kv.append((String(localized: "Turns", bundle: .previewKit, comment: "Session header fact label: how many turns the session took."), "\(s.turns.formatted()) · \(esc(promptsText))"))
        let rows = kv.map { "<span class=\"k\">\(esc($0.0))</span><span class=\"v\">\($0.1)</span>" }.joined()
        return """
        <div class="hcard"><span class="htile">\(icon("chat"))</span><div class="htx">
        <div class="ht">\(esc(s.title))</div>
        <div class="hs">\(meta.map(esc).joined(separator: " · "))</div>
        \(meter(s))
        <div class="kv hkv">\(rows)</div>
        </div></div>
        """
    }

    /// The context meter: tokens read at the last turn against the window. Claude Code transcripts do not record
    /// the window, so 200K is assumed (1M past it) and said; the design's split into system, rules, MCP tools and
    /// messages is not in the transcript and is not drawn.
    static func meter(_ s: AgentSession) -> String {
        // A window that is not positive is not recorded, and the count is held inside 0…window before anything is
        // subtracted, so no recorded number can make the arithmetic trap (S-16 F40).
        guard let c = s.context, c.used > 0 else { return "" }
        let recorded = c.window.flatMap { $0 > 0 ? $0 : nil }
        let assumed = recorded == nil
        let window = recorded ?? (c.used > 200_000 ? 1_000_000 : 200_000)
        let used = min(c.used, window)
        let pct = Double(used) / Double(window) * 100
        let usedText = tokens(c.used), windowText = tokens(window), freeText = tokens(window - used)
        let share = (Double(used) / Double(window)).formatted(.percent.precision(.fractionLength(0)))
        let context = String(localized: "Context \(usedText) of \(windowText)", bundle: .previewKit, comment: "Session context meter: tokens read at the last turn of the context window. Arguments: compact token counts (“42K”, “200K”).")
        let atLast = String(localized: "\(share) at the last turn", bundle: .previewKit, comment: "Session context meter: the share of the window used at the last turn; the argument is a percentage.")
        let read = String(localized: "Read at the last turn \(usedText)", bundle: .previewKit, comment: "Session context meter legend: tokens read at the last turn.")
        let free = String(localized: "Free \(freeText)", bundle: .previewKit, comment: "Session context meter legend: tokens left in the window.")
        let assumedText = String(localized: "window not recorded · \(windowText) assumed", bundle: .previewKit, comment: "Session context meter: the transcript does not record the window size, so this size is assumed.")
        return """
        <div class="hmeter"><div class="mbox">
        <div class="mline"><b>\(esc(context))</b><span class="t2">\(esc(atLast))</span></div>
        <div class="segbar"><i style="width:\(String(format: "%.2f", pct))%;background:var(--v-series-1)"></i></div>
        <div class="leg"><span><i style="background:var(--v-series-1)"></i>\(esc(read))</span><span><i style="background:var(--v-fill2)"></i>\(esc(free))</span>\(assumed ? "<span class=\"t3\">\(esc(assumedText))</span>" : "")</div>
        </div></div>
        """
    }

    static func dangerGroup(_ s: AgentSession) -> String {
        guard s.maskedSecrets > 0 else { return "" }
        let n = s.maskedSecrets
        let count = n.formatted()
        let title = n == 1
            ? String(localized: "\(count) secret in this session", bundle: .previewKit, comment: "Session danger group title: one secret was masked.")
            : String(localized: "\(count) secrets in this session", bundle: .previewKit, comment: "Session danger group title: how many secrets were masked.")
        let detail = n == 1
            ? String(localized: "A value that looks like a credential is masked here; Vitrine never shows the value.", bundle: .previewKit, comment: "Session danger group detail, one secret.")
            : String(localized: "Values that look like credentials are masked here; Vitrine never shows the value.", bundle: .previewKit, comment: "Session danger group detail, several secrets.")
        return """
        <div class="dgroup"><div class="dt">\(esc(title))</div>
        <div class="ds">\(esc(detail))</div></div>
        """
    }

    static func jumpBar(_ s: AgentSession) -> String {
        let prompts = s.items.compactMap { if case .prompt(let t, _) = $0 { t } else { nil } }
        guard prompts.count > 1 else { return "" }
        let count = prompts.count.formatted()
        let title = String(localized: "\(count) prompts", bundle: .previewKit, comment: "Session prompt bar: how many prompts the person wrote (two or more).")
        let hint = String(localized: "jump between prompts", bundle: .previewKit, comment: "Session prompt bar: the keys before it (⌥↑ ⌥↓) move between prompts.")
        return """
        <div class="jumpbar">\(icon("jump")) <b>\(esc(title))</b> <span class="t2">\(esc(SessionParser.firstLine(prompts[0], max: 90)))</span><span class="sp"></span><span class="kbd">⌥↑</span><span class="kbd">⌥↓</span> <span class="t3">\(esc(hint))</span></div>
        """
    }

    // MARK: The rail

    static func rail(_ s: AgentSession) -> String {
        var out: [String] = []
        var promptNumber = 0
        let you = String(localized: "You", bundle: .previewKit, comment: "Session conversation: the person's own prompts are labelled You.")
        for item in s.items {
            switch item {
            case .prompt(let text, let time):
                promptNumber += 1
                out.append("""
                <div class="rr user" id="p\(promptNumber)"><span class="rn user">\(icon("person"))</span><div class="rb"><div class="rr-who">\(esc(you)) \(timeText(time))</div><div class="rr-user bub">\(esc(text))</div></div></div>
                """)
            case .reply(let text, _):
                out.append("<div class=\"rr assistant\"><span class=\"rn dot\"></span><div class=\"rb\"><div class=\"rr-a\">\(prose(text))</div></div></div>")
            case .thinking(let text, _):
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty {
                    out.append("<div class=\"rr thinking\"><span class=\"rn ring\"></span><div class=\"rb\"><div class=\"rr-think\">\(esc(String(localized: "Thought · not recorded", bundle: .previewKit, comment: "Session conversation: the agent thought here, but the text was not recorded.")))</div></div></div>")
                } else {
                    let lines = SessionParser.lineCount(body), count = lines.formatted()
                    let summary = lines == 1
                        ? String(localized: "Thinking · \(count) line", bundle: .previewKit, comment: "Session conversation: folded thinking of one line.")
                        : String(localized: "Thinking · \(count) lines", bundle: .previewKit, comment: "Session conversation: folded thinking; the argument is how many lines.")
                    out.append("""
                    <div class="rr thinking"><span class="rn ring"></span><div class="rb"><details><summary class="rr-think">\(icon("chev")) \(esc(summary))</summary><div class="rr-thb">\(esc(body))</div></details></div></div>
                    """)
                }
            case .tool(let i):
                out.append(tool(s.tools[i]))
            case .note(let text, let time):
                out.append("<div class=\"rr note\"><span class=\"rn ring\"></span><div class=\"rb\"><div class=\"rr-note\">\(esc(text)) \(timeText(time))</div></div></div>")
            }
        }
        return out.joined(separator: "\n")
    }

    static func tool(_ t: SessionToolCall) -> String {
        if let agent = t.subagent {
            var res: [String] = []
            if let n = agent.toolUses {
                let uses = n.formatted()
                res.append(n == 1
                    ? String(localized: "\(uses) tool use", bundle: .previewKit, comment: "Session subagent: it called one tool.")
                    : String(localized: "\(uses) tool uses", bundle: .previewKit, comment: "Session subagent: how many tools it called."))
            }
            if let k = agent.tokens { res.append(tokens(k)) }
            if t.isError { res.append(SessionParser.failed) }
            let result = t.output.map { "<div class=\"rr-agres\">\(esc(SessionParser.cut($0, 400)))</div>" } ?? ""
            let type = agent.type
            let subagentTitle = String(localized: "Subagent · \(type)", bundle: .previewKit, comment: "Session conversation: a subagent call; the argument is its type (“Explore”).")
            return """
            <div class="rr agent"><span class="rn agent">\(icon("agent"))</span><div class="rb"><div class="rr-tool agent"><b>\(esc(subagentTitle))</b><span class="arg">\(esc(agent.description))</span><span class="sp"></span><span class="res">\(esc(res.joined(separator: " · ")))</span>\(timeText(t.time, cls: "tm"))</div>\(result)</div></div>
            """
        }
        var tail = ""
        if t.additions != nil || t.deletions != nil {
            let a = t.additions ?? 0, d = t.deletions ?? 0
            tail = (a > 0 || d == 0 ? "<span class=\"add\">+\(a.formatted())</span>" : "") + (d > 0 ? " <span class=\"del\">−\(d.formatted())</span>" : "")
            if t.isError { tail += " <span class=\"res err\">\(esc(SessionParser.failed))</span>" }
        } else if let r = t.result {
            tail = "<span class=\"res\(t.isError ? " err" : "")\">\(esc(r))</span>"
        }
        let row = "<b>\(esc(displayName(t.name)))</b><span class=\"arg\">\(esc(t.argument))</span><span class=\"sp\"></span>\(tail)"
        let secretCount = t.maskedSecrets.formatted()
        let secretText = t.maskedSecrets == 1
            ? String(localized: "\(secretCount) secret in this call · masked · values are never shown", bundle: .previewKit, comment: "Session tool call note: one secret was masked.")
            : String(localized: "\(secretCount) secrets in this call · masked · values are never shown", bundle: .previewKit, comment: "Session tool call note: how many secrets were masked.")
        let secret = t.maskedSecrets > 0
            ? "<div class=\"secnote\">\(icon("lock")) \(esc(secretText))</div>" : ""
        guard let output = t.output, !output.isEmpty else {
            return "<div class=\"rr tool\(t.isError ? " errrow" : "")\"><span class=\"rn tool\(t.isError ? " err" : "")\">\(icon("tool"))</span><div class=\"rb\"><div class=\"rr-tool\">\(row)\(timeText(t.time, cls: "tm"))</div>\(secret)</div></div>"
        }
        let show = t.isError ? "<span class=\"btn sm\">\(esc(String(localized: "Show", bundle: .previewKit, comment: "Session conversation: button on a failed tool call that unfolds its output.")))</span>" : ""
        return """
        <div class="rr tool\(t.isError ? " errrow" : "")"><span class="rn tool\(t.isError ? " err" : "")">\(icon("tool"))</span><div class="rb"><details\(secret.isEmpty ? "" : " open")><summary class="rr-tool">\(row)\(show)\(timeText(t.time, cls: "tm"))</summary><div class="tout\(t.isError ? " err" : "")">\(esc(output))</div></details>\(secret)</div></div>
        """
    }

    /// "mcp__github__create_issue" reads as "github · create_issue".
    static func displayName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : name
    }

    static func notes(_ s: AgentSession) -> String {
        var out: [String] = []
        if s.itemsCut {
            let count = s.items.count.formatted()
            let text = String(localized: "The first \(count) rows are drawn; the counts above cover every line read.", bundle: .previewKit, comment: "Session note: only the first rows are drawn; the argument is how many.")
            out.append("<div class=\"unk\">\(icon("info"))<span>\(esc(text))</span></div>")
        }
        if !s.isComplete {
            let done = bytes(s.bytesRead), size = bytes(s.fileSize)
            let text = String(localized: "\(done) of \(size) were read; the rest of this session is in Source.", bundle: .previewKit, comment: "Session note: only part of a large session was read. Arguments: size read, file size. “Source” is the viewer switch's Source view.")
            out.append("<div class=\"unk\">\(icon("info"))<span>\(esc(text))</span></div>")
        }
        if !s.unknownKinds.isEmpty {
            let kinds = s.unknownKinds.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) ×\($0.value.formatted())" }.joined(separator: ", ")
            let n = s.unknownKinds.count, count = n.formatted()
            let text = n == 1
                ? String(localized: "\(count) line kind Vitrine does not know yet was skipped (\(kinds)). The rest of the session still shows.", bundle: .previewKit, comment: "Session note: one unknown kind of line was skipped. The second argument lists it with its count (“x-telemetry ×1”).")
                : String(localized: "\(count) line kinds Vitrine does not know yet were skipped (\(kinds)). The rest of the session still shows.", bundle: .previewKit, comment: "Session note: unknown kinds of line were skipped. The second argument lists them with their counts.")
            out.append("<div class=\"unk\">\(icon("info"))<span>\(esc(text))</span></div>")
        }
        if s.unreadableLines > 0 {
            let count = s.unreadableLines.formatted()
            let text = s.unreadableLines == 1
                ? String(localized: "\(count) line could not be read as JSON and was skipped.", bundle: .previewKit, comment: "Session note: one line of the file was not valid JSON.")
                : String(localized: "\(count) lines could not be read as JSON and were skipped.", bundle: .previewKit, comment: "Session note: how many lines of the file were not valid JSON.")
            out.append("<div class=\"unk\">\(icon("info"))<span>\(esc(text))</span></div>")
        }
        return out.joined(separator: "\n")
    }

    // MARK: Text

    static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// A reply's Markdown, lightly: fenced code blocks, `code` spans, **bold**, paragraphs. Everything is escaped
    /// first, so nothing in a reply becomes markup of its own.
    static func prose(_ text: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var fence: [String]?
        func flush() {
            if !paragraph.isEmpty { html.append("<p>" + paragraph.map(inline).joined(separator: "<br>") + "</p>") }
            paragraph = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let f = fence { html.append("<pre class=\"code\">\(esc(f.joined(separator: "\n")))</pre>"); fence = nil } else { flush(); fence = [] }
                continue
            }
            if fence != nil { fence!.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { paragraph.append(line) }
        }
        if let f = fence { html.append("<pre class=\"code\">\(esc(f.joined(separator: "\n")))</pre>") }
        flush()
        return html.joined()
    }

    static func inline(_ line: String) -> String {
        var out = ""
        var rest = Substring(line)
        while let tick = rest.firstIndex(of: "`") {
            out += bold(esc(String(rest[..<tick])))
            let after = rest.index(after: tick)
            guard let close = rest[after...].firstIndex(of: "`") else { out += esc(String(rest[tick...])); rest = ""; break }
            out += "<code>\(esc(String(rest[after..<close])))</code>"
            rest = rest[rest.index(after: close)...]
        }
        return out + bold(esc(String(rest)))
    }

    static func bold(_ escaped: String) -> String {
        let parts = escaped.components(separatedBy: "**")
        guard parts.count >= 3 else { return escaped }
        return parts.enumerated().map { $0.offset % 2 == 1 && $0.offset < parts.count - 1 ? "<b>\($0.element)</b>" : $0.element }.joined()
    }

    static func timeText(_ date: Date?, cls: String = "") -> String {
        guard let date else { return "" }
        return "<span class=\"t3\(cls.isEmpty ? "" : " " + cls)\">\(date.formatted(date: .omitted, time: .shortened))</span>"
    }

    /// "42K", "1.2M": a token count in the locale's compact form.
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
        if n >= 1_000 { return n.formatted(.number.notation(.compactName).precision(.fractionLength(0))) }
        return n.formatted()
    }

    /// "1.2 MB of 4 MB read": how much of a session too large to read whole was read.
    static func readText(_ s: AgentSession) -> String {
        let done = bytes(s.bytesRead), size = bytes(s.fileSize)
        return String(localized: "\(done) of \(size) read", bundle: .previewKit, comment: "Session header: only part of a large session was read. Arguments: size read, file size.")
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// The longest length a header states: a session longer than this (a century) says this much and no more.
    static let maxDurationMinutes = 100 * 366 * 24 * 60

    static func durationText(_ t: TimeInterval) -> String {
        // Range-checked before the conversion: Int(Double) traps outside Int's range (S-16 F24). The parser already
        // drops implausible timestamps; this holds for any duration handed in. Clamping a display length is honest.
        let rounded = (t / 60).rounded()
        let m = rounded.isFinite ? Int(min(max(rounded, 0), Double(maxDurationMinutes))) : 0
        if m < 1 { return String(localized: "under a minute", bundle: .previewKit, comment: "Session length: less than one minute.") }
        if m < 60 {
            let minutes = m.formatted()
            return String(localized: "\(minutes) min", bundle: .previewKit, comment: "Session length in minutes (abbreviated).")
        }
        let hours = (m / 60).formatted(), minutes = (m % 60).formatted()
        return m % 60 == 0
            ? String(localized: "\(hours) h", bundle: .previewKit, comment: "Session length in whole hours (abbreviated).")
            : String(localized: "\(hours) h \(minutes) min", bundle: .previewKit, comment: "Session length in hours and minutes (abbreviated).")
    }

    // MARK: Icons (drawn here, 16-unit strokes in currentColor, after the design's own)

    static func icon(_ name: String) -> String {
        let path: String
        switch name {
        case "chat": path = "<path d=\"M2 3.5a1.25 1.25 0 011.25-1.25h9.5A1.25 1.25 0 0114 3.5v6.25A1.25 1.25 0 0112.75 11H6.5L3.5 13.75V11h-.25A1.25 1.25 0 012 9.75z\"/>"
        case "person": path = "<circle cx=\"8\" cy=\"5.5\" r=\"2.5\"/><path d=\"M3.5 13.5c.6-2.4 2.4-3.5 4.5-3.5s3.9 1.1 4.5 3.5\"/>"
        case "tool": path = "<path d=\"M9.8 2.6a3 3 0 00-3.7 3.9L2.6 10a1.4 1.4 0 002 2l3.5-3.5a3 3 0 003.9-3.7L10.3 6.5 9 5.2z\"/>"
        case "agent": path = "<rect x=\"3\" y=\"4.5\" width=\"10\" height=\"8\" rx=\"2\"/><path d=\"M8 2v2.5M6 8.5h.01M10 8.5h.01\"/>"
        case "lock": path = "<rect x=\"3.5\" y=\"7\" width=\"9\" height=\"6.5\" rx=\"1.5\"/><path d=\"M5.5 7V5a2.5 2.5 0 015 0v2\"/>"
        case "info": path = "<circle cx=\"8\" cy=\"8\" r=\"6\"/><path d=\"M8 7.2v4M8 4.8h.01\"/>"
        case "jump": path = "<path d=\"M5 6l3-3 3 3M5 10l3 3 3-3\"/>"
        case "chev": path = "<path d=\"M6 4l4 4-4 4\"/>"
        default: path = ""
        }
        return "<svg class=\"ic\" width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\(path)</svg>"
    }

    // MARK: Styles (the design's classes, on the unified tokens)

    static let css = """
    html, body { margin: 0; background: var(--v-win); color: var(--v-t1); font: 13px/1.45 var(--v-font); -webkit-font-smoothing: antialiased; }
    #vt-s { padding: 12px 14px 20px; max-width: 980px; }
    .t2 { color: var(--v-t2); } .t3 { color: var(--v-t3); } .c-danger { color: var(--v-danger-text); }
    .add { color: var(--v-diff-add-text); font-weight: 600; } .del { color: var(--v-diff-del-text); font-weight: 600; }
    .sp { flex: 1; }
    code { font: 11.5px var(--v-mono); background: var(--v-code); border-radius: 4px; padding: 0 3px; }
    pre.code { font: 11.5px/1.5 var(--v-mono); background: var(--v-code); border-radius: 8px; padding: 7px 10px; white-space: pre-wrap; margin: 4px 0; }
    .ic { flex: none; }
    .kbd { display: inline-block; font: 500 10.5px/15px var(--v-font); color: var(--v-t2); border: .5px solid var(--v-hair); border-bottom-width: 1.5px; border-radius: var(--v-r-kbd); padding: 0 4px; background: var(--v-card); white-space: nowrap; }
    .btn { display: inline-flex; align-items: center; justify-content: center; height: var(--v-h-ctl-sm); padding: 0 8px; font: 500 var(--v-fs-sub)/1 var(--v-font); border-radius: var(--v-r-ctl); background: var(--v-ctl); box-shadow: 0 0 0 .5px var(--v-hair), 0 .5px 1px rgba(0,0,0,.12); color: var(--v-t1); white-space: nowrap; flex: none; margin-left: 6px; }
    .hcard { display: flex; gap: 10px; align-items: flex-start; background: var(--v-card); border-radius: var(--v-r-panel); box-shadow: 0 0 0 .5px var(--v-hair), 0 1px 3px rgba(0,0,0,.06); padding: 10px 12px; margin-bottom: 8px; }
    .htile { width: 36px; height: 36px; border-radius: 9px; display: grid; place-items: center; background: var(--v-kind-ai); color: var(--v-on-accent); flex: none; }
    .htile .ic { width: 18px; height: 18px; }
    .htx { flex: 1; min-width: 0; }
    .ht { font-size: var(--v-fs-title3); font-weight: var(--v-fs-title3-w); letter-spacing: -.01em; line-height: var(--v-fs-title3-lh); overflow-wrap: anywhere; }
    .hs { font-size: 11.5px; color: var(--v-t2); margin-top: 1px; }
    .hmeter { margin-top: 8px; } .mbox { font-size: 11.5px; }
    .mline { display: flex; justify-content: space-between; margin-bottom: 5px; }
    .segbar { display: flex; height: 8px; border-radius: 4px; overflow: hidden; background: var(--v-fill); gap: 1px; }
    .segbar i { display: block; height: 100%; }
    .leg { display: flex; flex-wrap: wrap; gap: 2px 8px; font-size: 10.5px; color: var(--v-t2); margin-top: 6px; }
    .leg i { display: inline-block; width: 8px; height: 8px; border-radius: 2px; margin-right: 4px; }
    .kv { display: grid; grid-template-columns: auto 1fr; gap: 3px 12px; font-size: var(--v-fs-sub); margin-top: 8px; }
    .kv .k { color: var(--v-t2); } .kv .v { font-variant-numeric: tabular-nums; min-width: 0; overflow-wrap: anywhere; }
    .dgroup { box-shadow: inset 0 3px 0 var(--v-danger); padding: 9px 2px 6px; margin: 4px 0 8px; }
    .dgroup .dt { color: var(--v-danger-text); font-weight: 650; font-size: 12.5px; } .dgroup .ds { font-size: 12px; color: var(--v-t2); }
    .jumpbar { display: flex; align-items: center; gap: 6px; font-size: 11.5px; padding: 5px 10px; margin: 0 0 8px; border-radius: 9px; background: var(--v-card); box-shadow: 0 0 0 .5px var(--v-hair); white-space: nowrap; overflow: hidden; }
    .jumpbar .t2 { overflow: hidden; text-overflow: ellipsis; }
    .hbody { background: var(--v-card); border-radius: 12px; box-shadow: 0 0 0 .5px var(--v-hair); padding: 10px 14px; }
    .rail { position: relative; padding-left: 34px; }
    .rail:before { content: ""; position: absolute; left: 14px; top: 6px; bottom: 6px; width: 1.5px; background: var(--v-hair); }
    .rr { position: relative; margin: 0 0 9px; }
    .rn { position: absolute; left: -34px; top: 1px; width: 30px; display: grid; place-items: center; }
    .rn .ic { width: 11px; height: 11px; }
    .rn.user { left: -29px; width: 20px; height: 20px; border-radius: 50%; background: var(--v-accent); color: var(--v-on-accent); }
    .rn.dot:after { content: ""; width: 7px; height: 7px; border-radius: 50%; background: var(--v-t3); margin-top: 5px; }
    .rn.ring:after { content: ""; width: 8px; height: 8px; border-radius: 50%; border: 1.5px solid var(--v-t3); margin-top: 3px; background: var(--v-card); }
    .rn.tool { left: -27px; width: 16px; height: 16px; border-radius: 5px; background: var(--v-page); box-shadow: 0 0 0 1px var(--v-hair); color: var(--v-t2); }
    .rn.tool.err { background: var(--v-danger); color: var(--v-on-accent); box-shadow: none; }
    .rn.agent { left: -27px; width: 16px; height: 16px; border-radius: 5px; background: var(--v-kind-ai); color: var(--v-on-accent); }
    .rr-who { font-size: 11px; font-weight: 600; color: var(--v-accent-text); }
    .rr-user { font-size: var(--v-fs-body); font-weight: 500; line-height: 1.5; white-space: pre-wrap; overflow-wrap: anywhere; }
    .rr-user.bub { background: var(--v-accent-soft); border-radius: 4px 12px 12px 12px; padding: 6px 10px; display: inline-block; max-width: 100%; box-sizing: border-box; }
    .rr-a { font-size: 13px; line-height: 1.55; overflow-wrap: anywhere; } .rr-a p { margin: 0 0 6px; } .rr-a p:last-child { margin-bottom: 0; }
    .rr-think { font-size: 11.5px; color: var(--v-t3); font-style: italic; display: flex; gap: 4px; align-items: center; }
    .rr-thb { font-size: 12px; color: var(--v-t2); font-style: italic; padding: 2px 0 0 14px; white-space: pre-wrap; overflow-wrap: anywhere; }
    .rr-note { font-size: 11.5px; color: var(--v-t2); }
    .rr-tool { display: flex; align-items: center; gap: 6px; font-size: 12px; min-height: 18px; }
    .rr-tool .tm { font-size: 10.5px; min-width: 34px; text-align: right; flex: none; }
    .arg { color: var(--v-t2); font-family: var(--v-mono); font-size: 11.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
    .res { font-size: 11.5px; color: var(--v-t2); white-space: nowrap; } .res.err { color: var(--v-danger-text); font-weight: 600; }
    .rr-agres { font-size: 11.5px; color: var(--v-t2); margin-top: 2px; white-space: pre-wrap; overflow-wrap: anywhere; }
    .rr.errrow > .rb { background: var(--v-danger-soft); box-shadow: inset 0 0 0 .5px var(--v-danger-line); border-radius: var(--v-r-ctl); padding: 2px 6px; margin-left: -6px; }
    details > summary { list-style: none; cursor: default; } details > summary::-webkit-details-marker { display: none; }
    details[open] > summary .ic { transform: rotate(90deg); }
    .tout { font: 11px/1.55 var(--v-mono); background: var(--v-code); border-radius: 8px; padding: 7px 10px; margin: 4px 0 6px; color: var(--v-t2); white-space: pre-wrap; overflow-wrap: anywhere; max-height: 360px; overflow: auto; }
    .tout.err { box-shadow: inset 3px 0 0 var(--v-danger); }
    .secnote { font-size: 11px; color: var(--v-danger-text); margin: 0 0 6px; display: flex; gap: 5px; align-items: center; font-weight: 600; }
    .unk { margin: 10px 0 4px; font-size: 11.5px; color: var(--v-t2); background: var(--v-fill); border-radius: 8px; padding: 7px 10px; display: flex; gap: 6px; align-items: flex-start; }
    mark.vt-find { background: var(--v-find); color: inherit; border-radius: 2px; }
    mark.vt-find.cur { background: var(--v-find-cur); box-shadow: 0 0 0 2px var(--v-find-cur); }
    @media (max-width: 420px) {
      #vt-s { padding: 8px; } .hcard { padding: 8px; } .hbody { padding: 8px; }
      .hmeter, .kv, .jumpbar .kbd, .jumpbar .t3, .tm { display: none; }
      .htile { width: 28px; height: 28px; }
    }
    """
}
