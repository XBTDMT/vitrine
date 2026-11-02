import Foundation
import Testing
@testable import VitrineDetect

@Suite("Pattern generators (DETECTORS.md §3)")
struct GeneratorTests {
    // ORDER: the table rule (N ≥ 4 → [A-Z]{N}) and the row’s own description “5 capital letters” agree; the row’s literal regex cell does not.
    @Test("§3.5 worked examples", arguments: [
        ("CUS-004213", #"\bCUS-\d{6}\b"#, "“CUS”, “-”, 6 digits"),
        ("ORDER 2026-10-26", #"\b[A-Z]{5}\s+\d{4}-\d{2}-\d{2}\b"#, "5 capital letters, a space, 4 digits, “-”, 2 digits, “-”, 2 digits"),
        ("tok_8f3kq92z", #"\btok_[A-Za-z0-9]{7,9}\b"#, "“tok”, “_”, about 8 letters and digits"),
        ("+84 912 345 678", #"\+\d{2}\s+\d{3}\s+\d{3}\s+\d{3}\b"#, "“+”, 2 digits, a space, 3 digits, a space, 3 digits, a space, 3 digits"),
    ])
    func exampleWorkedExamples(input: String, regex: String, description: String) throws {
        let spec = PatternSpec(kind: .example, value: input)
        #expect(try spec.compiledPattern() == regex)
        #expect(spec.humanDescription == description)
    }

    @Test func exampleMixedRunIsOneRun() throws {
        #expect(try PatternSpec(kind: .example, value: "a1b2c3").compiledPattern() == #"\b[A-Za-z0-9]{5,7}\b"#)
        #expect(try PatternSpec(kind: .example, value: "abc").compiledPattern() == #"\babc\b"#)
        #expect(try PatternSpec(kind: .example, value: "lowercase9").compiledPattern() == #"\b[A-Za-z0-9]{9,11}\b"#)
        #expect(try PatternSpec(kind: .example, value: "hello-WORLD").compiledPattern() == #"\b[a-z]{5}-[A-Z]{5}\b"#)
        #expect(PatternSpec(kind: .example, value: "7").humanDescription == "an invalid pattern")
        // non-Latin letters stay literal, no \b at a non-alnum edge
        #expect(try PatternSpec(kind: .example, value: "ümlaut 1").compiledPattern() == #"ü[a-z]{5}\s+\d{1}\b"#)
    }

    @Test func exampleTooShort() {
        #expect(throws: PatternError.valueTooShort(minimum: 3)) { try PatternSpec(kind: .example, value: "ab").compiledPattern() }
        #expect(PatternError.valueTooShort(minimum: 3).userMessage == "Paste a longer example")
    }

    @Test func exactText() throws {
        let spec = PatternSpec(kind: .exactText, value: "Project  Falcon")
        #expect(try spec.compiledPattern() == #"(?i)Project\s+Falcon"#)
        #expect(spec.humanDescription == "“Project  Falcon”, in any letter case")
        let cs = PatternSpec(kind: .exactText, value: "a.b", caseSensitive: true)
        #expect(try cs.compiledPattern() == #"a\.b"#)
        #expect(cs.humanDescription == "“a.b”, exact case")
        #expect(throws: PatternError.valueTooShort(minimum: 1)) { try PatternSpec(kind: .exactText, value: "  ").compiledPattern() }
    }

    @Test func prefix() throws {
        let spec = PatternSpec(kind: .prefix, value: "cus_")
        #expect(try spec.compiledPattern() == #"cus_[A-Za-z0-9_\-]{8,}"#)
        #expect(spec.humanDescription == "cus_ followed by at least 8 letters, digits, _ or -")
        #expect(try PatternSpec.prefix("sk-ant-", n: 24).compiledPattern() == #"sk-ant-[A-Za-z0-9_\-]{24,}"#)
        #expect(spec.caseSensitive)
        #expect(throws: PatternError.valueTooShort(minimum: 2)) { try PatternSpec(kind: .prefix, value: "c").compiledPattern() }
        #expect(PatternError.valueTooShort(minimum: 2).userMessage == "Use at least 2 characters")
    }

    @Test func label() throws {
        let spec = PatternSpec(kind: .label, value: "Employee ID")
        #expect(try spec.compiledPattern() == #"(?i)Employee\s+ID\s*[:=#\-]?\s*["']?(?<secret>[^\s,;"']+)"#)
        #expect(spec.humanDescription == "the value written after “Employee ID”")
        let matcher = try ICURegexMatcher(pattern: try spec.compiledPattern())
        let line = "Employee ID: 48213"
        let hits = matcher.matches(in: line)
        #expect(hits.count == 1)
        #expect(Scanner.substring(line, hits[0].redactRange) == "48213")
        #expect(hits[0].range == NSRange(location: 0, length: line.utf16.count))
    }

    @Test func regexVerbatimAndInvalid() throws {
        #expect(try PatternSpec.regex(#"\bx\b"#).compiledPattern() == #"\bx\b"#)
        #expect(PatternSpec.regex("a").humanDescription == "whatever your regular expression matches")
        #expect(throws: PatternError.invalidRegex("(")) { try PatternSpec.regex("(").compiledPattern() }
        #expect(throws: PatternError.missingRegex) { try PatternSpec(kind: .regex).compiledPattern() }
        #expect(PatternError.invalidRegex("(").userMessage == "This isn't a valid regular expression")
    }

    @Test func matcherNeverReportsEmptyMatches() throws {
        let m = try ICURegexMatcher(pattern: "a*")
        #expect(m.matches(in: "bbb").isEmpty)
        #expect(m.matches(in: "baab").count == 1)
    }
}
