import XCTest
@testable import VitrinePreviewKit

final class MermaidCacheTests: XCTestCase {
    private func cache(limit: Int = 32 * 1024 * 1024) -> MermaidCache {
        MermaidCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("vt-mc-\(UUID().uuidString)"), limit: limit)
    }
    private let key = String(repeating: "a", count: 64)

    func testStoresAndReadsAnSVG() {
        let c = cache()
        XCTAssertNil(c.svg(for: key))
        c.store("<svg id=\"x\"></svg>", for: key)
        XCTAssertEqual(c.svg(for: key), "<svg id=\"x\"></svg>")
    }

    func testRefusesWhatIsNotADrawingOrAKey() {
        let c = cache()
        c.store("<script>alert(1)</script>", for: key)
        XCTAssertNil(c.svg(for: key))
        c.store("<svg></svg>", for: "../escape")
        c.store("<svg></svg>", for: String(repeating: "g", count: 64))
        XCTAssertNil(c.svg(for: "../escape"))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: c.directory.path))?.count ?? 0, 0)
    }

    func testPrunesOldestFirst() throws {
        let c = cache(limit: 3000)
        let body = "<svg>" + String(repeating: "x", count: 1000) + "</svg>"
        let keys = ["1", "2", "3", "4"].map { String(repeating: $0, count: 64) }
        for (i, k) in keys.enumerated() {
            c.store(body, for: k)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 10))],
                                                  ofItemAtPath: c.directory.appendingPathComponent(k + ".svg").path)
        }
        c.prune()
        XCTAssertNil(c.svg(for: keys[0]), "the oldest went first")
        XCTAssertNotNil(c.svg(for: keys[3]))
    }

    func testKnowsTheVendoredVersion() {
        XCTAssertEqual(MermaidCache.mermaidVersion, "12.2.0")
    }
}
