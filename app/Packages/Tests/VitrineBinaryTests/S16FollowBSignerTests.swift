import Foundation
import Security
import XCTest
@testable import VitrineBinary

/// S-16 follow-up B (G-34, the class of F3/F8/F58): an iOS app's signer is named only when its signature verified in
/// process: the CMS signature over the code directory, the directory's hashes over the code, Info.plist and the
/// resource list, and the chain to an Apple root. Each app is crafted in a temporary folder with system tools
/// (clang, `codesign -s -`, `openssl`, `zip`) from invented names; the CMS signature is made by a throwaway self-signed
/// key (S16TrustFixtures.resign), and hostile cases are byte edits. Nothing touches a keychain or the network.
/// roadmap: S-16
final class S16FollowBSignerTests: XCTestCase {
    static let famousName = "Apple Distribution: Famous Vendor (ABCDE12345)"

    // MARK: Fixtures

    /// `Payload/Field.app` (iOS layout: Info.plist beside the executable), signed ad hoc with room for a CMS blob,
    /// then (unless `adHoc`) its executable re-signed by a self-signed certificate calling itself `commonName`.
    func app(_ fx: S16TrustFixtures, as commonName: String = famousName, adHoc: Bool = false, source: String = "int main(void){return 0;}\n") throws -> URL {
        try fx.write("Payload/Field.app/Info.plist", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleName</key><string>Field</string><key>CFBundleIdentifier</key><string>com.example.s16.field</string>
        <key>CFBundleExecutable</key><string>Field</string><key>CFBundleShortVersionString</key><string>1.0</string>
        <key>CFBundleVersion</key><string>1</string><key>MinimumOSVersion</key><string>17.0</string>
        </dict></plist>
        """.utf8))
        try fx.write("Payload/Field.app/notes.txt", Data(String(repeating: "invented resource ", count: 40).utf8))
        try fx.write("main.c", Data(source.utf8))
        try fx.run("/usr/bin/clang", ["-arch", "arm64", "-mmacosx-version-min=13.0", "-o", "Payload/Field.app/Field", "main.c"])
        try fx.write("padded.plist", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>com.example.padding</key><string>\(String(repeating: "x", count: 6000))</string></dict></plist>
        """.utf8))
        try fx.run("/usr/bin/codesign", ["-s", "-", "-f", "--entitlements", "padded.plist", "Payload/Field.app"])
        if !adHoc { try fx.resign(fx.path("Payload/Field.app/Field"), as: commonName) }
        return fx.path("Payload/Field.app/Field")
    }

    func ipa(_ fx: S16TrustFixtures, name: String = "Field.ipa") throws -> IOSAppArchive {
        try fx.run("/usr/bin/zip", ["-q", "-r", "-y", name, "Payload"])
        return try IOSAppArchiveReader.read(contentsOf: fx.path(name))
    }

    static func be32(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) }
    static func le32(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
    static func put32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    /// The signature area of a thin 64-bit Mach-O, and its blobs by slot.
    static func signature(_ data: [UInt8]) -> (area: Range<Int>, blobs: [Int: [UInt8]]) {
        var offset = 32, area = 0..<0
        for _ in 0..<le32(data, 16) {
            if le32(data, offset) == 0x1D { let start = le32(data, offset + 8); area = start..<(start + le32(data, offset + 12)) }
            offset += le32(data, offset + 4)
        }
        var blobs: [Int: [UInt8]] = [:]
        for i in 0..<be32(data, area.lowerBound + 8) {
            let slot = be32(data, area.lowerBound + 12 + i * 8), at = area.lowerBound + be32(data, area.lowerBound + 16 + i * 8)
            blobs[slot] = Array(data[at..<(at + be32(data, at + 4))])
        }
        return (area, blobs)
    }

    static func superBlob(_ blobs: [(Int, [UInt8])]) -> [UInt8] {
        var index: [UInt8] = [], body: [UInt8] = []
        var at = 12 + 8 * blobs.count
        for (slot, blob) in blobs { index += put32(slot) + put32(at); body += blob; at += blob.count }
        return put32(0xFADE_0CC0) + put32(at) + put32(blobs.count) + index + body
    }

    // MARK: The app's signature (IOSAppArchive)

    /// A self-signed certificate naming a famous vendor: the signature checks out, nobody Apple vouches for it, and
    /// its name stays the certificate's claim.
    func testASelfSignedFamousNameIsNotVouchedFor() throws {
        let fx = try S16TrustFixtures()
        _ = try app(fx)
        let ipa = try ipa(fx)
        XCTAssertEqual(ipa.isExecutableSigned, true)
        let signature = try XCTUnwrap(ipa.signature)
        XCTAssertEqual(signature.verification, .notVouched, "the CMS signature and every hash match; the chain is not Apple's")
        XCTAssertFalse(signature.verification.isVerified)
        XCTAssertEqual(signature.certificates.first?.commonName, Self.famousName)
        XCTAssertEqual(signature.unchecked, [.resources])
        XCTAssertFalse(ipa.profileVouchesForSigner)
    }

    /// The signature taken from one app and put on different code: the CMS signature still matches its own code
    /// directory, which no longer matches the code.
    func testABorrowedSignatureOnOtherCodeIsBroken() throws {
        let donorFolder = try S16TrustFixtures()
        let donor = [UInt8](try Data(contentsOf: try app(donorFolder)))
        let fx = try S16TrustFixtures()
        let target = try app(fx, as: "Invented Nobody", source: "int main(void){return 1;}\n")
        var bytes = [UInt8](try Data(contentsOf: target))
        let (area, _) = Self.signature(bytes)
        let (donorArea, _) = Self.signature(donor)
        XCTAssertEqual(area, donorArea, "same layout, different code")
        bytes.replaceSubrange(area, with: donor[donorArea])
        XCTAssertNotEqual(Array(bytes[..<area.lowerBound]), Array(donor[..<donorArea.lowerBound]), "the code differs")
        try Data(bytes).write(to: target)
        let signature = try XCTUnwrap(try ipa(fx).signature)
        XCTAssertEqual(signature.verification, .broken("its code does not match its signature"))
        XCTAssertEqual(signature.certificates.first?.commonName, Self.famousName, "the borrowed name is still only a claim")
    }

    /// One byte of code changed after signing.
    func testChangedCodeIsBroken() throws {
        let fx = try S16TrustFixtures()
        let executable = try app(fx)
        var bytes = [UInt8](try Data(contentsOf: executable))
        bytes[0x100] ^= 0xFF                        // inside the load commands' page, before the signature
        try Data(bytes).write(to: executable)
        XCTAssertEqual(try ipa(fx).signature?.verification, .broken("its code does not match its signature"))
    }

    /// A CMS signature made over another code directory than the one the app carries.
    func testACMSSignatureOverAnotherCodeDirectoryIsBroken() throws {
        let fx = try S16TrustFixtures()
        let executable = try app(fx)
        var bytes = [UInt8](try Data(contentsOf: executable))
        let (area, blobs) = Self.signature(bytes)
        var other = try XCTUnwrap(blobs[0])
        other[other.count - 1] ^= 0xFF              // another directory: its last hash differs
        let id = try fx.identity(Self.famousName, name: "other")
        try fx.write("other.cd", Data(other))
        try fx.run("/usr/bin/openssl", ["cms", "-sign", "-binary", "-in", "other.cd", "-signer", id.certificate, "-inkey", id.key,
                                        "-outform", "DER", "-md", "sha256", "-out", "other.cms"])
        let cms = [UInt8](try Data(contentsOf: fx.path("other.cms")))
        let blob = Self.superBlob([(0, try XCTUnwrap(blobs[0])), (2, try XCTUnwrap(blobs[2])),
                                   (0x10000, Self.put32(0xFADE_0B01) + Self.put32(8 + cms.count) + cms)])
        XCTAssertLessThanOrEqual(blob.count, area.count)
        bytes.replaceSubrange(area, with: blob + [UInt8](repeating: 0, count: area.count - blob.count))
        try Data(bytes).write(to: executable)
        XCTAssertEqual(try ipa(fx).signature?.verification, .broken("its signature was not made over this code with its certificate's key"))
    }

    /// Info.plist edited after signing (a new name): the sealed hash no longer matches.
    func testAnInfoPlistChangedAfterSigningIsBroken() throws {
        let fx = try S16TrustFixtures()
        _ = try app(fx)
        let plist = fx.path("Payload/Field.app/Info.plist")
        let text = try String(contentsOf: plist, encoding: .utf8).replacingOccurrences(of: "<string>Field</string><key>CFBundleIdentifier", with: "<string>Famous</string><key>CFBundleIdentifier")
        try Data(text.utf8).write(to: plist)
        let ipa = try ipa(fx)
        XCTAssertEqual(ipa.name, "Famous")
        XCTAssertEqual(ipa.signature?.verification, .broken("its Info.plist does not match its signature"))
    }

    func testAnAdHocAppIsNotVerified() throws {
        let fx = try S16TrustFixtures()
        _ = try app(fx, adHoc: true)
        let ipa = try ipa(fx)
        XCTAssertEqual(ipa.isExecutableSigned, true)
        XCTAssertEqual(ipa.signature?.verification, .notVerified("it is signed ad hoc, with no developer identity"))
    }

    func testAnUnsignedAppHasNoSignature() throws {
        let fx = try S16TrustFixtures()
        _ = try app(fx, adHoc: true)
        try fx.run("/usr/bin/codesign", ["--remove-signature", "Payload/Field.app/Field"])
        let ipa = try ipa(fx)
        XCTAssertEqual(ipa.isExecutableSigned, false)
        XCTAssertNil(ipa.signature)
    }

    /// Pages the App Store encrypted are hashed decrypted, so they are skipped and said to be; a change outside them
    /// still breaks the signature.
    func testEncryptedPagesAreSkippedAndSaidToBe() throws {
        let fx = try S16TrustFixtures()
        let executable = try app(fx)
        var bytes = [UInt8](try Data(contentsOf: executable))
        let (area, blobs) = Self.signature(bytes)
        bytes[0x4010] ^= 0xFF                        // inside the second 16 KB page
        let directory = try XCTUnwrap(blobs[0])
        let info = [UInt8](try Data(contentsOf: fx.path("Payload/Field.app/Info.plist")))
        let resources = [UInt8](try Data(contentsOf: fx.path("Payload/Field.app/_CodeSignature/CodeResources")))
        func special(_ type: Int) -> [UInt8]? { type == 1 ? info : type == 3 ? resources : blobs[type] }
        func check(_ encryption: EncryptionInfo?) -> AppSignatureCheck.DirectoryResult {
            AppSignatureCheck.check(directory: directory, code: bytes[...], signatureOffset: area.lowerBound, encryption: encryption,
                                    special: special, specialTypes: Set((1...11).filter { special($0) != nil }))
        }
        XCTAssertEqual(AppSignatureCheck.check(directory: directory, code: [UInt8](try Data(contentsOf: executable))[...],
                                               signatureOffset: area.lowerBound, encryption: nil, special: special,
                                               specialTypes: Set((1...11).filter { special($0) != nil })),
                       .matches(skippedEncrypted: false), "the unchanged code matches")
        XCTAssertEqual(check(EncryptionInfo(offset: 0x4000, size: 0x4000, cryptID: 1)), .matches(skippedEncrypted: true))
        XCTAssertEqual(check(EncryptionInfo(offset: 0x4000, size: 0x4000, cryptID: 0)), .broken("its code does not match its signature"))
        XCTAssertEqual(check(nil), .broken("its code does not match its signature"))
    }

    // MARK: The profile (who the team is)

    /// A verified app signature (assumed here: no test can hold an Apple key) does not make a profile signed by
    /// someone else vouch for its team name, even when it lists that certificate and team.
    func testAProfileNobodyAppleSignedDoesNotVouch() throws {
        let fx = try S16TrustFixtures()
        let id = try fx.identity(Self.famousName, name: "dev")
        let leaf = try XCTUnwrap(CertificateSummary(der: [UInt8](id.der)))
        try fx.write("profile.plist", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Name</key><string>Borrowed</string><key>TeamName</key><string>Famous Vendor</string>
        <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
        <key>DeveloperCertificates</key><array><data>\(id.der.base64EncodedString())</data></array>
        </dict></plist>
        """.utf8))
        try fx.run("/usr/bin/openssl", ["smime", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", "profile.plist",
                                        "-signer", id.certificate, "-inkey", id.key, "-out", "embedded.mobileprovision"])
        let bytes = [UInt8](try Data(contentsOf: fx.path("embedded.mobileprovision")))
        let profile = try ProvisioningProfileReader.read(bytes: bytes)
        let assumed = AppSignature(verification: .verified(.appleIssued), certificates: [leaf], teamIdentifier: "ABCDE12345", unchecked: [])
        XCTAssertFalse(AppSignatureCheck.profileVouches(for: assumed, profileBytes: bytes, profile: profile),
                       "the profile's own signature does not chain to Apple")
        let unverified = AppSignature(verification: .notVouched, certificates: [leaf], teamIdentifier: "ABCDE12345", unchecked: [])
        XCTAssertFalse(AppSignatureCheck.profileVouches(for: unverified, profileBytes: bytes, profile: profile))
    }

    // MARK: A real Apple signature (positive control)

    /// Apple's Calculator, read-only (skipped where it is missing): the same check verifies a real Apple signature in
    /// every architecture, so the verified path is the one real signatures take.
    func testARealAppleSignatureVerifies() throws {
        let app = URL(fileURLWithPath: "/System/Applications/Calculator.app/Contents")
        let executable = app.appendingPathComponent("MacOS/Calculator")
        guard FileManager.default.fileExists(atPath: executable.path) else { throw XCTSkip("no Calculator here") }
        let bytes = [UInt8](try Data(contentsOf: executable))
        let macho = try MachOReader.read(source: BinaryDataSource(bytes))
        let info = [UInt8](try Data(contentsOf: app.appendingPathComponent("Info.plist")))
        let resources = [UInt8](try Data(contentsOf: app.appendingPathComponent("_CodeSignature/CodeResources")))
        let signature = try XCTUnwrap(AppSignatureCheck.verify(executable: bytes, macho: macho, infoPlist: info, codeResources: resources))
        XCTAssertEqual(signature.verification, .verified(.appleIssued))
        XCTAssertEqual(signature.unchecked, [.resources])
        // And one changed byte of its code breaks it.
        var changed = bytes
        let slice = try XCTUnwrap(macho.slices.first)
        changed[Int(slice.fileOffset) + 0x80] ^= 0xFF
        let broken = try XCTUnwrap(AppSignatureCheck.verify(executable: changed, macho: macho, infoPlist: info, codeResources: resources))
        XCTAssertEqual(broken.verification, .broken("its code does not match its signature"))
    }
}
