import AppKit
import UniformTypeIdentifiers
import VitrinePreviewKit
import VitrineSupport

/// The app's half of Finder's Quick Actions (X-5): the Services entries the Quick Action extensions call
/// (`NSServices` in Info.plist, QuickAction.serviceName / serviceMessage). The app is already the services provider
/// for the folder-icon entries (AppDelegate sets `NSApp.servicesProvider = self`), so these are more of its methods.
///
/// Any process can call a Services entry (NSPerformService), not only the extensions, and the app is not sandboxed.
/// So these entries take only the file URLs the request carries (ServicesPasteboard), never write anything back to the
/// request's pasteboard (no NSReturnTypes), and write an export only where the person chooses (QuickActionExporter.plan).
///
/// Each returns at once and does the work on the next turn of the run loop, so the extension's call never waits on
/// a render. roadmap: S-10 (X-5), S-16 (F11)
extension AppDelegate {
    @objc func quickActionOpen(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let files = ServicesPasteboard.fileURLs(on: pboard)
        guard !files.isEmpty else { return }
        DispatchQueue.main.async { PreviewWindows.shared.handle(.open(files: files), activate: true) }
    }

    @objc func quickActionExportPDF(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        QuickActionExports.run(ServicesPasteboard.fileURLs(on: pboard), as: .pdf)
    }

    @objc func quickActionExportHTML(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        QuickActionExports.run(ServicesPasteboard.fileURLs(on: pboard), as: .html)
    }
}

/// Asks where the exports go (one save panel, or one folder panel for several documents), then runs them one after
/// another and reports every failure in one alert at the end. Nothing is drawn or written before the person answers.
@MainActor
enum QuickActionExports {
    static func run(_ files: [URL], as format: PreviewExport.Format) {
        guard !files.isEmpty else { return }
        Task { @MainActor in
            var failures: [String] = []
            var exportable: [URL] = []
            for file in files {
                if QuickActionExporter.isExportable(FileSniffer.kind(of: file)) {
                    exportable.append(file)
                } else {
                    failures.append(QuickActionExporter.Failure.notExportable(file.lastPathComponent).localizedDescription)
                }
            }
            let jobs = QuickActionExporter.plan(exportable, format: format) { ask($0, format: format) }
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let context = RenderContext(appearance: dark ? .dark : .light)
            for job in jobs {
                do {
                    _ = try await QuickActionExporter.export(job.source, as: format, to: job.destination, context: context,
                                                             appearance: dark ? .darkAqua : .aqua)
                } catch {
                    failures.append("\(job.source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            guard !failures.isEmpty else { return }
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = format == .pdf
                ? String(localized: "Vitrine could not export as PDF", comment: "Alert title when a Finder Quick Action's PDF export failed.")
                : String(localized: "Vitrine could not export as HTML", comment: "Alert title when a Finder Quick Action's HTML export failed.")
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        }
    }

    /// The panel for `question`: a save panel named after the one document, or a folder panel for several. Both open
    /// in the document's folder; the person decides. The export still never replaces a file: a taken name gets a number.
    private static func ask(_ question: QuickActionExporter.DestinationQuestion, format: PreviewExport.Format) -> URL? {
        NSApp.activate()
        switch question {
        case .file(let source, let suggested):
            let panel = NSSavePanel()
            let name = source.lastPathComponent
            panel.message = format == .pdf
                ? String(localized: "Choose where to save the PDF of \(name).",
                         comment: "Save panel message for a Finder Quick Action's PDF export of one document; the document's file name.")
                : String(localized: "Choose where to save the HTML page of \(name).",
                         comment: "Save panel message for a Finder Quick Action's HTML export of one document; the document's file name.")
            panel.directoryURL = suggested.deletingLastPathComponent()
            panel.nameFieldStringValue = suggested.lastPathComponent
            panel.allowedContentTypes = [UTType(filenameExtension: suggested.pathExtension) ?? .data]
            panel.canCreateDirectories = true
            return panel.runModal() == .OK ? panel.url : nil
        case .folder(let sources, let folder):
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = folder
            panel.prompt = String(localized: "Export Here",
                                  comment: "Button of the folder panel for a Finder Quick Action export of several documents.")
            panel.message = format == .pdf
                ? String(localized: "Choose a folder for the PDFs of \(sources.count) documents.",
                         comment: "Folder panel message for a Finder Quick Action's PDF export of several documents; how many (2 or more).")
                : String(localized: "Choose a folder for the HTML pages of \(sources.count) documents.",
                         comment: "Folder panel message for a Finder Quick Action's HTML export of several documents; how many (2 or more).")
            return panel.runModal() == .OK ? panel.url : nil
        }
    }
}
