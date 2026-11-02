import XCTest
@testable import VitrineFormats

/// S-16 follow-up from lane 4: an email Date header with out-of-range numbers must read as no date, not as a wrong
/// one (Foundation turns year 9223372036854775807 into year 1), and its comment stripping must stay linear.
/// Every header here is invented. roadmap: S-16
final class S16MailDateTests: XCTestCase {
    func testOrdinaryDatesStillParse() {
        XCTAssertNotNil(EverydayMail.parseDate("Tue, 3 Nov 2026 09:30:00 +0100"))
        XCTAssertNotNil(EverydayMail.parseDate("3 Nov 26 09:30 GMT (a comment)"))
    }

    func testOutOfRangeNumbersReadAsNoDate() {
        XCTAssertNil(EverydayMail.parseDate("Tue, 3 Nov 9223372036854775807 09:30:00 +0000"))
        XCTAssertNil(EverydayMail.parseDate("Tue, 3 Nov 99999 09:30:00 +0000"))
        XCTAssertNil(EverydayMail.parseDate("Tue, 3 Nov 2026 09:30:9223372036854775807 +0000"))
        XCTAssertNil(EverydayMail.parseDate("Tue, 3 Nov 2026 09:30:61 +0000"))
        XCTAssertNil(EverydayMail.parseDate("Tue, 3 Nov 2026 09:30:00 +9999"))
    }

    func testCommentStrippingIsLinear() {
        let start = Date()
        _ = EverydayMail.parseDate(String(repeating: "(", count: 200_000) + " 3 Nov 2026 09:30 GMT")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
