import AppKit
import ImageIO
import VitrineFormats
import VitrineUI

/// Format view F5, option A (picked): a book or comic on the card's lit stage. The cover stands on a plinth like a
/// book in a shop window, and the contents (chapters, or a comic's pages) sit beside the details, as
/// `design/mockups/formats/decisions.html` draws it. A book without a readable cover gets a calm generated cover
/// with its title. Covers are decoded off the main thread through ImageIO at the size drawn; nothing is fetched or
/// written. roadmap: S-23
@MainActor
final class BookStageView: NSView {
    enum Kind: Equatable { case book, comic }

    let kind: Kind
    let title: String
    let coverView: DocStageCoverView
    let contentsGroup: DocStageGroupView
    let detailsGroup: DocStageGroupView
    private var coverTask: Task<Void, Never>?
    private var coverFrame = NSRect.zero
    private var plinthFrame = NSRect.zero

    /// Narrower than this, the groups step aside and the cover stands alone.
    static let groupsMinWidth: CGFloat = 560

    convenience init(book: MediaBookSummary) {
        let title = book.title.flatMap { $0.isEmpty ? nil : $0 } ?? book.headline
        let authors = book.creators.filter { $0.role == nil || $0.role == "aut" }.map(\.name)
        var details: [DocStageGroupView.Row] = []
        if !authors.isEmpty {
            details.append(.init(key: String(localized: "Author", bundle: .previewKit, comment: "Book stage detail label: who wrote the book."),
                                 value: authors.joined(separator: ", ")))
        }
        let translators = book.creators.filter { $0.role == "trl" }.map(\.name)
        if !translators.isEmpty {
            details.append(.init(key: String(localized: "Translator", bundle: .previewKit, comment: "Book stage detail label: who translated the book."),
                                 value: translators.joined(separator: ", ")))
        }
        if let publisher = book.publisher {
            details.append(.init(key: String(localized: "Publisher", bundle: .previewKit, comment: "Book or comic stage detail label."), value: publisher))
        }
        if let date = book.date {
            details.append(.init(key: String(localized: "Published", bundle: .previewKit, comment: "Book stage detail label: the publication date."),
                                 value: Self.publicationDate(date)))
        }
        if let language = book.language {
            details.append(.init(key: String(localized: "Language", bundle: .previewKit, comment: "Book stage detail label."),
                                 value: Locale.current.localizedString(forIdentifier: language) ?? language))
        }
        if let identifier = book.identifiers.first {
            details.append(.init(key: String(localized: "Identifier", bundle: .previewKit, comment: "Book stage detail label: the ISBN or UUID."),
                                 value: identifier, middleTruncate: true))
        }
        if let version = book.epubVersion {
            details.append(.init(key: String(localized: "Format", bundle: .previewKit, comment: "Book stage detail label: the EPUB version."),
                                 value: "EPUB \(version)"))
        }
        details.append(book.isProtected
            ? .init(key: String(localized: "Protection", bundle: .previewKit, comment: "Book stage detail label: whether the book has copy protection (DRM)."),
                    value: String(localized: "DRM, may not open here", bundle: .previewKit, comment: "Book stage detail value: the book is copy protected."),
                    tone: .caution, chip: 1)
            : .init(key: String(localized: "Protection", bundle: .previewKit, comment: "Book stage detail label: whether the book has copy protection (DRM)."),
                    value: String(localized: "None", bundle: .previewKit, comment: "Book stage detail value: no copy protection.")))

        var contents: [DocStageGroupView.Row] = []
        var chapter = 0
        for entry in book.tableOfContents.prefix(DocStageGroupView.maxRows) {
            if entry.depth <= 1 { chapter += 1 }
            contents.append(.init(key: entry.title, lead: entry.depth <= 1 ? "\(chapter)" : nil, indent: CGFloat(max(0, entry.depth - 1)) * 14))
        }
        if contents.isEmpty {
            contents.append(.init(key: String(localized: "This book has no contents list", bundle: .previewKit,
                                              comment: "Book stage: shown in the contents group when the EPUB has no table of contents."), tone: .quiet))
        }
        let count = book.tableOfContents.count
        let contentsTitle = count == 0
            ? String(localized: "Contents", bundle: .previewKit, comment: "Book stage group heading: the table of contents.")
            : String(localized: "Contents · \(count)\(book.truncated ? "+" : "")", bundle: .previewKit,
                     comment: "Book stage group heading; the argument is the number of entries in the table of contents.")
        self.init(kind: .book, title: title, author: authors.first, cover: book.cover?.data, contentsTitle: contentsTitle,
                  contents: contents, details: details, hidden: count > contents.count ? count - contents.count : 0)
    }

    convenience init(comic: MediaComicSummary) {
        let title = comic.title.flatMap { $0.isEmpty ? nil : $0 } ?? comic.series ?? comic.headline
        var details: [DocStageGroupView.Row] = []
        func add(_ key: String, _ value: String?) { if let value, !value.isEmpty { details.append(.init(key: key, value: value)) } }
        add(String(localized: "Series", bundle: .previewKit, comment: "Comic stage detail label."), comic.series)
        add(String(localized: "Issue", bundle: .previewKit, comment: "Comic stage detail label: the issue number."), comic.number)
        add(String(localized: "Writer", bundle: .previewKit, comment: "Comic stage detail label."), comic.writer)
        add(String(localized: "Artist", bundle: .previewKit, comment: "Comic stage detail label."), comic.artist)
        add(String(localized: "Publisher", bundle: .previewKit, comment: "Book or comic stage detail label."), comic.publisher)
        add(String(localized: "Year", bundle: .previewKit, comment: "Comic stage detail label."), comic.year)
        add(String(localized: "Archive", bundle: .previewKit, comment: "Comic stage detail label: the container format (ZIP, RAR…)."), comic.container)
        add(String(localized: "Pages", bundle: .previewKit, comment: "Comic stage detail label: number of pages."), "\(comic.pageCount)")

        var pages: [DocStageGroupView.Row] = comic.pages.prefix(DocStageGroupView.maxRows).enumerated().map { i, path in
            .init(key: (path as NSString).lastPathComponent, lead: "\(i + 1)", middleTruncate: true)
        }
        if pages.isEmpty {
            pages.append(.init(key: String(localized: "No pages found", bundle: .previewKit, comment: "Comic stage: the archive holds no page images."), tone: .quiet))
        }
        let pagesTitle = String(localized: "Pages · \(comic.pageCount)", bundle: .previewKit,
                                comment: "Comic stage group heading; the argument is the number of pages.")
        self.init(kind: .comic, title: title, author: comic.writer, cover: comic.cover?.data, contentsTitle: pagesTitle,
                  contents: pages, details: details, hidden: max(0, comic.pageCount - pages.count))
    }

    private init(kind: Kind, title: String, author: String?, cover: Data?, contentsTitle: String,
                 contents: [DocStageGroupView.Row], details: [DocStageGroupView.Row], hidden: Int) {
        self.kind = kind
        self.title = title
        coverView = DocStageCoverView(title: title, author: author)
        contentsGroup = DocStageGroupView(title: contentsTitle, rows: contents, alsoHidden: hidden)
        detailsGroup = DocStageGroupView(title: String(localized: "Details", bundle: .previewKit, comment: "Book or comic stage group heading."),
                                         rows: details)
        super.init(frame: .zero)
        addSubview(coverView)
        addSubview(contentsGroup)
        addSubview(detailsGroup)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        if let cover {
            coverView.state = .loading
            coverTask = Task { [weak self] in
                let decoded = await Task.detached(priority: .userInitiated) { DocStageImage.decode(cover, maxPixel: 900) }.value
                guard let self else { return }
                self.coverView.state = decoded.map { .image($0.cgImage) } ?? .generated
                self.needsLayout = true
                self.needsDisplay = true
            }
        } else {
            coverView.state = .generated
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Waits until the cover is decoded (or known to be unreadable) and drawn in its final state.
    func waitUntilDrawn() async { await coverTask?.value }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let wide = w >= Self.groupsMinWidth
        let plinthH: CGFloat = 12
        let coverH = max(96, min(h - plinthH - 28, 300))
        let coverW = (coverH * coverView.aspect).rounded()
        let zone = wide ? max(coverW + 80, 250) : w
        let top = ((h - coverH - plinthH) / 2).rounded()
        coverFrame = NSRect(x: ((zone - coverW) / 2).rounded(), y: top, width: coverW, height: coverH)
        plinthFrame = NSRect(x: coverFrame.minX - 30, y: coverFrame.maxY, width: coverW + 60, height: plinthH)
        coverView.frame = coverFrame

        contentsGroup.isHidden = !wide
        detailsGroup.isHidden = !wide
        if wide {
            let x0 = zone + 8, gap: CGFloat = 14
            let available = w - x0
            let contentsW = ((available - gap) * 1.4 / 2.4).rounded()
            let groupTop = max(0, top - 4), groupBottom = min(h, plinthFrame.maxY)
            contentsGroup.frame = NSRect(x: x0, y: groupTop, width: contentsW, height: groupBottom - groupTop)
            detailsGroup.frame = NSRect(x: x0 + contentsW + gap, y: groupTop, width: available - contentsW - gap, height: groupBottom - groupTop)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The plinth: a low slab in the card colour with its hairline, a soft contact shadow under it.
        DocStage.drawPanel(plinthFrame, radius: plinthFrame.height / 2, fill: "card", ring: "hair", shadow: "shadow-card")
        let top = NSRect(x: plinthFrame.minX + 6, y: plinthFrame.minY, width: plinthFrame.width - 12, height: 1)
        NSColor.token("sep").setFill()
        top.fill()
        // The cover's own drop shadow (the object shadow token), painted under the cover view.
        DocStage.drawPanel(coverFrame, radius: 4, fill: "card", ring: nil, shadow: "shadow-obj")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// "2026-01-02" → "2 January 2026", "2025-03" → "March 2025", "2025" stays; anything else as written.
    static func publicationDate(_ raw: String) -> String {
        let parts = raw.prefix(10).split(separator: "-").map { Int($0) }
        guard let year = parts.first ?? nil, raw.count >= 4 else { return raw }
        var components = DateComponents(year: year, month: 1, day: 1)
        var template = "y"
        if parts.count > 1, let month = parts[1], (1...12).contains(month) {
            components.month = month
            template = "MMMMy"
            if parts.count > 2, let day = parts[2], (1...31).contains(day) { components.day = day; template = "dMMMMy" }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: components) else { return raw }
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

/// The cover itself: the decoded picture (aspect-filled, rounded, with a shaded spine), a calm generated cover with
/// the title when the book has none, or a quiet placeholder while the picture decodes. roadmap: S-23
@MainActor
final class DocStageCoverView: NSView {
    enum State: Equatable {
        case loading, generated, image(CGImage)

        static func == (a: State, b: State) -> Bool {
            switch (a, b) {
            case (.loading, .loading), (.generated, .generated): true
            case let (.image(x), .image(y)): x === y
            default: false
            }
        }
    }

    let title: String
    let author: String?
    var state: State = .loading {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(String(localized: "Cover of \(title)", bundle: .previewKit, comment: "Accessibility label of a book cover; the argument is the title."))
        }
    }

    /// Width over height: the picture's own, kept within book-like bounds; 0.68 for a generated cover.
    var aspect: CGFloat {
        guard case .image(let image) = state, image.height > 0 else { return 0.68 }
        return min(0.9, max(0.5, CGFloat(image.width) / CGFloat(image.height)))
    }

    var isGenerated: Bool { state == .generated }

    init(title: String, author: String?) {
        self.title = title
        self.author = author
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let shape = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        switch state {
        case .loading:
            NSColor.token("fill2").setFill()
            rect.fill()
        case .image(let image):
            guard let context = NSGraphicsContext.current?.cgContext else { break }
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            // The view is flipped; draw the image upright.
            context.saveGState()
            context.translateBy(x: 0, y: rect.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: NSRect(x: target.minX, y: rect.height - target.maxY, width: target.width, height: target.height))
            context.restoreGState()
        case .generated:
            drawGenerated(in: rect)
        }
        // The spine: a shadow along the left edge, then a faint highlight, as on a paperback.
        let spine = NSGradient(colors: [NSColor.black.withAlphaComponent(0.30), NSColor.black.withAlphaComponent(0.0)])
        spine?.draw(in: NSRect(x: 0, y: 0, width: 10, height: rect.height), angle: 0)
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSRect(x: 10, y: 0, width: 1, height: rect.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        // A hairline edge so a pale cover still reads against the stage.
        NSColor.black.withAlphaComponent(0.18).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 4, yRadius: 4)
        edge.lineWidth = 0.5
        edge.stroke()
    }

    /// One of the calm series colours, chosen by the title so a book always gets the same cover: deep at the top,
    /// lighter at the foot, the title set in the serif face with rules above and below, the author in spaced capitals.
    private func drawGenerated(in rect: NSRect) {
        let tones = ["series-1", "series-3", "series-5", "series-6", "series-2", "series-4"]
        let seed = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        let base = NSColor.token(tones[seed % tones.count]).usingColorSpace(.sRGB) ?? .gray
        let deep = base.shadow(withLevel: 0.62) ?? base
        let mid = base.shadow(withLevel: 0.30) ?? base
        NSGradient(colors: [deep, mid, base], atLocations: [0, 0.6, 1], colorSpace: .sRGB)?.draw(in: rect, angle: 90)

        let ink = NSColor.white.withAlphaComponent(0.94)
        let width = rect.width
        let titleSize = max(12, (width * 0.115).rounded())
        let serif = NSFont.systemFont(ofSize: titleSize, weight: .bold).fontDescriptor.withDesign(.serif)
            .flatMap { NSFont(descriptor: $0, size: titleSize) } ?? NSFont.boldSystemFont(ofSize: titleSize)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byWordWrapping
        centered.lineHeightMultiple = 1.05
        let titleText = NSAttributedString(string: title, attributes: [.font: serif, .foregroundColor: ink, .paragraphStyle: centered])
        let inset = (width * 0.12).rounded()
        let titleBox = NSRect(x: inset, y: rect.height * 0.16, width: width - 2 * inset, height: rect.height * 0.46)
        let used = titleText.boundingRect(with: titleBox.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
        titleText.draw(with: NSRect(x: titleBox.minX, y: titleBox.minY, width: titleBox.width, height: min(used.height, titleBox.height)),
                       options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        NSColor.white.withAlphaComponent(0.45).setFill()
        let rule = (width * 0.22).rounded()
        NSRect(x: rect.midX - rule / 2, y: titleBox.minY - 12, width: rule, height: 1).fill()
        NSRect(x: rect.midX - rule / 2, y: titleBox.minY + min(used.height, titleBox.height) + 10, width: rule, height: 1).fill()

        if let author, !author.isEmpty {
            let small = systemFont(max(8, (width * 0.055).rounded()), cssWeight: 600)
            let authorText = NSAttributedString(string: author.uppercased(), attributes: [
                .font: small, .foregroundColor: ink, .kern: small.pointSize * 0.14, .paragraphStyle: centered,
            ])
            authorText.draw(with: NSRect(x: inset / 2, y: rect.height - small.pointSize * 2.6, width: width - inset, height: small.pointSize * 1.5),
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Shared parts of the document stage views (F5 book, F6 email, F7 invite and contact)

/// A decoded picture carried across the decode task (CGImage is immutable). roadmap: S-23
struct DocStageImage: @unchecked Sendable {
    let cgImage: CGImage

    /// The picture at most `maxPixel` on its long side, decoded now (not lazily at first draw), oriented upright;
    /// nil when ImageIO cannot read it. Runs off the main actor.
    nonisolated static func decode(_ data: Data, maxPixel: Int) -> DocStageImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return DocStageImage(cgImage: image)
    }
}

/// Drawing helpers the document stage views share: token panels with the system's box-shadow tokens read for the
/// current appearance, labels for frame layout, initials. roadmap: S-23
@MainActor
enum DocStage {
    /// A box-shadow token (`shadow-obj`, `shadow-pop`, `shadow-card`) for the current drawing appearance: its 0.5 pt
    /// ring colour and its softest drop as an NSShadow.
    static func shadow(_ token: String) -> (ring: NSColor?, drop: NSShadow?) {
        guard let value = GeneratedTokens.shadows.first(where: { $0.name == token }) else { return (nil, nil) }
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var ring: NSColor?, drop: NSShadow?, widest: Double = -1
        for part in topLevelParts(dark ? value.dark : value.light) where !part.hasPrefix("inset") {
            guard let start = part.range(of: "rgba(") ?? part.range(of: "rgb(") ?? part.range(of: "#"),
                  let color = NSColor(css: String(part[start.lowerBound...])) else { continue }
            let numbers = part[..<start.lowerBound].split(separator: " ").compactMap { Double($0.replacingOccurrences(of: "px", with: "")) }
            guard numbers.count >= 3 else { continue }
            if numbers.count >= 4, numbers[2] == 0, numbers[3] > 0 { ring = color; continue }
            if numbers[2] > widest {
                widest = numbers[2]
                let s = NSShadow()
                s.shadowColor = color
                // NSShadow offsets are in base coordinates (y up), whatever the view's flip.
                s.shadowOffset = NSSize(width: numbers[0], height: -numbers[1])
                s.shadowBlurRadius = numbers[2]
                drop = s
            }
        }
        return (ring, drop)
    }

    /// Splits a CSS list at its top-level commas (not those inside `rgba(…)`).
    static func topLevelParts(_ css: String) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for ch in css {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if ch == ",", depth == 0 { parts.append(current.trimmingCharacters(in: .whitespaces)); current = "" } else { current.append(ch) }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        return parts
    }

    /// A rounded panel in a fill token, with a ring token (0.5 pt) and a shadow token's drop.
    static func drawPanel(_ rect: NSRect, radius: CGFloat, fill: String, ring: String?, shadow token: String?) {
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let shadow = token.map { Self.shadow($0) }
        NSGraphicsContext.saveGraphicsState()
        shadow?.drop?.set()
        NSColor.token(fill).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        if let ringColor = ring.map({ NSColor.token($0) }) ?? shadow?.ring {
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
            edge.lineWidth = 0.5
            ringColor.setStroke()
            edge.stroke()
        }
    }

    /// A label for frame layout (the card's `cardLabel`, with its frame its own).
    static func label(_ text: String, font: NSFont, color: String, lines: Int = 1, alignment: NSTextAlignment = .left) -> NSTextField {
        let field = cardLabel(text, font: font, color: color)
        field.translatesAutoresizingMaskIntoConstraints = true
        field.alignment = alignment
        if lines != 1 {
            field.maximumNumberOfLines = lines
            field.lineBreakMode = .byWordWrapping
            field.cell?.wraps = true
            field.cell?.truncatesLastVisibleLine = true
        }
        return field
    }

    /// The height a label needs at `width`, at most its line limit.
    static func height(_ field: NSTextField, width: CGFloat) -> CGFloat {
        let size = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)) ?? .zero
        return ceil(size.height)
    }

    /// The width a one-line label wants.
    static func width(_ field: NSTextField) -> CGFloat { ceil(field.attributedStringValue.size().width) + 4 }

    /// Up to two initials: the first letters of the first and last words ("Jonah Whitaker" → "JW"), or the first
    /// character of a name written without spaces.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "@" || $0 == "." })
            .filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return name.first.map { String($0).uppercased() } ?? "?" }
        if words.count > 1, let last = words.last?.first, first.isASCII { return (String(first) + String(last)).uppercased() }
        return String(first).uppercased()
    }

    /// The avatar ground: a token colour lifted towards white at the top-left, as the design's `.avatar` gradient.
    static func avatarColors(_ token: String = "kind-text") -> (NSColor, NSColor) {
        let base = NSColor.token(token).usingColorSpace(.sRGB) ?? .gray
        return (base.blended(withFraction: 0.32, of: .white) ?? base, base)
    }

    /// A round avatar: the picture clipped to a circle, or initials on the avatar gradient; a hairline ring.
    static func drawAvatar(in rect: NSRect, initials: String, image: CGImage?, flipped: Bool) {
        let circle = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        if let image, let context = NSGraphicsContext.current?.cgContext {
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            context.saveGState()
            if flipped {
                context.translateBy(x: 0, y: rect.midY * 2)
                context.scaleBy(x: 1, y: -1)
            }
            context.interpolationQuality = .high
            context.draw(image, in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            context.restoreGState()
        } else {
            let (light, deep) = avatarColors()
            NSGradient(starting: light, ending: deep)?.draw(in: rect, angle: flipped ? -45 : 45)
            let font = systemFont(max(7, (rect.height * 0.36).rounded()), cssWeight: 600)
            let text = NSAttributedString(string: initials, attributes: [.font: font, .foregroundColor: NSColor.token("on-accent"),
                                                                         .kern: font.pointSize * 0.02])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25))
        ring.lineWidth = 0.5
        NSColor.token("hair").setStroke()
        ring.stroke()
    }

    /// A numbered finding chip (`.nchip`): a 16 pt circle in the strong caution or danger colour, white 10.5/700.
    static func drawNumberChip(_ number: Int, at origin: NSPoint, danger: Bool) {
        let rect = NSRect(x: origin.x, y: origin.y, width: 16, height: 16)
        NSColor.token(danger ? "danger-strong" : "caution-strong").setFill()
        NSBezierPath(ovalIn: rect).fill()
        let text = NSAttributedString(string: "\(number)", attributes: [.font: tokenFont("fs-micro", weight: 700),
                                                                        .foregroundColor: NSColor.token("on-accent")])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

/// An inset group (`.gh` heading over a `.gp` panel of `.c-row`s, cards r3-a): 32 pt rows, the key in t1 (with an
/// optional leading number in t3 and an indent), the value right-aligned in t2 or the caution or danger text colour
/// with its numbered chip. Rows that do not fit the height give way to an "N more" row. roadmap: S-23
@MainActor
final class DocStageGroupView: NSView {
    struct Row: Equatable {
        enum Tone: Equatable { case plain, quiet, caution, danger }
        var key: String
        var value: String = ""
        var tone: Tone = .plain
        var lead: String?
        var indent: CGFloat = 0
        var chip: Int?
        var middleTruncate = false
    }

    static let maxRows = 40
    static let rowHeight: CGFloat = 32
    static let headingHeight: CGFloat = 21

    let rows: [Row]
    let heading: NSTextField
    private(set) var keyFields: [NSTextField] = []
    private(set) var valueFields: [NSTextField] = []
    private var leadFields: [NSTextField?] = []
    let moreField: NSTextField
    /// Rows past `maxRows` (or the reader's own cap) that the "more" row counts too.
    let alsoHidden: Int
    private(set) var visibleRowCount = 0
    private var panel = NSRect.zero
    private var chipOrigins: [(Int, NSPoint, Bool)] = []

    init(title: String, rows: [Row], alsoHidden: Int = 0) {
        self.rows = Array(rows.prefix(Self.maxRows))
        self.alsoHidden = alsoHidden + max(0, rows.count - Self.maxRows)
        heading = DocStage.label(title, font: tokenFont("fs-sub", weight: 600), color: "t2")
        moreField = DocStage.label("", font: tokenFont("fs-callout"), color: "t2")
        super.init(frame: .zero)
        addSubview(heading)
        let font = tokenFont("fs-callout")
        for row in self.rows {
            let key = DocStage.label(row.key, font: font, color: row.tone == .quiet ? "t3" : "t1")
            key.lineBreakMode = row.middleTruncate ? .byTruncatingMiddle : .byTruncatingTail
            let valueColor = switch row.tone {
            case .caution: "caution-text"
            case .danger: "danger-text"
            default: "t2"
            }
            let weight = row.tone == .danger ? 600 : row.tone == .caution ? 500 : 400
            let value = DocStage.label(row.value, font: tokenFont("fs-callout", weight: weight), color: valueColor, alignment: .right)
            value.lineBreakMode = row.middleTruncate ? .byTruncatingMiddle : .byTruncatingTail
            value.toolTip = row.value
            let lead = row.lead.map { DocStage.label($0, font: tabularFigures(font), color: "t3") }
            if let lead { addSubview(lead) }
            addSubview(key)
            addSubview(value)
            keyFields.append(key)
            valueFields.append(value)
            leadFields.append(lead)
        }
        addSubview(moreField)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width
        heading.frame = NSRect(x: 4, y: 0, width: max(0, w - 8), height: 15)
        let room = max(0, bounds.height - Self.headingHeight)
        let fit = max(1, Int(room / Self.rowHeight))
        let total = rows.count + alsoHidden
        let showMore = total > fit && total > rows.count || rows.count > fit
        visibleRowCount = showMore ? min(rows.count, max(0, fit - 1)) : rows.count
        let shown = visibleRowCount + (showMore ? 1 : 0)
        panel = NSRect(x: 0, y: Self.headingHeight, width: w, height: CGFloat(shown) * Self.rowHeight)
        chipOrigins = []
        for (i, row) in rows.enumerated() {
            let visible = i < visibleRowCount
            keyFields[i].isHidden = !visible
            valueFields[i].isHidden = !visible
            leadFields[i]?.isHidden = !visible
            guard visible else { continue }
            let y = panel.minY + CGFloat(i) * Self.rowHeight
            let lineH: CGFloat = 16
            let ty = y + (Self.rowHeight - lineH) / 2
            var x = 12 + row.indent
            if let lead = leadFields[i] {
                lead.frame = NSRect(x: x, y: ty, width: 20, height: lineH)
                x += 22
            }
            let valueWant = row.value.isEmpty ? 0 : min(DocStage.width(valueFields[i]), (w - x - 12) * 0.62)
            let chipW: CGFloat = row.chip == nil ? 0 : 20
            let keyWant = DocStage.width(keyFields[i])
            let keyW = max(0, min(keyWant, w - x - 12 - valueWant - chipW - (valueWant > 0 ? 10 : 0)))
            keyFields[i].frame = NSRect(x: x, y: ty, width: keyW, height: lineH)
            let valueX = max(x + keyW + 10 + chipW, w - 12 - valueWant)
            valueFields[i].frame = NSRect(x: valueX, y: ty, width: max(0, w - 12 - valueX), height: lineH)
            if let chip = row.chip {
                chipOrigins.append((chip, NSPoint(x: valueX - 20, y: y + 8), row.tone == .danger))
            }
        }
        moreField.isHidden = !showMore
        if showMore {
            let hidden = total - visibleRowCount
            moreField.stringValue = String(localized: "\(hidden) more", bundle: .previewKit,
                                           comment: "Last row of a stage group that has more rows than fit; the argument is how many are not shown.")
            moreField.frame = NSRect(x: 12, y: panel.minY + CGFloat(visibleRowCount) * Self.rowHeight + 8, width: max(0, w - 24), height: 16)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        DocStage.drawPanel(panel, radius: Metric.value("r-card"), fill: "card", ring: "hair", shadow: nil)
        NSColor.token("sep").setFill()
        let lines = visibleRowCount + (moreField.isHidden ? 0 : 1)
        for i in 1..<max(1, lines) {
            NSRect(x: panel.minX, y: panel.minY + CGFloat(i) * Self.rowHeight, width: panel.width, height: 0.5).fill()
        }
        for (number, origin, danger) in chipOrigins { DocStage.drawNumberChip(number, at: origin, danger: danger) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
