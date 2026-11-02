import Foundation
import VitrineArchive

/// Where vulnerability hints live and whether they are on (G-26): one index file per OSV ecosystem in the app group's
/// container, written by the host app's updater and read by the previews. Off until the person turns it on and picks
/// ecosystems in Settings › Privacy; nothing here touches the network. roadmap: S-22
public enum AdvisoryStore {
    public static let suite = "MPD7MLYSRW.io.github.xbtdmt.vitrine"
    public static let enabledKey = "advisories.enabled"
    public static let weeklyKey = "advisories.weekly"
    /// `advisories.eco.<OSV name>` — a Bool per ecosystem.
    public static func ecosystemKey(_ e: OSVEcosystem) -> String { "advisories.eco." + e.rawValue }

    /// The ecosystems Settings offers: the ones the lockfile reader can match (Pub and Hex have no lockfile reader yet).
    public static let offered: [OSVEcosystem] = [.npm, .pypi, .crates, .go, .rubygems, .packagist, .swiftURL]

    /// Tests point the store at a folder of their own.
    nonisolated(unsafe) public static var directoryOverride: URL?

    public static var directory: URL? {
        if let directoryOverride { return directoryOverride }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suite)?
            .appendingPathComponent("Library/Application Support/Vitrine/Advisories", isDirectory: true)
    }

    public static func indexURL(_ e: OSVEcosystem) -> URL? { directory?.appendingPathComponent(e.rawValue + ".vitrine-advisories") }

    static var defaults: UserDefaults? { UserDefaults(suiteName: suite) }
    public static var isEnabled: Bool { defaults?.bool(forKey: enabledKey) ?? false }
    public static func isChosen(_ e: OSVEcosystem) -> Bool { defaults?.bool(forKey: ecosystemKey(e)) ?? false }

    /// The installed index for an ecosystem, or nil (off, not chosen, not downloaded, or unreadable).
    public static func index(for e: OSVEcosystem) -> AdvisoryIndex? {
        guard isEnabled || directoryOverride != nil, let url = indexURL(e), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? AdvisoryIndex.read(from: url)
    }

    /// Every record in an OSV `<ECOSYSTEM>/all.zip`, read one member at a time (the zip is never held whole), into
    /// an index. The host app calls it after a download; tests call it on a zip they make.
    public static func buildIndex(_ e: OSVEcosystem, zip: URL, lastModified: Date?) throws -> AdvisoryIndex {
        let source = try FileByteSource(url: zip)
        let limits = ArchiveLimits(maxEntries: 2_000_000, maxDecompressedBytes: 1 << 20, timeBudget: 3_600)
        let listing = try VitrineArchive.list(source: source, fileName: "all.zip", limits: limits)
        let records = listing.entries.indices.lazy.compactMap { i -> Data? in
            guard listing.entries[i].path.hasSuffix(".json"),
                  let member = try? VitrineArchive.memberData(source: source, fileName: "all.zip", listing: listing, entryIndex: i,
                                                              limit: 1 << 20, limits: limits), member.isComplete else { return nil }
            return Data(member.bytes)
        }
        return AdvisoryIndex.build(ecosystem: e, records: records, sourceLastModified: lastModified)
    }

    /// What a lockfile card can say about advisories for one ecosystem.
    public enum Coverage: Sendable, Equatable {
        case off                              // hints are switched off
        case unsupported                      // OSV has no feed for it (CocoaPods)
        case notDownloaded(OSVEcosystem)      // on, but this ecosystem's database is not installed
        case checked(AdvisoryIndex.Meta, [AdvisoryMatch])
    }

    public static func coverage(for summary: LockfileSummary) -> Coverage {
        guard isEnabled || directoryOverride != nil else { return .off }
        guard let e = OSVEcosystem.forLockfile(summary.ecosystem) else { return .unsupported }
        guard let index = index(for: e) else { return .notDownloaded(e) }
        return .checked(index.meta, index.matches(summary))
    }
}
