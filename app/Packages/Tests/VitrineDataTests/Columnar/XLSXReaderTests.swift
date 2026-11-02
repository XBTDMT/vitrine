import Foundation
import XCTest
@testable import VitrineData
import VitrineSupport

/// The xlsx reader over invented workbooks zipped by `TestXLSX` (B-4, G-20). roadmap: S-21
final class XLSXReaderTests: XCTestCase {
    /// Styles: cell format 0 General, 1 a date (built-in 14), 2 a custom date-time, 3 a custom number with quoted text.
    static let styles = """
    <numFmts count="2"><numFmt numFmtId="164" formatCode="yyyy-mm-dd hh:mm"/><numFmt numFmtId="165" formatCode="0.00 &quot;km&quot;"/></numFmts>\
    <cellXfs count="4"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="165"/></cellXfs>
    """

    static func book() -> [UInt8] {
        let strings = ["Name", "Joined", "Visits", "Score", "Member", "Ada", "Bo", "Cy", "Note"]
        let sheet1 = """
        <dimension ref="A1:F5"/><sheetData>\
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c><c r="E1" t="s"><v>4</v></c><c r="F1" t="s"><v>8</v></c></row>\
        <row r="2"><c r="A2" t="s"><v>5</v></c><c r="B2" s="1"><v>46266</v></c><c r="C2"><v>3</v></c><c r="D2" s="3"><v>0.30000000000000004</v></c><c r="E2" t="b"><v>1</v></c><c r="F2" t="inlineStr"><is><t>first</t></is></c></row>\
        <row r="3"><c r="A3" t="s"><v>6</v></c><c r="B3" s="1"><v>46267</v></c><c r="C3"><f>C2*2</f><v>6</v></c><c r="D3"><v>12.5</v></c><c r="E3" t="b"><v>0</v></c><c r="F3"><v>7</v></c></row>\
        <row r="5"><c r="A5" t="s"><v>7</v></c><c r="B5" s="1"><v>46268</v></c><c r="C5"><f>SUM(C2:C3)</f><v>9</v></c><c r="E5" t="e"><v>#N/A</v></c><c r="F5" t="str"><f>A5&amp;"!"</f><v>Cy!</v></c></row>\
        </sheetData><mergeCells count="1"><mergeCell ref="A7:B7"/></mergeCells>
        """
        let sheet2 = """
        <sheetData><row r="3"><c r="B3" s="2"><v>46266.5</v></c><c r="C3"><v>1</v></c></row><row r="4"><c r="B4" s="2"><v>46267.25</v></c><c r="C4"><v>2</v></c></row></sheetData>
        """
        return TestXLSX.workbook(sheets: [("People", sheet1), ("Log", sheet2), ("Secret", "<sheetData/>")], sharedStrings: strings,
                                 styles: styles, hidden: ["Secret"])
    }

    func text(_ table: any ColumnarTable, _ w: ColumnarWindow, _ row: Int, _ column: Int) -> String {
        ColumnarText.text(w.columns[column][row], kind: table.columns[column].kind)
    }

    func testSheetsHeaderTypesAndFormulas() throws {
        let book = try ColumnarOpener.open(source: MemoryByteSource(Self.book()), fileExtension: "xlsx")
        XCTAssertEqual(book.format, .xlsx)
        XCTAssertEqual(book.parts.map(\.name), ["People", "Log", "Secret"])
        XCTAssertEqual(book.parts[0].rows, 5)
        XCTAssertEqual(book.parts[2].note, "hidden")
        let facts = Dictionary(uniqueKeysWithValues: book.facts.map { ($0.label, $0.value) })
        XCTAssertEqual(facts["Sheets"], "3")
        XCTAssertEqual(facts["Written by"], "Vitrine Test Writer 1.0")

        let people = try book.table(0)
        XCTAssertEqual(people.columns.map(\.name), ["Name", "Joined", "Visits", "Score", "Member", "Note"])
        XCTAssertEqual(people.firstRowNumber, 2)
        XCTAssertEqual(people.rowCount, 4)                 // rows 2, 3, 4 (empty) and 5
        XCTAssertEqual(people.columns[1].kind, .date)
        XCTAssertEqual(people.columns[2].kind, .integer(bits: 64, signed: true))
        XCTAssertEqual(people.columns[3].kind, .float(bits: 64))
        XCTAssertEqual(people.columns[4].kind, .mixed)     // TRUE, FALSE and #N/A
        XCTAssertEqual(people.columns[5].kind, .mixed)
        let w = try people.read(rows: 0..<4)
        XCTAssertEqual(text(people, w, 0, 0), "Ada")
        XCTAssertEqual(text(people, w, 0, 1), "2026-09-01")
        XCTAssertEqual(text(people, w, 1, 2), "6")         // the formula's cached value
        XCTAssertEqual(text(people, w, 0, 3), "0.3")       // Excel's 15 digits, not the binary tail
        XCTAssertEqual(text(people, w, 0, 4), "TRUE")
        XCTAssertEqual(text(people, w, 3, 4), "#N/A")
        XCTAssertTrue(w.columns[0][2].isNull)              // row 4 is empty
        XCTAssertEqual(text(people, w, 3, 5), "Cy!")
        XCTAssertEqual(text(people, w, 1, 5), "7")
        let sheetFacts = Dictionary(uniqueKeysWithValues: people.facts.map { ($0.label, $0.value) })
        XCTAssertEqual(sheetFacts["Formulas"], "3 (cached values shown)")
        XCTAssertEqual(sheetFacts["Merged ranges"], "1")

        let log = try book.table(1)
        XCTAssertEqual(log.columns.map(\.name), ["A", "B", "C"])   // no header row: column letters
        XCTAssertEqual(log.firstRowNumber, 3)
        XCTAssertEqual(log.columns[1].kind, .timestamp(.millis, zone: nil))
        let l = try log.read(rows: 0..<2)
        XCTAssertEqual(text(log, l, 0, 1), "2026-09-01 12:00:00")
        XCTAssertEqual(text(log, l, 1, 1), "2026-09-02 06:00:00")
        XCTAssertEqual(log.columns[0].kind, .null)
    }

    func testDateFormatDetection() {
        XCTAssertTrue(XLSXParts.isDateFormat("yyyy-mm-dd"))
        XCTAssertTrue(XLSXParts.isDateFormat("[$-409]d-mmm-yy;@"))
        XCTAssertTrue(XLSXParts.isDateFormat("[h]:mm:ss"))
        XCTAssertFalse(XLSXParts.isDateFormat("0.00 \"km\""))
        XCTAssertFalse(XLSXParts.isDateFormat("#,##0;[Red]-#,##0"))
        XCTAssertFalse(XLSXParts.isDateFormat("General"))
        XCTAssertFalse(XLSXParts.isDateFormat("0.00E+00"))
    }

    func testDate1904AndCellReferences() throws {
        let sheet = "<sheetData><row r=\"1\"><c r=\"A1\" s=\"1\"><v>0</v></c></row></sheetData>"
        let book = try XLSXWorkbook(source: MemoryByteSource(TestXLSX.workbook(sheets: [("S", sheet)], sharedStrings: [],
                                                                                styles: Self.styles, date1904: true)))
        let t = try book.table(0)
        XCTAssertEqual(text(t, try t.read(rows: 0..<1), 0, 0), "1904-01-01")
        XCTAssertEqual(XLSXCellReference.parse("AB12")?.column, 27)
        XCTAssertEqual(XLSXCellReference.parse("$C$3")?.row, 3)
        XCTAssertEqual(XLSXCellReference.letters(27), "AB")
        XCTAssertNil(XLSXCellReference.parse("12"))
    }

    func testRefusals() {
        // A zip without a workbook part is not a workbook.
        XCTAssertThrowsError(try XLSXWorkbook(source: MemoryByteSource(TestXLSX.zip([("a.txt", Array("hi".utf8))]))))
        // A part declaring a DTD is refused, so no entity can expand.
        let evil = "<!DOCTYPE x [<!ENTITY a \"aaaaaaaaaa\">]><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>&a;</t></is></c></row></sheetData>"
        let book = try? XLSXWorkbook(source: MemoryByteSource(TestXLSX.workbook(sheets: [("S", evil)], sharedStrings: [])))
        XCTAssertNotNil(book)
        XCTAssertThrowsError(try book?.table(0)) { XCTAssertTrue("\($0)".contains("DTD"), "\($0)") }
        // Legacy .xls and encrypted .xlsx are OLE compound files.
        XCTAssertThrowsError(try ColumnarOpener.open(source: MemoryByteSource([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + Array(repeating: 0, count: 100)))) {
            XCTAssertTrue(($0 as? ColumnarError)?.errorDescription?.contains("legacy .xls") == true)
        }
    }

    /// Numbers no date can hold, in a date format, stay numbers; huge and infinite values never trap.
    func testOutOfRangeDatesAndHugeNumbers() throws {
        let sheet = "<sheetData><row r=\"1\"><c r=\"A1\" s=\"1\"><v>1e300</v></c><c r=\"B1\"><v>1e999</v></c><c r=\"C1\" s=\"1\"><v>-5</v></c>"
            + "<c r=\"D1\" t=\"d\"><v>99999-01-01</v></c></row><row r=\"2\"><c r=\"A2\" s=\"1\"><v>46266</v></c></row></sheetData>"
        let book = try XLSXWorkbook(source: MemoryByteSource(TestXLSX.workbook(sheets: [("S", sheet)], sharedStrings: [], styles: Self.styles)))
        let t = try book.table(0)
        let w = try t.read(rows: 0..<t.rowCount)
        XCTAssertEqual(t.columns[0].kind, .mixed)
        XCTAssertEqual(text(t, w, 0, 0), "1e+300")
        XCTAssertEqual(text(t, w, 1, 0), "2026-09-01")
        XCTAssertEqual(text(t, w, 0, 1), "inf")
        XCTAssertEqual(text(t, w, 0, 2), "-5")
        XCTAssertEqual(text(t, w, 0, 3), "99999-01-01")
    }

    func testCellBudget() throws {
        var limits = ColumnarLimits()
        limits.maxSheetCells = 3
        let rows = (1...5).map { "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0)</v></c></row>" }.joined()
        let book = try XLSXWorkbook(source: MemoryByteSource(TestXLSX.workbook(sheets: [("S", "<sheetData>\(rows)</sheetData>")], sharedStrings: [])),
                                    limits: limits)
        XCTAssertThrowsError(try book.table(0)) { XCTAssertEqual($0 as? ColumnarError, .tooLarge("the sheet has more than 3 cells")) }
    }
}
