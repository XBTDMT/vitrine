import Compression
import CryptoKit
import XCTest
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineGit
import VitrineSupport
import VitrineText

/// A folder that is a git repository gets the browse design's repository card (E-6): branch, latest commit,
/// uncommitted changes, the outline's last-commit column and the README, read from `.git` by hand-written
/// fixtures. No test runs git. roadmap: S-9
@MainActor
final class FolderRepositoryTests: XCTestCase {
    override func tearDown() {
        FolderRenderer.firstPaintWait = .milliseconds(250)
        super.tearDown()
    }

    /// Quick Look's panel is shorter than the snapshot: every part must still fit, the path row on top, the README
    /// shrinking (it scrolls inside its card) rather than pushing the top out of view.
    func testEverythingFitsAShortPanel() async throws {
        let root = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        FolderRenderer.firstPaintWait = .seconds(5)
        let renderer = FolderRenderer()
        let preview = try await renderer.render(url: root, kind: .folder, context: RenderContext(appearance: .light, defaultsSuite: "vt-folder-git"))
        // A host in a window, so its 300 pt height is held like the panel's (a free-standing view would grow).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        let host = try XCTUnwrap(window.contentView)
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(preview.view)
        NSLayoutConstraint.activate([
            preview.view.leadingAnchor.constraint(equalTo: host.leadingAnchor), preview.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            preview.view.topAnchor.constraint(equalTo: host.topAnchor), preview.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        // The window must keep its 300 pt: a view that outranks the window's own size grows it instead.
        XCTAssertEqual(window.frame.height, 300)
        XCTAssertEqual(preview.view.frame, NSRect(x: 0, y: 0, width: 800, height: 300), preview.view.subviews.map { "\(type(of: $0)) \(Int($0.frame.height))" }.joined(separator: ", "))
        for sub in preview.view.subviews where !sub.isHidden {
            XCTAssertTrue(preview.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(sub.frame), "\(type(of: sub)) at \(sub.frame) is outside \(preview.view.bounds)")
        }
    }

    func testRepositoryCardOutlineAndReadme() async throws {
        let root = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        FolderRenderer.firstPaintWait = .seconds(5)            // the whole read lands before the first paint
        let renderer = FolderRenderer()
        let preview = try await renderer.render(url: root, kind: .folder, context: RenderContext(appearance: .light, defaultsSuite: "vt-folder-git"))
        XCTAssertEqual(preview.document.dialect, "git")
        XCTAssertEqual(preview.document.fact("headline")?.value, Self.headline)
        XCTAssertEqual(preview.document.fact("branch")?.value, "main")
        XCTAssertEqual(preview.document.fact("source")?.value, "from the .git folder, no git process")

        let view = try XCTUnwrap(renderer.viewForTesting)
        let card = try XCTUnwrap(view.repository).textForTesting
        for word in ["main", "Add the greeting", "2 uncommitted", "read from .git, no git process", "M", "hello.txt", "+1 −1", "?", "notes.md", "new"] {
            XCTAssertTrue(card.contains(word), "the card shows \(word): \(card)")
        }
        XCTAssertTrue(card.contains("2"), "the commit count")

        let outline = try XCTUnwrap(renderer.outlineForTesting)
        let hello = try XCTUnwrap(outline.root.children().first { $0.name == "hello.txt" })
        XCTAssertEqual(outline.text(for: hello, column: "commit"), "Add the greeting")
        XCTAssertEqual(outline.git?.marks["hello.txt"], .modified)
        XCTAssertNil(outline.table.headerView, "the repository outline has no header row, as drawn")

        let readme = try XCTUnwrap(view.readme)
        let text = readme.textView.string
        XCTAssertTrue(text.hasPrefix("Demo\n"), text)
        XCTAssertTrue(text.contains("Hello world."), "Markdown is rendered, not shown as source")
        XCTAssertTrue(text.contains("make run"), "the code block is kept")
    }

    func testQuickFirstPaintThenTheRestArrives() async throws {
        let root = try Self.makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        FolderRenderer.firstPaintWait = .zero                  // force the quick path
        let renderer = FolderRenderer()
        let preview = try await renderer.render(url: root, kind: .folder, context: RenderContext(appearance: .light, defaultsSuite: "vt-folder-git"))
        var pushed: [PreviewDocument] = []
        preview.documentChanged = { pushed.append($0) }
        XCTAssertEqual(preview.document.fact("branch")?.value, "main", "HEAD is in the first paint")
        XCTAssertFalse(preview.document.fact("headline")?.value.contains("uncommitted") == true, "the status is not in the quick read")
        await renderer.waitForRepositoryFill()
        XCTAssertEqual(preview.document.fact("headline")?.value, Self.headline)
        XCTAssertEqual(pushed.count, 1, "the pill follows the full read")
        XCTAssertTrue(try XCTUnwrap(renderer.viewForTesting?.repository).textForTesting.contains("2 uncommitted"))
    }

    func testReadmeBlocksBecomeStyledText() {
        let blocks = MarkdownBlocks.parse("# Title\n\nSome `code` and *em*.\n\n```\nline one\nline two\n```\n\n> [!TIP]\n> Short tip.\n\n- a\n- b\n")
        let text = ReadmeText.attributed(blocks)
        XCTAssertEqual(text.string, "Title\nSome \u{2009}code\u{2009} and em.\nline one\nline two\nTip\nShort tip.\n•\ta\n•\tb")
        let codeAt = (text.string as NSString).range(of: "line two").location
        let boxes = text.attribute(.readmeBoxes, at: codeAt, effectiveRange: nil) as? [ReadmeBox]
        XCTAssertEqual(boxes?.count, 1, "the code block sits in its rounded box")
        let tipAt = (text.string as NSString).range(of: "Short tip").location
        XCTAssertNotNil(text.attribute(.readmeBoxes, at: tipAt, effectiveRange: nil), "the alert is boxed")
    }

    func testWords() {
        XCTAssertEqual(GitText.initials("Ada Q. Example"), "AE")
        XCTAssertEqual(GitText.initials("bo"), "B")
        XCTAssertEqual(GitText.initials(""), "?")
        XCTAssertEqual(GitText.avatarToken("ada@example.com"), GitText.avatarToken("ADA@example.com"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(GitText.relative(now.addingTimeInterval(-2 * 3600), now: now, locale: en), "2 hours ago")
        XCTAssertEqual(GitText.relative(now.addingTimeInterval(-86_400), now: now, locale: en), "yesterday")
        XCTAssertEqual(GitText.relative(now.addingTimeInterval(-7 * 86_400), now: now, locale: en), "last week")
    }

    // MARK: A repository written by hand

    /// Two tracked files of 43 + 3 bytes; hello.txt changed, notes.md untracked.
    static var headline: String { "git · 2 files · \(ByteCountFormatter.string(fromByteCount: 46, countStyle: .file)) · 2 uncommitted" }

    /// main has two commits; hello.txt was edited after (one line changed), notes.md is untracked, README.md
    /// is tracked and unchanged.
    static func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vt-folder-git-\(UUID().uuidString)")
        let git = root.appendingPathComponent(".git"), objects = git.appendingPathComponent("objects")
        let fm = FileManager.default
        try fm.createDirectory(at: objects, withIntermediateDirectories: true)
        try fm.createDirectory(at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        let readme = Array("# Demo\n\nHello **world**.\n\n```\nmake run\n```\n".utf8)
        let helloOld = Array("hi\n".utf8), helloNew = Array("ho\n".utf8)
        let readmeID = try loose("blob", readme, objects)
        let helloID = try loose("blob", helloOld, objects)
        let tree1 = try loose("tree", tree([("README.md", readmeID)]), objects)
        let tree2 = try loose("tree", tree([("README.md", readmeID), ("hello.txt", helloID)]), objects)
        let c1 = try loose("commit", commit(tree: tree1, parents: [], seconds: 1_790_000_000, subject: "Start the demo"), objects)
        let c2 = try loose("commit", commit(tree: tree2, parents: [c1], seconds: 1_790_100_000, subject: "Add the greeting"), objects)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "\(c2.hex)\n".write(to: git.appendingPathComponent("refs/heads/main"), atomically: true, encoding: .utf8)
        try Data(index([("README.md", readmeID, readme.count), ("hello.txt", helloID, helloOld.count)])).write(to: git.appendingPathComponent("index"))
        try Data(readme).write(to: root.appendingPathComponent("README.md"))
        try Data(helloNew).write(to: root.appendingPathComponent("hello.txt"))   // same size, other bytes: only a hash tells
        try "draft\n".write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return root
    }

    static func loose(_ type: String, _ content: [UInt8], _ objects: URL) throws -> GitObjectID {
        let id = GitObjectID.hash(type: type, content: content)
        let dir = objects.appendingPathComponent(String(id.hex.prefix(2)))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(zlib(Array("\(type) \(content.count)\0".utf8) + content)).write(to: dir.appendingPathComponent(String(id.hex.dropFirst(2))))
        return id
    }

    static func tree(_ entries: [(String, GitObjectID)]) -> [UInt8] {
        entries.sorted { $0.0 < $1.0 }.flatMap { Array("100644 \($0.0)\0".utf8) + $0.1.bytes }
    }

    static func commit(tree: GitObjectID, parents: [GitObjectID], seconds: Int, subject: String) -> [UInt8] {
        var s = "tree \(tree.hex)\n" + parents.map { "parent \($0.hex)\n" }.joined()
        s += "author Ada Example <ada@example.com> \(seconds) +0000\ncommitter Ada Example <ada@example.com> \(seconds) +0000\n\n\(subject)\n"
        return Array(s.utf8)
    }

    /// A version 2 index with the given entries (mtime 1, so every file is hashed).
    static func index(_ entries: [(String, GitObjectID, Int)]) -> [UInt8] {
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        var out = Array("DIRC".utf8) + be32(2) + be32(entries.count)
        for (path, id, size) in entries.sorted(by: { $0.0 < $1.0 }) {
            let start = out.count
            out += be32(1) + be32(0) + be32(1) + be32(0) + be32(1) + be32(1) + be32(0o100644) + be32(501) + be32(20) + be32(size)
            out += id.bytes + [UInt8(path.utf8.count >> 8), UInt8(path.utf8.count & 0xFF)] + Array(path.utf8)
            let length = out.count - start
            out += [UInt8](repeating: 0, count: ((length + 8) & ~7) - length)
        }
        return out + Array(Insecure.SHA1.hash(data: out))
    }

    static func zlib(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + 1024)
        let n = compression_encode_buffer(&out, out.count, data, data.count, nil, COMPRESSION_ZLIB)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = b << 16 | a
        return [0x78, 0x9C] + out[0..<n] + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
    }
}
