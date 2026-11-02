import Foundation

/// One entry of `.git/index`. roadmap: S-9
public struct GitIndexEntry: Sendable, Equatable {
    public let path: String
    public let mode: UInt32
    public let id: GitObjectID
    /// The file's size, truncated to 32 bits as git stores it.
    public let size: UInt32
    public let mtimeSeconds: UInt32
    public let mtimeNanoseconds: UInt32
    /// 0 for a normal entry; 1–3 for the sides of an unresolved merge conflict.
    public let stage: Int
    public let assumeValid: Bool
    public let skipWorktree: Bool
    public let intentToAdd: Bool

    public var isGitlink: Bool { mode & 0o170000 == 0o160000 }
    public var isSymlink: Bool { mode & 0o170000 == 0o120000 }
    /// A sparse index's collapsed directory (mode 040000), not a file.
    public var isSparseDirectory: Bool { mode & 0o170000 == 0o040000 }
}

/// `.git/index` in versions 2, 3 and 4: entries, the cache-tree extension (so an unchanged directory is never
/// expanded when comparing with HEAD) and the extensions this reader does not follow, noted rather than
/// misread. roadmap: S-9
public struct GitIndex: Sendable {
    public let version: Int
    public let entries: [GitIndexEntry]
    /// The declared entry count; more than `entries.count` when the read stopped at the entry limit.
    public let declaredCount: Int
    /// Directory path ("" for the root) → the tree id the index would write for it, for valid cache-tree entries.
    let cacheTree: [String: GitObjectID]
    /// A split index keeps most entries in a shared file this reader does not open.
    public let isSplit: Bool
    /// A sparse index has collapsed directories.
    public let isSparse: Bool

    public static func parse(_ bytes: [UInt8], maxEntries: Int) throws -> GitIndex {
        guard bytes.count >= 12 + 20 else { throw GitError.truncated("the index is too short") }
        guard bytes[0..<4] == Array("DIRC".utf8)[...] else { throw GitError.malformed("not an index file") }
        let version = Int(be32(bytes, 4)), count = Int(be32(bytes, 8))
        guard (2...4).contains(version) else { throw GitError.unsupported("index version \(version)") }
        let end = bytes.count - 20                     // the trailing checksum
        var entries: [GitIndexEntry] = []
        entries.reserveCapacity(min(count, maxEntries))
        var p = 12
        var previous: [UInt8] = []
        var sparse = false
        for _ in 0..<min(count, maxEntries) {
            guard p + 62 <= end else { throw GitError.truncated("the index ends inside an entry") }
            let mtimeS = be32(bytes, p + 8), mtimeN = be32(bytes, p + 12)
            let mode = be32(bytes, p + 24), size = be32(bytes, p + 36)
            let id = GitObjectID(bytes: Array(bytes[(p + 40)..<(p + 60)]))!
            let flags = Int(be16(bytes, p + 60))
            var q = p + 62
            var extended = 0
            if flags & 0x4000 != 0 {
                guard version >= 3, q + 2 <= end else { throw GitError.malformed("an index entry has extended flags in version 2") }
                extended = Int(be16(bytes, q)); q += 2
            }
            var path: [UInt8]
            if version == 4 {
                // The prefix length is read inside the entries (never from the checksum after them), and must
                // name part of the previous path: never negative, never more than it has.
                let strip = try GitVarint.offset(bytes, &q, end: end)
                guard strip >= 0, strip <= previous.count else { throw GitError.malformed("an index path strips more than it has") }
                guard q <= end, let nul = bytes[q..<end].firstIndex(of: 0) else { throw GitError.truncated("an index path has no end") }
                path = Array(previous[0..<(previous.count - strip)]) + bytes[q..<nul]
                p = nul + 1
            } else {
                guard let nul = bytes[q..<end].firstIndex(of: 0) else { throw GitError.truncated("an index path has no end") }
                path = Array(bytes[q..<nul])
                let length = nul - p                              // fixed part + path, before the padding
                p += (length + 8) & ~7                            // 1 to 8 NULs, to a multiple of 8
                guard p <= end else { throw GitError.truncated("the index ends inside an entry") }
            }
            guard !path.isEmpty, path.first != 0x2F else { throw GitError.malformed("an index path is empty or absolute") }
            previous = path
            let entry = GitIndexEntry(path: String(decoding: path, as: UTF8.self), mode: mode, id: id, size: size,
                                      mtimeSeconds: mtimeS, mtimeNanoseconds: mtimeN, stage: (flags >> 12) & 3,
                                      assumeValid: flags & 0x8000 != 0, skipWorktree: extended & 0x4000 != 0,
                                      intentToAdd: extended & 0x2000 != 0)
            if entry.isSparseDirectory { sparse = true }
            entries.append(entry)
        }

        // Extensions: 4-byte signature, 4-byte size, data. Only read when every entry was.
        var cacheTree: [String: GitObjectID] = [:]
        var split = false
        if count <= maxEntries {
            while p + 8 <= end {
                let signature = String(decoding: bytes[p..<(p + 4)], as: UTF8.self)
                let size = Int(be32(bytes, p + 4))
                let start = p + 8
                guard size >= 0, start + size <= end else { break }
                switch signature {
                case "TREE": cacheTree = Self.parseCacheTree(Array(bytes[start..<(start + size)]))
                case "link": split = true
                case "sdir": sparse = true
                default: break
                }
                p = start + size
            }
        }
        return GitIndex(version: version, entries: entries, declaredCount: count, cacheTree: cacheTree, isSplit: split, isSparse: sparse)
    }

    /// The cache-tree extension: a pre-order list of `path\0entries subtrees\n[20-byte id]`, where entries is -1
    /// for a directory whose tree is out of date (no id follows). Paths are names relative to the parent. Read with
    /// an explicit stack, never recursion: the nesting is the file's to declare (each node is 6 bytes, so a 100 KB
    /// extension can nest 16,000 deep). Nesting past `maxCacheTreeDepth`, paths past `maxCacheTreePathBytes` or more
    /// than `maxCacheTreeNodes` nodes end the read with what was gathered: the cache tree only saves work, and a
    /// directory it does not cover is compared in full.
    static let maxCacheTreeDepth = 4_096
    static let maxCacheTreePathBytes = 16 * 1024
    static let maxCacheTreeNodes = 1_000_000

    static func parseCacheTree(_ data: [UInt8]) -> [String: GitObjectID] {
        var out: [String: GitObjectID] = [:]
        guard !data.isEmpty else { return out }
        var i = 0
        var nodes = 0
        // Each open directory: its path and how many of its subtrees are still to come.
        var open: [(path: String, remaining: Int)] = []
        repeat {
            nodes += 1
            guard nodes <= maxCacheTreeNodes, let nul = data[i...].firstIndex(of: 0) else { return out }
            let name = String(decoding: data[i..<nul], as: UTF8.self)
            i = nul + 1
            guard let newline = data[i...].prefix(32).firstIndex(of: 0x0A) else { return out }
            let numbers = String(decoding: data[i..<newline], as: UTF8.self).split(separator: " ")
            i = newline + 1
            guard numbers.count == 2, let entries = Int(numbers[0]), let subtrees = Int(numbers[1]), subtrees >= 0 else { return out }
            let path: String
            if let parent = open.last {
                path = parent.path.isEmpty ? name : parent.path + "/" + name
                open[open.count - 1].remaining -= 1
            } else {
                path = ""                                                  // the root
            }
            guard path.utf8.count <= maxCacheTreePathBytes else { return out }
            if entries >= 0 {
                guard i + 20 <= data.count, let id = GitObjectID(bytes: Array(data[i..<(i + 20)])) else { return out }
                out[path] = id
                i += 20
            }
            if subtrees > 0 {
                guard open.count < maxCacheTreeDepth else { return out }
                open.append((path, subtrees))
            }
            while let last = open.last, last.remaining == 0 { open.removeLast() }
        } while !open.isEmpty
        return out
    }

    /// The tracked files' count and bytes (stage 0, files only), the "412 files · 38.4 MB" of the card.
    public var trackedFiles: (count: Int, bytes: Int64) {
        var n = 0, total: Int64 = 0
        for e in entries where e.stage == 0 && !e.isSparseDirectory && !e.isGitlink { n += 1; total += Int64(e.size) }
        return (n, total)
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    private static func be16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
}
