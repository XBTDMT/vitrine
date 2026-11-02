import AppKit
import ImageIO
import UniformTypeIdentifiers
import VitrineText
import VitrineUI

/// What a peek reads: a file on disk (a folder's item) or bytes already in memory (an archive member read up to a
/// bound). `total` is the member's full size when `data` holds only its start. roadmap: S-9
enum PeekPayload: Sendable {
    case file(URL)
    case data(Data, total: Int64?)
}

/// One row the peek drawer can show: anything in a browse outline (a folder's item, an archive's member). The
/// drawer reads the payload itself, bounded, off the main thread, and draws text, an image or a facts card.
/// roadmap: S-9
@MainActor
protocol PeekItem {
    var peekName: String { get }
    /// "Markdown text", "PNG image".
    var peekKind: String { get }
    var peekSize: Int64? { get }
    /// More facts for the header and the facts card: ("Packed", "2.9 KB"), ("Modified", "Oct 3, 2026").
    var peekFacts: [(label: String, value: String)] { get }
    /// The header's line after the size, as one whole phrase ("in archive.zip", "modified Oct 3, 2026"); nil = none.
    var peekLine: String? { get }
    /// The bytes to peek at. Data payloads should hold at most `maxBytes` (the drawer never reads past it).
    func loadPeek(maxBytes: Int) async throws -> PeekPayload
}

extension PeekItem {
    var peekFacts: [(label: String, value: String)] { [] }
    /// Items that do not say their own line: the first fact as "label value", lower-cased (English word order; an
    /// item localized for H-6 gives its own `peekLine`).
    var peekLine: String? { peekFacts.first.map { "\($0.label.lowercased()) \($0.value)" } }
}

/// What the drawer draws, worked out off the main thread from a payload. roadmap: S-9
enum PeekContent: Sendable {
    /// Text read up to the bound; `markdown` = drawn with the README styles, else monospaced.
    case text(String, markdown: Bool, shownBytes: Int, totalBytes: Int64?)
    case image(PeekImage)
    /// Not text, not an image (or unreadable): the facts card; `note` says why when it is not just the type.
    case facts(note: String?)

    /// Text first N KB, images up to this many pixels on the long side.
    static let maxTextBytes = 64 << 10
    static let maxImagePixels = 2048

    /// Decides by the name's type, then by the bytes: images by ImageIO, text when the start has no NUL and reads
    /// as UTF-8, everything else as facts.
    static func make(name: String, payload: PeekPayload) -> PeekContent {
        let ext = (name as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if case .file(let url) = payload, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return .facts(note: nil) }
        if let type, type.conforms(to: .image), !type.conforms(to: .svg) {
            let source: CGImageSource?
            switch payload {
            case .file(let url): source = CGImageSourceCreateWithURL(url as CFURL, nil)
            case .data(let data, _): source = CGImageSourceCreateWithData(data as CFData, nil)
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
                                            kCGImageSourceShouldCacheImmediately: true]
            if let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return .image(PeekImage(image))
            }
            return .facts(note: String(localized: "The image could not be decoded", bundle: .previewKit, comment: "Peek drawer: an image that does not decode."))
        }
        let bytes: Data, total: Int64?
        switch payload {
        case .file(let url):
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return .facts(note: String(localized: "The file could not be read", bundle: .previewKit, comment: "Peek drawer: a file that cannot be opened."))
            }
            defer { try? handle.close() }
            bytes = (try? handle.read(upToCount: maxTextBytes)) ?? Data()
            total = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(Int64.init) }
        case .data(let data, let t):
            bytes = data.prefix(maxTextBytes)
            total = t ?? Int64(data.count)
        }
        let textual = type.map { $0.conforms(to: .text) || $0.conforms(to: .sourceCode) || $0.conforms(to: .json) || $0.conforms(to: .xml) } ?? false
        let sniffed = !bytes.prefix(8000).contains(0)
        guard sniffed, textual || (type == nil || type == .data) || ext.isEmpty else { return .facts(note: nil) }
        var text = String(decoding: bytes, as: UTF8.self)
        let truncated = (total ?? Int64(bytes.count)) > Int64(bytes.count)
        // A cut in the middle of a character decodes as U+FFFD at the end; drop it.
        if truncated { while text.hasSuffix("\u{FFFD}") { text.removeLast() } }
        // Mostly replacement characters: not UTF-8 text after all.
        let bad = text.unicodeScalars.prefix(4000).filter { $0 == "\u{FFFD}" }.count
        if !textual && bad > 8 { return .facts(note: nil) }
        let markdown = ["md", "markdown", "mdown", "mkd"].contains(ext)
        return .text(text, markdown: markdown, shownBytes: bytes.count, totalBytes: total)
    }
}

/// A decoded image handed from the loading task to the main thread (CGImage is immutable). roadmap: S-9
final class PeekImage: @unchecked Sendable {
    let cgImage: CGImage
    init(_ image: CGImage) { cgImage = image }
}

/// The peek drawer beside a browse list (`.drawer`): `card2` with a `sep` edge on the left, a 44 pt header with
/// the name, its size and kind, previous / next / close, then the item's text, image or facts. It slides in at
/// `--v-dur-base`, or fades under Reduce Motion; the list beside it stays in view and ↑↓ step to the neighbour
/// (the list moves its selection and calls `show` again). roadmap: S-9
@MainActor
final class PeekDrawer: NSView {
    /// -1 for the previous item, +1 for the next.
    var onStep: ((Int) -> Void)?
    var onClose: (() -> Void)?
    /// "Extract to Downloads" (X-3, through VitrineHelper); nil hides the button (nested members, folders).
    var onExtract: (() -> Void)? { didSet { extractButton.isHidden = onExtract == nil } }
    private lazy var extractButton: NSButton = Self.ghost("square.and.arrow.down", help: String(localized: "Extract to Downloads", bundle: .previewKit,
        comment: "Peek drawer button tooltip: saves this one file from the archive into the Downloads folder.")) { [weak self] in self?.onExtract?() }

    private let nameLabel = NSTextField(labelWithString: "")
    private let factsLabel = NSTextField(labelWithString: "")
    private let body = NSView()
    private let edge = CALayer()
    private var load: Task<Void, Never>?
    private var generation = 0
    private(set) var item: (any PeekItem)?
    /// What the body shows now (tests).
    private(set) var content: PeekContent?

    /// The width the drawer takes beside a list of `width` points (the design's 430 of 800).
    static func width(for width: CGFloat) -> CGFloat { min(430, max(220, (width * 0.54).rounded())) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(edge)
        let header = NSView()
        nameLabel.font = .systemFont(ofSize: Metric.value("fs-body"), weight: .semibold)
        nameLabel.textColor = NSColor.token("t1")
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        factsLabel.font = .systemFont(ofSize: Metric.value("fs-sub"))
        factsLabel.textColor = NSColor.token("t2")
        factsLabel.lineBreakMode = .byTruncatingTail
        factsLabel.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        let previous = Self.ghost("chevron.up", help: String(localized: "Previous item (↑)", bundle: .previewKit, comment: "Peek drawer button tooltip.")) {
            [weak self] in self?.onStep?(-1)
        }
        let next = Self.ghost("chevron.down", help: String(localized: "Next item (↓)", bundle: .previewKit, comment: "Peek drawer button tooltip.")) {
            [weak self] in self?.onStep?(1)
        }
        let close = Self.ghost("xmark", help: String(localized: "Back to the list (esc)", bundle: .previewKit, comment: "Peek drawer button tooltip.")) {
            [weak self] in self?.onClose?()
        }
        extractButton.isHidden = true
        let row = NSStackView(views: [nameLabel, factsLabel, NSView(), extractButton, previous, next, close])
        row.spacing = 8
        row.setCustomSpacing(2, after: previous)
        row.setCustomSpacing(2, after: next)
        let rule = RuleView()
        for v in [row, rule] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(v) }
        for v in [header, body] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12), row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: header.leadingAnchor), rule.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: header.bottomAnchor), rule.heightAnchor.constraint(equalToConstant: 0.5),
            body.topAnchor.constraint(equalTo: header.bottomAnchor), body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Peek", bundle: .previewKit, comment: "Accessibility label of the drawer that peeks at an item in a folder or archive."))
    }

    required init?(coder: NSCoder) { nil }

    private static var unreadable: String {
        String(localized: "It could not be read", bundle: .previewKit, comment: "Peek drawer: the item could not be read.")
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.token("card2").cgColor
        edge.backgroundColor = NSColor.token("sep").cgColor
    }

    override func layout() {
        super.layout()
        edge.frame = NSRect(x: 0, y: 0, width: 0.5, height: bounds.height)
    }

    /// The header's words (tests).
    var headerText: (name: String, facts: String) { (nameLabel.stringValue, factsLabel.stringValue) }

    /// Shows `item`, replacing whatever was loading. Returns the loading task (tests await it).
    @discardableResult
    func show(_ item: any PeekItem) -> Task<Void, Never> {
        self.item = item
        generation += 1
        let run = generation
        load?.cancel()
        nameLabel.stringValue = item.peekName
        var facts: [String] = []
        if let size = item.peekSize { facts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let line = item.peekLine { facts.append(line) }
        if facts.isEmpty { facts.append(item.peekKind) }
        factsLabel.stringValue = facts.joined(separator: " · ")
        setBody(Self.note(String(localized: "Reading…", bundle: .previewKit, comment: "Peek drawer while the item is read.")))
        let name = item.peekName
        let task = Task { @MainActor [weak self] in
            let content: PeekContent
            do {
                let payload = try await item.loadPeek(maxBytes: PeekContent.maxTextBytes)
                content = await Task.detached(priority: .userInitiated) { PeekContent.make(name: name, payload: payload) }.value
            } catch let error as LocalizedError {
                content = .facts(note: error.errorDescription ?? Self.unreadable)
            } catch {
                content = .facts(note: Self.unreadable)
            }
            guard let self, !Task.isCancelled, run == self.generation else { return }
            self.present(content, for: item)
        }
        load = task
        return task
    }

    /// Slides in from the right at `--v-dur-base` (ease-out), or fades at `--v-dur-fast` under Reduce Motion.
    func animateIn() {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        if BrowseMotion.reduceMotion {
            fade.duration = BrowseMotion.duration("dur-fast")
            fade.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(fade, forKey: "peek-in")
            return
        }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 28
        slide.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, slide]
        group.duration = BrowseMotion.duration("dur-base")
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)   // --v-ease-out
        layer.add(group, forKey: "peek-in")
    }

    func stopLoading() { load?.cancel(); generation += 1 }

    /// Waits for the item being read (tests).
    func waitForLoad() async { await load?.value }

    private func present(_ content: PeekContent, for item: any PeekItem) {
        self.content = content
        switch content {
        case .text(let text, let markdown, let shown, let total):
            let view = Self.textView(text, markdown: markdown)
            var note: String?
            if let total, total > Int64(shown) {
                let fmt = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
                note = String(localized: "Showing the first \(fmt(Int64(shown))) of \(fmt(total))", bundle: .previewKit,
                              comment: "Peek drawer under a cut text: how much is shown, both as sizes.")
            }
            setBody(view, note: note)
        case .image(let image):
            let view = NSImageView(image: NSImage(cgImage: image.cgImage, size: .zero))
            view.imageScaling = .scaleProportionallyDown
            view.imageAlignment = .alignCenter
            view.setAccessibilityLabel(item.peekName)
            setBody(view, padding: 16)
        case .facts(let note):
            setBody(Self.factsCard(item, note: note), padding: 16, fill: false)
        }
    }

    private func setBody(_ view: NSView, note: String? = nil, padding: CGFloat = 12, fill: Bool = true) {
        for v in body.subviews { v.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        var constraints = [view.topAnchor.constraint(equalTo: body.topAnchor, constant: padding),
                           view.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
                           view.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -12)]
        if let note {
            let label = Self.note(note)
            label.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(label)
            constraints += [label.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
                            label.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor, constant: -12),
                            label.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -8),
                            view.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -6)]
        } else if fill {
            constraints.append(view.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -padding))
        } else {
            // Below the window's own size (500): a short panel cuts the facts card instead of growing.
            let fit = view.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor, constant: -padding)
            fit.priority = .init(490)
            constraints.append(fit)
        }
        NSLayoutConstraint.activate(constraints)
    }

    private static func note(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: Metric.value("fs-caption"))
        l.textColor = NSColor.token("t3")
        return l
    }

    /// Markdown in the README styles; anything else monospaced at the code size, lines unwrapped.
    private static func textView(_ text: String, markdown: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = ReadmeTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        if markdown {
            view.isHorizontallyResizable = false
            view.textContainer?.widthTracksTextView = true
            view.textStorage?.setAttributedString(ReadmeText.attributed(MarkdownBlocks.parse(text, maxBlocks: 400)))
        } else {
            view.isHorizontallyResizable = true
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            scroll.hasHorizontalScroller = true
            let p = NSMutableParagraphStyle()
            p.minimumLineHeight = (Metric.value("fs-mono") * 1.6).rounded()
            p.maximumLineHeight = p.minimumLineHeight
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: Metric.value("fs-mono"), weight: .regular),
                .foregroundColor: NSColor.token("t1"), .paragraphStyle: p,
            ]))
        }
        scroll.documentView = view
        return scroll
    }

    /// The facts card: the type's icon, the name, its kind and every fact the item has.
    private static func factsCard(_ item: any PeekItem, note: String?) -> NSView {
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.peekName as NSString).pathExtension) ?? .data))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSTextField(wrappingLabelWithString: item.peekName)
        title.font = .systemFont(ofSize: Metric.value("fs-title3"), weight: .semibold)
        title.textColor = NSColor.token("t1")
        var rows: [(String, String)] = [(String(localized: "Kind", bundle: .previewKit, comment: "Peek facts card label: the item's kind."), item.peekKind)]
        if let size = item.peekSize {
            rows.append((String(localized: "Size", bundle: .previewKit, comment: "Peek facts card label: the item's size."),
                         ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        rows += item.peekFacts
        let grid = NSGridView(views: rows.map { label, value in
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: Metric.value("fs-sub"))
            l.textColor = NSColor.token("t2")
            let v = NSTextField(labelWithString: value)
            v.font = .systemFont(ofSize: Metric.value("fs-sub"))
            v.textColor = NSColor.token("t1")
            v.lineBreakMode = .byTruncatingMiddle
            return [l, v]
        })
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        var views: [NSView] = [icon, title, grid]
        if let note { views.append(Self.note(note)) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: title)
        return stack
    }

    private static func ghost(_ symbol: String, help: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        button.isBordered = false
        button.contentTintColor = NSColor.token("t2")
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }
}

/// A borderless button that runs a closure (the drawer's ghost buttons, `.btn.gh`). roadmap: S-9
@MainActor
final class ClosureButton: NSButton {
    private let run: () -> Void
    init(action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func fire() { run() }
}

/// A 0.5 pt `sep` rule that follows light and dark. roadmap: S-9
@MainActor
final class RuleView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("sep").cgColor }
}

/// An outline that tells its owner about the browse keys: Return opens (a folder) or peeks (a file), Escape closes
/// the peek. ↑↓ stay the outline's own, so the peek follows the selection. The archive outline can adopt it.
/// roadmap: S-9
@MainActor
final class BrowseOutlineView: NSOutlineView {
    var onActivate: ((Int) -> Void)?
    var onEscape: (() -> Bool)?
    /// ⌘↑: back out one level (a folder navigated into).
    var onBack: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if command, event.keyCode == 126, let onBack { onBack(); return }
        if [36, 76].contains(event.keyCode) || command && event.keyCode == 125, selectedRow >= 0, let onActivate {
            onActivate(selectedRow)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() != true { super.cancelOperation(sender) }
    }
}
