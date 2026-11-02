import XCTest
import PDFKit
import VitrinePreviewKit

/// Finder Quick Actions (X-5), made from invented files in a temporary folder. The clipboard is always a private
/// pasteboard with a unique name, released after each test; the real one is never touched. roadmap: S-10 (X-5)
@MainActor
final class QuickActionsTests: XCTestCase {
    private var folders: [URL] = []
    private var pasteboards: [NSPasteboard] = []

    override func tearDown() async throws {
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        pasteboards = []; folders = []
    }

    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-quickaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folders.append(dir)
        return dir
    }

    func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("vt-quickaction-test-\(UUID().uuidString)"))
        pasteboards.append(board)
        return board
    }

    @discardableResult
    func write(_ text: String, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The source folder (app/), from this file's place.
    static let appFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    // MARK: Copy as Prompt (I-11)

    func testAFileIsCopiedAsItsPathAndNumberedLinesInTheCodeViewsForm() throws {
        let dir = try folder()
        let url = try write("func tide() -> Double {\n    return 2.5\n}\n", "Tide.swift", in: dir)
        let result = PromptCopy.build([url])
        let body = "\(url.path) (3 lines):\n\n```swift\n1  func tide() -> Double {\n2      return 2.5\n3  }\n```\n"
        XCTAssertTrue(result.text.hasSuffix(body), result.text)
        XCTAssertTrue(result.text.hasPrefix("1 file from Vitrine · ≈ \(PromptCopy.tokens(body)) tokens\n\n"), result.text)
        XCTAssertEqual(result.tokens, PromptCopy.tokens(result.text))
        XCTAssertEqual(result.filesCopied, 1)
        XCTAssertEqual(result.secretsMasked, 0)
    }

    func testLineNumbersArePaddedAndAFenceInsideTheFileGetsALongerFence() throws {
        let dir = try folder()
        let lines = (1...10).map { "line \($0)" } + ["```"]
        let url = try write(lines.joined(separator: "\n"), "notes.md", in: dir)
        let text = PromptCopy.build([url]).text
        XCTAssertTrue(text.contains("````markdown\n 1  line 1\n"), text)
        XCTAssertTrue(text.contains("\n11  ```\n````\n"), text)
    }

    func testSecretsAreMaskedBeforeTheTextIsBuilt() throws {
        let dir = try folder()
        let secret = "q7Rk2LmP9xVt4WzN8sBc"
        let url = try write("HARBOUR_NAME=Cascais\nHARBOUR_API_KEY=\(secret)\n", "harbour.env", in: dir)
        let result = PromptCopy.build([url])
        XCTAssertFalse(result.text.contains(secret), "the value never reaches the clipboard text")
        XCTAssertTrue(result.text.contains("HARBOUR_NAME=Cascais"), "the rest of the file stays")
        XCTAssertGreaterThanOrEqual(result.secretsMasked, 1)
        XCTAssertTrue(result.text.contains("secret value"), "the first line says values were masked")
    }

    func testAFolderBecomesItsTreeAndChosenFilesFollowIt() throws {
        let dir = try folder()
        let project = dir.appendingPathComponent("Tidepool", isDirectory: true)
        try write("# Tidepool\n", "Tidepool/README.md", in: dir)
        let chosen = try write("let height = 2.5\n", "Tidepool/Sources/Tide.swift", in: dir)
        try write("x\n", "Tidepool/.hidden", in: dir)
        let result = PromptCopy.build([project, chosen])
        let tree = "\(project.path) (folder, 3 entries shown):\n\n```text\nTidepool/\n├── Sources/\n│   └── Tide.swift\n└── README.md\n```\n"
        XCTAssertTrue(result.text.contains(tree), result.text)
        XCTAssertFalse(result.text.contains(".hidden"), "hidden files stay out of the tree")
        XCTAssertTrue(result.text.contains("\(chosen.path) (1 lines):\n\n```swift\n1  let height = 2.5\n```\n"), result.text)
        XCTAssertFalse(result.text.contains("# Tidepool"), "a file in the folder is copied only when chosen")
        XCTAssertEqual(result.filesCopied, 1)
    }

    func testATreeStopsAtItsLimits() throws {
        let dir = try folder()
        for i in 1...12 { try write("x\n", "Many/file\(i).txt", in: dir) }
        try write("x\n", "Many/a/b/c/deep.txt", in: dir)
        var limits = PromptCopy.Limits(); limits.treeEntries = 5; limits.treeDepth = 2
        let text = PromptCopy.build([dir.appendingPathComponent("Many")], limits: limits).text
        XCTAssertTrue(text.contains("(folder, 5 entries shown)"), text)
        XCTAssertTrue(text.contains("more entries"), text)
        XCTAssertFalse(text.contains("deep.txt"), text)
    }

    func testBinariesKeysAndHugeFilesAreNamedNotCopied() throws {
        let dir = try folder()
        let binary = dir.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00, 0x7F]).write(to: binary)
        let key = try write("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAinventedAAAA\n-----END OPENSSH PRIVATE KEY-----\n", "id_ed25519", in: dir)
        let big = try write(String(repeating: "tide\n", count: 400), "big.txt", in: dir)
        var limits = PromptCopy.Limits(); limits.fileBytes = 1_000
        let result = PromptCopy.build([binary, key, big], limits: limits)
        XCTAssertTrue(result.text.contains("\(binary.path): not text, not included."), result.text)
        XCTAssertTrue(result.text.contains("\(key.path): a key or certificate, never copied."), result.text)
        XCTAssertFalse(result.text.contains("AAAAinventedAAAA"))
        XCTAssertTrue(result.text.contains("\(big.path):") && result.text.contains("too large to copy"), result.text)
        XCTAssertEqual(result.filesCopied, 0)
        XCTAssertTrue(result.text.hasPrefix("0 files from Vitrine"))
    }

    func testTheTotalBudgetNamesLaterFiles() throws {
        let dir = try folder()
        let a = try write(String(repeating: "a", count: 600) + "\n", "a.txt", in: dir)
        let b = try write(String(repeating: "b", count: 600) + "\n", "b.txt", in: dir)
        var limits = PromptCopy.Limits(); limits.totalBytes = 1_000
        let result = PromptCopy.build([a, b, a], limits: limits)
        XCTAssertEqual(result.filesCopied, 1, "the repeat of a is dropped and b is past the budget")
        XCTAssertTrue(result.text.contains("\(b.path): not included, the copy is already at its size limit."), result.text)
    }

    func testCopyAsPromptWritesOnlyTheGivenPasteboard() throws {
        let dir = try folder()
        let url = try write("hello tide\n", "hello.txt", in: dir)
        let board = pasteboard()
        board.clearContents(); board.setString("before", forType: .string)
        var serviceCalls = 0
        try QuickActionRequestHandler.perform(.copyPrompt, on: [url], pasteboard: board) { _, _ in serviceCalls += 1; return true }
        let text = try XCTUnwrap(board.string(forType: .string))
        XCTAssertTrue(text.contains("\(url.path) (1 lines):\n\n```\n1  hello tide\n```\n"), text)
        XCTAssertEqual(serviceCalls, 0, "Copy as Prompt never needs the app")
    }

    // MARK: The hand-off to the app

    func testOpenAndExportsHandTheFilesToTheAppsService() throws {
        let dir = try folder()
        let files = try (1...3).map { try write("# \($0)\n", "doc\($0).md", in: dir) }
        let board = pasteboard()
        for action in [QuickAction.open, .exportPDF, .exportHTML] {
            var called: (String, [URL])?
            try QuickActionRequestHandler.perform(action, on: files, pasteboard: board) { name, carrier in
                called = (name, (carrier.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? [])
                return true
            }
            XCTAssertEqual(called?.0, action.serviceName)
            XCTAssertEqual(called?.1.map(\.standardizedFileURL), files.map(\.standardizedFileURL))
        }
        XCTAssertNil(board.string(forType: .string), "the hand-off leaves the clipboard alone")
    }

    func testFailuresAreReported() throws {
        let board = pasteboard()
        XCTAssertThrowsError(try QuickActionRequestHandler.perform(nil, on: [URL(fileURLWithPath: "/tmp/x")], pasteboard: board)) {
            XCTAssertEqual($0 as? QuickActionRequestHandler.Failure, .unknownAction)
        }
        XCTAssertThrowsError(try QuickActionRequestHandler.perform(.open, on: [], pasteboard: board)) {
            XCTAssertEqual($0 as? QuickActionRequestHandler.Failure, .noFiles)
        }
        XCTAssertThrowsError(try QuickActionRequestHandler.perform(.open, on: [URL(fileURLWithPath: "/tmp/x")], pasteboard: board) { _, _ in false }) {
            XCTAssertEqual($0 as? QuickActionRequestHandler.Failure, .appUnreachable)
        }
    }

    func testFinderAttachmentsBecomeFileURLs() async throws {
        let dir = try folder()
        let url = try write("x\n", "one.txt", in: dir)
        let provider = NSItemProvider(contentsOf: url)!
        let text = NSItemProvider(object: "not a file" as NSString)
        let urls = await QuickActionRequestHandler.fileURLs(from: [text, provider])
        XCTAssertEqual(urls.map(\.standardizedFileURL), [url.standardizedFileURL])
    }

    // MARK: Bundles and Services entries

    func info(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.appFolder.appendingPathComponent(name))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    static let bundles: [(file: String, action: QuickAction)] = [
        ("Extensions/QuickActions/OpenInVitrine-Info.plist", .open), ("Extensions/QuickActions/ExportPDF-Info.plist", .exportPDF),
        ("Extensions/QuickActions/ExportHTML-Info.plist", .exportHTML), ("Extensions/QuickActions/CopyPrompt-Info.plist", .copyPrompt),
    ]

    /// The extension context's shape the activation rule is evaluated against: items holding attachments' types.
    func selection(_ types: [[String]]) -> [String: Any] {
        ["extensionItems": [["attachments": types.map { ["registeredTypeIdentifiers": $0] }]]]
    }

    func testEachBundleIsAUILessFinderActionNamingItsAction() throws {
        for (file, action) in Self.bundles {
            let plist = try info(file)
            XCTAssertEqual(plist[QuickAction.infoKey] as? String, action.rawValue, file)
            let ext = try XCTUnwrap(plist["NSExtension"] as? [String: Any], file)
            XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.services", file)
            XCTAssertEqual(ext["NSExtensionPrincipalClass"] as? String, "$(PRODUCT_MODULE_NAME).QuickActionRequestHandler", file)
            let attributes = try XCTUnwrap(ext["NSExtensionAttributes"] as? [String: Any], file)
            XCTAssertEqual(attributes["NSExtensionServiceAllowsFinderPreviewItem"] as? Bool, true, "shown in the preview pane: \(file)")
            XCTAssertNotNil(attributes["NSExtensionServiceFinderPreviewIconName"] as? String, file)
        }
    }

    func testActivationRulesOfferEachActionOnTheRightFiles() throws {
        let markdown = ["net.daringfireball.markdown", "public.file-url"]
        let mdx = ["io.github.xbtdmt.vitrine.mdx", "public.file-url"]
        let swift = ["public.swift-source", "public.file-url"]
        let folder = ["public.folder", "public.file-url"]
        for (file, action) in Self.bundles {
            let ext = try XCTUnwrap(try info(file)["NSExtension"] as? [String: Any])
            let rule = try XCTUnwrap((ext["NSExtensionAttributes"] as? [String: Any])?["NSExtensionActivationRule"] as? String)
            let predicate = NSPredicate(format: rule)
            XCTAssertFalse(predicate.evaluate(with: selection([])), "nothing selected: \(file)")
            switch action {
            case .open, .copyPrompt:
                XCTAssertTrue(predicate.evaluate(with: selection([swift])), file)
                XCTAssertTrue(predicate.evaluate(with: selection([folder, markdown])), file)
            case .exportPDF, .exportHTML:
                XCTAssertTrue(predicate.evaluate(with: selection([markdown])), file)
                XCTAssertTrue(predicate.evaluate(with: selection([markdown, mdx])), file)
                XCTAssertFalse(predicate.evaluate(with: selection([swift])), "only documents export: \(file)")
                XCTAssertFalse(predicate.evaluate(with: selection([markdown, swift])), "every file must export: \(file)")
            }
        }
    }

    func testTheAppHasAServicesEntryForEveryActionThatNeedsIt() throws {
        let services = try XCTUnwrap(try info("Vitrine/Info.plist")["NSServices"] as? [[String: Any]])
        for action in QuickAction.allCases {
            let entry = services.first { ($0["NSMenuItem"] as? [String: String])?["default"] == action.serviceName }
            guard let name = action.serviceName else { XCTAssertNil(action.serviceMessage); continue }
            let found = try XCTUnwrap(entry, "no Services entry named \(name)")
            XCTAssertEqual(found["NSMessage"] as? String, action.serviceMessage)
            XCTAssertEqual(found["NSPortName"] as? String, "Vitrine")
            let types = found["NSSendFileTypes"] as? [String]
            XCTAssertEqual(types, action == .open ? ["public.item"] : QuickAction.exportableTypes)
        }
    }

    func testTheAppImplementsEveryServicesMessage() throws {
        let source = try String(contentsOf: Self.appFolder.appendingPathComponent("Vitrine/QuickActions/QuickActionServices.swift"), encoding: .utf8)
        for message in QuickAction.allCases.compactMap(\.serviceMessage) {
            XCTAssertTrue(source.contains("@objc func \(message)(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>)"),
                          "the services provider answers \(message)")
        }
    }

    // MARK: Export as PDF and HTML

    func testAnExportTakesTheFirstFreeName() throws {
        let dir = try folder()
        let desired = dir.appendingPathComponent("Tidepool.pdf")
        XCTAssertEqual(QuickActionExporter.freeName(for: desired), desired)
        try Data("kept".utf8).write(to: desired)
        XCTAssertEqual(QuickActionExporter.freeName(for: desired)?.lastPathComponent, "Tidepool 2.pdf")
        try Data("kept".utf8).write(to: dir.appendingPathComponent("Tidepool 2.pdf"))
        XCTAssertEqual(QuickActionExporter.freeName(for: desired)?.lastPathComponent, "Tidepool 3.pdf")
        XCTAssertEqual(QuickActionExporter.besideSource(dir.appendingPathComponent("Tidepool.md"), format: .html).lastPathComponent, "Tidepool.html")
    }

    func testPlacingNeverReplacesAFile() throws {
        let dir = try folder()
        let desired = dir.appendingPathComponent("Log.html")
        try Data("kept".utf8).write(to: desired)
        let made = dir.appendingPathComponent("scratch.html")
        try Data("new".utf8).write(to: made)
        let placed = try QuickActionExporter.place(made, at: desired)
        XCTAssertEqual(placed.lastPathComponent, "Log 2.html")
        XCTAssertEqual(try String(contentsOf: desired, encoding: .utf8), "kept")
        XCTAssertEqual(try String(contentsOf: placed, encoding: .utf8), "new")
    }

    func context(_ dir: URL) -> RenderContext {
        RenderContext(appearance: .light, defaultsSuite: "vt-quickaction-suite", cachesDirectory: dir.appendingPathComponent("caches"))
    }

    func testMarkdownExportsBesideItselfAsHTMLAndPDFWithoutReplacingAnything() async throws {
        let dir = try folder()
        let source = try write("# Tidepool\n\nThe tide at Cascais rose to 2.5 m.\n", "Tidepool.md", in: dir)
        let existing = dir.appendingPathComponent("Tidepool.pdf")
        try Data("an older PDF".utf8).write(to: existing)

        let html = try await QuickActionExporter.export(source, as: .html, to: QuickActionExporter.besideSource(source, format: .html), context: context(dir))
        XCTAssertEqual(html.lastPathComponent, "Tidepool.html")
        let page = try String(contentsOf: html, encoding: .utf8)
        XCTAssertTrue(page.hasPrefix("<!doctype html>") && page.contains("<title>Tidepool.md</title>") && page.contains("Cascais"))

        let pdf = try await QuickActionExporter.export(source, as: .pdf, to: QuickActionExporter.besideSource(source, format: .pdf), context: context(dir))
        XCTAssertEqual(pdf.lastPathComponent, "Tidepool 2.pdf", "the older PDF keeps its name")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "an older PDF")
        XCTAssertTrue(PDFDocument(url: pdf)?.string?.contains("Cascais") == true)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") && $0 != "caches" }.sorted()
        XCTAssertEqual(left, ["Tidepool 2.pdf", "Tidepool.html", "Tidepool.md", "Tidepool.pdf"], "no temporary file is left beside the document")
    }

    func testOnlyMarkdownExports() async throws {
        let dir = try folder()
        let source = try write("let x = 1\n", "code.swift", in: dir)
        do {
            _ = try await QuickActionExporter.export(source, as: .pdf, to: dir.appendingPathComponent("code.pdf"), context: context(dir))
            XCTFail("a code file does not export")
        } catch let failure as QuickActionExporter.Failure {
            XCTAssertEqual(failure, .notExportable("code.swift"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("code.pdf").path))
    }
}
