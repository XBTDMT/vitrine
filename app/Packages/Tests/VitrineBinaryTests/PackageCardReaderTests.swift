import CryptoKit
import Foundation
import XCTest
@testable import VitrineBinary
import VitrineArchive

/// The P-2/P-4 readers: torrents (own bencode), configuration profiles (plain and CMS-signed by a throwaway openssl
/// identity), iOS app archives (a zip made by /usr/bin/zip around a clang-built, ad-hoc signed executable) and
/// Android packages (a binary-XML manifest written byte by byte by `AXMLWriter` below, from the AAPT format). Every
/// name and value is invented. roadmap: S-8
final class PackageCardReaderTests: XCTestCase {
    // MARK: Torrents

    private func bencode(_ s: String) -> [UInt8] { Array("\(s.utf8.count):\(s)".utf8) }
    private func bencode(_ n: Int64) -> [UInt8] { Array("i\(n)e".utf8) }
    private func dict(_ pairs: [(String, [UInt8])]) -> [UInt8] {
        Array("d".utf8) + pairs.sorted { $0.0 < $1.0 }.flatMap { bencode($0.0) + $0.1 } + Array("e".utf8)
    }
    private func list(_ items: [[UInt8]]) -> [UInt8] { Array("l".utf8) + items.flatMap { $0 } + Array("e".utf8) }

    func testMultiFileTorrentAndItsInfoHash() throws {
        let info = dict([
            ("name", bencode("open-weather-sample")),
            ("piece length", bencode(262_144)),
            ("pieces", Array("20:".utf8) + [UInt8](repeating: 0xAB, count: 20)),
            ("private", bencode(1)),
            ("files", list([
                dict([("length", bencode(4_200)), ("path", list([bencode("data"), bencode("weather.parquet")]))]),
                dict([("length", bencode(6)), ("path", list([bencode("README.txt")]))]),
                dict([("length", bencode(10)), ("path", list([bencode(".pad"), bencode("10")])), ("attr", bencode("p"))]),
            ])),
        ])
        let bytes = dict([
            ("announce", bencode("https://tracker-one.example/announce")),
            ("announce-list", list([list([bencode("https://tracker-one.example/announce")]), list([bencode("udp://tracker-two.example:80")])])),
            ("created by", bencode("Invented Maker 1.0")),
            ("creation date", bencode(1_790_000_000)),
            ("comment", bencode("An invented dataset")),
            ("info", info),
        ])
        let t = try TorrentReader.read(bytes: bytes)
        XCTAssertEqual(t.name, "open-weather-sample")
        XCTAssertEqual(t.files.map(\.path), ["open-weather-sample/data/weather.parquet", "open-weather-sample/README.txt",
                                             "open-weather-sample/.pad/10"])
        XCTAssertEqual(t.files.map(\.isPadding), [false, false, true])
        XCTAssertEqual(t.totalSize, 4_206)
        XCTAssertEqual(t.pieceLength, 262_144)
        XCTAssertEqual(t.pieceCount, 1)
        XCTAssertEqual(t.trackers, ["https://tracker-one.example/announce", "udp://tracker-two.example:80"])
        XCTAssertTrue(t.isPrivate)
        XCTAssertEqual(t.createdBy, "Invented Maker 1.0")
        XCTAssertEqual(t.creationDate, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(t.version, .v1)
        // The info-hash is SHA-1 over exactly the bencoded info dictionary.
        XCTAssertEqual(t.infoHashV1, Insecure.SHA1.hash(data: info).map { String(format: "%02x", $0) }.joined())
        XCTAssertNil(t.infoHashV2)
        XCTAssertEqual(t.magnetLink, "magnet:?xt=urn:btih:\(t.infoHashV1!)")
    }

    func testSingleFileAndVersion2Torrents() throws {
        let single = try TorrentReader.read(bytes: dict([("info", dict([("name", bencode("notes.txt")), ("length", bencode(42)),
                                                                        ("piece length", bencode(16_384)),
                                                                        ("pieces", Array("20:".utf8) + [UInt8](repeating: 1, count: 20))]))]))
        XCTAssertEqual(single.files.map(\.path), ["notes.txt"])
        XCTAssertEqual(single.totalSize, 42)
        XCTAssertFalse(single.isPrivate)
        XCTAssertTrue(single.trackers.isEmpty)

        let leaf = { (n: Int64) in self.dict([("", self.dict([("length", self.bencode(n)), ("pieces root", self.bencode(String(repeating: "r", count: 32)))]))]) }
        let tree = dict([("a.txt", leaf(5)), ("sub", dict([("b.bin", leaf(7))]))])
        let info = dict([("name", bencode("v2set")), ("meta version", bencode(2)), ("piece length", bencode(16_384)), ("file tree", tree)])
        let v2 = try TorrentReader.read(bytes: dict([("info", info)]))
        XCTAssertEqual(v2.version, .v2)
        XCTAssertEqual(v2.files.map(\.path), ["v2set/a.txt", "v2set/sub/b.bin"])
        XCTAssertEqual(v2.totalSize, 12)
        XCTAssertEqual(v2.infoHashV2, SHA256.hash(data: info).map { String(format: "%02x", $0) }.joined())
        XCTAssertNil(v2.infoHashV1)
    }

    func testDamagedTorrentsThrowAndNeverTrap() throws {
        for bad in ["", "d", "de", "d4:infoi1ee", "d4:info", "l" + String(repeating: "l", count: 300), "d4:infod4:name99:xee", "i12345678901234567890123456e"] {
            XCTAssertThrowsError(try TorrentReader.read(bytes: Array(bad.utf8)), bad)
        }
        let good = dict([("info", dict([("name", bencode("x")), ("length", bencode(1))]))])
        for cut in 0..<good.count { _ = try? TorrentReader.read(bytes: Array(good.prefix(cut))) }
    }

    // MARK: Configuration profiles

    static func profileXML(payloads: String, removable: Bool = true) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadDisplayName</key><string>Example Corp Wi-Fi</string>
        <key>PayloadIdentifier</key><string>com.example.corp.wifi</string>
        <key>PayloadOrganization</key><string>Example Corp IT</string>
        <key>PayloadUUID</key><string>6F9619FF-8B86-D011-B42D-00C04FC964FF</string>
        <key>PayloadVersion</key><integer>1</integer>
        <key>PayloadRemovalDisallowed</key>\(removable ? "<false/>" : "<true/>")
        <key>PayloadContent</key><array>\(payloads)</array>
        </dict></plist>
        """
    }

    static let wifiAndVPN = """
        <dict><key>PayloadType</key><string>com.apple.wifi.managed</string><key>PayloadIdentifier</key><string>com.example.w</string>
        <key>SSID_STR</key><string>ExampleCorp</string><key>EncryptionType</key><string>WPA2</string></dict>
        <dict><key>PayloadType</key><string>com.apple.vpn.managed</string><key>PayloadIdentifier</key><string>com.example.v</string>
        <key>VPN</key><dict><key>RemoteAddress</key><string>vpn.example.com</string><key>OnDemandEnabled</key><integer>1</integer></dict></dict>
        """

    func testPlainProfileListsPayloadsByType() throws {
        let folder = try FixtureFolder()
        let identity = try TestIdentity.make(in: folder, subject: "/CN=Example Corp Root CA/O=Example Corp/C=US")
        let root = "<dict><key>PayloadType</key><string>com.apple.security.root</string><key>PayloadIdentifier</key><string>com.example.r</string>"
            + "<key>PayloadContent</key><data>\(Data(identity.der).base64EncodedString())</data></dict>"
        let p = try ConfigurationProfileReader.read(bytes: Array(Self.profileXML(payloads: Self.wifiAndVPN + root).utf8))
        XCTAssertEqual(p.displayName, "Example Corp Wi-Fi")
        XCTAssertEqual(p.organization, "Example Corp IT")
        XCTAssertFalse(p.removalDisallowed)
        XCTAssertNil(p.signature)
        XCTAssertEqual(p.payloads.map(\.kind), ["Wi-Fi", "VPN", "Root certificate"])
        XCTAssertEqual(p.payloads[0].summary, "“ExampleCorp” · WPA2")
        XCTAssertEqual(p.payloads[1].summary, "vpn.example.com · always on")
        XCTAssertTrue(p.payloads[2].summary?.hasPrefix("Example Corp Root CA") == true, "\(p.payloads[2].summary ?? "nil")")
        XCTAssertEqual(p.sensitivePayloads.map(\.kind), ["Root certificate"])
    }

    func testSignedProfileMatchesButIsNotTrusted() throws {
        let folder = try FixtureFolder()
        let identity = try TestIdentity.make(in: folder, subject: "/CN=Example Corp IT/O=Example Corp/C=US")
        try folder.write("plain.mobileconfig", Self.profileXML(payloads: Self.wifiAndVPN, removable: false))
        try identity.sign("plain.mobileconfig", to: "signed.mobileconfig", in: folder)
        let p = try ConfigurationProfileReader.read(contentsOf: folder.path("signed.mobileconfig"))
        XCTAssertTrue(p.removalDisallowed)
        let signature = try XCTUnwrap(p.signature)
        XCTAssertEqual(signature.signer?.commonName, "Example Corp IT")
        XCTAssertEqual(signature.matchesContent, true)
        guard case .untrusted? = signature.trust else { return XCTFail("a self-signed signer was trusted: \(String(describing: signature.trust))") }

        // Change one byte of the signed content: the signature no longer matches it.
        var bytes = try folder.bytes("signed.mobileconfig")
        let needle = Array("ExampleCorp".utf8)
        let at = try XCTUnwrap((0...(bytes.count - needle.count)).first { Array(bytes[$0..<($0 + needle.count)]) == needle })
        bytes[at] = UInt8(ascii: "F")
        if let tampered = try? ConfigurationProfileReader.read(bytes: bytes) {
            XCTAssertEqual(tampered.signature?.matchesContent, false)
        }
    }

    func testNotAProfile() {
        XCTAssertThrowsError(try ConfigurationProfileReader.read(bytes: Array("<plist><dict><key>A</key><string>b</string></dict></plist>".utf8)))
        XCTAssertThrowsError(try ConfigurationProfileReader.read(bytes: [0x30, 0x03, 0x02, 0x01]))
    }

    // MARK: iOS app archives

    /// A 1×1 PNG.
    static let png: [UInt8] = Array(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!)

    func testIPAReadsInfoProfileIconAndEntitlements() throws {
        let folder = try FixtureFolder()
        let app = "Payload/FieldLog.app"
        try folder.mkdir(app)
        try folder.write("\(app)/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleDisplayName</key><string>FieldLog</string>
        <key>CFBundleIdentifier</key><string>com.example.fieldlog</string>
        <key>CFBundleShortVersionString</key><string>1.8</string>
        <key>CFBundleVersion</key><string>77</string>
        <key>CFBundleExecutable</key><string>FieldLog</string>
        <key>MinimumOSVersion</key><string>17.0</string>
        <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
        <key>NSLocationWhenInUseUsageDescription</key><string>Tags each entry with where it was made.</string>
        <key>CFBundleIcons</key><dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array></dict></dict>
        </dict></plist>
        """)
        try folder.write("\(app)/AppIcon60x60@2x.png", bytes: Self.png)
        try folder.write("\(app)/Base.lproj/Main.txt", "invented\n")
        try folder.compile("\(app)/FieldLog")
        try folder.write("ent.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>aps-environment</key><string>production</string></dict></plist>
        """)
        try folder.run("/usr/bin/codesign", ["-s", "-", "-f", "--entitlements", "ent.plist", "\(app)/FieldLog"])
        let identity = try TestIdentity.make(in: folder)
        try folder.write("profile.plist", ProvisioningProfileTests.profile(expires: "2099-01-01T00:00:00Z", devices: ["0001", "0002"],
                                                                         getTaskAllow: false, certificate: identity.der))
        try identity.sign("profile.plist", to: "\(app)/embedded.mobileprovision", in: folder)
        try folder.run("/usr/bin/zip", ["-q", "-r", "FieldLog.ipa", "Payload"])

        let ipa = try IOSAppArchiveReader.read(contentsOf: folder.path("FieldLog.ipa"))
        XCTAssertEqual(ipa.bundlePath, app)
        XCTAssertEqual(ipa.name, "FieldLog")
        XCTAssertEqual(ipa.identifier, "com.example.fieldlog")
        XCTAssertEqual(ipa.shortVersion, "1.8")
        XCTAssertEqual(ipa.buildVersion, "77")
        XCTAssertEqual(ipa.minimumOSVersion, "17.0")
        XCTAssertEqual(ipa.deviceFamilies, ["iPhone", "iPad"])
        XCTAssertEqual(ipa.usageDescriptions.map(\.what), ["Location while in use"])
        XCTAssertEqual(ipa.iconData, Self.png)
        XCTAssertEqual(ipa.profile?.name, "Fixture Development Profile")
        XCTAssertEqual(ipa.profile?.distribution, .adHoc)
        XCTAssertEqual(ipa.entitlementsSource, .signature)
        XCTAssertEqual(ipa.entitlements?["aps-environment"]?.stringValue, "production")
        XCTAssertEqual(ipa.architectures, ["arm64"])
        XCTAssertEqual(ipa.isAppStoreEncrypted, false)
        XCTAssertTrue(ipa.listing.entries.contains { $0.path.hasSuffix("Main.txt") })
    }

    func testIPAWithoutABundleIsRefused() throws {
        let folder = try FixtureFolder()
        try folder.write("Payload/readme.txt", "no app here\n")
        try folder.run("/usr/bin/zip", ["-q", "-r", "empty.ipa", "Payload"])
        XCTAssertThrowsError(try IOSAppArchiveReader.read(contentsOf: folder.path("empty.ipa")))
    }

    // MARK: Android packages

    func testAPKManifestPermissionsAndSignatures() throws {
        let folder = try FixtureFolder()
        var w = AXMLWriter()
        w.start("manifest", [.init("package", .string("com.example.trailmap")), .android("versionCode", 0x0101_021B, .int(42)),
                             .android("versionName", 0x0101_021C, .string("3.1.0"))])
        w.start("uses-sdk", [.android("minSdkVersion", 0x0101_020C, .int(26)), .android("targetSdkVersion", 0x0101_0270, .int(35))]); w.end()
        for p in ["android.permission.INTERNET", "android.permission.ACCESS_FINE_LOCATION", "android.permission.CAMERA",
                  "android.permission.INTERNET"] {
            w.start("uses-permission", [.android("name", 0x0101_0003, .string(p))]); w.end()
        }
        w.start("application", [.android("label", 0x0101_0001, .string("Trail Map")), .android("debuggable", 0x0101_000F, .bool(true))])
        w.start("activity", [.android("name", 0x0101_0003, .string(".Main"))]); w.end()
        w.start("service", [.android("name", 0x0101_0003, .string(".Sync"))]); w.end()
        w.end(); w.end()
        try folder.write("apk/AndroidManifest.xml", bytes: w.bytes())
        try folder.write("apk/classes.dex", "dex\n035\0")
        try folder.write("apk/lib/arm64-v8a/libtrail.so", "invented\n")
        try folder.write("apk/META-INF/MANIFEST.MF", "Manifest-Version: 1.0\n")
        let identity = try TestIdentity.make(in: folder, subject: "/CN=Trail Map Release/O=Example Trails/C=US")
        try folder.run("/usr/bin/openssl", ["smime", "-sign", "-binary", "-outform", "DER", "-in", "apk/META-INF/MANIFEST.MF",
                                            "-signer", identity.certificatePEM, "-inkey", identity.keyPEM, "-out", "apk/META-INF/CERT.RSA"])
        try folder.run("/usr/bin/ditto", ["-c", "-k", "apk", "trail.apk"])

        let apk = try AndroidPackageReader.read(contentsOf: folder.path("trail.apk"))
        XCTAssertEqual(apk.packageName, "com.example.trailmap")
        XCTAssertEqual(apk.versionCode, 42)
        XCTAssertEqual(apk.versionName, "3.1.0")
        XCTAssertEqual(apk.minSDK, 26)
        XCTAssertEqual(apk.targetSDK, 35)
        XCTAssertEqual(apk.label, "Trail Map")
        XCTAssertFalse(apk.labelIsResource)
        XCTAssertEqual(apk.permissions, ["android.permission.INTERNET", "android.permission.ACCESS_FINE_LOCATION", "android.permission.CAMERA"])
        XCTAssertEqual(apk.dangerousPermissions, ["android.permission.ACCESS_FINE_LOCATION", "android.permission.CAMERA"])
        XCTAssertTrue(apk.debuggable)
        XCTAssertEqual(apk.activityCount, 1)
        XCTAssertEqual(apk.serviceCount, 1)
        XCTAssertEqual(apk.nativeABIs, ["arm64-v8a"])
        XCTAssertEqual(apk.signatureSchemes, ["v1 (JAR signing)"])
        XCTAssertEqual(apk.certificates.first?.commonName, "Trail Map Release")

        // Insert an APK Signing Block before the central directory and fix the end record's offset: v2+ is seen.
        var zip = try folder.bytes("trail.apk")
        let eocd = try XCTUnwrap((0...(zip.count - 22)).reversed().first { zip[$0..<($0 + 4)].elementsEqual([0x50, 0x4B, 0x05, 0x06]) })
        let cd = Int(UInt32(zip[eocd + 16]) | UInt32(zip[eocd + 17]) << 8 | UInt32(zip[eocd + 18]) << 16 | UInt32(zip[eocd + 19]) << 24)
        let block = [UInt8](repeating: 0, count: 16) + Array("APK Sig Block 42".utf8)
        zip.insert(contentsOf: block, at: cd)
        let moved = UInt32(cd + block.count)
        for i in 0..<4 { zip[eocd + block.count + 16 + i] = UInt8(truncatingIfNeeded: moved >> (8 * UInt32(i))) }
        let v2 = try AndroidPackageReader.read(source: BinaryDataSource(zip), fileName: "trail.apk")
        XCTAssertEqual(v2.signatureSchemes, ["v1 (JAR signing)", "v2+ (APK Signing Block)"])
    }

    func testStrippedAttributeNamesFallBackToResourceIDsAndResourceLabels() throws {
        var w = AXMLWriter()
        w.start("manifest", [.init("package", .string("com.example.obf")), .android("", 0x0101_021C, .string("9.9"))])
        w.start("application", [.android("", 0x0101_0001, .reference(0x7F0E_0001))]); w.end()
        w.end()
        let folder = try FixtureFolder()
        try folder.write("apk/AndroidManifest.xml", bytes: w.bytes())
        try folder.run("/usr/bin/ditto", ["-c", "-k", "apk", "obf.apk"])
        let apk = try AndroidPackageReader.read(contentsOf: folder.path("obf.apk"))
        XCTAssertEqual(apk.versionName, "9.9")
        XCTAssertNil(apk.label)
        XCTAssertTrue(apk.labelIsResource)
        XCTAssertTrue(apk.signatureSchemes.isEmpty)
    }

    func testDamagedManifestsThrowAndNeverTrap() throws {
        var w = AXMLWriter()
        w.start("manifest", [.init("package", .string("com.example.fuzz"))]); w.end()
        let good = w.bytes()
        XCTAssertNoThrow(try AndroidBinaryXML.parse(good))
        fuzz(good, rounds: 400) { _ = try? AndroidBinaryXML.parse($0) }
        for cut in 0..<good.count { _ = try? AndroidBinaryXML.parse(Array(good.prefix(cut))) }
        XCTAssertThrowsError(try AndroidBinaryXML.parse(Array("<manifest/>".utf8)))
    }
}

/// Writes Android binary XML (AAPT ResXMLTree): a UTF-16 string pool, the resource map for attribute names, and
/// start/end element chunks. Enough of the format to stand in for `aapt2`, which this Mac does not have.
struct AXMLWriter {
    enum Value { case string(String), int(Int32), bool(Bool), reference(UInt32) }
    struct Attribute {
        var name: String
        var resourceID: UInt32?
        var value: Value
        var android: Bool
        init(_ name: String, _ value: Value) { self.name = name; self.value = value; resourceID = nil; android = false }
        static func android(_ name: String, _ id: UInt32, _ value: Value) -> Attribute {
            var a = Attribute(name, value); a.resourceID = id; a.android = true; return a
        }
    }

    private var events: [(start: Bool, name: String, attributes: [Attribute])] = []
    mutating func start(_ name: String, _ attributes: [Attribute]) { events.append((true, name, attributes)) }
    mutating func end() {
        var depth = 0
        for e in events.reversed() {
            if !e.start { depth += 1; continue }
            if depth == 0 { events.append((false, e.name, [])); return }
            depth -= 1
        }
    }

    func bytes() -> [UInt8] {
        // Attribute names with resource ids come first in the pool, so the resource map lines up with them.
        // A stripped name is kept apart by a private key ("\0" + id) and written to the pool as an empty string.
        var strings: [String] = []
        var ids: [UInt32] = []
        var mapped: [String: UInt32] = [:]
        for e in events { for a in e.attributes where a.resourceID != nil {
            let key = a.name.isEmpty ? "\u{0}\(a.resourceID!)" : a.name
            if mapped[key] == nil { mapped[key] = UInt32(strings.count); strings.append(key); ids.append(a.resourceID!) }
        } }
        func intern(_ s: String) -> UInt32 {
            if let i = strings.firstIndex(of: s) { return UInt32(i) }
            strings.append(s); return UInt32(strings.count - 1)
        }
        let nsURI = intern("http://schemas.android.com/apk/res/android")
        let nsPrefix = intern("android")
        for e in events { _ = intern(e.name); for a in e.attributes {
            if a.resourceID == nil { _ = intern(a.name) }
            if case .string(let s) = a.value { _ = intern(s) }
        } }

        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
        func chunk(_ type: UInt16, header: [UInt8], body: [UInt8]) -> [UInt8] {
            le16(type) + le16(UInt16(8 + header.count)) + le32(UInt32(8 + header.count + body.count)) + header + body
        }

        // String pool, UTF-16. A stripped (empty) name stays empty in the pool.
        var data: [UInt8] = []
        var offsets: [UInt32] = []
        for s in strings {
            offsets.append(UInt32(data.count))
            let shown = s.hasPrefix("\u{0}") ? "" : s
            let units = Array(shown.utf16)
            data += le16(UInt16(units.count)) + units.flatMap(le16) + [0, 0]
        }
        while data.count % 4 != 0 { data.append(0) }
        let poolHeader = le32(UInt32(strings.count)) + le32(0) + le32(0) + le32(UInt32(28 + strings.count * 4)) + le32(0)
        var out = chunk(0x0001, header: poolHeader, body: offsets.flatMap(le32) + data)
        out += chunk(0x0180, header: [], body: ids.flatMap(le32))
        let lineComment = le32(1) + le32(0xFFFF_FFFF)
        out += chunk(0x0100, header: lineComment, body: le32(nsPrefix) + le32(nsURI))
        for e in events {
            if e.start {
                var body = le32(0xFFFF_FFFF) + le32(intern(e.name)) + le16(20) + le16(20) + le16(UInt16(e.attributes.count))
                    + le16(0) + le16(0) + le16(0)
                for a in e.attributes {
                    let key = a.resourceID == nil ? a.name : (a.name.isEmpty ? "\u{0}\(a.resourceID!)" : a.name)
                    let nameIndex = a.resourceID == nil ? intern(key) : mapped[key]!
                    body += le32(a.android ? nsURI : 0xFFFF_FFFF) + le32(nameIndex)
                    switch a.value {
                    case .string(let s): body += le32(intern(s)) + le16(8) + [0, 0x03] + le32(intern(s))
                    case .int(let i): body += le32(0xFFFF_FFFF) + le16(8) + [0, 0x10] + le32(UInt32(bitPattern: i))
                    case .bool(let b): body += le32(0xFFFF_FFFF) + le16(8) + [0, 0x12] + le32(b ? 0xFFFF_FFFF : 0)
                    case .reference(let r): body += le32(0xFFFF_FFFF) + le16(8) + [0, 0x01] + le32(r)
                    }
                }
                out += chunk(0x0102, header: lineComment, body: body)
            } else {
                out += chunk(0x0103, header: lineComment, body: le32(0xFFFF_FFFF) + le32(intern(e.name)))
            }
        }
        out += chunk(0x0101, header: lineComment, body: le32(nsPrefix) + le32(nsURI))
        return le16(0x0003) + le16(8) + le32(UInt32(8 + out.count)) + out
    }
}
