import AppIntents
import AppKit
import Foundation
import UniformTypeIdentifiers
import VitrinePreviewKit
import VitrineSupport

/// What Convert makes.
enum ConvertFormat: String, AppEnum {
    case html
    case pdf
    case png

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Format", comment: "Shortcuts parameter type: the format Convert makes."))
    static let caseDisplayRepresentations: [ConvertFormat: DisplayRepresentation] = [
        .html: DisplayRepresentation(title: LocalizedStringResource("HTML page", comment: "Convert format choice: a standalone HTML page (Markdown only).")),
        .pdf: DisplayRepresentation(title: LocalizedStringResource("PDF", comment: "Convert format choice: a PDF document (Markdown only).")),
        .png: DisplayRepresentation(title: LocalizedStringResource("PNG picture", comment: "Convert format choice: a picture of the preview.")),
    ]

    var fileExtension: String { rawValue }

    var contentType: UTType {
        switch self {
        case .html: .html
        case .pdf: .pdf
        case .png: .png
        }
    }
}

/// Convert (X-6): Markdown as one self-contained HTML page or a PDF, and any file Vitrine previews as a PNG picture of
/// the preview — through the Vitrine window's own export (PreviewExport, MarkdownRenderer.exportHTML) and the snapshot
/// path (PreviewSnapshot), in a window kept off every screen. roadmap: S-10
struct ConvertIntent: AppIntent {
    static let title = LocalizedStringResource("Convert File", comment: "Shortcuts action name: converts Markdown to HTML or PDF, or any file to a picture of its preview.")
    static let description = IntentDescription(
        LocalizedStringResource("Turns Markdown into a self-contained HTML page or a PDF, and any file Vitrine previews into a PNG picture of its preview.",
                                comment: "Shortcuts action description for Convert."),
        categoryName: LocalizedStringResource("Read files", comment: "Shortcuts category for Vitrine's actions that read files."))

    @Parameter(title: LocalizedStringResource("File", comment: "Shortcuts parameter: the file the action reads."),
               supportedContentTypes: [.item])
    var file: IntentFile

    @Parameter(title: LocalizedStringResource("Format", comment: "Shortcuts parameter: the format Convert makes."), default: .png)
    var format: ConvertFormat

    @Parameter(title: LocalizedStringResource("Dark appearance", comment: "Shortcuts parameter: draw the result in dark mode."), default: false)
    var dark: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$file) to \(\.$format)") {
            \.$dark
        }
    }

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        .result(value: try await run())
    }

    @MainActor
    func run() async throws -> IntentFile {
        let format = self.format, dark = self.dark
        return try await IntentInput.with(file) { input in
            let data = try await Self.convert(input, to: format, dark: dark)
            return IntentOutput.file(data, named: IntentOutput.filename(for: input.name, extension: format.fileExtension), type: format.contentType)
        }
    }

    /// How long a page settles in its window before it is exported (the snapshot path's own wait).
    static let settle: Duration = .milliseconds(600)
    static let pageSize = NSSize(width: 1000, height: 760)

    @MainActor
    static func convert(_ input: IntentInput, to format: ConvertFormat, dark: Bool) async throws -> Data {
        let kind = FileSniffer.kind(of: input.url)
        do {
            switch format {
            case .png:
                guard RendererRegistry.renderer(for: kind) != nil else { throw VitrineIntentError.unsupported(name: input.name) }
                return try await png(of: input.url, dark: dark)
            case .html, .pdf:
                guard case .markdown = kind else { throw VitrineIntentError.needsMarkdown(name: input.name) }
                return try await markdown(input, kind: kind, format: format, dark: dark)
            }
        } catch {
            throw VitrineIntentError.wrapping(error, name: input.name)
        }
    }

    /// The preview as drawn, at the screen's scale, through the snapshot path.
    @MainActor
    static func png(of url: URL, dark: Bool) async throws -> Data {
        let folder = try IntentOutput.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("preview.png")
        // Nothing may appear on screen while the person works (the connector worker's rule).
        PreviewSnapshot.keepsOffscreen = true
        try await PreviewSnapshot.write(file: url, to: out, size: pageSize, appearance: dark ? .darkAqua : .aqua)
        return try Data(contentsOf: out)
    }

    /// Markdown as the Vitrine window exports it: rendered into a window off every screen, then the page as one HTML
    /// file (pictures, styles and maths fonts inside, no script) or printed onto PDF pages in its own colours.
    @MainActor
    static func markdown(_ input: IntentInput, kind: FileKind, format: ConvertFormat, dark: Bool) async throws -> Data {
        let preview = try await MarkdownRenderer().render(url: input.url, kind: kind, context: RenderContext(appearance: dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: pageSize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        preview.view.frame = NSRect(origin: .zero, size: pageSize)
        window.contentView = preview.view
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: settle)
        switch format {
        case .html:
            guard let exporter = preview.htmlExporter else { throw VitrineIntentError.needsMarkdown(name: input.name) }
            return Data(try await exporter.exportHTML(title: input.name).utf8)
        case .pdf, .png:
            let folder = try IntentOutput.temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let out = folder.appendingPathComponent("page.pdf")
            try await PreviewExport.pdf(of: preview.view, to: out)
            return try Data(contentsOf: out)
        }
    }
}
