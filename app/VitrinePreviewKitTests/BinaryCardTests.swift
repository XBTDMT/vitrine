import AppKit
import XCTest
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineSupport

/// Apps, installers, disk images and profiles render as the Glass Case card with the trust verdict (cards r3-a,
/// trust r3-a; S-8, S-22): the gradient kind tile, the 650 title, at most three numbers, numbered findings, the calm
/// card's tight list, a card that scrolls in a small window and steps the stage aside in Finder's pane, and Details.
/// All values are invented.
@MainActor
final class BinaryCardTests: XCTestCase {
    private func fakeApp() throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("vt-card-\(UUID().uuidString)/Orbit Demo.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleName": "Orbit Demo", "CFBundleIdentifier": "com.example.orbit-demo",
                                   "CFBundleShortVersionString": "2.4.0", "CFBundleVersion": "240", "CFBundlePackageType": "APPL",
                                   "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    /// An invented installer: unsigned, two install scripts, so two findings (both caution).
    private func installerDoc() -> PreviewDocument {
        PreviewDocument(kind: .installerPackage, facts: [
            Fact(key: "identifier", label: "Package", value: "com.example.orbit-sync"),
            Fact(key: "version", label: "Version", value: "3.1"),
            Fact(key: "size", label: "Size", value: "2 MB"),
            Fact(key: "installLocation", label: "Installs to", value: "/Applications"),
            Fact(key: "signed", label: "Signature", value: "Not signed"),
            Fact(key: "scripts", label: "Runs scripts", value: "preinstall, postinstall"),
        ], badges: [Badge(level: .caution, title: "Not signed", detail: "macOS cannot tell who made this installer."),
                    Badge(level: .caution, title: "Runs install scripts", detail: "Installing runs preinstall, postinstall.")],
        views: [.text("")])
    }

    /// An invented app whose signature is broken: a danger finding and a caution-free rest.
    private func brokenAppDoc() -> PreviewDocument {
        PreviewDocument(kind: .appBundle, facts: [Fact(key: "name", label: "Name", value: "Orbit Demo"),
                                                  Fact(key: "version", label: "Version", value: "2.4.0 (240)"),
                                                  Fact(key: "signature", label: "Signature", value: "Broken: invented reason"),
                                                  Fact(key: "sandboxed", label: "Sandboxed", value: "No")],
                        badges: [Badge(level: .danger, title: "Signature broken", detail: "invented reason")], views: [.text("")])
    }

    /// An invented calm app: valid signature, stapled ticket, sandboxed.
    private func calmAppDoc() -> PreviewDocument {
        PreviewDocument(kind: .appBundle, facts: [Fact(key: "name", label: "Name", value: "Orbit Demo"),
                                                  Fact(key: "version", label: "Version", value: "2.4.0 (240)"),
                                                  Fact(key: "architectures", label: "Runs on", value: "arm64, x86_64"),
                                                  Fact(key: "minimumSystem", label: "Requires macOS", value: "14.0"),
                                                  Fact(key: "size", label: "Size", value: "48 MB"),
                                                  Fact(key: "signature", label: "Signature", value: "Valid · hardened runtime"),
                                                  Fact(key: "team", label: "Team", value: "A1B2C3D4E5"),
                                                  Fact(key: "signer", label: "Signed by", value: "Developer ID Application: Example Co"),
                                                  Fact(key: "notarization", label: "Notarization ticket", value: "Stapled"),
                                                  Fact(key: "sandboxed", label: "Sandboxed", value: "Yes")],
                        badges: [], views: [.text("")])
    }

    private func view(_ doc: PreviewDocument, size: NSSize = NSSize(width: 800, height: 600)) -> BinaryCardView {
        let card = BinaryCard.make(document: doc, url: URL(fileURLWithPath: "/nonexistent/Orbit Demo.app"))
        let v = BinaryCardView(card: card, icon: NSImage(size: NSSize(width: 64, height: 64)), facts: doc.facts)
        v.frame = NSRect(origin: .zero, size: size)
        v.layoutSubtreeIfNeeded()
        v.layoutSubtreeIfNeeded()
        return v
    }

    private func weight(_ font: NSFont?) -> CGFloat {
        let traits = font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? .nan
    }

    func testRegistryPicksTheCardForBinaryKinds() {
        for kind in [FileKind.appBundle, .installerPackage, .diskImage, .provisioningProfile] {
            XCTAssertTrue(RendererRegistry.renderer(for: kind) is BinaryCardRenderer, "\(kind)")
        }
    }

    func testUnsignedAppCard() async throws {
        let app = try fakeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let preview = try await BinaryCardRenderer().render(url: app, kind: .appBundle, context: RenderContext(appearance: .light, defaultsSuite: nil))
        let view = try XCTUnwrap(preview.view as? BinaryCardView)
        XCTAssertEqual(view.titleField.stringValue, "Orbit Demo")
        XCTAssertEqual(view.card.sentence, "Version 2.4.0, not signed; it needs macOS 14.0 or later.")
        XCTAssertEqual(view.sentenceField.stringValue, view.card.sentence)
        XCTAssertEqual(view.card.strip.map(\.label), ["Version", "Requires", "Size"], "at most three numbers, Size last")
        XCTAssertEqual(view.stripValues.first, "2.4.0")
        XCTAssertEqual(view.stripValues[1], "macOS 14.0")
        XCTAssertEqual(view.card.rule, .caution)
        XCTAssertNotNil(view.ruleView, "a caution badge draws the 3 pt top rule")
        XCTAssertEqual(view.card.verdict.level, .caution)
        XCTAssertEqual(view.card.verdict.title, "Not signed")
        XCTAssertEqual(view.card.verdict.chip, "Check before opening", "the trust design's caution chip")
        XCTAssertEqual(view.verdictBox.fill, "caution-soft")
        XCTAssertEqual(view.card.answers.first?.answer, "Nobody you can check: it is not signed")
        XCTAssertEqual(view.card.answers.first?.mark, .caution)
        XCTAssertNotNil(preview.toggleInspector, "the capsule's inspector opens Details")
        XCTAssertNotNil(preview.scrollOffset, "the card scrolls, so scroll memory applies")
        // Copy still has the text summary.
        guard case .text(let summary)? = preview.document.views.first else { return XCTFail("text view kept") }
        XCTAssertTrue(summary.contains("com.example.orbit-demo"))
    }

    func testArchitectureWords() {
        XCTAssertEqual(BinaryCard.archWords("arm64, x86_64"), "Apple silicon and Intel")
        XCTAssertEqual(BinaryCard.archWords("arm64e"), "Apple silicon")
        XCTAssertEqual(BinaryCard.archWords("x86_64"), "Intel")
        XCTAssertNil(BinaryCard.archWords(nil))
    }

    func testDangerBadgeMakesADangerVerdict() {
        let card = BinaryCard.make(document: brokenAppDoc(), url: URL(fileURLWithPath: "/nonexistent/Orbit Demo.app"))
        XCTAssertEqual(card.rule, .danger)
        XCTAssertEqual(card.verdict.level, .danger)
        XCTAssertEqual(card.verdict.chip, "Do not open")
        let box = BinaryCardView.verdictBox(card.verdict)
        XCTAssertEqual(box.fill, "danger-strong")
        XCTAssertEqual(box.chip.fill, "on-accent")
        XCTAssertEqual(box.chip.fillAlpha, 0.22, accuracy: 0.001, "the chip on the solid box is white at .22")
        XCTAssertTrue(card.sentence.contains("its signature is broken"))
    }

    /// Findings come first, worst first, numbered from 1; each number chip is drawn on the strong colour of its level.
    func testFindingsAreNumberedWorstFirst() {
        let installer = BinaryCard.make(document: installerDoc(), url: URL(fileURLWithPath: "/nonexistent/Orbit Sync.pkg"))
        XCTAssertEqual(installer.verdict.chip, "Check before installing")
        let numbered = installer.numberedAnswers
        XCTAssertEqual(numbered.map(\.number), [1, 2])
        XCTAssertEqual(numbered.map(\.answer.question), ["What else does it do", "Where does it come from"])
        XCTAssertEqual(numbered.first?.answer.evidence, "preinstall, postinstall", "the scripts are the evidence line")

        let broken = BinaryCard.make(document: brokenAppDoc(), url: URL(fileURLWithPath: "/nonexistent/Orbit Demo.app"))
        let marks = broken.numberedAnswers.map(\.answer.mark)
        let numbers = broken.numberedAnswers.map(\.number)
        XCTAssertEqual(Array(marks.prefix(2)), [.danger, .danger], "danger findings lead")
        XCTAssertEqual(Array(numbers.prefix(2)), [1, 2])
        XCTAssertTrue(numbers.dropFirst(2).allSatisfy { $0 == nil }, "the rest are not numbered")

        let v = view(brokenAppDoc())
        let chips = v.answerRows.compactMap { $0.lead as? NumberChip }
        XCTAssertEqual(chips.map(\.number), [1, 2])
        XCTAssertEqual(chips.map(\.fill), ["danger-strong", "danger-strong"])
        XCTAssertEqual(chips.first?.label.stringValue, "1")
        XCTAssertEqual(chips.first?.frame.size, NSSize(width: 16, height: 16), "16 pt (v2 V8)")
        XCTAssertTrue(v.answerRows.allSatisfy { $0.style == .full })
        XCTAssertEqual(v.answerRows.first?.questionField.stringValue, "Who made it?", "caution and danger ask with a question mark")

        let c = view(installerDoc())
        XCTAssertEqual(c.answerRows.compactMap { ($0.lead as? NumberChip)?.fill }, ["caution-strong", "caution-strong"])
    }

    /// A calm card lists its answers tight: no numbers, no hairlines, 12 pt words, 3 pt apart, questions plain.
    func testCalmCardUsesTheTightList() throws {
        let card = BinaryCard.make(document: calmAppDoc(), url: URL(fileURLWithPath: "/nonexistent/Orbit Demo.app"))
        XCTAssertEqual(card.verdict.level, .calm)
        XCTAssertEqual(card.verdict.title, "Signed by Developer ID Application: Example Co and notarized by Apple")
        XCTAssertEqual(card.verdict.reason, "Gatekeeper will open it without a warning.", "the trust design's calm sentence")
        XCTAssertEqual(card.verdict.chip, "Checks passed")
        XCTAssertTrue(card.numberedAnswers.allSatisfy { $0.number == nil })
        XCTAssertEqual(card.strip.map(\.label), ["Version", "Runs on", "Requires"])

        let v = view(calmAppDoc())
        XCTAssertEqual(v.verdictBox.fill, "fill")
        XCTAssertTrue(v.answerRows.allSatisfy { $0.style == .tight })
        XCTAssertFalse(v.answerRows.contains { $0.lead is NumberChip })
        XCTAssertFalse(v.answerRows.contains { row in row.subviews.contains { ($0 as? TokenBox)?.fill == "sep" } }, "no hairlines")
        XCTAssertEqual(v.answerRows.first?.questionField.stringValue, "Who made it")
        XCTAssertEqual(v.answerRows.first?.answerField.font?.pointSize, 12)
        let rows = v.answerRows
        let document = try XCTUnwrap(v.scrollView.documentView)
        XCTAssertTrue(document.isFlipped)
        for (a, b) in zip(rows, rows.dropFirst()) {
            let gap = b.convert(b.bounds, to: document).minY - a.convert(a.bounds, to: document).maxY
            XCTAssertEqual(gap, 3, accuracy: 0.5, "tight rows sit 3 pt apart")
        }
        let caution = view(installerDoc())
        XCTAssertGreaterThan(try XCTUnwrap(caution.answerRows.first).frame.height, try XCTUnwrap(rows.first).frame.height,
                             "full rows are taller than the tight list's")
    }

    /// Title 14/650 (fs-headline), the strip's numbers 650, the calm verdict 650 and the others 700.
    func testTitleWeightsFollowTheDesign() throws {
        let v = view(calmAppDoc())
        XCTAssertEqual(v.titleField.font?.pointSize, 14)
        // AppKit snaps systemFont(ofSize:weight:) to bold; the card sets SF's wght axis to 650 itself.
        XCTAssertEqual(try XCTUnwrap(fontWeightAxis(try XCTUnwrap(v.titleField.font))), 650, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(fontWeightAxis(try XCTUnwrap(v.verdictBox.titleField.font))), 650, accuracy: 0.5, "the calm verdict is 650")
        XCTAssertEqual(try XCTUnwrap(fontWeightAxis(try XCTUnwrap(v.stripValueFields.first?.font))), 650, accuracy: 0.5, "the strip's numbers")
        XCTAssertNotEqual(v.titleField.font, NSFont.systemFont(ofSize: 14, weight: .bold), "not snapped to bold")
        XCTAssertEqual(v.stripLabels.first?.stringValue, "Version", "sentence case, not upper case")
        XCTAssertEqual(v.stripLabels.first?.font?.pointSize, 11)
        let d = view(brokenAppDoc())
        XCTAssertEqual(weight(d.verdictBox.titleField.font), NSFont.Weight.bold.rawValue, accuracy: 0.01)
    }

    /// The tile is the drawn gradient: lighter at the top than the kind colour at the bottom, 32 pt; profiles are
    /// app-kind like the cards design draws them.
    func testKindTileIsAGradientOfTheKindColour() {
        let v = view(calmAppDoc())
        XCTAssertEqual(v.tile.token, "kind-app")
        XCTAssertEqual(v.tile.frame.size, NSSize(width: 32, height: 32))
        let c = v.tile.colors()
        func sum(_ color: NSColor) -> CGFloat {
            let c = color.usingColorSpace(.sRGB)!
            return c.redComponent + c.greenComponent + c.blueComponent
        }
        XCTAssertGreaterThan(sum(c.top), sum(c.bottom), "the top is the colour mixed with white")
        XCTAssertLessThan(sum(c.edge), sum(c.bottom), "the edge is darker than the colour")
        XCTAssertGreaterThan(sum(c.highlight), sum(c.top), "the top line is lighter still")
        XCTAssertEqual(BinaryCardView.tileToken(.provisioningProfile), "kind-app")
        XCTAssertEqual(BinaryCardView.tileToken(.installerPackage), "kind-app")
        XCTAssertEqual(BinaryCardView.tileToken(.diskImage), "kind-disk")
    }

    /// A small Quick Look window: the card scrolls instead of clipping, and every row stays inside the width.
    func testCardScrollsInASmallWindow() {
        let v = view(brokenAppDoc(), size: NSSize(width: 520, height: 260))
        XCTAssertFalse(v.isNarrow)
        XCTAssertFalse(v.stage.isHidden)
        XCTAssertGreaterThanOrEqual(v.stage.frame.height, 150)
        let document = try! XCTUnwrap(v.scrollView.documentView)
        XCTAssertGreaterThan(document.frame.height, v.scrollView.contentView.bounds.height, "taller than the window, so it scrolls")
        XCTAssertEqual(document.frame.width, v.scrollView.contentView.bounds.width, accuracy: 0.5, "never wider than the window")
        let last = try! XCTUnwrap(v.answerRows.last)
        XCTAssertLessThanOrEqual(last.convert(last.bounds, to: document).maxY, document.frame.height)
        for row in v.answerRows { XCTAssertLessThanOrEqual(row.convert(row.bounds, to: document).maxX, document.frame.width + 0.5) }
        v.scroll(to: 10_000)
        XCTAssertEqual(v.scrollView.contentView.bounds.maxY, document.frame.height, accuracy: 1, "scrolls to the end")
    }

    /// Finder's preview pane (under 420 pt): the stage steps aside, two numbers stay, the rows stack, nothing spills.
    func testNarrowPaneStepsTheStageAside() {
        let v = view(installerDoc(), size: NSSize(width: 280, height: 360))
        XCTAssertTrue(v.isNarrow)
        XCTAssertTrue(v.stage.isHidden)
        XCTAssertEqual(v.stage.frame.height, 0)
        XCTAssertEqual(v.stripCells.filter { !$0.isHidden }.count, 2)
        XCTAssertTrue(v.verdictBox.isNarrow)
        XCTAssertTrue(v.verdictBox.reasonField.isHidden)
        let document = try! XCTUnwrap(v.scrollView.documentView)
        for row in v.answerRows {
            XCTAssertTrue(row.isNarrow)
            XCTAssertGreaterThan(row.convert(row.answerField.frame, to: document).minY, row.convert(row.questionField.frame, to: document).minY,
                                 "the answer sits under the question")
            XCTAssertLessThanOrEqual(row.convert(row.bounds, to: document).maxX, document.frame.width + 0.5)
        }
        let chip = v.verdictBox.chip
        XCTAssertLessThanOrEqual(chip.convert(chip.bounds, to: v).maxX, v.bounds.width, "the chip stays in the pane")
        // Widening the pane brings the stage back.
        v.frame.size = NSSize(width: 800, height: 600)
        v.layoutSubtreeIfNeeded()
        XCTAssertFalse(v.isNarrow)
        XCTAssertFalse(v.stage.isHidden)
        XCTAssertEqual(v.stripCells.filter { !$0.isHidden }.count, 3)
    }

    /// ⌘I opens Details: 260 wide, every fact but the headline, closed again by the second press.
    func testDetailsInspectorToggles() {
        let v = view(calmAppDoc())
        XCTAssertFalse(v.isInspectorShown)
        v.toggleInspector()
        v.layoutSubtreeIfNeeded()
        XCTAssertTrue(v.isInspectorShown)
        XCTAssertEqual(v.inspector.frame.width, 260)
        XCTAssertEqual(v.scrollView.frame.width, 800 - 260)
        XCTAssertEqual(v.inspector.keys.first, "Name")
        XCTAssertTrue(v.inspector.values.contains("A1B2C3D4E5"))
        v.toggleInspector()
        v.layoutSubtreeIfNeeded()
        XCTAssertFalse(v.isInspectorShown)
        XCTAssertEqual(v.scrollView.frame.width, 800)
    }

    /// A profile names its kind, the app, the devices and certificates, and the days left (cards r3-a profile card).
    func testProfileCardWords() {
        let doc = PreviewDocument(kind: .provisioningProfile, facts: [
            Fact(key: "name", label: "Name", value: "Orbit Dev"),
            Fact(key: "team", label: "Team", value: "Example Co (A1B2C3D4E5)"),
            Fact(key: "platforms", label: "Platforms", value: "iOS"),
            Fact(key: "expires", label: "Expires", value: "6 Dec 2026"),
            Fact(key: "devices", label: "Devices", value: "12"),
            Fact(key: "appName", label: "App", value: "Orbit"),
            Fact(key: "distribution", label: "Distribution", value: "development"),
            Fact(key: "certificates", label: "Certificates", value: "2"),
            Fact(key: "expiresIn", label: "Expires in", value: "41 days"),
        ], badges: [], views: [.text("")])
        let card = BinaryCard.make(document: doc, url: URL(fileURLWithPath: "/nonexistent/Orbit_Dev.mobileprovision"))
        XCTAssertEqual(card.sentence, "A development profile for Orbit that lets 12 devices run builds signed by 2 certificates; it expires in 41 days.")
        XCTAssertEqual(card.bold, ["development profile", "expires in 41 days"])
        XCTAssertEqual(card.strip, [BinaryCard.Stat(value: "in 41 days", label: "Expires"), BinaryCard.Stat(value: "12", label: "Devices"),
                                    BinaryCard.Stat(value: "iOS", label: "Platforms")])
        XCTAssertEqual(card.answers.map(\.answer), ["Yes, for 41 more days", "Example Co (A1B2C3D4E5)", "Development, to 12 registered devices"])
        XCTAssertEqual(card.answers.first?.evidence, "profile expires 6 Dec 2026")
    }

    func testDaysLeft() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 15))!
        XCTAssertEqual(BinaryFacts.daysLeft(until: cal.date(from: DateComponents(year: 2026, month: 12, day: 9, hour: 9))!, from: now, calendar: cal), "41 days")
        XCTAssertEqual(BinaryFacts.daysLeft(until: cal.date(from: DateComponents(year: 2026, month: 10, day: 30))!, from: now, calendar: cal), "1 day")
        XCTAssertNil(BinaryFacts.daysLeft(until: cal.date(from: DateComponents(year: 2026, month: 10, day: 1))!, from: now, calendar: cal))
    }

    /// The test bundle sits inside the built Vitrine.app (hosted tests); when it is signed, the card is calm.
    func testBuiltVitrineAppIsCalmWhenSigned() async throws {
        var url = Bundle(for: Self.self).bundleURL
        while url.pathExtension != "app", url.path != "/" { url.deleteLastPathComponent() }
        guard url.pathExtension == "app" else { throw XCTSkip("the test bundle is not inside an app here") }
        let doc = try BinaryFacts.document(url: url, kind: .appBundle)
        guard doc.fact("signature")?.value.hasPrefix("Valid") == true else { throw XCTSkip("the built app is not validly signed here (\(doc.fact("signature")?.value ?? "?"))") }
        let card = BinaryCard.make(document: doc, url: url)
        if doc.fact("signerKind")?.value == "Not vouched for by Apple" {
            // A self-signed build (G-3) is intact but no certificate Apple vouches for stands behind it: a caution,
            // never a calm "Checks passed" (G-34, S-16).
            XCTAssertEqual(card.verdict.level, .caution)
            return
        }
        XCTAssertNil(card.rule)
        XCTAssertEqual(card.verdict.level, .calm)
        XCTAssertEqual(BinaryCardView.verdictBox(card.verdict).fill, "fill")
    }
}
