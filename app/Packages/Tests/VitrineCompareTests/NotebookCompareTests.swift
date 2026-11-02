import Foundation
import XCTest
@testable import VitrineCompare

/// The notebook compare against the design's state "Two notebooks: cell diff" (an invented churn model notebook,
/// written here as nbformat 4 JSON). roadmap: S-7
final class NotebookCompareTests: XCTestCase {
    private func code(_ source: [String], count: Int?, outputs: [[String: Any]] = [], metadata: [String: Any] = [:],
                      id: String? = nil) -> [String: Any] {
        var cell: [String: Any] = ["cell_type": "code", "source": source, "outputs": outputs, "metadata": metadata,
                                   "execution_count": count as Any? ?? NSNull()]
        if let id { cell["id"] = id }
        return cell
    }

    private func markdown(_ source: String, id: String? = nil) -> [String: Any] {
        var cell: [String: Any] = ["cell_type": "markdown", "source": source, "metadata": [String: Any]()]
        if let id { cell["id"] = id }
        return cell
    }

    private func stream(_ text: String) -> [String: Any] { ["output_type": "stream", "name": "stdout", "text": [text]] }

    private func png(_ base64: String) -> [String: Any] {
        ["output_type": "display_data", "data": ["image/png": base64, "text/plain": ["<Figure size 640x480>"]], "metadata": [:]]
    }

    private func notebook(_ cells: [[String: Any]], metadata: [String: Any] = ["kernelspec": ["name": "python3"]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["nbformat": 4, "nbformat_minor": 5, "metadata": metadata, "cells": cells])
    }

    private func designPair() throws -> (Data, Data) {
        let old = try notebook([
            markdown("# Churn model\n"),
            code(["from sklearn.ensemble import GradientBoostingClassifier\n",
                  "model = GradientBoostingClassifier(max_depth=4, n_estimators=200)\n",
                  "model.fit(X_train, y_train)\n"], count: 3),
            code(["print(f\"accuracy {model.score(X_test, y_test):.3f}\")\n"], count: 4, outputs: [stream("accuracy 0.871\n")]),
            code(["plot_importance(model)\n"], count: 5, outputs: [png("iVBORw0KGgoAAAA")], metadata: ["collapsed": false]),
            code(["df.describe()\n"], count: 6, outputs: [stream("count 100\n")]),
        ])
        let new = try notebook([
            markdown("# Churn model\n"),
            code(["from sklearn.ensemble import GradientBoostingClassifier\n",
                  "model = GradientBoostingClassifier(max_depth=6, n_estimators=300, learning_rate=0.05)\n",
                  "model.fit(X_train, y_train)\n"], count: 4),
            code(["print(f\"accuracy {model.score(X_test, y_test):.3f}\")\n"], count: 5, outputs: [stream("accuracy 0.894\n")]),
            code(["plot_importance(model)\n"], count: 6, outputs: [png("iVBORw0KGgoBBBB")], metadata: ["collapsed": true]),
            markdown("## Notes\nThe deeper model wins on recall.\n"),
        ])
        return (old, new)
    }

    func testDesignStateCountsAndNotes() throws {
        let (old, new) = try designPair()
        let r = try NotebookCompare.compare(old: old, new: new)
        XCTAssertFalse(r.matchedByID)
        XCTAssertEqual(r.counts.cells, 6)
        XCTAssertEqual(r.counts.changed, 5)
        XCTAssertEqual(r.lead, "6 cells · 5 changed")
        XCTAssertEqual(r.summary, "1 source change, 2 output changes, 1 cell added, 1 removed")
        XCTAssertEqual(r.counts.hiddenExecutionCounts, 3)
        XCTAssertEqual(r.counts.hiddenMetadataChanges, 1)
        XCTAssertEqual(r.hiddenNote, "Execution counts and 1 metadata change hidden")
        XCTAssertFalse(r.isEqual)
        XCTAssertTrue(r.isComplete)
    }

    func testDesignStateChangeList() throws {
        let (old, new) = try designPair()
        let r = try NotebookCompare.compare(old: old, new: new)
        XCTAssertEqual(r.changes.map(\.index), [2, 3, 4, 5, 6])
        XCTAssertEqual(r.changes.map(\.title), ["Code cell", "Code cell", "Code cell", "Code cell", "Markdown cell"])
        XCTAssertEqual(r.changes.map(\.detail), ["Source changed", "Output changed", "Output changed (image)", "Removed", "Added"])
        XCTAssertEqual(r.cells.map(\.status), [.same, .sourceChanged, .outputChanged, .outputChanged, .removed, .added])
    }

    func testSourceRowsWithIntralineHighlights() throws {
        let (old, new) = try designPair()
        let r = try NotebookCompare.compare(old: old, new: new)
        let cell = r.cells[1]
        XCTAssertEqual(cell.oldExecutionCount, 3); XCTAssertEqual(cell.newExecutionCount, 4)
        XCTAssertTrue(cell.executionCountChanged)
        XCTAssertEqual(cell.rows.map(\.kind), [.context, .deleted, .added, .context])
        XCTAssertEqual(cell.rows.map(\.oldNumber), [1, 2, nil, 3])
        XCTAssertEqual(cell.rows.map(\.newNumber), [1, nil, 2, 3])
        let deleted = cell.rows[1]
        XCTAssertFalse(deleted.highlights.isEmpty)
        let utf16 = Array(deleted.text.utf16)
        let marked = deleted.highlights.map { String(decoding: utf16[$0.start..<($0.start + $0.length)], as: UTF16.self) }
        XCTAssertTrue(marked.contains("4"), "\(marked)")
        XCTAssertFalse(cell.rows[2].highlights.isEmpty)
    }

    func testOutputsComparedByType() throws {
        let (old, new) = try designPair()
        let r = try NotebookCompare.compare(old: old, new: new)
        let text = r.cells[2].outputs
        XCTAssertEqual(text.count, 1)
        XCTAssertEqual(text[0].type, .stream)
        XCTAssertEqual(text[0].status, .changed)
        XCTAssertEqual(text[0].old, "accuracy 0.871\n"); XCTAssertEqual(text[0].new, "accuracy 0.894\n")
        let image = r.cells[3].outputs
        XCTAssertEqual(image.first?.type, .image)
        XCTAssertEqual(image.first?.mime, "image/png")
        XCTAssertEqual(image.first?.oldImage, "iVBORw0KGgoAAAA")
        XCTAssertEqual(image.first?.newImage, "iVBORw0KGgoBBBB")
        XCTAssertEqual(r.cells[3].outputDescription, "Output changed (image)")
        XCTAssertTrue(r.cells[3].metadataChanged)
        // A removed cell's rows and outputs are all on the old side.
        XCTAssertEqual(r.cells[4].rows.map(\.kind), [.deleted])
        XCTAssertEqual(r.cells[4].outputs.map(\.status), [.removed])
        XCTAssertEqual(r.cells[5].rows.map(\.kind), [.added, .added])
    }

    func testExecutionCountsAndMetadataOnlyAreHiddenNotChanges() throws {
        let old = try notebook([code(["x = 1\n"], count: 1, metadata: ["tags": ["a"]])])
        let new = try notebook([code(["x = 1\n"], count: 7, metadata: ["tags": ["b"]])], metadata: ["kernelspec": ["name": "py"]])
        let r = try NotebookCompare.compare(old: old, new: new)
        XCTAssertTrue(r.isEqual)
        XCTAssertTrue(r.changes.isEmpty)
        XCTAssertEqual(r.summary, "No differences")
        XCTAssertEqual(r.counts.hiddenMetadataChanges, 2)
        XCTAssertEqual(r.hiddenNote, "Execution counts and 2 metadata changes hidden")
        let metadataOnly = try NotebookCompare.compare(old: try notebook([markdown("a")]), new: try notebook([markdown("a")], metadata: [:]))
        XCTAssertEqual(metadataOnly.hiddenNote, "1 metadata change hidden")
    }

    func testCellsMatchedByIDWhenBothHaveIDs() throws {
        let old = try notebook([markdown("Intro", id: "a1"), code(["a = 1\n"], count: 1, id: "b2")])
        // The code cell is rewritten beyond recognition but keeps its id: still the same cell.
        let new = try notebook([markdown("Intro", id: "a1"), code(["totally_different_call()\n"], count: 1, id: "b2"),
                                markdown("New", id: "c3")])
        let r = try NotebookCompare.compare(old: old, new: new)
        XCTAssertTrue(r.matchedByID)
        XCTAssertEqual(r.cells.map(\.status), [.same, .sourceChanged, .added])
    }

    func testErrorAndHTMLOutputs() throws {
        let err: [String: Any] = ["output_type": "error", "ename": "ValueError", "evalue": "bad", "traceback": ["line 1"]]
        let html: [String: Any] = ["output_type": "execute_result", "execution_count": 2,
                                   "data": ["text/html": "<b>1</b>", "text/plain": "1"], "metadata": [:]]
        let html2: [String: Any] = ["output_type": "execute_result", "execution_count": 3,
                                    "data": ["text/html": "<b>2</b>", "text/plain": "2"], "metadata": [:]]
        let r = try NotebookCompare.compare(old: try notebook([code(["f()\n"], count: 1, outputs: [stream("ok\n")]),
                                                               code(["t\n"], count: 2, outputs: [html])]),
                                            new: try notebook([code(["f()\n"], count: 1, outputs: [err]),
                                                               code(["t\n"], count: 3, outputs: [html2])]))
        XCTAssertEqual(r.cells[0].outputs.map(\.status), [.removed, .added])
        XCTAssertEqual(r.cells[0].outputs.last?.type, .error)
        XCTAssertEqual(r.cells[0].outputs.last?.new, "ValueError: bad\nline 1")
        XCTAssertEqual(r.cells[1].outputDescription, "Output changed (HTML)")
    }

    func testMalformedNotebookNamesTheSide() throws {
        let good = try notebook([markdown("a")])
        XCTAssertThrowsError(try NotebookCompare.compare(old: good, new: Data("{\n \"cells\": [,]\n}".utf8))) { error in
            let e = error as? CompareError
            XCTAssertEqual(e?.side, .new)
            XCTAssertEqual(e?.kind, .malformed)
        }
        XCTAssertThrowsError(try NotebookCompare.compare(old: Data("{\"a\": 1}".utf8), new: good)) { error in
            XCTAssertEqual((error as? CompareError)?.side, .old)
        }
        XCTAssertThrowsError(try NotebookCompare.compare(old: Data("{\"nbformat\": 3, \"worksheets\": []}".utf8), new: good)) { error in
            XCTAssertEqual((error as? CompareError)?.kind, .unsupported)
        }
    }

    func testCellLimitMarksIncomplete() throws {
        let cells = (0..<12).map { markdown("cell \($0)") }
        let r = try NotebookCompare.compare(old: try notebook(cells), new: try notebook(cells), limits: .init(maxCells: 5))
        XCTAssertEqual(r.cells.count, 5)
        XCTAssertFalse(r.isComplete)
    }

    func testLargeImagesAreDescribedNotCarried() throws {
        let big = String(repeating: "A", count: 4_000)
        let r = try NotebookCompare.compare(old: try notebook([code(["p\n"], count: 1, outputs: [png(big)])]),
                                            new: try notebook([code(["p\n"], count: 1, outputs: [png(big + "BB")])]),
                                            limits: .init(maxImageCharacters: 1_000))
        let out = try XCTUnwrap(r.cells.first?.outputs.first)
        XCTAssertNil(out.oldImage)
        XCTAssertEqual(out.old, "image/png · 3 KB")
    }

    func testResultIsCodable() throws {
        let (old, new) = try designPair()
        let r = try NotebookCompare.compare(old: old, new: new)
        XCTAssertEqual(try JSONDecoder().decode(NotebookComparison.self, from: try JSONEncoder().encode(r)), r)
    }
}
