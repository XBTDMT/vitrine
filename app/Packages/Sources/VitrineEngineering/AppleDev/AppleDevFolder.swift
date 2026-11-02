import Foundation

/// A bounded, read-only walk of one folder the caller handed over (an `.xcassets` or `.xcarchive`). It never leaves
/// that folder: symbolic links are listed but never followed or opened, the walk stops at
/// `AppleDevReader.maxDepth` levels and `AppleDevReader.maxEntries` entries (and says so in `truncated`), and files
/// are opened with `O_NOFOLLOW`, only when they are regular files no larger than the cap they are read under.
final class AppleDevFolder {
    struct Entry {
        var name: String
        var url: URL
        var isDirectory: Bool
        var isSymbolicLink: Bool
        var isRegularFile: Bool
    }

    let root: URL
    let rootIsDirectory: Bool
    private(set) var visited = 0
    /// The walk hit its entry or depth cap somewhere, so a listing is incomplete.
    private(set) var truncated = false

    init(root: URL) {
        self.root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        rootIsDirectory = FileManager.default.fileExists(atPath: self.root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// The entries of `directory` (a folder at `depth` below the root; the root is 0), in name order, each one
    /// counted against the entry budget. Empty past the depth cap or once the budget is spent.
    func children(of directory: URL, depth: Int) -> [Entry] {
        guard depth <= AppleDevReader.maxDepth else { truncated = true; return [] }
        guard visited < AppleDevReader.maxEntries else { truncated = true; return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in true }) else { return [] }
        var out: [Entry] = []
        while let next = enumerator.nextObject() as? URL {
            guard visited < AppleDevReader.maxEntries else { truncated = true; break }
            visited += 1
            let values = try? next.resourceValues(forKeys: Set(keys))
            let link = values?.isSymbolicLink ?? false
            out.append(Entry(name: next.lastPathComponent, url: next,
                             isDirectory: !link && (values?.isDirectory ?? false), isSymbolicLink: link,
                             isRegularFile: !link && (values?.isRegularFile ?? false)))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// The entry named `name` directly inside `directory`, looked up without following links (not counted).
    func entry(_ name: String, in directory: URL) -> Entry? {
        let url = directory.appendingPathComponent(name)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        return Entry(name: name, url: url, isDirectory: type == S_IFDIR, isSymbolicLink: type == S_IFLNK,
                     isRegularFile: type == S_IFREG)
    }

    enum ReadResult {
        case data(Data)
        case missing
        case tooLarge(Int64)
        case notAFile
    }

    /// The bytes of a regular file inside the root, at most `limit` of them; a link, a folder, a device or a file
    /// outside the root is refused.
    func read(_ url: URL, limit: Int = AppleDevReader.maxSmallFileBytes) -> ReadResult {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root.path + "/") else { return .notAFile }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .notAFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .notAFile }
        guard info.st_size <= Int64(limit) else { return .tooLarge(Int64(info.st_size)) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var total = 0
        while total < bytes.count {
            let n = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress! + total, buffer.count - total)
            }
            if n <= 0 { break }
            total += n
        }
        return .data(Data(bytes.prefix(total)))
    }

    /// The path of `url` relative to the root, for display.
    func relativePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : url.lastPathComponent
    }
}
