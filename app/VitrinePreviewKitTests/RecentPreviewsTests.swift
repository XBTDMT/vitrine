import XCTest
import VitrineDocument
import VitrineSupport
@testable import VitrinePreviewKit

/// The menu bar's recents store (H-2, roadmap: S-10): bounded, newest first, paths and counts only, pausable,
/// clearable. Every test uses a private defaults suite and invented files in a temporary folder.
final class RecentPreviewsTests: XCTestCase {
    private var suite: String!
    private var store: RecentPreviews!
    private var dir: URL!

    override func setUpWithError() throws {
        suite = "vt-recents-test-\(UUID().uuidString)"
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-recents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = RecentPreviews(directories: [box], writeDirectory: box, suite: suite)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    /// The extension's container folder the store writes into.
    private var box: URL { dir.appendingPathComponent("container-markdown") }

    private func file(_ name: String, _ text: String = "x\n") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testNewestFirstAndARepeatMovesUp() throws {
        let a = try file("a.md"), b = try file("b.csv")
        store.record(a, kind: "Markdown", facts: "Markdown", at: Date(timeIntervalSince1970: 1))
        store.record(b, kind: "CSV", facts: "CSV", at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(store.entries().map(\.name), ["b.csv", "a.md"])
        store.record(a, kind: "Markdown", facts: "Markdown", at: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(store.entries().map(\.name), ["a.md", "b.csv"], "a repeat moves up, never appears twice")
        XCTAssertEqual(store.entries().first?.time, Date(timeIntervalSince1970: 3))
    }

    func testCappedAtTen() throws {
        for i in 0..<25 { store.record(try file("f\(i).txt"), kind: "Text", facts: "Text") }
        let names = store.entries().map(\.name)
        XCTAssertEqual(names.count, RecentPreviews.capacity)
        XCTAssertEqual(names.first, "f24.txt")
        XCTAssertEqual(names.last, "f15.txt")
    }

    func testStandardizedPathIsOneEntry() throws {
        let a = try file("a.md")
        store.record(a, kind: "Markdown", facts: "Markdown")
        store.record(dir.appendingPathComponent("./a.md"), kind: "Markdown", facts: "Markdown")
        XCTAssertEqual(store.entries().count, 1)
    }

    func testPauseStopsRecordingAndKeepsTheList() throws {
        store.record(try file("kept.md"), kind: "Markdown", facts: "Markdown")
        XCTAssertTrue(store.isRecording, "recording is on by default")
        store.isRecording = false
        store.record(try file("ignored.md"), kind: "Markdown", facts: "Markdown")
        XCTAssertEqual(store.entries().map(\.name), ["kept.md"])
        store.isRecording = true
        store.record(try file("again.md"), kind: "Markdown", facts: "Markdown")
        XCTAssertEqual(store.entries().map(\.name), ["again.md", "kept.md"])
    }

    func testClearAndForget() throws {
        let a = try file("a.md"), b = try file("b.md")
        store.record(a, kind: "Markdown", facts: "Markdown")
        store.record(b, kind: "Markdown", facts: "Markdown")
        store.forget(path: b.standardizedFileURL.path)
        XCTAssertEqual(store.entries().map(\.name), ["a.md"])
        store.clear()
        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.appendingPathComponent(RecentPreviews.fileName).path))
    }

    func testMissingFilesDropOutOfTheMenuButStayListed() throws {
        let gone = try file("gone.md"), here = try file("here.md")
        store.record(gone, kind: "Markdown", facts: "Markdown")
        store.record(here, kind: "Markdown", facts: "Markdown")
        try FileManager.default.removeItem(at: gone)
        XCTAssertEqual(store.existingEntries().map(\.name), ["here.md"])
        XCTAssertEqual(store.entries().count, 2)
    }

    func testGarbageReadsAsEmpty() {
        try? FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: box.appendingPathComponent(RecentPreviews.fileName))
        XCTAssertTrue(store.entries().isEmpty)
        try? Data("42".utf8).write(to: box.appendingPathComponent(RecentPreviews.fileName))
        XCTAssertTrue(store.entries().isEmpty)
    }

    /// The store never holds a byte of the file: only the path, the kind, counts and the time.
    func testNothingFromTheFileIsStored() throws {
        let secret = "SECRET_TOKEN_sk_live_EXAMPLE_0000"
        let url = try file("notes.md", "# \(secret)\n\(secret)\n")
        let document = PreviewDocument(kind: .markdown(.commonMark), facts: [
            Fact(key: "lines", label: "Lines", value: "2"),
            Fact(key: "starts", label: "Starts with", value: "“# \(secret)”"),
            Fact(key: "headline", label: "Summary", value: secret),
            Fact(key: "rows", label: "Rows", value: secret),   // a count key carrying words is refused too
        ], views: [.text("# \(secret)\n")])
        store.record(url, document: document)
        let raw = try Data(contentsOf: box.appendingPathComponent(RecentPreviews.fileName))
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains("SECRET"), text)
        XCTAssertEqual(store.entries().first?.facts, "Markdown · 2 lines")
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [[String: Any]]).first!.keys),
                       ["path", "kind", "facts", "time"])
    }

    func testFactsLine() {
        func line(_ facts: [Fact], kind: FileKind = .markdown(.commonMark)) -> String {
            RecentPreviews.factsLine(for: PreviewDocument(kind: kind, facts: facts, views: [.text("")]))
        }
        XCTAssertEqual(line([Fact(key: "lines", label: "Lines", value: "412"), Fact(key: "tokens", label: "Tokens", value: "≈ 3,201")]),
                       "Markdown · 412 lines · ≈ 3,201 tokens")
        XCTAssertEqual(line([Fact(key: "rows", label: "Rows", value: "12,480"), Fact(key: "size", label: "Size", value: "1.2 MB")], kind: .csv(delimiter: ",")),
                       "CSV · 12,480 rows", "a count wins over the size")
        XCTAssertEqual(line([Fact(key: "size", label: "Size", value: "3 KB")]), "Markdown · 3 KB", "the size when there is no count")
        XCTAssertEqual(line([Fact(key: "size", label: "Size", value: "Zero KB")]), "Markdown", "a size in words is dropped")
        XCTAssertEqual(line([]), "Markdown")
        XCTAssertEqual(line([Fact(key: "lines", label: "Lines", value: "1"), Fact(key: "files", label: "Files", value: "2"),
                             Fact(key: "tokens", label: "Tokens", value: "3")]), "Markdown · 1 lines · 2 files", "at most two counts")
    }

    /// The app reads every extension's file; the newest entry for a path wins; Clear and Forget reach all of them.
    func testTheAppMergesEveryExtensionsListAndClearsThemAll() throws {
        let code = dir.appendingPathComponent("container-code")
        let markdownStore = store!, codeStore = RecentPreviews(directories: [code], writeDirectory: code, suite: suite)
        let a = try file("a.md"), b = try file("b.swift"), c = try file("c.md")
        markdownStore.record(a, kind: "Markdown", facts: "Markdown", at: Date(timeIntervalSince1970: 1))
        codeStore.record(b, kind: "Swift", facts: "Swift", at: Date(timeIntervalSince1970: 2))
        markdownStore.record(c, kind: "Markdown", facts: "Markdown", at: Date(timeIntervalSince1970: 3))
        codeStore.record(a, kind: "Markdown", facts: "Markdown · 1 lines", at: Date(timeIntervalSince1970: 4))
        let app = RecentPreviews(directories: [box, code], writeDirectory: nil, suite: suite)
        XCTAssertEqual(app.entries().map(\.name), ["a.md", "c.md", "b.swift"], "merged, newest first, one entry per path")
        XCTAssertEqual(app.entries().first?.facts, "Markdown · 1 lines")
        app.record(b, kind: "Swift", facts: "Swift", at: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(app.entries().first?.name, "a.md", "the app never records")
        app.forget(path: a.standardizedFileURL.path)
        XCTAssertEqual(app.entries().map(\.name), ["c.md", "b.swift"], "forget reaches every extension's list")
        app.clear()
        XCTAssertTrue(app.entries().isEmpty)
        XCTAssertTrue(markdownStore.entries().isEmpty && codeStore.entries().isEmpty)
    }

    func testOnlyAQuickLookExtensionRecords() {
        XCTAssertTrue(RecentPreviews.isQuickLookExtension(bundlePath: "/Applications/Vitrine.app/Contents/PlugIns/VitrineMarkdown.appex"))
        XCTAssertFalse(RecentPreviews.isQuickLookExtension(bundlePath: "/Applications/Vitrine.app"))
        XCTAssertFalse(RecentPreviews.isQuickLookExtension(bundlePath: Bundle.main.bundlePath), "the test runner is not an extension")
    }

    /// End to end: a preview embedded by the real controller lands in the recorder, with its kind and counts.
    @MainActor func testTheControllerRecordsWhatItShows() async throws {
        let before = RecentPreviews.processRecorder
        XCTAssertNil(before, "outside an extension nothing records, so tests never touch the real suite")
        RecentPreviews.processRecorder = store
        defer { RecentPreviews.processRecorder = before }
        let url = try file("shown.txt", "one\ntwo\nthree\n")
        let controller = PreviewHostController()
        controller.loadView()
        try await controller.preparePreviewOfFile(at: url)
        let entry = try XCTUnwrap(store.entries().first)
        XCTAssertEqual(entry.path, url.standardizedFileURL.path)
        let kind = FileSniffer.kind(of: url).displayName
        XCTAssertEqual(entry.kind, kind)
        XCTAssertEqual(entry.facts, "\(kind) · 3 lines")
    }
}
