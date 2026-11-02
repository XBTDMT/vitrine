import XCTest
import Network
import WebKit
@testable import VitrinePreviewKit

/// G-9: a Markdown page cannot reach the network even though its extension holds the permission. A listener on
/// 127.0.0.1 stands in for the internet (nothing leaves the Mac): a positive control proves it accepts connections,
/// then a page tries every way out (an image link, raw HTML, fetch, an injected script) and the listener must stay
/// silent. Inline event handlers smuggled in a Markdown file must not run.
@MainActor
final class PageLockdownTests: XCTestCase {
    private final class Listener: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        let ready = XCTestExpectation(description: "listener ready")

        init() throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.lock.withLock { self?._count += 1 }
                connection.cancel()
            }
            listener.stateUpdateHandler = { [ready] state in if case .ready = state { ready.fulfill() } }
            listener.start(queue: .global())
        }

        var port: UInt16 { listener.port?.rawValue ?? 0 }
        deinit { listener.cancel() }
    }

    func testPageCannotReachTheNetwork() async throws {
        let sink = try Listener()
        await fulfillment(of: [sink.ready], timeout: 5)
        let base = "http://127.0.0.1:\(sink.port)"

        // Positive control: the listener does see a direct connection.
        _ = try? await URLSession.shared.data(from: URL(string: "\(base)/control")!)
        for _ in 0..<40 where sink.count == 0 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertGreaterThanOrEqual(sink.count, 1, "control: the listener must accept a direct connection")
        try await Task.sleep(for: .milliseconds(300))   // URLSession retries a dropped connection; let it settle
        let baseline = sink.count

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("leak.md")
        try """
        # Leak attempts

        ![remote](\(base)/markdown-image.png)

        <img src="\(base)/raw-image.png" onerror="window.__pwned = 1">
        """.write(to: url, atomically: true, encoding: .utf8)
        let preview = try await MarkdownRenderer().render(url: url, kind: .markdown(.commonMark),
                                                          context: RenderContext(appearance: .light, defaultsSuite: "vt-lock-\(UUID().uuidString)"))
        let web = try XCTUnwrap(preview.view as? WKWebView)
        let fetched = try await web.callAsyncJavaScript(
            "try { await fetch(u); return 'reached'; } catch (e) { return 'blocked'; }",
            arguments: ["u": "\(base)/fetch"], contentWorld: .page) as? String
        XCTAssertEqual(fetched, "blocked")
        _ = try await web.evaluateJavaScript("var s = document.createElement('script'); s.src = '\(base)/script.js'; document.head.appendChild(s); true")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(sink.count, baseline, "no request from the page may reach the listener")
        let pwned = try await web.evaluateJavaScript("typeof window.__pwned") as? String
        XCTAssertEqual(pwned, "undefined", "an inline handler from the Markdown file must not run")
    }

    func testRuleListCompiles() async throws {
        _ = try await PageLockdown.ruleList()
    }
}
