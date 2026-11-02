import AppKit
import VitrineDocument
import VitrineSupport
import VitrineUI

/// Unknown binaries (FileKind.binary) in the native hex inspector (code design state 13, E-8). The viewer switch
/// offers Hex (drawn natively) and Strings (the printable runs, as text); the pill names a known signature
/// ("Binary · PNG image · 1.2 MB") and its tooltip says what else the first bytes show. roadmap: S-5
@MainActor
public final class HexRenderer: NSObject, Renderer {
    public static func canRender(_ kind: FileKind) -> Bool { kind == .binary }

    public override required init() { super.init() }

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        let view: HexView
        do { view = try HexView.make(url: url) } catch { throw RenderError.unreadable(url) }
        return Self.preview(view: view, document: Self.document(for: view, kind: kind), owner: self)
    }

    /// A preview around a hex view: find, clear, copy as, the drawer as the inspector, Cancel and the gutter wired to
    /// the view; view 0 is the view itself, any other index is the document's text (Strings).
    public static func preview(view: HexView, document: PreviewDocument, owner: AnyObject?) -> RenderedPreview {
        let preview = RenderedPreview(view: view, document: document, owner: owner,
            reload: { [weak view] url in
                guard let view else { throw RenderError.unreadable(url) }
                try view.reload(url: url)
                return Self.document(for: view, kind: document.kind)
            },
            scrollOffset: { [weak view] in view?.scrollOffset },
            restoreScroll: { [weak view] y in view?.restoreScroll(y) },
            toggleInspector: { [weak view] in view?.toggleInspector() },
            find: { [weak view] query, forward in await view?.find(query, forward: forward) ?? FindResult(count: 0, index: -1) },
            clearFind: { [weak view] in view?.clearFind() },
            showView: { index in index == 0 },
            findStyle: .search)
        view.onGutter = { [weak preview] status in preview?.updateGutter(status) }
        preview.copyFormats = { [weak view] in
            view?.copyOffer() ?? (String(localized: "Copy as", bundle: .previewKit, comment: "Heading of the Copy as menu."), [])
        }
        preview.cancelWork = { [weak view] in view?.cancelSearch() }
        return preview
    }

    private static let formatLabel = String(localized: "Format", bundle: .previewKit, comment: "Fact label: the file's format.")

    /// The document for a binary: Hex and Strings, the size, a known signature (also as an info badge whose evidence
    /// points at its bytes), the text it starts with, how many text runs, and the entropy of the first 64 KB.
    public static func document(for view: HexView, kind: FileKind = .binary) -> PreviewDocument {
        let source = view.source
        let dumpLength = min(source.count, 64 * 1024)
        let head = source.bytes(in: 0..<dumpLength)
        let digits = HexFormat.digits(forSize: source.count)
        var facts: [Fact] = []
        var badges: [Badge] = []
        if let signature = view.signature {
            facts.append(Fact(key: "headline", label: Self.formatLabel, value: signature.name))
            let places = signature.evidence.map { r in
                r.count == 1 ? HexFormat.offset(r.lowerBound) : "\(HexFormat.offset(r.lowerBound))–\(HexFormat.offset(r.upperBound - 1))"
            }
            let offsets = places.formatted(.list(type: .and))
            facts.append(Fact(key: "signature", label: String(localized: "Identified by", bundle: .previewKit, comment: "Fact label: the bytes that identify the file's format."),
                              value: String(localized: "bytes \(offsets)", bundle: .previewKit, comment: "Fact value: the byte offsets that identify the format, as a list (“0x00–0x07”).")))
            if let first = signature.evidence.first, let last = signature.evidence.last {
                badges.append(Badge(level: .info, title: signature.name,
                                    detail: String(localized: "The signature bytes at \(offsets) match this format", bundle: .previewKit, comment: "Badge detail: the byte offsets (a list) that identify the file's format."),
                                    evidence: first.lowerBound..<last.upperBound))
            }
        } else {
            facts.append(Fact(key: "format", label: Self.formatLabel,
                              value: String(localized: "Unknown binary", bundle: .previewKit, comment: "Fact value: the binary file's format is not recognised.")))
        }
        facts.append(DocumentFacts.size(source.count))
        if let opening = view.runs.first, opening.offset == 0 {
            facts.append(Fact(key: "starts", label: String(localized: "Starts with", bundle: .previewKit, comment: "Fact label: the text the file begins with."), value: "“\(opening.text.prefix(40))”"))
        }
        let scanned = min(source.count, HexView.runsScanLength)
        let runs = view.runs.count.formatted() + (view.runs.count >= HexView.runsLimit ? "+" : "")
        let runsValue: String
        if scanned < source.count {
            let size = ByteCountFormatter.string(fromByteCount: scanned, countStyle: .file)
            runsValue = String(localized: "\(runs) in the first \(size)", bundle: .previewKit, comment: "Fact value: how many text runs were found in the first part of the file. Arguments: the count, a size.")
        } else {
            runsValue = runs
        }
        facts.append(Fact(key: "runs", label: String(localized: "Text runs", bundle: .previewKit, comment: "Fact label: how many runs of printable text the file holds."), value: runsValue))
        if let h = HexFormat.entropy(head) {
            let bits = h.formatted(.number.precision(.fractionLength(2)))
            let first = ByteCountFormatter.string(fromByteCount: 64 * 1024, countStyle: .memory)
            let value: String
            switch (dumpLength < source.count, h > 7.5, h < 4) {
            case (true, true, _): value = String(localized: "\(bits) bits per byte (first \(first)) · looks compressed or encrypted", bundle: .previewKit, comment: "Fact value: entropy of the file's first bytes, high. Arguments: bits per byte, a size.")
            case (true, false, true): value = String(localized: "\(bits) bits per byte (first \(first)) · mostly repeated or structured", bundle: .previewKit, comment: "Fact value: entropy of the file's first bytes, low. Arguments: bits per byte, a size.")
            case (true, false, false): value = String(localized: "\(bits) bits per byte (first \(first))", bundle: .previewKit, comment: "Fact value: entropy of the file's first bytes. Arguments: bits per byte, a size.")
            case (false, true, _): value = String(localized: "\(bits) bits per byte (whole file) · looks compressed or encrypted", bundle: .previewKit, comment: "Fact value: entropy of the whole file, high; the argument is bits per byte.")
            case (false, false, true): value = String(localized: "\(bits) bits per byte (whole file) · mostly repeated or structured", bundle: .previewKit, comment: "Fact value: entropy of the whole file, low; the argument is bits per byte.")
            case (false, false, false): value = String(localized: "\(bits) bits per byte (whole file)", bundle: .previewKit, comment: "Fact value: entropy of the whole file; the argument is bits per byte.")
            }
            facts.append(Fact(key: "entropy", label: String(localized: "Entropy", bundle: .previewKit, comment: "Fact label: how random the file's bytes are, in bits per byte."), value: value))
        }
        let dump = HexFormat.dump(head, digits: digits) + (dumpLength < source.count ? "\n…" : "")
        let strings = HexFormat.strings(view.runs, scanned: scanned, total: source.count, digits: digits)
        var document = PreviewDocument(kind: kind, facts: facts, badges: badges, views: [.text(dump), .text(strings)])
        document.viewTitles = ["Hex",
                                "Strings"]
        return document
    }
}
