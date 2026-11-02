// VitrineDetect — user rules: AllowRule (§2.3) and CustomRule (§2.4).
public import Foundation

/// "Never black out this." Matched before any detector; see §6 for the semantics.
public struct AllowRule: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var pattern: PatternSpec
    /// When on, a detector match that merely overlaps this rule's range is dropped too (§6).
    public var suppressPartialOverlap: Bool
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, pattern: PatternSpec, suppressPartialOverlap: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.suppressPartialOverlap = suppressPartialOverlap
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, name, pattern
        case suppressPartialOverlap = "suppress_partial_overlap"
        case isEnabled = "is_enabled"
    }
}

/// A rule the user wrote. A black-out rule becomes a `Detector` (`custom.<UUID>`, severity high, validator none);
/// an allow rule becomes an `AllowRule`.
public struct CustomRule: Codable, Hashable, Sendable, Identifiable {
    public enum Action: String, Codable, Sendable {
        case blackOut = "black_out"
        case allow
    }

    public let id: UUID
    public var name: String
    public var action: Action
    public var pattern: PatternSpec
    public var isEnabled: Bool
    public let createdAt: Date
    /// Allow rules only (§2.3); ignored for black-out rules.
    public var suppressPartialOverlap: Bool

    public init(id: UUID = UUID(), name: String, action: Action, pattern: PatternSpec, isEnabled: Bool = true, createdAt: Date = Date(), suppressPartialOverlap: Bool = false) {
        self.id = id
        self.name = name
        self.action = action
        self.pattern = pattern
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.suppressPartialOverlap = suppressPartialOverlap
    }

    /// The detector id a black-out rule gets: `custom.<UUIDv4>`.
    public var detectorID: String { "custom.\(id.uuidString)" }

    /// §2.4 mapping to a `Detector`. Nil for allow rules.
    public var asDetector: Detector? {
        guard action == .blackOut else { return nil }
        return Detector(
            id: detectorID, title: name, titleKey: "custom.rule.title", category: .custom, hint: pattern.humanDescription,
            patterns: [pattern], validator: .none, scope: .match, enabledByDefault: true, severity: .high, source: .custom
        )
    }

    /// §2.4 mapping to an `AllowRule`. Nil for black-out rules.
    public var asAllowRule: AllowRule? {
        guard action == .allow else { return nil }
        return AllowRule(id: id, name: name, pattern: pattern, suppressPartialOverlap: suppressPartialOverlap, isEnabled: isEnabled)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, action, pattern
        case isEnabled = "is_enabled"
        case createdAt = "created_at"
        case suppressPartialOverlap = "suppress_partial_overlap"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        action = try c.decode(Action.self, forKey: .action)
        pattern = try c.decode(PatternSpec.self, forKey: .pattern)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        suppressPartialOverlap = try c.decodeIfPresent(Bool.self, forKey: .suppressPartialOverlap) ?? false
    }
}
