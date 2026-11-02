import Foundation

extension GitRepository {
    /// The repository that holds `file`: the nearest folder above it with a `.git`, up to the volume root. nil when
    /// there is none, or when the folders above cannot be read (a sandboxed Quick Look preview of one file).
    /// roadmap: S-5
    public static func containing(_ file: URL, limits: GitLimits = .standard) -> (repository: GitRepository, path: String)? {
        var folder = file.deletingLastPathComponent().standardizedFileURL
        var parts = [file.lastPathComponent]
        for _ in 0..<64 {
            let dotGit = folder.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: dotGit.path), let repo = GitRepository(folder: folder, limits: limits) {
                return (repo, parts.joined(separator: "/"))
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return nil }
            parts.insert(folder.lastPathComponent, at: 0)
            folder = parent
        }
        return nil
    }

    /// The file at `path` (relative to the work tree, "/"-separated) as it is in the HEAD commit; nil when HEAD, the
    /// path or the blob cannot be read, or the blob is over `maxBlobBytes`. Never runs git. roadmap: S-5
    public func headFile(_ path: String) -> [UInt8]? {
        let refs = GitRefs(gitDir: location.gitDir, commonDir: location.commonDir, maxFileBytes: limits.maxSmallFileBytes)
        guard let commitID = refs.head().commitID else { return nil }
        let store = GitObjectStore(objectsDirectory: location.commonDir.appendingPathComponent("objects"), maxDeltaDepth: limits.maxDeltaDepth)
        guard let commitObject = store.object(commitID, maxBytes: limits.maxObjectBytes), commitObject.type == .commit,
              let commit = GitCommit.parse(id: commitID, commitObject.content) else { return nil }
        var tree = commit.tree
        let names = path.split(separator: "/").map(String.init)
        for (i, name) in names.enumerated() {
            guard let object = store.object(tree, maxBytes: limits.maxObjectBytes), object.type == .tree,
                  let entry = GitTreeEntry.parse(object.content).first(where: { $0.name == name }) else { return nil }
            if i == names.count - 1 {
                guard !entry.isTree, let blob = store.object(entry.id, maxBytes: limits.maxBlobBytes), blob.type == .blob else { return nil }
                return blob.content
            }
            guard entry.isTree else { return nil }
            tree = entry.id
        }
        return nil
    }
}
