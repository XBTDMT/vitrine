// G-22: what a short-read line with no finding is still covered for (LabelTrust.shortReadCandidates). Made-up values.
import Foundation
import Testing
@testable import VitrineDetect

@Suite("Short-read candidates (G-22)")
struct ShortReadCandidateTests {
    let catalogue = try! Catalogue.resolved(state: ["ai.huggingface.token": true])

    @Test func aLabelledValueStartsAtTheValueAndRunsToTheNextSpace() {
        let found = LabelTrust.shortReadCandidates(in: "SESSION_SECRET=aaaaaaaa # note", catalogue: catalogue)
        #expect(found.contains { $0.detectorID == "config.env.secret" && $0.range == NSRange(location: 15, length: 8) })
    }

    @Test func aVendorPrefixCountsOnlyAtTheStartOfAToken() {
        let start = LabelTrust.shortReadCandidates(in: "use hf_Ab3dE now", catalogue: catalogue)
        #expect(start.map(\.detectorID) == ["ai.huggingface.token"] && start.first?.range == NSRange(location: 4, length: 8))
        #expect(LabelTrust.shortReadCandidates(in: "leaf_node and xhf_Ab3dE", catalogue: catalogue).isEmpty)
    }

    @Test func aDisabledPrefixDetectorAndPlainTextGiveNothing() throws {
        let off = try Catalogue.resolved(state: ["ai.huggingface.token": false])
        #expect(LabelTrust.shortReadCandidates(in: "use hf_Ab3dE now", catalogue: off).isEmpty)
        #expect(LabelTrust.shortReadCandidates(in: "nothing to see on this line", catalogue: catalogue).isEmpty)
    }
}
