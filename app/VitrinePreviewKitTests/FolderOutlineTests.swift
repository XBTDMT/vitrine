import XCTest
@testable import VitrinePreviewKit
import VitrineSupport

/// Folders in the browse design: folders first then natural name order, hidden items counted and not listed,
/// packages closed, each folder read only when opened.
@MainActor
final class FolderOutlineTests: XCTestCase {
    func testOrderHiddenPackagesAndLazyReading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vt-folder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for d in ["src/deep", "Docs", "Tool.app/Contents"] { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        for f in ["file10.txt", "file2.txt", ".secret", "src/a.swift", "src/deep/b.swift"] {
            try "x\n".write(to: root.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        let renderer = FolderRenderer()
        let preview = try await renderer.render(url: root, kind: .folder, context: RenderContext(appearance: .light, defaultsSuite: "vt-folder"))
        let outline = try XCTUnwrap(renderer.outlineForTesting)
        let names = outline.root.children().map(\.name)
        XCTAssertEqual(names, ["Docs", "src", "file2.txt", "file10.txt", "Tool.app"], "folders first, natural order; the app sorts as a file")
        XCTAssertEqual(outline.root.hiddenCount, 1, ".secret is counted, not listed")
        let app = try XCTUnwrap(outline.root.children().first { $0.name == "Tool.app" })
        XCTAssertFalse(app.isFolder, "packages stay closed, as in Finder")
        XCTAssertEqual(preview.document.fact("headline")?.value, "5 items · 2 folders · 1 hidden")
        let src = try XCTUnwrap(outline.root.children().first { $0.name == "src" })
        XCTAssertEqual(src.children().map(\.name), ["deep", "a.swift"], "read when opened")
    }

    func testFindOpensFoldersAndSaysWhenItStopped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vt-ffind-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        for f in ["a/b/Needle.txt", "a/needle.md", "z.txt"] {
            try "x\n".write(to: root.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        let renderer = FolderRenderer()
        let preview = try await renderer.render(url: root, kind: .folder, context: RenderContext(appearance: .light, defaultsSuite: "vt-folder"))
        let outline = try XCTUnwrap(renderer.outlineForTesting)
        XCTAssertEqual(outline.table.numberOfRows, 2)
        let first = await preview.find?("needle", true)
        XCTAssertEqual(first, FindResult(count: 2, index: 0))
        XCTAssertEqual((outline.table.item(atRow: outline.table.selectedRow) as? FolderNode)?.name, "Needle.txt", "depth first: a/b/ comes before a/needle.md")
        preview.clearFind?()
        XCTAssertEqual(outline.table.selectedRow, -1)
        let m = CapsuleModel()
        m.show(preview.document, canToggleInspector: false, canFind: true)
        m.onFind = { _, _ in FindResult(count: 3, index: 0, searchedAll: false) }
        m.findQuery = "x"
        await m.find()
        XCTAssertEqual(m.findCountText, "1 of 3+", "a bounded search says its count is a floor")
    }
}
