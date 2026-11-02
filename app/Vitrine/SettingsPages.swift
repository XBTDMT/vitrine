import SwiftUI
import VitrinePreviewKit
import VitrineUI

// The Settings window's detail pages (S-10, design/mockups/unified/settings.html): each pane opens with a headline
// sentence that says what the settings add up to, then its groups; search and "Changed by you" list rows from every
// pane under the pane's name. roadmap: S-10

struct SettingsPanePage: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject private var diagnostics = Diagnostics.shared
    let pane: SettingsPane
    var go: (SettingsPane) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if pane == .about { AboutIdentity().padding(.bottom, 14) } else { lead.padding(.bottom, 14) }
                ForEach(SettingsCatalog.groups(in: pane), id: \.name) { group in
                    if group.rows.first?.control == .markdownThemes {
                        SettingsGroupHeading(title: group.name)
                        SettingsRowView(store: store, row: group.rows[0])
                            .background(Color.token("card"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.token("hair"), lineWidth: 0.5) }
                            .padding(.bottom, 12)
                    } else {
                        SettingsGroup(store: store, title: group.name, rows: group.rows)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 20)
        }
    }

    /// `.plead`: a dot, the 20/700 headline and its line, from the current settings.
    private var lead: some View {
        let (ok, headline, sub) = sentence
        return HStack(alignment: .top, spacing: 10) {
            Dot(token: ok ? "ok" : "needs").padding(.top, 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.system(size: Metric.value("fs-title2"), weight: .bold)).foregroundStyle(Color.token("t1"))
                    .fixedSize(horizontal: false, vertical: true)
                Text(sub).font(.v("callout")).foregroundStyle(Color.token("t2")).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2).padding(.top, 2)
    }

    private var sentence: (Bool, String, String) {
        switch pane {
        case .general:
            let off = diagnostics.extensions.filter { !$0.enabled }
            if off.isEmpty {
                return (true, String(localized: "Vitrine is previewing everything it can", comment: "Settings › General: headline when every extension is on"),
                        String(localized: "Every Vitrine extension is on.", comment: "Settings › General: line under the headline"))
            }
            // The names joined the way the language joins a list ("Markdown, Code and Data").
            let list = off.map(\.name).formatted(.list(type: .and))
            if off.count == 1 {
                return (false, String(localized: "One preview is off", comment: "Settings › General: headline when one extension is off"),
                        String(localized: "\(list) is not answering in Quick Look. Diagnostics can turn it on.",
                               comment: "Settings › General: the name of one preview extension that is off"))
            }
            return (false, String(localized: "\(off.count) previews are off", comment: "Settings › General: headline, how many extensions are off"),
                    String(localized: "\(list) are not answering in Quick Look. Diagnostics can turn them on.",
                           comment: "Settings › General: the names of the preview extensions that are off, as a list"))
        case .fileTypes:
            return (true, String(localized: "What each kind of file opens as", comment: "Settings › File Types: headline"),
                    String(localized: "A preview opens on the view chosen here; the viewer switch still offers the others.", comment: "Settings › File Types: line under the headline"))
        case .appearance:
            let theme = store.markdownTheme.name
            let codeTheme = store.codeThemeName(store.string(SettingsKey.codeTheme)), font = store.string(SettingsKey.codeFont)
            return (true, String(localized: "The \(theme) theme for Markdown", comment: "Settings › Appearance: headline naming the Markdown theme"),
                    String(localized: "Code uses \(codeTheme) in \(font).", comment: "Settings › Appearance: the code theme's name, then the code font's name"))
        case .markdown:
            let headline = store.bool(SettingsKey.markdownTOC)
                ? String(localized: "Markdown opens rendered, with a contents column", comment: "Settings › Markdown: headline")
                : String(localized: "Markdown opens rendered, at full width", comment: "Settings › Markdown: headline")
            let extras = [(SettingsKey.markdownMath, String(localized: "math", comment: "Settings › Markdown: a feature in the list of extras that are on")),
                          (SettingsKey.markdownEmoji, String(localized: "emoji", comment: "Settings › Markdown: a feature in the list of extras that are on")),
                          (SettingsKey.markdownSmart, String(localized: "smart punctuation", comment: "Settings › Markdown: a feature in the list of extras that are on"))]
                .filter { store.bool($0.0) }.map(\.1)
            let joined = extras.formatted(.list(type: .and))
            let list = joined.prefix(1).uppercased() + joined.dropFirst()
            let line = extras.isEmpty
                ? String(localized: "Math and emoji are off; remote images wait for you.", comment: "Settings › Markdown: line under the headline")
                : extras.count == 1
                ? String(localized: "\(list) is on; remote images wait for you.", comment: "Settings › Markdown: the one extra that is on (math, emoji or smart punctuation)")
                : String(localized: "\(list) are on; remote images wait for you.", comment: "Settings › Markdown: the extras that are on, as a list")
            return (true, headline, line)
        case .code:
            let headline = store.bool(SettingsKey.codeLineNumbers)
                ? String(localized: "Code opens highlighted, with line numbers", comment: "Settings › Code and Text: headline")
                : String(localized: "Code opens highlighted, without line numbers", comment: "Settings › Code and Text: headline")
            let theme = store.codeThemeName(store.string(SettingsKey.codeTheme)), tabs = Int(store.number(SettingsKey.codeTabSize))
            let line = store.bool(SettingsKey.codeWrap)
                ? String(localized: "\(theme) colours, long lines wrapped, tabs \(tabs) wide.", comment: "Settings › Code and Text: the code theme's name, then the tab width in spaces")
                : String(localized: "\(theme) colours, long lines scroll, tabs \(tabs) wide.", comment: "Settings › Code and Text: the code theme's name, then the tab width in spaces")
            return (true, headline, line)
        case .folders:
            let n = store.chosenFolderCount
            return (true, String(localized: "Folders can show what is inside on their Finder icon", comment: "Settings › Archives and Folders: headline"),
                    n == 0 ? String(localized: "No folder is chosen yet.", comment: "Settings › Archives and Folders: no folder shows its contents on its icon")
                    : n == 1 ? String(localized: "1 folder shows its contents, redrawn while Vitrine runs.", comment: "Settings › Archives and Folders")
                    : String(localized: "\(n) folders show their contents, redrawn while Vitrine runs.", comment: "Settings › Archives and Folders: how many folders show their contents"))
        case .privacy:
            return (true, String(localized: "Your previews stay on this Mac", comment: "Settings › Privacy: headline"),
                    store.bool(SettingsKey.recordRecents)
                    ? String(localized: "Recent previews are kept here for the menu bar, and nowhere else.", comment: "Settings › Privacy: line under the headline")
                    : String(localized: "Recent previews are paused.", comment: "Settings › Privacy: line under the headline"))
        case .about:
            return (true, "", "")
        }
    }
}

/// `.gh` for the Settings window: 11.5 pt semibold `--v-t2`.
struct SettingsGroupHeading: View {
    var title: String
    var trailing: (() -> AnyView)?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.v("sub", .semibold)).foregroundStyle(Color.token("t2"))
            Spacer(minLength: 8)
            if let trailing { trailing() }
        }
        .padding(.horizontal, 2).padding(.top, 14).padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }
}

/// `.grp`: rows on the card, hairline between them.
struct SettingsGroup: View {
    @ObservedObject var store: SettingsStore
    var title: String
    var rows: [SettingsRow]
    var trailing: (() -> AnyView)?
    var highlighted: Set<String> = []

    var body: some View {
        SettingsGroupHeading(title: title, trailing: trailing)
        RowGroup {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if i > 0 { Rectangle().fill(Color.token("sep")).frame(height: 0.5) }
                SettingsRowView(store: store, row: row, highlighted: highlighted.contains(row.id))
            }
        }
        .padding(.bottom, 12)
    }
}

/// About's head: the icon, the name and subtitle, and the version.
struct AboutIdentity: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage()).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Vitrine").font(.system(size: Metric.value("fs-title2"), weight: .bold)).foregroundStyle(Color.token("t1"))
                Text("Beautiful file previews").font(.v("callout")).foregroundStyle(Color.token("t2"))
                Text("Version \(Diagnostics.appVersion) · macOS 15 or later", comment: "Settings › About: the version, then the macOS it needs").font(.v("sub")).foregroundStyle(Color.token("t2"))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }
}

/// Search: "N results for “query”", grouped under each pane, with a link to the pane.
struct SearchResultsPage: View {
    @ObservedObject var store: SettingsStore
    let query: String
    var go: (SettingsPane) -> Void

    var body: some View {
        let found = SettingsCatalog.search(query)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(found.count == 1 ? String(localized: "1 result for “\(query)”", comment: "Settings search: one row matches the typed words")
                                      : String(localized: "\(found.count) results for “\(query)”", comment: "Settings search: how many rows match the typed words"))
                    .font(.system(size: Metric.value("fs-title2"), weight: .bold)).foregroundStyle(Color.token("t1"))
                    .padding(.horizontal, 2).padding(.top, 2)
                if found.isEmpty {
                    Text("No setting matches. Try a shorter word.").font(.v("callout")).foregroundStyle(Color.token("t2"))
                        .padding(.horizontal, 2).padding(.top, 3)
                }
                PaneGroupedRows(store: store, rows: found, highlighted: Set(found.map(\.id)), go: go)
            }
            .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 20)
        }
    }
}

/// Changed by you: every row whose value differs from its default, each with its Reset, and Reset All.
struct ChangedPage: View {
    @ObservedObject var store: SettingsStore
    var go: (SettingsPane) -> Void

    var body: some View {
        let changed = store.changedRows
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(changed.isEmpty ? String(localized: "Everything is as Vitrine came", comment: "Changed by You: headline when no setting differs from its default")
                             : changed.count == 1 ? String(localized: "You changed 1 setting", comment: "Changed by You: headline")
                             : String(localized: "You changed \(changed.count) settings", comment: "Changed by You: headline, how many settings differ from their defaults"))
                            .font(.system(size: Metric.value("fs-title2"), weight: .bold)).foregroundStyle(Color.token("t1"))
                        Text("Reset puts one back; the rest stay as you set them.").font(.v("callout")).foregroundStyle(Color.token("t2"))
                    }
                    Spacer()
                    if !changed.isEmpty {
                        Button("Reset All") { changed.forEach(store.reset) }.buttonStyle(.vitrine)
                    }
                }
                .padding(.horizontal, 2).padding(.top, 2)
                PaneGroupedRows(store: store, rows: changed, highlighted: [], go: go)
            }
            .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 20)
        }
    }
}

/// Rows from several panes, one group per pane with the pane's tile and a link to it.
struct PaneGroupedRows: View {
    @ObservedObject var store: SettingsStore
    let rows: [SettingsRow]
    let highlighted: Set<String>
    var go: (SettingsPane) -> Void

    var body: some View {
        ForEach(SettingsPane.allCases.filter { pane in rows.contains { $0.pane == pane } }) { pane in
            let list = rows.filter { $0.pane == pane }
            SettingsGroupHeading(title: pane.title) {
                AnyView(Button("Show") { go(pane) }.buttonStyle(.plain).font(.v("sub")).foregroundStyle(Color.token("accent-text")))
            }
            ForEach(list.filter { $0.control == .markdownThemes }) { row in
                SettingsRowView(store: store, row: row)
                    .background(Color.token("card"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.token("hair"), lineWidth: 0.5) }
                    .padding(.bottom, 12)
            }
            let plain = list.filter { $0.control != .markdownThemes }
            if !plain.isEmpty {
                RowGroup {
                    ForEach(Array(plain.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Rectangle().fill(Color.token("sep")).frame(height: 0.5) }
                        SettingsRowView(store: store, row: row, highlighted: highlighted.contains(row.id))
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }
}
