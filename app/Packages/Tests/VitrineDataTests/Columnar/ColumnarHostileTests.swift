import Foundation
import XCTest
@testable import VitrineData
import VitrineSupport

/// Codecs, refusals and hostile files: every lie a column file can tell ends in an error or an empty cell with a
/// warning, never a crash, a hang or a huge allocation (B-4, G-20). roadmap: S-21
final class ColumnarHostileTests: XCTestCase {
    // MARK: Codecs

    /// Python 3.14's `compression.zstd` (level 3) on the invented text below: a real entropy-coded frame.
    static let zstdFixture = "28b52ffd606c15cd0400b2040f14b025c74670e242b1cdd5e0ea5d52ca9404cee844e89842c6fdffff6ddbb6edb66ddba2630a1977f958e3a00444722c945b6ab0025c890046818fb52f2070a3623b26a1420fc20b9950841732a184f7427e1d5a44773097618c648e6119612ec318c91cc332c25c863192b919560223243137328689c04848cc81c8b08f33e201731d31c1e1be900d25bc210b657821bba1c887fa09"
    static var zstdPlain: [UInt8] { Array((0..<200).map { "row \($0 % 37) of an invented table; " }.joined().utf8) }

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var it = s.makeIterator()
        while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
        return out
    }

    func testCodecsRoundTrip() throws {
        let plain = Array((0..<3_000).map { "value \($0 % 97), " }.joined().utf8)
        XCTAssertEqual(try ColumnarCodecs.decompress(TestCodecs.snappy(plain)[...], codec: .snappy, expected: plain.count), plain)
        XCTAssertEqual(try ColumnarCodecs.decompress(TestCodecs.gzip(plain)[...], codec: .gzip, expected: plain.count), plain)
        XCTAssertEqual(try ColumnarCodecs.decompress(TestCodecs.zstdRawFrame(plain)[...], codec: .zstd, expected: plain.count), plain)
        XCTAssertEqual(try ColumnarCodecs.decompress(TestCodecs.lz4Literals(plain)[...], codec: .lz4Raw, expected: plain.count), plain)
        XCTAssertEqual(try ColumnarCodecs.decompress(Self.hex(Self.zstdFixture)[...], codec: .zstd, expected: Self.zstdPlain.count), Self.zstdPlain)
        XCTAssertEqual(try ColumnarCodecs.decompress(ArrowReaderTests.lz4Frame(plain)[...], codec: .lz4Frame, expected: plain.count), plain)
        // Hadoop-framed LZ4 (Parquet's deprecated LZ4 codec).
        let block = TestCodecs.lz4Literals(plain)
        let hadoop = [UInt8]([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: plain.count >> $0) }) + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: block.count >> $0) } + block
        XCTAssertEqual(try ColumnarCodecs.decompress(hadoop[...], codec: .lz4Hadoop, expected: plain.count), plain)
    }

    func testSnappyAndLZ4Lies() {
        // A copy before the start of the output.
        XCTAssertThrowsError(try ColumnarCodecs.snappy([10, 0x01 | (3 << 2), 9][...], expected: 10))
        // A declared length that disagrees with the page.
        XCTAssertThrowsError(try ColumnarCodecs.snappy([200, 1, 0, 0][...], expected: 4))
        // A literal longer than the block.
        XCTAssertThrowsError(try ColumnarCodecs.snappy([4, 60 << 2, 0xFF, 1, 2][...], expected: 4))
        // A varint that never ends.
        XCTAssertThrowsError(try ColumnarCodecs.snappy([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF][...], expected: 4))
        // LZ4: a match offset of zero, and one past the output.
        XCTAssertThrowsError(try ColumnarCodecs.lz4Block([0x10, 65, 0, 0, 0x00][...], expected: 10))
        XCTAssertThrowsError(try ColumnarCodecs.lz4Block([0x10, 65, 9, 0][...], expected: 10))
        // An endless run of 255 length bytes stops at the limit.
        XCTAssertThrowsError(try ColumnarCodecs.lz4Block([0xF0] + Array(repeating: 255, count: 10_000)[...], expected: 100))
        // GZIP and ZSTD that inflate to another size than declared.
        let plain = Array(repeating: UInt8(7), count: 1_000)
        XCTAssertThrowsError(try ColumnarCodecs.gzip(TestCodecs.gzip(plain)[...], expected: 999))
        XCTAssertThrowsError(try ColumnarCodecs.zstd(TestCodecs.zstdRawFrame(plain)[...], expected: 1_001))
        XCTAssertThrowsError(try ColumnarCodecs.zstd([1, 2, 3, 4][...], expected: 10))
    }

    // MARK: Parquet

    static func small() -> [UInt8] {
        TestParquet.file(ParquetReaderTests.trips(50))
    }

    func testTruncatedAndCorruptParquet() {
        let bytes = Self.small()
        // Cut short: the tail magic is gone.
        XCTAssertThrowsError(try ParquetFile(source: MemoryByteSource(Array(bytes.prefix(bytes.count - 3))))) {
            XCTAssertEqual(($0 as? ColumnarError).map { if case .truncated = $0 { true } else { false } }, true, "\($0)")
        }
        XCTAssertThrowsError(try ParquetFile(source: MemoryByteSource(Array(bytes.prefix(10)))))
        XCTAssertThrowsError(try ParquetFile(source: MemoryByteSource([])))
        // A footer length larger than the file.
        var lying = bytes
        lying.replaceSubrange((lying.count - 8)..<(lying.count - 4), with: TestBytes.le32(0x7FFF_FFF0))
        XCTAssertThrowsError(try ParquetFile(source: MemoryByteSource(lying))) { XCTAssertTrue("\($0)".contains("claims"), "\($0)") }
        // Encrypted footers are named.
        var encrypted = bytes
        encrypted.replaceSubrange((encrypted.count - 4)..<encrypted.count, with: Array("PARE".utf8))
        XCTAssertThrowsError(try ParquetFile(source: MemoryByteSource(encrypted))) {
            XCTAssertTrue(($0 as? ColumnarError)?.errorDescription?.contains("encrypted") == true)
        }
        // Every single-byte change in the footer either opens or throws; none crashes.
        let footerLength = Int(UInt32(bytes[bytes.count - 8]) | UInt32(bytes[bytes.count - 7]) << 8)
        let footerStart = bytes.count - 8 - footerLength
        for i in stride(from: footerStart, to: bytes.count - 8, by: 1) {
            for value: UInt8 in [0x00, 0xFF, 0x7F, bytes[i] ^ 0x15] {
                var damaged = bytes
                damaged[i] = value
                if let file = try? ParquetFile(source: MemoryByteSource(damaged)), let table = try? file.table(0) {
                    _ = try? table.read(rows: 0..<table.rowCount)
                }
            }
        }
    }

    func testEveryByteOfThePagesDamagedStillReads() throws {
        var options = TestParquetOptions()
        options.codec = 1
        options.pageRows = 16
        let bytes = TestParquet.file(ParquetReaderTests.trips(64), options)
        let footerLength = Int(UInt32(bytes[bytes.count - 8]) | UInt32(bytes[bytes.count - 7]) << 8)
        let dataEnd = bytes.count - 8 - footerLength
        for i in stride(from: 4, to: dataEnd, by: 3) {
            var damaged = bytes
            damaged[i] ^= 0xA5
            let file = try ParquetFile(source: MemoryByteSource(damaged))
            let table = try file.table(0)
            let w = try table.read(rows: 0..<64)
            XCTAssertEqual(w.count, 64)
            XCTAssertEqual(w.columns.count, 8)
            XCTAssertTrue(w.columns.allSatisfy { $0.count == 64 })
        }
    }

    func testOversizedClaimsAreRefused() throws {
        // A page header claiming a 2 GB page.
        var t = TestThrift()
        t.i32(1, 0); t.i32(2, Int32.max); t.i32(3, 10)
        t.begin(5); t.i32(1, 1); t.i32(2, 0); t.end()
        t.bytes.append(0)
        let page = t.bytes + Array(repeating: 0, count: 10)
        let normal = TestParquet.file([TestParquetColumn(name: "n", physical: .int64, optional: false, values: [.int(1)])])
        // Splice: keep the footer, replace the page bytes in place (same length budget is not needed: offsets are read
        // from the footer, and the claim is refused before any read past the file).
        let footerLength = Int(UInt32(normal[normal.count - 8]) | UInt32(normal[normal.count - 7]) << 8)
        let footer = Array(normal[(normal.count - 8 - footerLength)...])
        let spliced = Array("PAR1".utf8) + page + Array(repeating: 0, count: max(0, normal.count - 8 - footerLength - 4 - page.count)) + footer
        if let file = try? ParquetFile(source: MemoryByteSource(spliced)) {
            let table = try file.table(0)
            _ = try table.read(rows: 0..<1)
            XCTAssertTrue(table.warnings.contains { $0.contains("could not be read") }, "\(table.warnings)")
        }
        // A schema whose root claims a million children.
        var s = TestThrift()
        s.i32(1, 1)
        s.listHeader(2, type: 12, count: 1)
        s.beginElement(); s.string(4, "schema"); s.i32(5, 1_000_000); s.end()
        s.i64(3, 0)
        s.listHeader(4, type: 12, count: 0)
        s.bytes.append(0)
        let file = Array("PAR1".utf8) + s.bytes + TestBytes.le32(UInt32(s.bytes.count)) + Array("PAR1".utf8)
        XCTAssertThrowsError(try ParquetFile(source: MemoryByteSource(file)))
        // A list header claiming more elements than bytes.
        var l = TestThrift()
        l.listHeader(2, type: 12, count: 50_000_000)
        l.bytes.append(0)
        let listFile = Array("PAR1".utf8) + l.bytes + TestBytes.le32(UInt32(l.bytes.count)) + Array("PAR1".utf8)
        XCTAssertThrowsError(try ParquetFile(source: MemoryByteSource(listFile)))
        // Structures nested past the depth limit.
        var deep = TestThrift()
        for _ in 0..<200 { deep.begin(1) }
        for _ in 0..<200 { deep.end() }
        deep.bytes.append(0)
        let deepFile = Array("PAR1".utf8) + deep.bytes + TestBytes.le32(UInt32(deep.bytes.count)) + Array("PAR1".utf8)
        XCTAssertThrowsError(try ParquetFile(source: MemoryByteSource(deepFile)))
    }

    func testRowCountMismatchAndBadCodecNamed() throws {
        // Unsupported codecs are named on the column, the rest of the table reads.
        var bytes = TestParquet.file([TestParquetColumn(name: "n", physical: .int64, optional: false, values: [.int(1), .int(2)])])
        // The codec field (4) is written as i32 0 in the column metadata: header byte 0x15 then zigzag(0) = 0x00 right
        // after the path list. Find "n" in the footer's path list and patch the following codec value to BROTLI (4).
        let footerLength = Int(UInt32(bytes[bytes.count - 8]) | UInt32(bytes[bytes.count - 7]) << 8)
        let start = bytes.count - 8 - footerLength
        if let at = (start..<(bytes.count - 9)).first(where: { bytes[$0] == 0x15 && bytes[$0 + 1] == 0x00 && bytes[$0 - 1] == UInt8(ascii: "n") }) {
            bytes[at + 1] = 0x08   // zigzag(4)
        }
        let file = try ParquetFile(source: MemoryByteSource(bytes))
        let table = try file.table(0)
        let w = try table.read(rows: 0..<2)
        XCTAssertTrue(w.columns[0][0].isNull)
        XCTAssertTrue(table.warnings.contains { $0.contains("BROTLI") }, "\(table.warnings)")
    }

    // MARK: Arrow

    func testArrowDamageNeverCrashes() throws {
        let bytes = TestArrow.ipc(ArrowReaderTests.columns(20), batchRows: 8, file: true)
        for i in stride(from: 0, to: bytes.count, by: 5) {
            for value: UInt8 in [0xFF, bytes[i] ^ 0x5A] {
                var damaged = bytes
                damaged[i] = value
                if let dataset = try? ColumnarOpener.open(source: MemoryByteSource(damaged)), let table = try? dataset.table(0) {
                    if let w = try? table.read(rows: 0..<table.rowCount) {
                        XCTAssertTrue(w.columns.allSatisfy { $0.count == w.count })
                    }
                }
            }
        }
        // Truncated at every eighth byte.
        for n in stride(from: 0, to: bytes.count, by: 8) {
            if let dataset = try? ColumnarOpener.open(source: MemoryByteSource(Array(bytes.prefix(n))), fileExtension: "arrow"),
               let table = try? dataset.table(0) {
                _ = try? table.read(rows: 0..<table.rowCount)
            }
        }
    }

    func testArrowOversizedClaims() {
        // A message claiming a 1.9 GB header.
        let stream = TestBytes.le32(0xFFFF_FFFF) + TestBytes.le32(0x7000_0000) + Array(repeating: 0, count: 64)
        XCTAssertThrowsError(try ColumnarOpener.open(source: MemoryByteSource(stream)))
        // A file footer longer than the file.
        let file = Array("ARROW1".utf8) + [0, 0] + Array(repeating: 0, count: 16) + TestBytes.le32(0x0FFF_FFFF) + Array("ARROW1".utf8)
        XCTAssertThrowsError(try ColumnarOpener.open(source: MemoryByteSource(file)))
        // FlatBuffers offsets outside the buffer.
        XCTAssertThrowsError(try FlatTable.root([0xFF, 0xFF, 0xFF, 0x7F]))
        XCTAssertThrowsError(try FlatTable(bytes: [8, 0, 0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0], position: 8))
    }

    // MARK: xlsx

    func testWorkbookDamageNeverCrashes() {
        let bytes = XLSXReaderTests.book()
        for i in stride(from: 0, to: bytes.count, by: 7) {
            var damaged = bytes
            damaged[i] ^= 0x41
            if let book = try? XLSXWorkbook(source: MemoryByteSource(damaged)) {
                for p in book.parts.indices { if let t = try? book.table(p) { _ = try? t.read(rows: 0..<t.rowCount) } }
            }
        }
    }

    // MARK: SQL over a column table

    func testQueryCopy() throws {
        let file = try ParquetFile(source: MemoryByteSource(TestParquet.file(ParquetReaderTests.trips(120))))
        let engine = try SQLiteQueryEngine.columnar(try file.table(0), name: "trips.parquet")
        let result = try engine.run("SELECT zone, count(*) AS n, sum(passengers) FROM trips WHERE paid GROUP BY zone ORDER BY n DESC, zone LIMIT 2")
        XCTAssertEqual(result.columns.map(\.name), ["zone", "n", "sum(passengers)"])
        XCTAssertEqual(result.rows.count, 2)
        let dates = try engine.run("SELECT min(day), max(pickup_at), max(fare) FROM t")
        XCTAssertEqual(dates.rows.first?.first?.display, "2026-09-01")
        let maxFare = Double((0..<120).map { 1_000 + $0 * 37 % 5_000 }.max()!) / 100
        XCTAssertEqual(dates.rows.first?[2].display, SQLiteValue.real(maxFare).display)
        XCTAssertEqual(dates.rows.first?[1].display, "2026-09-01 03:58:00")
        var limits = ColumnarLimits()
        limits.maxQueryCells = 100
        XCTAssertThrowsError(try SQLiteQueryEngine.columnar(try file.table(0), name: "trips.parquet", columnarLimits: limits)) {
            XCTAssertTrue("\($0)".contains("cells"), "\($0)")
        }
    }
}
