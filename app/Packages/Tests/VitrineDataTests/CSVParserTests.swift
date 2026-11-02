import XCTest
@testable import VitrineData

/// RFC 4180 and the lenient cases around it, through the one scanner every reader uses.
final class CSVParserTests: XCTestCase {
    func testPlainFields() {
        XCTAssertEqual(CSVTestParse.fields("a,b,c\n1,2,3\n"), [["a", "b", "c"], ["1", "2", "3"]])
    }

    func testQuotedFieldWithDelimiter() {
        XCTAssertEqual(CSVTestParse.fields("name,city\n\"Lark, Ada\",Northvale\n"),
                       [["name", "city"], ["Lark, Ada", "Northvale"]])
    }

    func testDoubledQuotes() {
        XCTAssertEqual(CSVTestParse.fields("\"say \"\"hi\"\"\",x\n"), [["say \"hi\"", "x"]])
        XCTAssertEqual(CSVTestParse.fields("\"\"\"\"\n"), [["\""]])
    }

    func testEmbeddedNewlinesInsideQuotes() {
        let text = "id,note\n1,\"line one\nline two\r\nline three\"\n2,plain\n"
        XCTAssertEqual(CSVTestParse.fields(text),
                       [["id", "note"], ["1", "line one\nline two\r\nline three"], ["2", "plain"]])
    }

    func testEmptyFieldsAndTrailingDelimiter() {
        XCTAssertEqual(CSVTestParse.fields("a,,c\n,,\nx,y,\n"), [["a", "", "c"], ["", "", ""], ["x", "y", ""]])
        XCTAssertEqual(CSVTestParse.fields("\"\"\n"), [[""]], "a line of just \"\" is one empty field, not a blank line")
    }

    func testRaggedRowsAreKept() {
        XCTAssertEqual(CSVTestParse.fields("a,b,c\n1,2\n1,2,3,4\n"), [["a", "b", "c"], ["1", "2"], ["1", "2", "3", "4"]])
    }

    func testEmptyTrailingLineAndBlankLines() {
        XCTAssertEqual(CSVTestParse.fields("a,b\n1,2\n\n"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSVTestParse.fields("a,b\n\n\n1,2\n"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSVTestParse.fields(""), [])
        XCTAssertEqual(CSVTestParse.fields("\n\r\n"), [])
    }

    func testFinalLineWithoutNewline() {
        XCTAssertEqual(CSVTestParse.fields("a,b\n1,2"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSVTestParse.fields("a,b\n1,\"2\""), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSVTestParse.fields("a,b\n1,"), [["a", "b"], ["1", ""]])
    }

    func testLineEndings() {
        XCTAssertEqual(CSVTestParse.fields("a,b\r\n1,2\r\n"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSVTestParse.fields("a,b\r1,2\r"), [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSVTestParse.fields("a,b\n1,2\r\n3,4\r5,6"), [["a", "b"], ["1", "2"], ["3", "4"], ["5", "6"]])
    }

    func testLenientQuotes() {
        // A quote inside an unquoted field is literal; text after a closing quote is kept.
        XCTAssertEqual(CSVTestParse.fields("5\" bolt,x\n"), [["5\" bolt", "x"]])
        XCTAssertEqual(CSVTestParse.fields("\"ab\"cd,x\n"), [["abcd", "x"]])
        XCTAssertEqual(CSVTestParse.fields(" \"a\",b\n"), [[" \"a\"", "b"]], "a quote after a space does not open quoting")
    }

    func testUnterminatedQuoteRunsToEndAndIsReported() {
        let result = CSVTestParse.records(Array("a,b\n1,\"open\n2,3\n".utf8))
        XCTAssertEqual(result.rows.map(\.fields), [["a", "b"], ["1", "open\n2,3\n"]])
        XCTAssertTrue(result.endedInsideQuotes)
        XCTAssertFalse(CSVTestParse.records(Array("a,\"b\"\n".utf8)).endedInsideQuotes)
    }

    func testOtherDelimiters() {
        XCTAssertEqual(CSVTestParse.fields("a\tb\n\"x\ty\"\tz\n", delimiter: .tab), [["a", "b"], ["x\ty", "z"]])
        XCTAssertEqual(CSVTestParse.fields("a;b\n1,5;2\n", delimiter: .semicolon), [["a", "b"], ["1,5", "2"]])
        XCTAssertEqual(CSVTestParse.fields("a|b\n1|2\n", delimiter: .pipe), [["a", "b"], ["1", "2"]])
    }

    func testRecordOffsets() {
        let rows = CSVTestParse.records(Array("a,b\r\n\r\n\"1\n\",2\n3,4".utf8)).rows
        XCTAssertEqual(rows.map(\.offset), [0, 7, 14])
    }

    /// Every chunk boundary (inside a quote, between a CR and its LF, in a doubled quote) gives the same records.
    func testChunkBoundariesDoNotChangeTheResult() {
        let text = "id,note,x\r\n1,\"a \"\"quoted\"\", value\r\nspanning\",é\r\n\r\n2,plain,\"\"\r3,,\"end\"\n4,\"open"
        let bytes = Array(text.utf8)
        let whole = CSVTestParse.records(bytes)
        for chunk in 1...12 {
            let pieces = CSVTestParse.records(bytes, chunk: chunk)
            XCTAssertEqual(pieces.rows, whole.rows, "chunk size \(chunk)")
            XCTAssertEqual(pieces.endedInsideQuotes, whole.endedInsideQuotes)
        }
    }

    func testFieldCapTruncatesWithoutSplittingACharacter() {
        let value = String(repeating: "é", count: 10)   // 20 bytes of UTF-8
        var scanner = CSVScanner(delimiter: CSVDelimiter.comma.rawValue, quote: CSVQuote.double.rawValue)
        var collector = CSVRecordCollector(encoding: .utf8, maxFieldBytes: 7, limit: 10)
        Array("\(value),ok\n".utf8).withUnsafeBufferPointer { _ = scanner.scan($0, into: &collector) }
        XCTAssertEqual(collector.rows.first?.fields, ["ééé…", "ok"])
        XCTAssertEqual(collector.rows.first?.hasTruncatedField, true)
    }

    func testLatin1Decoding() {
        // "Café “x”" in Windows-1252.
        let bytes: [UInt8] = [0x43, 0x61, 0x66, 0xE9, 0x20, 0x93, 0x78, 0x94, 0x0A]
        XCTAssertEqual(CSVTestParse.records(bytes, encoding: .latin1).rows.first?.fields, ["Café “x”"])
        // A UTF-8 file with one stray Latin-1 field falls back for that field only.
        XCTAssertEqual(CSVTestParse.records(bytes, encoding: .utf8).rows.first?.fields, ["Café “x”"])
    }

    /// The property paging rests on: over random input made of the bytes that matter (quotes, delimiters, CR, LF),
    /// read in random chunk sizes, the indexer's checkpoints are exactly the parser's record offsets and both count
    /// the same records.
    func testIndexerAndParserAgreeOnRandomInput() {
        var random = SeededGenerator(seed: 42)
        let alphabet: [UInt8] = Array("ab,\"\"\n\r ".utf8)
        for round in 0..<300 {
            let length = Int(random.next() % 200)
            let bytes = (0..<length).map { _ in alphabet[Int(random.next() % UInt64(alphabet.count))] }
            let parsed = CSVTestParse.records(bytes, chunk: Int(random.next() % 16) + 1)

            let empty = CSVRowIndex(stride: 1, checkpoints: [], indexedRows: 0, scannedBytes: 0, fileSize: Int64(length),
                                    state: .indexing, raggedRows: 0, raggedRowSamples: [], maxFieldCount: 0,
                                    endsInsideQuotes: false)
            var sink = CSVIndexSink(index: empty, expectedFields: 0)
            var scanner = CSVScanner(delimiter: CSVDelimiter.comma.rawValue, quote: CSVQuote.double.rawValue)
            let chunk = Int(random.next() % 16) + 1
            var start = 0
            bytes.withUnsafeBufferPointer { all in
                while start < all.count {
                    let end = min(all.count, start + chunk)
                    scanner.scan(UnsafeBufferPointer(rebasing: all[start..<end]), into: &sink)
                    start = end
                }
            }
            scanner.finish(into: &sink)
            XCTAssertEqual(sink.index.indexedRows, parsed.rows.count, "round \(round)")
            XCTAssertEqual(sink.index.checkpoints, parsed.rows.map(\.offset), "round \(round)")
            XCTAssertEqual(sink.index.maxFieldCount, parsed.rows.map(\.fields.count).max() ?? 0, "round \(round)")
            XCTAssertEqual(parsed.rows, CSVTestParse.records(bytes).rows, "round \(round): chunking changed the result")
        }
    }
}
