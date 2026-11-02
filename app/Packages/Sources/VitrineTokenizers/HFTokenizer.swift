import Foundation
import VitrineDocument

/// A Hugging Face `tokenizer.json` read on this Mac (A-4, G-29 route C): when a model's tokenizer sits beside the file,
/// the meter can count that model's tokens exactly. Only byte-level BPE is supported — the GPT-2 family, Llama 3, Qwen,
/// Mistral Tekken — with the ByteLevel pre-tokenizer (or a Split regex followed by it) and an optional NFC normaliser;
/// any other model, normaliser or pre-tokenizer makes `init` return nil, so the meter never shows a count it cannot
/// stand behind. Added (special) tokens in the text are counted as ordinary text. roadmap: S-21 (A-4)
public final class HFTokenizer: @unchecked Sendable {
    /// The GPT-2 split, which ByteLevel uses when `use_regex` is on.
    static let gpt2Pattern = #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#
    /// tokenizer.json files over this size are not read in a preview.
    public static let maxFileBytes = 64 * 1024 * 1024

    private let vocab: [String: Int]
    private let mergeRanks: [String: Int]   // "left right" → rank
    private let splitters: [NSRegularExpression]
    private let addPrefixSpace: Bool
    private let nfc: Bool
    private let ignoreMerges: Bool
    /// A short name for the meter: the folder the tokenizer sits in, or the model's own name when it gives one.
    public let name: String

    /// GPT-2's byte → printable character table (`bytes_to_unicode`).
    static let byteToUnicode: [Character] = {
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) { bs.append(b); cs.append(256 + n); n += 1 }
        var table = [Character](repeating: " ", count: 256)
        for (b, c) in zip(bs, cs) { table[b] = Character(Unicode.Scalar(c)!) }
        return table
    }()

    public convenience init?(url: URL) {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maxFileBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data, name: url.deletingLastPathComponent().lastPathComponent)
    }

    init?(data: Data, name: String) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any], (model["type"] as? String) == "BPE",
              let vocab = model["vocab"] as? [String: Int], !vocab.isEmpty else { return nil }
        // Merges come as "a b" strings (older files) or ["a", "b"] pairs (newer).
        var ranks: [String: Int] = [:]
        if let merges = model["merges"] as? [Any] {
            for (rank, m) in merges.enumerated() {
                if let s = m as? String { ranks[s] = rank }
                else if let pair = m as? [String], pair.count == 2 { ranks[pair[0] + " " + pair[1]] = rank }
                else { return nil }
            }
        } else { return nil }
        // Byte fallback and continuing-subword prefixes belong to other families.
        if (model["byte_fallback"] as? Bool) == true { return nil }
        if let p = model["continuing_subword_prefix"] as? String, !p.isEmpty { return nil }
        if let p = model["end_of_word_suffix"] as? String, !p.isEmpty { return nil }

        // Normaliser: none, NFC, or a sequence of NFC only.
        var nfc = false
        if let normalizer = root["normalizer"] as? [String: Any] {
            func accept(_ n: [String: Any]) -> Bool {
                switch n["type"] as? String {
                case "NFC": nfc = true; return true
                case "Sequence": return ((n["normalizers"] as? [[String: Any]]) ?? []).allSatisfy(accept)
                default: return false
                }
            }
            guard accept(normalizer) else { return nil }
        }

        // Pre-tokenizer: ByteLevel, or a Sequence of Split regexes ending in ByteLevel(use_regex: false).
        var splitters: [NSRegularExpression] = []
        var addPrefixSpace = false
        guard let pre = root["pre_tokenizer"] as? [String: Any] else { return nil }
        func byteLevel(_ p: [String: Any]) -> Bool {
            guard p["type"] as? String == "ByteLevel" else { return false }
            addPrefixSpace = p["add_prefix_space"] as? Bool ?? false
            if p["use_regex"] as? Bool ?? true, let re = try? NSRegularExpression(pattern: Self.gpt2Pattern) { splitters.append(re) }
            return true
        }
        switch pre["type"] as? String {
        case "ByteLevel":
            guard byteLevel(pre) else { return nil }
        case "Sequence":
            guard let steps = pre["pretokenizers"] as? [[String: Any]], let last = steps.last else { return nil }
            for step in steps.dropLast() {
                guard step["type"] as? String == "Split", (step["behavior"] as? String) == "Isolated", (step["invert"] as? Bool) != true,
                      let pattern = (step["pattern"] as? [String: Any])?["Regex"] as? String,
                      let re = try? NSRegularExpression(pattern: pattern) else { return nil }
                splitters.append(re)
            }
            guard byteLevel(last) else { return nil }
        default:
            return nil
        }
        self.vocab = vocab
        self.mergeRanks = ranks
        self.splitters = splitters
        self.addPrefixSpace = addPrefixSpace
        self.nfc = nfc
        self.ignoreMerges = model["ignore_merges"] as? Bool ?? false
        self.name = name
    }

    /// Cuts `text` with each splitter in turn; with "Isolated", both the matches and the text between them are pieces.
    private func pieces(_ text: String) -> [String] {
        var current = [text]
        for re in splitters {
            var next: [String] = []
            for piece in current {
                let ns = piece as NSString
                var last = 0
                for m in re.matches(in: piece, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                    if m.range.location > last { next.append(ns.substring(with: NSRange(location: last, length: m.range.location - last))) }
                    next.append(ns.substring(with: m.range))
                    last = m.range.location + m.range.length
                }
                if last < ns.length { next.append(ns.substring(from: last)) }
            }
            current = next
        }
        return current
    }

    /// The token strings one piece becomes: its bytes mapped to GPT-2's alphabet, then merges by rank.
    func tokens(ofPiece piece: String) -> [String] {
        let word = String(piece.utf8.map { Self.byteToUnicode[Int($0)] })
        if ignoreMerges, vocab[word] != nil { return [word] }
        var symbols = word.map(String.init)
        while symbols.count > 1 {
            var best = (rank: Int.max, index: -1)
            for i in 0..<(symbols.count - 1) {
                if let r = mergeRanks[symbols[i] + " " + symbols[i + 1]], r < best.rank { best = (r, i) }
            }
            guard best.index >= 0 else { break }
            let left = symbols[best.index], right = symbols[best.index + 1]
            var merged: [String] = []
            merged.reserveCapacity(symbols.count)
            var i = 0
            while i < symbols.count {
                if i < symbols.count - 1, symbols[i] == left, symbols[i + 1] == right { merged.append(left + right); i += 2 }
                else { merged.append(symbols[i]); i += 1 }
            }
            symbols = merged
        }
        return symbols
    }

    public func tokens(_ text: String) -> [String] {
        var input = nfc ? text.precomposedStringWithCanonicalMapping : text
        if addPrefixSpace, !input.hasPrefix(" ") { input = " " + input }
        return pieces(input).flatMap { tokens(ofPiece: $0) }
    }

    public func count(_ text: String) -> Int { tokens(text).count }

    /// The tokenizer.json in the file's own folder, if there is one Vitrine can read.
    public static func beside(_ file: URL) -> HFTokenizer? {
        let candidate = file.deletingLastPathComponent().appendingPathComponent("tokenizer.json")
        guard candidate.standardizedFileURL != file.standardizedFileURL,
              FileManager.default.isReadableFile(atPath: candidate.path) else { return nil }
        return HFTokenizer(url: candidate)
    }
}
