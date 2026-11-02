import Foundation

// The agent-session model (parity H-5, B-9): what one Claude Code or Codex transcript says happened, read by
// SessionParser from the `.jsonl` file and drawn by SessionPage (the conversation), SessionChanges (the diffs) and
// the menu bar's Agent Sessions submenu (SessionLibrary). Foundation only, value types, no file access here.
// The record shapes it is read from are listed, with what is unverified, in SessionParser. roadmap: S-11

/// Which agent wrote the transcript.
public enum SessionSource: String, Sendable, Equatable, Codable, CaseIterable {
    case claudeCode
    case codex

    /// "Claude Code", "Codex": the menu's section headers and the header card's kind line.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The language id the document carries as its kind (`.code(language:)`), so the pill names the session.
    public var kindLanguage: String {
        switch self {
        case .claudeCode: "claude-code-session"
        case .codex: "codex-session"
        }
    }
}

/// One tool call the agent made, with what came back.
public struct SessionToolCall: Sendable, Equatable {
    public var id: String
    /// The tool's own name: Read, Edit, Bash, Task, shell, apply_patch, mcp__server__tool …
    public var name: String
    /// What the row shows after the name: a path relative to the project, a command's first line, a pattern.
    public var argument: String
    /// The result in a few words: "148 lines", "failed", "6 matches"; nil while no result was recorded.
    public var result: String?
    public var additions: Int?
    public var deletions: Int?
    public var isError: Bool
    /// The result's text, secrets masked and cut to `SessionLimits.outputBytes`; shown folded.
    public var output: String?
    /// Secrets masked in this call's input or output.
    public var maskedSecrets: Int
    public var time: Date?
    /// A subagent (Task / Agent tool): its type and description; nil for other tools.
    public var subagent: Subagent?

    public struct Subagent: Sendable, Equatable {
        public var type: String
        public var description: String
        /// Tool calls and tokens the subagent used, when the result records them.
        public var toolUses: Int?
        public var tokens: Int?
    }

    public init(id: String, name: String, argument: String, result: String? = nil, additions: Int? = nil, deletions: Int? = nil,
                isError: Bool = false, output: String? = nil, maskedSecrets: Int = 0, time: Date? = nil, subagent: Subagent? = nil) {
        self.id = id; self.name = name; self.argument = argument; self.result = result; self.additions = additions
        self.deletions = deletions; self.isError = isError; self.output = output; self.maskedSecrets = maskedSecrets
        self.time = time; self.subagent = subagent
    }
}

/// One row of the conversation rail, in file order.
public enum SessionItem: Sendable, Equatable {
    /// Something the person typed.
    case prompt(text: String, time: Date?)
    /// The agent's prose.
    case reply(text: String, time: Date?)
    /// The agent's thinking or reasoning summary; empty text when only its presence was recorded.
    case thinking(text: String, time: Date?)
    /// A tool call, by its index in `AgentSession.tools`.
    case tool(Int)
    /// A slash command the person ran ("/clear"), or a line the agent's program wrote itself.
    case note(text: String, time: Date?)
}

/// One change the agent made to a file through an edit tool, in the order it made them.
public struct SessionEdit: Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        /// Edit / MultiEdit: replace `old` with `new` (every occurrence when `all`).
        case replace(old: String, new: String, all: Bool)
        /// Write: the file's whole new text. `created` is true for a new file, false for an overwrite, nil when the
        /// transcript does not say.
        case write(content: String, created: Bool?)
        /// Codex apply_patch "Update File" chunks: each with its context line and its old and new lines.
        case chunks([PatchChunk])
        /// Codex apply_patch "Delete File".
        case delete
    }

    /// One `@@` chunk of a Codex patch; line numbers are not recorded in that format.
    public struct PatchChunk: Sendable, Equatable {
        public var context: String?
        /// Lines in order, each with " ", "-" or "+".
        public var lines: [(sign: Character, text: String)]
        public init(context: String?, lines: [(sign: Character, text: String)]) { self.context = context; self.lines = lines }
        public static func == (a: PatchChunk, b: PatchChunk) -> Bool {
            a.context == b.context && a.lines.count == b.lines.count && zip(a.lines, b.lines).allSatisfy { $0.sign == $1.sign && $0.text == $1.text }
        }
    }

    /// One hunk as Claude Code's tool result records it (`structuredPatch`), with real line numbers.
    public struct RecordedHunk: Sendable, Equatable {
        public var oldStart: Int, oldLines: Int, newStart: Int, newLines: Int
        /// Lines with their " ", "-" or "+" prefix, as recorded.
        public var lines: [String]
        public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [String]) {
            self.oldStart = oldStart; self.oldLines = oldLines; self.newStart = newStart; self.newLines = newLines; self.lines = lines
        }
    }

    /// The file as the agent named it (absolute for Claude Code, often relative for Codex).
    public var path: String
    /// Codex "Move to": the file's new name.
    public var movedTo: String?
    public var operation: Operation
    /// The file's text before this change, when the tool result recorded it (Claude Code `originalFile`).
    public var original: String?
    /// The change's hunks with line numbers, when the tool result recorded them.
    public var recordedHunks: [RecordedHunk]?
    /// The tool call that made it (`AgentSession.tools` index), and its time.
    public var tool: Int?
    public var time: Date?
    /// Made inside a subagent.
    public var bySubagent: Bool

    public init(path: String, movedTo: String? = nil, operation: Operation, original: String? = nil, recordedHunks: [RecordedHunk]? = nil,
                tool: Int? = nil, time: Date? = nil, bySubagent: Bool = false) {
        self.path = path; self.movedTo = movedTo; self.operation = operation; self.original = original
        self.recordedHunks = recordedHunks; self.tool = tool; self.time = time; self.bySubagent = bySubagent
    }
}

/// Token use at the last turn that recorded it.
public struct SessionContext: Sendable, Equatable {
    /// Tokens the model read at that turn (input + cache reads + cache writes).
    public var used: Int
    /// The window, when the transcript says it (Codex `model_context_window`); nil = not recorded.
    public var window: Int?
    public var output: Int?
}

/// Bounds on what one read takes from a transcript, so a 400 MB file never holds up a preview or the menu.
public struct SessionLimits: Sendable, Equatable {
    /// Bytes read from the start of the file.
    public var maxBytes: Int
    /// Rows of the rail kept for drawing; the counts still cover every record read.
    public var maxItems: Int
    /// Characters kept of one prompt, reply or thinking block.
    public var textChars: Int
    /// Characters kept of one tool result.
    public var outputChars: Int
    /// Characters of one edit's text kept for its diff (old, new or written content).
    public var editChars: Int

    public init(maxBytes: Int = 48 << 20, maxItems: Int = 1_500, textChars: Int = 24_000, outputChars: Int = 4_000, editChars: Int = 512_000) {
        self.maxBytes = maxBytes; self.maxItems = maxItems; self.textChars = textChars; self.outputChars = outputChars; self.editChars = editChars
    }

    /// The Quick Look preview and the Vitrine window.
    public static let preview = SessionLimits()
    /// The menu: titles, counts and touched files only, from the first 8 MB.
    public static let menu = SessionLimits(maxBytes: 8 << 20, maxItems: 0, textChars: 400, outputChars: 0, editChars: 64_000)
}

/// Everything read from one transcript.
public struct AgentSession: Sendable, Equatable {
    public var source: SessionSource
    public var id: String?
    /// The session's own title (a summary or custom-title record), else the first prompt's first line.
    public var title: String
    /// Where the agent ran.
    public var cwd: String?
    public var branch: String?
    public var model: String?
    public var version: String?
    public var started: Date?
    public var ended: Date?
    public var items: [SessionItem] = []
    public var tools: [SessionToolCall] = []
    public var edits: [SessionEdit] = []
    /// Prompts the person typed and replies the agent gave (an assistant message counts once, however many blocks).
    public var turns = 0
    public var prompts = 0
    public var context: SessionContext?
    /// Subagent records (Claude Code `isSidechain`) and Task calls.
    public var subagentTurns = 0
    /// Lines whose record type is unknown, by type: "2 line kinds Vitrine does not know yet were skipped".
    public var unknownKinds: [String: Int] = [:]
    /// Lines that are not JSON.
    public var unreadableLines = 0
    /// Bytes read and the file's size; lines read and, when read to the end, the total.
    public var bytesRead: Int64 = 0
    public var fileSize: Int64 = 0
    public var linesRead = 0
    /// The rail stopped at `SessionLimits.maxItems` rows; later rows are counted but not drawn.
    public var itemsCut = false
    public var maskedSecrets = 0

    public init(source: SessionSource, title: String = "") { self.source = source; self.title = title }

    public var isComplete: Bool { bytesRead >= fileSize }

    /// The project's folder name ("tidepool"), from the working directory.
    public var project: String? { cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } }

    /// Files the agent changed through edit tools, in the order first touched, with the final name of a moved file.
    public var changedFiles: [String] {
        var seen = Set<String>(), out: [String] = []
        for e in edits {
            let p = e.movedTo ?? e.path
            if seen.insert(p).inserted { out.append(p) }
        }
        return out
    }

    /// `path` relative to the working directory when it is inside it.
    public func relative(_ path: String) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// Wall time from the first to the last timestamp.
    public var duration: TimeInterval? {
        guard let started, let ended, ended >= started else { return nil }
        return ended.timeIntervalSince(started)
    }
}
