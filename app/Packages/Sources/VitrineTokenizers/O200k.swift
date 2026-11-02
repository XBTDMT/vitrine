import Foundation
import VitrineDocument

/// OpenAI's o200k_base tokenizer (GPT-4o and the o-series), counted exactly on this Mac (A-4, G-29, ruled
/// 2026-11-01). The ranks are tiktoken's file, bundled verbatim and checked against tiktoken's published SHA-256; the
/// counting is Vitrine's own Swift following tiktoken's algorithm: the o200k pre-split pattern, then byte-pair merges
/// by rank (`_byte_pair_merge`). It only counts; nothing is sent anywhere. roadmap: S-21 (A-4)
public final class O200kTokenizer: @unchecked Sendable {
    /// tiktoken's `pat_str` for o200k_base, its seven alternatives joined with `|` (tiktoken_ext/openai_public.py).
    static let pattern = [
        #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?"#,
        #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?"#,
        #"\p{N}{1,3}"#,
        #" ?[^\s\p{L}\p{N}]+[\r\n/]*"#,
        #"\s*[\r\n]+"#,
        #"\s+(?!\S)"#,
        #"\s+"#,
    ].joined(separator: "|")

    /// tiktoken's expected hash for the bundled file; the loader refuses any other bytes.
    public static let expectedSHA256 = "446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d"

    /// Every token's bytes, back to back; `offsets[r]..<offsets[r + 1]` is the token of rank r.
    private let blob: [UInt8]
    private let offsets: [Int32]
    /// Open addressing over token bytes → rank; -1 is empty.
    private let table: [Int32]
    private let mask: Int
    private let regex: NSRegularExpression

    public var vocabularySize: Int { offsets.count - 1 }

    /// The bundled o200k_base, loaded once per process on first use; nil if the resource is missing or altered.
    public static let shared: O200kTokenizer? = {
        guard let url = Bundle.module.url(forResource: "o200k_base", withExtension: "tiktoken"),
              let data = try? Data(contentsOf: url) else { return nil }
        return O200kTokenizer(tiktoken: data)
    }()

    /// Parses a `.tiktoken` file ("<base64 bytes> <rank>" per line, ranks 0…n-1 in order).
    init?(tiktoken data: Data) {
        guard let regex = try? NSRegularExpression(pattern: Self.pattern) else { return nil }
        self.regex = regex
        var blob: [UInt8] = []
        blob.reserveCapacity(data.count / 2)
        var offsets: [Int32] = [0]
        offsets.reserveCapacity(210_000)
        var expectedRank = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let space = line.firstIndex(of: UInt8(ascii: " ")),
                  let rank = Int(String(decoding: line[line.index(after: space)...], as: UTF8.self)),
                  rank == expectedRank,
                  let bytes = Data(base64Encoded: Data(line[line.startIndex..<space])) else { return nil }
            blob.append(contentsOf: bytes)
            offsets.append(Int32(blob.count))
            expectedRank += 1
        }
        guard expectedRank > 256 else { return nil }
        var size = 1
        while size < expectedRank * 2 { size <<= 1 }
        var table = [Int32](repeating: -1, count: size)
        let mask = size - 1
        blob.withUnsafeBufferPointer { b in
            for rank in 0..<expectedRank {
                let start = Int(offsets[rank]), end = Int(offsets[rank + 1])
                var slot = Self.hash(UnsafeBufferPointer(rebasing: b[start..<end])) & mask
                while table[slot] != -1 { slot = (slot + 1) & mask }
                table[slot] = Int32(rank)
            }
        }
        self.blob = blob
        self.offsets = offsets
        self.table = table
        self.mask = mask
    }

    /// FNV-1a, 64-bit.
    private static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(truncatingIfNeeded: h)
    }

    /// The rank of exactly these bytes, nil when they are not one token.
    func rank(_ bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        var slot = Self.hash(bytes) & mask
        return blob.withUnsafeBufferPointer { b in
            while true {
                let r = Int(table[slot])
                if r < 0 { return nil }
                let start = Int(offsets[r]), end = Int(offsets[r + 1])
                if end - start == bytes.count, memcmp(b.baseAddress! + start, bytes.baseAddress!, bytes.count) == 0 { return r }
                slot = (slot + 1) & mask
            }
        }
    }

    /// The token bytes of a rank (for round-trip checks).
    func bytes(ofRank rank: Int) -> [UInt8] { Array(blob[Int(offsets[rank])..<Int(offsets[rank + 1])]) }

    /// tiktoken's `_byte_pair_merge`: the start of each token the piece splits into (plus the end).
    func mergeBoundaries(_ piece: UnsafeBufferPointer<UInt8>) -> [Int] {
        let n = piece.count
        if n == 1 { return [0, 1] }
        func pairRank(_ a: Int, _ b: Int) -> Int { rank(UnsafeBufferPointer(rebasing: piece[a..<b])) ?? Int.max }
        var parts: [(start: Int, rank: Int)] = []
        parts.reserveCapacity(n + 1)
        var minRank = (rank: Int.max, index: -1)
        for i in 0..<(n - 1) {
            let r = pairRank(i, i + 2)
            if r < minRank.rank { minRank = (r, i) }
            parts.append((i, r))
        }
        parts.append((n - 1, Int.max))
        parts.append((n, Int.max))
        func rankAt(_ i: Int) -> Int { i + 3 < parts.count ? pairRank(parts[i].start, parts[i + 3].start) : Int.max }
        while minRank.rank != Int.max {
            let i = minRank.index
            if i > 0 { parts[i - 1].rank = rankAt(i - 1) }
            parts[i].rank = rankAt(i)
            parts.remove(at: i + 1)
            minRank = (Int.max, -1)
            for j in 0..<(parts.count - 1) where parts[j].rank < minRank.rank { minRank = (parts[j].rank, j) }
        }
        return parts.map(\.start)
    }

    /// The text split as o200k splits it, then each piece into tokens; returns the ranks (ordinary text, no special
    /// tokens).
    public func encode(_ text: String) -> [Int] {
        var ranks: [Int] = []
        forEachPiece(text) { piece in
            if let r = rank(piece) { ranks.append(r); return }
            let bounds = mergeBoundaries(piece)
            for k in 0..<(bounds.count - 1) {
                if let r = rank(UnsafeBufferPointer(rebasing: piece[bounds[k]..<bounds[k + 1]])) { ranks.append(r) }
            }
        }
        return ranks
    }

    /// The number of tokens, without keeping them.
    public func count(_ text: String) -> Int {
        var total = 0
        forEachPiece(text) { piece in
            total += rank(piece) != nil ? 1 : mergeBoundaries(piece).count - 1
        }
        return total
    }

    private func forEachPiece(_ text: String, _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        let ns = text as NSString
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.range.length > 0 else { return }
            let piece = Array(ns.substring(with: match.range).utf8)
            piece.withUnsafeBufferPointer { body($0) }
        }
    }
}

/// The o200k counter for the token meter (TokenCounting.all): exact OpenAI counts for text up to `maxBytes`.
public struct O200kCounter: TokenCounter {
    public static let id = "openai.o200k_base"
    /// Beyond this, counting would take too long in a preview; the meter keeps its estimate.
    public static let maxBytes = 4 * 1024 * 1024

    public init() {}

    public var id: String { Self.id }
    public var exactness: TokenCount.Exactness { .exact }
    public var methodDescription: String {
        String(localized: "Counted exactly with OpenAI's o200k_base tokenizer (GPT-4o and the o-series), on this Mac.", bundle: .module,
               comment: "Token meter foot for the exact OpenAI count. Product and tokenizer names stay as they are.")
    }

    public func count(_ source: TokenSource) -> TokenCount? {
        guard case .text(let text) = source, text.utf8.count <= Self.maxBytes, let tokenizer = O200kTokenizer.shared else { return nil }
        return TokenCount(value: tokenizer.count(text), exactness: .exact, method: Self.id)
    }
}
