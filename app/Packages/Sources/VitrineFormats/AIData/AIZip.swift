import Foundation
import VitrineArchive

/// Zip access for the readers whose files are zips (`.npz`, Inspect `.eval`), through VitrineArchive's in-memory
/// reader: the listing comes from the central directory, members are inflated into memory up to a limit.
enum AIZip {
    /// A tighter listing than an archive preview's: these files hold a handful of members.
    static let limits = ArchiveLimits(maxEntries: 20_000, maxDecompressedBytes: 64 * 1024 * 1024, timeBudget: 3)

    static func listing(_ bytes: [UInt8]) -> ArchiveListing? {
        guard let listing = try? ZipReader.list(source: DataByteSource(bytes), limits: limits),
              listing.format == .zip else { return nil }
        return listing
    }

    /// The first `limit` bytes of the member at `index`, or nil when it cannot be read (encrypted, damaged, an
    /// unsupported method).
    static func member(_ bytes: [UInt8], listing: ArchiveListing, index: Int, limit: Int) -> MemberData? {
        try? VitrineArchive.memberData(source: DataByteSource(bytes), listing: listing, entryIndex: index,
                                       limit: limit, limits: limits)
    }

    /// The member named `path` (the last of that name), or nil.
    static func member(_ bytes: [UInt8], listing: ArchiveListing, path: String, limit: Int) -> MemberData? {
        guard let index = listing.entries.lastIndex(where: { $0.path == path && !$0.isDirectory }) else { return nil }
        return member(bytes, listing: listing, index: index, limit: limit)
    }
}
