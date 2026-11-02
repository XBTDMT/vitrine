import XCTest
import WebKit
@testable import VitrinePreviewKit

/// Markdown's code blocks coloured by the code view's Shiki in the Markdown theme's own code colours (S-5). All
/// content is invented here. roadmap: S-5
@MainActor
final class MarkdownFenceTests: XCTestCase {
    private func render(_ markdown: String) async throws -> (RenderedPreview, WKWebView) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-fence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        let preview = try await MarkdownRenderer().render(url: url, kind: .markdown(.commonMark),
                                                          context: RenderContext(appearance: .light, defaultsSuite: "vt-fence-suite"))
        return (preview, try XCTUnwrap(preview.view as? WKWebView))
    }

    private func coloured(_ web: WKWebView) async throws -> Int {
        for _ in 0..<200 {
            let n = try await web.evaluateJavaScript("document.querySelectorAll('code[data-vt-coloured]').length") as? Int ?? 0
            if n > 0 { return n }
            try await Task.sleep(for: .milliseconds(25))
        }
        return 0
    }

    func testAFencedBlockTakesTheThemesKeywordColour() async throws {
        let (preview, web) = try await render("""
        # Orbit notes

        ```swift
        struct OrbitPlan { let stops = 2 }
        ```

        ```
        no language, left plain
        ```

        ```mermaid
        flowchart LR
          A --> B
        ```
        """)
        defer { withExtendedLifetime(preview) {} }
        let n = try await coloured(web)
        XCTAssertEqual(n, 1, "only the block with a language Shiki knows")
        let same = try await web.evaluateJavaScript("""
            (function () {
              const s = Array.from(document.querySelectorAll('code.language-swift span')).find(e => e.textContent === 'struct');
              const probe = document.createElement('span'); probe.style.color = getComputedStyle(document.documentElement).getPropertyValue('--sk');
              document.body.append(probe); const want = getComputedStyle(probe).color; probe.remove();
              return s ? getComputedStyle(s).color === want : 'no struct span';
            })()
            """) as? Bool
        XCTAssertEqual(same, true)
        let text = try await web.evaluateJavaScript("document.querySelector('code.language-swift').textContent") as? String
        XCTAssertEqual(text, "struct OrbitPlan { let stops = 2 }\n", "colouring never changes the text")
    }
}
