import SwiftUI
import VitrinePreviewKit
import VitrineUI

// The Settings window's rows and controls (S-10, design/mockups/unified/settings.html): `.grow` rows in `.grp` groups,
// native controls, the sea-glass edge and Reset link on a row changed from its default, and the Markdown theme tiles.
// roadmap: S-10

/// D4, "Accent follows the Mac": switches, sliders and selections take the Mac's accent colour, and sea glass
/// (`--v-accent`) under Multicolor, where macOS leaves `AppleAccentColor` unset.
enum SettingsAccent {
    static var color: Color {
        UserDefaults.standard.object(forKey: "AppleAccentColor") == nil ? Color.token("accent") : Color.accentColor
    }
}

/// One `.grow`: the label (title, optional subtitle, Reset when changed) and its control on the right.
struct SettingsRowView: View {
    @ObservedObject var store: SettingsStore
    let row: SettingsRow
    var highlighted = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let changed = store.isChanged(row)
        Group {
            if row.control == .markdownThemes {
                VStack(alignment: .trailing, spacing: 6) {
                    if changed {
                        Button("Reset") { store.reset(row) }
                            .buttonStyle(.plain)
                            .font(.v("caption")).foregroundStyle(Color.token("accent-text"))
                            .help("Back to the default theme")
                    }
                    MarkdownThemeGallery(store: store, row: row)
                }
                .padding(12)
            } else if row.id == "general.strip.facts" {
                // A wide row (settings r3-a): the title, then the chips wrapping across the whole row.
                VStack(alignment: .leading, spacing: 7) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(.v("body")).foregroundStyle(Color.token("t1"))
                        if let subtitle = subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.v("sub")).foregroundStyle(Color.token("t2"))
                        }
                    }
                    MetadataStripChips(store: store)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8).padding(.horizontal, 12)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 0) {
                            Text(row.title).font(.v("body")).foregroundStyle(Color.token("t1"))
                            if changed {
                                Button("Reset") { store.reset(row); afterChange() }
                                    .buttonStyle(.plain)
                                    .font(.v("caption")).foregroundStyle(Color.token("accent-text"))
                                    .padding(.leading, 9)
                                    .help("Back to the default")
                            }
                        }
                        if let subtitle = subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.v("sub")).foregroundStyle(Color.token("t2"))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    control.fixedSize()
                }
                .padding(.vertical, 7).padding(.horizontal, 12)
                .frame(minHeight: Metric.value("h-row-set"))
            }
        }
        .background(highlighted ? Color.token("accent-soft") : .clear)
        .overlay(alignment: .leading) {
            if changed {
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 2, topTrailingRadius: 2)
                    .fill(SettingsAccent.color)
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
        }
        .tint(SettingsAccent.color)
    }

    private var subtitle: String? {
        switch row.id {
        case "privacy.recents":
            let n = RecentPreviewsCount.now
            return n == 0 ? String(localized: "None kept · path, kind and counts of the last ten files, for the menu bar",
                                   comment: "Settings › Privacy › Recent previews: subtitle when no recent preview is kept")
                : n == 1 ? String(localized: "1 file, shown in the menu bar", comment: "Settings › Privacy › Recent previews: one recent preview is kept")
                : String(localized: "\(n) files, shown in the menu bar", comment: "Settings › Privacy › Recent previews: how many recent previews are kept")
        default: return row.subtitle
        }
    }

    /// Settings whose effect the app applies itself, not a preview.
    private func afterChange() {
        // A new look redraws the chosen folders' icons (the signature includes the style).
        if row.key == SettingsKey.folderIconStyle { FolderContentIcons.refresh(defaults: store.defaults) }
    }

    private func binding() -> Binding<SettingsValue> {
        Binding(get: { store.value(row) ?? row.defaultValue ?? .bool(false) },
                set: { store.set($0, for: row); afterChange() })
    }

    @ViewBuilder private var control: some View {
        switch row.control {
        case .toggle:
            Toggle(row.title, isOn: Binding(get: { store.value(row)?.bool ?? false }, set: { store.set(.bool($0), for: row) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
        case .segmented(let options):
            Picker(row.title, selection: binding()) {
                ForEach(options) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        case .menu(let options):
            Picker(row.title, selection: binding()) {
                ForEach(options) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        case .codeTheme:
            CodeThemePicker(store: store, row: row)
        case .codeFont:
            let fonts = SettingsCatalog.installedCodeFonts()
            let current = store.value(row)?.string ?? "SF Mono"
            Picker(row.title, selection: binding()) {
                ForEach(fonts + (fonts.contains(current) ? [] : [current]), id: \.self) { Text($0).tag(SettingsValue.string($0)) }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
        case let .slider(min, max, step, low, high):
            let value = store.value(row)?.double ?? min
            HStack(spacing: 8) {
                Text(low).font(.v("caption")).foregroundStyle(Color.token("t2"))
                // Continuous, rounded to `step` here: a stepped Slider draws tick marks the design does not have.
                Slider(value: Binding(get: { value }, set: { store.set(.int(Int(($0 / step).rounded() * step)), for: row) }), in: min...max)
                    .labelsHidden().controlSize(.small).frame(width: 130)
                Text(high).font(.v("caption")).foregroundStyle(Color.token("t2"))
                Text((value / 100).formatted(.percent.precision(.fractionLength(0)))).font(.v("callout")).monospacedDigit().foregroundStyle(Color.token("t1")).frame(width: 40, alignment: .trailing)
            }
        case .textScale:
            TextScaleControl(store: store, row: row)
        case .markdownThemes:
            EmptyView()
        case .custom:
            custom
        }
    }

    @ViewBuilder private var custom: some View {
        switch row.id {
        case "general.diagnostics", "fileTypes.owners":
            Button("Open Diagnostics…") { openWindow(id: "diagnostics") }.buttonStyle(.vitrine)
        case "general.sessions.claude":
            SessionHookButton()
        case "general.connector.code":
            ClaudeCodeConnectButton()
        case "general.connector.app":
            ClaudeAppConnectButton()
        case "general.commandline":
            Button("Set Up…") { openWindow(id: "command-line"); NSApp.activate() }.buttonStyle(.vitrine)
        case "about.update":
            Button("Check for Updates…") { UpdateCoordinator.shared.checkNowAndTell() }.buttonStyle(.vitrine)
        case "about.report":
            Button("Diagnostics…") { openWindow(id: "diagnostics") }.buttonStyle(.vitrine)
        case "advisories.update":
            AdvisoryUpdateControl()
        case "about.osv":
            Link(destination: URL(string: "https://osv.dev")!) { Text(verbatim: "osv.dev") }
        case "about.tiktoken":
            Link(destination: URL(string: "https://github.com/openai/tiktoken")!) { Text(verbatim: "tiktoken") }
        case "appearance.accent":
            HStack(spacing: 8) {
                Circle().fill(SettingsAccent.color).frame(width: 12, height: 12)
                    .overlay { Circle().strokeBorder(Color.token("hair"), lineWidth: 0.5) }
                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.vitrine)
            }
        case "privacy.recents":
            RecentsClearButton(store: store)
        default:
            EmptyView()
        }
    }
}

/// How many recent previews the menu has, read from every extension's list (counts only).
enum RecentPreviewsCount {
    @MainActor static var now: Int { RecentPreviews.forApp().entries().count }
}

/// Privacy › Kept on this Mac › Recent previews · Clear: empties every extension's list.
struct RecentsClearButton: View {
    @ObservedObject var store: SettingsStore
    @State private var cleared = 0

    var body: some View {
        Button("Clear") {
            RecentPreviews.forApp().clear()
            cleared += 1
            store.objectWillChange.send()
        }
        .buttonStyle(.vitrine)
        .disabled(RecentPreviewsCount.now == 0)
        .id(cleared)
    }
}

/// The code theme menu: the built-in themes, the rest of the set, and any the person imported in the code view.
struct CodeThemePicker: View {
    @ObservedObject var store: SettingsStore
    let row: SettingsRow

    var body: some View {
        let current = store.value(row)?.string ?? "vitrine"
        let imported = store.importedCodeThemes
        let known = (SettingsCatalog.codeThemes + SettingsCatalog.moreCodeThemes + imported).contains { $0.id == current }
        Picker(row.title, selection: Binding(get: { known ? current : "vitrine" }, set: { store.set(.string($0), for: row) })) {
            ForEach(SettingsCatalog.codeThemes, id: \.id) { Text($0.name).tag($0.id) }
            Section("More themes") {
                ForEach(SettingsCatalog.moreCodeThemes, id: \.id) { Text($0.name).tag($0.id) }
            }
            if !imported.isEmpty {
                Section("Imported") {
                    ForEach(imported, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
    }
}

/// Markdown text size: the seven steps the preview's own Aa menu uses, shown in points of the chosen theme.
struct TextScaleControl: View {
    @ObservedObject var store: SettingsStore
    let row: SettingsRow

    var body: some View {
        let scales = MarkdownTheme.textScales
        let scale = MarkdownTheme.textScale(store.value(row)?.double)
        let index = Double(scales.firstIndex(of: scale) ?? 2)
        let points = (store.markdownTheme.spec.size * scale * 2).rounded() / 2
        HStack(spacing: 8) {
            Text(verbatim: "A").font(.system(size: 10)).foregroundStyle(Color.token("t2"))
            Slider(value: Binding(get: { index }, set: { store.set(.double(scales[Int($0.rounded())]), for: row) }),
                   in: 0...Double(scales.count - 1))
                .labelsHidden().controlSize(.small).frame(width: 130)
            Text(verbatim: "A").font(.system(size: 15)).foregroundStyle(Color.token("t2"))
            let size = points.formatted(.number.precision(.fractionLength(0...1)))
            Text(String(localized: "\(size) pt", comment: "Settings › Appearance › Text size: a size in points, already formatted (12.5)"))
                .font(.v("callout")).monospacedDigit().foregroundStyle(Color.token("t1")).frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: - Markdown theme tiles

/// `.gal`: the Markdown Collection as tiles, five across, each drawn in its own colours and type; the default
/// (Vitrine) shows its day and night halves.
struct MarkdownThemeGallery: View {
    @ObservedObject var store: SettingsStore
    let row: SettingsRow

    var body: some View {
        let current = store.markdownTheme.id
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
            ForEach(MarkdownTheme.builtIn) { theme in
                Button { store.set(.string(theme.id), for: row) } label: {
                    MarkdownThemeTile(theme: theme, selected: theme.id == current, pair: theme.id == MarkdownTheme.defaultID)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.name)
                .accessibilityAddTraits(theme.id == current ? .isSelected : [])
            }
        }
    }
}

struct MarkdownThemeTile: View {
    let theme: MarkdownTheme
    var selected: Bool
    var pair: Bool

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if pair {
                    HStack(spacing: 0) {
                        half(theme.spec.light)
                        half(theme.spec.dark)
                    }
                } else {
                    half(theme.spec.light)
                }
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.token("hair"), lineWidth: 0.5) }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(SettingsAccent.color, lineWidth: 2)
                        .padding(-2)
                        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.token("focus"), lineWidth: 2).padding(-4) }
                }
            }
            Text(theme.name).font(.v("sub")).foregroundStyle(Color.token("t1")).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    private func half(_ c: ThemeColors) -> some View {
        let fg = Color(nsColor: NSColor(css: c.fg) ?? .textColor), acc = Color(nsColor: NSColor(css: c.acc) ?? .controlAccentColor)
        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "Aa").font(face(size: 17)).fontWeight(.semibold).foregroundStyle(fg)
                .padding(.top, 12).padding(.bottom, 2)
            Capsule().fill(fg.opacity(0.55)).frame(height: 3).frame(maxWidth: .infinity, alignment: .leading).scaleEffect(x: 0.8, anchor: .leading)
            Capsule().fill(fg.opacity(0.55)).frame(height: 3).scaleEffect(x: 0.64, anchor: .leading)
            Capsule().fill(acc).frame(height: 3).scaleEffect(x: 0.36, anchor: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: NSColor(css: c.bg) ?? .textBackgroundColor))
    }

    /// The theme's own family: serif, monospaced or the system face, read from its CSS font stack.
    private func face(size: CGFloat) -> Font {
        let stack = theme.spec.font.lowercased()
        let first = stack.split(separator: ",").first.map(String.init) ?? stack
        if first.contains("mono") || first.contains("courier") { return .system(size: size, design: .monospaced) }
        if first.contains("serif") && !first.contains("sans") { return .system(size: size, design: .serif) }
        return .system(size: size)
    }
}

/// Add or remove the Claude Code session hook (S-11); each shows the exact change in an alert before writing.
struct SessionHookButton: View {
    @State private var installed = ClaudeSessionHook().isInstalled

    var body: some View {
        Button(installed ? String(localized: "Remove Hook…", comment: "Settings › General › Track Claude Code sessions: button")
                         : String(localized: "Add Hook…", comment: "Settings › General › Track Claude Code sessions: button")) {
            _ = installed ? SessionsHook.confirmRemove() : SessionsHook.confirmInstall()
            installed = ClaudeSessionHook().isInstalled
        }
        .buttonStyle(.vitrine)
    }
}

/// Settings › General › Metadata strip › Facts and their order (I-13, settings r3-a): one chip per fact, accent when
/// shown, struck through when hidden. Click hides or shows; drag one chip onto another to move it there.
struct MetadataStripChips: View {
    @ObservedObject var store: SettingsStore
    @State private var settings = MetadataStrip.Settings.standard

    var body: some View {
        WrapLayout(spacing: 5) {
            ForEach(settings.order) { item in
                chip(item)
                    .draggable(item.rawValue)
                    .dropDestination(for: String.self) { names, _ in
                        guard let name = names.first, let moved = MetadataStrip.Item(rawValue: name), moved != item,
                              let from = settings.order.firstIndex(of: moved), let to = settings.order.firstIndex(of: item) else { return false }
                        settings.order.remove(at: from)
                        settings.order.insert(moved, at: to)
                        save()
                        return true
                    }
            }
            if settings.order != MetadataStrip.Settings.standard.order || settings.hidden != MetadataStrip.Settings.standard.hidden {
                Button("Reset") {
                    settings.order = MetadataStrip.Settings.standard.order
                    settings.hidden = MetadataStrip.Settings.standard.hidden
                    save()
                }
                .buttonStyle(.plain)
                .font(.v("caption")).foregroundStyle(Color.token("accent-text"))
                .frame(height: 22)
                .help("Back to the default facts and order")
            }
        }
        .onAppear { settings = MetadataStrip.Settings.read(store.defaults) }
    }

    private func chip(_ item: MetadataStrip.Item) -> some View {
        let on = !settings.hidden.contains(item)
        return Button {
            if on { settings.hidden.insert(item) } else { settings.hidden.remove(item) }
            save()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal").font(.system(size: 8, weight: .semibold)).opacity(0.5)
                Text(item.title).strikethrough(!on)
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.token(on ? "accent-text" : "t3"))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color.token(on ? "accent-soft" : "fill"), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(on ? String(localized: "Shown in the strip; click to hide", comment: "Settings › Metadata strip chip tooltip")
                 : String(localized: "Hidden; click to show", comment: "Settings › Metadata strip chip tooltip"))
        .accessibilityValue(on ? Text("Shown", comment: "Settings › Metadata strip chip state") : Text("Hidden", comment: "Settings › Metadata strip chip state"))
    }

    private func save() {
        // The show choice belongs to its own row: keep whatever it holds now.
        settings.show = MetadataStrip.Settings.read(store.defaults).show
        settings.write(store.defaults)
        store.objectWillChange.send()
    }
}

/// Lays its views out left to right and starts a new line when the next would not fit.
struct WrapLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
