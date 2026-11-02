import Foundation

/// Invented agent transcripts for the session tests (S-11). Every line is made here, in the record shapes
/// SessionParser documents; nothing is copied from a real session file. roadmap: S-11
enum SessionFixtures {
    static func line(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonl(_ objs: [[String: Any]]) -> String { objs.map(line).joined(separator: "\n") + "\n" }

    static let cwd = "/Users/example/tidepool"
    static let sessionID = "3f9c2a71-5b8e-4d0a-9c11-7e2d4b6a0f13"

    static func cc(_ type: String, _ time: String, _ message: [String: Any]? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = ["type": type, "timestamp": "2026-10-27T\(time).000Z", "sessionId": sessionID, "cwd": cwd,
                                "gitBranch": "fix/export-flake", "version": "2.0.0", "uuid": UUID().uuidString, "isSidechain": false]
        if let message { o["message"] = message }
        for (k, v) in extra { o[k] = v }
        return o
    }

    static func assistant(_ id: String, _ time: String, _ blocks: [[String: Any]], usage: Int? = nil, sidechain: Bool = false) -> [String: Any] {
        var message: [String: Any] = ["id": id, "role": "assistant", "model": "claude-sonnet-4-5-20250929", "content": blocks]
        if let usage { message["usage"] = ["input_tokens": 1200, "cache_read_input_tokens": usage - 1200 - 300, "cache_creation_input_tokens": 300, "output_tokens": 410] }
        return cc("assistant", time, message, extra: ["isSidechain": sidechain])
    }

    static func result(_ toolID: String, _ time: String, _ content: Any, error: Bool = false, structured: [String: Any]? = nil, sidechain: Bool = false) -> [String: Any] {
        var extra: [String: Any] = ["isSidechain": sidechain]
        if let structured { extra["toolUseResult"] = structured }
        return cc("user", time, ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolID, "content": content, "is_error": error]]], extra: extra)
    }

    static let csvOriginal = """
    export function exportOrdersCsv(
      orders: Order[],
      opts: ExportOptions = {}
    ): string {
      const rows = [...orders].sort((a, b) => a.createdAt - b.createdAt);
      const lines = [header(opts), ...rows.map(toLine)];
      return lines.join("\\n");
    }

    """

    /// The design's example session (ai.html state 1), invented: a prompt, thinking, Grep, Read, a failed Bash,
    /// two edits to one file (with its original recorded), a subagent, a new test file, a README edit with no recorded
    /// original, a secret in Bash output, a slash command and an unknown line kind.
    static func claudeCode() -> String {
        jsonl([
            ["type": "summary", "summary": "Fix flaky export test and add a CSV header option", "leafUuid": "leaf-1"],
            cc("user", "14:02:00", ["role": "user", "content": "The export test fails about one run in five on CI. Can you find out why and fix it?"]),
            assistant("msg_1", "14:02:09", [["type": "thinking", "thinking": "Probably an unstable sort.\nCheck createdAt."]]),
            assistant("msg_1", "14:03:00", [["type": "tool_use", "id": "t1", "name": "Grep", "input": ["pattern": "createdAt"]]]),
            result("t1", "14:03:01", "src/export/csv.ts\nsrc/report/summary.ts"),
            assistant("msg_2", "14:03:05", [["type": "tool_use", "id": "t2", "name": "Read", "input": ["file_path": "\(cwd)/src/export/csv.ts"]]]),
            result("t2", "14:03:06", "     1\texport function", structured: ["file": ["numLines": 148]]),
            assistant("msg_3", "14:05:00", [["type": "tool_use", "id": "t3", "name": "Bash", "input": ["command": "npm test -- csv.test.ts --repeat 20"]]]),
            result("t3", "14:05:30", "FAIL src/export/csv.test.ts\n4 of 20 runs failed", error: true),
            assistant("msg_4", "14:06:00", [["type": "text", "text": "The rows are sorted by `createdAt` only. I'll add **id** as a tie-breaker."]]),
            assistant("msg_5", "14:07:00", [["type": "tool_use", "id": "t4", "name": "Edit", "input": [
                "file_path": "\(cwd)/src/export/csv.ts",
                "old_string": "  const rows = [...orders].sort((a, b) => a.createdAt - b.createdAt);",
                "new_string": "  const rows = [...orders].sort(\n    (a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id)\n  );"]]]),
            result("t4", "14:07:01", "The file has been updated.", structured: ["filePath": "\(cwd)/src/export/csv.ts", "originalFile": csvOriginal]),
            assistant("msg_6", "14:08:00", [["type": "tool_use", "id": "t5", "name": "Task", "input": [
                "description": "Check the other sorts for the same tie problem", "prompt": "Look at every sort.", "subagent_type": "Explore"]]]),
            assistant("msg_s1", "14:08:10", [["type": "text", "text": "Looking."]], sidechain: true),
            result("t5", "14:10:00", [["type": "text", "text": "Two more sorts in src/report/summary.ts use createdAt only."]],
                   structured: ["totalToolUseCount": 6, "totalTokens": 11200]),
            assistant("msg_7", "14:11:00", [["type": "tool_use", "id": "t6", "name": "Edit", "input": [
                "file_path": "\(cwd)/src/export/csv.ts",
                "old_string": "  const lines = [header(opts), ...rows.map(toLine)];",
                "new_string": "  const lines = includeHeader\n    ? [header(opts), ...rows.map(toLine)]\n    : rows.map(toLine);"]]]),
            result("t6", "14:11:01", "The file has been updated."),
            assistant("msg_8", "14:15:00", [["type": "tool_use", "id": "t7", "name": "Write", "input": [
                "file_path": "\(cwd)/src/export/csv.test.ts", "content": "import { exportOrdersCsv } from './csv';\n\ntest('header', () => {});\n"]]]),
            result("t7", "14:15:01", "File created", structured: ["type": "create", "filePath": "\(cwd)/src/export/csv.test.ts"]),
            assistant("msg_9", "14:16:00", [["type": "tool_use", "id": "t8", "name": "Edit", "input": [
                "file_path": "\(cwd)/README.md", "old_string": "## Export options\n", "new_string": "## Export options\n\n- `includeHeader` (default true)\n"]]]),
            result("t8", "14:16:01", "The file has been updated."),
            assistant("msg_10", "14:17:00", [["type": "tool_use", "id": "t9", "name": "Edit", "input": [
                "file_path": "\(cwd)/package.json", "old_string": "\"version\": \"1.0.0\"", "new_string": "\"version\": \"1.1.0\""]]]),
            result("t9", "14:17:01", "String to replace not found in file.", error: true),
            assistant("msg_11", "14:18:00", [["type": "tool_use", "id": "t10", "name": "Bash", "input": ["command": "env | grep STRIPE"]]]),
            result("t10", "14:18:01", "STRIPE_KEY=sk_live_abcdefghijklmnop0000"),
            assistant("msg_12", "14:19:00", [["type": "text", "text": "Fixed: 50 of 50 runs pass now."]], usage: 148_000),
            cc("user", "14:36:00", ["role": "user", "content": "<command-name>/clear</command-name>\n<command-message>clear</command-message>"]),
            cc("user", "14:36:30", ["role": "user", "content": "Great. Update the README too."]),
            cc("x-telemetry", "14:37:00"),
            ["type": "file-history-snapshot", "messageId": "m"],
        ])
    }

    /// A Codex rollout in the current wrapped shape: meta, context, prompt, reasoning, a shell call with an exit
    /// code, an apply_patch that adds one file and updates another, and token counts.
    static func codex() -> String {
        let patch = """
        *** Begin Patch
        *** Add File: src/limits.ts
        +export const LIMIT = 100;
        *** Update File: src/rate.ts
        @@ function allow
        -  return count < 10;
        +  return count < LIMIT;
        *** End Patch
        """
        func w(_ type: String, _ time: String, _ payload: [String: Any]) -> [String: Any] {
            ["timestamp": "2026-10-28T\(time).000Z", "type": type, "payload": payload]
        }
        return jsonl([
            w("session_meta", "09:00:00", ["id": "0199-abc", "timestamp": "2026-10-28T09:00:00.000Z", "cwd": "/Users/example/harbor-api",
                                          "cli_version": "0.50.0", "git": ["branch": "main"]]),
            w("turn_context", "09:00:01", ["cwd": "/Users/example/harbor-api", "model": "gpt-5-codex"]),
            w("response_item", "09:00:02", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>cwd</environment_context>"]]]),
            w("response_item", "09:00:03", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fix the rate limiter"]]]),
            w("event_msg", "09:00:03", ["type": "user_message", "message": "Fix the rate limiter"]),
            w("response_item", "09:00:05", ["type": "reasoning", "summary": [["type": "summary_text", "text": "Look at rate.ts"]]]),
            w("response_item", "09:00:06", ["type": "function_call", "name": "shell", "call_id": "c1",
                                           "arguments": line(["command": ["bash", "-lc", "npm test"]])]),
            w("response_item", "09:00:09", ["type": "function_call_output", "call_id": "c1",
                                           "output": line(["output": "1 failing\n", "metadata": ["exit_code": 1]])]),
            w("response_item", "09:00:10", ["type": "custom_tool_call", "name": "apply_patch", "call_id": "c2", "input": patch]),
            w("response_item", "09:00:11", ["type": "custom_tool_call_output", "call_id": "c2", "output": "Success"]),
            w("response_item", "09:00:12", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Done: the limit is a constant now."]]]),
            w("event_msg", "09:00:12", ["type": "token_count", "info": ["last_token_usage": ["input_tokens": 52_000, "output_tokens": 900], "model_context_window": 272_000]]),
        ])
    }

    /// An ordinary JSON Lines file, not a session.
    static let plainJSONL = jsonl([["id": 1, "status": "ok"], ["id": 2, "status": "late"]])
}
