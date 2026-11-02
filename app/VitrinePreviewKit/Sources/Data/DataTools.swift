import AppKit
import VitrineUI

/// The caution banner above the rows (I-6, data "Lint banner", markdown 6's `.banner`): the warning glyph, what is
/// wrong in one line ("3 of 31,077 rows have 10 fields instead of 9."), where to read more, and Next issue (with its
/// place, "1 of 3") and Text view. Caution-soft ground, a 0.5 pt caution line under it. roadmap: S-6
@MainActor
final class LintBanner: NSView {
    static let height: CGFloat = 52
    var onNext: (() -> Void)?
    var onText: (() -> Void)?
    let message = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    private let next = NSButton(title: String(localized: "Next issue", bundle: .previewKit, comment: "Banner button: select the next row with a problem."), target: nil, action: nil)
    private let text = NSButton(title: String(localized: "Text view", bundle: .previewKit, comment: "Banner button: show the file as plain text."), target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let glyph = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: String(localized: "Caution", bundle: .previewKit, comment: "Accessibility description of the warning icon.")) ?? NSImage())
        glyph.contentTintColor = NSColor.token("caution")
        message.font = .systemFont(ofSize: Metric.value("fs-callout"), weight: .semibold)
        message.textColor = NSColor.token("t1")
        message.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: Metric.value("fs-sub"))
        detail.textColor = NSColor.token("t2")
        for b in [next, text] { b.bezelStyle = .push; b.controlSize = .small; b.target = self }
        next.action = #selector(nextPressed)
        text.action = #selector(textPressed)
        let words = NSStackView(views: [message, detail])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 1
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [glyph, words, NSView(), next, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        let line = LineView(token: "caution")
        for v in [row, line] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor), row.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor), line.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    /// `step` is the issue last shown (-1 before Next issue).
    func show(_ lint: DataLint, step: Int) {
        message.stringValue = lint.message
        if step >= 0, !lint.rows.isEmpty {
            let shown = (step + 1).formatted(), total = lint.rows.count.formatted()
            detail.stringValue = String(localized: "The File tab lists the rows; the file is never changed · showing \(shown) of \(total).", bundle: .previewKit, comment: "Banner detail while stepping through problem rows. Arguments: the problem shown, how many.")
        } else {
            detail.stringValue = String(localized: "The File tab lists the rows; the file is never changed.", bundle: .previewKit, comment: "Banner detail: where the problem rows are listed.")
        }
        next.isEnabled = !lint.rows.isEmpty
        setAccessibilityLabel("\(lint.message) \(detail.stringValue)")
    }

    @objc private func nextPressed() { onNext?() }
    @objc private func textPressed() { onText?() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("caution-soft").cgColor }
}

/// A 0.5 pt line in one token.
final class LineView: NSView {
    let token: String
    init(token: String) { self.token = token; super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token(token).cgColor }
}

/// Copy as (I-7): a block of shown rows and columns as CSV, TSV, a Markdown table, JSON objects or SQL INSERT
/// statements. Cells come from `TabularModel.cell`, so a NULL (drawn dim) exports as empty / null. roadmap: S-6
@MainActor
struct DataExport {
    let model: any TabularModel
    let rows: [Int]
    let columns: [Int]
    let table: String

    private func value(_ row: Int, _ column: Int) -> String? {
        let cell = model.cell(row: row, column: column)
        return cell.style == .missing ? nil : cell.text
    }

    /// RFC 4180 for ","; for a tab, tabs and line breaks inside a cell become spaces.
    func delimited(_ separator: String) -> String {
        func field(_ s: String) -> String {
            if separator == "\t" { return s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            guard s.contains(separator) || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = [columns.map { field(model.title($0)) }.joined(separator: separator)]
        for r in rows { lines.append(columns.map { field(value(r, $0) ?? "") }.joined(separator: separator)) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Numbers columns right-aligned (`---:`); `|` escaped; line breaks as spaces.
    func markdown() -> String {
        func cell(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        var lines = ["| " + columns.map { cell(model.title($0)) }.joined(separator: " | ") + " |"]
        lines.append("|" + columns.map { model.isNumeric($0) ? "---:|" : "---|" }.joined())
        for r in rows { lines.append("| " + columns.map { cell(value(r, $0) ?? "") }.joined(separator: " | ") + " |") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// An array of objects; numbers columns write numbers when the cell is one, NULL writes null.
    func json() -> String {
        let objects: [[String: Any]] = rows.map { r in
            var object: [String: Any] = [:]
            for c in columns {
                if model.isNumeric(c), let n = model.number(row: r, column: c) { object[model.title(c)] = n }
                else { object[model.title(c)] = value(r, c) ?? NSNull() }
            }
            return object
        }
        let data = (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// One INSERT per row into the table's own name; numbers unquoted, text single-quoted, NULL as NULL.
    func sqlInsert() -> String {
        func ident(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let head = "INSERT INTO \(ident(table)) (" + columns.map { ident(model.title($0)) }.joined(separator: ", ") + ") VALUES ("
        return rows.map { r in
            head + columns.map { c -> String in
                guard let v = value(r, c) else { return "NULL" }
                if model.isNumeric(c), let n = model.number(row: r, column: c) {
                    return n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
                }
                return "'" + v.replacingOccurrences(of: "'", with: "''") + "'"
            }.joined(separator: ", ") + ");"
        }.joined(separator: "\n") + "\n"
    }
}
