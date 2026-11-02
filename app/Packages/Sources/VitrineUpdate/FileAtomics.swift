public import Foundation

/// Atomic, permission-controlled file writes. Every byte the engine persists goes through here.
public enum FileAtomics {
    public enum Mode: Sendable {
        /// Private to the user: 0700 directories, 0600 files.
        case privateToUser
        /// Whatever the umask gives; used only for files the user already owns and expects to share.
        case `default`
    }

    /// Writes `data` to `url` atomically (temp file in the same directory + rename) and sets the mode.
    public static func write(_ data: Data, to url: URL, mode: Mode) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: mode == .privateToUser ? [.posixPermissions: 0o700] : nil)
        try data.write(to: url, options: [.atomic])
        if mode == .privateToUser {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Replaces the file at `target` with `data` using FileManager.replaceItemAt; the temp file lives in the same
    /// directory so the rename is atomic. The new file takes the new item's metadata (`.usingNewMetadataOnly`), so the
    /// target's Finder tags are carried over explicitly: a person's own tags survive every cover and undo (G-24).
    public static func replace(contentsOf target: URL, with data: Data) throws {
        let dir = target.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".vitrine-\(UUID().uuidString).tmp")
        let tags = (try? target.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        try data.write(to: temp, options: [.atomic])
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp, backupItemName: nil, options: [.usingNewMetadataOnly])
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        if !tags.isEmpty { try setTagNames(tags, on: target) }
    }

    /// Sets a file's Finder tags. `URLResourceValues.tagNames` is settable only from macOS 26, so this goes through
    /// NSURL's resource value, which writes the same attribute on every macOS Vitrine supports.
    public static func setTagNames(_ tags: [String], on url: URL) throws {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    /// Creates a directory private to the user (0700), including intermediates.
    public static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
