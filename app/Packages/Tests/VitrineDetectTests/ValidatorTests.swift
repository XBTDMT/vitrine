import Foundation
import Testing
@testable import VitrineDetect

@Suite("Validators (DETECTORS.md §5)")
struct ValidatorTests {
    @Test("Luhn", arguments: [
        ("4111 1111 1111 1111", true), ("5500 0000 0000 0004", true), ("378282246310005", true), ("4012-8888-8888-1881", true),
        ("6011111111111117", true), ("4111 1111 1111 1112", false), ("0000 0000 0000 0000", false), ("1234 5678 9012 3456", false),
        ("0123456789012", false), ("1234567890123456789", false), ("411111111111", false), ("41111111111111111111", false),
        ("79927398713", false),  // Luhn-valid but 11 digits
    ])
    func luhn(input: String, passes: Bool) {
        #expect(Validators.luhn(input).passes == passes)
    }

    @Test("IBAN mod-97", arguments: [
        ("DE89 3704 0044 0532 0130 00", true), ("GB82 WEST 1234 5698 7654 32", true), ("FR14 2004 1010 0505 0001 3M02 606", true),
        ("NL91ABNA0417164300", true), ("CH93 0076 2011 6238 5295 7", true), ("gb82west12345698765432", true),
        ("DE89 3704 0044 0532 0130 01", false), ("ZZ89 3704 0044 0532 0130 00", false), ("GB82WEST1234569876543", false),
        ("DE89370400440532013000X", false), ("DE", false),
    ])
    func iban(input: String, passes: Bool) {
        #expect(Validators.ibanMod97(input).passes == passes)
    }

    @Test func ibanLengthTableIsComplete() {
        #expect(Validators.ibanLengths.count == 86)
        #expect(Validators.ibanLengths["NO"] == 15 && Validators.ibanLengths["RU"] == 33 && Validators.ibanLengths["HN"] == 28)
    }

    @Test("entropy", arguments: [
        ("k8Hs9dPq2mZx7Lw4", 3.0, true), ("aaaaaaa1", 3.0, false), ("12345678", 3.0, false), ("abcdefgh", 3.0, false),
        ("short1", 3.0, false), ("changeme", 3.0, false), ("your-key-here", 3.0, false), ("your_token", 3.0, false),
        ("xxxxxxxxxx", 3.0, false), ("<your-key-1>", 3.0, false), ("${DB_PASSWORD}", 3.0, false), ("%API_KEY%", 3.0, false),
        ("true", 3.0, false), ("undefined", 3.0, false), ("ab1ab1ab1ab1", 3.5, false), ("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", 3.5, true),
    ])
    func entropy(input: String, min: Double, passes: Bool) {
        #expect(Validators.entropy(input, min: min).passes == passes)
    }

    @Test func shannon() {
        #expect(Validators.shannonEntropy("aaaa") == 0)
        #expect(abs(Validators.shannonEntropy("abcd") - 2.0) < 1e-9)
    }

    static func b64u(_ s: String) -> String {
        Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    @Test func jwt() {
        let header = Self.b64u(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = Self.b64u(#"{"sub":"1234567890","name":"Test","iat":1516239022}"#)
        // RFC 7519 §3.1 example: header {"typ":"JWT","alg":"HS256"} with the documented payload
        let rfc = "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(Validators.jwt(rfc).passes)
        #expect(Validators.jwt("\(header).\(payload).c2lnbmF0dXJl").passes)
        #expect(Validators.jwt("\(header).\(payload).a.b.c").passes, "JWE has 5 parts")
        #expect(!Validators.jwt("\(header).\(payload)").passes, "2 parts")
        #expect(!Validators.jwt("\(header).\(payload).a.b").passes, "4 parts")
        #expect(!Validators.jwt("\(Self.b64u(#"{"typ":"JWT"}"#)).\(payload).sig").passes, "header without alg")
        #expect(!Validators.jwt("\(Self.b64u("[1,2]")).\(payload).sig").passes, "header not an object")
        #expect(!Validators.jwt("\(header).!!!.sig").passes, "payload not base64url")
        #expect(!Validators.jwt("notbase64.\(payload).sig").passes)
    }

    @Test func githubChecksum() {
        // The checksum is CRC32 over the 30-char payload, base62, left-padded to 6 (computed here, as §9 asks).
        let payload = "AbCdEfGhIjKlMnOpQrStUvWxYz0123"
        let crc = Validators.crc32(Array(payload.utf8))
        let token = "ghp_" + payload + Validators.base62(crc, width: 6)
        #expect(token.count == 40)
        #expect(Validators.githubChecksum(token).passes)
        #expect(Validators.githubChecksum("gho_" + payload + Validators.base62(crc, width: 6)).passes)
        #expect(!Validators.githubChecksum("ghp_" + payload + "000000").passes)
        #expect(!Validators.githubChecksum("ghp_" + payload).passes, "wrong length")
        #expect(Validators.githubChecksum("github_pat_" + String(repeating: "A", count: 22) + "_" + String(repeating: "B", count: 59)).passes, "fine-grained has no checksum")
        #expect(Validators.crc32(Array("123456789".utf8)) == 0xCBF4_3926, "CRC32 check value")
        #expect(Validators.base62(0, width: 6) == "000000")
        #expect(Validators.base62(61, width: 2) == "0z")
        #expect(Validators.base62(62, width: 2) == "10")
    }

    @Test func awsKeyIdPrefix() {
        #expect(Validators.awsKeyIdPrefix("AKIAIOSFODNN7EXAMPLE") == .passAnnotated(subkind: "access key"))
        #expect(Validators.awsKeyIdPrefix("ASIAIOSFODNN7EXAMPLE") == .passAnnotated(subkind: "temporary key"))
        #expect(Validators.awsKeyIdPrefix("AROAIOSFODNN7EXAMPLE") == .passAnnotated(subkind: "role"))
        #expect(Validators.awsKeyIdPrefix("ACCAIOSFODNN7EXAMPLE") == .passAnnotated(subkind: "context"))
        #expect(Validators.awsKeyIdPrefix("ZZZZIOSFODNN7EXAMPLE") == .pass, "annotates only, never rejects")
        #expect(Validators.awsPrefixKinds.count == 11)
    }

    @Test("phone shape", arguments: [
        ("+44 20 7946 0958", true), ("+84 912 345 678", true), ("+1 (415) 555-0132", true),
        ("+12 34", false), ("+1 111 111 1111", false), ("+123456789012345", true), ("+1234567890123456", false),
    ])
    func phone(input: String, passes: Bool) {
        #expect(Validators.phoneShape(input, minDigits: 8, maxDigits: 15).passes == passes)
    }

    @Test func dispatch() {
        #expect(Validators.run(.none, on: "anything") == .pass)
        #expect(Validators.run(.luhn, on: "4111111111111111") == .pass)
        #expect(Validators.run(.phoneShape(minDigits: 8, maxDigits: 15), on: "+12 34") == .reject(code: "phone.digits"))
        #expect(Validators.run(.entropy(min: 3.0), on: "<your-key-1>") == .reject(code: "entropy.placeholder"))
    }
}
