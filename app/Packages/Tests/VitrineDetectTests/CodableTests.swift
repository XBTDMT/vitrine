import Foundation
import Testing
@testable import VitrineDetect

@Suite("Stable JSON (snake_case keys, string raw values)")
struct CodableTests {
    static func json<T: Encodable>(_ v: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(v), as: UTF8.self)
    }

    @Test func patternSpec() throws {
        let spec = PatternSpec(kind: .exactText, value: "Project Falcon")
        #expect(try Self.json(spec) == #"{"case_sensitive":false,"kind":"exact_text","value":"Project Falcon"}"#)
        let decoded = try JSONDecoder().decode(PatternSpec.self, from: Data(#"{"kind":"prefix","value":"cus_","token_length":12}"#.utf8))
        #expect(decoded == PatternSpec(kind: .prefix, value: "cus_", tokenLength: 12))
        #expect(decoded.caseSensitive, "prefix defaults to case-sensitive when the key is absent")
        let label = try JSONDecoder().decode(PatternSpec.self, from: Data(#"{"kind":"label","value":"Employee ID"}"#.utf8))
        #expect(!label.caseSensitive)
    }

    @Test func validatorAndScope() throws {
        #expect(try Self.json(Validator.entropy(min: 3.5)) == #"{"min":3.5,"type":"entropy"}"#)
        #expect(try Self.json(Validator.phoneShape(minDigits: 8, maxDigits: 15)) == #"{"max_digits":15,"min_digits":8,"type":"phone_shape"}"#)
        #expect(try Self.json(Validator.ibanMod97) == #"{"type":"iban_mod97"}"#)
        #expect(try Self.json(Scope.block(endMarkers: ["END"])) == #"{"end_markers":["END"],"type":"block"}"#)
        // A block written with the pre-F20 line cap still decodes; the cap is ignored.
        #expect(try JSONDecoder().decode(Scope.self, from: Data(#"{"end_markers":["END"],"max_lines":3,"type":"block"}"#.utf8)) == .block(endMarkers: ["END"]))
        #expect(try Self.json(Scope.match) == #"{"type":"match"}"#)
        for v: Validator in [.none, .luhn, .ibanMod97, .entropy(min: 3), .jwt, .githubChecksum, .awsKeyIdPrefix, .phoneShape(minDigits: 1, maxDigits: 2)] {
            #expect(try JSONDecoder().decode(Validator.self, from: Data(try Self.json(v).utf8)) == v)
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Validator.self, from: Data(#"{"type":"magic"}"#.utf8)) }
    }

    @Test func detectorRoundTrip() throws {
        for d in Catalogue.builtIn {
            let data = try JSONEncoder().encode(d)
            #expect(try JSONDecoder().decode(Detector.self, from: data) == d)
        }
        let s = try Self.json(Catalogue.builtIn[0])
        #expect(s.contains(#""enabled_by_default":true"#) && s.contains(#""title_key":"detector.ai.anthropic.apikey.title""#) && s.contains(#""source":"built_in""#))
    }

    @Test func customRuleMatchesSpecSchema() throws {
        let data = Data(#"{ "id": "7F9C24E8-3B0D-4BBF-8C1E-5E0D6A9C1B2A", "name": "Customer ids", "action": "black_out", "pattern": { "kind": "example", "value": "CUS-004213" }, "is_enabled": true }"#.utf8)
        let rule = try JSONDecoder().decode(CustomRule.self, from: data)
        #expect(rule.action == .blackOut && rule.isEnabled && rule.pattern.kind == .example)
        #expect(rule.detectorID == "custom.7F9C24E8-3B0D-4BBF-8C1E-5E0D6A9C1B2A")
        let allow = try JSONDecoder().decode(CustomRule.self, from: Data(#"{ "id": "7F9C24E8-3B0D-4BBF-8C1E-5E0D6A9C1B2B", "name": "Project Falcon", "action": "allow", "pattern": { "kind": "exact_text", "value": "Project Falcon", "case_sensitive": false }, "suppress_partial_overlap": true, "is_enabled": true }"#.utf8))
        #expect(allow.asAllowRule?.suppressPartialOverlap == true)
        #expect(allow.asDetector == nil)
        let s = try Self.json(AllowRule(id: rule.id, name: "x", pattern: .regex("a")))
        #expect(s.contains(#""suppress_partial_overlap":false"#) && s.contains(#""is_enabled":true"#))
    }

    @Test func allowRuleModeRawValues() {
        #expect(AllowRuleMode.trim.rawValue == "trim" && AllowRuleMode.containedOnly.rawValue == "contained_only")
    }
}
