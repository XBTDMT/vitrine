import AppKit
import XCTest
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineSupport

/// S-16 follow-up B (G-34, the class of F3/F8/F58 and F39) on the cards: an iOS app's or Android app's card names a
/// signer only when the signature was verified; a certificate's own name is shown labelled "Certificate name (not
/// verified)" with a caution mark, never as a check-marked "who made it". And a binary property list a format reader
/// gets is turned into XML only within the expansion budget. Every input is invented and built in a temporary folder
/// with system tools (clang, codesign -s -, openssl, zip, ditto); nothing touches a keychain or the network.
/// roadmap: S-16
@MainActor
final class S16FollowBCardTests: XCTestCase {
    static let famous = "Apple Distribution: Famous Vendor (ABCDE12345)"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-s16-followb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.currentDirectoryURL = dir
        p.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": FileManager.default.temporaryDirectory.path]
        let out = Pipe()
        p.standardError = out
        p.standardOutput = out
        try p.run()
        let message = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "S16FollowBCardTests", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments): \(message)"]) }
        return message
    }

    @discardableResult
    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func path(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private static func be32(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) }
    private static func le32(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
    private static func put32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    /// A throwaway self-signed certificate that names itself `commonName` (team OU ABCDE12345).
    private func identity(_ commonName: String, name: String) throws {
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "\(name).key", "-out", "\(name).pem",
                                     "-days", "30", "-subj", "/CN=\(commonName)/OU=ABCDE12345/O=Famous Vendor",
                                     "-addext", "extendedKeyUsage=codeSigning"])
        try run("/usr/bin/openssl", ["x509", "-in", "\(name).pem", "-outform", "DER", "-out", "\(name).der"])
    }

    /// Replaces an ad hoc signature with a CMS signature by the `id` key over the same code directory (its ad hoc flag
    /// cleared, the entitlement slots zeroed and their blobs dropped), as codesign would sign it.
    private func resign(_ binary: URL, id: String) throws {
        var data = [UInt8](try Data(contentsOf: binary))
        var offset = 32, area = 0..<0
        for _ in 0..<Self.le32(data, 16) {
            if Self.le32(data, offset) == 0x1D { let start = Self.le32(data, offset + 8); area = start..<(start + Self.le32(data, offset + 12)) }
            offset += Self.le32(data, offset + 4)
        }
        var blobs: [Int: [UInt8]] = [:]
        for i in 0..<Self.be32(data, area.lowerBound + 8) {
            let slot = Self.be32(data, area.lowerBound + 12 + i * 8), at = area.lowerBound + Self.be32(data, area.lowerBound + 16 + i * 8)
            blobs[slot] = Array(data[at..<(at + Self.be32(data, at + 4))])
        }
        var cd = try XCTUnwrap(blobs[0])
        cd.replaceSubrange(12..<16, with: Self.put32(Self.be32(cd, 12) & ~0x2))
        let hashOffset = Self.be32(cd, 16), special = Self.be32(cd, 24), hashSize = Int(cd[36])
        for slot in [5, 7] where slot <= special {
            let at = hashOffset - slot * hashSize
            cd.replaceSubrange(at..<(at + hashSize), with: [UInt8](repeating: 0, count: hashSize))
        }
        try write("cd.bin", Data(cd))
        try run("/usr/bin/openssl", ["cms", "-sign", "-binary", "-in", "cd.bin", "-signer", "\(id).pem", "-inkey", "\(id).key",
                                     "-outform", "DER", "-md", "sha256", "-out", "cd.cms"])
        let cms = [UInt8](try Data(contentsOf: path("cd.cms")))
        let parts: [(Int, [UInt8])] = [(0, cd), (2, try XCTUnwrap(blobs[2])), (0x10000, Self.put32(0xFADE_0B01) + Self.put32(8 + cms.count) + cms)]
        var index: [UInt8] = [], body: [UInt8] = []
        var at = 12 + 8 * parts.count
        for (slot, blob) in parts { index += Self.put32(slot) + Self.put32(at); body += blob; at += blob.count }
        let blob = Self.put32(0xFADE_0CC0) + Self.put32(at) + Self.put32(parts.count) + index + body
        XCTAssertLessThanOrEqual(blob.count, area.count)
        data.replaceSubrange(area, with: blob + [UInt8](repeating: 0, count: area.count - blob.count))
        try Data(data).write(to: binary)
    }

    /// An ad hoc build of `Payload/Field.app` whose executable is then signed by a self-signed certificate that calls
    /// itself a famous vendor, with a profile that same key signed, naming the vendor's team and listing that
    /// certificate: everything a borrower can make, nothing Apple signed.
    private func borrowedIPA() throws -> URL {
        try write("Payload/Field.app/Info.plist", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleDisplayName</key><string>Field</string><key>CFBundleIdentifier</key><string>com.example.s16.field</string>
        <key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string>
        <key>CFBundleExecutable</key><string>Field</string><key>MinimumOSVersion</key><string>17.0</string>
        <key>UIDeviceFamily</key><array><integer>1</integer></array>
        </dict></plist>
        """.utf8))
        try write("main.c", Data("int main(void){return 0;}\n".utf8))
        try run("/usr/bin/clang", ["-arch", "arm64", "-mmacosx-version-min=13.0", "-o", "Payload/Field.app/Field", "main.c"])
        try identity(Self.famous, name: "id")
        let der = try Data(contentsOf: path("id.der"))
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(90 * 86_400))
        try write("profile.plist", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Name</key><string>Field AdHoc</string><key>TeamName</key><string>Famous Vendor</string>
        <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
        <key>ExpirationDate</key><date>\(expiry)</date><key>CreationDate</key><date>2026-01-01T00:00:00Z</date>
        <key>ProvisionedDevices</key><array><string>DEV1</string></array>
        <key>DeveloperCertificates</key><array><data>\(der.base64EncodedString())</data></array>
        <key>Entitlements</key><dict><key>get-task-allow</key><false/></dict>
        </dict></plist>
        """.utf8))
        try run("/usr/bin/openssl", ["smime", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", "profile.plist",
                                     "-signer", "id.pem", "-inkey", "id.key", "-out", "Payload/Field.app/embedded.mobileprovision"])
        try write("padded.plist", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>com.example.padding</key><string>\(String(repeating: "x", count: 6000))</string></dict></plist>
        """.utf8))
        try run("/usr/bin/codesign", ["-s", "-", "-f", "--entitlements", "padded.plist", "Payload/Field.app"])
        try resign(path("Payload/Field.app/Field"), id: "id")
        try run("/usr/bin/zip", ["-q", "-r", "Field.ipa", "Payload"])
        return path("Field.ipa")
    }

    // MARK: iOS app

    /// The borrowed certificate and profile name the vendor everywhere they can; the card names nobody as the maker.
    func testABorrowedCertificateAndProfileShowNoVerifiedSigner() throws {
        let url = try borrowedIPA()
        let (doc, _) = try PackageFacts.iosApp(url: url, kind: .archive(.ipa))
        XCTAssertNil(doc.fact("signer"), "no signer fact without a verified signature")
        XCTAssertNil(doc.fact("team"), "the profile's team is not the maker unless the profile vouches")
        XCTAssertNil(doc.fact("certificate"), "the old unlabelled certificate fact is gone")
        XCTAssertEqual(doc.fact("claimedSigner")?.value, Self.famous)
        XCTAssertEqual(doc.fact("claimedSigner")?.label, "Certificate name (not verified)")
        XCTAssertEqual(doc.fact("claimedTeam")?.value, "Famous Vendor")
        XCTAssertTrue(doc.badges.contains { $0.level == .caution && $0.title == "Apple does not vouch for the signer" })

        let card = BinaryCard.make(document: doc, url: url)
        let who = try XCTUnwrap(card.answers.first { $0.question == "Who made it" })
        XCTAssertNotEqual(who.mark, .ok)
        XCTAssertEqual(who.mark, .caution)
        XCTAssertEqual(who.answer, "Someone Apple does not vouch for")
        XCTAssertEqual(who.evidence, "the certificate calls itself “\(Self.famous)”, which nothing verified")
        XCTAssertFalse(card.sentence.contains("Famous Vendor"), card.sentence)
        XCTAssertNotEqual(card.verdict.title, "Built by Famous Vendor")
        XCTAssertNotEqual(card.verdict.level, .calm)
        XCTAssertEqual(card.verdict.chip, "Check before installing", "a signature caution is not an expiring profile")
    }

    /// The same app with one byte of code changed after signing: a danger, never a name.
    func testChangedCodeIsABrokenSignatureOnTheCard() throws {
        let url = try borrowedIPA()
        try FileManager.default.removeItem(at: url)
        let executable = path("Payload/Field.app/Field")
        var bytes = [UInt8](try Data(contentsOf: executable))
        bytes[0x100] ^= 0xFF
        try Data(bytes).write(to: executable)
        try run("/usr/bin/zip", ["-q", "-r", "Field.ipa", "Payload"])
        let (doc, _) = try PackageFacts.iosApp(url: url, kind: .archive(.ipa))
        XCTAssertNil(doc.fact("signer"))
        XCTAssertEqual(doc.fact("signed")?.value, "Broken: its code does not match its signature")
        let card = BinaryCard.make(document: doc, url: url)
        XCTAssertEqual(card.verdict.level, .danger)
        XCTAssertEqual(card.answers.first { $0.question == "Who made it" }?.mark, .caution)
    }

    /// The words for a verified signature (no test can hold an Apple key, so the facts are those PackageFacts writes
    /// for one): the team the profile vouches for is the maker, with what the check covered as the evidence.
    func testAVerifiedSignatureNamesItsMaker() {
        let scope = "Its code and Info.plist; not its other files, which iOS checks when it installs the app"
        func card(_ facts: [Fact]) -> BinaryCard {
            BinaryCard.make(document: PreviewDocument(kind: .archive(.ipa), facts: [Fact(key: "name", label: "Name", value: "Field")] + facts,
                                                      badges: [], views: [.text("")]),
                            url: URL(fileURLWithPath: "/nonexistent/Field.ipa"))
        }
        let signed = [Fact(key: "signed", label: "Signature", value: "Signed and verified"),
                      Fact(key: "signer", label: "Signed by", value: "Apple Distribution: Example Field Co (F1E2D3C4B5)"),
                      Fact(key: "signatureScope", label: "Checked", value: scope)]
        let vouched = card(signed + [Fact(key: "team", label: "Team", value: "Example Field Co")])
        let who = vouched.answers.first { $0.question == "Who made it" }
        XCTAssertEqual(who?.mark, .ok)
        XCTAssertEqual(who?.answer, "Example Field Co")
        XCTAssertEqual(who?.evidence, scope)
        XCTAssertEqual(vouched.verdict.title, "Built by Example Field Co")
        let signerOnly = card(signed)
        XCTAssertEqual(signerOnly.answers.first { $0.question == "Who made it" }?.answer, "Apple Distribution: Example Field Co (F1E2D3C4B5)")
        XCTAssertEqual(signerOnly.verdict.title, "Signed by Apple Distribution: Example Field Co (F1E2D3C4B5)")
    }

    // MARK: Android app

    /// A v1 signature whose certificate calls itself a famous vendor: shown as the certificate's claim, with its
    /// digest, never as who made the app.
    func testAnAndroidCertificateNameIsAClaim() throws {
        try write("apk/AndroidManifest.xml", Data([0x03, 0x00, 0x08, 0x00, 0x08, 0x00, 0x00, 0x00]))
        try write("apk/classes.dex", Data("dex\n035\0".utf8))
        try write("apk/META-INF/MANIFEST.MF", Data("Manifest-Version: 1.0\n".utf8))
        try identity("Google LLC", name: "android")
        try run("/usr/bin/openssl", ["smime", "-sign", "-binary", "-outform", "DER", "-in", "apk/META-INF/MANIFEST.MF",
                                     "-signer", "android.pem", "-inkey", "android.key", "-out", "apk/META-INF/CERT.RSA"])
        try run("/usr/bin/ditto", ["-c", "-k", "apk", "app.apk"])
        let url = path("app.apk")
        let (doc, _) = try PackageFacts.androidApp(url: url, kind: .archive(.apk))
        XCTAssertNil(doc.fact("signer"))
        XCTAssertEqual(doc.fact("claimedSigner")?.value, "Google LLC")
        XCTAssertEqual(doc.fact("claimedSigner")?.label, "Certificate name (not verified)")
        XCTAssertEqual(doc.fact("certificateDigest")?.value.count, 64)
        let card = BinaryCard.make(document: doc, url: url)
        let who = try XCTUnwrap(card.answers.first { $0.question == "Who made it" })
        XCTAssertEqual(who.mark, .caution)
        XCTAssertEqual(who.answer, "Not verified")
        XCTAssertEqual(who.evidence, "the certificate calls itself “Google LLC”, which nothing verified")
        XCTAssertNotEqual(card.verdict.title, "Signed by Google LLC")
    }

    // MARK: Format readers (F39's class)

    /// 21 KB that Core Foundation writes out as 220 MB of XML: a reader's Source is not built from it.
    func testAReaderRefusesABinaryPlistThatExpandsPastTheBudget() throws {
        func be(_ v: Int, _ width: Int) -> [UInt8] { (0..<width).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        func header(_ count: Int) -> [UInt8] { count < 15 ? [0xA0 | UInt8(count)] : [0xAF, 0x12] + be(count, 4) }
        let objects: [[UInt8]] = [header(11) + [UInt8](repeating: 1, count: 11),
                                  header(20_000) + [UInt8](repeating: 2, count: 20_000),
                                  [0x5F, 0x12] + be(1_000, 4) + [UInt8](repeating: UInt8(ascii: "a"), count: 1_000)]
        var out = Array("bplist00".utf8)
        var offsets: [Int] = []
        for object in objects { offsets.append(out.count); out += object }
        let table = out.count
        for o in offsets { out += be(o, 4) }
        out += [0, 0, 0, 0, 0, 0, 4, 1] + be(objects.count, 8) + be(0, 8) + be(table, 8)
        let url = try write("Shared.plist", Data(out))
        let start = ContinuousClock.now
        let (doc, _) = try PackageFacts.reader(url: url, kind: .reader("plist"), id: "plist")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertEqual(doc.fact("form")?.value,
                       "The property list is too large to show: its shared parts expand past what a preview can hold")
    }
}
