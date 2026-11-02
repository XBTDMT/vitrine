import ServiceManagement
import SwiftUI
import VitrineUI

// The Diagnostics window (S-10; parity B-8 and H-4), built to design/mockups/unified/diagnostics.html: the sidebar
// shell with File Types and Extensions with Repair tools. Overview, Check a File, Failures, Speed and Report are not
// built yet and are left out of the sidebar.

enum DiagnosticsPane: String, CaseIterable, Identifiable, Sendable {
    case fileTypes, extensions
    var id: String { rawValue }
    var title: String {
        self == .fileTypes ? String(localized: "File Types", comment: "Diagnostics: pane name in the sidebar and window title")
                           : String(localized: "Extensions", comment: "Diagnostics: pane name in the sidebar and window title")
    }
    /// Sidebar tiles (G19): File Types → `--v-tile-filetypes`, Extensions → `--v-tile-appearance`.
    var tile: String { self == .fileTypes ? "tile-filetypes" : "tile-appearance" }
    var symbol: String { self == .fileTypes ? "doc" : "puzzlepiece.extension" }
}

// MARK: - Store

@MainActor
final class DiagnosticsStore: ObservableObject {
    static let shared = DiagnosticsStore()
    /// `Vitrine --diagnostics` asks for the window at launch; the Welcome window opens it once it appears.
    static var openOnLaunch = CommandLine.arguments.contains("--diagnostics")

    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let ok: Bool
        let undo: (@MainActor () -> Void)?
    }

    @Published var pane: DiagnosticsPane = .fileTypes
    @Published private(set) var snapshot: DiagnosticsSnapshot?
    @Published private(set) var checking = false
    /// The action running now (a row or tool id), so its button can wait.
    @Published private(set) var running: String?
    @Published var toast: Toast?
    @Published var plan: SetAsidePlan?

    init(snapshot: DiagnosticsSnapshot? = nil) { self.snapshot = snapshot }

    func check() {
        guard !checking else { return }
        checking = true
        Task.detached(priority: .userInitiated) {
            let s = DiagnosticsProbe.snapshot()
            await MainActor.run {
                self.snapshot = s
                self.checking = false
            }
        }
    }

    func checkIfNeeded() { if snapshot == nil { check() } }

    /// Runs one repair off the main thread, shows its outcome, then checks again.
    func perform(_ id: String, message: String? = nil, undo: (@MainActor () -> Void)? = nil,
                 _ work: @escaping @Sendable () -> DiagnosticsRepair.Outcome) {
        guard running == nil else { return }
        running = id
        Task.detached(priority: .userInitiated) {
            let outcome = work()
            await MainActor.run {
                self.running = nil
                self.show(Toast(message: outcome.ok ? (message ?? outcome.message) : outcome.message, ok: outcome.ok, undo: outcome.ok ? undo : nil))
                self.check()
            }
        }
    }

    func show(_ toast: Toast) {
        self.toast = toast
        let id = toast.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(toast.undo == nil ? 4 : 8))
            if self.toast?.id == id { self.toast = nil }
        }
    }

    // MARK: Use Vitrine

    func proposeUseVitrine(for rows: [KindRow]) {
        guard let s = snapshot else { return }
        plan = SetAsidePlan.make(rows: rows, installed: s.installed, summary: s.fileTypes,
                                 describe: { UTTypeName.describe($0) }, extensionsOf: { DiagnosticsProbe.extensions(of: $0) })
    }

    func confirm(_ plan: SetAsidePlan) {
        self.plan = nil
        let ids = plan.extensions.map(\.identifier)
        perform("use-vitrine", message: plan.doneMessage, undo: { [weak self] in
            let names = SetAsidePlan.list(plan.extensionNames)
            self?.perform("undo-use-vitrine", message: String(localized: "\(names) put back", comment: "Diagnostics: message after Undo; the other apps' extensions, as a list")) {
                DiagnosticsRepair.undoSetAside(ids)
            }
        }) { DiagnosticsRepair.setAside(ids) }
    }

    func copyReport() {
        let text = DiagnosticsReportText.make(appVersion: Diagnostics.appVersion, macOS: Diagnostics.macOSVersion, generated: snapshot?.date ?? Date(),
                                              fileTypes: snapshot?.fileTypes, extensions: snapshot?.extensions)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(Toast(message: String(localized: "Report copied: counts and kinds only, no file names or paths", comment: "Diagnostics: message after Copy Report"),
                   ok: true, undo: nil))
    }
}

import UniformTypeIdentifiers
enum UTTypeName {
    static func describe(_ uti: String) -> String? { UTType(uti)?.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
}

// MARK: - Window

struct DiagnosticsView: View {
    @ObservedObject var store: DiagnosticsStore

    var body: some View {
        NavigationSplitView {
            DiagnosticsSidebar(store: store)
                .navigationSplitViewColumnWidth(Metric.value("w-sidebar"))
        } detail: {
            ZStack(alignment: .bottom) {
                Color.token("win").ignoresSafeArea()
                switch store.pane {
                case .fileTypes: FileTypesPane(store: store)
                case .extensions: ExtensionsPane(store: store)
                }
                if let toast = store.toast {
                    ToastView(toast: toast) { store.toast = nil; toast.undo?() }
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.toast?.id)
            .navigationTitle(store.pane.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { store.check() } label: { Label("Check Now", systemImage: "arrow.clockwise") }
                        .disabled(store.checking)
                        .help("Ask macOS again which previewer answers for each type")
                    Button { store.copyReport() } label: { Label("Copy Report", systemImage: "doc.on.doc") }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .help("Copy counts and kinds for a bug report; no file names, paths or contents")
                }
            }
            .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
        .labelStyle(.titleAndIcon)
        .sheet(item: $store.plan) { plan in
            SetAsideSheet(plan: plan, cancel: { store.plan = nil }, confirm: { store.confirm(plan) })
        }
        .onAppear { store.checkIfNeeded() }
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - Sidebar

struct DiagnosticsSidebar: View {
    @ObservedObject var store: DiagnosticsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(DiagnosticsPane.allCases) { pane in
                Button { store.pane = pane } label: { row(pane) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.pane == pane ? .isSelected : [])
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 5) {
                Label("Vitrine \(Diagnostics.appVersion)", systemImage: "a.square")
                Label("macOS \(Diagnostics.macOSVersion)", systemImage: "display")
            }
            .labelStyle(StripLabelStyle())
            .font(.v("sub")).foregroundStyle(Color.token("t2"))
            .padding(.top, 9).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Color.token("sep")).frame(height: 0.5) }
        }
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 10)
    }

    private func row(_ pane: DiagnosticsPane) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: Metric.value("r-ctl"), style: .continuous)
                .fill(Color.token(pane.tile))
                .overlay { Image(systemName: pane.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white) }
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(pane.title).font(.v("body")).foregroundStyle(Color.token("t1")).lineLimit(1)
                Text(subtitle(pane)).font(.v("caption")).foregroundStyle(Color.token("t2")).lineLimit(1)
            }
            Spacer(minLength: 4)
            if needsAttention(pane) { Dot(token: "needs") }
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .frame(minHeight: Metric.value("h-row-side"))
        .background(store.pane == pane ? Color.token("fill2") : .clear, in: RoundedRectangle(cornerRadius: Metric.value("r-row"), style: .continuous))
        .contentShape(Rectangle())
    }

    private func subtitle(_ pane: DiagnosticsPane) -> String {
        guard let s = store.snapshot else {
            return store.checking ? String(localized: "Checking…", comment: "Diagnostics sidebar: the check is running")
                                  : String(localized: "Not checked", comment: "Diagnostics sidebar: the check has not run")
        }
        switch pane {
        case .fileTypes:
            let f = s.fileTypes
            let other = f.count(.otherApp), fallback = f.count(.fallback), mine = f.count(.vitrine)
            if other > 0 { return String(localized: "\(other) in other apps", comment: "Diagnostics sidebar, under File Types: how many kinds another app previews") }
            if fallback > 0 { return String(localized: "\(fallback) not previewed", comment: "Diagnostics sidebar, under File Types: how many kinds nothing previews") }
            return String(localized: "\(mine) kinds in Vitrine", comment: "Diagnostics sidebar, under File Types: how many kinds Vitrine previews")
        case .extensions:
            // Separate short statuses, shown side by side with a middle dot between them.
            let e = s.extensions
            var parts: [String] = []
            let off = e.offCount
            if off > 0 { parts.append(String(localized: "\(off) off", comment: "Diagnostics sidebar, under Extensions: how many extensions are turned off")) }
            let missing = e.extensions.filter { $0.state == .notRegistered }.count
            if missing > 0 { parts.append(String(localized: "\(missing) not registered", comment: "Diagnostics sidebar, under Extensions: how many extensions macOS does not list")) }
            if e.extensions.contains(where: { if case .onElsewhere = $0.state { true } else { false } }) {
                parts.append(String(localized: "another copy in use", comment: "Diagnostics sidebar, under Extensions: macOS uses another copy of Vitrine"))
            }
            let copies = e.otherCopies.count
            if copies > 0 {
                parts.append(copies == 1 ? String(localized: "1 old copy", comment: "Diagnostics sidebar, under Extensions: one other copy of Vitrine is registered")
                                         : String(localized: "\(copies) old copies", comment: "Diagnostics sidebar, under Extensions: how many other copies of Vitrine are registered"))
            }
            return parts.isEmpty ? String(localized: "All on", comment: "Diagnostics sidebar, under Extensions: every extension is on") : parts.joined(separator: " · ")
        }
    }

    private func needsAttention(_ pane: DiagnosticsPane) -> Bool {
        guard let s = store.snapshot else { return false }
        switch pane {
        case .fileTypes: return s.fileTypes.count(.otherApp) + s.fileTypes.count(.fallback) > 0
        case .extensions: return s.extensions.problemCount > 0
        }
    }
}

struct StripLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.font(.system(size: 11)).foregroundStyle(Color.token("t3")).frame(width: 13)
            configuration.title.lineLimit(1)
        }
    }
}

// MARK: - File Types

struct FileTypesPane: View {
    @ObservedObject var store: DiagnosticsStore
    @State private var info: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let f = store.snapshot?.fileTypes {
                    coverage(f).padding(.bottom, 4)
                    groups(f)
                } else {
                    checkingCard
                }
            }
            .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 20)
        }
    }

    private var checkingCard: some View {
        Card {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Asking macOS which previewer answers for each type…").font(.v("body")).foregroundStyle(Color.token("t2"))
            }
        }
    }

    private func coverage(_ f: FileTypesSummary) -> some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Vitrine previews \(f.count(.vitrine)) of the \(f.possible) kinds it can").font(.v("body", .semibold)).foregroundStyle(Color.token("t1"))
                Spacer()
                Text("\(f.kindCount) kinds · \(f.typeCount) types").font(.v("sub")).foregroundStyle(Color.token("t2"))
            }
            .padding(.bottom, 9)
            let legend = Self.legend(f)
            CoverageBar(segments: [
                .init(id: "vitrine", label: legend.vitrine, count: f.count(.vitrine), style: .vitrine),
                .init(id: "other", label: legend.other, count: f.count(.otherApp), style: .other),
                .init(id: "fallback", label: legend.fallback, count: f.count(.fallback), style: .other),
                .init(id: "macos", label: legend.macOS, count: f.count(.macOS), style: .macOS),
                .init(id: "unasked", label: legend.notAsked, count: f.count(.notAsked), style: .unknown),
            ])
            HStack(spacing: 16) {
                LegendItem(label: legend.vitrine, style: .vitrine)
                if f.count(.otherApp) > 0 || f.count(.fallback) == 0 { LegendItem(label: legend.other, style: .other) }
                if f.count(.fallback) > 0 { LegendItem(label: legend.fallback, style: .other) }
                LegendItem(label: legend.macOS, style: .macOS)
                if f.count(.notAsked) > 0 { LegendItem(label: legend.notAsked, style: .unknown) }
            }
            .padding(.top, 8)
        }
    }

    /// The coverage legend, each answer with its count ("Kept by macOS 4"); VoiceOver reads the same words for the bar.
    private static func legend(_ f: FileTypesSummary) -> (vitrine: String, other: String, fallback: String, macOS: String, notAsked: String) {
        let vitrine = f.count(.vitrine), other = f.count(.otherApp), fallback = f.count(.fallback), macOS = f.count(.macOS), notAsked = f.count(.notAsked)
        return (String(localized: "Vitrine \(vitrine)", comment: "Diagnostics coverage legend: kinds Vitrine previews, then the count"),
                String(localized: "Other apps \(other)", comment: "Diagnostics coverage legend: kinds other apps preview, then the count"),
                String(localized: "Fallback \(fallback)", comment: "Diagnostics coverage legend: kinds only macOS's icon-and-facts fallback shows, then the count"),
                String(localized: "Kept by macOS \(macOS)", comment: "Diagnostics coverage legend: kinds macOS previews itself, then the count"),
                String(localized: "Not asked \(notAsked)", comment: "Diagnostics coverage legend: kinds macOS was not asked about, then the count"))
    }

    @ViewBuilder private func groups(_ f: FileTypesSummary) -> some View {
        let others = f.rows(.otherApp)
        if !others.isEmpty {
            GroupHeading(title: "Previewed by other apps", dot: Dot(token: "needs")) {
                Button("Use Vitrine for All…") { store.proposeUseVitrine(for: others) }
                    .buttonStyle(.vitrinePrimarySmall).disabled(store.running != nil)
            }
            RowGroup {
                ForEach(others) { row in
                    PaneRow(title: row.kind.name, subtitle: row.subtitle, problem: true) {
                        KindTile(token: row.kind.tile, symbol: row.kind.symbol)
                    } controls: {
                        if case .otherApp(_, _, let app, let version) = row.owner {
                            Text([app, version].filter { !$0.isEmpty }.joined(separator: " ")).font(.v("control", .medium)).foregroundStyle(Color.token("needs-text"))
                        }
                        Button("Use Vitrine") { store.proposeUseVitrine(for: [row]) }
                            .buttonStyle(.vitrinePrimarySmall).disabled(store.running != nil)
                    }
                }
            }
        }
        let fallback = f.rows(.fallback)
        if !fallback.isEmpty {
            GroupHeading(title: "Vitrine extension off", dot: Dot(token: "needs")) {
                Button { Diagnostics.openQuickLookSettings() } label: { Label("Open System Settings", systemImage: "arrow.up.forward.square") }
                    .buttonStyle(.vitrinePrimarySmall)
            }
            RowGroup {
                ForEach(fallback) { row in
                    PaneRow(title: row.kind.name, subtitle: row.subtitle, problem: true) {
                        KindTile(token: row.kind.tile, symbol: row.kind.symbol)
                    } controls: {
                        Text("Fallback").font(.v("control")).foregroundStyle(Color.token("t2"))
                    }
                }
            }
        }
        let kept = f.rows(.macOS)
        if !kept.isEmpty {
            GroupHeading(title: "Kept by macOS", dot: Dot(token: "kind-other", opacity: 0.6)) { Text("nothing to fix") }
            RowGroup {
                ForEach(kept) { row in
                    keptRow(row)
                }
            }
        }
        let unknown = f.rows(.notAsked)
        if !unknown.isEmpty {
            GroupHeading(title: "Not asked", dot: Dot(token: "t3")) { Text("no test file") }
            RowGroup {
                ForEach(unknown) { row in
                    PaneRow(title: row.kind.name, subtitle: row.subtitle) {
                        KindTile(token: "kind-other", symbol: row.kind.symbol)
                    } controls: {
                        Text("Not asked").font(.v("control")).foregroundStyle(Color.token("t2"))
                        infoButton(row)
                    }
                }
            }
        }
        let mine = f.rows(.vitrine)
        if !mine.isEmpty {
            GroupHeading(title: "Vitrine", dot: Dot(token: "accent")) { Text("\(mine.count) kinds") }
            RowGroup {
                ForEach(mine) { row in
                    PaneRow(title: row.kind.name, subtitle: row.subtitle) {
                        KindTile(token: row.kind.tile, symbol: row.kind.symbol)
                    } controls: {
                        Text("Vitrine").font(.v("control")).foregroundStyle(Color.token("t2"))
                        Image(systemName: "checkmark.circle").foregroundStyle(Color.token("ok-text"))
                        if !row.unasked.isEmpty { infoButton(row) }
                    }
                }
            }
        }
    }

    private func keptRow(_ row: KindRow) -> some View {
        PaneRow(title: row.kind.name, subtitle: row.subtitle, selected: info == row.id) {
            KindTile(token: "kind-other", symbol: row.kind.symbol)
        } controls: {
            if case .macOS(let reason) = row.owner {
                Text(reason).font(.v("control")).foregroundStyle(Color.token("t2"))
            }
            infoButton(row)
        }
    }

    private func infoButton(_ row: KindRow) -> some View {
        Button { info = info == row.id ? nil : row.id } label: {
            Image(systemName: "info.circle").foregroundStyle(Color.token("accent-text"))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Why \(row.kind.name) is not in Vitrine", comment: "Diagnostics: VoiceOver label of the (i) button; the kind of file"))
        .popover(isPresented: Binding(get: { info == row.id }, set: { if !$0 { info = nil } }), arrowEdge: .bottom) {
            WhyPopover(row: row)
        }
    }
}

/// The (i) popover: "TypeScript stays with macOS" and why.
struct WhyPopover: View {
    let row: KindRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.v("body", .semibold)).foregroundStyle(Color.token("t1"))
            Text(text).font(.v("control")).foregroundStyle(Color.token("t2")).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .frame(width: 330, alignment: .leading)
    }

    private var title: String {
        let name = row.kind.name
        switch row.owner {
        case .notAsked: return String(localized: "\(name) was not asked", comment: "Diagnostics (i) popover title; the kind of file")
        case .macOS: return String(localized: "\(name) stays with macOS", comment: "Diagnostics (i) popover title; the kind of file")
        default:
            let n = row.unasked.count
            return n == 1 ? String(localized: "1 type was not asked", comment: "Diagnostics (i) popover title")
                          : String(localized: "\(n) types were not asked", comment: "Diagnostics (i) popover title; how many file types")
        }
    }

    private var text: String {
        var parts: [String] = []
        if case .macOS(let reason) = row.owner {
            if row.extensions.isEmpty {
                parts.append(String(localized: "macOS \(reason), so macOS never asks another app to preview these files. Nothing is broken and nothing here can change it.",
                                    comment: "Diagnostics (i) popover; the reason is a phrase whose subject is macOS (draws plain text itself)"))
            } else {
                let exts = row.extensions.map { "." + $0 }.joined(separator: " ")
                parts.append(String(localized: "macOS \(reason), so macOS never asks another app to preview \(exts) files. Nothing is broken and nothing here can change it.",
                                    comment: "Diagnostics (i) popover; the reason is a phrase whose subject is macOS (draws plain text itself), then filename extensions (.ts .mts)"))
            }
        }
        // One line per reason, naming the types it covers.
        var byReason: [(String, [String])] = []
        for u in row.unasked {
            let name = UTTypeName.describe(u.uti) ?? u.uti
            if let i = byReason.firstIndex(where: { $0.0 == u.reason }) { byReason[i].1.append(name) } else { byReason.append((u.reason, [name])) }
        }
        for (reason, names) in byReason {
            let list = SetAsidePlan.list(names)
            parts.append(String(localized: "\(list): \(reason)", comment: "Diagnostics (i) popover: file types, as a list, then the sentence saying why they were not asked"))
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Use Vitrine sheet

struct SetAsideSheet: View {
    let plan: SetAsidePlan
    var cancel: () -> Void
    var confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(plan.title).font(.v("headline", .semibold)).foregroundStyle(Color.token("t1")).padding(.bottom, 6)
            Text(Self.lead(plan))
                .font(.v("callout")).foregroundStyle(Color.token("t2")).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            ScrollView {
                RowGroup {
                    ForEach(plan.changes) { change in
                        PaneRow(title: change.name, subtitle: change.subtitle) {
                            KindTile(token: change.tile, symbol: change.symbol)
                        } controls: {
                            Text(change.from).font(.v("control")).foregroundStyle(Color.token("t2"))
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.token("t3"))
                            Text(change.toVitrine ? "Vitrine" : String(localized: "icon only", comment: "Diagnostics confirm sheet: the file will show only its icon"))
                                .font(.v("control", .semibold))
                                .foregroundStyle(Color.token(change.toVitrine ? "accent-text" : "needs-text"))
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            Text(Self.footnote(plan))
                .font(.v("sub")).foregroundStyle(Color.token("t2")).padding(.top, 10)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.vitrine).keyboardShortcut(.cancelAction)
                Button("Use Vitrine", action: confirm).buttonStyle(.vitrinePrimary).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(.top, 20).padding(.horizontal, 22).padding(.bottom, 18)
        .frame(width: 470)
    }

    /// The sheet's first sentence, one string for translators, with the extensions' names drawn in the primary colour.
    static func lead(_ plan: SetAsidePlan) -> AttributedString {
        let names = SetAsidePlan.list(plan.extensionNames)
        var text = AttributedString(localized: "macOS chooses previewers per app extension, not per file type. Vitrine will set aside \(names), which also changes:",
                                    comment: "Diagnostics confirm sheet; the other apps' Quick Look extensions, as a list")
        if let range = text.range(of: names) { text[range].foregroundColor = Color.token("t1") }
        return text
    }

    static func footnote(_ plan: SetAsidePlan) -> String {
        let apps = SetAsidePlan.list(plan.appNames)
        return plan.appNames.count == 1
            ? String(localized: "\(apps) keeps working as an app. Undo puts everything back.", comment: "Diagnostics confirm sheet; the other app's name")
            : String(localized: "\(apps) keep working as apps. Undo puts everything back.", comment: "Diagnostics confirm sheet; the other apps' names, as a list")
    }
}

// MARK: - Extensions

struct ExtensionsPane: View {
    @ObservedObject var store: DiagnosticsStore

    static let families: [String: (name: String, tile: String, symbol: String)] = [
        "io.github.xbtdmt.vitrine.quicklook.markdown": (String(localized: "Markdown previews", comment: "Diagnostics › Extensions: one of Vitrine's Quick Look extensions"), "kind-text", "text.document"),
        "io.github.xbtdmt.vitrine.quicklook.code": (String(localized: "Code previews", comment: "Diagnostics › Extensions: one of Vitrine's Quick Look extensions"), "kind-code", "chevron.left.forwardslash.chevron.right"),
        "io.github.xbtdmt.vitrine.quicklook.data": (String(localized: "Data previews", comment: "Diagnostics › Extensions: one of Vitrine's Quick Look extensions"), "kind-data", "tablecells"),
        "io.github.xbtdmt.vitrine.quicklook.packages": (String(localized: "Archive and app previews", comment: "Diagnostics › Extensions: one of Vitrine's Quick Look extensions"), "kind-archive", "archivebox"),
        "io.github.xbtdmt.vitrine.quicklook.folders": (String(localized: "Folder previews", comment: "Diagnostics › Extensions: one of Vitrine's Quick Look extensions"), "kind-folder", "folder"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let e = store.snapshot?.extensions {
                    header(e).padding(.bottom, 14)
                    RowGroup { ForEach(e.extensions) { row($0) } }
                    GroupHeading(title: "Background helper") { EmptyView() }
                    RowGroup { helperRow }
                    if !e.otherCopies.isEmpty { copies(e.otherCopies) }
                } else {
                    Card {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Reading the extension registry…").font(.v("body")).foregroundStyle(Color.token("t2"))
                        }
                    }
                }
                tools
            }
            .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 20)
        }
    }

    private func header(_ e: ExtensionsSummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: e.problemCount > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 17)).foregroundStyle(Color.token(e.problemCount > 0 ? "needs-text" : "ok-text"))
            VStack(alignment: .leading, spacing: 1) {
                Text(e.problemCount == 0 ? String(localized: "Extensions are working", comment: "Diagnostics › Extensions: headline when nothing is wrong")
                     : e.problemCount == 1 ? String(localized: "1 extension problem", comment: "Diagnostics › Extensions: headline")
                     : String(localized: "\(e.problemCount) extension problems", comment: "Diagnostics › Extensions: headline, how many problems"))
                    .font(.v("title3", .semibold)).foregroundStyle(Color.token("t1"))
                Text(sentence(e)).font(.v("control")).foregroundStyle(Color.token("t2"))
                    .frame(maxWidth: 520, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sentence(_ e: ExtensionsSummary) -> String {
        // Each problem is a whole clause; the clauses are joined as the language joins a list, into one sentence.
        var parts: [String] = []
        let off = e.extensions.filter { $0.state == .off }.map { name($0) }
        if !off.isEmpty {
            let list = SetAsidePlan.list(off)
            parts.append(off.count == 1 ? String(localized: "\(list) is off", comment: "Diagnostics › Extensions: a clause; one extension's name")
                                        : String(localized: "\(list) are off", comment: "Diagnostics › Extensions: a clause; extensions' names, as a list"))
        }
        let missing = e.extensions.filter { $0.state == .notRegistered }.map { name($0) }
        if !missing.isEmpty {
            let list = SetAsidePlan.list(missing)
            parts.append(missing.count == 1 ? String(localized: "\(list) is not registered", comment: "Diagnostics › Extensions: a clause; one extension's name")
                                            : String(localized: "\(list) are not registered", comment: "Diagnostics › Extensions: a clause; extensions' names, as a list"))
        }
        if e.extensions.contains(where: { if case .onElsewhere = $0.state { true } else { false } }) {
            parts.append(String(localized: "macOS uses another copy of Vitrine", comment: "Diagnostics › Extensions: a clause"))
        }
        if !e.otherCopies.isEmpty {
            let n = e.otherCopies.count
            parts.append(n == 1 ? String(localized: "another Vitrine is still registered", comment: "Diagnostics › Extensions: a clause")
                                : String(localized: "\(n) other copies of Vitrine are still registered", comment: "Diagnostics › Extensions: a clause; how many copies"))
        }
        guard !parts.isEmpty else { return String(localized: "Every Vitrine extension is on and macOS uses this copy.", comment: "Diagnostics › Extensions: line under the headline") }
        let joined = SetAsidePlan.list(parts)
        let clauses = joined.hasPrefix("macOS") ? joined : joined.prefix(1).uppercased() + joined.dropFirst()
        return String(localized: "\(clauses).", comment: "Diagnostics › Extensions: the problems as one sentence; end it with the language's full stop")
    }

    private func name(_ x: ExtensionHealth) -> String { Self.families[x.id]?.name ?? x.name }

    @ObservedObject private var helper = HelperLifecycle.shared

    /// VitrineHelper (X-3): on and answering, stale, off or waiting for approval, with the matching action.
    private var helperRow: some View {
        PaneRow(title: String(localized: "Vitrine Helper", comment: "Diagnostics › Extensions: the background helper's row"),
                subtitle: HelperRow.status(helper), subtitleToken: helper.isWorking ? "t2" : "needs-text", problem: !helper.isWorking) {
            KindTile(token: "kind-other", symbol: "gearshape.2")
        } controls: {
            if helper.isWorking {
                Image(systemName: "checkmark.circle").foregroundStyle(Color.token("ok-text"))
            } else if helper.state == .requiresApproval {
                Button { SMAppService.openSystemSettingsLoginItems() } label: { Label("Open System Settings", systemImage: "arrow.up.forward.square") }
                    .buttonStyle(.vitrinePrimarySmall)
            } else if helper.state == .enabled {
                Button("Re-register") { Task { await helper.reconcileAtLaunch() } }.buttonStyle(.vitrinePrimarySmall)
            } else {
                Button("Turn On") { Task { await helper.turnOn() } }.buttonStyle(.vitrinePrimarySmall)
            }
        }
        .task { await helper.refresh() }
    }

    private func row(_ x: ExtensionHealth) -> some View {
        let fam = Self.families[x.id] ?? (x.name, "kind-other", "puzzlepiece.extension")
        let (subtitle, token): (String, String) = switch x.state {
        case .on(let v): (String(localized: "On · \(v)", comment: "Diagnostics › Extensions: the extension is on, then its version"), "t2")
        case .onElsewhere(let v, let path):
            (String(localized: "On · \(v) · macOS uses the copy at \(Self.shortPath(path))", comment: "Diagnostics › Extensions: on, its version, then the folder of the copy macOS uses"),
             "needs-text")
        case .off: (String(localized: "Turned off in System Settings", comment: "Diagnostics › Extensions: row subtitle"), "needs-text")
        case .notRegistered: (String(localized: "Not registered with macOS", comment: "Diagnostics › Extensions: row subtitle"), "needs-text")
        }
        return PaneRow(title: fam.name, subtitle: subtitle, subtitleToken: token, problem: x.isProblem) {
            KindTile(token: fam.tile, symbol: fam.symbol)
        } controls: {
            switch x.state {
            case .on: Image(systemName: "checkmark.circle").foregroundStyle(Color.token("ok-text"))
            case .off:
                Button { Diagnostics.openQuickLookSettings() } label: { Label("Open System Settings", systemImage: "arrow.up.forward.square") }
                    .buttonStyle(.vitrinePrimarySmall)
            case .notRegistered, .onElsewhere:
                Button("Re-register") { store.perform("reregister") { DiagnosticsRepair.reRegister() } }
                    .buttonStyle(.vitrinePrimarySmall).disabled(store.running != nil)
            }
        }
    }

    @ViewBuilder private func copies(_ copies: [OtherCopy]) -> some View {
        GroupHeading(title: "Other copies of Vitrine") {
            if copies.count > 1 {
                Button("Unregister All…") { confirmUnregisterAll(copies) }
                    .buttonStyle(.vitrineSmall).disabled(store.running != nil)
            }
        }
        RowGroup {
            ForEach(copies) { c in
                PaneRow(title: Self.copyTitle(c), subtitle: Self.copySubtitle(c),
                         subtitleToken: "needs-text", subtitleLines: 2, problem: true) {
                    KindTile(token: "kind-other", symbol: "app.dashed")
                } controls: {
                    Button("Show in Finder") { DiagnosticsRepair.showInFinder(c.appPath) }.buttonStyle(.vitrineSmall)
                    Button("Unregister") { store.perform("unregister-" + c.appPath) { DiagnosticsRepair.unregister(c) } }
                        .buttonStyle(.vitrinePrimarySmall).disabled(store.running != nil)
                }
            }
        }
    }

    /// "Older copy: Vitrine 0.0.9 (Spacebar)": older or not than this copy, its version, and the working name when it
    /// carries it.
    static func copyTitle(_ c: OtherCopy) -> String {
        let v = c.version
        let title = isOlder(v) ? String(localized: "Older copy: Vitrine \(v)", comment: "Diagnostics › Other copies: an older Vitrine, then its version")
                               : String(localized: "Other copy: Vitrine \(v)", comment: "Diagnostics › Other copies: another Vitrine, then its version")
        return c.legacyName ? title + " (Spacebar)" : title
    }

    static func copySubtitle(_ c: OtherCopy) -> String {
        let path = abbreviate(c.appPath)
        return c.inUse ? String(localized: "Registered from \(path) · macOS uses its extensions now", comment: "Diagnostics › Other copies: the copy's folder")
                       : String(localized: "Registered from \(path) · macOS may pick this copy's extensions", comment: "Diagnostics › Other copies: the copy's folder")
    }

    private func confirmUnregisterAll(_ copies: [OtherCopy]) {
        let n = copies.count
        let alert = NSAlert()
        alert.messageText = String(localized: "Unregister \(n) other copies of Vitrine?", comment: "Diagnostics: alert title; how many copies (always two or more)")
        alert.informativeText = String(localized: "macOS forgets their Quick Look extensions and apps. Their files stay where they are; opening one registers it again.",
                                       comment: "Diagnostics: alert text for Unregister All")
        alert.addButton(withTitle: String(localized: "Unregister", comment: "Diagnostics: alert button that unregisters the other copies"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Alert button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.perform("unregister-all", message: String(localized: "\(n) copies unregistered", comment: "Diagnostics: message after Unregister All; how many copies")) {
            let results = copies.map { DiagnosticsRepair.unregister($0) }
            return results.first { !$0.ok } ?? DiagnosticsRepair.Outcome(ok: true, message: String(localized: "Unregistered", comment: "Diagnostics: message after Unregister"))
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeading(title: "Repair tools")
            RowGroup {
                tool(id: "reregister", String(localized: "Re-register Vitrine with macOS", comment: "Diagnostics › Repair tools: row title"),
                     String(localized: "Runs Launch Services registration again. Safe; nothing is deleted.", comment: "Diagnostics › Repair tools: row subtitle; Launch Services is the macOS app registry"),
                     button: String(localized: "Re-register", comment: "Diagnostics › Repair tools: button")) {
                    DiagnosticsRepair.reRegister()
                }
                tool(id: "restart", String(localized: "Restart Quick Look", comment: "Diagnostics › Repair tools: row title"),
                     String(localized: "Quits the preview service; Finder starts it again on the next Space.", comment: "Diagnostics › Repair tools: row subtitle; Space is the key"),
                     button: String(localized: "Restart", comment: "Diagnostics › Repair tools: button")) {
                    DiagnosticsRepair.restartQuickLook()
                }
                tool(id: "cache", String(localized: "Clear thumbnail cache", comment: "Diagnostics › Repair tools: row title"),
                     String(localized: "Finder redraws file icons as you browse.", comment: "Diagnostics › Repair tools: row subtitle"),
                     button: String(localized: "Clear", comment: "Diagnostics › Repair tools: button that clears the thumbnail cache")) {
                    DiagnosticsRepair.clearThumbnailCache()
                }
            }
        }
    }

    private func tool(id: String, _ title: String, _ subtitle: String, button: String,
                      _ work: @escaping @Sendable () -> DiagnosticsRepair.Outcome) -> some View {
        PaneRow(title: title, subtitle: subtitle) {
            EmptyView()
        } controls: {
            if store.running == id { ProgressView().controlSize(.small) }
            Button(button) { store.perform(id, work) }
                .buttonStyle(.vitrineSmall).disabled(store.running != nil)
        }
    }

    /// "~/Vitrine/…/Debug/Vitrine.app": home as ~, and long paths cut to their first two and last two parts.
    static func shortPath(_ path: String) -> String {
        let parts = abbreviate(path).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 5 else { return parts.joined(separator: "/") }
        return (parts.prefix(2) + ["…"] + parts.suffix(2)).joined(separator: "/")
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func isOlder(_ version: String) -> Bool {
        let mine = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        return version.compare(mine, options: .numeric) == .orderedAscending
    }
}

// MARK: - Offscreen picture

/// `Vitrine --diagnostics-snapshot <out.png> [dark] [types|extensions]`: runs the live check, draws the window
/// offscreen at the design's 880 × 660 and writes a PNG. Never clicks anything.
@MainActor
enum DiagnosticsSnapshotWriter {
    static func write(to url: URL, pane: DiagnosticsPane, dark: Bool) {
        Task.detached {
            let snapshot = DiagnosticsProbe.snapshot()
            await MainActor.run {
                let store = DiagnosticsStore(snapshot: snapshot)
                store.pane = pane
                let size = NSSize(width: 880, height: 660)
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.titlebarAppearsTransparent = true
                window.toolbarStyle = .unified
                let host = NSHostingView(rootView: DiagnosticsView(store: store))
                host.sceneBridgingOptions = ProcessInfo.processInfo.environment["VITRINE_SNAPSHOT_BRIDGE"] != nil ? [.toolbars, .title] : []
                window.contentView = host
                window.setContentSize(size)
                // Never ordered in: a key window would feed the main menu's focus tracking.
                window.isReleasedWhenClosed = false
                Task { @MainActor in
                    for _ in 0..<3 {
                        host.layoutSubtreeIfNeeded()
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                    let view = window.contentView?.superview ?? host
                    view.layoutSubtreeIfNeeded()
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    do {
                        try rep.representation(using: .png, properties: [:])?.write(to: url)
                        print("wrote \(url.path)"); exit(0)
                    } catch {
                        FileHandle.standardError.write(Data("diagnostics snapshot failed: \(error)\n".utf8)); exit(1)
                    }
                }
            }
        }
    }
}
