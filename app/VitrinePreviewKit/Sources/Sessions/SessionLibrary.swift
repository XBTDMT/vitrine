import Foundation

/// The menu bar's Agent Sessions list (parity H-5; design menubar.html "Agent Sessions submenu"): the recent Claude
/// Code and Codex sessions on this Mac with what they changed. Read-only and bounded: only transcripts modified in the
/// last `maxAge`, at most `maxSessions` per agent, each read from its first 8 MB (SessionLimits.menu), a capped
/// number of folder entries looked at. Nothing is written, nothing leaves the Mac. roadmap: S-11
///
/// Where it looks (the folders are settings; these are the documented defaults):
/// - Claude Code: `~/.claude/projects/<project>/<session>.jsonl` (one level of project folders), plus the
///   transcripts the session hook logged (ClaudeSessionHook), when tracking is on.
/// - Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` for the days in `maxAge`, plus files directly in the
///   folder (older Codex versions), when watching is on.
public struct SessionLibrary: Sendable {
    public struct Settings: Sendable, Equatable {
        public var tracksClaudeCode: Bool
        public var claudeFolder: URL
        public var hookLog: URL?
        public var watchesCodex: Bool
        public var codexFolder: URL
        public var maxAge: TimeInterval = 7 * 24 * 3600
        public var maxSessions = 5
        /// Folder entries looked at per agent before the scan stops.
        public var maxEntries = 4_000

        public init(tracksClaudeCode: Bool, claudeFolder: URL, hookLog: URL?, watchesCodex: Bool, codexFolder: URL) {
            self.tracksClaudeCode = tracksClaudeCode; self.claudeFolder = claudeFolder; self.hookLog = hookLog
            self.watchesCodex = watchesCodex; self.codexFolder = codexFolder
        }
    }

    /// The settings keys (VitrineDefaults.shared, written by Settings › Integrations; see SessionKeys).
    public enum Keys {
        public static let trackClaudeCode = "sessions.claudeCode.track"
        public static let claudeFolder = "sessions.claudeCode.folder"
        public static let watchCodex = "sessions.codex.watch"
        public static let codexFolder = "sessions.codex.folder"
    }

    public static func defaultClaudeFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }
    public static func defaultCodexFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }
    public static func hookLog(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(ClaudeSessionHook.logPath)
    }

    /// The settings from a defaults store: tracking is on when the key says so or the hook is installed.
    public static func settings(from defaults: UserDefaults, hookInstalled: Bool,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Settings {
        func folder(_ key: String, _ fallback: URL) -> URL {
            guard let s = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return fallback }
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true)
        }
        return Settings(tracksClaudeCode: defaults.bool(forKey: Keys.trackClaudeCode) || hookInstalled,
                        claudeFolder: folder(Keys.claudeFolder, defaultClaudeFolder(home: home)),
                        hookLog: hookLog(home: home),
                        watchesCodex: defaults.bool(forKey: Keys.watchCodex),
                        codexFolder: folder(Keys.codexFolder, defaultCodexFolder(home: home)))
    }

    /// One row of the submenu.
    public struct Summary: Sendable, Equatable {
        public var url: URL
        public var source: SessionSource
        public var title: String
        public var project: String?
        public var modified: Date
        public var turns: Int
        /// Files changed through edit tools, absolute where the transcript says so.
        public var changedFiles: [String]
        /// Only the start of a long transcript was read: the counts are at least these.
        public var isPartial: Bool

        /// "harbor-api · 46 turns · 7 files changed · 24 min" (the design's sub-line).
        public func subtitle(now: Date = Date()) -> String {
            var parts: [String] = []
            if let project { parts.append(project) }
            let turnCount = turns.formatted(), fileCount = changedFiles.count.formatted()
            switch (turns == 1, isPartial) {
            case (true, false): parts.append(String(localized: "\(turnCount) turn", bundle: .previewKit, comment: "Session list subtitle: one turn."))
            case (false, false): parts.append(String(localized: "\(turnCount) turns", bundle: .previewKit, comment: "Session list subtitle: how many turns."))
            case (true, true): parts.append(String(localized: "\(turnCount)+ turn", bundle: .previewKit, comment: "Session list subtitle: at least one turn (only the start of the file was read)."))
            case (false, true): parts.append(String(localized: "\(turnCount)+ turns", bundle: .previewKit, comment: "Session list subtitle: at least this many turns (only the start of the file was read)."))
            }
            if changedFiles.isEmpty {
                parts.append(String(localized: "no files changed", bundle: .previewKit, comment: "Session list subtitle: the session changed no files."))
            } else {
                switch (changedFiles.count == 1, isPartial) {
                case (true, false): parts.append(String(localized: "\(fileCount) file changed", bundle: .previewKit, comment: "Session list subtitle: one file changed."))
                case (false, false): parts.append(String(localized: "\(fileCount) files changed", bundle: .previewKit, comment: "Session list subtitle: how many files changed."))
                case (true, true): parts.append(String(localized: "\(fileCount)+ file changed", bundle: .previewKit, comment: "Session list subtitle: at least one file changed (only the start was read)."))
                case (false, true): parts.append(String(localized: "\(fileCount)+ files changed", bundle: .previewKit, comment: "Session list subtitle: at least this many files changed (only the start was read)."))
                }
            }
            parts.append(SessionLibrary.age(modified, now: now))
            return parts.joined(separator: " · ")
        }
    }

    public let settings: Settings
    public init(settings: Settings) { self.settings = settings }

    /// "just now", "24 min", "3 h", "Yesterday", "Oct 25".
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return String(localized: "just now", bundle: .previewKit, comment: "Session list: the session changed less than a minute ago.") }
        if s < 3600 {
            let minutes = Int(s / 60).formatted()
            return String(localized: "\(minutes) min", bundle: .previewKit, comment: "Session list: minutes since the session changed (abbreviated).")
        }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) {
            let hours = Int(s / 3600).formatted()
            return String(localized: "\(hours) h", bundle: .previewKit, comment: "Session list: hours since the session changed (abbreviated).")
        }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) {
            return String(localized: "Yesterday", bundle: .previewKit, comment: "Session list: the session last changed yesterday.")
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: Finding transcripts

    struct Candidate { let url: URL; let modified: Date }

    func recentFiles(_ source: SessionSource, now: Date) -> [Candidate] {
        let fm = FileManager.default
        let oldest = now.addingTimeInterval(-settings.maxAge)
        var visited = 0
        var found: [URL: Date] = [:]
        func consider(_ url: URL) {
            guard url.pathExtension.lowercased() == "jsonl" else { return }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let m = values.contentModificationDate, m >= oldest else { return }
            found[url.standardizedFileURL] = m
        }
        func list(_ folder: URL) -> [URL] {
            guard visited < settings.maxEntries else { return [] }
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            let take = Array(items.prefix(settings.maxEntries - visited))
            visited += take.count
            return take
        }
        func isFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }

        switch source {
        case .claudeCode:
            // Every project folder is listed: a folder's own date does not change when a session in it grows.
            for project in list(settings.claudeFolder) where isFolder(project) {
                for file in list(project) { consider(file) }
            }
            if let log = settings.hookLog {
                for path in ClaudeSessionHook.loggedTranscripts(log: log).suffix(200) where path.hasPrefix("/") {
                    consider(URL(fileURLWithPath: path))
                }
            }
        case .codex:
            let cal = Calendar(identifier: .gregorian)
            let days = Int((settings.maxAge / 86_400).rounded(.up))
            for d in 0...max(0, days) {
                guard let day = cal.date(byAdding: .day, value: -d, to: now) else { continue }
                let c = cal.dateComponents([.year, .month, .day], from: day)
                let folder = settings.codexFolder.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0), isDirectory: true)
                for file in list(folder) { consider(file) }
            }
            for file in list(settings.codexFolder) { consider(file) }
        }
        return found.map { Candidate(url: $0.key, modified: $0.value) }.sorted { $0.modified > $1.modified }
    }

    // MARK: Summaries

    /// The most recent sessions of one agent, newest first; empty when that agent is switched off.
    public func recent(_ source: SessionSource, now: Date = Date(), cache: SummaryCache? = nil) -> [Summary] {
        switch source {
        case .claudeCode: guard settings.tracksClaudeCode else { return [] }
        case .codex: guard settings.watchesCodex else { return [] }
        }
        var out: [Summary] = []
        for candidate in recentFiles(source, now: now).prefix(settings.maxSessions * 3) {
            guard out.count < settings.maxSessions else { break }
            if let s = cache?.summary(for: candidate.url, modified: candidate.modified) ?? Self.summary(candidate.url, modified: candidate.modified),
               s.source == source {
                cache?.store(s)
                out.append(s)
            }
        }
        return out
    }

    /// One transcript read for the menu; nil when it is not an agent session.
    public static func summary(_ url: URL, modified: Date) -> Summary? {
        guard let s = try? SessionParser.parse(url: url, limits: .menu) else { return nil }
        return Summary(url: url, source: s.source, title: s.title, project: s.project, modified: modified, turns: s.turns,
                       changedFiles: s.changedFiles, isPartial: !s.isComplete)
    }
}

/// Summaries kept between menu openings, keyed by file and modification date, so an unchanged transcript is not
/// read again.
public final class SummaryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL: SessionLibrary.Summary] = [:]
    public init() {}

    public func summary(for url: URL, modified: Date) -> SessionLibrary.Summary? {
        lock.lock(); defer { lock.unlock() }
        guard let s = items[url], s.modified == modified else { return nil }
        return s
    }

    public func store(_ s: SessionLibrary.Summary) {
        lock.lock(); defer { lock.unlock() }
        items[s.url] = s
        if items.count > 200 { items.removeAll() }
    }
}
