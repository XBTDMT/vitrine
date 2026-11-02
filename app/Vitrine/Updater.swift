// Vitrine's own updates (H-8, G-21: ported from Obscura's G-33, no third-party framework). The checking and installing
// live in VitrineUpdate; this file holds the rules for when to check and what the person sees, and wires them to the
// running app: the public key and feed address from Info.plist, the app's own bundle, and the relaunch.
//
// A build with the placeholder key or feed address (every build until the maintainer creates the release key and the
// release feed exists, S-13) has no updater: `isAvailable` is false, Check for Updates… says updates aren't set up, and
// nothing is ever fetched. roadmap: S-13
import AppKit
import Foundation
import Observation
import VitrinePreviewKit
import VitrineUpdate

/// An update found and held for the person: the menu bar's update banner and Settings › About show it.
struct UpdateOffer: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Found and waiting for Install or Later.
        case ready
        /// Install pressed: downloading, verifying, replacing. Ends with a relaunch or `failed`.
        case installing
        /// Install stopped; the installed app is unchanged. The reason is one plain sentence.
        case failed(reason: String)
    }

    var version: String
    var releaseNotesURL: URL?
    var phase: Phase = .ready
}

/// What one check found.
enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(version: String)
    case available(UpdateOffer)
    case failed(reason: String)
}

/// How an install ended.
enum UpdateInstallResult: Equatable, Sendable {
    case relaunching
    case failed(reason: String)
}

/// The updater behind the coordinator: VitrineUpdate in the app, a fake in tests.
@MainActor
protocol UpdateDriver: AnyObject {
    /// False when this build cannot check at all (no release key or feed address yet).
    var isAvailable: Bool { get }
    var lastCheck: Date? { get }
    func recordCheck(at date: Date)
    func check() async -> UpdateCheckResult
    func install() async -> UpdateInstallResult
}

enum UpdateCopy {
    static var notSetUpTitle: String { String(localized: "Updates aren't set up in this build", comment: "Check for Updates alert title") }
    static var notSetUpBody: String {
        String(localized: "This copy of Vitrine was built without an update signing key and feed, so it can't check for new versions. Download new versions by hand from the project's releases.",
               comment: "Check for Updates alert text when this build cannot check")
    }
    static func upToDateTitle(_ version: String) -> String {
        String(localized: "Vitrine \(version) is up to date", comment: "Check for Updates alert title; the running version")
    }
    static var checkFailedTitle: String { String(localized: "Couldn't check for updates", comment: "Check for Updates alert title") }
    static func availableTitle(_ version: String) -> String {
        String(localized: "Vitrine \(version) is available", comment: "Check for Updates alert title; the new version")
    }
    static var availableBody: String {
        String(localized: "Installing downloads it, checks that it is signed by the same developer as this copy, and relaunches Vitrine.",
               comment: "Check for Updates alert text when an update is available")
    }
    static var install: String { String(localized: "Install", comment: "Check for Updates alert button") }
    static var later: String { String(localized: "Later", comment: "Check for Updates alert button") }
}

/// Decides what the update banner shows, from checks, installs and the person's two buttons.
@MainActor
@Observable
final class UpdateCoordinator {
    static let shared = UpdateCoordinator(driver: AppUpdater.shared)

    /// Settings › About: "Check for updates automatically" (the only network traffic Vitrine makes).
    nonisolated static let automaticKey = "general.updatesCheckAutomatically"
    /// At most one scheduled check a day.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// The offer the menu and Settings show; nil when there is none.
    private(set) var offer: UpdateOffer?
    @ObservationIgnored weak var driver: (any UpdateDriver)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var checking = false

    init(driver: (any UpdateDriver)?, defaults: UserDefaults = VitrineDefaults.shared, now: @escaping () -> Date = Date.init) {
        self.driver = driver
        self.defaults = defaults
        self.now = now
    }

    var isAvailable: Bool { driver?.isAvailable ?? false }
    var checksAutomatically: Bool { defaults.object(forKey: Self.automaticKey) as? Bool ?? true }

    /// A scheduled check: only with automatic checks on, and only once a day. Returns whether it ran. A failure changes
    /// nothing on screen; it is retried at the next opportunity.
    @discardableResult
    func scheduledCheck() async -> Bool {
        guard let driver, driver.isAvailable, checksAutomatically, !checking else { return false }
        if let last = driver.lastCheck, now().timeIntervalSince(last) < Self.checkInterval, last <= now() { return false }
        apply(await runCheck(driver))
        return true
    }

    /// Check for Updates…: always checks now; the caller shows the result. Nil when this build cannot check.
    func checkForUpdates() async -> UpdateCheckResult? {
        guard let driver, driver.isAvailable, !checking else { return nil }
        let result = await runCheck(driver)
        apply(result)
        return result
    }

    /// Install: ready or failed → installing → relaunch, or failed with its reason.
    func install() async {
        guard let driver, var current = offer, current.phase != .installing else { return }
        current.phase = .installing
        offer = current
        switch await driver.install() {
        case .relaunching: break
        case .failed(let reason):
            current.phase = .failed(reason: reason)
            offer = current
        }
    }

    /// Later: the banner goes until the next check reports the update again; an install in progress is not interrupted.
    func dismiss() {
        guard offer?.phase != .installing else { return }
        offer = nil
    }

    private func apply(_ result: UpdateCheckResult) {
        guard offer?.phase != .installing else { return }
        switch result {
        case .available(let found): offer = found
        case .upToDate: offer = nil
        case .failed: break
        }
    }

    private func runCheck(_ driver: any UpdateDriver) async -> UpdateCheckResult {
        checking = true
        defer { checking = false }
        let result = await driver.check()
        driver.recordCheck(at: now())
        return result
    }

    /// Check for Updates… from a menu or a button: checks and says what it found in an alert.
    func checkNowAndTell() {
        Task { @MainActor in
            let alert = NSAlert()
            if let result = await checkForUpdates() {
                switch result {
                case .upToDate(let version): alert.messageText = UpdateCopy.upToDateTitle(version)
                case .available(let found):
                    alert.messageText = UpdateCopy.availableTitle(found.version)
                    alert.informativeText = UpdateCopy.availableBody
                    alert.addButton(withTitle: UpdateCopy.install)
                    alert.addButton(withTitle: UpdateCopy.later)
                case .failed(let reason):
                    alert.messageText = UpdateCopy.checkFailedTitle
                    alert.informativeText = reason
                }
            } else {
                alert.messageText = UpdateCopy.notSetUpTitle
                alert.informativeText = UpdateCopy.notSetUpBody
            }
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn, offer?.phase == .ready { await install() }
        }
    }
}

/// The running app's driver: VitrineUpdate's installer with the key and feed from Info.plist.
@MainActor
final class AppUpdater: UpdateDriver {
    static let shared = AppUpdater()

    /// Info.plist keys, filled from the VITRINE_UPDATE_FEED_URL and VITRINE_UPDATE_PUBLIC_KEY build settings.
    static let feedURLKey = "VitrineUpdateFeedURL"
    static let publicKeyKey = "VitrineUpdatePublicKey"

    private let installer: UpdateInstaller?
    /// The manifest the last successful check found; Install installs exactly this one.
    private var found: UpdateManifest?

    /// The feed address, when it is a real HTTPS address (not the placeholder).
    static var feedURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: feedURLKey) as? String, !text.contains("REPLACE_WITH"),
              let url = URL(string: text), url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    static var trust: UpdateTrust? {
        (Bundle.main.object(forInfoDictionaryKey: publicKeyKey) as? String).flatMap(UpdateTrust.init(base64PublicKey:))
    }

    private init() {
        if let trust = Self.trust, let feed = Self.feedURL, let app = InstalledApp.running(), let state = try? Self.stateFolder() {
            installer = UpdateInstaller(installed: app, feedURL: feed, trust: trust, transport: URLSessionUpdateTransport(),
                                        codeVerifier: RunningAppVerifier(), stateFolder: state)
        } else {
            installer = nil
        }
        // This launch may be the new copy a just-finished install opened: the rollback copy can go.
        _ = installer?.settlePendingInstall()
    }

    /// `~/Library/Application Support/Vitrine/Updates` (0700): the pending-install record and the last check time.
    static func stateFolder() throws -> URL {
        let folder = ContainerBridge.ownDirectory.appending(path: "Updates", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    var isAvailable: Bool { installer != nil }
    var lastCheck: Date? { installer?.lastCheck }
    func recordCheck(at date: Date) { installer?.recordCheck(at: date) }

    func check() async -> UpdateCheckResult {
        guard let installer else { return .failed(reason: UpdateError.notConfigured.reason) }
        do {
            switch try await installer.check() {
            case .upToDate:
                found = nil
                return .upToDate(version: installer.installed.version.marketingString)
            case .available(let manifest):
                found = manifest
                return .available(UpdateOffer(version: manifest.version, releaseNotesURL: manifest.releaseNotesURL))
            }
        } catch {
            return .failed(reason: error.reason)
        }
    }

    func install() async -> UpdateInstallResult {
        guard let installer, let manifest = found else { return .failed(reason: UpdateError.notConfigured.reason) }
        do {
            let prepared = try await installer.install(manifest)
            guard Relauncher.start(prepared) else { return .failed(reason: UpdateError.relaunchFailed.reason) }
            NSApp.terminate(nil)
            return .relaunching
        } catch {
            return .failed(reason: error.reason)
        }
    }
}
