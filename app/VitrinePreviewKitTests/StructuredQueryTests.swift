import XCTest
@testable import VitrinePreviewKit
import VitrineData
import VitrineDocument
import VitrineSupport

/// jq in the query box over a structured file's Tree (I-8, G-17): which files offer it, outputs drawn as a tree,
/// one run per YAML document (and per JSON Lines line, for A-5's table), whole values (not the tree's cut previews), errors in jq's words,
/// limits said, and Clear bringing the file's tree back. Sample content is invented. roadmap: S-5
@MainActor
final class StructuredQueryTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-jq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func render(_ name: String, _ text: String) async throws -> (RenderedPreview, StructuredView) {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let renderer = StructuredRenderer()
        let preview = try await renderer.render(url: url, kind: FileSniffer.kind(of: url), context: RenderContext(appearance: .light, defaultsSuite: "vt-jq"))
        return (preview, try XCTUnwrap(renderer.view))
    }

    /// The top-level rows of the tree on screen.
    private func topRows(_ view: StructuredView) -> [String] {
        let outline = view.shownOutline!
        return (0..<outline.table.numberOfRows).compactMap { row in
            guard outline.table.level(forRow: row) == 0, let node = outline.table.item(atRow: row) as? StructuredOutline.NodeItem else { return nil }
            return outline.model.row(node.index, expanded: false).text.trimmingCharacters(in: .whitespaces)
        }
    }

    private let notes = """
    {"notes": [
      {"id": "n_0095", "title": "Grocery list", "pinned": false},
      {"id": "n_0096", "title": "Trip to Lisbon", "pinned": true},
      {"id": "n_0097", "title": "Book ideas", "pinned": true}
    ], "settings": {"theme": "harbor-light"}}
    """

    func testJSONOffersJQAndDrawsTheOutputsAsATree() async throws {
        let (preview, view) = try await render("notes.json", notes)
        XCTAssertEqual(preview.findModes, [.search, .query])
        XCTAssertEqual(preview.queryLanguage, "jq")
        let outcome = await preview.query!(".notes[] | select(.pinned) | .title")
        XCTAssertNil(outcome.message)
        XCTAssertEqual(outcome.rows, 2)
        XCTAssertTrue(outcome.summary.hasPrefix("2 results · "), outcome.summary)
        XCTAssertEqual(topRows(view).count, 2)
        XCTAssertEqual(topRows(view), ["Result 1: Trip to Lisbon", "Result 2: Book ideas"])

        preview.clearQuery!()
        XCTAssertNil(preview.gutter)
        XCTAssertNil(view.resultOutline)
        XCTAssertTrue(view.shownOutline === view.outline, "Clear brings the file's own tree back")
    }

    func testErrorsAreJQsOwnWordsAndRefusalsNameTheFeature() async throws {
        let (preview, _) = try await render("notes.json", notes)
        let error = await preview.query!(".notes[0].id | .a")
        XCTAssertEqual(error.rows, nil)
        XCTAssertEqual(error.message, "jq: error: Cannot index string with \"a\"")
        XCTAssertEqual(preview.gutter?.leading, error.message, "the message is said in the gutter, as SQL's is")
        let refused = await preview.query!("input")
        XCTAssertTrue(refused.message?.contains("not supported in Vitrine") == true, refused.message ?? "")
        let syntax = await preview.query!(".notes[")
        XCTAssertTrue(syntax.message?.contains("line 1") == true, syntax.message ?? "")
    }

    /// JSON Lines files have their own table (A-5, not built yet); the reader they will use is tested here.
    func testJSONLinesRunsOncePerLineAndSaysWhichLinesAreNotJSON() throws {
        let lines = (1...6).map { #"{"custom_id": "req-\#($0)", "result": {"type": "\#($0 % 3 == 0 ? "errored" : "succeeded")"}}"# }
        let text = (lines[0..<3] + ["{not json", ""] + lines[3...]).joined(separator: "\n") + "\n"
        let inputs = try StructuredQueryController.read(Data(text.utf8), format: .jsonLines)
        XCTAssertEqual(inputs.values.count, 6, "blank lines are skipped")
        XCTAssertEqual(inputs.note, "1 line is not JSON · line 4")
        let ran = StructuredQueryController.run(try JQ.compile(#"select(.result.type != "succeeded") | .custom_id"#), over: inputs.values)
        XCTAssertEqual(ran.outputs, [.string("req-3"), .string("req-6")])
    }

    func testYAMLDocumentsAreSeparateInputsAndValuesAreWhole() async throws {
        let long = String(repeating: "Lisbon ", count: 100)
        let (preview, _) = try await render("trips.yaml", "city: Kyoto\nnote: \(long)\n---\ncity: Porto\nnote: short\n")
        let count = await preview.query!(".city")
        XCTAssertEqual(count.rows, 2, "one output per YAML document")
        let length = await preview.query!("select(.city == \"Kyoto\") | .note | length")
        XCTAssertEqual(length.rows, 1)
        XCTAssertNil(length.note, "read whole: nothing cut")
        let program = try JQ.compile(".note | length")
        let inputs = try StructuredQueryController.read(Data("city: Kyoto\nnote: \(long)\n".utf8), format: .yaml)
        XCTAssertEqual(StructuredQueryController.run(program, over: inputs.values).outputs, [.number(Double(long.trimmingCharacters(in: .whitespaces).count))],
                       "the 700-byte string reaches jq whole, past the tree's 256-byte preview")
    }

    func testLimitsAreSharedAcrossInputsAndSaid() throws {
        let program = try JQ.compile("range(10)")
        var limits = JQLimits()
        limits.maxOutputs = 25
        let ran = StructuredQueryController.run(program, over: Array(repeating: .null, count: 5), limits: limits)
        XCTAssertEqual(ran.outputs.count, 25)
        XCTAssertNotNil(ran.stoppedReason)
        XCTAssertNil(ran.error)
    }

    func testAnErrorAfterOutputsKeepsThemAndSaysTheError() throws {
        let program = try JQ.compile(".a")
        let ran = StructuredQueryController.run(program, over: [try JQValue(json: #"{"a": 1}"#), .number(3)])
        XCTAssertEqual(ran.outputs, [.number(1)])
        XCTAssertEqual(ran.error, "jq: error: Cannot index number with \"a\"")
    }

    func testTheResultTreeFillsTheWidthOfAViewInAWindow() async throws {
        let (preview, view) = try await render("notes.json", notes)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        _ = await preview.query!(".notes[0]")
        let column = try XCTUnwrap(view.shownOutline?.table.tableColumns.first)
        XCTAssertEqual(column.width, view.treeScroll.contentView.bounds.width, accuracy: 1, "a swapped-in tree is not squeezed")
    }

    func testXMLAndBrokenFilesKeepFindOnly() async throws {
        let (xml, _) = try await render("feed.xml", "<feed><item>Kyoto</item></feed>")
        XCTAssertEqual(xml.findModes, [.search])
        let (broken, _) = try await render("broken.json", "{\"notes\": [1, 2,,]}")
        XCTAssertEqual(broken.findModes, [.search], "a file with a syntax error opens on its Source, where jq is not offered")
    }
}
