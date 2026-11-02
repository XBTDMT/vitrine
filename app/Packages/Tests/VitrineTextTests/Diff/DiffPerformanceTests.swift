import XCTest
@testable import VitrineText

/// ARCHITECTURE §7 budgets, measured on generated input. `swift test` builds for debug, so the bounds are generous
/// (several times what a release build takes); the measured times are printed for the record.
final class DiffPerformanceTests: XCTestCase {
    /// Code-like lines with braces, blank lines and repeated statements, so the diff meets frequent lines.
    private func codeFile(lines: Int, seed: UInt64) -> [String] {
        var rng = SeededRandom(seed: seed)
        var out: [String] = []
        out.reserveCapacity(lines)
        var function = 0
        while out.count < lines {
            function += 1
            out.append("func handler\(function)(_ input: Input) -> Output {")
            for k in 0..<Int.random(in: 3...12, using: &rng) {
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: out.append("    guard let value = input.value else { return .empty }")
                case 1: out.append("    let step\(k) = transform(value, by: \(Int.random(in: 0..<100, using: &rng)))")
                case 2: out.append("")
                default: out.append("    log(\"handler \(function) step \(k)\")")
                }
            }
            out.append("    return .done")
            out.append("}")
            out.append("")
        }
        return Array(out.prefix(lines))
    }

    func testFiftyThousandLineComparison() {
        let old = codeFile(lines: 50_000, seed: 1)
        var rng = SeededRandom(seed: 2)
        var new = old
        // About 1,000 scattered edits: replacements, insertions, deletions.
        for _ in 0..<1_000 {
            let at = Int.random(in: 0..<new.count, using: &rng)
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: new[at] = "    let changed = \(Int.random(in: 0..<1_000_000, using: &rng))"
            case 1: new.insert("    audit(\(at))", at: at)
            default: new.remove(at: at)
            }
        }
        let oldText = old.joined(separator: "\n") + "\n", newText = new.joined(separator: "\n") + "\n"
        let clock = ContinuousClock()
        var result: TextComparison?
        let time = clock.measure { result = TextCompare.compare(old: oldText, new: newText) }
        guard let result else { return XCTFail() }
        XCTAssertFalse(result.isSimplified)
        XCTAssertEqual(apply(result.file, to: old), new)
        var rows = 0
        let layoutTime = clock.measure {
            for hunk in result.file.hunks.prefix(200) { rows += Intraline.pairs(in: hunk).count }
            rows += DiffLayout.split(result.file).count
        }
        print("VitrineText diff perf: 50,000-line compare (histogram, \(result.changes.count) changes, +\(result.additions) −\(result.deletions)) \(time); split layout + highlights \(layoutTime)")
        XCTAssertLessThan(time, .seconds(10))
        XCTAssertLessThan(layoutTime, .seconds(10))

        // Myers on the same input, with its default budget: it either finishes or falls back, and is correct
        // either way.
        var myers: TextComparison?
        let myersTime = clock.measure { myers = TextCompare.compare(old: oldText, new: newText, options: .init(algorithm: .myers)) }
        XCTAssertEqual(myers.flatMap { apply($0.file, to: old) }, new)
        print("VitrineText diff perf: 50,000-line compare (myers, simplified: \(myers?.isSimplified ?? false)) \(myersTime)")
        XCTAssertLessThan(myersTime, .seconds(15))
    }

    func testCompletelyDifferentFiftyThousandLinesHitsTheBudgetGracefully() {
        let old = (0..<50_000).map { "old line \($0 % 50)" }
        let new = (0..<50_000).map { "new line \($0 % 70)" }
        let clock = ContinuousClock()
        var result: TextComparison?
        let time = clock.measure {
            result = TextCompare.compare(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"),
                                         options: .init(budget: .init(timeLimit: .milliseconds(500))))
        }
        XCTAssertEqual(result?.additions, 50_000)
        XCTAssertEqual(result?.deletions, 50_000)
        print("VitrineText diff perf: 50,000 vs 50,000 unrelated lines \(time)")
        XCTAssertLessThan(time, .seconds(10))
    }

    func testTenMegabytePatch() {
        var text = ""
        text.reserveCapacity(11 << 20)
        text += "From 0123456789abcdef0123456789abcdef01234567 Mon Sep 17 00:00:00 2001\nFrom: Dana Reyes <dana@example.com>\nDate: Mon, 27 Oct 2026 10:00:00 +0100\nSubject: [PATCH] Vendor bump\n\nBump everything.\n---\n"
        var file = 0, additions = 0, deletions = 0
        while text.utf8.count < 10 << 20 {
            file += 1
            let dir = ["vendor/swift-nio", "vendor/grpc-swift", "vendor/swift-protobuf"][file % 3]
            text += "diff --git a/\(dir)/File\(file).swift b/\(dir)/File\(file).swift\nindex 1234567..89abcde 100644\n--- a/\(dir)/File\(file).swift\n+++ b/\(dir)/File\(file).swift\n"
            for h in 0..<3 {
                text += "@@ -\(h * 100 + 1),7 +\(h * 100 + 1),8 @@ struct Type\(file) {\n"
                text += "     let a = 1\n     let b = 2\n-    let c = old(\(h))\n+    let c = new(\(h))\n+    let d = extra()\n     let e = 3\n     let f = 4\n     let g = 5\n     let h = 6\n"
                additions += 2; deletions += 1
            }
        }
        text += "-- \n2.43.0\n"
        let data = Data(text.utf8)
        let clock = ContinuousClock()
        var patch: Patch?
        let time = clock.measure { patch = PatchParser.parse(data) }
        guard let patch else { return XCTFail() }
        XCTAssertEqual(patch.totals.files, file)
        XCTAssertEqual(patch.totals.additions, additions)
        XCTAssertEqual(patch.totals.deletions, deletions)
        XCTAssertEqual(patch.commits.first?.gitVersion, "2.43.0")
        XCTAssertEqual(patch.issues.filter { $0.severity == .error }, [])
        // The default caps keep 10,000 hunks (here 90,000 lines) of detail and count the rest.
        XCTAssertFalse(patch.coverage.isComplete)
        XCTAssertEqual(patch.coverage.hunksKept, PatchLimits.default.maxDetailedHunks)
        XCTAssertEqual(patch.coverage.linesKept, PatchLimits.default.maxDetailedHunks * 9)
        XCTAssertEqual(patch.coverage.linesSeen, file * 27)
        var summary: DiffSummary?
        let summaryTime = clock.measure {
            summary = DiffSummary(patch: patch)
            _ = summary?.folders()
            _ = DiffFacts.facts(for: patch)
        }
        print("VitrineText diff perf: parse \(data.count.formatted()) byte patch (\(file.formatted()) files, \(patch.lineCount.formatted()) lines) \(time); summary + folders + facts \(summaryTime); \(summary?.coverageNote ?? "")")
        XCTAssertLessThan(time, .seconds(10))
        XCTAssertLessThan(summaryTime, .seconds(5))
    }
}
