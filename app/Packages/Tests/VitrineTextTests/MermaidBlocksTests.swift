import XCTest
@testable import VitrineText

final class MermaidBlocksTests: XCTestCase {
    private let fence = "```mermaid\nflowchart LR\n  A[\"a & b\"] --> B<\"x\">\n```\n"

    func testFindsTheSourceExactly() {
        let html = MarkdownHTML.render("# T\n\n" + fence + "\n```swift\nlet x = 1\n```\n")
        let blocks = MermaidBlocks.find(in: html)
        XCTAssertEqual(blocks.map(\.source), ["flowchart LR\n  A[\"a & b\"] --> B<\"x\">\n"])
    }

    func testKeyChangesWithEverythingThatChangesTheDrawing() {
        let base = MermaidBlocks.key(source: "a", theme: "vitrine", appearance: "light", mermaidVersion: "12.2.0")
        XCTAssertEqual(base.count, 64)
        XCTAssertEqual(base, MermaidBlocks.key(source: "a", theme: "vitrine", appearance: "light", mermaidVersion: "12.2.0"))
        XCTAssertNotEqual(base, MermaidBlocks.key(source: "b", theme: "vitrine", appearance: "light", mermaidVersion: "12.2.0"))
        XCTAssertNotEqual(base, MermaidBlocks.key(source: "a", theme: "paper", appearance: "light", mermaidVersion: "12.2.0"))
        XCTAssertNotEqual(base, MermaidBlocks.key(source: "a", theme: "vitrine", appearance: "dark", mermaidVersion: "12.2.0"))
        XCTAssertNotEqual(base, MermaidBlocks.key(source: "a", theme: "vitrine", appearance: "light", mermaidVersion: "12.3.0"))
    }

    func testRewriteUsesTheCacheOrTagsTheBlock() {
        let html = MarkdownHTML.render(fence + "\n" + "```mermaid\nsequenceDiagram\n  A->>B: hi\n```\n")
        let out = MermaidBlocks.rewrite(html, key: { $0.hasPrefix("flowchart") ? "k1" : "k2" },
                                        cached: { $0 == "k1" ? "<svg id=\"m\"></svg>" : nil })
        XCTAssertTrue(out.contains(#"<div class="mermaid-block" data-cached="1"><svg id="m"></svg></div>"#), out)
        XCTAssertTrue(out.contains(#"<pre data-mermaid-key="k2"><code class="language-mermaid">sequenceDiagram"#), out)
        XCTAssertTrue(out.contains("A-&gt;&gt;B: hi"), "the uncached source stays escaped")
        XCTAssertEqual(MermaidBlocks.find(in: out).count, 0, "tagged blocks no longer match the plain pattern")
    }
}
