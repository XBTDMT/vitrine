import AppKit
import XCTest
@testable import VitrinePreviewKit
import VitrineArchive
import VitrineSupport

/// The E-9 archives in the browse outline, and archives inside archives opened in place (S-8): the breadcrumbs name
/// each level and go back, the pill follows the level on screen, a member that cannot open says why in the gutter.
/// Archives are made by /usr/bin/zip and /usr/bin/tar (bsdtar) from invented files.
@MainActor
final class NestedArchiveTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-nested-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.currentDirectoryURL = dir
        p.environment = ["PATH": "/usr/bin:/bin"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(tool) \(arguments)")
    }

    private func write(_ name: String, _ text: String) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func render(_ name: String, _ kind: FileKind) async throws -> (RenderedPreview, ArchiveView) {
        let preview = try await ArchiveRenderer().render(url: dir.appendingPathComponent(name), kind: kind,
                                                         context: RenderContext(appearance: .light, defaultsSuite: "vt-nested"))
        let view = try XCTUnwrap(preview.view as? ArchiveView)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        return (preview, view)
    }

    private func waitFor(_ condition: () -> Bool, seconds: Double = 10) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testZipInsideAnXzTarOpensInPlaceAndBacksOut() async throws {
        try write("inner/docs/a.txt", "alpha\n")
        try write("inner/b.txt", "bravo\n")
        try run("/usr/bin/zip", ["-q", "-r", "inner.zip", "inner"])
        try write("readme.txt", "outer readme\n")
        try run("/usr/bin/tar", ["-cJf", "outer.tar.xz", "inner.zip", "readme.txt"])

        let (preview, view) = try await render("outer.tar.xz", .archive(.xz))
        XCTAssertEqual(view.pathRow.segments, ["outer.tar.xz"])
        XCTAssertEqual(preview.document.fact("format")?.value, "Tar archive (xz)")
        XCTAssertEqual(view.outline.table.numberOfRows, 2)
        let listing = view.levels[0].model.listing
        let index = try XCTUnwrap(listing.entries.firstIndex { $0.path == "inner.zip" })
        XCTAssertTrue(view.canOpen(entryIndex: index))
        XCTAssertFalse(view.canOpen(entryIndex: try XCTUnwrap(listing.entries.firstIndex { $0.path == "readme.txt" })))

        view.open(entryIndex: index)
        await waitFor { view.levels.count == 2 }
        XCTAssertEqual(view.levels.count, 2)
        // A calm nested zip with one top folder lists that folder, named after the nested archive in the path.
        XCTAssertEqual(view.pathRow.segments, ["outer.tar.xz", "inner.zip", "inner"])
        XCTAssertEqual(view.pathRow.buttons.map(\.title), ["outer.tar.xz"])
        XCTAssertEqual(preview.document.fact("format")?.value, "ZIP archive", "the pill follows the level on screen")
        XCTAssertNil(preview.gutter)

        view.pathRow.buttons[0].performClick(nil)
        XCTAssertEqual(view.levels.count, 1)
        XCTAssertEqual(view.pathRow.segments, ["outer.tar.xz"])
        XCTAssertEqual(preview.document.fact("format")?.value, "Tar archive (xz)")
    }

    func testAMemberPeeksBesideTheListAndTheDrawerFollows() async throws {
        try write("readme.txt", "outer readme\n")
        try write("notes.md", "# Lumen\n")
        try run("/usr/bin/tar", ["-cJf", "outer.tar.xz", "notes.md", "readme.txt"])
        let (_, view) = try await render("outer.tar.xz", .archive(.xz))
        let listing = view.levels[0].model.listing
        let readme = try XCTUnwrap(listing.entries.firstIndex { $0.path.hasSuffix("readme.txt") })
        view.peek(entryIndex: readme)
        XCTAssertFalse(view.drawer.isHidden)
        await view.drawer.waitForLoad()
        XCTAssertEqual(view.drawer.headerText.name, "readme.txt")
        guard case .text("outer readme\n", false, _, _)? = view.drawer.content else { return XCTFail("the member shows as text: \(String(describing: view.drawer.content))") }
        // Moving the list's selection moves the drawer.
        let notesRow = try XCTUnwrap((0..<view.outline.table.numberOfRows).first { view.outline.entryIndex(atRow: $0).map { listing.entries[$0].path.hasSuffix("notes.md") } ?? false })
        view.outline.table.selectRowIndexes([notesRow], byExtendingSelection: false)
        await view.drawer.waitForLoad()
        XCTAssertEqual(view.drawer.headerText.name, "notes.md")
        view.closePeek()
        XCTAssertTrue(view.drawer.isHidden)
    }

    func testDeleteKeyStepsOutAndReturnOpens() async throws {
        try write("inner/x.txt", "x\n")
        try run("/usr/bin/tar", ["--format", "7zip", "-cf", "inner.7z", "inner"])
        try write("other.txt", "o\n")
        try run("/usr/bin/zip", ["-q", "outer.zip", "inner.7z", "other.txt"])
        let (_, view) = try await render("outer.zip", .archive(.zip))
        let row = (0..<view.outline.table.numberOfRows).first { view.outline.entryIndex(atRow: $0).map { view.levels[0].model.listing.entries[$0].path } == "inner.7z" }
        view.outline.table.selectRowIndexes(IndexSet(integer: try XCTUnwrap(row)), byExtendingSelection: false)
        XCTAssertEqual(view.outline.onKey?(.open), true)
        await waitFor { view.levels.count == 2 }
        XCTAssertEqual(view.pathRow.segments.prefix(2), ["outer.zip", "inner.7z"])
        // libarchive gives no per-member packed size: the column says so with a dash, never a guess.
        XCTAssertEqual(view.levels[1].model.listing.entries.allSatisfy { $0.compressedSize == nil }, true)
        XCTAssertEqual(view.outline.onKey?(.back), true)
        XCTAssertEqual(view.levels.count, 1)
        XCTAssertEqual(view.outline.onKey?(.back), false, "the file itself is the bottom of the stack")
    }

    func testAMemberThatIsNotAnArchiveSaysWhyInTheGutter() async throws {
        try write("fake.zip", "this is not a zip at all\n")
        try write("other.txt", "o\n")
        try run("/usr/bin/tar", ["-cf", "outer.tar", "fake.zip", "other.txt"])
        let (preview, view) = try await render("outer.tar", .archive(.tar))
        let index = try XCTUnwrap(view.levels[0].model.listing.entries.firstIndex { $0.path == "fake.zip" })
        view.open(entryIndex: index)
        await waitFor { preview.gutter?.busy == false }
        XCTAssertEqual(view.levels.count, 1)
        XCTAssertTrue(preview.gutter?.leading?.hasPrefix("fake.zip did not open: ") == true, preview.gutter?.leading ?? "nil")
    }

    func testNewFormatsListInTheOutline() async throws {
        try write("disc/readme.txt", "on a disc\n")
        try run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-o", "disc.iso", "disc"])
        let (preview, view) = try await render("disc.iso", .archive(.iso))
        XCTAssertEqual(preview.document.fact("format")?.value, "ISO 9660 disc image")
        XCTAssertGreaterThan(view.outline.table.numberOfRows, 0)

        // A tiny archive is larger than what it holds: said plainly, never as "473% packed".
        try run("/usr/bin/tar", ["--format", "7zip", "-cf", "d.7z", "disc"])
        let (tiny, _) = try await render("d.7z", .archive(.sevenZip))
        let tinyHeadline = try XCTUnwrap(tiny.document.fact("headline")?.value)
        XCTAssertTrue(tinyHeadline.contains("no space saved"), tinyHeadline)
        // A compressible one: the whole file against what it holds.
        try write("notes/log.txt", String(repeating: "sync pushed 50 notes in 212 ms\n", count: 2_000))
        try run("/usr/bin/tar", ["--format", "7zip", "-cf", "n.7z", "notes"])
        let (sevenZip, _) = try await render("n.7z", .archive(.sevenZip))
        let headline = try XCTUnwrap(sevenZip.document.fact("headline")?.value)
        XCTAssertTrue(headline.contains("% packed"), "the whole file against what it holds: \(headline)")
        XCTAssertFalse(headline.contains("no space saved"), headline)
    }
}
