import XCTest

/// Spotlight is asked to re-read Vitrine's types once per build, and again after a failed request (S-19, X-8).
/// roadmap: S-19
final class SpotlightReimportTests: XCTestCase {
    func testOncePerBuild() {
        XCTAssertTrue(SpotlightReimport.isNeeded(stored: nil, current: "0.1.0 (1)"), "never asked")
        XCTAssertFalse(SpotlightReimport.isNeeded(stored: "0.1.0 (1)", current: "0.1.0 (1)"), "asked for this build")
        XCTAssertTrue(SpotlightReimport.isNeeded(stored: "0.1.0 (1)", current: "0.1.1 (2)"), "a new build brings a new importer")
    }

    func testTheImporterIsWhereSpotlightLooks() {
        XCTAssertTrue(SpotlightReimport.importer.path.hasSuffix("Contents/Library/Spotlight/Vitrine.mdimporter"))
    }
}
