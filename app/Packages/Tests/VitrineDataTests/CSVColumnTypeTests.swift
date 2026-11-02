import XCTest
@testable import VitrineData

final class CSVColumnTypeTests: XCTestCase {
    private func type(_ values: [String], style: CSVValueStyle = CSVValueStyle()) -> CSVColumnTypeInfo {
        CSVColumnInference.infer(values, style: style)
    }

    func testBasicTypes() {
        XCTAssertEqual(type(["1", "-2", "+30", " 4 "]).type, .integer)
        XCTAssertEqual(type(["1", "2.5", ".5", "-3e4", "1E-3"]).type, .decimal)
        XCTAssertEqual(type(["true", "False", "YES", "no"]).type, .boolean)
        XCTAssertEqual(type(["2024-01-02", "1999-12-31"]).type, .date)
        XCTAssertEqual(type(["2024-01-02T03:04:05Z", "2024-01-02 03:04", "2024-01-02"]).type, .dateTime)
        XCTAssertEqual(type(["Ada", "Ori"]).type, .text)
        XCTAssertEqual(type(["", " ", ""]).type, .empty)
        XCTAssertEqual(type([]).type, .empty)
    }

    func testFitCountMarksMisfits() {
        let info = type(["1", "2", "3", "4", "5", "6", "7", "8", "9", "n/a", ""])
        XCTAssertEqual(info.type, .integer)
        XCTAssertEqual(info.sampled, 11)
        XCTAssertEqual(info.nonEmpty, 10)
        XCTAssertEqual(info.fitCount, 9)
        XCTAssertEqual(info.misfitCount, 1)
        XCTAssertFalse(info.accepts("n/a"))
        XCTAssertTrue(info.accepts("42"))
        XCTAssertTrue(info.accepts(""), "empty cells are missing, not wrong")
    }

    func testBelowThresholdIsText() {
        // 3 of 5 numbers is under 80%.
        let info = type(["1", "2", "3", "x", "y"])
        XCTAssertEqual(info.type, .text)
        XCTAssertEqual(info.fitCount, 5)
    }

    func testMixedIntegersAndDecimalsIsDecimalAndBothFit() {
        let info = type(["1", "2", "3", "4", "5", "6", "7", "8", "9", "1.5"])
        XCTAssertEqual(info.type, .decimal)
        XCTAssertEqual(info.fitCount, 10)
    }

    func testDecimalCommaOnlyWhenTheDialectFreesTheComma() {
        XCTAssertEqual(type(["1,5", "2,25"], style: CSVValueStyle(decimalComma: true)).type, .decimal)
        XCTAssertEqual(type(["1,5", "2,25"]).type, .text)
    }

    func testNotNumbers() {
        for value in ["1.2.3", "--1", "e5", "1e", "12abc", "0x1F", "1,000", "nan", "inf", "."] {
            XCTAssertEqual(CSVValueClassifier.classify(value, style: CSVValueStyle()), .text, value)
        }
    }

    func testDateForms() {
        let forms = ["2024-02-29", "2024/02/29", "02/29/2024", "29/02/2024", "29.02.2024"]
        for form in forms { XCTAssertEqual(CSVValueClassifier.classify(form, style: CSVValueStyle()), .date, form) }
        let times = ["2024-02-29T13:45:00Z", "2024-02-29T13:45:00.250+02:00", "2024-02-29 13:45", "02/29/2024 1:45 PM",
                     "2024-02-29T13:45:00-0500"]
        for form in times { XCTAssertEqual(CSVValueClassifier.classify(form, style: CSVValueStyle()), .dateTime, form) }
        for bad in ["2023-02-29", "2024-13-01", "2024-01-32", "13/13/2024", "2024-01-02T25:00", "2024-01-02 10:61",
                    "2024-01-02X", "1/2/24"] {
            XCTAssertEqual(CSVValueClassifier.classify(bad, style: CSVValueStyle()), .text, bad)
        }
    }

    func testDateValues() throws {
        let style = CSVValueStyle()
        XCTAssertEqual(CSVValueClassifier.date("1970-01-01", style: style)?.date, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(CSVValueClassifier.date("2000-03-01", style: style)?.date, Date(timeIntervalSince1970: 951_868_800))
        XCTAssertEqual(CSVValueClassifier.date("2024-01-02T03:04:05+01:00", style: style)?.date,
                       CSVValueClassifier.date("2024-01-02T02:04:05Z", style: style)?.date)
        XCTAssertEqual(CSVValueClassifier.date("01/02/2024 12:00 AM", style: style)?.date,
                       CSVValueClassifier.date("2024-01-02", style: style)?.date)
        XCTAssertEqual(CSVValueClassifier.daysFromCivil(1969, 12, 31), -1)
    }

    func testSlashOrderIsDecidedPerColumn() {
        let dayFirst = type(["03/04/2024", "25/04/2024", "01/05/2024"])
        XCTAssertEqual(dayFirst.type, .date)
        XCTAssertTrue(dayFirst.style.dayFirst)
        XCTAssertEqual(CSVValueClassifier.date("03/04/2024", style: dayFirst.style)?.date,
                       CSVValueClassifier.date("2024-04-03", style: CSVValueStyle())?.date)
        let monthFirst = type(["03/04/2024", "04/25/2024"])
        XCTAssertFalse(monthFirst.style.dayFirst)
        // Under day-first, a month-first-only value does not fit.
        let mixed = type(["25/04/2024", "26/04/2024", "27/04/2024", "28/04/2024", "29/04/2024", "04/30/2024"])
        XCTAssertTrue(mixed.style.dayFirst)
        XCTAssertEqual(mixed.fitCount, 5)
        XCTAssertFalse(mixed.accepts("04/30/2024"))
    }

    func testInferRowsUsesColumns() {
        let rows = [CSVRow(fields: ["1", "x", "2024-01-01"]), CSVRow(fields: ["2", "y"]), CSVRow(fields: ["3", "z", "2024-01-03"])]
        let infos = CSVColumnInference.infer(rows: rows, columnCount: 3, dialect: CSVDialect())
        XCTAssertEqual(infos.map(\.type), [.integer, .text, .date])
        XCTAssertEqual(infos[2].sampled, 3)
        XCTAssertEqual(infos[2].nonEmpty, 2, "a short row counts as empty in its missing column")
    }
}
