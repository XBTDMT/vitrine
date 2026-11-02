import XCTest
import VitrineHelperKit

/// The app's ping to a helper that does not answer returns nil from the main actor instead of trapping (exit 133,
/// 2026-11-01), so the launch check can re-register a stale helper. S-16: the ping's answer counts only from a peer
/// signed by the app's own certificate. roadmap: S-10 (X-3), S-16
@MainActor
final class HelperLifecycleTests: XCTestCase {
    /// The xctest host is signed ad hoc, so no leaf pin can be built for it; its identifier stands in for "signed by
    /// our own certificate" where a test needs the call to reach XPC.
    static let hostRequirement = #"identifier "com.apple.xctest""#

    func testPingToASilentServiceIsNilNotACrash() async {
        let answer = await HelperLifecycle.ping(timeout: 2, service: HelperService.appGroup + ".no-such-service",
                                                requirement: Self.hostRequirement)
        XCTAssertNil(answer)
    }

    /// A stand-in that answers every ping with a fingerprint of its choosing.
    final class Impostor: NSObject, NSXPCListenerDelegate, VitrineHelperProtocol, @unchecked Sendable {
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = HelperService.interface()
            connection.exportedObject = self
            connection.resume()
            return true
        }
        func ping(reply: @escaping @Sendable (Int, String) -> Void) { reply(HelperService.protocolVersion, "chosen-by-impostor") }
        func applications(forOpening path: String, reply: @escaping @Sendable ([[String]]) -> Void) { reply([]) }
        func open(_ path: String, withApplication appPath: String, reply: @escaping @Sendable (String?) -> Void) { reply(nil) }
        func reveal(_ path: String, reply: @escaping @Sendable (String?) -> Void) { reply(nil) }
        func openLink(_ link: String, reply: @escaping @Sendable (String?) -> Void) { reply(nil) }
        func open(_ path: String, atLine line: Int, editor: String, reply: @escaping @Sendable (String?) -> Void) { reply(nil) }
        func installedEditors(reply: @escaping @Sendable ([String]) -> Void) { reply([]) }
        func extract(member: String, fromArchive path: String, reply: @escaping @Sendable (String?, String?) -> Void) { reply(nil, nil) }
        func canSummarize(reply: @escaping @Sendable (Bool) -> Void) { reply(false) }
        func summarize(_ text: String, reply: @escaping @Sendable (String?, String?) -> Void) { reply(nil, nil) }
    }

    func ping(requirement: String?) async -> (version: Int, fingerprint: String)? {
        let impostor = Impostor()
        let listener = NSXPCListener.anonymous()
        listener.delegate = impostor
        listener.resume()
        defer { listener.invalidate() }
        nonisolated(unsafe) let endpoint = listener.endpoint
        return await HelperLifecycle.ping(timeout: 3, requirement: requirement, connect: { NSXPCConnection(listenerEndpoint: endpoint) })
    }

    func testAnImpostorsFingerprintIsNotBelieved() async {
        let other = HelperService.clientRequirement(leafCertificateDER: Data((0..<64).map { UInt8($0) }))
        let answer = await ping(requirement: other)
        XCTAssertNil(answer, "a peer not signed by our certificate cannot answer the ping")
    }

    func testAPeerMeetingTheRequirementAnswers() async {
        let answer = await ping(requirement: Self.hostRequirement)
        XCTAssertEqual(answer?.fingerprint, "chosen-by-impostor", "the positive control: the same stand-in answers when it meets the pin")
    }

    func testWithoutACertificateThePingAsksNothing() async {
        let answer = await ping(requirement: nil)
        XCTAssertNil(answer)
    }

    // MARK: Re-registering after an update or a change of signer (S-13)

    final class Steps: @unchecked Sendable {
        let lock = NSLock()
        var log: [String] = []
        var goneAfter: Int
        var answersAfter: Int
        var checks = 0, pings = 0
        init(goneAfter: Int, answersAfter: Int) { self.goneAfter = goneAfter; self.answersAfter = answersAfter }
        func note(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
    }

    func testRegistersOnlyAfterLaunchdDropsTheOldJobThenWaitsForAnAnswer() async {
        let steps = Steps(goneAfter: 3, answersAfter: 2)
        let error = await HelperLifecycle.reregister(
            unregister: { steps.note("unregister") },
            jobGone: { steps.checks += 1; let gone = steps.checks > steps.goneAfter; if gone { steps.note("gone") }; return gone },
            register: { steps.note("register") },
            answers: { steps.pings += 1; return steps.pings > steps.answersAfter },
            settle: .seconds(5), quiet: [.milliseconds(10)], answerTries: 5, pause: .milliseconds(10))
        XCTAssertNil(error)
        XCTAssertEqual(steps.log, ["unregister", "gone", "register"], "register waits until the old job is gone")
        XCTAssertEqual(steps.pings, 3, "the first spawn after a register gets more than one chance to answer")
    }

    func testAJobThatNeverGoesStillRegistersAfterTheSettleTime() async {
        let steps = Steps(goneAfter: .max, answersAfter: 0)
        let start = Date()
        _ = await HelperLifecycle.reregister(
            unregister: {}, jobGone: { false }, register: { steps.note("register") }, answers: { true },
            settle: .milliseconds(600), quiet: [.milliseconds(10)], answerTries: 1, pause: .milliseconds(10))
        XCTAssertEqual(steps.log, ["register"])
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testARegisterErrorIsReturned() async {
        struct Refused: LocalizedError { var errorDescription: String? { "refused by the system" } }
        let error = await HelperLifecycle.reregister(
            unregister: {}, jobGone: { true }, register: { throw Refused() }, answers: { true },
            settle: .seconds(1), quiet: [.milliseconds(10)], answerTries: 1, pause: .milliseconds(10))
        XCTAssertEqual(error, "refused by the system")
    }

    func testItStaysQuietAfterTheJobGoesBeforeRegistering() async {
        let steps = Steps(goneAfter: 0, answersAfter: 0)
        let clock = ContinuousClock()
        var gone: ContinuousClock.Instant?, registered: ContinuousClock.Instant?
        _ = await HelperLifecycle.reregister(
            unregister: {}, jobGone: { gone = gone ?? clock.now; return true }, register: { registered = clock.now },
            answers: { true }, settle: .seconds(1), quiet: [.milliseconds(400)], answerTries: 1, pause: .milliseconds(10))
        let waited = try? XCTUnwrap(registered) - XCTUnwrap(gone)
        XCTAssertGreaterThanOrEqual(waited ?? .zero, .milliseconds(350), "Background Task Management needs a quiet moment after launchd drops the job")
        _ = steps
    }

    func testASilentHelperGetsASecondCycleWithALongerPause() async {
        let steps = Steps(goneAfter: 0, answersAfter: 3)
        _ = await HelperLifecycle.reregister(
            unregister: { steps.note("unregister") }, jobGone: { true }, register: { steps.note("register") },
            answers: { steps.pings += 1; return steps.pings > steps.answersAfter },
            settle: .seconds(1), quiet: [.milliseconds(10), .milliseconds(20)], answerTries: 2, pause: .milliseconds(10))
        XCTAssertEqual(steps.log, ["unregister", "register", "unregister", "register"])
        XCTAssertEqual(steps.pings, 4)
    }

    func testAMissingJobReadsAsGone() {
        XCTAssertTrue(HelperLifecycle.launchdHasNoJob("io.github.xbtdmt.vitrine.no-such-job"))
    }
}

