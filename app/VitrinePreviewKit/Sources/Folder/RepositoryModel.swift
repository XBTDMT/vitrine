import Foundation
import VitrineDocument
import VitrineGit
import VitrineText

/// What the repository card draws: the reader's summary plus the line counts of the first few changes, all read
/// off the main thread. roadmap: S-9
struct RepositoryRead: Sendable {
    let summary: GitSummary
    /// Change path → "+14 −3", "+62", "−8" or "new", for the rows the card shows.
    let lineStats: [String: String]
    /// The README as blocks, parsed once here so the main thread only draws.
    let readme: [MarkdownBlock]?
    /// The tracked bytes by language for the path row's hairline (the repository's language bar, in the series
    /// colours), largest first; empty when the index could not be read or holds no known language.
    var languages: [RepositoryLanguage] = []

    /// The rows the card lists before "and N more".
    static let listedChanges = 5

    /// Reads the repository. `parts` empty = the quick read for the first paint (HEAD, recent commits, tag,
    /// index counts, README); `.all` adds the status, history counts and line counts.
    static func read(_ repo: GitRepository, parts: GitRepository.Parts) -> RepositoryRead {
        let summary = repo.summary(parts)
        var stats: [String: String] = [:]
        if let status = summary.status, let workTree = repo.location.workTree {
            for change in status.changes.prefix(listedChanges) {
                stats[change.path] = lineStat(change, repo: repo, workTree: workTree)
            }
        }
        var blocks: [MarkdownBlock]?
        if let readme = summary.readme {
            blocks = readme.isMarkdown ? MarkdownBlocks.parse(readme.text, maxBlocks: 120) : [.code(language: nil, text: readme.text)]
        }
        var read = RepositoryRead(summary: summary, lineStats: stats, readme: blocks)
        read.languages = RepositoryLanguage.breakdown(repo)
        return read
    }

    /// Lines added and removed against HEAD (`git diff HEAD --stat` for one path), bounded: binary or large files
    /// get no count.
    static func lineStat(_ change: GitChange, repo: GitRepository, workTree: URL) -> String? {
        if change.kind == .untracked {
            return String(localized: "new", bundle: .previewKit, comment: "Repository card: a new, untracked file (in place of its line counts).")
        }
        let maxBytes = 512 << 10
        func lines(_ bytes: [UInt8]?) -> [Substring]? {
            guard let bytes, bytes.count <= maxBytes, !bytes.prefix(8000).contains(0) else { return nil }
            let text = String(decoding: bytes, as: UTF8.self)
            if text.isEmpty { return [] }
            var out = text.split(separator: "\n", omittingEmptySubsequences: false)
            if text.hasSuffix("\n") { out.removeLast() }
            return out
        }
        // The base is HEAD's blob; a path changed only in the work tree has no HEAD id in the change, but its index
        // blob is HEAD's then. A new path starts from nothing.
        let oldBytes: [UInt8]?
        if let head = change.headID { oldBytes = repo.blob(head) }
        else if change.kind == .added { oldBytes = [] }
        else if let index = change.indexID { oldBytes = repo.blob(index) }
        else { oldBytes = nil }
        let newBytes: [UInt8]?
        let file = workTree.appendingPathComponent(change.path)
        if change.kind == .deleted && !FileManager.default.fileExists(atPath: file.path) { newBytes = [] }
        else if change.unstaged || change.kind == .added, let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= maxBytes {
            newBytes = [UInt8](data)
        } else if let id = change.indexID { newBytes = repo.blob(id) }
        else { newBytes = nil }
        guard let old = lines(oldBytes), let new = lines(newBytes) else { return nil }
        let diff = LineDiff.diff(old, new, budget: LineDiff.Budget(timeLimit: .milliseconds(150), maxElements: 200_000))
        let add = diff.additions, del = diff.deletions
        if add == 0 && del == 0 { return nil }
        if del == 0 { return "+\(add.formatted())" }
        if add == 0 { return "−\(del.formatted())" }
        return "+\(add.formatted()) −\(del.formatted())"
    }
}

/// One language's share of a repository's tracked bytes, read from the index's file sizes (no file is opened).
/// The top three keep a series colour each; the rest share `kind-other` as "Other". roadmap: S-9
struct RepositoryLanguage: Sendable, Equatable {
    let name: String
    let share: Double
    let token: String

    static let names: [String: String] = [
        "swift": "Swift", "m": "Objective-C", "mm": "Objective-C++", "c": "C", "h": "C", "cc": "C++", "cpp": "C++", "hpp": "C++",
        "cs": "C#", "go": "Go", "rs": "Rust", "java": "Java", "kt": "Kotlin", "kts": "Kotlin", "scala": "Scala", "py": "Python",
        "rb": "Ruby", "php": "PHP", "js": "JavaScript", "mjs": "JavaScript", "cjs": "JavaScript", "jsx": "JavaScript",
        "ts": "TypeScript", "tsx": "TypeScript", "astro": "Astro", "vue": "Vue", "svelte": "Svelte", "html": "HTML", "htm": "HTML",
        "css": "CSS", "scss": "SCSS", "sass": "Sass", "less": "Less", "md": "Markdown", "markdown": "Markdown", "sh": "Shell",
        "bash": "Shell", "zsh": "Shell", "lua": "Lua", "dart": "Dart", "ex": "Elixir", "exs": "Elixir", "erl": "Erlang",
        "hs": "Haskell", "ml": "OCaml", "zig": "Zig", "sql": "SQL", "r": "R", "jl": "Julia", "pl": "Perl", "nix": "Nix",
        "tf": "HCL", "proto": "Protocol Buffers", "ipynb": "Jupyter Notebook", "json": "JSON", "yml": "YAML", "yaml": "YAML",
        "toml": "TOML", "xml": "XML",
    ]

    /// Shares of bytes by language from the index (bounded by the reader's own index limits).
    static func breakdown(_ repo: GitRepository) -> [RepositoryLanguage] {
        let url = repo.location.gitDir.appendingPathComponent("index")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size <= repo.limits.maxIndexBytes, let data = try? Data(contentsOf: url),
              let index = try? GitIndex.parse([UInt8](data), maxEntries: repo.limits.maxIndexEntries) else { return [] }
        var bytes: [String: Int64] = [:]
        for e in index.entries where e.stage == 0 && !e.isGitlink && !e.isSymlink {
            let ext = (e.path as NSString).pathExtension.lowercased()
            guard let name = names[ext] else { continue }
            bytes[name, default: 0] += Int64(e.size)
        }
        return shares(bytes)
    }

    static func shares(_ bytes: [String: Int64]) -> [RepositoryLanguage] {
        let total = Double(bytes.values.reduce(0, +))
        guard total > 0 else { return [] }
        let ranked = bytes.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var out = ranked.prefix(3).enumerated().map { i, kv in
            RepositoryLanguage(name: kv.key, share: Double(kv.value) / total, token: "series-\(i + 1)")
        }
        let rest = ranked.dropFirst(3).reduce(Int64(0)) { $0 + $1.value }
        if rest > 0 {
            out.append(RepositoryLanguage(name: String(localized: "Other", bundle: .previewKit, comment: "Repository language bar: every language past the top three."), share: Double(rest) / total, token: "kind-other"))
        }
        return out
    }
}

/// The words the card, the pill and the facts use. roadmap: S-9
enum GitText {
    /// "2 hours ago", "yesterday", "last week".
    static func relative(_ date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        formatter(locale).localizedString(for: date, relativeTo: now)
    }

    private static func formatter(_ locale: Locale) -> RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.dateTimeStyle = .named
        f.unitsStyle = .full
        return f
    }

    /// "Ada Example" → "AE"; one word → its first letter; nothing → "?".
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return "?" }
        let last = words.count > 1 ? words.last?.first : nil
        return (String(first) + (last.map(String.init) ?? "")).uppercased()
    }

    /// The same person always gets the same series colour.
    static func avatarToken(_ email: String) -> String {
        let sum = email.lowercased().utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7FFF_FFFF }
        return "series-\(sum % 6 + 1)"
    }

    /// "3 uncommitted", "3+ uncommitted" when a part stopped early, "Nothing uncommitted" ("clean" when `short`).
    static func uncommitted(_ status: GitStatus, short: Bool = false) -> String {
        if status.count == 0 {
            guard status.complete else { return String(localized: "Uncommitted not fully checked", bundle: .previewKit, comment: "Repository: the check for uncommitted changes stopped early and found none so far.") }
            return short ? String(localized: "clean", bundle: .previewKit, comment: "Repository summary: nothing uncommitted (short form in the one-line summary).") : String(localized: "Nothing uncommitted", bundle: .previewKit, comment: "Repository card: there are no uncommitted changes.")
        }
        let count = status.count.formatted()
        return status.complete
            ? String(localized: "\(count) uncommitted", bundle: .previewKit, comment: "Repository: how many uncommitted changes.")
            : String(localized: "\(count)+ uncommitted", bundle: .previewKit, comment: "Repository: at least this many uncommitted changes (the check stopped early).")
    }

    /// The pill's headline: "git · 412 files · 38.4 MB · 4 uncommitted" (the design's words).
    static func headline(_ s: GitSummary) -> String {
        var parts = ["git"]
        if s.objectFormat == .sha256 {
            parts.append(String(localized: "SHA-256, not read", bundle: .previewKit, comment: "Repository summary: the repository uses SHA-256 object names, which are not read."))
        }
        if let n = s.trackedFiles {
            let count = n.formatted()
            parts.append(n == 1
                ? String(localized: "\(count) file", bundle: .previewKit, comment: "Repository summary: one tracked file.")
                : String(localized: "\(count) files", bundle: .previewKit, comment: "Repository summary: how many tracked files."))
        }
        if let b = s.trackedBytes { parts.append(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)) }
        if let status = s.status, status.count > 0 || status.complete { parts.append(uncommitted(status, short: true)) }
        return parts.joined(separator: " · ")
    }

    static func branchLabel(_ head: GitHead) -> String {
        switch head {
        case .branch(let name, _): name
        case .detached(let id):
            String(localized: "detached at \(id.short)", bundle: .previewKit, comment: "Repository branch label: HEAD is detached at this commit (short id).")
        case .unknown: String(localized: "unknown", bundle: .previewKit, comment: "Repository branch label: the branch could not be read.")
        }
    }

    /// Every fact the tooltip, describe and MCP see.
    static func facts(_ s: GitSummary) -> [Fact] {
        var facts = [Fact(key: "repository", label: String(localized: "Repository", bundle: .previewKit, comment: "Fact label: what kind of repository the folder is."),
                          value: s.location.layout == .bare
                              ? String(localized: "bare git repository", bundle: .previewKit, comment: "Fact value: a git repository with no working files.")
                              : String(localized: "git repository", bundle: .previewKit, comment: "Fact value: the folder is a git repository."))]
        facts.append(Fact(key: "branch", label: String(localized: "Branch", bundle: .previewKit, comment: "Fact label: the current git branch."), value: branchLabel(s.head)))
        if let c = s.headCommit {
            facts.append(Fact(key: "commit", label: String(localized: "Latest commit", bundle: .previewKit, comment: "Fact label: the most recent commit (short id and subject)."), value: "\(c.id.short) \(c.subject)"))
            if let a = c.author {
                facts.append(Fact(key: "author", label: String(localized: "Author", bundle: .previewKit, comment: "Fact label: who wrote the latest commit."), value: a.name))
            }
        }
        if let up = s.upstream {
            var v = up
            if let a = s.ahead, let b = s.behind {
                let push = a.formatted(), pull = b.formatted()
                v = String(localized: "\(up) (\(push) to push, \(pull) to pull)", bundle: .previewKit, comment: "Fact value: the upstream branch and how many commits are ahead (to push) and behind (to pull).")
            }
            facts.append(Fact(key: "upstream", label: String(localized: "Upstream", bundle: .previewKit, comment: "Fact label: the branch this one tracks."), value: v))
        }
        if let n = s.commitCount {
            facts.append(Fact(key: "commits", label: String(localized: "Commits", bundle: .previewKit, comment: "Fact label: number of commits."), value: n.formatted() + (s.commitCountIsFloor ? "+" : "")))
        }
        if let t = s.nearestTag {
            facts.append(Fact(key: "tag", label: s.tagOnHead
                ? String(localized: "Tag", bundle: .previewKit, comment: "Fact label: the git tag on the current commit.")
                : String(localized: "Nearest tag", bundle: .previewKit, comment: "Fact label: the closest git tag in the branch's history."), value: t))
        }
        if let n = s.trackedFiles {
            facts.append(Fact(key: "tracked", label: String(localized: "Tracked files", bundle: .previewKit, comment: "Fact label: number of files git tracks."), value: n.formatted()))
        }
        if let st = s.status {
            facts.append(Fact(key: "uncommitted", label: String(localized: "Uncommitted", bundle: .previewKit, comment: "Fact label: number of uncommitted changes."), value: st.count.formatted() + (st.complete ? "" : "+")))
            if !st.untrackedCounted {
                facts.append(Fact(key: "untracked", label: String(localized: "Untracked files", bundle: .previewKit, comment: "Fact label: number of files git does not track."),
                                  value: String(localized: "not counted", bundle: .previewKit, comment: "Fact value: this count was not made.")))
            }
        }
        if let r = s.readme {
            let name = r.name, first = ByteCountFormatter.string(fromByteCount: 128 * 1024, countStyle: .memory)
            facts.append(Fact(key: "readme", label: "README",
                              value: r.truncated ? String(localized: "\(name) (first \(first))", bundle: .previewKit, comment: "Fact value: the README's file name, only its start read. The second argument is a size.") : name))
        }
        facts.append(Fact(key: "source", label: String(localized: "Read", bundle: .previewKit, comment: "Fact label: how the repository was read."),
                          value: String(localized: "from the .git folder, no git process", bundle: .previewKit, comment: "Fact value: Vitrine reads the .git folder itself and never runs git. Keep “.git” and “git”.")))
        if !s.notes.isEmpty { facts.append(Fact(key: "notRead", label: String(localized: "Not read", bundle: .previewKit, comment: "Fact label: parts of the repository that were not read."), value: s.notes.joined(separator: "; "))) }
        return facts
    }
}
