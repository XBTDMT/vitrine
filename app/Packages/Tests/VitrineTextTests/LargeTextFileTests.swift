import XCTest
@testable import VitrineText

/// Windowed reading of huge files (S-5, code state 14): line counting with anchors, windows anywhere, streaming
/// find. All content is invented here. roadmap: S-5
final class LargeTextFileTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("vt-large-\(UUID().uuidString).sql")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: url) }

    /// Line n reads "(n, 'note n', 'Lisbon')" on every 1,000th line and "(n, 'note n')" otherwise.
    private func writeNotes(_ count: Int, trailingNewline: Bool = true) throws {
        var s = ""
        s.reserveCapacity(count * 24)
        for n in 1...count { s += n % 1_000 == 0 ? "(\(n), 'note \(n)', 'Lisbon')\n" : "(\(n), 'note \(n)')\n" }
        if !trailingNewline { s.removeLast() }
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    func testCountsLinesAndReadsAWindowAnywhere() async throws {
        try writeNotes(250_000)
        let file = try LargeTextFile(url: url)
        let before = await file.lineCount
        XCTAssertFalse(before.exact)
        try await file.index()
        let after = await file.lineCount
        XCTAssertEqual(after.count, 250_000)
        XCTAssertTrue(after.exact)

        let w = try await file.window(from: 123_457, count: 3)
        XCTAssertEqual(w.first, 123_457)
        XCTAssertEqual(w.text, "(123457, 'note 123457')\n(123458, 'note 123458')\n(123459, 'note 123459')")
        // An anchor boundary (stride 1,024) reads the same.
        let edge = try await file.window(from: 1_025, count: 1)
        XCTAssertEqual(edge.text, "(1025, 'note 1025')")
        // The last window stops at the end of the file.
        let tail = try await file.window(from: 249_999, count: 10)
        XCTAssertEqual(tail.count, 2)
    }

    func testAFileWithoutATrailingNewlineCountsItsLastLine() async throws {
        try writeNotes(3_000, trailingNewline: false)
        let file = try LargeTextFile(url: url)
        try await file.index()
        let total = await file.lineCount
        XCTAssertEqual(total.count, 3_000)
        let last = try await file.window(from: 3_000, count: 5)
        XCTAssertEqual(last.text, "(3000, 'note 3000', 'Lisbon')")
    }

    func testTheEstimateIsCloseBeforeTheCountEnds() async throws {
        try writeNotes(600_000)
        let file = try LargeTextFile(url: url)
        let seen = Box()
        try await file.index { lines, bytes in seen.append(lines, bytes) }
        XCTAssertGreaterThan(seen.steps.count, 1, "the count reports as it goes (8 MB chunks)")
        let total = await file.lineCount.count
        // The density after the first chunk predicts the total within 2 %.
        let (lines, bytes) = seen.steps[0]
        let estimate = Double(lines) / Double(bytes) * Double(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        XCTAssertEqual(estimate, Double(total), accuracy: Double(total) * 0.02)
    }

    func testFindStreamsAndNamesEachMatchingLineOnce() async throws {
        try writeNotes(600_000)
        let file = try LargeTextFile(url: url)
        let seen = Box()
        let result = try await file.find("lisbon") { p in seen.append(p.lines.count, p.bytesSearched) }
        XCTAssertTrue(result.done)
        XCTAssertEqual(result.lines.count, 600)
        XCTAssertEqual(Array(result.lines.prefix(3)), [1_000, 2_000, 3_000])
        XCTAssertEqual(result.lines.last, 600_000)
        XCTAssertGreaterThan(seen.steps.count, 1, "matches arrive before the end")
        XCTAssertLessThan(seen.steps[0].1, Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!))
        // Accents and case fold, as in the native finder.
        let accent = try await file.find("LISBÖN") { _ in }
        XCTAssertEqual(accent.lines.count, 600)
    }

    func testFindCanBeCancelled() async throws {
        try writeNotes(600_000)
        let file = try LargeTextFile(url: url)
        let task = Task { try await file.find("note") { _ in } }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled find throws")
        } catch is CancellationError {}
    }

    func testAVeryLongLineIsCutWithANote() async throws {
        try (String(repeating: "x", count: 50_000) + "\nshort\n").write(to: url, atomically: true, encoding: .utf8)
        let file = try LargeTextFile(url: url)
        let w = try await file.window(from: 1, count: 2)
        XCTAssertEqual(w.cutLines, 1)
        XCTAssertTrue(w.text.hasPrefix(String(repeating: "x", count: 20_000) + " … (30,000 more characters)"))
        XCTAssertTrue(w.text.hasSuffix("\nshort"))
    }
}

/// Progress reports, collected from a @Sendable closure.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, Int64)] = []
    func append(_ a: Int, _ b: Int64) { lock.lock(); items.append((a, b)); lock.unlock() }
    var steps: [(Int, Int64)] { lock.lock(); defer { lock.unlock() }; return items }
}
