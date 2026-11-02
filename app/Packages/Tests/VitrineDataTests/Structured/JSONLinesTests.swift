import XCTest
@testable import VitrineData

/// JSON Lines: one root per line, bad lines reported by line number, paging by line-offset checkpoints.
final class JSONLinesTests: XCTestCase {
    func testOneRootPerLineAndBadLinesReported() {
        let text = "{\"id\":1}\n\n{\"id\":2,}\r\n[1,2]\n  \n\"tail\"\nnot json\n"
        let result = ST.parse(text, .jsonLines)
        XCTAssertEqual(result.dialect, .jsonLines)
        XCTAssertEqual(result.documentCount, 5)
        XCTAssertEqual(result.tree.roots.count, 5)
        let roots = result.tree.roots.map { result.tree[$0] }
        XCTAssertEqual(roots.map(\.role), [.value, .invalid, .value, .value, .invalid])
        XCTAssertEqual(roots.map { $0.span.line }, [1, 3, 4, 6, 7])
        XCTAssertEqual(roots[1].preview, "{\"id\":2,}")
        let errors = result.diagnostics.filter { $0.severity == .error }
        XCTAssertEqual(errors.map { $0.location?.description }, ["3:9", "7:1"])
        XCTAssertEqual(errors.first?.reason, "trailing comma before '}'")
        XCTAssertEqual(result.error?.location?.line, 3)
        XCTAssertTrue(result.coverage.isComplete, "bad lines are shown as lines, the tree covers every record")
        XCTAssertEqual(ST.problems(result.tree), [])
        XCTAssertEqual(result.tree.path(of: result.tree.roots[2] + 1), "$[0]")
    }

    func testSpansAreFileOffsets() throws {
        let text = "{\"a\":1}\n{\"b\":\"x\"}\n"
        let result = ST.parse(text, .jsonLines)
        let b = try XCTUnwrap(ST.node(result, "$.b"))
        XCTAssertEqual(b.span.byteOffset, 13)
        XCTAssertEqual(b.span.line, 2)
    }

    func testCutLastLineIsSkippedWhenTheInputWasTruncated() {
        let data = Data("{\"a\":1}\n{\"a\":2}\n{\"a\":".utf8)
        let result = StructuredParser.parse(data, format: .jsonLines, fileSize: 1000)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.tree.roots.count, 2)
        XCTAssertFalse(result.coverage.isComplete)
    }

    func testFileIndexAndPages() throws {
        let directory = try TemporaryDirectory()
        var lines: [String] = []
        for i in 0..<10_000 {
            lines.append(i % 1000 == 999 ? "{broken \(i)" : i % 777 == 0 ? "" : "{\"n\":\(i),\"name\":\"user-\(i)\"}")
        }
        let url = try directory.write(lines.joined(separator: "\n") + "\n", name: "log.jsonl")
        var options = StructuredOptions()
        options.lineIndexStride = 64
        let file = try JSONLinesFile.open(url, options: options)
        XCTAssertEqual(file.index.lineCount, 10_000)
        XCTAssertTrue(file.index.isComplete)
        XCTAssertEqual(file.index.checkpoints.count, 10_000 / 64 + 1)

        let page = try file.page(5_990..<6_010)
        XCTAssertEqual(page.tree.roots.count, 20)
        let first = page.tree[page.tree.roots[0]]
        XCTAssertEqual(first.span.line, 5_991)
        XCTAssertEqual(page.tree.children(of: page.tree.roots[0]).first.map { page.tree[$0].preview }, "5990")
        let bad = page.tree.roots.map { page.tree[$0] }.filter { $0.role == .invalid }
        XCTAssertEqual(bad.map { $0.span.line }, [6_000])
        XCTAssertEqual(page.error?.location?.line, 6_000)
        XCTAssertEqual(page.error?.reason, "object keys must be double-quoted strings")

        // The byte offset in a page is the file's own.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(first.span.byteOffset!))
        let raw = try XCTUnwrap(handle.read(upToCount: Int(first.span.byteLength!)))
        XCTAssertEqual(String(decoding: raw, as: UTF8.self), "{\"n\":5990,\"name\":\"user-5990\"}")

        // Blank lines keep their numbers; the end of the file ends the page.
        let blank = try file.page(776..<779)
        XCTAssertEqual(blank.tree.roots.map { blank.tree[$0].span.line }, [777, 779])
        let tail = try file.page(9_998..<20_000)
        XCTAssertEqual(tail.tree.roots.count, 2)
        XCTAssertTrue(try file.page(20_000..<20_010).tree.isEmpty)
        XCTAssertTrue(try file.page(5..<5).tree.isEmpty)
    }

    func testFileWithoutTrailingNewline() throws {
        let directory = try TemporaryDirectory()
        let url = try directory.write("{\"a\":1}\r\n{\"a\":2}", name: "two.ndjson")
        let file = try JSONLinesFile.open(url)
        XCTAssertEqual(file.index.lineCount, 2)
        let page = try file.page(0..<2)
        XCTAssertEqual(page.tree.roots.count, 2)
        XCTAssertNil(page.error)
        XCTAssertEqual(StructuredFormat(fileExtension: "ndjson"), .jsonLines)
    }
}
