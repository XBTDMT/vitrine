import Foundation
import XCTest
@testable import VitrineData
import VitrineSupport

/// The Parquet reader over invented files written by `TestParquet` (B-4, G-20). roadmap: S-21
final class ParquetReaderTests: XCTestCase {
    static let zones = ["Riverside", "Harbour", "University", "Waterfront", "Old Town"]

    /// Invented trips: every type the reader maps, nulls in two columns, a dictionary column.
    static func trips(_ n: Int, encoding: TestParquetColumn.Encoding = .plain) -> [TestParquetColumn] {
        let base: Int64 = 1_788_220_800_000_000   // 2026-09-01 00:00 UTC in µs
        return [
            TestParquetColumn(name: "trip_id", physical: .int64, optional: false, encoding: encoding == .dictionary ? .plain : encoding,
                              values: (0..<n).map { .int(Int64($0 + 1)) }),
            TestParquetColumn(name: "pickup_at", physical: .int64, logical: .timestamp(utc: true, unit: 2),
                              values: (0..<n).map { .int(base + Int64($0) * 120_000_000) }),
            TestParquetColumn(name: "zone", physical: .byteArray, logical: .string, encoding: .dictionary,
                              values: (0..<n).map { $0 % 11 == 5 ? .null : .string(zones[$0 % zones.count]) }),
            TestParquetColumn(name: "passengers", physical: .int32, encoding: encoding == .dictionary ? .plain : encoding,
                              values: (0..<n).map { $0 % 7 == 3 ? .null : .int(Int64($0 % 4 + 1)) }),
            TestParquetColumn(name: "distance_km", physical: .double, values: (0..<n).map { .double(Double($0 % 50) / 2 + 0.5) }),
            TestParquetColumn(name: "fare", physical: .int32, logical: .decimal(precision: 9, scale: 2),
                              values: (0..<n).map { .int(Int64(1_000 + $0 * 37 % 5_000)) }),
            TestParquetColumn(name: "paid", physical: .boolean, values: (0..<n).map { .bool($0 % 3 != 0) }),
            TestParquetColumn(name: "day", physical: .int32, logical: .date, values: (0..<n).map { .int(20_697 + Int64($0 / 100)) }),
        ]
    }

    func open(_ bytes: [UInt8]) throws -> (ParquetFile, any ColumnarTable) {
        let file = try ParquetFile(source: MemoryByteSource(bytes))
        return (file, try file.table(0))
    }

    func text(_ table: any ColumnarTable, _ window: ColumnarWindow, row: Int, column: Int) -> String {
        ColumnarText.text(window.columns[column][row], kind: table.columns[column].kind)
    }

    func testFooterFactsAndSchema() throws {
        var options = TestParquetOptions()
        options.rowGroupRows = 100
        options.keyValues = [("pandas", "{}"), ("ARROW:schema", "x")]
        let (file, table) = try open(TestParquet.file(Self.trips(250), options))
        XCTAssertEqual(table.rowCount, 250)
        XCTAssertEqual(table.chunks.map(\.rows), [100, 100, 50])
        XCTAssertEqual(table.columns.map(\.name), ["trip_id", "pickup_at", "zone", "passengers", "distance_km", "fare", "paid", "day"])
        let facts = Dictionary(uniqueKeysWithValues: file.facts.map { ($0.label, $0.value) })
        XCTAssertEqual(facts["Rows"], "250")
        XCTAssertEqual(facts["Row groups"], "3 × ~83")
        XCTAssertEqual(facts["Compression"], "UNCOMPRESSED")
        XCTAssertEqual(facts["Written by"], "vitrine-test-writer 1.0")
        XCTAssertEqual(facts["Metadata"], "pandas schema · 1 more key")
        XCTAssertEqual(table.columns[1].typeDescription, "INT64 · TIMESTAMP(µs, UTC)")
        XCTAssertEqual(table.columns[5].kind, .decimal(precision: 9, scale: 2))
        // Statistics from the footer, across the three row groups.
        XCTAssertEqual(table.columns[0].statistics?.min, "1")
        XCTAssertEqual(table.columns[0].statistics?.max, "250")
        XCTAssertEqual(table.columns[2].statistics?.min, "Harbour")
        XCTAssertEqual(table.columns[2].statistics?.max, "Waterfront")
        XCTAssertEqual(table.columns[3].statistics?.nullCount, (0..<250).filter { $0 % 7 == 3 }.count)
    }

    func testValuesAcrossRowGroupsAndPages() throws {
        var options = TestParquetOptions()
        options.rowGroupRows = 100
        options.pageRows = 30
        let (_, table) = try open(TestParquet.file(Self.trips(250), options))
        let w = try table.read(rows: 95..<130)
        XCTAssertEqual(w.count, 35)
        XCTAssertEqual(text(table, w, row: 0, column: 0), "96")
        XCTAssertEqual(text(table, w, row: 5, column: 0), "101")
        XCTAssertEqual(text(table, w, row: 0, column: 1), "2026-09-01 03:10:00")
        XCTAssertEqual(text(table, w, row: 0, column: 2), Self.zones[95 % 5])
        XCTAssertFalse(w.columns[2][5].isNull)                    // row 100: 100 % 11 == 1
        XCTAssertTrue(w.columns[3][(101 - 95)].isNull)            // row 101 % 7 == 3
        XCTAssertEqual(text(table, w, row: 0, column: 4), "23")   // 95 % 50 / 2 + 0.5
        XCTAssertEqual(text(table, w, row: 0, column: 5), "\(Self.fare(95))")
        XCTAssertEqual(text(table, w, row: 0, column: 6), "true")
        XCTAssertEqual(text(table, w, row: 0, column: 7), "2026-09-01")
        XCTAssertEqual(text(table, w, row: 10, column: 7), "2026-09-02")
        XCTAssertTrue(table.warnings.isEmpty, "\(table.warnings)")
        // Every row once, in order.
        let all = try table.read(rows: 0..<250)
        XCTAssertEqual((0..<250).map { text(table, all, row: $0, column: 0) }, (1...250).map(String.init))
        XCTAssertEqual((0..<250).filter { all.columns[2][$0].isNull }, (0..<250).filter { $0 % 11 == 5 })
    }

    static func fare(_ i: Int) -> String {
        let cents = 1_000 + i * 37 % 5_000
        return "\(cents / 100).\(String(format: "%02d", cents % 100))"
    }

    func testCompressionCodecs() throws {
        for codec: Int32 in [1, 2, 6, 7] {
            for version in [1, 2] {
                var options = TestParquetOptions()
                options.codec = codec
                options.pageVersion = version
                options.rowGroupRows = 64
                options.pageRows = 20
                let (file, table) = try open(TestParquet.file(Self.trips(150), options))
                let w = try table.read(rows: 0..<150)
                XCTAssertEqual(text(table, w, row: 149, column: 0), "150", "codec \(codec) v\(version)")
                XCTAssertEqual(text(table, w, row: 70, column: 2), Self.zones[70 % 5], "codec \(codec) v\(version)")
                XCTAssertTrue(w.columns[3][3].isNull, "codec \(codec) v\(version)")
                XCTAssertTrue(table.warnings.isEmpty, "codec \(codec) v\(version): \(table.warnings)")
                XCTAssertNotNil(file.facts.first { $0.label == "Compression" })
            }
        }
    }

    func testDeltaAndSplitEncodings() throws {
        let n = 300
        let columns = [
            TestParquetColumn(name: "id", physical: .int64, optional: false, encoding: .delta, values: (0..<n).map { .int(Int64($0 * 3 - 100)) }),
            TestParquetColumn(name: "small", physical: .int32, encoding: .delta, values: (0..<n).map { $0 % 5 == 0 ? .null : .int(Int64(($0 * 7919) % 1000)) }),
            TestParquetColumn(name: "word", physical: .byteArray, logical: .string, encoding: .delta, values: (0..<n).map { .string("w\($0 % 13)") }),
            TestParquetColumn(name: "path", physical: .byteArray, logical: .string, encoding: .deltaByteArray,
                              values: (0..<n).map { .string("/data/2026/09/\($0 / 10)/part-\($0).parquet") }),
            TestParquetColumn(name: "x", physical: .double, encoding: .byteStreamSplit, values: (0..<n).map { .double(Double($0) * 1.25) }),
            TestParquetColumn(name: "flag", physical: .boolean, optional: false, encoding: .rle, values: (0..<n).map { .bool($0 % 4 == 0) }),
        ]
        for version in [1, 2] {
            var options = TestParquetOptions()
            options.pageVersion = version
            options.pageRows = 70
            let (_, table) = try open(TestParquet.file(columns, options))
            let w = try table.read(rows: 0..<n)
            XCTAssertTrue(table.warnings.isEmpty, "\(table.warnings)")
            for i in [0, 1, 69, 70, 199, 299] {
                XCTAssertEqual(text(table, w, row: i, column: 0), "\(i * 3 - 100)")
                if i % 5 == 0 { XCTAssertTrue(w.columns[1][i].isNull) } else { XCTAssertEqual(text(table, w, row: i, column: 1), "\((i * 7919) % 1000)") }
                XCTAssertEqual(text(table, w, row: i, column: 2), "w\(i % 13)")
                XCTAssertEqual(text(table, w, row: i, column: 3), "/data/2026/09/\(i / 10)/part-\(i).parquet")
                XCTAssertEqual(text(table, w, row: i, column: 4), ColumnarText.double(Double(i) * 1.25))
                XCTAssertEqual(text(table, w, row: i, column: 5), i % 4 == 0 ? "true" : "false")
            }
        }
    }

    func testRepeatedColumnShownAsLists() throws {
        let values: [TestValue] = [.list([.int(1), .int(2)]), .list([]), .list([.int(3)]), .list((0..<100).map { .int(Int64($0)) })]
        let columns = [
            TestParquetColumn(name: "id", physical: .int32, optional: false, values: (0..<4).map { .int(Int64($0)) }),
            TestParquetColumn(name: "tags", physical: .int32, optional: false, repeated: true, values: values),
        ]
        var options = TestParquetOptions()
        options.pageRows = 2
        let (_, table) = try open(TestParquet.file(columns, options))
        XCTAssertEqual(table.columns[1].kind, .nested)
        XCTAssertEqual(table.columns[1].typeDescription, "list<INT32>")
        let w = try table.read(rows: 0..<4)
        XCTAssertEqual(text(table, w, row: 0, column: 1), "[1, 2]")
        XCTAssertEqual(text(table, w, row: 1, column: 1), "[]")
        XCTAssertEqual(text(table, w, row: 2, column: 1), "[3]")
        XCTAssertTrue(text(table, w, row: 3, column: 1).hasSuffix(", …]"))
        let last = try table.read(rows: 3..<4)
        XCTAssertEqual(text(table, last, row: 0, column: 0), "3")
        XCTAssertTrue(text(table, last, row: 0, column: 1).hasPrefix("[0, 1, 2"))
    }

    func testLegacyStatisticsUsedOnlyForSignedNumbers() throws {
        var options = TestParquetOptions()
        options.legacyStatistics = true
        let (_, table) = try open(TestParquet.file(Self.trips(40), options))
        XCTAssertEqual(table.columns[0].statistics?.max, "40")
        // The deprecated byte-array min/max sorted signed in old writers: not shown.
        XCTAssertNil(table.columns[2].statistics?.min)
    }

    func testOtherLogicalTypes() throws {
        let columns = [
            TestParquetColumn(name: "u8", physical: .int32, logical: .integer(bits: 8, signed: false), values: [.int(200), .int(7)]),
            TestParquetColumn(name: "u64", physical: .int64, logical: .integer(bits: 64, signed: false), values: [.int(-1), .int(5)]),
            TestParquetColumn(name: "id", physical: .fixed, typeLength: 16, logical: .uuid,
                              values: [.bytes(Array(0..<16)), .bytes(Array(repeating: 0xAB, count: 16))]),
            TestParquetColumn(name: "big", physical: .fixed, typeLength: 16, logical: .decimal(precision: 38, scale: 3),
                              values: [.bytes(Array(repeating: 0, count: 15) + [0x2A]), .bytes(Array(repeating: 0xFF, count: 16))]),
            TestParquetColumn(name: "small", physical: .fixed, typeLength: 4, logical: .decimal(precision: 9, scale: 2),
                              values: [.bytes([0, 0, 0x30, 0x39]), .bytes([0xFF, 0xFF, 0xFF, 0x9C])]),
            TestParquetColumn(name: "legacy_ts", physical: .int96, values: [.int(1_788_220_800_000_000_000 + 1_500), .null]),
            TestParquetColumn(name: "raw", physical: .byteArray, values: [.bytes([0xDE, 0xAD]), .bytes([])]),
            TestParquetColumn(name: "f", physical: .float, values: [.double(1.5), .double(-2)]),
            TestParquetColumn(name: "old_utf8", physical: .byteArray, convertedType: 0, values: [.string("ü"), .string("x")]),
        ]
        let (_, table) = try open(TestParquet.file(columns))
        let w = try table.read(rows: 0..<2)
        XCTAssertEqual(text(table, w, row: 0, column: 0), "200")
        XCTAssertEqual(text(table, w, row: 0, column: 1), "18446744073709551615")
        XCTAssertEqual(text(table, w, row: 0, column: 2), "00010203-0405-0607-0809-0a0b0c0d0e0f")
        XCTAssertEqual(text(table, w, row: 0, column: 3), "0.042")
        XCTAssertEqual(text(table, w, row: 1, column: 3), "-0.001")
        XCTAssertEqual(text(table, w, row: 0, column: 4), "123.45")
        XCTAssertEqual(text(table, w, row: 1, column: 4), "-1.00")
        XCTAssertEqual(text(table, w, row: 0, column: 5), "2026-09-01 00:00:00.0000015")
        XCTAssertTrue(w.columns[5][1].isNull)
        XCTAssertEqual(text(table, w, row: 0, column: 6), "dead")
        XCTAssertEqual(text(table, w, row: 0, column: 7), "1.5")
        XCTAssertEqual(text(table, w, row: 0, column: 8), "ü")
        XCTAssertEqual(table.columns[8].kind, .string)
    }

    func testWindowsNeverReadWholeFileForOneRow() throws {
        // A page that is not asked for is skipped by its header: damage a far page and read the first rows.
        var options = TestParquetOptions()
        options.pageRows = 50
        var bytes = TestParquet.file([TestParquetColumn(name: "n", physical: .int64, optional: false,
                                                        values: (0..<500).map { .int(Int64($0)) })], options)
        // The values of the last page sit just before the footer; overwrite its last value's bytes.
        let footerLength = Int(UInt32(bytes[bytes.count - 8]) | UInt32(bytes[bytes.count - 7]) << 8)
        let lastValue = bytes.count - 8 - footerLength - 8
        for k in 0..<8 { bytes[lastValue + k] = 0xEE }
        let (_, table) = try open(bytes)
        let first = try table.read(rows: 0..<10)
        XCTAssertEqual(text(table, first, row: 9, column: 0), "9")
        let last = try table.read(rows: 499..<500)
        XCTAssertNotEqual(text(table, last, row: 0, column: 0), "499")
    }
}
