import AppKit
import VitrineData
import VitrineDocument
import VitrineSupport
import VitrineUI

/// Structured files (JSON, JSONC, JSON5, YAML, TOML, XML, property lists including binary ones) in the picked code
/// design (S-15, design/mockups/unified/code.html states 5, 9 and 10): a native Tree, an outline of the parsed
/// document with folding, child counts, a colour and type tag per value, the selected node's path in a 30 pt path row
/// and per-node copy of its value or path. The capsule's viewer switch offers Tree, Formatted (a minified file),
/// and Source ("XML" for a binary property list, which shows its XML form); Hex is not built yet.
///
/// Which view opens first: the Tree (the design's switch reads "Tree · Source" with Tree on). A file with a syntax
/// error opens on its Source, because the tree stops at the error and would hide the rest; the Tree it could read
/// is still offered after Source, ending in the error. A file above `FamilyFacts.parseLimit` is not parsed and shows
/// its source through PlainTextRenderer, as before. The parse runs off the main thread, the outline asks for rows
/// only as they unfold, and large containers page their children, so a big document never holds up the first paint;
/// a tree a limit cut short says so in the gutter (coverage in nodes). roadmap: S-5
@MainActor
public final class StructuredRenderer: NSObject, Renderer {
    static let languages: Set<String> = ["json", "jsonc", "json5", "yaml", "toml", "xml", "plist"]

    public static func canRender(_ kind: FileKind) -> Bool {
        if case .code(let language) = kind { return languages.contains(language) }
        return false
    }

    public override required init() { super.init() }

    private(set) var view: StructuredView?
    var outlineForTesting: StructuredOutline? { view?.outline }

    /// Everything one render reads, built off the main thread.
    struct Built: Sendable {
        let document: PreviewDocument
        let result: StructuredParseResult?
        let source: Data
        /// Index of the Tree in the viewer switch, nil when there is no tree to show.
        let treeIndex: Int?
        /// The format parsed (jq reads the file again in it); nil when there is no tree.
        var format: StructuredFormat? = nil
    }

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        guard case .code(let language) = kind else { throw RenderError.unsupported(kind) }
        let built = try await Task.detached(priority: .userInitiated) {
            try StructuredRenderer.build(url: url, kind: kind, language: language)
        }.value
        try Task.checkCancellation()
        guard let built else { return try await PlainTextRenderer().render(url: url, kind: kind, context: context) }
        let view = StructuredView(built: built, context: context)
        self.view = view
        let preview = RenderedPreview(view: view, document: built.document, owner: self,
                               scrollOffset: { [weak view] in view?.scrollOffset },
                               restoreScroll: { [weak view] y in view?.restoreScroll(y) },
                               find: { [weak view] query, forward in view?.find(query, forward: forward) ?? FindResult(count: 0, index: -1) },
                               clearFind: { [weak view] in view?.clearFind() },
                               showView: { [weak view] index in view?.show(index) ?? false })
        StructuredQueryController.attach(to: preview, view: view, built: built)
        return preview
    }

    /// Reads and parses the file and lays out the viewer switch. nil = above the parse cap or not a structured
    /// format after all: the caller shows plain source.
    nonisolated static func build(url: URL, kind: FileKind, language: String) throws -> Built? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        guard size <= FamilyFacts.parseLimit else { return nil }
        let data = try Data(contentsOf: url)
        let isBinaryPlist = data.starts(with: Array("bplist".utf8))
        guard let format = isBinaryPlist ? .propertyList : FamilyFacts.structuredFormat(language: language, url: url) else { return nil }
        var options = StructuredOptions()
        options.maxInputBytes = FamilyFacts.parseLimit
        let result = StructuredParser.parse(data, format: format, options: options, fileSize: size)

        // The facts, badges and Formatted view are the text family's (FamilyFacts), so both paths agree.
        var document = FamilyFacts.structured(try PlainTextRenderer.textDocument(url: url, kind: kind), url: url, format: format)
        guard let sourceIndex = document.views.lastIndex(where: { if case .code = $0 { true } else { false } }) else { return nil }
        var sourceTitle = "Source"
        if isBinaryPlist {
            // Its bytes are not text: the source view is the property list written out as XML (state 9: "Tree XML").
            let xml = StructuredFormatter.propertyListXML(data).text
            document.views[sourceIndex] = .code(xml.isEmpty ? String(localized: "This binary property list could not be read.", bundle: .previewKit,
                                                                     comment: "In place of a binary property list's XML when it cannot be read.") : xml,
                                                language: "xml")
            sourceTitle = "XML"
        }
        var titles = document.views.map(\.title)
        titles[sourceIndex] = sourceTitle
        guard !result.tree.isEmpty else {
            document.viewTitles = titles
            return Built(document: document, result: nil, source: data, treeIndex: nil)
        }
        // The Tree's slot carries the source text, so describe, copy and Spotlight read the file as before.
        let source = document.views[sourceIndex]
        let treeIndex: Int
        if result.isValid {
            document.views.insert(source, at: 0)
            titles.insert("Tree", at: 0)
            treeIndex = 0
        } else {
            document.views.append(source)
            titles.append("Tree")
            treeIndex = document.views.count - 1
        }
        document.viewTitles = titles
        // A tree a limit cut short says so in the gutter; one cut by a syntax error opens on Source and ends in the error.
        if result.isValid, case .partial(let shown, let total, _) = result.coverage {
            document.coverage = .partial(shown: Int64(shown), total: total.map(Int64.init), unit: .nodes,
                                         reason: result.coverage.note ?? String(localized: "Part of the tree", bundle: .previewKit,
                                                                                         comment: "Why a JSON/YAML tree is shown in part."))
        }
        return Built(document: document, result: result, source: data, treeIndex: treeIndex, format: format)
    }
}

/// The renderer's own view: the Tree (path row over the outline) and, when the file opens on its source, that text.
/// `show(_:)` answers the viewer switch for the indices it draws itself.
@MainActor
final class StructuredView: NSView {
    let outline: StructuredOutline?
    /// The jq query's outputs drawn as a tree in place of the file's (I-8); nil = the file's own tree.
    private(set) var resultOutline: StructuredOutline?
    /// The tree on screen: the query's while one is shown, else the file's.
    var shownOutline: StructuredOutline? { resultOutline ?? outline }
    var queryController: StructuredQueryController?
    let pathBar = StructuredPathBar()
    let treeScroll = NSScrollView()
    private let treePane = NSView()
    /// View 0's text when view 0 is not the Tree (a file with a syntax error opens on its source).
    private var textPane: (scroll: NSScrollView, finder: TextFinder)?
    private let treeIndex: Int?
    private(set) var showsTree: Bool

    init(built: StructuredRenderer.Built, context: RenderContext) {
        treeIndex = built.treeIndex
        outline = built.result.map { StructuredOutline(model: StructuredTreeModel(result: $0, source: built.source)) }
        showsTree = built.treeIndex == 0
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true

        if let outline {
            treeScroll.documentView = outline.table
            treeScroll.hasVerticalScroller = true
            treeScroll.autohidesScrollers = true
            treeScroll.drawsBackground = false
            for v in [pathBar, treeScroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; treePane.addSubview(v) }
            NSLayoutConstraint.activate([
                pathBar.topAnchor.constraint(equalTo: treePane.topAnchor), pathBar.leadingAnchor.constraint(equalTo: treePane.leadingAnchor),
                pathBar.trailingAnchor.constraint(equalTo: treePane.trailingAnchor),
                pathBar.heightAnchor.constraint(equalToConstant: Metric.value("h-ctl-lg") + Metric.value("sp-2")),
                treeScroll.topAnchor.constraint(equalTo: pathBar.bottomAnchor), treeScroll.leadingAnchor.constraint(equalTo: treePane.leadingAnchor),
                treeScroll.trailingAnchor.constraint(equalTo: treePane.trailingAnchor), treeScroll.bottomAnchor.constraint(equalTo: treePane.bottomAnchor),
            ])
            bind(outline)
            outline.ruler = RulerScroller.install(on: treeScroll)
            outline.expandDefault()
            fill(treePane)
        }
        if built.treeIndex != 0 {
            let text: String
            switch built.document.views[0] {
            case .text(let s), .code(let s, _), .formatted(let s, _): text = s
            case .markdown: text = built.document.searchText
            }
            let (scroll, textView) = TextPreviewView.make(text: text, context: context)
            fill(scroll)
            textPane = (scroll, TextFinder(textView))
        }
        treePane.isHidden = !showsTree
        textPane?.scroll.isHidden = showsTree
    }

    required init?(coder: NSCoder) { nil }

    /// The path row follows the tree on screen.
    private func bind(_ outline: StructuredOutline) {
        let model = outline.model
        pathBar.show(model.pathComponents(of: nil), enabled: false)
        outline.onSelect = { [weak self] node in self?.pathBar.show(model.pathComponents(of: node), enabled: node != nil) }
        pathBar.onCopyPath = { [weak outline] in if let o = outline, let n = o.selectedNode { o.copyPath(of: n) } }
        pathBar.onCopyValue = { [weak outline] in if let o = outline, let n = o.selectedNode { o.copyValue(of: n) } }
    }

    /// Shows a jq query's outputs as a tree, one top-level item per output (read as JSON Lines, so each output is
    /// its own root), or the file's tree again with nil.
    func showQueryResult(_ outputs: [JQValue]?) {
        guard let outline else { return }
        resultOutline?.clearFind()
        if let outputs {
            let text = outputs.map { $0.compactJSON() }.joined(separator: "\n")
            let data = Data(text.utf8)
            var options = StructuredOptions()
            options.maxInputBytes = max(options.maxInputBytes, Int64(data.count))
            let result = StructuredParser.parse(data, format: .jsonLines, options: options, fileSize: Int64(data.count))
            let model = StructuredTreeModel(result: result, source: data)
            model.rootNoun = .result
            model.alwaysNameRoots = true
            let shown = StructuredOutline(model: model)
            resultOutline = shown
            shown.ruler = treeScroll.verticalScroller as? RulerScroller
            treeScroll.documentView = shown.table
            bind(shown)
            shown.expandDefault()
            // A table swapped in after layout starts narrow; it and its one column take the clip view's width, as
            // the file's own tree does.
            let width = treeScroll.contentView.bounds.width
            shown.table.frame.size.width = width
            shown.table.tableColumns.first?.width = width
        } else {
            resultOutline = nil
            treeScroll.documentView = outline.table
            bind(outline)
        }
        treeScroll.contentView.scroll(to: .zero)
        treeScroll.reflectScrolledClipView(treeScroll.contentView)
    }

    private func fill(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// The viewer switch: the Tree's index shows the tree; 0 shows this view's own first view; any other index is the
    /// host's to show as text.
    func show(_ index: Int) -> Bool {
        if index == treeIndex, outline != nil { setShowsTree(true); return true }
        if index == 0 { setShowsTree(false); return true }
        return false
    }

    private func setShowsTree(_ on: Bool) {
        if showsTree != on { clearFind() }
        showsTree = on
        treePane.isHidden = !on
        textPane?.scroll.isHidden = on
    }

    func find(_ query: String, forward: Bool) -> FindResult {
        if showsTree, let outline = shownOutline { return outline.find(query, forward: forward) }
        return textPane?.finder.find(query, forward: forward) ?? FindResult(count: 0, index: -1)
    }

    func clearFind() {
        outline?.clearFind()
        resultOutline?.clearFind()
        textPane?.finder.clear()
    }

    private var activeScroll: NSScrollView? { showsTree ? treeScroll : textPane?.scroll }

    var scrollOffset: Double? { activeScroll.map { Double($0.contentView.bounds.origin.y) } }

    func restoreScroll(_ y: Double) {
        guard let scroll = activeScroll else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // A layer colour is resolved once; drawing it here follows light and dark.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("page").cgColor }
}

/// "$ › notes › [3] › attachments › [0] › size" with Path and Value copy at the right: the code surface's own path
/// row (`.c-h-row`, 30 pt on card2 with a `sep` line under it); the last component on the accent tint. roadmap: S-5
@MainActor
final class StructuredPathBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private let pathButton: NSButton
    private let valueButton: NSButton
    var onCopyPath: (() -> Void)?
    var onCopyValue: (() -> Void)?
    private(set) var components: [String] = []

    override init(frame: NSRect) {
        pathButton = NSButton(title: StructuredOutline.pathWord, image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage(),
                              target: nil, action: nil)
        valueButton = NSButton(title: StructuredOutline.valueWord, image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage(),
                               target: nil, action: nil)
        super.init(frame: frame)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingHead
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, action) in [(pathButton, #selector(copyPath)), (valueButton, #selector(copyValue))] {
            button.target = self
            button.action = action
            button.imagePosition = .imageLeading
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .systemFont(ofSize: Metric.value("fs-control"))
        }
        pathButton.toolTip = String(localized: "Copy the selected node's path", bundle: .previewKit, comment: "Tooltip of the tree's Path button.")
        valueButton.toolTip = String(localized: "Copy the selected node's value", bundle: .previewKit, comment: "Tooltip of the tree's Value button.")
        let rule = Rule()
        for v in [label, pathButton, valueButton, rule] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metric.value("sp-10")),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: pathButton.leadingAnchor, constant: -Metric.value("sp-8")),
            pathButton.trailingAnchor.constraint(equalTo: valueButton.leadingAnchor, constant: -Metric.value("sp-4")),
            pathButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metric.value("sp-8")),
            valueButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor), rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor), rule.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ components: [String], enabled: Bool) {
        self.components = components
        let mono = NSFont.monospacedSystemFont(ofSize: Metric.value("fs-mono-sm"), weight: .regular)
        let text = NSMutableAttributedString()
        for (i, part) in components.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "  ›  ", attributes: [.font: mono, .foregroundColor: NSColor.token("t3")])) }
            let last = i == components.count - 1 && enabled
            var attributes: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.token(last ? "accent-text" : "t1")]
            if last { attributes[.backgroundColor] = NSColor.token("accent-soft") }
            text.append(NSAttributedString(string: last ? " \(part) " : part, attributes: attributes))
        }
        label.attributedStringValue = text
        pathButton.isEnabled = enabled
        valueButton.isEnabled = enabled
    }

    @objc private func copyPath() { onCopyPath?() }
    @objc private func copyValue() { onCopyValue?() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("card2").cgColor }

    /// The `sep` hairline under the row.
    private final class Rule: NSView {
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
        required init?(coder: NSCoder) { nil }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = NSColor.token("sep").cgColor }
    }
}
