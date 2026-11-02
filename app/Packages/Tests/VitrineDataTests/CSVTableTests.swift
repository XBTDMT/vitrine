import XCTest
@testable import VitrineData

/// Opening, the first page, the row index and paging, on generated files.
final class CSVTableTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws { directory = try TemporaryDirectory() }
    override func tearDown() { directory = nil }

    /// `count` rows of invented data; every 7th note holds a quoted newline, every 11th a doubled quote, every 13th
    /// a comma. Returns the file text and the expected fields per data row.
    private func fixture(rows count: Int, lineEnding: String = "\n") -> (text: String, rows: [[String]]) {
        var text = "id,label,note" + lineEnding
        var rows: [[String]] = []
        for i in 0..<count {
            var note = "n\(i)"
            if i % 7 == 0 { note = "first line \(i)\nsecond line" }
            if i % 11 == 0 { note = "says \"hi\" \(i)" }
            if i % 13 == 0 { note = "a, b \(i)" }
            let quoted = note.contains("\n") || note.contains("\"") || note.contains(",")
            let written = quoted ? "\"" + note.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : note
            text += "\(i),item-\(i % 97),\(written)" + lineEnding
            rows.append(["\(i)", "item-\(i % 97)", note])
        }
        return (text, rows)
    }

    private func smallOptions() -> CSVOptions {
        var options = CSVOptions()
        options.indexStride = 16
        options.firstPageRows = 20
        options.readChunkBytes = 4096
        options.pageChunkBytes = 4096
        return options
    }

    func testSmallFileIsCompleteFromTheFirstPage() throws {
        let url = try directory.write("name,qty\nbolt,3\nnut,10\n")
        let table = try CSVTable.open(url)
        XCTAssertEqual(table.header, ["name", "qty"])
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.firstPage.rows.map(\.fields), [["bolt", "3"], ["nut", "10"]])
        XCTAssertTrue(table.firstPage.reachesEndOfFile)
        XCTAssertEqual(table.rowCount(index: nil), .exactly(2))
        XCTAssertEqual(table.coverage(index: nil), .complete(rows: 2))
        XCTAssertEqual(try table.rows(in: 1..<5), [table.firstPage.rows[1]])
    }

    func testExactlyOnePageIsKnownComplete() throws {
        var options = CSVOptions()
        options.firstPageRows = 3
        let url = try directory.write("a\n1\n2\n3\n")
        let table = try CSVTable.open(url, options: options)
        XCTAssertEqual(table.firstPage.rows.count, 3)
        XCTAssertTrue(table.firstPage.reachesEndOfFile)
        let longer = try CSVTable.open(try directory.write("a\n1\n2\n3\n4\n", name: "b.csv"), options: options)
        XCTAssertFalse(longer.firstPage.reachesEndOfFile)
        XCTAssertEqual(longer.rowCount(index: nil), .atLeast(3))
        XCTAssertEqual(longer.coverage(index: nil), .partial(shownRows: 3, totalRows: nil, reason: .firstPageOnly))
    }

    func testFileWithoutHeader() throws {
        let url = try directory.write("1,2.5\n2,3.5\n3,4.5\n")
        let table = try CSVTable.open(url)
        XCTAssertNil(table.header)
        XCTAssertEqual(table.firstPage.rows.count, 3)
        XCTAssertEqual(table.columnTitle(1), "Column 2")
        XCTAssertEqual(table.dataStartOffset, 0)
    }

    func testBOMIsNotPartOfTheFirstHeader() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("name,qty\r\nbolt,3\r\n".utf8))
        let table = try CSVTable.open(try directory.write(data))
        XCTAssertEqual(table.header, ["name", "qty"])
        XCTAssertEqual(table.dataStartOffset, 13)
        XCTAssertEqual(table.firstPage.rows.first?.offset, 13)
    }

    func testTSVExtensionHint() throws {
        let url = try directory.write("a\tb\n1\t2\n", name: "fixture.tsv")
        XCTAssertEqual(try CSVTable.open(url).dialect.delimiter, .tab)
    }

    func testIndexAndPagingMatchAFullParse() async throws {
        let (text, expected) = fixture(rows: 1000)
        let table = try CSVTable.open(try directory.write(text), options: smallOptions())
        XCTAssertEqual(table.firstPage.rows.map(\.fields), Array(expected.prefix(20)))
        XCTAssertFalse(table.firstPage.reachesEndOfFile)

        let index = try await table.buildIndex(options: smallOptions())
        XCTAssertTrue(index.isComplete)
        XCTAssertEqual(index.indexedRows, 1000)
        XCTAssertEqual(index.rowCount, .exactly(1000))
        XCTAssertEqual(index.checkpoints.count, 63)   // rows 0, 16, …, 992
        XCTAssertEqual(index.raggedRows, 0)
        XCTAssertEqual(table.rowCount(index: index), .exactly(1000))
        XCTAssertEqual(table.coverage(index: index), .complete(rows: 1000))

        // Every checkpoint is where the parser starts that row, even right after quoted newlines.
        let all = CSVTestParse.records(Array(text.utf8)).rows.dropFirst()
        for (k, offset) in index.checkpoints.enumerated() {
            XCTAssertEqual(offset, all[all.startIndex + k * 16].offset, "checkpoint \(k)")
        }

        for range in [0..<5, 15..<17, 16..<32, 500..<537, 990..<1000, 995..<1010, 1000..<1003] {
            let rows = try table.rows(in: range, index: index)
            let upper = min(range.upperBound, 1000)
            XCTAssertEqual(rows.map(\.fields), Array(expected[min(range.lowerBound, upper)..<upper]), "\(range)")
        }
        // Without an index rows are still right, reached by scanning on from the first page.
        XCTAssertEqual(try table.rows(in: 300..<302).map(\.fields), Array(expected[300..<302]))
    }

    func testCRLFFileIndexes() async throws {
        let (text, expected) = fixture(rows: 300, lineEnding: "\r\n")
        let table = try CSVTable.open(try directory.write(text), options: smallOptions())
        XCTAssertEqual(table.dialect.lineEnding, .crlf)
        let index = try await table.buildIndex(options: smallOptions())
        XCTAssertEqual(index.indexedRows, 300)
        XCTAssertEqual(try table.rows(in: 250..<260, index: index).map(\.fields), Array(expected[250..<260]))
    }

    func testRaggedRowsAreCountedAndKept() async throws {
        var text = "a,b,c\n"
        for i in 0..<100 { text += i % 10 == 3 ? "\(i),x\n" : i == 50 ? "\(i),x,y,z\n" : "\(i),x,y\n" }
        let table = try CSVTable.open(try directory.write(text), options: smallOptions())
        XCTAssertEqual(table.firstPage.raggedRows, 2)   // rows 3 and 13
        let index = try await table.buildIndex(options: smallOptions())
        XCTAssertEqual(index.raggedRows, 11)
        XCTAssertEqual(index.raggedRowSamples, [3, 13, 23, 33, 43, 50, 53, 63])
        XCTAssertEqual(index.maxFieldCount, 4)
        XCTAssertEqual(try table.rows(in: 50..<51, index: index).first?.fields, ["50", "x", "y", "z"])
        XCTAssertEqual(table.facts(index: index).raggedRows, .exactly(11))
    }

    func testByteLimitGivesPartialCoverage() async throws {
        let (text, expected) = fixture(rows: 2000)
        let url = try directory.write(text)
        var options = smallOptions()
        options.indexByteLimit = 10_000
        let table = try CSVTable.open(url, options: options)
        let index = try await table.buildIndex(options: options)
        XCTAssertEqual(index.state, .stoppedAtByteLimit)
        XCTAssertEqual(index.scannedBytes, 10_000)
        XCTAssertGreaterThan(index.indexedRows, 20)
        XCTAssertLessThan(index.indexedRows, 2000)
        XCTAssertEqual(table.rowCount(index: index), .atLeast(index.indexedRows))
        guard case .partial(let shown, nil, .byteLimit(10_000, let size)) = table.coverage(index: index) else {
            return XCTFail("expected partial coverage at the byte limit")
        }
        XCTAssertEqual(shown, index.indexedRows)
        XCTAssertEqual(size, Int64(text.utf8.count))
        XCTAssertEqual(try table.rows(in: 100..<103, index: index).map(\.fields), Array(expected[100..<103]))
        XCTAssertEqual(table.facts(index: index).rows.formatted(locale: Locale(identifier: "en_US")),
                       "≥ \(index.indexedRows.formatted(.number.locale(Locale(identifier: "en_US"))))")
    }

    func testProgressSnapshotsCanPageBeforeTheIndexFinishes() async throws {
        let (text, expected) = fixture(rows: 3000)
        var options = smallOptions()
        options.progressIntervalBytes = 8192
        let table = try CSVTable.open(try directory.write(text), options: options)
        let snapshots = Snapshots()
        let index = try await table.buildIndex(options: options) { snapshots.append($0) }
        let seen = snapshots.all
        XCTAssertGreaterThan(seen.count, 3)
        XCTAssertTrue(seen.allSatisfy { $0.state == .indexing && $0.rowCount == .atLeast($0.indexedRows) })
        XCTAssertEqual(seen.map(\.indexedRows), seen.map(\.indexedRows).sorted())
        XCTAssertEqual(index.indexedRows, 3000)
        let early = try XCTUnwrap(seen.first)
        XCTAssertEqual(try table.rows(in: early.indexedRows - 5..<early.indexedRows, index: early).map(\.fields),
                       Array(expected[early.indexedRows - 5..<early.indexedRows]))
        guard case .partial(_, nil, .indexing) = early.coverage else { return XCTFail("a snapshot is partial") }
    }

    func testCancellationStopsIndexing() async throws {
        let (text, _) = fixture(rows: 3000)
        var options = smallOptions()
        options.progressIntervalBytes = 4096
        let table = try CSVTable.open(try directory.write(text), options: options)
        let task = Task {
            try await table.buildIndex(options: options) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            XCTFail("indexing should have been cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testUnterminatedQuoteIsReported() async throws {
        let url = try directory.write("a,b\n1,2\n3,\"open\n4,5\n")
        let table = try CSVTable.open(url)
        XCTAssertEqual(table.firstPage.rows.map(\.fields), [["1", "2"], ["3", "open\n4,5\n"]])
        let index = try await table.buildIndex()
        XCTAssertTrue(index.endsInsideQuotes)
        XCTAssertEqual(index.indexedRows, 2)
    }

    func testHeaderOnlyAndEmptyFiles() async throws {
        let header = try CSVTable.open(try directory.write("name,qty\n", name: "h.csv"))
        XCTAssertEqual(header.header, ["name", "qty"])
        XCTAssertEqual(header.rowCount(index: nil), .exactly(0))
        let indexed = try await header.buildIndex()
        XCTAssertEqual(indexed.rowCount, .exactly(0))

        let empty = try CSVTable.open(try directory.write("", name: "e.csv"))
        XCTAssertNil(empty.header)
        XCTAssertEqual(empty.columnCount, 0)
        XCTAssertEqual(empty.rowCount(index: nil), .exactly(0))
        XCTAssertEqual(try empty.rows(in: 0..<10), [])
    }

    func testSampleRowsSpreadOverTheFile() async throws {
        let (text, _) = fixture(rows: 5000)
        let table = try CSVTable.open(try directory.write(text), options: smallOptions())
        let index = try await table.buildIndex(options: smallOptions())
        let sample = try table.sampleRows(index: index, maxRows: 400, spread: 4)
        XCTAssertEqual(sample.count, 400)
        let ids = sample.compactMap { Int($0[0]) }
        XCTAssertEqual(ids.first, 0)
        XCTAssertGreaterThan(ids.max() ?? 0, 4800, "the last run comes from the end of the file")
        XCTAssertEqual(Set(ids).count, 400)
        // A file no larger than the sample is sampled whole.
        XCTAssertEqual(try table.sampleRows(index: index, maxRows: 10_000).count, 5000)
    }
}

/// Collects progress snapshots from the indexer's callback.
private final class Snapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CSVRowIndex] = []
    func append(_ value: CSVRowIndex) { lock.withLock { values.append(value) } }
    var all: [CSVRowIndex] { lock.withLock { values } }
}
