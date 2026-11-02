import XCTest
import WebKit
import PDFKit
@testable import VitrinePreviewKit

/// Beautiful export (I-10): pictures, PDFs and Markdown as one HTML page, made from invented files. roadmap: S-24
@MainActor
final class PreviewExportTests: XCTestCase {
    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A Markdown preview in an off-screen window, as the Vitrine window holds it.
    func markdown(_ text: String, in dir: URL) async throws -> (RenderedPreview, NSWindow) {
        let url = dir.appendingPathComponent("Tidepool.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let preview = try await MarkdownRenderer().render(url: url, kind: .markdown(.commonMark),
            context: RenderContext(appearance: .light, defaultsSuite: "vt-export-suite", cachesDirectory: dir.appendingPathComponent("caches")))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        preview.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = preview.view
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(400))
        return (preview, window)
    }

    func testANativeViewBecomesAPictureAndAOnePagePDF() async throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor.systemTeal.cgColor
        let png = try await PreviewExport.png(of: view)
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertGreaterThanOrEqual(NSBitmapImageRep(data: png)?.pixelsWide ?? 0, 120)
        let url = try folder().appendingPathComponent("card.pdf")
        try await PreviewExport.pdf(of: view, to: url)
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 1)
    }

    func testALongMarkdownPageIsPrintedOntoSeveralPages() async throws {
        let dir = try folder()
        let text = "# Tide log\n\n" + (1...120).map { "Reading \($0): the tide at Cascais rose to \($0 % 4).\($0 % 10) m.\n" }.joined(separator: "\n")
        let (preview, window) = try await markdown(text, in: dir)
        defer { window.orderOut(nil) }
        let url = dir.appendingPathComponent("tides.pdf")
        try await PreviewExport.pdf(of: preview.view, to: url)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(pdf.pageCount, 1, "a long page is paginated")
        XCTAssertTrue(pdf.string?.contains("Reading 120") == true, "the last reading is in the PDF")
    }

    func testMarkdownExportsAsOneSelfContainedPage() async throws {
        let dir = try folder()
        let pixel = NSImage(size: NSSize(width: 4, height: 4))
        pixel.lockFocus(); NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); pixel.unlockFocus()
        let rep = NSBitmapImageRep(data: try XCTUnwrap(pixel.tiffRepresentation))
        try XCTUnwrap(rep?.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("tide.png"))
        let (preview, window) = try await markdown("# Tidepool\n\n![tide chart](tide.png)\n\nHeight $h = 2.5$ m.\n\n```sh\nbrew install tidepool\n```\n", in: dir)
        defer { window.orderOut(nil) }
        let exporter = try XCTUnwrap(preview.htmlExporter, "Markdown offers HTML export")
        let html = try await exporter.exportHTML(title: "Tidepool.md")
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("<title>Tidepool.md</title>"))
        XCTAssertTrue(html.contains("<h1"), "the document is there")
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"), "the picture beside the file is inside")
        XCTAssertTrue(html.contains("katex") && html.contains("data:font/woff2;base64,"), "maths keeps its styles and fonts")
        XCTAssertFalse(html.lowercased().contains("<script"), "no script travels")
        XCTAssertFalse(html.contains("vitrine://"), "nothing points back into Vitrine")
        XCTAssertFalse(html.contains("class=\"copy\""), "Vitrine's controls stay behind")
        let text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        XCTAssertTrue(text.contains("brew install tidepool"), "the code block's words, coloured into spans")
    }

    func testOnlyRenderersThatWritePagesOfferHTML() async throws {
        let url = try folder().appendingPathComponent("notes.txt")
        try "plain".write(to: url, atomically: true, encoding: .utf8)
        let preview = try await PlainTextRenderer().render(url: url, kind: .plainText, context: RenderContext(appearance: .light))
        XCTAssertNil(preview.htmlExporter)
    }
}
