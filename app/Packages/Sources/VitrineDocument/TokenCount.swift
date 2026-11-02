import Foundation

/// Token counts for language models (A-4; chrome r3-b's inspector "Tokens" section, ai r3-b "Count honesty"). A count
/// says whether it is exact and which counter made it, so every surface can label an estimate as one. Counters sit
/// behind `TokenCounter`: the shipped default estimates from bytes; an exact counter (a public tokenizer such as
/// OpenAI's o200k_base, or a `tokenizer.json` beside the file) joins `TokenCounting.all` without touching the meter.
/// roadmap: S-21

/// One count of a text's tokens.
public struct TokenCount: Sendable, Equatable, Codable {
    public enum Exactness: String, Sendable, Codable {
        /// A heuristic: no tokenizer ran (Claude's tokenizer is not public).
        case estimate
        /// A real tokenizer ran over the text.
        case exact
    }

    public var value: Int
    public var exactness: Exactness
    /// The counter's stable id (`TokenCounter.id`), so the method can be named after a round trip.
    public var method: String

    public init(value: Int, exactness: Exactness, method: String) {
        self.value = max(0, value); self.exactness = exactness; self.method = method
    }

    public var isEstimate: Bool { exactness == .estimate }

    /// The number as people read it: "≈ 3,180" for an estimate, "3,052" for an exact count.
    public var formatted: String {
        let number = value.formatted()
        return isEstimate
            ? String(localized: "≈ \(number)", bundle: .module, comment: "An approximate count; the argument is a formatted number.")
            : number
    }
}

/// What a counter is given: the text itself, or only its size when the text was not read whole (a huge file).
public enum TokenSource: Sendable {
    case text(String)
    case byteCount(Int)

    var byteCount: Int {
        switch self {
        case .text(let s): s.utf8.count
        case .byteCount(let n): n
        }
    }
}

/// Something that counts tokens. Exact counters need the text and return nil for `.byteCount`.
public protocol TokenCounter: Sendable {
    /// Stable id stored with each count ("estimate.bytes", later "openai.o200k_base").
    var id: String { get }
    var exactness: TokenCount.Exactness { get }
    /// How the count was made, in a sentence, for the meter's foot.
    var methodDescription: String { get }
    func count(_ source: TokenSource) -> TokenCount?
}

/// The shipped default: about four UTF-8 bytes a token, rounded to the nearest, never 0 for a non-empty text. It
/// needs only the size, so a huge file is counted without being read.
public struct ByteEstimateCounter: TokenCounter {
    public static let id = "estimate.bytes"
    public static let bytesPerToken = 4

    public init() {}

    public var id: String { Self.id }
    public var exactness: TokenCount.Exactness { .estimate }
    public var methodDescription: String {
        String(localized: "Estimated at about 4 bytes a token. Claude’s tokenizer is not public, so no count here is exact for Claude.",
               bundle: .module, comment: "Token meter foot: how the estimate is made and why it is not exact.")
    }

    public func count(_ source: TokenSource) -> TokenCount? {
        let bytes = source.byteCount
        let value = bytes <= 0 ? 0 : max(1, (bytes + Self.bytesPerToken / 2) / Self.bytesPerToken)
        return TokenCount(value: value, exactness: .estimate, method: id)
    }
}

/// The counters Vitrine knows, the default first.
public enum TokenCounting {
    /// What every preview counts with today.
    public static let standard: any TokenCounter = ByteEstimateCounter()
    /// Every counter, so a stored count's method can be named; exact counters are added here.
    public static let all: [any TokenCounter] = [standard]

    public static func counter(id: String) -> (any TokenCounter)? { all.first { $0.id == id } }

    /// The default count of a source; the estimate always answers.
    public static func count(_ source: TokenSource) -> TokenCount {
        standard.count(source) ?? ByteEstimateCounter().count(source)!
    }
}

extension PreviewDocument {
    /// Records the document's token count and keeps the `tokens` fact (the pill, Recent Previews) in step with it.
    public mutating func setTokens(_ count: TokenCount) {
        tokens = count
        let fact = DocumentFacts.tokens(count)
        if let index = facts.firstIndex(where: { $0.key == fact.key }) { facts[index] = fact } else { facts.append(fact) }
    }
}
