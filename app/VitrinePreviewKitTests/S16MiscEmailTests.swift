import XCTest
@testable import VitrinePreviewKit

/// S-16 F55: the patterns run over a message's HTML (up to 1,000,000 characters, the sender's) are linear, so a
/// crafted .eml cannot pin the preview's CPU; and they still find what they found. Every message is invented.
/// roadmap: S-16
final class S16MiscEmailTests: XCTestCase {
    static let budget: Duration = .seconds(2)

    func time(_ body: () -> Void) -> Duration { ContinuousClock().measure(body) }

    func testASpaceRunAfterURLIsCountedInLinearTime() {
        let html = "url(" + String(repeating: " ", count: 999_000) + "x"
        var count = -1
        let elapsed = time { count = EmailStageView.countRemote(html) }
        XCTAssertLessThan(elapsed, Self.budget, "999,000 spaces after url( took \(elapsed)")
        XCTAssertEqual(count, 0)
        let src = "<img src=" + String(repeating: " ", count: 500_000) + "\"" + String(repeating: " ", count: 400_000) + "x"
        XCTAssertLessThan(time { _ = EmailStageView.countRemote(src) }, Self.budget)
    }

    func testUnclosedAnchorsAreDisarmedAndScannedInLinearTime() {
        let html = String(repeating: "<a ", count: 300_000)
        let disarmed = time { _ = EmailStageView.disarm(html) }
        XCTAssertLessThan(disarmed, Self.budget, "300,000 unclosed <a disarmed in \(disarmed)")
        let ringed = time { _ = EmailStageView.foreignLinkHosts(html, senderDomain: "example.com") }
        XCTAssertLessThan(ringed, Self.budget, "300,000 unclosed <a scanned for hosts in \(ringed)")
        let metas = String(repeating: "<meta ", count: 300_000)
        XCTAssertLessThan(time { _ = EmailStageView.disarm(metas) }, Self.budget)
        let spaced = "<meta http-equiv=" + String(repeating: " ", count: 500_000) + "'" + String(repeating: " ", count: 400_000) + "x>"
        XCTAssertLessThan(time { _ = EmailStageView.disarm(spaced) }, Self.budget)
    }

    func testTheLinearPatternsStillFindWhatTheyFound() {
        let html = """
        <p>Hi</p><a class="b" href="https://tracker.invalid/x">one</a> <AREA shape=rect HREF = 'https://maps.invalid/'>
        <a\tid=z href=mailto:me@example.com>two</a><abbr href="x">no</abbr>
        <meta http-equiv = "Refresh" content="0;url=https://away.invalid/"><meta name="x" content="y">
        <img src="https://pixel.invalid/p.gif"><div style="background: url( 'https://img.invalid/b.png')"></div>
        <img src="cid:part1"><a href="https://news.example.com/">sender</a><a href="https://user@other.invalid:8080/p">at</a>
        <a title="x" href="https://unclosed.invalid/
        """
        let disarmed = EmailStageView.disarm(html)
        XCTAssertNil(disarmed.range(of: #"<(a|area)\b[^>]*\shref\s*="#, options: [.regularExpression, .caseInsensitive]),
                       "every link's href is renamed, the unclosed last one included")
        XCTAssertTrue(disarmed.contains(#"<a class="b" data-vitrine-href="https://tracker.invalid/x">"#))
        XCTAssertTrue(disarmed.contains("<AREA shape=rect data-vitrine-href = 'https://maps.invalid/'>"))
        XCTAssertTrue(disarmed.contains(#"<abbr href="x">"#), "other tags are left alone")
        XCTAssertTrue(disarmed.contains(#"<meta data-vitrine-http-equiv = "Refresh""#))
        XCTAssertTrue(disarmed.contains(#"<meta name="x" content="y">"#))
        XCTAssertEqual(EmailStageView.countRemote(html), 2)
        XCTAssertEqual(EmailStageView.foreignLinkHosts(html, senderDomain: "example.com"),
                       ["tracker.invalid", "other.invalid", "unclosed.invalid"])
    }
}
