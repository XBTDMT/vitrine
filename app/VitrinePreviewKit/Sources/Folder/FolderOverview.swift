import AppKit
import VitrineUI

/// The storage overview the kinds hairline opens in place (N-10, `.ov` on `zebra` with a `sep` rule): the 12 pt
/// kinds bar, the legend (kind, bytes, count), the total, then the largest items with size bars and the
/// subfolders with their item counts, each a way into that folder. Every number comes from the background count;
/// until it is done they are floors and the total says so. roadmap: S-9
@MainActor
final class FolderOverview: NSView {
    var onOpenFolder: ((FolderNode) -> Void)?
    var onPeek: ((FolderNode) -> Void)?
    private let stack = NSStackView()
    private let rule = CALayer()
    private(set) var totalLine = ""
    private(set) var largestNames: [String] = []
    private(set) var folderNames: [String] = []
    static let rowsShown = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(rule)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // The overview wants its content's height, but below the window's own size (500) and the list's minimum
        // (495): in a short panel it is cut at the bottom instead of pushing the path row out of view.
        let fit = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        fit.priority = .init(490)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10), stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14), fit,
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Storage overview", bundle: .previewKit, comment: "Accessibility label of the folder's storage overview panel."))
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.token("zebra").cgColor
        rule.backgroundColor = NSColor.token("sep").cgColor
    }

    override func layout() {
        super.layout()
        rule.frame = NSRect(x: 0, y: isFlipped ? bounds.maxY - 0.5 : 0, width: bounds.width, height: 0.5)
        // The wrapping legend needs a fixed wrap width, or its height and width chase each other.
        let width = stack.frame.width
        if let legend = legendLabel, width > 0, abs(legend.preferredMaxLayoutWidth - width) > 0.5 { legend.preferredMaxLayoutWidth = width }
    }

    private weak var legendLabel: NSTextField?

    /// "48.2 GB in 186 items", "At least 412 MB in 31,880 items · still counting", "At least … · stopped at 250,000 items".
    static func totalText(_ s: FolderSizes, limit: Int) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: s.totalBytes, countStyle: .file)
        let count = s.totalItems.formatted(), one = s.totalItems == 1
        if s.complete {
            return one ? String(localized: "\(bytes) in \(count) item", bundle: .previewKit, comment: "Storage overview total: a size in one item.") : String(localized: "\(bytes) in \(count) items", bundle: .previewKit, comment: "Storage overview total. Arguments: a size, the number of items.")
        }
        if !s.finished {
            return one ? String(localized: "At least \(bytes) in \(count) item · still counting", bundle: .previewKit, comment: "Storage overview total while counting, one item so far.") : String(localized: "At least \(bytes) in \(count) items · still counting", bundle: .previewKit, comment: "Storage overview total while counting. Arguments: a size, the number of items so far.")
        }
        let stop = min(s.totalItems, limit).formatted()
        return one ? String(localized: "At least \(bytes) in \(count) item · counting stopped at \(stop) items", bundle: .previewKit, comment: "Storage overview total when counting hit its limit, one item. Arguments: size, count, the limit.") : String(localized: "At least \(bytes) in \(count) items · counting stopped at \(stop) items", bundle: .previewKit, comment: "Storage overview total when counting hit its limit. Arguments: size, count, the limit.")
    }

    func update(sizes: FolderSizes, nodes: [FolderNode], limit: Int, folderSize: (FolderNode) -> Int64?) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        let kinds = sizes.byKind.filter { $0.value.bytes > 0 || $0.value.items > 0 }.sorted { $0.value.bytes > $1.value.bytes }
        let total = Double(max(1, kinds.reduce(Int64(0)) { $0 + $1.value.bytes }))
        let bar = KindsBar(shares: kinds.map { ($0.key, Double($0.value.bytes) / total) })
        bar.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(bar)
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let legend = NSMutableAttributedString()
        let small = NSFont.systemFont(ofSize: Metric.value("fs-caption"))
        for (i, (token, entry)) in kinds.enumerated() {
            if i > 0 { legend.append(NSAttributedString(string: "    ", attributes: [.font: small])) }
            legend.append(NSAttributedString(string: "■ ", attributes: [.font: small, .foregroundColor: NSColor.token(token)]))
            legend.append(NSAttributedString(string: FolderSizer.kindName(token) + " ", attributes: [.font: small, .foregroundColor: NSColor.token("t2")]))
            legend.append(NSAttributedString(string: ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file),
                                             attributes: [.font: NSFont.systemFont(ofSize: Metric.value("fs-caption"), weight: .medium), .foregroundColor: NSColor.token("t1")]))
            legend.append(NSAttributedString(string: " · \(entry.items.formatted())", attributes: [.font: small, .foregroundColor: NSColor.token("t2")]))
        }
        if legend.length > 0 {
            let l = NSTextField(labelWithAttributedString: legend)
            l.lineBreakMode = .byWordWrapping
            l.maximumNumberOfLines = 3
            l.preferredMaxLayoutWidth = max(200, stack.frame.width)
            legendLabel = l
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(l)
            l.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        totalLine = Self.totalText(sizes, limit: limit)
        let totalLabel = NSTextField(labelWithString: totalLine)
        totalLabel.font = .systemFont(ofSize: Metric.value("fs-caption"), weight: .medium)
        totalLabel.textColor = NSColor.token(sizes.complete ? "t2" : "t3")
        stack.addArrangedSubview(totalLabel)
        stack.setCustomSpacing(4, after: totalLabel)

        // Largest items (files and folders) and the subfolders, side by side; one column in a narrow pane.
        let largest = nodes.compactMap { n in folderSize(n).map { (n, $0) } }.sorted { $0.1 > $1.1 }.prefix(Self.rowsShown)
        let maxBytes = Double(max(1, largest.first?.1 ?? 1))
        largestNames = largest.map(\.0.name)
        let left = column(largest.map { n, bytes in
            OverviewRow(node: n, detail: nil, bytes: bytes, fraction: Double(bytes) / maxBytes, chevron: false) { [weak self] in
                if n.isFolder { self?.onOpenFolder?(n) } else { self?.onPeek?(n) }
            }
        })
        let folders = nodes.filter(\.isFolder).sorted { (folderSize($0) ?? -1) > (folderSize($1) ?? -1) }.prefix(Self.rowsShown)
        folderNames = folders.map(\.name)
        let right = column(folders.map { n in
            let entry = sizes.children[n.name]
            let items = entry.map { e -> String in
                let count = e.items.formatted()
                switch (e.complete, e.items == 1) {
                case (true, true): return String(localized: "\(count) item", bundle: .previewKit, comment: "Storage overview: a folder holds one item.")
                case (true, false): return String(localized: "\(count) items", bundle: .previewKit, comment: "Storage overview: how many items a folder holds.")
                case (false, true): return String(localized: "≥ \(count) item", bundle: .previewKit, comment: "Storage overview: a folder holds at least one item (still counting).")
                case (false, false): return String(localized: "≥ \(count) items", bundle: .previewKit, comment: "Storage overview: a folder holds at least this many items (still counting).")
                }
            } ?? FolderOutline.counting
            return OverviewRow(node: n, detail: items, bytes: folderSize(n), fraction: nil, chevron: true) { [weak self] in self?.onOpenFolder?(n) }
        })
        let columns = NSStackView(views: [left, right])
        columns.distribution = .fillEqually
        columns.alignment = .top
        columns.spacing = 24
        columns.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(columns)
        columns.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        narrow = right
        right.isHidden = bounds.width > 0 && bounds.width < 420 || folders.isEmpty
        left.isHidden = largest.isEmpty
    }

    private weak var narrow: NSView?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if let narrow, !folderNames.isEmpty { narrow.isHidden = bounds.width < 420 }
    }

    private func column(_ rows: [OverviewRow]) -> NSStackView {
        let s = NSStackView(views: rows)
        s.orientation = .vertical
        s.spacing = 0
        s.alignment = .leading
        for r in rows { r.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
        return s
    }
}

/// One overview row (24 pt, a `sep` rule under it): icon, name, then a size bar and size, or an item count, size
/// and a chevron into the folder. roadmap: S-9
@MainActor
private final class OverviewRow: NSView {
    private let action: () -> Void
    private let rule = CALayer()

    init(node: FolderNode, detail: String?, bytes: Int64?, fraction: Double?, chevron: Bool, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(rule)
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: node.url.path))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let name = NSTextField(labelWithString: node.name)
        name.font = .systemFont(ofSize: Metric.value("fs-callout"))
        name.textColor = NSColor.token("t1")
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, name]
        if let detail {
            let d = NSTextField(labelWithString: detail)
            d.font = .systemFont(ofSize: Metric.value("fs-caption"))
            d.textColor = NSColor.token("t3")
            views.append(d)
        }
        if let fraction {
            let bar = SizeBar(fraction: fraction, token: node.isFolder ? "kind-folder" : FolderSizer.kindToken(name: node.name, isPackage: !node.isFolder && node.isPackage))
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 70).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 5).isActive = true
            views.append(bar)
        }
        let size = NSTextField(labelWithString: bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
        size.font = .monospacedDigitSystemFont(ofSize: Metric.value("fs-callout"), weight: .regular)
        size.textColor = NSColor.token("t2")
        size.alignment = .right
        size.translatesAutoresizingMaskIntoConstraints = false
        size.widthAnchor.constraint(equalToConstant: 60).isActive = true
        views.append(size)
        if chevron, let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: String(localized: "Open", bundle: .previewKit, comment: "Accessibility description of the chevron that opens a folder.")) {
            let c = NSImageView(image: image)
            c.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            c.contentTintColor = NSColor.token("t3")
            views.append(c)
        }
        let row = NSStackView(views: views)
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        let nodeName = node.name
        toolTip = node.isFolder
            ? String(localized: "Open \(nodeName)", bundle: .previewKit, comment: "Tooltip: open this folder in the preview; the argument is its name.")
            : String(localized: "Peek at \(nodeName)", bundle: .previewKit, comment: "Tooltip: preview this item beside the list; the argument is its name.")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(node.name), \(size.stringValue)")
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { rule.backgroundColor = NSColor.token("sep").cgColor }
    override func layout() {
        super.layout()
        rule.frame = NSRect(x: 0, y: isFlipped ? bounds.maxY - 0.5 : 0, width: bounds.width, height: 0.5)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

/// The 12 pt kinds bar (`.kbar`): rounded, a 1.5 pt gap between kinds, on `fill`. roadmap: S-9
@MainActor
final class KindsBar: NSView {
    private let shares: [(token: String, share: Double)]

    init(shares: [(token: String, share: Double)]) {
        self.shares = shares.filter { $0.share > 0 }
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).addClip()
        NSColor.token("fill").setFill()
        bounds.fill()
        var x = bounds.minX
        for (i, part) in shares.enumerated() {
            let w = i == shares.count - 1 ? bounds.maxX - x : (bounds.width * part.share).rounded()
            NSColor.token(part.token).setFill()
            NSRect(x: x, y: 0, width: max(0, w - (i == shares.count - 1 ? 0 : 1.5)), height: bounds.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A 5 pt size bar (`.szb`) filled to `fraction` in a kind colour. roadmap: S-9
@MainActor
private final class SizeBar: NSView {
    private let fraction: Double
    private let token: String
    init(fraction: Double, token: String) { self.fraction = fraction; self.token = token; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        NSColor.token("fill").setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        NSColor.token(token).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * fraction), height: bounds.height), xRadius: r, yRadius: r).fill()
    }
}
