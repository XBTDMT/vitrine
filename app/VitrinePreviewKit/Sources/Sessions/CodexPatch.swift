import Foundation

/// Codex's `apply_patch` text: the envelope its edit tool takes instead of old/new strings. roadmap: S-11
///
///     *** Begin Patch
///     *** Add File: path          then "+line" for every line
///     *** Update File: path       optionally "*** Move to: new/path", then "@@ context" chunks of " ", "-", "+"
///     *** Delete File: path
///     *** End of File             (inside a chunk: the change touches the file's end)
///     *** End Patch
///
/// Source: the format as Codex's own tool instructions describe it (openai/codex, `apply_patch` tool description),
/// recalled, not fetched in this session: unverified in detail, so the reader is tolerant. A line it does not
/// understand inside a chunk is kept as context; a patch with no `*** Begin Patch` yields nothing.
public enum CodexPatch {
    public struct FileChange: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case add, update, delete }
        public var kind: Kind
        public var path: String
        public var movedTo: String?
        /// For an added file: its lines.
        public var addedLines: [String]
        /// For an update: its chunks.
        public var chunks: [SessionEdit.PatchChunk]
    }

    public static func parse(_ text: String) -> [FileChange] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        guard let begin = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "*** Begin Patch" }) else { return [] }
        var out: [FileChange] = []
        var current: FileChange?
        var chunk: SessionEdit.PatchChunk?

        func closeChunk() {
            if let c = chunk, !c.lines.isEmpty || c.context != nil { current?.chunks.append(c) }
            chunk = nil
        }
        func closeFile() {
            closeChunk()
            if let c = current { out.append(c) }
            current = nil
        }

        for line in lines[(begin + 1)...] {
            if line.hasPrefix("*** ") {
                let rest = String(line.dropFirst(4))
                if rest.hasPrefix("End Patch") { break }
                if let p = value(rest, "Add File:") { closeFile(); current = FileChange(kind: .add, path: p, addedLines: [], chunks: []); continue }
                if let p = value(rest, "Update File:") { closeFile(); current = FileChange(kind: .update, path: p, addedLines: [], chunks: []); continue }
                if let p = value(rest, "Delete File:") { closeFile(); current = FileChange(kind: .delete, path: p, addedLines: [], chunks: []); continue }
                if let p = value(rest, "Move to:") { current?.movedTo = p; continue }
                if rest.hasPrefix("End of File") { continue }
            }
            guard current != nil else { continue }
            if current?.kind == .add {
                if line.hasPrefix("+") { current?.addedLines.append(String(line.dropFirst())) }
                continue
            }
            guard current?.kind == .update else { continue }
            if line.hasPrefix("@@") {
                closeChunk()
                let context = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                chunk = SessionEdit.PatchChunk(context: context.isEmpty ? nil : context, lines: [])
                continue
            }
            if chunk == nil { chunk = SessionEdit.PatchChunk(context: nil, lines: []) }
            if let first = line.first, first == "+" || first == "-" || first == " " {
                chunk?.lines.append((first, String(line.dropFirst())))
            } else {
                // A bare line: Codex treats it as context; so do we.
                chunk?.lines.append((" ", line))
            }
        }
        closeFile()
        return out
    }

    private static func value(_ rest: String, _ key: String) -> String? {
        guard rest.hasPrefix(key) else { return nil }
        let v = rest.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// The patch text inside a shell call: `["apply_patch", "<patch>"]`, or a bash script with an
    /// `apply_patch <<'EOF' … EOF` heredoc. nil when the command applies no patch.
    public static func patchText(inCommand command: [String]) -> String? {
        if let first = command.first, (first as NSString).lastPathComponent == "apply_patch" || first == "applypatch", command.count >= 2 {
            return command[1]
        }
        guard let script = command.last, script.contains("apply_patch"), let begin = script.range(of: "*** Begin Patch") else { return nil }
        let end = script.range(of: "*** End Patch", range: begin.upperBound..<script.endIndex)?.upperBound ?? script.endIndex
        return String(script[begin.lowerBound..<end])
    }
}
