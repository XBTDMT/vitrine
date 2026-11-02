import Foundation

/// A session as plain text: the Conversation view's words for find, copying, token counts and the Claude connector
/// (X-9), in reading order. The parser has already masked secrets and cut long texts (SessionLimits), so nothing here
/// shows more than the conversation page does. roadmap: S-11
enum SessionText {
    static func transcript(_ s: AgentSession) -> String {
        var out: [String] = [s.title]
        let facts = [s.source.displayName, s.project, s.branch, s.model].compactMap { $0 }.filter { !$0.isEmpty }
        out.append(facts.joined(separator: " · "))
        let assistant = s.source == .claudeCode ? "Claude" : "Codex"
        for item in s.items {
            out.append("")
            switch item {
            case .prompt(let text, _):
                out.append(String(localized: "You", bundle: .previewKit, comment: "Session as text: label before the person's prompt.") + ":")
                out.append(text)
            case .reply(let text, _):
                out.append(assistant + ":")
                out.append(text)
            case .thinking(let text, _):
                out.append(String(localized: "Thinking", bundle: .previewKit, comment: "Session as text: label before the model's visible reasoning.") + ":")
                out.append(text)
            case .note(let text, _):
                out.append("· " + text)
            case .tool(let index):
                guard s.tools.indices.contains(index) else { continue }
                out.append(contentsOf: tool(s.tools[index]))
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func tool(_ t: SessionToolCall) -> [String] {
        var head = "→ \(t.name)"
        if let sub = t.subagent { head += " (\(sub.type)): \(sub.description)" } else if !t.argument.isEmpty { head += ": \(t.argument)" }
        if let a = t.additions, let d = t.deletions { head += " +\(a) −\(d)" }
        var lines = [head]
        if let result = t.result, !result.isEmpty { lines.append("  ← " + (t.isError ? "✕ " : "") + result) }
        if let output = t.output, !output.isEmpty {
            lines.append(contentsOf: output.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 })
        }
        return lines
    }
}
