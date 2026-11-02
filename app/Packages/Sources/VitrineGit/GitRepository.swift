import Darwin
import Foundation
import VitrineSupport

/// Where a repository's pieces are. roadmap: S-9
public struct GitLocation: Sendable, Equatable {
    public enum Layout: String, Sendable, Equatable {
        /// A work tree with its `.git` directory.
        case standard
        /// A work tree whose `.git` is a file naming the git directory elsewhere (a linked worktree, a submodule).
        case gitFile
        /// A repository with no work tree (the folder is the git directory).
        case bare
    }
    public let layout: Layout
    /// nil for a bare repository.
    public let workTree: URL?
    /// HEAD and the index live here.
    public let gitDir: URL
    /// Objects, shared refs and config live here (the git directory itself, unless `commondir` says otherwise).
    public let commonDir: URL

    /// Finds the repository whose work tree is `folder` (a `.git` directory or a `gitdir:` file in it), or the
    /// bare repository that `folder` is. Only that folder is looked at; parents are not searched, because a
    /// preview describes the folder itself.
    public static func locate(_ folder: URL) -> GitLocation? {
        let folder = folder.standardizedFileURL
        let dotGit = folder.appendingPathComponent(".git")
        var st = stat()
        if lstat(dotGit.path, &st) == 0 {
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                guard looksLikeGitDir(dotGit) else { return nil }
                return GitLocation(layout: .standard, workTree: folder, gitDir: dotGit, commonDir: commonDir(of: dotGit))
            case S_IFREG:
                guard let text = SmallFile.text(dotGit, max: 4096) else { return nil }
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("gitdir:") else { return nil }
                let path = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { return nil }
                let dir = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)).standardizedFileURL
                guard looksLikeGitDir(dir) else { return nil }
                return GitLocation(layout: .gitFile, workTree: folder, gitDir: dir, commonDir: commonDir(of: dir))
            default:
                return nil
            }
        }
        // A bare repository (or a .git folder previewed on its own): HEAD, objects and refs at the top.
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent("objects").path),
              fm.fileExists(atPath: folder.appendingPathComponent("refs").path),
              looksLikeGitDir(folder) else { return nil }
        return GitLocation(layout: .bare, workTree: nil, gitDir: folder, commonDir: commonDir(of: folder))
    }

    private static func looksLikeGitDir(_ dir: URL) -> Bool {
        guard let head = SmallFile.text(dir.appendingPathComponent("HEAD"), max: 4096) else { return false }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("ref:") || GitObjectID(hex: line.prefix(40)) != nil || line.count == 64
    }

    private static func commonDir(of gitDir: URL) -> URL {
        guard let text = SmallFile.text(gitDir.appendingPathComponent("commondir"), max: 4096) else { return gitDir }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return gitDir }
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : gitDir.appendingPathComponent(path)).standardizedFileURL
    }
}

/// A README found at the top of the repository: from the work tree, or from HEAD's tree in a bare repository.
public struct GitReadme: Sendable, Equatable {
    public let name: String
    public let text: String
    /// Only the first `maxReadmeBytes` were read.
    public let truncated: Bool
    public var isMarkdown: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd", "mkdn"].contains(ext)
    }
}

/// Everything the repository card shows, read straight from the files in `.git`. Whatever could not be read is
/// nil (or empty) and named in `notes`; nothing here throws. roadmap: S-9
public struct GitSummary: Sendable, Equatable {
    public enum ObjectFormat: String, Sendable, Equatable { case sha1, sha256 }

    public let location: GitLocation
    public let objectFormat: ObjectFormat
    public let head: GitHead
    public let headCommit: GitCommit?
    /// Newest first, at most `GitLimits.recentCommits`.
    public let recent: [GitCommit]
    /// Commits on the branch that its upstream does not have (drawn as "not pushed").
    public let notPushed: Set<GitObjectID>
    /// "origin/main", from `branch.<name>.remote` and `.merge`.
    public let upstream: String?
    public let ahead: Int?
    public let behind: Int?
    /// Commits reachable from HEAD; a floor when `commitCountIsFloor`.
    public let commitCount: Int?
    public let commitCountIsFloor: Bool
    /// The newest tag on HEAD's history within the walk bound, and whether it is on HEAD itself.
    public let nearestTag: String?
    public let tagOnHead: Bool
    /// Top-level name → the newest commit that changed it (within the walk bound).
    public let lastTouch: [String: GitCommit]
    /// Tracked files and their bytes, from the index.
    public let trackedFiles: Int?
    public let trackedBytes: Int64?
    public let status: GitStatus?
    public let readme: GitReadme?
    /// Packs present, for the facts.
    public let packCount: Int
    /// What was not read, and why, in words.
    public let notes: [String]
}

/// Reads a repository from its files. Never runs git, never writes, never follows the network. Each `summary`
/// call is one bounded read on the calling thread; call it off the main thread. roadmap: S-9
public final class GitRepository: @unchecked Sendable {
    public let location: GitLocation
    public let limits: GitLimits

    public init?(folder: URL, limits: GitLimits = .standard) {
        guard let location = GitLocation.locate(folder) else { return nil }
        self.location = location
        self.limits = limits
    }

    public struct Parts: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Commit count, ahead/behind, each top-level item's last commit.
        public static let history = Parts(rawValue: 1)
        /// Uncommitted changes and untracked files.
        public static let status = Parts(rawValue: 2)
        public static let all: Parts = [.history, .status]
    }

    /// Reads the card's facts. Without `parts` it reads only what is quick (HEAD, the recent commits, the tag, the
    /// index's counts and the README), for the first paint.
    public func summary(_ parts: Parts = []) -> GitSummary {
        let deadline = GitDeadline(limits.timeBudget)
        var notes: [String] = []
        let config = GitConfig(text: SmallFile.text(location.commonDir.appendingPathComponent("config"), max: limits.maxSmallFileBytes) ?? "")
        let refs = GitRefs(gitDir: location.gitDir, commonDir: location.commonDir, maxFileBytes: limits.maxSmallFileBytes)

        let format: GitSummary.ObjectFormat = config.value("extensions", nil, "objectformat")?.lowercased() == "sha256" ? .sha256 : .sha1
        let reftable = config.value("extensions", nil, "refstorage")?.lowercased() == "reftable"
        if (Int(config.value("core", nil, "repositoryformatversion") ?? "0") ?? 0) > 1 { notes.append(String(localized: "unknown repository format version", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")) }

        // SHA-256 or reftable repositories: the branch name is still in HEAD as text, but objects and refs are in
        // forms this reader does not parse, so it stops here rather than misread them.
        if format == .sha256 || reftable {
            var head = GitHead.unknown
            if let text = SmallFile.text(location.gitDir.appendingPathComponent("HEAD"), max: 4096),
               case let line = text.trimmingCharacters(in: .whitespacesAndNewlines), line.hasPrefix("ref: refs/heads/"),
               !line.hasSuffix(".invalid") {
                head = .branch(String(line.dropFirst("ref: refs/heads/".count)), nil)
            }
            notes.append(format == .sha256 ? String(localized: "SHA-256 repository: objects are not read", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")
                         : String(localized: "reftable refs are not read", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read."))
            return GitSummary(location: location, objectFormat: format, head: head, headCommit: nil, recent: [], notPushed: [],
                              upstream: nil, ahead: nil, behind: nil, commitCount: nil, commitCountIsFloor: false, nearestTag: nil,
                              tagOnHead: false, lastTouch: [:], trackedFiles: nil, trackedBytes: nil, status: nil,
                              readme: workTreeReadme(), packCount: 0, notes: notes)
        }

        let store = GitObjectStore(objectsDirectory: location.commonDir.appendingPathComponent("objects"), maxDeltaDepth: limits.maxDeltaDepth)
        if store.unreadablePacks > 0 { notes.append(store.unreadablePacks == 1 ? String(localized: "1 pack file could not be read", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")
                         : String(localized: "\(store.unreadablePacks.formatted()) pack files could not be read", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")) }
        let history = GitHistory(store: store, deadline: deadline, maxObjectBytes: limits.maxObjectBytes)
        let head = refs.head()
        if head == .unknown { notes.append(String(localized: "HEAD could not be read", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")) }
        if FileManager.default.fileExists(atPath: location.commonDir.appendingPathComponent("shallow").path) { notes.append(String(localized: "shallow clone: history ends early", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")) }

        var headCommit: GitCommit?
        if let id = head.commitID {
            headCommit = history.commit(id)
            if headCommit == nil { notes.append(String(localized: "the current commit could not be read", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")) }
        }

        // Recent commits.
        var recent: [GitCommit] = []
        if let id = headCommit?.id {
            history.walk(from: [id], limit: limits.recentCommits) { recent.append($0); return true }
        }

        // Upstream: branch.<name>.remote + branch.<name>.merge → refs/remotes/<remote>/<branch>.
        var upstream: String?, upstreamID: GitObjectID?
        if let branch = head.branchName, let remote = config.value("branch", branch, "remote"), remote != ".",
           let merge = config.value("branch", branch, "merge"), merge.hasPrefix("refs/heads/") {
            let name = remote + "/" + merge.dropFirst("refs/heads/".count)
            upstream = name
            upstreamID = refs.resolve("refs/remotes/" + name)
            if upstreamID == nil { notes.append(String(localized: "the upstream \(name) is not known locally", bundle: .module, comment: "Repository note; the argument is the upstream branch name.")) }
        }

        // Nearest tag: the first commit in the date-ordered walk that a tag points at.
        var nearestTag: String?, tagOnHead = false
        let tags = refs.tags(limit: limits.maxTags)
        if let id = headCommit?.id, !tags.isEmpty {
            var byCommit: [GitObjectID: [String]] = [:]
            for t in tags {
                let target = t.peeled ?? history.commit(t.id)?.id
                if let target { byCommit[target, default: []].append(t.name) }
            }
            history.walk(from: [id], limit: parts.contains(.history) ? limits.maxHistoryWalk : 200) { c in
                guard let names = byCommit[c.id] else { return true }
                nearestTag = names.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.first
                tagOnHead = c.id == id
                return false
            }
        }

        // The index: counts for the pill, entries for the status.
        var index: GitIndex?
        var indexModified: timespec?
        let indexURL = location.gitDir.appendingPathComponent("index")
        var st = stat()
        if lstat(indexURL.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG {
            indexModified = st.st_mtimespec
            if st.st_size > Int64(limits.maxIndexBytes) { notes.append(String(localized: "the index is too large to read", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")) }
            else if let bytes = SmallFile.bytes(indexURL, max: limits.maxIndexBytes) {
                do { index = try GitIndex.parse(bytes, maxEntries: limits.maxIndexEntries) }
                catch { notes.append(String(localized: "the index could not be read", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")) }
            }
        }
        let tracked = index?.trackedFiles

        // The slower parts.
        var notPushed = Set<GitObjectID>(), ahead: Int?, behind: Int?
        var commitCount: Int?, floor = false
        var lastTouch: [String: GitCommit] = [:]
        var status: GitStatus?
        if parts.contains(.history), let id = headCommit?.id {
            if let up = upstreamID {
                if let r = history.aheadBehind(head: id, upstream: up, limit: limits.maxHistoryWalk) {
                    ahead = r.ahead; behind = r.behind; notPushed = r.onlyHead
                } else { notes.append(String(localized: "ahead and behind were not counted (history too long)", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")) }
            }
            var n = 0
            let reachedEnd = history.walk(from: [id], limit: limits.maxCountedCommits) { _ in n += 1; return true }
            commitCount = n; floor = !reachedEnd
            if let root = history.rootEntries(headCommit!.tree) {
                lastTouch = history.lastTouch(head: id, names: Set(root.keys), limit: limits.maxHistoryWalk)
            }
        }
        if parts.contains(.status), let workTree = location.workTree {
            let reader = GitStatusReader(workTree: workTree, gitDir: location.gitDir, commonDir: location.commonDir, store: store,
                                         config: config, limits: limits, deadline: deadline)
            let headKnown = head.commitID == nil ? head != .unknown : headCommit != nil
            status = reader.read(index: index, indexModified: indexModified, headTree: headCommit?.tree, headKnown: headKnown)
            notes.append(contentsOf: status?.notes ?? [])
        }
        if deadline.expired { notes.append(String(localized: "the time budget ran out", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")) }

        let readme = location.workTree == nil ? treeReadme(store: store, tree: headCommit?.tree) : workTreeReadme()
        return GitSummary(location: location, objectFormat: format, head: head, headCommit: headCommit, recent: recent,
                          notPushed: notPushed, upstream: upstream, ahead: ahead, behind: behind, commitCount: commitCount,
                          commitCountIsFloor: floor, nearestTag: nearestTag, tagOnHead: tagOnHead, lastTouch: lastTouch,
                          trackedFiles: tracked?.count, trackedBytes: tracked?.bytes, status: status, readme: readme,
                          packCount: store.packCount, notes: notes)
    }

    /// A blob's content (for line counts), or nil when it is missing, not a blob or over `maxBlobBytes`.
    public func blob(_ id: GitObjectID) -> [UInt8]? {
        let store = GitObjectStore(objectsDirectory: location.commonDir.appendingPathComponent("objects"), maxDeltaDepth: limits.maxDeltaDepth)
        guard let object = store.object(id, maxBytes: limits.maxBlobBytes), object.type == .blob else { return nil }
        return object.content
    }

    // MARK: README

    /// The README the card shows: Markdown first, then plain text, then the other markups.
    static func readmeRank(_ name: String) -> Int? {
        let lower = name.lowercased()
        guard lower == "readme" || lower.hasPrefix("readme.") else { return nil }
        switch (lower as NSString).pathExtension {
        case "md", "markdown", "mdown", "mkd", "mkdn": return 0
        case "": return 1
        case "txt", "text": return 2
        case "rst", "adoc", "asciidoc", "org", "rdoc", "textile": return 3
        default: return nil
        }
    }

    public static let maxReadmeBytes = 128 << 10

    private func workTreeReadme() -> GitReadme? {
        guard let root = location.workTree,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        let candidates = names.compactMap { n in Self.readmeRank(n).map { (n, $0) } }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        for (name, _) in candidates {
            let url = root.appendingPathComponent(name)
            guard let source = try? BoundedFileSource<GitError>(url: url),
                  let bytes = try? source.read(at: 0, count: Self.maxReadmeBytes) else { continue }
            return GitReadme(name: name, text: Self.decode(bytes), truncated: source.size > Int64(Self.maxReadmeBytes))
        }
        return nil
    }

    private func treeReadme(store: GitObjectStore, tree: GitObjectID?) -> GitReadme? {
        guard let tree, let object = store.object(tree, maxBytes: limits.maxObjectBytes), object.type == .tree else { return nil }
        let candidates = GitTreeEntry.parse(object.content).filter { !$0.isTree && !$0.isGitlink }
            .compactMap { e in Self.readmeRank(e.name).map { (e, $0) } }.sorted { ($0.1, $0.0.name) < ($1.1, $1.0.name) }
        for (entry, _) in candidates {
            guard let blob = store.object(entry.id, maxBytes: limits.maxBlobBytes), blob.type == .blob else { continue }
            let bytes = Array(blob.content.prefix(Self.maxReadmeBytes))
            return GitReadme(name: entry.name, text: Self.decode(bytes), truncated: blob.content.count > Self.maxReadmeBytes)
        }
        return nil
    }

    /// UTF-8, dropping a cut final character rather than showing a replacement mark.
    static func decode(_ bytes: [UInt8]) -> String {
        var end = bytes.count
        var i = end - 1, continuation = 0
        while i >= 0, continuation < 3, bytes[i] & 0xC0 == 0x80 { i -= 1; continuation += 1 }
        if i >= 0, bytes[i] >= 0xC0 {
            let need = bytes[i] >= 0xF0 ? 4 : bytes[i] >= 0xE0 ? 3 : 2
            if end - i < need { end = i }
        }
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }
}
