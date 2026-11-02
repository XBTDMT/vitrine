import XCTest
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineText

/// ARCHITECTURE §12 step 2: previews are drawn from a `PreviewDocument`.
@MainActor
final class PreviewDocumentBuilderTests: XCTestCase {
    private func file(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testPlainTextDocumentIsCodeWithFacts() throws {
        let doc = try PlainTextRenderer.document(url: try file("m.py", "a = 1\nb = 2\n"), kind: .code(language: "python"))
        XCTAssertEqual(doc.views, [.code("a = 1\nb = 2\n", language: "python")])
        XCTAssertEqual(doc.fact("lines")?.value, "2")
        XCTAssertTrue(doc.coverage.isComplete)
    }

    func testLargeFileIsPartialAndSaysSo() throws {
        let big = String(repeating: "0123456789abcdef\n", count: Int(PlainTextRenderer.streamingThreshold / 17) + 10)
        let doc = try PlainTextRenderer.document(url: try file("big.log", big), kind: .plainText)
        guard case .partial(let shown, let total, let unit, let reason) = doc.coverage else { return XCTFail("partial") }
        XCTAssertEqual(shown, Int64(PlainTextRenderer.firstChunk))
        XCTAssertEqual(total, Int64(big.utf8.count))
        XCTAssertEqual(unit, .bytes)
        XCTAssertTrue(reason.contains("first 1 MB"), reason)
    }

    func testRenderedPreviewCarriesItsDocument() async throws {
        let url = try file("r.md", "# R\n")
        let preview = try await MarkdownRenderer().render(url: url, kind: .markdown(.commonMark),
                                                          context: RenderContext(appearance: .light, defaultsSuite: "vt-doc-\(UUID().uuidString)"))
        XCTAssertEqual(preview.kind, .markdown(.commonMark))
        XCTAssertEqual(preview.document.views.last, .text("# R\n"))
    }
}
