import AppKit
import SwiftUI
import VitrinePreviewKit
import VitrineUI

/// The empty window (window.html state 10): a dashed drop well with "No file open" and how to get a file in, then
/// the recent previews. The recents are the menu bar's list (what Quick Look showed), read here and never written:
/// the window itself records nothing. roadmap: S-10 (H-3)
struct WindowEmptyView: View {
    var entries: [RecentPreviews.Entry]
    var open: (URL) -> Void
    var now = Date()

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.token("t2"))
                Text("No file open")
                    .font(.system(size: Metric.value("fs-title3"), weight: .semibold))
                    .foregroundStyle(Color.token("t1"))
                Text(Self.hint)
                    .font(.system(size: Metric.value("fs-body")))
                    .foregroundStyle(Color.token("t2"))
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 22).padding(.horizontal, 18)
            .frame(width: 360)
            .overlay(RoundedRectangle(cornerRadius: Metric.value("r-panel"))
                .strokeBorder(Color.token("hair"), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent")
                        .font(.system(size: Metric.value("fs-caption"), weight: .semibold))
                        .foregroundStyle(Color.token("t2"))
                        .padding(.horizontal, 8).padding(.bottom, 2)
                    ForEach(entries.prefix(5), id: \.path) { entry in
                        RecentRow(entry: entry, now: now) { open(entry.url) }
                    }
                }
                .frame(width: 360)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.token("page"))
    }

    /// How to get a file in, one sentence for translators; the command (never translated) is set in the code face.
    static var hint: AttributedString {
        let command = "vitrine open <file>"
        var text = AttributedString(localized: "Drop a file here, press ⌘O, or run \(command)",
                                    comment: "Vitrine window, empty: how to open a file; the placeholder is the Terminal command, keep it")
        if let range = text.range(of: command) { text[range].font = .system(size: Metric.value("fs-mono"), design: .monospaced) }
        return text
    }
}

private struct RecentRow: View {
    var entry: RecentPreviews.Entry
    var now: Date
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                WindowKindTile(fileName: entry.name)
                Text(entry.name)
                    .font(.system(size: Metric.value("fs-callout")))
                    .foregroundStyle(Color.token("t1"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: Metric.value("fs-caption")))
                    .foregroundStyle(Color.token("t2"))
                    .lineLimit(1)
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: Metric.value("r-ctl")).fill(hover ? Color.token("fill") : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(entry.path)
    }

    /// "harbor-sync · 2 min ago": the folder it is in, then when Quick Look showed it.
    private var detail: String {
        let folder = entry.url.deletingLastPathComponent().lastPathComponent
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = now.timeIntervalSince(entry.time) < 60 ? String(localized: "just now", comment: "Vitrine window › Recent: previewed less than a minute ago")
            : formatter.localizedString(for: entry.time, relativeTo: now)
        return "\(folder) · \(when)"
    }
}

/// The design's kind tile (`.kt`): the file's extension in white on its family's colour, 16 pt.
struct WindowKindTile: View {
    var fileName: String
    var size: CGFloat = 16

    var body: some View {
        Text(Self.label(for: fileName))
            .font(.system(size: 6.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.token(Self.token(for: fileName))))
    }

    static func label(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "": return "DOC"
        case "jsonl", "ndjson": return "JL"
        case "markdown", "mdown": return "MD"
        case "yaml": return "YML"
        default: return String(ext.uppercased().prefix(4))
        }
    }

    static func token(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mdx", "txt", "rst", "adoc", "org": return "kind-text"
        case "csv", "tsv", "sqlite", "db", "sqlite3", "parquet", "xlsx": return "kind-data"
        case "jsonl", "ndjson", "ipynb": return "kind-ai"
        case "zip", "tar", "gz", "tgz", "7z", "rar", "xz", "bz2": return "kind-archive"
        case "app", "pkg": return "kind-app"
        case "dmg", "iso": return "kind-disk"
        case "png", "jpg", "jpeg", "gif", "heic", "svg", "webp", "tiff": return "kind-image"
        case "log": return "kind-other"
        case "": return "kind-other"
        default: return "kind-code"
        }
    }
}

/// A file the window cannot show: what happened, where the file is, and the way out to the default app.
/// Not drawn in the design; the plainest native message.
struct WindowMessageView: View {
    var title: String
    var detail: String
    var actionTitle: String?
    var action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 26))
                .foregroundStyle(Color.token("t2"))
            Text(title)
                .font(.system(size: Metric.value("fs-title3"), weight: .semibold))
                .foregroundStyle(Color.token("t1"))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: Metric.value("fs-caption")))
                .foregroundStyle(Color.token("t2"))
                .lineLimit(1).truncationMode(.middle)
            if let actionTitle {
                Button(actionTitle, action: action).padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.token("page"))
    }
}

/// Info (⌘I, state 7): File (kind, size, where, modified), Window (keep on top) and Actions, as group boxes.
/// The remembered-size rule and Follow changes are not built.
struct WindowInfoView: View {
    var url: URL
    var app: String?
    @State var keepOnTop: Bool
    var toggleKeepOnTop: () -> Void
    var openInApp: () -> Void
    var reveal: () -> Void
    var copyPath: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("File") {
                row("Kind", values?.localizedTypeDescription ?? "—")
                if values?.isDirectory != true, let size = values?.fileSize {
                    row("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
                row("Where", url.deletingLastPathComponent().lastPathComponent)
                if let date = values?.contentModificationDate {
                    row("Modified", date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            section("Window") {
                Toggle("Keep on top", isOn: Binding(get: { keepOnTop }, set: { keepOnTop = $0; toggleKeepOnTop() }))
                    .toggleStyle(.switch).controlSize(.mini)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            section("Actions") {
                HStack(spacing: 6) {
                    if let app { Button("Open in \(app)", action: openInApp) }
                    Button("Reveal", action: reveal)
                    Button("Copy Path", action: copyPath)
                }
                .controlSize(.small)
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .padding(10)
        .frame(width: 290)
    }

    private var values: URLResourceValues? {
        try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey, .contentModificationDateKey])
    }

    private func section<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: Metric.value("fs-caption"), weight: .semibold))
                .foregroundStyle(Color.token("t2"))
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Metric.value("r-card")).fill(Color.token("card")))
                .overlay(RoundedRectangle(cornerRadius: Metric.value("r-card")).strokeBorder(Color.token("hair"), lineWidth: 0.5))
        }
    }

    private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(Color.token("t2"))
            Spacer()
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: Metric.value("fs-control")))
        .padding(.horizontal, 10).frame(minHeight: 30)
    }
}
