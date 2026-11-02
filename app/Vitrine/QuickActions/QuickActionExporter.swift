import AppKit
import VitrinePreviewKit
import VitrineSupport

/// Export as PDF and Export as HTML from Finder (X-5), done by the app because the extensions cannot write files. The
/// export goes only where the person chooses in a panel Vitrine shows (`plan`, S-16 F11). The document is drawn by
/// the same renderer as the preview, in a window off every screen, and written with the window's own export (PreviewExport.pdf, MarkdownRenderer.exportHTML). Only documents whose page holds the
/// whole file export (the Markdown family), as in the preview's menu.
///
/// A file is never overwritten: the export goes to a temporary file first and is then moved to the first free name
/// ("Notes.pdf", "Notes 2.pdf" …); a move refuses an existing name, so a file that appears meanwhile is kept too.
/// roadmap: S-10 (X-5), S-16 (F11)
@MainActor
enum QuickActionExporter {
    enum Failure: LocalizedError, Equatable {
        case notExportable(String)
        case noFreeName(String)

        var errorDescription: String? {
            switch self {
            case .notExportable(let name):
                return String(localized: "\(name) is not a Markdown document. Only Markdown documents export as PDF or HTML.",
                              comment: "Finder Quick Action export error; the file's name.")
            case .noFreeName(let name):
                return String(localized: "There is no free name for the export of \(name) in its folder.",
                              comment: "Finder Quick Action export error, after 999 numbered names were taken; the file's name.")
            }
        }
    }

    /// The name the export would take beside `source` (or at `destination`'s place): its own name with the format's
    /// extension, then numbered from 2 until one is free.
    static func freeName(for desired: URL, fileManager: FileManager = .default) -> URL? {
        let folder = desired.deletingLastPathComponent()
        let base = desired.deletingPathExtension().lastPathComponent, ext = desired.pathExtension
        for n in 1...999 {
            let name = n == 1 ? base : "\(base) \(n)"
            let candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The name and folder the save panel suggests for the export of `source`: beside it, named after it.
    static func besideSource(_ source: URL, format: PreviewExport.Format) -> URL {
        source.deletingPathExtension().appendingPathExtension(format.fileExtension)
    }

    /// What Vitrine asks before a Finder Quick Action exports. The answer is the only place the export is written.
    enum DestinationQuestion: Equatable {
        /// One document: a save panel named after it (`suggested`), opening in the document's folder.
        case file(source: URL, suggested: URL)
        /// Several: one folder panel for the whole selection; each export takes its document's name there.
        case folder(sources: [URL], suggestedFolder: URL)
    }

    /// One export to make: draw `source`, write it at `destination` or the first free name after it.
    struct Job: Equatable {
        let source: URL
        let destination: URL
    }

    /// Where each export goes, asked once through `ask`; no answer means nothing is exported (S-16, F11, G-35).
    ///
    /// The export Services can be called by any process, not only Vitrine's Quick Actions: a sandboxed app can put a
    /// document's URL on a pasteboard and call NSPerformService. Vitrine is not sandboxed, so an export written beside
    /// that document (in a folder the caller can read back) would hand the caller what Vitrine read for it. So Vitrine
    /// never picks the place itself: the person chooses it, in a panel Vitrine shows, every time.
    static func plan(_ files: [URL], format: PreviewExport.Format, ask: (DestinationQuestion) -> URL?) -> [Job] {
        guard let first = files.first else { return [] }
        if files.count == 1 {
            guard let chosen = ask(.file(source: first, suggested: besideSource(first, format: format))) else { return [] }
            return [Job(source: first, destination: chosen)]
        }
        guard let folder = ask(.folder(sources: files, suggestedFolder: first.deletingLastPathComponent())) else { return [] }
        return files.map { Job(source: $0, destination: folder.appendingPathComponent(besideSource($0, format: format).lastPathComponent)) }
    }

    /// Whether a document of `kind` exports (the Markdown family, whose page holds the whole document).
    static func isExportable(_ kind: FileKind) -> Bool {
        if case .markdown = kind { return true }
        return false
    }

    /// Draws `source` and writes it as `format` at `desired` or the first free name after it; returns where it went.
    static func export(_ source: URL, as format: PreviewExport.Format, to desired: URL,
                       context: RenderContext, appearance: NSAppearance.Name = .aqua, settleFor seconds: Double = 0.4) async throws -> URL {
        let kind = FileSniffer.kind(of: source)
        guard isExportable(kind), format != .png else { throw Failure.notExportable(source.lastPathComponent) }
        let preview = try await MarkdownRenderer().render(url: source, kind: kind, context: context)
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        preview.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = preview.view
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .seconds(seconds))

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent(desired.lastPathComponent)
        switch format {
        case .pdf:
            try await PreviewExport.pdf(of: preview.view, to: temporary)
        case .html:
            guard let exporter = preview.htmlExporter else { throw Failure.notExportable(source.lastPathComponent) }
            try Data(try await exporter.exportHTML(title: source.lastPathComponent).utf8).write(to: temporary, options: .withoutOverwriting)
        case .png:
            throw Failure.notExportable(source.lastPathComponent)
        }
        return try place(temporary, at: desired)
    }

    /// Moves `file` to `desired` or the first free numbered name after it, never replacing a file.
    static func place(_ file: URL, at desired: URL, fileManager: FileManager = .default) throws -> URL {
        var attempts = 0
        while attempts < 999 {
            attempts += 1
            guard let target = freeName(for: desired, fileManager: fileManager) else { break }
            do {
                try fileManager.moveItem(at: file, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw Failure.noFreeName(desired.deletingPathExtension().lastPathComponent)
    }
}

/// The files a Services request carries (S-16, F11): its `public.file-url` items, in order, at most `limit`. Text and
/// web URLs are never read as paths. File reference URLs (`file:///.file/id=…`) arrive as their paths.
///
/// This is not a check on the caller: the pasteboard server turns a legacy NSFilenamesPboardType list into file URL
/// items itself, and any process can write a file URL. What protects the files is what each entry does with them
/// (an export is written only where the person chooses). Shared by every Services entry that takes files.
enum ServicesPasteboard {
    static func fileURLs(on pboard: NSPasteboard, limit: Int = QuickAction.maxFiles) -> [URL] {
        var urls: [URL] = []
        for item in pboard.pasteboardItems ?? [] where urls.count < limit {
            guard let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL,
                  let path = (url as NSURL).filePathURL else { continue }
            urls.append(path.standardizedFileURL)
        }
        return urls
    }
}
