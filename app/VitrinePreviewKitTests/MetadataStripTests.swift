import XCTest
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineSupport

/// The metadata strip (I-13, settings r3-a): which facts the capsule's pill shows, in whose order. roadmap: S-24
final class MetadataStripTests: XCTestCase {
    func defaults() -> UserDefaults {
        let name = "vt-strip-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    let code = PreviewDocument(kind: .code(language: "swift"),
                               facts: [Fact(key: "headline", label: "Lines", value: "66 lines"), Fact(key: "size", label: "Size", value: "2.2 KB"),
                                       Fact(key: "encoding", label: "Encoding", value: "UTF-8"), Fact(key: "tokens", label: "Tokens", value: "≈ 550"),
                                       Fact(key: "branch", label: "Branch", value: "main")],
                               views: [.text("")])

    func testTheDefaultIsTheDesignsFiveQuietUntilHover() {
        let s = MetadataStrip.Settings.read(defaults())
        XCTAssertEqual(s, .standard)
        XCTAssertEqual(s.show, .hover)
        XCTAssertEqual(s.visible, [.kind, .lines, .size, .encoding, .tokens])
        XCTAssertEqual(MetadataStrip.parts(code, settings: s), ["Swift", "66 lines", "2.2 KB", "UTF-8", "≈ 550 tok"])
    }

    func testThePersonsOrderAndHiddenFactsAreKept() {
        let d = defaults()
        var s = MetadataStrip.Settings.standard
        s.order = [.tokens, .git, .kind] + MetadataStrip.Item.allCases.filter { ![.tokens, .git, .kind].contains($0) }
        s.hidden = [.lines, .size, .encoding, .dimensions, .modified, .owner]
        s.show = .always
        s.write(d)
        let back = MetadataStrip.Settings.read(d)
        XCTAssertEqual(back, s)
        XCTAssertEqual(MetadataStrip.parts(code, settings: back), ["≈ 550 tok", "main", "Swift"])
    }

    func testUnknownNamesAreDroppedAndNewFactsJoinAtTheEnd() {
        let d = defaults()
        d.set(["size", "made-up", "size", "kind"], forKey: MetadataStrip.orderKey)
        d.set("loud", forKey: MetadataStrip.showKey)
        let s = MetadataStrip.Settings.read(d)
        XCTAssertEqual(Array(s.order.prefix(2)), [.size, .kind])
        XCTAssertEqual(Set(s.order), Set(MetadataStrip.Item.allCases), "every fact is in the list once")
        XCTAssertEqual(s.order.count, MetadataStrip.Item.allCases.count)
        XCTAssertEqual(s.show, .hover, "an unknown show value falls back to the default")
    }

    func testFileFactsFillModifiedAndOwnerApp() {
        var s = MetadataStrip.Settings.standard
        s.hidden = [.kind, .lines, .size, .encoding, .tokens, .git, .dimensions]
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let parts = MetadataStrip.parts(code, settings: s, file: .init(modified: date, owner: "Xcode"))
        XCTAssertEqual(parts, [date.formatted(date: .abbreviated, time: .shortened), "Xcode"])
        XCTAssertEqual(MetadataStrip.parts(code, settings: s), [], "no file facts, nothing to say")
    }

    func testTextWithoutAHeadlineSaysItsLinesWithTheUnit() {
        let swift = PreviewDocument(kind: .code(language: "swift"), facts: [Fact(key: "lines", label: "Lines", value: "1,227")], views: [.text("")])
        XCTAssertEqual(MetadataStrip.parts(swift, settings: .standard), ["Swift", "1,227 lines"])
        let one = PreviewDocument(kind: .plainText, facts: [Fact(key: "lines", label: "Lines", value: "1")], views: [.text("")])
        XCTAssertEqual(MetadataStrip.parts(one, settings: .standard).last, "1 line")
    }

    func testAPictureDoesNotSayItsSizeTwice() {
        let photo = PreviewDocument(kind: .image, facts: [Fact(key: "headline", label: "Dimensions", value: "1280 × 800"),
                                                          Fact(key: "dimensions", label: "Dimensions", value: "1280 × 800")], views: [.text("")])
        var s = MetadataStrip.Settings.standard
        s.hidden.remove(.dimensions)
        XCTAssertEqual(MetadataStrip.parts(photo, settings: s).filter { $0 == "1280 × 800" }.count, 1)
        s.hidden.insert(.lines)
        XCTAssertEqual(MetadataStrip.parts(photo, settings: s).filter { $0 == "1280 × 800" }.count, 1, "shown by Dimensions when Lines / rows is off")
    }

    @MainActor
    func testThePillFollowsTheStrip() {
        let m = CapsuleModel()
        m.show(code, canToggleInspector: false, canFind: true)
        XCTAssertEqual(m.pillText, "Swift · 66 lines · 2.2 KB · UTF-8 · ≈ 550 tok")
        m.strip.hidden = Set(MetadataStrip.Item.allCases).subtracting([.git])
        XCTAssertEqual(m.pillText, "main")
    }
}
