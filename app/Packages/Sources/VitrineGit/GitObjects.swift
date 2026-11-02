import Foundation

/// A person and a moment, as commits and tags record them: `Name <email> 1700000000 +0100`. roadmap: S-9
public struct GitSignature: Sendable, Equatable {
    public let name: String
    public let email: String
    public let date: Date
    /// Minutes east of UTC.
    public let timeZoneMinutes: Int

    /// Parses one signature line's value; nil when it is not that shape.
    static func parse(_ text: Substring) -> GitSignature? {
        guard let open = text.lastIndex(of: "<"), let close = text[open...].firstIndex(of: ">") else { return nil }
        let name = text[..<open].trimmingCharacters(in: .whitespaces)
        let email = String(text[text.index(after: open)..<close])
        let rest = text[text.index(after: close)...].split(separator: " ")
        guard let seconds = rest.first.flatMap({ Int64($0) }) else { return nil }
        var tz = 0
        if rest.count > 1, let raw = Int(rest[1]) {
            tz = (raw / 100) * 60 + (raw % 100)
        }
        return GitSignature(name: name, email: email, date: Date(timeIntervalSince1970: TimeInterval(seconds)), timeZoneMinutes: tz)
    }
}

/// The parts of a commit the card shows. roadmap: S-9
public struct GitCommit: Sendable, Equatable {
    public let id: GitObjectID
    public let tree: GitObjectID
    public let parents: [GitObjectID]
    public let author: GitSignature?
    public let committer: GitSignature?
    /// The message's first line.
    public let subject: String

    /// Parses a commit object's content. Unknown headers (gpgsig, encoding, mergetag) and their continuation lines
    /// are skipped; a commit without a tree line is not a commit.
    static func parse(id: GitObjectID, _ content: [UInt8]) -> GitCommit? {
        let text = String(decoding: content, as: UTF8.self)
        var tree: GitObjectID?
        var parents: [GitObjectID] = []
        var author: GitSignature?, committer: GitSignature?
        var subject = ""
        var inHeaders = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if inHeaders {
                if line.isEmpty { inHeaders = false; continue }
                if line.hasPrefix(" ") { continue }                       // continuation of a multi-line header
                guard let space = line.firstIndex(of: " ") else { continue }
                let key = line[..<space], value = line[line.index(after: space)...]
                switch key {
                case "tree": tree = GitObjectID(hex: value)
                case "parent": if let p = GitObjectID(hex: value) { parents.append(p) }
                case "author": author = GitSignature.parse(value)
                case "committer": committer = GitSignature.parse(value)
                default: break
                }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                subject = line.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard let tree else { return nil }
        return GitCommit(id: id, tree: tree, parents: parents, author: author, committer: committer, subject: subject)
    }

    /// The order commits are walked in: the committer's time, falling back to the author's.
    var walkDate: Date { committer?.date ?? author?.date ?? .distantPast }
}

/// One line of a tree. roadmap: S-9
public struct GitTreeEntry: Sendable, Equatable {
    public let mode: UInt32
    public let name: String
    public let id: GitObjectID

    public var isTree: Bool { mode & 0o170000 == 0o040000 }
    /// A submodule: the id is a commit in another repository.
    public var isGitlink: Bool { mode & 0o170000 == 0o160000 }

    /// Parses a tree object's content: `mode name\0` followed by 20 bytes, repeated. Stops at the first damaged
    /// entry and returns what came before it.
    static func parse(_ content: [UInt8], limit: Int = .max) -> [GitTreeEntry] {
        var out: [GitTreeEntry] = []
        var i = 0
        while i < content.count, out.count < limit {
            guard let space = content[i...].prefix(8).firstIndex(of: 0x20) else { break }
            var mode: UInt32 = 0
            var valid = space > i
            for c in content[i..<space] {
                guard c >= 48, c <= 55 else { valid = false; break }
                mode = mode << 3 | UInt32(c - 48)
            }
            guard valid, let nul = content[(space + 1)...].prefix(4096).firstIndex(of: 0), nul + 21 <= content.count,
                  let id = GitObjectID(bytes: Array(content[(nul + 1)...(nul + 20)])) else { break }
            out.append(GitTreeEntry(mode: mode, name: String(decoding: content[(space + 1)..<nul], as: UTF8.self), id: id))
            i = nul + 21
        }
        return out
    }
}

/// An annotated tag's target. roadmap: S-9
struct GitTag {
    let object: GitObjectID
    let type: String

    static func parse(_ content: [UInt8]) -> GitTag? {
        var object: GitObjectID?, type = ""
        for line in String(decoding: content.prefix(4096), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }
            if line.hasPrefix("object ") { object = GitObjectID(hex: line.dropFirst(7)) }
            if line.hasPrefix("type ") { type = String(line.dropFirst(5)) }
        }
        return object.map { GitTag(object: $0, type: type) }
    }
}
