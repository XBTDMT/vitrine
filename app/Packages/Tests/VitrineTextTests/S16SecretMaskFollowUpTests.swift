import XCTest
@testable import VitrineText

/// S-16 follow-ups from lane 5: a *_PASS key is a password key, and the URL-password pattern stays linear on long
/// values with no "://". Every value here is invented. roadmap: S-16
final class S16SecretMaskFollowUpTests: XCTestCase {
    func testAPassKeyIsMaskedButAWordThatOnlyContainsPassIsNot() {
        let r = SecretMask.mask("DB_PASS=harbor-not-real\nPASS=tide-not-real\nmysql.pass=reef-not-real\nBYPASS_CACHE=true\nPASSPORT_ROUTE=/v2")
        XCTAssertEqual(r.count, 3)
        XCTAssertFalse(r.text.contains("harbor-not-real"))
        XCTAssertFalse(r.text.contains("tide-not-real"))
        XCTAssertFalse(r.text.contains("reef-not-real"))
        XCTAssertTrue(r.text.contains("BYPASS_CACHE=true"))
        XCTAssertTrue(r.text.contains("PASSPORT_ROUTE=/v2"))
    }

    func testTheURLPasswordPatternIsLinearOnALongValueWithNoScheme() {
        let value = String(repeating: "a", count: 200_000)
        let start = Date()
        let r = SecretMask.mask("NOTE=\(value)")
        XCTAssertEqual(r.count, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testAURLPasswordInsideAValueIsStillMasked() {
        let r = SecretMask.mask("MIRROR=see https://sam:reef-not-real@mirror.example.invalid/x")
        XCTAssertEqual(r.count, 1)
        XCTAssertFalse(r.text.contains("reef-not-real"))
        XCTAssertTrue(r.text.contains("https://sam:"))
    }
}
