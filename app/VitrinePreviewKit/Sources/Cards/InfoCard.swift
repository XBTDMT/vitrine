import AppKit
import VitrineDocument
import VitrineSupport
import VitrineUI

/// The facts card the everyday formats share (cards.html §3b and §4, the `.d3A` card: photos, animated images and
/// fonts): a stage holding the file's own content, the museum label (kind tile, title, sentence, at most three
/// numbers, actions) and a body of grouped sections in two columns: key/value rows, chips, or a drawn block. Pure
/// data, so the wording is tested without drawing. roadmap: S-23
struct InfoCard: Equatable {
    struct Stat: Equatable { var value: String; var label: String }

    struct Action: Equatable {
        enum Style: Equatable { case primary, normal }
        var id: String
        var title: String
        var style: Style
    }

    /// One `.c-row`: the key at the left, the value at the right in t2. A flagged row is the design's neutral flag
    /// (`.flag-neutral`: a fill with a 3 pt bar at the left) and may carry a numbered badge after its key.
    struct Row: Equatable {
        var key: String
        var value: String
        var flagged = false
        var number: Int?
    }

    enum Content: Equatable {
        case rows([Row])
        case chips([String])
        /// A block the renderer draws (a font's size waterfall), looked up by this id.
        case drawn(String)
    }

    struct Section: Equatable {
        var title: String
        var content: Content
    }

    /// What the pill calls the file ("Photo", "Animated image", "Font").
    var kindName: String
    var title: String
    var sentence: String
    var bold: [String]
    var tileToken: String
    var tileSymbol: String
    var strip: [Stat]
    var actions: [Action]
    var sections: [Section]

    /// "a" or "an" before a number as it is said: an 8, an 11, an 18, an 80, an 800; a 24.
    static func article(beforeNumber text: String) -> String {
        // The whole part only: "0.5" is said "nought point five", "8.3" "eight point three".
        let digits = text.prefix { $0.isNumber || $0 == "," }.filter(\.isNumber)
        guard let first = digits.first else { return "a" }
        if first == "8" { return "an" }
        // Eleven and eighteen as the leading group of three digits: 11, 18, 11,000, 18,500,000.
        let leadLength = digits.count % 3 == 0 ? 3 : digits.count % 3
        let lead = String(digits.prefix(leadLength))
        return lead == "11" || lead == "18" ? "an" : "a"
    }

    /// "a, b and c": the separator and the last joiner are localized, so a translation can use its own ("a、b、c").
    static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        let head = items.dropLast().joined(separator: String(localized: ", ", bundle: .previewKit, comment: "Separator between the items of a list."))
        return String(localized: "\(head) and \(last)", bundle: .previewKit,
                      comment: "Joins the last item to the rest of a list; e.g. “Latin, Greek and Cyrillic”, “Wi-Fi and a VPN”.")
    }
}

/// How the stage takes its height: a share of the card (a photo), the content's own height (a font specimen), or no
/// stage at all.
enum InfoStageHeight {
    case share(CGFloat, minimum: CGFloat)
    case content
}

/// The card drawn: the stage, the label and the two-column body inside a scroll view, Details on the right when it
/// is open. Under 420 pt the body is one column, the strip keeps two numbers and the actions step aside (the grouped
/// card of cards §4); the stage keeps `narrowStageHeight` or is hidden. roadmap: S-23
@MainActor
final class InfoCardView: NSView {
    let card: InfoCard
    static let narrowWidth: CGFloat = 420

    private(set) var scrollView: NSScrollView!
    private(set) var stage: StageView!
    private(set) var tile: KindTileView!
    private(set) var titleField: NSTextField!
    private(set) var sentenceField: WrappingLabel!
    private(set) var stripCells: [NSView] = []
    private(set) var stripValueFields: [NSTextField] = []
    private(set) var actionButtons: [CardButton] = []
    private(set) var sectionViews: [InfoSectionView] = []
    private(set) var inspector: DetailsInspector!
    private(set) var isNarrow = false
    /// The view the stage shows (the picture, the specimen); nil when the card has no stage.
    let stageContent: NSView?
    var isInspectorShown: Bool { !inspector.isHidden }

    private var content: CardFlippedView!
    private var columns: NSStackView!
    private var left: NSStackView!
    private var right: NSStackView!
    private var actionsStack: NSStackView!
    private var stageWide: [NSLayoutConstraint] = []
    private var stageNarrow: [NSLayoutConstraint] = []
    private var inspectorWidth: NSLayoutConstraint!
    private let narrowStageHeight: CGFloat?
    var onAction: ((String) -> Void)?

    /// - Parameters:
    ///   - stageContent: what stands on the stage; nil = no stage.
    ///   - drawn: the views for `.drawn(id)` sections.
    init(card: InfoCard, stageContent: NSView?, stageHeight: InfoStageHeight, narrowStageHeight: CGFloat?,
         drawn: [String: NSView] = [:], facts: [Fact] = []) {
        self.card = card
        self.stageContent = stageContent
        self.narrowStageHeight = narrowStageHeight
        super.init(frame: .zero)
        wantsLayer = true

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        content = CardFlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content
        inspector = DetailsInspector(facts: facts)
        inspector.isHidden = true
        addSubview(scrollView)
        addSubview(inspector)

        stage = StageView()
        stage.layer?.masksToBounds = true
        let lbl = museumLabel()
        let body = makeBody(drawn: drawn)
        for v in [stage!, lbl, body] as [NSView] { content.addSubview(v) }

        let clip = scrollView.contentView
        inspectorWidth = inspector.widthAnchor.constraint(equalToConstant: 0)
        var constraints: [NSLayoutConstraint] = [
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor), scrollView.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: trailingAnchor), inspector.topAnchor.constraint(equalTo: topAnchor),
            inspector.bottomAnchor.constraint(equalTo: bottomAnchor), inspectorWidth,
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor), content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stage.topAnchor.constraint(equalTo: content.topAnchor), stage.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            lbl.topAnchor.constraint(equalTo: stage.bottomAnchor), lbl.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            lbl.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.topAnchor.constraint(equalTo: lbl.bottomAnchor, constant: 14), body.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: 16),
        ]
        if let stageContent {
            stageContent.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(stageContent)
            constraints += [stageContent.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                            stageContent.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                            stageContent.topAnchor.constraint(equalTo: stage.topAnchor)]
            switch stageHeight {
            case .share(let share, let minimum):
                let fill = stage.heightAnchor.constraint(equalTo: heightAnchor, multiplier: share)
                fill.priority = .defaultHigh
                stageWide = [fill, stage.heightAnchor.constraint(greaterThanOrEqualToConstant: minimum),
                             stageContent.bottomAnchor.constraint(equalTo: stage.bottomAnchor)]
            case .content:
                stageWide = [stage.bottomAnchor.constraint(equalTo: stageContent.bottomAnchor)]
            }
            stageNarrow = narrowStageHeight.map { [stage.heightAnchor.constraint(equalToConstant: $0),
                                                   stageContent.bottomAnchor.constraint(equalTo: stage.bottomAnchor)] }
                ?? [stage.heightAnchor.constraint(equalToConstant: 0)]
        } else {
            stage.isHidden = true
            stageWide = [stage.heightAnchor.constraint(equalToConstant: 0)]
            stageNarrow = stageWide
        }
        NSLayoutConstraint.activate(constraints + stageWide)
    }

    required init?(coder: NSCoder) { nil }

    /// The museum label (cards `.label`): hairlines, the tile, title and sentence, then the number strip with the
    /// actions at its right under a separator (`.l2`).
    private func museumLabel() -> NSView {
        let lbl = TokenBox(fill: "card")
        let hairTop = TokenBox(fill: "hair"), hairBottom = TokenBox(fill: "hair")
        tile = KindTileView(token: card.tileToken, symbol: card.tileSymbol)
        titleField = cardLabel(card.title, font: tokenFont("fs-headline"), color: "t1")
        sentenceField = WrappingLabel(attributed: Self.sentence(card), lines: 3)
        for v in [hairTop, hairBottom, tile!, titleField!, sentenceField!] as [NSView] { lbl.addSubview(v) }
        var constraints: [NSLayoutConstraint] = [
            hairTop.topAnchor.constraint(equalTo: lbl.topAnchor), hairTop.leadingAnchor.constraint(equalTo: lbl.leadingAnchor),
            hairTop.trailingAnchor.constraint(equalTo: lbl.trailingAnchor), hairTop.heightAnchor.constraint(equalToConstant: 0.5),
            hairBottom.bottomAnchor.constraint(equalTo: lbl.bottomAnchor), hairBottom.leadingAnchor.constraint(equalTo: lbl.leadingAnchor),
            hairBottom.trailingAnchor.constraint(equalTo: lbl.trailingAnchor), hairBottom.heightAnchor.constraint(equalToConstant: 0.5),
            tile.topAnchor.constraint(equalTo: lbl.topAnchor, constant: 11), tile.leadingAnchor.constraint(equalTo: lbl.leadingAnchor, constant: 16),
            titleField.topAnchor.constraint(equalTo: tile.topAnchor, constant: -1), titleField.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 11),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: lbl.trailingAnchor, constant: -16),
            sentenceField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1), sentenceField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            sentenceField.trailingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: -16),
        ]
        let sep = TokenBox(fill: "sep")
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.distribution = .fillEqually
        strip.spacing = 0
        strip.translatesAutoresizingMaskIntoConstraints = false
        for (i, stat) in card.strip.prefix(3).enumerated() {
            let cell = NSView()
            cell.translatesAutoresizingMaskIntoConstraints = false
            // `.label .ss`: value 14/650 tabular, its name 11 t2; padding 6 16 7; a separator between cells.
            let value = cardLabel(stat.value, font: tabularFigures(tokenFont("fs-headline")), color: "t1")
            let name = cardLabel(stat.label, font: tokenFont("fs-caption"), color: "t2")
            cell.addSubview(value); cell.addSubview(name)
            NSLayoutConstraint.activate([
                value.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6), value.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                value.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -16),
                name.topAnchor.constraint(equalTo: value.bottomAnchor), name.leadingAnchor.constraint(equalTo: value.leadingAnchor),
                name.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -16),
                name.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -7),
            ])
            let line = TokenBox(fill: "sep")
            cell.addSubview(line)
            NSLayoutConstraint.activate([line.trailingAnchor.constraint(equalTo: cell.trailingAnchor), line.topAnchor.constraint(equalTo: cell.topAnchor),
                                         line.bottomAnchor.constraint(equalTo: cell.bottomAnchor), line.widthAnchor.constraint(equalToConstant: 0.5)])
            line.isHidden = i == card.strip.prefix(3).count - 1 && card.actions.isEmpty
            strip.addArrangedSubview(cell)
            stripCells.append(cell)
            stripValueFields.append(value)
        }
        actionsStack = NSStackView()
        actionsStack.orientation = .horizontal
        actionsStack.spacing = 6
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        for action in card.actions {
            let button = CardButton(title: action.title, primary: action.style == .primary)
            button.onPress = { [weak self] in self?.onAction?(action.id) }
            actionsStack.addArrangedSubview(button)
            actionButtons.append(button)
        }
        actionsStack.setContentHuggingPriority(.required, for: .horizontal)
        actionsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [sep, strip, actionsStack!] as [NSView] { lbl.addSubview(v) }
        constraints += [
            sep.topAnchor.constraint(greaterThanOrEqualTo: sentenceField.bottomAnchor, constant: 9),
            sep.topAnchor.constraint(greaterThanOrEqualTo: tile.bottomAnchor, constant: 9),
            sep.topAnchor.constraint(equalTo: sentenceField.bottomAnchor, constant: 9).with(priority: .defaultLow),
            sep.leadingAnchor.constraint(equalTo: lbl.leadingAnchor), sep.trailingAnchor.constraint(equalTo: lbl.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 0.5),
            strip.topAnchor.constraint(equalTo: sep.bottomAnchor), strip.leadingAnchor.constraint(equalTo: lbl.leadingAnchor),
            strip.bottomAnchor.constraint(equalTo: lbl.bottomAnchor),
            strip.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            actionsStack.leadingAnchor.constraint(equalTo: strip.trailingAnchor, constant: 10),
            actionsStack.trailingAnchor.constraint(equalTo: lbl.trailingAnchor, constant: -12),
            actionsStack.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        return lbl
    }

    /// The body (`.d3A .bd`, `columns: 2; column-gap: 16px`): sections fill the left column first, then the right,
    /// split where the heights balance; one column when narrow.
    private func makeBody(drawn: [String: NSView]) -> NSView {
        func stack() -> NSStackView {
            let s = NSStackView()
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 0
            s.translatesAutoresizingMaskIntoConstraints = false
            return s
        }
        left = stack(); right = stack()
        columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 16
        columns.translatesAutoresizingMaskIntoConstraints = false
        sectionViews = card.sections.map { InfoSectionView($0, drawn: drawn) }
        arrangeColumns()
        return columns
    }

    /// Splits the sections between the columns by their estimated height, keeping their order (CSS columns).
    private func arrangeColumns() {
        for v in sectionViews { v.removeFromSuperview() }
        let heights = sectionViews.map(\.estimatedHeight)
        let total = heights.reduce(0, +)
        var leftHeight: CGFloat = 0
        var split = sectionViews.count
        if !isNarrow {
            for (i, h) in heights.enumerated() {
                if i > 0, leftHeight + h / 2 > total / 2 { split = i; break }
                leftHeight += h
            }
        }
        for (i, v) in sectionViews.enumerated() {
            let column = i < split ? left! : right!
            v.isFirst = column.arrangedSubviews.isEmpty
            column.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        right.isHidden = isNarrow || split >= sectionViews.count
    }

    override func layout() {
        let width = bounds.width - inspectorWidth.constant
        let narrow = bounds.width > 0 && width < Self.narrowWidth
        if narrow != isNarrow { setNarrow(narrow) }
        super.layout()
    }

    private func setNarrow(_ narrow: Bool) {
        isNarrow = narrow
        NSLayoutConstraint.deactivate(narrow ? stageWide : stageNarrow)
        NSLayoutConstraint.activate(narrow ? stageNarrow : stageWide)
        stage.isHidden = stageContent == nil || (narrow && narrowStageHeight == nil)
        for (i, cell) in stripCells.enumerated() { cell.isHidden = narrow && i >= 2 }
        actionsStack.isHidden = narrow
        arrangeColumns()
        needsLayout = true
    }

    func toggleInspector() {
        inspector.isHidden.toggle()
        inspectorWidth.constant = inspector.isHidden ? 0 : Metric.value("w-inspector")
        needsLayout = true
    }

    func scroll(to y: CGFloat) {
        layoutSubtreeIfNeeded()
        let maxY = max(0, content.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.token("win").cgColor }
    }

    /// The sentence 12 t2 at line height 1.38, the bold parts t1 at 600 (`.label .snt b`).
    static func sentence(_ card: InfoCard) -> NSAttributedString {
        let size = Metric.value("fs-control")
        let text = NSMutableAttributedString(string: card.sentence, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.token("t2")])
        let ns = card.sentence as NSString
        for part in card.bold where !part.isEmpty {
            let r = ns.range(of: part)
            if r.location != NSNotFound {
                text.addAttributes([.font: NSFont.systemFont(ofSize: size, weight: cssWeight(600)), .foregroundColor: NSColor.token("t1")], range: r)
            }
        }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = (size * 1.38).rounded()
        style.maximumLineHeight = (size * 1.38).rounded()
        style.lineBreakMode = .byWordWrapping
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }
}

/// One section: its heading (`.gh`: 11.5/600 t2, 14 above and 6 below, none above the first) and its panel (`.gp`:
/// card, radius 10, a hairline edge) holding rows, chips or a drawn block. roadmap: S-23
@MainActor
final class InfoSectionView: NSView {
    let section: InfoCard.Section
    private(set) var heading: NSTextField!
    private(set) var rowViews: [InfoRowView] = []
    private(set) var chipViews: [ChipView] = []
    private var headingTop: NSLayoutConstraint!

    var isFirst = false { didSet { headingTop.constant = isFirst ? 0 : 14 } }

    init(_ section: InfoCard.Section, drawn: [String: NSView]) {
        self.section = section
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heading = cardLabel(section.title, font: tokenFont("fs-sub", weight: 600), color: "t2")
        let panel = TokenBox(fill: "card", radius: Metric.value("r-card"), border: "hair", borderWidth: 0.5)
        panel.layer?.masksToBounds = true
        addSubview(heading); addSubview(panel)
        headingTop = heading.topAnchor.constraint(equalTo: topAnchor, constant: 14)
        var constraints: [NSLayoutConstraint] = [
            headingTop, heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            panel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6), panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor), panel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        switch section.content {
        case .rows(let rows):
            var previous: NSView?
            for (i, row) in rows.enumerated() {
                let v = InfoRowView(row, first: i == 0)
                panel.addSubview(v)
                constraints += [v.leadingAnchor.constraint(equalTo: panel.leadingAnchor), v.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                                v.topAnchor.constraint(equalTo: previous?.bottomAnchor ?? panel.topAnchor)]
                previous = v
                rowViews.append(v)
            }
            if let previous { constraints.append(panel.bottomAnchor.constraint(equalTo: previous.bottomAnchor)) }
        case .chips(let names):
            let chips = names.map { ChipView(text: $0, symbol: nil, fill: "fill", textColor: "t2") }
            chipViews = chips
            let flow = FlowView(chips, spacing: 6)
            panel.addSubview(flow)
            constraints += [flow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
                            flow.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
                            flow.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
                            panel.bottomAnchor.constraint(equalTo: flow.bottomAnchor, constant: 10)]
        case .drawn(let id):
            let block = drawn[id] ?? NSView()
            block.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(block)
            constraints += [block.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
                            block.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
                            block.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
                            panel.bottomAnchor.constraint(equalTo: block.bottomAnchor, constant: 10)]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }

    /// A height guess for balancing the columns, before layout knows the width.
    var estimatedHeight: CGFloat {
        let heading: CGFloat = 14 + 15 + 6
        switch section.content {
        case .rows(let rows): return heading + CGFloat(rows.count) * 32
        case .chips(let names): return heading + 20 + CGFloat((names.count + 5) / 6) * 28
        case .drawn: return heading + 20 + 110
        }
    }
}

/// A `.c-row`: min 32 pt, padding 6 12, 12.5 pt; the key in t1, the value right-aligned in t2 and truncated; a
/// 0.5 pt separator above every row but the first. roadmap: S-23
@MainActor
final class InfoRowView: TokenBox {
    let row: InfoCard.Row
    private(set) var keyField: NSTextField!
    private(set) var valueField: NSTextField!
    private(set) var badge: TokenBox?

    init(_ row: InfoCard.Row, first: Bool) {
        self.row = row
        super.init(fill: row.flagged ? "fill" : nil)
        let font = tokenFont("fs-callout")
        keyField = cardLabel(row.key, font: font, color: "t1")
        keyField.setContentCompressionResistancePriority(.required, for: .horizontal)
        keyField.setContentHuggingPriority(.required, for: .horizontal)
        valueField = cardLabel(row.value, font: font, color: "t2")
        valueField.alignment = .right
        valueField.toolTip = row.value
        addSubview(keyField); addSubview(valueField)
        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            // As short as the words allow: 32 pt, or taller only when the text needs it.
            heightAnchor.constraint(equalToConstant: 32).with(priority: .defaultLow),
            keyField.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            keyField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), keyField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), valueField.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueField.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
        ]
        var afterKey: NSView = keyField
        if let number = row.number {
            // `.bdg.num.fl`: the accent badge, 18 high, radius 9, 11/700 white, 5 pt after the key.
            let b = TokenBox(fill: "accent", radius: 9)
            let n = cardLabel("\(number)", font: tokenFont("fs-caption", weight: 700), color: "on-accent")
            b.addSubview(n)
            addSubview(b)
            badge = b
            constraints += [b.leadingAnchor.constraint(equalTo: keyField.trailingAnchor, constant: 5), b.centerYAnchor.constraint(equalTo: centerYAnchor),
                            b.heightAnchor.constraint(equalToConstant: Metric.value("h-badge")),
                            b.widthAnchor.constraint(greaterThanOrEqualToConstant: Metric.value("h-badge")),
                            n.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 6), n.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -6),
                            n.centerYAnchor.constraint(equalTo: b.centerYAnchor)]
            afterKey = b
        }
        constraints.append(valueField.leadingAnchor.constraint(greaterThanOrEqualTo: afterKey.trailingAnchor, constant: 10))
        if !first {
            let line = TokenBox(fill: "sep")
            addSubview(line)
            constraints += [line.topAnchor.constraint(equalTo: topAnchor), line.leadingAnchor.constraint(equalTo: leadingAnchor),
                            line.trailingAnchor.constraint(equalTo: trailingAnchor), line.heightAnchor.constraint(equalToConstant: 0.5)]
        }
        if row.flagged {
            let bar = TokenBox(fill: "fill2")
            addSubview(bar)
            constraints += [bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.topAnchor.constraint(equalTo: topAnchor),
                            bar.bottomAnchor.constraint(equalTo: bottomAnchor), bar.widthAnchor.constraint(equalToConstant: 3)]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }
}

/// Chips laid out in rows that wrap at the width layout gives (`.row.chips`, gap 6). roadmap: S-23
@MainActor
final class FlowView: NSView {
    let items: [NSView]
    let spacing: CGFloat
    private var lastWidth: CGFloat = 0

    init(_ items: [NSView], spacing: CGFloat) {
        self.items = items
        self.spacing = spacing
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for item in items {
            item.translatesAutoresizingMaskIntoConstraints = true
            addSubview(item)
        }
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    private func frames(for width: CGFloat) -> [NSRect] {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        return items.map { item in
            let size = item.fittingSize
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            defer { x += size.width + spacing; rowHeight = max(rowHeight, size.height) }
            return NSRect(x: x, y: y, width: min(size.width, max(width, 1)), height: size.height)
        }
    }

    override var intrinsicContentSize: NSSize {
        let width = lastWidth > 0 ? lastWidth : 400
        return NSSize(width: NSView.noIntrinsicMetric, height: frames(for: width).map(\.maxY).max() ?? 0)
    }

    override func layout() {
        super.layout()
        for (item, frame) in zip(items, frames(for: bounds.width)) { item.frame = frame }
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// `.btn` (22 pt, radius 6, `ctl` with a hairline) and `.btn.pri` (accent, white words), 12.5/500 words, padding 0 10.
@MainActor
final class CardButton: TokenBox {
    let label: NSTextField
    let primary: Bool
    var onPress: (() -> Void)?

    init(title: String, primary: Bool) {
        self.primary = primary
        label = cardLabel(title, font: tokenFont("fs-callout", weight: 500), color: primary ? "on-accent" : "t1")
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        super.init(fill: primary ? "accent" : "ctl", radius: Metric.value("r-ctl"), border: primary ? nil : "hair", borderWidth: 0.5)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metric.value("h-ctl")),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}
