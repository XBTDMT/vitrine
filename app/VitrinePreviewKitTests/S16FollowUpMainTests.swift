import XCTest
@testable import VitrinePreviewKit

/// S-16 follow-ups made in the main session: the code view's snapshot rectangle from the page, the email link
/// disarm's quoted ">" and attribute separators, and masking of every session tool argument. Every value here is
/// invented. roadmap: S-16
@MainActor
final class S16FollowUpMainTests: XCTestCase {
    // MARK: Code snapshot rectangle

    func testASnapshotRectangleIsCheckedAndHeldInsideTheView() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(CodeRenderer.snapshotRect(["x": 10, "y": 20, "w": 100, "h": 50], bounds: bounds), CGRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertNil(CodeRenderer.snapshotRect(["x": 0, "y": 0, "w": Double.infinity, "h": 50], bounds: bounds))
        XCTAssertNil(CodeRenderer.snapshotRect(["x": Double.nan, "y": 0, "w": 10, "h": 10], bounds: bounds))
        XCTAssertNil(CodeRenderer.snapshotRect(["x": 0, "y": 0, "w": 0, "h": 10], bounds: bounds))
        XCTAssertNil(CodeRenderer.snapshotRect(["x": 5000, "y": 5000, "w": 10, "h": 10], bounds: bounds), "wholly outside: what is in view")
        XCTAssertEqual(CodeRenderer.snapshotRect(["x": 700, "y": 0, "w": 1e8, "h": 10], bounds: bounds), CGRect(x: 700, y: 0, width: 100, height: 10))
    }

    // MARK: Email links

    func testALinkAfterAQuotedGreaterThanIsDisarmed() {
        let out = EmailStageView.disarm(#"<a title="x>y" href="https://tide.example.invalid/a">go</a>"#)
        XCTAssertFalse(out.contains(" href="), out)
        XCTAssertTrue(out.contains("data-vitrine-href"))
    }

    func testEveryAttributeSeparatorBrowsersAcceptIsCovered() {
        for html in [#"<a/href="https://tide.example.invalid/b">x</a>"#, #"<a title="x"href="https://tide.example.invalid/c">x</a>"#,
                     #"<a title='x'href=https://tide.example.invalid/d>x</a>"#, "<a\nhref=\"https://tide.example.invalid/e\">x</a>"] {
            let out = EmailStageView.disarm(html)
            XCTAssertNil(out.range(of: #"(?i)(?<![-\w])href\s*="#, options: .regularExpression), out)
        }
        let refresh = EmailStageView.disarm(#"<meta content="0;url=https://tide.example.invalid"/http-equiv="refresh">"#)
        XCTAssertFalse(refresh.lowercased().contains("/http-equiv"), refresh)
    }

    func testQuotedTagBodiesStayLinear() {
        let html = String(repeating: #"<a title="x" "#, count: 50_000) + String(repeating: "'", count: 50_000)
        let start = Date()
        _ = EmailStageView.disarm(html)
        _ = EmailStageView.foreignLinkHosts(html, senderDomain: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    // MARK: Session tool arguments

    func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    func testEveryToolArgumentIsMasked() throws {
        let token = "ghp_" + String(repeating: "Q7rT", count: 9)
        let lines = [
            #"{"type":"assistant","sessionId":"x","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"WebFetch","input":{"url":"https://sam:reef-not-real@api.example.invalid/v1?page=2&access_token=harbor-not-real#top"}}]}}"#,
            #"{"type":"assistant","sessionId":"x","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Grep","input":{"pattern":"\#(token)"}}]}}"#,
            #"{"type":"assistant","sessionId":"x","message":{"id":"m3","content":[{"type":"tool_use","id":"t3","name":"Task","input":{"description":"rotate \#(token)","prompt":"p"}}]}}"#,
        ]
        let s = try XCTUnwrap(SessionParser.parse(data: data(lines)))
        let args = s.tools.map(\.argument)
        XCTAssertEqual(args.count, 3)
        XCTAssertFalse(args[0].contains("reef-not-real"), args[0])
        XCTAssertFalse(args[0].contains("harbor-not-real"), args[0])
        XCTAssertTrue(args[0].contains("page=2"), args[0])
        XCTAssertTrue(args[0].hasSuffix("#top"), args[0])
        XCTAssertFalse(args[1].contains(token), args[1])
        XCTAssertFalse(args[2].contains(token), args[2])
        XCTAssertGreaterThanOrEqual(s.maskedSecrets, 4)
    }
}

/// S-16 follow-up: a standalone provisioning profile's card names its team only when the profile's own signature
/// checks out against Apple (G-34). The profile is invented and signed by a throwaway identity. roadmap: S-16
@MainActor
final class S16ProfileCardTests: XCTestCase {
    func testAProfileSignedByNobodyAppleVouchesForNamesNoTeam() throws {
        let fx = try S16TrustFixtures()
        let id = try fx.identity("Apple Distribution: Famous Vendor (ABCDE12345)", name: "dev")
        _ = try fx.write("p.plist", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Name</key><string>Borrowed</string><key>TeamName</key><string>Famous Vendor</string>
        <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
        <key>ExpirationDate</key><date>2099-01-01T00:00:00Z</date>
        </dict></plist>
        """.utf8))
        _ = try fx.run("/usr/bin/openssl", ["smime", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", fx.path("p.plist").path,
                                            "-signer", id.certificate, "-inkey", id.key, "-out", fx.path("Borrowed.mobileprovision").path])
        let url = fx.path("Borrowed.mobileprovision")
        let doc = try BinaryFacts.document(url: url, kind: .provisioningProfile)
        XCTAssertNil(doc.facts.first { $0.key == "team" }, "no verified team")
        XCTAssertEqual(doc.facts.first { $0.key == "claimedTeam" }?.value, "Famous Vendor (ABCDE12345)")
        let card = BinaryCard.make(document: doc, url: url)
        let maker = try XCTUnwrap(card.answers.first { $0.question == BinaryCard.Phrase.whoMadeIt })
        XCTAssertEqual(maker.mark, .caution)
        XCTAssertNotEqual(maker.answer, "Famous Vendor (ABCDE12345)")
    }
}
