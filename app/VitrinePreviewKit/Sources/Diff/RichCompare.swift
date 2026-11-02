import Foundation
import UniformTypeIdentifiers
import VitrineCompare
import VitrineData
import VitrineSupport
import VitrineText

/// The two-file compares that are not line diffs (diff design: structural JSON, rich prose, notebook cells, images in
/// 2-up, swipe, onion skin and difference), chosen by the files' type; the engines are VitrineCompare's. Each keeps
/// the design's one shape: a lead, a "what changed" list, a detail; JSON and Markdown keep their line diff one switch
/// away (Text, Source). roadmap: S-7
struct RichCompare: Encodable {
    enum Kind: String, Encodable { case structural, prose, notebook, image }

    let type: Kind
    var structural: StructuralComparison?
    var prose: ProseComparison?
    var notebook: NotebookComparison?
    var image: ImageComparison?
    /// The two images and their difference as data: URLs (the page may load nothing else, G-9).
    var oldSrc: String?
    var newSrc: String?
    var diffSrc: String?
    /// The viewer switch's titles, in order; the page's modes have the same names.
    var modes: [String]

    /// Images above this many pixels a side are described, not compared, inside a preview (the extension's memory).
    static let maxImagePixels = 16_000_000

    /// The compare for two files of a type a rich engine reads; nil = a line diff is the compare. A file one engine
    /// cannot read (malformed JSON, an old notebook format) falls back to the line diff, with the reason kept.
    static func make(old: URL, new: URL, a: Data, b: Data) -> (RichCompare?, String?) {
        let types = (UTType(filenameExtension: old.pathExtension.lowercased()), UTType(filenameExtension: new.pathExtension.lowercased()))
        do {
            if types.0?.conforms(to: .image) == true, types.1?.conforms(to: .image) == true, types.0?.conforms(to: .svg) != true {
                var result = try ImageCompare.compare(old: a, new: b, limits: ImageCompareLimits(maxPixels: maxImagePixels))
                let diff = result.differencePNG.map { "data:image/png;base64," + $0.base64EncodedString() }
                result.differencePNG = nil
                let mime = { (t: UTType?) in t?.preferredMIMEType ?? "image/png" }
                return (RichCompare(type: .image, image: result,
                                    oldSrc: "data:\(mime(types.0));base64," + a.base64EncodedString(),
                                    newSrc: "data:\(mime(types.1));base64," + b.base64EncodedString(),
                                    diffSrc: diff, modes: ["2-up", "Swipe", "Onion skin", "Difference"]), nil)
            }
            let ext = (old.pathExtension.lowercased(), new.pathExtension.lowercased())
            if ext.0 == "ipynb", ext.1 == "ipynb" {
                return (RichCompare(type: .notebook, notebook: try NotebookCompare.compare(old: a, new: b), modes: ["Source", "Outputs"]), nil)
            }
            if ["md", "markdown", "mdown", "mkd"].contains(ext.0), ["md", "markdown", "mdown", "mkd"].contains(ext.1) {
                let prose = ProseCompare.compare(old: String(decoding: a, as: UTF8.self), new: String(decoding: b, as: UTF8.self))
                return (RichCompare(type: .prose, prose: prose, modes: ["Tracked", "Source"]), nil)
            }
            if let fa = StructuredFormat(fileExtension: ext.0), let fb = StructuredFormat(fileExtension: ext.1), fa == fb, fa != .xml {
                return (RichCompare(type: .structural, structural: try JSONCompare.compare(old: a, new: b, format: fa), modes: ["Structure", "Text"]), nil)
            }
        } catch let error as CompareError {
            return (nil, error.description)
        } catch {
            return (nil, error.localizedDescription)
        }
        return (nil, nil)
    }

    // MARK: Lead and list

    /// The lead's sentence and line, the pill's headline, and the "what changed" list for this compare.
    func lead(oldName: String, newName: String) -> (sentence: String, meta: String, headline: String, items: [DiffPage.Compare.Item]) {
        let names = "\(oldName) ⇄ \(newName)"
        switch type {
        case .structural:
            let s = structural!
            let unchanged = s.counts.unchangedValues
            let items = s.changes.map { c -> DiffPage.Compare.Item in
                // The key path is the file's own (`servers[0].port`), never translated.
                let title = switch c.kind {
                case .changed: String(localized: "Changed \(c.path)", bundle: .previewKit, comment: "Structured compare change: a value at a key path changed.")
                case .added: String(localized: "Added \(c.path)", bundle: .previewKit, comment: "Structured compare change: a key path was added.")
                case .removed: String(localized: "Removed \(c.path)", bundle: .previewKit, comment: "Structured compare change: a key path was removed.")
                case .typeChanged: String(localized: "Type changed \(c.path)", bundle: .previewKit,
                                          comment: "Structured compare change: the type of the value at a key path changed.")
                }
                let detail = [c.old, c.new].compactMap { $0 }.joined(separator: " → ")
                return .init(title: title, detail: detail.isEmpty ? nil : detail, line: nil, additions: 0, deletions: 0)
            }
            let n = s.changes.count + s.counts.reorderedObjects
            // The format's name (JSON, YAML) is a proper noun, shown as it is.
            return (s.isEqual ? String(localized: "Same data, by key", bundle: .previewKit, comment: "Structured compare lead: the data is equal when compared by key.")
                        : s.summary,
                    String(localized: "Compared by key · key order ignored · \(unchanged) values unchanged", bundle: .previewKit,
                           comment: "Structured compare meta line: how it compared, then how many values did not change."),
                    String(localized: "\(s.format.uppercased()) · \(n) changes by key", bundle: .previewKit,
                           comment: "Structured compare pill headline: the format's name, then how many changes."), items)
        case .prose:
            let p = prose!
            let items = p.changes.map { DiffPage.Compare.Item(title: "\($0.index) \($0.title)", detail: $0.detail, line: $0.block, additions: 0, deletions: 0) }
            return (p.isEqual ? String(localized: "Same text", bundle: .previewKit, comment: "Markdown compare lead: the text is the same.") : p.summary,
                    String(localized: "Rendered Markdown · tracked changes · \(names)", bundle: .previewKit,
                           comment: "Markdown compare meta line; the argument is the two file names."),
                    String(localized: "Markdown · \(p.blocksChanged) blocks changed", bundle: .previewKit,
                           comment: "Markdown compare pill headline: how many blocks (paragraphs, headings) changed."), items)
        case .notebook:
            let n = notebook!
            let items = n.changes.map { DiffPage.Compare.Item(title: "\($0.index) \($0.title)", detail: $0.detail, line: $0.index, additions: 0, deletions: 0) }
            return (n.isEqual ? String(localized: "Same notebook", bundle: .previewKit, comment: "Notebook compare lead: nothing changed.") : n.summary,
                    n.hiddenNote ?? names,
                    String(localized: "Notebook · \(n.lead)", bundle: .previewKit, comment: "Notebook compare pill headline; the argument is its summary."), items)
        case .image:
            let i = image!
            let items = i.regions.map {
                DiffPage.Compare.Item(title: String(localized: "Region \($0.index)", bundle: .previewKit, comment: "Image compare: one region that differs."),
                                      detail: String(localized: "\($0.width) × \($0.height) px", bundle: .previewKit, comment: "A region's size in pixels."),
                                      line: $0.index, additions: 0, deletions: 0)
            }
            return (i.summary, i.detail, "\(i.new.format) · \(i.new.width) × \(i.new.height)", items)
        }
    }
}
