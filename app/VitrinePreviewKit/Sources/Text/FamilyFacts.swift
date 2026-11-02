import Foundation
import VitrineArchive
import VitrineData
import VitrineDocument
import VitrineSupport
import VitrineText

/// What the merged engines add to a text-shaped preview before each family has its own view: the facts the pill and
/// its tooltip show (with one `headline` the pill puts beside the kind), warnings as badges, a Formatted view for a
/// minified structured file, and for archives the listing itself. Each engine is bounded by its own limits; this
/// layer adds a size cap so a preview never waits on a parse it does not need. roadmap: S-5, S-6, S-7, S-8
enum FamilyFacts {
    /// Files above this are previewed as text only; their facts would cost more than the first paint allows.
    static let parseLimit: Int64 = 16 * 1024 * 1024

    static func enrich(_ document: PreviewDocument, url: URL) -> PreviewDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        switch document.kind {
        case .code(let language) where structuredFormat(language: language, url: url) != nil:
            guard size <= parseLimit, let format = structuredFormat(language: language, url: url) else { return document }
            return structured(document, url: url, format: format)
        case .csv:
            return csv(document, url: url)
        case .diff:
            guard size <= parseLimit else { return document }
            return diff(document, url: url)
        default:
            return document
        }
    }

    // MARK: Structured (S-5)

    static func structuredFormat(language: String, url: URL) -> StructuredFormat? {
        if let byExtension = StructuredFormat(fileExtension: url.pathExtension) { return byExtension }
        switch language {
        case "json", "jsonc", "json5": return .json
        case "yaml": return .yaml
        case "toml": return .toml
        case "xml": return .xml
        default: return nil
        }
    }

    static func structured(_ document: PreviewDocument, url: URL, format: StructuredFormat) -> PreviewDocument {
        var options = StructuredOptions()
        options.maxInputBytes = parseLimit
        guard let result = try? StructuredParser.parse(contentsOf: url, format: format, options: options) else { return document }
        var doc = document
        let facts = result.facts.entries().map { Fact(key: $0.key, label: $0.label, value: $0.value) }
        let headline: String
        if let error = result.error {
            if let location = error.location {
                headline = String(localized: "Syntax error at \(location.description)", bundle: .previewKit,
                                  comment: "Capsule pill headline: where a JSON/YAML/TOML/XML file stops parsing, as line:column.")
                doc.badges.append(Badge(level: .caution,
                                        title: String(localized: "Syntax error at line \(location.description)", bundle: .previewKit,
                                                      comment: "Warning title: where a structured file stops parsing, as line:column."),
                                        detail: error.reason, evidence: location.byteOffset.map { $0..<($0 + 1) }))
            } else {
                headline = String(localized: "Syntax error", bundle: .previewKit, comment: "Capsule pill headline: a structured file does not parse; the place is unknown.")
                doc.badges.append(Badge(level: .caution,
                                        title: String(localized: "Syntax error at an unknown place", bundle: .previewKit,
                                                      comment: "Warning title: a structured file does not parse and the place is unknown."),
                                        detail: error.reason))
            }
        } else {
            headline = String(localized: "\(result.sourceNodeCount) nodes", bundle: .previewKit,
                              comment: "Capsule pill headline: how many nodes a JSON/YAML/TOML/XML tree holds.")
        }
        doc.facts = [Fact(key: "headline", label: summaryLabel, value: headline)] + doc.facts + facts.filter { f in !doc.facts.contains { $0.key == f.key } }
        if result.layout.isMinified, [.json, .xml, .propertyList].contains(format),
           let data = try? FileHandle(forReadingFrom: url).read(upToCount: Int(parseLimit)) {
            if let formatted = StructuredFormatter.format(data, as: format), !formatted.text.isEmpty,
               case .code(_, let language)? = doc.views.first {
                doc.views.insert(.formatted(formatted.text, language: language), at: 0)
            }
        }
        return doc
    }

    // MARK: CSV and TSV (S-6)

    /// `table` and `index` come from a caller that already opened and counted the file; without them the count is
    /// the first page's floor ("≥ 200 rows").
    static func csv(_ document: PreviewDocument, url: URL, table opened: CSVTable? = nil, index: CSVRowIndex? = nil) -> PreviewDocument {
        guard let table = opened ?? (try? CSVTable.open(url)) else { return document }
        let facts = table.facts(index: index)
        var doc = document
        let entries = facts.entries().map { Fact(key: $0.key, label: $0.label, value: $0.value) }
        let rows = entries.first { $0.key == "rows" }?.value ?? "?"
        // The row count arrives formatted ("3,214", "≥ 200"), so the one-row sentence is its own.
        let columns = table.columnCount
        let headline = rows == "1"
            ? String(localized: "1 row × \(columns) columns", bundle: .previewKit, comment: "Capsule pill headline of a one-row CSV table.")
            : String(localized: "\(rows) rows × \(columns) columns", bundle: .previewKit,
                     comment: "Capsule pill headline of a CSV table; the row count arrives formatted ('3,214' or '≥ 200').")
        doc.facts = [Fact(key: "headline", label: summaryLabel, value: headline)] + doc.facts + entries.filter { f in !doc.facts.contains { $0.key == f.key } }
        return doc
    }

    // MARK: Patches (S-7)

    static func diff(_ document: PreviewDocument, url: URL) -> PreviewDocument {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return document }
        let patch = PatchParser.parse(data)
        var doc = document
        let totals = patch.totals
        let headline = String(localized: "\(totals.files) files · +\(totals.additions) −\(totals.deletions)", bundle: .previewKit,
                              comment: "Capsule pill headline of a patch: files changed, lines added (+) and removed (−).")
        let lead = Fact(key: "summary", label: String(localized: "Changes", bundle: .previewKit, comment: "Fact label: a patch's one-line summary."),
                        value: DiffSummary(patch: patch).lead)
        doc.facts = [Fact(key: "headline", label: summaryLabel, value: headline), lead] + doc.facts
            + DiffFacts.facts(for: patch).filter { f in !doc.facts.contains { $0.key == f.key } }
        for issue in patch.issues where issue.severity == .error {
            doc.badges.append(Badge(level: .caution, title: String(localized: "Patch problem", bundle: .previewKit,
                                                                   comment: "Warning title: a patch file has a malformed part."),
                                    detail: issue.message))
        }
        return doc
    }

    // MARK: Archives (S-8)

    /// The listing as text (folders first, sizes on the right) with the archive's facts and its safety findings as
    /// badges. The outline view of the picked browse design replaces the text later; the facts stay.
    /// Everything the archive preview draws from: the listing, its summary, the safety scan and the outline tree.
    struct ArchiveModel {
        let listing: ArchiveListing
        let summary: ArchiveSummary
        let safety: SafetyReport
        let tree: ArchiveTree
        let document: PreviewDocument
    }

    static func archive(url: URL, kind: FileKind, maxLines: Int = 20_000) throws -> PreviewDocument {
        try archiveModel(url: url, kind: kind, maxLines: maxLines).document
    }

    static func archiveModel(url: URL, kind: FileKind, maxLines: Int = 20_000) throws -> ArchiveModel {
        let listing = try VitrineArchive.list(contentsOf: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? listing.fileSize
        return archiveModel(listing: listing, fileSize: size, kind: kind, maxLines: maxLines)
    }

    /// The model for a listing already read: a file's, a nested archive's (S-8 nested navigation), or the files a
    /// torrent names.
    static func archiveModel(listing: ArchiveListing, fileSize size: Int64, kind: FileKind, maxLines: Int = 20_000) -> ArchiveModel {
        let summary = ArchiveSummary(listing)
        let safety = ArchiveSafety.scan(listing)
        let tree = ArchiveTree(entries: listing.entries)
        var lines: [String] = []
        var stack = tree.children(of: tree.root).reversed().map { ($0, 0) }
        while let (node, depth) = stack.popLast(), lines.count < maxLines {
            let name = String(repeating: "  ", count: depth) + node.name + (node.isFolder ? "/" : "")
            let right = node.isFolder ? items(node.descendantCount) : ByteCountFormatter.string(fromByteCount: node.totalSize, countStyle: .file)
            lines.append(name.padding(toLength: max(name.count + 2, 56), withPad: " ", startingAt: 0) + right)
            stack.append(contentsOf: tree.children(of: node).reversed().map { ($0, depth + 1) })
        }
        let shownAll = lines.count < maxLines || stack.isEmpty
        let total = ByteCountFormatter.string(fromByteCount: summary.totalUncompressedSize, countStyle: .file)
        // The browse design's pill: "214 items · 18.6 MB · 65% packed · no problems".
        let problems = safety.findings.filter { $0.level != .info }.count
        // The pill's parts are each a whole phrase; " · " is the pill's list separator, not grammar.
        var headline = [items(summary.entryCount), total]
        if let packed = summary.totalCompressedSize, summary.totalUncompressedSize > 0 {
            headline.append(packedPhrase(packed, of: summary.totalUncompressedSize))
        } else if listing.format.isCompressed, listing.coverage.isComplete, summary.totalUncompressedSize > 0, size > 0 {
            // Formats that give no per-member packed size (7z, RAR, xz tars): the whole file against what it holds,
            // both measured; the outline's Packed column stays "—".
            headline.append(packedPhrase(size, of: summary.totalUncompressedSize))
        }
        headline.append(problems == 0
                        ? String(localized: "no problems", bundle: .previewKit, comment: "Archive pill: the safety scan found nothing (lower case, mid-line).")
                        : problemCount(problems))
        var facts = [Fact(key: "headline", label: summaryLabel, value: headline.joined(separator: " · ")),
                     Fact(key: "verdict", label: String(localized: "Verdict", bundle: .previewKit, comment: "Fact label: the archive safety scan's verdict."),
                          value: problems == 0 ? noProblems : problemCount(problems)),
                     Fact(key: "entries", label: String(localized: "Entries", bundle: .previewKit, comment: "Fact label: entries in an archive."),
                          value: summary.entryCount.formatted()),
                     Fact(key: "files", label: String(localized: "Files", bundle: .previewKit, comment: "Fact label: files in an archive."),
                          value: summary.fileCount.formatted()),
                     Fact(key: "folders", label: String(localized: "Folders", bundle: .previewKit, comment: "Fact label: folders in an archive."),
                          value: summary.folderCount.formatted()),
                     Fact(key: "uncompressed", label: String(localized: "Uncompressed", bundle: .previewKit, comment: "Fact label: an archive's unpacked size."),
                          value: total)]
        if let compressed = summary.totalCompressedSize {
            facts.append(Fact(key: "compressed", label: String(localized: "Compressed", bundle: .previewKit, comment: "Fact label: an archive's packed size."),
                              value: ByteCountFormatter.string(fromByteCount: compressed, countStyle: .file)))
        }
        if let top = summary.singleTopFolder {
            facts.append(Fact(key: "topFolder", label: String(localized: "Top folder", bundle: .previewKit,
                                                              comment: "Fact label: the one folder an archive holds everything in."), value: top))
        }
        facts.append(Fact(key: "format", label: String(localized: "Format", bundle: .previewKit, comment: "Fact label: an archive's format name."),
                          value: listing.format.name))
        // The archive file's own size, under its own key: the pill already carries the unpacked size.
        facts.insert(Fact(key: "archiveSize", label: String(localized: "Archive size", bundle: .previewKit, comment: "Fact label: the archive file's own size."),
                          value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), at: 1)
        let badges = safety.findings.filter { $0.level != .info || $0.kind == .encrypted }.map { finding in
            Badge(level: finding.level == .danger ? .danger : finding.level == .caution ? .caution : .info,
                  title: finding.title, detail: finding.detail)
        }
        let coverage: Coverage
        switch listing.coverage {
        case .partial(let listed, let total, let reason):
            coverage = .partial(shown: Int64(listed), total: total.map(Int64.init), unit: .members, reason: reason)
        case .complete:
            coverage = shownAll ? .complete
                : .partial(shown: Int64(maxLines), total: Int64(tree.nodes.count - 1), unit: .members,
                           reason: String(localized: "Long listing", bundle: .previewKit, comment: "Why an archive listing is cut: it is very long."))
        }
        let document = PreviewDocument(kind: kind, facts: facts, badges: badges, views: [.text(lines.joined(separator: "\n"))], coverage: coverage)
        return ArchiveModel(listing: listing, summary: summary, safety: safety, tree: tree, document: document)
    }

    /// "1 file", "2 files", "1,204 nodes": English only. Kept for the families not yet localized; localized code says
    /// each counted phrase whole with `String(localized:)` (H-6).
    static func plural(_ n: Int, _ noun: String) -> String { "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")" }

    /// The label of the `headline` fact (the pill's summary, also in describe's JSON).
    static var summaryLabel: String {
        String(localized: "Summary", bundle: .previewKit, comment: "Fact label: the one-line summary the capsule pill shows beside the kind.")
    }

    /// The archive verdict when the safety scan found nothing; the capsule's dot turns calm green on it.
    static var noProblems: String {
        String(localized: "No problems", bundle: .previewKit, comment: "Archive verdict: the safety scan found nothing.")
    }

    /// "3 problems": what the archive safety scan found.
    static func problemCount(_ n: Int) -> String {
        String(localized: "\(n) problems", bundle: .previewKit, comment: "Archive verdict: how many problems the safety scan found.")
    }

    /// "214 items": an archive's or a folder's entries.
    static func items(_ n: Int) -> String {
        String(localized: "\(n) items", bundle: .previewKit, comment: "How many items an archive or a folder in it holds.")
    }

    /// "65%"; a share that rounds to nothing but is not nothing reads "<1%" (a block of zeros packs to a few bytes).
    /// "65% packed"; an archive no smaller than what it holds (a few tiny files, stored members) says
    /// "no space saved" rather than "473% packed".
    static func packedPhrase(_ packed: Int64, of total: Int64) -> String {
        Double(packed) / Double(max(1, total)) >= 0.995
            ? String(localized: "no space saved", bundle: .previewKit, comment: "Archive pill: packing saved no space (lower case, mid-line).")
            : String(localized: "\(packedShare(packed, of: total)) packed", bundle: .previewKit,
                     comment: "Archive pill: the packed size as a share of the unpacked size, e.g. '65% packed'.")
    }

    /// "65%", "<1%", formatted as a percent in the person's locale.
    static func packedShare(_ packed: Int64, of total: Int64) -> String {
        let percent = Double(packed) / Double(max(1, total)) * 100
        if percent > 0 && percent < 0.5 {
            return String(localized: "<\(0.01.formatted(.percent))", bundle: .previewKit,
                          comment: "A share too small to round to a whole percent, e.g. '<1%'.")
        }
        return (Double(Int(percent.rounded())) / 100).formatted(.percent)
    }
}
