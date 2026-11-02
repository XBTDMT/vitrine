// Fail-open #20: on text Vision read, a validator that checks a vendor format (GitHub's checksum, a JWT's header) must not
// drop a match whose prefix and shape are the vendor's: one or two misread characters break the checksum or the header
// while the token is still on screen. Such a match is kept as an unverified finding (covered, flagged), while on exact
// text (the text fixtures, text copied beside an image, the Settings line tester) the rejection still drops it.
// Validators that decide whether a generic shape is a secret at all (entropy, Luhn, IBAN, phone) keep dropping on both.
// Every token is made up.
import Foundation
import Testing
@testable import VitrineDetect

@Suite("Unverified vendor-format matches on recognized text (fail-open #20)")
struct UnverifiedFormatTests {
    static func scanner(_ ids: [String], input: VitrineDetect.Scanner.Input) throws -> VitrineDetect.Scanner {
        VitrineDetect.Scanner(catalogue: try Catalogue.resolved(state: Dictionary(uniqueKeysWithValues: Catalogue.builtIn.map { ($0.id, ids.contains($0.id)) })),
                input: input)
    }

    static func scan(_ line: String, _ ids: [String], _ input: VitrineDetect.Scanner.Input) throws -> [Finding] {
        try scanner(ids, input: input).scan([ScanLine(index: 0, text: line)])
    }

    /// `text` with the characters at `offsets` replaced by `with` (one per offset): a misread.
    static func misread(_ text: String, at offsets: [Int], with replacements: [Character]) -> String {
        var chars = Array(text)
        for (o, c) in zip(offsets, replacements) { chars[o] = c }
        return String(chars)
    }

    @Test func aGitHubTokenWithTwoMisreadCharactersIsCoveredUnverified() throws {
        // A fixture positive (valid checksum), two characters misread: no single swap repairs it.
        let token = Self.misread("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", at: [9, 20], with: ["Q", "w"])
        let line = "export GITHUB_TOKEN=" + token
        try #require(try Self.scan(line, ["scm.github.token"], .exact).isEmpty, "the misread must break the checksum")
        let found = try Self.scan(line, ["scm.github.token"], .recognized)
        let finding = try #require(found.first)
        #expect(found.count == 1 && finding.unverified && finding.detectorIDs == ["scm.github.token"])
        #expect(VitrineDetect.Scanner.substring(line, finding.secretRange) == token)
    }

    @Test func aJWTWhoseHeaderWasMisreadIsCoveredUnverified() throws {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IlRlc3QgVXNlciIsImlhdCI6MTUxNjIzOTAyMn0.M1Xt41AV-8O_vYID4sYKq4_JWGrMRS--W_XIUdBWxDX"
        let misread = Self.misread(jwt, at: [4, 7], with: ["6", "q"])
        let line = "Authorization: Bearer " + misread
        try #require(try Self.scan(line, ["tokens.jwt.compact"], .exact).isEmpty, "the misread must break the header")
        let finding = try #require(try Self.scan(line, ["tokens.jwt.compact"], .recognized).first)
        #expect(finding.unverified && VitrineDetect.Scanner.substring(line, finding.secretRange) == misread)
    }

    @Test func aVerifiedMatchStaysVerifiedOnRecognizedText() throws {
        let found = try Self.scan("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", ["scm.github.token"], .recognized)
        #expect(found.count == 1 && found.allSatisfy { !$0.unverified })
    }

    /// Ordinary text that carries the vendor prefix is never covered: the prefix alone is not the token's shape.
    @Test(arguments: [
        "Create a personal access token; classic ones start with ghp_ and are 40 characters long",
        "ghp_tokens expire after 90 days unless you choose otherwise",
        "Fine-grained tokens use the github_pat_ prefix instead",
        "see the docs at ghp_example_token_value_here for the format",
        "A JWT header such as eyJhbGciOiJIUzI1NiJ9 is base64 for the algorithm",
        "token: eyJ.eyJ.sig",
        "the three parts are eyJ..., eyJ... and a signature",
    ])
    func proseWithAVendorPrefixIsNotCovered(_ line: String) throws {
        let ids = ["scm.github.token", "tokens.jwt.compact", "tokens.kubeconfig.token", "cloud.supabase.key"]
        let recognized = try Self.scan(line, ids, .recognized), exact = try Self.scan(line, ids, .exact)
        #expect(recognized.isEmpty)
        #expect(exact.isEmpty)
    }

    @Test func aGenericShapeTheEntropyValidatorRejectsIsStillDropped() throws {
        let entropy = try Self.scan("API_KEY=changeme", ["config.env.secret"], .recognized)
        let luhn = try Self.scan("card 4111 1111 1111 1112", ["personal.card.pan"], .recognized)
        #expect(entropy.isEmpty && luhn.isEmpty)
    }

    /// Over every built-in detector's negative fixtures: on recognized text the only thing added is an unverified
    /// finding of a detector whose validator checks a vendor format (a full-shape token whose checksum or header fails),
    /// never a verified finding and never one from another detector.
    @Test func onRecognizedTextNegativesGainOnlyUnverifiedVendorFormatFindings() throws {
        var unverified = 0
        for detector in Catalogue.builtIn {
            guard let fixture = try CatalogueTests.fixture(for: detector.id) else { continue }
            let compiled = CompiledCatalogue(detectors: [try Catalogue.compile(detector)], allowRules: [], compileErrors: [:])
            let scanner = VitrineDetect.Scanner(catalogue: compiled, input: .recognized)
            for line in fixture.negative {
                let found = scanner.scan([ScanLine(index: 0, text: line)])
                let id = detector.id, allUnverified = found.allSatisfy { $0.unverified }
                #expect(allUnverified, "\(id): a verified finding on a negative")
                let vendorFormat = detector.validator.checksVendorFormat
                if !found.isEmpty { #expect(vendorFormat, "\(id): its validator must keep dropping") }
                unverified += found.count
            }
        }
        // The full-shape negatives with a failing checksum or header (GitHub, JWT, kubeconfig, Supabase) are the ones.
        #expect(unverified > 0)
    }
}
