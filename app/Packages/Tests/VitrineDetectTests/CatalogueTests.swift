import Foundation
import Testing
@testable import VitrineDetect

struct Fixture: Decodable {
    let positive: [String]
    let negative: [String]
}

@Suite("Catalogue (DETECTORS.md §4, §9 invariants)")
struct CatalogueTests {
    static let fixturesDirectory: URL = {
        // Package.swift copies Tests/VitrineDetectTests/text into the bundle as the folder `text`.
        Bundle.module.url(forResource: "text", withExtension: nil)!
    }()

    static func fixture(for id: String) throws -> Fixture? {
        let url = fixturesDirectory.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    static let allIDs: [String] = Catalogue.builtIn.map(\.id)

    @Test func catalogueCounts() {
        #expect(Catalogue.builtIn.count == 84)
        #expect(Catalogue.builtIn.filter(\.enabledByDefault).count == 71)
        let perCategory = Dictionary(grouping: Catalogue.builtIn, by: \.category).mapValues(\.count)
        #expect(perCategory == [.ai: 12, .cloud: 13, .payments: 6, .scm: 10, .messaging: 10, .databases: 4, .tokens: 11, .config: 5, .personal: 8, .network: 5])
    }

    @Test func idsUniqueAndWellFormed() throws {
        let regex = try NSRegularExpression(pattern: Catalogue.idPattern)
        #expect(Set(Self.allIDs).count == Self.allIDs.count)
        for d in Catalogue.builtIn {
            #expect(regex.firstMatch(in: d.id, range: NSRange(location: 0, length: d.id.utf16.count)) != nil, "id \(d.id)")
            #expect(d.id.hasPrefix(d.category.rawValue + "."), "id \(d.id) carries its category")
            #expect(!d.title.isEmpty && !d.hint.isEmpty && !d.patterns.isEmpty)
            #expect(d.source == .builtIn)
        }
    }

    @Test func everyPatternCompilesAndNeverMatchesEmpty() throws {
        for d in Catalogue.builtIn {
            for spec in d.patterns {
                let source = try spec.compiledPattern()
                let matcher = try ICURegexMatcher(pattern: source)
                #expect(matcher.matches(in: "").isEmpty, "\(d.id) matches the empty string")
                #expect(!source.hasPrefix("(?i)") || spec.kind == .regex, "\(d.id): case-insensitivity is inline only")
            }
            if let indexes = d.validatedPatternIndexes {
                #expect(indexes.allSatisfy { $0 >= 0 && $0 < d.patterns.count }, "\(d.id) validator indexes in range")
            }
        }
    }

    @Test func specPinnedShapes() throws {
        let byID = Dictionary(uniqueKeysWithValues: Catalogue.builtIn.map { ($0.id, $0) })
        #expect(byID["tokens.pem.privatekey"]?.scope == .block(endMarkers: ["END", "PRIVATE KEY"]))
        #expect(byID["personal.card.pan"]?.validator == .luhn)
        #expect(byID["personal.iban.account"]?.validator == .ibanMod97)
        #expect(byID["personal.iban.account"]?.enabledByDefault == true)
        #expect(byID["config.env.secret"]?.validator == .entropy(min: 3.0))
        #expect(byID["cloud.aws.secretkey"]?.validator == .entropy(min: 3.5))
        #expect(byID["scm.github.token"]?.validator == .githubChecksum && byID["scm.github.token"]?.validatedPatternIndexes == [0])
        #expect(byID["cloud.supabase.key"]?.validator == .jwt && byID["cloud.supabase.key"]?.validatedPatternIndexes == [2])
        #expect(byID["cloud.aws.accesskeyid"]?.validator == .awsKeyIdPrefix)
        #expect(byID["personal.phone.e164"]?.validator == .phoneShape(minDigits: 8, maxDigits: 15))
        #expect(byID["payments.stripe.publishable"]?.enabledByDefault == false && byID["payments.stripe.publishable"]?.severity == .low)
        #expect(byID["tokens.ssh.publickey"]?.enabledByDefault == false)
        #expect(Catalogue.builtIn.filter { $0.category == .network }.allSatisfy { !$0.enabledByDefault && $0.severity == .low })
        #expect(Catalogue.builtIn.filter { $0.category == .ai }.allSatisfy { $0.enabledByDefault && $0.severity == .critical })
        #expect(try byID["ai.anthropic.apikey"]?.patterns[0].compiledPattern() == #"sk-ant-[A-Za-z0-9_\-]{24,}"#)
        #expect(byID["ai.anthropic.apikey"]?.patterns[0].caseSensitive == true)
    }

    @Test func builtInOrderIsCatalogueOrder() {
        let order: [Detector.Category] = [.ai, .cloud, .payments, .scm, .messaging, .databases, .tokens, .config, .personal, .network]
        let seen = Catalogue.builtIn.map(\.category)
        var last = -1
        for c in seen {
            let i = order.firstIndex(of: c)!
            #expect(i >= last)
            last = i
        }
    }

    /// Every built-in detector has a fixture file with ≥1 positive and ≥1 negative line, and each line behaves
    /// when that detector runs alone (positives → ≥1 finding, negatives → none).
    @Test("fixtures", arguments: allIDs)
    func fixtures(id: String) throws {
        let detector = try #require(Catalogue.builtIn.first { $0.id == id })
        let fixture = try #require(try Self.fixture(for: id), "Tests/VitrineDetectTests/text/\(id).json is missing — a detector without fixtures does not merge")
        #expect(!fixture.positive.isEmpty && !fixture.negative.isEmpty, "\(id) needs ≥1 positive and ≥1 negative")
        let compiled = CompiledCatalogue(detectors: [try Catalogue.compile(detector)], allowRules: [], compileErrors: [:])
        let scanner = Scanner(catalogue: compiled)
        for line in fixture.positive {
            let findings = scanner.scan([ScanLine(index: 0, text: line)])
            #expect(!findings.isEmpty, "\(id) should match positive fixture #\(fixture.positive.firstIndex(of: line) ?? -1)")
            #expect(findings.allSatisfy { $0.detectorIDs == [id] && $0.severity == detector.severity && $0.category == detector.category })
        }
        for line in fixture.negative {
            #expect(scanner.scan([ScanLine(index: 0, text: line)]).isEmpty, "\(id) must not match negative fixture #\(fixture.negative.firstIndex(of: line) ?? -1)")
        }
    }

    @Test func noOrphanFixtureFiles() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.fixturesDirectory.path).filter { $0.hasSuffix(".json") }
        let ids = Set(files.map { String($0.dropLast(5)) })
        #expect(ids.subtracting(Self.allIDs).isEmpty, "fixture files without a detector")
        #expect(Set(Self.allIDs).subtracting(ids).isEmpty, "detectors without a fixture file")
    }

    @Test func secretGroupIsHonouredInBuiltIns() throws {
        let compiled = try Catalogue.resolved()
        let line = "postgres://app:s3cr3tpw@db.internal:5432/app"
        let f = Scanner(catalogue: compiled).scan([ScanLine(index: 0, text: line)]).first { $0.detectorIDs.contains("databases.url.credentials") }
        #expect(f.map { Scanner.substring(line, $0.secretRange) } == "s3cr3tpw")
    }

    // MARK: config.labelled.secret against the rest of the defaults (G-16, DETECTORS.md §8)

    static func scan(_ line: String, without id: String? = nil) throws -> [Finding] {
        let compiled = try Catalogue.resolved(state: id.map { [$0: false] } ?? [:])
        return Scanner(catalogue: compiled).scan([ScanLine(index: 0, text: line)])
    }

    /// Both shapes of the 2026-10-27 live test (made up): one cover each, and only the plain-word detector knows them.
    @Test func plainWordLabelsAreCovered() throws {
        for line in ["KEY: 4820193746582019374655", "API KEY: 7302x918465027381946"] {
            let findings = try Self.scan(line)
            #expect(findings.count == 1)
            #expect(findings.first?.detectorIDs == ["config.labelled.secret"])
            #expect(try Self.scan(line, without: "config.labelled.secret").isEmpty, "no other default detector covers it")
        }
    }

    /// A vendor token behind a plain-word label is one box that the vendor detector owns; a labelled card number is one
    /// box, not two (the merge of §8, in catalogue order).
    @Test func overlappingFindingsMergeIntoOneBox() throws {
        let stripe = "API KEY: sk_live_Zq8vN3pXw7Lk2Rt9Yb4Hc6Mf"
        let f = try Self.scan(stripe)
        #expect(f.count == 1)
        #expect(f.first?.detectorIDs == ["payments.stripe.secretkey", "config.labelled.secret"])
        #expect(f.first.map { Scanner.substring(stripe, $0.secretRange) } == "sk_live_Zq8vN3pXw7Lk2Rt9Yb4Hc6Mf")

        let card = "Key: 4111111111111111"
        let c = try Self.scan(card)
        #expect(c.count == 1)
        #expect(Set(c.first?.detectorIDs ?? []) == ["config.labelled.secret", "personal.card.pan"])
        #expect(c.first?.secretRange == NSRange(location: 5, length: 16))
    }

    /// Code-style labels keep exactly the covers they had: the same number of findings, the same ranges and the same
    /// label owner with the plain-word detector on as with it off (it only joins as a later id).
    @Test func codeStyleLabelsKeepTheirFindings() throws {
        let lines = [
            "API_KEY=LJa8hTgjUwSuWTMisdQwvcKw1bppqqWh", "STRIPE_SECRET_KEY=sk_live_Zq8vN3pXw7Lk2Rt9Yb4Hc6Mf",
            "SECRET_KEY=Hq7Wm2Zx9Rk4Tv8Lp3Nc6Bs1", "ACCESS_TOKEN=\"Pz4Kt8Wq2Nm7Xr5Lb9Vc3Hd\"", "api_key: 9fK2mQ7xL4vR8tW1zN6pB3cH",
            "API-KEY: Tn5Rw8Kq3Zm7Xp2Lv9Hc4Bd", "export AUTH_TOKEN=Bv6Nq2Xt8Lk4Rz9Wm3Hp7Cs", "JWT_SIGNING_KEY: c6CE7mvJyLA9Z14VRnVsFePs",
            "FIREBASE_KEY=Qm7vT2xLp9RkW4sZ", "  \"client_secret\": \"Wx3Kp9Rt2Lm7Zq5Nv8Hb4Cd\",", "DEBUG_TOKEN=true", "API_KEY=your-key-here",
        ]
        for line in lines {
            let on = try Self.scan(line), off = try Self.scan(line, without: "config.labelled.secret")
            #expect(on.map(\.secretRange) == off.map(\.secretRange), "ranges for line \(lines.firstIndex(of: line) ?? -1)")
            #expect(on.map { $0.detectorIDs.first } == off.map { $0.detectorIDs.first }, "label owner for line \(lines.firstIndex(of: line) ?? -1)")
        }
        // A digits-only value behind a code-style label: config.env.secret reaches it only through a route C misread
        // variant (pass 2), the plain-word detector in pass 1, so it is still one box over the same range, now owned by
        // the plain-word detector.
        for line in ["API_KEY=4820193746582019374655", "SECRET=4820193746582019374655"] {
            let on = try Self.scan(line), off = try Self.scan(line, without: "config.labelled.secret")
            #expect(on.map(\.secretRange) == off.map(\.secretRange))
            #expect(on.first?.detectorIDs == ["config.labelled.secret", "config.env.secret"])
        }
    }

    /// Vision-style fullwidth output (measured 2026-10-27 on a dark Menlo terminal): the fold is 1:1, so the finding's
    /// range indexes the OCR text itself and lands on the glyphs that were read.
    @Test func fullwidthVisionOutputIsFoundAtItsOwnOffsets() throws {
        let phone = "（212）555-0199"
        let scanner = Scanner(catalogue: try Catalogue.resolved(state: ["personal.phone.nanp": true]))
        let found = scanner.scan([ScanLine(index: 0, text: phone)]).filter { $0.detectorIDs.contains("personal.phone.nanp") }
        #expect(found.count == 1)
        #expect(found.first?.secretRange == NSRange(location: 0, length: phone.utf16.count))

        let labelled = "API KEY：7302x918465027381946"
        let f = try Self.scan(labelled)
        #expect(f.map(\.detectorIDs) == [["config.labelled.secret"]])
        #expect(f.first.map { Scanner.substring(labelled, $0.secretRange) } == "7302x918465027381946")
    }

    // MARK: resolved(with:state:rules:allowRules:)

    @Test func resolvedDefaultsToEnabledByDefault() throws {
        let compiled = try Catalogue.resolved()
        #expect(compiled.detectors.count == 71)
        #expect(compiled.compileErrors.isEmpty)
        #expect(!compiled.detectors.contains { $0.detector.id == "personal.email.address" })
    }

    @Test func stateTogglesDetectors() throws {
        let compiled = try Catalogue.resolved(state: ["personal.email.address": true, "ai.anthropic.apikey": false])
        #expect(compiled.detectors.contains { $0.detector.id == "personal.email.address" })
        #expect(!compiled.detectors.contains { $0.detector.id == "ai.anthropic.apikey" })
        #expect(compiled.detectors.count == 71)
    }

    @Test func overridesReplacePatternsAndMarkSource() throws {
        let compiled = try Catalogue.resolved(with: ["ai.anthropic.apikey": [.prefix("sk-ant-", n: 4)]])
        let d = try #require(compiled.detectors.first { $0.detector.id == "ai.anthropic.apikey" })
        #expect(d.detector.source == .override)
        #expect(d.detector.patterns == [.prefix("sk-ant-", n: 4)])
        #expect(!d.matchers[0].matches(in: "sk-ant-abcd").isEmpty)
    }

    /// Fail-open #3: an edit that does not compile is reported, and the detector keeps running on its built-in patterns
    /// (it used to vanish from the catalogue, so its secrets went uncovered).
    @Test func badOverrideFallsBackToTheBuiltInPatterns() throws {
        let builtIn = try #require(Catalogue.builtIn.first { $0.id == "ai.anthropic.apikey" })
        let compiled = try Catalogue.resolved(with: ["ai.anthropic.apikey": [.regex("(")]])
        #expect(compiled.overrideErrors["ai.anthropic.apikey"] == "This isn't a valid regular expression")
        #expect(compiled.compileErrors.isEmpty, "an override's failure is not a custom rule's")
        let kept = try #require(compiled.detectors.first { $0.detector.id == "ai.anthropic.apikey" })
        #expect(kept.detector.source == .builtIn)
        #expect(kept.detector.patterns == builtIn.patterns)
        #expect(compiled.detectors.count == 71, "no detector is lost")
    }

    @Test func customRulesBecomeDetectorsAndAllowRules() throws {
        let black = CustomRule(name: "Customer ids", action: .blackOut, pattern: PatternSpec(kind: .example, value: "CUS-004213"))
        let allow = CustomRule(name: "Project Falcon", action: .allow, pattern: PatternSpec(kind: .exactText, value: "Project Falcon"))
        let bad = CustomRule(name: "broken", action: .blackOut, pattern: .regex("["))
        let badAllow = CustomRule(name: "broken allow", action: .allow, pattern: .regex("["))
        let off = CustomRule(name: "off", action: .blackOut, pattern: .regex("x"), isEnabled: false)
        let compiled = try Catalogue.resolved(rules: [black, allow, bad, badAllow, off])
        let custom = try #require(compiled.detectors.first { $0.detector.id == black.detectorID })
        #expect(custom.detector.category == .custom && custom.detector.severity == .high && custom.detector.source == .custom && custom.detector.validator == .none)
        #expect(custom.detector.id.hasPrefix("custom."))
        #expect(compiled.allowRules.map { $0.rule.id } == [allow.id])
        #expect(compiled.compileErrors.keys.sorted() == [bad.id.uuidString, badAllow.id.uuidString].sorted())
        #expect(compiled.detectors.count == 72)
        let findings = Scanner(catalogue: compiled).scan([ScanLine(index: 0, text: "CUS-998877 for Project Falcon")])
        #expect(findings.map(\.detectorIDs) == [[black.detectorID]])
    }
}
