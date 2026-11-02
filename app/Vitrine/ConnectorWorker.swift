import AppKit
import ImageIO
import VitrineDocument
import VitrineConnector
import VitrineMCP
import VitrinePreviewKit
import VitrineSupport
import VitrineText
import VitrineTrust
import VitrineDetect

/// The Claude connector's worker (X-9, G-22 route A): `vitrine mcp` starts `Vitrine --mcp-call` once per tool call,
/// writes one WorkerRequest to its standard input and reads one WorkerResponse from its standard output. It runs the
/// same renderers the previews use, with no window on screen, no Dock icon, no menu bar and none of the app's
/// background parts; a crash or hang here costs the one call. roadmap: S-11
@MainActor
enum ConnectorWorker {
    static var isRequested: Bool { CommandLine.arguments.contains("--mcp-call") }

    /// Runs one call and exits. Called from VitrineMain before SwiftUI starts, so no scene is ever created.
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let input = FileHandle.standardInput.readDataToEndOfFile()
        Task { @MainActor in
            let response: WorkerResponse
            if let request = try? JSONDecoder().decode(WorkerRequest.self, from: input) {
                response = await answer(request)
            } else {
                response = WorkerResponse(error: "The connector sent a request Vitrine could not read.")
            }
            let data = (try? JSONEncoder().encode(response)) ?? Data(#"{"error":"Vitrine could not encode its answer."}"#.utf8)
            FileHandle.standardOutput.write(data)
            exit(0)
        }
        app.run()
        exit(0)
    }

    static func answer(_ request: WorkerRequest) async -> WorkerResponse {
        let url = URL(fileURLWithPath: request.path)
        let name = url.lastPathComponent
        do {
            switch request.tool {
            case ConnectorTools.render where request.format == "image":
                return WorkerResponse(png: try await image(of: url, dark: request.appearance == "dark"))
            case ConnectorTools.describe:
                return WorkerResponse(text: ConnectorText.describe(try await document(for: url), name: name, path: url.path))
            case ConnectorTools.render:
                let doc = try await document(for: url)
                var text = doc.searchText, count = 0
                if request.secrets == "show" { text = fileText(url, kind: doc.kind) ?? text }
                else { (text, count) = ConnectorText.masked(text, scanner: try scanner(for: doc.kind)) }
                return WorkerResponse(text: ConnectorText.page(text, name: name, kind: doc.kind.displayName, offset: request.offset ?? 0,
                                                               limit: request.limit ?? ConnectorLimits.defaultLines, maskedCount: count,
                                                               coverage: doc.coverage))
            case ConnectorTools.scanSecrets:
                let doc = try await document(for: url)
                // The file's own text where it has one: the preview's text is already masked for config files and
                // sessions, and a scan of masked text finds nothing.
                let own = fileText(url, kind: doc.kind)
                return WorkerResponse(text: ConnectorText.secretsReport(own ?? doc.searchText, name: name, scanner: try scanner(for: doc.kind),
                                                                        coverage: own == nil ? doc.coverage : .complete))
            case ConnectorTools.tokenCount:
                let doc = try await document(for: url)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                // A text file is counted as written (the preview's text has masked values in place of secrets).
                let own = fileText(url, kind: doc.kind)
                return WorkerResponse(text: ConnectorText.tokens(own ?? doc.searchText, name: name, fileBytes: isFolder ? nil : size,
                                                                 coverage: own == nil ? doc.coverage : .complete))
            default:
                return WorkerResponse(error: "Vitrine has no tool named \(request.tool).")
            }
        } catch {
            return WorkerResponse(error: "Vitrine could not read \(name): \(error.localizedDescription)")
        }
    }

    /// The detectors for a kind of file (G-23): format detectors on code; every enabled one on prose and configuration.
    static func scanner(for kind: FileKind) throws -> VitrineDetect.Scanner {
        if let family = LensPolicy.family(for: kind), let scanner = LensPolicy.scanner(for: family) { return scanner }
        return try ConnectorText.scanner()
    }

    /// The most of a text file the connector reads as it is (scan_secrets, render with secrets "show").
    static let fileTextLimit = 32 * 1024 * 1024

    /// A text file's own words, decoded as the code view decodes them; nil for anything that is not text (tables,
    /// archives, apps, images: their text is Vitrine's reading of them) or is larger than the limit.
    static func fileText(_ url: URL, kind: FileKind) -> String? {
        switch kind {
        case .markdown, .code, .plainText, .csv, .diff, .svg: break
        default: return nil
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size <= fileTextLimit,
              let data = try? Data(contentsOf: url) else { return nil }
        return TextEncodingDetector.decode(data).text
    }

    /// The document the preview is drawn from: the same sniffing and renderer the Quick Look controller uses.
    static func document(for url: URL) async throws -> PreviewDocument {
        let kind = FileSniffer.kind(of: url)
        guard let renderer = RendererRegistry.renderer(for: kind) else { throw RenderError.unsupported(kind) }
        return try await renderer.render(url: url, kind: kind, context: RenderContext(appearance: .light)).document
    }

    /// The preview as drawn, through the snapshot path, in a window kept off every screen.
    static func image(of url: URL, dark: Bool) async throws -> Data {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-mcp-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        PreviewSnapshot.keepsOffscreen = true
        try await PreviewSnapshot.write(file: url, to: out, appearance: dark ? .darkAqua : .aqua)
        return try scaled(Data(contentsOf: out))
    }

    /// Claude scales an image down past this long edge, so a larger one only costs context.
    static let imageLongEdge = 1_568

    /// The PNG with its long edge at most `imageLongEdge` pixels (the snapshot is drawn at the screen's 2x).
    static func scaled(_ png: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: imageLongEdge,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return png }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return png }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : png
    }
}
