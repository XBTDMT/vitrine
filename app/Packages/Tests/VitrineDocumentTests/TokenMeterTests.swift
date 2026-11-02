import XCTest
@testable import VitrineDocument
import VitrineSupport

/// A-4: the token counter abstraction, the `tokens` fact and the context-fit meter's rows. Invented text only.
final class TokenMeterTests: XCTestCase {
    func testTheEstimateIsAboutFourBytesAToken() {
        let counter = ByteEstimateCounter()
        XCTAssertEqual(counter.count(.byteCount(0))?.value, 0)
        XCTAssertEqual(counter.count(.byteCount(1))?.value, 1, "a non-empty text is never 0 tokens")
        XCTAssertEqual(counter.count(.byteCount(4))?.value, 1)
        XCTAssertEqual(counter.count(.byteCount(10))?.value, 3)
        XCTAssertEqual(counter.count(.byteCount(12_720))?.value, 3_180)
        // Text is counted by its UTF-8 bytes: "é" is two.
        XCTAssertEqual(counter.count(.text("café au lait"))?.value, counter.count(.byteCount(13))?.value)
        XCTAssertEqual(counter.count(.text(""))?.exactness, .estimate)
        XCTAssertEqual(counter.count(.text("x"))?.method, ByteEstimateCounter.id)
    }

    func testTheFactIsUnchangedForTheDefaultCounter() {
        // The pill and Recent Previews read this value; it must say what it said before the counter existed.
        XCTAssertEqual(DocumentFacts.tokens(bytes: 12_720).value, "≈ " + 3_180.formatted())
        XCTAssertEqual(DocumentFacts.tokens(bytes: 0).value, "≈ 0")
        XCTAssertEqual(DocumentFacts.tokens(TokenCount(value: 3_052, exactness: .exact, method: "test.exact")).value, 3_052.formatted(),
                       "an exact count carries no ≈")
    }

    func testSetTokensKeepsTheFactInStep() {
        var doc = PreviewDocument(kind: .plainText, facts: [Fact(key: "size", label: "Size", value: "1 KB"), DocumentFacts.tokens(bytes: 8)],
                                  views: [.text("A tide table for Tidepool Bay.")])
        doc.setTokens(TokenCounting.count(.byteCount(4_000)))
        XCTAssertEqual(doc.tokens?.value, 1_000)
        XCTAssertEqual(doc.facts.filter { $0.key == "tokens" }.count, 1, "the fact is replaced, not repeated")
        XCTAssertEqual(doc.fact("tokens")?.value, "≈ " + 1_000.formatted())
        XCTAssertEqual(doc.facts.first?.key, "size", "the other facts keep their place")
    }

    func testTheCountSurvivesARoundTrip() throws {
        var doc = PreviewDocument(kind: .plainText, views: [.text("Low tide at 06:12.")])
        doc.setTokens(TokenCounting.count(.text("Low tide at 06:12.")))
        XCTAssertEqual(try JSONDecoder().decode(PreviewDocument.self, from: JSONEncoder().encode(doc)), doc)
        let plain = PreviewDocument(kind: .plainText, views: [.text("x")])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("tokens"),
                       "a document without a count encodes as it did before")
    }

    func testRowsFollowTheDesignsWindows() {
        let meter = TokenMeter(TokenCounting.count(.byteCount(12_720)))
        XCTAssertEqual(meter.rows.map(\.window), [200_000, 1_000_000])
        XCTAssertEqual(meter.number, "≈ " + 3_180.formatted())
        XCTAssertEqual(meter.unit, "Claude tokens, estimate")
        XCTAssertTrue(meter.method.contains("4 bytes a token"), meter.method)
        XCTAssertTrue(meter.rows.allSatisfy(\.fits))
        XCTAssertEqual(meter.rows[0].text, "\(0.0159.formatted(.percent.precision(.fractionLength(1)))) of a 200K window")
        XCTAssertEqual(meter.rows[0].fill, 0.0159, accuracy: 0.0001)
        XCTAssertEqual(meter.rows[1].text, "\(0.00318.formatted(.percent.precision(.fractionLength(1)))) of a 1M window")
    }

    func testTinyAndLargeShares() {
        let tiny = TokenMeter(TokenCount(value: 40, exactness: .estimate, method: ByteEstimateCounter.id))
        XCTAssertTrue(tiny.rows[0].text.hasPrefix("under "), tiny.rows[0].text)
        XCTAssertEqual(tiny.rows[1].compactText, "under \(0.001.formatted(.percent.precision(.fractionLength(1)))) of 1M")
        XCTAssertGreaterThan(tiny.rows[0].fill, 0)
        let half = TokenMeter(TokenCount(value: 120_000, exactness: .estimate, method: ByteEstimateCounter.id))
        XCTAssertEqual(half.rows[0].text, "\(0.6.formatted(.percent.precision(.fractionLength(0)))) of a 200K window",
                       "10% and above drop the decimal")
        let empty = TokenMeter(TokenCount(value: 0, exactness: .estimate, method: ByteEstimateCounter.id))
        XCTAssertEqual(empty.rows[0].fill, 0)
        XCTAssertFalse(empty.rows[0].text.hasPrefix("under"), "nothing is 0%, not under 0.1%")
    }

    func testOverWindowStates() {
        let big = TokenMeter(TokenCount(value: 480_000, exactness: .estimate, method: ByteEstimateCounter.id))
        XCTAssertFalse(big.rows[0].fits)
        XCTAssertEqual(big.rows[0].fill, 1, "the bar is full, never past its end")
        let times = 2.4.formatted(.number.precision(.fractionLength(1)))
        XCTAssertEqual(big.rows[0].text, "Over a 200K window (\(times)×)")
        XCTAssertEqual(big.rows[0].compactText, "Over 200K (\(times)×)")
        XCTAssertTrue(big.rows[1].fits)
        XCTAssertEqual(big.rows[1].compactText, "\(0.48.formatted(.percent.precision(.fractionLength(0)))) of 1M")
        let exactlyFull = TokenMeter(TokenCount(value: 200_000, exactness: .estimate, method: ByteEstimateCounter.id))
        XCTAssertTrue(exactlyFull.rows[0].fits, "a text the window's size still fits")
        let huge = TokenMeter(TokenCount(value: 2_500_000, exactness: .estimate, method: ByteEstimateCounter.id))
        XCTAssertEqual(huge.rows.filter(\.fits).count, 0)
    }

    func testAnExactCounterNeedsNoMeterChange() {
        struct WordCounter: TokenCounter {
            var id: String { "test.words" }
            var exactness: TokenCount.Exactness { .exact }
            var methodDescription: String { "Counted word by word." }
            func count(_ source: TokenSource) -> TokenCount? {
                guard case .text(let text) = source else { return nil }
                return TokenCount(value: text.split(separator: " ").count, exactness: .exact, method: id)
            }
        }
        let counter = WordCounter()
        XCTAssertNil(counter.count(.byteCount(100)), "an exact counter cannot count from a size alone")
        let count = try! XCTUnwrap(counter.count(.text("the tide turns at noon")))
        let meter = TokenMeter(count)
        XCTAssertEqual(meter.number, "5", "no ≈ on an exact count")
        XCTAssertEqual(meter.unit, "tokens, exact")
        XCTAssertEqual(meter.method, "Counted with a tokenizer.", "a counter this build does not list is still named as exact")
        XCTAssertTrue(meter.accessibilityLabel.hasPrefix("5 tokens, exact"))
    }
}
