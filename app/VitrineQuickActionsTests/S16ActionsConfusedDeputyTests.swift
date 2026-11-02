import XCTest
import VitrinePreviewKit

/// S-16 lane 6 (F11, F44, greenman G-35): a Service or Quick Action never hands file contents to a caller that could
/// not read them, and acts only on items the system handed over with access. Invented files in a temporary folder;
/// every pasteboard is private, uniquely named and released. roadmap: S-16
@MainActor
final class S16ActionsConfusedDeputyTests: XCTestCase {
    private var folders: [URL] = []
    private var pasteboards: [NSPasteboard] = []

    override func tearDown() async throws {
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        for folder in folders {
            // A test makes a file unreadable; give it back its rights so the folder can be removed.
            if let names = try? FileManager.default.subpathsOfDirectory(atPath: folder.path) {
                for name in names { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent(name).path) }
            }
            try? FileManager.default.removeItem(at: folder)
        }
        pasteboards = []; folders = []
    }

    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-s16-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folders.append(dir)
        return dir.resolvingSymlinksInPath()
    }

    func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("vt-s16-actions-\(UUID().uuidString)"))
        pasteboards.append(board)
        board.clearContents()
        return board
    }

    @discardableResult
    func write(_ text: String, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static let appFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    // MARK: F11 — the app's export Services write only where the person chooses

    func testAnExportGoesOnlyWhereThePersonChoosesNeverBesideTheSourceUnasked() throws {
        let dir = try folder()
        let source = try write("# Tidepool\n", "Tidepool.md", in: dir)
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: dir.path), "the source's folder is writable: the case the caller could read back")
        let chosen = try folder().appendingPathComponent("Chosen.html")
        var questions: [QuickActionExporter.DestinationQuestion] = []
        let jobs = QuickActionExporter.plan([source], format: .html) { questions.append($0); return chosen }
        XCTAssertEqual(questions, [.file(source: source, suggested: dir.appendingPathComponent("Tidepool.html"))],
                       "Vitrine always asks, even when it could write beside the document")
        XCTAssertEqual(jobs, [QuickActionExporter.Job(source: source, destination: chosen)])
    }

    func testDecliningThePanelExportsNothing() throws {
        let dir = try folder()
        let source = try write("# Tidepool\n", "Tidepool.md", in: dir)
        for format in [PreviewExport.Format.html, .pdf] {
            XCTAssertEqual(QuickActionExporter.plan([source], format: format) { _ in nil }, [], "no answer, no file: \(format)")
        }
    }

    func testSeveralDocumentsAskForOneFolderAndExportThereUnderTheirOwnNames() throws {
        let dir = try folder()
        let sources = try ["a.md", "b.md", "a.markdown"].map { try write("# x\n", $0, in: dir) }
        let target = try folder()
        var questions: [QuickActionExporter.DestinationQuestion] = []
        let jobs = QuickActionExporter.plan(sources, format: .pdf) { questions.append($0); return target }
        XCTAssertEqual(questions, [.folder(sources: sources, suggestedFolder: dir)], "one panel for the whole selection")
        XCTAssertEqual(jobs.map(\.source), sources)
        XCTAssertEqual(jobs.map(\.destination), ["a.pdf", "b.pdf", "a.pdf"].map { target.appendingPathComponent($0) },
                       "two documents with one base name are numbered when placed (place never replaces)")
        XCTAssertEqual(QuickActionExporter.plan(sources, format: .pdf) { _ in nil }, [])
        XCTAssertEqual(QuickActionExporter.plan([], format: .pdf) { _ in XCTFail("nothing to ask about"); return target }, [])
    }

    /// The reader takes `public.file-url` items only. (A legacy NSFilenamesPboardType list is translated into file URL
    /// items by the pasteboard server itself, so no reader can tell it from a file URL; any sender can write a file
    /// URL anyway. The gate against a caller is the save panel, not the pasteboard type.)
    func testTheServicesReaderTakesFileURLsNeverTextOrWebURLs() throws {
        let invented = "/private/tmp/vt-s16-not-there/notes.md"
        let text = pasteboard()
        text.setString(invented, forType: .string)
        XCTAssertEqual(ServicesPasteboard.fileURLs(on: text), [], "a plain-text path is not a file URL")
        let web = pasteboard()
        web.setString("https://example.invalid/notes.md", forType: .URL)
        XCTAssertEqual(ServicesPasteboard.fileURLs(on: web), [])

        let dir = try folder()
        let files = try (1...3).map { try write("# \($0)\n", "doc\($0).md", in: dir) }
        let carried = pasteboard()
        carried.writeObjects(files as [NSURL])
        XCTAssertEqual(ServicesPasteboard.fileURLs(on: carried), files, "the file URLs the extension carries still arrive, in order")
        XCTAssertEqual(ServicesPasteboard.fileURLs(on: carried, limit: 2), Array(files.prefix(2)))
    }

    func testAFileReferenceURLArrivesAsItsPath() throws {
        let dir = try folder()
        let file = try write("# ref\n", "ref.md", in: dir)
        let reference = try XCTUnwrap((file as NSURL).fileReferenceURL())
        let board = pasteboard()
        let item = NSPasteboardItem()
        item.setString(reference.absoluteString, forType: .fileURL)
        board.writeObjects([item])
        XCTAssertEqual(ServicesPasteboard.fileURLs(on: board), [file])
    }

    func testTheQuickActionServicesReturnNothingToTheCaller() throws {
        let data = try Data(contentsOf: Self.appFolder.appendingPathComponent("Vitrine/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        for message in QuickAction.allCases.compactMap(\.serviceMessage) {
            let entry = try XCTUnwrap(services.first { $0["NSMessage"] as? String == message }, message)
            XCTAssertNil(entry["NSReturnTypes"], "\(message) returns nothing through the services pasteboard")
            XCTAssertNil(entry["NSSendTypes"], "\(message) takes files only, never pasted text")
        }
    }

    // MARK: F44 — Copy as Prompt reads only what the system handed over

    /// The four Quick Action extensions are signed with their own entitlements: the sandbox and nothing more. The
    /// read exception for "/" (which let them read any file a host named) and the app group and helper lookup they
    /// never use are gone; the preview extensions keep theirs.
    func testTheQuickActionExtensionsCarryNoReadException() throws {
        let spec = try String(contentsOf: Self.appFolder.appendingPathComponent("project.yml"), encoding: .utf8)
        let lines = spec.components(separatedBy: "\n")
        for target in ["VitrineOpenAction", "VitrineExportPDFAction", "VitrineExportHTMLAction", "VitrineCopyPromptAction"] {
            let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("  \(target):") }, target)
            let rest = lines[(start + 1)...]
            let end = rest.firstIndex { $0.hasPrefix("  ") && !$0.hasPrefix("   ") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") } ?? lines.endIndex
            let block = lines[(start + 1)..<end]
            let line = try XCTUnwrap(block.first { $0.contains("CODE_SIGN_ENTITLEMENTS:") }, "\(target) names its entitlements")
            let file = line.components(separatedBy: "CODE_SIGN_ENTITLEMENTS:")[1].trimmingCharacters(in: .whitespaces)
            let data = try Data(contentsOf: Self.appFolder.appendingPathComponent(file))
            let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true, "\(target) is sandboxed")
            XCTAssertEqual(Set(entitlements.keys), ["com.apple.security.app-sandbox"], "\(target) (\(file)) carries the sandbox only")
        }
    }

    func testAFileThatCannotBeReadIsSaidSo() throws {
        let dir = try folder()
        let file = try write("let tide = 2.5\n", "Tide.swift", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        guard (try? Data(contentsOf: file)) == nil else { throw XCTSkip("this user can read a file with no permissions (root)") }
        let result = PromptCopy.build([file])
        XCTAssertTrue(result.text.contains("\(file.path): cannot be read, not included."), result.text)
        XCTAssertFalse(result.text.contains("not UTF-8"), "a denied read is not a text-encoding problem")
        XCTAssertEqual(result.filesCopied, 0)
    }
}
