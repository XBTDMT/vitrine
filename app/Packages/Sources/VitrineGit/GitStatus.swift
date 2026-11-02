import Darwin
import Foundation

/// One uncommitted path, as `git status --short` would list it (one letter, the most telling of its two
/// columns). roadmap: S-9
public struct GitChange: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case modified = "M", added = "A", deleted = "D", unmerged = "U", untracked = "?"
    }
    public let path: String
    public let kind: Kind
    /// Differs between HEAD and the index (would be committed as is).
    public let staged: Bool
    /// Differs between the index and the working file.
    public let unstaged: Bool
    /// The blob in HEAD and in the index, when there is one (for line counts).
    public let headID: GitObjectID?
    public let indexID: GitObjectID?
    /// An untracked directory, listed once as `dir/` the way git does.
    public let isDirectory: Bool
}

/// The uncommitted changes of a work tree. roadmap: S-9
public struct GitStatus: Sendable, Equatable {
    /// Sorted by path, at most `GitLimits.maxListedChanges`.
    public let changes: [GitChange]
    /// Every change found, listed or not.
    public let count: Int
    /// Whether untracked files were counted (false when the walk ran out of budget or there is no work tree).
    public let untrackedCounted: Bool
    /// False when any part stopped early: then `count` is a floor.
    public let complete: Bool
    /// What was not checked, in words for the facts.
    public let notes: [String]
}

/// Compares the work tree with the index (size and modification time first, hashing a file only when its size
/// matches but its time does not, or the entry is racily clean), the index with HEAD's tree (skipping every
/// directory whose cache-tree id equals HEAD's), and walks the work tree for untracked files with the ignore
/// rules. Every part is bounded; whatever is cut short says so in `notes`. roadmap: S-9
struct GitStatusReader {
    let workTree: URL
    let gitDir: URL
    let commonDir: URL
    let store: GitObjectStore
    let config: GitConfig
    let limits: GitLimits
    let deadline: GitDeadline

    private struct Entry { var staged: GitChange.Kind?; var unstaged: GitChange.Kind?; var headID: GitObjectID?; var indexID: GitObjectID?; var dir = false }

    func read(index: GitIndex?, indexModified: timespec?, headTree: GitObjectID?, headKnown: Bool) -> GitStatus {
        var notes: [String] = []
        var complete = true
        var table: [String: Entry] = [:]
        let entries = index?.entries ?? []
        if let index, index.declaredCount > index.entries.count { notes.append(String(localized: "the index has more entries than were read", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")); complete = false }
        if index?.isSplit == true { notes.append(String(localized: "a split index is not read", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")); complete = false }

        // Unmerged paths first; their stages are not compared further.
        var unmerged = Set<String>()
        for e in entries where e.stage != 0 { unmerged.insert(e.path) }
        for path in unmerged { table[path] = Entry(staged: .unmerged, unstaged: nil) }

        // 1. Work tree against the index.
        let fileMode = config.bool("core", nil, "filemode") ?? true
        let crlf = (config.value("core", nil, "autocrlf").map { $0.lowercased() != "false" } ?? false)
            || FileManager.default.fileExists(atPath: workTree.appendingPathComponent(".gitattributes").path)
        var hashed = 0, unchecked = 0
        for e in entries where e.stage == 0 && !e.skipWorktree && !e.isSparseDirectory && !e.isGitlink {
            if deadline.expired { complete = false; notes.append(String(localized: "time ran out comparing files", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")); break }
            if e.intentToAdd { table[e.path, default: Entry()].unstaged = .added; table[e.path]!.indexID = nil; continue }
            switch workingState(e, fileMode: fileMode, indexModified: indexModified, hashed: &hashed, crlf: crlf) {
            case .clean: break
            case .modified: table[e.path, default: Entry()].unstaged = .modified; table[e.path]!.indexID = e.id
            case .deleted: table[e.path, default: Entry()].unstaged = .deleted; table[e.path]!.indexID = e.id
            case .unchecked: unchecked += 1
            }
        }
        if unchecked > 0 { complete = false; notes.append(unchecked == 1 ? String(localized: "1 file was not hashed (over the size or count bound)", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")
                                                   : String(localized: "\(unchecked.formatted()) files were not hashed (over the size or count bound)", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")) }

        // 2. The index against HEAD.
        if headKnown {
            let compared = compareWithHead(entries: entries, unmerged: unmerged, index: index, headTree: headTree, into: &table)
            if !compared { complete = false; notes.append(String(localized: "HEAD's tree was not fully compared", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")) }
        }

        // 3. Untracked files.
        var untrackedCounted = false
        if !deadline.expired {
            untrackedCounted = untracked(entries: entries, into: &table)
            if !untrackedCounted { complete = false; notes.append(String(localized: "untracked files were not all counted", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read.")) }
        } else {
            complete = false; notes.append(String(localized: "untracked files were not counted", bundle: .module, comment: "Repository note in the folder view: what Vitrine could not read."))
        }

        var changes: [GitChange] = []
        for (path, e) in table {
            let kind: GitChange.Kind
            if e.staged == .unmerged { kind = .unmerged }
            else if e.unstaged == .untracked { kind = .untracked }
            else if e.staged == .added || e.unstaged == .added { kind = .added }
            else if e.staged == .deleted || e.unstaged == .deleted { kind = .deleted }
            else { kind = .modified }
            changes.append(GitChange(path: path, kind: kind, staged: e.staged != nil && e.staged != .unmerged,
                                     unstaged: e.unstaged != nil && e.unstaged != .untracked, headID: e.headID,
                                     indexID: e.indexID, isDirectory: e.dir))
        }
        changes.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        return GitStatus(changes: Array(changes.prefix(limits.maxListedChanges)), count: changes.count,
                         untrackedCounted: untrackedCounted, complete: complete, notes: notes)
    }

    // MARK: Work tree against the index

    private enum WorkingState { case clean, modified, deleted, unchecked }

    private func workingState(_ e: GitIndexEntry, fileMode: Bool, indexModified: timespec?, hashed: inout Int, crlf: Bool) -> WorkingState {
        let url = workTree.appendingPathComponent(e.path)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return .deleted }
        let type = st.st_mode & S_IFMT
        if e.isSymlink { guard type == S_IFLNK else { return .modified } }
        else {
            if type == S_IFDIR { return .deleted }            // a directory where the file was
            guard type == S_IFREG else { return .modified }
            if fileMode, (e.mode & 0o111 != 0) != (st.st_mode & 0o100 != 0) { return .modified }
        }
        if e.assumeValid { return .clean }
        if UInt32(truncatingIfNeeded: st.st_size) != e.size { return .modified }
        let sameTime = UInt32(truncatingIfNeeded: st.st_mtimespec.tv_sec) == e.mtimeSeconds
            && (e.mtimeNanoseconds == 0 || UInt32(truncatingIfNeeded: st.st_mtimespec.tv_nsec) == e.mtimeNanoseconds)
        // Racily clean: written in the same second the index was, so a change could hide behind equal times.
        var racy = false
        if let im = indexModified {
            racy = Int(e.mtimeSeconds) > im.tv_sec || (Int(e.mtimeSeconds) == im.tv_sec && Int(e.mtimeNanoseconds) >= im.tv_nsec)
        }
        if sameTime && !racy { return .clean }
        // Size matches, time does not: hash the content.
        guard hashed < limits.maxHashedFiles, st.st_size <= limits.maxBlobBytes else { return .unchecked }
        hashed += 1
        guard var content = readWorking(url, symlink: e.isSymlink, size: Int(st.st_size)) else { return .unchecked }
        if GitObjectID.hash(type: "blob", content: content) == e.id { return .clean }
        if crlf, content.contains(0x0D) {
            content = Self.normalizeCRLF(content)
            if GitObjectID.hash(type: "blob", content: content) == e.id { return .clean }
        }
        return .modified
    }

    private func readWorking(_ url: URL, symlink: Bool, size: Int) -> [UInt8]? {
        if symlink {
            var buffer = [CChar](repeating: 0, count: 4097)
            let n = readlink(url.path, &buffer, 4096)
            guard n >= 0 else { return nil }
            return buffer[0..<n].map { UInt8(bitPattern: $0) }
        }
        return SmallFile.bytes(url, max: max(size, 0) + 1)
    }

    static func normalizeCRLF(_ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            if b[i] == 0x0D, i + 1 < b.count, b[i + 1] == 0x0A { i += 1; continue }
            out.append(b[i]); i += 1
        }
        return out
    }

    // MARK: Index against HEAD

    /// Expands HEAD's tree only where the cache tree cannot vouch for a directory, then compares paths.
    private func compareWithHead(entries: [GitIndexEntry], unmerged: Set<String>, index: GitIndex?, headTree: GitObjectID?,
                                 into table: inout [String: Entry]) -> Bool {
        var head: [String: (mode: UInt32, id: GitObjectID)] = [:]
        var sameDirs = Set<String>()
        var complete = true
        if let headTree {
            let cache = index?.cacheTree ?? [:]
            var stack: [(String, GitObjectID)] = [("", headTree)]
            var expanded = 0
            while let (dir, tree) = stack.popLast() {
                if cache[dir] == tree { sameDirs.insert(dir); continue }
                if deadline.expired || expanded > limits.maxTreeEntries { complete = false; break }
                guard let object = store.object(tree, maxBytes: limits.maxObjectBytes), object.type == .tree else { complete = false; continue }
                for item in GitTreeEntry.parse(object.content) {
                    expanded += 1
                    let path = dir.isEmpty ? item.name : dir + "/" + item.name
                    if item.isTree { stack.append((path, item.id)) } else { head[path] = (item.mode, item.id) }
                }
            }
        }
        guard complete else { return false }
        func underSameDir(_ path: String) -> Bool {
            if sameDirs.contains("") { return true }
            var p = Substring(path)
            while let slash = p.lastIndex(of: "/") {
                p = p[..<slash]
                if sameDirs.contains(String(p)) { return true }
            }
            return false
        }
        var inIndex = Set<String>()
        for e in entries where e.stage == 0 && !e.intentToAdd {
            inIndex.insert(e.path)
            if unmerged.contains(e.path) || underSameDir(e.path) { continue }
            if let h = head[e.path] {
                if h.id != e.id || h.mode != e.mode {
                    table[e.path, default: Entry()].staged = .modified
                    table[e.path]!.headID = h.id; table[e.path]!.indexID = e.id
                }
            } else if !e.isSparseDirectory {
                table[e.path, default: Entry()].staged = .added
                table[e.path]!.indexID = e.id
            }
        }
        for (path, h) in head where !inIndex.contains(path) && !unmerged.contains(path) {
            table[path, default: Entry()].staged = .deleted
            table[path]!.headID = h.id
        }
        return true
    }

    // MARK: Untracked

    /// Walks the work tree (never into `.git`, ignored directories or packages of tracked files' parents), the
    /// way `git status` shows untracked files: a file in a tracked directory one by one, a directory with no
    /// tracked file as one `dir/` when anything in it is not ignored. Returns false when the budget ran out.
    private func untracked(entries: [GitIndexEntry], into table: inout [String: Entry]) -> Bool {
        var tracked = Set<String>(), trackedDirs = Set<String>([""])
        for e in entries {
            tracked.insert(e.path)
            var p = Substring(e.path)
            while let slash = p.lastIndex(of: "/") {
                p = p[..<slash]
                if !trackedDirs.insert(String(p)).inserted { break }
            }
        }
        var ignore = GitIgnore()
        if let text = SmallFile.text(commonDir.appendingPathComponent("info/exclude"), max: limits.maxSmallFileBytes) { ignore.add(text, base: "") }
        var visits = 0
        var stack: [String] = [""]
        var budgetOK = true
        while let dir = stack.popLast() {
            let dirURL = dir.isEmpty ? workTree : workTree.appendingPathComponent(dir)
            if let text = SmallFile.text(dirURL.appendingPathComponent(".gitignore"), max: limits.maxSmallFileBytes) { ignore.add(text, base: dir) }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dirURL.path) else { continue }
            for name in names.sorted() {
                visits += 1
                if visits > limits.maxUntrackedVisits || deadline.expired { return false }
                if name == ".git" { continue }
                let path = dir.isEmpty ? name : dir + "/" + name
                if tracked.contains(path) { continue }
                var st = stat()
                guard lstat(dirURL.appendingPathComponent(name).path, &st) == 0 else { continue }
                let isDir = st.st_mode & S_IFMT == S_IFDIR
                if ignore.isIgnored(path, isDirectory: isDir) { continue }
                if !isDir { table[path, default: Entry()].unstaged = .untracked; continue }
                if trackedDirs.contains(path) { stack.append(path); continue }
                switch hasContent(path, ignore: ignore, visits: &visits) {
                case .some(true): table[path + "/", default: Entry()].unstaged = .untracked; table[path + "/"]!.dir = true
                case .some(false): break
                case .none: budgetOK = false
                }
            }
        }
        return budgetOK
    }

    /// Whether an untracked directory holds anything git would show (a non-ignored file, or a nested repository);
    /// nil when the budget ran out first.
    private func hasContent(_ dir: String, ignore outer: GitIgnore, visits: inout Int) -> Bool? {
        let root = workTree.appendingPathComponent(dir)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) { return true }
        var ignore = outer
        var stack = [dir]
        while let d = stack.popLast() {
            let url = workTree.appendingPathComponent(d)
            if let text = SmallFile.text(url.appendingPathComponent(".gitignore"), max: limits.maxSmallFileBytes) { ignore.add(text, base: d) }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { continue }
            for name in names {
                visits += 1
                if visits > limits.maxUntrackedVisits || deadline.expired { return nil }
                let path = d + "/" + name
                var st = stat()
                guard lstat(url.appendingPathComponent(name).path, &st) == 0 else { continue }
                let isDir = st.st_mode & S_IFMT == S_IFDIR
                if ignore.isIgnored(path, isDirectory: isDir) { continue }
                if !isDir { return true }
                stack.append(path)
            }
        }
        return false
    }
}
