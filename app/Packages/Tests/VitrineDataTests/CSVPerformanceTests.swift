import XCTest
@testable import VitrineData

/// ARCHITECTURE §7: first page ≤ 300 ms at any size. Measured on a generated 50 MB file with quoted fields and quoted
/// newlines. Bounds are generous (debug builds, shared CI machines); the measured times are printed for the report.
final class CSVPerformanceTests: XCTestCase {
    static let targetBytes = 50 * 1024 * 1024

    /// Writes ≈ 50 MB of invented rows: `id,sku,amount,day,note`, where every 9th note is quoted with a comma, a
    /// doubled quote and a newline. Returns the row count.
    private func generate(at url: URL) throws -> Int {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer: [UInt8] = Array("id,sku,amount,day,note\n".utf8)
        buffer.reserveCapacity(4 * 1024 * 1024 + 256)
        var written = 0
        var rows = 0
        var random = SeededGenerator(seed: 0x5EED)

        func appendNumber(_ value: Int) {
            if value >= 10 { appendNumber(value / 10) }
            buffer.append(UInt8(0x30 + value % 10))
        }
        let quotedNote = Array("\"Lot \"\"B\"\", shelf 4\nsecond line\"".utf8)
        let plainNote = Array("in stock".utf8)

        while written + buffer.count < Self.targetBytes {
            appendNumber(rows); buffer.append(0x2C)
            buffer += [0x53, 0x4B, 0x55, 0x2D]; appendNumber(Int(random.next() % 90_000) + 10_000); buffer.append(0x2C)
            appendNumber(Int(random.next() % 100_000)); buffer.append(0x2E); appendNumber(Int(random.next() % 90) + 10)
            buffer.append(0x2C)
            buffer += Array("2024-0".utf8); appendNumber(Int(random.next() % 9) + 1)
            buffer += [0x2D, 0x31]; appendNumber(Int(random.next() % 9) + 1); buffer.append(0x2C)
            buffer += rows % 9 == 0 ? quotedNote : plainNote
            buffer.append(0x0A)
            rows += 1
            if buffer.count >= 4 * 1024 * 1024 {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: buffer)
        return rows
    }

    func testFiftyMegabyteFile() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("large.csv")
        let rowCount = try generate(at: url)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThanOrEqual(size, Self.targetBytes - 1024)

        let clock = ContinuousClock()
        var table: CSVTable?
        let openTime = try clock.measure { table = try CSVTable.open(url) }
        let opened = try XCTUnwrap(table)
        XCTAssertEqual(opened.firstPage.rows.count, 200)
        XCTAssertEqual(opened.header, ["id", "sku", "amount", "day", "note"])
        XCTAssertEqual(opened.firstPage.rows[9][4], "Lot \"B\", shelf 4\nsecond line")
        XCTAssertLessThan(openTime, .milliseconds(200), "first page must be ready well inside the 300 ms budget")

        var index: CSVRowIndex?
        let indexTime = try await clock.measure { index = try await opened.buildIndex() }
        let built = try XCTUnwrap(index)
        XCTAssertTrue(built.isComplete)
        XCTAssertEqual(built.indexedRows, rowCount)
        XCTAssertEqual(built.raggedRows, 0)
        XCTAssertLessThan(indexTime, .seconds(30))

        var page: [CSVRow] = []
        let target = rowCount * 3 / 4
        let pageTime = try clock.measure { page = try opened.rows(in: target..<(target + 200), index: built) }
        XCTAssertEqual(page.count, 200)
        XCTAssertEqual(page.first?[0], String(target))
        XCTAssertEqual(page.last?[0], String(target + 199))
        XCTAssertLessThan(pageTime, .milliseconds(200))

        var profile: CSVProfile?
        let profileTime = try clock.measure { profile = try opened.profile(index: built) }
        XCTAssertEqual(profile?.columns.map(\.typeInfo.type), [.integer, .text, .decimal, .date, .text])
        XCTAssertEqual(profile?.isSample, true)

        let megabytes = Double(size) / 1_048_576
        let seconds = Double(indexTime.components.attoseconds) / 1e18 + Double(indexTime.components.seconds)
        print(String(format: "CSV perf: %.1f MB, %d rows; open + first page %@; full index %@ (%.0f MB/s); " +
                     "page at row %d %@; profile %@", megabytes, rowCount, "\(openTime)", "\(indexTime)",
                     megabytes / max(seconds, 1e-9), target, "\(pageTime)", "\(profileTime)"))
    }
}
