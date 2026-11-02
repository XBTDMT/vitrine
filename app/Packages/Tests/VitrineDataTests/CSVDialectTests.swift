import XCTest
@testable import VitrineData

final class CSVDialectTests: XCTestCase {
    private func sniff(_ text: String, hint: CSVDelimiter? = nil, whole: Bool = true) throws -> CSVDialect {
        try CSVDialectSniffer.sniff(Data(text.utf8), isWholeFile: whole, delimiterHint: hint)
    }

    // MARK: Delimiter

    func testDelimiters() throws {
        XCTAssertEqual(try sniff("a,b,c\n1,2,3\n4,5,6\n").delimiter, .comma)
        XCTAssertEqual(try sniff("a\tb\tc\n1\t2\t3\n").delimiter, .tab)
        XCTAssertEqual(try sniff("a;b;c\n1;2;3\n").delimiter, .semicolon)
        XCTAssertEqual(try sniff("a|b|c\n1|2|3\n").delimiter, .pipe)
    }

    func testDelimiterInsideQuotesDoesNotVote() throws {
        // Commas only inside quotes, semicolons between fields.
        let text = "name;note\n\"Vale, Ori\";\"a, b, c\"\n\"Fenn, Ash\";\"d, e\"\n"
        XCTAssertEqual(try sniff(text).delimiter, .semicolon)
    }

    func testEuropeanSemicolonFileWithDecimalCommas() throws {
        let text = "item;price;qty\nwidget;1,50;3\ngadget;12,25;1\nsprocket;0,75;10\n"
        let dialect = try sniff(text, hint: .comma)
        XCTAssertEqual(dialect.delimiter, .semicolon, "the sample overrides the .csv hint when it clearly disagrees")
        XCTAssertTrue(dialect.overrodeHint)
    }

    func testHintKeptWhenPlausible() throws {
        // Every row has one comma inside an unquoted field and two tabs: a .tsv hint keeps tab.
        let text = "name\tcity\tcode\nLark, A\tNorthvale\t1\nVale, O\tEastmere\t2\n"
        let dialect = try sniff(text, hint: .tab)
        XCTAssertEqual(dialect.delimiter, .tab)
        XCTAssertFalse(dialect.overrodeHint)
        // A .tsv that is really comma-separated is overridden.
        let commas = try sniff("a,b,c\n1,2,3\n4,5,6\n", hint: .tab)
        XCTAssertEqual(commas.delimiter, .comma)
        XCTAssertTrue(commas.overrodeHint)
    }

    func testSingleColumnFileKeepsHint() throws {
        XCTAssertEqual(try sniff("name\nAda\nOri\n", hint: .tab).delimiter, .tab)
        XCTAssertEqual(try sniff("name\nAda\nOri\n").delimiter, .comma)
    }

    func testTruncatedSampleIgnoresHalfRow() throws {
        // The sample cuts the last record mid-way; it has fewer fields and must not drag the vote.
        let text = "a;b;c;d\n1;2;3;4\n5;6;7;8\n9;10"
        XCTAssertEqual(try sniff(text, whole: false).delimiter, .semicolon)
    }

    // MARK: Quote

    func testQuoteCharacter() throws {
        XCTAssertEqual(try sniff("a,b\n\"x, y\",1\n").quote, .double)
        XCTAssertEqual(try sniff("a,b\n'x, y',1\n'z',2\n").quote, .single)
        XCTAssertEqual(try sniff("name,city\nO'Neil,Brae\nD'Arcy,Lune\n").quote, .double, "apostrophes in words do not vote")
    }

    // MARK: Header

    func testHeaderOverTypedColumns() throws {
        XCTAssertTrue(try sniff("id,price,day\n1,2.5,2024-01-02\n2,3.75,2024-01-03\n").hasHeader)
        XCTAssertFalse(try sniff("1,2.5,2024-01-02\n2,3.75,2024-01-03\n3,1.0,2024-02-01\n").hasHeader)
    }

    func testHeaderOverTextColumns() throws {
        // All text, fixed-length codes below a label of another length.
        XCTAssertTrue(try sniff("sku,name\nAB12,Fenn\nCD34,Ash\nEF56,Ori\n").hasHeader)
        // Distinct labels over text with no other evidence: a header.
        XCTAssertTrue(try sniff("first,last\nAda,Lark\nOri,Vale\n").hasHeader)
        // Repeated first-row values look like data.
        XCTAssertFalse(try sniff("x,x\nq,r\n").hasHeader)
    }

    func testSingleRowHeader() throws {
        XCTAssertTrue(try sniff("name,age,city\n").hasHeader)
        XCTAssertFalse(try sniff("Ada,30,Northvale\n").hasHeader)
    }

    func testNumericLabelsOverNumbersAreData() throws {
        XCTAssertFalse(try sniff("10,20\n30,40\n50,60\n").hasHeader)
    }

    // MARK: Line ending, BOM, encoding

    func testLineEndings() throws {
        XCTAssertEqual(try sniff("a,b\n1,2\n").lineEnding, .lf)
        XCTAssertEqual(try sniff("a,b\r\n1,2\r\n").lineEnding, .crlf)
        XCTAssertEqual(try sniff("a,b\r1,2\r").lineEnding, .cr)
        XCTAssertNil(try sniff("a,b").lineEnding)
        // Excel: CRLF rows with LF inside quoted cells. Quoted breaks are content, so the rows win.
        XCTAssertEqual(try sniff("a,b\r\n\"x\ny\nz\",1\r\n\"p\nq\",2\r\n").lineEnding, .crlf)
    }

    func testBOM() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("name,qty\nbolt,3\n".utf8))
        let dialect = try CSVDialectSniffer.sniff(data, isWholeFile: true)
        XCTAssertTrue(dialect.hasBOM)
        XCTAssertEqual(dialect.encoding, .utf8)
        XCTAssertEqual(dialect.contentOffset, 3)
        XCTAssertFalse(try sniff("a,b\n").hasBOM)
    }

    func testEncodingFallback() throws {
        let latin1 = Data([0x6E, 0x61, 0x6D, 0x65, 0x0A, 0x43, 0x61, 0x66, 0xE9, 0x0A])   // name\nCafé\n
        XCTAssertEqual(try CSVDialectSniffer.sniff(latin1, isWholeFile: true).encoding, .latin1)
        XCTAssertEqual(try sniff("name\nCafé\n").encoding, .utf8)
        // A sample that cuts a UTF-8 character in half is still UTF-8.
        let cut = Data("name\nCafé".utf8).dropLast()
        XCTAssertEqual(try CSVDialectSniffer.sniff(Data(cut), isWholeFile: false).encoding, .utf8)
        XCTAssertEqual(try CSVDialectSniffer.sniff(Data(cut), isWholeFile: true).encoding, .latin1)
    }

    func testUnsupportedInput() {
        XCTAssertThrowsError(try CSVDialectSniffer.sniff(Data([0xFF, 0xFE, 0x61, 0x00]), isWholeFile: true)) {
            XCTAssertEqual($0 as? CSVError, .unsupportedEncoding("UTF-16"))
        }
        XCTAssertThrowsError(try CSVDialectSniffer.sniff(Data([0x61, 0x2C, 0x00, 0x62]), isWholeFile: true)) {
            XCTAssertEqual($0 as? CSVError, .binaryContent)
        }
    }

    func testEmptySample() throws {
        let dialect = try sniff("")
        XCTAssertEqual(dialect.delimiter, .comma)
        XCTAssertFalse(dialect.hasHeader)
    }

    func testDelimiterFromExtensionAndCharacter() {
        XCTAssertEqual(CSVDelimiter(fileExtension: "TSV"), .tab)
        XCTAssertEqual(CSVDelimiter(fileExtension: "csv"), .comma)
        XCTAssertNil(CSVDelimiter(fileExtension: "txt"))
        XCTAssertEqual(CSVDelimiter("\t"), .tab)
        XCTAssertNil(CSVDelimiter("x"))
    }

    /// The design's lint case (I-6): a `.csv` export that is really semicolon-separated with decimal commas. Each data
    /// row holds one decimal comma, so comma looked as consistent as semicolon and the file name's comma won.
    func testSemicolonExportWithDecimalCommasBeatsTheCommaHint() throws {
        var text = "order_id;customer;total;status\n"
        for i in 0..<120 { text += "\(100_000 + i);Customer \(i);\(i % 90),50;paid\n" }
        let dialect = try CSVDialectSniffer.sniff(Data(text.utf8), isWholeFile: true, delimiterHint: .comma)
        XCTAssertEqual(dialect.delimiter, .semicolon)
    }

    func testAPlainCommaFileKeepsItsComma() throws {
        var text = "id,name,amount\n"
        for i in 0..<50 { text += "\(i),Item \(i),\(i).25\n" }
        let dialect = try CSVDialectSniffer.sniff(Data(text.utf8), isWholeFile: true, delimiterHint: .comma)
        XCTAssertEqual(dialect.delimiter, .comma)
    }
}
