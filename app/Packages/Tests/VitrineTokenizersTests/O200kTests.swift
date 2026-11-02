import CryptoKit
import Foundation
import Testing
@testable import VitrineTokenizers
import VitrineDocument

/// o200k_base counted on this Mac (A-4, G-29): the bundled file is tiktoken's (its published SHA-256), every token
/// boundary falls on the text's own bytes (a split that reassembles exactly), and the counts behave as a byte-level
/// BPE must. roadmap: S-21 (A-4)
struct O200kTests {
    static let tokenizer = O200kTokenizer.shared

    @Test func theBundledFileIsTiktokens() throws {
        let url = try #require(Bundle.module.url(forResource: "o200k_base", withExtension: "tiktoken")
                               ?? Bundle(for: Marker.self).url(forResource: "o200k_base", withExtension: "tiktoken"))
        let data = try Data(contentsOf: url)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(hex == O200kTokenizer.expectedSHA256)
    }

    @Test func theVocabularyLoads() throws {
        let t = try #require(Self.tokenizer)
        #expect(t.vocabularySize == 199_998)
        // Every single byte is a token: a byte-level BPE can always fall back to bytes.
        for b in 0...255 as ClosedRange<Int> {
            let one = [UInt8(b)]
            #expect(one.withUnsafeBufferPointer { t.rank($0) } != nil)
        }
    }

    @Test(arguments: [
        "hello world",
        "The harbour office publishes weekly tide tables, flagged in red for spring tides.",
        "func add(_ a: Int, _ b: Int) -> Int {\n    return a + b // sum\n}\n",
        "Ünïcödé — “quotes”, emoji 👩‍💻🚀, numbers 1234567 and 3.14159.",
        "潮汐表は毎週月曜日に公開されます。",
        "   leading spaces\n\n\ttabs\r\nand CRLF  ",
        "I'm sure they'll say we've done it, DON'T you think?",
    ])
    func splitsReassembleExactly(_ text: String) throws {
        let t = try #require(Self.tokenizer)
        let ranks = t.encode(text)
        let joined = ranks.flatMap { t.bytes(ofRank: $0) }
        #expect(joined == Array(text.utf8), "every token is the text's own bytes, in order")
        #expect(ranks.count == t.count(text))
        #expect(ranks.count <= text.utf8.count)
    }

    @Test func commonWordsAreSingleTokens() throws {
        let t = try #require(Self.tokenizer)
        #expect(t.count("hello world") == 2, "\"hello\" and \" world\" are each one token")
        // tiktoken's o200k_base ids for "hello world" as remembered (not from a published test): 24912, 2375.
        #expect(t.encode("hello world") == [24912, 2375])
        #expect(t.count("") == 0)
        #expect(t.count(" the") == 1)
    }

    @Test func theCounterIsExactAndCapped() {
        let counter = O200kCounter()
        let count = counter.count(.text("hello world"))
        #expect(count?.value == 2)
        #expect(count?.exactness == .exact)
        #expect(count?.method == O200kCounter.id)
        #expect(counter.count(.byteCount(10)) == nil, "an exact count needs the text")
        #expect(counter.count(.text(String(repeating: "a", count: O200kCounter.maxBytes + 1))) == nil)
    }

    @Test func aLongTextCountsQuickly() throws {
        let t = try #require(Self.tokenizer)
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20_000) // ~900 KB
        let start = Date()
        let n = t.count(text)
        let seconds = Date().timeIntervalSince(start)
        #expect(n > 100_000)
        #expect(seconds < 10, "counted \(n) tokens in \(seconds) s")
    }
}

private final class Marker {}
