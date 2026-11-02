import AppKit
import XCTest
@testable import VitrinePreviewKit
import VitrineBinary
import VitrineDocument
import VitrineSupport

/// S-16 follow-up A: the flaw classes of the first lanes at the sites they could not touch. Page-supplied numbers in
/// every web page's messages and find answers go through one checked helper (`PageNumbers`) with an honest range;
/// the notebook rebuild drops only the tag of a void element; the binary card never waits on the main thread for
/// the full signature check and changes in place when it ends. All inputs are invented in the test. roadmap: S-16
@MainActor
final class S16FollowATests: XCTestCase {

    // MARK: The shared helper

    func testPageNumbersTakeOnlyNumbersInRange() {
        XCTAssertEqual(PageNumbers.integer(250.4, in: 160...360), 250)
        XCTAssertEqual(PageNumbers.integer(NSNumber(value: 7), in: 0...9), 7)
        for bad: Any in [true, false, Double.nan, -Double.infinity, 1e300, Double(Int.max), "3", NSNull(), [3]] {
            XCTAssertNil(PageNumbers.integer(bad, in: Int.min...Int.max), "\(bad)")
        }
        XCTAssertNil(PageNumbers.index(0, in: 0..<0), "nothing indexes an empty list")
        XCTAssertEqual(PageNumbers.index(2, in: 0..<3), 2)
        XCTAssertNil(PageNumbers.index(3, in: 0..<3), "an index past the end")
        XCTAssertNil(PageNumbers.index(-1, in: 0..<3))
        XCTAssertNil(PageNumbers.scrollOffset(Double.nan))
        XCTAssertNil(PageNumbers.scrollOffset(-5.0))
        XCTAssertEqual(PageNumbers.scrollOffset(120.5), 120.5)
    }

    /// A find answer's current match lies inside its count; before, `index + 1` in the capsule trapped on Int.max.
    func testAFindAnswerKeepsItsIndexInsideItsCount() {
        XCTAssertTrue(PageNumbers.matches(["count": 3.0, "index": 2.0]) == (3, 2))
        XCTAssertTrue(PageNumbers.matches(["count": 3.0, "index": Double(Int.max)]) == (3, -1))
        XCTAssertTrue(PageNumbers.matches(["count": 3.0, "index": 3.0]) == (3, -1), "the index is 0-based")
        XCTAssertTrue(PageNumbers.matches(["count": Double.infinity, "index": 0.0]) == (0, -1))
        XCTAssertTrue(PageNumbers.matches(["count": -4.0, "index": -1.0]) == (0, -1))
        XCTAssertTrue(PageNumbers.matches(nil) == (0, -1))
    }

    // MARK: Code (CodeRenderer)

    func testCodeLinesAreCountedAsTheEditorCountsThem() {
        XCTAssertEqual(CodeRenderer.lineCount(""), 1)
        XCTAssertEqual(CodeRenderer.lineCount("a\nb"), 2)
        XCTAssertEqual(CodeRenderer.lineCount("a\r\nb\r\n"), 3)
        XCTAssertEqual(CodeRenderer.lineCount("a\rb\rc"), 3, "a lone CR breaks a line in CodeMirror too")
    }

    /// A selection is held to the lines the page holds. Before: `to - from + 1` trapped on a forged pair.
    func testASelectionOutsideTheShownLinesIsIgnored() {
        let renderer = CodeRenderer()   // nothing shown yet: one empty line
        renderer.receive(["type": "selection", "from": -9.2e18, "to": 9.2e18, "empty": false])
        XCTAssertNil(renderer.selectedLines)
        renderer.receive(["type": "selection", "from": Double.nan, "to": 1.0, "empty": false])
        XCTAssertNil(renderer.selectedLines)
        renderer.receive(["type": "selection", "from": 1.0, "to": 2.0, "empty": false])
        XCTAssertNil(renderer.selectedLines, "line 2 is not on the page")
        renderer.receive(["type": "selection", "from": 1.0, "to": 1.0, "empty": false])
        XCTAssertTrue(renderer.selectedLines.map { $0 == (1, 1) } ?? false)
    }

    /// Forged first-paint reports, log counts, windows and encodings change nothing and never trap.
    func testOtherCodeMessagesHoldTheirRanges() {
        let renderer = CodeRenderer()
        renderer.receive(["type": "ready", "ms": 1e300, "lang": "swift"])
        XCTAssertEqual(renderer.readyReport?.ms, -1, "a broken timing is not a measurement")
        renderer.receive(["type": "ready", "ms": 41.0, "lang": "swift"])
        XCTAssertEqual(renderer.readyReport?.ms, 41)
        renderer.receive(["type": "log", "errors": 1e300, "warnings": -1e300])
        renderer.receive(["type": "window", "line": Double.infinity, "first": -1e300, "dy": Double.nan])
        renderer.receive(["type": "reopen", "encoding": -1.0])
        renderer.receive(["type": "reopen", "encoding": 1e300])
        renderer.receive(["type": "scroll", "y": Double.nan])
    }

    /// A display option is saved only as the kind of value it is read back as: a null or an object is not even a
    /// valid setting (UserDefaults raises on it), a size outside its range is not a size.
    func testDisplayOptionsAreCheckedBeforeTheyAreSaved() {
        XCTAssertEqual(CodeRenderer.optionValue(14.0, for: "fontSize") as? Int, 14)
        XCTAssertNil(CodeRenderer.optionValue(1e300, for: "fontSize"))
        XCTAssertNil(CodeRenderer.optionValue(NSNull(), for: "fontSize"))
        XCTAssertEqual(CodeRenderer.optionValue(8.0, for: "tabSize") as? Int, 8)
        XCTAssertNil(CodeRenderer.optionValue(3.0, for: "tabSize"))
        XCTAssertEqual(CodeRenderer.optionValue(true, for: "wrap") as? Bool, true)
        XCTAssertNil(CodeRenderer.optionValue(1.0, for: "wrap"))
        XCTAssertNil(CodeRenderer.optionValue(["a": NSNull()], for: "theme"))
        XCTAssertEqual(CodeRenderer.optionValue("roomy", for: "lineHeight") as? String, "roomy")
        XCTAssertNil(CodeRenderer.optionValue("huge", for: "lineHeight"))
        XCTAssertNil(CodeRenderer.optionValue("x", for: "notAnOption"))
    }

    // MARK: Diff (DiffRenderer)

    /// A file index must be one of the patch's files. Before: any number became `currentFile` (and the gutter's
    /// `currentFile + 1` trapped on Int.max).
    func testADiffFileIndexOutsideThePatchIsIgnored() {
        let renderer = DiffRenderer()   // no files
        for bad: Any in [Double(Int.max), 9.2e18, -3.0, Double.nan, 1.0] {
            renderer.receive(["type": "current", "index": bad])
            XCTAssertEqual(renderer.currentFile, 0, "\(bad)")
            renderer.receive(["type": "rows", "index": bad])
        }
    }

    // MARK: Notebook (NotebookRenderer)

    /// The coloured-block count is at most the page's code elements. Before: each report was added unchecked, so
    /// two forged reports overflowed the total.
    func testANotebookColourCountIsHeldToThePagesCodeBlocks() {
        let renderer = NotebookRenderer()   // no page: no code elements
        renderer.receive(["name": "fences", "body": 9.2e18])
        renderer.receive(["name": "fences", "body": 9.2e18])
        XCTAssertEqual(renderer.colouredBlocks, 0)
        renderer.receive(["name": "fences", "body": 0.0])
        XCTAssertEqual(renderer.colouredBlocks, 0)
        XCTAssertEqual(NotebookRenderer.codeElementCount(in: "<div class=\"cb\"><pre><code class=\"language-python\">x</code></pre></div><CODE>y</CODE>"), 2)
    }

    // MARK: Notebook outputs (NotebookHTML)

    /// `<embed>` is void: only its tag goes. Before: the rebuild looked for `</embed>` and dropped everything after.
    func testOutputAfterAnEmbedSurvives() {
        let out = NotebookHTML.sanitize("<p>before</p><embed src=\"x.swf\"><p>after</p>")
        XCTAssertEqual(out, "<p>before</p><p>after</p>")
        XCTAssertEqual(NotebookHTML.sanitize("a<embed type=\"x\"/>b</embed>c"), "abc")
        XCTAssertEqual(NotebookHTML.sanitize("a<frame src=\"x\">b"), "ab", "<frame> is void too")
    }

    /// A self-closing `<svg/>` has no content in a browser; only its tag goes. An open `<svg>` still takes its content.
    func testASelfClosingForeignElementDropsOnlyItsTag() {
        XCTAssertEqual(NotebookHTML.sanitize("a<svg/>b"), "ab")
        XCTAssertEqual(NotebookHTML.sanitize("a<math display=\"block\" />b"), "ab")
        XCTAssertEqual(NotebookHTML.sanitize("a<svg><text>hidden</text></svg>b"), "ab")
        XCTAssertEqual(NotebookHTML.sanitize("a<svg width=10/>hidden</svg>b"), "ab", "an unquoted value's slash is the value's")
        XCTAssertEqual(NotebookHTML.sanitize("a<script>bad()</script>b"), "ab", "content-bearing drops still take their content")
    }

    // MARK: The binary card's signature check (BinaryCardRenderer)

    private var savedAssess: (@Sendable (URL, Duration) -> SignatureAssessment)?
    private var savedFirstLook: Duration?

    override func setUp() async throws {
        savedAssess = BinaryCardRenderer.assessSignature
        savedFirstLook = BinaryCardRenderer.firstLookBudget
    }

    override func tearDown() async throws {
        if let savedAssess { BinaryCardRenderer.assessSignature = savedAssess }
        if let savedFirstLook { BinaryCardRenderer.firstLookBudget = savedFirstLook }
    }

    private func fakeApp() throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("vt-s16fa-\(UUID().uuidString)/Orbit Demo.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleName": "Orbit Demo", "CFBundleIdentifier": "com.example.orbit-demo",
                                   "CFBundleShortVersionString": "2.4.0", "CFBundleVersion": "240", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    /// A check that stalls: the first look sees the quick result, the full result waits for `release`.
    private static func stalledCheck(release: DispatchSemaphore) -> @Sendable (URL, Duration) -> SignatureAssessment {
        let quick = SignatureAssessment(status: .valid, depth: .quick, anchor: .developerID, teamIdentifier: "ABCDE12345")
        return { _, budget in
            if budget < .seconds(10) {
                Thread.sleep(forTimeInterval: Double(budget.components.seconds) + Double(budget.components.attoseconds) / 1e18)
                return quick.outOfTimeForTest()
            }
            release.wait()
            return SignatureAssessment(status: .valid, depth: .full, anchor: .developerID, teamIdentifier: "ABCDE12345")
        }
    }

    /// The first render returns without waiting for a stalled check, says it is still checking, then changes in
    /// place to the full verdict. Before: the render waited on the main actor for up to 4 s, and never updated.
    func testTheCardRendersAtOnceThenUpdatesInPlace() async throws {
        let app = try fakeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent().deletingLastPathComponent()) }
        let release = DispatchSemaphore(value: 0)
        BinaryCardRenderer.assessSignature = Self.stalledCheck(release: release)
        BinaryCardRenderer.firstLookBudget = .milliseconds(100)

        let renderer = BinaryCardRenderer()
        let clock = ContinuousClock()
        var rendered: RenderedPreview?
        let elapsed = try await clock.measure {
            rendered = try await renderer.render(url: app, kind: .appBundle, context: RenderContext(appearance: .light, defaultsSuite: nil))
        }
        let preview = try XCTUnwrap(rendered)
        XCTAssertLessThan(elapsed, .seconds(2), "the render does not wait for the full check")
        let view = try XCTUnwrap(preview.view as? BinaryCardView)
        XCTAssertEqual(preview.document.fact("signature")?.value, BinaryFacts.partlyCheckedWord)
        XCTAssertEqual(preview.gutter, BinaryCardRenderer.checkingStatus, "the card says it is still checking")
        XCTAssertEqual(view.card.verdict.level, .caution)
        XCTAssertTrue(preview.document.badges.contains(BinaryFacts.notFullyCheckedBadge))

        release.signal()
        let task = try XCTUnwrap(renderer.followUp.current)
        await task.value
        XCTAssertTrue(preview.view === view, "the same view, changed in place")
        XCTAssertEqual(preview.document.fact("signature")?.value, "Valid")
        XCTAssertFalse(preview.document.badges.contains(BinaryFacts.notFullyCheckedBadge))
        XCTAssertNil(preview.gutter, "the checking line goes when the check ends")
        XCTAssertEqual(view.card, BinaryCard.make(document: preview.document, url: app))
        XCTAssertEqual(view.answerRows.count, view.card.numberedAnswers.count)
        XCTAssertTrue(view.inspector.values.contains("Valid"), "Details lists the final verdict")
        XCTAssertEqual(view.inspector.isHidden, true, "Details stays as it was")
    }

    /// A preview closed before the check ends cancels its wait; the late result is dropped without a trace.
    func testAPreviewClosedFirstDropsTheLateResult() async throws {
        let app = try fakeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent().deletingLastPathComponent()) }
        let release = DispatchSemaphore(value: 0)
        BinaryCardRenderer.assessSignature = Self.stalledCheck(release: release)
        BinaryCardRenderer.firstLookBudget = .milliseconds(50)

        var renderer: BinaryCardRenderer? = BinaryCardRenderer()
        var preview: RenderedPreview? = try await renderer?.render(url: app, kind: .appBundle,
                                                                   context: RenderContext(appearance: .light, defaultsSuite: nil))
        let task = try XCTUnwrap(renderer?.followUp.current)
        XCTAssertNotNil(preview)
        preview = nil
        renderer = nil
        XCTAssertTrue(task.isCancelled, "closing the preview cancels the wait")
        release.signal()
        await task.value   // returns without touching anything
    }
}

private extension SignatureAssessment {
    /// The quick result as SignatureVerifier returns it when the budget ran out (its own `outOfTime()` is internal).
    func outOfTimeForTest() -> SignatureAssessment {
        SignatureAssessment(status: status, depth: .quick, ranOutOfTime: true, anchor: anchor, notarization: notarization,
                            ticketFile: ticketFile, identifier: identifier, teamIdentifier: teamIdentifier, format: format,
                            certificates: certificates, signingTime: signingTime, secureTimestamp: secureTimestamp, flags: flags,
                            entitlements: entitlements, cdHash: cdHash)
    }
}
