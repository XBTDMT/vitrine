import XCTest
import VitrineSupport
@testable import VitrineText

/// MDX, MDC, Quarto, R Markdown, reStructuredText, AsciiDoc and Org drawn through the Markdown pipeline (M-11):
/// each sample goes through the dialect step and cmark, and the test reads the HTML the page would show.
/// Every sample is invented. roadmap: S-4, S-12
final class MarkdownDialectsTests: XCTestCase {
    private func html(_ source: String, _ dialect: FileKind.MarkdownDialect) -> String {
        MarkdownHTML.render(MarkdownDialects.prepare(source, dialect: dialect))
    }

    func testMDXComponentsAreLabelledBlocksAndImportsAreHiddenAndCounted() {
        let out = html("""
        import { Steps } from "../components"

        ## Pairing a new Mac

        Open Tidepool on both Macs, then follow the code.

        <Callout type="info">
        The code expires after **two minutes**.
        </Callout>

        <Steps />

        ```jsx
        import { Hidden } from "not-this"
        <Steps />
        ```
        """, .mdx)
        XCTAssertTrue(out.contains("<div class=\"mdxc\"><span class=\"mdxt\">&lt;Callout type=&quot;info&quot;&gt;</span>")
                      || out.contains("<div class=\"mdxc\"><span class=\"mdxt\">&lt;Callout type=\"info\"&gt;</span>"), out)
        XCTAssertTrue(out.contains("<strong>two minutes</strong>"), "Markdown inside a component still renders")
        XCTAssertTrue(out.contains("&lt;Steps /&gt;</span><p class=\"mdxn\">MDX component"), out)
        XCTAssertTrue(out.contains("— 1 import hidden"), out)
        XCTAssertFalse(out.contains("<p>import { Steps }"), "the import line itself is not drawn as text")
        XCTAssertTrue(out.contains("import { Hidden } from"), "code fences are never touched")
    }

    func testMDCBlocksAreLabelledAndClosed() {
        let out = html("""
        # Tidepool

        ::hero{color="blue"}
        Sync your notes **privately**.
        ::

        After the hero.
        """, .mdc)
        XCTAssertTrue(out.contains("<span class=\"mdxt\">::hero{color=&quot;blue&quot;}</span>") || out.contains("::hero{color=\"blue\"}</span>"), out)
        XCTAssertTrue(out.contains("<strong>privately</strong>"))
        XCTAssertTrue(out.contains("</div>\n<p>After the hero.</p>"), out)
    }

    func testQuartoChunksHighlightAsTheirLanguageAndCalloutsBecomeAlerts() {
        let out = html("""
        ---
        title: "Tide report"
        ---

        ```{python tides, echo=false}
        import pandas as pd
        ```

        ::: {.callout-warning}
        Readings after 18:00 are estimates.
        :::

        ::: {.column-margin}
        A margin note.
        :::
        """, .quarto)
        XCTAssertTrue(out.contains("<pre lang=\"python\"><code>import pandas as pd") || out.contains("class=\"language-python\""), out)
        XCTAssertTrue(out.contains("tides · echo=false"), "the chunk's label and options as a caption")
        XCTAssertTrue(out.contains("alert alert-warning"), out)
        XCTAssertTrue(out.contains("Readings after 18:00 are estimates."))
        XCTAssertTrue(out.contains("A margin note."), "an unknown fenced div keeps its content")
        XCTAssertFalse(out.contains(":::"), out)
    }

    func testRMarkdownChunks() {
        let out = html("```{r setup, include=FALSE}\nlibrary(tidyr)\n```\n", .rMarkdown)
        XCTAssertTrue(out.contains("library(tidyr)"))
        XCTAssertTrue(out.contains("lang=\"r\"") || out.contains("language-r"), out)
    }

    func testReStructuredText() {
        let out = html("""
        ==============
        Tidepool guide
        ==============

        Getting started
        ---------------

        Install with ``brew install tidepool`` and read the `docs <https://example.com/docs>`_.
        See also tides_.

        .. _tides: https://example.com/tides

        .. note:: Sync needs both Macs online.

        .. code-block:: swift

           let city = "Lisbon"

        Example::

           raw literal text

        #. first
        #. second

        .. a hidden comment

        +-------+-----+
        | grid  | tbl |
        +-------+-----+

        .. unknowndirective:: arg
           body
        """, .reStructuredText)
        XCTAssertTrue(out.contains("<h1>Tidepool guide</h1>"), out)
        XCTAssertTrue(out.contains("<h2>Getting started</h2>"), out)
        XCTAssertTrue(out.contains("<code>brew install tidepool</code>"))
        XCTAssertTrue(out.contains("<a href=\"https://example.com/docs\">docs</a>"), out)
        XCTAssertTrue(out.contains("<a href=\"https://example.com/tides\">tides</a>"), out)
        XCTAssertTrue(out.contains("alert alert-note") && out.contains("Sync needs both Macs online."), out)
        XCTAssertTrue(out.contains("let city = &quot;Lisbon&quot;") || out.contains("let city = \"Lisbon\""), out)
        XCTAssertTrue(out.contains("<pre><code>raw literal text"), out)
        XCTAssertTrue(out.contains("<ol>"), out)
        XCTAssertFalse(out.contains("hidden comment"))
        XCTAssertTrue(out.contains("| grid  | tbl |"), "a grid table is shown as source")
        XCTAssertTrue(out.contains(".. unknowndirective:: arg"), "an unknown directive is shown as source, not dropped")
    }

    func testAsciiDoc() {
        let out = html("""
        = Tidepool Guide
        :toc:
        :author: Invented

        == Install

        Run *carefully* and _slowly_ with `brew`.
        See https://example.com[the site] and <<sync,Sync>>.

        NOTE: Both Macs need to be online.

        [source,swift]
        ----
        let city = "Porto"
        ----

        * one
        ** nested
        . first

        .Block title
        image::tide.png[Tide chart]

        // a comment

        [WARNING]
        ====
        Readings are estimates.
        ====
        """, .asciiDoc)
        XCTAssertTrue(out.contains("<h1>Tidepool Guide</h1>") && out.contains("<h2>Install</h2>"), out)
        XCTAssertFalse(out.contains(":toc:"))
        XCTAssertTrue(out.contains("<strong>carefully</strong>") && out.contains("<em>slowly</em>"), out)
        XCTAssertTrue(out.contains("<a href=\"https://example.com\">the site</a>"), out)
        XCTAssertTrue(out.contains("<a href=\"#sync\">Sync</a>"), out)
        XCTAssertTrue(out.contains("alert alert-note") && out.contains("alert alert-warning"), out)
        XCTAssertTrue(out.contains("let city = &quot;Porto&quot;") || out.contains("let city = \"Porto\""), out)
        XCTAssertTrue(out.contains("<img src=\"tide.png\" alt=\"Tide chart\""), out)
        XCTAssertTrue(out.contains("<strong>Block title</strong>"), out)
        XCTAssertFalse(out.contains("a comment"))
    }

    func testOrg() {
        let out = html("""
        #+TITLE: Tide log
        #+AUTHOR: Invented
        * TODO Check the gauge   :work:
        :PROPERTIES:
        :ID: 1234
        :END:
        Some *bold*, /italic/, =verbatim=, ~code~ and +struck+ text, a [[https://example.com][link]].
        - [X] done item
        - [ ] open item
        1) first

        #+BEGIN_SRC python
        print("tide")
        #+END_SRC

        #+BEGIN_QUOTE
        The sea is patient.
        #+END_QUOTE

        | Place  | Height |
        |--------+--------|
        | Lisbon | 3.1    |

        # a comment
        """, .org)
        XCTAssertTrue(out.contains("<h1>Tide log</h1>") && out.contains("<h2>TODO Check the gauge</h2>"), "sections sit under the title")
        XCTAssertFalse(out.contains(":work:") || out.contains(":ID:") || out.contains("a comment"), out)
        XCTAssertTrue(out.contains("<strong>bold</strong>") && out.contains("<em>italic</em>"), out)
        XCTAssertTrue(out.contains("<code>verbatim</code>") && out.contains("<code>code</code>") && out.contains("<del>struck</del>"), out)
        XCTAssertTrue(out.contains("<a href=\"https://example.com\">link</a>"), out)
        XCTAssertTrue(out.contains("checked=\"\"") || out.contains("checked"), "a task list")
        XCTAssertTrue(out.contains("print(&quot;tide&quot;)") || out.contains("print(\"tide\")"), out)
        XCTAssertTrue(out.contains("<blockquote>"), out)
        XCTAssertTrue(out.contains("<table>") && out.contains("<td>Lisbon</td>"), out)
    }

    func testCommonMarkIsUntouched() {
        let source = "# Title\n\n<Steps />\n\n::not-mdc\n"
        XCTAssertEqual(MarkdownDialects.prepare(source, dialect: .commonMark), source)
    }
}
