import Foundation
import XCTest
@testable import VitrineCompare

/// The prose compare against the design's state "Two files: rich prose diff" (an invented launch post).
/// roadmap: S-7
final class ProseCompareTests: XCTestCase {
    private let draft = """
    # Acme Notes 3.0 is here

    Acme Notes 3.0 brings faster search and a new export panel. Search now finds words inside attachments, and export can produce PDF or Markdown.

    ## What's new

    - Offline editing with automatic sync
    - Export to PDF and Markdown
    - A refreshed sidebar
    - Dark mode for the editor

    [Read the release notes](https://example.com/notes/3.0) for everything else.
    """

    private let final = """
    # Acme Notes 3.0 is here: notes that work offline

    Acme Notes 3.0 brings offline editing, faster search and a new export panel. Edits you make without a connection are queued and synced in order once you are back online.

    ## What's new

    - Offline editing with automatic sync
    - Search inside attachments
    - Export to PDF, Markdown and HTML
    - A refreshed sidebar

    [Read the release notes](https://example.com/notes/3-0) for everything else.
    """

    func testDesignStateChangeList() {
        let r = ProseCompare.compare(old: draft, new: final)
        XCTAssertEqual(r.changes.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(r.changes.map(\.title), ["Title", "Intro", "List", "Link"])
        XCTAssertEqual(r.changes[0].detail, "“: notes that work offline”")
        XCTAssertEqual(r.changes[1].detail, "offline editing, sentence replaced")
        XCTAssertTrue(r.changes[2].detail.hasPrefix("1 added, 1 removed, "), r.changes[2].detail)
        XCTAssertEqual(r.changes[3].detail, "target /3.0 → /3-0")
        // Each entry points at the block it describes.
        XCTAssertEqual(r.blocks[r.changes[0].block].kind, .heading)
        XCTAssertEqual(r.blocks[r.changes[1].block].kind, .paragraph)
        XCTAssertEqual(r.blocks[r.changes[2].block].kind, .listItem)
        XCTAssertEqual(r.blocks[r.changes[3].block].linkChanges.first?.old, "https://example.com/notes/3.0")
    }

    func testDesignStateBlocksAndSegments() {
        let r = ProseCompare.compare(old: draft, new: final)
        XCTAssertEqual(r.blocks.map(\.kind), [.heading, .paragraph, .heading, .listItem, .listItem, .listItem, .listItem,
                                              .listItem, .paragraph])
        XCTAssertEqual(r.blocks.map(\.status), [.changed, .changed, .same, .same, .added, .changed, .same, .removed, .changed])
        XCTAssertEqual(r.blocks[0].level, 1)
        XCTAssertEqual(r.blocks[3].level, 1)
        XCTAssertEqual(r.blocks[0].segments, [.init(text: "Acme Notes 3.0 is here", mark: .same),
                                              .init(text: ": notes that work offline", mark: .inserted)])
        // The rewritten second sentence is one replacement, not confetti.
        let intro = r.blocks[1].segments
        XCTAssertEqual(intro.filter { $0.mark == .deleted }.count, 1)
        XCTAssertEqual(intro.filter { $0.mark == .inserted }.count, 2)
        XCTAssertTrue(intro.contains { $0.mark == .deleted && $0.text.hasPrefix("Search now finds words") })
        XCTAssertTrue(intro.contains { $0.mark == .inserted && $0.text.hasPrefix("Edits you make") })
        // Reconstructing each side from the segments gives the block's text back.
        XCTAssertEqual(intro.filter { $0.mark != .inserted }.map(\.text).joined(),
                       "Acme Notes 3.0 brings faster search and a new export panel. Search now finds words inside attachments, and export can produce PDF or Markdown.")
        XCTAssertEqual(intro.filter { $0.mark != .deleted }.map(\.text).joined(),
                       "Acme Notes 3.0 brings offline editing, faster search and a new export panel. Edits you make without a connection are queued and synced in order once you are back online.")
        // The link-only change keeps its text unmarked.
        XCTAssertEqual(r.blocks[8].segments.map(\.mark), [.same])
        XCTAssertEqual(r.blocks[8].linkChanges, [.init(text: "Read the release notes", old: "https://example.com/notes/3.0",
                                                       new: "https://example.com/notes/3-0")])
    }

    func testDesignStateTotals() {
        let r = ProseCompare.compare(old: draft, new: final)
        XCTAssertEqual(r.blocksChanged, 6)
        XCTAssertFalse(r.isEqual)
        XCTAssertTrue(r.isComplete)
        let inserted = r.blocks.flatMap(\.segments).filter { $0.mark == .inserted }.map(\.text).joined(separator: " ")
        let deleted = r.blocks.flatMap(\.segments).filter { $0.mark == .deleted }.map(\.text).joined(separator: " ")
        XCTAssertEqual(r.insertions, WordToken.tokenize(inserted).filter { $0.kind == .word }.count)
        XCTAssertEqual(r.deletions, WordToken.tokenize(deleted).filter { $0.kind == .word }.count)
        XCTAssertEqual(r.summary, "\(r.insertions) insertions and \(r.deletions) deletions in 6 blocks")
    }

    func testIdenticalProse() {
        let r = ProseCompare.compare(old: draft, new: draft)
        XCTAssertTrue(r.isEqual)
        XCTAssertTrue(r.changes.isEmpty)
        XCTAssertEqual(r.summary, "No differences")
        XCTAssertTrue(r.blocks.allSatisfy { $0.status == .same })
    }

    func testAddedAndRemovedBlocks() {
        let r = ProseCompare.compare(old: "Alpha one.\n\nBeta two.\n", new: "Alpha one.\n\nGamma ray burst here.\n\nBeta two.\n\n```swift\nlet x = 1\n```\n")
        XCTAssertEqual(r.blocks.map(\.status), [.same, .added, .same, .added])
        XCTAssertEqual(r.blocks[3].kind, .code)
        XCTAssertEqual(r.blocks[3].language, "swift")
        XCTAssertEqual(r.changes.map(\.title), ["Paragraph", "Code block"])
        XCTAssertEqual(r.changes.map(\.detail), ["added", "added"])
        XCTAssertEqual(r.insertions, 4 + 3)
    }

    func testHeadingLevelChange() {
        let r = ProseCompare.compare(old: "## Setup\n", new: "### Setup\n")
        XCTAssertEqual(r.blocks.map(\.status), [.changed])
        XCTAssertEqual(r.changes.first?.title, "Heading")
        XCTAssertEqual(r.changes.first?.detail, "heading level 2 → 3")
    }

    func testWordReplacementDetail() {
        let r = ProseCompare.compare(old: "The quick fox.\n", new: "The slow fox.\n")
        XCTAssertEqual(r.blocks[0].segments, [.init(text: "The ", mark: .same), .init(text: "quick", mark: .deleted),
                                              .init(text: "slow", mark: .inserted), .init(text: " fox.", mark: .same)])
        XCTAssertEqual(r.changes.first?.detail, "“quick” → “slow”")
        XCTAssertEqual(r.insertions, 1); XCTAssertEqual(r.deletions, 1)
    }

    func testNestedListsQuotesAndTasks() {
        let r = ProseCompare.compare(old: "> Quoted line\n\n- [ ] ship it\n  - nested\n",
                                     new: "> Quoted line\n\n- [x] ship it\n  - nested\n")
        XCTAssertEqual(r.blocks.map(\.kind), [.quote, .listItem, .listItem])
        XCTAssertEqual(r.blocks.map(\.level), [1, 1, 2])
        XCTAssertEqual(r.blocks.map(\.status), [.same, .changed, .same])
        XCTAssertEqual(r.changes.map(\.title), ["List"])
    }

    func testPlainTextParagraphs() {
        let r = ProseCompare.compare(old: "First para\nstill first.\n\nSecond.", new: "First para\nstill first.\n\nSecond one.",
                                     format: .plain)
        XCTAssertEqual(r.format, .plain)
        XCTAssertEqual(r.blocks.map(\.status), [.same, .changed])
        XCTAssertEqual(r.changes.first?.title, "Paragraph")
        XCTAssertEqual(r.insertions, 1)
    }

    func testBlockLimitMarksIncomplete() {
        let many = (1...30).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        let r = ProseCompare.compare(old: many, new: many, limits: .init(maxBlocks: 10))
        XCTAssertEqual(r.blocks.count, 10)
        XCTAssertFalse(r.isComplete)
        XCTAssertNotNil(r.incompleteReason)
    }

    func testURLTails() {
        XCTAssertEqual(ProseCompare.shortTargets("https://a.com/x/3.0", "https://a.com/x/3-0").0, "/3.0")
        XCTAssertEqual(ProseCompare.shortTargets("https://a.com/", "mailto:b").1, "mailto:b")
    }

    func testResultIsCodable() throws {
        let r = ProseCompare.compare(old: draft, new: final)
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(ProseComparison.self, from: data), r)
    }
}
