import XCTest
@testable import VitrinePreviewKit
import VitrineText

/// Agent transcripts read into the session model (S-11, H-5): Claude Code and Codex shapes, failures that change
/// nothing, secrets masked, unknown kinds counted, bounds kept, and the diffs rebuilt from the edits (B-9).
/// Every transcript is invented (SessionFixtures). roadmap: S-11
final class SessionParserTests: XCTestCase {
    func data(_ s: String) -> Data { Data(s.utf8) }

    func testDetectsEachAgentAndNothingElse() {
        XCTAssertEqual(SessionParser.detect(data(SessionFixtures.claudeCode())), .claudeCode)
        XCTAssertEqual(SessionParser.detect(data(SessionFixtures.codex())), .codex)
        XCTAssertNil(SessionParser.detect(data(SessionFixtures.plainJSONL)))
        XCTAssertNil(SessionParser.detect(data("not json\nat all\n")))
        XCTAssertNil(SessionParser.parse(data: data(SessionFixtures.plainJSONL)))
    }

    func testClaudeCodeSession() throws {
        let s = try XCTUnwrap(SessionParser.parse(data: data(SessionFixtures.claudeCode())))
        XCTAssertEqual(s.source, .claudeCode)
        XCTAssertEqual(s.title, "Fix flaky export test and add a CSV header option")
        XCTAssertEqual(s.project, "tidepool")
        XCTAssertEqual(s.branch, "fix/export-flake")
        XCTAssertEqual(SessionParser.modelName(s.model ?? ""), "Claude Sonnet 4.5")
        XCTAssertEqual(s.prompts, 2)
        // 2 prompts + 12 distinct main-line assistant messages; the subagent's message is not a turn of its own.
        XCTAssertEqual(s.turns, 14)
        XCTAssertEqual(s.subagentTurns, 1)
        XCTAssertEqual(s.context?.used, 148_000)
        XCTAssertEqual(s.duration, 34 * 60 + 30 + 30)
        XCTAssertEqual(s.unknownKinds, ["x-telemetry": 1])

        let tools = s.tools
        XCTAssertEqual(tools.map(\.name), ["Grep", "Read", "Bash", "Edit", "Task", "Edit", "Write", "Edit", "Edit", "Bash"])
        XCTAssertEqual(tools[1].result, "148 lines")
        XCTAssertEqual(tools[1].argument, "src/export/csv.ts")
        XCTAssertNil(tools[1].output, "a Read's file contents are not kept")
        XCTAssertTrue(tools[2].isError)
        XCTAssertEqual(tools[2].result, "failed")
        XCTAssertEqual(tools[3].additions, 3); XCTAssertEqual(tools[3].deletions, 1)
        XCTAssertEqual(tools[4].subagent?.type, "Explore")
        XCTAssertEqual(tools[4].subagent?.toolUses, 6)
        XCTAssertEqual(tools[4].subagent?.tokens, 11_200)
        XCTAssertTrue(tools[8].isError, "the package.json edit failed")
        XCTAssertNil(tools[8].additions)

        // The secret in Bash output is masked, never kept.
        XCTAssertEqual(tools[9].maskedSecrets, 1)
        XCTAssertFalse(tools[9].output?.contains("abcdefghijklmnop") ?? true)
        XCTAssertEqual(s.maskedSecrets, 1)

        // Rail: the slash command is a note, the subagent's own reply is not on the main rail.
        XCTAssertTrue(s.items.contains(.note(text: "Ran /clear", time: SessionParser.date("2026-10-27T14:36:00.000Z"))))
        XCTAssertFalse(s.items.contains { if case .reply(let t, _) = $0 { t == "Looking." } else { false } })
        XCTAssertTrue(s.items.contains { if case .thinking(let t, _) = $0 { t.hasPrefix("Probably") } else { false } })

        // Failed edits leave the change list.
        XCTAssertEqual(s.changedFiles.map(s.relative), ["src/export/csv.ts", "src/export/csv.test.ts", "README.md"])
        XCTAssertEqual(s.edits.count, 4)
        XCTAssertNotNil(s.edits[0].original)
        XCTAssertEqual(s.edits[2].operation, .write(content: "import { exportOrdersCsv } from './csv';\n\ntest('header', () => {});\n", created: true))
    }

    func testCodexSession() throws {
        let s = try XCTUnwrap(SessionParser.parse(data: data(SessionFixtures.codex())))
        XCTAssertEqual(s.source, .codex)
        XCTAssertEqual(s.title, "Fix the rate limiter")
        XCTAssertEqual(s.project, "harbor-api")
        XCTAssertEqual(s.branch, "main")
        XCTAssertEqual(s.model, "gpt-5-codex")
        XCTAssertEqual(s.prompts, 1, "the environment context and the duplicate event message are not prompts")
        XCTAssertEqual(s.turns, 2)
        XCTAssertEqual(s.context, SessionContext(used: 52_000, window: 272_000, output: 900))
        XCTAssertEqual(s.tools.map(\.name), ["Shell", "apply_patch"])
        XCTAssertEqual(s.tools[0].argument, "npm test")
        XCTAssertEqual(s.tools[0].result, "exit 1 · 1 line")
        XCTAssertTrue(s.tools[0].isError)
        XCTAssertEqual(s.tools[1].argument, "src/limits.ts, src/rate.ts")
        XCTAssertEqual(s.tools[1].additions, 2); XCTAssertEqual(s.tools[1].deletions, 1)
        XCTAssertEqual(s.changedFiles, ["/Users/example/harbor-api/src/limits.ts", "/Users/example/harbor-api/src/rate.ts"])
    }

    func testOlderCodexShape() throws {
        let text = SessionFixtures.jsonl([
            ["id": "old-1", "timestamp": "2025-05-01T10:00:00.000Z", "instructions": "", "git": ["branch": "dev"]],
            ["record_type": "state"],
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Add a README"]]],
            ["type": "function_call", "name": "shell", "call_id": "c1", "arguments": SessionFixtures.line(["command": ["apply_patch", "*** Begin Patch\n*** Add File: README.md\n+# Hi\n*** End Patch"]])],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Added."]]],
        ])
        let s = try XCTUnwrap(SessionParser.parse(data: data(text)))
        XCTAssertEqual(s.source, .codex)
        XCTAssertEqual(s.title, "Add a README")
        XCTAssertEqual(s.branch, "dev")
        XCTAssertEqual(s.edits.count, 1)
        XCTAssertEqual(s.unknownKinds, [:])
    }

    func testCodexPatchFormat() {
        let changes = CodexPatch.parse("""
        *** Begin Patch
        *** Update File: a.txt
        *** Move to: b.txt
        @@ section
         keep
        -old
        +new
        *** End of File
        *** Delete File: gone.txt
        *** End Patch
        """)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].movedTo, "b.txt")
        XCTAssertEqual(changes[0].chunks.first?.context, "section")
        XCTAssertEqual(changes[0].chunks.first?.lines.map { String($0.sign) + $0.text }, [" keep", "-old", "+new"])
        XCTAssertEqual(changes[1].kind, .delete)
        XCTAssertEqual(CodexPatch.patchText(inCommand: ["bash", "-lc", "apply_patch <<'EOF'\n*** Begin Patch\n*** End Patch\nEOF"]), "*** Begin Patch\n*** End Patch")
        XCTAssertNil(CodexPatch.patchText(inCommand: ["bash", "-lc", "ls"]))
    }

    func testToleratesBrokenLinesAndMissingFields() throws {
        let text = SessionFixtures.jsonl([["type": "user", "message": ["role": "user", "content": "hi"], "sessionId": "x"]])
            + "{not json\n" + SessionFixtures.jsonl([["type": "assistant", "sessionId": "x"], ["type": "assistant", "message": ["content": 5], "sessionId": "x"]])
        let s = try XCTUnwrap(SessionParser.parse(data: data(text)))
        XCTAssertEqual(s.unreadableLines, 1)
        XCTAssertEqual(s.title, "hi")
        XCTAssertEqual(s.prompts, 1)
    }

    func testBoundsCutTheReadAndTheRail() throws {
        let prompts = (0..<50).map { i in SessionFixtures.cc("user", "10:00:\(String(format: "%02d", i % 60))", ["role": "user", "content": "prompt \(i) " + String(repeating: "x", count: 200)]) }
        let text = SessionFixtures.jsonl(prompts)
        let limits = SessionLimits(maxBytes: 4_000, maxItems: 5)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vt-session-\(UUID().uuidString).jsonl")
        try data(text).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try XCTUnwrap(SessionParser.parse(url: url, limits: limits))
        XCTAssertFalse(s.isComplete)
        XCTAssertLessThanOrEqual(s.bytesRead, 4_000)
        XCTAssertEqual(s.items.count, 5)
        XCTAssertTrue(s.itemsCut)
        XCTAssertGreaterThan(s.prompts, 5, "the counts cover every line read, past the drawn rows")
        XCTAssertEqual(s.unreadableLines, 0, "the line the cut fell inside is dropped, not counted as broken")
    }

    func testProseMasksOnlyCredentialForms() {
        XCTAssertEqual(SessionSecrets.maskProse("Token: the auth flow is fine").1, 0)
        let (masked, n) = SessionSecrets.maskProse("use ghp_abcdefghijklmnopqrstuvwxyz0123 here")
        XCTAssertEqual(n, 1)
        XCTAssertFalse(masked.contains("abcdefghijklmnopqrstuvwxyz"))
    }

    // MARK: Changes (B-9)

    func testChangesRebuildNetDiffsWithLineNumbers() throws {
        let s = try XCTUnwrap(SessionParser.parse(data: data(SessionFixtures.claudeCode())))
        let files = SessionChanges.files(s)
        XCTAssertEqual(files.map(\.path), ["src/export/csv.ts", "src/export/csv.test.ts", "README.md"])
        XCTAssertEqual(files.map(\.kind), [.modified, .added, .modified])
        // Two edits replayed on the recorded original: one net change with real line numbers.
        XCTAssertTrue(files[0].lineNumbersKnown)
        XCTAssertEqual(files[0].edits, 2)
        XCTAssertEqual(files[0].additions, 6); XCTAssertEqual(files[0].deletions, 2)
        XCTAssertEqual(files[0].hunks.first?.oldStart, 2)
        XCTAssertEqual(files[1].additions, 3)
        // No original recorded: its own hunk, said to have no line numbers.
        XCTAssertFalse(files[2].lineNumbersKnown)
        XCTAssertEqual(files[2].hunks.first?.section, SessionChanges.unknownLines)
        XCTAssertEqual(files[2].additions, 2); XCTAssertEqual(files[2].deletions, 0)

        // The patch reads back through the diff engine as the same three files and counts.
        let patch = PatchParser.parse(SessionChanges.patch(s, mail: true))
        XCTAssertEqual(patch.files.map(\.path), ["src/export/csv.ts", "src/export/csv.test.ts", "README.md"])
        XCTAssertEqual(patch.totals.additions, 11)
        XCTAssertEqual(patch.totals.deletions, 2)
        XCTAssertTrue(patch.files[1].isNewFile)
        XCTAssertEqual(DiffSummary(patch: patch).subject, "Fix flaky export test and add a CSV header option")
        XCTAssertFalse(patch.issues.contains { $0.severity == .error }, "\(patch.issues)")
    }

    func testCodexChangesFromChunks() throws {
        let s = try XCTUnwrap(SessionParser.parse(data: data(SessionFixtures.codex())))
        let files = SessionChanges.files(s)
        XCTAssertEqual(files.map(\.path), ["src/limits.ts", "src/rate.ts"])
        XCTAssertEqual(files[0].kind, .added)
        XCTAssertFalse(files[1].lineNumbersKnown)
        XCTAssertEqual(files[1].hunks.first?.section, "function allow · \(SessionChanges.unknownLines)")
        let patch = PatchParser.parse(SessionChanges.patch(s))
        XCTAssertEqual(patch.totals.additions, 2)
        XCTAssertEqual(patch.totals.deletions, 1)
        XCTAssertFalse(patch.issues.contains { $0.severity == .error }, "\(patch.issues)")
    }

    func testRecordedHunksAreUsedWhenNoOriginal() {
        var s = AgentSession(source: .claudeCode, title: "t")
        s.cwd = "/p"
        s.edits = [SessionEdit(path: "/p/a.swift", operation: .replace(old: "x", new: "y", all: false),
                               recordedHunks: [.init(oldStart: 40, oldLines: 3, newStart: 40, newLines: 3, lines: [" a", "-x", "+y", " b"])])]
        let f = SessionChanges.files(s)[0]
        XCTAssertTrue(f.lineNumbersKnown)
        XCTAssertEqual(f.hunks.first?.oldStart, 40)
        XCTAssertEqual(PatchParser.parse(SessionChanges.patch(s)).files.first?.hunks.first?.oldStart, 40)
    }

    func testReplayStopsWhenAnEditCannotBePlaced() {
        XCTAssertNil(SessionChanges.replay("abc", [SessionEdit(path: "f", operation: .replace(old: "zzz", new: "y", all: false))]))
        XCTAssertEqual(SessionChanges.replay("a a", [SessionEdit(path: "f", operation: .replace(old: "a", new: "b", all: true))]), "b b")
        XCTAssertEqual(SessionChanges.apply([SessionEdit.PatchChunk(context: nil, lines: [(" ", "1"), ("-", "2"), ("+", "two")])], to: "0\n1\n2\n3"), "0\n1\ntwo\n3")
    }
}

/// The session as plain text (X-9): what find, copying, token counts and the Claude connector read. roadmap: S-11
final class SessionTextTests: XCTestCase {
    func testTheTranscriptReadsInOrderWithToolsAndNoSecrets() throws {
        let s = try XCTUnwrap(SessionParser.parse(data: Data(SessionFixtures.claudeCode().utf8)))
        let text = SessionText.transcript(s)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Fix flaky export test and add a CSV header option")
        XCTAssertTrue(lines[1].hasPrefix("Claude Code · tidepool · fix/export-flake"), lines[1])
        let you = try XCTUnwrap(lines.firstIndex(of: "You:")), claude = try XCTUnwrap(lines.firstIndex(of: "Claude:"))
        XCTAssertLessThan(you, claude, "the first prompt comes before the first reply")
        XCTAssertEqual(lines.filter { $0 == "You:" }.count, s.prompts)
        XCTAssertTrue(lines.contains { $0.hasPrefix("→ ") }, "tool calls are listed")
        if s.maskedSecrets > 0 { XCTAssertTrue(text.contains("•"), "masked values stay masked") }
    }

    @MainActor
    func testTheConversationViewCarriesTheTranscript() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try Data(SessionFixtures.claudeCode().utf8).write(to: url)
        let rendered = try await SessionRenderer().render(url: url, kind: .plainText, context: RenderContext(appearance: .light))
        XCTAssertTrue(rendered.document.searchText.hasPrefix("Fix flaky export test"), String(rendered.document.searchText.prefix(80)))
    }
}
