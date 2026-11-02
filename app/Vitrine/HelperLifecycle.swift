import Foundation
import OSLog
import ServiceManagement
import VitrinePreviewKit
import VitrineHelperKit

/// VitrineHelper's life in the app (X-3): whether it is registered and answering, turning it on and off (Welcome and
/// Diagnostics), and the launch check that re-registers it after an update (SP-3: launchd will not start a replaced
/// helper under the old registration). roadmap: S-10 (X-3)
@MainActor
final class HelperLifecycle: ObservableObject {
    static let shared = HelperLifecycle()
    private static let log = Logger(subsystem: "io.github.xbtdmt.vitrine", category: "helper")

    @Published private(set) var state: HelperRegistration.State = .notRegistered
    /// The fingerprint the running helper reported; nil when it did not answer.
    @Published private(set) var answered: String?
    @Published private(set) var lastError: String?

    var service: SMAppService { SMAppService.agent(plistName: HelperService.launchAgentPlistName) }

    static func state(_ status: SMAppService.Status) -> HelperRegistration.State {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    /// The helper inside this app, fingerprinted the way the helper fingerprints itself.
    static var bundledFingerprint: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VitrineHelper")
        return (try? Data(contentsOf: url, options: .mappedIfSafe)).map(HelperRegistration.fingerprint(of:))
    }

    /// Asks the helper for its protocol version and fingerprint; nil when it does not answer within `timeout`.
    /// Not on the main actor: XPC calls the error handler on its own queue, and a main-actor closure there traps.
    /// The reply counts only from a peer signed by this app's own certificate (S-16, the mirror of G-33): a process
    /// that took the service name could otherwise answer with the fingerprint the launch-time reconcile trusts.
    /// macOS drops replies from a peer that fails the requirement. A build with no certificate pins nothing and asks
    /// nothing (the helper answers no such caller anyway).
    nonisolated static func ping(timeout: TimeInterval = 3, service: String = HelperService.machServiceName,
                                 requirement: String? = HelperService.ownSignerRequirement) async -> (version: Int, fingerprint: String)? {
        await ping(timeout: timeout, requirement: requirement, connect: { NSXPCConnection(machServiceName: service, options: []) })
    }

    /// The same over any connection (the tests use an anonymous listener's).
    nonisolated static func ping(timeout: TimeInterval, requirement: String?,
                                 connect: @Sendable () -> NSXPCConnection) async -> (version: Int, fingerprint: String)? {
        guard let requirement else { return nil }
        let connection = connect()
        connection.remoteObjectInterface = HelperService.interface()
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        defer { connection.invalidate() }
        return await withCheckedContinuation { done in
            let once = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ value: (Int, String)?) {
                if once.withLock({ let first = !$0; $0 = true; return first }) { done.resume(returning: value) }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(nil) } as? VitrineHelperProtocol
            proxy?.ping { version, fingerprint in finish((version, fingerprint)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Whether everything that relies on the helper can use it now.
    var isWorking: Bool { state == .enabled && answered != nil }

    func refresh() async {
        state = Self.state(service.status)
        answered = state == .enabled ? await Self.ping()?.fingerprint : nil
    }

    func turnOn() async {
        do { try service.register(); lastError = nil } catch { lastError = error.localizedDescription }
        await refresh()
    }

    func turnOff() async {
        do { try await service.unregister(); lastError = nil } catch { lastError = error.localizedDescription }
        await refresh()
    }

    /// At launch: a helper the person turned on that is stale (another build) or silent is registered again.
    func reconcileAtLaunch() async {
        state = Self.state(service.status)
        let answeredNow = state == .enabled ? await Self.ping()?.fingerprint : nil
        let step = HelperRegistration.launchStep(state: state, answeredFingerprint: answeredNow, bundledFingerprint: Self.bundledFingerprint)
        if step == .reregister {
            Self.log.notice("helper is stale or silent; registering it again")
            let service = self.service
            let error = await Self.reregister(
                unregister: { try? await service.unregister() },
                jobGone: { Self.launchdHasNoJob(HelperService.launchdLabel) },
                register: { try service.register() },
                answers: { await Self.ping() != nil })
            if let error { lastError = error }
        }
        await refresh()
    }

    /// Registers the helper again after an update or a change of signer, and returns the error, if any. Measured
    /// 2026-11-02: launchd drops the old job within half a second of the unregister, but Background Task Management
    /// keeps the old record (it holds the helper's checksum) a few seconds longer; a register inside that window
    /// gives launchd exit 78 EX_CONFIG ("Unable to get updated LWCR" after a signer change). With 5 s of quiet after
    /// the job left, the new helper answered on the first ping. So each cycle waits for the job to go (up to
    /// `settle`), stays quiet for its pause, registers, and gives the helper `answerTries` pings a second apart; a
    /// cycle whose helper stays silent is repeated once with a longer pause.
    static func reregister(unregister: () async -> Void, jobGone: () -> Bool, register: () throws -> Void,
                           answers: () async -> Bool, settle: Duration = .seconds(15),
                           quiet: [Duration] = [.seconds(5), .seconds(12)], answerTries: Int = 8,
                           pause: Duration = .seconds(1)) async -> String? {
        for wait in quiet {
            await unregister()
            let clock = ContinuousClock(), deadline = clock.now + settle
            while !jobGone(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: wait)
            do { try register() } catch { return error.localizedDescription }
            for attempt in 0..<answerTries {
                if await answers() { return nil }
                if attempt < answerTries - 1 { try? await Task.sleep(for: pause) }
            }
        }
        return nil   // registered; refresh() reports that it does not answer
    }

    /// Whether launchd holds no job by this label in the user's GUI domain (`launchctl print` fails for a missing job).
    nonisolated static func launchdHasNoJob(_ label: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "gui/\(getuid())/\(label)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return true }
        task.waitUntilExit()
        return task.terminationStatus != 0
    }
}
