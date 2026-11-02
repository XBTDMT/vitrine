// The parts that only the system can judge, run for real on temp files: Security's static code check against a
// requirement, hdiutil's read-only attach, and the relaunch helper's rollback. No network, no Keychain, no real install.
import Foundation
import Testing
@testable import VitrineUpdate

@Suite(.serialized) struct SystemIntegrationTests {
    /// A real, ad-hoc-signed app bundle: a copy of /usr/bin/true as its executable.
    static func signedProbe(in folder: URL, options: [String] = ["--options", "runtime"], entitlements: URL? = nil) throws -> URL {
        let app = folder.appending(path: "Probe.app", directoryHint: .isDirectory)
        let macOS = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: macOS.appending(path: "Probe"))
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.vitrine-probe", "CFBundleExecutable": "Probe",
                                    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "7"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        var args = ["--force", "--sign", "-"] + options
        if let entitlements { args += ["--entitlements", entitlements.path] }
        #expect(try T.run("/usr/bin/codesign", args + [app.path]) == 0, "codesign could sign the probe")
        return app
    }

    static let ownIdentifierOnly = #"identifier "com.example.vitrine-probe""#
    /// The probe's identifier, but a leaf certificate it does not have (what a self-signed Vitrine's requirement looks like).
    static let someoneElse = #"identifier "com.example.vitrine-probe" and certificate leaf = H"0123456789abcdef0123456789abcdef01234567""#

    @Test func aBundleMeetingTheRequirementPasses() throws {
        // Positive control: the same check can pass, so the refusals below are the requirement's doing.
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try Self.signedProbe(in: folder)
        #expect(throws: Never.self) { try SecCodeAppVerifier(requirement: Self.ownIdentifierOnly).verify(app) }
    }

    @Test func aBundleNotMeetingTheRequirementIsRefused() throws {
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try Self.signedProbe(in: folder)
        #expect(throws: UpdateError.requirementNotMet) { try SecCodeAppVerifier(requirement: Self.someoneElse).verify(app) }
    }

    @Test func anAlteredBundleIsRefused() throws {
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try Self.signedProbe(in: folder)
        let plist = app.appending(path: "Contents/Info.plist")
        var data = try Data(contentsOf: plist)
        data.append(contentsOf: Array("<!-- -->".utf8))
        try data.write(to: plist)
        #expect {
            try SecCodeAppVerifier(requirement: Self.ownIdentifierOnly).verify(app)
        } throws: { error in
            if case .signatureInvalid = error as? UpdateError { return true }
            return false
        }
    }

    @Test func aBuildWithoutTheHardenedRuntimeIsRefused() throws {
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try Self.signedProbe(in: folder, options: [])
        #expect(throws: UpdateError.unsafeBuild("hardened runtime off")) { try SecCodeAppVerifier(requirement: Self.ownIdentifierOnly).verify(app) }
    }

    @Test func aBuildThatTurnsLibraryValidationOffIsRefused() throws {
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entitlements = folder.appending(path: "e.plist")
        try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.cs.disable-library-validation": true], format: .xml, options: 0)
            .write(to: entitlements)
        let app = try Self.signedProbe(in: folder, entitlements: entitlements)
        #expect(throws: UpdateError.unsafeBuild("com.apple.security.cs.disable-library-validation")) {
            try SecCodeAppVerifier(requirement: Self.ownIdentifierOnly).verify(app)
        }
    }

    @Test func hdiutilAttachesReadOnlyUnderTheUpdateFolder() async throws {
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "src", directoryHint: .isDirectory)
        try T.makeApp(at: source.appending(path: "Vitrine.app"), version: "1.1.0", build: "7", marker: "new")
        let image = folder.appending(path: "test.dmg")
        #expect(try T.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "VitrineTest", "-srcfolder", source.path,
                                              "-format", "UDZO", image.path]) == 0)
        let mountRoot = folder.appending(path: "mount", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let mounter = HdiutilMounter()
        let point = try await mounter.attach(image, under: mountRoot)
        let app = try UpdateInstaller.singleApp(in: point)
        #expect(T.marker(of: app) == "new")
        #expect((try? point.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true)
        #expect(!FileManager.default.isWritableFile(atPath: app.path))
        await mounter.detach(point)
        #expect(!FileManager.default.fileExists(atPath: app.path), "detached")
    }

    @Test func theInstallersOwnMountFolderCanBeRead() async throws {
        // G-21: macOS 27 refuses to read a disk image mounted inside the item-replacement folder (TemporaryItems), so the
        // installer reported "app missing" on a real Mac. This mounts where the installer mounts, not in a test folder.
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "src", directoryHint: .isDirectory)
        try T.makeApp(at: source.appending(path: "Vitrine.app"), version: "1.1.0", build: "7", marker: "new")
        let image = folder.appending(path: "test.dmg")
        #expect(try T.run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "VitrineTest", "-srcfolder", source.path,
                                              "-format", "UDZO", image.path]) == 0)
        let mountRoot = try UpdateInstaller.privateMountFolder()
        defer { try? FileManager.default.removeItem(at: mountRoot) }
        let mounter = HdiutilMounter()
        let point = try await mounter.attach(image, under: mountRoot)
        let found = Result { () throws(UpdateError) in try UpdateInstaller.singleApp(in: point) }
        let marker = (try? found.get()).map(T.marker(of:))
        await mounter.detach(point)
        #expect(throws: Never.self) { try found.get() }
        #expect(marker == "new")
    }

    // MARK: Relaunch helper

    static func runHelper(app: URL, rollback: URL, opener: String) throws {
        let finished = Process()
        finished.executableURL = URL(filePath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()   // a pid that has already exited
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", Relauncher.script, "test", String(finished.processIdentifier), app.path, rollback.path, opener]
        try p.run()
        p.waitUntilExit()
    }

    @Test func theHelperKeepsTheNewAppWhenItOpens() throws {
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try T.makeApp(at: folder.appending(path: "Vitrine.app"), version: "1.1.0", build: "7", marker: "new")
        let rollback = try T.makeApp(at: folder.appending(path: "work/Vitrine.app"), version: "1.0.0", build: "5", marker: "old")
        try Self.runHelper(app: app, rollback: rollback, opener: "/usr/bin/true")
        #expect(T.marker(of: app) == "new")
        #expect(T.marker(of: rollback) == "old", "the rollback stays until the new app settles it")
    }

    @Test func theHelperPutsThePreviousAppBackWhenTheNewOneCannotOpen() throws {
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try T.makeApp(at: folder.appending(path: "Vitrine.app"), version: "1.1.0", build: "7", marker: "new")
        let rollback = try T.makeApp(at: folder.appending(path: "work/Vitrine.app"), version: "1.0.0", build: "5", marker: "old")
        try Self.runHelper(app: app, rollback: rollback, opener: "/usr/bin/false")
        #expect(T.marker(of: app) == "old")
        #expect(!FileManager.default.fileExists(atPath: rollback.path))
        #expect(!FileManager.default.fileExists(atPath: rollback.path + ".failed"))
    }
}
