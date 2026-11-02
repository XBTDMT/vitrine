import Foundation

/// What a preview should warn about before anyone extracts an archive (ARCHITECTURE §8; the trust lens's archive
/// safety card reads this). Everything is judged from the listing: names, types, modes and sizes. Each finding
/// carries a count and the first offending paths, so the card can say "3 entries write outside the folder" and
/// show which.
public enum ArchiveSafety {
    public static func scan(_ listing: ArchiveListing, policy: SafetyPolicy = .default) -> SafetyReport {
        var collector = Collector(cap: policy.maxPathsPerFinding)
        let entries = listing.entries

        var seen: [[UInt32]: Int] = [:]
        var folded: [String: String] = [:]
        var reportedCollision: Set<String> = []
        var totalUncompressed: Int64 = 0
        // Links are judged through the archive's own other links (a → ".", b → "a/.." is the root's parent).
        var links = ArchivePath.LinkResolver(entries)

        for entry in entries {
            let path = entry.path
            if ArchivePath.windowsComponents(path).contains("..") { collector.add(.parentTraversal, path) }
            if path.hasPrefix("/") { collector.add(.absolutePath, path) }
            if ArchivePath.hasWindowsForm(path) { collector.add(.windowsPath, path) }

            switch entry.type {
            case .symlink:
                if let target = entry.linkTarget, links.escapes(linkPath: path, target: target) {
                    collector.add(.linkOutsideArchive, "\(path) → \(target)")
                } else {
                    collector.add(.symlink, entry.linkTarget.map { "\(path) → \($0)" } ?? path)
                }
            case .hardlink:
                if let target = entry.linkTarget,
                   target.hasPrefix("/") || ArchivePath.windowsComponents(target).contains("..") {
                    collector.add(.linkOutsideArchive, "\(path) ⇒ \(target)")
                } else {
                    collector.add(.hardlink, entry.linkTarget.map { "\(path) ⇒ \($0)" } ?? path)
                }
            case .characterDevice, .blockDevice, .fifo:
                collector.add(.specialFile, path)
            case .file, .directory, .other:
                break
            }
            if entry.type != .symlink {
                if entry.isSetUID { collector.add(.setuid, path) }
                if entry.isSetGID { collector.add(.setgid, path) }
            }
            if entry.isEncrypted { collector.add(.encrypted, path) }
            if entry.type == .file {
                if ArchivePath.hasDisguisedExtension(path) {
                    collector.add(.disguisedProgram, path)
                } else if ArchivePath.isProgram(path, mode: entry.mode) {
                    collector.add(.program, path)
                }
                if ArchivePath.isArchive(path) {
                    let size = entry.uncompressedSize ?? 0
                    if size > Int64(policy.maxNestedArchiveBytes) {
                        let shown = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                        collector.add(.oversizedNestedArchive, String(localized: "\(path) (\(shown))", bundle: .module,
                                                                      comment: "A path in the archive safety card followed by its size."))
                    } else {
                        collector.add(.nestedArchive, path)
                    }
                }
            }

            let scalars = path.unicodeScalars
            if scalars.contains(where: ArchivePath.isControl) { collector.add(.controlCharacters, path) }
            if scalars.contains(where: ArchivePath.isBidiControl) { collector.add(.bidiOverride, path) }

            if entry.type != .directory {
                // Duplicates compare stored characters exactly (Swift's String equality would merge canonically
                // equivalent spellings, which belong to the collision check below).
                let key = ArchivePath.normalized(path)
                let exact = Array(key.unicodeScalars.map(\.value))
                let count = (seen[exact] ?? 0) + 1
                seen[exact] = count
                if count == 2 { collector.add(.duplicatePath, key) } else if count > 2 { collector.bump(.duplicatePath) }
                // APFS and HFS+ default to case- and normalization-insensitive names: these collide on extraction.
                let fold = key.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
                if let first = folded[fold] {
                    if !first.unicodeScalars.elementsEqual(key.unicodeScalars), !reportedCollision.contains(fold) {
                        reportedCollision.insert(fold)
                        collector.add(.caseCollision, "\(first) ≈ \(key)")
                    }
                } else {
                    folded[fold] = key
                }
            }

            if let size = entry.uncompressedSize, size > 0 {
                let (sum, overflow) = totalUncompressed.addingReportingOverflow(size)
                totalUncompressed = overflow ? .max : sum
                if size >= policy.entryRatioMinimumBytes, let ratio = entry.compressionRatio,
                   ratio > policy.entryRatioThreshold {
                    collector.add(.entryExpansion, String(localized: "\(path) (\(Self.ratioText(ratio)))", bundle: .module,
                                                          comment: "A path in the archive safety card followed by its expansion ratio, like 420×."))
                }
            }
        }

        // Overlapping members are the trick behind non-recursive zip bombs: many directory entries share one
        // block of compressed data. A next header that starts before the current member's data could end is
        // certain overlap (30 bytes is the smallest local header).
        if case .zip = listing.format {
            let spans = entries.filter { $0.compressedSize != nil }.sorted { $0.headerOffset < $1.headerOffset }
            for (a, b) in zip(spans, spans.dropFirst()) {
                // Offsets and sizes come from the directory (ZIP64 values may be near Int64.max): every step is
                // checked, and a member whose data would end past any possible file overlaps whatever follows it.
                let (start, startOverflow) = a.headerOffset.addingReportingOverflow(30)
                let (end, endOverflow) = start.addingReportingOverflow(max(0, a.compressedSize ?? 0))
                if startOverflow || endOverflow || b.headerOffset < end { collector.add(.overlappingEntries, b.path) }
            }
        }

        // Names hidden behind header encryption: the members cannot be judged, and the archive says so.
        if listing.notes.contains(.encryptedHeaders) { collector.add(.encrypted, String(localized: "(the names themselves are encrypted)", bundle: .module, comment: "Archive safety card: shown instead of a path when the member names are encrypted.")) }

        var archiveRatio: Double?
        if listing.fileSize > 0 {
            let expanded: Int64
            if listing.format.isCompressed {
                let isize = Int64(listing.gzip?.trailerSize ?? 0)
                expanded = max(totalUncompressed, isize)
            } else {
                expanded = 0                                       // stored, not compressed: no expansion to judge
            }
            if expanded > 0 {
                let ratio = Double(expanded) / Double(listing.fileSize)
                archiveRatio = ratio
                if expanded >= policy.archiveRatioMinimumBytes, ratio > policy.archiveRatioThreshold {
                    let expandedText = ByteCountFormatter.string(fromByteCount: expanded, countStyle: .file)
                    let sizeText = ByteCountFormatter.string(fromByteCount: listing.fileSize, countStyle: .file)
                    let line = String(localized: "\(Self.ratioText(ratio)) (\(expandedText) from \(sizeText))", bundle: .module,
                                      comment: "Archive safety card: expansion ratio, then the expanded size and the archive's own size.")
                    collector.add(.archiveExpansion, line)
                }
            }
        }

        if entries.count > policy.manyEntriesThreshold {
            collector.add(.manyEntries, String(localized: "\(entries.count.formatted()) entries", bundle: .module,
                                               comment: "Archive safety card: how many entries the archive holds (always many)."))
        }
        if case .partial(let listed, let total, let reason) = listing.coverage {
            let line = if let total {
                String(localized: "\(listed.formatted()) of \(total.formatted()) entries listed: \(reason)", bundle: .module,
                       comment: "Archive safety card: entries listed out of the total, then why the listing stopped.")
            } else {
                String(localized: "\(listed.formatted()) entries listed: \(reason)", bundle: .module,
                       comment: "Archive safety card: entries listed (total unknown), then why the listing stopped.")
            }
            collector.add(.incompleteListing, line)
        }

        return SafetyReport(findings: collector.findings(), totalUncompressedSize: totalUncompressed,
                            expansionRatio: archiveRatio)
    }

    /// "420×"; whole numbers only, never trapping on a ratio too large for an Int.
    static func ratioText(_ ratio: Double) -> String {
        ratio.isFinite ? ratio.formatted(.number.precision(.fractionLength(0))) + "×" : "∞×"
    }

    private struct Collector {
        let cap: Int
        var order: [SafetyFinding.Kind] = []
        var counts: [SafetyFinding.Kind: Int] = [:]
        var paths: [SafetyFinding.Kind: [String]] = [:]

        mutating func add(_ kind: SafetyFinding.Kind, _ path: String) {
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
            if paths[kind, default: []].count < cap { paths[kind, default: []].append(ArchivePath.visible(path)) }
        }

        mutating func bump(_ kind: SafetyFinding.Kind) { counts[kind, default: 0] += 1 }

        func findings() -> [SafetyFinding] {
            order.map { SafetyFinding(kind: $0, count: counts[$0] ?? 0, paths: paths[$0] ?? []) }
                .sorted { ($0.level, $1.kind.rank) > ($1.level, $0.kind.rank) }
        }
    }
}

/// Thresholds for the findings. The defaults suit a Quick Look card: loud for what extraction would do to the
/// disk, quiet for what is merely unusual.
public struct SafetyPolicy: Sendable, Equatable {
    /// Paths kept per finding; counts are always exact.
    public var maxPathsPerFinding: Int
    /// Total uncompressed over the archive's size above which the archive reads as a bomb.
    public var archiveRatioThreshold: Double
    /// …only when it expands to at least this much (a small file of zeros is not a threat).
    public var archiveRatioMinimumBytes: Int64
    /// A single member's uncompressed over compressed size above which it reads as a bomb.
    public var entryRatioThreshold: Double
    public var entryRatioMinimumBytes: Int64
    /// More entries than this is reported.
    public var manyEntriesThreshold: Int
    /// Nested archives larger than this cannot be opened in place (`ArchiveLimits.maxNestedArchiveBytes`).
    public var maxNestedArchiveBytes: Int

    public init(maxPathsPerFinding: Int = 20, archiveRatioThreshold: Double = 100,
                archiveRatioMinimumBytes: Int64 = 10 * 1024 * 1024, entryRatioThreshold: Double = 100,
                entryRatioMinimumBytes: Int64 = 1024 * 1024, manyEntriesThreshold: Int = 50_000,
                maxNestedArchiveBytes: Int = ArchiveLimits.default.maxNestedArchiveBytes) {
        self.maxPathsPerFinding = max(0, maxPathsPerFinding); self.archiveRatioThreshold = archiveRatioThreshold
        self.archiveRatioMinimumBytes = archiveRatioMinimumBytes; self.entryRatioThreshold = entryRatioThreshold
        self.entryRatioMinimumBytes = entryRatioMinimumBytes; self.manyEntriesThreshold = manyEntriesThreshold
        self.maxNestedArchiveBytes = maxNestedArchiveBytes
    }

    public static let `default` = SafetyPolicy()
}

public struct SafetyReport: Sendable, Equatable {
    /// Most severe first.
    public var findings: [SafetyFinding]
    public var totalUncompressedSize: Int64
    /// Total expansion over the archive's size (nil for plain tar, which stores members as they are).
    public var expansionRatio: Double?

    public var highestLevel: SafetyFinding.Level? { findings.map(\.level).max() }
    public func finding(_ kind: SafetyFinding.Kind) -> SafetyFinding? { findings.first { $0.kind == kind } }
    public var isClean: Bool { findings.isEmpty }
}

public struct SafetyFinding: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case parentTraversal, absolutePath, windowsPath, linkOutsideArchive, archiveExpansion, entryExpansion
        case overlappingEntries, bidiOverride, disguisedProgram, specialFile, setuid, setgid, controlCharacters
        case duplicatePath, caseCollision, manyEntries, incompleteListing, symlink, hardlink, encrypted, program
        case nestedArchive, oversizedNestedArchive

        /// Display order within a level: the order the cases are declared.
        var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    /// Mirrors `Badge.Level` in VitrineDocument, so the trust lens maps one to one.
    public enum Level: String, Sendable, Comparable {
        case info, caution, danger
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
        private var rank: Int { switch self { case .info: 0; case .caution: 1; case .danger: 2 } }
    }

    public var kind: Kind
    /// How many entries (or, for archive-wide findings, 1).
    public var count: Int
    /// The first offending paths, at most `SafetyPolicy.maxPathsPerFinding`, decorated where it helps
    /// (`link → target`, `name (420×)`); control characters are shown as `\u{…}` escapes.
    public var paths: [String]

    public init(kind: Kind, count: Int, paths: [String]) { self.kind = kind; self.count = count; self.paths = paths }

    public var pathsTruncated: Bool { count > paths.count }

    public var level: Level {
        switch kind {
        case .parentTraversal, .absolutePath, .linkOutsideArchive, .archiveExpansion, .entryExpansion,
             .overlappingEntries, .bidiOverride, .disguisedProgram:
            .danger
        case .windowsPath, .specialFile, .setuid, .setgid, .controlCharacters, .duplicatePath, .manyEntries,
             .incompleteListing:
            .caution
        case .caseCollision, .symlink, .hardlink, .encrypted, .program, .nestedArchive, .oversizedNestedArchive:
            .info
        }
    }

    public var title: String {
        switch kind {
        case .parentTraversal: String(localized: "Paths climb out with “..”", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .absolutePath: String(localized: "Absolute paths", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .windowsPath: String(localized: "Windows-style paths", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .linkOutsideArchive: String(localized: "Links point outside the archive", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .archiveExpansion: String(localized: "Expands far beyond its size", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .entryExpansion: String(localized: "Members compress implausibly well", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .overlappingEntries: String(localized: "Members share compressed data", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .bidiOverride: String(localized: "Names with direction overrides", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .specialFile: String(localized: "Device files or pipes", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .setuid: String(localized: "Set-user-ID files", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .setgid: String(localized: "Set-group-ID files", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .controlCharacters: String(localized: "Names with control characters", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .duplicatePath: String(localized: "Duplicate paths", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .caseCollision: String(localized: "Names that differ only by case", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .manyEntries: String(localized: "A very large number of entries", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .incompleteListing: String(localized: "Listing incomplete", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .symlink: String(localized: "Symbolic links", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .hardlink: String(localized: "Hard links", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .encrypted: String(localized: "Encrypted members", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .disguisedProgram: String(localized: "Programs named like documents", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .program: String(localized: "Programs and scripts", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .nestedArchive: String(localized: "Archives inside", bundle: .module, comment: "Archive safety card: the title of one finding.")
        case .oversizedNestedArchive: String(localized: "Archives inside too large to open here", bundle: .module, comment: "Archive safety card: the title of one finding.")
        }
    }

    /// One sentence for the safety card. Singular and plural are separate phrases, so each translates whole.
    public var detail: String {
        let n = count.formatted()
        let one = count == 1
        return switch kind {
        case .parentTraversal:
            one ? String(localized: "1 entry would be written above the folder it is extracted into.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) entries would be written above the folder it is extracted into.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .absolutePath:
            one ? String(localized: "1 entry names an absolute location on disk.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) entries name an absolute location on disk.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .windowsPath:
            one ? String(localized: "1 name uses drive letters or backslashes, which Windows reads as folders.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) names use drive letters or backslashes, which Windows reads as folders.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .linkOutsideArchive:
            one ? String(localized: "1 link leads outside the extracted folder.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) links lead outside the extracted folder.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .archiveExpansion:
            String(localized: "The archive expands to many times its own size, the mark of a decompression bomb.", bundle: .module, comment: "Archive safety card: one finding's sentence.")
        case .entryExpansion:
            one ? String(localized: "1 member expands over the per-member ratio threshold.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) members expand over the per-member ratio threshold.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .overlappingEntries:
            one ? String(localized: "1 member overlaps another's data, a zip bomb construction.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) members overlap another's data, a zip bomb construction.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .bidiOverride:
            one ? String(localized: "1 name contains bidirectional controls that can disguise an extension.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) names contain bidirectional controls that can disguise an extension.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .specialFile:
            one ? String(localized: "1 entry is a device or pipe.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) entries are devices or pipes.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .setuid:
            one ? String(localized: "1 file would run with the owner's privileges.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) files would run with the owner's privileges.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .setgid:
            one ? String(localized: "1 file would run with the group's privileges.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) files would run with the group's privileges.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .controlCharacters:
            one ? String(localized: "1 name contains invisible control characters.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) names contain invisible control characters.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .duplicatePath:
            one ? String(localized: "1 extra copy of paths already in the archive; later ones overwrite.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) extra copies of paths already in the archive; later ones overwrite.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .caseCollision:
            one ? String(localized: "1 name collides on a case-insensitive disk.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) names collide on a case-insensitive disk.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .manyEntries:
            String(localized: "The archive holds an unusually large number of entries.", bundle: .module, comment: "Archive safety card: one finding's sentence.")
        case .incompleteListing:
            String(localized: "Not every entry was listed, so these findings may be incomplete.", bundle: .module, comment: "Archive safety card: one finding's sentence.")
        case .symlink:
            one ? String(localized: "1 symbolic link.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) symbolic links.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .hardlink:
            one ? String(localized: "1 hard link.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) hard links.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .encrypted:
            one ? String(localized: "1 member is encrypted; its content cannot be previewed.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) members are encrypted; their content cannot be previewed.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .disguisedProgram:
            one ? String(localized: "1 program wears a document's extension first (“invoice.pdf.exe”), which hides what it is.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) programs wear a document's extension first (“invoice.pdf.exe”), which hides what they are.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .program:
            one ? String(localized: "1 file is a program, installer or script: it runs when opened.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) files are programs, installers or scripts: they run when opened.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .nestedArchive:
            one ? String(localized: "1 member is an archive itself; open it to look inside.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) members are archives themselves; open one to look inside.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        case .oversizedNestedArchive:
            one ? String(localized: "1 archive inside is larger than Vitrine opens in place.", bundle: .module, comment: "Archive safety card: one finding's sentence (one).")
                : String(localized: "\(n) archives inside are larger than Vitrine opens in place.", bundle: .module, comment: "Archive safety card: one finding's sentence (more than one; the argument is the count).")
        }
    }
}

/// Path reasoning shared by the safety scan, the summary and the tree.
public enum ArchivePath {
    /// Segments split on `/`, without empty or `.` segments. `..` is kept: it is what the scan looks for.
    public static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
    }

    /// The path with `./`, repeated or trailing slashes, a leading `/` and `.` segments removed: the key for
    /// duplicates, the summary and the tree.
    public static func normalized(_ path: String) -> String { components(path).joined(separator: "/") }

    /// Segments as a Windows extractor sees them: backslashes are separators too. The traversal check uses this,
    /// so `..\..\x` is caught as well as `../../x`.
    static func windowsComponents(_ path: String) -> [String] {
        components(path.replacingOccurrences(of: "\\", with: "/"))
    }

    /// Drive letters (`C:`), UNC prefixes or backslashes, which Windows extractors read as separators.
    static func hasWindowsForm(_ path: String) -> Bool {
        path.contains("\\") || hasDriveLetter(path)
    }

    static func hasDriveLetter(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars.prefix(2))
        guard scalars.count == 2, scalars[1] == ":" else { return false }
        return ("a"..."z").contains(scalars[0]) || ("A"..."Z").contains(scalars[0])
    }

    /// Whether a symlink at `linkPath` pointing at `target` resolves outside the archive's root when the archive
    /// holds no other links: the lexical judgement. Backslashes count as separators too, as Windows would read
    /// them. The safety scan uses `LinkResolver`, which also follows the archive's other links.
    static func linkEscapes(linkPath: String, target: String) -> Bool {
        var none = LinkResolver([])
        return none.escapes(linkPath: linkPath, target: target)
    }

    /// Whether a target names a place on disk outright: `/…`, `\…` or a drive letter.
    static func isAbsoluteTarget(_ target: String) -> Bool {
        target.hasPrefix("/") || target.hasPrefix("\\") || hasDriveLetter(target)
    }

    /// Resolves link targets the way an extraction folder would: segment by segment from the root, where a segment
    /// that names another symlink in the archive is replaced by that link's target. A chain of links that each look
    /// internal by their text (`a` → `.`, `b` → `a/..`) is then seen to climb out. Names are compared folded for
    /// case and Unicode normalization, as APFS and HFS+ compare them by default (the same fold as the collision
    /// check). Iterative, with a hop limit per link (macOS follows at most 32 links in one path, `MAXSYMLINKS`) and
    /// a step budget for the whole archive; a link that reaches either limit cannot be shown to stay inside, so it
    /// is reported as leading outside.
    struct LinkResolver {
        static let maxHops = 32
        /// Segments walked or queued across the whole archive. A real archive's links cost a few segments each.
        static let maxSteps = 4_000_000

        /// A trie over the links' folded path segments, so walking one segment deeper is one dictionary lookup.
        private var children: [[String: Int]] = [[:]]
        /// Each link's target: absolute, or its segments in reverse order (ready to queue).
        private var targets: [Int: Target] = [:]
        private var steps = 0

        private enum Target { case absolute, segments([String]) }

        init(_ entries: [ArchiveEntry]) {
            for entry in entries where entry.type == .symlink {
                guard let target = entry.linkTarget else { continue }
                let parts = ArchivePath.windowsComponents(entry.path)
                guard !parts.isEmpty, !parts.contains("..") else { continue }
                var node = 0
                for part in parts {
                    let key = Self.fold(part)
                    if let next = children[node][key] {
                        node = next
                    } else {
                        children.append([:])
                        children[node][key] = children.count - 1
                        node = children.count - 1
                    }
                }
                // A later entry of the same name replaces an earlier one, as extraction would.
                targets[node] = ArchivePath.isAbsoluteTarget(target)
                    ? .absolute : .segments(Array(ArchivePath.windowsComponents(target).reversed()))
            }
        }

        static func fold(_ segment: String) -> String {
            segment.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
        }

        /// Whether the link at `linkPath` pointing at `target` leads outside the root (or cannot be resolved within
        /// the limits).
        mutating func escapes(linkPath: String, target: String) -> Bool {
            if ArchivePath.isAbsoluteTarget(target) { return true }
            var folder = ArchivePath.windowsComponents(linkPath)
            if !folder.isEmpty { folder.removeLast() }           // the link's own folder
            if folder.contains("..") { return true }
            // Segments still to walk, last first, so taking the next one is `popLast`. The link's folder is walked
            // too: a folder that is itself a link moves where the target starts.
            var pending = Array((folder + ArchivePath.windowsComponents(target)).reversed())
            steps += pending.count
            var resolved: [Int?] = []                            // the trie node of each resolved segment (nil: no link below)
            var hops = 0
            while let part = pending.popLast() {
                steps += 1
                if steps > Self.maxSteps { return true }
                if part == ".." {
                    if resolved.isEmpty { return true }
                    resolved.removeLast()
                    continue
                }
                let parent: Int? = resolved.isEmpty ? 0 : resolved[resolved.count - 1]
                var node: Int?
                if let parent, !children[parent].isEmpty { node = children[parent][Self.fold(part)] }
                if let node, let next = targets[node] {
                    hops += 1
                    guard hops <= Self.maxHops, case .segments(let parts) = next else { return true }
                    steps += parts.count
                    if steps > Self.maxSteps { return true }
                    // The link is replaced by its target, read from the link's own folder (`resolved` as it is).
                    pending.append(contentsOf: parts)
                } else {
                    resolved.append(node)
                }
            }
            return false
        }
    }

    /// Extensions of things that run when opened: Windows and Mac programs, installers, and scripts.
    static let programExtensions: Set<String> = [
        "exe", "msi", "bat", "cmd", "com", "scr", "pif", "cpl", "ps1", "vbs", "vbe", "wsf", "wsh", "hta", "jse", "lnk",
        "reg", "jar", "sh", "command", "tool", "pkg", "mpkg", "apk", "appimage",
    ]
    /// Extensions people read as harmless documents, for the "invoice.pdf.exe" disguise.
    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "jpg", "jpeg", "png", "gif", "heic", "mp3",
        "mp4", "mov", "csv", "zip", "html", "pages", "numbers", "key",
    ]
    /// Archive extensions a member can carry (the formats VitrineArchive opens).
    static let archiveExtensions: Set<String> = [
        "zip", "jar", "war", "ear", "ipa", "apk", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
        "lz4", "lzma", "tlz", "lz", "z", "taz", "rar", "7z", "iso", "cpio", "rpm", "deb", "xar", "cab", "lha", "lzh",
    ]

    static func lastExtensions(_ path: String) -> (last: String, previous: String?) {
        let name = components(path).last ?? path
        let parts = name.lowercased().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return ("", nil) }
        return (parts[parts.count - 1], parts.count >= 3 ? parts[parts.count - 2] : nil)
    }

    /// A program by its extension, a folder inside an `.app` bundle's executable folder, or a file with an execute
    /// bit (when the archive records modes).
    static func isProgram(_ path: String, mode: UInt32?) -> Bool {
        if programExtensions.contains(lastExtensions(path).last) { return true }
        let parts = components(path)
        if let i = parts.firstIndex(where: { $0.lowercased().hasSuffix(".app") }), parts.count == i + 4,
           parts[i + 1] == "Contents", parts[i + 2] == "MacOS" {
            return true
        }
        if let mode, mode & 0o170000 == 0o100000, mode & 0o111 != 0 { return true }
        return false
    }

    /// "invoice.pdf.exe": a program extension right after a document one.
    static func hasDisguisedExtension(_ path: String) -> Bool {
        let (last, previous) = lastExtensions(path)
        guard let previous, programExtensions.contains(last), !["sh", "command", "tool", "jar", "pkg", "mpkg", "apk"].contains(last)
        else { return false }
        return documentExtensions.contains(previous)
    }

    /// A member that is itself an archive, by its extension.
    static func isArchive(_ path: String) -> Bool {
        archiveExtensions.contains(lastExtensions(path).last)
    }

    /// C0 controls, DEL and C1 controls.
    static func isControl(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x20 || s.value == 0x7F || (0x80...0x9F).contains(s.value)
    }

    /// Embeddings, overrides and isolates (U+202A–U+202E, U+2066–U+2069): the "Trojan Source" set that reorders
    /// what a name looks like. Marks (LRM, RLM) are left alone; legitimate right-to-left names use them.
    static func isBidiControl(_ s: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value)
    }

    /// A name with controls and bidi characters written as `\u{…}`, so a report line cannot itself be spoofed.
    public static func visible(_ path: String) -> String {
        var out = ""
        for s in path.unicodeScalars {
            if isControl(s) || isBidiControl(s) { out += "\\u{\(String(s.value, radix: 16, uppercase: true))}" }
            else { out.unicodeScalars.append(s) }
        }
        return out
    }
}
