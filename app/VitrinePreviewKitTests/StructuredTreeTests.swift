import XCTest
@testable import VitrinePreviewKit
import VitrineData
import VitrineDocument
import VitrineSupport

/// The structured Tree (S-5, code design states 5, 9 and 10): its shape for JSON, YAML, TOML and a binary property
/// list, the viewer switch, bounded find, the selected node's path and per-node copy. Sample content is invented.
@MainActor
final class StructuredTreeTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func render(_ url: URL) async throws -> (StructuredRenderer, RenderedPreview, StructuredOutline) {
        let kind = FileSniffer.kind(of: url)
        XCTAssertTrue(StructuredRenderer.canRender(kind), "\(kind)")
        let renderer = StructuredRenderer()
        let preview = try await renderer.render(url: url, kind: kind, context: RenderContext(appearance: .light, defaultsSuite: "vt-tree"))
        return (renderer, preview, try XCTUnwrap(renderer.outlineForTesting))
    }

    /// Each visible row as "key: value [count]", indented two spaces per level.
    private func visibleRows(_ outline: StructuredOutline) -> [String] {
        (0..<outline.table.numberOfRows).map { row in
            let item = outline.table.item(atRow: row)
            let indent = String(repeating: "  ", count: outline.table.level(forRow: row))
            switch item {
            case let node as StructuredOutline.NodeItem:
                let r = outline.model.row(node.index, expanded: outline.table.isItemExpanded(node))
                return indent + r.text.trimmingCharacters(in: .whitespaces) + (r.count.map { " [\($0)]" } ?? "")
            case let more as StructuredOutline.MoreItem: return indent + "more \(more.range)"
            case let note as StructuredOutline.NoteItem: return indent + "note " + note.text
            default: return indent + "?"
            }
        }
    }

    private let notesJSON = """
    {
      "notes": [
        {"id": "n_0095", "title": "Grocery list", "pinned": false, "attachments": []},
        {"id": "n_0096", "title": "Trip to Lisbon", "pinned": true, "attachments": []},
        {"id": "n_0097", "title": "Book ideas", "pinned": false, "attachments": []},
        {"id": "n_0098", "title": "Kitchen renovation", "createdAt": "2026-09-30T18:02:44Z", "tags": ["home", "budget"],
         "attachments": [{"name": "quote-v2.pdf", "size": 184320, "type": "application/pdf"}]}
      ],
      "settings": {"theme": "harbor-light", "sync": true, "fontSize": 14, "backup": null}
    }
    """

    // MARK: Shape

    func testJSONTreeOpensFirstWithKeysCountsAndTypes() async throws {
        let (_, preview, outline) = try await render(try file("notes-export.json", notesJSON))
        XCTAssertEqual(preview.document.viewTitles, ["Tree", "Source"], "Tree opens first; Source one switch away")
        XCTAssertEqual(visibleRows(outline), [
            "notes: [4 items]",
            "  0: { id, title, pinned, … } [4 keys]",
            "  1: { id, title, pinned, … } [4 keys]",
            "  2: { id, title, pinned, … } [4 keys]",
            "  3: { id, title, createdAt, … } [5 keys]",
            "settings: [4 keys]",
            "  theme: \"harbor-light\"",
            "  sync: true",
            "  fontSize: 14",
            "  backup: null",
        ], "the root object's keys are the top rows; level 2 stays folded")
        let settings = try XCTUnwrap(outline.rows(nil).compactMap { $0 as? StructuredOutline.NodeItem }.last)
        let theme = try XCTUnwrap(outline.rows(settings.index).first as? StructuredOutline.NodeItem)
        let row = outline.model.row(theme.index, expanded: false)
        XCTAssertEqual(row.typeTag, "String")
        XCTAssertEqual(row.segments.last?.token, "syn-str")
        XCTAssertEqual(preview.document.searchText, notesJSON, "copy and Spotlight still read the source")
    }

    func testYAMLTreeReadsBareStringsAndInlinePreviews() async throws {
        let yaml = """
        app:
          name: harbor-sync
          port: 8443
          debug: false
        workers:
          - { name: push, every: 2s }
          - { name: pull, every: 30s }
        """
        let (_, preview, outline) = try await render(try file("config.yaml", yaml))
        XCTAssertEqual(preview.document.viewTitles, ["Tree", "Source"])
        XCTAssertEqual(visibleRows(outline), [
            "app: [3 keys]",
            "  name: harbor-sync",
            "  port: 8443",
            "  debug: false",
            "workers: [2 items]",
            "  0: { name, every } [2 keys]",
            "  1: { name, every } [2 keys]",
        ])
    }

    func testTOMLTreeShowsTablesAndArraysOfTables() async throws {
        let toml = """
        title = "Harbor Notes"

        [server]
        host = "sync.example.com"
        port = 8443

        [[workers]]
        name = "push"

        [[workers]]
        name = "pull"
        """
        let (_, _, outline) = try await render(try file("settings.toml", toml))
        XCTAssertEqual(visibleRows(outline), [
            "title: \"Harbor Notes\"",
            "server: [2 keys]",
            "  host: \"sync.example.com\"",
            "  port: 8443",
            "workers: [2 items]",
            "  0: { name } [1 key]",
            "  1: { name } [1 key]",
        ])
    }

    func testBinaryPropertyListIsATypedTreeWithAnXMLView() async throws {
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.acmenotes", "ACTrialDays": 14,
                                    "NSAppTransportSecurity": ["NSAllowsArbitraryLoads": false],
                                    "CFBundleDocumentTypes": ["Acme Note", "Plain Text"], "ACIconHash": Data(count: 32)]
        let url = dir.appendingPathComponent("Settings.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
        XCTAssertEqual(FileSniffer.kind(of: url), .code(language: "plist"), "a bplist is structured data, not an unknown binary")
        // An app's own Info.plist is the Apple development card in plain words (E-5); its Source is the XML form.
        let info = dir.appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: info)
        XCTAssertEqual(FileSniffer.kind(of: info), .reader("apple.file"))
        let (_, preview, outline) = try await render(url)
        XCTAssertEqual(preview.document.viewTitles, ["Tree", "XML"], "state 9: Tree · XML")
        guard case .code(let xml, "xml") = preview.document.views[1] else { return XCTFail("the source view is the XML form") }
        XCTAssertTrue(xml.contains("<key>CFBundleIdentifier</key>"), xml)
        XCTAssertEqual(visibleRows(outline), [
            "Root: [Dictionary · 5 keys]",
            "  ACIconHash: 32 bytes",
            "  ACTrialDays: 14",
            "  CFBundleDocumentTypes: [Array · 2 items]",
            "    0: Acme Note",
            "    1: Plain Text",
            "  CFBundleIdentifier: com.example.acmenotes",
            "  NSAppTransportSecurity: [Dictionary · 1 key]",
            "    NSAllowsArbitraryLoads: NO",
        ], "keys sorted as plutil -p shows a binary plist; booleans read YES / NO")
    }

    func testXMLElementsCarryAttributesAndTheirText() async throws {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0"><channel><title>Harbor Notes releases</title>
        <item><title>Harbor Notes 3.2</title><guid isPermaLink="false">harbor-3.2.0</guid></item></channel></rss>
        """
        let (_, _, outline) = try await render(try file("changelog.xml", xml))
        XCTAssertEqual(visibleRows(outline), [
            "<rss> version=\"2.0\" [1 child]",
            "  <channel> [2 children]",
            "    <title> Harbor Notes releases",
            "    <item> Harbor Notes 3.2 [2 children]",
        ])
    }

    // MARK: Paging, find, path, copy

    func testLargeArrayPagesAndFindIsBounded() async throws {
        let items = (0..<450).map { "{\"id\": \"n_\($0)\", \"note\": \"\($0 == 420 ? "needle" : "hay")\"}" }
        let (_, _, outline) = try await render(try file("big.json", "{\"notes\": [\(items.joined(separator: ","))], \"meta\": {\"v\": 1}}"))
        let notes = try XCTUnwrap(outline.rows(nil).first as? StructuredOutline.NodeItem)
        XCTAssertFalse(outline.table.isItemExpanded(notes), "a 450-row container stays folded on the first paint")
        XCTAssertTrue(outline.table.isItemExpanded(try XCTUnwrap(outline.rows(nil).last as? StructuredOutline.NodeItem)), "its small sibling opens")
        XCTAssertEqual(outline.rows(notes.index).count, StructuredOutline.pageSize + 1, "one page, then a more row")

        let found = outline.find("needle", forward: true)
        XCTAssertEqual(found, FindResult(count: 1, index: 0, searchedAll: true))
        let selected = try XCTUnwrap(outline.selectedNode)
        XCTAssertEqual(outline.model.path(of: selected), "$.notes[420].note", "find reveals the match past the first page")
        XCTAssertEqual(visibleRows(outline).filter { $0.contains("more") || $0.contains("above") }.count, 2,
                       "the page moved onto the match: rows above and below it are placeholders")

        outline.clearFind()
        let bounded = outline.find("needle", forward: true, limit: 100)
        XCTAssertEqual(bounded, FindResult(count: 0, index: -1, searchedAll: false), "the search stopped at its bound and says so")
        outline.clearFind()
        let hay = outline.find("hay", forward: true, limit: 200)
        XCTAssertFalse(hay.searchedAll)
        XCTAssertGreaterThan(hay.count, 0)
    }

    func testSelectedNodePathAndPerNodeCopy() async throws {
        let (renderer, _, outline) = try await render(try file("notes-export.json", notesJSON))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vt-tree-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        outline.pasteboard = pasteboard
        _ = outline.find("184320", forward: true)
        let size = try XCTUnwrap(outline.selectedNode)
        XCTAssertEqual(outline.model.path(of: size), "$.notes[3].attachments[0].size")
        XCTAssertEqual(renderer.view?.pathBar.components, ["$", "notes", "[3]", "attachments", "[0]", "size"], "the path row follows the selection")

        outline.copyPath(of: size)
        XCTAssertEqual(pasteboard.string(forType: .string), "$.notes[3].attachments[0].size")
        outline.copyValue(of: size)
        XCTAssertEqual(pasteboard.string(forType: .string), "184320")

        let title = try XCTUnwrap(outline.model.tree.parent(named: "title", under: outline.model.tree.parentIndex(of: size, levels: 3)))
        outline.copyValue(of: title)
        XCTAssertEqual(pasteboard.string(forType: .string), "Kitchen renovation", "a string's value without its quotes")

        let attachment = try XCTUnwrap(outline.model.tree[size].parent)
        outline.copyValue(of: attachment)
        XCTAssertEqual(pasteboard.string(forType: .string), #"{"name": "quote-v2.pdf", "size": 184320, "type": "application/pdf"}"#,
                       "a container copies its source text")
    }

    func testPropertyListContainerCopiesAsJSON() async throws {
        let url = dir.appendingPathComponent("prefs.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Window": ["Width": 800, "Title": "Notes \"main\""]], format: .binary, options: 0).write(to: url)
        let (_, _, outline) = try await render(url)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("vt-tree-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        outline.pasteboard = pasteboard
        _ = outline.find("Window", forward: true)
        outline.copyValue(of: try XCTUnwrap(outline.selectedNode))
        XCTAssertEqual(pasteboard.string(forType: .string), "{\n  \"Title\": \"Notes \\\"main\\\"\",\n  \"Width\": 800\n}")
    }

    // MARK: Errors, caps and the viewer switch

    func testSyntaxErrorOpensOnSourceAndTheTreeEndsInTheError() async throws {
        let (renderer, preview, outline) = try await render(try file("settings.jsonc", "{\n  // editor\n  \"a\": 1\n  \"b\": 2\n}\n"))
        XCTAssertEqual(preview.document.viewTitles, ["Source", "Tree"], "a broken file opens on its source")
        XCTAssertEqual(preview.document.badges.first?.level, .caution, "the syntax-error badge stays")
        let view = try XCTUnwrap(renderer.view)
        XCTAssertFalse(view.showsTree)
        XCTAssertTrue(preview.showView?(1) == true)
        XCTAssertTrue(view.showsTree)
        XCTAssertTrue(visibleRows(outline).last?.hasPrefix("note Line 4:") == true, visibleRows(outline).description)
    }

    func testMinifiedJSONKeepsItsFormattedView() async throws {
        let body = (0..<200).map { "\"key\($0)\":\($0)" }.joined(separator: ",")
        let (_, preview, _) = try await render(try file("theme.min.json", "{\(body)}"))
        XCTAssertEqual(preview.document.viewTitles, ["Tree", "Formatted", "Source"])
        XCTAssertEqual(preview.showView?(1), false, "the host shows Formatted as text")
    }

    func testAboveTheParseCapShowsSource() async throws {
        let url = dir.appendingPathComponent("huge.json")
        var data = Data("[".utf8)
        let chunk = Data(String(repeating: "\"padding-text-for-a-big-file\",", count: 4096).utf8)
        while Int64(data.count) <= FamilyFacts.parseLimit { data.append(chunk) }
        data.append(Data("0]".utf8))
        try data.write(to: url)
        let renderer = StructuredRenderer()
        let preview = try await renderer.render(url: url, kind: .code(language: "json"), context: RenderContext(appearance: .light, defaultsSuite: "vt-tree"))
        XCTAssertNil(renderer.outlineForTesting, "no tree above the cap")
        XCTAssertTrue((preview.view as? NSScrollView)?.documentView is NSTextView, "the source, streamed")
        XCTAssertFalse(preview.document.coverage.isComplete, "and the frame says it is partial")
    }

    func testViewerSwitchMovesBetweenTreeAndSourceInTheHost() async throws {
        let url = try file("config.yaml", "app:\n  name: harbor-sync\n")
        let controller = PreviewHostController()
        controller.loadView()
        try await controller.preparePreviewOfFile(at: url)
        let capsule = controller.capsuleForTesting
        XCTAssertEqual(capsule.viewTitles, ["Tree", "Source"])
        let tree = try XCTUnwrap(controller.view.allSubviews.compactMap { $0 as? StructuredView }.first)
        XCTAssertFalse(tree.isHidden)
        capsule.selectView(1)
        XCTAssertTrue(tree.isHidden, "Source replaces the tree")
        let text = controller.view.allSubviews.compactMap { $0 as? NSTextView }.first { !$0.enclosingScrollView!.isHidden }
        XCTAssertEqual(text?.string, "app:\n  name: harbor-sync\n")
        capsule.selectView(0)
        XCTAssertFalse(tree.isHidden, "and the tree comes back")
        XCTAssertTrue(tree.showsTree)
    }
}

private extension StructuredTree {
    /// The ancestor `levels` up from `node`.
    func parentIndex(of node: Int, levels: Int) -> Int {
        var current = node
        for _ in 0..<levels { current = self[current].parent ?? current }
        return current
    }

    /// The child of `parent` with key `name`.
    func parent(named name: String, under parent: Int) -> Int? { children(of: parent).first { self[$0].name == name } }
}
