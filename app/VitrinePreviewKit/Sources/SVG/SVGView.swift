import AppKit
import VitrineData
import VitrineDocument
import VitrineUI

/// The SVG preview's own view (data design "SVG preview"): the content area — the picture on its ground, or the
/// coloured source — and the 260 pt Inspector at the right, with the facts, the Background control and the warnings.
/// `show(_:)` answers the viewer switch; the Inspector button shows and hides the side column. roadmap: S-6
@MainActor
final class SVGView: NSView {
    private let content = NSView()
    let inspector: SVGInspector
    private var inspectorWidth: NSLayoutConstraint?
    private(set) var inspectorShown = true
    private var decidedInspector = false

    private(set) var picture: SVGPicture?
    private var built: SVGRenderer.Built
    private let context: RenderContext
    private var source: (scroll: NSScrollView, textView: NSTextView, finder: TextFinder)?
    private(set) var showsPicture: Bool

    init(built: SVGRenderer.Built, context: RenderContext) {
        self.built = built
        self.context = context
        showsPicture = built.hasPicture
        let stored = context.defaults.object(forKey: SVGBackground.key) as? Int
        inspector = SVGInspector(document: built.document, background: stored.flatMap(SVGBackground.init(rawValue:)) ?? .checker,
                                 hasPicture: built.hasPicture)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        for v in [content, inspector] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        let width = inspector.widthAnchor.constraint(equalToConstant: Metric.value("w-inspector"))
        inspectorWidth = width
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspector.topAnchor.constraint(equalTo: topAnchor), inspector.bottomAnchor.constraint(equalTo: bottomAnchor),
            inspector.trailingAnchor.constraint(equalTo: trailingAnchor), width,
        ])
        inspector.onBackground = { [weak self] background in
            self?.picture?.canvas.background = background
            self?.context.defaults.set(background.rawValue, forKey: SVGBackground.key)
        }
        if built.hasPicture {
            let picture = SVGPicture()
            picture.canvas.background = inspector.background
            fill(picture.canvas)
            self.picture = picture
        } else {
            showSource()
        }
    }

    required init?(coder: NSCoder) { nil }

    private func fill(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: content.topAnchor), v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor), v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    /// Draws the picture; the renderer waits for this before the preview is shown.
    func drawPicture() async -> SVGPicture.Outcome {
        guard let picture, let data = built.drawable else { return .drawn }
        layoutSubtreeIfNeeded()
        return await picture.draw(data)
    }

    /// The picture was refused after all: Source only, the Inspector without the Background control.
    func dropPicture(_ built: SVGRenderer.Built) {
        self.built = built
        picture?.canvas.removeFromSuperview()
        picture = nil
        inspector.update(document: built.document, hasPicture: false)
        showSource()
    }

    // MARK: Viewer switch

    func show(_ index: Int) -> Bool {
        if built.hasPicture, index == 0 { setShowsPicture(true); return true }
        if index == (built.hasPicture ? 1 : 0) { setShowsPicture(false); return true }
        return false
    }

    private func setShowsPicture(_ on: Bool) {
        if !on { _ = sourcePane() }
        showsPicture = on && picture != nil
        picture?.canvas.isHidden = !showsPicture
        source?.scroll.isHidden = showsPicture
    }

    private func showSource() {
        _ = sourcePane()
        showsPicture = false
        source?.scroll.isHidden = false
    }

    /// The coloured source, made the first time it is needed (a picture usually opens without it).
    @discardableResult
    private func sourcePane() -> (scroll: NSScrollView, textView: NSTextView, finder: TextFinder) {
        if let source { return source }
        let (scroll, textView) = TextPreviewView.make(text: built.sourceText, context: context)
        SVGSourceColours.apply(built.spans, to: textView)
        fill(scroll)
        scroll.isHidden = showsPicture
        let pane = (scroll, textView, TextFinder(textView))
        source = pane
        return pane
    }

    var sourceTextViewForTesting: NSTextView? { source?.textView }

    // MARK: Find, scroll, Inspector

    /// Find searches the source (the picture has no text to mark).
    func find(_ query: String, forward: Bool) -> FindResult { sourcePane().finder.find(query, forward: forward) }
    func clearFind() { source?.finder.clear() }

    var scrollOffset: Double? {
        guard !showsPicture, let scroll = source?.scroll else { return nil }
        return Double(scroll.contentView.bounds.origin.y)
    }

    func restoreScroll(_ y: Double) {
        guard !showsPicture, let scroll = source?.scroll else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func toggleInspector() { setInspector(!inspectorShown) }

    private func setInspector(_ on: Bool) {
        inspectorShown = on
        inspector.isHidden = !on
        inspectorWidth?.constant = on ? Metric.value("w-inspector") : 0
    }

    /// The Finder preview pane and other narrow panels open without the Inspector.
    override func layout() {
        super.layout()
        if !decidedInspector, bounds.width > 0 {
            decidedInspector = true
            if bounds.width < Metric.value("w-inspector") * 2 + Metric.value("sp-32") { setInspector(false) }
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("page").cgColor }
}

/// XML colours for the source, from the code tokens (the same roles the structured tree uses for XML).
@MainActor
enum SVGSourceColours {
    static func token(_ role: SVGSyntaxSpan.Role) -> String {
        switch role {
        case .punctuation: "syn-punct"
        case .tagName: "syn-kw"
        case .attributeName: "syn-attr"
        case .attributeValue: "syn-str"
        case .comment, .declaration: "syn-com"
        case .cdata: "syn-str"
        case .entity: "syn-const"
        }
    }

    static func apply(_ spans: [SVGSyntaxSpan], to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let length = storage.length
        let colours = Dictionary(uniqueKeysWithValues: [SVGSyntaxSpan.Role.punctuation, .tagName, .attributeName, .attributeValue,
                                                        .comment, .declaration, .cdata, .entity].map { ($0, NSColor.token(token($0))) })
        storage.beginEditing()
        for span in spans where span.range.upperBound <= length {
            storage.addAttribute(.foregroundColor, value: colours[span.role] ?? NSColor.token("t1"),
                                 range: NSRange(location: span.range.lowerBound, length: span.range.count))
        }
        storage.endEditing()
    }
}
