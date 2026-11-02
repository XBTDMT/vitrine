import Foundation

/// The parts of `.git/config` the card needs, read as text: section, optional subsection, key, value. Includes
/// (`[include]`) are not followed. Keys and section names compare case-insensitively, subsections exactly, as git
/// does; the last value wins. roadmap: S-9
struct GitConfig {
    private var values: [String: String] = [:]

    init(text: String) {
        var section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                guard let close = line.lastIndex(of: "]") else { continue }
                let inner = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                if let quote = inner.firstIndex(of: "\"") {
                    let name = inner[..<quote].trimmingCharacters(in: .whitespaces).lowercased()
                    let sub = inner[inner.index(after: quote)...].replacingOccurrences(of: "\"", with: "")
                    section = name + "\u{0}" + sub
                } else if let dot = inner.firstIndex(of: ".") {   // old form [section.sub]: subsection lowercased
                    section = inner[..<dot].lowercased() + "\u{0}" + inner[inner.index(after: dot)...].lowercased()
                } else {
                    section = inner.lowercased()
                }
                // A key may follow the header on the same line.
                line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
            }
            let key: String, value: String
            if let eq = line.firstIndex(of: "=") {
                key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                value = Self.unquote(line[line.index(after: eq)...])
            } else {
                key = line.lowercased(); value = "true"
            }
            values[section + "\u{1}" + key] = value
        }
    }

    /// Removes quotes and trailing comments outside quotes; keeps simple escapes.
    private static func unquote(_ raw: Substring) -> String {
        var out = "", quoted = false, escaped = false
        for c in raw.trimmingCharacters(in: .whitespaces) {
            if escaped { out.append(c == "n" ? "\n" : c == "t" ? "\t" : c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "\"" { quoted.toggle(); continue }
            if !quoted, c == "#" || c == ";" { break }
            out.append(c)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    func value(_ section: String, _ subsection: String? = nil, _ key: String) -> String? {
        let s = section.lowercased() + (subsection.map { "\u{0}" + $0 } ?? "")
        return values[s + "\u{1}" + key.lowercased()]
    }

    func bool(_ section: String, _ subsection: String? = nil, _ key: String) -> Bool? {
        guard let v = value(section, subsection, key)?.lowercased() else { return nil }
        if ["true", "yes", "on", "1"].contains(v) { return true }
        if ["false", "no", "off", "0", ""].contains(v) { return false }
        return nil
    }
}

/// Where HEAD points. roadmap: S-9
public enum GitHead: Sendable, Equatable {
    /// On a branch (`main`); the id is nil when the branch has no commits yet.
    case branch(String, GitObjectID?)
    case detached(GitObjectID)
    /// HEAD could not be read or names something this reader does not follow.
    case unknown

    public var branchName: String? { if case .branch(let n, _) = self { n } else { nil } }
    public var commitID: GitObjectID? {
        switch self {
        case .branch(_, let id): id
        case .detached(let id): id
        case .unknown: nil
        }
    }
}

/// Loose refs and `packed-refs`, read from the files. A linked worktree keeps its own HEAD in its git directory
/// and shares every other ref through the common directory. Symbolic refs are followed five deep at most, and a
/// ref name is checked before it becomes a path, so a hostile HEAD cannot point the reader outside `.git`.
/// roadmap: S-9
final class GitRefs {
    private let gitDir: URL
    private let commonDir: URL
    private let maxFileBytes: Int
    private var packedCache: [String: (id: GitObjectID, peeled: GitObjectID?)]?

    init(gitDir: URL, commonDir: URL, maxFileBytes: Int) {
        self.gitDir = gitDir; self.commonDir = commonDir; self.maxFileBytes = maxFileBytes
    }

    /// Every ref in `packed-refs`, with its peeled target when the file records one.
    var packed: [String: (id: GitObjectID, peeled: GitObjectID?)] {
        if let packedCache { return packedCache }
        var out: [String: (id: GitObjectID, peeled: GitObjectID?)] = [:]
        var last: String?
        if let text = SmallFile.text(commonDir.appendingPathComponent("packed-refs"), max: maxFileBytes) {
            for line in text.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("#") { continue }
                if line.hasPrefix("^") {
                    if let name = last, let peeled = GitObjectID(hex: line.dropFirst()) { out[name]?.peeled = peeled }
                    continue
                }
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let id = GitObjectID(hex: parts[0]) else { last = nil; continue }
                let name = String(parts[1])
                out[name] = (id, nil)
                last = name
            }
        }
        packedCache = out
        return out
    }

    static func isSafeName(_ name: String) -> Bool {
        guard name == "HEAD" || name.hasPrefix("refs/"), !name.hasSuffix("/"), name.utf8.count < 1024 else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == ".." || $0 == "." }
            && !name.contains("\u{0}") && !name.contains("\\")
    }

    /// HEAD, the per-worktree refs and pseudo-refs live in the git directory; everything else is shared.
    private func file(for name: String) -> URL {
        let perWorktree = name == "HEAD" || name.hasPrefix("refs/bisect/") || name.hasPrefix("refs/worktree/") || name.hasPrefix("refs/rewritten/")
        return (perWorktree ? gitDir : commonDir).appendingPathComponent(name)
    }

    /// What a ref's file says, without following anything.
    enum Target: Equatable { case id(GitObjectID), symbolic(String) }

    func target(_ name: String) -> Target? {
        guard Self.isSafeName(name) else { return nil }
        if let text = SmallFile.text(file(for: name), max: 4096) {
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("ref:") { return .symbolic(line.dropFirst(4).trimmingCharacters(in: .whitespaces)) }
            if let id = GitObjectID(hex: line.prefix(40)) { return .id(id) }
            return nil
        }
        return packed[name].map { .id($0.id) }
    }

    /// The commit (or other object) a ref finally names; nil when it does not exist yet or cannot be followed.
    func resolve(_ name: String) -> GitObjectID? {
        var current = name
        for _ in 0..<5 {
            switch target(current) {
            case .id(let id): return id
            case .symbolic(let next): current = next
            case nil: return nil
            }
        }
        return nil
    }

    func head() -> GitHead {
        switch target("HEAD") {
        case .id(let id): return .detached(id)
        case .symbolic(let ref):
            guard ref.hasPrefix("refs/heads/") else { return .unknown }
            return .branch(String(ref.dropFirst("refs/heads/".count)), resolve(ref))
        case nil: return .unknown
        }
    }

    /// Every tag (loose and packed, loose winning) with the object it names and, when known without reading an
    /// object, the commit it peels to. Bounded by `limit`.
    func tags(limit: Int) -> [(name: String, id: GitObjectID, peeled: GitObjectID?)] {
        var out: [String: (id: GitObjectID, peeled: GitObjectID?)] = [:]
        for (name, value) in packed where name.hasPrefix("refs/tags/") { out[name] = value }
        let root = commonDir.appendingPathComponent("refs/tags")
        var stack: [(URL, String)] = [(root, "refs/tags")]
        var visited = 0
        while let (dir, prefix) = stack.popLast(), visited < limit {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                visited += 1
                if visited > limit { break }
                let url = dir.appendingPathComponent(name), ref = prefix + "/" + name
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue { stack.append((url, ref)); continue }
                if case .id(let id) = target(ref) { out[ref] = (id, out[ref]?.id == id ? out[ref]?.peeled : nil) }
            }
        }
        return out.sorted { $0.key < $1.key }.prefix(limit).map { (String($0.key.dropFirst("refs/tags/".count)), $0.value.id, $0.value.peeled) }
    }
}
