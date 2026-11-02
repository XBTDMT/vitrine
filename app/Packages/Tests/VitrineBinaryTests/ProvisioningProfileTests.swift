import Foundation
import XCTest
@testable import VitrineBinary

/// A throwaway signing identity made with `/usr/bin/openssl` in the fixture folder (never added to a keychain).
struct TestIdentity {
    let certificatePEM: String
    let keyPEM: String
    let der: [UInt8]

    static func make(in folder: FixtureFolder, name: String = "id",
                     subject: String = "/CN=Fixture Developer: Test Person (ABCDE12345)/OU=ABCDE12345/O=Fixture Org/C=US") throws -> TestIdentity {
        try folder.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "\(name).key",
                                            "-out", "\(name).pem", "-days", "30", "-subj", subject])
        try folder.run("/usr/bin/openssl", ["x509", "-in", "\(name).pem", "-outform", "DER", "-out", "\(name).der"])
        return TestIdentity(certificatePEM: "\(name).pem", keyPEM: "\(name).key", der: try folder.bytes("\(name).der"))
    }

    /// Signs `input` into a DER CMS signedData message with the content attached.
    func sign(_ input: String, to output: String, in folder: FixtureFolder) throws {
        try folder.run("/usr/bin/openssl", ["smime", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", input,
                                            "-signer", certificatePEM, "-inkey", keyPEM, "-out", output])
    }
}

final class ProvisioningProfileTests: XCTestCase {
    static func profile(expires: String, devices: [String], getTaskAllow: Bool, allDevices: Bool = false,
                        certificate: [UInt8]) -> String {
        let deviceXML = devices.isEmpty ? "" :
            "<key>ProvisionedDevices</key><array>" + devices.map { "<string>\($0)</string>" }.joined() + "</array>"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>AppIDName</key><string>Fixture App</string>
        <key>ApplicationIdentifierPrefix</key><array><string>ABCDE12345</string></array>
        <key>CreationDate</key><date>2026-01-01T00:00:00Z</date>
        <key>Platform</key><array><string>iOS</string><string>xrOS</string></array>
        <key>IsXcodeManaged</key><true/>
        <key>DeveloperCertificates</key><array><data>\(Data(certificate).base64EncodedString())</data></array>
        <key>Entitlements</key><dict>
          <key>application-identifier</key><string>ABCDE12345.com.example.fixture</string>
          <key>get-task-allow</key>\(getTaskAllow ? "<true/>" : "<false/>")
          <key>keychain-access-groups</key><array><string>ABCDE12345.*</string></array>
        </dict>
        <key>ExpirationDate</key><date>\(expires)</date>
        <key>Name</key><string>Fixture Development Profile</string>
        \(deviceXML)
        \(allDevices ? "<key>ProvisionsAllDevices</key><true/>" : "")
        <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
        <key>TeamName</key><string>Fixture Org</string>
        <key>TimeToLive</key><integer>365</integer>
        <key>UUID</key><string>3F2504E0-4F89-11D3-9A0C-0305E82C3301</string>
        <key>Version</key><integer>1</integer>
        </dict></plist>
        """
    }

    func testSignedDevelopmentProfile() throws {
        let folder = try FixtureFolder()
        let identity = try TestIdentity.make(in: folder)
        try folder.write("profile.plist", Self.profile(expires: "2099-01-01T00:00:00Z", devices: ["00008110-AAAA", "00008110-BBBB"],
                                                       getTaskAllow: true, certificate: identity.der))
        try identity.sign("profile.plist", to: "Fixture.mobileprovision", in: folder)
        let profile = try ProvisioningProfileReader.read(contentsOf: folder.path("Fixture.mobileprovision"))
        XCTAssertEqual(profile.name, "Fixture Development Profile")
        XCTAssertEqual(profile.uuid, "3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertEqual(profile.appIDName, "Fixture App")
        XCTAssertEqual(profile.applicationIdentifier, "ABCDE12345.com.example.fixture")
        XCTAssertEqual(profile.teamIdentifiers, ["ABCDE12345"])
        XCTAssertEqual(profile.teamName, "Fixture Org")
        XCTAssertEqual(profile.platforms, ["iOS", "xrOS"])
        XCTAssertEqual(profile.deviceCount, 2)
        XCTAssertFalse(profile.provisionsAllDevices)
        XCTAssertTrue(profile.isXcodeManaged)
        XCTAssertEqual(profile.timeToLiveDays, 365)
        XCTAssertEqual(profile.distribution, .development)
        XCTAssertEqual(profile.creationDate, ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        XCTAssertEqual(profile.isExpired(at: ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z") ?? Date()), false)
        XCTAssertEqual(profile.isExpired(at: ISO8601DateFormatter().date(from: "2100-01-01T00:00:00Z") ?? Date()), true)
        XCTAssertEqual(profile.entitlements["get-task-allow"], .bool(true))
        XCTAssertEqual(profile.signatureMatchesContent, true)

        let developer = try XCTUnwrap(profile.developerCertificates.first)
        XCTAssertEqual(developer.commonName, "Fixture Developer: Test Person (ABCDE12345)")
        XCTAssertEqual(developer.organizationalUnit, "ABCDE12345")
        XCTAssertEqual(developer.organization, "Fixture Org")
        XCTAssertEqual(developer.issuerCommonName, developer.commonName)      // self-signed
        XCTAssertEqual(developer.isExpired(), false)
        XCTAssertEqual(developer.sha256Fingerprint.count, 64)
        XCTAssertEqual(profile.signerCertificates.first?.sha256Fingerprint, developer.sha256Fingerprint)

        // The facade recognizes it by extension.
        guard case .provisioningProfile(let again) = try VitrineBinary.inspect(folder.path("Fixture.mobileprovision")) else {
            return XCTFail("inspect must read a profile")
        }
        XCTAssertEqual(again, profile)
    }

    func testDistributionKindsAndExpiry() throws {
        let folder = try FixtureFolder()
        let identity = try TestIdentity.make(in: folder)
        let cases: [(String, [String], Bool, Bool, ProvisioningProfile.Distribution)] = [
            ("adhoc", ["1"], false, false, .adHoc),
            ("store", [], false, false, .appStore),
            ("enterprise", [], false, true, .enterprise),
        ]
        for (name, devices, debug, all, expected) in cases {
            try folder.write("\(name).plist", Self.profile(expires: "2020-01-01T00:00:00Z", devices: devices,
                                                          getTaskAllow: debug, allDevices: all, certificate: identity.der))
            try identity.sign("\(name).plist", to: "\(name).provisionprofile", in: folder)
            let profile = try ProvisioningProfileReader.read(contentsOf: folder.path("\(name).provisionprofile"))
            XCTAssertEqual(profile.distribution, expected, name)
            XCTAssertEqual(profile.isExpired(), true, name)
        }
    }

    func testDamagedProfiles() throws {
        let folder = try FixtureFolder()
        let identity = try TestIdentity.make(in: folder)
        try folder.write("p.plist", Self.profile(expires: "2099-01-01T00:00:00Z", devices: [], getTaskAllow: false,
                                                 certificate: identity.der))
        try identity.sign("p.plist", to: "p.mobileprovision", in: folder)
        let good = try folder.bytes("p.mobileprovision")

        // Not CMS at all; a bare plist; empty.
        assertBinaryError(try ProvisioningProfileReader.read(bytes: Array("<plist/>".utf8)), matching: {
            if case .notRecognized = $0 { true } else { false }
        })
        assertBinaryError(try ProvisioningProfileReader.read(bytes: []))
        // Signed content that is not a property list.
        try folder.write("junk.txt", "just words")
        try identity.sign("junk.txt", to: "junk.mobileprovision", in: folder)
        assertBinaryError(try ProvisioningProfileReader.read(contentsOf: folder.path("junk.mobileprovision")))

        // A changed byte in the signed content: either the message no longer decodes, or the signature says so.
        let marker = Array("Fixture Org".utf8)
        let at = try XCTUnwrap(good.firstRange(of: marker)?.lowerBound)
        var tampered = good
        tampered[at] = UInt8(ascii: "G")
        if let profile = try? ProvisioningProfileReader.read(bytes: tampered) {
            XCTAssertEqual(profile.signatureMatchesContent, false)
        }

        // Random damage and truncation never trap.
        fuzz(good, rounds: 300, seed: 7) { damaged in _ = try? ProvisioningProfileReader.read(bytes: damaged) }
    }
}
