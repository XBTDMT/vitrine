import AppKit
import XCTest
@testable import VitrinePreviewKit

/// Folder contents on Finder's icon for chosen folders (O-3, G-18): choose writes the custom icon, a change to the
/// newest items redraws it, an unchanged folder is left alone, unchoose puts the plain icon back. Invented folders in
/// a temporary directory only; a private defaults suite. roadmap: S-9
@MainActor
final class FolderContentIconsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        suite = "vt-folder-icons-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-icons-\(UUID().uuidString)/Lumen trip")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        return dir
    }

    private func write(_ name: String, in dir: URL, at seconds: Double) throws {
        let url = dir.appendingPathComponent(name)
        try "Packing list: Kyoto".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    func testChooseRefreshAndUnchoose() throws {
        let dir = try folder()
        try write("packing.txt", in: dir, at: 1_790_000_000)
        XCTAssertFalse(FolderContentIcons.hasCustomIcon(dir))

        try FolderContentIcons.choose(dir, defaults: defaults)
        XCTAssertTrue(FolderContentIcons.hasCustomIcon(dir), "the custom icon file is written")
        XCTAssertEqual(FolderContentIcons.chosen(defaults).map(\.path), [dir.path])
        XCTAssertEqual(FolderContentIcons.refresh(defaults: defaults), [], "nothing changed, nothing redrawn")

        try write("itinerary.txt", in: dir, at: 1_790_000_600)
        XCTAssertEqual(FolderContentIcons.refresh(defaults: defaults).map(\.path), [dir.path], "a newer item redraws the icon")
        XCTAssertEqual(FolderContentIcons.refresh(defaults: defaults), [])

        FolderContentIcons.remove(from: dir)
        XCTAssertEqual(FolderContentIcons.refresh(defaults: defaults).map(\.path), [dir.path], "an icon removed outside Vitrine comes back while chosen")

        FolderContentIcons.unchoose(dir, defaults: defaults)
        XCTAssertFalse(FolderContentIcons.hasCustomIcon(dir), "the plain icon is back")
        XCTAssertEqual(FolderContentIcons.chosen(defaults), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["itinerary.txt", "packing.txt"],
                       "nothing of Vitrine's is left in the folder")
    }

    func testTheIconsOwnFileDoesNotCountAsContent() throws {
        let dir = try folder()
        try write("packing.txt", in: dir, at: 1_790_000_000)
        let before = FolderContentIcons.signature(of: dir)
        try FolderContentIcons.apply(to: dir)
        XCTAssertEqual(FolderContentIcons.signature(of: dir), before)
    }

    func testANewLookRedrawsEveryChosenFolder() throws {
        let dir = try folder()
        try write("packing.txt", in: dir, at: 1_790_000_000)
        try FolderContentIcons.choose(dir, defaults: defaults)
        XCTAssertEqual(FolderContentIcons.refresh(defaults: defaults), [])
        defaults.set("grid", forKey: FolderContentIcons.styleKey)
        XCTAssertEqual(FolderContentIcons.refresh(defaults: defaults).map(\.path), [dir.path])
        FolderContentIcons.unchoose(dir, defaults: defaults)
    }

    func testOnlyFoldersAreWritten() throws {
        let dir = try folder()
        try write("packing.txt", in: dir, at: 1_790_000_000)
        XCTAssertThrowsError(try FolderContentIcons.choose(dir.appendingPathComponent("packing.txt"), defaults: defaults)) { error in
            guard case FolderContentIcons.Failure.notAFolder = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(FolderContentIcons.chosen(defaults), [])
    }
}
