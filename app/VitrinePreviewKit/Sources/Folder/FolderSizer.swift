import Foundation
import UniformTypeIdentifiers

/// What the background count has found so far in one folder (N-10): bytes and items under each top-level folder,
/// bytes and counts by kind, and the totals. While it runs, or after it stopped at its budget, every number is a
/// floor and the views say "at least" or "so far". roadmap: S-9
struct FolderSizes: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var bytes: Int64 = 0
        var items = 0
        /// Every item under it was counted.
        var complete = false
    }

    /// Top-level folder or package name → what is inside it.
    var children: [String: Entry] = [:]
    /// Kind token (`kind-image`) → bytes and how many files or packages, at every depth.
    var byKind: [String: Entry] = [:]
    var totalBytes: Int64 = 0
    /// Every item below the folder, folders and hidden items included.
    var totalItems = 0
    /// The count ended: it reached the end, or its budget, or was cancelled.
    var finished = false
    /// It ended having counted everything.
    var complete = false

    /// The totals are floors (still counting, stopped at the budget, or cancelled).
    var isFloor: Bool { !complete }
}

/// Counts a folder's bytes in the background, bounded by items and time, cancellable, never following links and
/// never opening a file (iCloud placeholders report their size without downloading). Sizes are the files' own sizes,
/// as Finder's Size column shows them; a file with several hard links counts its bytes once. roadmap: S-9
enum FolderSizer {
    struct Budget: Sendable {
        var maxItems = 250_000
        var time: Duration = .seconds(8)
        /// How often a snapshot goes out while counting.
        var reportEvery = 4_096
    }

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .isSymbolicLinkKey, .linkCountKey, .fileResourceIdentifierKey]

    /// The folder's kind token for one item: the browse kinds (G19) with disk images and apps told apart.
    static func kindToken(name: String, isPackage: Bool) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["dmg", "iso", "sparseimage", "sparsebundle", "img", "cdr"].contains(ext) { return "kind-disk" }
        if isPackage, ext == "app" || UTType(filenameExtension: ext)?.conforms(to: .applicationBundle) == true { return "kind-app" }
        return baseToken(ext)
    }

    /// The words for a kind token in the overview's legend.
    static func kindName(_ token: String) -> String {
        switch token {
        case "kind-disk": String(localized: "Disk images", bundle: .previewKit, comment: "Storage overview legend: a kind of file.")
        case "kind-media": String(localized: "Media", bundle: .previewKit, comment: "Storage overview legend: a kind of file.")
        case "kind-archive": String(localized: "Archives", bundle: .previewKit, comment: "Storage overview legend: a kind of file.")
        case "kind-app": String(localized: "Apps", bundle: .previewKit, comment: "Storage overview legend: a kind of file.")
        case "kind-text": String(localized: "Documents", bundle: .previewKit, comment: "Storage overview legend: a kind of file.")
        case "kind-image": String(localized: "Images", bundle: .previewKit, comment: "Storage overview legend: a kind of file.")
        case "kind-code": String(localized: "Code", bundle: .previewKit, comment: "Storage overview legend: a kind of file.")
        case "kind-data": String(localized: "Data", bundle: .previewKit, comment: "Storage overview legend: a kind of file.")
        case "kind-ai": String(localized: "AI files", bundle: .previewKit, comment: "Storage overview legend: a kind of file.")
        default: String(localized: "Other", bundle: .previewKit, comment: "Storage overview legend: a kind of file.")
        }
    }

    static func measure(_ root: URL, budget: Budget = Budget(), isCancelled: () -> Bool = { false },
                        progress: (FolderSizes) -> Void = { _ in }) -> FolderSizes {
        var sizes = FolderSizes()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget.time)
        var stopped = false
        var sinceReport = 0

        func tick() -> Bool {
            sizes.totalItems += 1
            sinceReport += 1
            if sizes.totalItems > budget.maxItems { stopped = true }
            if sizes.totalItems % 256 == 0, clock.now > deadline || isCancelled() { stopped = true }
            if sinceReport >= budget.reportEvery { sinceReport = 0; progress(sizes) }
            return !stopped
        }

        // Files reached again through another hard link: their bytes are already counted.
        var linked = Set<NSObject>()
        func bytes(_ v: URLResourceValues?) -> Int64 {
            let size = Int64(v?.fileSize ?? 0)
            guard (v?.linkCount ?? 1) > 1, let id = v?.fileResourceIdentifier as? NSObject else { return size }
            return linked.insert(id).inserted ? size : 0
        }

        func addKind(_ token: String, bytes: Int64, count: Int) {
            sizes.byKind[token, default: FolderSizes.Entry()].bytes += bytes
            sizes.byKind[token, default: FolderSizes.Entry()].items += count
        }

        let top = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [])) ?? []
        for child in top {
            if isCancelled() { stopped = true; break }
            guard tick() else { break }
            let v = try? child.resourceValues(forKeys: Set(keys))
            let name = child.lastPathComponent
            if v?.isSymbolicLink == true { continue }
            guard v?.isDirectory == true else {
                let bytes = bytes(v)
                sizes.totalBytes += bytes
                addKind(kindToken(name: name, isPackage: false), bytes: bytes, count: 1)
                continue
            }
            // A folder or a package: count everything under it. A package counts once in its kind, with all its bytes.
            let topPackage = v?.isPackage == true ? kindToken(name: name, isPackage: true) : nil
            if let topPackage { addKind(topPackage, bytes: 0, count: 1) }
            var entry = FolderSizes.Entry()
            var package: (prefix: String, token: String)?
            let walker = FileManager.default.enumerator(at: child, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
            var finishedChild = true
            while let any = walker?.nextObject() {
                guard let url = any as? URL else { continue }
                guard tick() else { finishedChild = false; break }
                entry.items += 1
                let cv = try? url.resourceValues(forKeys: Set(keys))
                if cv?.isSymbolicLink == true { continue }
                let path = url.path
                if let p = package, !path.hasPrefix(p.prefix) { package = nil }
                if cv?.isDirectory == true {
                    if topPackage == nil, package == nil, cv?.isPackage == true {
                        let token = kindToken(name: url.lastPathComponent, isPackage: true)
                        package = (path + "/", token)
                        addKind(token, bytes: 0, count: 1)
                    }
                    continue
                }
                let bytes = bytes(cv)
                entry.bytes += bytes
                sizes.totalBytes += bytes
                if let token = topPackage ?? package?.token { addKind(token, bytes: bytes, count: 0) }
                else { addKind(kindToken(name: url.lastPathComponent, isPackage: false), bytes: bytes, count: 1) }
            }
            entry.complete = finishedChild
            sizes.children[name] = entry
            if stopped { break }
        }
        sizes.finished = true
        sizes.complete = !stopped
        progress(sizes)
        return sizes
    }
}

extension FolderSizer {
    /// The browse kinds by the name's type, as the archive outline's hairline reads them (it runs off the main
    /// thread here), with PDFs, presentations and spreadsheets counted as documents.
    static func baseToken(_ ext: String) -> String {
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "kind-other" }
        if type.conforms(to: .archive) || ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z"].contains(ext) { return "kind-archive" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "kind-code" }
        if type.conforms(to: .image) { return "kind-image" }
        if type.conforms(to: .audiovisualContent) { return "kind-media" }
        if ["json", "csv", "tsv", "yaml", "yml", "toml", "xml", "plist", "sqlite", "db"].contains(ext) { return "kind-data" }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) { return "kind-text" }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return "kind-app" }
        return "kind-other"
    }
}
