// Checks the feed and installs a verified update (G-21). Order of an install, each step a gate:
//   1. Vitrine can replace itself where it is (writable, not translocated, not on the disk image).
//   2. Download the disk image into a private folder on the app's own volume; size and SHA-256 must equal the signed
//      manifest's (the download is capped at the manifest's size while it streams).
//   3. Attach it read-only (no Finder, no auto-open) under a private folder in the temporary directory (G-21: never in
//      the work folder, whose mounts macOS 27 will not let Vitrine read), copy the one app out, detach.
//   4. Verify the COPY (what will be installed, not what was mounted): valid signature meeting the running app's own
//      designated requirement, hardened runtime, no exceptions; same bundle id; exactly the manifest's version, newer.
//   5. Swap it with the installed app in one atomic rename (`renamex_np` RENAME_SWAP; FileManager.replaceItemAt where
//      the volume cannot swap). The previous app stays in the private folder as the rollback copy.
//   6. Record the pending install; the relaunch helper opens the new app, and puts the rollback back if it cannot.
//      The new app, once running, deletes the rollback (`settlePendingInstall`).
// Any failure before step 5 leaves the installed app untouched and returns the reason.
public import Foundation
import Darwin

/// Where and what the running app is.
public struct InstalledApp: Sendable {
    public var bundleURL: URL
    public var bundleIdentifier: String
    public var version: AppVersion

    public init(bundleURL: URL, bundleIdentifier: String, version: AppVersion) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.version = version
    }

    /// The running app, from its own bundle. Nil outside an app bundle (tests, the CLI) or with a malformed version.
    public static func running(_ bundle: Bundle = .main) -> InstalledApp? {
        guard bundle.bundleURL.pathExtension == "app", let id = bundle.bundleIdentifier,
              let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let version = AppVersion(marketing: short, build: build) else { return nil }
        return InstalledApp(bundleURL: bundle.bundleURL, bundleIdentifier: id, version: version)
    }
}

/// What a finished install leaves for the relaunch.
public struct PreparedRelaunch: Equatable, Sendable {
    /// The installed path, now holding the new app.
    public var app: URL
    /// The previous app, kept until the new one runs.
    public var rollback: URL
    public var version: String
}

/// The record the new app reads at launch to delete the rollback copy.
struct PendingInstall: Codable, Equatable {
    var version: String
    var build: String
    var app: String
    var rollbackFolder: String
}

public enum InstallStep: Equatable, Sendable { case downloading, verifying, installing }

public final class UpdateInstaller: Sendable {
    public let installed: InstalledApp
    public let feedURL: URL
    public let verifier: FeedVerifier
    let transport: any UpdateTransport
    let mounter: any DiskImageMounting
    let codeVerifier: any AppSignatureVerifying
    /// Private (0700) folder for the pending-install record and the last-check time.
    let stateFolder: URL
    /// The private work folder on the app's volume; injectable for tests.
    let workFolder: @Sendable (URL) throws -> URL
    /// The private folder the disk image is mounted under (G-21); injectable for tests.
    let mountFolder: @Sendable () throws -> URL

    public init(installed: InstalledApp, feedURL: URL, trust: UpdateTrust, transport: any UpdateTransport,
                mounter: any DiskImageMounting = HdiutilMounter(), codeVerifier: any AppSignatureVerifying, stateFolder: URL,
                systemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                workFolder: @escaping @Sendable (URL) throws -> URL = UpdateInstaller.privateFolder(onVolumeOf:),
                mountFolder: @escaping @Sendable () throws -> URL = UpdateInstaller.privateMountFolder) {
        self.installed = installed
        self.feedURL = feedURL
        self.verifier = FeedVerifier(trust: trust, bundleIdentifier: installed.bundleIdentifier, current: installed.version,
                                     systemVersion: systemVersion)
        self.transport = transport
        self.mounter = mounter
        self.codeVerifier = codeVerifier
        self.stateFolder = stateFolder
        self.workFolder = workFolder
        self.mountFolder = mountFolder
    }

    // MARK: Check

    /// Fetches and verifies the feed. The only request a check makes.
    public func check() async throws(UpdateError) -> UpdateCheckOutcome {
        guard feedURL.scheme?.lowercased() == "https" else { throw .insecureURL(feedURL.absoluteString) }
        let data = try await transport.fetch(feedURL, limit: FeedVerifier.maxFeedBytes)
        return try verifier.evaluate(feed: data)
    }

    // MARK: Install

    public func install(_ manifest: UpdateManifest, progress: @Sendable (InstallStep) -> Void = { _ in }) async throws(UpdateError) -> PreparedRelaunch {
        // The manifest is re-judged here, so install never trusts a caller's copy blindly.
        guard manifest.bundleIdentifier == installed.bundleIdentifier else { throw .wrongApp(manifest.bundleIdentifier) }
        guard let offered = manifest.appVersion else { throw .manifestInvalid("version") }
        guard installed.version < offered else { throw .notNewer(offered: manifest.version, current: installed.version.marketingString) }
        guard manifest.url.scheme?.lowercased() == "https" else { throw .insecureURL(manifest.url.absoluteString) }
        try Self.checkReplaceable(installed.bundleURL)

        let work: URL
        do { work = try workFolder(installed.bundleURL) } catch { throw .fileSystem("work folder") }
        var keepWork = false
        defer { if !keepWork { try? FileManager.default.removeItem(at: work) } }

        progress(.downloading)
        let image = work.appending(path: "update.dmg")
        let got = try await transport.download(manifest.url, to: image, limit: manifest.size)
        guard got.size == manifest.size else { throw .downloadSizeMismatch(expected: manifest.size, got: got.size) }
        guard got.sha256 == manifest.sha256 else { throw .downloadHashMismatch }

        progress(.verifying)
        let staged = work.appending(path: "new", directoryHint: .isDirectory).appending(path: installed.bundleURL.lastPathComponent)
        do { try FileAtomics.makePrivateDirectory(staged.deletingLastPathComponent()) } catch { throw .fileSystem("work folders") }
        let mountRoot: URL
        do { mountRoot = try mountFolder() } catch { throw .fileSystem("mount folder") }
        defer { try? FileManager.default.removeItem(at: mountRoot) }
        let mountPoint = try await mounter.attach(image, under: mountRoot)
        let copied: Result<Void, UpdateError>
        do {
            let app = try Self.singleApp(in: mountPoint)
            try FileManager.default.copyItem(at: app, to: staged)
            copied = .success(())
        } catch let error as UpdateError {
            copied = .failure(error)
        } catch {
            copied = .failure(.fileSystem("copy from disk image"))
        }
        await mounter.detach(mountPoint)
        try copied.get()

        try codeVerifier.verify(staged)
        try Self.checkBundle(staged, manifest: manifest, installed: installed)

        progress(.installing)
        try Self.swap(staged, with: installed.bundleURL)
        // `staged` now holds the previous app: the rollback copy.
        keepWork = true
        let record = PendingInstall(version: manifest.version, build: manifest.build, app: installed.bundleURL.path,
                                    rollbackFolder: work.path)
        do {
            try FileAtomics.write(try JSONEncoder().encode(record), to: pendingRecordURL, mode: .privateToUser)
        } catch {
            UpdateLog.logger.error("update: pending record not written; the rollback copy stays in the temporary folder")
        }
        UpdateLog.logger.notice("update: installed \(manifest.version, privacy: .public) (\(manifest.build, privacy: .public))")
        return PreparedRelaunch(app: installed.bundleURL, rollback: staged, version: manifest.version)
    }

    // MARK: After the relaunch

    var pendingRecordURL: URL { stateFolder.appending(path: "pending-install.json") }

    /// Called by the app at launch: if this launch is the version a pending install put in place, the rollback copy is
    /// no longer needed and is deleted. Returns the version that was just installed, if any.
    @discardableResult
    public func settlePendingInstall() -> String? {
        guard let data = try? Data(contentsOf: pendingRecordURL),
              let record = try? JSONDecoder().decode(PendingInstall.self, from: data) else { return nil }
        guard let recorded = AppVersion(marketing: record.version, build: record.build), installed.version == recorded,
              record.app == installed.bundleURL.path else {
            // An older copy is running (the helper rolled back, or the user opened another copy): keep the files for
            // the next launch of the new version, unless they are gone.
            if !FileManager.default.fileExists(atPath: record.rollbackFolder) { try? FileManager.default.removeItem(at: pendingRecordURL) }
            return nil
        }
        try? FileManager.default.removeItem(atPath: record.rollbackFolder)
        try? FileManager.default.removeItem(at: pendingRecordURL)
        return record.version
    }

    // MARK: Last check (for the once-a-day schedule)

    var lastCheckURL: URL { stateFolder.appending(path: "last-check") }

    public var lastCheck: Date? {
        guard let text = try? String(contentsOf: lastCheckURL, encoding: .utf8), let t = TimeInterval(text) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    public func recordCheck(at date: Date) {
        try? FileAtomics.write(Data(String(date.timeIntervalSince1970).utf8), to: lastCheckURL, mode: .privateToUser)
    }

    // MARK: Steps

    /// A private (0700) folder Foundation picks on the same volume as `app`, so the final rename is atomic.
    @Sendable public static func privateFolder(onVolumeOf app: URL) throws -> URL {
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        try FileAtomics.makePrivateDirectory(folder)
        return folder
    }

    /// Where the downloaded disk image is mounted (G-21): a fresh private (0700) folder in the per-user temporary
    /// directory, removed once the image is detached. Not in the work folder: macOS 27 refuses to read a disk image
    /// mounted inside the item-replacement folder (TemporaryItems), and every install then stopped as "app missing".
    @Sendable public static func privateMountFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "io.github.xbtdmt.vitrine-update-mount-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileAtomics.makePrivateDirectory(folder)
        return folder
    }

    static func checkReplaceable(_ app: URL) throws(UpdateError) {
        let path = app.path
        if path.contains("/AppTranslocation/") { throw .cannotReplace(String(localized: "it is running from a temporary location; move Vitrine to Applications first", bundle: .module, comment: "Lower-case reason Vitrine cannot replace itself; it fills 'Vitrine can't replace itself here: …'.")) }
        let values = try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if values?.volumeIsReadOnly == true { throw .cannotReplace(String(localized: "it is running from a read-only disk", bundle: .module, comment: "Lower-case reason Vitrine cannot replace itself; it fills 'Vitrine can't replace itself here: …'.")) }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: path) else {
            throw .cannotReplace(String(localized: "you don't have permission to change \(app.deletingLastPathComponent().path)", bundle: .module, comment: "Lower-case reason Vitrine cannot replace itself; it fills 'Vitrine can't replace itself here: …'."))
        }
    }

    /// The one app at the top of the mounted image: a real folder (not a link) ending in ".app".
    static func singleApp(in mountPoint: URL) throws(UpdateError) -> URL {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path) else { throw .appMissingInImage }
        let apps = names.filter { $0.hasSuffix(".app") }.map { mountPoint.appending(path: $0) }
        guard apps.count == 1, let app = apps.first,
              let kind = try? FileManager.default.attributesOfItem(atPath: app.path)[.type] as? FileAttributeType,
              kind == .typeDirectory else { throw .appMissingInImage }
        return app
    }

    /// The staged app is the bundle and exact version the signed manifest announced, and newer than this one.
    static func checkBundle(_ app: URL, manifest: UpdateManifest, installed: InstalledApp) throws(UpdateError) {
        let plistURL = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw .signatureInvalid("Info.plist unreadable")
        }
        let id = plist["CFBundleIdentifier"] as? String ?? "?"
        guard id == installed.bundleIdentifier else { throw .wrongApp(id) }
        let short = plist["CFBundleShortVersionString"] as? String ?? "?"
        let build = plist["CFBundleVersion"] as? String ?? "?"
        guard short == manifest.version, build == manifest.build, let found = AppVersion(marketing: short, build: build) else {
            throw .versionMismatch(expected: "\(manifest.version) (\(manifest.build))", found: "\(short) (\(build))")
        }
        guard installed.version < found else { throw .notNewer(offered: short, current: installed.version.marketingString) }
    }

    /// Exchanges `staged` and `installed` in one step. Afterwards `installed` holds the new app and `staged` the old one.
    static func swap(_ staged: URL, with installed: URL) throws(UpdateError) {
        let result = staged.withUnsafeFileSystemRepresentation { a in
            installed.withUnsafeFileSystemRepresentation { b in
                guard let a, let b else { return Int32(-1) }
                return renamex_np(a, b, UInt32(RENAME_SWAP))
            }
        }
        if result == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else { throw .fileSystem("swap errno \(code)") }
        // A volume without RENAME_SWAP: FileManager's replace (atomic on the same volume), keeping the old app as a
        // backup that is moved straight back to where the rollback copy belongs.
        let backupName = ".vitrine-previous-\(UUID().uuidString).app"
        do {
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged, backupItemName: backupName,
                                                      options: [.withoutDeletingBackupItem])
            try FileManager.default.moveItem(at: installed.deletingLastPathComponent().appending(path: backupName), to: staged)
        } catch {
            throw .fileSystem("replace")
        }
    }
}
