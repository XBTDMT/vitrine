// The install pipeline with fakes for the network, the disk image and the signature check: every refusal leaves the
// installed app byte-for-byte as it was; a success swaps atomically and keeps a rollback copy until the new app runs.
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import VitrineUpdate

@Suite struct InstallerTests {
    /// A test world: an "installed" 1.0.0 (5) app, a disk image folder holding `image` app, and the installer.
    struct World {
        let root: URL
        let installedApp: URL
        let state: URL
        let mounter: FakeMounter
        let installer: UpdateInstaller
        let image: Data

        init(imageApp: (version: String, build: String, id: String) = ("1.1.0", "7", T.bundleID),
             verifier: FakeCodeVerifier = FakeCodeVerifier(), imageBytes: Data = Data("disk image bytes".utf8),
             servedBytes: Data? = nil) throws {
            root = try T.tempFolder()
            installedApp = try T.makeApp(at: root.appending(path: "Applications/Vitrine.app"), version: "1.0.0", build: "5", marker: "old")
            let volume = root.appending(path: "volume", directoryHint: .isDirectory)
            try T.makeApp(at: volume.appending(path: "Vitrine.app"), id: imageApp.id, version: imageApp.version, build: imageApp.build, marker: "new")
            try FileManager.default.createSymbolicLink(at: volume.appending(path: "Applications"), withDestinationURL: URL(filePath: "/Applications"))
            state = root.appending(path: "state", directoryHint: .isDirectory)
            mounter = FakeMounter(content: volume)
            image = imageBytes
            let work = root.appending(path: "work", directoryHint: .isDirectory)
            let mount = root.appending(path: "mount", directoryHint: .isDirectory)
            installer = UpdateInstaller(
                installed: InstalledApp(bundleURL: installedApp, bundleIdentifier: T.bundleID, version: T.version("1.0.0", "5")),
                feedURL: URL(string: "https://updates.example.com/feed.json")!, trust: UpdateTrust(keys: []),
                transport: FakeTransport(image: servedBytes ?? imageBytes), mounter: mounter, codeVerifier: verifier, stateFolder: state,
                workFolder: { _ in
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    return work
                },
                mountFolder: { [mount] in
                    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    return mount
                })
        }

        var manifest: UpdateManifest { T.manifest(size: Int64(image.count), sha256: T.sha256(image)) }
        var workFolder: URL { root.appending(path: "work") }
        var mountFolder: URL { root.appending(path: "mount") }

        func installedIsUntouched() -> Bool {
            T.marker(of: installedApp) == "old" && !FileManager.default.fileExists(atPath: workFolder.path)
        }
    }

    @Test func aVerifiedUpdateReplacesTheAppAndKeepsARollback() async throws {
        let w = try World()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let steps = Mutex<[InstallStep]>([])
        let prepared = try await w.installer.install(w.manifest) { step in steps.withLock { $0.append(step) } }
        #expect(steps.withLock { $0 } == [.downloading, .verifying, .installing])
        #expect(T.marker(of: w.installedApp) == "new")
        #expect(prepared.app == w.installedApp)
        #expect(T.marker(of: prepared.rollback) == "old", "the previous app is kept until the new one runs")
        #expect(prepared.rollback.path.hasPrefix(w.workFolder.path))
        #expect(w.mounter.detached.withLock { $0.count } == 1, "the disk image is detached")
        #expect(!FileManager.default.fileExists(atPath: w.mountFolder.path), "and its mount folder removed (G-21)")
        #expect(FileManager.default.fileExists(atPath: w.state.appending(path: "pending-install.json").path))
    }

    @Test func theNewAppsFirstLaunchDeletesTheRollback() async throws {
        let w = try World()
        defer { try? FileManager.default.removeItem(at: w.root) }
        _ = try await w.installer.install(w.manifest)
        // The old version launching (a rollback happened) keeps everything.
        #expect(w.installer.settlePendingInstall() == nil)
        #expect(FileManager.default.fileExists(atPath: w.workFolder.path))
        // The new version launching settles it.
        let next = UpdateInstaller(installed: InstalledApp(bundleURL: w.installedApp, bundleIdentifier: T.bundleID, version: T.version("1.1.0", "7")),
                                   feedURL: w.installer.feedURL, trust: UpdateTrust(keys: []), transport: FakeTransport(image: Data()),
                                   mounter: w.mounter, codeVerifier: FakeCodeVerifier(), stateFolder: w.state)
        #expect(next.settlePendingInstall() == "1.1.0")
        #expect(!FileManager.default.fileExists(atPath: w.workFolder.path))
        #expect(!FileManager.default.fileExists(atPath: w.state.appending(path: "pending-install.json").path))
    }

    @Test func aHashMismatchIsRefusedAndNothingChanges() async throws {
        let w = try World(servedBytes: Data("disk image bytez".utf8))   // same size, one byte different
        defer { try? FileManager.default.removeItem(at: w.root) }
        await #expect(throws: UpdateError.downloadHashMismatch) { try await w.installer.install(w.manifest) }
        #expect(w.installedIsUntouched())
        #expect(w.mounter.detached.withLock { $0.isEmpty }, "a bad download is never mounted")
    }

    @Test func aSizeMismatchIsRefusedAndNothingChanges() async throws {
        let w = try World(servedBytes: Data("short".utf8))
        defer { try? FileManager.default.removeItem(at: w.root) }
        await #expect(throws: UpdateError.downloadSizeMismatch(expected: Int64(w.image.count), got: 5)) { try await w.installer.install(w.manifest) }
        #expect(w.installedIsUntouched())
        let long = try World(servedBytes: Data("disk image bytes and more".utf8))
        defer { try? FileManager.default.removeItem(at: long.root) }
        await #expect(throws: UpdateError.downloadSizeMismatch(expected: Int64(long.image.count), got: Int64(long.image.count) + 1)) {
            try await long.installer.install(long.manifest)
        }
        #expect(long.installedIsUntouched())
    }

    @Test func anAppSignedBySomeoneElseIsRefusedAndNothingChanges() async throws {
        let w = try World(verifier: FakeCodeVerifier(failure: .requirementNotMet))
        defer { try? FileManager.default.removeItem(at: w.root) }
        await #expect(throws: UpdateError.requirementNotMet) { try await w.installer.install(w.manifest) }
        #expect(w.installedIsUntouched())
        #expect(w.mounter.detached.withLock { $0.count } == 1)
    }

    @Test func anAppThatIsNotTheAnnouncedVersionIsRefused() async throws {
        let w = try World(imageApp: ("1.0.9", "6", T.bundleID))
        defer { try? FileManager.default.removeItem(at: w.root) }
        await #expect(throws: UpdateError.versionMismatch(expected: "1.1.0 (7)", found: "1.0.9 (6)")) { try await w.installer.install(w.manifest) }
        #expect(w.installedIsUntouched())
    }

    @Test func anotherAppInTheImageIsRefused() async throws {
        let w = try World(imageApp: ("1.1.0", "7", "com.example.other"))
        defer { try? FileManager.default.removeItem(at: w.root) }
        await #expect(throws: UpdateError.wrongApp("com.example.other")) { try await w.installer.install(w.manifest) }
        #expect(w.installedIsUntouched())
    }

    @Test func installRefusesAnOlderOrEqualManifestBeforeDownloading() async throws {
        let w = try World()
        defer { try? FileManager.default.removeItem(at: w.root) }
        for (v, b) in [("1.0.0", "5"), ("0.9.0", "9")] {
            var m = w.manifest
            m.version = v
            m.build = b
            await #expect(throws: UpdateError.notNewer(offered: v, current: "1.0.0")) { try await w.installer.install(m) }
        }
        #expect(w.installedIsUntouched())
    }

    @Test func theSwapIsOneRenameNotACopy() throws {
        let root = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try T.makeApp(at: root.appending(path: "Vitrine.app"), version: "1.0.0", build: "5", marker: "old")
        let staged = try T.makeApp(at: root.appending(path: "work/Vitrine.app"), version: "1.1.0", build: "7", marker: "new")
        let inode = { (url: URL) in (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int) }
        let (oldInode, newInode) = (try inode(installed), try inode(staged))
        try UpdateInstaller.swap(staged, with: installed)
        #expect(T.marker(of: installed) == "new" && T.marker(of: staged) == "old")
        // The very directories changed places: the installed path now names the staged folder's inode, and vice versa.
        #expect(try inode(installed) == newInode)
        #expect(try inode(staged) == oldInode)
    }

    @Test func aReadOnlyOrTranslocatedCopyCannotReplaceItself() throws {
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.checkReplaceable(URL(filePath: "/private/var/folders/xx/AppTranslocation/ABC/d/Vitrine.app"))
        }
        #expect(throws: UpdateError.self) { try UpdateInstaller.checkReplaceable(URL(filePath: "/System/Applications/Calculator.app")) }
    }

    @Test func theImageMustHoldExactlyOneRealApp() throws {
        let root = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: UpdateError.appMissingInImage) { try UpdateInstaller.singleApp(in: root) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Vitrine.app"), withDestinationURL: URL(filePath: "/Applications"))
        #expect(throws: UpdateError.appMissingInImage) { try UpdateInstaller.singleApp(in: root) }
    }

    @Test func theLastCheckTimeIsRemembered() throws {
        let w = try World()
        defer { try? FileManager.default.removeItem(at: w.root) }
        #expect(w.installer.lastCheck == nil)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        w.installer.recordCheck(at: when)
        #expect(w.installer.lastCheck == when)
    }

    @Test func aCheckFetchesOnlyTheFeed() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let root = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = T.manifest()
        let installer = UpdateInstaller(
            installed: InstalledApp(bundleURL: root.appending(path: "Vitrine.app"), bundleIdentifier: T.bundleID, version: T.version("1.0.0", "5")),
            feedURL: URL(string: "https://updates.example.com/feed.json")!, trust: UpdateTrust(keys: [key.publicKey]),
            transport: FakeTransport(feed: try T.feed(manifest, key: key), image: Data()), codeVerifier: FakeCodeVerifier(),
            stateFolder: root, systemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        #expect(try await installer.check() == .available(manifest))
    }
}
