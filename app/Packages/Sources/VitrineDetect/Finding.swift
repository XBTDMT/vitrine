// VitrineDetect — the Scanner's output (DETECTORS.md §2.5). Ranges are UTF-16 offsets valid on both the
// folded and the original line text (ConfusableFold invariant). `textForLogs` never carries the text.
public import Foundation
import CryptoKit

public struct Finding: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let lineIndex: Int
    /// The whole match.
    public let range: NSRange
    /// The part to redact: the `secret` group, else `range`.
    public let secretRange: NSRange
    /// Every detector that contributed to the merged range; `detectorIDs[0]` owns the label.
    public let detectorIDs: [String]
    public let category: Detector.Category
    /// Max over the contributing detectors.
    public let severity: Detector.Severity
    /// Block-scope findings cover the whole line.
    public let wholeLine: Bool
    /// Shared by every line of one block-scope finding so the Journal shows one row; nil for ranged findings.
    public let blockID: UUID?
    /// Annotation from `awsKeyIdPrefix` (§5.6), e.g. "access key"; nil otherwise.
    public let subkind: String?
    /// SHA-256 hex of the matched (secret) text. Lets two scans be compared in logs without the text.
    public let textForLogs: String
    /// Fail-open #20: on recognized text, the vendor's prefix and shape matched but the vendor-format validator (checksum,
    /// JWT header) rejected the text, as a misread does. Covered at lower confidence instead of dropped. A merged finding
    /// is unverified only when every contributor is.
    public let unverified: Bool

    public init(
        id: UUID = UUID(),
        lineIndex: Int,
        range: NSRange,
        secretRange: NSRange,
        detectorIDs: [String],
        category: Detector.Category,
        severity: Detector.Severity,
        wholeLine: Bool = false,
        blockID: UUID? = nil,
        subkind: String? = nil,
        textForLogs: String,
        unverified: Bool = false
    ) {
        self.id = id
        self.lineIndex = lineIndex
        self.range = range
        self.secretRange = secretRange
        self.detectorIDs = detectorIDs
        self.category = category
        self.severity = severity
        self.wholeLine = wholeLine
        self.blockID = blockID
        self.subkind = subkind
        self.textForLogs = textForLogs
        self.unverified = unverified
    }

    /// The hash used for `textForLogs`: SHA-256 over the UTF-8 of the matched text, lowercase hex.
    public static func logDigest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// How a detector match that partially overlaps an allow range is handled (ARCHITECTURE.md §4 row 10).
public enum AllowRuleMode: String, Codable, Sendable {
    /// Trim the overlapping part out of the match (default). A match fully inside an allow range is dropped.
    case trim
    /// Drop only matches fully contained in an allow range; partial overlaps are kept whole.
    case containedOnly = "contained_only"
}
