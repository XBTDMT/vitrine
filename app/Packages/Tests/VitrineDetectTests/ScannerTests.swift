import Foundation
import Testing
@testable import VitrineDetect

@Suite("Scanner: allow rules, merge, block scope")
struct ScannerTests {
    static func lines(_ texts: String...) -> [ScanLine] { lines(texts) }
    static func lines(_ texts: [String]) -> [ScanLine] { texts.enumerated().map { ScanLine(index: $0.offset, text: $0.element) } }

    static func detector(_ id: String, _ regex: String, severity: Detector.Severity = .high, validator: Validator = .none, scope: Scope = .match) -> Detector {
        Detector(id: id, title: id, category: .custom, hint: "", patterns: [.regex(regex)], validator: validator, scope: scope, severity: severity)
    }

    /// A catalogue of exactly these detectors and allow rules (bypasses the built-ins).
    static func catalogue(_ detectors: [Detector], allow: [AllowRule] = []) throws -> CompiledCatalogue {
        CompiledCatalogue(
            detectors: try detectors.map { try Catalogue.compile($0) },
            allowRules: try allow.map { try Catalogue.compileAllow($0) },
            compileErrors: [:]
        )
    }

    static func text(_ line: String, _ f: Finding) -> String { Scanner.substring(line, f.secretRange) }

    // MARK: allow rules (§6)

    @Test func allowFullyContainedIsDroppedInBothModes() throws {
        let cat = try Self.catalogue([Self.detector("t.a.b", #"\d{6}"#)], allow: [AllowRule(name: "ticket", pattern: PatternSpec(kind: .exactText, value: "ticket 123456"))])
        for mode in [AllowRuleMode.trim, .containedOnly] {
            let findings = Scanner(catalogue: cat, allowRuleMode: mode).scan(Self.lines("see ticket 123456 and 654321"))
            #expect(findings.count == 1)
            #expect(Self.text("see ticket 123456 and 654321", findings[0]) == "654321")
        }
    }

    @Test func allowPartialOverlapTrimsInTrimMode() throws {
        let line = "token ABCDEFGHIJ"
        let cat = try Self.catalogue([Self.detector("t.a.b", #"[A-Z]{10}"#)], allow: [AllowRule(name: "abc", pattern: PatternSpec(kind: .exactText, value: "ABCDE", caseSensitive: true))])
        let trimmed = Scanner(catalogue: cat, allowRuleMode: .trim).scan(Self.lines(line))
        #expect(trimmed.count == 1)
        #expect(Self.text(line, trimmed[0]) == "FGHIJ")
        #expect(NSEqualRanges(NSUnionRange(trimmed[0].range, trimmed[0].secretRange), trimmed[0].range), "range still contains secretRange")
        let kept = Scanner(catalogue: cat, allowRuleMode: .containedOnly).scan(Self.lines(line))
        #expect(kept.count == 1)
        #expect(Self.text(line, kept[0]) == "ABCDEFGHIJ")
    }

    @Test func allowInsideMatchSplitsInTrimMode() throws {
        let line = "ABCDEFGHIJ"
        let cat = try Self.catalogue([Self.detector("t.a.b", #"[A-Z]{10}"#)], allow: [AllowRule(name: "mid", pattern: PatternSpec(kind: .exactText, value: "EF", caseSensitive: true))])
        let pieces = Scanner(catalogue: cat, allowRuleMode: .trim).scan(Self.lines(line)).map { Self.text(line, $0) }.sorted()
        #expect(pieces == ["ABCD", "GHIJ"])
    }

    @Test func suppressPartialOverlapDropsInBothModes() throws {
        let cat = try Self.catalogue([Self.detector("t.a.b", #"[A-Z]{10}"#)], allow: [AllowRule(name: "abc", pattern: PatternSpec(kind: .exactText, value: "ABCDE"), suppressPartialOverlap: true)])
        for mode in [AllowRuleMode.trim, .containedOnly] {
            #expect(Scanner(catalogue: cat, allowRuleMode: mode).scan(Self.lines("ABCDEFGHIJ")).isEmpty)
        }
    }

    @Test func allowRulesBeatValidators() throws {
        let cat = try Self.catalogue([Self.detector("t.card.pan", #"\b(?:\d[ ]?){12,18}\d\b"#, validator: .luhn)], allow: [AllowRule(name: "test pan", pattern: PatternSpec(kind: .exactText, value: "4111 1111 1111 1111"))])
        #expect(Scanner(catalogue: cat).scan(Self.lines("card 4111 1111 1111 1111 ok")).isEmpty)
    }

    @Test func allowRuleUsesItsSecretGroup() throws {
        let line = "Project: Falcon and secret 123456"
        let cat = try Self.catalogue([Self.detector("t.a.b", #"\d{6}|Falcon"#)], allow: [AllowRule(name: "label", pattern: PatternSpec(kind: .label, value: "Project"))])
        let findings = Scanner(catalogue: cat).scan(Self.lines(line))
        #expect(findings.map { Self.text(line, $0) } == ["123456"])
    }

    @Test func disabledAllowRuleIsIgnoredByResolved() throws {
        let compiled = try Catalogue.resolved(allowRules: [AllowRule(name: "off", pattern: PatternSpec(kind: .exactText, value: "x"), isEnabled: false)])
        #expect(compiled.allowRules.isEmpty)
    }

    // MARK: merge (§8)

    @Test func intersectingMatchesUnionMergeWithFirstAsLabel() throws {
        let line = "key=abcdef123456 trailing"
        let cat = try Self.catalogue([
            Self.detector("t.first.a", #"key=(?<secret>[a-z]+)"#, severity: .medium),
            Self.detector("t.second.b", #"[a-z]+\d{6}"#, severity: .critical),
        ])
        let findings = Scanner(catalogue: cat).scan(Self.lines(line))
        #expect(findings.count == 1)
        #expect(findings[0].detectorIDs == ["t.first.a", "t.second.b"])
        #expect(findings[0].severity == .critical)
        #expect(Self.text(line, findings[0]) == "abcdef123456")
        #expect(Scanner.substring(line, findings[0].range) == "key=abcdef123456")
        #expect(findings[0].category == .custom)
    }

    @Test func adjacentMatchesAreNotMerged() throws {
        let line = "aaa111"
        let cat = try Self.catalogue([Self.detector("t.a.a", "a+"), Self.detector("t.b.b", #"\d+"#)])
        let findings = Scanner(catalogue: cat).scan(Self.lines(line))
        #expect(findings.count == 2)
        #expect(Set(findings.map { Self.text(line, $0) }) == ["aaa", "111"])
    }

    @Test func mergeCascades() throws {
        let line = "aaabbbccc"
        let cat = try Self.catalogue([Self.detector("t.a.a", "aaa"), Self.detector("t.c.c", "ccc"), Self.detector("t.b.b", "abbbc")])
        let findings = Scanner(catalogue: cat).scan(Self.lines(line))
        #expect(findings.count == 1)
        #expect(Self.text(line, findings[0]) == "aaabbbccc")
        #expect(findings[0].detectorIDs.count == 3)
        #expect(findings[0].detectorIDs[0] == "t.a.a")
    }

    @Test func sameDetectorTwiceOnOneLineGivesTwoFindings() throws {
        let cat = try Self.catalogue([Self.detector("t.a.a", #"\d{3}"#)])
        #expect(Scanner(catalogue: cat).scan(Self.lines("123 and 456")).count == 2)
    }

    // MARK: block scope (§7)

    static let pem = Self.detector("t.pem.key", #"-{3,}\s*BEGIN (?:[A-Z ]*PRIVATE KEY)\s*-{3,}"#, severity: .critical, scope: .block(endMarkers: ["END", "PRIVATE KEY"]))

    @Test func blockCoversTriggerThroughEndMarkerInclusive() throws {
        let cat = try Self.catalogue([Self.pem, Self.detector("t.a.a", "MIIE")])
        let lines = Self.lines("before", "-----BEGIN RSA PRIVATE KEY-----", "MIIEowIBAAKCAQEA", "-----END RSA PRIVATE KEY-----", "after MIIE")
        let findings = Scanner(catalogue: cat).scan(lines)
        let block = findings.filter { $0.wholeLine }
        #expect(block.map(\.lineIndex) == [1, 2, 3])
        #expect(Set(block.map(\.blockID)).count == 1 && block[0].blockID != nil)
        #expect(block.allSatisfy { $0.range.location == 0 && $0.secretRange == $0.range })
        #expect(block[1].range.length == "MIIEowIBAAKCAQEA".utf16.count)
        // the ranged detector skips the consumed line 2 but still fires on line 4
        let ranged = findings.filter { !$0.wholeLine }
        #expect(ranged.map(\.lineIndex) == [4])
    }

    /// Security scan F20: with the footer cropped, every line after the trigger is covered (it was the first maxLines).
    @Test func blockFailsClosedWhenFooterIsCropped() throws {
        let cat = try Self.catalogue([Self.pem])
        let lines = Self.lines("-----BEGIN OPENSSH PRIVATE KEY-----", "l1", "l2", "l3", "l4", "l5", "l6", "l7")
        let findings = Scanner(catalogue: cat).scan(lines)
        #expect(findings.map(\.lineIndex) == Array(0...7), "no footer: to the end of the text")
    }

    /// Security scan F20: an armored key longer than the old 120-line cap (a PGP secret key with RSA-4096 subkeys is
    /// 150–200 lines) is covered from its header to its footer, every line, and nothing after the footer.
    @Test func aKeyLongerThanTheOldCapIsCoveredToItsFooter() throws {
        let body = (1...240).map { "EXAMPLEbase64body\($0)AAAABBBBCCCCDDDDEEEEFFFF0000111122223333" }
        let cases = [(try Self.catalogue([Self.pem]), "RSA PRIVATE KEY"), (try Catalogue.resolved(), "PGP PRIVATE KEY BLOCK"),
                     (try Catalogue.resolved(), "OPENSSH PRIVATE KEY")]
        for (catalogue, label) in cases {
            let lines = Self.lines(["before", "-----BEGIN \(label)-----", "", "Version: Example 1.0"] + body
                                   + ["=AbCd", "-----END \(label)-----", "after the key"])
            let result = VitrineDetect.Scanner(catalogue: catalogue).check(lines)
            let covered = result.findings.filter(\.wholeLine).map(\.lineIndex)
            #expect(covered == Array(1...(lines.count - 2)), "header through footer, \(covered.count) lines")
            #expect(Set(result.findings.filter(\.wholeLine).map(\.blockID)).count == 1)
            #expect(result.isComplete)
        }
    }

    /// The same key with its footer cropped off: every line from the header to the end is covered, none left visible.
    @Test func aLongKeyWithItsFooterCroppedIsCoveredToTheEnd() throws {
        let body = (1...300).map { "EXAMPLEbase64body\($0)AAAABBBBCCCCDDDDEEEEFFFF0000111122223333" }
        let lines = Self.lines(["-----BEGIN RSA PRIVATE KEY-----"] + body)
        let result = VitrineDetect.Scanner(catalogue: try Catalogue.resolved()).check(lines)
        #expect(result.findings.filter(\.wholeLine).map(\.lineIndex) == Array(0...300))
        #expect(result.isComplete)
    }

    @Test func blockNeedsEveryEndMarker() throws {
        let cat = try Self.catalogue([Self.pem])
        let lines = Self.lines("-----BEGIN EC PRIVATE KEY-----", "-----END-----", "-----END EC PRIVATE KEY-----", "tail")
        #expect(Scanner(catalogue: cat).scan(lines).map(\.lineIndex) == [0, 1, 2])
    }

    @Test func allowRuleCoveringWholeLineWithSuppressPartialSkipsBlockLine() throws {
        let cat = try Self.catalogue([Self.pem], allow: [AllowRule(name: "comment", pattern: PatternSpec.regex("^# .*$"), suppressPartialOverlap: true)])
        let lines = Self.lines("-----BEGIN PRIVATE KEY-----", "# comment line", "-----END PRIVATE KEY-----")
        #expect(Scanner(catalogue: cat).scan(lines).map(\.lineIndex) == [0, 2])
        let noSuppress = try Self.catalogue([Self.pem], allow: [AllowRule(name: "comment", pattern: PatternSpec.regex("^# .*$"))])
        #expect(Scanner(catalogue: noSuppress).scan(lines).map(\.lineIndex) == [0, 1, 2])
    }

    @Test func twoBlocksAreDistinct() throws {
        let cat = try Self.catalogue([Self.pem])
        let lines = Self.lines("-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----", "x", "-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----")
        let findings = Scanner(catalogue: cat).scan(lines)
        #expect(findings.map(\.lineIndex) == [0, 1, 3, 4])
        #expect(Set(findings.map(\.blockID)).count == 2)
    }

    // MARK: fold, ranges, logs

    @Test func rangesAreValidOnOriginalTextAfterFolding() throws {
        let original = "key＝АBC123４５６"      // fullwidth '=', Cyrillic А, fullwidth digits
        let cat = try Self.catalogue([Self.detector("t.a.a", #"ABC\d{6}"#)])
        let findings = Scanner(catalogue: cat).scan([ScanLine(index: 7, text: original)])
        #expect(findings.count == 1)
        #expect(findings[0].lineIndex == 7)
        #expect(Scanner.substring(original, findings[0].secretRange) == "АBC123４５６")
        #expect(Scanner.substring(ConfusableFold.fold(original), findings[0].secretRange) == "ABC123456")
    }

    @Test func textForLogsIsADigestNeverTheText() throws {
        let cat = try Self.catalogue([Self.detector("t.a.a", "hunter2")])
        let f = Scanner(catalogue: cat).scan(Self.lines("pw hunter2")).first
        #expect(f?.textForLogs == Finding.logDigest(of: "hunter2"))
        #expect(f?.textForLogs.count == 64)
        #expect(f?.textForLogs.contains("hunter") == false)
        #expect(Finding.logDigest(of: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func validatorRejectDropsTheMatch() throws {
        let cat = try Self.catalogue([Self.detector("t.a.a", #"\d{16}"#, validator: .luhn)])
        #expect(Scanner(catalogue: cat).scan(Self.lines("4111111111111112")).isEmpty)
        #expect(Scanner(catalogue: cat).scan(Self.lines("4111111111111111")).count == 1)
    }

    @Test func validatorAppliesOnlyToListedPatterns() throws {
        let det = Detector(id: "t.a.a", title: "", category: .custom, hint: "", patterns: [.regex("[a-z]{4}"), .regex(#"\d{16}"#)],
                           validator: .luhn, validatedPatternIndexes: [1], severity: .low)
        let findings = Scanner(catalogue: try Self.catalogue([det])).scan(Self.lines("word 4111111111111112"))
        #expect(findings.count == 1, "the word passes (unvalidated); the bad PAN is rejected")
    }

    @Test func awsAnnotationLandsInSubkind() throws {
        let det = Self.detector("t.aws.id", #"\bAKIA[A-Z0-9]{16}\b"#, validator: .awsKeyIdPrefix)
        let f = Scanner(catalogue: try Self.catalogue([det])).scan(Self.lines("AKIAIOSFODNN7EXAMPLE")).first
        #expect(f?.subkind == "access key")
    }

    @Test func scanSortsByLineIndexAndKeepsIndexes() throws {
        let cat = try Self.catalogue([Self.detector("t.a.a", "x")])
        let findings = Scanner(catalogue: cat).scan([ScanLine(index: 5, text: "x"), ScanLine(index: 2, text: "x")])
        #expect(findings.map(\.lineIndex) == [2, 5])
    }
}
