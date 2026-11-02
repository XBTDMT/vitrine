import Foundation
import VitrineGit
import VitrineText

/// The changed-line gutter (I-16, the code design's hero): which lines of a file differ from the last commit — added
/// (green), changed (blue), or removed after a line (a grey wedge). From the file's own repository read without git
/// (VitrineGit) and the histogram line diff. Quick Look's sandbox usually cannot read the folders above a previewed
/// file, so there it is empty; the Vitrine window shows it. roadmap: S-5
enum CodeChanges {
    struct Run: Encodable, Equatable { let from: Int; let to: Int; let kind: String }

    /// Lines above which no diff is tried (the gutter stays empty rather than slow the first paint).
    static let maxLines = 200_000

    static func runs(for url: URL, text: String) -> [Run] {
        guard let (repo, path) = GitRepository.containing(url), let head = repo.headFile(path) else { return [] }
        return runs(old: String(decoding: head, as: UTF8.self), new: text)
    }

    static func runs(old: String, new: String) -> [Run] {
        let a = lines(old), b = lines(new)
        guard a != b, a.count + b.count <= maxLines else { return [] }
        let ops = LineDiff.diff(a, b, budget: .init(timeLimit: .milliseconds(250))).ops
        var out: [Run] = []
        var i = 0
        while i < ops.count {
            let op = ops[i]
            switch op.kind {
            case .equal:
                i += 1
            case .delete:
                if i + 1 < ops.count, ops[i + 1].kind == .insert {
                    let ins = ops[i + 1]
                    out.append(Run(from: ins.new.lowerBound + 1, to: ins.new.upperBound, kind: "mod"))
                    i += 2
                } else {
                    let at = max(1, op.new.lowerBound)
                    out.append(Run(from: at, to: at, kind: "del"))
                    i += 1
                }
            case .insert:
                if i + 1 < ops.count, ops[i + 1].kind == .delete {
                    out.append(Run(from: op.new.lowerBound + 1, to: op.new.upperBound, kind: "mod"))
                    i += 2
                } else {
                    out.append(Run(from: op.new.lowerBound + 1, to: op.new.upperBound, kind: "add"))
                    i += 1
                }
            }
        }
        return out
    }

    private static func lines(_ s: String) -> [Substring] {
        var parts = s.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts.map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
    }
}
