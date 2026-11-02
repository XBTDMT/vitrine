import XCTest
@testable import VitrinePreviewKit
import VitrineDocument

/// The quick wins of 2026-10-29: the merged engines' facts in the pill, before each family has its own view.
@MainActor
final class FamilyFactsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-family-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func pill(_ doc: PreviewDocument) -> CapsuleModel {
        let m = CapsuleModel()
        m.show(doc, canToggleInspector: false, canFind: true)
        return m
    }

    func testMinifiedJSONOpensFormattedWithItsNodeCount() throws {
        let minified = "{\"users\":[{\"name\":\"Dana\",\"tags\":[\"a\",\"b\"]},{\"name\":\"Ari\",\"tags\":[]}],\"count\":2}" + String(repeating: " ", count: 1200)
        let url = try file("users.json", Data(minified.utf8))
        let doc = try PlainTextRenderer.document(url: url, kind: .code(language: "json"))
        XCTAssertEqual(doc.views.map(\.title), ["Formatted", "Code"], "a minified file opens formatted, the original one switch away")
        guard case .formatted(let text, _) = doc.views[0] else { return XCTFail("formatted first") }
        XCTAssertTrue(text.contains("\n  \"users\": ["), text)
        XCTAssertEqual(PlainTextRenderer.shownText(doc), text)
        XCTAssertEqual(doc.fact("headline")?.value, "11 nodes", "root, users, 2 objects, 2 names, 2 tag arrays, 2 tags, count")
        XCTAssertEqual(pill(doc).pillText.hasPrefix("JSON · 11 nodes · "), true, pill(doc).pillText)
    }

    func testBrokenJSONSaysWhere() throws {
        let url = try file("bad.json", Data("{\n  \"a\": 1,\n  \"b\": \n}\n".utf8))
        let doc = try PlainTextRenderer.document(url: url, kind: .code(language: "json"))
        XCTAssertEqual(doc.fact("headline")?.value.hasPrefix("Syntax error at 4:"), true, doc.fact("headline")?.value ?? "nil")
        XCTAssertEqual(doc.badges.first?.level, .caution)
        XCTAssertEqual(pill(doc).dotToken, "caution")
        XCTAssertEqual(doc.views.map(\.title), ["Code"], "nothing to format when it does not parse")
    }

    func testCSVShowsRowsAndColumns() throws {
        let url = try file("t.tsv", Data("name\tqty\napple\t3\npear\t5\n".utf8))
        let doc = try PlainTextRenderer.document(url: url, kind: .csv(delimiter: "\t"))
        XCTAssertEqual(doc.fact("headline")?.value, "2 rows × 2 columns")
        XCTAssertNotNil(doc.fact("delimiter"))
    }

    func testPatchLeadsWithItsSummary() throws {
        let patch = "diff --git a/a.txt b/a.txt\nindex 1111111..2222222 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n"
        let url = try file("change.patch", Data(patch.utf8))
        let doc = try PlainTextRenderer.document(url: url, kind: .diff)
        XCTAssertEqual(doc.fact("headline")?.value, "1 file · +1 −1")
        XCTAssertEqual(doc.fact("summary")?.value, "a.txt edited; 1 line added, 1 removed")
    }

    func testZipListsItsFilesNotItsBytes() throws {
        let src = dir.appendingPathComponent("src/demo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "hello\n".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "bye\n".write(to: src.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qr", dir.appendingPathComponent("demo.zip").path, "demo"]
        zip.currentDirectoryURL = dir.appendingPathComponent("src")
        try zip.run(); zip.waitUntilExit()
        let doc = try PlainTextRenderer.document(url: dir.appendingPathComponent("demo.zip"), kind: .archive(.zip))
        guard case .text(let listing) = doc.primaryView else { return XCTFail("listing") }
        XCTAssertTrue(listing.hasPrefix("demo/"), listing)
        XCTAssertTrue(listing.contains("\n  a.txt"), listing)
        XCTAssertEqual(doc.fact("files")?.value, "2")
        XCTAssertEqual(doc.fact("headline")?.value.hasPrefix("3 items · "), true, doc.fact("headline")?.value ?? "nil")
        XCTAssertEqual(doc.fact("headline")?.value.hasSuffix(" · no problems"), true)
        XCTAssertTrue(listing.contains("2 items"), listing)
        XCTAssertTrue(doc.badges.isEmpty, "a clean archive has no warnings")
        XCTAssertEqual(pill(doc).dotToken, "ok", "a clean archive's dot is green, as the browse design draws it")
    }

    func testEscapingPathInATarTurnsTheDotRed() throws {
        let url = try file("evil.tar", Self.tar(path: "../evil.txt", body: Data("x\n".utf8)))
        let doc = try PlainTextRenderer.document(url: url, kind: .archive(.tar))
        XCTAssertEqual(doc.badges.map(\.level).max(), .danger, doc.badges.map(\.title).description)
        XCTAssertEqual(pill(doc).dotToken, "danger")
        XCTAssertTrue(pill(doc).pillDetail.hasPrefix(doc.badges.sorted { $0.level > $1.level }[0].title), "warnings lead the tooltip")
    }

    /// A one-member ustar archive built by hand (tar tools refuse to write `..` paths).
    static func tar(path: String, body: Data) -> Data {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, _ at: Int) { for (i, b) in s.utf8.enumerated() { h[at + i] = b } }
        put(path, 0); put("0000644\0", 100); put("0000000\0", 108); put("0000000\0", 116)
        put(String(format: "%011o\0", body.count), 124); put("00000000000\0", 136)
        put("        ", 148); h[156] = UInt8(ascii: "0"); put("ustar\0", 257); put("00", 263)
        put(String(format: "%06o\0 ", h.reduce(0) { $0 + Int($1) }), 148)
        var out = Data(h) + body
        out += Data(repeating: 0, count: (512 - body.count % 512) % 512)
        out += Data(repeating: 0, count: 1024)
        return out
    }
}
