import XCTest
@testable import VitrinePreviewKit
import VitrineSupport

/// The browse design for archives (r3-a Quiet outline): the outline lists the single top folder's contents, folders
/// holding a flagged entry open by themselves, and the pill carries the counts and the verdict.
@MainActor
final class ArchiveOutlineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-outline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func render(_ url: URL, _ kind: FileKind) async throws -> (RenderedPreview, ArchiveOutline) {
        let renderer = ArchiveRenderer()
        let preview = try await renderer.render(url: url, kind: kind, context: RenderContext(appearance: .light, defaultsSuite: "vt-outline"))
        let view = try XCTUnwrap(preview.view as? ArchiveView)
        return (preview, view.outline)
    }

    func testSingleTopFolderIsTheRootAndCleanIsGreen() async throws {
        let src = dir.appendingPathComponent("src/proj-1.0/docs")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "a\n".write(to: src.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "b\n".write(to: src.deletingLastPathComponent().appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qr", dir.appendingPathComponent("p.zip").path, "proj-1.0"]
        zip.currentDirectoryURL = dir.appendingPathComponent("src")
        try zip.run(); zip.waitUntilExit()
        let (preview, outline) = try await render(dir.appendingPathComponent("p.zip"), .archive(.zip))
        XCTAssertEqual(outline.rootNodeName, "proj-1.0", "the top folder is named in the path row, its contents listed")
        XCTAssertEqual(outline.table.numberOfRows, 2, "docs/ and README.md")
        XCTAssertEqual(preview.document.fact("headline")?.value.hasSuffix(" · no problems"), true)
        let m = CapsuleModel(); m.show(preview.document, canToggleInspector: false, canFind: false)
        XCTAssertEqual(m.dotToken, "ok")
        XCTAssertFalse(m.pillText.contains("Archive size"), "the archive's own size stays out of the pill")
    }

    func testFlaggedEntriesAreOpenedAndTinted() async throws {
        let url = dir.appendingPathComponent("evil.tar")
        try FamilyFactsTests.tar(path: "../escape.sh", body: Data("echo\n".utf8)).write(to: url)
        let (preview, outline) = try await render(url, .archive(.tar))
        XCTAssertEqual(outline.table.numberOfRows, 2, "the .. folder opened to show the entry inside it")
        let row = try XCTUnwrap(outline.table.rowView(atRow: 1, makeIfNecessary: true))
        XCTAssertEqual(String(describing: type(of: row)), "FlaggedRow")
        XCTAssertEqual(preview.document.badges.map(\.level).max(), .danger)
        XCTAssertEqual(preview.document.fact("verdict")?.value, "1 problem")
    }

    func testFindRevealsMatchesInsideClosedFolders() async throws {
        let src = dir.appendingPathComponent("src/proj/a/b")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for f in ["proj/a/b/Needle.txt", "proj/a/needle.md", "proj/other.txt"] {
            try "x\n".write(to: dir.appendingPathComponent("src/" + f), atomically: true, encoding: .utf8)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qr", dir.appendingPathComponent("f.zip").path, "proj"]
        zip.currentDirectoryURL = dir.appendingPathComponent("src")
        try zip.run(); zip.waitUntilExit()
        let (preview, outline) = try await render(dir.appendingPathComponent("f.zip"), .archive(.zip))
        XCTAssertEqual(outline.table.numberOfRows, 2, "a/ and other.txt, folders closed")
        let first = await preview.find?("NEEDLE", true)
        XCTAssertEqual(first, FindResult(count: 2, index: 0))
        let selected = outline.table.item(atRow: outline.table.selectedRow) as? ArchiveOutline.Item
        XCTAssertNotNil(selected, "the first match is selected after its folders open")
        XCTAssertGreaterThan(outline.table.numberOfRows, 2)
        let back = await preview.find?("NEEDLE", false)
        XCTAssertEqual(back, FindResult(count: 2, index: 1), "backwards wraps to the last match")
        preview.clearFind?()
        XCTAssertEqual(outline.table.selectedRow, -1)
        let none = await preview.find?("absent", true)
        XCTAssertEqual(none, FindResult(count: 0, index: -1))
    }
}
