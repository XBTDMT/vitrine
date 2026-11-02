import XCTest
@testable import VitrineData

final class CSVFactsTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    func testFactsForACompleteFile() throws {
        let directory = try TemporaryDirectory()
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("a;b;c\n1;2;3\n4;5\n".utf8))
        let table = try CSVTable.open(try directory.write(data))
        let facts = table.facts(index: nil)
        XCTAssertEqual(facts.rows, .exactly(2))
        XCTAssertEqual(facts.raggedRows, .exactly(1))
        XCTAssertEqual(facts.entries(locale: english).map(\.key), ["rows", "columns", "delimiter", "header", "encoding", "raggedRows"])
        XCTAssertEqual(facts.entries(locale: english).map(\.value), ["2", "3", "Semicolon", "Yes", "UTF-8 with BOM", "1"])
    }

    func testFactsBeforeAndAfterIndexing() async throws {
        let directory = try TemporaryDirectory()
        var bytes: [UInt8] = Array("name,qty\n".utf8)
        for i in 0..<1500 { bytes += Array("Caf".utf8) + [0xE9] + Array(",\(i)\n".utf8) }   // Latin-1 é
        let table = try CSVTable.open(try directory.write(Data(bytes)))
        let early = table.facts(index: nil).entries(locale: english)
        XCTAssertEqual(early.first { $0.key == "rows" }?.value, "≥ 200")
        XCTAssertEqual(early.first { $0.key == "encoding" }?.value, "Latin-1 (Windows-1252)")
        XCTAssertEqual(early.first { $0.key == "raggedRows" }?.value, "≥ 0")
        XCTAssertEqual(table.firstPage.rows.first?.fields, ["Café", "0"])

        let index = try await table.buildIndex()
        let late = table.facts(index: index).entries(locale: english)
        XCTAssertEqual(late.first { $0.key == "rows" }?.value, "1,500")
        XCTAssertEqual(late.first { $0.key == "raggedRows" }?.value, "0")
        XCTAssertEqual(late.first { $0.key == "header" }?.value, "Yes")
        XCTAssertEqual(late.first { $0.key == "delimiter" }?.value, "Comma")
    }

    func testPartialReasonText() {
        let reason = CSVPartialReason.byteLimit(scannedBytes: 1_000_000, fileSize: 3_000_000)
        XCTAssertTrue(reason.description.hasPrefix("Rows counted in the first"))
        XCTAssertEqual(CSVRowCount.atLeast(12_345).formatted(locale: english), "≥ 12,345")
        XCTAssertEqual(CSVRowCount.exactly(7).formatted(locale: english), "7")
    }
}
