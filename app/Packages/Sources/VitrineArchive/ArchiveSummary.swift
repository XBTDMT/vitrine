import Foundation

/// The facts a preview's header shows for an archive: how much is inside and how it is laid out. Folders count
/// whether the archive stores them or only implies them through member paths, because that is what extraction
/// creates.
public struct ArchiveSummary: Sendable, Equatable {
    public var entryCount: Int
    public var fileCount: Int
    /// Distinct folders, stored or implied by paths.
    public var folderCount: Int
    public var symlinkCount: Int
    /// Hard links, devices, pipes and other kinds.
    public var otherCount: Int
    public var totalUncompressedSize: Int64
    /// Sum of known compressed sizes (zip, gzip); nil for tar.
    public var totalCompressedSize: Int64?
    /// The biggest files by uncompressed size, largest first.
    public var largestEntries: [ArchiveEntry]
    /// Names at the top of the archive that are folders, sorted as the tree sorts them.
    public var topLevelFolders: [String]
    /// Names at the top of the archive that are not folders.
    public var topLevelFiles: [String]
    /// The one folder everything lives in, when there is one (macOS resource-fork folders `__MACOSX` aside):
    /// "extracts into a folder" versus "spills into the current folder".
    public var singleTopFolder: String?
    /// Entries under `__MACOSX/`: AppleDouble resource forks added by Archive Utility.
    public var appleDoubleCount: Int

    public static let resourceForkFolder = "__MACOSX"

    public init(_ listing: ArchiveListing, largestCount: Int = 5) {
        let entries = listing.entries
        entryCount = entries.count
        var files = 0, links = 0, others = 0, appleDouble = 0
        var total: Int64 = 0
        var compressed: Int64 = 0, sawCompressed = false
        var folders: [[String: Int]] = [[:]]                 // node 0 is the root
        var topFolders: Set<String> = [], topFiles: Set<String> = []

        for entry in entries {
            let parts = ArchivePath.components(entry.path)
            guard let top = parts.first else { continue }
            if top == Self.resourceForkFolder { appleDouble += 1 }
            let isFolder = entry.type == .directory
            // Folders are counted in a trie of segments, never as joined prefixes, so a deep name costs its length.
            var node = 0
            for segment in isFolder ? parts[...] : parts.dropLast() {
                if let next = folders[node][segment] {
                    node = next
                } else {
                    folders.append([:])
                    folders[node][segment] = folders.count - 1
                    node = folders.count - 1
                }
            }
            if parts.count > 1 || isFolder { topFolders.insert(top) } else { topFiles.insert(top) }
            switch entry.type {
            case .file: files += 1
            case .directory: break
            case .symlink: links += 1
            default: others += 1
            }
            if let size = entry.uncompressedSize, size > 0 {
                let (sum, overflow) = total.addingReportingOverflow(size)
                total = overflow ? .max : sum
            }
            if let c = entry.compressedSize {
                sawCompressed = true
                let (sum, overflow) = compressed.addingReportingOverflow(c)
                compressed = overflow ? .max : sum
            }
        }
        fileCount = files
        folderCount = folders.count - 1
        symlinkCount = links
        otherCount = others
        totalUncompressedSize = total
        totalCompressedSize = sawCompressed ? compressed : nil
        appleDoubleCount = appleDouble

        largestEntries = Array(entries.enumerated()
            .filter { $0.element.type == .file }
            .sorted { ($0.element.uncompressedSize ?? 0, $1.offset) > ($1.element.uncompressedSize ?? 0, $0.offset) }
            .prefix(max(0, largestCount))
            .map(\.element))
        topLevelFolders = topFolders.sorted(by: ArchiveTree.nameOrder)
        topLevelFiles = topFiles.subtracting(topFolders).sorted(by: ArchiveTree.nameOrder)
        let meaningful = topLevelFolders.filter { $0 != Self.resourceForkFolder }
        singleTopFolder = meaningful.count == 1 && topLevelFiles.isEmpty ? meaningful[0] : nil
    }
}
