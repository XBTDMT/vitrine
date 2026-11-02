import XCTest
@testable import VitrinePreviewKit
import VitrineSupport

/// Apps show their facts and an unsigned app is flagged, read statically (S-8, S-22).
final class BinaryFactsTests: XCTestCase {
    func testUnsignedAppShowsFactsAndCaution() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("vt-bin-\(UUID().uuidString)/Orbit Demo.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleName": "Orbit Demo", "CFBundleIdentifier": "com.example.orbit-demo",
                                   "CFBundleShortVersionString": "2.4.0", "CFBundleVersion": "240", "CFBundlePackageType": "APPL",
                                   "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let doc = try BinaryFacts.document(url: app, kind: .appBundle)
        XCTAssertEqual(doc.fact("identifier")?.value, "com.example.orbit-demo")
        XCTAssertEqual(doc.fact("version")?.value, "2.4.0 (240)")
        XCTAssertEqual(doc.fact("minimumSystem")?.value, "14.0")
        XCTAssertEqual(doc.fact("headline")?.value, "2.4.0 · not signed")
        XCTAssertEqual(doc.badges.first?.title, "Not signed")
        XCTAssertEqual(doc.badges.first?.level, .caution)
    }

    func testUnsignedInstallerWithScriptIsFlaggedTwice() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-pkg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("root/opt/orbit"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "orbit\n".write(to: dir.appendingPathComponent("root/opt/orbit/README"), atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("scripts/postinstall")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pkg = dir.appendingPathComponent("orbit.pkg")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/pkgbuild")
        build.arguments = ["--quiet", "--root", dir.appendingPathComponent("root").path, "--scripts", dir.appendingPathComponent("scripts").path,
                           "--identifier", "com.example.orbit", "--version", "2.4.0", "--install-location", "/", pkg.path]
        try build.run(); build.waitUntilExit()
        XCTAssertEqual(build.terminationStatus, 0)
        let doc = try BinaryFacts.document(url: pkg, kind: .installerPackage)
        XCTAssertEqual(doc.fact("identifier")?.value, "com.example.orbit")
        XCTAssertEqual(doc.fact("scripts")?.value, "postinstall")
        XCTAssertEqual(doc.fact("headline")?.value, "1 install script")
        XCTAssertEqual(Set(doc.badges.map(\.title)), ["Not signed", "Runs install scripts"])
    }
}
