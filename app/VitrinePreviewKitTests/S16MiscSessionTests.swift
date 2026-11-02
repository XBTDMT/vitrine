import XCTest
@testable import VitrinePreviewKit
import VitrineText

/// S-16 hardening of the session reader and page (F23, F24, F25, F40, F47): numbers a transcript writes cannot trap
/// the process that draws it, the masker keeps only a vendor's known prefix, and masking reads a bounded text in
/// linear time. Every transcript is invented here. roadmap: S-16
final class S16MiscSessionTests: XCTestCase {
    func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    // MARK: F23: token counters

    func testHugeTokenCountersDoNotTrapAndReadAsUnknown() throws {
        let line = #"{"type":"assistant","sessionId":"x","message":{"id":"m","usage":{"input_tokens":9223372036854775807,"cache_read_input_tokens":1},"content":[]}}"#
        let s = try XCTUnwrap(SessionParser.parse(data: data([line])))
        XCTAssertNil(s.context, "a counter past any real count makes the reading unknown")
        let both = #"{"type":"assistant","sessionId":"x","message":{"id":"m","usage":{"input_tokens":5e18,"cache_creation_input_tokens":5e18},"content":[]}}"#
        XCTAssertNil(try XCTUnwrap(SessionParser.parse(data: data([both]))).context)
        let negative = #"{"type":"assistant","sessionId":"x","message":{"id":"m","usage":{"input_tokens":-5,"cache_read_input_tokens":9},"content":[]}}"#
        XCTAssertNil(try XCTUnwrap(SessionParser.parse(data: data([negative]))).context)
        // An honest reading is still read.
        let fine = #"{"type":"assistant","sessionId":"x","message":{"id":"m","usage":{"input_tokens":1200,"cache_read_input_tokens":800,"output_tokens":40},"content":[]}}"#
        let ok = try XCTUnwrap(SessionParser.parse(data: data([fine])))
        XCTAssertEqual(ok.context?.used, 2_000)
        XCTAssertEqual(ok.context?.output, 40)
    }

    func testCountsFromTheFileAreCheckedAndSumsSaturate() {
        XCTAssertEqual(SessionParser.count(NSNumber(value: 42)), 42)
        XCTAssertEqual(SessionParser.count(NSNumber(value: 12.9)), 12)
        XCTAssertNil(SessionParser.count(NSNumber(value: -1)))
        XCTAssertNil(SessionParser.count(NSNumber(value: Int.max)))
        XCTAssertNil(SessionParser.count(NSNumber(value: Double.infinity)))
        XCTAssertNil(SessionParser.count(NSNumber(value: Double.nan)))
        XCTAssertNil(SessionParser.count(NSNumber(value: true)), "a Boolean is not a count")
        XCTAssertNil(SessionParser.count("12"))
        XCTAssertEqual(SessionParser.saturatingSum([Int.max, 1, 5]), Int.max)
        XCTAssertEqual(SessionParser.saturatingSum([2, 3]), 5)
    }

    func testRecordedHunksWithDamagedNumbersAreNotUsed() throws {
        let lines = [
            #"{"type":"user","sessionId":"x","timestamp":"2026-10-01T09:00:00Z","cwd":"/p","message":{"role":"user","content":"edit it"}}"#,
            #"{"type":"assistant","sessionId":"x","timestamp":"2026-10-01T09:00:01Z","message":{"id":"a1","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/p/a.txt","old_string":"one","new_string":"two"}}]}}"#,
            #"{"type":"user","sessionId":"x","timestamp":"2026-10-01T09:00:02Z","toolUseResult":{"structuredPatch":[{"oldStart":-9223372036854775808,"oldLines":1,"newStart":1,"newLines":1e300,"lines":["-one","+two"]}]},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
        ]
        let s = try XCTUnwrap(SessionParser.parse(data: data(lines)))
        XCTAssertEqual(s.edits.count, 1)
        XCTAssertNil(s.edits[0].recordedHunks, "numbers that are not counts are not taken as line numbers")
        _ = SessionChanges.patch(s)
    }

    // MARK: F24: timestamps and the session's length

    func testExtremeTimestampsDoNotTrapTheHeader() throws {
        let lines = [
            #"{"type":"user","sessionId":"x","timestamp":0,"message":{"role":"user","content":"hi"}}"#,
            #"{"type":"user","sessionId":"x","timestamp":1e300,"message":{"role":"user","content":"hi"}}"#,
            #"{"type":"user","sessionId":"x","timestamp":-1e300,"message":{"role":"user","content":"hi"}}"#,
        ]
        let s = try XCTUnwrap(SessionParser.parse(data: data(lines)))
        if let ended = s.ended { XCTAssertTrue(SessionParser.plausibleTimes.contains(ended)) }
        if let started = s.started { XCTAssertTrue(SessionParser.plausibleTimes.contains(started)) }
        let html = SessionPage.html(s, files: SessionChanges.files(s), appearance: .light)
        XCTAssertFalse(html.isEmpty)
    }

    func testTimestampsOutsideThePlausibleRangeReadAsNoTime() {
        XCTAssertNil(SessionParser.date(NSNumber(value: 1e300)))
        XCTAssertNil(SessionParser.date(NSNumber(value: -1e300)))
        XCTAssertNil(SessionParser.date(NSNumber(value: Double.nan)))
        XCTAssertNil(SessionParser.date(NSNumber(value: true)))
        XCTAssertNotNil(SessionParser.date(NSNumber(value: 1_790_000_000)))
        XCTAssertNotNil(SessionParser.date(NSNumber(value: 1_790_000_000_000)), "milliseconds still read")
        XCTAssertNotNil(SessionParser.date("2026-10-01T09:00:00Z"))
        XCTAssertNotNil(SessionParser.date("2026-10-01T09:00:00.250Z"))
    }

    func testDurationTextNeverTraps() {
        XCTAssertEqual(SessionPage.durationText(20), "under a minute")
        XCTAssertEqual(SessionPage.durationText(90 * 60), "1 h 30 min")
        XCTAssertFalse(SessionPage.durationText(1e297).isEmpty)
        XCTAssertFalse(SessionPage.durationText(-1e297).isEmpty)
        XCTAssertFalse(SessionPage.durationText(.infinity).isEmpty)
    }

    // MARK: F40: the context window

    func testANegativeContextWindowDoesNotTrapTheMeter() throws {
        let lines = [
            #"{"type":"session_meta","payload":{"id":"x"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1},"model_context_window":-9223372036854775808}}}"#,
        ]
        let s = try XCTUnwrap(SessionParser.parse(data: data(lines)))
        XCTAssertEqual(s.source, .codex)
        XCTAssertEqual(s.context?.used, 1)
        XCTAssertNil(s.context?.window, "a window that is not positive is not recorded")
        XCTAssertTrue(SessionPage.meter(s).contains("assumed"))
        _ = SessionPage.html(s, files: [], appearance: .light)
    }

    func testTheMeterHoldsForAnyContextItIsHanded() {
        var s = AgentSession(source: .codex)
        for (used, window) in [(Int.max, Int.min), (Int.max, -2), (Int.max, 0), (5, Int.max), (Int.max, Int.max), (-7, 100)] {
            s.context = SessionContext(used: used, window: window, output: nil)
            _ = SessionPage.meter(s)
        }
    }

    // MARK: F25: what the mask keeps

    /// The masked form keeps only `prefix` in clear, and the last four only when `suffix`.
    func assertMasked(_ secret: String, prefix: String, suffix: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let (masked, n) = SessionSecrets.maskProse("key: \(secret) end")
        XCTAssertEqual(n, 1, "found \(secret)", file: file, line: line)
        let expected = prefix + SecretMask.bullets(secret.count) + (suffix ? String(secret.suffix(4)) : "")
        XCTAssertEqual(masked, "key: \(expected) end", file: file, line: line)
    }

    func testOnlyTheVendorsPrefixIsKept() {
        // The first underscore sits inside the random body, near its end: before the fix all but a character showed.
        assertMasked("sk-ant-api03-Qw7Rt2Yp9Lm4Nx8Bv3Cz6Kd1Fg5Hj0Ss7Tu2Wv9Xe4Ab8Cd3Ef6Gh1Ij5Kl0Mn_Op", prefix: "sk-ant-api03-", suffix: true)
        assertMasked("sk-proj-Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4z_Q", prefix: "sk-proj-", suffix: true)
        assertMasked("sk-Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4z_Q7", prefix: "sk-", suffix: true)
        assertMasked("AIzaSyAb3dEf6hIj9kLm2nOp5qRs8tUv1w_x", prefix: "AIza", suffix: true)
        assertMasked("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.Ab3dEf6hIj9kLm2n_pQ", prefix: "eyJ", suffix: true)
        assertMasked("ghp_Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4z0Q", prefix: "ghp_", suffix: true)
        assertMasked("github_pat_11Ab3dEf6hIj9kLm2nOp5_qRs8tUv1wXy4z0Q", prefix: "github_pat_", suffix: true)
        assertMasked("xoxb-1234567890-Ab3dEf6hIj9k", prefix: "xoxb-", suffix: true)
        // Short bodies: the last four would be too much of what is hidden.
        assertMasked("sk_live_Ab3dEf6h", prefix: "sk_live_", suffix: false)
        assertMasked("AKIAABCDEFGHIJKLMNOP", prefix: "AKIA", suffix: false)
    }

    func testNoPartOfTheBodyShowsBeforeTheLastFour() {
        let body = "Qw7Rt2Yp9Lm4Nx8Bv3Cz6Kd1Fg5Hj0Ss7Tu2Wv9Xe4Ab8Cd3Ef6Gh1Ij5Kl0Mn_Op"
        let (masked, _) = SessionSecrets.maskProse("sk-ant-api03-" + body)
        for start in 0..<(body.count - 4 - 3) {
            let piece = String(body.dropFirst(start).prefix(4))
            XCTAssertFalse(masked.contains(piece), "\(piece) of the hidden body is shown")
        }
    }

    // MARK: F47: masking runs in linear time on a bounded window

    func testAPathologicalRunMasksInLinearTime() {
        let run = String(repeating: "-eyJ", count: 250_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = SessionSecrets.maskProse(run) }
        XCTAssertLessThan(elapsed, .seconds(2), "1 MB of -eyJ masked in \(elapsed)")
    }

    func testAHugeThinkingBlockIsCutBeforeItIsMasked() throws {
        let thinking = String(repeating: "-eyJ", count: 1_000_000)
        let obj: [String: Any] = ["type": "assistant", "sessionId": "x",
                                  "message": ["id": "m", "content": [["type": "thinking", "thinking": thinking]]]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        // A short first record, so the transcript is recognised from its first 256 KB.
        let first = #"{"type":"user","sessionId":"x","message":{"role":"user","content":"think"}}"#
        let clock = ContinuousClock()
        var session: AgentSession?
        let elapsed = clock.measure { session = SessionParser.parse(data: data([first, line])) }
        XCTAssertLessThan(elapsed, .seconds(2), "a 4 MB thinking block parsed in \(elapsed)")
        let drawn = session?.items.compactMap { item -> String? in if case .thinking(let t, _) = item { t } else { nil } }.first
        let text = try XCTUnwrap(drawn, "no thinking row")
        XCTAssertLessThanOrEqual(text.count, SessionLimits.preview.textChars + 2)
        XCTAssertTrue(text.hasSuffix("\n…"))
    }

    func testACredentialStraddlingTheCutIsMaskedWhole() {
        let key = "ghp_Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4z0Q"
        let text = String(repeating: "a ", count: 50) + key + " tail"
        let (masked, n) = SessionSecrets.maskProse(text, cutTo: 110)
        XCTAssertEqual(n, 1)
        XCTAssertFalse(masked.contains("Ab3dEf"), "the part before the cut is masked")
        XCTAssertTrue(masked.hasSuffix("\n…"))
        XCTAssertEqual(SessionSecrets.maskProse("short", cutTo: 110).0, "short")
        XCTAssertEqual(SessionSecrets.maskProse("anything", cutTo: 0).0, "")
    }

    func testCodexReasoningAndArgumentsAreMasked() throws {
        let lines = [
            #"{"type":"session_meta","payload":{"id":"x"}}"#,
            #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"text":"use ghp_Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4z0Q"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"fetch","call_id":"c1","arguments":"{\"token\":\"sk-Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4z0Q7\"}"}}"#,
        ]
        let s = try XCTUnwrap(SessionParser.parse(data: data(lines)))
        guard case .thinking(let text, _) = try XCTUnwrap(s.items.first) else { return XCTFail("no reasoning row") }
        XCTAssertFalse(text.contains("Ab3dEf"))
        XCTAssertFalse(s.tools.first?.argument.contains("Ab3dEf") ?? true)
        XCTAssertEqual(s.maskedSecrets, 2)
    }
}
