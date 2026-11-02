// Security scan 2026-10-28 F23: a regular expression from a person or an imported rules file was compiled and run with
// no limit, so `^(\w+\s?)*$` stalled every scan on ordinary prose. `RegexComplexity` refuses a repeat inside a repeat and
// an over-long source before a pattern is compiled; `MatchBudget` bounds whatever else is slow (RegexWorkTests).
import Foundation
import Testing
@testable import VitrineDetect

@Suite struct RegexComplexityTests {
    @Test(arguments: [
        #"^(\w+\s?)*$"#, #"(\w+\s?)*"#, #"(a+)+"#, #"(?:x*y?)+"#, #"(a{2,})*"#, #"((a)+b)*"#, #"(?:(?:a+))+"#, #"(a+)*?"#,
        #"(a+)++"#, #"(?<n>[0-9]+-)+x"#, #"(?:[a-z]+\.)+com"#, #"(a*){3,}"#,
    ])
    func aRepeatInsideARepeatIsRefused(_ source: String) {
        #expect(throws: PatternError.regexTooComplex) { try RegexComplexity.check(source) }
        #expect(throws: PatternError.regexTooComplex) { try PatternSpec.regex(source).compiledPattern() }
    }

    @Test(arguments: [
        #"[a-z]+"#, #"(ab)+"#, #"(?:\d{4}-){3}\d{4}"#, #"(a+){2}"#, #"(a+){1,5}"#, #"\(a+\)*"#, #"[(a+)]*"#, #"\Q(a+)*\E"#,
        #"(?#(a+)*)x"#, #"x{"#, #"a{1,3}"#, #"(?i)\bcus_[A-Za-z0-9]{8,}"#, #"\p{L}+(?:-\p{L})*"#, #"[[a-z]&&[^q]]+"#,
        #"(a|b)*c"#, #"(?:[\w\-]|\.(?=[\w\-]))*/"#,
    ])
    func boundedOrFlatRepeatsAreAccepted(_ source: String) throws {
        try RegexComplexity.check(source)
    }

    @Test func anOverLongSourceIsRefused() throws {
        try RegexComplexity.check(String(repeating: "a", count: RegexComplexity.maxLength))
        #expect(throws: PatternError.regexTooLong(maximum: RegexComplexity.maxLength)) {
            try PatternSpec.regex(String(repeating: "a", count: RegexComplexity.maxLength + 1)).compiledPattern()
        }
    }

    /// The same rule applies to every built-in pattern, and each passes it.
    @Test func everyBuiltInPatternPasses() throws {
        for detector in Catalogue.builtIn {
            for spec in detector.patterns { try RegexComplexity.check(try spec.compiledPattern()) }
        }
    }

    /// config.labelled.secret's host-and-path exclusion was the one built-in with a repeat inside a repeat; its rewrite
    /// excludes exactly the same values.
    @Test func theLabelledSecretPathExclusionReadsTheSameText() throws {
        let old = try NSRegularExpression(pattern: #"^(?![\w\-]+(?:\.[\w\-]+)+/)"#)
        let new = try NSRegularExpression(pattern: #"^(?![\w\-]+\.(?=[\w\-])(?:[\w\-]|\.(?=[\w\-]))*/)"#)
        let samples = ["host.name/path", "a.b.c/", "a../x", "a./x", "abc/", "a.b", ".a/b", "a-b.c-d/e", "a.b.c", "a..b/c", "x.y.z.w/",
                       "EXAMPLEkey9f8e7d6c5b4a", "a.b/../c", "-.-/", "a.-/", "a_b.c_d/"]
        for sample in samples {
            let range = NSRange(location: 0, length: sample.utf16.count)
            #expect((old.firstMatch(in: sample, range: range) != nil) == (new.firstMatch(in: sample, range: range) != nil), "\(sample)")
        }
    }

    /// A custom rule or an edited detector refused by the check never runs: the rule is reported, and the detector runs
    /// on its built-in patterns.
    @Test func aRefusedUserPatternNeverRuns() throws {
        let rule = CustomRule(name: "imported", action: .blackOut, pattern: .regex(#"^(\w+\s?)*$"#))
        let catalogue = try Catalogue.resolved(with: ["config.env.secret": [.regex(#"(a+)+"#)]], rules: [rule])
        #expect(catalogue.compileErrors[rule.id.uuidString] == PatternError.regexTooComplex.userMessage)
        #expect(!catalogue.detectors.contains { $0.detector.id == rule.detectorID })
        #expect(catalogue.overrideErrors["config.env.secret"] == PatternError.regexTooComplex.userMessage)
        let env = try #require(catalogue.detectors.first { $0.detector.id == "config.env.secret" })
        #expect(env.detector.source == .builtIn)
    }
}
