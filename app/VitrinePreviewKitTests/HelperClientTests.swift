import XCTest
@testable import VitrinePreviewKit
import VitrineHelperKit

/// Calling the helper when it does not answer (off, stale after an update, or missing) must come back with the
/// fallback, never trap: XPC calls the error handler on its own queue, and a closure isolated to the main actor traps
/// there (seen 2026-11-01 as exit 133 from `Vitrine --helper ping` after an install). roadmap: S-10 (X-3)
@MainActor
final class HelperClientTests: XCTestCase {
    func testASilentServiceGivesTheFallbackFromTheMainActor() async {
        // A requirement this (ad hoc) test host meets, so the call still goes out over XPC to the silent service: with
        // the default pin, which an ad-hoc host cannot build, the call would fail closed before connecting (S-16 F59).
        let answer = await HelperClient.call(timeout: 2, fallback: "fallback",
                                             service: HelperService.appGroup + ".no-such-service",
                                             requirement: #"identifier "com.apple.xctest""#) { helper, done in
            helper.reveal("/") { done($0 ?? "answered") }
        }
        XCTAssertEqual(answer, "fallback")
    }

    func testRefusalCodesAreWorded() {
        XCTAssertEqual(HelperClient.words("refusal:link"), "Only web and mail links open from a preview.")
        XCTAssertEqual(HelperClient.words("Some macOS error."), "Some macOS error.")
        XCTAssertNil(HelperClient.words(nil))
    }
}
