import Foundation
import XCTest
@testable import VitrineBinary

/// S-16 follow-up: a standalone provisioning profile names its team only when the profile's own signature checks
/// out against Apple. Every profile here is invented and signed by a throwaway identity. roadmap: S-16
final class S16ProfileSignatureTests: XCTestCase {
    func profile(_ fx: S16TrustFixtures) throws -> [UInt8] {
        let id = try fx.identity("Apple Distribution: Famous Vendor (ABCDE12345)", name: "dev")
        try fx.write("p.plist", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Name</key><string>Borrowed</string><key>TeamName</key><string>Famous Vendor</string>
        <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
        </dict></plist>
        """.utf8))
        try fx.run("/usr/bin/openssl", ["smime", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", "p.plist",
                                        "-signer", id.certificate, "-inkey", id.key, "-out", "p.mobileprovision"])
        return [UInt8](try Data(contentsOf: fx.path("p.mobileprovision")))
    }

    func testAProfileSignedBySomeoneAppleDoesNotVouchForIsNotVerified() throws {
        let fx = try S16TrustFixtures()
        let bytes = try profile(fx)
        XCTAssertEqual(try ProvisioningProfileReader.read(bytes: bytes).teamName, "Famous Vendor", "the reader still reads the claim")
        let verdict = ProvisioningProfileReader.signatureVerification(bytes: bytes)
        XCTAssertFalse(verdict.isVerified, "\(verdict)")
    }

    func testAProfileWhoseContentChangedAfterSigningIsBroken() throws {
        let fx = try S16TrustFixtures()
        var bytes = try profile(fx)
        let marker = Array("Borrowed".utf8)
        let at = try XCTUnwrap((0...(bytes.count - marker.count)).first { Array(bytes[$0..<$0 + marker.count]) == marker })
        bytes[at] = UInt8(ascii: "C")
        let verdict = ProvisioningProfileReader.signatureVerification(bytes: bytes)
        XCTAssertFalse(verdict.isVerified)
        if case .notVouched = verdict { XCTFail("a changed profile must not read as intact: \(verdict)") }
    }

    func testBytesThatAreNotASignedMessageAreNotVerified() {
        XCTAssertFalse(ProvisioningProfileReader.signatureVerification(bytes: [0x30, 0x03, 0x02, 0x01, 0x00]).isVerified)
        XCTAssertFalse(ProvisioningProfileReader.signatureVerification(bytes: []).isVerified)
    }
}
