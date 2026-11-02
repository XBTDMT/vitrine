import Foundation
import OSLog
import VitrineHelperKit

/// The previews' way to VitrineHelper (X-3, G-30/G-31): the sandboxed extensions cannot open apps, reveal files, open
/// links, open an editor at a line, write an extracted member or run the on-device model, so they ask the helper. In
/// the Vitrine window (unsandboxed) the same calls go to the helper too, so every action passes one set of rules.
/// Each call gives up after a timeout and returns a sentence the capsule can show. roadmap: S-10 (X-3), S-21 (A-9)
public enum HelperClient {
    private static let log = Logger(subsystem: "io.github.xbtdmt.vitrine", category: "helper-client")

    /// Running in a sandbox (a Quick Look extension), where only the helper can act.
    public static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    public static var notRunning: String {
        String(localized: "Vitrine Helper is not running. Turn it on in Vitrine's Welcome window or Diagnostics.", bundle: .previewKit,
               comment: "Shown when a preview action needs the background helper and it does not answer.")
    }

    /// A helper refusal code in the person's language; other replies (macOS's own errors) pass through.
    public static func words(_ reply: String?) -> String? {
        guard let reply, let refusal = HelperRules.Refusal.from(reply) else { return reply }
        switch refusal {
        case .missing: return String(localized: "The file is no longer there.", bundle: .previewKit, comment: "Helper refusal: the file was moved or deleted.")
        case .runs: return String(localized: "Vitrine does not open programs, scripts, installers or apps from a preview. Reveal it in Finder instead.", bundle: .previewKit, comment: "Helper refusal: opening this file would run it.")
        case .notAnApp: return String(localized: "That app does not open this kind of file.", bundle: .previewKit, comment: "Helper refusal: the chosen app cannot open the file.")
        case .link: return String(localized: "Only web and mail links open from a preview.", bundle: .previewKit, comment: "Helper refusal: a link that is not http, https or mailto.")
        case .editor: return String(localized: "That editor is not installed.", bundle: .previewKit, comment: "Helper refusal: open at line in an editor that is not on this Mac.")
        case .member: return String(localized: "That file's path leaves the archive.", bundle: .previewKit, comment: "Helper refusal: an archive member whose path points outside the archive.")
        case .tooLarge: return String(localized: "That file is too large to extract from a preview.", bundle: .previewKit, comment: "Helper refusal: an archive member over the extraction limit.")
        case .model: return String(localized: "Apple's on-device model is not available on this Mac.", bundle: .previewKit, comment: "Helper refusal: no summary because the model is missing or off.")
        }
    }

    /// Calls `body` on the helper's proxy; `fallback` when the helper does not answer within `timeout`.
    ///
    /// The helper is reached by name, and a name can be answered by anyone who registers it first, so the connection
    /// requires the peer to be signed by the certificate that signed this process (G-33, the same pin the helper puts
    /// on its callers; S-16 F59). The requirement is checked on what the peer sends, not on what is sent to it
    /// (measured 2026-11-02: a peer that fails it still receives the message; only its reply is dropped). So the
    /// first message is a `ping`, which names no file and carries no text, and the request itself is sent only after
    /// the ping's reply arrives, which happens only when the peer meets the requirement. An impostor gets a ping and
    /// nothing else, and the call gives the fallback. With no requirement (an ad-hoc build has no certificate to pin)
    /// nothing is sent at all: the call fails closed with the fallback.
    static func call<T: Sendable>(timeout: TimeInterval, fallback: T, service: String = HelperService.machServiceName,
                                  requirement: String? = HelperService.ownSignerRequirement,
                                  _ body: @escaping @Sendable (VitrineHelperProtocol, @escaping @Sendable (T) -> Void) -> Void) async -> T {
        await call(timeout: timeout, fallback: fallback, requirement: requirement,
                   connect: { NSXPCConnection(machServiceName: service, options: []) }, body)
    }

    /// The same over any connection (the tests use an anonymous listener's).
    static func call<T: Sendable>(timeout: TimeInterval, fallback: T, requirement: String?, connect: @Sendable () -> NSXPCConnection,
                                  _ body: @escaping @Sendable (VitrineHelperProtocol, @escaping @Sendable (T) -> Void) -> Void) async -> T {
        guard let requirement else {
            log.error("helper call not made: this build has no signing certificate to require of the helper")
            return fallback
        }
        let connection = connect()
        connection.remoteObjectInterface = HelperService.interface()
        connection.setCodeSigningRequirement(requirement)
        // A peer that went away after the ping (and whatever answers next) is not the one the ping verified.
        let interrupted = OSAllocatedUnfairLock(initialState: false)
        connection.interruptionHandler = { interrupted.withLock { $0 = true } }
        connection.resume()
        defer { connection.invalidate() }
        return await withCheckedContinuation { done in
            let once = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ value: T) {
                if once.withLock({ let first = !$0; $0 = true; return first }) { done.resume(returning: value) }
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                log.error("helper call failed: \((error as NSError).code, privacy: .public)")
                finish(fallback)
            }) as? VitrineHelperProtocol else { return finish(fallback) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(fallback) }
            // An NSXPC proxy may be messaged from any thread.
            nonisolated(unsafe) let verified = proxy
            proxy.ping { _, _ in
                guard !interrupted.withLock({ $0 }), !once.withLock({ $0 }) else { return }
                body(verified, finish)
            }
        }
    }

    /// nil when done; otherwise why not.
    public static func open(_ file: URL, with app: URL) async -> String? {
        words(await call(timeout: 10, fallback: notRunning) { helper, done in helper.open(file.path, withApplication: app.path) { done($0) } })
    }

    public static func reveal(_ file: URL) async -> String? {
        words(await call(timeout: 10, fallback: notRunning) { helper, done in helper.reveal(file.path) { done($0) } })
    }

    public static func openLink(_ link: String) async -> String? {
        words(await call(timeout: 10, fallback: notRunning) { helper, done in helper.openLink(link) { done($0) } })
    }

    public static func open(_ file: URL, atLine line: Int, in editor: HelperRules.Editor) async -> String? {
        words(await call(timeout: 10, fallback: notRunning) { helper, done in helper.open(file.path, atLine: line, editor: editor.rawValue) { done($0) } })
    }

    public static func installedEditors() async -> [HelperRules.Editor] {
        await call(timeout: 3, fallback: [String]()) { helper, done in helper.installedEditors { done($0) } }
            .compactMap(HelperRules.Editor.init(rawValue:))
    }

    public static func applications(forOpening file: URL) async -> [(url: URL, name: String, isDefault: Bool)] {
        await call(timeout: 3, fallback: [[String]]()) { helper, done in helper.applications(forOpening: file.path) { done($0) } }
            .compactMap { row in row.count == 3 ? (URL(fileURLWithPath: row[0]), row[1], row[2] == "1") : nil }
    }

    /// The extracted file's location, or why not.
    public static func extract(member: String, from archive: URL) async -> (destination: URL?, error: String?) {
        let pair = await call(timeout: 60, fallback: [String?](arrayLiteral: nil, notRunning)) { helper, done in
            helper.extract(member: member, fromArchive: archive.path) { done([$0, $1]) }
        }
        return (pair[0].map { URL(fileURLWithPath: $0) }, words(pair[1]))
    }

    /// Whether the summary can be offered: the helper answers and the model is ready (A-9).
    public static func canSummarize() async -> Bool {
        await call(timeout: 3, fallback: false) { helper, done in helper.canSummarize { done($0) } }
    }

    /// The summary, or why not (A-9).
    public static func summarize(_ text: String) async -> (summary: String?, error: String?) {
        let pair = await call(timeout: 45, fallback: [String?](arrayLiteral: nil, notRunning)) { helper, done in
            // Cut here as well as in the helper: no more of the document leaves this process than the model reads.
            helper.summarize(HelperRules.summaryInput(text)) { done([$0, $1]) }
        }
        return (pair[0], words(pair[1]))
    }
}
