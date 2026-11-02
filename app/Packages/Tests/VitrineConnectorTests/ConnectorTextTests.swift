import Foundation
import Testing
import VitrineDocument
import VitrineSupport
@testable import VitrineConnector
import VitrineMCP

// What the connector's tools say (X-9, G-22). Every value below is invented; the keys have the form of real ones so
// the detectors see them. roadmap: S-11

@Suite("Connector text (X-9)")
struct ConnectorTextTests {
    static let key = "sk-ant-api03-OdR-zLBztqrYi_rvGbv_a_Qx0nby3pkIrvS2pn9v7rZHTaTc8eH2yOynBcI5AA"
    static let env = "# Tidepool settings\nREGION=lisbon\nAPI_KEY=LJa8hTgjUwSuWTMisdQwvcKw1bppqqWh\nclient = \"\(key)\"\n"

    @Test func describeSaysKindCoverageFactsNotesAndViews() {
        var document = PreviewDocument(kind: .csv(delimiter: ","), facts: [Fact(key: "rows", label: "Rows", value: "60,000")],
                                       badges: [Badge(level: .caution, title: "Ragged rows", detail: "3 rows have 4 cells")],
                                       views: [.text("a,b")], coverage: .partial(shown: 200, total: 60_000, unit: .rows, reason: "the first rows"))
        document.viewTitles = ["Table", "Text"]
        let text = ConnectorText.describe(document, name: "trips.csv", path: "/tmp/trips.csv")
        #expect(text.contains("kind: CSV (csv"))
        #expect(text.contains("coverage: partial: 200 of 60,000 rows shown (the first rows)"))
        #expect(text.contains("  Rows: 60,000"))
        #expect(text.contains("  [caution] Ragged rows: 3 rows have 4 cells"))
        #expect(text.hasSuffix("views: Table, Text"))
    }

    @Test func pagesAreNumberedAndSayWhatFollows() {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let page = ConnectorText.page(text, name: "a.txt", kind: "Text", offset: 2, limit: 3, maskedCount: 0, coverage: .complete)
        let lines = page.components(separatedBy: "\n")
        #expect(lines[0] == "a.txt · Text · lines 3–5 of 10")
        #expect(lines[1] == "3  line 3" && lines[3] == "5  line 5")
        #expect(lines.last == "… 5 more lines; call render with offset 5 for the next page.")
        let past = ConnectorText.page(text, name: "a.txt", kind: "Text", offset: 99, limit: 3, maskedCount: 0, coverage: .complete)
        #expect(past.hasPrefix("a.txt · Text · offset 99 is past the last line (10)"))
        let empty = ConnectorText.page("", name: "a.bin", kind: "Binary", offset: 0, limit: 3, maskedCount: 0, coverage: .complete)
        #expect(empty.contains("no text"))
    }

    @Test func aPageStopsAtTheCharacterCap() {
        let text = (1...100).map { _ in String(repeating: "x", count: 50) }.joined(separator: "\n")
        let page = ConnectorText.page(text, name: "a", kind: "Text", offset: 0, limit: 100, maxCharacters: 500, maskedCount: 0, coverage: .complete)
        #expect(page.count < 700)
        #expect(page.contains("more lines; call render with offset"))
    }

    @Test func secretsAreMaskedInTheTextAndTheRestStays() throws {
        let (text, count) = ConnectorText.masked(Self.env, scanner: try ConnectorText.scanner())
        #expect(count == 2)
        #expect(!text.contains("LJa8hTgj") && !text.contains("OdR-zLBz"))
        #expect(text.contains("REGION=lisbon") && text.contains("API_KEY=•"))
        #expect(text.hasSuffix("\n"))
    }

    @Test func theReportNamesEachFindingWithoutItsValue() throws {
        let report = ConnectorText.secretsReport(Self.env, name: ".env", scanner: try ConnectorText.scanner(), coverage: .complete)
        #expect(report.hasPrefix("Secrets in .env: 2 found in 4 lines (every line checked)"))
        #expect(report.contains("- line 3 · "))
        #expect(report.contains("- line 4 · ") && report.contains("(ai, "))
        #expect(!report.contains("LJa8hTgj") && !report.contains(Self.key))
        let clean = ConnectorText.secretsReport("REGION=lisbon\n", name: "a.env", scanner: try ConnectorText.scanner(), coverage: .complete)
        #expect(clean.hasPrefix("Secrets in a.env: none found in 1 line (every line checked)"))
    }

    @Test func anOverLongLineIsNeverCalledClean() throws {
        let long = "data=" + String(repeating: "a", count: 5_000)
        let report = ConnectorText.secretsReport(long, name: "a", scanner: try ConnectorText.scanner(), coverage: .complete)
        #expect(report.contains("1 line not checked: too long"))
        let (text, count) = ConnectorText.masked(long, scanner: try ConnectorText.scanner())
        #expect(count == 1 && text.hasPrefix("[line not checked for secrets"))
    }

    @Test func tokensAreALabelledEstimate() {
        let text = String(repeating: "word ", count: 100)
        let out = ConnectorText.tokens(text, name: "a.md", fileBytes: 900, coverage: .complete)
        #expect(out.hasPrefix("a.md: about 125 tokens (estimate"))
        #expect(out.contains("words: 100"))
        #expect(out.contains("the file is 900 bytes; the count is of the text Vitrine reads from it"))
    }
}
