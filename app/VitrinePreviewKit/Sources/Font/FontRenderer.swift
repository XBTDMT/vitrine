import AppKit
import CoreText
import VitrineDocument
import VitrineSupport
import VitrineUI

/// Font files on the facts card (cards.html §3b "Font in the Vitrine window"): the specimen on the stage ("Aa" with
/// up to three of the file's styles beside it, and a 12-column glyph grid), the label, then the Sizes waterfall, the
/// Font facts, the axes of a variable font and the OpenType features. The viewer switch has Glyphs (the card), Text
/// (every style in the file set as a sample) and Info (everything the name table says). The file is read in place and
/// never installed; Install… hands it to Font Book.
///
/// macOS keeps Quick Look for TrueType, OpenType and collections (measured 2026-10-30: `qlmanage -p -o` gets
/// macOS's own PDF preview for .ttf, .ttc and .otf), so those reach this card through the Vitrine window; WOFF and
/// WOFF 2 have no macOS type and no macOS preview at all, and Vitrine claims them in Quick Look. roadmap: S-23
@MainActor
public final class FontRenderer: NSObject, Renderer {
    public static func canRender(_ kind: FileKind) -> Bool { kind == .font }
    public override required init() { super.init() }

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        let info = try await Task.detached(priority: .userInitiated) { try FontFileInfo.read(url: url) }.value
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let card = FontCard.make(info, fileSize: fileSize)
        let text = FontCard.infoText(info, card: card)
        var document = PreviewDocument(kind: .font, facts: FontCard.facts(info, card: card, fileSize: fileSize),
                                       views: [.text(text), .text(text), .text(text)])
        document.viewTitles = ["Glyphs",
                               "Text",
                               "Info"]

        let specimen = FontSpecimenView(info)
        let sizes = FontWaterfallView(info)
        let view = InfoCardView(card: card, stageContent: specimen, stageHeight: .content, narrowStageHeight: nil,
                                drawn: ["sizes": sizes], facts: document.facts)
        let samples = FontSamplesView(info)
        samples.isHidden = true
        samples.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(samples)
        NSLayoutConstraint.activate([
            samples.leadingAnchor.constraint(equalTo: view.leadingAnchor), samples.trailingAnchor.constraint(equalTo: view.inspector.leadingAnchor),
            samples.topAnchor.constraint(equalTo: view.topAnchor), samples.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.onAction = { id in
            switch id {
            case "install":
                let fontBook = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FontBook")
                if let fontBook { NSWorkspace.shared.open([url], withApplicationAt: fontBook, configuration: NSWorkspace.OpenConfiguration()) }
            case "copyName":
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.family, forType: .string)
            default: break
            }
        }
        return RenderedPreview(view: view, document: document, owner: self,
                               scrollOffset: { [weak view] in view.map { Double($0.scrollView.contentView.bounds.origin.y) } },
                               restoreScroll: { [weak view] y in view?.scroll(to: CGFloat(y)) },
                               toggleInspector: { [weak view] in view?.toggleInspector() },
                               showView: { [weak view, weak samples] index in
                                   guard index <= 1 else { return false }
                                   view?.scrollView.isHidden = index == 1
                                   samples?.isHidden = index != 1
                                   return true
                               })
    }
}

extension FontFileInfo {
    /// A face at a size, with the variation (`wght` and the like) asked for where the font has the axis. The cascade
    /// list is LastResort alone, so a character the font lacks draws as LastResort's box instead of borrowing another
    /// font's glyph.
    func font(_ face: Face? = nil, size: CGFloat, variation: [String: Double] = [:]) -> NSFont {
        var descriptor = (face ?? faces[0]).descriptor
        var attributes: [CFString: Any] = [kCTFontCascadeListAttribute: [CTFontDescriptorCreateWithNameAndSize("LastResort" as CFString, 0)]]
        let usable = variation.compactMap { tag, value -> (UInt32, Double)? in
            guard let axis = axes.first(where: { $0.tag == tag }) else { return nil }
            return (tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }, min(max(value, axis.minimum), axis.maximum))
        }
        if !usable.isEmpty { attributes[kCTFontVariationAttribute] = Dictionary(uniqueKeysWithValues: usable.map { (NSNumber(value: $0.0), NSNumber(value: $0.1)) }) }
        descriptor = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    /// Up to three faces for the specimen's lines, the design's Regular, Bold and Italic where the file has them.
    var specimenFaces: [Face] {
        guard faces.count > 1 else { return faces }
        var picked: [Face] = []
        for wanted in ["Regular", "Bold", "Italic"] {
            if let f = faces.first(where: { $0.style == wanted }) ?? faces.first(where: { $0.style.contains(wanted) }),
               !picked.contains(where: { $0.fullName == f.fullName }) { picked.append(f) }
        }
        for f in faces where picked.count < 3 && !picked.contains(where: { $0.fullName == f.fullName }) { picked.append(f) }
        return Array(picked.prefix(3))
    }
}

/// The stage: padding 16; "Aa" at 64 (weight 200 where the font has a `wght` axis) beside up to three styles of the
/// sample line at 15 / 1.35, then the glyph grid, 12 columns with 5 pt gaps, square cells of radius 6 on `fill`, the
/// glyph at 19 (cards §3b). The view's height follows its width (the cells stay square). roadmap: S-23
@MainActor
final class FontSpecimenView: NSView {
    let info: FontFileInfo
    private(set) var cells: [TokenBox] = []
    private(set) var cellLabels: [NSTextField] = []
    private(set) var sampleLines: [NSTextField] = []
    private(set) var bigLabel: NSTextField!
    private var height: NSLayoutConstraint!
    static let columns = 12, gap: CGFloat = 5, padding: CGFloat = 16

    init(_ info: FontFileInfo) {
        self.info = info
        super.init(frame: .zero)
        bigLabel = cardLabel(info.sample.hasPrefix("Sphinx") ? "Aa" : String(info.gridCharacters.prefix(2).joined()),
                             font: info.font(size: 64, variation: ["wght": 200]), color: "t1")
        addSubview(bigLabel)
        let line = info.sample.hasPrefix("Sphinx") ? "Glass holds the light" : info.sample
        for face in info.specimenFaces {
            let field = cardLabel(line, font: info.font(face, size: 15), color: "t1")
            addSubview(field)
            sampleLines.append(field)
        }
        for character in info.gridCharacters.prefix(36) {
            let cell = TokenBox(fill: "fill", radius: 6)
            cell.translatesAutoresizingMaskIntoConstraints = true
            let label = cardLabel(character, font: info.font(size: 19), color: "t1")
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = true
            cell.addSubview(label)
            addSubview(cell)
            cells.append(cell); cellLabels.append(label)
        }
        height = heightAnchor.constraint(equalToConstant: 200)
        var constraints = [height!, bigLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
                           bigLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding)]
        var previous: NSView?
        let block = NSLayoutGuide()
        addLayoutGuide(block)
        constraints += [block.leadingAnchor.constraint(equalTo: bigLabel.trailingAnchor, constant: 16),
                        block.centerYAnchor.constraint(equalTo: bigLabel.centerYAnchor),
                        block.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.padding)]
        for field in sampleLines {
            constraints += [field.leadingAnchor.constraint(equalTo: block.leadingAnchor), field.trailingAnchor.constraint(lessThanOrEqualTo: block.trailingAnchor),
                            field.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? block.topAnchor)]
            previous = field
        }
        constraints.append(block.bottomAnchor.constraint(equalTo: previous?.bottomAnchor ?? block.topAnchor))
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    var cellSize: CGFloat {
        let width = bounds.width - 2 * Self.padding - CGFloat(Self.columns - 1) * Self.gap
        return max(12, floor(width / CGFloat(Self.columns)))
    }

    override func layout() {
        super.layout()
        let headerBottom = max(bigLabel.frame.maxY, sampleLines.last?.frame.maxY ?? 0) + 12
        let size = cellSize
        for (i, cell) in cells.enumerated() {
            let column = i % Self.columns, row = i / Self.columns
            cell.frame = NSRect(x: Self.padding + CGFloat(column) * (size + Self.gap), y: headerBottom + CGFloat(row) * (size + Self.gap), width: size, height: size)
            let label = cellLabels[i]
            let fitted = label.fittingSize
            label.frame = NSRect(x: 0, y: (size - fitted.height) / 2, width: size, height: fitted.height)
        }
        let rows = (cells.count + Self.columns - 1) / Self.columns
        let wanted = headerBottom + CGFloat(rows) * size + CGFloat(max(rows - 1, 0)) * Self.gap + Self.padding
        if bounds.width > 0, abs(height.constant - wanted) > 0.5 { height.constant = wanted }
    }
}

/// The Sizes block: the sample line at 9, 12, 16, 22 and 30 pt, each with its size in a 22 pt column at 10 pt t2;
/// weights 300 to 700 down the column where the font has a `wght` axis, as the design draws its variable font.
/// roadmap: S-23
@MainActor
final class FontWaterfallView: NSView {
    static let sizes: [(CGFloat, Double)] = [(9, 300), (12, 400), (16, 500), (22, 600), (30, 700)]
    private(set) var lines: [NSTextField] = []

    init(_ info: FontFileInfo) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        var previous: NSView?
        var constraints: [NSLayoutConstraint] = []
        for (size, weight) in Self.sizes {
            let number = cardLabel(String(Int(size)), font: .systemFont(ofSize: 10), color: "t2")
            number.alignment = .right
            let line = cardLabel(info.sample, font: info.font(size: size, variation: ["wght": weight]), color: "t1")
            line.lineBreakMode = .byClipping
            addSubview(number); addSubview(line)
            constraints += [
                number.leadingAnchor.constraint(equalTo: leadingAnchor), number.widthAnchor.constraint(equalToConstant: 22),
                line.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 10),
                line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                line.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? topAnchor),
                number.firstBaselineAnchor.constraint(equalTo: line.firstBaselineAnchor),
                line.heightAnchor.constraint(greaterThanOrEqualToConstant: (size * 1.25).rounded()),
            ]
            previous = line
            lines.append(line)
        }
        if let previous { constraints.append(bottomAnchor.constraint(equalTo: previous.bottomAnchor)) }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }
}

/// The Text view (not in the design; the plainest form): every style in the file, its name in 11.5 t2, the sample at
/// 28 pt and a paragraph of the grid's characters at 14 pt, top to bottom in a scroll view; up to 60 styles.
/// roadmap: S-23
@MainActor
final class FontSamplesView: NSView {
    private(set) var styleNames: [String] = []
    let scrollView = NSScrollView()

    init(_ info: FontFileInfo) {
        super.init(frame: .zero)
        wantsLayer = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let doc = CardFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = doc
        addSubview(scrollView)
        var constraints = [
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor), scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor), doc.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ]
        var previous: NSView?
        let paragraph = info.sample + (info.sample.hasPrefix("Sphinx") ? ". 0123456789 & @ ? ! “quotes” — ‘fi fl’ (1/2)" : "")
        for face in info.faces.prefix(60) {
            let name = cardLabel(face.fullName, font: tokenFont("fs-sub", weight: 600), color: "t2")
            let big = cardLabel(info.sample, font: info.font(face, size: 28), color: "t1")
            big.lineBreakMode = .byClipping
            let body = WrappingLabel(paragraph, font: info.font(face, size: 14), color: "t1", lines: 0)
            for v in [name, big, body] as [NSView] { doc.addSubview(v) }
            constraints += [
                name.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? doc.topAnchor, constant: previous == nil ? 16 : 22),
                name.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
                name.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -20),
                big.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4), big.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                big.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -20),
                body.topAnchor.constraint(equalTo: big.bottomAnchor, constant: 4), body.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            ]
            previous = body
            styleNames.append(face.fullName)
        }
        if let previous { constraints.append(doc.bottomAnchor.constraint(equalTo: previous.bottomAnchor, constant: 16)) }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.token("page").cgColor }
    }
}
