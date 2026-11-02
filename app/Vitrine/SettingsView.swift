import SwiftUI
import VitrinePreviewKit
import VitrineUI

// The Settings window (S-10, parity H-1), built to design/mockups/unified/settings.html (pick r3-a, unified): the house
// sidebar with a value line under each pane, search, "Changed by you", a headline sentence per pane, and grouped rows.
// Every row writes one key in `VitrineDefaults.shared` that a renderer or the app already reads (SettingsModel);
// SettingsBridge carries it to the extensions (G-19 route B). roadmap: S-10

/// What the detail column shows: a pane, the search results, or the rows changed from their defaults.
enum SettingsPage: Hashable {
    case pane(SettingsPane)
    case changed
}

struct SettingsView: View {
    @StateObject private var store: SettingsStore
    @State private var page: SettingsPage
    @State private var query = ""
    /// Search runs only when asked (the snapshots draw a page with a query typed in).
    private let searchable: Bool

    init(defaults: UserDefaults = VitrineDefaults.shared, page: SettingsPage = .pane(.general), query: String = "", searchable: Bool = true) {
        _store = StateObject(wrappedValue: SettingsStore(defaults: defaults))
        _page = State(initialValue: page)
        _query = State(initialValue: query)
        self.searchable = searchable
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(store: store, page: $page, query: $query, showsField: !searchable)
                .frame(width: Metric.value("w-sidebar"))
                .navigationSplitViewColumnWidth(Metric.value("w-sidebar"))
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ZStack {
                Color.token("win").ignoresSafeArea()
                detail
            }
            .navigationTitle(title)
            .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(SidebarSearch(enabled: searchable, query: $query))
        .frame(width: 960, height: 640)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var title: String {
        if !trimmedQuery.isEmpty { return String(localized: "Search", comment: "Settings: window title while search results show") }
        switch page {
        case .pane(let pane): return pane.title
        case .changed: return String(localized: "Changed by You", comment: "Settings: the page listing settings changed from their defaults")
        }
    }

    @ViewBuilder private var detail: some View {
        if !trimmedQuery.isEmpty {
            SearchResultsPage(store: store, query: trimmedQuery) { pane in query = ""; page = .pane(pane) }
        } else {
            switch page {
            case .pane(let pane): SettingsPanePage(store: store, pane: pane, go: { page = .pane($0) })
            case .changed: ChangedPage(store: store) { page = .pane($0) }
            }
        }
    }
}

/// `.searchable` in the sidebar, the native field; left off when a snapshot draws its own field.
private struct SidebarSearch: ViewModifier {
    var enabled: Bool
    @Binding var query: String
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, placement: .sidebar, prompt: "Search")
        } else {
            content
        }
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var diagnostics = Diagnostics.shared
    @Binding var page: SettingsPage
    @Binding var query: String
    /// A drawn search field, for snapshots taken without a window toolbar.
    var showsField = false

    var body: some View {
        // A plain column, as in the Diagnostics sidebar: every pane fits at the window's 640 pt height.
        VStack(alignment: .leading, spacing: 1) {
                if showsField {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.token("t2"))
                        Text(query.isEmpty ? String(localized: "Search", comment: "Settings: placeholder in the search field") : query).font(.v("callout")).foregroundStyle(Color.token(query.isEmpty ? "t3" : "t1"))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Color.token("fill"), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .padding(.bottom, 8)
                }
                ForEach([SettingsSection.top, .previews, .thisMac, .vitrine], id: \.self) { section in
                    if section != .top {
                        Text(section.title).font(.v("caption", .semibold)).foregroundStyle(Color.token("t2"))
                            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 3)
                    }
                    ForEach(SettingsPane.allCases.filter { $0.section == section }) { pane in
                        item(.pane(pane), title: pane.title, subtitle: summary(pane), tile: pane.tile, symbol: pane.symbol)
                    }
                }
                let changed = store.changedRows.count
                if changed > 0 {
                    Spacer(minLength: 10)
                    item(.changed, title: String(localized: "Changed by You", comment: "Settings: the page listing settings changed from their defaults"),
                         subtitle: changed == 1 ? String(localized: "1 setting", comment: "Settings sidebar: one setting changed from its default")
                                                : String(localized: "\(changed) settings", comment: "Settings sidebar: how many settings are changed from their defaults"),
                         tile: "accent", symbol: "slider.horizontal.3")
                }
                Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 10)
    }

    private func item(_ target: SettingsPage, title: String, subtitle: String, tile: String, symbol: String) -> some View {
        let selected = query.isEmpty && page == target
        return Button {
            query = ""
            page = target
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: Metric.value("r-ctl"), style: .continuous)
                    .fill(Color.token(tile))
                    .overlay { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white) }
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.v("body")).foregroundStyle(Color.token("t1")).lineLimit(1)
                    Text(subtitle).font(.v("caption")).foregroundStyle(Color.token("t2")).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .frame(minHeight: Metric.value("h-row-side"))
            .background(selected ? Color.token("fill2") : .clear, in: RoundedRectangle(cornerRadius: Metric.value("r-row"), style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The value line under each pane (the design's "values" in the sidebar).
    private func summary(_ pane: SettingsPane) -> String {
        switch pane {
        case .general:
            let on = diagnostics.extensions.filter(\.enabled).count
            return String(localized: "\(on) of \(diagnostics.extensions.count) previews on",
                          comment: "Settings sidebar, under General: how many of Vitrine's preview extensions are on")
        case .fileTypes:
            let changed = SettingsCatalog.rows.filter { $0.pane == .fileTypes && $0.key != nil && store.isChanged($0) }.count
            let kinds = SettingsCatalog.rows.filter { $0.pane == .fileTypes && $0.key != nil }.count
            return changed == 0
                ? String(localized: "\(kinds) kinds, each in its first view", comment: "Settings sidebar, under File Types: how many kinds of file, none changed")
                : String(localized: "\(kinds) kinds, \(changed) changed by you", comment: "Settings sidebar, under File Types: how many kinds, how many the person changed")
        case .appearance:
            let theme = store.markdownTheme.name, font = store.string(SettingsKey.codeFont), size = Int(store.number(SettingsKey.codeFontSize))
            return String(localized: "\(theme) theme, \(font) \(size) pt",
                          comment: "Settings sidebar, under Appearance: the Markdown theme's name, then the code font and its size in points")
        case .markdown:
            return store.bool(SettingsKey.markdownTOC)
                ? String(localized: "Contents column, rendered", comment: "Settings sidebar, under Markdown: files open rendered with a table of contents")
                : String(localized: "Rendered, no contents column", comment: "Settings sidebar, under Markdown: files open rendered without a table of contents")
        case .code:
            // Up to two of the features that are on, as a short list ("Line numbers, sticky headers").
            let on = [(SettingsKey.codeLineNumbers, String(localized: "line numbers", comment: "Settings sidebar, under Code and Text: a feature in a short list")),
                      (SettingsKey.codeSticky, String(localized: "sticky headers", comment: "Settings sidebar, under Code and Text: a feature in a short list")),
                      (SettingsKey.codeWrap, String(localized: "wrapped", comment: "Settings sidebar, under Code and Text: long lines wrap; a feature in a short list")),
                      (SettingsKey.codeIndentGuides, String(localized: "indent guides", comment: "Settings sidebar, under Code and Text: a feature in a short list"))]
                .filter { store.bool($0.0) }.map(\.1)
            let line = Array(on.prefix(2)).formatted(.list(type: .and, width: .narrow))
            return line.isEmpty ? store.codeThemeName(store.string(SettingsKey.codeTheme)) : line.prefix(1).uppercased() + line.dropFirst()
        case .folders:
            let n = store.chosenFolderCount
            return n == 0 ? String(localized: "No folder icons yet", comment: "Settings sidebar, under Archives and Folders")
                : n == 1 ? String(localized: "1 folder icon", comment: "Settings sidebar, under Archives and Folders: one folder shows its contents on its icon")
                : String(localized: "\(n) folder icons", comment: "Settings sidebar, under Archives and Folders: how many folders show their contents on their icon")
        case .privacy:
            return store.bool(SettingsKey.recordRecents)
                ? String(localized: "Kept on this Mac", comment: "Settings sidebar, under Privacy: recent previews are kept locally")
                : String(localized: "Recents paused", comment: "Settings sidebar, under Privacy: recent previews are not being kept")
        case .about:
            return String(localized: "\(Diagnostics.appVersion) · free", comment: "Settings sidebar, under About: the version, then that Vitrine is free")
        }
    }
}
