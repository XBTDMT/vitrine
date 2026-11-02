import XCTest
import Network
import WebKit
@testable import VitrinePreviewKit

/// G-10 B: web images load only on "Load once", fetched by the extension (never the page), images only. A tiny
/// HTTP server on 127.0.0.1 stands in for the web; nothing leaves the Mac.
@MainActor
final class RemoteImagesTests: XCTestCase {
    /// Serves `/a.png` (a 1×1 PNG), `/page.png` (HTML pretending), and 404 for anything else; records each path.
    private final class TinyServer: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var _paths: [String] = []
        var paths: [String] { lock.withLock { _paths } }
        let ready = XCTestExpectation(description: "server ready")
        static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

        init() throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] c in
                guard let server = self else { c.cancel(); return }
                c.start(queue: .global())
                c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
                    server.record(path)
                    let (status, type, body): (String, String, Data) = switch path {
                    case "/a.png": ("200 OK", "image/png", TinyServer.png)
                    case "/page.png": ("200 OK", "text/html", Data("<script>alert(1)</script>".utf8))
                    default: ("404 Not Found", "text/plain", Data("no".utf8))
                    }
                    let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
                }
            }
            listener.stateUpdateHandler = { [ready] state in if case .ready = state { ready.fulfill() } }
            listener.start(queue: .global())
        }
        var port: UInt16 { listener.port?.rawValue ?? 0 }
        func record(_ path: String) { lock.withLock { _paths.append(path) } }
        deinit { listener.cancel() }
    }

    func testFindsTheFilesOwnRemoteImages() {
        let html = #"<img src="https://a.example/x.png"><img src="//b.example/y.svg"><img src="local.png"><img src="https://a.example/x.png"><img src="ftp://c.example/z.png">"#
        XCTAssertEqual(RemoteImages.images(inHTML: html).map(\.src), ["https://a.example/x.png", "//b.example/y.svg"])
        XCTAssertEqual(RemoteImages.images(inHTML: html).last?.url.absoluteString, "https://b.example/y.svg")
        let many = (1...30).map { "<img src=\"https://a.example/\($0).png\">" }.joined()
        XCTAssertEqual(RemoteImages.images(inHTML: many).count, RemoteImages.maxImages)
    }

    func testLoadOnceFetchesOnlyOnClickAndOnlyImages() async throws {
        let server = try TinyServer()
        await fulfillment(of: [server.ready], timeout: 5)
        let base = "http://127.0.0.1:\(server.port)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("r.md")
        try "# R\n\n![shot](\(base)/a.png) ![gone](\(base)/missing.png) ![fake](\(base)/page.png)\n".write(to: url, atomically: true, encoding: .utf8)
        let preview = try await MarkdownRenderer().render(url: url, kind: .markdown(.commonMark),
            context: RenderContext(appearance: .light, defaultsSuite: "vt-remote", cachesDirectory: dir.appendingPathComponent("c")))
        let web = try XCTUnwrap(preview.view as? WKWebView)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(server.paths, [], "nothing is fetched before the click")
        let bar = try await web.evaluateJavaScript("document.querySelector('.remote-bar b').textContent") as? String
        XCTAssertEqual(bar, "3 images are not loaded")

        _ = try await web.evaluateJavaScript("document.querySelector('.remote-bar button').click(); true")
        var loaded = 0
        for _ in 0..<80 {
            loaded = (try await web.evaluateJavaScript("document.querySelectorAll('img[src^=\"vitrine://remote/\"]').length") as? Int) ?? 0
            if loaded > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(loaded, 1, "only the real image is shown")
        try await Task.sleep(for: .milliseconds(200))
        let width = try await web.evaluateJavaScript("document.querySelector('img[src^=\"vitrine://remote/\"]').naturalWidth") as? Int
        XCTAssertEqual(width, 1, "the bytes reached the page through vitrine://remote/")
        XCTAssertEqual(Set(server.paths), ["/a.png", "/missing.png", "/page.png"], "each named image was asked for once, by the extension")
        XCTAssertEqual(server.paths.count, 3)
        let after = try await web.evaluateJavaScript("document.querySelector('.remote-bar b').textContent") as? String
        XCTAssertEqual(after, "2 images could not be loaded", "the 404 and the HTML pretending to be an image")
        let button = try await web.evaluateJavaScript("document.querySelectorAll('.remote-bar button').length") as? Int
        XCTAssertEqual(button, 0, "once means once")
    }
}
