import Foundation

/// Commit walks over the object store, newest first by committer date (git log's default order), each one
/// bounded by a commit count and the read's deadline. Missing parents (a shallow clone) end the walk there.
/// roadmap: S-9
final class GitHistory {
    private let store: GitObjectStore
    private let deadline: GitDeadline
    private let maxObjectBytes: Int
    private var commits: [GitObjectID: GitCommit] = [:]
    private var trees: [GitObjectID: [String: GitObjectID]] = [:]

    init(store: GitObjectStore, deadline: GitDeadline, maxObjectBytes: Int) {
        self.store = store; self.deadline = deadline; self.maxObjectBytes = maxObjectBytes
    }

    /// Annotated tags followed to reach a commit. Real chains are one or two long; the store never checks that an
    /// object hashes to its name, so a file can make two tags name each other.
    static let maxTagHops = 32

    /// The commit `id` names, peeling annotated tags iteratively: a tag seen twice (a cycle) or a chain longer than
    /// `maxTagHops` names no commit.
    func commit(_ id: GitObjectID) -> GitCommit? {
        if let hit = commits[id] { return hit }
        var current = id
        var tags: [GitObjectID] = []
        var seen: Set<GitObjectID> = []
        while true {
            if let hit = commits[current] { return remember(hit, for: tags) }
            guard seen.insert(current).inserted, tags.count <= Self.maxTagHops,
                  let object = store.object(current, maxBytes: maxObjectBytes) else { return nil }
            switch object.type {
            case .commit:
                guard let parsed = GitCommit.parse(id: current, object.content) else { return nil }
                commits[current] = parsed
                return remember(parsed, for: tags)
            case .tag:
                guard let tag = GitTag.parse(object.content) else { return nil }
                tags.append(current)
                current = tag.object
            default:
                return nil
            }
        }
    }

    /// Caches `commit` under every tag that peeled to it.
    private func remember(_ commit: GitCommit, for tags: [GitObjectID]) -> GitCommit {
        for tag in tags { commits[tag] = commit }
        return commit
    }

    /// A tree's entries by name (top level only), cached.
    func rootEntries(_ tree: GitObjectID) -> [String: GitObjectID]? {
        if let hit = trees[tree] { return hit }
        guard let object = store.object(tree, maxBytes: maxObjectBytes), object.type == .tree else { return nil }
        var map: [String: GitObjectID] = [:]
        for e in GitTreeEntry.parse(object.content) { map[e.name] = e.id }
        trees[tree] = map
        return map
    }

    /// Visits commits reachable from `starts`, newest first, until `visit` returns false, `limit` commits were
    /// seen or time ran out. Returns whether the walk reached the end of history.
    @discardableResult
    func walk(from starts: [GitObjectID], limit: Int, _ visit: (GitCommit) -> Bool) -> Bool {
        var heap = CommitHeap()
        var seen = Set<GitObjectID>()
        for id in starts where seen.insert(id).inserted { if let c = commit(id) { heap.push(c) } }
        var count = 0
        while let c = heap.pop() {
            if count >= limit || deadline.expired { return false }
            count += 1
            guard visit(c) else { return false }
            for p in c.parents where seen.insert(p).inserted {
                if let pc = commit(p) { heap.push(pc) }
            }
        }
        return true
    }

    /// Commits only on `head` and only on `upstream` (git's ahead and behind), and the set of commits only on
    /// `head`, by painting both sides until every commit still queued is on both. nil when the walk ran out of
    /// budget before it settled.
    func aheadBehind(head: GitObjectID, upstream: GitObjectID, limit: Int) -> (ahead: Int, behind: Int, onlyHead: Set<GitObjectID>)? {
        if head == upstream { return (0, 0, []) }
        var flags: [GitObjectID: UInt8] = [:]
        var heap = CommitHeap()
        guard let h = commit(head), let u = commit(upstream) else { return nil }
        flags[head] = 1; flags[upstream] = 2
        heap.push(h); heap.push(u)
        var steps = 0
        while let c = heap.pop() {
            if heap.allSatisfy({ flags[$0.id] == 3 }) && flags[c.id] == 3 { break }
            steps += 1
            if steps > limit || deadline.expired { return nil }
            let f = flags[c.id] ?? 0
            for p in c.parents {
                let old = flags[p] ?? 0
                let new = old | f
                guard new != old, let pc = commit(p) else { continue }
                flags[p] = new
                heap.push(pc)
            }
        }
        var ahead = 0, behind = 0
        var onlyHead = Set<GitObjectID>()
        for (id, f) in flags {
            if f == 1 { ahead += 1; onlyHead.insert(id) } else if f == 2 { behind += 1 }
        }
        return (ahead, behind, onlyHead)
    }

    /// For each top-level name, the newest commit that changed it (its entry differs from every parent's, or the
    /// commit has no parents), looking at `limit` commits at most. Names not found within the bound stay out.
    func lastTouch(head: GitObjectID, names: Set<String>, limit: Int) -> [String: GitCommit] {
        var remaining = names
        var out: [String: GitCommit] = [:]
        guard !remaining.isEmpty else { return out }
        walk(from: [head], limit: limit) { c in
            guard let mine = rootEntries(c.tree) else { return true }
            let parents = c.parents.compactMap { commit($0) }.compactMap { rootEntries($0.tree) }
            for name in remaining {
                let id = mine[name]
                let changed = parents.isEmpty ? id != nil : parents.allSatisfy { $0[name] != id }
                if changed { out[name] = c }
            }
            remaining.subtract(out.keys)
            return !remaining.isEmpty
        }
        return out
    }
}

/// A max-heap of commits by walk date; ties broken by id so the order is stable.
struct CommitHeap {
    private var items: [GitCommit] = []

    var isEmpty: Bool { items.isEmpty }

    func allSatisfy(_ p: (GitCommit) -> Bool) -> Bool { items.allSatisfy(p) }

    private static func before(_ a: GitCommit, _ b: GitCommit) -> Bool {
        a.walkDate != b.walkDate ? a.walkDate > b.walkDate : b.id < a.id
    }

    mutating func push(_ c: GitCommit) {
        items.append(c)
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard Self.before(items[i], items[parent]) else { break }
            items.swapAt(i, parent); i = parent
        }
    }

    mutating func pop() -> GitCommit? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var best = i
            if l < items.count, Self.before(items[l], items[best]) { best = l }
            if r < items.count, Self.before(items[r], items[best]) { best = r }
            if best == i { break }
            items.swapAt(i, best); i = best
        }
        return top
    }
}
