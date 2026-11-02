import XCTest
import WebKit
import VitrineDocument
import VitrineSupport
import VitrineUI
@testable import VitrinePreviewKit

/// A-4: the context-fit meter where chrome r3-b puts it (the Details inspector's "Tokens" section), the host's
/// Details sheet for text previews, the data Inspector's File tab and the Markdown column's foot. Pictures of the
/// meter, light and dark, land in the temporary folder for review. Invented text only.
@MainActor
final class TokenMeterViewTests: XCTestCase {
    private let readmeFacts = [
        Fact(key: "kindName", label: "Kind", value: "Markdown"),
        Fact(key: "size", label: "Size", value: "12.7 KB"),
        Fact(key: "lines", label: "Lines", value: "412"),
        Fact(key: "encoding", label: "Encoding", value: "UTF-8"),
        DocumentFacts.tokens(bytes: 12_720),
    ]

    private func sample(_ name: String, _ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-tokens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: The native meter

    func testTheMeterDrawsTheModel() {
        let count = TokenCounting.count(.byteCount(12_720))
        let view = TokenMeterView(meter: TokenMeter(count))
        XCTAssertEqual(view.numberField.stringValue, "≈ " + 3_180.formatted())
        XCTAssertEqual(view.unitField.stringValue, "Claude tokens, estimate", "the estimate is labelled as one")
        XCTAssertTrue(view.methodField.stringValue.contains("4 bytes a token"), "the method is named")
        XCTAssertEqual(view.rowFields.map(\.stringValue), TokenMeter(count).rows.map(\.text))
        XCTAssertEqual(view.bars.count, 2, "one bar per window the design draws (200K, 1M)")
        XCTAssertTrue(view.bars.allSatisfy { !$0.over })
        XCTAssertTrue(view.accessibilityLabel()?.contains("200K") == true)
    }

    /// G-29: the exact OpenAI line fills in from the text, and stays empty when the switch is off.
    func testTheExactOpenAILineFillsInAndHonoursTheSwitch() async throws {
        let count = TokenCount(value: 3, exactness: .estimate, method: ByteEstimateCounter.id)
        let suite = "vt-tokens-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let on = TokenMeterView(meter: TokenMeter(count), exactText: "hello world", defaults: defaults)
        await on.exactTask?.value
        XCTAssertEqual(on.exactField.stringValue, "OpenAI (o200k): 2 tokens, exact")
        // With the switch off, a model tokenizer.json beside the file still counts (it carries its own licence).
        defaults.set(false, forKey: TokenMeterView.exactKey)
        let off = TokenMeterView(meter: TokenMeter(count), exactText: "hello world", defaults: defaults)
        await off.exactTask?.value
        XCTAssertEqual(off.exactField.stringValue, "", "no OpenAI line, and no tokenizer.json beside it")
    }

    func testOverWindowBarsAreFullAndCaution() throws {
        let view = TokenMeterView(meter: TokenMeter(TokenCount(value: 480_000, exactness: .estimate, method: ByteEstimateCounter.id)))
        let (_, window) = host(view, width: 236)
        defer { window.orderOut(nil) }
        XCTAssertTrue(view.bars[0].over)
        XCTAssertEqual(view.bars[0].filledWidth, TokenMeterView.barWidth, "a window it does not fit is a full bar")
        XCTAssertFalse(view.bars[1].over)
        XCTAssertEqual(view.bars[1].filledWidth, (TokenMeterView.barWidth * 0.48).rounded(), accuracy: 0.5)
        XCTAssertTrue(view.rowFields[0].stringValue.hasPrefix("Over a 200K window"))
        let tiny = TokenMeterView(meter: TokenMeter(TokenCount(value: 12, exactness: .estimate, method: ByteEstimateCounter.id)))
        let (_, w2) = host(tiny, width: 236)
        defer { w2.orderOut(nil) }
        XCTAssertEqual(tiny.bars[1].filledWidth, TokenMeterView.MeterBar.sliver, "a share too small to see still shows")
    }

    func testDetailsShowsTheMeterInPlaceOfTheTokensRow() {
        let count = TokenCounting.count(.byteCount(12_720))
        let details = DetailsInspector(facts: readmeFacts, tokens: count)
        XCTAssertNotNil(details.tokenMeter)
        XCTAssertFalse(details.keys.contains("Tokens"), "the count is the meter, not a row as well")
        XCTAssertEqual(details.keys, ["Kind", "Size", "Lines", "Encoding"])
        let plain = DetailsInspector(facts: readmeFacts)
        XCTAssertNil(plain.tokenMeter, "a card without a count keeps its rows as they were")
        XCTAssertTrue(plain.keys.contains("Tokens"))
    }

    // MARK: Pictures

    func testPicturesLightAndDark() throws {
        let states: [(String, TokenCount)] = [
            ("readme", TokenCounting.count(.byteCount(12_720))),
            ("over", TokenCount(value: 480_000, exactness: .estimate, method: ByteEstimateCounter.id)),
            ("huge", TokenCount(value: 2_400_000, exactness: .estimate, method: ByteEstimateCounter.id)),
        ]
        for (name, count) in states {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let details = DetailsInspector(facts: readmeFacts, tokens: count)
                let (box, window) = host(details, width: DetailsInspector.width, height: 330, appearance: appearance)
                let url = try write(picture(box), "details-\(name)-\(mode)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                window.orderOut(nil)
            }
        }
    }

    // MARK: Where it shows

    func testThePlainTextPreviewOffersDetailsWithTheMeter() async throws {
        let url = try sample("tide-notes.txt", String(repeating: "High tide at Tidepool Bay is at 14:20 today.\n", count: 300))
        let controller = PreviewHostController()
        controller.loadView()
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = controller.view
        defer { window.orderOut(nil) }
        try await controller.preparePreviewOfFile(at: url)
        let capsule = controller.capsuleForTesting
        XCTAssertTrue(capsule.canToggleInspector, "a text preview without its own panel gets the host's Details")
        XCTAssertNil(controller.detailsForTesting)
        capsule.toggleInspector()
        controller.view.layoutSubtreeIfNeeded()
        let details = try XCTUnwrap(controller.detailsForTesting, "the capsule's inspector button opens Details")
        let meter = try XCTUnwrap(details.tokenMeter)
        let bytes = 300 * "High tide at Tidepool Bay is at 14:20 today.\n".utf8.count
        XCTAssertEqual(meter.meter.count, TokenCounting.count(.byteCount(bytes)))
        XCTAssertEqual(details.frame.width, DetailsInspector.width, accuracy: 0.5, "the sheet pushes the file, at the design's width")
        // The picture of the whole preview with the sheet open, light.
        try write(picture(controller.view), "host-plaintext-light")
        capsule.toggleInspector()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertNil(controller.detailsForTesting, "the button closes it again")
    }

    func testTheSheetStepsAsideInTheFinderPane() async throws {
        let url = try sample("narrow.txt", "Low tide.\n")
        let controller = PreviewHostController()
        controller.loadView()
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 280, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = controller.view
        defer { window.orderOut(nil) }
        try await controller.preparePreviewOfFile(at: url)
        controller.capsuleForTesting.toggleInspector()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertNil(controller.detailsForTesting, "a 280 pt pane leaves the file its room")
    }

    func testEveryTextFamilyCarriesACount() async throws {
        let csv = try sample("tides.csv", "day,high,low\nMon,14:20,08:05\nTue,15:02,08:49\n")
        let json = try sample("station.json", #"{"station":"Tidepool Bay","depth":4.2}"#)
        let swift = try sample("Tide.swift", "struct Tide { let height: Double }\n")
        let text = try sample("log.txt", "tide gauge ok\n")
        for url in [csv, json, swift, text] {
            let kind = FileSniffer.kind(of: url)
            let document = try PlainTextRenderer.textDocument(url: url, kind: kind)
            let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            XCTAssertEqual(document.tokens, TokenCounting.count(.byteCount(size)), url.lastPathComponent)
            XCTAssertEqual(document.fact("tokens")?.value, document.tokens?.formatted, url.lastPathComponent)
        }
    }

    func testTheDataInspectorEndsItsFileTabWithTheMeter() async throws {
        let url = try sample("tides.csv", "day,high,low\nMon,14:20,08:05\nTue,15:02,08:49\n")
        let preview = try await DataRenderer().render(url: url, kind: FileSniffer.kind(of: url), context: RenderContext(appearance: .light))
        let view = try XCTUnwrap(preview.view as? DataView)
        XCTAssertNotNil(preview.document.tokens)
        XCTAssertEqual(view.inspector.tokenMeter?.meter.count, preview.document.tokens)
        view.inspector.show(.column(0))
        XCTAssertNil(view.inspector.tokenMeter, "the meter belongs to the File tab")
        view.inspector.show(.file)
        XCTAssertNotNil(view.inspector.tokenMeter)
    }

    func testTheMarkdownColumnDrawsTheSameMeter() async throws {
        var doc = PreviewDocument(kind: .markdown(.commonMark), facts: readmeFacts, views: [.text("# Tidepool")])
        doc.setTokens(TokenCount(value: 480_000, exactness: .estimate, method: ByteEstimateCounter.id))
        let html = MarkdownColumn.factRows(doc)
        let meter = try XCTUnwrap(doc.tokenMeter)
        XCTAssertTrue(html.contains("sa-tok"))
        XCTAssertTrue(html.contains(NotebookHTML.escape(meter.number)))
        XCTAssertTrue(html.contains("Claude tokens, estimate"))
        for row in meter.rows {
            XCTAssertTrue(html.contains(NotebookHTML.escape(row.compactText)), "the narrow column uses the compact words: \(row.compactText)")
            XCTAssertTrue(html.contains("title=\"\(NotebookHTML.escape(row.text))\""), "the full sentence on hover: \(row.text)")
        }
        XCTAssertTrue(html.contains("sa-m over"), "the window it does not fit is marked")
        XCTAssertTrue(html.contains("width:100.0%"))
        XCTAssertFalse(html.contains("≈ 480,000 tokens</span>"), "the old count row is replaced by the meter")

        // The real page, light and dark, with the column open.
        let url = try sample("TIDES.md", "# Tidepool Bay\n\n## Tides\n\nHigh at 14:20.\n\n## Gauges\n\nAll reading.\n\n## Notes\n\n"
                             + String(repeating: "The bay fills twice a day. ", count: 400))
        for (mode, appearance) in [("light", DesignTokens.Appearance.light), ("dark", .dark)] {
            let context = RenderContext(appearance: appearance, defaultsSuite: "vt-tokens-suite",
                                        cachesDirectory: url.deletingLastPathComponent().appendingPathComponent("caches"))
            let preview = try await MarkdownRenderer().render(url: url, kind: .markdown(.commonMark), context: context)
            let web = try XCTUnwrap(preview.view as? WKWebView)
            web.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
            let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
            window.contentView = web
            try await Task.sleep(for: .milliseconds(600))
            let rows = try await web.evaluateJavaScript("document.querySelectorAll('.sa-tok .sa-m').length") as? Int
            XCTAssertEqual(rows, 2, "the column foot carries both windows")
            let image = try await web.takeSnapshot(configuration: nil)
            let png = try XCTUnwrap(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:]))
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-tokens-markdown-column-\(mode).png")
            try png.write(to: out)
            print("TokenMeterViewTests PNG: \(out.path)")
            window.orderOut(nil)
        }
    }

    // MARK: Hosting and pictures

    private func host(_ view: NSView, width: CGFloat, height: CGFloat = 200,
                      appearance: NSAppearance.Name = .aqua) -> (NSView, NSWindow) {
        let box = CardFlippedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: view is DetailsInspector ? 0 : 12),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: view is DetailsInspector ? 0 : -12),
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: view is DetailsInspector ? 0 : 10),
        ] + (view is DetailsInspector ? [view.bottomAnchor.constraint(equalTo: box.bottomAnchor)] : []))
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = box
        box.layoutSubtreeIfNeeded()
        box.displayIfNeeded()
        return (box, window)
    }

    private func picture(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    @discardableResult
    private func write(_ rep: NSBitmapImageRep, _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-tokens-\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("TokenMeterViewTests PNG: \(url.path)")
        return url
    }
}
