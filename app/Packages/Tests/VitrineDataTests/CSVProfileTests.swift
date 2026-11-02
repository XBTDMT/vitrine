import XCTest
@testable import VitrineData

final class CSVProfileTests: XCTestCase {
    func testColumnProfiles() throws {
        let rows = [
            ["1", "10.5", "red", "2024-01-05", "yes"],
            ["2", "", "blue", "2023-12-31", "no"],
            ["3", "4.5", "red", "2024-03-01", "yes"],
            ["4", "6", "green", "", "yes"],
            ["5", "n/a", "red", "2024-02-10", "no"],
            ["6", "3", "blue", "2024-02-11", "yes"],
            ["7", "1", "red", "2024-02-12", "yes"],
        ].map { CSVRow(fields: $0) }
        let profile = CSVProfiler.profile(rows: rows, columnTitles: ["id", "price", "colour", "day", "ok"],
                                          dialect: CSVDialect(), totalRows: .exactly(7))
        XCTAssertFalse(profile.isSample)
        XCTAssertEqual(profile.sampledRows, 7)

        let id = profile.columns[0]
        XCTAssertEqual(id.typeInfo.type, .integer)
        XCTAssertEqual(id.numbers, .init(min: 1, max: 7, mean: 4))
        XCTAssertEqual(id.distinct, 7)
        XCTAssertEqual(id.topValues, [])

        let price = profile.columns[1]
        XCTAssertEqual(price.typeInfo.type, .decimal)
        XCTAssertEqual(price.nonEmpty, 6)
        XCTAssertEqual(price.empty, 1)
        XCTAssertEqual(price.typeInfo.misfitCount, 1)
        XCTAssertEqual(price.numbers, .init(min: 1, max: 10.5, mean: 5), "n/a is left out of the numbers")

        let colour = profile.columns[2]
        XCTAssertEqual(colour.typeInfo.type, .text)
        XCTAssertEqual(colour.distinct, 3)
        XCTAssertEqual(colour.topValues.map(\.value), ["red", "blue", "green"])
        XCTAssertEqual(colour.topValues.map(\.count), [4, 2, 1])
        XCTAssertNil(colour.numbers)

        let day = profile.columns[3]
        XCTAssertEqual(day.typeInfo.type, .date)
        XCTAssertEqual(day.dates?.earliest, CSVValueClassifier.date("2023-12-31", style: CSVValueStyle())?.date)
        XCTAssertEqual(day.dates?.latest, CSVValueClassifier.date("2024-03-01", style: CSVValueStyle())?.date)

        let ok = profile.columns[4]
        XCTAssertEqual(ok.typeInfo.type, .boolean)
        XCTAssertEqual(ok.topValues, [.init(value: "yes", count: 5), .init(value: "no", count: 2)])
    }

    func testTopValuesAreCappedAtFiveWithStableTies() {
        let values = ["e", "d", "c", "b", "a", "f", "a", "b"]
        let info = CSVColumnInference.infer(values)
        let profile = CSVProfiler.profile(values: values, title: "x", info: info)
        XCTAssertEqual(profile.topValues.map(\.value), ["a", "b", "c", "d", "e"])
    }

    func testDistinctCap() {
        let values = (0..<(CSVProfiler.distinctCap + 50)).map { "v\($0)" }
        let profile = CSVProfiler.profile(values: values, title: "x", info: CSVColumnInference.infer(values))
        XCTAssertEqual(profile.distinct, CSVProfiler.distinctCap)
        XCTAssertTrue(profile.distinctIsCapped)
    }

    func testProfileSaysItIsASample() async throws {
        let directory = try TemporaryDirectory()
        var text = "n,label\n"
        for i in 0..<3000 { text += "\(i),k\(i % 4)\n" }
        let table = try CSVTable.open(try directory.write(text))
        let early = try table.profile(index: nil)
        XCTAssertTrue(early.isSample)
        XCTAssertEqual(early.sampledRows, 200)
        XCTAssertEqual(early.totalRows, .atLeast(200))

        let index = try await table.buildIndex()
        let full = try table.profile(index: index, maxRows: 500)
        XCTAssertTrue(full.isSample)
        XCTAssertEqual(full.totalRows, .exactly(3000))
        XCTAssertEqual(full.sampledRows, 496, "eight runs of 62 rows spread over the file")
        XCTAssertGreaterThan(full.columns[0].numbers?.max ?? 0, 2900)
        XCTAssertEqual(full.columns[1].title, "label")
        let whole = try table.profile(index: index, maxRows: 5000)
        XCTAssertFalse(whole.isSample)
    }

    /// The column profile's histogram, median, misfit examples and repeated-number top values (I-5). roadmap: S-6
    func testNumbersGetADistributionAndMisfitExamples() {
        // 17 numbers and 3 values that are not (85 % fit, above the 80 % rule for a numbers column).
        let values = ["1", "2", "2", "3", "two", "4", "—", "40", "2", "two"] + (5...14).map(String.init)
        let rows = values.map { CSVRow(fields: [$0], offset: 0, hasTruncatedField: false) }
        let profile = CSVProfiler.profile(rows: rows, columnTitles: ["qty"], dialect: CSVDialect(), totalRows: .exactly(values.count))
        let qty = profile.columns[0]
        XCTAssertEqual(qty.typeInfo.type, .integer)
        XCTAssertEqual(qty.distribution?.median, 7)
        XCTAssertEqual(qty.distribution?.histogram.count, CSVProfiler.histogramBins)
        XCTAssertEqual(qty.distribution?.histogram.reduce(0, +), 17, "every fitting value lands in a bin")
        XCTAssertEqual(qty.distribution?.histogram.last, 1, "the maximum lands in the last bin")
        XCTAssertEqual(qty.misfitExamples, ["two", "—"])
        XCTAssertEqual(qty.topValues.first, .init(value: "2", count: 3), "a repeated number is a top value")
    }
}
