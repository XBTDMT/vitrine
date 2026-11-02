import WebKit
import XCTest
@testable import VitrinePreviewKit
import VitrineSupport
import VitrineUI

/// The code view's appearance (S-5, state 15): themes, display options kept between files, the popover, editor
/// theme import, and the changed-line gutter. All content is invented here. roadmap: S-5
@MainActor
final class CodeAppearanceTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!
    private let suite = "vt-code-appearance"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-codeapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        CodeRenderer.readyTimeout = .seconds(10)
    }

    override func tearDownWithError() throws {
        CodeRenderer.readyTimeout = .seconds(3)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private let source = """
    struct SyncQueue {
        var pending: [String] = []
        func flush() -> Int {
            if pending.isEmpty {
                return 0
            }
            return pending.count
        }
    }

    """

    private func render(_ appearance: DesignTokens.Appearance = .light) async throws -> (CodeRenderer, RenderedPreview, WKWebView) {
        let url = dir.appendingPathComponent("SyncQueue.swift")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let renderer = CodeRenderer()
        let preview = try await renderer.render(url: url, kind: .code(language: "swift"),
                                                context: RenderContext(appearance: appearance, defaultsSuite: suite))
        return (renderer, preview, try XCTUnwrap((preview.view as? CodeContainer)?.web, "\(renderer.pageErrors)"))
    }

    private func js(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.callAsyncJavaScript(script, contentWorld: .page)
    }

    private func keywordStyle(_ web: WKWebView) async throws -> String? {
        try await js(web, """
            const s = Array.from(document.querySelectorAll('.cm-line span[style]')).find(e => e.textContent === 'struct');
            return s ? s.getAttribute('style') : null;
            """) as? String
    }

    func testAThemePickRecoloursThePageAndIsKeptForTheNextFile() async throws {
        let (_, preview, web) = try await render()
        XCTAssertNotNil(preview.displayOptions, "the capsule shows the More button")
        let v1 = try await js(web, "return window.vitrine.themeName();") as? String
        XCTAssertEqual(v1, "vitrine")
        _ = try await js(web, "await window.vitrine.setOption('theme', 'github'); return true;")
        let v2 = try await js(web, "return window.vitrine.themeName();") as? String
        XCTAssertEqual(v2, "github-light", "the light half of the pair")
        let ground = try await js(web, "return getComputedStyle(document.body).backgroundColor;") as? String
        XCTAssertEqual(ground, "rgb(255, 255, 255)")
        // GitHub Light's keyword red.
        let v3 = try await keywordStyle(web)?.contains("rgb(215, 58, 73)")
        XCTAssertEqual(v3, true, "")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(UserDefaults(suiteName: suite)?.string(forKey: "code.theme"), "github")

        // The next file opens in it, in its dark half when the Mac is dark.
        let (_, _, dark) = try await render(.dark)
        let v4 = try await js(dark, "return window.vitrine.themeName();") as? String
        XCTAssertEqual(v4, "github-dark")
    }

    func testDisplayOptionsApplyAtOnceAndAreKept() async throws {
        // The preview is kept: it owns the renderer that receives the page's messages.
        let (_, preview, web) = try await render()
        defer { withExtendedLifetime(preview) {} }
        let v5 = try await js(web, "return document.querySelectorAll('.cm-lineNumbers .cm-gutterElement').length;") as? Int
        XCTAssertGreaterThan(v5 ?? 0, 0)
        let v6 = try await js(web, "return document.querySelectorAll('.cm-line.vt-ig').length;") as? Int
        XCTAssertGreaterThan(v6 ?? 0, 0,
                             "indent guides are on by default")
        _ = try await js(web, """
            await window.vitrine.setOption('lineNumbers', false);
            await window.vitrine.setOption('minimap', true);
            await window.vitrine.setOption('fontSize', 15);
            await window.vitrine.setOption('tabSize', 2);
            return true;
            """)
        let v7 = try await js(web, "return document.querySelectorAll('.cm-lineNumbers').length;") as? Int
        XCTAssertEqual(v7, 0)
        let v8 = try await js(web, "return document.querySelectorAll('canvas.vt-minimap').length;") as? Int
        XCTAssertEqual(v8, 1)
        let v9 = try await js(web, "return getComputedStyle(document.querySelector('.cm-content')).fontSize;") as? String
        XCTAssertEqual(v9, "15px")
        try await Task.sleep(for: .milliseconds(100))
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(d.object(forKey: "code.lineNumbers") as? Bool, false)
        XCTAssertEqual(d.object(forKey: "code.fontSize") as? Int, 15)
        XCTAssertEqual(CodeOptions(defaults: d).tabSize, 2)
        XCTAssertTrue(CodeOptions(defaults: d).minimap)
    }

    func testThePopoverShowsTwentyFourThemesAndTheOptions() async throws {
        let (_, preview, web) = try await render()
        preview.displayOptions?()
        var tiles = 0
        for _ in 0..<80 {
            tiles = try await js(web, "return document.querySelectorAll('#vt-tpop .vt-thw').length;") as? Int ?? 0
            if tiles > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(tiles, 24)
        // More themes: the rest of the set, past the 38 the parity target lists.
        _ = try await js(web, "document.querySelector('#vt-tpop .vt-morebtn').click(); return true;")
        let all = try await js(web, "return document.querySelectorAll('#vt-tpop .vt-thw').length;") as? Int
        XCTAssertEqual(all, 48)
        let v10 = try await js(web, "return document.querySelector('#vt-tpop .vt-thw.on .vt-thn').textContent;") as? String
        XCTAssertEqual(v10, "Vitrine (auto)")
        let toggles = try await js(web, "return Array.from(document.querySelectorAll('#vt-tpop .vt-tog span')).map(e => e.textContent);") as? [String]
        XCTAssertEqual(toggles, ["Wrap lines", "Line numbers", "Indent guides", "Changed lines", "Sticky scope", "Minimap"])
        // Escape closes it.
        _ = try await js(web, "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); return true;")
        let v11 = try await js(web, "return document.querySelectorAll('#vt-tpop').length;") as? Int
        XCTAssertEqual(v11, 0)
    }

    func testImportsVSCodeZedAndTextMateThemes() throws {
        let vscode = """
        {
          // a comment, as VS Code allows
          "name": "Fjord", "type": "dark",
          "colors": { "editor.background": "#152029", "editor.foreground": "#D3DEE7", "bogus": "red" },
          "tokenColors": [
            { "scope": ["keyword", "storage"], "settings": { "foreground": "#7FC4E8" } },
            { "scope": "string", "settings": { "foreground": "#C7E39A", "fontStyle": "italic" } },
          ]
        }
        """
        let a = try CodeThemeImport.read(Data(vscode.utf8), fileName: "fjord-color-theme.json")
        XCTAssertEqual(a.map(\.name), ["Fjord"])
        let theme = try XCTUnwrap(try JSONSerialization.jsonObject(with: a[0].theme) as? [String: Any])
        XCTAssertEqual((theme["colors"] as? [String: String])?["editor.background"], "#152029")
        XCTAssertNil((theme["colors"] as? [String: String])?["bogus"], "colours that are not hex are dropped")
        XCTAssertEqual((theme["tokenColors"] as? [Any])?.count, 2)

        let zed = """
        { "name": "Harbor Lights", "themes": [
          { "name": "Harbor Lights Dark", "appearance": "dark", "style": { "editor.background": "#101820", "editor.foreground": "#E0E6EB",
            "syntax": { "keyword": { "color": "#FF9F6E" }, "comment": { "color": "#6B7A86", "font_style": "italic" } } } },
          { "name": "Harbor Lights Light", "appearance": "light", "style": { "editor.background": "#FFFFFF",
            "syntax": { "string": { "color": "#2B7A5B" } } } } ] }
        """
        let b = try CodeThemeImport.read(Data(zed.utf8), fileName: "harbor.json")
        XCTAssertEqual(b.map(\.name), ["Harbor Lights Dark", "Harbor Lights Light"])

        let tm = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>name</key><string>Lumen</string><key>settings</key><array>
          <dict><key>settings</key><dict><key>background</key><string>#FAFAF7</string><key>foreground</key><string>#222222</string></dict></dict>
          <dict><key>scope</key><string>keyword</string><key>settings</key><dict><key>foreground</key><string>#8A3FB0</string></dict></dict>
        </array></dict></plist>
        """
        let c = try CodeThemeImport.read(Data(tm.utf8), fileName: "Lumen.tmTheme")
        let lumen = try XCTUnwrap(try JSONSerialization.jsonObject(with: c[0].theme) as? [String: Any])
        XCTAssertEqual(lumen["type"] as? String, "light")

        XCTAssertThrowsError(try CodeThemeImport.read(Data("{\"hello\": 1}".utf8), fileName: "x.json"))
        XCTAssertThrowsError(try CodeThemeImport.read(Data(count: CodeThemeImport.maxBytes + 1), fileName: "big.json"))
    }

    func testAnImportedThemeIsOfferedAndUsable() async throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fjord = """
        { "name": "Fjord", "type": "dark", "colors": { "editor.background": "#152029", "editor.foreground": "#D3DEE7" },
          "tokenColors": [ { "scope": ["keyword", "storage"], "settings": { "foreground": "#7FC4E8" } } ] }
        """
        let themes = try CodeThemeImport.read(Data(fjord.utf8), fileName: "fjord.json")
        CodeThemeImport.store(themes, in: d)
        d.set(themes[0].id, forKey: "code.theme")
        let (_, _, web) = try await render()
        let v12 = try await js(web, "return getComputedStyle(document.body).backgroundColor;") as? String
        XCTAssertEqual(v12, "rgb(21, 32, 41)")
        let v13 = try await keywordStyle(web)?.contains("rgb(127, 196, 232)")
        XCTAssertEqual(v13, true)
    }

    func testChangedLinesAgainstTheLastCommit() {
        let old = "a\nb\nc\nd\ne\n"
        let new = "a\nB\nc\nnew\nd\n"
        XCTAssertEqual(CodeChanges.runs(old: old, new: new), [
            CodeChanges.Run(from: 2, to: 2, kind: "mod"),
            CodeChanges.Run(from: 4, to: 4, kind: "add"),
            CodeChanges.Run(from: 5, to: 5, kind: "del"),
        ])
        XCTAssertEqual(CodeChanges.runs(old: old, new: old), [])
    }

    func testChangedLinesDrawInTheGutter() async throws {
        let url = dir.appendingPathComponent("SyncQueue.swift")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let renderer = CodeRenderer()
        let preview = try await renderer.render(url: url, kind: .code(language: "swift"), context: RenderContext(appearance: .light, defaultsSuite: suite))
        let web = try XCTUnwrap((preview.view as? CodeContainer)?.web)
        _ = try await js(web, "window.vitrine.setChanges([{ from: 2, to: 3, kind: 'add' }, { from: 5, to: 5, kind: 'mod' }]); return true;")
        let v14 = try await js(web, "return Array.from(document.querySelectorAll('.vt-chg-add')).filter(e => e.parentElement.style.visibility !== 'hidden').length;") as? Int
        XCTAssertEqual(v14, 2)
        let v15 = try await js(web, "return Array.from(document.querySelectorAll('.vt-chg-mod')).filter(e => e.parentElement.style.visibility !== 'hidden').length;") as? Int
        XCTAssertEqual(v15, 1)
    }

    // MARK: The ruler (C-8)

    func testTheRulerIsTheScrollbarAndMarksMatchesAndChanges() async throws {
        let long = (0..<30).map { _ in source }.joined()
        let url = dir.appendingPathComponent("SyncQueue.swift")
        try long.write(to: url, atomically: true, encoding: .utf8)
        let renderer = CodeRenderer()
        let preview = try await renderer.render(url: url, kind: .code(language: "swift"), context: RenderContext(appearance: .light, defaultsSuite: suite))
        let web = try XCTUnwrap((preview.view as? CodeContainer)?.web)
        // In a window, so the page has a real height to scroll (as in Quick Look).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = preview.view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        let parts = try await js(web, "return [document.querySelectorAll('.vt-ruler').length, document.querySelector('.vt-ruler .thumb').hidden];") as? [Any]
        XCTAssertEqual(parts?[0] as? Int, 1)
        XCTAssertEqual(parts?[1] as? Bool, false, "a file taller than the view has a thumb")
        let find = try XCTUnwrap(preview.find)
        _ = await find("pending.count", true)
        _ = try await js(web, "window.vitrine.setChanges([{ from: 2, to: 3, kind: 'add' }, { from: 40, to: 40, kind: 'mod' }]); return true;")
        try await Task.sleep(for: .milliseconds(120))
        let marks = try await js(web, "return window.vitrine.rulerMarks();") as? [String] ?? []
        XCTAssertEqual(marks.filter { $0 == "fc" }.count, 1, "the current match")
        XCTAssertEqual(marks.filter { $0 == "f" }.count, 29, "the other 29 matching lines")
        XCTAssertEqual(marks.filter { $0 == "add" }.count, 1)
        XCTAssertEqual(marks.filter { $0 == "chg" }.count, 1)
        // A click near the bottom of the ruler moves the view there.
        let moved = try await js(web, """
            const r = document.querySelector('.vt-ruler').getBoundingClientRect(), s = window.vitrine.view.scrollDOM;
            s.scrollTop = 0;
            document.querySelector('.vt-ruler').dispatchEvent(new MouseEvent('mousedown', { clientX: r.left + 6, clientY: r.bottom - 5, bubbles: true }));
            window.dispatchEvent(new MouseEvent('mouseup'));
            return s.scrollTop > s.scrollHeight / 2;
            """) as? Bool
        XCTAssertEqual(moved, true)
    }
}
