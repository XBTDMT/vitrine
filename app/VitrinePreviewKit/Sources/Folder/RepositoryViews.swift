import AppKit
import VitrineGit
import VitrineText
import VitrineUI

/// A rounded box in the card style (`.rcard`): `card` fill, `r-card` corners, a hairline ring. The colours are
/// set in `updateLayer` so they follow light and dark. roadmap: S-9
@MainActor
final class CardBox: NSView {
    var fill = "card" { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metric.value("r-card")
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.token(fill).cgColor
        layer?.borderColor = NSColor.token("hair").cgColor
    }
}

/// A solid fill that follows the appearance (the card's header strip, the repository band).
@MainActor
final class FillView: NSView {
    private let token: String
    private let bottomRule: Bool
    private let rule = CALayer()

    init(_ token: String, bottomRule: Bool = false) {
        self.token = token; self.bottomRule = bottomRule
        super.init(frame: .zero)
        wantsLayer = true
        if bottomRule { layer?.addSublayer(rule) }
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.token(token).cgColor
        rule.backgroundColor = NSColor.token("sep").cgColor
    }
    override func layout() {
        super.layout()
        rule.frame = NSRect(x: 0, y: isFlipped ? bounds.maxY - 0.5 : 0, width: bounds.width, height: 0.5)
    }
}

/// A capsule label: the branch pill (`.pill`) or a tag badge (`.bdg`), an SF Symbol and words.
@MainActor
final class PillLabel: NSView {
    private let fillToken: String
    private var content: NSStackView?
    private let padding: CGFloat
    private let height: CGFloat

    /// As wide as its words: with this the pill hugs its content instead of taking a row's slack.
    override var intrinsicContentSize: NSSize {
        NSSize(width: (content?.fittingSize.width ?? 0) + 2 * padding, height: height)
    }

    init(symbol: String?, text: String, textToken: String = "t1", fill: String = "fill", height: CGFloat, radius: CGFloat,
         font: NSFont, padding: CGFloat) {
        fillToken = fill
        self.padding = padding
        self.height = height
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = NSColor.token(textToken)
        label.lineBreakMode = .byTruncatingTail
        var views: [NSView] = []
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: font.pointSize - 0.5, weight: .medium)
            icon.contentTintColor = NSColor.token(textToken == "t1" ? "t2" : textToken)
            views.append(icon)
        }
        views.append(label)
        let stack = NSStackView(views: views)
        stack.spacing = 4
        stack.setHuggingPriority(.required, for: .horizontal)   // the pill is as wide as its words, never a filler
        label.setContentHuggingPriority(.required, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        content = stack
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padding),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token(fillToken).cgColor }
}

/// The author's initials on their series colour (`.av`).
@MainActor
final class AvatarView: NSView {
    private let token: String

    init(name: String, email: String, size: CGFloat = 16) {
        token = GitText.avatarToken(email)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = size / 2
        let label = NSTextField(labelWithString: GitText.initials(name))
        label.font = .systemFont(ofSize: 8, weight: .bold)
        label.textColor = NSColor.token("on-accent")
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size),
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = name
    }

    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token(token).cgColor }
}

/// The repository band (`.repo` on `win`, a rule under it) holding the card: branch pill, commits to push,
/// latest commit (avatar, subject, short id, when, how many commits), then the uncommitted changes, "read from
/// .git, no git process". It is rebuilt in place when the full read arrives after the first paint.
/// roadmap: S-9
@MainActor
final class RepositoryPanel: NSView {
    private let card = CardBox()
    private let stack = NSStackView()
    private(set) var read: RepositoryRead

    init(read: RepositoryRead) {
        self.read = read
        super.init(frame: .zero)
        let band = FillView("win", bottomRule: true)
        for v in [band, card] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: topAnchor), band.leadingAnchor.constraint(equalTo: leadingAnchor),
            band.trailingAnchor.constraint(equalTo: trailingAnchor), band.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 10), card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: card.topAnchor), stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    func update(_ read: RepositoryRead) {
        self.read = read
        rebuild()
    }

    /// The words on the card, for tests: header then rows.
    var textForTesting: [String] {
        func texts(_ v: NSView) -> [String] {
            if let f = v as? NSTextField { return f.stringValue.isEmpty ? [] : [f.stringValue] }
            return v.subviews.flatMap(texts)
        }
        return texts(stack)
    }

    private func rebuild() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        let header = headerRow()
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let changes = changesSection() {
            stack.addArrangedSubview(changes)
            changes.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private static func label(_ text: String, size: CGFloat, token: String, weight: NSFont.Weight = .regular, mono: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        l.textColor = NSColor.token(token)
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }

    private func headerRow() -> NSView {
        let s = read.summary
        let strip = FillView("card2")
        var views: [NSView] = []
        let sub = NSFont.systemFont(ofSize: Metric.value("fs-sub"), weight: .medium)
        views.append(PillLabel(symbol: "arrow.triangle.branch", text: GitText.branchLabel(s.head), height: 22, radius: 11, font: sub, padding: 9))
        if let ahead = s.ahead, ahead > 0 {
            let push = ahead.formatted()
            views.append(PillLabel(symbol: "arrow.up", text: String(localized: "\(push) to push", bundle: .previewKit, comment: "Repository card: commits waiting to be pushed."), textToken: "accent-text", fill: "card2",
                                   height: 18, radius: 0, font: .systemFont(ofSize: Metric.value("fs-control"), weight: .medium), padding: 0))
        }
        if let behind = s.behind, behind > 0 {
            let pull = behind.formatted()
            views.append(PillLabel(symbol: "arrow.down", text: String(localized: "\(pull) to pull", bundle: .previewKit, comment: "Repository card: commits waiting to be pulled."), textToken: "t2", fill: "card2",
                                   height: 18, radius: 0, font: .systemFont(ofSize: Metric.value("fs-control")), padding: 0))
        }
        if let c = s.headCommit {
            if let a = c.author { views.append(AvatarView(name: a.name, email: a.email)) }
            let subject = Self.label(c.subject.isEmpty ? String(localized: "(no message)", bundle: .previewKit, comment: "Repository card: the latest commit has an empty message.") : c.subject, size: Metric.value("fs-control"), token: "t1")
            subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            subject.setContentHuggingPriority(.defaultLow, for: .horizontal)
            views.append(subject)
            views.append(Self.label(c.id.short, size: Metric.value("fs-caption"), token: "t2", mono: true))
            if let date = c.author?.date ?? c.committer?.date {
                views.append(Self.label(GitText.relative(date), size: Metric.value("fs-sub"), token: "t3"))
            }
            if let n = s.commitCount {
                views.append(PillLabel(symbol: "clock.arrow.circlepath", text: n.formatted() + (s.commitCountIsFloor ? "+" : ""), textToken: "t2",
                                       fill: "card2", height: 18, radius: 0, font: .monospacedDigitSystemFont(ofSize: Metric.value("fs-sub"), weight: .regular),
                                       padding: 0))
            }
        } else {
            let why = s.objectFormat == .sha256
                ? String(localized: "SHA-256 repository: commits not read", bundle: .previewKit, comment: "Repository card: SHA-256 repositories are not read.")
                : s.head.commitID == nil && s.head != .unknown
                    ? String(localized: "No commits yet", bundle: .previewKit, comment: "Repository card: the repository has no commits.")
                    : String(localized: "The latest commit could not be read", bundle: .previewKit, comment: "Repository card: reading the latest commit failed.")
            let l = Self.label(why, size: Metric.value("fs-control"), token: "t2")
            l.setContentHuggingPriority(.defaultLow, for: .horizontal)
            views.append(l)
        }
        let row = NSStackView(views: views)
        row.spacing = 8
        row.alignment = .centerY
        row.distribution = .fill          // the subject takes the slack; everything else keeps its own width
        row.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(row)
        NSLayoutConstraint.activate([
            strip.heightAnchor.constraint(equalToConstant: 36),
            row.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ])
        return strip
    }

    /// "4 uncommitted · read from .git, no git process" and the first rows; nil before the status is read, or for
    /// a bare repository.
    private func changesSection() -> NSView? {
        guard let status = read.summary.status else { return nil }
        let box = NSView()
        let rule = FillView("sep")
        let title = Self.label(GitText.uncommitted(status), size: Metric.value("fs-caption"), token: "t2", weight: .semibold)
        let source = Self.label(String(localized: "read from .git, no git process", bundle: .previewKit, comment: "Repository card: Vitrine reads the .git folder itself and never runs git. Keep “.git” and “git”."), size: Metric.value("fs-caption"), token: "t3")
        var rows: [NSView] = []
        for change in status.changes.prefix(RepositoryRead.listedChanges) { rows.append(changeRow(change)) }
        if status.count > RepositoryRead.listedChanges {
            let more = (status.count - RepositoryRead.listedChanges).formatted()
            rows.append(Self.label(String(localized: "and \(more) more", bundle: .previewKit, comment: "Repository card: how many more uncommitted changes are not listed."), size: Metric.value("fs-caption"), token: "t3"))
        }
        for v in [rule, title, source] + rows { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        var constraints = [
            rule.topAnchor.constraint(equalTo: box.topAnchor), rule.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: box.trailingAnchor), rule.heightAnchor.constraint(equalToConstant: 0.5),
            title.topAnchor.constraint(equalTo: box.topAnchor, constant: 7), title.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            source.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            source.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            source.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
        ]
        var previous: NSView = title
        for (i, row) in rows.enumerated() {
            constraints += [row.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: i == 0 ? 3 : 0),
                            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
                            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12)]
            if !(row is NSTextField) { constraints.append(row.heightAnchor.constraint(equalToConstant: 22)) }
            previous = row
        }
        constraints.append(previous.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: rows.isEmpty ? -7 : -4))
        NSLayoutConstraint.activate(constraints)
        return box
    }

    private func changeRow(_ change: GitChange) -> NSView {
        let letter = Self.label(change.kind.rawValue, size: Metric.value("fs-caption"), token: Self.markToken(change.kind), weight: .semibold, mono: true)
        letter.alignment = .center
        let path = Self.label(change.path, size: Metric.value("fs-sub"), token: "t1", mono: true)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stat = Self.label(read.lineStats[change.path] ?? "", size: Metric.value("fs-caption"), token: "t3")
        stat.font = .monospacedDigitSystemFont(ofSize: Metric.value("fs-caption"), weight: .regular)
        let row = NSStackView(views: [letter, path, stat])
        row.spacing = 8
        row.alignment = .centerY
        row.distribution = .fill
        letter.widthAnchor.constraint(equalToConstant: 12).isActive = true
        return row
    }

    /// The status letter's colour (`.st-m`, `.st-a`, `.st-u`).
    static func markToken(_ kind: GitChange.Kind) -> String {
        switch kind {
        case .modified: "caution-text"
        case .added: "ok-text"
        case .untracked: "t3"
        case .deleted, .unmerged: "danger-text"
        }
    }
}

/// The README card (`.rcard` with a `README.md` caption), drawn natively from the Markdown blocks in the Vitrine
/// Markdown theme's type scale and the design tokens. It scrolls on its own; the outline above keeps its place.
/// roadmap: S-9
@MainActor
final class ReadmeCard: NSView {
    let textView: ReadmeTextView
    private let scroll = NSScrollView()

    init(name: String, blocks: [MarkdownBlock], truncated: Bool) {
        textView = ReadmeTextView(usingTextLayoutManager: false)   // TextKit 1: the boxes are drawn from line fragments
        super.init(frame: .zero)
        let box = CardBox()
        let caption = NSTextField(labelWithString: name)
        caption.font = .systemFont(ofSize: Metric.value("fs-caption"), weight: .semibold)
        caption.textColor = NSColor.token("t2")
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let text = ReadmeText.attributed(blocks)
        if truncated {
            let note = String(localized: "Only the start of this README is shown.", bundle: .previewKit, comment: "Under a long README in the repository card.")
            text.append(NSAttributedString(string: "\n" + note, attributes: ReadmeText.attrs(size: 11.5, token: "t3"))) }
        textView.textStorage?.setAttributedString(text)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        for v in [box, caption, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor), box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor), box.bottomAnchor.constraint(equalTo: bottomAnchor),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 10), caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // Leave room on the right for the overlay scroller, as the design's 14 pt padding does.
        textView.textContainer?.containerSize = NSSize(width: max(0, scroll.contentSize.width - 6), height: .greatestFiniteMagnitude)
    }
}

/// A shape drawn behind README text: a code block or alert box, a quote bar, a heading's rule, a thematic break.
/// The text carries the boxes it sits in (outermost first) under `.readmeBoxes`; the text view draws them from
/// the laid-out line fragments, so they follow the width and the appearance. roadmap: S-9
final class ReadmeBox: NSObject {
    enum Kind { case fill(String?, bar: String?, radius: CGFloat), ruleBelow, rule }
    let kind: Kind
    /// Left edge, from the text container's.
    let inset: CGFloat
    /// Space under the box that belongs to the gap, not to the box (the last paragraph's spacing includes it).
    let marginBelow: CGFloat

    init(_ kind: Kind, inset: CGFloat, marginBelow: CGFloat = 0) {
        self.kind = kind; self.inset = inset; self.marginBelow = marginBelow
    }
}

extension NSAttributedString.Key {
    static let readmeBoxes = NSAttributedString.Key("io.github.xbtdmt.vitrine.readmeBoxes")
}

/// The README's text view: draws the `ReadmeBox` shapes under the text (TextKit 1 line fragments).
@MainActor
final class ReadmeTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return }
        var spans: [ObjectIdentifier: (box: ReadmeBox, range: NSRange, depth: Int)] = [:]
        storage.enumerateAttribute(.readmeBoxes, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let boxes = value as? [ReadmeBox] else { return }
            for (depth, b) in boxes.enumerated() {
                let key = ObjectIdentifier(b)
                spans[key] = (b, spans[key].map { NSUnionRange($0.range, range) } ?? range, depth)
            }
        }
        let origin = textContainerOrigin
        for span in spans.values.sorted(by: { $0.depth < $1.depth }) {
            let glyphs = lm.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let first = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let last = lm.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let lastUsed = lm.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let x = origin.x + span.box.inset, width = max(0, tc.size.width - span.box.inset)
            switch span.box.kind {
            case .fill(let fill, let bar, let radius):
                let r = NSRect(x: x, y: origin.y + first.minY, width: width, height: max(0, last.maxY - span.box.marginBelow - first.minY))
                guard r.intersects(rect) else { continue }
                if let fill {
                    NSColor.token(fill).setFill()
                    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
                }
                if let bar {
                    NSColor.token(bar).setFill()
                    NSRect(x: r.minX, y: r.minY, width: 3, height: r.height).fill()
                }
            case .ruleBelow:
                NSColor.token("sep").setFill()
                NSRect(x: x, y: origin.y + lastUsed.maxY + 2, width: width, height: 0.5).fill()
            case .rule:
                NSColor.token("sep").setFill()
                NSRect(x: x, y: origin.y + first.midY, width: width, height: 1).fill()
            }
        }
    }
}

/// Markdown blocks → attributed text with the design's README styles (`.md`: 13.5 body, 22 h1, 15.5 h2 with a
/// rule, 12 mono code on `code` in an 8 pt rounded box, alerts on `accent-soft` with an `accent-text` bar). Links
/// are coloured, not live: a preview opens nothing. roadmap: S-9
@MainActor
enum ReadmeText {
    static let body: CGFloat = 13.5

    static func attrs(size: CGFloat = body, token: String = "t1", weight: NSFont.Weight = .regular, mono: Bool = false,
                      paragraph: NSParagraphStyle? = nil, boxes: [ReadmeBox] = []) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [
            .font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.token(token),
        ]
        a[.paragraphStyle] = paragraph ?? style()
        if !boxes.isEmpty { a[.readmeBoxes] = boxes }
        return a
    }

    static func style(before: CGFloat = 0, after: CGFloat = 8, indent: CGFloat = 0, firstIndent: CGFloat? = nil, tail: CGFloat = 0,
                      lineHeight: CGFloat = 1.6, size: CGFloat = body, clip: Bool = false) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.headIndent = indent
        p.firstLineHeadIndent = firstIndent ?? indent
        p.tailIndent = -tail
        p.minimumLineHeight = (size * lineHeight).rounded()
        p.maximumLineHeight = (size * lineHeight).rounded()
        if clip { p.lineBreakMode = .byClipping }
        return p
    }

    static func attributed(_ blocks: [MarkdownBlock]) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() { append(block, to: out, indent: 0, tail: 0, first: i == 0, boxes: []) }
        // No trailing paragraph break.
        while out.length > 0, out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    /// Sets the space before the first paragraph and after the last one in `range` (a box's padding).
    private static func pad(_ out: NSMutableAttributedString, _ range: NSRange, top: CGFloat, bottom: CGFloat) {
        guard range.length > 0 else { return }
        let ns = out.string as NSString
        let firstPara = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
        let lastPara = ns.paragraphRange(for: NSRange(location: NSMaxRange(range) - 1, length: 0))
        func adjust(_ r: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
            guard let p = (out.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            change(p)
            out.addAttribute(.paragraphStyle, value: p, range: r)
        }
        adjust(firstPara) { $0.paragraphSpacingBefore = top }
        if lastPara == firstPara {
            adjust(lastPara) { $0.paragraphSpacingBefore = top; $0.paragraphSpacing = bottom }
        } else {
            adjust(lastPara) { $0.paragraphSpacing = bottom }
        }
    }

    private static func append(_ block: MarkdownBlock, to out: NSMutableAttributedString, indent: CGFloat, tail: CGFloat, first: Bool, boxes: [ReadmeBox]) {
        let start = out.length
        switch block {
        case .heading(let level, let inl):
            let size: CGFloat = level == 1 ? 22 : level == 2 ? 15.5 : 13.5
            let weight: NSFont.Weight = level == 1 ? .bold : .semibold
            let mine = level == 2 ? boxes + [ReadmeBox(.ruleBelow, inset: indent)] : boxes
            let p = style(before: first ? 0 : (level == 1 ? 6 : 12), after: level == 2 ? 10 : 6, indent: indent, tail: tail, lineHeight: 1.25, size: size)
            out.append(inline(inl, base: attrs(size: size, weight: weight, paragraph: p, boxes: mine)))
            out.append(NSAttributedString(string: "\n", attributes: attrs(size: size, paragraph: p, boxes: mine)))
        case .paragraph(let inl):
            let p = style(indent: indent, tail: tail)
            out.append(inline(inl, base: attrs(paragraph: p, boxes: boxes)))
            out.append(NSAttributedString(string: "\n", attributes: attrs(paragraph: p, boxes: boxes)))
        case .code(_, let text):
            // One paragraph per line, so the box's padding goes on the first and last only; long lines clip.
            let box = ReadmeBox(.fill("code", bar: nil, radius: Metric.value("r-code")), inset: indent, marginBelow: 10)
            let p = style(after: 0, indent: indent + 10, tail: tail + 10, lineHeight: 1.55, size: 12, clip: true)
            out.append(NSAttributedString(string: text + "\n", attributes: attrs(size: 12, mono: true, paragraph: p, boxes: boxes + [box])))
            pad(out, NSRange(location: start, length: out.length - start), top: 8, bottom: 8 + 10)
        case .quote(let inner):
            let bar = ReadmeBox(.fill(nil, bar: "sep", radius: 0), inset: indent, marginBelow: 8)
            for (i, b) in inner.enumerated() { append(b, to: out, indent: indent + 13, tail: tail, first: i == 0, boxes: boxes + [bar]) }
            pad(out, NSRange(location: start, length: out.length - start), top: 0, bottom: 8)
        case .alert(let kind, let inner):
            let box = ReadmeBox(.fill("accent-soft", bar: "accent-text", radius: 6), inset: indent, marginBelow: 8)
            let all = boxes + [box]
            let p = style(after: 0, indent: indent + 13, tail: tail + 10, size: 12.5)
            out.append(NSAttributedString(string: kind + "\n", attributes: attrs(size: 12.5, token: "accent-text", weight: .semibold, paragraph: p, boxes: all)))
            for b in inner {
                if case .paragraph(let inl) = b {
                    let pp = style(after: 4, indent: indent + 13, tail: tail + 10, size: 12.5)
                    out.append(inline(inl, base: attrs(size: 12.5, paragraph: pp, boxes: all)))
                    out.append(NSAttributedString(string: "\n", attributes: attrs(size: 12.5, paragraph: pp, boxes: all)))
                } else {
                    append(b, to: out, indent: indent + 13, tail: tail + 10, first: false, boxes: all)
                }
            }
            pad(out, NSRange(location: start, length: out.length - start), top: 4, bottom: 4 + 8)
        case .list(let ordered, let start, let items):
            for (n, item) in items.enumerated() {
                let marker: String
                if let checked = item.checked { marker = checked ? "☑" : "☐" }
                else { marker = ordered ? "\(start + n)." : "•" }
                let p = NSMutableParagraphStyle()
                p.setParagraphStyle(style(after: 2, indent: indent + 18, firstIndent: indent, tail: tail))
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18)]
                let line = NSMutableAttributedString(string: marker + "\t", attributes: attrs(token: "t2", paragraph: p, boxes: boxes))
                var rest = item.blocks
                if case .paragraph(let inl)? = rest.first {
                    line.append(inline(inl, base: attrs(paragraph: p, boxes: boxes)))
                    rest.removeFirst()
                }
                line.append(NSAttributedString(string: "\n", attributes: attrs(paragraph: p, boxes: boxes)))
                out.append(line)
                for b in rest { append(b, to: out, indent: indent + 18, tail: tail, first: false, boxes: boxes) }
            }
            pad(out, NSRange(location: out.length - 1, length: 1), top: (out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0, bottom: 8)
        case .table(let rows):
            let p = style(after: 0, indent: indent, tail: tail, lineHeight: 1.5, size: 12)
            for (r, row) in rows.enumerated() {
                let line = NSMutableAttributedString()
                for (c, cell) in row.enumerated() {
                    if c > 0 { line.append(NSAttributedString(string: "  │  ", attributes: attrs(size: 12, token: "t3", paragraph: p, boxes: boxes))) }
                    line.append(inline(cell, base: attrs(size: 12, weight: r == 0 ? .semibold : .regular, paragraph: p, boxes: boxes)))
                }
                line.append(NSAttributedString(string: "\n", attributes: attrs(size: 12, paragraph: p, boxes: boxes)))
                out.append(line)
            }
            pad(out, NSRange(location: start, length: out.length - start), top: 0, bottom: 8)
        case .rule:
            let p = style(after: 8, indent: indent, tail: tail, lineHeight: 1, size: 12)
            out.append(NSAttributedString(string: "\u{00A0}\n", attributes: attrs(size: 12, paragraph: p, boxes: boxes + [ReadmeBox(.rule, inset: indent)])))
        case .html(let text):
            let p = style(after: 8, indent: indent, tail: tail, lineHeight: 1.5, size: 12)
            out.append(NSAttributedString(string: text + "\n", attributes: attrs(size: 12, token: "t3", mono: true, paragraph: p, boxes: boxes)))
        }
    }

    private static func inline(_ items: [MarkdownInline], base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let size = (base[.font] as? NSFont)?.pointSize ?? body
        for item in items {
            switch item {
            case .text(let s): out.append(NSAttributedString(string: s, attributes: base))
            case .code(let s):
                var a = base
                a[.font] = NSFont.monospacedSystemFont(ofSize: max(10, size - 1.5), weight: .regular)
                a[.backgroundColor] = NSColor.token("code")
                out.append(NSAttributedString(string: "\u{2009}" + s + "\u{2009}", attributes: a))
            case .emphasis(let x):
                let inner = NSMutableAttributedString(attributedString: inline(x, base: base))
                inner.enumerateAttribute(.font, in: NSRange(location: 0, length: inner.length)) { value, range, _ in
                    guard let f = value as? NSFont else { return }
                    inner.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask), range: range)
                }
                out.append(inner)
            case .strong(let x):
                let inner = NSMutableAttributedString(attributedString: inline(x, base: base))
                inner.enumerateAttribute(.font, in: NSRange(location: 0, length: inner.length)) { value, range, _ in
                    guard let f = value as? NSFont else { return }
                    inner.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask), range: range)
                }
                out.append(inner)
            case .strikethrough(let x):
                let inner = NSMutableAttributedString(attributedString: inline(x, base: base))
                inner.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: inner.length))
                out.append(inner)
            case .link(let x, _):
                var a = base
                a[.foregroundColor] = NSColor.token("accent-text")
                out.append(inline(x, base: a))
            case .image(let alt):
                var a = base
                a[.foregroundColor] = NSColor.token("t3")
                out.append(NSAttributedString(string: alt.isEmpty ? String(localized: "[image]", bundle: .previewKit, comment: "Stands for an image with no description in a README.") : "[\(alt)]", attributes: a))
            case .softBreak: out.append(NSAttributedString(string: " ", attributes: base))
            case .lineBreak: out.append(NSAttributedString(string: "\u{2028}", attributes: base))
            }
        }
        return out
    }
}
