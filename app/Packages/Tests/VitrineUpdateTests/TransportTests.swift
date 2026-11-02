// The real URLSession transport against a URLProtocol stub that replaces every system loader: no request leaves the Mac.
import Foundation
import Testing
@testable import VitrineUpdate

@Suite struct TransportTests {
    let transport = URLSessionUpdateTransport(protocolClasses: [StubURLProtocol.self])

    @Test func anHTTPSFeedIsFetched() async throws {
        StubURLProtocol.set("https://ok.feed.test/feed.json", .body(status: 200, data: Data("hello".utf8)))
        let data = try await transport.fetch(URL(string: "https://ok.feed.test/feed.json")!, limit: 1024)
        #expect(data == Data("hello".utf8))
    }

    @Test func aNonHTTPSAddressIsRefusedWithoutARequest() async {
        StubURLProtocol.set("http://plain.feed.test/feed.json", .body(status: 200, data: Data("x".utf8)))
        await #expect(throws: UpdateError.insecureURL("http://plain.feed.test/feed.json")) {
            try await transport.fetch(URL(string: "http://plain.feed.test/feed.json")!, limit: 1024)
        }
        #expect(StubURLProtocol.requests(host: "plain.feed.test").isEmpty, "nothing was requested")
    }

    @Test func aRedirectToAnotherHostIsRefused() async {
        StubURLProtocol.set("https://cross.feed.test/feed.json", .redirect(to: "https://evil.feed.test/feed.json"))
        StubURLProtocol.set("https://evil.feed.test/feed.json", .body(status: 200, data: Data("forged".utf8)))
        await #expect(throws: UpdateError.redirectRefused(from: "cross.feed.test", to: "evil.feed.test")) {
            try await transport.fetch(URL(string: "https://cross.feed.test/feed.json")!, limit: 1024)
        }
        #expect(StubURLProtocol.requests(host: "evil.feed.test").isEmpty, "the other host was never asked")
    }

    @Test func aRedirectToPlainHTTPOnTheSameHostIsRefused() async {
        StubURLProtocol.set("https://downgrade.feed.test/feed.json", .redirect(to: "http://downgrade.feed.test/feed.json"))
        await #expect(throws: UpdateError.insecureURL("http://downgrade.feed.test/feed.json")) {
            try await transport.fetch(URL(string: "https://downgrade.feed.test/feed.json")!, limit: 1024)
        }
    }

    @Test func anHTTPSRedirectOnTheSameHostIsFollowed() async throws {
        StubURLProtocol.set("https://same.feed.test/old.json", .redirect(to: "https://same.feed.test/new.json"))
        StubURLProtocol.set("https://same.feed.test/new.json", .body(status: 200, data: Data("moved".utf8)))
        let data = try await transport.fetch(URL(string: "https://same.feed.test/old.json")!, limit: 1024)
        #expect(data == Data("moved".utf8))
    }

    @Test func anErrorStatusIsRefused() async {
        StubURLProtocol.set("https://missing.feed.test/feed.json", .body(status: 404, data: Data("nope".utf8)))
        await #expect(throws: UpdateError.httpStatus(404)) {
            try await transport.fetch(URL(string: "https://missing.feed.test/feed.json")!, limit: 1024)
        }
    }

    @Test func aFeedOverTheLimitIsRefused() async {
        StubURLProtocol.set("https://big.feed.test/feed.json", .body(status: 200, data: Data(count: 2048)))
        await #expect(throws: UpdateError.feedTooLarge) {
            try await transport.fetch(URL(string: "https://big.feed.test/feed.json")!, limit: 1024)
        }
    }

    @Test func aDownloadIsWrittenPrivatelyAndHashed() async throws {
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        StubURLProtocol.set("https://dl.feed.test/Vitrine.dmg", .body(status: 200, data: bytes))
        let file = folder.appending(path: "update.dmg")
        let got = try await transport.download(URL(string: "https://dl.feed.test/Vitrine.dmg")!, to: file, limit: Int64(bytes.count))
        #expect(got.size == Int64(bytes.count))
        #expect(got.sha256 == T.sha256(bytes))
        #expect(try Data(contentsOf: file) == bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode.map { $0 & 0o777 } == 0o600)
    }

    @Test func aDownloadLargerThanTheSignedSizeIsCutOffAndDeleted() async throws {
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        StubURLProtocol.set("https://huge.feed.test/Vitrine.dmg", .body(status: 200, data: Data(count: 5000)))
        let file = folder.appending(path: "update.dmg")
        await #expect(throws: UpdateError.downloadSizeMismatch(expected: 1000, got: 5000)) {
            try await transport.download(URL(string: "https://huge.feed.test/Vitrine.dmg")!, to: file, limit: 1000)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aDownloadRedirectedToAnotherHostIsRefused() async throws {
        let folder = try T.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        StubURLProtocol.set("https://rel.feed.test/Vitrine.dmg", .redirect(to: "https://cdn.other.test/Vitrine.dmg"))
        await #expect(throws: UpdateError.redirectRefused(from: "rel.feed.test", to: "cdn.other.test")) {
            try await transport.download(URL(string: "https://rel.feed.test/Vitrine.dmg")!, to: folder.appending(path: "u.dmg"), limit: 1000)
        }
    }
}
