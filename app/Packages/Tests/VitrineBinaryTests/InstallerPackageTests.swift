import Foundation
import XCTest
@testable import VitrineBinary

/// zlib (RFC 1950) bytes: header, Foundation's raw deflate, Adler-32 trailer.
func zlibWrap(_ bytes: [UInt8]) throws -> [UInt8] {
    let deflated = [UInt8](try (Data(bytes) as NSData).compressed(using: .zlib) as Data)
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in bytes { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
    var out: [UInt8] = [0x78, 0x9C] + deflated
    out.be32(b << 16 | a)
    return out
}

/// Writes xar bytes directly, for packages no tool makes: signed without an identity, lying offsets, hostile XML.
struct XarBuilder {
    var toc: String
    var heap: [UInt8] = []
    var headerSize: UInt16 = 28
    var declaredTocSize: UInt64?

    /// A `<file>` element whose data sits at `offset` in the heap.
    static func file(_ name: String, offset: Int, length: Int, size: Int? = nil,
                     encoding: String = "application/octet-stream", children: String = "") -> String {
        """
        <file><name>\(name)</name><type>file</type><data><offset>\(offset)</offset><length>\(length)</length>
        <size>\(size ?? length)</size><encoding style="\(encoding)"/></data>\(children)</file>
        """
    }

    func build() throws -> [UInt8] {
        let tocBytes = Array(toc.utf8)
        let compressed = try zlibWrap(tocBytes)
        var out: [UInt8] = []
        out.be32(0x7861_7221); out.be16(headerSize); out.be16(1)
        out.be64(UInt64(compressed.count)); out.be64(declaredTocSize ?? UInt64(tocBytes.count)); out.be32(1)
        out += [UInt8](repeating: 0, count: max(0, Int(headerSize) - 28))
        return out + compressed + heap
    }
}

final class InstallerPackageTests: XCTestCase {
    func makeComponent(_ folder: FixtureFolder, name: String = "comp.pkg") throws {
        try folder.write("root/Applications/Fixture.txt", "payload file one\n")
        try folder.write("root/Applications/Second.txt", "payload file two\n")
        try folder.write("scripts/preinstall", "#!/bin/sh\nexit 0\n")
        try folder.write("scripts/postinstall", "#!/bin/sh\nexit 0\n")
        try folder.write("scripts/helper.sh", "echo helper\n")
        for script in ["preinstall", "postinstall"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path("scripts/\(script)").path)
        }
        try folder.run("/usr/bin/pkgbuild", ["--quiet", "--root", "root", "--identifier", "com.example.fixture",
                                             "--version", "1.2.3", "--scripts", "scripts",
                                             "--install-location", "/Library/VitrineFixture", name])
    }

    func testComponentPackage() throws {
        let folder = try FixtureFolder()
        try makeComponent(folder)
        let package = try InstallerPackageReader.read(contentsOf: folder.path("comp.pkg"))
        XCTAssertEqual(package.kind, .component)
        XCTAssertTrue(package.notes.isEmpty, "\(package.notes)")
        XCTAssertEqual(package.header.headerSize, 28)
        XCTAssertEqual(package.header.checksumAlgorithm, "SHA-1")
        XCTAssertFalse(package.isSigned)
        XCTAssertNil(package.distribution)
        XCTAssertNotNil(package.creationTime)
        XCTAssertEqual(Set(package.members.map(\.path)), ["Bom", "Payload", "Scripts", "PackageInfo"])
        XCTAssertFalse(package.membersTruncated)

        let component = try XCTUnwrap(package.components.first)
        XCTAssertEqual(component.path, "")
        XCTAssertEqual(component.identifier, "com.example.fixture")
        XCTAssertEqual(component.version, "1.2.3")
        XCTAssertEqual(component.installLocation, "/Library/VitrineFixture")
        XCTAssertEqual(component.authorization, "root")
        XCTAssertEqual(Set(component.declaredScripts.map(\.name)), ["preinstall", "postinstall"])
        XCTAssertEqual(component.declaredScripts.first { $0.name == "postinstall" }?.file, "./postinstall")
        XCTAssertFalse(component.scriptFilesTruncated)
        let files = Dictionary(uniqueKeysWithValues: component.scriptFiles.map { ($0.name, $0) })
        XCTAssertEqual(Set(files.keys), ["preinstall", "postinstall", "helper.sh"])
        XCTAssertEqual(files["postinstall"]?.isExecutable, true)
        XCTAssertEqual(files["helper.sh"]?.isExecutable, false)
        XCTAssertEqual(files["helper.sh"]?.size, 12)
        XCTAssertEqual(files["helper.sh"]?.text, "echo helper\n", "scripts are kept as text (T-2)")
        XCTAssertEqual(files["postinstall"]?.text, "#!/bin/sh\nexit 0\n")
        XCTAssertTrue(package.hasInstallScripts)
        XCTAssertEqual(Set(package.scriptNames), ["preinstall", "postinstall", "helper.sh"])

        let payload = try XCTUnwrap(component.payload)
        XCTAssertEqual(payload.format, "gzip cpio")
        XCTAssertEqual(payload.numberOfFiles, 4)               // ., Applications, and the two files
        XCTAssertGreaterThan(payload.archivedSize, 0)
        XCTAssertGreaterThan(payload.installKBytes ?? 0, 0)
    }

    func testProductArchiveWithDistribution() throws {
        let folder = try FixtureFolder()
        try makeComponent(folder)
        try folder.write("dist.xml", """
        <?xml version="1.0" encoding="utf-8"?>
        <installer-gui-script minSpecVersion="2">
            <title>Fixture Installer</title>
            <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
            <domains enable_localSystem="true" enable_anywhere="false" enable_currentUserHome="true"/>
            <allowed-os-versions><os-version min="13.0"/></allowed-os-versions>
            <installation-check script="checkIt()"/>
            <script><![CDATA[ function checkIt() { return true; } ]]></script>
            <choices-outline><line choice="default"><line choice="com.example.fixture"/></line></choices-outline>
            <choice id="default"/>
            <choice id="com.example.fixture" visible="false"><pkg-ref id="com.example.fixture"/></choice>
            <pkg-ref id="com.example.fixture" version="1.2.3" installKBytes="4">#comp.pkg</pkg-ref>
        </installer-gui-script>
        """)
        try folder.run("/usr/bin/productbuild", ["--quiet", "--distribution", "dist.xml", "--package-path", ".", "product.pkg"])
        let package = try InstallerPackageReader.read(contentsOf: folder.path("product.pkg"))
        XCTAssertEqual(package.kind, .product)
        XCTAssertTrue(package.notes.isEmpty, "\(package.notes)")
        let dist = try XCTUnwrap(package.distribution)
        XCTAssertEqual(dist.title, "Fixture Installer")
        XCTAssertEqual(dist.minSpecVersion, "2")
        XCTAssertEqual(dist.hostArchitectures, ["arm64", "x86_64"])
        XCTAssertEqual(dist.allowedOSVersions, ["≥ 13.0"])
        XCTAssertEqual(dist.installationCheck, "checkIt()")
        XCTAssertEqual(dist.javaScriptBlocks, 1)
        XCTAssertEqual(dist.domains, ["localSystem", "currentUserHome"])
        XCTAssertEqual(dist.customize, "never")
        XCTAssertEqual(dist.packageReferences.map(\.identifier), ["com.example.fixture"])
        XCTAssertEqual(dist.packageReferences.first?.version, "1.2.3")
        XCTAssertEqual(dist.packageReferences.first?.location, "#comp.pkg")
        XCTAssertEqual(package.components.first?.path, "comp.pkg")
        XCTAssertEqual(package.components.first?.identifier, "com.example.fixture")
        XCTAssertEqual(Set(package.scriptNames), ["preinstall", "postinstall", "helper.sh"])

        guard case .installerPackage(let again) = try VitrineBinary.inspect(folder.path("product.pkg")) else {
            return XCTFail("inspect must read a package")
        }
        XCTAssertEqual(again, package)
    }

    func testSignatureSectionFromBytes() throws {
        let folder = try FixtureFolder()
        let identity = try TestIdentity.make(in: folder, subject: "/CN=Developer ID Installer: Fixture Org (ABCDE12345)/OU=ABCDE12345/O=Fixture Org")
        let cert = Data(identity.der).base64EncodedString(options: [.lineLength64Characters])
        let info = Array(#"<pkg-info identifier="com.example.signed" version="3"/>"#.utf8)
        let builder = XarBuilder(toc: """
        <?xml version="1.0" encoding="UTF-8"?>
        <xar><toc><checksum style="sha1"><offset>0</offset><size>20</size></checksum>
        <signature style="RSA"><offset>20</offset><size>256</size>
          <KeyInfo xmlns="http://www.w3.org/2000/09/xmldsig#"><X509Data><X509Certificate>\(cert)</X509Certificate></X509Data></KeyInfo>
        </signature>
        \(XarBuilder.file("PackageInfo", offset: 276, length: info.count))
        </toc></xar>
        """, heap: [UInt8](repeating: 0, count: 276) + info)
        let package = try InstallerPackageReader.read(source: BinaryDataSource(try builder.build()))
        let signature = try XCTUnwrap(package.signature)
        XCTAssertEqual(signature.styles, ["RSA"])
        XCTAssertEqual(signature.size, 256)
        XCTAssertEqual(signature.certificates.first?.commonName, "Developer ID Installer: Fixture Org (ABCDE12345)")
        XCTAssertEqual(signature.certificates.first?.organizationalUnit, "ABCDE12345")
        // The heap holds zeros where the checksum and signature belong: the certificate is listed, never trusted (F58).
        XCTAssertEqual(signature.verification, .broken("the table of contents does not match its checksum"))
        XCTAssertEqual(package.components.first?.identifier, "com.example.signed")
        XCTAssertEqual(package.kind, .component)
    }

    func testHostileArchives() throws {
        let folder = try FixtureFolder()
        assertBinaryError(try InstallerPackageReader.read(source: BinaryDataSource(Array("PK\u{3}\u{4}not xar".utf8))), matching: {
            if case .notRecognized = $0 { true } else { false }
        })
        // Header size below the minimum; table of contents larger than the cap or the file; not zlib; not XML.
        var bytes = try XarBuilder(toc: "<xar><toc/></xar>", headerSize: 4).build()
        assertBinaryError(try InstallerPackageReader.read(source: BinaryDataSource(bytes)))
        bytes = try XarBuilder(toc: "<xar><toc/></xar>").build()
        bytes.replaceSubrange(8..<16, with: [0, 0, 0, 0x10, 0, 0, 0, 0])
        assertBinaryError(try InstallerPackageReader.read(source: BinaryDataSource(bytes)))
        bytes = try XarBuilder(toc: "<xar><toc/></xar>").build()
        bytes[28] = 0x00
        assertBinaryError(try InstallerPackageReader.read(source: BinaryDataSource(bytes)))
        assertBinaryError(try InstallerPackageReader.read(source: BinaryDataSource(try XarBuilder(toc: "<xar><toc>").build())))
        assertBinaryError(try InstallerPackageReader.read(source: BinaryDataSource(try XarBuilder(toc: "<other/>").build())))

        // External entities are never resolved: a marker in a local file must not reach a member name.
        try folder.write("secret.txt", "SECRET-MARKER")
        let xxe = """
        <?xml version="1.0"?><!DOCTYPE xar [<!ENTITY leak SYSTEM "\(folder.path("secret.txt").absoluteString)">]>
        <xar><toc><file><name>a&leak;b</name><type>file</type></file></toc></xar>
        """
        if let package = try? InstallerPackageReader.read(source: BinaryDataSource(try XarBuilder(toc: xxe).build())) {
            XCTAssertFalse(package.members.contains { $0.path.contains("SECRET") })
        }

        // Nesting past the cap is refused.
        let deep = String(repeating: "<file><name>d</name>", count: 200) + String(repeating: "</file>", count: 200)
        assertBinaryError(try InstallerPackageReader.read(source: BinaryDataSource(try XarBuilder(toc: "<xar><toc>\(deep)</toc></xar>").build())), matching: {
            if case .unsupported = $0 { true } else { false }
        })

        // Member data outside the file, and a member count past the cap.
        let lying = XarBuilder(toc: "<xar><toc>\(XarBuilder.file("Distribution", offset: 1 << 40, length: 100))</toc></xar>")
        let package = try InstallerPackageReader.read(source: BinaryDataSource(try lying.build()))
        XCTAssertEqual(package.kind, .product)
        XCTAssertNil(package.distribution)
        XCTAssertTrue(package.notes.first?.contains("outside") == true)
        let many = (0..<50).map { "<file><name>f\($0)</name><type>file</type></file>" }.joined()
        var limits = BinaryLimits()
        limits.maxXarMembers = 10
        let capped = try InstallerPackageReader.read(source: BinaryDataSource(try XarBuilder(toc: "<xar><toc>\(many)</toc></xar>").build()),
                                                     limits: limits)
        XCTAssertEqual(capped.members.count, 10)
        XCTAssertTrue(capped.membersTruncated)
        XCTAssertEqual(capped.kind, .other)
    }

    func testScriptArchiveCapAndDecompressionBomb() throws {
        let folder = try FixtureFolder()
        // A Scripts archive whose one file is 8 MiB of zeros: gzip makes it a few KiB.
        func odc(mode: String, name: String, size: Int) -> [UInt8] {
            let nameSize = String(name.utf8.count + 1, radix: 8), fileSize = String(size, radix: 8)
            let header = "070707" + "000000" + "000001" + mode + "000000" + "000000" + "000001" + "000000"
                + "00000000000" + String(repeating: "0", count: 6 - nameSize.count) + nameSize
                + String(repeating: "0", count: 11 - fileSize.count) + fileSize
            return Array(header.utf8) + Array(name.utf8) + [0]
        }
        var cpio = odc(mode: "100755", name: "./postinstall", size: 8 * 1024 * 1024)
        XCTAssertEqual(cpio.count, 76 + 14)
        cpio += [UInt8](repeating: 0, count: 8 * 1024 * 1024)
        cpio += odc(mode: "000000", name: "TRAILER!!!", size: 0)
        try folder.write("Scripts.cpio", bytes: cpio)
        try folder.run("/usr/bin/gzip", ["-9", "Scripts.cpio"])
        let gz = try folder.bytes("Scripts.cpio.gz")
        XCTAssertLessThan(gz.count, 64 * 1024)
        let info = Array(#"<pkg-info identifier="com.example.bomb"><scripts><postinstall file="./postinstall"/></scripts></pkg-info>"#.utf8)
        let builder = XarBuilder(toc: """
        <xar><toc>\(XarBuilder.file("PackageInfo", offset: 0, length: info.count))\(XarBuilder.file("Scripts", offset: info.count, length: gz.count))</toc></xar>
        """, heap: info + gz)
        var limits = BinaryLimits()
        limits.maxScriptArchiveBytes = 1024 * 1024
        let package = try InstallerPackageReader.read(source: BinaryDataSource(try builder.build()), limits: limits)
        let component = try XCTUnwrap(package.components.first)
        XCTAssertTrue(component.scriptFilesTruncated)
        XCTAssertEqual(component.declaredScripts.map(\.name), ["postinstall"])
        XCTAssertEqual(package.scriptNames, ["postinstall"])

        // With room, the same archive lists its one file and its size.
        let roomy = try InstallerPackageReader.read(source: BinaryDataSource(try builder.build()))
        XCTAssertEqual(roomy.components.first?.scriptFiles.first?.size, 8 * 1024 * 1024)
        XCTAssertEqual(roomy.components.first?.scriptFilesTruncated, false)
    }

    func testRandomDamageNeverTraps() throws {
        let folder = try FixtureFolder()
        try makeComponent(folder)
        let bytes = try folder.bytes("comp.pkg")
        var read = 0
        fuzz(bytes, rounds: 400, seed: 11) { damaged in
            if (try? InstallerPackageReader.read(source: BinaryDataSource(damaged))) != nil { read += 1 }
        }
        XCTAssertGreaterThan(read, 0)
    }
}
