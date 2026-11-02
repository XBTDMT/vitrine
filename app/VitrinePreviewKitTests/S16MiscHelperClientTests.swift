import Foundation
import os
import XCTest
@testable import VitrinePreviewKit
import VitrineHelperKit

/// S-16 F59: the previews require the helper they reach to be signed by their own certificate (G-33's pin, mirrored),
/// and send nothing when they cannot require it. The helper here is a stand-in served by an anonymous listener in
/// this process, so the peer's signature is this test runner's own. roadmap: S-16
@MainActor
final class S16MiscHelperClientTests: XCTestCase {
    /// A stand-in helper that records every path it is handed.
    final class FakeHelper: NSObject, VitrineHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
        let received = OSAllocatedUnfairLock(initialState: [String]())
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = HelperService.interface()
            connection.exportedObject = self
            connection.resume()
            return true
        }
        func note(_ s: String) { received.withLock { $0.append(s) } }
        func ping(reply: @escaping @Sendable (Int, String) -> Void) { reply(HelperService.protocolVersion, "fake") }
        func applications(forOpening path: String, reply: @escaping @Sendable ([[String]]) -> Void) { note(path); reply([]) }
        func open(_ path: String, withApplication appPath: String, reply: @escaping @Sendable (String?) -> Void) { note(path); reply(nil) }
        func reveal(_ path: String, reply: @escaping @Sendable (String?) -> Void) { note(path); reply(nil) }
        func openLink(_ link: String, reply: @escaping @Sendable (String?) -> Void) { note(link); reply(nil) }
        func open(_ path: String, atLine line: Int, editor: String, reply: @escaping @Sendable (String?) -> Void) { note(path); reply(nil) }
        func installedEditors(reply: @escaping @Sendable ([String]) -> Void) { reply([]) }
        func extract(member: String, fromArchive path: String, reply: @escaping @Sendable (String?, String?) -> Void) { note(path); reply(nil, nil) }
        func canSummarize(reply: @escaping @Sendable (Bool) -> Void) { reply(true) }
        func summarize(_ text: String, reply: @escaping @Sendable (String?, String?) -> Void) { note(text); reply("summary", nil) }
    }

    var helper: FakeHelper!
    var listener: NSXPCListener!

    override func setUp() async throws {
        helper = FakeHelper()
        listener = NSXPCListener.anonymous()
        listener.delegate = helper
        listener.resume()
    }

    override func tearDown() async throws {
        listener.invalidate()
    }

    func reveal(requirement: String?) async -> String {
        nonisolated(unsafe) let endpoint = listener.endpoint
        return await HelperClient.call(timeout: 3, fallback: "fallback", requirement: requirement,
                                       connect: { NSXPCConnection(listenerEndpoint: endpoint) }) { proxy, done in
            proxy.reveal("/Users/example/Documents/private.txt") { done($0 ?? "answered") }
        }
    }

    func testAPeerSignedByAnotherCertificateIsSentNothing() async {
        let other = HelperService.clientRequirement(leafCertificateDER: Data((0..<64).map { UInt8($0) }))
        let answer = await reveal(requirement: other)
        XCTAssertEqual(answer, "fallback", "an impostor's answer never arrives")
        XCTAssertEqual(helper.received.withLock { $0 }, [], "the previewed file's path never reaches an impostor")
    }

    func testWithoutACertificateNothingIsSent() async {
        let connected = OSAllocatedUnfairLock(initialState: false)
        nonisolated(unsafe) let endpoint = listener.endpoint
        let answer = await HelperClient.call(timeout: 3, fallback: "fallback", requirement: nil,
                                             connect: { connected.withLock { $0 = true }; return NSXPCConnection(listenerEndpoint: endpoint) }) { proxy, done in
            proxy.reveal("/Users/example/Documents/private.txt") { done($0 ?? "answered") }
        }
        XCTAssertEqual(answer, "fallback")
        XCTAssertFalse(connected.withLock { $0 }, "an ad-hoc build does not even connect")
        XCTAssertEqual(helper.received.withLock { $0 }, [])
    }

    func testAPeerSignedByOurOwnCertificateAnswers() async throws {
        // The positive control: the same pin, built from this runner's own certificate, lets the real peer answer.
        // The xctest agent that hosts these tests is signed ad hoc (codesign: Signature=adhoc), so no leaf pin can be
        // built for it; its identifier stands in for "signed by our own certificate" as the requirement it meets.
        let own = HelperService.ownSignerRequirement ?? #"identifier "com.apple.xctest""#
        let answer = await reveal(requirement: own)
        XCTAssertEqual(answer, "answered")
        XCTAssertEqual(helper.received.withLock { $0 }, ["/Users/example/Documents/private.txt"])
    }

    func testTheDefaultRequirementIsTheHelpersOwnPin() {
        XCTAssertEqual(HelperService.ownSignerRequirement,
                       HelperService.clientRequirement(leafCertificateDER: HelperService.ownLeafCertificateDER()))
    }
}
