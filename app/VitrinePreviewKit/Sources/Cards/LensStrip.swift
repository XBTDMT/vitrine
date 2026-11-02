import AppKit
import VitrineTrust
import VitrineUI

/// The trust lens over a text preview (S-20, trust r3-a states 8, 9, 11, 12): the cards' verdict box, then the
/// numbered findings, each with its line and, when it has one, a short quote. Up to five findings show; the rest are
/// counted. A calm result has no strip (the gutter says it was checked). roadmap: S-20
@MainActor
final class LensStripView: TokenBox {
    static let shownFindings = 5
    let report: LensReport

    init(report: LensReport) {
        self.report = report
        // A token box resolves its colour for the appearance it is drawn in (a plain layer colour kept the one of the
        // moment it was made: dark under a light preview).
        super.init(fill: "page")
        let level: BinaryCard.Verdict.Level = report.level == .danger ? .danger : .caution
        let box = VerdictBoxView(BinaryCard.Verdict(level: level, title: report.headline, reason: "", chip: report.chip ?? ""))
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        var constraints = [
            box.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ]
        var last: NSView = box
        for (i, f) in report.findings.prefix(Self.shownFindings).enumerated() {
            let row = Self.row(number: i + 1, finding: f)
            addSubview(row)
            constraints += [
                row.topAnchor.constraint(equalTo: last.bottomAnchor, constant: i == 0 ? 10 : 6),
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            ]
            last = row
        }
        if report.findings.count > Self.shownFindings {
            let more = cardLabel(String(localized: "and \(report.findings.count - Self.shownFindings) more", bundle: .previewKit,
                                        comment: "Trust strip: how many findings are not listed."),
                                 font: tokenFont("fs-caption"), color: "t2")
            addSubview(more)
            constraints += [more.topAnchor.constraint(equalTo: last.bottomAnchor, constant: 6), more.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44)]
            last = more
        }
        let rule = TokenBox(fill: "sep")
        addSubview(rule)
        constraints += [
            rule.topAnchor.constraint(equalTo: last.bottomAnchor, constant: 12),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor), rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 0.5),
            bottomAnchor.constraint(equalTo: rule.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(report.headline)
    }

    required init?(coder: NSCoder) { nil }

    /// "① Downloads and runs code · line 5", then the quote in mono under it.
    static func row(number: Int, finding f: LensReport.Finding) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let chip = NumberChip(number: number, danger: f.level == .danger)
        chip.translatesAutoresizingMaskIntoConstraints = false
        var title = f.title
        if let line = f.line, !title.contains(String(line)) {
            title = String(localized: "\(f.title) · line \(line)", bundle: .previewKit, comment: "Trust strip finding: what it is, then its line number.")
        }
        let label = cardLabel(title, font: tokenFont("fs-control", weight: 600), color: "t1")
        row.addSubview(chip); row.addSubview(label)
        var constraints = [
            chip.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            chip.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
            label.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: row.topAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
        ]
        var bottom: NSView = label
        if let detail = f.detail, !detail.isEmpty {
            let quote = cardLabel(detail, font: .monospacedSystemFont(ofSize: Metric.value("fs-caption"), weight: .regular), color: "t2")
            quote.lineBreakMode = .byTruncatingTail
            row.addSubview(quote)
            constraints += [
                quote.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                quote.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
                quote.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            ]
            bottom = quote
        }
        constraints.append(row.bottomAnchor.constraint(equalTo: bottom.bottomAnchor))
        NSLayoutConstraint.activate(constraints)
        return row
    }
}
