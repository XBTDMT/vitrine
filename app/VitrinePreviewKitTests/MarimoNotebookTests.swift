import XCTest
import WebKit
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineSupport

/// A marimo notebook (A-8) previews on the notebook page: its kind in the header, Markdown cells drawn, code cells
/// as Python, a named cell's name and a hidden cell's note above it, the note that marimo stores no outputs, and a
/// Python Source view. A `.py` that stops reading as marimo falls back to the Python code view with the reason.
/// Invented notebooks only; nothing in them is run. roadmap: S-21
@MainActor
final class MarimoNotebookTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-marimo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static let notebook = #"""
    import marimo

    __generated_with = "0.9.14"
    app = marimo.App(width="medium")


    @app.cell(hide_code=True)
    def _(mo):
        mo.md(
            r"""
            # Tide tables

            Reads the **harbour** gauge and plots the week.
            """
        )
        return


    @app.cell
    def load_readings():
        import csv
        readings = [1.2, 2.4, 3.1]
        return csv, readings


    @app.cell
    def _(readings):
        peak = max(readings)
        peak
        return (peak,)


    @app.cell
    def _():
        import marimo as mo
        return (mo,)


    if __name__ == "__main__":
        app.run()
    """#

    private func render(_ url: URL, kind: FileKind? = nil) async throws -> (RenderedPreview, WKWebView?) {
        let preview = try await NotebookRenderer().render(url: url, kind: kind ?? FileSniffer.kind(of: url),
                                                          context: RenderContext(appearance: .light, defaultsSuite: "vt-marimo"))
        return (preview, preview.view as? WKWebView)
    }

    func testRoutedAsAMarimoNotebookAndPlainPythonStaysPython() throws {
        let url = dir.appendingPathComponent("tides.py")
        try Self.notebook.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileSniffer.kind(of: url), .code(language: "marimo"))
        XCTAssertTrue(RendererRegistry.renderer(for: .code(language: "marimo")) is NotebookRenderer)
        let plain = dir.appendingPathComponent("plain.py")
        try "import csv\nprint('marimo.App(')\n".write(to: plain, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileSniffer.kind(of: plain), .code(language: "python"))
    }

    func testDrawsTheNotebookPage() async throws {
        let url = dir.appendingPathComponent("tides.py")
        try Self.notebook.write(to: url, atomically: true, encoding: .utf8)
        let (preview, maybeWeb) = try await render(url)
        let web = try XCTUnwrap(maybeWeb, "drawn on the notebook page")
        web.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
        try await Task.sleep(for: .milliseconds(400))
        let text = try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
        XCTAssertTrue(text.contains("marimo notebook"), text)
        XCTAssertTrue(text.contains("4 cells"), text)
        XCTAssertTrue(text.contains("no stored outputs"), text)
        XCTAssertTrue(text.contains("marimo 0.9.14"), text)
        XCTAssertTrue(text.contains("medium"), "the width option")
        XCTAssertTrue(text.contains("Tide tables"), "the Markdown cell is drawn")
        XCTAssertTrue(text.contains("readings = [1.2, 2.4, 3.1]"), "the code cell, dedented")
        XCTAssertFalse(text.contains("return csv, readings"), "the closing return that only hands names on is dropped")
        XCTAssertTrue(text.contains("load_readings"), "the named cell's name")
        XCTAssertTrue(text.contains("code hidden in the app"), "hide_code is shown")
        XCTAssertFalse(text.contains("app.run()"), "the file's footer is not a cell")
        XCTAssertFalse(text.contains("[ ]"), "marimo stores no runs, so no run counter")

        let doc = preview.document
        XCTAssertEqual(doc.kind, .code(language: "marimo"))
        XCTAssertEqual(doc.viewTitles, ["Notebook", "Code only", "Source"])
        guard case .code(let source, "python") = doc.views[2] else { return XCTFail("Source is the Python text") }
        XCTAssertTrue(source.contains("@app.cell"))

        // A picture of the page for review, in the temporary folder.
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        try await Task.sleep(for: .milliseconds(300))
        let image = try await web.takeSnapshot(configuration: nil)
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("vt-marimo-notebook.png")
            try png.write(to: out)
            print("marimo picture:", out.path)
        }
    }

    func testAFileThatNoLongerReadsAsMarimoFallsBackToPython() async throws {
        let url = dir.appendingPathComponent("edited.py")
        try "import csv\nrows = list(csv.reader(open('x')))\n".write(to: url, atomically: true, encoding: .utf8)
        let (preview, _) = try await render(url, kind: .code(language: "marimo"))
        XCTAssertEqual(preview.document.badges.first?.title, "Not drawn as a notebook")
        XCTAssertTrue(preview.document.badges.first?.detail.contains("marimo") == true)
    }
}
