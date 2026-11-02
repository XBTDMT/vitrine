import AppKit
import VitrineDocument
import VitrineUI

/// The trust half of the card (trust r3-a Verdict first): the verdict box in its three weights, the answer rows with
/// their numbered findings, the calm card's tight list, and the Details inspector the capsule's ⌘I opens. Each part
/// has a narrow form for Finder's preview pane (under 420 pt), as the design's pane states draw it. roadmap: S-8, S-22

/// The verdict box: danger is the strong red with white words, caution the soft wash with its 1 pt line, calm the
/// grey fill (trust r3-a states 1–3). Title 14/700 (calm 650), the reason 12 under it, a chip on the right; in the
/// narrow pane the reason steps aside and the chip sits under the title.
@MainActor
final class VerdictBoxView: TokenBox {
    let verdict: BinaryCard.Verdict
    let titleField: WrappingLabel
    let reasonField: WrappingLabel
    let chip: ChipView
    private let icon: NSImageView
    private var wide: [NSLayoutConstraint] = []
    private var narrowSet: [NSLayoutConstraint] = []
    var isNarrow = false { didSet { if isNarrow != oldValue { apply() } } }

    init(_ v: BinaryCard.Verdict) {
        verdict = v
        let titleColor, reasonColor, iconColor, iconName, chipSymbol: String
        let chipFill, chipText: String
        var chipAlpha: CGFloat = 1
        let fill: String, border: String?
        switch v.level {
        case .danger:
            (fill, border) = ("danger-strong", nil)
            (titleColor, reasonColor, iconColor, iconName) = ("on-accent", "on-accent", "on-accent", "xmark.octagon")
            (chipFill, chipText, chipSymbol) = ("on-accent", "on-accent", "hand.raised")
            chipAlpha = 0.22
        case .caution:
            (fill, border) = ("caution-soft", "caution-line")
            (titleColor, reasonColor, iconColor, iconName) = ("t1", "t1", "caution-text", "exclamationmark.triangle")
            (chipFill, chipText, chipSymbol) = ("caution-strong", "on-accent", "exclamationmark.triangle")
        case .calm:
            (fill, border) = ("fill", nil)
            (titleColor, reasonColor, iconColor, iconName) = ("t1", "t2", "ok-text", "checkmark.circle")
            (chipFill, chipText, chipSymbol) = ("fill2", "t2", "checkmark")
        }
        icon = cardSymbol(iconName, size: 18, color: iconColor, weight: .medium)
        titleField = WrappingLabel(v.title, font: tokenFont("fs-headline", weight: v.level == .calm ? tokenWeight("fs-headline") : 700),
                                   color: titleColor, lines: 3)
        reasonField = WrappingLabel(v.reason, font: tokenFont("fs-control"), color: reasonColor, lines: 4)
        reasonField.isHidden = v.reason.isEmpty
        chip = ChipView(text: v.chip, symbol: chipSymbol, fill: chipFill, fillAlpha: chipAlpha, textColor: chipText)
        super.init(fill: fill, radius: Metric.value("r-panel"), border: border, borderWidth: 1)
        for s in [icon, titleField, reasonField, chip] as [NSView] { addSubview(s) }
        let textBottom: NSView = v.reason.isEmpty ? titleField : reasonField
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 14 + 12),
            icon.topAnchor.constraint(equalTo: titleField.topAnchor, constant: 0),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14 + 24 + 12),
            reasonField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
            reasonField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            reasonField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
        ])
        wide = [
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleField.trailingAnchor.constraint(equalTo: chip.leadingAnchor, constant: -12),
            chip.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            chip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bottomAnchor.constraint(equalTo: textBottom.bottomAnchor, constant: 12).with(priority: .defaultHigh),
            bottomAnchor.constraint(greaterThanOrEqualTo: textBottom.bottomAnchor, constant: 12),
            bottomAnchor.constraint(greaterThanOrEqualTo: chip.bottomAnchor, constant: 12),
            bottomAnchor.constraint(greaterThanOrEqualTo: icon.bottomAnchor, constant: 12),
        ]
        narrowSet = [
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chip.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 6),
            chip.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            chip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: 8),
        ]
        apply()
    }

    required init?(coder: NSCoder) { nil }

    private func apply() {
        NSLayoutConstraint.deactivate(isNarrow ? wide : narrowSet)
        NSLayoutConstraint.activate(isNarrow ? narrowSet : wide)
        // Title 14/700, calm 650 (G12 and system.html's calm verdict); 13 in the narrow pane.
        let weight = verdict.level == .calm ? tokenWeight("fs-headline") : 700
        titleField.font = tokenFont(isNarrow ? "fs-body" : "fs-headline", weight: weight)
        reasonField.isHidden = isNarrow || verdict.reason.isEmpty
    }
}

/// One answer. Caution and danger draw full rows (trust r3-a `.ra-q`): a mark or the finding's number, the question
/// (150 wide, t2, with its question mark), the answer 12.5 and the evidence line in mono under it, a hairline above.
/// Calm draws the tight list (`.ra-ok`): 12 pt marks, question and answer both 12 t2, 3 pt apart, no hairlines.
/// In the narrow pane the question sits above the answer (full rows) or steps aside (tight rows).
@MainActor
final class AnswerRow: NSView {
    enum Style { case full, tight }
    let answer: BinaryCard.Answer
    let number: Int?
    let style: Style
    let questionField: NSTextField
    let answerField: NSTextField
    let evidenceField: NSTextField?
    let lead: NSView
    private var wide: [NSLayoutConstraint] = []
    private var narrowSet: [NSLayoutConstraint] = []
    var isNarrow = false { didSet { if isNarrow != oldValue { apply() } } }

    /// The design's question column; a card whose longest question is wider gets a wider column for every row, so
    /// no question is cut and the answers stay aligned.
    static let questionWidth: CGFloat = 150
    private(set) var questionWidthConstraint: NSLayoutConstraint!

    /// The column every row of a card shares: 150, or the longest question's width (at most 200).
    static func questionColumn(for rows: [AnswerRow]) -> CGFloat {
        let widest = rows.map { ceil($0.questionField.intrinsicContentSize.width) }.max() ?? 0
        return min(200, max(questionWidth, widest))
    }

    init(_ a: BinaryCard.Answer, number: Int?, style: Style) {
        answer = a; self.number = number; self.style = style
        if let number {
            lead = NumberChip(number: number, danger: a.mark == .danger)
        } else {
            let size: CGFloat = style == .tight ? 11 : 13
            switch a.mark {
            case .ok: lead = cardSymbol("checkmark.circle", size: size, color: "ok-text", weight: .medium)
            case .neutral: lead = cardSymbol("minus.circle", size: size, color: "t3", weight: .medium)
            case .caution: lead = cardSymbol("exclamationmark.triangle", size: size, color: "caution-text", weight: .medium)
            case .danger: lead = cardSymbol("xmark.circle", size: size, color: "danger-text", weight: .medium)
            }
        }
        let calmish = style == .tight
        let asked = a.question
        questionField = cardLabel(calmish || !a.asksQuestion ? asked : String(localized: "\(asked)?", bundle: .previewKit,
                                                           comment: "A trust card's question with its question mark; e.g. “Who made it?”."),
                                  font: tokenFont("fs-control"), color: "t2")
        if calmish {
            answerField = cardLabel(a.answer, font: tokenFont("fs-control"), color: "t2")
        } else {
            let color = a.mark == .danger ? "danger-text" : (a.isFinding ? "t1" : "t2")
            answerField = WrappingLabel(a.answer, font: tokenFont("fs-callout", weight: a.isFinding ? 600 : 500), color: color, lines: 3)
        }
        evidenceField = (calmish ? nil : a.evidence).map {
            cardLabel($0, font: .monospacedSystemFont(ofSize: Metric.value("fs-mono-xs"), weight: .regular), color: "t2")
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        var views: [NSView] = [lead, questionField, answerField]
        if let evidenceField { views.append(evidenceField) }
        if style == .full {
            let sep = TokenBox(fill: "sep")
            views.insert(sep, at: 0)
            addSubview(sep)
            NSLayoutConstraint.activate([sep.topAnchor.constraint(equalTo: topAnchor), sep.leadingAnchor.constraint(equalTo: leadingAnchor),
                                         sep.trailingAnchor.constraint(equalTo: trailingAnchor), sep.heightAnchor.constraint(equalToConstant: 0.5)])
        }
        for v in views where v.superview == nil { addSubview(v) }
        let last: NSView = evidenceField ?? answerField
        let leadWidth: CGFloat = 16
        NSLayoutConstraint.activate([
            lead.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 2 + leadWidth / 2),
            answerField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2).with(priority: style == .full ? .required : .defaultHigh),
            answerField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
        ])
        if let evidenceField {
            NSLayoutConstraint.activate([
                evidenceField.topAnchor.constraint(equalTo: answerField.bottomAnchor, constant: 2),
                evidenceField.leadingAnchor.constraint(equalTo: answerField.leadingAnchor),
                evidenceField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            ])
        }
        let pad: CGFloat = style == .full ? 7 : 0
        let afterLead = 2 + leadWidth + 10
        questionWidthConstraint = questionField.widthAnchor.constraint(equalToConstant: Self.questionWidth)
        wide = [
            questionField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: afterLead),
            questionWidthConstraint,
            questionField.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            answerField.leadingAnchor.constraint(equalTo: questionField.trailingAnchor, constant: 10),
            answerField.firstBaselineAnchor.constraint(equalTo: questionField.firstBaselineAnchor),
            lead.centerYAnchor.constraint(equalTo: questionField.centerYAnchor),
            bottomAnchor.constraint(equalTo: last.bottomAnchor, constant: pad),
            bottomAnchor.constraint(greaterThanOrEqualTo: questionField.bottomAnchor, constant: pad),
        ]
        if style == .full {
            // Finder's pane (trust r3-a): the question 10.5 above the answer, 5 pt rows.
            narrowSet = [
                questionField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: afterLead),
                questionField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
                questionField.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                answerField.leadingAnchor.constraint(equalTo: questionField.leadingAnchor),
                answerField.topAnchor.constraint(equalTo: questionField.bottomAnchor, constant: 1),
                lead.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                bottomAnchor.constraint(equalTo: last.bottomAnchor, constant: 5),
            ]
        } else {
            // The calm pane lists the answers alone.
            narrowSet = [
                answerField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: afterLead),
                answerField.topAnchor.constraint(equalTo: topAnchor),
                lead.centerYAnchor.constraint(equalTo: answerField.centerYAnchor),
                bottomAnchor.constraint(equalTo: answerField.bottomAnchor),
            ]
        }
        apply()
    }

    required init?(coder: NSCoder) { nil }

    private func apply() {
        NSLayoutConstraint.deactivate(isNarrow ? wide : narrowSet)
        NSLayoutConstraint.activate(isNarrow ? narrowSet : wide)
        if style == .tight {
            questionField.isHidden = isNarrow
        } else {
            questionField.font = isNarrow ? tokenFont("fs-micro", weight: 400) : tokenFont("fs-control")
            answerField.font = isNarrow ? tokenFont("fs-sub", weight: 600) : tokenFont("fs-callout", weight: answer.isFinding ? 600 : 500)
        }
    }
}

/// Details (⌘I), the capsule's inspector (trust r3-a state 7): 260 wide on card2 with a hairline edge, one
/// "Details" section listing every fact the file gave, key in t2 and value in t1 at 11.5. It starts hidden.
/// A text file's token count is not a row but chrome r3-b's "Tokens" section under the facts: the context-fit
/// meter (A-4).
@MainActor
final class DetailsInspector: TokenBox {
    private(set) var keys: [String] = []
    private(set) var values: [String] = []
    private(set) var tokenMeter: TokenMeterView?

    /// The inspector's width in the design (trust r3-a state 7).
    static let width: CGFloat = 260

    init(facts: [Fact], tokens: TokenCount? = nil, text: String? = nil, fileURL: URL? = nil) {
        super.init(fill: "card2")
        let edge = TokenBox(fill: "sep")
        addSubview(edge)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        addSubview(scroll)
        let doc = CardFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        let heading = cardLabel(String(localized: "Details", bundle: .previewKit, comment: "Heading of the inspector that lists every fact the file gave."),
                                font: tokenFont("fs-caption", weight: 600), color: "t2")
        doc.addSubview(heading)
        let font = tokenFont("fs-sub")
        let shown = facts.filter { $0.key != "headline" && (tokens == nil || $0.key != "tokens") }
        let keyFields = shown.map { cardLabel($0.label, font: font, color: "t2") }
        let keyWidth = min(110, keyFields.map { ceil($0.intrinsicContentSize.width) }.max() ?? 0)
        var previous: NSView = heading
        var constraints = [
            edge.leadingAnchor.constraint(equalTo: leadingAnchor), edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor), edge.widthAnchor.constraint(equalToConstant: 0.5),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0.5), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            heading.topAnchor.constraint(equalTo: doc.topAnchor, constant: 10), heading.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
        ]
        for (fact, key) in zip(shown, keyFields) {
            let value = WrappingLabel(fact.value, font: .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular), color: "t1", lines: 0)
            value.lineBreakMode = .byCharWrapping
            doc.addSubview(key); doc.addSubview(value)
            constraints += [
                key.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12), key.widthAnchor.constraint(equalToConstant: keyWidth),
                key.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: previous === heading ? 6 : 3),
                value.leadingAnchor.constraint(equalTo: key.trailingAnchor, constant: 12), value.firstBaselineAnchor.constraint(equalTo: key.firstBaselineAnchor),
                value.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -12),
            ]
            previous = value
            keys.append(fact.label); values.append(fact.value)
        }
        if let tokens {
            // The design's section rule, then the meter at the facts' inset.
            let rule = TokenBox(fill: "sep")
            let meter = TokenMeterView(meter: TokenMeter(tokens), exactText: text, fileURL: fileURL)
            doc.addSubview(rule); doc.addSubview(meter)
            constraints += [
                rule.leadingAnchor.constraint(equalTo: doc.leadingAnchor), rule.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                rule.heightAnchor.constraint(equalToConstant: 0.5),
                rule.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 10),
                meter.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 10),
                meter.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
                meter.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -12),
            ]
            tokenMeter = meter
            previous = meter
        }
        constraints.append(doc.bottomAnchor.constraint(equalTo: previous.bottomAnchor, constant: 10))
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class CardFlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension NSLayoutConstraint {
    func with(priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint { self.priority = priority; return self }
}
