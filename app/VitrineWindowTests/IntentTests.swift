import AppIntents
import AppKit
import PDFKit
import SQLite3
import XCTest
import VitrineDocument
import VitrinePreviewKit

/// Vitrine's App Intents (X-6): each action's perform on invented files written by the test into a temporary folder,
/// and the errors a person would read. No file is run, nothing is fetched, no window reaches a screen. roadmap: S-10
@MainActor
final class IntentTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-intents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func write(_ name: String, _ text: String) throws -> URL { try write(name, Data(text.utf8)) }

    private func file(_ url: URL) -> IntentFile { IntentFile(fileURL: url, filename: url.lastPathComponent) }

    private func assertThrows<T>(_ expected: VitrineIntentError, file: StaticString = #filePath, line: UInt = #line,
                                 _ body: () async throws -> T) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as VitrineIntentError {
            XCTAssertEqual(error, expected, file: file, line: line)
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "every error says a sentence", file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Describe File

    func testDescribeSaysKindFactsAndNotesAsTheConnectorDoes() async throws {
        let url = try write("harbor-notes.md", "---\ntitle: Harbor notes\n---\n# Harbor notes\n\nThe tide at Cascais rose to 2.4 m.\n\n- [ ] check the moorings\n")
        let intent = DescribeFileIntent()
        intent.file = file(url)
        let text = try await intent.run()
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Vitrine · harbor-notes.md")
        XCTAssertEqual(lines[1], "path: \(url.path)")
        XCTAssertTrue(lines[2].hasPrefix("kind: Markdown"), lines[2])
        XCTAssertTrue(text.contains("coverage: the whole file"), text)
        XCTAssertTrue(text.contains("facts:"), text)
        XCTAssertTrue(text.contains("views: "), text)
        _ = try await intent.perform()
    }

    func testDescribeReadsAFileThatArrivesAsDataAndLeavesNothingBehind() async throws {
        let intent = DescribeFileIntent()
        intent.file = IntentFile(data: Data("id,total\n1,2.50\n2,3.75\n".utf8), filename: "orders.csv")
        let text = try await intent.run()
        XCTAssertTrue(text.hasPrefix("Vitrine · orders.csv\npath: orders.csv\nkind: "), text)
        // The temporary copy is removed when the call ends.
        let leftovers = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-intents")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: leftovers.path)) ?? []
        for name in names {
            XCTAssertFalse(FileManager.default.fileExists(atPath: leftovers.appendingPathComponent(name).appendingPathComponent("orders.csv").path))
        }
    }

    func testAMissingFileAndNoFileSayWhatIsWrong() async throws {
        let intent = DescribeFileIntent()
        intent.file = file(folder.appendingPathComponent("gone.md"))
        await assertThrows(.unreadable(name: "gone.md")) { try await intent.run() }
        await assertThrows(.noFile) { try await IntentInput.with(nil) { _ in 0 } }
        XCTAssertEqual(IntentInput.safeName("../../etc/passwd"), "passwd", "a name from elsewhere never leaves the temporary folder")
        XCTAssertEqual(IntentInput.safeName(".."), String(localized: "Untitled", comment: "Name of a file handed to a Shortcuts action without a name."))
    }

    // MARK: Extract Table

    func testExtractTableFromCSVAsAFileAndAsText() async throws {
        let url = try write("orders.csv", "id,customer,note\n1,Ana,\"rope, 20 m\"\n2,Bruno,\"said \"\"soon\"\"\"\n3,Carla,\n")
        let intent = ExtractTableIntent()
        intent.file = file(url)
        intent.output = .csvFile
        intent.rowLimit = 1_000
        let csv = try await intent.run()
        XCTAssertEqual(csv.filename, "orders.csv")
        XCTAssertEqual(csv.type, .commaSeparatedText)
        XCTAssertEqual(String(decoding: csv.data, as: UTF8.self),
                       "id,customer,note\n1,Ana,\"rope, 20 m\"\n2,Bruno,\"said \"\"soon\"\"\"\n3,Carla,\n")

        intent.output = .text
        intent.rowLimit = 2
        let text = try await intent.run()
        XCTAssertEqual(text.filename, "orders.txt")
        XCTAssertEqual(String(decoding: text.data, as: UTF8.self),
                       "| id | customer | note |\n|---|---|---|\n| 1 | Ana | rope, 20 m |\n| 2 | Bruno | said \"soon\" |\n")
        _ = try await intent.perform()

        let capped = try TableExtraction.extract(url: url, name: "orders.csv", table: "ORDERS", limit: 2)
        XCTAssertEqual(capped.rows.count, 2)
        XCTAssertTrue(capped.hasMore)
        XCTAssertEqual(capped.totalRows, 3)
        await assertThrows(.tableNotFound(name: "orders.csv", requested: "invoices", available: ["orders"])) {
            try TableExtraction.extract(url: url, name: "orders.csv", table: "invoices", limit: 10)
        }
    }

    func testExtractTablePicksASQLiteTableByName() async throws {
        let url = folder.appendingPathComponent("shop.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE orders (id INTEGER PRIMARY KEY, total REAL, note TEXT);
        INSERT INTO orders VALUES (1, 2.5, 'rope'), (2, 3.75, NULL), (3, 10, 'chain, 5 m');
        CREATE TABLE customers (name TEXT, city TEXT);
        INSERT INTO customers VALUES ('Ana', 'Cascais'), ('Bruno', 'Porto');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let customers = try TableExtraction.extract(url: url, name: "shop.sqlite", table: "Customers", limit: 100)
        XCTAssertEqual(customers.name, "customers")
        XCTAssertEqual(customers.columns, ["name", "city"])
        XCTAssertEqual(customers.rows, [["Ana", "Cascais"], ["Bruno", "Porto"]])
        XCTAssertFalse(customers.hasMore)

        let intent = ExtractTableIntent()
        intent.file = file(url)
        intent.table = nil
        intent.output = .csvFile
        intent.rowLimit = 2
        let first = try await intent.run()
        XCTAssertEqual(first.filename, "orders.csv", "without a name, the first table")
        XCTAssertEqual(String(decoding: first.data, as: UTF8.self), "id,total,note\n1,2.5,rope\n2,3.75,\n")

        await assertThrows(.tableNotFound(name: "shop.sqlite", requested: "invoices", available: ["orders", "customers"])) {
            try TableExtraction.extract(url: url, name: "shop.sqlite", table: "invoices", limit: 10)
        }
    }

    func testExtractTableReadsAParquetFileAndAWorkbookSheet() async throws {
        let parquet = try write("trips.parquet", Data(TestParquet.file([
            TestParquetColumn(name: "trip_id", physical: .int64, optional: false, values: [.int(1), .int(2), .int(3)]),
            TestParquetColumn(name: "zone", physical: .byteArray, logical: .string, values: [.string("Harbour"), .null, .string("Old Town")]),
        ])))
        let trips = try TableExtraction.extract(url: parquet, name: "trips.parquet", table: "trips", limit: 2)
        XCTAssertEqual(trips.columns, ["trip_id", "zone"])
        XCTAssertEqual(trips.rows, [["1", "Harbour"], ["2", ""]])
        XCTAssertEqual(trips.totalRows, 3)
        XCTAssertTrue(trips.hasMore)

        let sales = "<sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" t=\"s\"><v>1</v></c></row>"
            + "<row r=\"2\"><c r=\"A2\" t=\"s\"><v>2</v></c><c r=\"B2\"><v>40</v></c></row></sheetData>"
        let other = "<sheetData><row r=\"1\"><c r=\"A1\"><v>1.5</v></c></row></sheetData>"
        let book = try write("book.xlsx", Data(TestXLSX.workbook(sheets: [("Sales", sales), ("Other", other)], sharedStrings: ["Region", "Units", "North"])))
        let sheet = try TableExtraction.extract(url: book, name: "book.xlsx", table: "sales", limit: 10)
        XCTAssertEqual(sheet.name, "Sales")
        XCTAssertEqual(sheet.columns, ["Region", "Units"])
        XCTAssertEqual(sheet.rows, [["North", "40"]])
        await assertThrows(.tableNotFound(name: "book.xlsx", requested: "Totals", available: ["Sales", "Other"])) {
            try TableExtraction.extract(url: book, name: "book.xlsx", table: "Totals", limit: 10)
        }
    }

    func testExtractTableRefusesAFileThatIsNotATable() async throws {
        let url = try write("notes.md", "# Not a table\n")
        let intent = ExtractTableIntent()
        intent.file = file(url)
        intent.output = .csvFile
        intent.rowLimit = 10
        await assertThrows(.notATable(name: "notes.md")) { try await intent.run() }
    }

    // MARK: Count Tokens

    func testCountTokensInTextUsesTheMetersCounter() async throws {
        let text = "The tide at Cascais rose to 2.4 m before the harbour gate closed."
        let intent = CountTokensIntent()
        intent.input = .text
        intent.text = text
        let (count, report) = try await intent.run()
        XCTAssertEqual(count, TokenCounting.count(.text(text)))
        XCTAssertTrue(count.isEstimate)
        XCTAssertTrue(report.hasPrefix(TokenMeter(count).number), report)
        XCTAssertTrue(report.contains(TokenMeter(count).method), report)
        _ = try await intent.perform()

        intent.text = ""
        await assertThrows(.noText) { try await intent.run() }
    }

    func testCountTokensInAFileIsTheCountThePreviewShows() async throws {
        let body = String(repeating: "Harbour log: the gate opened at dawn.\n", count: 40)
        let url = try write("log.md", body)
        let intent = CountTokensIntent()
        intent.input = .file
        intent.file = file(url)
        let (count, report) = try await intent.run()
        let preview = try await ConnectorWorker.document(for: url)
        XCTAssertEqual(count, preview.tokens, "the count Details' token meter shows")
        XCTAssertEqual(count, TokenCounting.count(.byteCount(body.utf8.count)))
        XCTAssertTrue(report.hasPrefix("log.md: "), report)

        intent.file = nil
        await assertThrows(.noFile) { try await intent.run() }
    }

    // MARK: Check Signature

    /// A 64-bit arm64 Mach-O header with no load commands: enough for the readers, never executed.
    private func machOBytes() -> Data {
        func word(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        return Data(word(0xFEED_FACF) + word(0x0100_000C) + word(0) + word(2) + word(0) + word(0) + word(0x0020_0085) + word(0) + [UInt8](repeating: 0, count: 64))
    }

    func testCheckSignatureOfAnUnsignedAppAndBinary() async throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.example.harbor", "CFBundleExecutable": "Harbor", "CFBundlePackageType": "APPL",
            "CFBundleName": "Harbor", "CFBundleShortVersionString": "1.0",
        ], format: .xml, options: 0)
        try write("Harbor.app/Contents/Info.plist", plist)
        try write("Harbor.app/Contents/MacOS/Harbor", machOBytes())
        let intent = CheckSignatureIntent()
        intent.file = file(folder.appendingPathComponent("Harbor.app"))
        let app = try await intent.run()
        XCTAssertEqual(app.kind, .app)
        XCTAssertNil(app.signer)
        XCTAssertNotEqual(app.state, .valid)
        XCTAssertTrue([.blocked, .brokenSignature].contains(app.gatekeeper), "\(app.gatekeeper)")
        XCTAssertFalse(app.quarantined)
        XCTAssertTrue(app.text.hasPrefix("Harbor.app · "), app.text)
        XCTAssertTrue(app.text.contains(app.gatekeeperWord), app.text)
        _ = try await intent.perform()

        let tool = try write("harbor-tool", machOBytes())
        intent.file = file(tool)
        let binary = try await intent.run()
        XCTAssertEqual(binary.kind, .binary)
        XCTAssertEqual(binary.ticket, .cannotStaple)
        XCTAssertNotEqual(binary.state, .valid)
    }

    func testCheckSignatureRefusesWhatIsNotCode() async throws {
        let url = try write("notes.txt", "hello")
        let intent = CheckSignatureIntent()
        intent.file = file(url)
        await assertThrows(.notSignable(name: "notes.txt")) { try await intent.run() }
    }

    func testTheGatekeeperRuleIsTheTrustCards() {
        // Who stands behind the signer is the anchor the requirements decided (G-34), never the certificate's name.
        var check = SignatureCheck(name: "Harbor.app", kind: .app, state: .valid, anchor: .developerID,
                                   signer: "Developer ID Application: Harbor Co (ABCDE12345)",
                                   chain: [], identifier: nil, team: "ABCDE12345", hardenedRuntime: true, ticket: .notarized,
                                   quarantined: true, downloadedFrom: "https://example.com/Harbor.dmg")
        XCTAssertEqual(check.gatekeeper, .opens)
        XCTAssertTrue(check.text.contains("https://example.com/Harbor.dmg"))
        check.ticket = .ticketUnverified
        XCTAssertEqual(check.gatekeeper, .checksOnline, "a ticket macOS did not verify never predicts “opens”")
        check.ticket = .notStapled
        XCTAssertEqual(check.gatekeeper, .checksOnline)
        check.anchor = .appleIssued
        XCTAssertEqual(check.gatekeeper, .otherIdentity, "only a Developer ID opens a download without asking")
        check.anchor = .notVouched
        check.ticket = .notarized
        XCTAssertEqual(check.gatekeeper, .otherIdentity, "a certificate Apple does not vouch for, whatever its name")
        check.state = .notVerified("an invented reason")
        XCTAssertEqual(check.gatekeeper, .unverified)
        check.state = .adHoc
        XCTAssertEqual(check.gatekeeper, .blocked)
        check.state = .unsigned
        XCTAssertEqual(check.gatekeeper, .blocked)
        check.state = .broken("a sealed resource is missing or invalid")
        XCTAssertEqual(check.gatekeeper, .brokenSignature)
        XCTAssertTrue(check.text.contains("a sealed resource is missing or invalid"))
    }

    // MARK: Convert

    func testConvertMarkdownToHTMLAndPDF() async throws {
        let url = try write("Tidepool.md", "# Tidepool\n\nThe tide at Cascais rose to **2.4 m**.\n\n```sh\nbrew install tidepool\n```\n")
        let intent = ConvertIntent()
        intent.file = file(url)
        intent.dark = false
        intent.format = .html
        let html = try await intent.run()
        XCTAssertEqual(html.filename, "Tidepool.html")
        XCTAssertEqual(html.type, .html)
        let page = String(decoding: html.data, as: UTF8.self)
        XCTAssertTrue(page.hasPrefix("<!doctype html>"))
        XCTAssertTrue(page.contains("<title>Tidepool.md</title>"))
        XCTAssertFalse(page.lowercased().contains("<script"), "no script travels")

        intent.format = .pdf
        let pdf = try await intent.run()
        XCTAssertEqual(pdf.filename, "Tidepool.pdf")
        let document = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertGreaterThanOrEqual(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("Cascais") == true)
        _ = try await intent.perform()
    }

    func testConvertAnyPreviewToPNGAndRefuseHTMLForNonMarkdown() async throws {
        let url = try write("orders.csv", "id,total\n1,2.50\n2,3.75\n")
        let intent = ConvertIntent()
        intent.file = file(url)
        intent.dark = true
        intent.format = .png
        let png = try await intent.run()
        XCTAssertEqual(png.filename, "orders.png")
        XCTAssertEqual(Array(png.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertGreaterThanOrEqual(NSBitmapImageRep(data: png.data)?.pixelsWide ?? 0, Int(ConvertIntent.pageSize.width))

        intent.format = .html
        await assertThrows(.needsMarkdown(name: "orders.csv")) { try await intent.run() }
    }

    // MARK: App Shortcuts

    func testEveryIntentHasAnAppShortcut() {
        XCTAssertEqual(VitrineShortcuts.appShortcuts.count, 5)
    }
}
