// The signed feed: signature first, then fields, then versions (G-21). Every key here is a throwaway made per test.
import CryptoKit
import Foundation
import Testing
@testable import VitrineUpdate

@Suite struct FeedVerifierTests {
    let key = Curve25519.Signing.PrivateKey()

    @Test func aGoodSignatureAndANewerVersionIsOffered() throws {
        let manifest = T.manifest()
        let outcome = try T.verifier(key: key).evaluate(feed: try T.feed(manifest, key: key))
        #expect(outcome == .available(manifest))
    }

    @Test func aFeedSignedByAnotherKeyIsRefused() throws {
        let other = Curve25519.Signing.PrivateKey()
        #expect(throws: UpdateError.badSignature) { try T.verifier(key: key).evaluate(feed: try T.feed(T.manifest(), key: other)) }
    }

    @Test func oneTamperedManifestByteIsRefused() throws {
        let signed = try FeedSigner.sign(T.manifest(), with: key)
        var bytes = try #require(Data(base64Encoded: signed.manifest))
        // "1.1.0" → "9.1.0": a single byte, the kind of change an attacker would want.
        let index = try #require(bytes.firstRange(of: Data("\"version\":\"1".utf8))).upperBound - 1
        bytes[index] = UInt8(ascii: "9")
        var tampered = signed
        tampered.manifest = bytes.base64EncodedString()
        #expect(throws: UpdateError.badSignature) { try T.verifier(key: key).evaluate(feed: try tampered.encoded()) }
    }

    @Test func aTamperedSignatureByteIsRefused() throws {
        let signed = try FeedSigner.sign(T.manifest(), with: key)
        var signature = try #require(Data(base64Encoded: signed.signature))
        signature[0] ^= 0x01
        var tampered = signed
        tampered.signature = signature.base64EncodedString()
        #expect(throws: UpdateError.badSignature) { try T.verifier(key: key).evaluate(feed: try tampered.encoded()) }
    }

    @Test func malformedAndOversizedFeedsAreRefusedBeforeParsing() throws {
        let v = T.verifier(key: key)
        #expect(throws: UpdateError.feedMalformed) { try v.evaluate(feed: Data("not json".utf8)) }
        #expect(throws: UpdateError.feedMalformed) { try v.evaluate(feed: Data(#"{"format":2,"manifest":"","signature":""}"#.utf8)) }
        #expect(throws: UpdateError.feedTooLarge) { try v.evaluate(feed: Data(count: FeedVerifier.maxFeedBytes + 1)) }
    }

    @Test func anEqualVersionIsUpToDateNotOffered() throws {
        let feed = try T.feed(T.manifest(version: "1.0.0", build: "5"), key: key)
        #expect(try T.verifier(key: key).evaluate(feed: feed) == .upToDate(latest: "1.0.0"))
    }

    @Test func anOlderVersionIsNeverOffered() throws {
        // A validly signed OLD release replayed at the feed address: a downgrade, refused.
        for (version, build) in [("0.9.0", "9"), ("1.0.0", "4"), ("1.0", "4")] {
            let feed = try T.feed(T.manifest(version: version, build: build), key: key)
            #expect(try T.verifier(key: key).evaluate(feed: feed) == .upToDate(latest: version), "\(version) (\(build))")
        }
    }

    @Test func aHigherBuildOfTheSameVersionIsNewer() throws {
        let manifest = T.manifest(version: "1.0.0", build: "6")
        #expect(try T.verifier(key: key).evaluate(feed: try T.feed(manifest, key: key)) == .available(manifest))
    }

    @Test func versionsCompareByNumbersThenBuild() {
        #expect(T.version("1.10.0", "1") > T.version("1.9.9", "99"))
        #expect(T.version("1.0", "3") == T.version("1.0.0", "3"))
        #expect(T.version("2.0", "1") > T.version("1.99", "1000"))
        #expect(AppVersion(marketing: "1.0-beta", build: "1") == nil)
        #expect(AppVersion(marketing: "1..0", build: "1") == nil)
        #expect(AppVersion(marketing: "1.0", build: "1a") == nil)
        #expect(AppVersion(marketing: "١.٠", build: "1") == nil, "non-ASCII digits are refused")
    }

    @Test func aNonHTTPSDownloadIsRefused() throws {
        let feed = try T.feed(T.manifest(url: "http://updates.example.com/Vitrine.dmg"), key: key)
        #expect(throws: UpdateError.insecureURL("http://updates.example.com/Vitrine.dmg")) { try T.verifier(key: key).evaluate(feed: feed) }
    }

    @Test func anotherAppsManifestIsRefused() throws {
        let feed = try T.feed(T.manifest(bundleID: "com.example.other"), key: key)
        #expect(throws: UpdateError.wrongApp("com.example.other")) { try T.verifier(key: key).evaluate(feed: feed) }
    }

    @Test func aRequiredMacOSNewerThanThisMacIsRefused() throws {
        let feed = try T.feed(T.manifest(minimumSystemVersion: "16.1"), key: key)
        #expect(throws: UpdateError.systemTooOld(required: "16.1")) { try T.verifier(key: key).evaluate(feed: feed) }
        let fine = try T.feed(T.manifest(minimumSystemVersion: "15.4"), key: key)
        #expect(throws: Never.self) { try T.verifier(key: key).evaluate(feed: fine) }
    }

    @Test func malformedFieldsAreRefused() throws {
        let v = T.verifier(key: key)
        #expect(throws: UpdateError.manifestInvalid("SHA-256")) { try v.evaluate(feed: try T.feed(T.manifest(sha256: "ABC"), key: key)) }
        #expect(throws: UpdateError.manifestInvalid("size")) { try v.evaluate(feed: try T.feed(T.manifest(size: 0), key: key)) }
        #expect(throws: UpdateError.manifestInvalid("version")) { try v.evaluate(feed: try T.feed(T.manifest(version: "1.x"), key: key)) }
    }

    @Test func thePlaceholderKeyIsNoTrust() {
        #expect(UpdateTrust(base64PublicKey: UpdateTrust.placeholder) == nil)
        #expect(UpdateTrust(base64PublicKey: "") == nil)
        #expect(UpdateTrust(base64PublicKey: Data(count: 31).base64EncodedString()) == nil)
        #expect(UpdateTrust(base64PublicKey: key.publicKey.rawRepresentation.base64EncodedString())?.keys.count == 1)
    }

    @Test func theSignerRoundTripsWithTheVerifier() throws {
        // The `vitrine release` path: digest a file, build the manifest, sign, encode; the app's verifier accepts it.
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appending(path: "Vitrine-1.1.0_7.dmg")
        let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: image)
        let digest = try FeedSigner.digest(of: image)
        #expect(digest.size == Int64(bytes.count))
        #expect(digest.sha256 == T.sha256(bytes))
        let manifest = T.manifest(size: digest.size, sha256: digest.sha256)
        let feed = try FeedSigner.sign(manifest, with: key).encoded()
        let trust = try #require(UpdateTrust(base64PublicKey: key.publicKey.rawRepresentation.base64EncodedString()))
        let verifier = FeedVerifier(trust: trust, bundleIdentifier: T.bundleID, current: T.version("1.0.0", "5"),
                                    systemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        #expect(try verifier.evaluate(feed: feed) == .available(manifest))
        // The manifest's signed bytes are exactly the canonical encoding, so a re-sign is reproducible.
        let signed = try JSONDecoder().decode(SignedFeed.self, from: feed)
        #expect(Data(base64Encoded: signed.manifest) == (try FeedSigner.manifestBytes(manifest)))
    }
}
