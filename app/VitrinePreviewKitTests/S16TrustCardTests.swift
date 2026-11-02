import CryptoKit
import Foundation
import XCTest
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineSupport

/// S-16 lane 1 (G-34): a trust card claims only what the Security framework verified. Each input is crafted in a
/// temporary folder (S16TrustFixtures below) and read through the preview's own path (BinaryFacts, then BinaryCard), so
/// the assertions are on the words a person reads: no "notarized" from a ticket-shaped file, no Developer ID from a
/// certificate's name, no "Valid" from the quick check, no signer from a disk image's unverified bytes or a forged
/// installer signature, and never a calm "Checks passed" for any of them. roadmap: S-16
final class S16TrustCardTests: XCTestCase {
    static let fakeDeveloperID = "Developer ID Application: Invented Vendor (ABCDE12345)"
    static let fakeInstallerID = "Developer ID Installer: Invented Vendor (ABCDE12345)"

    private func card(_ url: URL, _ kind: FileKind) throws -> (PreviewDocument, BinaryCard) {
        let doc = try BinaryFacts.document(url: url, kind: kind)
        return (doc, BinaryCard.make(document: doc, url: url))
    }

    private func answer(_ card: BinaryCard, _ question: String) -> BinaryCard.Answer? {
        card.answers.first { $0.question == question }
    }

    /// No answer, title or sentence repeats a name nothing vouched for as if it were the signer.
    private func assertNameIsNotClaimed(_ name: String, _ doc: PreviewDocument, _ card: BinaryCard, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(doc.fact("signer"), "the signer fact is only for a verified signer", file: file, line: line)
        XCTAssertFalse(card.verdict.title.contains(name), card.verdict.title, file: file, line: line)
        XCTAssertFalse(card.sentence.contains(name), card.sentence, file: file, line: line)
        XCTAssertFalse(card.answers.contains { $0.answer.contains(name) }, "\(card.answers.map(\.answer))", file: file, line: line)
    }

    // MARK: Notarization (F2, F9)

    /// An ad hoc app with a ticket-shaped `Contents/CodeResources`: before, "Yes, notarized" and a calm verdict.
    func testATicketFileOnAnAdhocAppIsNotNotarized() throws {
        let fx = try S16TrustFixtures()
        let app = try fx.adhocApp("Ticketed")
        try fx.addFakeTicket(to: app)
        let (doc, card) = try card(app, .appBundle)
        XCTAssertEqual(doc.fact("notarization")?.value, "Ticket present, not verified")
        XCTAssertNotEqual(card.verdict.level, .calm)
        XCTAssertNotEqual(card.verdict.chip, "Checks passed")
        let checked = try XCTUnwrap(answer(card, "Has Apple checked it"))
        XCTAssertEqual(checked.mark, .caution)
        XCTAssertNotEqual(checked.answer, "Yes, notarized")
        XCTAssertFalse(card.verdict.reason.contains("without a warning"), card.verdict.reason)
    }

    // MARK: Who vouches for the signer (F5, F7)

    /// A self-signed certificate that calls itself a Developer ID, plus a ticket-shaped file: before, "Signed by
    /// Developer ID Application: … and notarized by Apple", "Gatekeeper will open it without a warning", "Checks passed".
    func testASelfSignedDeveloperIDNameIsNotVouchedFor() throws {
        let fx = try S16TrustFixtures()
        let app = try fx.selfSignedApp("Vendor", as: Self.fakeDeveloperID)
        try fx.addFakeTicket(to: app)
        let (doc, card) = try card(app, .appBundle)
        XCTAssertTrue(doc.fact("signature")?.value.hasPrefix("Valid") == true, "the signature is intact: \(doc.fact("signature")?.value ?? "-")")
        XCTAssertEqual(doc.fact("signerKind")?.value, "Not vouched for by Apple")
        XCTAssertEqual(doc.fact("claimedSigner")?.value, Self.fakeDeveloperID, "the name is shown only labelled as not verified")
        assertNameIsNotClaimed(Self.fakeDeveloperID, doc, card)
        XCTAssertEqual(card.verdict.level, .caution)
        XCTAssertNotEqual(card.verdict.chip, "Checks passed")
        XCTAssertFalse(card.verdict.title.contains("notarized"), card.verdict.title)
        let who = try XCTUnwrap(answer(card, "Who made it"))
        XCTAssertEqual(who.mark, .caution)
        XCTAssertEqual(who.answer, "Someone Apple does not vouch for")
        XCTAssertEqual(answer(card, "Has Apple checked it")?.mark, .caution)
    }

    // MARK: Valid is the full check (F4)

    /// A certificate-signed app whose resource changed after signing: before, the quick check said "Valid".
    func testAChangedResourceIsBrokenNotValid() throws {
        let fx = try S16TrustFixtures()
        let app = try fx.selfSignedApp("Changed", as: Self.fakeDeveloperID)
        try Data("changed after signing".utf8).write(to: app.appendingPathComponent("Contents/Resources/readme.txt"))
        let (doc, card) = try card(app, .appBundle)
        let signature = try XCTUnwrap(doc.fact("signature")?.value)
        XCTAssertFalse(signature.hasPrefix("Valid"), signature)
        XCTAssertTrue(signature.hasPrefix("Broken"), signature)
        XCTAssertEqual(card.verdict.level, .danger)
        XCTAssertEqual(answer(card, "Is the signature intact")?.mark, .danger)
    }

    /// The same for an ad hoc app: before, "Ad-hoc" from the quick check and a calm "The signature checks out".
    func testAChangedResourceOnAnAdhocAppIsBroken() throws {
        let fx = try S16TrustFixtures()
        let app = try fx.adhocApp("AdhocChanged")
        try Data("changed after signing".utf8).write(to: app.appendingPathComponent("Contents/Resources/readme.txt"))
        let (doc, card) = try card(app, .appBundle)
        XCTAssertTrue(doc.fact("signature")?.value.hasPrefix("Broken") == true, doc.fact("signature")?.value ?? "-")
        XCTAssertEqual(card.verdict.level, .danger)
    }

    /// An intact ad hoc app is not calm either: no developer identity stands behind it (F9's fix).
    func testAnIntactAdhocAppIsACaution() throws {
        let fx = try S16TrustFixtures()
        let (doc, card) = try card(try fx.adhocApp("Plain"), .appBundle)
        XCTAssertEqual(doc.fact("signature")?.value, "Ad-hoc (no developer identity)")
        XCTAssertEqual(card.verdict.level, .caution)
        XCTAssertNotEqual(card.verdict.chip, "Checks passed")
    }

    // MARK: Disk images (F3, F8, F12, F13)

    /// A disk image whose trailer points at a borrowed signature naming a vendor, with a ticket slot: before,
    /// "Is it signed: Yes", the vendor as "Who made it", "a notarization ticket is stapled", "Signed disk image".
    func testABorrowedDiskImageSignatureNamesNobody() throws {
        let fx = try S16TrustFixtures()
        let (doc, card) = try card(try fx.diskImageWithBorrowedSignature(as: Self.fakeDeveloperID), .diskImage)
        XCTAssertNotEqual(doc.fact("signed")?.value, "Signed")
        XCTAssertEqual(doc.fact("claimedSigner")?.value, Self.fakeDeveloperID)
        XCTAssertEqual(doc.fact("notarization")?.value, "Ticket present, not verified")
        assertNameIsNotClaimed(Self.fakeDeveloperID, doc, card)
        XCTAssertNotEqual(card.verdict.level, .calm)
        XCTAssertNotEqual(card.verdict.title, "Signed disk image")
        XCTAssertNotEqual(answer(card, "Is it signed")?.answer, "Yes")
        XCTAssertNotEqual(answer(card, "Who made it")?.mark, .ok)
        XCTAssertEqual(answer(card, "Has Apple checked it")?.mark, .caution)
    }

    // MARK: Installer packages (F58)

    /// A table of contents carrying a vendor's certificate and junk signature bytes: before, "is signed by Developer
    /// ID Installer: …", the vendor with an OK mark and a calm "Signed by …" verdict.
    func testAForgedInstallerSignatureNamesNobody() throws {
        let fx = try S16TrustFixtures()
        let (doc, card) = try card(try fx.installer("forged", as: Self.fakeInstallerID, signature: .forged), .installerPackage)
        XCTAssertTrue(doc.fact("signed")?.value.hasPrefix("Broken") == true, doc.fact("signed")?.value ?? "-")
        XCTAssertEqual(doc.fact("claimedSigner")?.value, Self.fakeInstallerID)
        assertNameIsNotClaimed(Self.fakeInstallerID, doc, card)
        XCTAssertEqual(card.verdict.level, .danger)
        XCTAssertEqual(answer(card, "Where does it come from")?.mark, .danger)
    }

    /// A real signature by a self-signed key: intact, but nobody Apple vouches for; never calm.
    func testASelfSignedInstallerIsNotVouchedFor() throws {
        let fx = try S16TrustFixtures()
        let (doc, card) = try card(try fx.installer("self", as: Self.fakeInstallerID, signature: .selfSigned), .installerPackage)
        XCTAssertEqual(doc.fact("signed")?.value, "Signed by a certificate Apple does not vouch for")
        assertNameIsNotClaimed(Self.fakeInstallerID, doc, card)
        XCTAssertEqual(card.verdict.level, .caution)
        XCTAssertEqual(answer(card, "Where does it come from")?.answer, "Someone Apple does not vouch for")
    }
}

// MARK: - Crafted signing fixtures (S-16, G-34)

/// Crafted signing inputs for the S-16 trust tests, built in a fresh temporary folder from invented names with system
/// tools — clang (the code is never run), `codesign -s -` (ad hoc, no keychain), `openssl` (a throwaway self-signed
/// key), `hdiutil create` (never attached) — and byte edits for what no tool makes: a code signature by a self-signed
/// certificate, a ticket-shaped file, a disk image trailer pointing at a borrowed signature, and xar signatures that
/// are forged, self-signed or bound to the wrong checksum. Nothing touches a keychain, the network or a user folder.
final class S16TrustFixtures: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-s16-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }

    /// Runs a system tool inside the folder and throws with its output when it fails.
    @discardableResult
    func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = url
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": FileManager.default.temporaryDirectory.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "S16TrustFixtures", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments.joined(separator: " ")): \(output)"])
        }
        return output
    }

    struct Identity { let certificate: String; let key: String; let der: Data }

    /// A throwaway self-signed code-signing certificate that names itself `commonName`.
    func identity(_ commonName: String, name: String = "id") throws -> Identity {
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "\(name).key", "-out", "\(name).pem",
                                     "-days", "30", "-subj", "/CN=\(commonName)/OU=ABCDE12345/O=Invented Vendor",
                                     "-addext", "extendedKeyUsage=codeSigning", "-addext", "keyUsage=critical,digitalSignature",
                                     "-addext", "basicConstraints=critical,CA:false"])
        try run("/usr/bin/openssl", ["x509", "-in", "\(name).pem", "-outform", "DER", "-out", "\(name).der"])
        return Identity(certificate: "\(name).pem", key: "\(name).key", der: try Data(contentsOf: path("\(name).der")))
    }

    /// Entitlements padded with an invented 6 KB string, so `codesign -s -` leaves room in the signature area for the
    /// CMS blob `resign` puts in their place.
    private func paddedEntitlements() throws -> String {
        let padding = String(repeating: "x", count: 6000)
        try write("padded.plist", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>com.example.padding</key><string>\(padding)</string></dict></plist>
        """.utf8))
        return "padded.plist"
    }

    private func compile(_ relative: String) throws {
        let source = "src-\(UUID().uuidString).c"
        try write(source, Data("int main(void){return 0;}\n".utf8))
        try FileManager.default.createDirectory(at: path(relative).deletingLastPathComponent(), withIntermediateDirectories: true)
        try run("/usr/bin/clang", ["-arch", "arm64", "-mmacosx-version-min=13.0", "-o", relative, source])
    }

    /// A tiny arm64 executable, signed ad hoc (with room for a CMS signature).
    func adhocBinary(_ relative: String, identifier: String = "com.example.s16.tool") throws -> URL {
        try compile(relative)
        try run("/usr/bin/codesign", ["-s", "-", "-f", "--entitlements", try paddedEntitlements(), "-i", identifier, relative])
        return path(relative)
    }

    /// An app bundle around a tiny executable, with one resource, signed ad hoc.
    func adhocApp(_ name: String) throws -> URL {
        let app = "\(name).app"
        try write("\(app)/Contents/Info.plist", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleName</key><string>\(name)</string><key>CFBundleIdentifier</key><string>com.example.s16.\(name.lowercased())</string>
        <key>CFBundleExecutable</key><string>\(name)</string><key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string>
        <key>LSMinimumSystemVersion</key><string>13.0</string>
        </dict></plist>
        """.utf8))
        try write("\(app)/Contents/Resources/readme.txt", Data(String(repeating: "invented resource ", count: 50).utf8))
        try compile("\(app)/Contents/MacOS/\(name)")
        try run("/usr/bin/codesign", ["-s", "-", "-f", "--entitlements", try paddedEntitlements(), app])
        return path(app)
    }

    /// The same app, its executable re-signed by a self-signed certificate that calls itself `commonName`.
    func selfSignedApp(_ name: String, as commonName: String) throws -> URL {
        let app = try adhocApp(name)
        try resign(app.appendingPathComponent("Contents/MacOS/\(name)"), as: commonName)
        return app
    }

    /// A tiny executable signed by a self-signed certificate that calls itself `commonName`.
    func selfSignedBinary(_ relative: String, as commonName: String) throws -> URL {
        let binary = try adhocBinary(relative)
        try resign(binary, as: commonName)
        return binary
    }

    /// Ticket-shaped bytes where `stapler` puts an app's ticket (`Contents/CodeResources`, outside the seal): the
    /// `s8ch` magic, a version and invented bytes. Apple never signed them.
    func addFakeTicket(to app: URL) throws {
        try Data(Array("s8ch".utf8) + [1, 0, 0, 0] + [UInt8](repeating: 0x30, count: 64))
            .write(to: app.appendingPathComponent("Contents/CodeResources"))
    }

    // MARK: Signature bytes

    private static func be32(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) }
    private static func le32(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
    private static func put32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    /// A SuperBlob of `(slot, blob)` pairs.
    private static func superBlob(_ blobs: [(Int, [UInt8])]) -> [UInt8] {
        var index: [UInt8] = [], body: [UInt8] = []
        var at = 12 + 8 * blobs.count
        for (slot, blob) in blobs { index += put32(slot) + put32(at); body += blob; at += blob.count }
        return put32(0xFADE_0CC0) + put32(at) + put32(blobs.count) + index + body
    }

    /// The ad hoc signature's blobs in a thin Mach-O, and where its signature area is.
    private func signature(of binary: URL) throws -> (bytes: [UInt8], area: Range<Int>, blobs: [Int: [UInt8]]) {
        let data = [UInt8](try Data(contentsOf: binary))
        var offset = 32, area = 0..<0
        for _ in 0..<Self.le32(data, 16) {
            if Self.le32(data, offset) == 0x1D {
                let start = Self.le32(data, offset + 8)
                area = start..<(start + Self.le32(data, offset + 12))
            }
            offset += Self.le32(data, offset + 4)
        }
        var blobs: [Int: [UInt8]] = [:]
        for i in 0..<Self.be32(data, area.lowerBound + 8) {
            let slot = Self.be32(data, area.lowerBound + 12 + i * 8), at = area.lowerBound + Self.be32(data, area.lowerBound + 16 + i * 8)
            blobs[slot] = Array(data[at..<(at + Self.be32(data, at + 4))])
        }
        return (data, area, blobs)
    }

    /// The code directory with the ad hoc flag cleared and the entitlements' slot hashes zeroed, CMS-signed (detached)
    /// by a self-signed certificate that calls itself `commonName`.
    private func signedCodeDirectory(_ directory: [UInt8], as commonName: String) throws -> (cd: [UInt8], cms: [UInt8]) {
        var cd = directory
        let flags = Self.be32(cd, 12) & ~0x2
        cd.replaceSubrange(12..<16, with: Self.put32(flags))
        let hashOffset = Self.be32(cd, 16), special = Self.be32(cd, 24), hashSize = Int(cd[36])
        for slot in [5, 7] where slot <= special {
            let at = hashOffset - slot * hashSize
            cd.replaceSubrange(at..<(at + hashSize), with: [UInt8](repeating: 0, count: hashSize))
        }
        let name = "cms-\(UUID().uuidString)"
        let id = try identity(commonName, name: name)
        try write("\(name).cd", Data(cd))
        try run("/usr/bin/openssl", ["cms", "-sign", "-binary", "-in", "\(name).cd", "-signer", id.certificate, "-inkey", id.key,
                                     "-outform", "DER", "-md", "sha256", "-out", "\(name).cms"])
        return (cd, [UInt8](try Data(contentsOf: path("\(name).cms"))))
    }

    /// Replaces an ad hoc signature with one by a self-signed certificate (no keychain): the same code directory, its
    /// ad hoc flag cleared, signed with CMS over it as codesign would; the entitlement blobs give up their room.
    func resign(_ binary: URL, as commonName: String) throws {
        var (data, area, blobs) = try signature(of: binary)
        let (cd, cms) = try signedCodeDirectory(try XCTUnwrap(blobs[0]), as: commonName)
        let blob = Self.superBlob([(0, cd), (2, try XCTUnwrap(blobs[2])), (0x10000, Self.put32(0xFADE_0B01) + Self.put32(8 + cms.count) + cms)])
        precondition(blob.count <= area.count, "the signature area is too small for the CMS blob")
        data.replaceSubrange(area, with: blob + [UInt8](repeating: 0, count: area.count - blob.count))
        try Data(data).write(to: binary)
    }

    // MARK: Disk images

    /// A UDIF image whose trailer points at a signature borrowed from elsewhere: another file's code directory, a CMS
    /// message naming `commonName` (internally consistent, over that other code directory), and a ticket slot holding
    /// invented ticket-shaped bytes. Nothing in it describes this image.
    func diskImageWithBorrowedSignature(as commonName: String) throws -> URL {
        try write("dmg-src/hello.txt", Data(String(repeating: "invented disk image\n", count: 50).utf8))
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", "dmg-src", "-volname", "Invented", "-format", "UDZO", "-o", "plain.dmg"])
        let donor = try adhocBinary("donor-\(UUID().uuidString)")
        let (cd, cms) = try signedCodeDirectory(try XCTUnwrap(try signature(of: donor).blobs[0]), as: commonName)
        let ticket = Array("s8ch".utf8) + Self.put32(16) + [UInt8](repeating: 0x42, count: 8)
        let blob = Self.superBlob([(0, cd), (0x10000, Self.put32(0xFADE_0B01) + Self.put32(8 + cms.count) + cms), (0x10002, ticket)])
        var image = [UInt8](try Data(contentsOf: path("plain.dmg")))
        let trailerStart = image.count - 512
        var trailer = Array(image[trailerStart...])
        func put64(_ at: Int, _ v: Int) { for i in 0..<8 { trailer[at + i] = UInt8(truncatingIfNeeded: v >> (8 * (7 - i))) } }
        put64(296, trailerStart)               // codeSignatureOffset: where the borrowed blob now starts
        put64(304, blob.count)                 // codeSignatureLength
        image = Array(image[..<trailerStart]) + blob + trailer
        return try write("borrowed.dmg", Data(image))
    }

    // MARK: Installer packages

    enum XarSignature {
        /// Junk bytes where the RSA signature belongs: nobody signed anything.
        case forged
        /// A real PKCS #1 v1.5 signature over the checksum, by the self-signed key of the certificate it lists.
        case selfSigned
        /// A real signature, but over a checksum that is not the table of contents'.
        case wrongChecksum
    }

    /// A component package (one PackageInfo) whose table of contents carries a certificate naming `commonName`.
    func installer(_ name: String, as commonName: String, signature kind: XarSignature) throws -> URL {
        let id = try identity(commonName, name: "pkg-\(UUID().uuidString)")
        let info = Array(#"<pkg-info identifier="com.example.s16.package" version="1.0" install-location="/Applications"/>"#.utf8)
        let toc = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xar><toc><checksum style="sha1"><offset>0</offset><size>20</size></checksum>
        <signature style="RSA"><offset>20</offset><size>256</size>
        <KeyInfo xmlns="http://www.w3.org/2000/09/xmldsig#"><X509Data><X509Certificate>\(id.der.base64EncodedString())</X509Certificate></X509Data></KeyInfo>
        </signature>
        <file id="1"><name>PackageInfo</name><type>file</type><data><offset>276</offset><length>\(info.count)</length><size>\(info.count)</size><encoding style="application/octet-stream"/></data></file>
        </toc></xar>
        """
        let tocBytes = Array(toc.utf8)
        let deflated = [UInt8](try (Data(tocBytes) as NSData).compressed(using: .zlib) as Data)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in tocBytes { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let compressed = [0x78, 0x9C] + deflated + Self.put32(Int(b << 16 | a))
        let checksum = Array(Insecure.SHA1.hash(data: compressed))
        let stored = kind == .wrongChecksum ? [UInt8](repeating: 0x11, count: 20) : checksum
        let signature: [UInt8]
        switch kind {
        case .forged:
            signature = [UInt8](repeating: 0x5A, count: 256)
        case .selfSigned, .wrongChecksum:
            // DigestInfo(SHA-1) then the digest: what PKCS #1 v1.5 signs.
            let digestInfo: [UInt8] = [0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2B, 0x0E, 0x03, 0x02, 0x1A, 0x05, 0x00, 0x04, 0x14] + stored
            let input = "di-\(UUID().uuidString).bin"
            try write(input, Data(digestInfo))
            try run("/usr/bin/openssl", ["pkeyutl", "-sign", "-inkey", id.key, "-in", input, "-out", "\(input).sig"])
            signature = [UInt8](try Data(contentsOf: path("\(input).sig")))
        }
        var header = Array("xar!".utf8) + [0, 28, 0, 1]
        header += [0, 0, 0, 0] + Self.put32(compressed.count) + [0, 0, 0, 0] + Self.put32(tocBytes.count) + Self.put32(1)
        return try write("\(name).pkg", Data(header + compressed + stored + signature + info))
    }
}
