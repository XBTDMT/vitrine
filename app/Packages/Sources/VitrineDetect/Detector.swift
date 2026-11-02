// VitrineDetect — Detector and its enums (DETECTORS.md §2.2). All JSON keys snake_case, enum raw values strings.
import Foundation

public struct Detector: Codable, Hashable, Sendable, Identifiable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        case ai, cloud, payments, scm, messaging, databases, tokens, config, personal, network, custom
    }

    /// UI only; sorting and badges. The renderer ignores it (§1 principle 12).
    public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        case low, medium, high, critical

        var rank: Int {
            switch self {
            case .low: return 0
            case .medium: return 1
            case .high: return 2
            case .critical: return 3
            }
        }
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    public enum Source: String, Codable, Sendable {
        case builtIn = "built_in"
        case override
        case custom
    }

    /// `<category>.<vendor>.<kind>` for built-ins; `custom.<UUID>` for user rules. Never reused.
    public let id: String
    /// Display title. English for now; `titleKey` is the localization key so a string table can replace it later.
    public let title: String
    public let titleKey: String
    public let category: Category
    /// One-line example shape shown greyed in the Detectors pane; made up, never a real token.
    public let hint: String
    /// OR'd: the detector matches when any pattern matches.
    public var patterns: [PatternSpec]
    public let validator: Validator
    /// Which pattern indexes the validator applies to; `nil` means every pattern. Lets one detector
    /// carry a JWT-only or checksum-only validator next to patterns of another shape (§5.4, §5.5).
    public let validatedPatternIndexes: [Int]?
    public let scope: Scope
    public let enabledByDefault: Bool
    public let severity: Severity
    public var source: Source

    public init(
        id: String,
        title: String,
        titleKey: String? = nil,
        category: Category,
        hint: String,
        patterns: [PatternSpec],
        validator: Validator = .none,
        validatedPatternIndexes: [Int]? = nil,
        scope: Scope = .match,
        enabledByDefault: Bool = true,
        severity: Severity,
        source: Source = .builtIn
    ) {
        self.id = id
        self.title = title
        self.titleKey = titleKey ?? "detector.\(id).title"
        self.category = category
        self.hint = hint
        self.patterns = patterns
        self.validator = validator
        self.validatedPatternIndexes = validatedPatternIndexes
        self.scope = scope
        self.enabledByDefault = enabledByDefault
        self.severity = severity
        self.source = source
    }

    /// Whether the validator applies to the pattern at `index`.
    public func validatorApplies(toPatternAt index: Int) -> Bool {
        guard let indexes = validatedPatternIndexes else { return true }
        return indexes.contains(index)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, category, hint, patterns, validator, scope, severity, source
        case titleKey = "title_key"
        case validatedPatternIndexes = "validated_pattern_indexes"
        case enabledByDefault = "enabled_by_default"
    }
}

/// A closed set, not a plug-in system (§5). Associated values encode as `{"type": "...", ...}`.
public enum Validator: Codable, Hashable, Sendable {
    case none
    case luhn
    case ibanMod97
    case entropy(min: Double)
    case jwt
    case githubChecksum
    case awsKeyIdPrefix
    case phoneShape(minDigits: Int, maxDigits: Int)

    enum CodingKeys: String, CodingKey {
        case type, min
        case minDigits = "min_digits"
        case maxDigits = "max_digits"
    }

    /// True for the validators that check a vendor's own token format (GitHub's CRC-32 checksum, a JWT's decodable
    /// header and payload). Each runs only behind a pattern that already fixes the vendor prefix and the token's exact
    /// shape, and one or two misread characters break it. On text OCR read a rejection by one of them keeps the match as
    /// an unverified finding (fail-open #20); the others (entropy, Luhn, IBAN, phone) decide whether a generic shape is a
    /// secret at all, so their rejection drops the match on any text.
    public var checksVendorFormat: Bool {
        switch self {
        case .jwt, .githubChecksum: return true
        case .none, .luhn, .ibanMod97, .entropy, .awsKeyIdPrefix, .phoneShape: return false
        }
    }

    public var typeName: String {
        switch self {
        case .none: return "none"
        case .luhn: return "luhn"
        case .ibanMod97: return "iban_mod97"
        case .entropy: return "entropy"
        case .jwt: return "jwt"
        case .githubChecksum: return "github_checksum"
        case .awsKeyIdPrefix: return "aws_key_id_prefix"
        case .phoneShape: return "phone_shape"
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "none": self = .none
        case "luhn": self = .luhn
        case "iban_mod97": self = .ibanMod97
        case "entropy": self = .entropy(min: try c.decode(Double.self, forKey: .min))
        case "jwt": self = .jwt
        case "github_checksum": self = .githubChecksum
        case "aws_key_id_prefix": self = .awsKeyIdPrefix
        case "phone_shape":
            self = .phoneShape(minDigits: try c.decode(Int.self, forKey: .minDigits), maxDigits: try c.decode(Int.self, forKey: .maxDigits))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown validator type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .entropy(let min): try c.encode(min, forKey: .min)
        case .phoneShape(let lo, let hi):
            try c.encode(lo, forKey: .minDigits)
            try c.encode(hi, forKey: .maxDigits)
        default: break
        }
    }
}

/// Where a detector's findings live: inside the matched range, or across a block of lines (§7).
public enum Scope: Codable, Hashable, Sendable {
    case match
    /// From the trigger line to the first line holding every end marker, inclusive; with no such line, to the end of the
    /// text. There is no line cap (security scan 2026-10-28 F20: a cap of 120 lines left the rest of a long key visible).
    case block(endMarkers: [String])

    enum CodingKeys: String, CodingKey {
        case type
        case endMarkers = "end_markers"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "match": self = .match
        case "block":
            // A `max_lines` written before F20 is ignored: a block has no line cap.
            self = .block(endMarkers: try c.decode([String].self, forKey: .endMarkers))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown scope type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .match:
            try c.encode("match", forKey: .type)
        case .block(let endMarkers):
            try c.encode("block", forKey: .type)
            try c.encode(endMarkers, forKey: .endMarkers)
        }
    }
}
