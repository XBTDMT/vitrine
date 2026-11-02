import XCTest
@testable import VitrineArchive

/// ARCHITECTURE §7: a listing is part of the first paint. The bounds are generous (debug build, shared CI
/// machines); the measured times are printed for the record.
final class PerformanceTests: XCTestCase {
    func testTwentyThousandEntryZip() throws {
        let folder = try FixtureFolder()
        var builder = ZipBuilder()
        builder.entries = (0..<20_000).map { i in
            ZipBuilder.Entry("dept-\(i % 40)/team-\(i % 7)/record-\(i).txt", data: Array("row \(i)\n".utf8))
        }
        try folder.write("many.zip", Data(builder.build()))
        // The builder's bytes are a real zip: Info-ZIP's own lister agrees on the count.
        let names = try folder.run("/usr/bin/zipinfo", ["-1", "many.zip"])
        XCTAssertEqual(String(decoding: names, as: UTF8.self).split(separator: "\n").count, 20_000)

        let clock = ContinuousClock()
        var listing: ArchiveListing?
        let listTime = try clock.measure { listing = try folder.list("many.zip") }
        let result = try XCTUnwrap(listing)
        XCTAssertEqual(result.entries.count, 20_000)
        XCTAssertTrue(result.coverage.isComplete)

        var summary: ArchiveSummary?, tree: ArchiveTree?, report: SafetyReport?
        let deriveTime = clock.measure {
            summary = ArchiveSummary(result)
            tree = ArchiveTree(entries: result.entries)
            report = ArchiveSafety.scan(result)
        }
        XCTAssertEqual(summary?.fileCount, 20_000)
        XCTAssertEqual(summary?.folderCount, 40 + 280)
        XCTAssertEqual(tree?.root.descendantCount, 20_000)
        XCTAssertEqual(report?.isClean, true)

        print("VitrineArchive perf: list 20,000-entry zip \(listTime); summary + tree + safety \(deriveTime)")
        XCTAssertLessThan(listTime, .seconds(2))
        XCTAssertLessThan(deriveTime, .seconds(4))
    }

    func testTwentyThousandEntryTar() throws {
        var tar = TarBuilder()
        for i in 0..<20_000 { tar.header("set-\(i % 50)/item-\(i).dat", size: 10); tar.data([UInt8](repeating: 7, count: 10)) }
        tar.end()
        let source = DataByteSource(tar.bytes)
        let clock = ContinuousClock()
        var listing: ArchiveListing?
        let time = try clock.measure { listing = try TarReader.list(source: source) }
        XCTAssertEqual(listing?.entries.count, 20_000)
        print("VitrineArchive perf: list 20,000-entry tar \(time)")
        XCTAssertLessThan(time, .seconds(3))
    }
}
