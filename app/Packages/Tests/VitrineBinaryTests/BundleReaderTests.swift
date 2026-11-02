import Foundation
import XCTest
@testable import VitrineBinary

final class BundleReaderTests: XCTestCase {
    static let infoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleName</key><string>Fixture</string>
    <key>CFBundleDisplayName</key><string>Fixture Viewer</string>
    <key>CFBundleIdentifier</key><string>com.example.fixture</string>
    <key>CFBundleShortVersionString</key><string>1.4.2</string>
    <key>CFBundleVersion</key><string>142</string>
    <key>CFBundleExecutable</key><string>Fixture</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>Invented for a test</string>
    <key>NSCameraUsageDescription</key><string>Scan codes with the camera.</string>
    <key>NSAppleEventsUsageDescription</key><string>Talk to Finder.</string>
    <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>fixture</string><string>fx</string></array></dict></array>
    <key>CFBundleDocumentTypes</key><array><dict>
      <key>CFBundleTypeName</key><string>Fixture Document</string><key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>com.example.fixture.doc</string></array>
      <key>LSHandlerRank</key><string>Owner</string></dict></array>
    <key>UTExportedTypeDeclarations</key><array><dict>
      <key>UTTypeIdentifier</key><string>com.example.fixture.doc</string>
      <key>UTTypeDescription</key><string>Fixture Document</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>fxd</string></array></dict>
    </dict></array>
    </dict></plist>
    """

    static func plist(id: String, extra: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(id)</string><key>CFBundleShortVersionString</key><string>9.9</string>
        \(extra)</dict></plist>
        """
    }

    /// A small app: universal executable, a framework, an app extension, a helper app, signed ad hoc (deep) with
    /// sandbox entitlements.
    func makeApp(_ folder: FixtureFolder) throws -> URL {
        let fx = try SharedFixtures.get()
        try folder.write("Fixture.app/Contents/Info.plist", Self.infoPlist)
        try folder.mkdir("Fixture.app/Contents/MacOS")
        try FileManager.default.copyItem(at: fx.fat, to: folder.path("Fixture.app/Contents/MacOS/Fixture"))
        try folder.write("Fixture.app/Contents/Resources/readme.txt", String(repeating: "resource ", count: 500))
        // A versioned framework: Versions/A holds the binary and resources, the top-level names are links.
        let kit = "Fixture.app/Contents/Frameworks/Kit.framework"
        try folder.write("\(kit)/Versions/A/Resources/Info.plist",
                         Self.plist(id: "com.example.kit", extra: "<key>CFBundleExecutable</key><string>Kit</string>"))
        try FileManager.default.copyItem(at: fx.dylib, to: folder.path("\(kit)/Versions/A/Kit"))
        for (link, target) in [("Versions/Current", "A"), ("Kit", "Versions/Current/Kit"),
                               ("Resources", "Versions/Current/Resources")] {
            try FileManager.default.createSymbolicLink(atPath: folder.path("\(kit)/\(link)").path, withDestinationPath: target)
        }
        let exe = "<key>CFBundleExecutable</key><string>Inner</string>"
        let share = "Fixture.app/Contents/PlugIns/Share.appex"
        try folder.write("\(share)/Contents/Info.plist", Self.plist(
            id: "com.example.fixture.share",
            extra: exe + "<key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.share-services</string></dict>"))
        let helper = "Fixture.app/Contents/Library/LoginItems/Helper.app"
        try folder.write("\(helper)/Contents/Info.plist", Self.plist(id: "com.example.fixture.helper", extra: exe))
        for inner in [share, helper] {
            try folder.mkdir("\(inner)/Contents/MacOS")
            try FileManager.default.copyItem(at: fx.thin, to: folder.path("\(inner)/Contents/MacOS/Inner"))
        }
        try folder.write("ent.plist", SharedFixtures.entitlementsXML)
        // Inside out, as codesign requires: nested code first, then the app with its entitlements.
        for inner in ["\(kit)/Versions/A", share, helper] { try folder.run("/usr/bin/codesign", ["-s", "-", "-f", inner]) }
        try folder.run("/usr/bin/codesign", ["-s", "-", "-f", "--entitlements", "ent.plist", "Fixture.app"])
        return folder.path("Fixture.app")
    }

    func testAppBundleFacts() throws {
        let folder = try FixtureFolder()
        let app = try makeApp(folder)
        let facts = try BundleReader.read(contentsOf: app)
        XCTAssertEqual(facts.layout, .macOS)
        let info = facts.info
        XCTAssertEqual(info.name, "Fixture")
        XCTAssertEqual(info.displayName, "Fixture Viewer")
        XCTAssertEqual(info.identifier, "com.example.fixture")
        XCTAssertEqual(info.shortVersion, "1.4.2")
        XCTAssertEqual(info.buildVersion, "142")
        XCTAssertEqual(info.minimumSystemVersion, "13.0")
        XCTAssertEqual(info.categoryName, "Developer Tools")
        XCTAssertEqual(info.urlSchemes, ["fixture", "fx"])
        XCTAssertEqual(info.documentTypes.first?.contentTypes, ["com.example.fixture.doc"])
        XCTAssertEqual(info.documentTypes.first?.role, "Viewer")
        XCTAssertEqual(info.exportedTypes.first?.identifier, "com.example.fixture.doc")
        XCTAssertEqual(info.exportedTypes.first?.extensions, ["fxd"])
        XCTAssertEqual(info.privacyUsage.map(\.key), ["NSAppleEventsUsageDescription", "NSCameraUsageDescription"])
        XCTAssertEqual(info.privacyUsage.map(\.resource), ["Apple Events", "Camera"])
        XCTAssertEqual(info.privacyUsage.last?.purpose, "Scan codes with the camera.")
        XCTAssertFalse(info.isAgent)

        XCTAssertEqual(Set(facts.architectures), ["arm64", "x86_64"])
        XCTAssertEqual(facts.executableURL?.lastPathComponent, "Fixture")
        XCTAssertNil(facts.executableProblem)
        XCTAssertEqual(facts.isSandboxed, true)
        XCTAssertEqual(facts.entitlements, try SharedFixtures.get().entitlements)
        XCTAssertEqual(facts.signature?.identifier, "com.example.fixture")
        XCTAssertEqual(facts.notarization, .notStapled)

        let byPath = Dictionary(uniqueKeysWithValues: facts.embedded.map { ($0.relativePath, $0) })
        XCTAssertEqual(byPath["Contents/Frameworks/Kit.framework"]?.kind, .framework)
        XCTAssertEqual(byPath["Contents/Frameworks/Kit.framework"]?.identifier, "com.example.kit")
        XCTAssertEqual(byPath["Contents/PlugIns/Share.appex"]?.kind, .appExtension)
        XCTAssertEqual(byPath["Contents/PlugIns/Share.appex"]?.extensionPoint, "com.apple.share-services")
        XCTAssertEqual(byPath["Contents/Library/LoginItems/Helper.app"]?.kind, .loginItem)
        XCTAssertEqual(byPath["Contents/Library/LoginItems/Helper.app"]?.version, "9.9")
        XCTAssertFalse(facts.embeddedTruncated)

        XCTAssertFalse(facts.size.isPartial)
        XCTAssertGreaterThan(facts.size.logicalBytes, 4500)
        XCTAssertGreaterThan(facts.size.allocatedBytes, 0)
        XCTAssertGreaterThanOrEqual(facts.size.fileCount, 6)

        // The Security layer agrees: deep ad-hoc signature, valid offline.
        let assessment = SignatureVerifier.assess(url: app)
        XCTAssertEqual(assessment.status, .adhoc)
        XCTAssertEqual(assessment.identifier, "com.example.fixture")

        // A resource changed after signing breaks the seal (full depth sees it; quick does not look).
        try folder.write("Fixture.app/Contents/Resources/readme.txt", "changed")
        guard case .invalid = SignatureVerifier.assess(url: app, depth: .full).status else {
            return XCTFail("a modified resource must fail the full check")
        }
        XCTAssertEqual(SignatureVerifier.assess(url: app, depth: .quick).status, .adhoc)
    }

    func testCapsAndDamage() throws {
        let folder = try FixtureFolder()
        let app = try makeApp(folder)
        var limits = BinaryLimits()
        limits.maxWalkEntries = 3
        limits.maxEmbeddedItems = 1
        let facts = try BundleReader.read(contentsOf: app, limits: limits)
        XCTAssertTrue(facts.size.isPartial)
        XCTAssertEqual(facts.embedded.count, 1)
        XCTAssertTrue(facts.embeddedTruncated)

        // A missing executable, a broken Info.plist, a folder that is not a bundle.
        try folder.write("Missing.app/Contents/Info.plist", Self.plist(id: "x", extra: "<key>CFBundleExecutable</key><string>Gone</string>"))
        let missing = try BundleReader.read(contentsOf: folder.path("Missing.app"))
        XCTAssertNil(missing.executable)
        XCTAssertNotNil(missing.executableProblem)
        XCTAssertNil(missing.isSandboxed)
        try folder.write("Broken.app/Contents/Info.plist", "<plist><dict><key>")
        assertBinaryError(try BundleReader.read(contentsOf: folder.path("Broken.app")))
        try folder.mkdir("Empty.app")
        assertBinaryError(try BundleReader.read(contentsOf: folder.path("Empty.app")), matching: {
            if case .notRecognized = $0 { true } else { false }
        })
        // An executable name that tries to leave the bundle is not followed.
        try folder.write("Escape.app/Contents/Info.plist", Self.plist(id: "x", extra: "<key>CFBundleExecutable</key><string>../../../../bin/ls</string>"))
        XCTAssertNil(try BundleReader.read(contentsOf: folder.path("Escape.app")).executableURL)
    }

    /// Read-only: a system app's facts, as a check against real-world Info.plists and universal binaries.
    func testSystemAppReadOnly() throws {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        guard FileManager.default.fileExists(atPath: calculator.path) else { throw XCTSkip("Calculator.app is not here") }
        let clock = ContinuousClock()
        var facts: BundleFacts?
        let time = try clock.measure { facts = try BundleReader.read(contentsOf: calculator) }
        print("VitrineBinary perf: Calculator.app bundle facts \(time)")
        let read = try XCTUnwrap(facts)
        XCTAssertEqual(read.info.identifier, "com.apple.calculator")
        XCTAssertTrue(read.architectures.contains("arm64e") || read.architectures.contains("arm64"))
        XCTAssertEqual(read.isSandboxed, true)
        XCTAssertNotNil(read.info.shortVersion)
        XCTAssertLessThan(time, .seconds(2))
    }
}
