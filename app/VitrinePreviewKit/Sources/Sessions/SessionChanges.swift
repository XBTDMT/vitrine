import Foundation
import VitrineText

/// What the agent changed (parity B-9; design ai.html state 3, "Diffs rebuilt from the session's Edit and Write
/// calls"): every file the session's edit tools touched, as one unified patch the diff page (DiffRenderer) draws.
///
/// Per file, the net change when the file's text before the first edit is known (a new file, or Claude Code's
/// recorded `originalFile`): every edit is replayed on that text in order and the result compared with it, so the
/// hunks carry real line numbers and several edits read as one change. Otherwise each edit is its own hunk: the
/// tool result's own hunks when it recorded them (`structuredPatch`, real line numbers), else the edit's old and
/// new text compared, numbered from 1 and labelled "line numbers not recorded". A file changed by a shell command is
/// not in the transcript as an edit and is not guessed. roadmap: S-11
public enum SessionChanges {
    public struct File: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable { case added, modified, deleted, renamed }
        /// As the patch names it: relative to the session's folder when inside it.
        public var path: String
        public var absolutePath: String
        public var kind: Kind
        public var edits: Int
        public var additions: Int
        public var deletions: Int
        /// The hunks carry the file's real line numbers.
        public var lineNumbersKnown: Bool
        /// The hunks, ready to print.
        public var hunks: [Hunk]
        public var bySubagent: Bool
    }

    public struct Hunk: Sendable, Equatable {
        public var oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        public var section: String?
        /// Lines with their " ", "-" or "+".
        public var lines: [String]

        var text: String {
            func range(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
            let head = "@@ -\(range(oldStart, oldCount)) +\(range(newStart, newCount)) @@" + (section.map { " " + $0 } ?? "")
            return ([head] + lines).joined(separator: "\n") + "\n"
        }
    }

    public static let unknownLines = String(localized: "line numbers not recorded", bundle: .previewKit, comment: "Diff hunk note in a session's changes: the transcript does not record where in the file the edit was.")

    /// Every changed file, in the order the session first touched it.
    public static func files(_ session: AgentSession) -> [File] {
        var order: [String] = []
        var groups: [String: [SessionEdit]] = [:]
        for edit in session.edits {
            if groups[edit.path] == nil { order.append(edit.path) }
            groups[edit.path, default: []].append(edit)
        }
        return order.compactMap { path in groups[path].map { file(path: path, edits: $0, session: session) } }
    }

    /// The whole change as a unified patch. With `mail`, it opens with a format-patch header (the session's title as
    /// the subject, the agent as the author, the last edit's time as the date), so the diff page's lead names the
    /// session.
    public static func patch(_ session: AgentSession, mail: Bool = false) -> String {
        let body = files(session).map(patchText).joined()
        guard mail else { return body }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let date = session.edits.compactMap(\.time).last ?? session.ended ?? Date(timeIntervalSince1970: 0)
        let subject = session.title.replacingOccurrences(of: "\n", with: " ")
        return """
        From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
        From: \(session.source.displayName) <agent@session.invalid>
        Date: \(f.string(from: date))
        Subject: [PATCH] \(subject)

        Rebuilt from the session's edit calls. A file changed by a shell command is not in the transcript as an edit and is not listed.
        ---

        """ + body
    }

    static func patchText(_ f: File) -> String {
        var out = "diff --git a/\(f.path) b/\(f.path)\n"
        switch f.kind {
        case .added: out += "new file mode 100644\n--- /dev/null\n+++ b/\(f.path)\n"
        case .deleted: out += "deleted file mode 100644\n--- a/\(f.path)\n+++ /dev/null\n"
        case .renamed, .modified: out += "--- a/\(f.path)\n+++ b/\(f.path)\n"
        }
        return out + f.hunks.map(\.text).joined()
    }

    // MARK: One file

    static func file(path: String, edits: [SessionEdit], session: AgentSession) -> File {
        let finalPath = edits.last(where: { $0.movedTo != nil })?.movedTo ?? path
        var kind: File.Kind = finalPath != path ? .renamed : .modified
        if case .write(_, let created) = edits[0].operation, created == true { kind = .added }
        if case .delete = edits.last?.operation { kind = .deleted }
        var result = File(path: session.relative(finalPath), absolutePath: finalPath, kind: kind, edits: edits.count, additions: 0, deletions: 0,
                          lineNumbersKnown: false, hunks: [], bySubagent: edits.allSatisfy(\.bySubagent))
        if kind == .deleted { return result }

        let base: String? = kind == .added ? "" : edits[0].original
        if let base, let final = replay(base, edits) {
            let compared = TextCompare.compare(old: base, new: final)
            result.hunks = compared.file.hunks.map { h in
                Hunk(oldStart: h.oldStart, oldCount: h.oldCount, newStart: h.newStart, newCount: h.newCount, section: h.section,
                     lines: h.lines.map { ($0.kind == .added ? "+" : $0.kind == .deleted ? "-" : " ") + $0.text })
            }
            result.lineNumbersKnown = true
        } else if edits.allSatisfy({ $0.recordedHunks != nil }) {
            result.hunks = edits.flatMap { e in
                e.recordedHunks!.map { Hunk(oldStart: $0.oldStart, oldCount: $0.oldLines, newStart: $0.newStart, newCount: $0.newLines, section: nil, lines: $0.lines) }
            }
            result.lineNumbersKnown = true
        } else {
            result.hunks = synthesized(edits)
        }
        for h in result.hunks {
            for l in h.lines { if l.hasPrefix("+") { result.additions += 1 } else if l.hasPrefix("-") { result.deletions += 1 } }
        }
        return result
    }

    /// Applies every edit in order to `base`; nil when one cannot be placed (its old text is not there).
    static func replay(_ base: String, _ edits: [SessionEdit]) -> String? {
        var text = base
        for e in edits {
            switch e.operation {
            case .replace(let old, let new, let all):
                guard !old.isEmpty, text.contains(old) else { return nil }
                text = all ? text.replacingOccurrences(of: old, with: new) : text.replacingFirst(old, with: new)
            case .write(let content, _):
                text = content
            case .chunks(let chunks):
                guard let applied = apply(chunks, to: text) else { return nil }
                text = applied
            case .delete:
                return nil
            }
        }
        return text
    }

    /// Codex chunks placed by their old lines, searched forward from the previous chunk.
    static func apply(_ chunks: [SessionEdit.PatchChunk], to text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        var from = 0
        for chunk in chunks {
            let old = chunk.lines.filter { $0.sign != "+" }.map(\.text)
            let new = chunk.lines.filter { $0.sign != "-" }.map(\.text)
            guard !old.isEmpty else { return nil }
            guard let at = (from...max(from, lines.count - old.count)).first(where: { i in
                i + old.count <= lines.count && Array(lines[i..<(i + old.count)]) == old
            }) else { return nil }
            lines.replaceSubrange(at..<(at + old.count), with: new)
            from = at + new.count
        }
        return lines.joined(separator: "\n")
    }

    /// One hunk per edit, numbered from 1 one after another, each said to have no recorded line numbers.
    static func synthesized(_ edits: [SessionEdit]) -> [Hunk] {
        var hunks: [Hunk] = []
        var next = 1
        for (i, e) in edits.enumerated() {
            let number = (i + 1).formatted(), total = edits.count.formatted(), unknown = unknownLines
            let label = edits.count > 1
                ? String(localized: "edit \(number) of \(total) · \(unknown)", bundle: .previewKit, comment: "Diff hunk note: which edit this is, then that its line numbers were not recorded.")
                : unknownLines
            var lines: [String] = []
            switch e.operation {
            case .replace(let old, let new, _):
                if let recorded = e.recordedHunks { lines = recorded.flatMap(\.lines); break }
                let c = TextCompare.compare(old: old, new: new, options: CompareOptions(contextLines: nil))
                lines = c.file.hunks.flatMap { $0.lines.map { ($0.kind == .added ? "+" : $0.kind == .deleted ? "-" : " ") + $0.text } }
                if lines.isEmpty, !new.isEmpty { lines = new.components(separatedBy: "\n").map { "+" + $0 } }
            case .write(let content, let created):
                lines = content.split(separator: "\n", omittingEmptySubsequences: false).dropLast(content.hasSuffix("\n") ? 1 : 0).map { "+" + $0 }
                if created != true {
                    hunks.append(Hunk(oldStart: 0, oldCount: 0, newStart: next, newCount: lines.count,
                                      section: String(localized: "whole file written · its earlier text is not recorded", bundle: .previewKit, comment: "Diff hunk note: the session wrote the whole file and its earlier text is unknown."),
                                      lines: lines))
                    next += lines.count + 1
                    continue
                }
            case .chunks(let chunks):
                for (j, chunk) in chunks.enumerated() {
                    let ls = chunk.lines.map { String($0.sign) + $0.text }
                    let oldCount = ls.filter { !$0.hasPrefix("+") }.count, newCount = ls.filter { !$0.hasPrefix("-") }.count
                    let number = (j + 1).formatted(), total = chunks.count.formatted()
                    let chunkLabel: String? = chunks.count > 1
                        ? String(localized: "chunk \(number) of \(total)", bundle: .previewKit, comment: "Diff hunk note: which chunk of a patch this is.")
                        : nil
                    let section = [chunk.context, chunkLabel, unknownLines].compactMap { $0 }.joined(separator: " · ")
                    hunks.append(Hunk(oldStart: oldCount == 0 ? 0 : next, oldCount: oldCount, newStart: newCount == 0 ? 0 : next, newCount: newCount,
                                      section: section, lines: ls))
                    next += max(oldCount, newCount) + 1
                }
                continue
            case .delete:
                continue
            }
            let oldCount = lines.filter { !$0.hasPrefix("+") }.count, newCount = lines.filter { !$0.hasPrefix("-") }.count
            guard !lines.isEmpty else { continue }
            hunks.append(Hunk(oldStart: oldCount == 0 ? 0 : next, oldCount: oldCount, newStart: newCount == 0 ? 0 : next, newCount: newCount,
                              section: label, lines: lines))
            next += max(oldCount, newCount) + 1
        }
        return hunks
    }
}

private extension String {
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let r = range(of: target) else { return self }
        return replacingCharacters(in: r, with: replacement)
    }
}
