// G-12 routes C and D: bounded misread candidates through unchanged validators, and the shared label lexicon.
// Every value below is made up.
import Foundation
import Testing
@testable import VitrineDetect

@Suite("Misread candidates (G-12 route C)")
struct MisreadCandidateTests {
    /// A made-up classic GitHub token whose CRC32 checksum is right: `ghp_` + 30 payload characters + 6 checksum.
    static let payload = "Xk7lmQ2pRt9vWz4bNc8dFg1hJs5yLa"
    static var validGitHub: String { "ghp_" + payload + Validators.base62(Validators.crc32(Array(payload.utf8)), width: 6) }

    @Test func singleSwapsAreBoundedAndOneUnitEach() {
        let text = String(repeating: "lO0I1", count: 100)                    // 500 confusable units
        let swaps = MisreadCandidates.singleSwaps(text)
        #expect(swaps.count == MisreadCandidates.maxSwaps)
        let original = Array(text.utf16)
        for swap in swaps {
            let units = Array(swap.utf16)
            #expect(units.count == original.count)
            #expect(zip(units, original).filter { $0 != $1 }.count == 1)
        }
    }

    @Test func caseFlipsAreOnlyTheSameShapeLetters() {
        #expect(MisreadCandidates.singleSwaps("z").contains("Z"))
        #expect(MisreadCandidates.singleSwaps("K").contains("k"))
        #expect(MisreadCandidates.singleSwaps("a").isEmpty)                  // `a` and `A` look different
        #expect(MisreadCandidates.singleSwaps("G").isEmpty)
    }

    @Test func onlyStrongChecksAreRepairedBySwaps() {
        #expect(MisreadCandidates.swapsCanRepair(.githubChecksum))
        #expect(MisreadCandidates.swapsCanRepair(.jwt))
        #expect(!MisreadCandidates.swapsCanRepair(.luhn))
        #expect(!MisreadCandidates.swapsCanRepair(.ibanMod97))
        #expect(!MisreadCandidates.swapsCanRepair(.entropy(min: 3.0)))
    }

    @Test func lineVariantsAreBounded() {
        let line = (0..<20).map { "abcdefghijkl\($0)" }.joined(separator: " ") + " <<<^<<< C<<<"
        let variants = MisreadCandidates.lineVariants(line)
        // 5 class mappings + 1 join + 1 `<` repair + 16 run extensions + 3 probes × at most 4 fragments.
        #expect(variants.count <= 5 + 1 + 1 + MisreadCandidates.maxRunExtension + 12)
        #expect(MisreadCandidates.lineVariants("hello world").isEmpty)
    }

    @Test func variantRangesMapBackAcrossAnInsertion() {
        let variant = MisreadCandidates.Variant(text: "ab_Xcd", insertions: [3], changed: [3])
        #expect(variant.originalRange(of: NSRange(location: 0, length: 6)) == NSRange(location: 0, length: 5))
        #expect(variant.originalRange(of: NSRange(location: 4, length: 2)) == NSRange(location: 3, length: 2))
        #expect(variant.repairs(NSRange(location: 0, length: 6)))
        #expect(!variant.repairs(NSRange(location: 4, length: 2)))          // touches no change
    }

    @Test func aRewriteIsNotARepair() {
        let variant = MisreadCandidates.Variant(text: "llll", insertions: [], changed: [0, 1, 2, 3])
        #expect(!variant.repairs(NSRange(location: 0, length: 4)))
    }

    // MARK: through the Scanner, with the built-in detectors and validators unchanged

    static func scan(_ id: String, _ line: String) throws -> [Finding] {
        Scanner(catalogue: try Catalogue.resolved(state: Dictionary(uniqueKeysWithValues: Catalogue.builtIn.map { ($0.id, $0.id == id) })))
            .scan([ScanLine(index: 0, text: line)])
    }

    @Test func aGitHubTokenWithOneMisreadIsFoundAtTheReadRange() throws {
        let token = Self.validGitHub
        #expect(try Self.scan("scm.github.token", token).count == 1)
        let misread = token.replacingOccurrences(of: "l", with: "1")         // the one `l` read as `1`
        #expect(Validators.githubChecksum(misread) != .pass)
        let findings = try Self.scan("scm.github.token", misread)
        #expect(findings.count == 1)
        #expect(findings.first?.secretRange == NSRange(location: 0, length: misread.utf16.count))
    }

    @Test func aWrongChecksumThatNoSingleSwapFixesStaysRejected() throws {
        var units = Array(Self.validGitHub)
        units[units.count - 1] = units.last == "Q" ? "R" : "Q"               // break the checksum itself
        #expect(try Self.scan("scm.github.token", String(units)).isEmpty)
    }

    @Test func aCardNumberIsNeverRepairedBySwaps() throws {
        // Luhn passes one guess in ten: a near-miss card number must stay rejected.
        #expect(try Self.scan("personal.card.pan", "4111 1111 1111 1112").isEmpty)
    }

    @Test func aBase32SecretReadWithAZeroIsFound() throws {
        let line = "otpauth://totp/Example:me@example.com?secret=JBSWY3DPEHPK3PXP0QRS&issuer=Example"
        #expect(try Self.scan("tokens.otp.uri", line).count == 1)
    }

    @Test func aFixedLengthHexKeyMissingOneCharacterIsFound() throws {
        let full = "rubygems_" + String(repeating: "0a1b2c3d", count: 6)    // 48 hex
        #expect(try Self.scan("scm.rubygems.key", full).count == 1)
        #expect(try Self.scan("scm.rubygems.key", String(full.dropLast())).count == 1)
        #expect(try Self.scan("scm.rubygems.key", String(full.dropLast(3))).isEmpty)    // three short is not one dropped
    }

    @Test func anUnderscoreReadAsASpaceIsJoined() throws {
        let body = String(repeating: "Ab3dE", count: 28)                    // 140 token characters
        var parts = Array(body)
        parts[40] = "_"; parts[90] = "_"
        let key = "AAAAb3dEf9Q:" + String(parts)
        #expect(try Self.scan("cloud.firebase.key", key).count == 1)
        let misread = key.replacingOccurrences(of: "_", with: " ")
        #expect(try Self.scan("cloud.firebase.key", misread).count == 1)
    }

    @Test func anMRZFillerReadShortIsCompleted() throws {
        let mrz = "P<UTOERIKSSON<<ANNA<MARIA" + String(repeating: "<", count: 19)
        #expect(try Self.scan("personal.passport.mrz", mrz).count == 1)
        let misread = "P<UTOERIKSSON<<ANNA<MARIA<<<<<<< C<<<<<<"                 // as the 2× re-read measured
        #expect(try Self.scan("personal.passport.mrz", misread).count == 1)
    }

    @Test func aDigitsToLettersRewriteDoesNotFeedABroadPattern() throws {
        let det = Detector(id: "t.a.a", title: "", category: .custom, hint: "", patterns: [.regex("[a-z]{4}")], severity: .low)
        let cat = CompiledCatalogue(detectors: [try Catalogue.compile(det)], allowRules: [], compileErrors: [:])
        let findings = Scanner(catalogue: cat).scan([ScanLine(index: 0, text: "word 4111111111111112")])
        #expect(findings.count == 1)                                        // only "word"
    }
}

@Suite("Label trust (G-12 route D)")
struct LabelTrustTests {
    static func lines(_ texts: String...) -> [ScanLine] { texts.enumerated().map { ScanLine(index: $0.offset, text: $0.element) } }

    @Test func theLexiconIsTheConfigDetectorsOwn() {
        #expect(LabelTrust.labelDetectorIDs == ["config.env.secret", "config.labelled.password", "config.yaml.secret", "config.labelled.secret"])
        #expect(!LabelTrust.matchers.isEmpty)
    }

    @Test func keyNamesEndingInKeyLabelTheirValue() {
        #expect(!LabelTrust.labelledValues(in: "FIREBASE_KEY=Qm7vT2xLp9RkW4sZ").isEmpty)
        #expect(!LabelTrust.labelledValues(in: #"  "supabase_key": "Vb3nQ8rTz5Lw1KpX","#).isEmpty)
        #expect(LabelTrust.labelledValues(in: "SSH_KEY_PATH=/home/dev/.ssh/id_ed25519").isEmpty)
        #expect(LabelTrust.labelledValues(in: "MONKEY_NAME=george2024abc").isEmpty)
    }

    @Test func aLabelledValueWithoutAVendorFindingIsFlagged() throws {
        let lines = Self.lines("AZURE_CLIENT_SECRET=kem3nRw7TQIlar_AbdQcw1¿JWkJ8RFp~nx9AmkDM", "PORT=8080", "hello world")
        let scanner = Scanner(catalogue: try Catalogue.resolved())
        #expect(LabelTrust.unrecognizedLabelLines(lines, findings: scanner.scan(lines)) == [0])
    }

    @Test func aLabelledValueAVendorDetectorRecognizedIsNotFlagged() throws {
        let lines = Self.lines("STRIPE_KEY=sk_live_Ab12Cd34Ef56Gh78Ij90Kl12")
        let scanner = Scanner(catalogue: try Catalogue.resolved())
        let findings = scanner.scan(lines)
        #expect(findings.contains { $0.detectorIDs.contains("payments.stripe.secretkey") })
        #expect(LabelTrust.unrecognizedLabelLines(lines, findings: findings).isEmpty)
    }
}
