import AppKit
import XCTest
@testable import VitrinePreviewKit
import VitrineSupport

/// The shared ruler on the natively drawn previews (B-7, C-8): plain text and the structured tree carry the 12 pt
/// ruler as their scroller and mark every find match at its place in the whole document. Invented files only.
/// roadmap: S-24
@MainActor
final class RulerScrollerTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-ruler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    func testPlainTextMarksEveryMatchInTheWholeText() async throws {
        let url = dir.appendingPathComponent("tides.txt")
        try (1...200).map { $0 % 50 == 0 ? "line \($0): Lisbon harbour" : "line \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let preview = try await PlainTextRenderer().render(url: url, kind: .plainText, context: RenderContext(appearance: .light, defaultsSuite: "vt-ruler"))
        preview.view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        preview.view.layoutSubtreeIfNeeded()
        let ruler = try XCTUnwrap(scrollViews(in: preview.view).first?.verticalScroller as? RulerScroller)
        XCTAssertEqual(RulerScroller.width, 12)
        let result = await preview.find!("lisbon", true)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(ruler.marks.count, 4)
        XCTAssertEqual(ruler.marks.filter { $0.kind == .current }.count, 1)
        let places = ruler.marks.map(\.at)
        XCTAssertEqual(places, places.sorted(), "top to bottom")
        XCTAssertGreaterThan(places.last ?? 0, 0.9, "the last match sits near the end of the text")
        preview.clearFind?()
        XCTAssertTrue(ruler.marks.isEmpty)
    }

    func testTheTreeMarksMatchesIncludingCollapsedOnes() async throws {
        let url = dir.appendingPathComponent("trips.json")
        let trips = (1...30).map { #"{"city": "\#($0 % 10 == 0 ? "Lisbon" : "Porto")", "days": \#($0)}"# }.joined(separator: ",")
        try #"{"trips": [\#(trips)]}"#.write(to: url, atomically: true, encoding: .utf8)
        let renderer = StructuredRenderer()
        let preview = try await renderer.render(url: url, kind: FileSniffer.kind(of: url), context: RenderContext(appearance: .light, defaultsSuite: "vt-ruler"))
        let view = try XCTUnwrap(renderer.view)
        let ruler = try XCTUnwrap(view.treeScroll.verticalScroller as? RulerScroller)
        let result = await preview.find!("Lisbon", true)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(ruler.marks.count, 3)
        XCTAssertEqual(ruler.marks.filter { $0.kind == .current }.count, 1)
        XCTAssertGreaterThan(ruler.marks.last?.at ?? 0, 0.8)
    }

    func testTheFolderListMarksMatchesInCollapsedFolders() async throws {
        let root = dir.appendingPathComponent("Lumen trip")
        for path in ["notes/lisbon-day1.md", "notes/porto.md", "photos/a.png", "photos/lisbon-harbour.png", "budget.csv"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        let preview = try await FolderRenderer().render(url: root, kind: FileSniffer.kind(of: root), context: RenderContext(appearance: .light, defaultsSuite: "vt-ruler"))
        let ruler = try XCTUnwrap(scrollViews(in: preview.view).compactMap { $0.verticalScroller as? RulerScroller }.first)
        let result = await preview.find!("lisbon", true)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(ruler.marks.count, 2, "both matches, though one sits in a folder not yet opened")
        XCTAssertEqual(ruler.marks.filter { $0.kind == .current }.count, 1)
        preview.clearFind?()
        XCTAssertTrue(ruler.marks.isEmpty)
    }
}
