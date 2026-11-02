import Foundation
import Testing
@testable import VitrineTokenizers

/// Hugging Face tokenizer.json files, byte-level BPE (A-4, G-29 route C), on small hand-made files whose results are
/// worked out by hand: merges apply by rank, "Ġ" stands for a space, ignore_merges takes a whole word from the
/// vocabulary, Split regexes cut before ByteLevel, NFC composes first, and every other family declines (nil) rather
/// than show a count it cannot stand behind. roadmap: S-21 (A-4)
struct HFTokenizerTests {
    /// A tiny GPT-2-style tokenizer: merges h+e, l+l, he+ll, hell+o, Ġ+w, Ġw+o, Ġwo+r, Ġwor+l, Ġworl+d.
    static func gpt2Style(merges: [String] = ["h e", "l l", "he ll", "hell o", "Ġ w", "Ġw o", "Ġwo r", "Ġwor l", "Ġworl d"],
                          pre: [String: Any] = ["type": "ByteLevel", "add_prefix_space": false, "use_regex": true],
                          extraModel: [String: Any] = [:], normalizer: Any = NSNull()) -> Data {
        var vocab: [String: Int] = [:]
        for (i, b) in (0..<256).enumerated() { vocab[String(HFTokenizer.byteToUnicode[b])] = i }
        for m in merges { vocab[m.replacingOccurrences(of: " ", with: "")] = vocab.count }
        var model: [String: Any] = ["type": "BPE", "vocab": vocab, "merges": merges]
        for (k, v) in extraModel { model[k] = v }
        let root: [String: Any] = ["version": "1.0", "normalizer": normalizer, "pre_tokenizer": pre, "model": model]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    @Test func mergesApplyByRankAndSpacesBecomeG() throws {
        let t = try #require(HFTokenizer(data: Self.gpt2Style(), name: "tiny"))
        #expect(t.tokens("hello world") == ["hello", "Ġworld"])
        #expect(t.count("hello world") == 2)
        #expect(t.tokens("hello!") == ["hello", "!"])
        #expect(t.count("") == 0)
    }

    @Test func unknownPairsStayAsBytes() throws {
        let t = try #require(HFTokenizer(data: Self.gpt2Style(), name: "tiny"))
        #expect(t.tokens("xyz") == ["x", "y", "z"])
        #expect(t.count("é") == 2, "two UTF-8 bytes, no merge for them")
    }

    @Test func addPrefixSpaceAndIgnoreMerges() throws {
        let prefixed = try #require(HFTokenizer(data: Self.gpt2Style(pre: ["type": "ByteLevel", "add_prefix_space": true]), name: "p"))
        #expect(prefixed.tokens("world") == ["Ġworld"])
        // With ignore_merges, a word the vocabulary holds whole is one token even without a merge path to it.
        let whole = try #require(HFTokenizer(data: Self.gpt2Style(merges: ["h e"], extraModel: ["ignore_merges": true]), name: "w"))
        #expect(whole.tokens("he") == ["he"])
        #expect(whole.tokens("hex") == ["he", "x"])
    }

    @Test func aSplitRegexCutsBeforeByteLevel() throws {
        let pre: [String: Any] = ["type": "Sequence", "pretokenizers": [
            ["type": "Split", "pattern": ["Regex": "\\d"], "behavior": "Isolated", "invert": false],
            ["type": "ByteLevel", "add_prefix_space": false, "use_regex": false],
        ]]
        let t = try #require(HFTokenizer(data: Self.gpt2Style(merges: ["1 2"], pre: pre), name: "s"))
        #expect(t.tokens("a12b") == ["a", "1", "2", "b"], "each digit is its own piece, so 1+2 never merges")
    }

    @Test func nfcComposesFirst() throws {
        let t = try #require(HFTokenizer(data: Self.gpt2Style(normalizer: ["type": "NFC"]), name: "n"))
        #expect(t.count("e\u{0301}") == t.count("é"), "decomposed é counts as the composed one")
    }

    @Test func otherFamiliesDecline() {
        #expect(HFTokenizer(data: Self.gpt2Style(extraModel: ["byte_fallback": true]), name: "sp") == nil, "SentencePiece-style byte fallback")
        #expect(HFTokenizer(data: Self.gpt2Style(normalizer: ["type": "Lowercase"]), name: "l") == nil)
        #expect(HFTokenizer(data: Self.gpt2Style(pre: ["type": "Metaspace"]), name: "m") == nil)
        let unigram = try! JSONSerialization.data(withJSONObject: ["model": ["type": "Unigram", "vocab": [["a", -1.0]]]])
        #expect(HFTokenizer(data: unigram, name: "u") == nil)
        #expect(HFTokenizer(data: Data("not json".utf8), name: "x") == nil)
    }

    @Test func theTokenizerBesideAFileIsFound() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-hf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = dir.appendingPathComponent("prompt.txt")
        try "hello world".write(to: doc, atomically: true, encoding: .utf8)
        #expect(HFTokenizer.beside(doc) == nil, "no tokenizer.json yet")
        try Self.gpt2Style().write(to: dir.appendingPathComponent("tokenizer.json"))
        let t = try #require(HFTokenizer.beside(doc))
        #expect(t.count("hello world") == 2)
        #expect(t.name == dir.lastPathComponent)
    }
}
