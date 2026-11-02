import XCTest
@testable import VitrinePreviewKit
import VitrineUI

/// The Markdown Collection as the app uses it.
final class MarkdownThemeTests: XCTestCase {
    func testTheCollectionFromTheDesignSystem() {
        XCTAssertEqual(MarkdownTheme.builtIn.count, GeneratedTokens.markdownThemes.count)
        XCTAssertEqual(MarkdownTheme.builtIn.count, 15, "the Collection has fifteen themes (G-8)")
        XCTAssertEqual(Set(MarkdownTheme.builtIn.map(\.id)).count, 15)
        XCTAssertEqual(MarkdownTheme.defaultID, "vitrine")
        XCTAssertEqual(MarkdownTheme.theme(id: "nope").id, MarkdownTheme.defaultID)
        let paper = MarkdownTheme.theme(id: "paper")
        let css = paper.cssVariables(for: .dark)
        XCTAssertTrue(css.contains("--bg: \(paper.spec.dark.bg);"))
        XCTAssertTrue(css.contains("--hfont: \(paper.spec.headingFont);"))
        XCTAssertTrue(css.contains("--v-r-card: 10px;"), "size tokens ride along too")
        XCTAssertTrue(css.contains("--v-accent-text: #3CC6AA;"), "system colours ride along for the page")
        for t in MarkdownTheme.builtIn {
            for c in [t.spec.light, t.spec.dark] {
                for v in [c.bg, c.fg, c.fg2, c.acc, c.rule, c.code, c.sk, c.ss, c.sn, c.sc, c.sf, c.hl] {
                    XCTAssertNotNil(NSColor(css: v), "\(t.id): colour the page cannot use: \(v)")
                }
                XCTAssertTrue(c.bg.hasPrefix("#"), "\(t.id): the ground backs the web view and must be solid")
            }
        }
    }
}

final class PreviewSchemeHandlerTests: XCTestCase {
    func testResolvesDocAndVendorAndRefusesEscapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vt-scheme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("img"), withIntermediateDirectories: true)
        // S-16 F14: only a file that exists is resolved, and to its real path (the temp folder sits behind /var -> /private/var).
        try Data([0x89]).write(to: root.appendingPathComponent("img/a b.png"))
        let h = PreviewSchemeHandler(documentRoot: root)
        XCTAssertEqual(h.resolve(URL(string: "vitrine://doc/img/a%20b.png")!)?.path, try XCTUnwrap(ConfinedFile.realPath(root.path)) + "/img/a b.png")
        XCTAssertNil(h.resolve(URL(string: "vitrine://doc/img/missing.png")!), "a missing file is not resolved")
        XCTAssertNil(h.resolve(URL(string: "vitrine://doc/../secret.txt")!))
        XCTAssertNil(h.resolve(URL(string: "vitrine://doc/img/../../secret.txt")!))
        XCTAssertNil(h.resolve(URL(string: "vitrine://other/x")!))
        XCTAssertNil(h.resolve(URL(string: "file:///etc/passwd")!))
        let katex = try XCTUnwrap(h.resolve(URL(string: "vitrine://vendor/katex/katex.min.js")!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: katex.path), "vendored KaTeX must ship in the framework")
        let script = try XCTUnwrap(h.resolve(URL(string: "vitrine://app/markdown.js")!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path), "the page script ships beside the template")
        XCTAssertNil(h.resolve(URL(string: "vitrine://app/../../Info.plist")!))
        XCTAssertNil(h.resolve(URL(string: "vitrine://vendor/../Info.plist")!))
    }
}
