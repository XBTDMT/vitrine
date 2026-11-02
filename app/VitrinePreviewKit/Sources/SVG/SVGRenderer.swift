import AppKit
import OSLog
import VitrineData
import VitrineDocument
import VitrineSupport
import VitrineUI

/// SVG files in the picked data design's SVG state (D-4, design/mockups/unified/data.html "SVG preview"): the picture
/// fitted to the panel on the transparency checkerboard (`checker1`/`checker2`, or a plain light or dark ground picked
/// in the Inspector), the viewer switch offering Picture and Source (the file's text coloured as XML), the size facts
/// in the capsule's pill and in the 260 pt Inspector, and a warning badge for anything risky inside: scripts, `on…`
/// event handlers, `javascript:` links, references outside the file, `<foreignObject>` HTML, entity declarations.
///
/// How it is drawn (G-12): WebKit draws the file as an image — the bytes go into an `<img>` as a `data:` URL on a
/// page with JavaScript off, the G-9 content rule list and a CSP that allows nothing but `data:` images. WebKit's
/// SVG-as-image mode never runs script and never loads anything the file refers to; the two locks would stop it if
/// it tried. The file is never loaded as a page of its own and never handed a URL, so nothing relative resolves.
///
/// What is not drawn: a file that is not well-formed XML with an `<svg>` root (it opens on Source with the line and
/// column of the problem), and a file past the drawing limits (`Limits`), which also opens on Source and says why.
/// The scan, the colouring and the reading all run off the main thread, and the page is drawn in WebKit's own process,
/// so a huge or deeply nested file cannot hold up the first paint. roadmap: S-6
@MainActor
public final class SVGRenderer: NSObject, Renderer {
    /// The drawing limits. Measured 2026-10-29 (G-12): WebKit drew 200,000 rects in 0.63 s and a 300-deep nest, and
    /// drew nothing for a 600-deep one; so a file deeper than `maxDepth` is shown as source, not as a blank picture.
    public enum Limits {
        public static let maxDrawBytes: Int64 = 16 * 1024 * 1024
        public static let maxElements = 250_000
        public static let maxDepth = 400
        /// Source text past this many bytes is shown plain, without colours.
        public static let maxColouredBytes = 512 * 1024
        /// How long the first paint waits for WebKit before showing whatever it has drawn.
        public static let loadWait: Duration = .seconds(2)
    }

    public static func canRender(_ kind: FileKind) -> Bool { kind == .svg }

    public override required init() { super.init() }

    private(set) var view: SVGView?
    static let log = Logger(subsystem: "io.github.xbtdmt.vitrine", category: "svg")

    /// Everything one render reads, built off the main thread.
    struct Built: Sendable {
        var document: PreviewDocument
        let scan: SVGScan
        /// The bytes to draw; nil = the file is not drawn (not well-formed, past a limit).
        var drawable: Data?
        let sourceText: String
        let spans: [SVGSyntaxSpan]
        let fileSize: Int64

        var hasPicture: Bool { drawable != nil }
    }

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        var built = try await Task.detached(priority: .userInitiated) { try SVGRenderer.build(url: url) }.value
        try Task.checkCancellation()
        let view = SVGView(built: built, context: context)
        self.view = view
        if built.hasPicture {
            switch await view.drawPicture() {
            case .drawn: break
            case .refused(let badge):
                // Locked down or not drawable after all: the file opens on its source and says why.
                built = Self.withoutPicture(built, badge: badge)
                view.dropPicture(built)
            }
        }
        try Task.checkCancellation()
        let preview = RenderedPreview(view: view, document: built.document, owner: self,
                                      scrollOffset: { [weak view] in view?.scrollOffset },
                                      restoreScroll: { [weak view] y in view?.restoreScroll(y) },
                                      toggleInspector: { [weak view] in view?.toggleInspector() },
                                      find: { [weak view] query, forward in view?.find(query, forward: forward) ?? FindResult(count: 0, index: -1) },
                                      clearFind: { [weak view] in view?.clearFind() },
                                      showView: { [weak view] index in view?.show(index) ?? false })
        preview.updateGutter(GutterStatus(leading: Self.gutterLine(built.scan)))
        return preview
    }

    // MARK: The document

    /// Reads, scans and colours the file. Never throws for content; only for a file that cannot be read.
    nonisolated static func build(url: URL) throws -> Built {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let tooBig = size > Limits.maxDrawBytes
        let data: Data
        do {
            if tooBig {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                data = try handle.read(upToCount: PlainTextRenderer.firstChunk) ?? Data()
            } else {
                data = try Data(contentsOf: url)
            }
        } catch {
            throw RenderError.unreadable(url)
        }
        return build(data: data, fileSize: max(size, Int64(data.count)), truncated: tooBig)
    }

    nonisolated static func build(data: Data, fileSize: Int64, truncated: Bool) -> Built {
        let scan = SVGScanner.scan(data, truncated: truncated)
        // The source view follows the plain-text rule: a file past the streaming threshold shows its first chunk.
        let showsPart = Int64(data.count) > PlainTextRenderer.streamingThreshold || truncated
        let shown = showsPart ? data.prefix(PlainTextRenderer.firstChunk) : data
        let text = String(decoding: shown, as: UTF8.self)
        let spans = SVGScanner.syntaxSpans(text, limit: Limits.maxColouredBytes)

        var badges = riskBadges(scan)
        var drawable: Data?
        if truncated {
            let size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            let limit = ByteCountFormatter.string(fromByteCount: Limits.maxDrawBytes, countStyle: .file)
            badges.append(Badge(level: .caution, title: String(localized: "Too large to draw", bundle: .previewKit, comment: "SVG warning title."),
                                detail: String(localized: "\(size) is past the \(limit) drawing limit, so its source is shown.", bundle: .previewKit,
                                               comment: "SVG warning detail: the file's size and the drawing limit.")))
        } else if let problem = scan.problem {
            // The problem's message is the XML parser's own words.
            badges.append(Badge(level: .caution,
                                title: scan.rootName != nil && !scan.isSVG
                                    ? String(localized: "Not an SVG", bundle: .previewKit, comment: "SVG warning title: the XML's root is not <svg>.")
                                    : String(localized: "Not well-formed XML", bundle: .previewKit, comment: "SVG warning title: the file does not parse as XML."),
                                detail: String(localized: "Line \(problem.line), column \(problem.column): \(problem.message). Its source is shown instead of the picture.",
                                               bundle: .previewKit, comment: "SVG warning detail: where the XML breaks, the parser's message, then what is shown.")))
        } else if scan.elements > Limits.maxElements {
            badges.append(Badge(level: .caution, title: String(localized: "Too complex to draw", bundle: .previewKit, comment: "SVG warning title."),
                                detail: String(localized: "\(scan.elements) elements is past the \(Limits.maxElements)-element drawing limit, so its source is shown.",
                                               bundle: .previewKit, comment: "SVG warning detail: the element count and the drawing limit.")))
        } else if scan.maxDepth > Limits.maxDepth {
            badges.append(Badge(level: .caution, title: String(localized: "Nested too deeply to draw", bundle: .previewKit, comment: "SVG warning title."),
                                detail: String(localized: "Elements nest \(scan.maxDepth) deep, past the \(Limits.maxDepth)-level drawing limit, so its source is shown.",
                                               bundle: .previewKit, comment: "SVG warning detail: how deep elements nest and the drawing limit.")))
        } else {
            drawable = SVGScanner.drawable(data, scan: scan)
        }

        let source = DocumentView.code(text, language: "xml")
        var document = PreviewDocument(kind: .svg, facts: facts(scan, fileSize: fileSize, text: text), badges: badges,
                                       views: drawable != nil ? [source, source] : [source])
        document.viewTitles = drawable != nil ? ["Picture", "Source"] : ["Source"]
        if showsPart {
            document.coverage = .partial(shown: Int64(shown.count), total: fileSize, unit: .bytes,
                                         reason: String(localized: "Large file: showing the first \(ByteCountFormatter.string(fromByteCount: Int64(PlainTextRenderer.firstChunk), countStyle: .memory)) of the source",
                                                        bundle: .previewKit, comment: "Why an SVG's source is shown in part; the argument is a size such as '8 MB'."))
        }
        return Built(document: document, scan: scan, drawable: drawable, sourceText: text, spans: spans, fileSize: fileSize)
    }

    /// The picture could not be drawn after all: Source only, with the reason.
    static func withoutPicture(_ built: Built, badge: Badge) -> Built {
        var b = built
        b.drawable = nil
        b.document.views = [b.document.views[0]]
        b.document.viewTitles = ["Source"]
        b.document.badges.append(badge)
        return b
    }

    /// The pill's headline ("128 × 128 · no scripts") and the Inspector's facts, in the design's order.
    nonisolated static func facts(_ scan: SVGScan, fileSize: Int64, text: String) -> [Fact] {
        var facts: [Fact] = []
        var headline: [String] = []
        if let d = scan.dimensions { headline.append(d) }
        headline.append(scan.scriptLike == 0
                        ? String(localized: "no scripts", bundle: .previewKit, comment: "SVG pill (lower case): the file has no scripts.")
                        : String(localized: "scripts not run", bundle: .previewKit, comment: "SVG pill (lower case): the file has scripts, which never run."))
        facts.append(Fact(key: "headline", label: FamilyFacts.summaryLabel, value: headline.joined(separator: " · ")))
        var viewBoxSize: String?
        if let vb = scan.viewBox {
            let size = "\(SVGScannerFormat.number(vb[2])) × \(SVGScannerFormat.number(vb[3]))"
            viewBoxSize = size
            let value = vb[0] == 0 && vb[1] == 0 ? size
                : String(localized: "\(size) at \(SVGScannerFormat.number(vb[0])), \(SVGScannerFormat.number(vb[1]))", bundle: .previewKit,
                         comment: "SVG viewBox fact: its size, then its origin when it is not 0, 0.")
            // viewBox is the SVG attribute's own name.
            facts.append(Fact(key: "viewBox", label: "viewBox", value: value))
        }
        // The declared size only when it says something the viewBox does not.
        if let w = scan.width, let h = scan.height, "\(w) × \(h)" != viewBoxSize {
            facts.append(Fact(key: "declaredSize", label: String(localized: "Width × height", bundle: .previewKit, comment: "SVG fact label: the declared size."),
                              value: "\(w) × \(h)"))
        }
        facts.append(DocumentFacts.size(fileSize))
        facts.append(Fact(key: "elements", label: String(localized: "Elements", bundle: .previewKit, comment: "SVG fact label: how many elements."),
                          value: scan.elements.formatted()))
        facts.append(Fact(key: "scripts", label: String(localized: "Scripts", bundle: .previewKit, comment: "SVG fact label: how many scripts."),
                          value: scan.scriptLike.formatted()))
        facts.append(Fact(key: "externalRefs", label: String(localized: "External refs", bundle: .previewKit,
                                                             comment: "SVG fact label: references to things outside the file."),
                          value: scan.externalRefs.formatted()))
        // foreignObject is the SVG element's own name.
        if scan.foreignObjects > 0 { facts.append(Fact(key: "foreignObjects", label: "foreignObject", value: scan.foreignObjects.formatted())) }
        if scan.entityDeclarations > 0 {
            facts.append(Fact(key: "entities", label: String(localized: "Entities", bundle: .previewKit, comment: "SVG fact label: XML entity declarations."),
                              value: scan.entityDeclarations.formatted()))
        }
        facts.append(DocumentFacts.lines(in: text))
        return facts
    }

    /// One warning per kind of risk. None of it runs or loads here; the warning says what would elsewhere.
    nonisolated static func riskBadges(_ scan: SVGScan) -> [Badge] {
        var badges: [Badge] = []
        if scan.scriptLike > 0 {
            // Each kind a whole counted phrase; <script>, javascript: are the code's own words.
            var parts: [String] = []
            if scan.scripts > 0 {
                parts.append(String(localized: "\(scan.scripts) <script> elements", bundle: .previewKit, comment: "SVG script warning: how many <script> elements."))
            }
            if scan.eventHandlers > 0 {
                parts.append(String(localized: "\(scan.eventHandlers) event handlers", bundle: .previewKit,
                                    comment: "SVG script warning: how many event handler attributes (onclick …)."))
            }
            if scan.javascriptURLs > 0 {
                parts.append(String(localized: "\(scan.javascriptURLs) javascript: links", bundle: .previewKit,
                                    comment: "SVG script warning: how many javascript: links."))
            }
            let list = parts.formatted(.list(type: .and, width: .narrow))
            badges.append(Badge(level: .danger, title: String(localized: "Script inside · not run", bundle: .previewKit, comment: "SVG warning title."),
                                detail: scan.scriptLike == 1
                                    ? String(localized: "\(list). A browser would run it when the file opens; Vitrine draws the file as a still image, so none of it runs.",
                                             bundle: .previewKit, comment: "SVG warning detail for one script; the argument names it.")
                                    : String(localized: "\(list). A browser would run them when the file opens; Vitrine draws the file as a still image, so none of it runs.",
                                             bundle: .previewKit, comment: "SVG warning detail for several scripts; the argument lists them.")))
        }
        if scan.externalRefs > 0 {
            // The examples are the file's own addresses.
            let examples = scan.externalExamples.joined(separator: ", ")
            badges.append(Badge(level: .caution, title: String(localized: "External references · not loaded", bundle: .previewKit, comment: "SVG warning title."),
                                detail: String(localized: "\(scan.externalRefs) references to files or addresses outside the file (\(examples)). Vitrine never loads them, so those parts are missing from the picture.",
                                               bundle: .previewKit, comment: "SVG warning detail: how many outside references, then examples in parentheses.")))
        }
        if scan.foreignObjects > 0 {
            badges.append(Badge(level: .caution, title: String(localized: "Embedded HTML", bundle: .previewKit, comment: "SVG warning title."),
                                detail: String(localized: "\(scan.foreignObjects) <foreignObject> elements carry HTML; it is drawn without scripts or loads.",
                                               bundle: .previewKit, comment: "SVG warning detail: how many <foreignObject> elements hold HTML.")))
        }
        if scan.entityDeclarations > 0 {
            badges.append(Badge(level: .info, title: String(localized: "Declares XML entities", bundle: .previewKit, comment: "SVG notice title."),
                                detail: String(localized: "\(scan.entityDeclarations) entity declarations in the document type; nothing outside the file is read for them.",
                                               bundle: .previewKit, comment: "SVG notice detail: how many XML entity declarations.")))
        }
        return badges
    }

    /// "14 elements · 0 external refs" (the design's gutter line).
    nonisolated static func gutterLine(_ scan: SVGScan) -> String {
        String(localized: "\(scan.elements) elements · \(scan.externalRefs) external refs", bundle: .previewKit,
               comment: "SVG gutter line: how many elements, then how many references outside the file.")
    }
}

/// Number formatting shared by the facts (the scanner's own helpers are internal to its module).
enum SVGScannerFormat {
    static func number(_ n: Double) -> String {
        n.rounded() == n ? Int(n).formatted() : n.formatted(.number.precision(.fractionLength(0...2)))
    }
}
