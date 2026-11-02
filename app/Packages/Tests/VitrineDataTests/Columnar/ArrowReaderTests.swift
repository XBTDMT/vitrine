import CLZ4
import Foundation
import XCTest
@testable import VitrineData
import VitrineSupport

/// The Arrow IPC reader (file, stream, Feather 2) over invented files written by `TestArrow` (B-4, G-20). roadmap: S-21
final class ArrowReaderTests: XCTestCase {
    static func columns(_ n: Int) -> [TestArrowColumn] {
        [
            TestArrowColumn(name: "id", kind: .int64, values: (0..<n).map { .int(Int64($0 + 1)) }),
            TestArrowColumn(name: "count", kind: .int32, values: (0..<n).map { $0 % 6 == 2 ? .null : .int(Int64($0 * 3)) }),
            TestArrowColumn(name: "score", kind: .float64, values: (0..<n).map { .double(Double($0) / 4) }),
            TestArrowColumn(name: "name", kind: .utf8, values: (0..<n).map { $0 % 9 == 4 ? .null : .string("item-\($0)") }),
            TestArrowColumn(name: "ok", kind: .bool, values: (0..<n).map { .bool($0 % 2 == 0) }),
            TestArrowColumn(name: "day", kind: .date32, values: (0..<n).map { .int(20_697 + Int64($0 % 30)) }),
            TestArrowColumn(name: "at", kind: .timestampMicros(zone: "UTC"), values: (0..<n).map { .int(1_788_220_800_000_000 + Int64($0) * 1_000_000) }),
            TestArrowColumn(name: "price", kind: .decimal128(precision: 10, scale: 2), values: (0..<n).map { .int(Int64($0 * 101 - 50)) }),
            TestArrowColumn(name: "tags", kind: .listInt32, values: (0..<n).map { $0 % 5 == 1 ? .null : .list((0..<($0 % 3)).map { .int(Int64($0)) }) }),
            TestArrowColumn(name: "pair", kind: .structIntUtf8, values: (0..<n).map { .list([.int(Int64($0)), .string("p\($0)")]) }),
            TestArrowColumn(name: "zone", kind: .dictionaryUtf8, values: (0..<n).map { .string(["north", "south", "east"][$0 % 3]) }),
            TestArrowColumn(name: "code", kind: .utf8View, values: (0..<n).map { .string($0 % 2 == 0 ? "short\($0)" : "a-much-longer-code-\($0)") }),
        ]
    }

    func text(_ table: any ColumnarTable, _ w: ColumnarWindow, _ row: Int, _ column: Int) -> String {
        ColumnarText.text(w.columns[column][row], kind: table.columns[column].kind)
    }

    func check(_ bytes: [UInt8], format: ColumnarFormat, file: StaticString = #filePath, line: UInt = #line) throws {
        let dataset = try ColumnarOpener.open(source: MemoryByteSource(bytes), fileExtension: format == .feather ? "feather" : "")
        XCTAssertEqual(dataset.format, format, file: file, line: line)
        let table = try dataset.table(0)
        XCTAssertEqual(table.rowCount, 100, file: file, line: line)
        XCTAssertEqual(table.chunks.map(\.rows), [40, 40, 20], file: file, line: line)
        let w = try table.read(rows: 35..<45)
        XCTAssertEqual(table.warnings, [], file: file, line: line)
        XCTAssertEqual(text(table, w, 0, 0), "36", file: file, line: line)
        XCTAssertEqual(text(table, w, 5, 0), "41", file: file, line: line)
        XCTAssertTrue(w.columns[1][38 - 35].isNull, file: file, line: line)
        XCTAssertEqual(text(table, w, 4, 1), "\(39 * 3)", file: file, line: line)
        XCTAssertEqual(text(table, w, 1, 2), "9", file: file, line: line)
        XCTAssertEqual(text(table, w, 0, 3), "item-35", file: file, line: line)
        XCTAssertTrue(w.columns[3][40 - 35].isNull, file: file, line: line)
        XCTAssertEqual(text(table, w, 0, 4), "false", file: file, line: line)
        XCTAssertEqual(text(table, w, 0, 5), "2026-09-06", file: file, line: line)
        XCTAssertEqual(text(table, w, 0, 6), "2026-09-01 00:00:35", file: file, line: line)
        XCTAssertEqual(text(table, w, 0, 7), "34.85", file: file, line: line)
        XCTAssertEqual(text(table, w, 2, 8), "[0]", file: file, line: line)          // row 37: 37 % 3 = 1 element
        XCTAssertEqual(text(table, w, 1, 8), "", file: file, line: line)             // row 36 % 5 == 1: null
        XCTAssertEqual(text(table, w, 0, 9), "{a: 35, b: \"p35\"}", file: file, line: line)
        XCTAssertEqual(text(table, w, 0, 10), "east", file: file, line: line)
        XCTAssertEqual(text(table, w, 0, 11), "a-much-longer-code-35", file: file, line: line)
        XCTAssertEqual(text(table, w, 1, 11), "short36", file: file, line: line)
        XCTAssertEqual(table.columns[10].typeDescription, "Dictionary<Int32, Utf8>", file: file, line: line)
        XCTAssertEqual(table.columns[6].typeDescription, "Timestamp(µs, UTC)", file: file, line: line)
    }

    func testFileStreamAndFeather() throws {
        try check(TestArrow.ipc(Self.columns(100), batchRows: 40, file: true), format: .arrowFile)
        try check(TestArrow.ipc(Self.columns(100), batchRows: 40, file: false), format: .arrowStream)
        try check(TestArrow.ipc(Self.columns(100), batchRows: 40, file: true), format: .feather)
    }

    func testListsAndNulls() throws {
        let dataset = try ArrowFile.open(source: MemoryByteSource(TestArrow.ipc(Self.columns(10), batchRows: 10, file: true)),
                                         limits: ColumnarLimits(), format: .arrowFile)
        let table = try dataset.table(0)
        let w = try table.read(rows: 0..<10)
        XCTAssertEqual(text(table, w, 0, 8), "[]")
        XCTAssertTrue(w.columns[8][1].isNull)
        XCTAssertEqual(text(table, w, 2, 8), "[0, 1]")
        XCTAssertEqual(text(table, w, 4, 8), "[0]")
    }

    func testCompressedBodies() throws {
        let zstd: TestArrow.Compressor = (1, TestCodecs.zstdRawFrame)
        try check(TestArrow.ipc(Self.columns(100), batchRows: 40, file: true, compressor: zstd), format: .arrowFile)
        let lz4: TestArrow.Compressor = (0, Self.lz4Frame)
        try check(TestArrow.ipc(Self.columns(100), batchRows: 40, file: false, compressor: lz4), format: .arrowStream)
        let dataset = try ColumnarOpener.open(source: MemoryByteSource(TestArrow.ipc(Self.columns(100), batchRows: 40, file: true, compressor: lz4)))
        XCTAssertEqual(dataset.facts.first { $0.label == "Compression" }?.value, "LZ4_FRAME")
    }

    /// A real LZ4 frame from the vendored library's encoder.
    static func lz4Frame(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: LZ4F_compressFrameBound(input.count, nil))
        let n = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in LZ4F_compressFrame(dst.baseAddress, dst.count, src.baseAddress, src.count, nil) }
        }
        precondition(LZ4F_isError(n) == 0)
        return Array(out.prefix(n))
    }

    func testFileWithoutFooterReadsAsStream() throws {
        var bytes = TestArrow.ipc(Self.columns(100), batchRows: 40, file: true)
        bytes.removeLast(30)
        let dataset = try ColumnarOpener.open(source: MemoryByteSource(bytes))
        XCTAssertEqual(try dataset.table(0).rowCount, 100)
        XCTAssertTrue(dataset.facts.contains { $0.label == "Footer" && $0.value.hasPrefix("missing") })
    }

    func testFeatherVersionOneRefusedByName() {
        XCTAssertThrowsError(try ColumnarOpener.open(source: MemoryByteSource(Array("FEA1".utf8) + Array(repeating: 0, count: 40)))) { error in
            XCTAssertTrue((error as? ColumnarError)?.errorDescription?.contains("Feather version 1") == true, "\(error)")
        }
    }
}
