import XCTest
@testable import VitrineText

final class TextCompareTests: XCTestCase {
    /// Random line files over a small alphabet, so lines repeat the way `}` and blank lines do in code.
    private func randomLines(_ rng: inout SeededRandom, count: Int, alphabet: Int) -> [String] {
        (0..<count).map { _ in
            let k = Int.random(in: 0..<alphabet, using: &rng)
            return k == 0 ? "" : k == 1 ? "}" : "line \(k)"
        }
    }

    private func mutate(_ lines: [String], _ rng: inout SeededRandom, alphabet: Int) -> [String] {
        var out = lines
        for _ in 0..<Int.random(in: 0...6, using: &rng) {
            let at = Int.random(in: 0...out.count, using: &rng)
            switch Int.random(in: 0..<3, using: &rng) {
            case 0 where at < out.count: out.remove(at: at)
            case 1: out.insert("line \(Int.random(in: 0..<alphabet * 2, using: &rng))", at: at)
            default: if at < out.count { out[at] = "edit \(Int.random(in: 0..<alphabet, using: &rng))" }
            }
        }
        return out
    }

    private func text(_ lines: [String]) -> String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }

    /// Length of a longest common subsequence: the yardstick for Myers' minimality.
    private func lcs(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diag = 0
            for j in 1...b.count {
                let up = row[j]
                row[j] = x == b[j - 1] ? diag + 1 : max(row[j], row[j - 1])
                diag = up
            }
        }
        return row[b.count]
    }

    func testRandomComparisonsAreCorrectAndMyersIsMinimal() {
        var rng = SeededRandom(seed: 7)
        for iteration in 0..<400 {
            let alphabet = [3, 6, 20][iteration % 3]
            let old = randomLines(&rng, count: Int.random(in: 0...40, using: &rng), alphabet: alphabet)
            let new = Bool.random(using: &rng) ? mutate(old, &rng, alphabet: alphabet)
                                               : randomLines(&rng, count: Int.random(in: 0...40, using: &rng), alphabet: alphabet)
            for algorithm in [LineDiff.Algorithm.histogram, .myers] {
                for context in [0, 3, nil] as [Int?] {
                    let result = TextCompare.compare(old: text(old), new: text(new),
                                                     options: CompareOptions(algorithm: algorithm, contextLines: context))
                    XCTAssertEqual(apply(result.file, to: old), new, "\(algorithm) context \(String(describing: context))")
                    XCTAssertFalse(result.isSimplified)
                    if algorithm == .myers {
                        XCTAssertEqual(result.additions + result.deletions, old.count + new.count - 2 * lcs(old, new))
                    }
                    if old == new { XCTAssertEqual(result.status, .identical) }
                    for hunk in result.file.hunks {
                        XCTAssertEqual(hunk.lines.filter { $0.kind != .added }.count, hunk.oldCount)
                        XCTAssertEqual(hunk.lines.filter { $0.kind != .deleted }.count, hunk.newCount)
                    }
                }
            }
        }
    }

    func testHunkHeadersMatchDiffU() throws {
        let folder = try DiffFixtureFolder()
        let cases: [([String], [String])] = [
            ((1...10).map { "l\($0)" }, (1...10).map { $0 == 3 ? "X" : "l\($0)" } + ["k"]),
            (["b", "c"], ["a", "b", "c"]),
            (["a", "b", "c"], ["a", "b"]),
            ([], ["only"]),
            (["gone"], []),
            ((1...30).map { "row \($0)" }, (1...30).map { "row \($0)" }.filter { $0 != "row 15" }),
        ]
        for (index, (old, new)) in cases.enumerated() {
            try folder.write("a\(index)", text(old))
            try folder.write("b\(index)", text(new))
            for context in [0, 3] {
                let reference = PatchParser.parse(try folder.diffU("a\(index)", "b\(index)", extra: ["-U\(context)"]))
                let ours = TextCompare.compare(old: text(old), new: text(new), options: CompareOptions(contextLines: context))
                // macOS's diff writes `-1,0` for an insertion before line 1, where GNU diff and git write `-0,0`
                // (the empty range names the line it follows). Vitrine writes git's form.
                let referenceHeaders = (reference.files.first?.hunks.map(\.header) ?? [])
                    .map { index == 1 && $0.hasPrefix("@@ -1,0 ") ? $0.replacingOccurrences(of: "@@ -1,0 ", with: "@@ -0,0 ") : $0 }
                XCTAssertEqual(ours.file.hunks.map(\.header), referenceHeaders, "case \(index) -U\(context)")
                // And the parser read diff's own output correctly: applying it gives the new file.
                if let file = reference.files.first, referenceHeaders == file.hunks.map(\.header) {
                    XCTAssertEqual(apply(file, to: old), new)
                }
            }
        }
    }

    func testRandomFilesAgainstSystemDiff() throws {
        let folder = try DiffFixtureFolder()
        var rng = SeededRandom(seed: 99)
        for n in 0..<25 {
            let old = randomLines(&rng, count: 60, alphabet: 8)
            let new = mutate(mutate(old, &rng, alphabet: 8), &rng, alphabet: 8)
            try folder.write("o\(n)", text(old)); try folder.write("n\(n)", text(new))
            let reference = PatchParser.parse(try folder.diffU("o\(n)", "n\(n)"))
            assertConsistent(reference)
            let referenceEdits = reference.totals.additions + reference.totals.deletions
            if let file = reference.files.first { XCTAssertEqual(apply(file, to: old), new) }
            let myers = TextCompare.compare(old: text(old), new: text(new), options: CompareOptions(algorithm: .myers))
            XCTAssertLessThanOrEqual(myers.additions + myers.deletions, referenceEdits, "Myers is minimal")
            let histogram = TextCompare.compare(old: text(old), new: text(new))
            XCTAssertEqual(apply(histogram.file, to: old), new)
        }
    }

    func testAddedFunctionReadsAsTheFunctionAndItsBlankLine() {
        let old = "func a() {\n    one()\n}\n\nfunc c() {\n    three()\n}\n"
        let new = "func a() {\n    one()\n}\n\nfunc b() {\n    two()\n}\n\nfunc c() {\n    three()\n}\n"
        for algorithm in [LineDiff.Algorithm.histogram, .myers] {
            let result = TextCompare.compare(old: old, new: new, options: CompareOptions(algorithm: algorithm))
            XCTAssertEqual(result.changes.map(\.label), ["Lines 5–8"], "\(algorithm)")
            XCTAssertEqual(result.changes.first?.preview, "func b() {")
            let added = result.file.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text)
            XCTAssertEqual(added, ["func b() {", "    two()", "}", ""])
        }
    }

    func testHistogramKeepsTheUnchangedRunWholeWhereMyersScatters() {
        // Found by a seeded search over code-like lines: Myers' shortest script matches the scattered frequent
        // lines (`d()`, `}`) and splits the edit into four regions; histogram anchors on the rare shared run
        // `d() d() return nil f()` and reads as "these five lines went, these three came".
        let old = ["f()", "return nil", "d()", "a()", "e()", "}", "d()", "d()", "return nil", "f()"]
        let new = ["f()", "d()", "d()", "return nil", "f()", "}", "}", "e()"]
        let histogram = TextCompare.compare(old: text(old), new: text(new))
        let myers = TextCompare.compare(old: text(old), new: text(new), options: CompareOptions(algorithm: .myers))
        XCTAssertEqual(apply(histogram.file, to: old), new)
        XCTAssertEqual(apply(myers.file, to: old), new)
        XCTAssertEqual(histogram.changes.map(\.old), [1..<6, 10..<10])
        XCTAssertEqual(histogram.changes.map(\.new), [1..<1, 5..<8])
        XCTAssertEqual(myers.changes.count, 4)
        XCTAssertLessThan(myers.additions + myers.deletions, histogram.additions + histogram.deletions + 1)
    }

    func testWhitespaceOptions() {
        let old = "if x {\n  call(a,  b)   \n}\n"
        let new = "if x {\n    call(a, b)\n}\n"
        let exact = TextCompare.compare(old: old, new: new)
        XCTAssertEqual(exact.status, .whitespaceOnly)
        XCTAssertEqual(exact.additions, 1)
        XCTAssertEqual(exact.whitespace?.otherWhitespaceChanges, 1)
        XCTAssertEqual(TextCompare.compare(old: old, new: new, options: .init(whitespace: .ignoreTrailing)).additions, 1)
        XCTAssertEqual(TextCompare.compare(old: old, new: new, options: .init(whitespace: .ignoreChanges)).additions, 0)
        XCTAssertEqual(TextCompare.compare(old: "x\n", new: "  x\n", options: .init(whitespace: .ignoreChanges)).additions, 1,
                       "-b: indentation where there was none is a change")
        let all = TextCompare.compare(old: old, new: new, options: .init(whitespace: .ignoreAll))
        XCTAssertEqual(all.additions + all.deletions, 0)
        XCTAssertTrue(all.file.hunks.isEmpty)

        XCTAssertEqual(TextCompare.compare(old: "a \n", new: "a\n", options: .init(whitespace: .ignoreTrailing)).additions, 0)
        XCTAssertEqual(TextCompare.compare(old: "a  b\n", new: "a b\n", options: .init(whitespace: .ignoreChanges)).additions, 0)
        XCTAssertEqual(TextCompare.compare(old: "ab\n", new: "a b\n", options: .init(whitespace: .ignoreChanges)).additions, 1)
        XCTAssertEqual(TextCompare.compare(old: "ab\n", new: "a b\n", options: .init(whitespace: .ignoreAll)).additions, 0)
    }

    func testLineEndingsAndTheWhitespaceOnlyState() {
        let lines = (1...412).map { "key\($0) = value\($0)" }
        let trailing = Set(stride(from: 0, to: 370, by: 10))                   // 37 lines
        let old = lines.enumerated().map { trailing.contains($0.offset) ? $0.element + "  " : $0.element }
            .joined(separator: "\r\n") + "\r\n"
        let new = lines.joined(separator: "\n") + "\n"
        let result = TextCompare.compare(old: old, new: new, oldName: "server.conf", newName: "server.conf.edited")
        XCTAssertEqual(result.status, .whitespaceOnly)
        XCTAssertEqual(result.oldLineEnding, .crlf)
        XCTAssertEqual(result.newLineEnding, .lf)
        XCTAssertEqual(result.whitespace?.lineEndingChanges, 412)
        XCTAssertEqual(result.whitespace?.trailingWhitespaceChanges, 37)
        XCTAssertEqual(result.whitespace?.summary, "412 line endings CRLF → LF · 37 trailing spaces")
        XCTAssertEqual(result.additions, 412, "exact mode shows every line, for the Show whitespace changes switch")

        let ignoring = TextCompare.compare(old: old, new: new, options: .init(whitespace: .ignoreTrailing, ignoreLineEndings: true))
        XCTAssertEqual(ignoring.additions + ignoring.deletions, 0)
        XCTAssertEqual(DiffSummary(comparison: ignoring).lead, "Same text, different whitespace")
        XCTAssertEqual(DiffFacts.facts(for: ignoring).first { $0.key == "whitespace" }?.value,
                       "412 line endings CRLF → LF · 37 trailing spaces")
        XCTAssertEqual(DiffFacts.facts(for: ignoring).first { $0.key == "lineEndings" }?.value, "CRLF → LF")

        let noFinal = TextCompare.compare(old: "a\nb\n", new: "a\nb")
        XCTAssertEqual(noFinal.status, .whitespaceOnly)
        XCTAssertEqual(noFinal.whitespace?.finalNewlineChanged, true)
        XCTAssertEqual(noFinal.file.hunks.first?.lines.last?.ending, DiffLineEnding.none)
        XCTAssertEqual(TextCompare.compare(old: "a\nb\n", new: "a\nb", options: .init(ignoreLineEndings: true)).additions, 0)
    }

    func testIdenticalAndCanonicalEquivalence() {
        let same = TextCompare.compare(old: "x\ny\n", new: "x\ny\n", oldName: "notes-backup.txt", newName: "notes.txt")
        XCTAssertEqual(same.status, .identical)
        XCTAssertTrue(same.file.hunks.isEmpty)
        XCTAssertEqual(DiffSummary(comparison: same).lead, "These files are identical")
        XCTAssertEqual(DiffFacts.facts(for: same).first?.value, "Identical")
        // Swift's == would call these equal; the bytes on disk differ.
        let composed = TextCompare.compare(old: "caf\u{E9}\n", new: "cafe\u{301}\n")
        XCTAssertEqual(composed.status, .different)
        XCTAssertEqual(composed.additions, 1)
    }

    func testBinaryAndLatin1Data() {
        let binary = TextCompare.compare(old: Data([0, 1, 2]), new: Data([0, 1, 3, 4]), oldName: "a.png", newName: "b.png")
        XCTAssertEqual(binary.status, .binary)
        XCTAssertEqual(binary.file.binary?.oldSize, 3)
        XCTAssertEqual(binary.file.binary?.newSize, 4)
        XCTAssertEqual(DiffSummary(comparison: binary).lead, "Binary files differ: 3 bytes → 4 bytes")
        XCTAssertEqual(TextCompare.compare(old: Data([0, 1]), new: Data([0, 1])).status, .identical)

        let latin = TextCompare.compare(old: Data([0x63, 0x61, 0x66, 0xE9, 0x0A]), new: Data("café\n".utf8))
        XCTAssertEqual(latin.latin1Lines, 1)
        XCTAssertEqual(latin.status, .different)
        XCTAssertEqual(latin.file.hunks.first?.lines.map(\.text), ["café", "café"])
    }

    func testBudgetFallbackStillProducesACorrectDiff() {
        var rng = SeededRandom(seed: 3)
        let old = randomLines(&rng, count: 300, alphabet: 5)
        let new = mutate(mutate(randomLines(&rng, count: 300, alphabet: 5), &rng, alphabet: 5), &rng, alphabet: 5)
        for budget in [LineDiff.Budget(timeLimit: .zero), LineDiff.Budget(maxElements: 10)] {
            for algorithm in [LineDiff.Algorithm.histogram, .myers] {
                let result = TextCompare.compare(old: text(old), new: text(new), options: .init(algorithm: algorithm, budget: budget))
                XCTAssertTrue(result.isSimplified)
                XCTAssertEqual(apply(result.file, to: old), new)
                XCTAssertEqual(DiffFacts.facts(for: result).last?.key, "coverage")
            }
        }
        // Even out of budget, what the two share at the edges is still matched.
        let edges = TextCompare.compare(old: "a\nb\nc\nd\n", new: "a\nX\nY\nd\n", options: .init(budget: .init(timeLimit: .zero)))
        XCTAssertEqual(edges.changes.map(\.label), ["Lines 2–3"])
    }

    func testWhatChangedListForTheDesignsTextCompare() {
        let old = (1...17).map { "line \($0)" }
        var new = old
        new.insert("new field", at: 4)                                  // line 5
        new[10] = "price A"; new[11] = "price B"                       // lines 11–12 replace old 10–11
        new.remove(at: 15)
        let result = TextCompare.compare(old: text(old), new: text(new), oldName: "pricing.ts", newName: "pricing-v2.ts")
        XCTAssertEqual(apply(result.file, to: old), new)
        XCTAssertEqual(result.changes.map(\.label), ["Line 5", "Lines 11–12", "Removed line 15"])
        XCTAssertEqual(result.changes.map(\.additions), [1, 2, 0])
        XCTAssertEqual(result.changes.map(\.deletions), [0, 2, 1])
        let summary = DiffSummary(comparison: result)
        XCTAssertEqual(summary.lead, "3 changes: 3 lines added, 3 removed")
        XCTAssertEqual(DiffFacts.facts(for: result).first { $0.key == "lines" }?.value, "17 → 17")
        // A compare knows the file length, so there is a fold after the last hunk when lines remain.
        let full = TextCompare.compare(old: text(old), new: text(new), options: .init(contextLines: 1))
        XCTAssertNotNil(DiffLayout.folds(full.file).after)
    }

    func testGenericDiffOnTokens() {
        let result = LineDiff.diff(Array("kitten"), Array("sitting"), algorithm: .myers)
        XCTAssertEqual(result.additions + result.deletions, 5)            // k→s, e→i, +g
        XCTAssertEqual(LineDiff.diff([Int](), [1, 2]).ops, [LineDiff.Op(.insert, old: 0..<0, new: 0..<2)])
        XCTAssertEqual(LineDiff.diff([1, 2], [Int]()).ops, [LineDiff.Op(.delete, old: 0..<2, new: 0..<0)])
        XCTAssertEqual(LineDiff.diff([1, 2, 3], [1, 2, 3]).ops, [LineDiff.Op(.equal, old: 0..<3, new: 0..<3)])
    }
}
