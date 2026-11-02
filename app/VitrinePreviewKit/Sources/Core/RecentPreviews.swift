import Foundation
import VitrineDocument
import VitrineSupport

/// The files Vitrine previewed last, newest first, for the menu bar's Recent Previews (H-2). roadmap: S-10
///
/// Written by the sandboxed Quick Look extensions (`PreviewHostController.embed` calls `recordShown`), each into a
/// file in its own container (G-19 route B: there is no shared container), and read by the host app's menu, which
/// merges every extension's file; Clear and Forget reach all of them. What is kept, and only this: the file's path, the
/// kind's name, a facts line built from counts alone (allowlisted keys, digits and size units only), and the time.
/// Never a byte of the file. The list is capped at `capacity`; the person can pause recording and clear it.
public struct RecentPreviews: Sendable {
    /// The defaults key the first version used; never published between the app and the extensions.
    public static let entriesKey = "general.recentPreviews"
    /// Each extension's list, in its container's `Application Support/Vitrine`.
    public static let fileName = "recents.json"
    /// Bool, default true. False pauses recording; what is already kept stays until cleared.
    public static let recordingKey = "general.recordRecents"
    /// The menu shows five rows (⌘1–⌘5) and the rest of the ten under More Recent Previews.
    public static let capacity = 10

    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        /// The kind as people name it: "Markdown", "CSV", "Zip archive".
        public var kind: String
        /// "Markdown · 412 lines · ≈ 3,201 tokens": the kind, then at most two counts.
        public var facts: String
        public var time: Date

        public var url: URL { URL(fileURLWithPath: path) }
        public var name: String { url.lastPathComponent }

        public init(path: String, kind: String, facts: String, time: Date) {
            self.path = path; self.kind = kind; self.facts = facts; self.time = time
        }
    }

    /// Every folder whose list is read (the app: all its extensions'; an extension: its own).
    private let directories: [URL]
    /// Where `record` writes; nil in the app, which never records.
    private let writeDirectory: URL?
    private let suite: String?
    private var defaults: UserDefaults { VitrineDefaults.defaults(suite: suite) }

    public init(directories: [URL], writeDirectory: URL?, suite: String? = VitrineDefaults.suiteName) {
        self.directories = directories
        self.writeDirectory = writeDirectory
        self.suite = suite
    }

    /// The host app's view: every extension's list.
    public static func forApp() -> RecentPreviews {
        RecentPreviews(directories: ContainerBridge.extensions().map(\.supportDirectory), writeDirectory: nil)
    }

    /// An extension's own list, in its container.
    public static func forExtension() -> RecentPreviews {
        RecentPreviews(directories: [ContainerBridge.ownDirectory], writeDirectory: ContainerBridge.ownDirectory)
    }

    private static func read(_ directory: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func write(_ list: [Entry], to directory: URL) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    // MARK: Reading

    /// Newest first, at most `capacity`. An unreadable or foreign value reads as empty, never as a crash.
    public func entries() -> [Entry] {
        var newest: [String: Entry] = [:]
        for entry in directories.flatMap(Self.read) where (newest[entry.path]?.time ?? .distantPast) < entry.time {
            newest[entry.path] = entry
        }
        return Array(newest.values.sorted { $0.time > $1.time }.prefix(Self.capacity))
    }

    /// The entries whose file is still there (the host app is not sandboxed and can look); a moved or deleted file
    /// drops out of the menu but is not erased from the list, so a file that comes back reappears.
    public func existingEntries(fileManager: FileManager = .default) -> [Entry] {
        entries().filter { fileManager.fileExists(atPath: $0.path) }
    }

    public var isRecording: Bool {
        get { defaults.object(forKey: Self.recordingKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.recordingKey) }
    }

    // MARK: Writing

    /// Puts the file at the top; a file already in the list moves up rather than appearing twice. Does nothing while
    /// recording is paused. Paths are standardized so `/a/./b` and `/a/b` are one entry.
    public func record(_ url: URL, kind: String, facts: String, at time: Date = Date()) {
        guard isRecording, url.isFileURL, let writeDirectory else { return }
        let path = url.standardizedFileURL.path
        var list = Self.read(writeDirectory).filter { $0.path != path }
        list.insert(Entry(path: path, kind: kind, facts: facts, time: time), at: 0)
        if list.count > Self.capacity { list.removeLast(list.count - Self.capacity) }
        Self.write(list, to: writeDirectory)
    }

    public func record(_ url: URL, document: PreviewDocument, at time: Date = Date()) {
        record(url, kind: document.kind.displayName, facts: Self.factsLine(for: document), at: time)
    }

    /// Removes one file from the list (the menu shows it no more).
    public func forget(path: String) {
        for directory in allDirectories {
            let list = Self.read(directory)
            if list.contains(where: { $0.path == path }) { Self.write(list.filter { $0.path != path }, to: directory) }
        }
    }

    public func clear() {
        for directory in allDirectories {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.fileName))
        }
    }

    private var allDirectories: [URL] { Array(Set(directories + [writeDirectory].compactMap { $0 })) }

    // MARK: The facts line

    /// Count facts the line may carry, in the order it prefers them.
    static let countKeys = ["rows", "lines", "files", "items", "tokens"]

    /// "412 lines": one count as a whole localized phrase (H-6). The value arrives formatted ("12,480", "≈ 3,201").
    static func countPhrase(_ key: String, _ value: String) -> String? {
        switch key {
        case "rows": String(localized: "\(value) rows", bundle: .previewKit, comment: "Recent Previews menu: a table's row count; the number arrives formatted.")
        case "lines": String(localized: "\(value) lines", bundle: .previewKit, comment: "Recent Previews menu: a file's line count; the number arrives formatted.")
        case "files": String(localized: "\(value) files", bundle: .previewKit, comment: "Recent Previews menu: how many files; the number arrives formatted.")
        case "items": String(localized: "\(value) items", bundle: .previewKit, comment: "Recent Previews menu: how many items; the number arrives formatted.")
        case "tokens": String(localized: "\(value) tokens", bundle: .previewKit, comment: "Recent Previews menu: the approximate token count, formatted.")
        default: nil
        }
    }

    /// The kind, then up to two counts from the allowlist, else the size. A value is kept only if it is a number
    /// (digits, separators, an approximate sign, a size unit), so a renderer that one day puts words from the file
    /// into a fact never leaks them here.
    public static func factsLine(for document: PreviewDocument) -> String {
        var parts = [document.kind.displayName]
        var counts: [String] = []
        for key in countKeys where counts.count < 2 {
            if let value = document.fact(key)?.value, isCount(value), let phrase = countPhrase(key, value) { counts.append(phrase) }
        }
        if counts.isEmpty, let size = document.fact("size")?.value, isSize(size) { counts.append(size) }
        parts += counts
        return parts.joined(separator: " · ")
    }

    static func isCount(_ value: String) -> Bool {
        value.range(of: #"^(≈ ?)?[0-9][0-9,.\u{00A0}\u{202F} ]*\+?$"#, options: .regularExpression) != nil
    }

    /// A size as ByteCountFormatter writes it in any language: a number, a space, a unit of at most six letters
    /// ("3 KB", "1,2 Mo", "12 バイト"). A size in words ("Zero KB") is still refused.
    static func isSize(_ value: String) -> Bool {
        value.range(of: #"^[0-9][0-9,.\u{00A0}\u{202F}]*[ \u{00A0}\u{202F}]\p{L}{1,6}$"#, options: .regularExpression) != nil
    }

    // MARK: The process's recorder

    /// Who records in this process; nil records nothing. Only tests set it (a store on a private suite).
    ///
    /// Only the extensions record, each into its own container (G-19 route B: the shared suite cannot be written
    /// there); the app, `--snapshot`, compares and the tests do not.
    @MainActor public static var processRecorder: RecentPreviews? =
        ContainerBridge.isQuickLookExtension() ? RecentPreviews.forExtension() : nil

    /// Called once per embedded preview by `PreviewHostController`.
    @MainActor public static func recordShown(_ url: URL?, document: PreviewDocument) {
        guard let url, let recorder = processRecorder else { return }
        recorder.record(url, document: document)
    }

    /// A Quick Look preview runs in an `.appex` bundle inside the host app's PlugIns folder.
    public static func isQuickLookExtension(bundlePath: String) -> Bool { ContainerBridge.isQuickLookExtension(bundlePath: bundlePath) }
}
