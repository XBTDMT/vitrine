import WebKit
import XCTest
@testable import VitrinePreviewKit
import VitrineSupport

/// The log view (S-5, code state 11): levels, folded repeats, silences, the level filter and the Log/Text switch.
/// The log is invented here. roadmap: S-5
@MainActor
final class CodeLogTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CodeRenderer.readyTimeout = .seconds(10)
    }

    override func tearDownWithError() throws {
        CodeRenderer.readyTimeout = .seconds(3)
        try? FileManager.default.removeItem(at: dir)
    }

    /// 6 lines, a 4 min 12 s silence, 39 retries (attempts 2…40) a second apart, then 3 lines.
    private var workerLog: String {
        var lines = [
            "09:41:02.118 INFO  worker started pid=4127 version=3.2.0",
            "09:41:02.140 DEBUG config loaded 14 keys from /etc/harbor/worker.toml",
            "09:41:03.502 INFO  sync pushed 50 notes in 212 ms",
            "09:41:05.511 INFO  sync pushed 50 notes in 198 ms",
            "09:41:07.902 WARN  sync 3 conflicts, keeping local copies",
            "09:45:20.004 ERROR net connect ECONNREFUSED 10.0.4.12:8443",
        ]
        for attempt in 2...40 {
            lines.append(String(format: "09:45:%02d.250 WARN  net retrying connection (attempt %d)", 18 + attempt, attempt))
        }
        lines += [
            "09:46:01.330 ERROR sync gave up after 5 attempts",
            "09:46:01.331 INFO  sync queued 182 notes for next run",
            "09:47:00.000 INFO  worker health ok queue=182 rss=88 MB",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private func render() async throws -> (CodeRenderer, RenderedPreview, WKWebView) {
        let url = dir.appendingPathComponent("sync-worker.log")
        try workerLog.write(to: url, atomically: true, encoding: .utf8)
        let renderer = CodeRenderer()
        let preview = try await renderer.render(url: url, kind: FileSniffer.kind(of: url), context: RenderContext(appearance: .light, defaultsSuite: "vt-log"))
        return (renderer, preview, try XCTUnwrap((preview.view as? CodeContainer)?.web, "\(renderer.pageErrors)"))
    }

    private func js(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.callAsyncJavaScript(script, contentWorld: .page)
    }

    func testLevelsRepeatsAndSilences() async throws {
        let (renderer, preview, web) = try await render()
        defer { withExtendedLifetime(renderer) {} }
        XCTAssertEqual(preview.document.viewTitles, ["Log", "Text", "Hex"])
        XCTAssertEqual(preview.findPrefixes, [.line, .symbol, .level])
        XCTAssertEqual(preview.document.fact("headline")?.value, "48 lines · 2 errors")

        let analysis = try await js(web, "const a = window.vitrine.logAnalysis(); return JSON.stringify({ e: a.errors, w: a.warnings, runs: a.runs, gaps: a.gaps });") as? String
        let a = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(analysis).utf8)) as? [String: Any])
        XCTAssertEqual(a["e"] as? Int, 2)
        XCTAssertEqual(a["w"] as? Int, 40)
        let gaps = try XCTUnwrap(a["gaps"] as? [[String: Any]])
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0]["line"] as? Int, 6)

        let run = try await js(web, "return document.querySelector('.vt-run').textContent;") as? String
        XCTAssertEqual(run, "×38 net retrying connection (attempt 3 … 40) over 37 s · Show all")
        let silence = try await js(web, "return document.querySelector('.vt-gap').textContent;") as? String
        XCTAssertEqual(silence, "4 min 12 s with no lines")
        let error = try await js(web, "const e = document.querySelector('.vt-lv-error'); return e ? e.textContent : null;") as? String
        XCTAssertEqual(error, "ERROR")
        // The level's colour, not the grammar's, on the word itself.
        let warnColour = try await js(web, """
            const w = document.querySelector('.vt-lv-warn'); const inner = w.querySelector('span') || w;
            const probe = document.createElement('span'); probe.style.color = getComputedStyle(document.documentElement).getPropertyValue('--v-caution-text');
            document.body.append(probe); const want = getComputedStyle(probe).color; probe.remove();
            return getComputedStyle(inner).color === want;
            """) as? Bool
        XCTAssertEqual(warnColour, true)

        // Text: the same lines, plain.
        XCTAssertEqual(preview.showView?(1), true)
        try await Task.sleep(for: .milliseconds(100))
        let plain = try await js(web, "return [document.querySelectorAll('.vt-run').length, document.querySelectorAll('.vt-gap').length, document.querySelectorAll('.vt-lv').length];") as? [Int]
        XCTAssertEqual(plain, [0, 0, 0])
    }

    func testNewLinesAreAppendedAndFollowedAtTheEnd() async throws {
        let (renderer, preview, web) = try await render()
        defer { withExtendedLifetime(renderer) {} }
        let url = try XCTUnwrap(renderer.fileURL)
        // At the end of the log, three lines arrive.
        _ = try await js(web, "const s = window.vitrine.view.scrollDOM; s.scrollTop = s.scrollHeight; return true;")
        let more = "09:47:12.300 INFO  sync pushed 50 notes in 198 ms\n09:47:14.311 ERROR sync gave up after 5 attempts\n09:47:16.902 INFO  sync pushed 50 notes in 193 ms\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(more.utf8))
        try handle.close()
        let reload = try XCTUnwrap(preview.reload)
        let document = try await reload(url)
        preview.replaceDocument(document) // what the host does with a reload's document
        XCTAssertEqual(document.viewTitles, ["Log", "Text", "Hex"])
        let lines = try await js(web, "return window.vitrine.view.state.doc.lines;") as? Int
        XCTAssertEqual(lines, 52)
        let chip = try await js(web, "return document.getElementById('vt-follow').textContent;") as? String
        XCTAssertEqual(chip, "Following · 3 new lines")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(preview.document.fact("headline")?.value, "51 lines · growing · 3 errors")
    }

    func testLevelFilterKeepsWarningsAndWorse() async throws {
        let (renderer, preview, web) = try await render()
        defer { withExtendedLifetime(renderer) {} }
        let find = try XCTUnwrap(preview.find)
        let r = await find("level:warn", true)
        XCTAssertEqual(r.label, "42 lines at WARN or worse")
        let folds = try await js(web, "return Array.from(document.querySelectorAll('.vt-level')).map(e => e.textContent);") as? [String]
        XCTAssertEqual(folds, ["3 lines below WARN"], "lines 2–4; line 1 anchors the fold, the closing two are shown")
        preview.clearFind?()
        try await Task.sleep(for: .milliseconds(50))
        let left = try await js(web, "return document.querySelectorAll('.vt-level').length;") as? Int
        XCTAssertEqual(left, 0)
    }
}
