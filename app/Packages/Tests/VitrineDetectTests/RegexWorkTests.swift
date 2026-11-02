// Security scan 2026-10-28 F9/F14/F23: the regex work a scan does is bounded. The built-in patterns are proved linear
// with ICU's own work counter (`MatchBudget.work`: deterministic for a pattern and a text, about two units per
// character for a linear pattern), and the Scanner bounds whatever a pattern does with a per-line length cap, a
// per-search and per-scan time budget and the task's cancellation, reporting every line it could not finish.
import Foundation
import Testing
@testable import VitrineDetect

@Suite struct RegexWorkTests {
    /// Work units `pattern` spends searching `atom` repeated to `length` UTF-16 units.
    static func work(_ pattern: String, _ atom: String, length: Int) throws -> Int {
        let matcher = try ICURegexMatcher(pattern: pattern)
        var text = ""
        while text.utf16.count < length { text += atom }
        let budget = MatchBudget(.unlimited)
        _ = matcher.matches(in: text, budget: budget)
        return budget.work
    }

    /// config.env.secret as it was before the fix (`\b` run, secret word, run): kept here only to prove the measure.
    static let oldEnvSecret = ##"(?i)\b[A-Za-z0-9_.\-]*(?:SECRET|TOKEN|PASSW(?:OR)?D|PASS|PWD|API[_\-]?KEY|ACCESS[_\-]?KEY|PRIVATE[_\-]?KEY|AUTH[_\-]?KEY|CLIENT[_\-]?SECRET|CREDENTIALS?|SIGNING[_\-]?KEY|ENCRYPTION[_\-]?KEY|[_.\-]KEY(?=\s*[=:]))[A-Za-z0-9_.\-]*\s*[=:]\s*["']?(?<secret>[^\s"'#]{8,})"##

    static func builtInPattern(_ id: String) throws -> String {
        let detector = try #require(Catalogue.builtIn.first { $0.id == id })
        return try detector.patterns[0].compiledPattern()
    }

    /// The finding's lines: a long run of secret words and separators with no `=` or `:`. Doubling a `pass.pass.…` line
    /// multiplied the old pattern's work by more than four (cubic: about 46 times for four times the length; 4 s on
    /// 2,000 characters); the new pattern's work only doubles, on that line and on the other separator runs.
    @Test func configEnvSecretIsLinearWhereItWasCubic() throws {
        let old500 = try Self.work(Self.oldEnvSecret, "pass.", length: 500)
        let old1000 = try Self.work(Self.oldEnvSecret, "pass.", length: 1_000)
        #expect(Double(old1000) / Double(old500) > 3.5, "the measure sees the old blow-up: \(old500) → \(old1000)")

        let new = try Self.builtInPattern("config.env.secret")
        for atom in ["pass.", "a-", "x.y", "sk-ant-"] {
            let new1k = try Self.work(new, atom, length: 1_024)
            let new2k = try Self.work(new, atom, length: 2_048)
            let new16k = try Self.work(new, atom, length: 16_384)
            #expect(Double(new2k) / Double(new1k) < 2.3, "\(atom): \(new1k) → \(new2k)")
            #expect(new16k <= 3 * 16_384, "\(atom): \(new16k) units on 16 Ki characters")
        }
    }

    /// The rewrite still finds what the old pattern found: the same secret on every shape it is written for.
    @Test func configEnvSecretStillMatchesItsShapes() throws {
        let old = try ICURegexMatcher(pattern: Self.oldEnvSecret)
        let new = try ICURegexMatcher(pattern: try Self.builtInPattern("config.env.secret"))
        let lines = [
            "API_KEY=EXAMPLEa1b2c3d4e5f6", "export DB_PASSWORD = 'EXAMPLEhunter2xx'", "app.client_secret: EXAMPLEzzq81xk",
            "x-PASS=EXAMPLEvalue123", "MY_SIGNING_KEY=EXAMPLE998877aa", "service.key = EXAMPLE77aa88bb", "-PASSWORD=EXAMPLEabc12345",
            "AUTH_TOKEN_HINT=EXAMPLE0011223344", "KEYBOARD=EXAMPLE1234567", "monkey=EXAMPLE1234567", "PASSPORT: EXAMPLE12345678",
            "the password is long", "pass.pass.pass.pass", "token := EXAMPLEnotassign",
        ]
        for line in lines {
            let a = old.matches(in: line).map { VitrineDetect.Scanner.substring(line, $0.redactRange) }
            let b = new.matches(in: line).map { VitrineDetect.Scanner.substring(line, $0.redactRange) }
            #expect(a == b, "\(line): \(a) vs \(b)")
        }
    }

    /// Every built-in pattern on adversarial lines: four times the line, at most about four and a half times the work,
    /// and never more than three units per character. (Two built-ins, the e-mail and internal-hostname patterns, both
    /// off by default, grow slightly faster than linear on runs of `a-`; they stay inside both bounds at the longest
    /// line the Scanner reads.)
    @Test func everyBuiltInPatternIsLinearOnAdversarialLines() throws {
        let atoms = ["a", "a-", "pass.", "key=", "key=key:", "-", "0", "0 ", "a.", "x.y", ":", "a:", "<", "https://a:", "api key: ",
                     "key: ://", "key=a.", "_KEY", "-----", "----- BEGIN", "1.", "eyJa.", "sk-ant-", "@", "a@b."]
        for detector in Catalogue.builtIn {
            for (index, spec) in detector.patterns.enumerated() {
                let pattern = try spec.compiledPattern()
                for atom in atoms {
                    let short = try Self.work(pattern, atom, length: 1_024)
                    let long = try Self.work(pattern, atom, length: 4_096)
                    #expect(long <= 3 * 4_096, "\(detector.id)#\(index) on \(atom): \(long) units")
                    #expect(Double(long) / Double(max(short, 1)) < 4.9, "\(detector.id)#\(index) on \(atom): \(short) → \(long)")
                }
            }
        }
    }

    // MARK: the budget

    /// An exponential pattern (no nested quantifier, so no static check catches it) is stopped at its search time, and
    /// a stopped search reports nothing, never a partial list.
    @Test func aCatastrophicSearchIsStoppedAtItsTime() throws {
        let matcher = try ICURegexMatcher(pattern: #"^(?:a|a)*$"#)
        let budget = MatchBudget(MatchBudget.Limits(searchTime: .milliseconds(50), totalTime: .seconds(30)))
        let started = ContinuousClock.now
        #expect(matcher.matches(in: String(repeating: "a", count: 40) + "!", budget: budget) == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(budget.searchesOverTime == 1)
        #expect(budget.lastSearchOverTime)
        #expect(!budget.isExhausted, "one slow pattern does not stop the others")
        #expect(matcher.matches(in: "aaa", budget: budget)?.count == 1)
        #expect(!budget.lastSearchOverTime)
    }

    @Test func anExhaustedBudgetRefusesEverySearch() throws {
        let matcher = try ICURegexMatcher(pattern: "a")
        let budget = MatchBudget(MatchBudget.Limits(searchTime: .seconds(1), totalTime: .zero))
        #expect(matcher.matches(in: "aaa", budget: budget) == nil)
        #expect(budget.isExhausted)
    }

    @Test func aCancelledTaskStopsItsSearches() async throws {
        let matcher = try ICURegexMatcher(pattern: "a")
        let task = Task { () -> [PatternMatch]? in
            withUnsafeCurrentTask { $0?.cancel() }
            return matcher.matches(in: "aaa", budget: MatchBudget())
        }
        #expect(await task.value == nil)
    }

    // MARK: the Scanner

    static func catalogue(rules: [CustomRule] = []) throws -> CompiledCatalogue {
        try Catalogue.resolved(rules: rules)
    }

    /// A line longer than the Scanner reads is not searched, never cut: it is reported unchecked with no findings, and
    /// the lines around it are scanned as usual.
    @Test func aLineLongerThanTheLimitIsUncheckedNotCut() throws {
        let scanner = VitrineDetect.Scanner(catalogue: try Self.catalogue(), limits: VitrineDetect.Scanner.Limits(maxLineLength: 64, matching: .standard))
        let long = "STRIPE_SECRET_KEY=sk_live_gHBJ59jWkyqhEGdgw5UhJjnc " + String(repeating: "x", count: 64)
        let result = scanner.check([ScanLine(index: 0, text: "plain"), ScanLine(index: 1, text: long),
                                    ScanLine(index: 2, text: "sk_live_gHBJ59jWkyqhEGdgw5UhJjnc")])
        #expect(result.uncheckedLines == [1])
        #expect(!result.isComplete)
        #expect(result.findings.map(\.lineIndex) == [2])
        #expect(VitrineDetect.Scanner.Limits.standard.maxLineLength == 4_096)
    }

    /// A user rule that is too slow on a line leaves that line unchecked and names the rule; the built-in detectors'
    /// findings on the same line are still reported, and other lines are checked.
    @Test func aSlowRuleLeavesItsLineUncheckedAndNamesIt() throws {
        let slow = CustomRule(name: "slow", action: .blackOut, pattern: .regex(#"^(?:a|a)*$"#))
        let scanner = VitrineDetect.Scanner(catalogue: try Self.catalogue(rules: [slow]),
                              limits: VitrineDetect.Scanner.Limits(maxLineLength: 4_096, matching: MatchBudget.Limits(searchTime: .milliseconds(50), totalTime: .seconds(30))))
        let hostile = String(repeating: "a", count: 40) + "! sk_live_gHBJ59jWkyqhEGdgw5UhJjnc"
        let result = scanner.check([ScanLine(index: 0, text: hostile), ScanLine(index: 1, text: "nothing here")])
        #expect(result.uncheckedLines == [0])
        #expect(result.slowDetectorIDs == [slow.detectorID])
        #expect(result.findings.contains { $0.lineIndex == 0 && $0.detectorIDs.contains("payments.stripe.secretkey") })
    }

    /// Out of time for the whole scan: every line not yet searched is unchecked.
    @Test func aScanOutOfTimeReportsEveryLineUnchecked() throws {
        let scanner = VitrineDetect.Scanner(catalogue: try Self.catalogue(),
                              limits: VitrineDetect.Scanner.Limits(maxLineLength: 4_096, matching: MatchBudget.Limits(searchTime: .seconds(1), totalTime: .zero)))
        let result = scanner.check([ScanLine(index: 0, text: "sk_live_gHBJ59jWkyqhEGdgw5UhJjnc"), ScanLine(index: 1, text: "b")])
        #expect(result.uncheckedLines == [0, 1])
        #expect(result.findings.isEmpty)
    }

    /// A cancelled scan stops and says so.
    @Test func aCancelledScanReportsItsLinesUnchecked() async throws {
        let scanner = VitrineDetect.Scanner(catalogue: try Self.catalogue())
        let task = Task { () -> VitrineDetect.Scanner.Result in
            withUnsafeCurrentTask { $0?.cancel() }
            return scanner.check([ScanLine(index: 0, text: "sk_live_gHBJ59jWkyqhEGdgw5UhJjnc")])
        }
        let result = await task.value
        #expect(result.uncheckedLines == [0])
    }

    /// The finding's line in a scan: hundreds of `pass.` with no `=`, at the longest line the Scanner reads, checks in
    /// well under a second (the old pattern took about 4 s on half of it).
    @Test func theFindingsLineChecksQuickly() throws {
        let scanner = VitrineDetect.Scanner(catalogue: try Self.catalogue())
        let line = String(String(repeating: "pass.", count: 900).prefix(4_096))
        let started = ContinuousClock.now
        let result = scanner.check([ScanLine(index: 0, text: line)])
        #expect(result.isComplete)
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}
