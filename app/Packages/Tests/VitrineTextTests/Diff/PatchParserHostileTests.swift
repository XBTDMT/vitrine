import XCTest
@testable import VitrineText

/// Hand-written patches that lie, break off or were mangled on the way: every one parses without trapping, shows
/// what is there and names what is wrong.
final class PatchParserHostileTests: XCTestCase {
    private func kinds(_ patch: Patch) -> [PatchIssue.Kind] { patch.issues.map(\.kind) }

    func testCutOffHunkFromAnEmailSaysSo() {
        let text = """
        --- a/Sources/NoteRepository.swift
        +++ b/Sources/NoteRepository.swift
        @@ -40,6 +40,7 @@ struct NoteRepository {
             func save(_ note: Note) throws {
        -        try store.write(note)
        +        try store.write(note, atomically: true)
        +        index.update(note)
             }

        """
        let patch = PatchParser.parse(text)
        assertConsistent(patch)
        let hunk = patch.files[0].hunks[0]
        XCTAssertTrue(hunk.isShort)
        XCTAssertEqual(hunk.lines.count, 5)
        XCTAssertEqual(hunk.section, "struct NoteRepository {")
        XCTAssertTrue(patch.isTruncated)
        XCTAssertTrue(kinds(patch).contains(.hunkTooShort(declaredOld: 6, declaredNew: 7, foundOld: 3, foundNew: 4)))
        XCTAssertEqual(patch.worstIssue, .error)
        let short = patch.issues.first { if case .hunkTooShort = $0.kind { true } else { false } }
        XCTAssertEqual(short?.line, 3)
        XCTAssertEqual(short?.message, "The hunk header says 6 old and 7 new lines; 3 and 4 arrived. Showing what is there.")
    }

    func testEqualCountsMessageMatchesTheDesign() {
        let issue = PatchIssue(.hunkTooShort(declaredOld: 12, declaredNew: 12, foundOld: 9, foundNew: 9), line: 3)
        XCTAssertEqual(issue.message, "The hunk header says 12 lines; 9 arrived. Showing what is there.")
    }

    func testCountsThatClaimTooFewKeepTheExtraLines() {
        let text = "--- a/x\n+++ b/x\n@@ -1,1 +1,1 @@\n-old\n+new\n+surprise\n context\n"
        let patch = PatchParser.parse(text)
        assertConsistent(patch)
        let hunk = patch.files[0].hunks[0]
        XCTAssertTrue(hunk.isLong)
        XCTAssertEqual(hunk.lines.map(\.text), ["old", "new", "surprise", "context"])
        XCTAssertTrue(kinds(patch).contains(.hunkTooLong(extraLines: 2)))
        XCTAssertEqual(patch.files[0].additions, 2)
    }

    func testCountsAreTrustedSoDashLinesAreNotHeaders() {
        // Deleting "-- x" and adding "++ y" writes `--- x` / `+++ y` inside the hunk.
        let text = "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n--- x\n+++ y\n keep\n"
        let patch = PatchParser.parse(text)
        XCTAssertEqual(patch.files.count, 1)
        XCTAssertEqual(patch.files[0].hunks[0].lines.map(\.text), ["-- x", "++ y", "keep"])
        XCTAssertEqual(patch.issues.filter { $0.severity != .info }, [])
    }

    func testBadHunkHeadersAreReportedAndSkipped() {
        let text = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -x,2 +1,2 @@
        -bad
        +worse
        @@ -10,1 +10,1 @@
        -ten
        +TEN
        @@ -99999999999,1 +1 @@
        -overflow
        @@ -1 +1
        """
        let patch = PatchParser.parse(text)
        assertConsistent(patch)
        XCTAssertEqual(patch.files.count, 1)
        XCTAssertEqual(patch.files[0].hunks.count, 1)
        XCTAssertEqual(patch.files[0].hunks[0].oldStart, 10)
        let bad = patch.issues.filter { if case .badHunkHeader = $0.kind { true } else { false } }
        XCTAssertEqual(bad.map(\.line), [4, 10, 12])
        XCTAssertEqual(bad.first?.kind, .badHunkHeader(skippedLines: 2))
    }

    func testHunkWithoutFileHeaderAndGarbageBetweenFiles() {
        let text = "@@ -1 +1 @@\n-a\n+b\n\nthis is not a diff\nnor is this\ndiff --git a/c b/c\n--- a/c\n+++ b/c\n@@ -1 +1 @@\n-c\n+C\n"
        let patch = PatchParser.parse(text)
        assertConsistent(patch)
        XCTAssertEqual(patch.files.count, 2)
        XCTAssertEqual(patch.files[0].path, "(unnamed file)")
        XCTAssertTrue(kinds(patch).contains(.missingFileHeader))
        XCTAssertTrue(kinds(patch).contains(.unrecognizedLines(count: 2)))
        XCTAssertEqual(patch.files[1].path, "c")
    }

    func testPreambleIsKeptAndContextDiffIsRefusedHonestly() {
        let note = "Hi team,\n\nplease apply this.\n\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-1\n+2\n"
        let patch = PatchParser.parse(note)
        XCTAssertEqual(patch.preamble, "Hi team,\n\nplease apply this.")
        XCTAssertEqual(patch.files.count, 1)

        let context = "*** a.txt\t2026-10-27\n--- b.txt\t2026-10-27\n***************\n*** 1 ****\n! old\n--- 1 ----\n! new\n"
        let refused = PatchParser.parse(context)
        XCTAssertTrue(kinds(refused).contains(.contextDiffUnsupported))
        XCTAssertEqual(refused.files.count, 0)
        XCTAssertEqual(refused.format, .none)
    }

    func testNothingAtAll() {
        for (input, lead) in [("", "No changes"), ("\n\n", "No changes"), ("\u{FEFF}", "No changes"),
                              ("just some text\n", "No diff found")] {
            let patch = PatchParser.parse(input)
            XCTAssertTrue(patch.files.isEmpty)
            XCTAssertTrue(kinds(patch).contains(.noDiffFound), input)
            XCTAssertEqual(DiffSummary(patch: patch).lead, lead, input)
        }
        let bom = PatchParser.parse("\u{FEFF}--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
        XCTAssertEqual(bom.files.count, 1)
    }

    func testWholePatchInCRLF() {
        let lf = "diff --git a/w.txt b/w.txt\nindex 1111111..2222222 100644\n--- a/w.txt\n+++ b/w.txt\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n"
        let patch = PatchParser.parse(lf.replacingOccurrences(of: "\n", with: "\r\n"))
        assertConsistent(patch)
        XCTAssertEqual(patch.files.first?.path, "w.txt")
        XCTAssertEqual(patch.files.first?.oldIndex, "1111111")
        XCTAssertEqual(patch.files.first?.hunks.first?.lines.map(\.text), ["keep", "old", "new"])
        XCTAssertEqual(patch.crlfLineCount, patch.lineCount)
        XCTAssertEqual(DiffFacts.facts(for: patch).first { $0.key == "lineEndings" }?.value, "CRLF")
    }

    func testMailerStrippedTheLoneSpaceOfAnEmptyContextLine() {
        let text = "--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n a\n\n-b\n+B\n"
        let patch = PatchParser.parse(text)
        assertConsistent(patch)
        XCTAssertEqual(patch.files[0].hunks[0].lines.map(\.kind), [.context, .context, .deleted, .added])
        XCTAssertFalse(patch.files[0].hunks[0].isShort)
    }

    func testVeryLongLinesAreCutOnACharacterBoundary() {
        let long = String(repeating: "é", count: 10_000)            // 20,000 bytes
        let text = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-\(long)\n+short\n"
        let patch = PatchParser.parse(text, limits: PatchLimits(maxLineBytes: 1_001))
        let line = patch.files[0].hunks[0].lines[0]
        XCTAssertTrue(line.isTruncated)
        XCTAssertEqual(line.text.utf8.count, 1_000)
        XCTAssertTrue(line.text.allSatisfy { $0 == "é" })
        XCTAssertEqual(patch.coverage.truncatedLines, 1)
        XCTAssertTrue(kinds(patch).contains(.longLinesTruncated(count: 1)))
        XCTAssertFalse(patch.coverage.isComplete)
        XCTAssertEqual(patch.coverage.note, "1 long line is cut short")
    }

    func testLatin1LinesInsideAUTF8Patch() {
        var bytes = Array("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-caf".utf8)
        bytes += [0xE9, 0x0A]                                       // Latin-1 é, invalid UTF-8
        bytes += Array("+café\n".utf8)
        let patch = PatchParser.parse(Data(bytes))
        XCTAssertEqual(patch.files[0].hunks[0].lines.map(\.text), ["café", "café"])
        XCTAssertTrue(kinds(patch).contains(.latin1Lines(count: 1)))
    }

    func testInvalidModesAndHostileNumbers() {
        let text = "diff --git a/m b/m\nold mode 9z\nnew mode 1007550000000\n"
        let patch = PatchParser.parse(text)
        XCTAssertEqual(patch.files.count, 1)
        XCTAssertNil(patch.files[0].oldMode)
        XCTAssertNil(patch.files[0].newMode)
        XCTAssertEqual(patch.issues.filter { if case .invalidMode = $0.kind { true } else { false } }.count, 2)
        XCTAssertNil(PatchScanner.percent("1000%"))
        XCTAssertEqual(PatchScanner.percent("91%"), 91)
    }

    func testQuotedPrintableEmailIsDecoded() {
        let text = """
        From: =?UTF-8?q?Dana=20R=C3=A9yes?= <dana@example.com>
        Subject: [PATCH] =?UTF-8?B?Q2Fmw6k=?= menu
        Date: Mon, 27 Oct 2026 10:00:00 +0100
        Content-Transfer-Encoding: quoted-printable

        A body with a soft=
         break.
        ---
        --- a/menu.txt
        +++ b/menu.txt
        @@ -1 +1 @@
        -caf=C3=A9
        +caf=C3=A9 au lait

        """
        let patch = PatchParser.parse(text)
        assertConsistent(patch)
        let commit = patch.commits[0]
        XCTAssertEqual(commit.authorName, "Dana Réyes")
        XCTAssertEqual(commit.subject, "Café menu")
        XCTAssertEqual(commit.body, "A body with a soft break.")
        XCTAssertEqual(patch.files.first?.hunks.first?.lines.map(\.text), ["café", "café au lait"])
        XCTAssertTrue(kinds(patch).contains(.transferEncodingDecoded("quoted-printable")))
    }

    func testEncodedWordsAndSubjectPrefixes() {
        XCTAssertEqual(PatchMail.decodeEncodedWords("=?utf-8?q?a?= =?utf-8?q?b?= c"), "ab c")
        XCTAssertEqual(PatchMail.decodeEncodedWords("=?bogus"), "=?bogus")
        XCTAssertEqual(PatchMail.decodeEncodedWords("=?iso-8859-1?q?caf=E9?="), "café")
        let s = PatchMail.splitSubject("Re: [PATCH v3 07/12] [RFC] net: fix")
        XCTAssertEqual(s.subject, "net: fix")
        XCTAssertEqual(s.prefix, "[PATCH v3 07/12] [RFC]")
        XCTAssertEqual(s.index, 7)
        XCTAssertEqual(s.total, 12)
        XCTAssertEqual(PatchMail.splitAuthor("\"Reyes, Dana\" <d@example.com>").name, "Reyes, Dana")
        XCTAssertNotNil(PatchMail.parseDate("Mon, 27 Oct 2026 10:00:00 +0100 (CET)"))
        XCTAssertNotNil(PatchMail.parseDate("Mon Oct 27 10:00:00 2026 +0100"))
        XCTAssertNil(PatchMail.parseDate("yesterday"))
    }

    func testGitHeaderNameResolution() {
        XCTAssertEqual(PatchScanner.gitHeaderNames("a/x y b/x y").map { [$0.old, $0.new] }, ["x y", "x y"])
        XCTAssertEqual(PatchScanner.gitHeaderNames("x y x y").map { [$0.old, $0.new] }, ["x y", "x y"])
        XCTAssertEqual(PatchScanner.gitHeaderNames("a/old b/new").map { [$0.old, $0.new] }, ["old", "new"])
        XCTAssertEqual(PatchScanner.gitHeaderNames("\"a/caf\\303\\251\" \"b/caf\\303\\251\"").map { [$0.old, $0.new] }, ["café", "café"])
        XCTAssertEqual(PatchScanner.unquote("\"tab\\there\\\"q\\\"\""), "tab\there\"q\"")
        XCTAssertEqual(PatchScanner.unquote("\"unterminated"), "\"unterminated")
        XCTAssertNil(PatchScanner.gitHeaderNames("single"))
    }

    func testOrphanNoNewlineMarker() {
        let patch = PatchParser.parse("--- a/x\n+++ b/x\n@@ -1 +1 @@\n\\ No newline at end of file\n-a\n+b\n")
        XCTAssertTrue(kinds(patch).contains(.orphanNoNewlineMarker))
        XCTAssertEqual(patch.files[0].hunks[0].lines.count, 2)
    }

    func testCapsKeepCountingSoTotalsStayExact() {
        var text = ""
        for f in 0..<50 {
            text += "diff --git a/f\(f).txt b/f\(f).txt\n--- a/f\(f).txt\n+++ b/f\(f).txt\n@@ -1,2 +1,3 @@\n a\n-b\n+B\n+C\n"
        }
        let limits = PatchLimits(maxFiles: 30, maxDetailedLines: 40, maxDetailedHunks: 1_000)
        let patch = PatchParser.parse(text, limits: limits)
        assertConsistent(patch)
        XCTAssertEqual(patch.files.count, 30)
        XCTAssertEqual(patch.totals.files, 50)
        XCTAssertEqual(patch.totals.additions, 100)
        XCTAssertEqual(patch.totals.deletions, 50)
        XCTAssertEqual(patch.coverage.linesKept, 40)
        XCTAssertEqual(patch.coverage.linesSeen, 200)
        XCTAssertEqual(patch.coverage.filesWithDetail, 10)
        XCTAssertFalse(patch.coverage.isComplete)
        XCTAssertEqual(patch.coverage.note, "Showing 10 of 50 files")
        XCTAssertEqual(patch.issues.filter { $0.kind == .limitReached }.count, 1)
        XCTAssertTrue(patch.files[10...].allSatisfy { $0.isDetailOmitted && $0.additions == 2 })
        let summary = DiffSummary(patch: patch)
        XCTAssertEqual(summary.lead, "50 files changed; 100 lines added, 50 removed")
        XCTAssertEqual(summary.coverageNote, "Showing 10 of 50 files")
        XCTAssertEqual(DiffFacts.coverage(for: patch),
                       .partial(shown: 40, total: 200, unit: .rows, reason: "Showing 10 of 50 files"))
    }

    func testByteCapReadsWholeLinesOnly() {
        let text = String(repeating: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n", count: 100)
        let patch = PatchParser.parse(text, limits: PatchLimits(maxBytes: 100))
        XCTAssertLessThanOrEqual(patch.coverage.bytesRead, 100)
        XCTAssertEqual(patch.coverage.totalBytes, text.utf8.count)
        XCTAssertTrue(kinds(patch).contains(.inputCut(readBytes: patch.coverage.bytesRead, totalBytes: text.utf8.count)))
        if case .partial(_, _, let unit, _) = DiffFacts.coverage(for: patch) { XCTAssertEqual(unit, .bytes) } else { XCTFail() }
    }
}
