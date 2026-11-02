import AppKit
import VitrineUI

/// The design's motion tokens as seconds (`--v-dur-base` 250 ms, `--v-dur-fast` 150 ms), read from the generated
/// tokens so a token change reaches the native views. roadmap: S-9
enum BrowseMotion {
    static func duration(_ name: String) -> TimeInterval {
        guard let raw = GeneratedTokens.metrics.first(where: { $0.name == name })?.value, raw.hasSuffix("ms"),
              let ms = Double(raw.dropLast(2)) else { return 0.25 }
        return ms / 1000
    }

    /// Reduce Motion turns slides into fades (browse 7).
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// A small control drawn in the design's styles: `.btn.sm` (20 pt, radius 6, `ctl` with the control shadow) for
/// the path row's arrangement button, `.chip.btnish` (22 pt, radius 11) for the Overview chip. It runs its action,
/// or pops up its menu under itself. roadmap: S-9
@MainActor
final class BrowseButton: NSControl {
    enum Style { case small, chip }
    private let style: Style
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let trailingIcon = NSImageView()
    var popUpMenu: NSMenu?
    var onPress: (() -> Void)?

    init(style: Style, symbol: String?, title: String, trailingSymbol: String? = nil) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        let height: CGFloat = style == .small ? Metric.value("h-ctl-sm") : Metric.value("h-chip")
        layer?.cornerRadius = style == .small ? Metric.value("r-ctl") : height / 2
        label.font = .systemFont(ofSize: style == .small ? Metric.value("fs-sub") : Metric.value("fs-sub"), weight: .medium)
        label.textColor = NSColor.token("t1")
        let pointSize: CGFloat = style == .small ? 11 : 11.5
        for (view, name) in [(icon, symbol), (trailingIcon, trailingSymbol)] {
            guard let name, let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { view.isHidden = true; continue }
            view.image = image
            view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: view === trailingIcon ? 8.5 : pointSize, weight: .medium)
            view.contentTintColor = NSColor.token("t2")
        }
        let stack = NSStackView(views: [icon, label, trailingIcon])
        stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style == .small ? 7 : 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: style == .small ? -7 : -9),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        self.title = title
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; setAccessibilityLabel(newValue) }
    }

    func setTrailingSymbol(_ name: String) {
        trailingIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.token("ctl").cgColor
        layer?.borderColor = NSColor.token("hair").cgColor
        layer?.borderWidth = 0.5
    }

    override func mouseDown(with event: NSEvent) { press() }

    /// The click: pops up the menu under the button (flipped or not), or runs the action.
    func press() {
        if let popUpMenu {
            popUpMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.height + 4 : -4), in: self)
        } else {
            onPress?()
        }
    }

    override func accessibilityPerformPress() -> Bool { press(); return true }
}

/// The path row's breadcrumbs (`.gb .path`): every crumb but the last is a link back out; the last is where you
/// are (t1, semibold). Shared by the folder and (later) the archive outline. roadmap: S-9
@MainActor
final class BrowsePathRow: NSView {
    struct Crumb {
        var title: String
        var icon: NSImage?
        /// Called when the crumb is clicked; nil = not a link (the current place, or context above the preview).
        var action: (() -> Void)?
    }

    private let crumbStack = NSStackView()
    private let accessoryStack = NSStackView()
    private(set) var crumbs: [Crumb] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        crumbStack.spacing = 2
        crumbStack.setHuggingPriority(.defaultLow, for: .horizontal)
        accessoryStack.spacing = 8
        accessoryStack.setHuggingPriority(.required, for: .horizontal)
        for v in [crumbStack, accessoryStack] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            crumbStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), crumbStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), accessoryStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            crumbStack.trailingAnchor.constraint(lessThanOrEqualTo: accessoryStack.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// The crumbs' words, for tests and accessibility.
    var titles: [String] { crumbs.map(\.title) }

    func setCrumbs(_ crumbs: [Crumb]) {
        self.crumbs = crumbs
        for v in crumbStack.arrangedSubviews { crumbStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, crumb) in crumbs.enumerated() {
            if i > 0, let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
                let sep = NSImageView(image: chevron)
                sep.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
                sep.contentTintColor = NSColor.token("t3")
                crumbStack.addArrangedSubview(sep)
            }
            let last = i == crumbs.count - 1
            let view = CrumbView(crumb: crumb, current: last)
            // The current place keeps its name; earlier crumbs give way first.
            view.setContentCompressionResistancePriority(last ? .init(490) : .init(250 + Float(i)), for: .horizontal)
            crumbStack.addArrangedSubview(view)
        }
    }

    func setAccessories(_ views: [NSView]) {
        for v in accessoryStack.arrangedSubviews { accessoryStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for v in views { accessoryStack.addArrangedSubview(v) }
    }

    /// Clicks the crumb at `index` (tests).
    func activateCrumb(_ index: Int) { crumbs[index].action?() }
}

/// One crumb: icon and name, a link when it has an action.
@MainActor
private final class CrumbView: NSView {
    private let action: (() -> Void)?

    init(crumb: BrowsePathRow.Crumb, current: Bool) {
        action = crumb.action
        super.init(frame: .zero)
        var views: [NSView] = []
        if let image = crumb.icon {
            let icon = NSImageView(image: image)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
            views.append(icon)
        }
        let label = NSTextField(labelWithString: crumb.title)
        label.font = .systemFont(ofSize: Metric.value("fs-control"), weight: current ? .semibold : .regular)
        label.textColor = NSColor.token(current ? "t1" : "t2")
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        views.append(label)
        let stack = NSStackView(views: views)
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        if action != nil {
            toolTip = String(localized: "Back to \(crumb.title)", bundle: .previewKit, comment: "Tooltip of a path crumb: go back to that folder.")
            setAccessibilityRole(.link)
        }
        setAccessibilityLabel(crumb.title)
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        if action != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) { action?() }
    override func accessibilityPerformPress() -> Bool { action?(); return action != nil }
}
