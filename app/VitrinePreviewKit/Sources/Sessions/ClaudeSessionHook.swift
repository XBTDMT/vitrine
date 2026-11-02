import Foundation

/// "Track Claude Code sessions" (design settings.html › Integrations › Agent sessions: "Adds one hook line to
/// ~/.claude/settings.json so the menu bar lists recent sessions"). Installing it changes the person's Claude Code
/// settings, so it is only ever an action they take: `plan` says exactly what would be written and changes nothing;
/// `apply` writes that plan and nothing else, and refuses if the file changed since the plan was shown; `remove`
/// takes out exactly the line it added. No test and no code path runs `apply` on the real file. roadmap: S-11
///
/// What the hook is: one `SessionStart` entry whose command appends the hook's input (Claude Code sends it as JSON on
/// standard input: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `source`) to a log in Vitrine's own
/// Application Support folder. It prints nothing (a SessionStart hook's standard output is added to the session's
/// context), sends nothing anywhere and reads nothing. The menu reads the log for transcript paths.
/// Sources: Claude Code's hooks documentation (docs.anthropic.com/en/docs/claude-code/hooks): settings `hooks` →
/// event → `[{matcher?, hooks: [{type: "command", command}]}]`, the stdin JSON fields, SessionStart's stdout going to
/// the context. Recalled, not fetched in this session: unverified, in particular that an entry without `matcher`
/// matches every SessionStart source.
public struct ClaudeSessionHook: Sendable {
    /// The comment that marks Vitrine's entry, so it is found and removed without touching anything else.
    public static let marker = "vitrine-session-hook"
    /// Where the hook appends, relative to the home folder.
    public static let logPath = "Library/Application Support/Vitrine/Agent Sessions/claude-code-hook.jsonl"

    /// The shell line Claude Code runs.
    public static let command =
        #"d="$HOME/Library/Application Support/Vitrine/Agent Sessions"; mkdir -p "$d" && { cat; echo; } >> "$d/claude-code-hook.jsonl" # "# + marker

    /// The one line added to the `SessionStart` list.
    public static var entry: String {
        let cmd = try! JSONSerialization.data(withJSONObject: command, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return #"{"hooks": [{"type": "command", "command": "# + String(decoding: cmd, as: UTF8.self) + "}]}"
    }

    public let settingsFile: URL
    public init(settingsFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")) {
        self.settingsFile = settingsFile
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case notJSONObject
        case unexpectedShape(String)
        case changedSinceShown
        case noSettingsFolder
        /// The part of the file an `unexpectedShape` names when it is the file's overall layout.
        static let layout = String(localized: "layout", bundle: .previewKit, comment: "Part of the Claude Code settings file named in an error: its overall layout.")

        public var errorDescription: String? {
            switch self {
            case .notJSONObject: String(localized: "The settings file is not a JSON object, so Vitrine leaves it alone.", bundle: .previewKit, comment: "Error adding the Claude Code session hook: ~/.claude/settings.json is not a JSON object.")
            case .unexpectedShape(let what): String(localized: "The settings file's \(what) is not in the shape Claude Code documents, so Vitrine leaves it alone.", bundle: .previewKit, comment: "Error adding the Claude Code session hook. The argument names the part of the settings file (a JSON key such as “hooks”, or its layout).")
            case .changedSinceShown: String(localized: "The settings file changed after the change was shown. Nothing was written; look again.", bundle: .previewKit, comment: "Error adding the Claude Code session hook: the file changed meanwhile.")
            case .noSettingsFolder: String(localized: "Claude Code's settings folder is not there, so there is nothing to add the hook to.", bundle: .previewKit, comment: "Error adding the Claude Code session hook: ~/.claude does not exist.")
            }
        }
    }

    /// One change, shown before it is made.
    public struct Plan: Sendable, Equatable {
        public enum Action: Sendable, Equatable { case install, remove }
        public let action: Action
        public let file: URL
        /// The file as read (empty when it does not exist yet).
        public let original: String
        public let exists: Bool
        /// The whole file as it would be written.
        public let updated: String
        /// The text added (install) or taken out (remove), exactly.
        public let change: String
    }

    // MARK: Reading

    public func read() -> (text: String, exists: Bool) {
        guard let data = try? Data(contentsOf: settingsFile) else { return ("", false) }
        return (String(decoding: data, as: UTF8.self), true)
    }

    public var isInstalled: Bool { Self.isInstalled(in: read().text) }

    public static func isInstalled(in text: String) -> Bool { !(entries(in: text)?.isEmpty ?? true) }

    // MARK: Planning (no writes)

    public func planInstall() throws -> Plan? {
        let (text, exists) = read()
        guard let updated = try Self.installing(into: text) else { return nil }
        return Plan(action: .install, file: settingsFile, original: text, exists: exists, updated: updated, change: Self.entry)
    }

    public func planRemove() throws -> Plan? {
        let (text, exists) = read()
        guard exists, let (updated, removed) = try Self.removing(from: text) else { return nil }
        return Plan(action: .remove, file: settingsFile, original: text, exists: exists, updated: updated, change: removed)
    }

    /// The settings text with the entry added; nil when it is already there.
    public static func installing(into original: String) throws -> String? {
        let base = original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}\n" : original
        guard (try? JSONSerialization.jsonObject(with: Data(base.utf8))) is [String: Any] else { throw Failure.notJSONObject }
        if isInstalled(in: base) { return nil }
        let j = JSONText(base)
        let unit = j.indentUnit
        let rootOpen = j.skipSpace(0)
        guard let root = j.members(rootOpen) else { throw Failure.notJSONObject }
        var out: String
        if let hooks = root.members.first(where: { $0.key == "hooks" }) {
            guard let inner = j.members(hooks.valueStart) else { throw Failure.unexpectedShape("\"hooks\"") }
            if let start = inner.members.first(where: { $0.key == "SessionStart" }) {
                guard let list = j.elements(start.valueStart) else { throw Failure.unexpectedShape("\"hooks.SessionStart\"") }
                let indent = j.lineIndent(start.keyStart) + unit
                out = insert(into: j, open: start.valueStart, close: list.close, lastEnd: list.elements.last?.end, item: entry,
                             indent: indent, closeIndent: j.lineIndent(start.keyStart))
            } else {
                let indent = j.lineIndent(hooks.keyStart) + unit
                let member = "\"SessionStart\": [\n\(indent + unit)\(entry)\n\(indent)]"
                out = insert(into: j, open: hooks.valueStart, close: inner.close, lastEnd: inner.members.last?.valueEnd, item: member,
                             indent: indent, closeIndent: j.lineIndent(hooks.keyStart))
            }
        } else {
            let indent = j.lineIndent(rootOpen) + unit
            let member = "\"hooks\": {\n\(indent + unit)\"SessionStart\": [\n\(indent + unit + unit)\(entry)\n\(indent + unit)]\n\(indent)}"
            out = insert(into: j, open: rootOpen, close: root.close, lastEnd: root.members.last?.valueEnd, item: member,
                         indent: indent, closeIndent: j.lineIndent(rootOpen))
        }
        // The result must read back as JSON with the entry in it, or nothing is offered.
        guard (try? JSONSerialization.jsonObject(with: Data(out.utf8))) is [String: Any], isInstalled(in: out) else {
            throw Failure.unexpectedShape(Failure.layout)
        }
        return out
    }

    /// Adds `item` to the container that opens at `open` and closes at `close`: after its last value with a comma, or
    /// as its only content.
    static func insert(into j: JSONText, open: Int, close: Int, lastEnd: Int?, item: String, indent: String, closeIndent: String) -> String {
        if let lastEnd {
            return j.text(0, lastEnd) + ",\n" + indent + item + j.text(lastEnd, j.bytes.count)
        }
        return j.text(0, open + 1) + "\n" + indent + item + "\n" + closeIndent + j.text(close, j.bytes.count)
    }

    /// Vitrine's entries in `hooks.SessionStart`: their ranges; nil when the file has no such list.
    static func entries(in text: String) -> [JSONText.Element]? {
        let j = JSONText(text)
        guard let root = j.members(j.skipSpace(0)),
              let hooks = root.members.first(where: { $0.key == "hooks" }), let inner = j.members(hooks.valueStart),
              let start = inner.members.first(where: { $0.key == "SessionStart" }), let list = j.elements(start.valueStart) else { return nil }
        return list.elements.filter { j.text($0.start, $0.end).contains(marker) }
    }

    /// The settings text with Vitrine's entry taken out (and the `SessionStart` list and the `hooks` object, when it
    /// leaves them empty), and the text taken out; nil when the entry is not there.
    public static func removing(from original: String) throws -> (String, String)? {
        guard (try? JSONSerialization.jsonObject(with: Data(original.utf8))) is [String: Any] else { throw Failure.notJSONObject }
        var text = original
        var removed = ""
        while true {
            let j = JSONText(text)
            guard let root = j.members(j.skipSpace(0)), let hooks = root.members.first(where: { $0.key == "hooks" }),
                  let inner = j.members(hooks.valueStart), let start = inner.members.first(where: { $0.key == "SessionStart" }),
                  let list = j.elements(start.valueStart),
                  let k = list.elements.firstIndex(where: { j.text($0.start, $0.end).contains(marker) }) else { break }
            let range: Range<Int>
            if list.elements.count > 1 {
                range = k > 0 ? list.elements[k - 1].end..<list.elements[k].end : list.elements[0].start..<list.elements[1].start
            } else if inner.members.count > 1 {
                let m = inner.members.firstIndex { $0.key == "SessionStart" }!
                range = memberRange(inner.members, m)
            } else if root.members.count > 1 {
                let m = root.members.firstIndex { $0.key == "hooks" }!
                range = memberRange(root.members, m)
            } else {
                // The hook was the file's only setting: an empty object is left.
                range = (j.skipSpace(0) + 1)..<root.close
            }
            removed += j.text(range.lowerBound, range.upperBound)
            text = j.text(0, range.lowerBound) + j.text(range.upperBound, j.bytes.count)
        }
        guard !removed.isEmpty else { return nil }
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) is [String: Any], !isInstalled(in: text) else {
            throw Failure.unexpectedShape(Failure.layout)
        }
        return (text, removed)
    }

    static func memberRange(_ members: [JSONText.Member], _ m: Int) -> Range<Int> {
        m > 0 ? members[m - 1].valueEnd..<members[m].valueEnd : members[0].keyStart..<members[1].keyStart
    }

    // MARK: Writing (only when the person says so)

    /// Writes the plan, only if the file still holds exactly what the plan was made from. Keeps the file's
    /// permissions; writes through a temporary file so a half-written settings file never exists.
    public func apply(_ plan: Plan) throws {
        let (now, exists) = read()
        guard now == plan.original, exists == plan.exists else { throw Failure.changedSinceShown }
        let folder = plan.file.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { throw Failure.noSettingsFolder }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: plan.file.path))?[.posixPermissions]
        try Data(plan.updated.utf8).write(to: plan.file, options: .atomic)
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: plan.file.path) }
    }

    // MARK: The log

    /// Transcript paths the hook logged, newest last, from the log's last `maxBytes`.
    public static func loggedTranscripts(log: URL, maxBytes: Int = 256 << 10) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        return JSONText(String(decoding: data, as: UTF8.self)).values().compactMap { ($0 as? [String: Any])?["transcript_path"] as? String }
    }
}
