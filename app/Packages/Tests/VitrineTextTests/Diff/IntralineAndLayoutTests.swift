import XCTest
@testable import VitrineText

final class IntralineAndLayoutTests: XCTestCase {
    private func utf16(_ s: String, _ r: Range<Int>) -> String {
        let u = Array(s.utf16)
        return String(decoding: u[r], as: UTF16.self)
    }

    private func hunk(_ lines: [(DiffLine.Kind, String)]) -> DiffHunk {
        var old = 1, new = 1
        var out: [DiffLine] = []
        for (kind, text) in lines {
            out.append(DiffLine(kind: kind, text: text, oldNumber: kind == .added ? nil : old, newNumber: kind == .deleted ? nil : new))
            if kind != .added { old += 1 }
            if kind != .deleted { new += 1 }
        }
        return DiffHunk(oldStart: 1, oldCount: old - 1, newStart: 1, newCount: new - 1, lines: out)
    }

    func testOneTokenRenameIsFoundExactly() throws {
        let old = "    var count: Int { pending.count }", new = "    var pendingCount: Int { pending.count }"
        let h = try XCTUnwrap(Intraline.highlight(old: old, new: new))
        XCTAssertEqual(h.old.map { utf16(old, $0) }, ["count"])
        XCTAssertEqual(h.new.map { utf16(new, $0) }, ["pendingCount"])
        XCTAssertGreaterThan(h.similarity, 0.7)
    }

    func testEditsSeparatedOnlyBySpaceMergeIntoOneRange() throws {
        let old = "return plan.monthly * seats;", new = "const base = plan.monthly * seats;"
        let h = try XCTUnwrap(Intraline.highlight(old: old, new: new))
        XCTAssertEqual(h.old.map { utf16(old, $0) }, ["return"])
        XCTAssertEqual(h.new.map { utf16(new, $0) }, ["const base ="])
    }

    func testRangesAreUTF16() throws {
        let old = "say 👋 hi", new = "say 👋 bye"
        let h = try XCTUnwrap(Intraline.highlight(old: old, new: new))
        XCTAssertEqual(h.new, [7..<10])
        XCTAssertEqual(h.new.map { utf16(new, $0) }, ["bye"])
        XCTAssertEqual(h.old.map { utf16(old, $0) }, ["hi"])
    }

    func testLinesThatShareNothingAreNeverPaired() {
        XCTAssertNil(Intraline.highlight(old: "let total = 4", new: "print(error)"))
        XCTAssertNil(Intraline.highlight(old: "", new: "x"))
        let h = hunk([(.deleted, "import Foundation"), (.added, "@MainActor final class Store {}")])
        XCTAssertTrue(Intraline.pairs(in: h).isEmpty)
        // Punctuation alone is too little to call two lines an edit.
        XCTAssertNil(Intraline.highlight(old: "a.b(c)", new: "x.y(z)"))
    }

    func testBlockPairingFollowsContentNotPosition() {
        let h = hunk([
            (.context, "struct Plan {"),
            (.deleted, "    let monthly: Int"),
            (.deleted, "    let name: String"),
            (.deleted, "    let seats: Int"),
            (.added, "    let monthly: Decimal"),
            (.added, "    let yearlyDiscount: Double?"),
            (.added, "    let name: String // shown"),
            (.added, "    let seats: Int8"),
            (.context, "}"),
        ])
        let pairs = Intraline.pairs(in: h)
        XCTAssertEqual(pairs.map { [$0.deleted, $0.added] }, [[1, 4], [2, 6], [3, 7]])
        XCTAssertEqual(pairs.first.map { pair in pair.newRanges.map { utf16(h.lines[pair.added].text, $0) } }, ["Decimal"])

        let file = DiffFile(oldPath: "Plan.swift", newPath: "Plan.swift", hunks: [h])
        let rows = DiffLayout.split(file)
        let shape: [String] = rows.map {
            guard case .pair(let l, let r) = $0 else { return "fold" }
            return "\(l.map { "\($0.line)" } ?? "_")|\(r.map { "\($0.line)" } ?? "_")"
        }
        XCTAssertEqual(shape, ["0|0", "1|4", "_|5", "2|6", "3|7", "8|8"])
        if case .pair(let l, let r) = rows[1] {
            XCTAssertEqual(l?.number, 2); XCTAssertEqual(r?.number, 2)
            XCTAssertEqual(l?.kind, .deleted); XCTAssertEqual(r?.kind, .added)
            XCTAssertFalse(r?.highlights.isEmpty ?? true)
        } else { XCTFail() }
        if case .pair(let l, let r) = rows[0] { XCTAssertEqual(l?.number, 1); XCTAssertEqual(r?.number, 1) }
    }

    func testUnpairedLinesFillRowsThenGaps() {
        let h = hunk([(.deleted, "alpha one"), (.deleted, "beta two"), (.added, "zzz"), (.context, "end")])
        let rows = DiffLayout.split(DiffFile(oldPath: "x", newPath: "x", hunks: [h]))
        let shape: [String] = rows.map {
            guard case .pair(let l, let r) = $0 else { return "fold" }
            return "\(l.map { "\($0.line)" } ?? "_")|\(r.map { "\($0.line)" } ?? "_")"
        }
        XCTAssertEqual(shape, ["0|2", "1|_", "3|3"])
    }

    func testInterleavedPatchLinesStillPair() {
        let h = hunk([(.deleted, "let a = 1"), (.added, "let a = 2"), (.deleted, "let b = 1"), (.added, "let b = 2")])
        XCTAssertEqual(Intraline.pairs(in: h).map { [$0.deleted, $0.added] }, [[0, 1], [2, 3]])
    }

    func testHugeBlocksPairByPositionAndLongLinesAreSkipped() {
        var lines: [(DiffLine.Kind, String)] = (0..<100).map { (.deleted, "value \($0) = old") }
        lines += (0..<100).map { (.added, "value \($0) = new") }
        let pairs = Intraline.pairs(in: hunk(lines), options: .init(maxAlignedLines: 64))
        XCTAssertEqual(pairs.count, 100)
        XCTAssertTrue(pairs.allSatisfy { $0.added == $0.deleted + 100 })
        let long = String(repeating: "x", count: 5_000)
        XCTAssertNil(Intraline.highlight(old: long, new: long + "y"))
    }

    func testUnifiedRowsCarryFoldsAndHighlights() {
        let old = (1...30).map { "row \($0)" }
        var new = old
        new[19] = "row 20 changed"
        let text = { (l: [String]) in l.joined(separator: "\n") + "\n" }
        let result = TextCompare.compare(old: text(old), new: text(new))
        let rows = DiffLayout.unified(result.file)
        guard case .fold(let first) = rows.first, case .fold(let last) = rows.last else { return XCTFail("\(rows)") }
        XCTAssertEqual(first.label, "lines 1–16 unchanged")
        XCTAssertEqual(first.hunkIndex, 0)
        XCTAssertEqual(last.label, "lines 24–30 unchanged")
        XCTAssertNil(last.hunkIndex)
        let highlighted = rows.compactMap { row -> [Range<Int>]? in
            if case .line(_, _, let h) = row, !h.isEmpty { return h } else { return nil }
        }
        XCTAssertEqual(highlighted, [[6..<14]])                          // " changed", the space merged in
        XCTAssertEqual(rows.count, 2 + 7 + 1)
        XCTAssertEqual(DiffLayout.unified(result.file, intraline: nil).filter {
            if case .line(_, _, let h) = $0 { !h.isEmpty } else { false }
        }.count, 0)
    }

    func testFoldLabelsForOneLineAndSections() {
        let fold = DiffLayout.Fold(old: 5...5, new: 6...6, section: "extension SyncQueue {", hunkIndex: 1)
        XCTAssertEqual(fold.label, "line 5 unchanged · extension SyncQueue {")
        XCTAssertEqual(fold.lineCount, 1)
    }

    // MARK: - Summary

    func testLeadSentencesAndOrdering() {
        func file(_ path: String, add: Int, del: Int, _ configure: (inout DiffFile) -> Void = { _ in }) -> DiffFile {
            var f = DiffFile(oldPath: path, newPath: path, additions: add, deletions: del, hunkCount: 1)
            configure(&f)
            return f
        }
        let files = [
            file("Docs/sync.md", add: 2, del: 1) { $0.isRenamed = true; $0.oldPath = "Docs/syncing.md"; $0.similarity = 91 },
            file("Sources/Sync/SyncQueue.swift", add: 20, del: 6),
            file("Sources/Sync/RetryPolicy.swift", add: 21, del: 0) { $0.isNewFile = true; $0.oldPath = nil },
            file("Resources/sync-badge.png", add: 0, del: 0) { $0.binary = DiffBinary(source: .gitBinaryPatch, newSize: 4_500, oldSize: 4_100) },
            file("Sources/Legacy/OldSync.swift", add: 0, del: 20) { $0.isDeletedFile = true; $0.newPath = nil },
        ]
        let patch = Patch(format: .git, commits: [], files: files, preamble: "", issues: [],
                          coverage: PatchCoverage(filesListed: 5, filesSeen: 5, filesWithDetail: 5),
                          totals: .init(files: 5, additions: 43, deletions: 27, hunks: 4), crlfLineCount: 0, lineCount: 1)
        let summary = DiffSummary(patch: patch)
        XCTAssertEqual(summary.lead, "5 files changed: 1 edited, 1 added, 1 deleted, 1 renamed, 1 binary; 43 lines added, 27 removed")
        XCTAssertEqual(summary.files.map(\.kind.letter), ["M", "A", "D", "R", "B"])
        XCTAssertEqual(summary.files.map(\.name), ["SyncQueue.swift", "RetryPolicy.swift", "OldSync.swift", "sync.md", "sync-badge.png"])
        XCTAssertEqual(summary.files[0].directory, "Sources/Sync/")
        XCTAssertEqual(summary.files[3].detail, "← Docs/syncing.md · 91% similar")
        XCTAssertEqual(summary.files[4].detail, "4 KB → 5 KB")
        let top = summary.topFiles(3)
        XCTAssertEqual(top.rows.count, 3)
        XCTAssertEqual(top.more, 2)

        let one = Patch(format: .git, commits: [], files: [files[1]], preamble: "", issues: [],
                        coverage: PatchCoverage(filesListed: 1, filesSeen: 1, filesWithDetail: 1),
                        totals: .init(files: 1, additions: 20, deletions: 6, hunks: 2), crlfLineCount: 0, lineCount: 1)
        XCTAssertEqual(DiffSummary(patch: one).lead, "SyncQueue.swift edited; 20 lines added, 6 removed")
        let binaryOnly = Patch(format: .git, commits: [], files: [files[3]], preamble: "", issues: [],
                               coverage: PatchCoverage(filesListed: 1, filesSeen: 1, filesWithDetail: 1),
                               totals: .init(files: 1), crlfLineCount: 0, lineCount: 1)
        XCTAssertEqual(DiffSummary(patch: binaryOnly).lead, "sync-badge.png changed (binary)")
        XCTAssertEqual(DiffSummary.lineCounts(additions: 1, deletions: 0), "1 line added")
        XCTAssertEqual(DiffSummary.lineCounts(additions: 0, deletions: 12), "12 lines removed")
        XCTAssertEqual(DiffSummary.lineCounts(additions: 1_000, deletions: 1), "1,000 lines added, 1 removed")
    }

    func testFolderGroupsForAHugePatch() {
        var text = ""
        for (dir, count) in [("vendor/swift-nio/Sources", 12), ("vendor/grpc-swift/Sources", 5), ("vendor/swift-protobuf/x", 2)] {
            for i in 0..<count {
                text += "--- a/\(dir)/f\(i).swift\n+++ b/\(dir)/f\(i).swift\n@@ -1 +1,2 @@\n-a\n+b\n+c\n"
            }
        }
        text += "--- a/Package.resolved\n+++ b/Package.resolved\n@@ -1 +1 @@\n-x\n+y\n"
        let summary = DiffSummary(patch: PatchParser.parse(text))
        let groups = summary.folders(depth: 2)
        XCTAssertEqual(groups.map(\.path), ["vendor/swift-nio/", "vendor/grpc-swift/", "vendor/swift-protobuf/", "Package.resolved"])
        XCTAssertEqual(groups.map(\.fileCount), [12, 5, 2, 1])
        XCTAssertEqual(groups.first?.additions, 24)
        XCTAssertEqual(groups.first?.deletions, 12)
    }

    func testModeDetails() {
        var f = DiffFile(oldPath: "x", newPath: "x")
        f.oldMode = DiffFileMode(octal: "100755"); f.newMode = DiffFileMode(octal: "100644")
        XCTAssertEqual(DiffSummary.modeDetail(f), "no longer executable")
        f.newMode = DiffFileMode(octal: "120000")
        XCTAssertEqual(DiffSummary.modeDetail(f), "now a symlink")
        XCTAssertEqual(DiffFileMode(octal: "160000")?.kind, .submodule)
        XCTAssertEqual(DiffFileMode(octal: "040000")?.kind, .directory)
        XCTAssertNil(DiffFileMode(octal: "8"))
        XCTAssertNil(DiffFileMode(octal: ""))
    }
}
