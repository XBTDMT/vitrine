import Foundation
import VitrineText

/// Reads a Claude Code or Codex transcript (`.jsonl`, one JSON record per line) into an `AgentSession`. Bounded by
/// `SessionLimits`: only the first `maxBytes` are read, long texts are cut, the rail keeps `maxItems` rows.
/// Every record is read with JSONSerialization and looked at by key; a record or field it does not know is skipped
/// and counted, never fatal. roadmap: S-11
///
/// Record shapes, and where they come from. Nothing under ~/.claude or ~/.codex was opened to learn them: the
/// sources are public documentation and the shapes as commonly described, recalled (not fetched) in this session,
/// so every one is unverified against a real file and the reader is written to tolerate their absence.
///
/// Claude Code (docs.anthropic.com/en/docs/claude-code: "hooks" for `transcript_path`, `session_id`, `cwd`;
/// transcripts live in `~/.claude/projects/<project folder>/<session id>.jsonl`, or under `$CLAUDE_CONFIG_DIR`):
/// - every line: `type`, `uuid`, `parentUuid`, `sessionId`, `timestamp` (ISO 8601), `cwd`, `gitBranch`, `version`,
///   `isSidechain` (a subagent's record), `isMeta` (a line the program added, not the person).
/// - `type: "user"`: `message.content` is a string (a prompt) or an array of `{type: "text", text}`,
///   `{type: "image"}` and `{type: "tool_result", tool_use_id, content (string or text blocks), is_error}`;
///   a tool result's record may carry `toolUseResult` (Edit: `originalFile`, `structuredPatch` [{oldStart,
///   oldLines, newStart, newLines, lines}]; Write: `type` "create"/"update", `content`, `originalFile`; Read:
///   `file.numLines`; Task: `totalToolUseCount`, `totalTokens`).
/// - `type: "assistant"`: `message.id`, `message.model`, `message.usage` {input_tokens,
///   cache_creation_input_tokens, cache_read_input_tokens, output_tokens}, `message.content` of `{type: "text"}`,
///   `{type: "thinking", thinking}`, `{type: "redacted_thinking"}` and `{type: "tool_use", id, name, input}`.
///   Edit input {file_path, old_string, new_string, replace_all}; MultiEdit {file_path, edits: [{old_string,
///   new_string, replace_all}]}; Write {file_path, content}; NotebookEdit {notebook_path, new_source}; Bash
///   {command, description}; Read/Glob/Grep {file_path | pattern, path}; Task {description, prompt, subagent_type}.
/// - `type: "summary"` {summary} and a record with `customTitle`: the session's name.
/// - also seen and not drawn: `system`, `file-history-snapshot`, `queue-operation`, `progress`.
///
/// Codex (github.com/openai/codex, the rollout recorder; files `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`):
/// - current lines: `{timestamp, type, payload}` with `type` one of `session_meta` (payload id, timestamp, cwd,
///   cli_version, git {branch}), `turn_context` (cwd, model), `response_item` (payload.type `message` {role,
///   content [{type: input_text | output_text, text}]}, `reasoning` {summary [{text}]}, `function_call` {name,
///   arguments (a JSON string), call_id}, `function_call_output` {call_id, output}, `custom_tool_call` {name,
///   input, call_id}, `custom_tool_call_output`, `local_shell_call` {call_id, action {command}}), `event_msg`
///   (`user_message`, `agent_message`, `token_count` {info {last_token_usage {input_tokens, output_tokens},
///   model_context_window}}) and `compacted`.
/// - older files: a first line `{id, timestamp, instructions, git}` then bare response items (`{type: "message",
///   role, content}` …) and `{record_type: "state"}` lines.
/// - edits come as `apply_patch` (a custom tool call's `input`, or a shell call's command; see CodexPatch).
public enum SessionParser {
    /// Which agent wrote the transcript, from its first lines; nil = not an agent session (any other JSON Lines).
    public static func detect(_ prefix: Data) -> SessionSource? {
        var claudeVotes = 0, codexVotes = 0, seen = 0
        for line in prefix.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard seen < 40 else { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            seen += 1
            let type = obj["type"] as? String
            if obj["sessionId"] != nil || ((type == "user" || type == "assistant") && obj["message"] is [String: Any]) { claudeVotes += 1 }
            if type == "summary", obj["leafUuid"] != nil { claudeVotes += 1 }
            if let type, ["session_meta", "response_item", "event_msg", "turn_context"].contains(type), obj["payload"] != nil { codexVotes += 1 }
            if seen == 1, obj["instructions"] != nil, obj["id"] != nil, obj["timestamp"] != nil { codexVotes += 1 }
            if type == "message", obj["role"] != nil, obj["content"] is [Any], obj["message"] == nil { codexVotes += 1 }
        }
        if claudeVotes == 0, codexVotes == 0 { return nil }
        return claudeVotes >= codexVotes ? .claudeCode : .codex
    }

    /// Reads the file's start (up to `limits.maxBytes`) and parses it; nil = not an agent session.
    public static func parse(url: URL, limits: SessionLimits = .preview) throws -> AgentSession? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // The first 256 KB decide; any other JSON Lines file is never read further.
        var data = try handle.read(upToCount: min(limits.maxBytes, 256 << 10)) ?? Data()
        guard detect(data) != nil else { return nil }
        if data.count < limits.maxBytes, let rest = try handle.read(upToCount: limits.maxBytes - data.count) { data.append(rest) }
        return parse(data: data, fileSize: max(size, Int64(data.count)), limits: limits)
    }

    public static func parse(data: Data, fileSize: Int64? = nil, limits: SessionLimits = .preview) -> AgentSession? {
        guard let source = detect(data.prefix(256 << 10)) else { return nil }
        var body = data
        let size = fileSize ?? Int64(data.count)
        // A read that stopped inside a line drops that partial line.
        if Int64(data.count) < size, let lastNewline = data.lastIndex(of: 0x0A) { body = data[data.startIndex...lastNewline] }
        var session: AgentSession
        switch source {
        case .claudeCode:
            var reader = ClaudeCodeReader(limits: limits)
            reader.read(body)
            session = reader.finish()
        case .codex:
            var reader = CodexReader(limits: limits)
            reader.read(body)
            session = reader.finish()
        }
        session.bytesRead = Int64(body.count)
        session.fileSize = size
        return session
    }

    // MARK: Shared helpers

    /// The times a transcript may record: 1970 to 2100. A timestamp outside them is damaged and reads as no time, so
    /// a session's length stays a length a person could have spent (S-16 F24).
    static let plausibleTimes = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 4_102_444_800)

    static func date(_ value: Any?) -> Date? {
        let date: Date?
        if let s = value as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) {
                date = d
            } else {
                f.formatOptions = [.withInternetDateTime]
                date = f.date(from: s)
            }
        } else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite {
            let v = n.doubleValue
            date = Date(timeIntervalSince1970: v > 1e11 ? v / 1000 : v)
        } else {
            date = nil
        }
        guard let date, plausibleTimes.contains(date) else { return nil }
        return date
    }

    /// The largest count a transcript may record (tokens, lines, tool calls, line numbers): 2^50, far beyond any real
    /// session, and small enough that sums of a few of them never come near `Int.max`.
    static let maxCount = 1 << 50

    /// A whole, non-negative count from a transcript; nil when it is absent, not a number (a Boolean included), not
    /// finite, negative or past `maxCount`. A count the file damaged reads as not recorded, never as a trap (S-16 F23).
    static func count(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d <= Double(maxCount) else { return nil }
        return Int(d.rounded(.towardZero))
    }

    /// Counts added without a trap: past `Int.max` the sum stays at `Int.max`.
    static func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(0) { total, n in
            let (sum, overflow) = total.addingReportingOverflow(n)
            return overflow ? (n < 0 ? Int.min : Int.max) : sum
        }
    }

    static func cut(_ s: String, _ limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "\n…"
    }

    static func lineCount(_ s: String) -> Int {
        guard !s.isEmpty else { return 0 }
        var n = s.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        if !s.hasSuffix("\n") { n += 1 }
        return n
    }

    static func firstLine(_ s: String, max: Int = 120) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }

    /// Lines added and removed going from `old` to `new` (both cut to `limit`).
    static func lineDelta(old: String, new: String, limit: Int) -> (Int, Int) {
        if old.isEmpty { return (lineCount(String(new.prefix(limit))), 0) }
        if new.isEmpty { return (0, lineCount(String(old.prefix(limit)))) }
        let r = TextCompare.compare(old: String(old.prefix(limit)), new: String(new.prefix(limit)))
        return (r.additions, r.deletions)
    }

    /// The text of a content value: a string, or the `text` of each text block in an array.
    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [Any] else { return "" }
        return blocks.compactMap { block -> String? in
            guard let b = block as? [String: Any] else { return block as? String }
            if let t = b["text"] as? String { return t }
            if (b["type"] as? String) == "image" || (b["type"] as? String) == "input_image" { return Self.imageWord }
            return nil
        }.joined(separator: "\n")
    }

    /// "[image]": an image in a message, which the conversation does not draw.
    static let imageWord = String(localized: "[image]", bundle: .previewKit, comment: "Stands for an image in a session's message.")
    /// A tool call's result when it failed.
    static let failed = String(localized: "failed", bundle: .previewKit, comment: "A session's tool call failed.")

    /// "claude-sonnet-4-5-20250929" → "Claude Sonnet 4.5"; "claude-3-5-haiku-20241022" → "Claude Haiku 3.5";
    /// anything else is returned as written.
    public static func modelName(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        var parts = id.dropFirst(7).split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        let words = parts.filter { Int($0) == nil }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let numbers = parts.filter { Int($0) != nil && $0.count <= 2 }
        guard !words.isEmpty else { return id }
        return (["Claude"] + words + (numbers.isEmpty ? [] : [numbers.joined(separator: ".")])).joined(separator: " ")
    }
}

// MARK: Secrets

/// Masking what a transcript shows (design ai.html state 4: "a secret masked in tool output"): command output and
/// tool inputs through SecretMask (key = value lines, URLs with passwords, known credential forms); prose only for
/// credentials recognisable by their form, since "Token: …" in a sentence is not a secret. roadmap: S-11
enum SessionSecrets {
    /// Credentials by their form. A match starts only where a token starts (no letter, digit, `_` or `-` before it)
    /// and every run is possessive, so each token is tried once and a text is read in linear time whatever it holds:
    /// "-eyJ-eyJ-eyJ…" no longer makes every "eyJ" rescan the rest of the run (S-16 F47).
    static let credential = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_-])(?:(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{8,}+|gh[pousr]_[A-Za-z0-9]{20,}+|github_pat_[A-Za-z0-9_]{20,}+|AKIA[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9-]{10,}+|sk-[A-Za-z0-9_-]{20,}+|AIza[0-9A-Za-z_-]{30,}+|eyJ[A-Za-z0-9_-]{10,}+\.[A-Za-z0-9_-]{10,}+\.[A-Za-z0-9_-]++)"#)

    /// The vendor's own fixed start of each form above, the only part of a match ever kept in clear: the random body
    /// is never searched for a delimiter, since `_` and `-` are ordinary characters inside it (S-16 F25).
    static let knownPrefix = try! NSRegularExpression(
        pattern: #"^(?:(?:sk|rk|pk)_(?:live|test)_|gh[pousr]_|github_pat_|AKIA|xox[abposr]-|sk-(?:ant-[a-z]{1,12}[0-9]{0,4}-|proj-|svcacct-|admin-)?|AIza|eyJ)"#)

    /// The last four characters are shown only when at least this many characters of the body stay hidden.
    static let minHiddenForSuffix = 16

    /// One credential as shown: its known prefix, bullets, and the last four characters when the body is long.
    static func masked(_ found: String) -> String {
        let ns = found as NSString
        let prefixLength = knownPrefix.firstMatch(in: found, range: NSRange(location: 0, length: ns.length))?.range.length ?? 0
        let prefix = ns.substring(to: prefixLength)
        let body = ns.length - prefixLength
        let suffix = body - 4 >= minHiddenForSuffix ? ns.substring(from: ns.length - 4) : ""
        return prefix + SecretMask.bullets(found.count) + suffix
    }

    /// Credentials by form anywhere in the text.
    static func maskProse(_ text: String) -> (String, Int) {
        let ns = text as NSString
        let matches = credential.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, 0) }
        let out = NSMutableString(string: text)
        for m in matches.reversed() {
            out.replaceCharacters(in: m.range, with: masked(ns.substring(with: m.range)))
        }
        return (out as String, matches.count)
    }

    /// A URL as shown: credentials by form, a password in its user part, and the values of query parameters whose
    /// names say secret (token, key, password …), through the config masker's own rules.
    static func maskURL(_ url: String) -> (String, Int) {
        let (prose, formed) = maskProse(url)
        var count = formed
        let authority = SecretMask.mask("u=" + prose)
        var out = String(authority.text.dropFirst(2))
        count += authority.count
        guard let mark = out.firstIndex(of: "?") else { return (out, count) }
        let start = out.index(after: mark)
        let end = out[start...].firstIndex(of: "#") ?? out.endIndex
        let parts = out[start..<end].split(separator: "&", omittingEmptySubsequences: false).map { part -> String in
            guard part.contains("=") else { return String(part) }
            let r = SecretMask.mask(String(part))
            count += r.count
            return r.text
        }
        out.replaceSubrange(start..<end, with: parts.joined(separator: "&"))
        return (out, count)
    }

    /// Tool input or output: key = value lines first, then credentials by form.
    static func maskOutput(_ text: String) -> (String, Int) {
        let lines = SecretMask.mask(text)
        let (prose, n) = maskProse(lines.text)
        return (prose, lines.count + n)
    }

    /// Characters past a cut that are still read for credentials, so a credential that straddles the cut is
    /// recognised whole instead of showing its first characters in clear.
    static let cutMargin = 1_024

    /// `text` cut to `limit` characters with credentials masked. Masking reads at most `limit + cutMargin`
    /// characters, whatever the text's size: a thinking block used to be masked whole, up to the 48 MB a preview
    /// reads, before it was cut (S-16 F47).
    static func maskProse(_ text: String, cutTo limit: Int) -> (String, Int) {
        masking(text, cutTo: limit, with: maskProse)
    }

    /// The same for tool input or output.
    static func maskOutput(_ text: String, cutTo limit: Int) -> (String, Int) {
        masking(text, cutTo: limit, with: maskOutput)
    }

    private static func masking(_ text: String, cutTo limit: Int, with mask: (String) -> (String, Int)) -> (String, Int) {
        guard limit > 0 else { return ("", 0) }
        let window = text.prefix(limit + cutMargin)
        let (masked, n) = mask(String(window))
        if masked.count > limit { return (String(masked.prefix(limit)) + "\n…", n) }
        return (window.endIndex < text.endIndex ? masked + "\n…" : masked, n)
    }
}

// MARK: Claude Code

private struct ClaudeCodeReader {
    let limits: SessionLimits
    var s = AgentSession(source: .claudeCode)
    var toolIndex: [String: Int] = [:]
    var editsByTool: [Int: [Int]] = [:]
    var assistantIDs = Set<String>()
    var firstPrompt: String?
    var summary: String?
    var customTitle: String?
    static let ignored: Set<String> = ["system", "file-history-snapshot", "queue-operation", "progress", "attachment"]
    static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    init(limits: SessionLimits) { self.limits = limits }

    mutating func read(_ data: Data) {
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            s.linesRead += 1
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                if !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { s.unreadableLines += 1 }
                continue
            }
            record(obj)
        }
    }

    mutating func add(_ item: SessionItem) {
        guard s.items.count < limits.maxItems else { s.itemsCut = limits.maxItems > 0; return }
        s.items.append(item)
    }

    mutating func record(_ obj: [String: Any]) {
        let time = SessionParser.date(obj["timestamp"])
        if let time {
            if s.started == nil || time < s.started! { s.started = time }
            if s.ended == nil || time > s.ended! { s.ended = time }
        }
        if s.id == nil, let id = obj["sessionId"] as? String { s.id = id }
        if let cwd = obj["cwd"] as? String, !cwd.isEmpty { s.cwd = cwd }
        if let branch = obj["gitBranch"] as? String, !branch.isEmpty { s.branch = branch }
        if let v = obj["version"] as? String { s.version = v }
        if let t = obj["customTitle"] as? String, !t.isEmpty { customTitle = t }
        let type = obj["type"] as? String ?? ""
        let sidechain = obj["isSidechain"] as? Bool ?? false
        switch type {
        case "user": user(obj, time: time, sidechain: sidechain)
        case "assistant": assistant(obj, time: time, sidechain: sidechain)
        case "summary":
            if summary == nil, let t = obj["summary"] as? String, !t.isEmpty { summary = t }
        case "custom-title": break
        default:
            if obj["customTitle"] != nil { break }
            if !Self.ignored.contains(type) { s.unknownKinds[type.isEmpty ? "untyped" : type, default: 0] += 1 }
        }
    }

    mutating func user(_ obj: [String: Any], time: Date?, sidechain: Bool) {
        let message = obj["message"] as? [String: Any]
        let content = message?["content"]
        if let blocks = content as? [Any] {
            var texts: [String] = []
            for case let block as [String: Any] in blocks {
                switch block["type"] as? String {
                case "tool_result": toolResult(block, record: obj, sidechain: sidechain)
                case "text": if let t = block["text"] as? String { texts.append(t) }
                case "image": texts.append(SessionParser.imageWord)
                default: break
                }
            }
            if !texts.isEmpty { prompt(texts.joined(separator: "\n"), meta: obj["isMeta"] as? Bool ?? false, time: time, sidechain: sidechain) }
        } else if let text = content as? String {
            prompt(text, meta: obj["isMeta"] as? Bool ?? false, time: time, sidechain: sidechain)
        }
    }

    mutating func prompt(_ raw: String, meta: Bool, time: Date?, sidechain: Bool) {
        if sidechain { s.subagentTurns += 1; return }
        guard !meta else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text.hasPrefix("<command-name>") || text.contains("<command-name>") {
            let name = text.range(of: "<command-name>").flatMap { r in text.range(of: "</command-name>", range: r.upperBound..<text.endIndex).map { String(text[r.upperBound..<$0.lowerBound]) } } ?? "command"
            add(.note(text: String(localized: "Ran \(name)", bundle: .previewKit, comment: "Session note: the person ran this slash command; the argument is its name."), time: time))
            return
        }
        if text.hasPrefix("<local-command-stdout>") || text.hasPrefix("<local-command-stderr>") || text.hasPrefix("<system-reminder>") { return }
        if text.hasPrefix("[Request interrupted") {
            add(.note(text: String(localized: "Interrupted by the person", bundle: .previewKit, comment: "Session note: the person stopped the agent mid-reply."), time: time))
            return
        }
        let (masked, n) = SessionSecrets.maskProse(text, cutTo: limits.textChars)
        s.maskedSecrets += n
        s.turns += 1
        s.prompts += 1
        if firstPrompt == nil { firstPrompt = SessionParser.firstLine(text, max: 80) }
        add(.prompt(text: masked, time: time))
    }

    mutating func assistant(_ obj: [String: Any], time: Date?, sidechain: Bool) {
        guard let message = obj["message"] as? [String: Any] else { return }
        if let model = message["model"] as? String, !model.hasPrefix("<") { s.model = model }
        let messageID = message["id"] as? String ?? obj["uuid"] as? String ?? UUID().uuidString
        let firstBlock = assistantIDs.insert(messageID).inserted
        if sidechain {
            if firstBlock { s.subagentTurns += 1 }
        } else if firstBlock {
            s.turns += 1
        }
        if !sidechain, let usage = message["usage"] as? [String: Any] {
            // Counters from the file: one that is there but is not a count makes the reading unknown, and the sum
            // cannot trap (S-16 F23).
            let counters = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].map { key -> Int? in
                guard let value = usage[key], !(value is NSNull) else { return 0 }
                return SessionParser.count(value)
            }
            if counters.allSatisfy({ $0 != nil }) {
                let used = SessionParser.saturatingSum(counters.compactMap { $0 })
                if used > 0 { s.context = SessionContext(used: used, window: nil, output: SessionParser.count(usage["output_tokens"])) }
            }
        }
        guard let blocks = message["content"] as? [Any] else { return }
        for case let block as [String: Any] in blocks {
            switch block["type"] as? String {
            case "text":
                guard !sidechain, let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let (masked, n) = SessionSecrets.maskProse(t, cutTo: limits.textChars)
                s.maskedSecrets += n
                add(.reply(text: masked, time: time))
            case "thinking", "redacted_thinking":
                guard !sidechain else { continue }
                // Cut before masking, as prompts and replies are: masking reads a bounded window (S-16 F47).
                let (masked, n) = SessionSecrets.maskProse(block["thinking"] as? String ?? "", cutTo: limits.textChars)
                s.maskedSecrets += n
                add(.thinking(text: masked, time: time))
            case "tool_use":
                toolUse(block, time: time, sidechain: sidechain)
            default: break
            }
        }
    }

    mutating func toolUse(_ block: [String: Any], time: Date?, sidechain: Bool) {
        let id = block["id"] as? String ?? UUID().uuidString
        let name = block["name"] as? String ?? "Tool"
        let input = block["input"] as? [String: Any] ?? [:]
        var call = SessionToolCall(id: id, name: name, argument: "", time: time)
        let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String
        var masked = 0
        switch name {
        case "Bash":
            let (cmd, n) = SessionSecrets.maskOutput(SessionParser.firstLine(input["command"] as? String ?? "", max: 160))
            call.argument = cmd; masked += n
        case "Grep", "Glob":
            call.argument = input["pattern"] as? String ?? ""
        case "Task", "Agent":
            let type = input["subagent_type"] as? String ?? "general-purpose"
            let description = input["description"] as? String ?? SessionParser.firstLine(input["prompt"] as? String ?? "")
            call.argument = description
            call.subagent = .init(type: type, description: description)
        case "WebFetch": call.argument = input["url"] as? String ?? ""
        case "WebSearch": call.argument = input["query"] as? String ?? ""
        case "TodoWrite":
                let todos = (input["todos"] as? [Any])?.count ?? 0, count = todos.formatted()
                call.argument = todos == 1
                    ? String(localized: "\(count) item", bundle: .previewKit, comment: "Session tool call argument: a to-do list with one item.")
                    : String(localized: "\(count) items", bundle: .previewKit, comment: "Session tool call argument: how many items a to-do list has.")
        default:
            call.argument = path.map { s.relative($0) } ?? SessionParser.firstLine(input.values.compactMap { $0 as? String }.first ?? "", max: 100)
        }
        if let path, ["Read", "Edit", "MultiEdit", "Write", "NotebookEdit"].contains(name) { call.argument = s.relative(path) }
        // Every argument shown is masked, not only a command (S-16): a fetched URL can carry a token in its query or
        // its user part, and a search or a task description can quote a key. Bash went through maskOutput above;
        // the to-do count is Vitrine's own words.
        if name != "Bash", name != "TodoWrite" {
            let (argument, n) = name == "WebFetch" ? SessionSecrets.maskURL(call.argument) : SessionSecrets.maskProse(call.argument)
            call.argument = argument; masked += n
        }
        call.maskedSecrets = masked
        s.maskedSecrets += masked
        let index = s.tools.count
        s.tools.append(call)
        toolIndex[id] = index
        if !sidechain { add(.tool(index)) }
        if Self.editTools.contains(name), let path { edits(name: name, input: input, path: path, tool: index, time: time, sidechain: sidechain) }
    }

    mutating func edits(name: String, input: [String: Any], path: String, tool: Int, time: Date?, sidechain: Bool) {
        let limit = limits.editChars
        var made: [SessionEdit] = []
        switch name {
        case "Edit":
            made.append(SessionEdit(path: path, operation: .replace(old: String((input["old_string"] as? String ?? "").prefix(limit)),
                                                                   new: String((input["new_string"] as? String ?? "").prefix(limit)),
                                                                   all: input["replace_all"] as? Bool ?? false),
                                    tool: tool, time: time, bySubagent: sidechain))
        case "MultiEdit":
            for case let e as [String: Any] in input["edits"] as? [Any] ?? [] {
                made.append(SessionEdit(path: path, operation: .replace(old: String((e["old_string"] as? String ?? "").prefix(limit)),
                                                                       new: String((e["new_string"] as? String ?? "").prefix(limit)),
                                                                       all: e["replace_all"] as? Bool ?? false),
                                        tool: tool, time: time, bySubagent: sidechain))
            }
        case "Write":
            made.append(SessionEdit(path: path, operation: .write(content: String((input["content"] as? String ?? "").prefix(limit)), created: nil),
                                    tool: tool, time: time, bySubagent: sidechain))
        case "NotebookEdit":
            // A notebook cell's new source; the cell is not located, so it reads as a written fragment.
            made.append(SessionEdit(path: path, operation: .replace(old: "", new: String((input["new_source"] as? String ?? "").prefix(limit)), all: false),
                                    tool: tool, time: time, bySubagent: sidechain))
        default: break
        }
        var adds = 0, dels = 0
        for e in made {
            switch e.operation {
            case .replace(let old, let new, _): let (a, d) = SessionParser.lineDelta(old: old, new: new, limit: limit); adds += a; dels += d
            case .write(let content, _): adds += SessionParser.lineCount(content)
            default: break
            }
        }
        s.tools[tool].additions = adds
        s.tools[tool].deletions = dels
        editsByTool[tool] = Array(s.edits.count..<(s.edits.count + made.count))
        s.edits += made
    }

    mutating func toolResult(_ block: [String: Any], record: [String: Any], sidechain: Bool) {
        guard let id = block["tool_use_id"] as? String, let index = toolIndex[id] else { return }
        let isError = block["is_error"] as? Bool ?? false
        let text = SessionParser.text(of: block["content"])
        let structured = record["toolUseResult"] as? [String: Any]
        var call = s.tools[index]
        call.isError = isError
        let lines = SessionParser.lineCount(text)
        switch call.name {
        case "Read":
            let n = SessionParser.count((structured?["file"] as? [String: Any])?["numLines"]) ?? lines
            let count = n.formatted()
            call.result = isError ? SessionParser.failed : n == 1
                ? String(localized: "\(count) line", bundle: .previewKit, comment: "Session tool call result: one line read.")
                : String(localized: "\(count) lines", bundle: .previewKit, comment: "Session tool call result: how many lines were read.")
        case "Bash":
            let count = lines.formatted()
            call.result = isError ? SessionParser.failed
                : lines == 0 ? String(localized: "no output", bundle: .previewKit, comment: "Session tool call result: the command printed nothing.")
                : lines == 1 ? String(localized: "\(count) line of output", bundle: .previewKit, comment: "Session tool call result: the command printed one line.")
                : String(localized: "\(count) lines of output", bundle: .previewKit, comment: "Session tool call result: how many lines the command printed.")
        case "Grep", "Glob":
            let count = lines.formatted()
            call.result = isError ? SessionParser.failed
                : lines == 0 ? String(localized: "no matches", bundle: .previewKit, comment: "Session tool call result: a search found nothing.")
                : lines == 1 ? String(localized: "\(count) result", bundle: .previewKit, comment: "Session tool call result: a search found one result.")
                : String(localized: "\(count) results", bundle: .previewKit, comment: "Session tool call result: how many results a search found.")
        case "Task", "Agent":
            call.subagent?.toolUses = SessionParser.count(structured?["totalToolUseCount"])
            call.subagent?.tokens = SessionParser.count(structured?["totalTokens"])
            call.result = isError ? SessionParser.failed : nil
        default:
            if isError { call.result = SessionParser.failed }
        }
        if call.name != "Read", limits.outputChars > 0, !text.isEmpty {
            let (masked, n) = SessionSecrets.maskOutput(text, cutTo: limits.outputChars)
            call.output = masked
            call.maskedSecrets += n
            s.maskedSecrets += n
        }
        s.tools[index] = call
        guard let editIndices = editsByTool[index] else { return }
        if isError {
            // A refused or failed edit changed nothing: it leaves the change list.
            let drop = Set(editIndices)
            s.edits = s.edits.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            editsByTool[index] = nil
            for (k, v) in editsByTool { editsByTool[k] = v.map { i in i - drop.filter { $0 < i }.count } }
            s.tools[index].additions = nil
            s.tools[index].deletions = nil
            return
        }
        guard let structured, let first = editIndices.first else { return }
        if let original = structured["originalFile"] as? String, original.count <= limits.editChars { s.edits[first].original = original }
        if case .write(let content, _) = s.edits[first].operation, let kind = structured["type"] as? String {
            s.edits[first].operation = .write(content: content, created: kind == "create")
        }
        if let hunks = structured["structuredPatch"] as? [Any], editIndices.count == 1 {
            let recorded: [SessionEdit.RecordedHunk] = hunks.compactMap { h in
                guard let h = h as? [String: Any] else { return nil }
                // Line numbers from the file: a hunk whose numbers are not counts is not used (the diff is rebuilt).
                let n = { (k: String) in SessionParser.count(h[k]) }
                guard let os = n("oldStart"), let ol = n("oldLines"), let ns = n("newStart"), let nl = n("newLines"), let lines = h["lines"] as? [String] else { return nil }
                return .init(oldStart: os, oldLines: ol, newStart: ns, newLines: nl, lines: lines)
            }
            if !recorded.isEmpty { s.edits[first].recordedHunks = recorded }
        }
    }

    mutating func finish() -> AgentSession {
        s.title = customTitle ?? summary ?? firstPrompt
            ?? String(localized: "Claude Code session", bundle: .previewKit, comment: "Title of a Claude Code session that has no title or prompt.")
        return s
    }
}

// MARK: Codex

private struct CodexReader {
    let limits: SessionLimits
    var s = AgentSession(source: .codex)
    var toolIndex: [String: Int] = [:]
    var firstPrompt: String?
    /// Messages arrive both as response items and as event messages in newer files; response items win.
    var sawResponseMessages = false
    /// Rows drawn from event messages, with the counts they added, taken out again if response items carry the same.
    var eventItems = Set<Int>()
    var eventTurns = 0, eventPrompts = 0
    static let ignoredTypes: Set<String> = ["compacted", "state"]

    init(limits: SessionLimits) { self.limits = limits }

    mutating func read(_ data: Data) {
        var first = true
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            s.linesRead += 1
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                if !line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { s.unreadableLines += 1 }
                continue
            }
            defer { first = false }
            if let type = obj["type"] as? String, let payload = obj["payload"] as? [String: Any] {
                wrapped(type: type, payload: payload, time: SessionParser.date(obj["timestamp"]))
            } else if first, obj["instructions"] != nil || obj["id"] != nil, obj["type"] == nil {
                // The older first line: the session's own facts.
                meta(obj)
            } else if obj["record_type"] != nil {
                continue
            } else if obj["type"] is String {
                item(obj, time: SessionParser.date(obj["timestamp"]))
            } else {
                s.unknownKinds["untyped", default: 0] += 1
            }
        }
    }

    mutating func touch(_ time: Date?) {
        guard let time else { return }
        if s.started == nil || time < s.started! { s.started = time }
        if s.ended == nil || time > s.ended! { s.ended = time }
    }

    mutating func add(_ item: SessionItem) {
        guard s.items.count < limits.maxItems else { s.itemsCut = limits.maxItems > 0; return }
        s.items.append(item)
    }

    mutating func meta(_ p: [String: Any]) {
        if let id = p["id"] as? String { s.id = id }
        if let cwd = p["cwd"] as? String { s.cwd = cwd }
        if let v = p["cli_version"] as? String { s.version = v }
        if let git = p["git"] as? [String: Any], let b = git["branch"] as? String { s.branch = b }
        touch(SessionParser.date(p["timestamp"]))
    }

    mutating func wrapped(type: String, payload: [String: Any], time: Date?) {
        touch(time)
        switch type {
        case "session_meta": meta(payload)
        case "turn_context":
            if let m = payload["model"] as? String { s.model = m }
            if let cwd = payload["cwd"] as? String { s.cwd = cwd }
        case "response_item": item(payload, time: time)
        case "event_msg": event(payload, time: time)
        default: if !Self.ignoredTypes.contains(type) { s.unknownKinds[type, default: 0] += 1 }
        }
    }

    mutating func event(_ p: [String: Any], time: Date?) {
        switch p["type"] as? String {
        case "user_message", "agent_message":
            guard let m = p["message"] as? String, !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let (turns, prompts, count) = (s.turns, s.prompts, s.items.count)
            if p["type"] as? String == "user_message" { userText(m, time: time) } else { replyText(m, time: time) }
            if s.items.count > count { eventItems.insert(count) }
            eventTurns += s.turns - turns; eventPrompts += s.prompts - prompts
        case "token_count":
            guard let info = p["info"] as? [String: Any] else { return }
            let last = info["last_token_usage"] as? [String: Any] ?? info["total_token_usage"] as? [String: Any]
            // Counts from the file (S-16 F40): a window that is not a positive count reads as not recorded.
            let used = SessionParser.count(last?["input_tokens"]) ?? 0
            if used > 0 {
                let window = SessionParser.count(info["model_context_window"]).flatMap { $0 > 0 ? $0 : nil }
                s.context = SessionContext(used: used, window: window, output: SessionParser.count(last?["output_tokens"]))
            }
        default: break
        }
    }

    mutating func item(_ p: [String: Any], time: Date?) {
        switch p["type"] as? String {
        case "message":
            let role = p["role"] as? String ?? ""
            let text = SessionParser.text(of: p["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if role == "user" {
                // Codex sends its own context as user messages wrapped in tags.
                if text.hasPrefix("<environment_context>") || text.hasPrefix("<user_instructions>") || text.hasPrefix("# AGENTS.md") { return }
                sawResponseMessages = true
                userText(text, time: time)
            } else if role == "assistant" {
                sawResponseMessages = true
                replyText(text, time: time)
            }
        case "reasoning":
            let summary = (p["summary"] as? [Any])?.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined(separator: "\n") ?? ""
            // Masked like Claude Code's thinking: a reasoning summary can quote a credential too.
            let (masked, n) = SessionSecrets.maskProse(summary, cutTo: limits.textChars)
            s.maskedSecrets += n
            add(.thinking(text: masked, time: time))
        case "function_call", "custom_tool_call", "local_shell_call":
            call(p, time: time)
        case "function_call_output", "custom_tool_call_output":
            output(p)
        case "web_search_call":
            let q = (p["action"] as? [String: Any])?["query"] as? String ?? ""
            appendTool(SessionToolCall(id: p["id"] as? String ?? UUID().uuidString,
                                       name: String(localized: "Web search", bundle: .previewKit, comment: "Name shown for a Codex session's web search tool call."), argument: q, time: time))
        default:
            s.unknownKinds[(p["type"] as? String) ?? "untyped", default: 0] += 1
        }
    }

    mutating func userText(_ text: String, time: Date?) {
        let (masked, n) = SessionSecrets.maskProse(text, cutTo: limits.textChars)
        s.maskedSecrets += n
        s.turns += 1; s.prompts += 1
        if firstPrompt == nil { firstPrompt = SessionParser.firstLine(text, max: 80) }
        add(.prompt(text: masked, time: time))
    }

    mutating func replyText(_ text: String, time: Date?) {
        let (masked, n) = SessionSecrets.maskProse(text, cutTo: limits.textChars)
        s.maskedSecrets += n
        s.turns += 1
        add(.reply(text: masked, time: time))
    }

    @discardableResult
    mutating func appendTool(_ call: SessionToolCall) -> Int {
        let index = s.tools.count
        s.tools.append(call)
        toolIndex[call.id] = index
        add(.tool(index))
        return index
    }

    mutating func call(_ p: [String: Any], time: Date?) {
        let id = p["call_id"] as? String ?? p["id"] as? String ?? UUID().uuidString
        var name = p["name"] as? String ?? (p["type"] as? String == "local_shell_call" ? "shell" : "tool")
        var command: [String] = []
        var patch: String?
        if let input = p["input"] as? String, name == "apply_patch" { patch = input }
        if let args = p["arguments"] as? String, let data = args.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            command = obj["command"] as? [String] ?? (obj["command"] as? String).map { [$0] } ?? []
            if name == "apply_patch", let input = obj["input"] as? String { patch = input }
        }
        if let action = p["action"] as? [String: Any] { command = action["command"] as? [String] ?? command }
        if patch == nil, !command.isEmpty { patch = CodexPatch.patchText(inCommand: command) }
        var call = SessionToolCall(id: id, name: name, argument: "", time: time)
        if let patch {
            name = "apply_patch"
            call.name = name
            let changes = CodexPatch.parse(patch)
            call.argument = changes.map { s.relative($0.movedTo ?? $0.path) }.joined(separator: ", ")
            let index = appendTool(call)
            var adds = 0, dels = 0
            for c in changes {
                let path = absolute(c.path)
                switch c.kind {
                case .add:
                    s.edits.append(SessionEdit(path: path, operation: .write(content: c.addedLines.joined(separator: "\n") + "\n", created: true), tool: index, time: time))
                    adds += c.addedLines.count
                case .update:
                    s.edits.append(SessionEdit(path: path, movedTo: c.movedTo.map(absolute), operation: .chunks(c.chunks), tool: index, time: time))
                    for chunk in c.chunks { for l in chunk.lines { if l.sign == "+" { adds += 1 } else if l.sign == "-" { dels += 1 } } }
                case .delete:
                    s.edits.append(SessionEdit(path: path, operation: .delete, tool: index, time: time))
                }
            }
            s.tools[index].additions = adds
            s.tools[index].deletions = dels
            return
        }
        if !command.isEmpty {
            // ["bash", "-lc", "npm test"] reads as the script.
            let script = command.count >= 3 && ["bash", "sh", "zsh"].contains((command[0] as NSString).lastPathComponent) ? command.last! : command.joined(separator: " ")
            let (cmd, n) = SessionSecrets.maskOutput(SessionParser.firstLine(script, max: 160))
            call.argument = cmd
            call.maskedSecrets = n
            s.maskedSecrets += n
            if name == "shell" || name == "local_shell" || name == "exec_command" {
                call.name = String(localized: "Shell", bundle: .previewKit, comment: "Name shown for a Codex session's shell command tool call.")
            }
        } else if let args = p["arguments"] as? String {
            // Masked like a command: arguments are tool input and can carry a credential.
            let (argument, n) = SessionSecrets.maskOutput(SessionParser.firstLine(args, max: 100))
            call.argument = argument
            call.maskedSecrets = n
            s.maskedSecrets += n
        }
        appendTool(call)
    }

    mutating func output(_ p: [String: Any]) {
        guard let id = p["call_id"] as? String, let index = toolIndex[id] else { return }
        var text = p["output"] as? String ?? SessionParser.text(of: p["output"])
        var exitCode: Int?
        // Shell output is often a JSON string: {"output": "…", "metadata": {"exit_code": 0}}.
        if let data = text.data(using: .utf8), text.hasPrefix("{"), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let o = obj["output"] as? String { text = o }
            exitCode = ((obj["metadata"] as? [String: Any])?["exit_code"] as? NSNumber)?.intValue
        }
        var call = s.tools[index]
        if let exitCode {
            call.isError = exitCode != 0
            let lines = SessionParser.lineCount(text)
            let code = String(exitCode), count = lines.formatted()
            call.result = lines == 0 ? String(localized: "exit \(code)", bundle: .previewKit, comment: "Session tool call result: the command's exit status. Keep “exit”, a shell word, or translate as the shell term.")
                : lines == 1 ? String(localized: "exit \(code) · \(count) line", bundle: .previewKit, comment: "Session tool call result: exit status and one line of output.")
                : String(localized: "exit \(code) · \(count) lines", bundle: .previewKit, comment: "Session tool call result: exit status and how many lines of output.")
        }
        if limits.outputChars > 0, !text.isEmpty, call.name != "apply_patch" {
            let (masked, n) = SessionSecrets.maskOutput(text, cutTo: limits.outputChars)
            call.output = masked
            call.maskedSecrets += n
            s.maskedSecrets += n
        }
        s.tools[index] = call
    }

    func absolute(_ path: String) -> String {
        guard !path.hasPrefix("/"), let cwd = s.cwd, !cwd.isEmpty else { return path }
        return (cwd as NSString).appendingPathComponent(path)
    }

    mutating func finish() -> AgentSession {
        if sawResponseMessages, !eventItems.isEmpty || eventTurns > 0 {
            s.items = s.items.enumerated().filter { !eventItems.contains($0.offset) }.map(\.element)
            s.turns -= eventTurns; s.prompts -= eventPrompts
        }
        s.title = firstPrompt ?? String(localized: "Codex session", bundle: .previewKit, comment: "Title of a Codex session that has no prompt.")
        return s
    }
}
