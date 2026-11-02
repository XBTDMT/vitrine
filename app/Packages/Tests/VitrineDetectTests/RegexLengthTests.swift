// G-40 route D: the shortest text a pattern can report as a secret, read from the regex source. The bound may be lower
// than the truth (an unknown construct counts as 0), never higher: a higher bound would let D skip a spot that could hold
// a secret.
import Foundation
import Testing
@testable import VitrineDetect

@Suite("The shortest secret a pattern can report (G-40 route D)")
struct RegexLengthTests {
    @Test(arguments: [
        ("abc", 3),
        ("a+b", 2),
        ("a*b", 1),
        ("a?b?c", 1),
        ("[A-Za-z0-9]{20}", 20),
        ("[A-Z]{4,}", 4),
        ("x{2,5}", 2),
        ("(?:ab|c)d", 2),
        ("ab|c", 1),
        (#"\d{3}-\d{2}"#, 6),
        (#"\bkey\b"#, 3),
        (#"(?i)token"#, 5),
        (#"(?=abc)abc"#, 3),
        (#"(?<!x)ab"#, 2),
        (#"\Qa.b\E"#, 3),
        (#"\p{L}{5}"#, 5),
        (#"(a)\1"#, 1),
        ("a{", 2),
        ("[]a]b", 2),
        (#"[\]x]y"#, 2),
    ])
    func minimumLengths(_ pattern: String, _ expected: Int) {
        #expect(RegexLength.minimumRedactLength(of: pattern) == expected, "\(pattern)")
    }

    /// The named `secret` group is what a match redacts, so it is the bound (never more than the whole match's).
    @Test func theSecretGroupIsTheBound() {
        #expect(RegexLength.minimumRedactLength(of: #"password[:=]\s*(?<secret>\S{8,})"#) == 8)
        #expect(RegexLength.minimumRedactLength(of: #"key=(?<secret>[a-z]{4})|(?<x>q)"#) == 1, "a match without the group redacts the whole match")
    }

    /// Anything this reader cannot follow reads as 0: the switch then skips nothing.
    @Test func unreadableSourceIsZero() {
        #expect(RegexLength.minimumRedactLength(of: "(abc") == 0)
        #expect(RegexLength.minimumRedactLength(of: "abc)") == 0)
        #expect(RegexLength.minimumRedactLength(of: "[abc") == 0)
        #expect(RegexLength.minimumRedactLength(of: "*a") == 0)
    }

    /// Every compiled pattern of the built-in catalogue is read, and the bound is never longer than a real match: each
    /// detector's own made-up positive fixtures are at least that long where they are redacted.
    @Test func theBuiltInCatalogueHasAShortestSecret() throws {
        let catalogue = try Catalogue.resolved()
        let shortest = try #require(catalogue.shortestSecretLength)
        #expect(shortest > 0)
        for compiled in catalogue.detectors {
            for matcher in compiled.matchers {
                #expect(RegexLength.minimumRedactLength(of: matcher.pattern) >= shortest)
            }
        }
    }

    /// The bound follows what is enabled: switching detectors off can only raise it, and a custom rule counts.
    @Test func disablingDetectorsAndAddingRulesMoveTheThreshold() throws {
        let all = try Catalogue.resolved()
        let shortest = try #require(all.shortestSecretLength)
        // Every detector whose patterns reach the shortest bound, switched off: the bound rises.
        let atBound = all.detectors.filter { $0.matchers.contains { RegexLength.minimumRedactLength(of: $0.pattern) == shortest } }.map(\.detector.id)
        #expect(!atBound.isEmpty)
        let fewer = try Catalogue.resolved(state: Dictionary(uniqueKeysWithValues: atBound.map { ($0, false) }))
        #expect(try #require(fewer.shortestSecretLength) > shortest)
        // A custom rule shorter than any built-in brings it down to the rule's own length.
        let rule = CustomRule(name: "made up", action: .blackOut, pattern: PatternSpec(kind: .exactText, value: "zq7"))
        let withRule = try Catalogue.resolved(rules: [rule])
        #expect(withRule.shortestSecretLength == min(shortest, 3))
    }
}
