import XCTest
@testable import VitrineData

/// A generated 20 MB JSON file parses into the tree within generous bounds (debug build, shared machine). The times
/// are printed for the report.
final class StructuredPerformanceTests: XCTestCase {
    /// ≈ 20 MB of invented user records, minified, one array of objects with strings, numbers, booleans, nulls and a
    /// nested array each.
    private func generate(at url: URL, targetBytes: Int) throws -> Int {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var random = SeededGenerator(seed: 0x2020)
        var buffer: [UInt8] = [UInt8(ascii: "[")]
        var written = 0
        var records = 0
        let bio = Array("Invented biography text for a placeholder account, used only to give records realistic weight. ".utf8)
        while written + buffer.count < targetBytes - 512 {
            if records > 0 { buffer.append(UInt8(ascii: ",")) }
            let id = records
            let score = Int(random.next() % 100_000)
            buffer += Array("{\"id\":\(id),\"name\":\"user-\(id)\",\"email\":\"user\(id)@example.invalid\",\"score\":\(score).\(score % 97),".utf8)
            buffer += Array("\"active\":\(id % 3 == 0),\"manager\":null,\"tags\":[\"t\(id % 7)\",\"t\(id % 11)\",\(id % 13)],\"bio\":\"".utf8)
            buffer += bio
            buffer += Array("\",\"address\":{\"city\":\"Town \(id % 500)\",\"zip\":\"\(10_000 + id % 89_999)\"}}".utf8)
            records += 1
            if buffer.count >= 4 * 1024 * 1024 {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
            }
        }
        buffer.append(UInt8(ascii: "]"))
        try handle.write(contentsOf: buffer)
        return records
    }

    func testTwentyMegabyteJSON() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("large.json")
        let records = try generate(at: url, targetBytes: 20 * 1024 * 1024)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThanOrEqual(size, 20 * 1024 * 1024 - 1024)

        let clock = ContinuousClock()
        var result: StructuredParseResult?
        // Default limits: the 500,000-node cap is reached and the parse goes on counting to the end.
        let capped = try clock.measure { result = try StructuredParser.parse(contentsOf: url) }
        let first = try XCTUnwrap(result)
        XCTAssertNil(first.error)
        XCTAssertEqual(first.tree.count, 500_000)
        XCTAssertEqual(first.sourceNodeCount, 1 + records * 15)
        XCTAssertEqual(first.coverage, .partial(shownNodes: 500_000, totalNodes: 1 + records * 15, reasons: [.nodeLimit(500_000)]))
        XCTAssertTrue(first.layout.isMinified)

        // Raised cap: every node kept.
        var options = StructuredOptions()
        options.maxNodes = 2_000_000
        let full = try clock.measure { result = try StructuredParser.parse(contentsOf: url, options: options) }
        let whole = try XCTUnwrap(result)
        XCTAssertTrue(whole.coverage.isComplete)
        XCTAssertEqual(whole.tree.count, 1 + records * 15)
        XCTAssertEqual(whole.tree[0].childCount, records)
        XCTAssertEqual(ST.node(whole, "$[\(records - 1)].address.city")?.preview, "Town \((records - 1) % 500)")

        let data = try Data(contentsOf: url)
        let format = clock.measure { _ = StructuredFormatter.json(data) }

        print("20 MB JSON (\(size) bytes, \(records) records, \(1 + records * 15) nodes): capped parse \(capped), full parse \(full), format \(format)")
        XCTAssertLessThan(capped, .seconds(60))
        XCTAssertLessThan(full, .seconds(60))
        XCTAssertLessThan(format, .seconds(60))
    }
}
