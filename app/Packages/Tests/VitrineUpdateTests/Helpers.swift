// Shared helpers for the updater tests: throwaway keys, temp folders, minimal app bundles, a URL-loading stub.
// Nothing here touches the network, the Keychain or any real Vitrine install.
import CryptoKit
import Foundation
import Synchronization
@testable import VitrineUpdate

enum T {
    static let bundleID = "io.github.xbtdmt.vitrine"

    static func tempFolder(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "vitrine-update-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    static func version(_ marketing: String, _ build: String) -> AppVersion { AppVersion(marketing: marketing, build: build)! }

    static func manifest(version: String = "1.1.0", build: String = "7", url: String = "https://updates.example.com/Vitrine-1.1.0_7.dmg",
                         size: Int64 = 3, sha256: String = String(repeating: "a", count: 64), minimumSystemVersion: String = "15.0",
                         bundleID: String = T.bundleID) -> UpdateManifest {
        UpdateManifest(bundleIdentifier: bundleID, version: version, build: build, url: URL(string: url)!, size: size,
                       sha256: sha256, minimumSystemVersion: minimumSystemVersion,
                       releaseNotesURL: URL(string: "https://updates.example.com/notes/1.1.0.html"))
    }

    static func feed(_ manifest: UpdateManifest, key: Curve25519.Signing.PrivateKey) throws -> Data {
        try FeedSigner.sign(manifest, with: key).encoded()
    }

    static func verifier(key: Curve25519.Signing.PrivateKey, current: AppVersion = T.version("1.0.0", "5"),
                         system: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)) -> FeedVerifier {
        FeedVerifier(trust: UpdateTrust(keys: [key.publicKey]), bundleIdentifier: bundleID, current: current, systemVersion: system)
    }

    /// A minimal app bundle (Info.plist + a marker file standing in for the executable).
    @discardableResult
    static func makeApp(at url: URL, id: String = T.bundleID, version: String, build: String, marker: String) throws -> URL {
        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleVersion": build,
                                    "CFBundleExecutable": "Vitrine", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
        try Data(marker.utf8).write(to: contents.appending(path: "MacOS/Vitrine"))
        return url
    }

    static func marker(of app: URL) -> String? {
        (try? Data(contentsOf: app.appending(path: "Contents/MacOS/Vitrine"))).map { String(decoding: $0, as: UTF8.self) }
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - URL loading stub (no network)

/// What the stub answers for one URL.
enum StubAnswer: Sendable {
    case body(status: Int, data: Data)
    case redirect(to: String)
}

/// Registered in the session's `protocolClasses`, so it replaces every system loader: a URL with no answer fails, it
/// never goes out. Answers are keyed by full URL; each test uses its own host.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let answers = Mutex<[String: StubAnswer]>([:])
    static let requested = Mutex<[String]>([])

    static func set(_ url: String, _ answer: StubAnswer) { answers.withLock { $0[url] = answer } }
    static func requests(host: String) -> [String] { requested.withLock { $0.filter { URL(string: $0)?.host() == host } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requested.withLock { $0.append(url.absoluteString) }
        switch Self.answers.withLock({ $0[url.absoluteString] }) {
        case .body(let status, let data)?:
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target)?:
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
        }
    }

    override func stopLoading() {}
}

// MARK: - Fakes for the installer

/// Serves one disk image's bytes for any URL.
struct FakeTransport: UpdateTransport {
    var feed = Data()
    var image: Data

    func fetch(_ url: URL, limit: Int) async throws(UpdateError) -> Data { feed }

    func download(_ url: URL, to file: URL, limit: Int64) async throws(UpdateError) -> (size: Int64, sha256: String) {
        let bytes = image.count > Int(limit) ? image.prefix(Int(limit) + 1) : image
        do { try bytes.write(to: file) } catch { throw .fileSystem("test") }
        if Int64(bytes.count) > limit { throw .downloadSizeMismatch(expected: limit, got: Int64(bytes.count)) }
        return (Int64(bytes.count), T.sha256(bytes))
    }
}

/// "Mounts" by copying a prepared folder under the mount root; records detaches.
final class FakeMounter: DiskImageMounting, @unchecked Sendable {
    let content: URL
    let detached = Mutex<[URL]>([])
    init(content: URL) { self.content = content }

    func attach(_ image: URL, under mountRoot: URL) async throws(UpdateError) -> URL {
        let point = mountRoot.appending(path: "vol", directoryHint: .isDirectory)
        do { try FileManager.default.copyItem(at: content, to: point) } catch { throw .diskImage("test") }
        return point
    }

    func detach(_ mountPoint: URL) async { detached.withLock { $0.append(mountPoint) } }
}

struct FakeCodeVerifier: AppSignatureVerifying {
    var failure: UpdateError?
    func verify(_ app: URL) throws(UpdateError) { if let failure { throw failure } }
}
