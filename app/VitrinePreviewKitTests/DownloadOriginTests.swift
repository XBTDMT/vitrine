import XCTest
@testable import VitrinePreviewKit

/// Where a download came from (T-1), read from the attributes macOS writes; set here on an invented file. roadmap: S-20
final class DownloadOriginTests: XCTestCase {
    func set(_ name: String, _ data: Data, on url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            _ = data.withUnsafeBytes { setxattr(path!, name, $0.baseAddress, data.count, 0, 0) }
        }
    }

    func testTheAddressAndTheAppAreReadAndANonDownloadSaysNothing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeetlyConnect-\(UUID().uuidString).pkg")
        try Data("x".utf8).write(to: url)
        XCTAssertNil(DownloadOrigin.read(url))
        XCTAssertEqual(DownloadOrigin.facts(for: url), [])
        let froms = try PropertyListSerialization.data(fromPropertyList: ["https://meetly-connect.example.net/get/MeetlyConnect-Setup.pkg?ref=invite", "https://example.net/invite"], format: .binary, options: 0)
        set("com.apple.metadata:kMDItemWhereFroms", froms, on: url)
        set("com.apple.quarantine", Data("0083;6543a1b2;Safari;0A1B2C3D-0000-0000-0000-000000000000".utf8), on: url)
        XCTAssertEqual(DownloadOrigin.read(url), .init(url: "https://meetly-connect.example.net/get/MeetlyConnect-Setup.pkg?ref=invite", agent: "Safari", quarantined: true))
        let facts = DownloadOrigin.facts(for: url)
        XCTAssertEqual(facts.map(\.key), ["downloadedFrom", "quarantined", "downloadedWith"])
        XCTAssertEqual(facts.first?.value, "meetly-connect.example.net/get/MeetlyConnect-Setup.pkg", "the address without its query")
    }
}
