import os
import Foundation

/// Remembers where the user was in a file, per path, so reopening a long document lands at the last position.
/// Persists through the shared app-group defaults so every extension and the host app see one table.
public struct ScrollMemory: Sendable {
    public static let defaultsKey = "general.scrollPositions"
    public static let limit = 500

    private let suite: String?
    private var defaults: UserDefaults { VitrineDefaults.defaults(suite: suite) }

    public init(suite: String? = VitrineDefaults.suiteName) { self.suite = suite }

    public func position(for url: URL) -> Double? {
        (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double])?[url.path]
    }

    public func remember(_ y: Double, for url: URL) {
        var table = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double]) ?? [:]
        table[url.path] = y
        if table.count > Self.limit {
            // Drop arbitrary entries past the cap; a bounded table beats an ever-growing plist.
            for key in table.keys.prefix(table.count - Self.limit) { table.removeValue(forKey: key) }
        }
        defaults.set(table, forKey: Self.defaultsKey)
    }
}

/// The one UserDefaults every Vitrine process reads: the app-group suite shared by the host app and all extensions.
/// `UserDefaults` is thread-safe but not marked Sendable, so values carry the suite name and resolve the object
/// where they use it; Foundation caches suites, so this costs nothing.
public enum VitrineDefaults {
    public static let suiteName = "MPD7MLYSRW.io.github.xbtdmt.vitrine"
    public static var shared: UserDefaults { defaults(suite: suiteName) }
    public static func defaults(suite: String?) -> UserDefaults {
        if suite == suiteName, let layered = extensionDefaults { return layered }
        return suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// In a Quick Look extension the shared suite cannot be written (no app-group container, G-19): its settings are
    /// the app's snapshot in its own container with its own changes layered over them (LayeredDefaults).
    /// `nonisolated(unsafe)`: an immutable reference to one LayeredDefaults, which guards its own state with a lock
    /// (SharedSettings.swift); Release's whole-module build would otherwise refuse the optional subclass of UserDefaults.
    nonisolated(unsafe) static let extensionDefaults: LayeredDefaults? = {
        let isExtension = ContainerBridge.isQuickLookExtension()
        let made = isExtension
            ? LayeredDefaults(snapshotURL: ContainerBridge.ownDirectory.appendingPathComponent(SettingsSnapshot.fileName), localSuite: nil)
            : nil
        Logger(subsystem: "io.github.xbtdmt.vitrine", category: "settings").info(
            "layered settings: extension \(isExtension, privacy: .public), made \(made != nil, privacy: .public), bundle \(Bundle.main.bundleURL.lastPathComponent, privacy: .public)")
        return made
    }()
}
