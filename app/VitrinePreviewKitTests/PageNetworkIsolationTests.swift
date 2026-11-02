import XCTest
import WebKit
import Network
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineSupport

/// G-9's promise, measured: nothing a preview page shows reaches the network, not even a connection. A listener on
/// 127.0.0.1 stands in for the internet; a positive control proves it hears a direct request. Each web-drawn preview
/// (Markdown, SVG, notebook) is given links, a picture and preconnect hints pointing at it, then the person's real
/// actions are delivered to the page as AppKit events in this process: hover, click, and focus plus Return. Any
/// connection, with or without a request after it, fails. Invented content only; the window sits far off screen.
/// roadmap: S-20
@MainActor
final class PageNetworkIsolationTests: XCTestCase {
    final class Listener: @unchecked Sendable {
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

    private var sink: Listener!
    /// Links the guard asked the host to open (X-3); recorded instead of opening a browser.
    private var opened: [String] = []
    private var savedOpener: (@MainActor (String) -> Void)?
    private var base: String { "http://127.0.0.1:\(sink.port)" }

    override func setUp() async throws {
        savedOpener = PageLockdown.linkOpener
        PageLockdown.linkOpener = { [weak self] link in self?.opened.append(link) }
        sink = try Listener()
        await fulfillment(of: [sink.ready], timeout: 5)
        // Positive control: silence later means something only if a direct request is heard.
        _ = try? await URLSession.shared.data(from: URL(string: "\(base)/control")!)
        for _ in 0..<80 where sink.count == 0 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertGreaterThanOrEqual(sink.count, 1, "control: the listener must hear a direct connection")
        try await Task.sleep(for: .milliseconds(300))
    }

    override func tearDown() async throws {
        if let savedOpener { PageLockdown.linkOpener = savedOpener }
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func context(_ dir: URL) -> RenderContext {
        RenderContext(appearance: .light, defaultsSuite: "vt-net-suite", cachesDirectory: dir.appendingPathComponent("caches"))
    }

    /// Hosts the preview's view in a window far off screen (never shown to the person) and returns its web view.
    private func host(_ view: NSView) throws -> (NSWindow, WKWebView) {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.orderFrontRegardless()
        func find(_ v: NSView) -> WKWebView? { (v as? WKWebView) ?? v.subviews.lazy.compactMap(find).first }
        return (window, try XCTUnwrap(find(view), "the preview draws with a web view"))
    }

    /// The centre of the first element matching `selector`, in window coordinates; nil when there is none.
    private func centre(_ selector: String, in web: WKWebView) async throws -> NSPoint? {
        let js = "const e = document.querySelector(s); if (!e) return null; e.scrollIntoView({block: 'center'}); const r = e.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2];"
        guard let xy = try await web.callAsyncJavaScript(js, arguments: ["s": selector], contentWorld: .defaultClient) as? [NSNumber], xy.count == 2 else { return nil }
        try await Task.sleep(for: .milliseconds(100))
        let inWeb = NSPoint(x: xy[0].doubleValue, y: web.isFlipped ? xy[1].doubleValue : web.bounds.height - xy[1].doubleValue)
        return web.convert(inWeb, to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, in window: NSWindow) {
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0) else { return }
        window.sendEvent(e)
    }

    private func key(_ chars: String, code: UInt16, in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            window.sendEvent(e)
        }
    }

    /// Connections the listener heard since `before`, after giving WebKit time to act.
    private func heard(since before: Int) async throws -> Int {
        try await Task.sleep(for: .milliseconds(900))
        return sink.count - before
    }

    /// Delivers hover, click and keyboard activation to the link and reports each phase's connections.
    private func exercise(_ name: String, web: WKWebView, window: NSWindow, link selector: String, loadedBefore: Int) async throws -> [String: Int] {
        var phases = ["load": try await heard(since: loadedBefore)]
        // No element may still hold an address that leaves the page (G-27's guard), in any frame we can read.
        let live = try await web.callAsyncJavaScript(
            "return Array.from(document.querySelectorAll('[href],[action],[formaction]')).map(e => e.getAttribute('href') ?? e.getAttribute('action') ?? e.getAttribute('formaction')).filter(v => v.startsWith(b));",
            arguments: ["b": base], contentWorld: .defaultClient) as? [String]
        XCTAssertEqual(live ?? ["?"], [], "\(name): addresses outside the page are parked, not live")
        guard let p = try await centre(selector, in: web) else {
            XCTFail("\(name): the page has no element for \(selector)")
            return phases
        }
        var before = sink.count
        mouse(.mouseMoved, at: p, in: window)
        try await Task.sleep(for: .milliseconds(200))
        mouse(.mouseMoved, at: NSPoint(x: p.x + 1, y: p.y), in: window)
        phases["hover"] = try await heard(since: before)

        before = sink.count
        mouse(.leftMouseDown, at: p, in: window)
        mouse(.leftMouseUp, at: p, in: window)
        phases["click"] = try await heard(since: before)

        before = sink.count
        _ = try? await web.callAsyncJavaScript("const e = document.querySelector(s); if (e && e.focus) e.focus(); return true;",
                                               arguments: ["s": selector], contentWorld: .defaultClient)
        window.makeFirstResponder(web)
        key("\r", code: 36, in: window)
        phases["keyboard"] = try await heard(since: before)

        before = sink.count
        _ = try? await web.callAsyncJavaScript("const e = document.querySelector(s); if (e) e.click(); return true;",
                                               arguments: ["s": selector], contentWorld: .page)
        phases["scripted click"] = try await heard(since: before)
        print("PageNetworkIsolation \(name):", phases.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        return phases
    }

    private func assertSilent(_ name: String, _ phases: [String: Int], file: StaticString = #filePath, line: UInt = #line) {
        for (phase, n) in phases.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(n, 0, "\(name) · \(phase): \(n) connection(s) reached the listener", file: file, line: line)
        }
    }

    func testMarkdownPageOpensNoConnection() async throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("README.md")
        try """
        # Links

        <link rel="preconnect" href="\(base)/preconnect">
        <link rel="dns-prefetch" href="\(base)/prefetch">

        A [plain link](\(base)/plain) and an autolink <\(base)/auto>.

        ![picture](\(base)/picture.png)

        <a id="raw" href="\(base)/raw">raw HTML link</a>
        """.write(to: url, atomically: true, encoding: .utf8)
        let before = sink.count
        let preview = try await MarkdownRenderer().render(url: url, kind: .markdown(.commonMark), context: context(dir))
        let (window, web) = try host(preview.view)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        let phases = try await exercise("markdown", web: web, window: window, link: "a[href$='/plain'], a[data-vitrine-href$='/plain']", loadedBefore: before)
        assertSilent("markdown", phases)
        XCTAssertTrue(opened.contains("\(base)/plain"), "activating the parked link asks the host to open it (X-3): \(opened)")
    }

    func testSVGPageOpensNoConnection() async throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("badge.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="600" height="400">
          <a id="go" href="\(base)/svg-link"><rect x="100" y="100" width="400" height="200" fill="#3a7"/></a>
          <image href="\(base)/svg-picture.png" x="0" y="0" width="10" height="10"/>
        </svg>
        """.write(to: url, atomically: true, encoding: .utf8)
        let before = sink.count
        let preview = try await SVGRenderer().render(url: url, kind: .svg, context: context(dir))
        let (window, web) = try host(preview.view)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        // The picture is an <img> (G-12), so its own links can never be activated; the click lands on the picture.
        let phases = try await exercise("svg", web: web, window: window, link: "img", loadedBefore: before)
        assertSilent("svg", phases)
    }

    func testNotebookPageOpensNoConnection() async throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("links.ipynb")
        let cell = "A [notebook link](\(base)/nb-link) and ![p](\(base)/nb-picture.png)"
        let notebook: [String: Any] = [
            "nbformat": 4, "nbformat_minor": 5, "metadata": [:],
            "cells": [["cell_type": "markdown", "metadata": [:], "source": [cell]]],
        ]
        try JSONSerialization.data(withJSONObject: notebook).write(to: url)
        let before = sink.count
        let preview = try await NotebookRenderer().render(url: url, kind: .code(language: "ipynb"), context: context(dir))
        let (window, web) = try host(preview.view)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        let phases = try await exercise("notebook", web: web, window: window, link: "a[href$='/nb-link'], a[data-vitrine-href$='/nb-link']", loadedBefore: before)
        assertSilent("notebook", phases)
        XCTAssertTrue(opened.contains("\(base)/nb-link"), "activating the parked link asks the host to open it (X-3): \(opened)")
    }
}
