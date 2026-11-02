import XCTest
@testable import VitrineText

/// Patches in the exact forms `git diff`, `git format-patch`, `git log -p` and `git show --cc` write, kept as saved
/// samples (ruled 2026-10-29, option A: no test runs `git`). Each sample is invented content in git's own layout:
/// headers, `index` lines, rename/copy/mode lines, function context, quoted paths, binary blocks, combined hunks,
/// the format-patch diffstat and the `-- ` signature. The `diff -u` / `diff -ruN` case still runs `/usr/bin/diff`.
final class PatchParserSampleTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testGitDiffOfTheFiveFileCommit() throws {
        let patch = PatchParser.parse(data(Samples.fiveFileDiff))
        assertConsistent(patch)
        XCTAssertEqual(patch.format, .git)
        XCTAssertEqual(patch.issues.filter { $0.severity != .info }, [])
        let byPath = Dictionary(uniqueKeysWithValues: patch.files.map { ($0.path, $0) })
        XCTAssertEqual(Set(byPath.keys), ["Sources/Sync/SyncQueue.swift", "Sources/Sync/RetryPolicy.swift",
                                          "Sources/Legacy/OldSync.swift", "Docs/sync.md", "Resources/sync-badge.png", "run.sh"])

        let queue = try XCTUnwrap(byPath["Sources/Sync/SyncQueue.swift"])
        XCTAssertEqual(queue.kind, .modified)
        XCTAssertEqual(queue.additions, 3)
        XCTAssertEqual(queue.deletions, 2)
        XCTAssertEqual(queue.oldMode?.octal, "100644")
        XCTAssertEqual(queue.hunks.count, 3)
        XCTAssertEqual(queue.hunks[1].section, "final class SyncQueue {")

        let added = try XCTUnwrap(byPath["Sources/Sync/RetryPolicy.swift"])
        XCTAssertEqual(added.kind, .added)
        XCTAssertNil(added.oldPath)
        XCTAssertEqual(added.newMode?.kind, .regular)
        XCTAssertEqual(added.additions, 5)
        XCTAssertEqual(added.hunks.first?.oldStart, 0)
        XCTAssertEqual(added.hunks.first?.oldCount, 0)

        let deleted = try XCTUnwrap(byPath["Sources/Legacy/OldSync.swift"])
        XCTAssertEqual(deleted.kind, .deleted)
        XCTAssertNil(deleted.newPath)
        XCTAssertEqual(deleted.deletions, 20)

        let renamed = try XCTUnwrap(byPath["Docs/sync.md"])
        XCTAssertEqual(renamed.kind, .renamed)
        XCTAssertEqual(renamed.oldPath, "Docs/syncing.md")
        XCTAssertEqual(renamed.similarity.map { $0 >= 90 }, true)
        XCTAssertEqual(renamed.additions, 1)
        XCTAssertEqual(renamed.deletions, 1)

        let binary = try XCTUnwrap(byPath["Resources/sync-badge.png"])
        XCTAssertEqual(binary.kind, .binary)
        XCTAssertEqual(binary.binary?.source, .marker)

        let mode = try XCTUnwrap(byPath["run.sh"])
        XCTAssertEqual(mode.kind, .modeChanged)
        XCTAssertTrue(mode.isModeChange)
        XCTAssertEqual(mode.oldMode?.kind, .regular)
        XCTAssertEqual(mode.newMode?.kind, .executable)
        XCTAssertTrue(mode.hunks.isEmpty)

        let summary = DiffSummary(patch: patch)
        XCTAssertEqual(summary.lead, "6 files changed: 1 edited, 1 added, 1 deleted, 1 renamed, 1 mode changed, 1 binary; 9 lines added, 23 removed")
        XCTAssertEqual(summary.files.map(\.name).prefix(3), ["OldSync.swift", "RetryPolicy.swift", "SyncQueue.swift"])
        XCTAssertEqual(summary.files.first { $0.name == "sync.md" }?.detail.map { $0.hasPrefix("← Docs/syncing.md · ") }, true)
        XCTAssertEqual(summary.files.first { $0.name == "run.sh" }?.detail, "now executable")
    }

    func testFormatPatchHeadersMessageAndSignature() throws {
        let patch = PatchParser.parse(data(Samples.fiveFileFormatPatch))
        assertConsistent(patch)
        XCTAssertEqual(patch.format, .formatPatch)
        XCTAssertEqual(patch.commits.count, 1)
        let commit = try XCTUnwrap(patch.commits.first)
        XCTAssertEqual(commit.source, .email)
        XCTAssertEqual(commit.hash?.count, 40)
        XCTAssertEqual(commit.authorName, "Dana Reyes")
        XCTAssertEqual(commit.authorEmail, "dana@example.com")
        XCTAssertEqual(commit.subject, "Sync: queue edits while offline and retry with backoff")
        XCTAssertEqual(commit.subjectPrefix, "[PATCH]")
        XCTAssertEqual(commit.body, "Edits made with no network were dropped when the app quit.\nThey now go into an actor-backed queue.")
        XCTAssertEqual(commit.date, ISO8601DateFormatter().date(from: "2026-10-27T09:00:00Z"))
        XCTAssertEqual(commit.gitVersion, "2.50.1")
        XCTAssertEqual(patch.files.count, 6)
        XCTAssertTrue(patch.files.allSatisfy { $0.commitIndex == 0 })
        XCTAssertEqual(patch.totals.additions, 9)
        XCTAssertEqual(patch.totals.deletions, 23)
        // The diffstat between `---` and the first diff is not taken as preamble or as garbage.
        XCTAssertEqual(patch.preamble, "")
        XCTAssertFalse(patch.issues.contains { if case .unrecognizedLines = $0.kind { return true } else { return false } })

        let facts = DiffFacts.facts(for: patch)
        XCTAssertEqual(facts.first { $0.key == "subject" }?.value, commit.subject)
        XCTAssertEqual(facts.first { $0.key == "author" }?.value, "Dana Reyes <dana@example.com>")
        XCTAssertEqual(facts.first { $0.key == "files" }?.value, "6")
        XCTAssertEqual(facts.first { $0.key == "renames" }?.value, "1")
        XCTAssertEqual(facts.first { $0.key == "binaryFiles" }?.value, "1")
        XCTAssertEqual(DiffFacts.coverage(for: patch), .complete)
    }

    func testFormatPatchSeriesInOneMbox() throws {
        let patch = PatchParser.parse(data(Samples.series))
        assertConsistent(patch)
        XCTAssertEqual(patch.commits.map(\.subject), ["Add two", "Add bee"])
        XCTAssertEqual(patch.commits.map(\.seriesIndex), [1, 2])
        XCTAssertEqual(patch.commits.map(\.seriesTotal), [2, 2])
        XCTAssertEqual(patch.commits.map(\.subjectPrefix), ["[PATCH 1/2]", "[PATCH 2/2]"])
        XCTAssertEqual(patch.commits[1].body, "With a body.")
        XCTAssertEqual(patch.files.map(\.path), ["a.txt", "b.txt"])
        XCTAssertEqual(patch.files.map(\.commitIndex), [0, 1])
        XCTAssertEqual(patch.files(inCommit: 1).map(\.kind), [.added])
    }

    func testGitBinaryPatchIsNotedWithSizes() throws {
        let patch = PatchParser.parse(data(Samples.binaryModified))
        let staged = PatchParser.parse(data(Samples.binaryModified + Samples.binaryAdded))
        for p in [patch, staged] {
            assertConsistent(p)
            let icon = try XCTUnwrap(p.files.first { $0.path == "icon.bin" })
            XCTAssertEqual(icon.binary?.source, .gitBinaryPatch)
            XCTAssertEqual(icon.binary?.forward, .literal)
            XCTAssertEqual(icon.binary?.reverse, .literal)
            XCTAssertEqual(icon.binary?.newSize, 1504)
            XCTAssertEqual(icon.binary?.oldSize, 1004)
            XCTAssertTrue(p.issues.contains { $0.kind == .binaryNotDecoded })
            XCTAssertEqual(p.issues.filter { $0.severity != .info }, [])
        }
        let added = try XCTUnwrap(staged.files.first { $0.path == "new.bin" })
        XCTAssertEqual(added.kind, .added)
        XCTAssertEqual(added.binary?.newSize, 4)
        XCTAssertEqual(added.binary?.oldSize, 0)
    }

    func testNoNewlineAtEndOfFileAndCRLFContent() throws {
        let patch = PatchParser.parse(data(Samples.endings))
        assertConsistent(patch)
        let eol = try XCTUnwrap(patch.files.first { $0.path == "eol.txt" })
        let lines = try XCTUnwrap(eol.hunks.first?.lines)
        XCTAssertEqual(lines.last?.kind, .added)
        XCTAssertEqual(lines.last?.text, "gamma")
        XCTAssertEqual(lines.last?.ending, DiffLineEnding.none)
        XCTAssertEqual(lines.first { $0.kind == .deleted }?.ending, .lf)
        let win = try XCTUnwrap(patch.files.first { $0.path == "win.txt" })
        let added = try XCTUnwrap(win.hunks.first?.lines.first { $0.kind == .added })
        XCTAssertEqual(added.text, "TWO")
        XCTAssertEqual(added.ending, .crlf)
        XCTAssertGreaterThan(patch.crlfLineCount, 0)
    }

    func testQuotedUnicodeAndSpacedPaths() throws {
        let patch = PatchParser.parse(data(Samples.quotedPaths))
        assertConsistent(patch)
        XCTAssertEqual(Set(patch.files.map(\.path)), ["café menu.txt", "dir with space/plain name.txt"])
        XCTAssertTrue(patch.files.allSatisfy { $0.oldPath == $0.newPath })
    }

    func testRenameWithoutContentChangeAndCopy() throws {
        let patch = PatchParser.parse(data(Samples.renameAndCopy))
        assertConsistent(patch)
        let rename = try XCTUnwrap(patch.files.first { $0.isRenamed })
        XCTAssertEqual(rename.oldPath, "one.txt")
        XCTAssertEqual(rename.newPath, "two.txt")
        XCTAssertEqual(rename.similarity, 100)
        XCTAssertTrue(rename.hunks.isEmpty)
        let copy = try XCTUnwrap(patch.files.first { $0.isCopied })
        XCTAssertEqual(copy.kind, .copied)
        XCTAssertEqual(copy.oldPath, "one.txt")
        XCTAssertEqual(copy.newPath, "copy.txt")
        XCTAssertEqual(copy.additions, 1)
        XCTAssertEqual(DiffSummary(patch: patch).lead, "2 files changed: 1 renamed, 1 copied; 1 line added")
    }

    func testSymlinkAndTypeChange() throws {
        let patch = PatchParser.parse(data(Samples.symlinks))
        assertConsistent(patch)
        let link = try XCTUnwrap(patch.files.first { $0.path == "link" })
        XCTAssertEqual(link.kind, .added)
        XCTAssertEqual(link.newMode?.kind, .symlink)
        XCTAssertEqual(link.hunks.first?.lines.first?.text, "target.txt")
        XCTAssertEqual(link.hunks.first?.lines.first?.ending, DiffLineEnding.none)
        // git writes a type change as a deletion and an addition of the same path.
        let thing = patch.files.filter { $0.path == "thing" || $0.oldPath == "thing" }
        XCTAssertEqual(thing.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.added, .deleted])
        XCTAssertEqual(DiffSummary.detail(link), "symlink")
    }

    func testGitLogPatchAndMergeCombinedDiff() throws {
        let log = PatchParser.parse(data(Samples.log))
        assertConsistent(log)
        XCTAssertEqual(log.format, .gitLog)
        XCTAssertEqual(log.commits.map(\.subject), ["Main change", "Side change"])
        XCTAssertEqual(log.commits.first?.authorName, "Dana Reyes")
        XCTAssertNotNil(log.commits.first?.date)
        XCTAssertEqual(log.files.map(\.commitIndex), [0, 1])

        let merge = PatchParser.parse(data(Samples.mergeCC))
        assertConsistent(merge)
        XCTAssertEqual(merge.commits.first?.mergeParents.count, 2)
        let file = try XCTUnwrap(merge.files.first)
        XCTAssertTrue(file.isCombined)
        XCTAssertEqual(file.parentCount, 2)
        XCTAssertEqual(file.path, "conflict.txt")
        XCTAssertTrue(merge.issues.contains { $0.kind == .combinedDiff(parents: 2) })
        let hunk = try XCTUnwrap(file.hunks.first)
        XCTAssertEqual(hunk.parentRanges.count, 2)
        XCTAssertTrue(hunk.header.hasPrefix("@@@ "))
        XCTAssertEqual(hunk.lines.first { $0.kind == .added }?.text, "resolved")
        XCTAssertEqual(hunk.lines.filter { $0.kind == .deleted }.map(\.text).sorted(), ["main", "side"])
        XCTAssertEqual(hunk.lines.first { $0.kind == .added }?.combinedMarkers, "++")
        XCTAssertFalse(merge.issues.contains { $0.severity == .error })
    }

    func testFunctionContextBecomesTheSectionAndFolds() throws {
        let patch = PatchParser.parse(data(Samples.functionContext))
        let file = try XCTUnwrap(patch.files.first)
        let hunk = try XCTUnwrap(file.hunks.first)
        XCTAssertEqual(hunk.oldStart, 18)
        XCTAssertEqual(hunk.section, "int main(void) {")
        let folds = DiffLayout.folds(file)
        XCTAssertEqual(folds.before.first??.label, "lines 1–17 unchanged · int main(void) {")
        XCTAssertNil(folds.after, "a patch does not know the file's length")
    }

    func testPlainDiffUAndRecursiveNewFile() throws {
        let plain = try DiffFixtureFolder()
        try plain.write("old/notes.txt", "a\nb\nc\nd\n")
        try plain.write("new/notes.txt", "a\nB\nc\nd\ne\n")
        try plain.write("new/added.txt", "fresh\n")
        try plain.write("old/gone.txt", "bye\n")
        try plain.write("old/only-old.txt", "x\n")
        let single = PatchParser.parse(try plain.diffU("old/notes.txt", "new/notes.txt"))
        assertConsistent(single)
        XCTAssertEqual(single.format, .unified)
        XCTAssertEqual(single.files.first?.oldPath, "old/notes.txt")
        XCTAssertEqual(single.files.first?.newPath, "new/notes.txt")
        XCTAssertEqual(single.files.first?.additions, 2)
        XCTAssertEqual(single.files.first?.deletions, 1)

        let recursive = PatchParser.parse(try plain.diff(["-ruN", "old", "new"]))
        assertConsistent(recursive)
        XCTAssertEqual(recursive.issues.filter { $0.severity != .info }, [])
        let added = try XCTUnwrap(recursive.files.first { $0.newPath == "new/added.txt" })
        XCTAssertEqual(added.kind, .added, "diff -N marks a missing side with the epoch and -0,0")
        let gone = try XCTUnwrap(recursive.files.first { $0.oldPath == "old/gone.txt" })
        XCTAssertEqual(gone.kind, .deleted)

        let brief = PatchParser.parse(try plain.diff(["-ru", "old", "new"]))
        XCTAssertTrue(brief.issues.contains { if case .onlyInOneSide = $0.kind { return true } else { return false } })
        XCTAssertEqual(brief.files.count, 1)
    }

    func testRenameDetectedOnlyByHeaderNamesWithSpaces() throws {
        let patch = PatchParser.parse(data(Samples.spacedRename))
        XCTAssertEqual(patch.files.first?.oldPath, "my notes.txt")
        XCTAssertEqual(patch.files.first?.newPath, "our notes.txt")
    }
}

/// The saved patches, in git's exact layout (invented content; hashes and blob ids are made up but well-formed).
/// A literal's last line break is not part of its text, so blocks git ends with an empty line end with two here.
private enum Samples {
    /// git's format-patch signature: "-- " (with its trailing space) and the git version.
    static let signature = "-- \n2.50.1\n\n"

    static let queueHunks = """
@@ -1,4 +1,4 @@
-final class SyncQueue {
+actor SyncQueue {
     line 1 of the queue
     line 2 of the queue
     line 3 of the queue
@@ -18,7 +18,7 @@ final class SyncQueue {
     line 17 of the queue
     line 18 of the queue
     line 19 of the queue
-    line 20 of the queue
+    row 20 of the queue
     line 21 of the queue
     line 22 of the queue
     line 23 of the queue
@@ -39,4 +39,5 @@ final class SyncQueue {
     line 38 of the queue
     line 39 of the queue
     line 40 of the queue
+    var pendingCount: Int { 0 }
 }

"""

    static let legacyDeletion = (1...20).map { "-legacy \($0)" }.joined(separator: "\n") + "\n"

    static let fiveFileBody = """
diff --git a/Docs/syncing.md b/Docs/sync.md
similarity index 96%
rename from Docs/syncing.md
rename to Docs/sync.md
index 3b18e51..8c1f4d2 100644
--- a/Docs/syncing.md
+++ b/Docs/sync.md
@@ -27,4 +27,4 @@ Sync paragraph 26 explains the offline queue.
 Sync paragraph 27 explains the offline queue.
 Sync paragraph 28 explains the offline queue.
 Sync paragraph 29 explains the offline queue.
-Sync paragraph 30 explains the offline queue.
+Sync paragraph 30 describes the offline queue.
diff --git a/Resources/sync-badge.png b/Resources/sync-badge.png
index 5f2a9c0..e41b7d3 100644
Binary files a/Resources/sync-badge.png and b/Resources/sync-badge.png differ
diff --git a/Sources/Legacy/OldSync.swift b/Sources/Legacy/OldSync.swift
deleted file mode 100644
index 9d7c3e1..0000000
--- a/Sources/Legacy/OldSync.swift
+++ /dev/null
@@ -1,20 +0,0 @@

""" + legacyDeletion + """
diff --git a/Sources/Sync/RetryPolicy.swift b/Sources/Sync/RetryPolicy.swift
new file mode 100644
index 0000000..a1c0e9b
--- /dev/null
+++ b/Sources/Sync/RetryPolicy.swift
@@ -0,0 +1,5 @@
+import Foundation
+
+struct RetryPolicy: Sendable {
+    var attempts = 3
+}
diff --git a/Sources/Sync/SyncQueue.swift b/Sources/Sync/SyncQueue.swift
index 4c0d2aa..b7e91f5 100644
--- a/Sources/Sync/SyncQueue.swift
+++ b/Sources/Sync/SyncQueue.swift

""" + queueHunks + """
diff --git a/run.sh b/run.sh
old mode 100644
new mode 100755

"""

    static let fiveFileDiff = fiveFileBody

    static let fiveFileFormatPatch = """
From 4e1f0b9a2c7d3e8f5a6b1c0d9e8f7a6b5c4d3e2f Mon Sep 17 00:00:00 2001
From: Dana Reyes <dana@example.com>
Date: Tue, 27 Oct 2026 10:00:00 +0100
Subject: [PATCH] Sync: queue edits while offline and retry with backoff

Edits made with no network were dropped when the app quit.
They now go into an actor-backed queue.
---
 Docs/{syncing.md => sync.md}   |  2 +-
 Resources/sync-badge.png       | Bin 309 -> 328 bytes
 Sources/Legacy/OldSync.swift   | 20 --------------------
 Sources/Sync/RetryPolicy.swift |  5 +++++
 Sources/Sync/SyncQueue.swift   |  5 +++--
 run.sh                         |  0
 6 files changed, 9 insertions(+), 23 deletions(-)
 rename Docs/{syncing.md => sync.md} (96%)
 delete mode 100644 Sources/Legacy/OldSync.swift
 create mode 100644 Sources/Sync/RetryPolicy.swift
 mode change 100644 => 100755 run.sh


""" + fiveFileBody.trimmingCharacters(in: .newlines) + "\n" + signature

    static let series = """
From 7a3c9e1f0b2d4c6e8a0b1c2d3e4f5a6b7c8d9e0f Mon Sep 17 00:00:00 2001
From: Dana Reyes <dana@example.com>
Date: Tue, 27 Oct 2026 10:00:00 +0100
Subject: [PATCH 1/2] Add two

---
 a.txt | 1 +
 1 file changed, 1 insertion(+)

diff --git a/a.txt b/a.txt
index 5626abf..814f4a4 100644
--- a/a.txt
+++ b/a.txt
@@ -1 +1,2 @@
 one
+two

""" + signature + """
From 0c9b8a7f6e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b Mon Sep 17 00:00:00 2001
From: Dana Reyes <dana@example.com>
Date: Tue, 27 Oct 2026 10:00:00 +0100
Subject: [PATCH 2/2] Add bee

With a body.
---
 b.txt | 1 +
 1 file changed, 1 insertion(+)
 create mode 100644 b.txt

diff --git a/b.txt b/b.txt
new file mode 100644
index 0000000..e4b7a35
--- /dev/null
+++ b/b.txt
@@ -0,0 +1 @@
+bee

""" + signature

    static let binaryModified = """
diff --git a/icon.bin b/icon.bin
index 6c1d0f0..9a8b7c6 100644
GIT binary patch
literal 1504
zcmV;N1!MZ0P)<h;3K|Lk000e1NJLTq000mG000mO1^@s6AM^iV00001b5ch_0Itp)
zR{#J2HAzH4RCwC$noCFoK^TQ6sZUc+<4H6qRNJ_SEZT%3ZLnfX@m84Lf)~-TB2-3d
Jq3?1!6aYNP{nh{g

literal 1004
zcmeIu0Sy2E0K%a6Pi+o2h(KYzfB^#r3>YwAz<>b*1`HT5V8DO@0|pEjFkrxdfdK;s
b3>YwAz<>b*1`HT5V8DO@0|pEjFkrxdfdTF9


"""

    static let binaryAdded = """
diff --git a/new.bin b/new.bin
new file mode 100644
index 0000000..d8e0f1a
GIT binary patch
literal 4
LcmZQzU|;|M00aO5

literal 0
HcmV?d00001


"""

    /// `\r` is written as ⏎ below and put back, so the CRLF lines survive the source file.
    static let endings = """
diff --git a/eol.txt b/eol.txt
index 2c8c58a..f5b1c36 100644
--- a/eol.txt
+++ b/eol.txt
@@ -1,3 +1,3 @@
 alpha
 beta
-gamma
+gamma
\\ No newline at end of file
diff --git a/win.txt b/win.txt
index 7f1d3a2..c4e5b60 100644
--- a/win.txt
+++ b/win.txt
@@ -1,2 +1,2 @@
 one⏎
-two⏎
+TWO⏎

""".replacingOccurrences(of: "⏎", with: "\r")

    static let quotedPaths = #"""
diff --git "a/caf\303\251 menu.txt" "b/caf\303\251 menu.txt"
index 1e5b7a0..6a9c3f2 100644
--- "a/caf\303\251 menu.txt"
+++ "b/caf\303\251 menu.txt"
@@ -1 +1,2 @@
 soup
+bread
diff --git a/dir with space/plain name.txt b/dir with space/plain name.txt
index 587be6b..975fbec 100644
--- a/dir with space/plain name.txt
+++ b/dir with space/plain name.txt
@@ -1 +1 @@
-x
+y

"""#

    static let renameAndCopy = """
diff --git a/one.txt b/copy.txt
similarity index 95%
copy from one.txt
copy to copy.txt
index 3e1d7a9..b2c4f08 100644
--- a/one.txt
+++ b/copy.txt
@@ -18,3 +18,4 @@ shared line 17
 shared line 18
 shared line 19
 shared line 20
+extra
diff --git a/one.txt b/two.txt
similarity index 100%
rename from one.txt
rename to two.txt

"""

    static let symlinks = """
diff --git a/link b/link
new file mode 120000
index 0000000..2b0f1c2
--- /dev/null
+++ b/link
@@ -0,0 +1 @@
+target.txt
\\ No newline at end of file
diff --git a/thing b/thing
deleted file mode 100644
index 7d3b0e1..0000000
--- a/thing
+++ /dev/null
@@ -1 +0,0 @@
-a regular file
diff --git a/thing b/thing
new file mode 120000
index 0000000..2b0f1c2
--- /dev/null
+++ b/thing
@@ -0,0 +1 @@
+target.txt
\\ No newline at end of file

"""

    static let log = """
commit 9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
Author: Dana Reyes <dana@example.com>
Date:   Tue Oct 27 10:00:00 2026 +0100

    Main change

diff --git a/conflict.txt b/conflict.txt
index 5b6c1b8..a3f0e27 100644
--- a/conflict.txt
+++ b/conflict.txt
@@ -1,2 +1,2 @@
-base
+main
 shared

commit 1a2b3c4d5e6f708192a3b4c5d6e7f80912a3b4c5
Author: Dana Reyes <dana@example.com>
Date:   Tue Oct 27 10:00:00 2026 +0100

    Side change

diff --git a/conflict.txt b/conflict.txt
index 5b6c1b8..e8d2f41 100644
--- a/conflict.txt
+++ b/conflict.txt
@@ -1,2 +1,2 @@
-base
+side
 shared

"""

    static let mergeCC = """
commit 0f1e2d3c4b5a69788796a5b4c3d2e1f0a9b8c7d6
Merge: 9f8e7d6 1a2b3c4
Author: Dana Reyes <dana@example.com>
Date:   Tue Oct 27 10:00:00 2026 +0100

    Merge side

diff --cc conflict.txt
index a3f0e27,e8d2f41..6b1f0c9
--- a/conflict.txt
+++ b/conflict.txt
@@@ -1,2 -1,2 +1,2 @@@
- main
 -side
++resolved
  shared

"""

    static let functionContext = """
diff --git a/calc.c b/calc.c
index 2f9e1c4..8b3d7a0 100644
--- a/calc.c
+++ b/calc.c
@@ -18,7 +18,7 @@ int main(void) {
     let v17 = 17
     let v18 = 18
     let v19 = 19
-    let v20 = 20
+    let v20 = 21
     let v21 = 21
     let v22 = 22
     let v23 = 23

"""

    static let spacedRename = """
diff --git a/my notes.txt b/our notes.txt
similarity index 100%
rename from my notes.txt
rename to our notes.txt

"""
}
