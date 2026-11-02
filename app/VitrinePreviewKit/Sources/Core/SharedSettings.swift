import Foundation

/// How the app and its sandboxed Quick Look extensions share data (G-19 route B, measured by SP-2 on 2026-10-30):
/// macOS gives the extensions no app-group container under this signing, so every write to a shared suite is
/// refused. Instead each extension's own container is the meeting place: an extension writes only inside its own
/// container (always allowed), and the unsandboxed host app reads and writes there. roadmap: S-10
public enum ContainerBridge {
    /// Vitrine's folder in this process's Application Support: inside its own container in an extension,
    /// `~/Library/Application Support/Vitrine` in the host app.
    public static var ownDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("Vitrine", isDirectory: true)
    }

    /// Whether this process is one of the Quick Look extensions (an `.appex` in the app's PlugIns folder).
    public static func isQuickLookExtension(bundlePath: String = Bundle.main.bundlePath) -> Bool {
        URL(fileURLWithPath: bundlePath).pathExtension == "appex"
    }

    /// One extension's folders, as the host app sees them from outside.
    public struct Extension: Sendable, Equatable {
        public let id: String
        /// Its `Application Support/Vitrine`, where the app leaves the settings snapshot and the extension its recents.
        public let supportDirectory: URL
        /// Its own preferences file, where the changes it makes itself land.
        public let preferencesFile: URL

        public init(id: String, containerData: URL) {
            self.id = id
            supportDirectory = containerData.appendingPathComponent("Library/Application Support/Vitrine", isDirectory: true)
            preferencesFile = containerData.appendingPathComponent("Library/Preferences/\(id).plist")
        }
    }

    /// The app's extensions, by the bundle ids in its PlugIns folder, with their containers under `home`.
    public static func extensions(of app: URL = Bundle.main.bundleURL,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Extension] {
        let plugins = app.appendingPathComponent("Contents/PlugIns")
        let bundles = (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
        return bundles.filter { $0.pathExtension == "appex" }.compactMap { Bundle(url: $0)?.bundleIdentifier }.sorted().map { id in
            Extension(id: id, containerData: home.appendingPathComponent("Library/Containers/\(id)/Data", isDirectory: true))
        }
    }
}

/// The app's settings as one file it writes into every extension's container: each value with the time it last
/// changed, so a change made inside an extension and one made in the app are ordered by when they happened.
public struct SettingsSnapshot: Equatable {
    public static let fileName = "app-settings.plist"
    public var values: [String: Any]
    public var times: [String: Double]

    public init(values: [String: Any] = [:], times: [String: Double] = [:]) { self.values = values; self.times = times }

    public static func == (a: SettingsSnapshot, b: SettingsSnapshot) -> Bool {
        a.times == b.times && NSDictionary(dictionary: a.values).isEqual(to: b.values)
    }

    public static func read(_ url: URL) -> SettingsSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return SettingsSnapshot(values: plist["values"] as? [String: Any] ?? [:], times: plist["times"] as? [String: Double] ?? [:])
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["values": values, "times": times], format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }
}

/// An extension's settings: what it changed itself (its own preferences, inside its container, where writes are
/// allowed) layered over the app's snapshot, the newer of the two winning key by key. Every write records when it
/// happened (`changedPrefix + key`), so the app can fold the change back and pass it on. roadmap: S-10
public final class LayeredDefaults: UserDefaults, @unchecked Sendable {
    public static let changedPrefix = "vitrine.changed."
    private let snapshotURL: URL
    private let lock = NSLock()
    private var snapshot = SettingsSnapshot()
    private var snapshotStamp: Date?
    private var checkedAt = Date.distantPast

    /// `localSuite` nil is this process's own domain (an extension's lives in its container).
    public init?(snapshotURL: URL, localSuite: String?) {
        self.snapshotURL = snapshotURL
        super.init(suiteName: localSuite)
    }

    /// The app's snapshot, read again when the file changed (checked at most twice a second).
    private func current() -> SettingsSnapshot {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(checkedAt) > 0.5 {
            checkedAt = now
            // Read fresh: a URL caches its resource values, which would hide the app's next snapshot.
            let stamp = (try? FileManager.default.attributesOfItem(atPath: snapshotURL.path))?[.modificationDate] as? Date
            if stamp != snapshotStamp {
                snapshotStamp = stamp
                snapshot = stamp == nil ? SettingsSnapshot() : (SettingsSnapshot.read(snapshotURL) ?? SettingsSnapshot())
            }
        }
        return snapshot
    }

    public override func object(forKey key: String) -> Any? {
        let shared = current()
        let localTime = super.object(forKey: Self.changedPrefix + key) as? Double
        if let localTime, localTime >= (shared.times[key] ?? -.infinity), let local = super.object(forKey: key) { return local }
        if let value = shared.values[key] { return value }
        return super.object(forKey: key)
    }

    public override func set(_ value: Any?, forKey key: String) {
        super.set(value, forKey: key)
        // As an object: Foundation's typed setters call back into `set(_:forKey:)` on self, which would loop.
        super.set(NSNumber(value: Date().timeIntervalSince1970) as Any?, forKey: Self.changedPrefix + key)
    }
    public override func set(_ value: Int, forKey key: String) { set(value as Any?, forKey: key) }
    public override func set(_ value: Float, forKey key: String) { set(value as Any?, forKey: key) }
    public override func set(_ value: Double, forKey key: String) { set(value as Any?, forKey: key) }
    public override func set(_ value: Bool, forKey key: String) { set(value as Any?, forKey: key) }
    public override func set(_ url: URL?, forKey key: String) { set(url?.absoluteString as Any?, forKey: key) }

    /// Drops this extension's own value, so the app's applies again.
    public override func removeObject(forKey key: String) {
        super.removeObject(forKey: key)
        super.removeObject(forKey: Self.changedPrefix + key)
    }

    // The typed readers go through `object(forKey:)`, so they see the layers too.
    public override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    public override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    public override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    public override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    public override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    public override func integer(forKey key: String) -> Int { Self.number(object(forKey: key))?.intValue ?? 0 }
    public override func float(forKey key: String) -> Float { Self.number(object(forKey: key))?.floatValue ?? 0 }
    public override func double(forKey key: String) -> Double { Self.number(object(forKey: key))?.doubleValue ?? 0 }
    public override func bool(forKey key: String) -> Bool {
        if let s = object(forKey: key) as? String { return ["yes", "true", "1"].contains(s.lowercased()) }
        return Self.number(object(forKey: key))?.boolValue ?? false
    }
    public override func url(forKey key: String) -> URL? {
        if let u = object(forKey: key) as? URL { return u }
        return (object(forKey: key) as? String).flatMap { URL(string: $0) }
    }

    private static func number(_ value: Any?) -> NSNumber? {
        if let n = value as? NSNumber { return n }
        if let s = value as? String, let d = Double(s) { return NSNumber(value: d) }
        return nil
    }
}

/// The host app's half: publishes its settings into every extension's container, and folds back the changes the
/// extensions made themselves (newest wins), so a choice made in one preview reaches the others and the Settings
/// window. Keys that are one extension's own state (scroll positions) stay where they are. roadmap: S-10
@MainActor
public final class SettingsBridge {
    public static let shared = SettingsBridge(master: VitrineDefaults.shared, domain: VitrineDefaults.suiteName,
                                              extensions: ContainerBridge.extensions(), stateDirectory: ContainerBridge.ownDirectory)

    /// Never published or folded back: per-extension state, and the change stamps themselves.
    public static let localOnlyKeys: Set<String> = [ScrollMemory.defaultsKey, RecentPreviews.entriesKey]

    private let master: UserDefaults
    private let domain: String
    private let extensions: [ContainerBridge.Extension]
    private let timesURL: URL
    private let publishedURL: URL
    private var observer: NSObjectProtocol?
    private var pending: [String: DispatchWorkItem] = [:]
    private var stream: FSEventStreamRef?

    public init(master: UserDefaults, domain: String, extensions: [ContainerBridge.Extension], stateDirectory: URL) {
        self.master = master
        self.domain = domain
        self.extensions = extensions
        timesURL = stateDirectory.appendingPathComponent("settings-times.plist")
        publishedURL = stateDirectory.appendingPathComponent("settings-published.plist")
    }

    static func shareable(_ key: String) -> Bool {
        !localOnlyKeys.contains(key) && !key.hasPrefix(LayeredDefaults.changedPrefix)
    }

    /// The app's settings now, without per-extension state.
    private func masterValues() -> [String: Any] {
        (master.persistentDomain(forName: domain) ?? [:]).filter { Self.shareable($0.key) }
    }

    /// Writes the snapshot into every extension's container. A key that changed since the last publish gets the time
    /// now, or the time the extension made it when it came from `collect`.
    @discardableResult
    public func publish(changeTimes given: [String: Double] = [:], now: Double = Date().timeIntervalSince1970) -> SettingsSnapshot {
        let values = masterValues()
        let previous = SettingsSnapshot.read(publishedURL) ?? SettingsSnapshot()
        var times = SettingsSnapshot.read(timesURL)?.times ?? previous.times
        for key in Set(values.keys).union(previous.values.keys) {
            let before = previous.values[key].map { NSDictionary(dictionary: ["v": $0]) }
            let after = values[key].map { NSDictionary(dictionary: ["v": $0]) }
            if before != after || times[key] == nil { times[key] = given[key] ?? now }
        }
        let snapshot = SettingsSnapshot(values: values, times: times.filter { values[$0.key] != nil || previous.values[$0.key] != nil })
        for ext in extensions {
            try? snapshot.write(to: ext.supportDirectory.appendingPathComponent(SettingsSnapshot.fileName))
        }
        try? SettingsSnapshot(times: snapshot.times).write(to: timesURL)
        try? SettingsSnapshot(values: values, times: snapshot.times).write(to: publishedURL)
        return snapshot
    }

    /// Folds every extension's own newer changes into the app's settings, then publishes. Returns the keys taken.
    @discardableResult
    public func collect() -> [String] {
        var times = SettingsSnapshot.read(timesURL)?.times ?? [:]
        var taken: [String: Double] = [:]
        for ext in extensions {
            guard let data = try? Data(contentsOf: ext.preferencesFile),
                  let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            for (stamp, time) in prefs where stamp.hasPrefix(LayeredDefaults.changedPrefix) {
                let key = String(stamp.dropFirst(LayeredDefaults.changedPrefix.count))
                guard Self.shareable(key), let time = time as? Double, time > (times[key] ?? 0), time > (taken[key] ?? 0) else { continue }
                if let value = prefs[key] { master.set(value, forKey: key) } else { master.removeObject(forKey: key) }
                taken[key] = time
                times[key] = time
            }
        }
        publish(changeTimes: taken)
        return taken.keys.sorted()
    }

    /// While the app runs: publish when its settings change, collect when an extension's preferences change.
    public func start() {
        collect()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule("publish") { $0.publish() } }
        }
        let folders = extensions.map { $0.preferencesFile.deletingLastPathComponent().path }
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let bridge = Unmanaged<SettingsBridge>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in bridge.schedule("collect") { $0.collect() } }
        }
        if let s = FSEventStreamCreate(nil, callback, &context, folders as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                       FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) {
            FSEventStreamSetDispatchQueue(s, .main)
            FSEventStreamStart(s)
            stream = s
        }
    }

    /// Runs `work` once after a short quiet spell; a publish and a collect are debounced separately.
    private func schedule(_ name: String, _ work: @escaping @MainActor (SettingsBridge) -> Void) {
        pending[name]?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if let self { work(self) } } }
        pending[name] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
}
