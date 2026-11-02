import Foundation

/// What the capsule's find field asks of the hex view: bytes ("DE AD BE EF", "0xDEADBEEF"), text (any other words,
/// matched as UTF-8, ASCII letters in either case), or a jump (":4096", ":0x1000", the go-to prefix code 4 gives
/// lines). roadmap: S-5
public enum HexQuery: Sendable, Equatable {
    case bytes([UInt8])
    case text([UInt8], caseInsensitive: Bool)
    case offset(Int64)
    /// A go-to prefix with no readable offset after it.
    case invalidOffset

    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(":") {
            self = Self.offset(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)).map(HexQuery.offset) ?? .invalidOffset
            return
        }
        if let bytes = Self.hexBytes(trimmed) { self = .bytes(bytes); return }
        let utf8 = Array(raw.utf8)
        self = .text(utf8, caseInsensitive: utf8.contains { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) })
    }

    /// "4096" (decimal) or "0x1000" / "1000h" (hex).
    static func offset(_ s: String) -> Int64? {
        let t = s.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ",", with: "")
        if t.lowercased().hasPrefix("0x") { return Int64(t.dropFirst(2), radix: 16) }
        if t.lowercased().hasSuffix("h") { return Int64(t.dropLast(), radix: 16) }
        return Int64(t)
    }

    /// Two or more space-separated pairs of hex digits ("DE AD BE EF"), or 0x and an even run of them ("0xDEADBEEF").
    /// A lone word stays text, so "cafe" finds the word.
    static func hexBytes(_ s: String) -> [UInt8]? {
        func pairs<S: StringProtocol>(_ digits: S) -> [UInt8]? {
            guard !digits.isEmpty, digits.count.isMultiple(of: 2) else { return nil }
            var out: [UInt8] = []
            var i = digits.startIndex
            while i < digits.endIndex {
                let j = digits.index(i, offsetBy: 2)
                guard let b = UInt8(digits[i..<j], radix: 16) else { return nil }
                out.append(b)
                i = j
            }
            return out
        }
        if s.lowercased().hasPrefix("0x") { return pairs(s.dropFirst(2)) }
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 2, tokens.allSatisfy({ $0.count == 2 }) else { return nil }
        return pairs(tokens.joined())
    }

    /// The bytes searched for and whether ASCII letters match either case; nil for a jump.
    var pattern: (bytes: [UInt8], caseInsensitive: Bool)? {
        switch self {
        case .bytes(let b): return b.isEmpty ? nil : (b, false)
        case .text(let b, let ci): return b.isEmpty ? nil : (b, ci)
        case .offset, .invalidOffset: return nil
        }
    }
}

/// One streaming search's result: the match offsets (ascending, at most `limit`), how far it got, and why it stopped
/// early when it did. roadmap: S-5
public struct HexSearchOutcome: Sendable, Equatable {
    public var matches: [Int64]
    public var searched: Int64
    public var total: Int64
    public var cancelled: Bool
    /// More matches exist than were kept.
    public var capped: Bool
    public var complete: Bool { !cancelled && !capped }
}

/// Searches a source from start to end in chunks (4 MB by default), never holding more than one chunk, with progress
/// after each and a way to stop: `progress` returns false, or the surrounding task is cancelled. A match that straddles
/// two chunks is found once (the chunks overlap by the pattern's length less one). roadmap: S-5
public enum HexSearcher {
    public static let chunkSize = 4 * 1024 * 1024
    public static let matchLimit = 100_000

    public static func search(_ pattern: [UInt8], caseInsensitive: Bool, in source: HexByteSource,
                              chunkSize: Int = chunkSize, matchLimit: Int = matchLimit,
                              progress: (Int64) -> Bool = { _ in true }) -> HexSearchOutcome {
        var outcome = HexSearchOutcome(matches: [], searched: 0, total: source.count, cancelled: false, capped: false)
        guard !pattern.isEmpty, let reader = try? source.chunks() else { return outcome }
        let needle = caseInsensitive ? pattern.map(fold) : pattern
        var offset: Int64 = 0
        while offset < source.count {
            if Task.isCancelled { outcome.cancelled = true; return outcome }
            var chunk = reader.read(at: offset, length: chunkSize + needle.count - 1)
            if chunk.isEmpty { break }
            if caseInsensitive { for i in chunk.indices { chunk[i] = fold(chunk[i]) } }
            // Matches that start in this chunk's own span; the overlap's are the next chunk's.
            let ownSpan = min(chunkSize, chunk.count)
            chunk.withUnsafeBytes { hay in
                needle.withUnsafeBytes { nd in
                    guard let base = hay.baseAddress, let nbase = nd.baseAddress else { return }
                    var start = 0
                    while start < ownSpan, start + needle.count <= hay.count {
                        guard let hit = memmem(base + start, hay.count - start, nbase, needle.count) else { break }
                        let at = base.distance(to: UnsafeRawPointer(hit))
                        guard at < ownSpan else { break }
                        if outcome.matches.count >= matchLimit { outcome.capped = true; return }
                        outcome.matches.append(offset + Int64(at))
                        start = at + 1
                    }
                }
            }
            offset += Int64(chunkSize)
            outcome.searched = min(source.count, offset)
            if outcome.capped { return outcome }
            if !progress(outcome.searched) || Task.isCancelled {
                if outcome.searched < source.count { outcome.cancelled = true }
                return outcome
            }
        }
        outcome.searched = source.count
        return outcome
    }

    @inline(__always) static func fold(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b | 0x20 : b }
}
