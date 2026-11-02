import XCTest
@testable import VitrinePreviewKit
import VitrineBinary
import VitrineDocument

/// S-16 lane 1 (G-34): the words for states only the budgeted check produces (the full check ran out of time, or
/// nothing finished) and for a ticket macOS verified, from assessments built in the test. roadmap: S-16
final class S16TrustWordingTests: XCTestCase {
    private func answer(_ card: BinaryCard, _ question: String) -> BinaryCard.Answer? {
        card.answers.first { $0.question == question }
    }

    private func app(_ facts: [Fact], badges: [Badge]) -> BinaryCard {
        BinaryCard.make(document: PreviewDocument(kind: .appBundle, facts: [Fact(key: "name", label: "Name", value: "Orbit Demo")] + facts,
                                                  badges: badges, views: [.text("")]),
                        url: URL(fileURLWithPath: "/nonexistent/Orbit Demo.app"))
    }

    /// The quick check finished, the full one did not: the signer is known, "Valid" is not said, and it is a caution.
    func testAQuickResultIsPartlyCheckedNeverValid() {
        var badges: [Badge] = []
        let word = BinaryFacts.verdict(SignatureAssessment(status: .valid, depth: .quick, ranOutOfTime: true, anchor: .developerID), badges: &badges)
        XCTAssertEqual(word, "Partly checked: its other files were not checked in time")
        XCTAssertEqual(badges.map(\.title), ["Not fully checked"])
        XCTAssertEqual(badges.map(\.level), [.caution])
        let card = app([Fact(key: "signature", label: "Signature", value: word),
                        Fact(key: "signerKind", label: "Signing certificate", value: "Developer ID"),
                        Fact(key: "signer", label: "Signed by", value: "Developer ID Application: Example Co"),
                        Fact(key: "notarization", label: "Notarization ticket", value: "Stapled and verified by macOS")], badges: badges)
        XCTAssertEqual(card.verdict.level, .caution)
        XCTAssertEqual(card.verdict.title, "Not fully checked")
        XCTAssertEqual(answer(card, "Is the signature intact")?.mark, .caution)
        XCTAssertEqual(answer(card, "Who made it")?.answer, "Developer ID Application: Example Co")
        XCTAssertEqual(answer(card, "Has Apple checked it")?.answer, "Yes, notarized")
        XCTAssertTrue(card.sentence.contains("signed by Developer ID Application: Example Co"), card.sentence)
    }

    /// Nothing finished in time: nothing about the signature is claimed.
    func testNothingCheckedInTimeClaimsNothing() {
        var badges: [Badge] = []
        let word = BinaryFacts.verdict(SignatureAssessment(status: .notChecked, depth: .quick, ranOutOfTime: true), badges: &badges)
        XCTAssertEqual(word, "Not checked: the check did not finish in time")
        XCTAssertEqual(badges.map(\.level), [.caution])
        let card = app([Fact(key: "signature", label: "Signature", value: word)], badges: badges)
        XCTAssertEqual(card.verdict.level, .caution)
        XCTAssertTrue(card.sentence.contains("its signature was not checked in time"), card.sentence)
        XCTAssertFalse(card.sentence.contains("not signed"), card.sentence)
    }

    /// Only the full check is "Valid".
    func testOnlyTheFullCheckIsValid() {
        var badges: [Badge] = []
        XCTAssertEqual(BinaryFacts.verdict(SignatureAssessment(status: .valid, depth: .full, anchor: .developerID), badges: &badges), "Valid")
        XCTAssertTrue(badges.isEmpty)
        XCTAssertNotEqual(BinaryFacts.verdict(SignatureAssessment(status: .valid, depth: .quick, anchor: .developerID), badges: &badges), "Valid")
    }

    /// A ticket macOS verified: stapled or held by this Mac, both "notarized"; a ticket-shaped file alone is a caution.
    func testNotarizationWords() {
        var badges: [Badge] = []
        XCTAssertEqual(BinaryFacts.notarization(SignatureAssessment(status: .valid, depth: .full, anchor: .developerID, notarization: .verified,
                                                                    ticketFile: .present(version: 1, size: 2000)), notTicket: nil, badges: &badges),
                       "Stapled and verified by macOS")
        XCTAssertEqual(BinaryFacts.notarization(SignatureAssessment(status: .valid, depth: .full, anchor: .developerID, notarization: .verified,
                                                                    ticketFile: .notStapled), notTicket: nil, badges: &badges),
                       "Notarized (verified by macOS)")
        XCTAssertTrue(badges.isEmpty)
        XCTAssertEqual(BinaryFacts.notarization(SignatureAssessment(status: .adhoc, depth: .full, notarization: .ticketUnverified,
                                                                    ticketFile: .present(version: 1, size: 72)), notTicket: nil, badges: &badges),
                       "Ticket present, not verified")
        XCTAssertEqual(badges.map(\.title), ["Notarization not verified"])
    }

    /// The signer's kind, from the requirements: an Apple-issued certificate that is not a Developer ID is named, but
    /// macOS asks before opening a download signed with it; a certificate Apple does not vouch for is a finding.
    func testSignerKinds() {
        XCTAssertEqual(BinaryFacts.signerKindWord(.apple), "Apple's own")
        XCTAssertEqual(BinaryFacts.signerKindWord(.developerID), "Developer ID")
        XCTAssertEqual(BinaryFacts.signerKindWord(.macAppStore), "Mac App Store")
        XCTAssertEqual(BinaryFacts.signerKindWord(.appleIssued), "Issued by Apple, not a Developer ID")
        XCTAssertEqual(BinaryFacts.signerKindWord(.notVouched), "Not vouched for by Apple")
        XCTAssertNil(BinaryFacts.signerKindWord(.none))

        let downloaded = Fact(key: "quarantined", label: "Marked as downloaded", value: "Yes")
        let development = app([Fact(key: "signature", label: "Signature", value: "Valid"),
                               Fact(key: "signerKind", label: "Signing certificate", value: "Issued by Apple, not a Developer ID"),
                               Fact(key: "signer", label: "Signed by", value: "Apple Development: Sample Developer (XYZ)"), downloaded], badges: [])
        XCTAssertEqual(answer(development, "Who made it")?.answer, "Apple Development: Sample Developer (XYZ)")
        XCTAssertEqual(answer(development, "Will macOS open it")?.mark, .caution, "Gatekeeper asks first for a non-Developer ID download")

        var badges: [Badge] = []
        var facts: [Fact] = []
        BinaryFacts.signerFacts(SignatureAssessment(status: .valid, depth: .full, anchor: .notVouched), embedded: [],
                                add: { key, label, value in if let value { facts.append(Fact(key: key, label: label, value: value)) } },
                                badges: &badges)
        XCTAssertEqual(facts.map(\.key), ["signerKind"])
        XCTAssertEqual(badges.map(\.title), ["Apple does not vouch for the signer"])
    }
}
