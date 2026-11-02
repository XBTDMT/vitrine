import XCTest
@testable import VitrineText

/// Random damage to well-formed patches: flipped bytes, lost and doubled lines, cuts, swapped lines, hostile
/// numbers. The parser must never trap, every parsed value must stay self-consistent, and everything built on a
/// parse (summary, layout, highlights, facts) must build too.
final class PatchFuzzTests: XCTestCase {
    static let corpus: [String] = [
        """
        From 0123456789abcdef0123456789abcdef01234567 Mon Sep 17 00:00:00 2001
        From: Dana Reyes <dana@example.com>
        Date: Mon, 27 Oct 2026 10:00:00 +0100
        Subject: [PATCH 1/1] Sync: queue edits while offline

        Edits made with no network were dropped.
        ---
         Sources/Sync/SyncQueue.swift | 4 ++--
         1 file changed, 2 insertions(+), 2 deletions(-)

        diff --git a/Sources/Sync/SyncQueue.swift b/Sources/Sync/SyncQueue.swift
        index 1a2b3c4..5d6e7f8 100644
        --- a/Sources/Sync/SyncQueue.swift
        +++ b/Sources/Sync/SyncQueue.swift
        @@ -12,3 +12,3 @@ import Foundation
         /// Holds edits made while offline.
        -final class SyncQueue {
        +actor SyncQueue {
             private var pending: [Edit] = []
        @@ -58,3 +58,3 @@ extension SyncQueue {
             var isEmpty: Bool { pending.isEmpty }
        -    var count: Int { pending.count }
        +    var pendingCount: Int { pending.count }
         }
        diff --git a/Docs/syncing.md b/Docs/sync.md
        similarity index 91%
        rename from Docs/syncing.md
        rename to Docs/sync.md
        index 0000001..0000002 100644
        --- a/Docs/syncing.md
        +++ b/Docs/sync.md
        @@ -1,2 +1,2 @@
        -Old title
        +New title
         Body
        \\ No newline at end of file
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755
        diff --git a/icon.png b/icon.png
        new file mode 100644
        index 0000000..1234567
        GIT binary patch
        literal 12
        TcmZ?wbhEHbWMKdSM~DH5

        literal 0
        HcmV?d00001

        --\u{20}
        2.43.0

        """,
        """
        commit 89abcdef0123456789abcdef0123456789abcdef
        Merge: 1111111 2222222
        Author: Dana Reyes <dana@example.com>
        Date:   Mon Oct 27 10:00:00 2026 +0100

            Merge side

        diff --cc conflict.txt
        index 1111111,2222222..3333333
        --- a/conflict.txt
        +++ b/conflict.txt
        @@@ -1,2 -1,2 +1,2 @@@
        - main
         -side
        ++resolved
          shared

        """,
        "--- old/a.txt\t2026-10-27 10:00:00.000000000 +0100\n+++ new/a.txt\t2026-10-27 10:00:00.000000000 +0100\n@@ -1,4 +1,5 @@\n a\n-b\n+B\n c\n d\n+e\nOnly in old: gone.txt\nBinary files old/x.bin and new/x.bin differ\n",
    ]

    private enum Damage: CaseIterable { case flipByte, dropLine, doubleLine, cut, swapLines, insertBytes, hugeNumber, crlf }

    private func damage(_ text: String, _ rng: inout SeededRandom) -> Data {
        var bytes = Array(text.utf8)
        let rounds = Int.random(in: 1...4, using: &rng)
        for _ in 0..<rounds {
            guard !bytes.isEmpty else { break }
            switch Damage.allCases.randomElement(using: &rng)! {
            case .flipByte:
                let i = Int.random(in: 0..<bytes.count, using: &rng)
                bytes[i] = UInt8.random(in: 0...255, using: &rng)
            case .dropLine, .doubleLine, .swapLines, .crlf:
                var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
                guard !lines.isEmpty else { break }
                let i = Int.random(in: 0..<lines.count, using: &rng)
                let j = Int.random(in: 0..<lines.count, using: &rng)
                switch Damage.allCases.randomElement(using: &rng)! {
                case .dropLine: lines.remove(at: i)
                case .doubleLine: lines.insert(lines[i], at: i)
                case .crlf: lines[i].append(0x0D)
                default: lines.swapAt(i, j)
                }
                bytes = Array(lines.joined(separator: [0x0A]))
            case .cut:
                bytes = Array(bytes.prefix(Int.random(in: 0..<bytes.count, using: &rng)))
            case .insertBytes:
                let i = Int.random(in: 0...bytes.count, using: &rng)
                let junk: [[UInt8]] = [[0xFF, 0xFE], [0], Array("@@ -1,99999 +1 @@\n".utf8), Array("\\\n".utf8),
                                       Array("diff --git \n".utf8), Array("@@@ -1 -1 +1 @@@\n".utf8), [0xE2, 0x80]]
                bytes.insert(contentsOf: junk.randomElement(using: &rng)!, at: i)
            case .hugeNumber:
                if let at = bytes.firstIndex(of: 0x40) {                     // "@"
                    bytes.insert(contentsOf: Array("-999999999,999999999 ".utf8), at: min(bytes.count, at + 3))
                }
            }
        }
        return Data(bytes)
    }

    func testRandomDamageNeverTrapsAndStaysConsistent() {
        var rng = SeededRandom(seed: 0xD1FF_5EED)
        var withIssues = 0
        let iterations = 1_500
        for n in 0..<iterations {
            let base = Self.corpus[n % Self.corpus.count]
            let data = damage(base, &rng)
            let patch = PatchParser.parse(data, limits: PatchLimits(maxDetailedLines: 50, maxLineBytes: 64))
            assertConsistent(patch)
            if !patch.issues.isEmpty { withIssues += 1 }
            for issue in patch.issues { XCTAssertFalse(issue.message.isEmpty) }
            let summary = DiffSummary(patch: patch)
            XCTAssertFalse(summary.lead.isEmpty)
            _ = summary.folders()
            _ = DiffFacts.facts(for: patch)
            _ = DiffFacts.coverage(for: patch)
            for file in patch.files {
                _ = DiffLayout.unified(file)
                _ = DiffLayout.split(file)
                for hunk in file.hunks { _ = hunk.header }
            }
        }
        // Damage is random; most of it must be noticed and named.
        XCTAssertGreaterThan(withIssues, iterations / 3)
    }

    func testUndamagedCorpusIsClean() {
        for text in Self.corpus {
            let patch = PatchParser.parse(text)
            assertConsistent(patch)
            XCTAssertEqual(patch.issues.filter { $0.severity == .error }, [], text.prefix(40).description)
        }
        let first = PatchParser.parse(Self.corpus[0])
        XCTAssertEqual(first.files.map(\.kind), [.modified, .renamed, .modeChanged, .added])
        XCTAssertEqual(first.commits.first?.gitVersion, "2.43.0")
        XCTAssertEqual(first.files[3].binary?.newSize, 12)
        XCTAssertEqual(first.files[1].hunks[0].lines.last?.ending, DiffLineEnding.none)
        let plain = PatchParser.parse(Self.corpus[2])
        XCTAssertEqual(plain.files.map(\.kind), [.modified, .binary])
    }

    func testRandomBytesNeverTrap() {
        var rng = SeededRandom(seed: 42)
        for _ in 0..<300 {
            let count = Int.random(in: 0..<2_000, using: &rng)
            var bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
            // Seed some structure so the deeper paths run.
            for marker in ["\n@@ -1,3 +1,3 @@\n", "\ndiff --git a/x b/x\n", "\n--- a\n+++ b\n", "\nFrom: x\n\n", "\n+", "\n-", "\n "] {
                if Bool.random(using: &rng) { bytes.insert(contentsOf: Array(marker.utf8), at: Int.random(in: 0...bytes.count, using: &rng)) }
            }
            let patch = PatchParser.parse(Data(bytes))
            assertConsistent(patch)
            _ = DiffSummary(patch: patch).lead
        }
    }
}
