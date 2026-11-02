// VitrineDetect — PatternSpec: how a user-facing value turns into a regex (DETECTORS.md §2.1, §3).
import Foundation

/// A pattern as stored on disk and edited in the UI. `compiledPattern()` derives the regex source;
/// `humanDescription` is the plain-language preview. Stored JSON uses snake_case keys and string
/// raw values so a renamed Swift case never breaks a saved rule.
public struct PatternSpec: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case example
        case exactText = "exact_text"
        case prefix
        case label
        case regex

        /// §2.1: `exactText` and `label` default to case-insensitive; `prefix` to case-sensitive.
        /// `example` and `regex` carry no case flag of their own (the generaliser is literal; a regex says `(?i)` itself).
        public var defaultCaseSensitive: Bool {
            switch self {
            case .exactText, .label: return false
            case .prefix, .example, .regex: return true
            }
        }
    }

    public var kind: Kind
    /// The user-facing input for example / exactText / prefix / label (trimmed at generation time).
    public var value: String
    /// The regex source; required for `.regex`, ignored for the other kinds (derived instead).
    public var pattern: String?
    /// `.prefix` only: minimum run length after the prefix (default 8).
    public var tokenLength: Int?
    public var caseSensitive: Bool

    public static let defaultTokenLength = 8

    public init(kind: Kind, value: String = "", pattern: String? = nil, tokenLength: Int? = nil, caseSensitive: Bool? = nil) {
        self.kind = kind
        self.value = value
        self.pattern = pattern
        self.tokenLength = tokenLength
        self.caseSensitive = caseSensitive ?? kind.defaultCaseSensitive
    }

    /// Convenience for a verbatim regex.
    public static func regex(_ source: String) -> PatternSpec { PatternSpec(kind: .regex, pattern: source) }
    /// Convenience for a case-sensitive vendor prefix followed by at least `n` token characters.
    public static func prefix(_ value: String, n: Int) -> PatternSpec { PatternSpec(kind: .prefix, value: value, tokenLength: n) }

    enum CodingKeys: String, CodingKey {
        case kind, value, pattern
        case tokenLength = "token_length"
        case caseSensitive = "case_sensitive"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        self.kind = kind
        self.value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        self.pattern = try c.decodeIfPresent(String.self, forKey: .pattern)
        self.tokenLength = try c.decodeIfPresent(Int.self, forKey: .tokenLength)
        self.caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? kind.defaultCaseSensitive
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(value, forKey: .value)
        try c.encodeIfPresent(pattern, forKey: .pattern)
        try c.encodeIfPresent(tokenLength, forKey: .tokenLength)
        try c.encode(caseSensitive, forKey: .caseSensitive)
    }

    /// The regex source this spec compiles to (§3). Throws `PatternError` when the value is too short,
    /// the regex is missing or the regex does not compile with options `[]`.
    public func compiledPattern() throws -> String {
        try PatternGenerator.generate(self).regex
    }

    /// Plain-language description of what the pattern matches (§3). Never throws: an invalid spec
    /// describes itself as invalid.
    public var humanDescription: String {
        (try? PatternGenerator.generate(self).description) ?? "an invalid pattern"
    }
}

/// Why a PatternSpec could not become a regex. `userMessage` is the sentence the UI shows.
public enum PatternError: Error, Equatable, Sendable {
    case valueTooShort(minimum: Int)
    case missingRegex
    case invalidRegex(String)
    /// Security scan F23: longer than `RegexComplexity.maxLength`.
    case regexTooLong(maximum: Int)
    /// Security scan F23: a group repeated without bound that holds a repeat without bound (exponential on ordinary text).
    case regexTooComplex

    public var userMessage: String {
        switch self {
        case .valueTooShort(let minimum) where minimum >= 3: return "Paste a longer example"
        case .valueTooShort(let minimum): return "Use at least \(minimum) characters"
        case .missingRegex: return "This rule has no regular expression"
        case .invalidRegex: return "This isn't a valid regular expression"
        case .regexTooLong(let maximum): return "This regular expression is longer than \(maximum) characters"
        case .regexTooComplex: return "This regular expression repeats a group that already repeats, which can take too long to check. Simplify it"
        }
    }
}
