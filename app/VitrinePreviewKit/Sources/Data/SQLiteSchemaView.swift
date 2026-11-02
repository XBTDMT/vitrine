import AppKit
import VitrineData
import VitrineUI

/// The SQLite Schema view (D-2, data "SQLite schema"): the picked table's columns with their type and constraint
/// chips, its indexes and triggers, then the CREATE statements in the unified syntax palette (G14). Shown in place of
/// the rows when the viewer switch picks Schema. roadmap: S-6
@MainActor
final class SQLiteSchemaView: NSView {
    let scroll = NSScrollView()
    private let stack = NSStackView()
    private let model: SQLiteDataModel
    /// The text of every row, for tests.
    private(set) var lines: [String] = []

    init(model: SQLiteDataModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        scroll.documentView = flipped
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            flipped.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            flipped.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor, constant: -18),
        ])
        reload()
    }

    required init?(coder: NSCoder) { nil }

    func reload() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        lines = []
        guard let object = model.current else { return }
        let sql = object.sql ?? ""
        for (i, column) in model.columns.enumerated() {
            let row = columnRow(column, tag: model.typeTag(i), autoincrement: column.primaryKeyPosition > 0
                                && sql.range(of: "AUTOINCREMENT", options: .caseInsensitive) != nil)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let dependents = model.db.dependents(of: object.name)
        if !dependents.isEmpty {
            let heading = DataProfileViews.label(String(localized: "Indexes · triggers", bundle: .previewKit, comment: "Schema view heading over a table's indexes and triggers."), size: Metric.value("fs-caption"), token: "t2", weight: .semibold)
            stack.addArrangedSubview(spacer(14))
            stack.addArrangedSubview(heading)
            stack.addArrangedSubview(spacer(6))
            for d in dependents {
                let row = dependentRow(d)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        if !model.schemaSQL.isEmpty {
            stack.addArrangedSubview(spacer(16))
            let code = NSTextField(labelWithAttributedString: Self.highlight(model.schemaSQL))
            code.lineBreakMode = .byCharWrapping
            code.maximumNumberOfLines = 0
            code.isSelectable = true
            let box = TokenBox(fill: "fill", radius: Metric.value("r-card"))
            code.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(code)
            NSLayoutConstraint.activate([
                code.topAnchor.constraint(equalTo: box.topAnchor, constant: 10), code.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
                code.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12), code.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            ])
            stack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// One column: its tag, name and type, then chips for each constraint, on a 30 pt row over a `sep` line.
    private func columnRow(_ c: SQLiteColumn, tag: String, autoincrement: Bool) -> NSView {
        var chips: [String] = []
        if c.primaryKeyPosition > 0 { chips.append("PRIMARY KEY") }
        if autoincrement { chips.append("AUTOINCREMENT") }
        if c.notNull { chips.append("NOT NULL") }
        if let ref = c.references {
            let key = String(localized: "key", bundle: .previewKit, comment: "Stands for a referenced table's primary key in “table.key”, when the reference names no column.")
            chips.append("→ \(ref.table).\(ref.column ?? key)")
            if ref.onDelete != "NO ACTION" { chips.append(ref.onDelete) }
        }
        if let d = c.defaultValue { chips.append("DEFAULT \(d)") }
        if c.isGenerated { chips.append("GENERATED") }
        if c.isIndexed, c.primaryKeyPosition == 0 {
            chips.append(String(localized: "indexed", bundle: .previewKit, comment: "Column header tooltip: the column has an index."))
        }
        lines.append(([c.name, c.declaredType] + chips).joined(separator: " "))
        let name = DataProfileViews.label(c.name, size: Metric.value("fs-control"), token: "t1", weight: .semibold, mono: false)
        name.font = .monospacedSystemFont(ofSize: Metric.value("fs-control"), weight: .semibold)
        let type = DataProfileViews.label(c.declaredType.isEmpty ? String(localized: "any", bundle: .previewKit, comment: "Schema view: a column with no declared type (it takes any type).") : c.declaredType, size: Metric.value("fs-sub"), token: "syn-ty")
        type.font = .monospacedSystemFont(ofSize: Metric.value("fs-sub"), weight: .regular)
        var views: [NSView] = [TagView(tag: tag), name, type]
        views += chips.map { Chip(text: $0, accent: $0.hasPrefix("→")) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 6
        row.setCustomSpacing(8, after: name)
        row.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return Underlined(row)
    }

    /// "idx_notes_folder · on folder_id", "notes_touch · trigger · after update".
    private func dependentRow(_ d: SQLiteObject) -> NSView {
        let sql = d.sql ?? ""
        let detail: String
        if d.kind == .index {
            // The column list between the first "(" and the ")" after it (an expression index may show cut short).
            if let open = sql.firstIndex(of: "("), let close = sql[open...].firstIndex(of: ")") {
                let columns = sql[sql.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                detail = String(localized: "on \(columns)", bundle: .previewKit, comment: "Schema view: the columns an index covers (SQL text).")
            } else {
                detail = sql.isEmpty
                    ? String(localized: "automatic index", bundle: .previewKit, comment: "Schema view: an index SQLite made itself.")
                    : String(localized: "index", bundle: .previewKit, comment: "Schema view: an index whose columns could not be read.")
            }
        } else {
            let timing = ["BEFORE", "AFTER", "INSTEAD OF"].first { sql.range(of: $0, options: .caseInsensitive) != nil }?.lowercased() ?? ""
            let event = ["INSERT", "UPDATE", "DELETE"].first { sql.range(of: " \($0)", options: .caseInsensitive) != nil }?.lowercased() ?? ""
            detail = [String(localized: "trigger", bundle: .previewKit, comment: "Schema view: the object is a trigger; followed by its SQL timing and event (“after update”)."), [timing, event].filter { !$0.isEmpty }.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        lines.append("\(d.name) \(detail)")
        let name = DataProfileViews.label(d.name, size: Metric.value("fs-control"), token: "t1")
        name.font = .monospacedSystemFont(ofSize: Metric.value("fs-control"), weight: .regular)
        let row = NSStackView(views: [name, DataProfileViews.label(detail, size: Metric.value("fs-sub"), token: "t2")])
        row.orientation = .horizontal
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return row
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    /// SQL in the unified syntax palette: keywords `syn-kw`, strings `syn-str`, numbers `syn-num`, types `syn-ty`, the
    /// rest t1. A small tokenizer: enough for CREATE statements, not a SQL parser.
    static func highlight(_ sql: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: Metric.value("fs-sub"), weight: .regular)
        let out = NSMutableAttributedString(string: sql, attributes: [.font: font, .foregroundColor: NSColor.token("t1")])
        let keywords = ["CREATE", "TABLE", "INDEX", "UNIQUE", "TRIGGER", "VIEW", "VIRTUAL", "USING", "ON", "IF", "NOT", "EXISTS",
                        "PRIMARY", "KEY", "AUTOINCREMENT", "NULL", "DEFAULT", "REFERENCES", "FOREIGN", "CHECK", "IN", "DELETE", "UPDATE",
                        "INSERT", "CASCADE", "SET", "RESTRICT", "NO", "ACTION", "AFTER", "BEFORE", "INSTEAD", "OF", "FOR", "EACH", "ROW",
                        "BEGIN", "END", "WHEN", "AS", "SELECT", "FROM", "WHERE", "AND", "OR", "WITHOUT", "ROWID", "COLLATE", "DESC", "ASC",
                        "GENERATED", "ALWAYS", "STORED", "CONSTRAINT", "CURRENT_TIMESTAMP"]
        let types = ["INTEGER", "INT", "TEXT", "REAL", "BLOB", "NUMERIC", "BOOLEAN", "DATE", "DATETIME", "VARCHAR", "CHAR", "FLOAT", "DOUBLE"]
        let ns = sql as NSString
        func paint(_ pattern: String, _ token: String, options: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for m in re.matches(in: sql, range: NSRange(location: 0, length: ns.length)) {
                out.addAttribute(.foregroundColor, value: NSColor.token(token), range: m.range)
            }
        }
        paint(#"\b(\#(keywords.joined(separator: "|")))\b"#, "syn-kw", options: .caseInsensitive)
        paint(#"\b(\#(types.joined(separator: "|")))\b"#, "syn-ty", options: .caseInsensitive)
        paint(#"\b\d+(\.\d+)?\b"#, "syn-num")
        paint(#"'(?:[^']|'')*'"#, "syn-str")
        paint(#"--[^\n]*"#, "syn-com")
        return out
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.token("page").cgColor }
}

/// A constraint chip: 18 pt, mono 10.5 in t2 on `fill`, radius 5; a link in accent text.
final class Chip: NSView {
    init(text: String, accent: Bool) {
        super.init(frame: .zero)
        let label = DataProfileViews.label(text, size: Metric.value("fs-micro"), token: accent ? "accent-text" : "t2")
        label.font = .monospacedSystemFont(ofSize: Metric.value("fs-micro"), weight: .medium)
        let box = TokenBox(fill: "fill", radius: 5)
        for v in [box, label] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(box)
        box.addSubview(label)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor), box.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor), box.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 18),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6), label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
        ])
    }
    required init?(coder: NSCoder) { nil }
}

/// A row with a 0.5 pt `sep` line under it.
final class Underlined: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        let line = SepLine()
        for v in [content, line] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor), content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor), content.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor), line.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }
    required init?(coder: NSCoder) { nil }
}
