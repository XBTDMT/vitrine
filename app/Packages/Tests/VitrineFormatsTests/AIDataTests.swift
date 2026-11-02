import Foundation
import Testing
@testable import VitrineFormats

/// The AI data readers (S-21: A-5 JSONL, A-10 chat exports, A-11 evals and traces, A-7 arrays) against invented
/// fixtures built here byte by byte: per format a good file, a malformed one, a truncated one, and damage sweeps
/// (every prefix, seeded byte flips) that must never crash. roadmap: S-21
@Suite struct AIDataTests {

    // MARK: Helpers

    static func read(_ text: String, _ name: String) -> AIDataDocument? {
        AIDataReader.read(data: Data(text.utf8), fileName: name)
    }

    static func read(_ bytes: [UInt8], _ name: String) -> AIDataDocument? {
        AIDataReader.read(data: Data(bytes), fileName: name)
    }

    static func jsonl(_ doc: AIDataDocument?) -> JSONLSummary? { if case .jsonLines(let s)? = doc { s } else { nil } }
    static func chat(_ doc: AIDataDocument?) -> ChatExportSummary? { if case .chatExport(let s)? = doc { s } else { nil } }
    static func trace(_ doc: AIDataDocument?) -> OTLPTraceSummary? { if case .trace(let s)? = doc { s } else { nil } }
    static func promptfoo(_ doc: AIDataDocument?) -> PromptfooSummary? { if case .promptfoo(let s)? = doc { s } else { nil } }
    static func inspect(_ doc: AIDataDocument?) -> InspectEvalSummary? { if case .inspectEval(let s)? = doc { s } else { nil } }
    static func npy(_ doc: AIDataDocument?) -> NPYSummary? { if case .numpyArray(let s)? = doc { s } else { nil } }
    static func npz(_ doc: AIDataDocument?) -> NPZSummary? { if case .numpyArchive(let s)? = doc { s } else { nil } }
    static func hdf5(_ doc: AIDataDocument?) -> HDF5Summary? { if case .hdf5(let s)? = doc { s } else { nil } }

    /// Every prefix (by `step`) and 150 seeded mutations of `bytes`: the reader must return, whatever it returns.
    static func survivesDamage(_ bytes: [UInt8], name: String, step: Int = 1) {
        for n in stride(from: 0, through: bytes.count, by: max(1, step)) {
            _ = AIDataReader.read(data: Data(bytes.prefix(n)), fileName: name)
        }
        guard !bytes.isEmpty else { return }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 11
        }
        for _ in 0..<150 {
            var copy = bytes
            for _ in 0..<(1 + Int(next() % 4)) {
                copy[Int(next() % UInt64(copy.count))] = UInt8(truncatingIfNeeded: next())
            }
            _ = AIDataReader.read(data: Data(copy), fileName: name)
        }
    }

    static func le(_ value: UInt64, _ width: Int) -> [UInt8] {
        (0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    static func le(_ value: Int, _ width: Int) -> [UInt8] { le(UInt64(bitPattern: Int64(value)), width) }

    static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: Zip and NPY builders

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    /// A zip with stored or deflated members (raw DEFLATE from Foundation's zlib compressor).
    static func zip(_ members: [(name: String, data: [UInt8], deflate: Bool)]) -> [UInt8] {
        var out: [UInt8] = []
        var central: [UInt8] = []
        for m in members {
            let stored: [UInt8]
            let method: Int
            if m.deflate, let packed = try? (Data(m.data) as NSData).compressed(using: .zlib) as Data {
                stored = [UInt8](packed); method = 8
            } else {
                stored = m.data; method = 0
            }
            let crc = UInt64(crc32(m.data))
            let name = ascii(m.name)
            let offset = out.count
            out += le(0x0403_4B50, 4) + le(20, 2) + le(0, 2) + le(method, 2) + le(0, 2) + le(0x21, 2)
            out += le(crc, 4) + le(stored.count, 4) + le(m.data.count, 4) + le(name.count, 2) + le(0, 2) + name + stored
            central += le(0x0201_4B50, 4) + le(0x031E, 2) + le(20, 2) + le(0, 2) + le(method, 2) + le(0, 2) + le(0x21, 2)
            central += le(crc, 4) + le(stored.count, 4) + le(m.data.count, 4) + le(name.count, 2) + le(0, 2) + le(0, 2)
            central += le(0, 2) + le(0, 2) + le(0o100644 << 16, 4) + le(offset, 4) + name
        }
        let cdOffset = out.count
        out += central
        out += le(0x0605_4B50, 4) + le(0, 2) + le(0, 2) + le(members.count, 2) + le(members.count, 2)
        out += le(central.count, 4) + le(cdOffset, 4) + le(0, 2)
        return out
    }

    /// An `.npy` with the header NumPy writes: the dict, padded with spaces to a 64-byte boundary, then a newline.
    static func npyBytes(descr: String, shape: String, fortran: Bool = false, data: [UInt8], major: UInt8 = 1) -> [UInt8] {
        var header = "{'descr': \(descr), 'fortran_order': \(fortran ? "True" : "False"), 'shape': \(shape), }"
        let width = major >= 2 ? 4 : 2
        let unpadded = 8 + width + header.utf8.count + 1
        header += String(repeating: " ", count: (64 - unpadded % 64) % 64) + "\n"
        return [0x93] + ascii("NUMPY") + [major, 0] + le(header.utf8.count, width) + ascii(header) + data
    }

    static func doubles(_ values: [Double]) -> [UInt8] { values.flatMap { le($0.bitPattern, 8) } }

    // MARK: JSONL

    @Test func jsonlGenericSchemaTableAndMalformedLines() throws {
        let long = String(repeating: "x", count: 300)
        let text = """
        {"id": 1, "name": "ada", "meta": {"lang": "en", "tags": ["a", "b"]}, "score": 0.5}
        {"id": 2, "name": "bea", "meta": {"lang": "fr"}, "note": "\(long)"}

        {"id": 3, "name": null, "score": 2}
        {"id": 4, "name": "cy" broken
        [1, 2, 3]
        {"id": 5}
        """
        let s = try #require(Self.jsonl(Self.read(text, "people.jsonl")))
        #expect(s.shape == .generic)
        #expect(s.recordCount == 6)
        #expect(s.recordCountIsExact)
        #expect(s.blankLines == 1)
        #expect(s.malformedLines == [5])
        #expect(s.malformedCount == 1)
        #expect(s.nonObjectCount == 1)
        #expect(s.sampledRecords == 4)
        let id = try #require(s.fields.first { $0.path == "id" })
        #expect(id.types == [.integer])
        #expect(id.presence == 1)
        let name = try #require(s.fields.first { $0.path == "name" })
        #expect(name.types == [.string, .null])
        let score = try #require(s.fields.first { $0.path == "score" })
        #expect(score.types == [.integer, .number])
        #expect(score.presentCount == 2)
        #expect(s.fields.contains { $0.path == "meta.lang" && $0.presence == 0.5 })
        #expect(s.fields.contains { $0.path == "meta" && $0.types == [.object] })

        #expect(s.table.columns == ["id", "name", "meta.lang", "meta.tags", "score", "note"])
        #expect(s.table.rows.count == 4)
        #expect(s.table.rows[0] == ["1", "ada", "en", "[\"a\",\"b\"]", "0.5", ""])
        #expect(s.table.rows[2][1] == "null")
        let note = s.table.rows[1][5]
        #expect(note.count == AIDataTable.maxCellCharacters)
        #expect(note.hasSuffix("…"))
        #expect(s.table.totalRows == 4)
        #expect(!s.table.isTruncated)
        #expect(s.warnings.contains { $0.reason.contains("not valid JSON") && $0.reason.contains("line 5") })
        #expect(s.warnings.contains { $0.reason.contains("not an object") })
        #expect(s.headline.contains("6"))
    }

    @Test func jsonlOpenAIBatchInputWithDuplicateIDs() throws {
        let lines = (0..<4).map { i in
            #"{"custom_id": "req-\#(i == 3 ? 0 : i)", "method": "POST", "url": "/v1/chat/completions", "body": {"model": "gpt-4o-mini", "messages": [{"role": "user", "content": "Hello \#(i)"}]}}"#
        }
        let s = try #require(Self.jsonl(Self.read(lines.joined(separator: "\n"), "batch.jsonl")))
        #expect(s.shape == .openAIBatchInput)
        #expect(s.facts.contains { $0.label == "Endpoints" && $0.value.contains("/v1/chat/completions (4)") })
        #expect(s.facts.contains { $0.label == "Models" && $0.value.contains("gpt-4o-mini") })
        #expect(s.warnings.contains { $0.reason.contains("custom_id") })
        #expect(s.table.columns.contains("body.model"))
    }

    @Test func jsonlKnownShapes() throws {
        let output = """
        {"id": "batch_req_1", "custom_id": "a", "response": {"status_code": 200, "body": {"model": "gpt-4o", "usage": {"prompt_tokens": 10, "completion_tokens": 5}}}, "error": null}
        {"id": "batch_req_2", "custom_id": "b", "response": {"status_code": 500, "body": {}}, "error": {"code": "server_error"}}
        """
        let out = try #require(Self.jsonl(Self.read(output, "out.jsonl")))
        #expect(out.shape == .openAIBatchOutput)
        #expect(out.facts.contains { $0.label == "Failed" && $0.value == "1" })
        #expect(out.facts.contains { $0.label == "Input tokens" && $0.value == "10" })

        let tuning = """
        {"messages": [{"role": "system", "content": "Be brief."}, {"role": "user", "content": "Hi"}, {"role": "assistant", "content": "Hello."}]}
        {"messages": [{"role": "user", "content": "Only a question"}]}
        """
        let ft = try #require(Self.jsonl(Self.read(tuning, "train.jsonl")))
        #expect(ft.shape == .openAIFineTuningChat)
        #expect(ft.facts.contains { $0.label == "Messages" && $0.value == "4" })
        #expect(ft.facts.contains { $0.label == "With a system message" && $0.value == "1" })
        #expect(ft.warnings.contains { $0.reason.contains("no assistant message") })

        let requests = """
        {"custom_id": "q1", "params": {"model": "claude-test-model", "max_tokens": 1024, "messages": [{"role": "user", "content": "Hi"}]}}
        {"custom_id": "q2", "params": {"model": "claude-test-model", "max_tokens": 64, "messages": []}}
        """
        let req = try #require(Self.jsonl(Self.read(requests, "requests.jsonl")))
        #expect(req.shape == .anthropicBatchRequests)
        #expect(req.facts.contains { $0.label == "Largest max_tokens" && $0.value == "1,024" || $0.value == "1024" })

        let results = """
        {"custom_id": "q1", "result": {"type": "succeeded", "message": {"model": "claude-test-model", "usage": {"input_tokens": 12, "output_tokens": 7}}}}
        {"custom_id": "q2", "result": {"type": "errored", "error": {"type": "invalid_request"}}}
        """
        let res = try #require(Self.jsonl(Self.read(results, "results.jsonl")))
        #expect(res.shape == .anthropicBatchResults)
        #expect(res.facts.contains { $0.label == "Output tokens" && $0.value == "7" })
        #expect(res.warnings.contains { $0.reason.contains("did not succeed") })

        let evals = """
        {"input": "2+2", "expected": "4", "output": "4", "score": 1}
        {"input": "3+3", "expected": "6", "output": "7", "score": 0}
        {"input": "1+1", "expected": "2", "output": "2", "score": 0.5}
        """
        let ev = try #require(Self.jsonl(Self.read(evals, "evals.jsonl")))
        #expect(ev.shape == .evaluationResults)
        #expect(ev.facts.contains { $0.label == "Mean score" && $0.value == "0.5" })
        #expect(ev.facts.contains { $0.label == "Score field" && $0.value == "score" })

        let session = """
        {"type": "summary", "summary": "Invented", "leafUuid": "u2"}
        {"type": "user", "sessionId": "s-1", "uuid": "u1", "message": {"role": "user", "content": "hi"}}
        {"type": "assistant", "sessionId": "s-1", "uuid": "u2", "message": {"role": "assistant", "content": []}}
        """
        let cc = try #require(Self.jsonl(Self.read(session, "abc.jsonl")))
        #expect(cc.shape == .claudeCodeSession)
        #expect(cc.facts.contains { $0.label == "Sessions" && $0.value == "1" })
    }

    @Test func jsonlRowCapAndEstimateWhenCut() throws {
        let text = (0..<600).map { #"{"n": \#($0)}"# }.joined(separator: "\n") + "\n"
        let s = try #require(Self.jsonl(Self.read(text, "many.ndjson")))
        #expect(s.recordCount == 600)
        #expect(s.table.rows.count == AIDataTable.maxRows)
        #expect(s.table.isTruncated)
        #expect(s.table.totalRows == 600)

        // The caller passed only the first bytes of a file ten times as large, ending inside a record.
        let partial = Array(text.utf8) + Array(#"{"n": 6"#.utf8)
        let doc = AIDataReader.read(data: Data(partial), fileName: "many.jsonl", totalFileSize: Int64(text.utf8.count * 10))
        let cut = try #require(Self.jsonl(doc))
        #expect(!cut.recordCountIsExact)
        #expect(cut.malformedCount == 0)
        #expect(cut.recordCount > 5_000 && cut.recordCount < 7_000)
        #expect(cut.headline.contains("about"))
        #expect(cut.warnings.contains { $0.reason.contains("estimate") })
        #expect(cut.table.totalRows == nil)
    }

    @Test func jsonlLargerThanTheReadCap() throws {
        let line = Array(#"{"n": 1234567, "ok": true}"#.utf8) + [0x0A]  // 27 bytes
        let lines = AIDataReader.maxBytes / line.count + 50_000
        var bytes: [UInt8] = []
        bytes.reserveCapacity(lines * line.count)
        for _ in 0..<lines { bytes += line }
        let s = try #require(Self.jsonl(Self.read(bytes, "huge.jsonl")))
        #expect(!s.recordCountIsExact)
        #expect(s.malformedCount == 0)  // the partial last line inside the cap is not counted as broken
        #expect(abs(s.recordCount - lines) <= 1)
        #expect(s.sampledRecords == JSONLSummary.maxSampled)
        #expect(s.warnings.contains { $0.reason.contains("estimate") })
        #expect(s.warnings.contains { $0.reason.contains("checked for valid JSON") })
    }

    @Test func jsonlInsideJSONFileAndAllBroken() throws {
        let text = "{\"a\": 1}\n{\"a\": 2}\n"
        #expect(Self.jsonl(Self.read(text, "data.json"))?.recordCount == 2)
        let broken = try #require(Self.jsonl(Self.read("nope\n{bad\n", "x.jsonl")))
        #expect(broken.malformedCount == 2)
        #expect(broken.warnings.contains { $0.reason.contains("No line") })
        #expect(Self.read("{\"plain\": true}", "config.json") == nil)
        #expect(Self.read("", "empty.json") == nil)
        let deep = String(repeating: "[", count: 500) + String(repeating: "]", count: 500)
        #expect(Self.jsonl(Self.read(deep + "\n" + deep, "deep.jsonl"))?.malformedCount == 2)
    }

    @Test func jsonlSurvivesDamage() {
        let text = """
        {"custom_id": "r1", "method": "POST", "url": "/v1/embeddings", "body": {"model": "m", "input": "a\\u00e9\\ud83d\\ude00"}}
        {"custom_id": "r2", "method": "POST", "url": "/v1/embeddings", "body": {"model": "m", "input": [1, 2.5e3, -0.1, true, null]}}
        """
        Self.survivesDamage(Array(text.utf8), name: "b.jsonl")
    }

    @Test func jsonParserEscapesAndBudget() throws {
        let parsed = try AIJSONParser.parseDocument(Array(#"{"s": "a\nb\u00e9\ud83d\ude00\/", "n": -1.5e2, "big": 12345678901234567890}"#.utf8), limits: .document).get()
        #expect(parsed.value["s"]?.string == "a\nbé😀/")
        #expect(parsed.value["n"]?.double == -150)
        #expect(parsed.value["big"]?.uint64 == 12_345_678_901_234_567_890)
        #expect(parsed.value["big"]?.type == .integer)
        let small = AIJSONParser.Limits(stringCap: 4, maxDepth: 8, nodeBudget: 3)
        let cut = try AIJSONParser.parseDocument(Array(#"{"k": "abcdefgh", "a": [1, 2, 3, 4]}"#.utf8), limits: small).get()
        #expect(cut.budgetHit)
        #expect(cut.value["k"]?.string == "abcd…")
        for bad in ["{", "[1,]", "{\"a\" 1}", "01", "\"\\x\"", "tru", "1.", "{\"a\":1}x", "\"\u{01}\""] {
            #expect((try? AIJSONParser.parseDocument(Array(bad.utf8), limits: .document).get()) == nil, "\(bad)")
        }
    }

    // MARK: Chat exports

    static let chatGPTExport = """
    [
      {
        "title": "Invented trip plan",
        "create_time": 1700000000.5,
        "update_time": 1700003600.25,
        "current_node": "a2",
        "conversation_id": "conv-1",
        "default_model_slug": "gpt-4o",
        "mapping": {
          "root": {"id": "root", "message": null, "parent": null, "children": ["sys"]},
          "sys": {"id": "sys", "message": {"author": {"role": "system"}, "content": {"content_type": "text", "parts": [""]}, "metadata": {"is_visually_hidden_from_conversation": true}}, "parent": "root", "children": ["u1"]},
          "u1": {"id": "u1", "message": {"author": {"role": "user"}, "create_time": 1700000001, "content": {"content_type": "multimodal_text", "parts": ["Plan a walk", {"content_type": "image_asset_pointer"}]}}, "parent": "sys", "children": ["a1", "a2"]},
          "a1": {"id": "a1", "message": {"author": {"role": "assistant"}, "content": {"content_type": "text", "parts": ["First draft"]}, "metadata": {"model_slug": "gpt-4o"}}, "parent": "u1", "children": []},
          "a2": {"id": "a2", "message": {"author": {"role": "assistant"}, "content": {"content_type": "text", "parts": ["Regenerated answer"]}, "metadata": {"model_slug": "o3-test"}}, "parent": "u1", "children": []}
        }
      },
      {"title": "Second", "create_time": 1690000000, "update_time": 1690000100, "mapping": {"n": {"id": "n", "message": {"author": {"role": "user"}, "content": {"content_type": "text", "parts": ["solo"]}}, "parent": null, "children": []}}}
    ]
    """

    @Test func chatGPTExportMainPathBranchesAndModels() throws {
        let s = try #require(Self.chat(Self.read(Self.chatGPTExport, "conversations.json")))
        #expect(s.source == .chatGPT)
        #expect(s.conversationCount == 2)
        #expect(s.conversationCountIsExact)
        #expect(s.totalMessages == 4)
        #expect(s.earliest == Date(timeIntervalSince1970: 1_690_000_000))
        #expect(s.latest == Date(timeIntervalSince1970: 1_700_003_600.25))
        let first = s.conversations[0]
        #expect(first.title == "Invented trip plan")
        #expect(first.id == "conv-1")
        #expect(first.branchCount == 1)
        #expect(first.messageCount == 3)
        #expect(first.models == ["gpt-4o", "o3-test"])
        #expect(first.mainPath.map(\.role) == ["user", "assistant"])
        #expect(first.mainPath[0].text == "Plan a walk\n[image]")
        #expect(first.mainPath[1].text == "Regenerated answer")
        #expect(first.mainPathLength == 2)
        #expect(s.conversations[1].mainPath.map(\.text) == ["solo"])
        #expect(s.table.rows.count == 2)
        #expect(s.models["gpt-4o"] == 1)
    }

    @Test func claudeExport() throws {
        let long = String(repeating: "word ", count: 400)
        let text = """
        [{"uuid": "c-1", "name": "", "created_at": "2025-03-01T10:00:00.123456Z", "updated_at": "2025-03-02T11:30:00Z",
          "chat_messages": [
            {"uuid": "m1", "sender": "human", "text": "Hello there", "created_at": "2025-03-01T10:00:01Z", "attachments": [{"file_name": "a.txt"}], "files": []},
            {"uuid": "m2", "sender": "assistant", "text": "", "content": [{"type": "text", "text": "\(long)"}, {"type": "tool_use", "name": "search"}]}
          ]}]
        """
        let s = try #require(Self.chat(Self.read(text, "conversations.json")))
        #expect(s.source == .claude)
        let c = s.conversations[0]
        #expect(c.title == "Untitled")
        #expect(c.messageCount == 2)
        #expect(c.created == AIDates.iso8601("2025-03-01T10:00:00.123456Z"))
        #expect(c.mainPath[0].role == "user")
        #expect(c.mainPath[0].text.hasPrefix("Hello there\n["))
        #expect(c.mainPath[1].isTruncated)
        #expect(c.mainPath[1].text.count == ChatExportSummary.maxMessageCharacters)
        #expect(AIDates.iso8601("2025-03-01T12:00:00+02:00") == AIDates.iso8601("2025-03-01T10:00:00Z"))
        #expect(AIDates.iso8601("2025-13-01") == nil)
    }

    @Test func chatExportDamagedAndUnrelated() throws {
        let text = Self.chatGPTExport
        let cut = String(text.prefix(text.count - 120))
        let s = try #require(Self.chat(Self.read(cut, "conversations.json")))
        #expect(s.conversationCount == 1)
        #expect(!s.conversationCountIsExact)
        #expect(s.warnings.contains { $0.reason.contains("1 conversation before it") }, "one conversation, in the singular")
        #expect(Self.read("[{\"a\": 1}, {\"b\": 2}]", "list.json") == nil)
        #expect(Self.read("[1, 2, 3]", "numbers.json") == nil)
        Self.survivesDamage(Array(text.utf8), name: "conversations.json", step: 7)
    }

    // MARK: promptfoo

    static let promptfooResults = """
    {"evalId": "eval-test-1", "results": {"version": 3, "timestamp": "2025-05-05T12:00:00Z",
      "prompts": [{"raw": "Answer: {{q}}", "label": "short", "provider": "openai:gpt-4o-mini"}],
      "results": [
        {"testIdx": 0, "promptIdx": 0, "provider": {"id": "openai:gpt-4o-mini"}, "prompt": {"raw": "Answer: 2+2", "label": "short"}, "vars": {"q": "2+2"}, "response": {"output": "4"}, "success": true, "score": 1, "latencyMs": 120},
        {"testIdx": 1, "promptIdx": 0, "provider": {"id": "openai:gpt-4o-mini"}, "prompt": {"raw": "Answer: 3+3", "label": "short"}, "vars": {"q": "3+3"}, "response": {"output": "7"}, "success": false, "score": 0, "failureReason": 1, "gradingResult": {"pass": false, "score": 0}},
        {"testIdx": 2, "promptIdx": 0, "provider": {"id": "openai:gpt-4o-mini"}, "prompt": {"raw": "Answer: x", "label": "short"}, "vars": {"q": "x"}, "error": "timeout", "success": false, "score": 0, "failureReason": 2}
      ],
      "stats": {"successes": 1, "failures": 1, "errors": 1, "tokenUsage": {"total": 321}}},
     "config": {"description": "Invented arithmetic check"}}
    """

    @Test func promptfooResultsFile() throws {
        let s = try #require(Self.promptfoo(Self.read(Self.promptfooResults, "results.json")))
        #expect(s.evalID == "eval-test-1")
        #expect(s.version == 3)
        #expect(s.testCount == 3)
        #expect(s.passCount == 1 && s.failCount == 1 && s.errorCount == 1)
        #expect(s.providers == ["openai:gpt-4o-mini"])
        #expect(s.prompts == ["short"])
        #expect(s.totalTokens == 321)
        #expect(s.meanScore == 1.0 / 3.0)
        #expect(s.evalDescription == "Invented arithmetic check")
        #expect(s.table.rows.map { $0[4] } == ["pass", "fail", "error"])
        #expect(s.table.rows[2][3] == "timeout")
        #expect(s.headline.contains("33%"))
        #expect(s.warnings.count == 2)
    }

    @Test func promptfooMalformedAndTruncated() {
        let text = Self.promptfooResults
        #expect(Self.read(String(text.prefix(text.count / 2)), "results.json") == nil)
        #expect(Self.read("{\"results\": {\"results\": 5}}", "results.json") == nil)
        Self.survivesDamage(Array(text.utf8), name: "results.json", step: 11)
    }

    // MARK: Inspect

    static func inspectZip(header: String?, journalOnly: Bool = false) -> [UInt8] {
        var members: [(name: String, data: [UInt8], deflate: Bool)] = []
        members.append(("_journal/start.json", ascii(#"{"version": 2, "eval": {"task": "arith", "model": "mockllm/model"}}"#), false))
        if let header { members.append(("header.json", ascii(header), true)) }
        if !journalOnly {
            members.append(("summaries.json", ascii("""
            [{"id": 1, "epoch": 1, "input": "What is 2+2?", "target": "4", "scores": {"match": {"value": "C"}}},
             {"id": "two", "epoch": 1, "input": [{"role": "system", "content": "Be exact."}, {"role": "user", "content": [{"type": "text", "text": "3+3?"}]}], "target": ["6", "six"], "scores": {"match": {"value": "I"}}, "error": "boom"}]
            """), true))
            members.append(("samples/1_epoch_1.json", ascii(#"{"id": 1}"#), true))
            members.append(("samples/two_epoch_1.json", ascii(#"{"id": "two"}"#), false))
        }
        return zip(members)
    }

    static let inspectHeader = """
    {"version": 2, "status": "success",
     "eval": {"task": "arith", "model": "mockllm/model", "created": "2025-06-01T09:00:00+00:00", "dataset": {"name": "invented-sums", "samples": 2}},
     "results": {"total_samples": 2, "completed_samples": 2,
                 "scores": [{"name": "match", "scorer": "match", "metrics": {"accuracy": {"name": "accuracy", "value": 0.5}, "stderr": {"name": "stderr", "value": 0.5}}}]},
     "stats": {"started_at": "2025-06-01T09:00:00+00:00", "completed_at": "2025-06-01T09:00:02.5+00:00",
               "model_usage": {"mockllm/model": {"input_tokens": 30, "output_tokens": 4, "total_tokens": 34}}}}
    """

    @Test func inspectEvalZip() throws {
        let s = try #require(Self.inspect(Self.read(Self.inspectZip(header: Self.inspectHeader), "2025-06-01_arith.eval")))
        #expect(s.container == .evalZip)
        #expect(s.task == "arith")
        #expect(s.model == "mockllm/model")
        #expect(s.dataset == "invented-sums")
        #expect(s.sampleCount == 2 && s.completedSamples == 2)
        #expect(s.status == "success")
        #expect(s.scores == [InspectEvalSummary.Score(name: "match", scorer: "match", metrics: [
            InspectEvalSummary.Metric(name: "accuracy", value: 0.5), InspectEvalSummary.Metric(name: "stderr", value: 0.5)])])
        #expect(s.usage.first?.totalTokens == 34)
        #expect(s.samples.columns == ["ID", "Epoch", "Input", "Target", "match", "Error"])
        #expect(s.samples.rows[0] == ["1", "1", "What is 2+2?", "4", "C", ""])
        #expect(s.samples.rows[1][2] == "3+3?")
        #expect(s.samples.rows[1][3] == "6 | six")
        #expect(s.facts.contains { $0.label == "Duration" && $0.value.contains("2.5") })
        #expect(s.warnings.isEmpty)
    }

    @Test func inspectRunningMalformedAndJSONLog() throws {
        let running = try #require(Self.inspect(Self.read(Self.inspectZip(header: nil, journalOnly: true), "run.eval")))
        #expect(running.task == "arith")
        #expect(running.status == nil)

        let broken = try #require(Self.inspect(Self.read(Self.inspectZip(header: "{not json"), "bad.eval")))
        #expect(broken.task == "arith")  // falls back to the journal start
        #expect(broken.warnings.contains { $0.reason.contains("header.json") })

        let log = """
        {"version": 1, "status": "error", "eval": {"task": "qa", "model": "mock/m"}, "error": {"message": "Provider failed\\ntraceback here"},
         "samples": [{"id": 1, "epoch": 1, "input": "q", "target": "a", "scores": {"s": {"value": 1}}}]}
        """
        let s = try #require(Self.inspect(Self.read(log, "log.json")))
        #expect(s.container == .json)
        #expect(s.errorMessage == "Provider failed")
        #expect(s.warnings.contains { $0.reason.contains("Provider failed") })
        #expect(s.samples.rows.count == 1)

        let zipBytes = Self.inspectZip(header: Self.inspectHeader)
        Self.survivesDamage(zipBytes, name: "x.eval", step: 13)
    }

    // MARK: OpenTelemetry

    static let otlp = """
    {"resourceSpans": [{
      "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "agent-svc"}}]},
      "scopeSpans": [{"scope": {"name": "test"}, "spans": [
        {"traceId": "t1", "spanId": "b", "parentSpanId": "a", "name": "chat gpt-4o", "kind": 3,
         "startTimeUnixNano": "1000002000000", "endTimeUnixNano": "1000007000000",
         "attributes": [{"key": "gen_ai.operation.name", "value": {"stringValue": "chat"}},
                        {"key": "gen_ai.system", "value": {"stringValue": "openai"}},
                        {"key": "gen_ai.request.model", "value": {"stringValue": "gpt-4o"}},
                        {"key": "gen_ai.response.model", "value": {"stringValue": "gpt-4o-2024-08-06"}},
                        {"key": "gen_ai.usage.input_tokens", "value": {"intValue": "120"}},
                        {"key": "gen_ai.usage.output_tokens", "value": {"intValue": 30}}],
         "status": {"code": 1}},
        {"traceId": "t1", "spanId": "a", "parentSpanId": "", "name": "agent run", "kind": "SPAN_KIND_SERVER",
         "startTimeUnixNano": "1000000000000", "endTimeUnixNano": "1000010000000"},
        {"traceId": "t1", "spanId": "c", "parentSpanId": "a", "name": "tool lookup",
         "startTimeUnixNano": "1000008000000", "endTimeUnixNano": "1000009500000",
         "status": {"code": "STATUS_CODE_ERROR", "message": "not found"}},
        {"traceId": "t2", "spanId": "x", "parentSpanId": "y", "name": "loop x", "startTimeUnixNano": "5", "endTimeUnixNano": "6"},
        {"traceId": "t2", "spanId": "y", "parentSpanId": "x", "name": "loop y", "startTimeUnixNano": "4", "endTimeUnixNano": "9"}
      ]}]}]}
    """

    @Test func otlpWaterfallAndGenAI() throws {
        let s = try #require(Self.trace(Self.read(Self.otlp, "trace.json")))
        #expect(s.traceCount == 2)
        #expect(s.spanCount == 5)
        #expect(s.services == ["agent-svc"])
        #expect(s.genAISpanCount == 1)
        #expect(s.inputTokens == 120 && s.outputTokens == 30)
        #expect(s.models == ["gpt-4o-2024-08-06", "gpt-4o"])
        #expect(s.errorSpanCount == 1)
        let t1 = s.rows.filter { $0.traceID == "t1" }
        #expect(t1.map(\.name) == ["agent run", "chat gpt-4o", "tool lookup"])
        #expect(t1.map(\.depth) == [0, 1, 1])
        #expect(t1[1].startOffsetMs == 2 && t1[1].durationMs == 5)
        #expect(t1[0].kind == "server" && t1[1].kind == "client")
        #expect(t1[1].genAI == OTLPTraceSummary.GenAI(operation: "chat", provider: "openai", requestModel: "gpt-4o",
                                                      responseModel: "gpt-4o-2024-08-06", inputTokens: 120, outputTokens: 30))
        #expect(t1[2].status == .error && t1[2].statusMessage == "not found")
        // A parent cycle: both spans are still shown, once each.
        #expect(s.rows.filter { $0.traceID == "t2" }.count == 2)
        #expect(s.table.rows.first?[0] == "agent run")
        #expect(s.table.rows[1][0] == "  chat gpt-4o")
        #expect(s.warnings.contains { $0.reason.contains("error status") })
    }

    @Test func otlpJSONLinesAndDamage() throws {
        let compact = Self.otlp.replacingOccurrences(of: "\n", with: " ")
        let lines = compact + "\n" + compact + "\n"
        let s = try #require(Self.trace(Self.read(lines, "traces.jsonl")))
        #expect(s.spanCount == 10)
        #expect(Self.read("{\"resourceSpans\": [", "t.json") == nil)
        Self.survivesDamage(Array(Self.otlp.utf8), name: "trace.json", step: 9)
    }

    // MARK: NumPy

    @Test func npyFloatArrayWithPreview() throws {
        let bytes = Self.npyBytes(descr: "'<f8'", shape: "(2, 3)", data: Self.doubles([1, 2.5, -3, 4, 5, 6]))
        #expect(bytes.count % 64 == 48)  // header ends on a 64-byte boundary; 48 data bytes follow
        let s = try #require(Self.npy(Self.read(bytes, "weights.npy")))
        #expect(s.version == "1.0")
        #expect(s.dtype?.kind == .float && s.dtype?.itemSize == 8 && s.dtype?.byteOrder == .little)
        #expect(s.dtype?.description == "64-bit float, little-endian")
        #expect(s.shape == [2, 3])
        #expect(s.elementCount == 6)
        #expect(s.dataOffset == 128)  // magic, version, length and a ~60-character dict, padded to 64-byte blocks
        #expect(s.expectedDataBytes == 48 && s.availableDataBytes == 48)
        #expect(s.preview == ["1.0", "2.5", "-3.0", "4.0", "5.0", "6.0"])
        #expect(!s.containsPythonObjects)
        #expect(s.warnings.isEmpty)
        #expect(s.headline == "NumPy array · 2 × 3 · <f8")
    }

    @Test func npyOtherDtypesAndVersions() throws {
        let big = try #require(Self.npy(Self.read(Self.npyBytes(descr: "'>i2'", shape: "(3,)", data: [0xFF, 0xFE, 0x00, 0x05, 0x80, 0x00]), "a.npy")))
        #expect(big.preview == ["-2", "5", "-32768"])
        #expect(big.dtype?.byteOrder == .big)

        let bools = try #require(Self.npy(Self.read(Self.npyBytes(descr: "'|b1'", shape: "(2,)", data: [1, 0], major: 2), "b.npy")))
        #expect(bools.version == "2.0")
        #expect(bools.preview == ["True", "False"])

        let half = try #require(Self.npy(Self.read(Self.npyBytes(descr: "'<f2'", shape: "(2,)", data: [0x00, 0x3C, 0x00, 0xC0], major: 3), "h.npy")))
        #expect(half.preview == ["1.0", "-2.0"])

        let complex = try #require(Self.npy(Self.read(Self.npyBytes(descr: "'<c16'", shape: "(1,)", data: Self.doubles([1, -2])), "c.npy")))
        #expect(complex.preview == ["1.0-2.0j"])

        let fortran = try #require(Self.npy(Self.read(Self.npyBytes(descr: "'<u1'", shape: "(2, 2)", fortran: true, data: [1, 2, 3, 4]), "f.npy")))
        #expect(fortran.fortranOrder)
        #expect(fortran.preview == ["1", "2", "3", "4"])

        let scalar = try #require(Self.npy(Self.read(Self.npyBytes(descr: "'<i8'", shape: "()", data: Self.le(7, 8)), "s.npy")))
        #expect(scalar.shape == [] && scalar.elementCount == 1 && scalar.preview == ["7"])

        let strings = try #require(Self.npy(Self.read(Self.npyBytes(descr: "'<U3'", shape: "(1L,)", data: [UInt8](repeating: 0, count: 12)), "u.npy")))
        #expect(strings.dtype?.kind == .unicode && strings.dtype?.itemSize == 12 && strings.preview.isEmpty)
        #expect(strings.shape == [1])
    }

    @Test func npyObjectAndStructuredDtypesAreFlagged() throws {
        let object = try #require(Self.npy(Self.read(Self.npyBytes(descr: "'|O'", shape: "(2,)", data: Self.ascii("\u{80}\u{04}junk")), "o.npy")))
        #expect(object.containsPythonObjects)
        #expect(object.warnings.first?.level == .danger)
        #expect(object.preview.isEmpty)

        let structured = try #require(Self.npy(Self.read(
            Self.npyBytes(descr: "[('x', '<f4'), ('pos', '<i4', (3,)), ('meta', '|O')]", shape: "(1,)", data: []), "rec.npy")))
        #expect(structured.dtype?.kind == nil)
        #expect(structured.dtype?.fields.map(\.name) == ["x", "pos", "meta"])
        #expect(structured.dtype?.fields[1].shape == [3])
        #expect(structured.dtype?.itemSize == 4 + 12 + 8)
        #expect(structured.containsPythonObjects)
    }

    @Test func npyMalformedAndTruncated() throws {
        let good = Self.npyBytes(descr: "'<f8'", shape: "(4,)", data: Self.doubles([1, 2, 3, 4]))
        let short = try #require(Self.npy(Self.read(Array(good.prefix(good.count - 10)), "t.npy")))
        #expect(short.warnings.contains { $0.reason.contains("shorter than its header") })
        #expect(short.preview == ["1.0", "2.0"])  // 22 data bytes hold two whole doubles

        let inHeader = try #require(Self.npy(Self.read(Array(good.prefix(30)), "t.npy")))
        #expect(inHeader.dtype == nil && inHeader.shape == nil)
        #expect(!inHeader.warnings.isEmpty)

        var badHeader = good
        for i in 10..<20 { badHeader[i] = UInt8(ascii: "?") }
        #expect(Self.npy(Self.read(badHeader, "x.npy"))?.dtype == nil)
        #expect(Self.npy(Self.read([0x93] + Self.ascii("NUMPY") + [9, 0, 0, 0], "v.npy"))?.version == "9.0")
        #expect(Self.read(Self.ascii("not numpy at all"), "x.npy") == nil)
        Self.survivesDamage(good, name: "t.npy")
        Self.survivesDamage(Self.npyBytes(descr: "[('a', '<f4'), ('b', [('c', '|S2')])]", shape: "(2, 1)", data: [1, 2, 3]), name: "r.npy")
    }

    // MARK: NPZ

    @Test func npzMembers() throws {
        let a = Self.npyBytes(descr: "'<f8'", shape: "(3,)", data: Self.doubles([1, 2, 3]))
        let b = Self.npyBytes(descr: "'<i4'", shape: "(2, 2)", data: [UInt8](repeating: 1, count: 16))
        let o = Self.npyBytes(descr: "'|O'", shape: "(1,)", data: [0x80, 0x04])
        let bytes = Self.zip([("weights.npy", a, false), ("labels.npy", b, true), ("objs.npy", o, true), ("README.txt", Self.ascii("hi"), false)])
        let s = try #require(Self.npz(Self.read(bytes, "model.npz")))
        #expect(s.members.map(\.name) == ["weights", "labels", "objs"])
        #expect(s.members[0].dtype?.descr == "<f8" && s.members[0].shape == [3] && !s.members[0].compressed)
        #expect(s.members[1].shape == [2, 2] && s.members[1].compressed)
        #expect(s.members[2].containsPythonObjects)
        #expect(s.containsPythonObjects)
        #expect(s.otherFiles == 1)
        #expect(s.warnings.first?.level == .danger)
        #expect(s.table.rows[1][2] == "2 × 2")
        #expect(s.headline == "NumPy archive · 3 arrays")

        // Named .zip but holding only arrays: still an NPZ.
        #expect(Self.npz(Self.read(Self.zip([("x.npy", a, false)]), "arrays.zip"))?.members.count == 1)
        // A zip that is neither.
        #expect(Self.read(Self.zip([("notes.txt", Self.ascii("x"), false)]), "plain.zip") == nil)
    }

    @Test func npzMalformedAndTruncated() throws {
        let a = Self.npyBytes(descr: "'<f8'", shape: "(3,)", data: Self.doubles([1, 2, 3]))
        let bytes = Self.zip([("bad.npy", Self.ascii("not an array"), false), ("good.npy", a, true)])
        let s = try #require(Self.npz(Self.read(bytes, "m.npz")))
        #expect(s.members[0].problem != nil)
        #expect(s.members[1].problem == nil)
        #expect(s.warnings.contains { $0.reason.contains("could not be read") })
        #expect(Self.read(Array(bytes.prefix(bytes.count / 2)), "m.npz") == nil)  // no central directory
        Self.survivesDamage(bytes, name: "m.npz", step: 3)
    }

    // MARK: HDF5

    static let undefined = UInt64.max

    /// A message in a version 1 object header: type, size, flags, three reserved bytes, data padded to 8.
    static func msg1(_ type: Int, _ data: [UInt8]) -> [UInt8] {
        let padded = data + [UInt8](repeating: 0, count: (8 - data.count % 8) % 8)
        return le(type, 2) + le(padded.count, 2) + [0, 0, 0, 0] + padded
    }

    static func ohdr1(_ messages: [[UInt8]], count: Int? = nil) -> [UInt8] {
        let body = messages.flatMap { $0 }
        return [1, 0] + le(count ?? messages.count, 2) + le(1, 4) + le(body.count, 4) + [0, 0, 0, 0] + body
    }

    static func msg2(_ type: Int, _ data: [UInt8]) -> [UInt8] { [UInt8(type)] + le(data.count, 2) + [0] + data }

    static func ohdr2(_ messages: [[UInt8]]) -> [UInt8] {
        let body = messages.flatMap { $0 }
        return ascii("OHDR") + [2, 0, UInt8(body.count)] + body + [0, 0, 0, 0]
    }

    /// Lays pieces out in order, resolving their addresses (relative to the superblock) in a second pass.
    static func layout(_ build: ([String: UInt64]) -> [(String, [UInt8])]) -> (bytes: [UInt8], addresses: [String: UInt64]) {
        var addresses: [String: UInt64] = [:]
        var offset: UInt64 = 0
        for (name, bytes) in build([:]) {
            addresses[name] = offset
            offset += UInt64(bytes.count)
        }
        addresses["eof"] = offset
        return (build(addresses).flatMap { $0.1 }, addresses)
    }

    /// Superblock version 0, an old-style root group (symbol table, B-tree, local heap) holding a float dataset
    /// whose attribute sits in a continuation block, an empty subgroup and a soft link.
    static func hdf5V0(userBlock: Int = 0) -> [UInt8] {
        let built = layout { a in
            func A(_ k: String) -> [UInt8] { le(a[k] ?? 0, 8) }
            var sb = AIHDF5Reader.signature + [0, 0, 0, 0, 0, 8, 8, 0] + le(4, 2) + le(16, 2) + le(0, 4)
            sb += le(UInt64(userBlock), 8) + le(undefined, 8) + A("eof") + le(undefined, 8)
            sb += le(0, 8) + A("root") + le(1, 4) + le(0, 4) + A("tree") + A("heap")
            let root = ohdr1([msg1(0x11, A("tree") + A("heap"))])
            let names: [UInt8] = [UInt8](repeating: 0, count: 8) + ascii("temps\0\0\0") + ascii("sub\0\0\0\0\0")
                + ascii("alias\0\0\0") + ascii("/temps\0\0")
            let heap = ascii("HEAP") + [0, 0, 0, 0] + le(names.count, 8) + le(undefined, 8) + le((a["heap"] ?? 0) + 32, 8) + names
            let tree = ascii("TREE") + [0, 0] + le(1, 2) + le(undefined, 8) + le(undefined, 8) + le(0, 8) + A("snod") + le(8, 8)
            func entry(_ nameOffset: Int, _ header: [UInt8], cache: Int = 0, scratch: [UInt8] = []) -> [UInt8] {
                le(nameOffset, 8) + header + le(cache, 4) + le(0, 4) + scratch + [UInt8](repeating: 0, count: 16 - scratch.count)
            }
            let snod = ascii("SNOD") + [1, 0] + le(3, 2) + entry(8, A("dset")) + entry(16, A("sub"))
                + entry(24, le(undefined, 8), cache: 2, scratch: le(32, 4))
            let attribute: [UInt8] = [1, 0] + le(6, 2) + le(8, 2) + le(8, 2) + ascii("units\0\0\0")
                + [0x13, 0, 0, 0] + le(4, 4) + [1, 0, 0, 0, 0, 0, 0, 0] + ascii("degC")
            let cont = msg1(0x0C, attribute)
            let dataspace: [UInt8] = [1, 2, 0, 0, 0, 0, 0, 0] + le(3, 8) + le(4, 8)
            let datatype: [UInt8] = [0x11, 0x20, 0x3F, 0x00] + le(8, 4) + le(0, 2) + le(64, 2) + [52, 11, 0, 52] + le(1023, 4)
            let layoutMessage: [UInt8] = [3, 1] + le(undefined, 8) + le(96, 8)
            let dset = ohdr1([msg1(1, dataspace), msg1(3, datatype), msg1(8, layoutMessage),
                              msg1(0x10, A("cont") + le(cont.count, 8))], count: 5)
            let sub = ohdr1([msg1(0x11, A("tree2") + A("heap2"))])
            let tree2 = ascii("TREE") + [0, 0] + le(0, 2) + le(undefined, 8) + le(undefined, 8) + le(0, 8)
            let heap2 = ascii("HEAP") + [0, 0, 0, 0] + le(8, 8) + le(undefined, 8) + le((a["heap2"] ?? 0) + 32, 8) + [UInt8](repeating: 0, count: 8)
            return [("sb", sb), ("root", root), ("heap", heap), ("tree", tree), ("snod", snod), ("dset", dset),
                    ("cont", cont), ("sub", sub), ("tree2", tree2), ("heap2", heap2)]
        }
        return [UInt8](repeating: 0, count: userBlock) + built.bytes
    }

    /// Superblock version 2, a new-style root group of link messages: a chunked, filtered int32 dataset, a group
    /// whose links are in dense storage, a soft link and an external link.
    static func hdf5V2() -> [UInt8] {
        layout { a in
            func A(_ k: String) -> [UInt8] { le(a[k] ?? 0, 8) }
            let sb = AIHDF5Reader.signature + [2, 8, 8, 0] + le(0, 8) + le(undefined, 8) + A("eof") + A("root") + [0, 0, 0, 0]
            let linkInfo = msg2(2, [0, 0] + le(undefined, 8) + le(undefined, 8))
            func hard(_ name: String, _ target: String) -> [UInt8] { msg2(6, [1, 0, UInt8(name.utf8.count)] + ascii(name) + A(target)) }
            let soft = msg2(6, [1, 0x08, 1, 5] + ascii("alias") + le(7, 2) + ascii("/logits"))
            let external = msg2(6, [1, 0x08, 64, 3] + ascii("ext") + le(13, 2) + [0] + ascii("other.h5\0/x\0"))
            let attributeInfo = msg2(0x15, [0, 0] + le(64, 8) + le(undefined, 8))
            let root = ohdr2([linkInfo, hard("logits", "dset"), hard("layers", "grp"), soft, external, attributeInfo])
            let dataspace = msg2(1, [2, 3, 1, 1] + le(2, 8) + le(5, 8) + le(7, 8) + le(undefined, 8) + le(5, 8) + le(7, 8))
            let datatype = msg2(3, [0x10, 0x08, 0, 0] + le(4, 4) + le(0, 2) + le(32, 2))
            let chunked = msg2(8, [3, 2, 4] + le(undefined, 8) + le(1, 4) + le(5, 4) + le(7, 4) + le(4, 4))
            let filters = msg2(11, [2, 2] + le(1, 2) + le(0, 2) + le(1, 2) + le(6, 4) + le(2, 2) + le(0, 2) + le(1, 2) + le(4, 4))
            let attribute = msg2(12, [3, 0] + le(5, 2) + le(8, 2) + le(4, 2) + [0] + ascii("note\0") + [0x13, 0, 0, 0] + le(2, 4) + [2, 0, 0, 0] + ascii("hi"))
            let dset = ohdr2([dataspace, datatype, chunked, filters, attribute])
            let grp = ohdr2([msg2(2, [0, 0] + le(64, 8) + le(undefined, 8))])
            return [("sb", sb), ("root", root), ("dset", dset), ("grp", grp)]
        }.bytes
    }

    @Test func hdf5OldStyleGroups() throws {
        let s = try #require(Self.hdf5(Self.read(Self.hdf5V0(), "data.h5")))
        #expect(s.superblockVersion == 0)
        #expect(s.offsetSize == 8 && s.lengthSize == 8)
        #expect(s.objects.map(\.path) == ["/", "/temps", "/sub", "/alias"])
        #expect(s.objects[0].kind == .group)
        let temps = s.objects[1]
        #expect(temps.kind == .dataset)
        #expect(temps.shape == [3, 4])
        #expect(temps.datatype == "64-bit float, little-endian")
        #expect(temps.layout == "contiguous")
        #expect(temps.attributes == ["units"])
        #expect(temps.depth == 1)
        #expect(s.objects[2].kind == .group)
        #expect(s.objects[3].kind == .softLink("/temps"))
        #expect(s.groupCount == 2 && s.datasetCount == 1)
        #expect(s.warnings.isEmpty)
        #expect(s.headline == "HDF5 · 2 groups, 1 dataset")
        #expect(s.table.rows[1][2] == "3 × 4")
    }

    @Test func hdf5UserBlock() throws {
        let s = try #require(Self.hdf5(Self.read(Self.hdf5V0(userBlock: 512), "with-userblock.h5")))
        #expect(s.superblockOffset == 512)
        #expect(s.objects.map(\.path) == ["/", "/temps", "/sub", "/alias"])
    }

    @Test func hdf5NewStyleLinks() throws {
        let s = try #require(Self.hdf5(Self.read(Self.hdf5V2(), "model.hdf5")))
        #expect(s.superblockVersion == 2)
        #expect(s.objects.map(\.path) == ["/", "/logits", "/layers", "/alias", "/ext"])
        let logits = s.objects[1]
        #expect(logits.kind == .dataset)
        #expect(logits.shape == [2, 5, 7])
        #expect(logits.maxShape == [-1, 5, 7])
        #expect(logits.datatype == "32-bit signed integer, little-endian")
        #expect(logits.layout == "chunked (1 × 5 × 7)")
        #expect(logits.filters == ["deflate", "shuffle"])
        #expect(logits.attributes == ["note"])
        #expect(s.objects[2].kind == .group && s.objects[2].note != nil)
        #expect(s.objects[3].kind == .softLink("/logits"))
        #expect(s.objects[4].kind == .externalLink(file: "other.h5", path: "/x"))
        #expect(s.notRead.contains { $0.contains("/layers") && $0.contains("dense") })
        #expect(s.notRead.contains { $0.contains("Attributes of /") })
        #expect(s.notRead.contains { $0.contains("other.h5") })
        #expect(s.facts.contains { $0.label == "Filters" && $0.value == "deflate, shuffle" })
    }

    @Test func hdf5MalformedAndTruncated() throws {
        let v0 = Self.hdf5V0()
        // Cut after the root group's heap: the children cannot be reached.
        let cut = try #require(Self.hdf5(Self.read(Array(v0.prefix(200)), "cut.h5")))
        #expect(cut.objects.first?.path == "/")
        #expect(!cut.notRead.isEmpty || cut.objects.contains { $0.kind == .unread })

        let garbage = try #require(Self.hdf5(Self.read(AIHDF5Reader.signature + [7] + [UInt8](repeating: 0xAB, count: 60), "x.h5")))
        #expect(garbage.objects.isEmpty)
        #expect(garbage.warnings.contains { $0.reason.contains("version 7") })

        var badSizes = v0
        badSizes[13] = 3
        #expect(Self.hdf5(Self.read(badSizes, "x.h5"))?.warnings.contains { $0.reason.contains("damaged") } == true)

        #expect(Self.read(Self.ascii("plain text"), "x.h5") == nil)
        Self.survivesDamage(v0, name: "d.h5")
        Self.survivesDamage(Self.hdf5V2(), name: "d.h5")
    }

    @Test func hdf5GroupCycleIsShownOnce() throws {
        // A v2 root whose only link points back at itself.
        let bytes = Self.layout { a in
            let sb = AIHDF5Reader.signature + [2, 8, 8, 0] + Self.le(0, 8) + Self.le(Self.undefined, 8) + Self.le(a["eof"] ?? 0, 8)
                + Self.le(a["root"] ?? 0, 8) + [0, 0, 0, 0]
            let root = Self.ohdr2([Self.msg2(6, [1, 0, 4] + Self.ascii("self") + Self.le(a["root"] ?? 0, 8))])
            return [("sb", sb), ("root", root)]
        }.bytes
        let s = try #require(Self.hdf5(Self.read(bytes, "loop.h5")))
        #expect(s.objects.map(\.path) == ["/", "/self"])
        #expect(s.objects[1].note?.contains("already shown") == true)
    }

    // MARK: Dispatch

    @Test func documentAccessorsAndDispatch() throws {
        let doc = try #require(Self.read(Self.npyBytes(descr: "'|O'", shape: "(1,)", data: []), "x.npy"))
        #expect(doc.warnings.first?.level == .danger)
        #expect(doc.table == nil)
        #expect(!doc.headline.isEmpty)
        #expect(!doc.facts.isEmpty)
        #expect(Self.read(Self.ascii("PK\u{03}\u{04}junk"), "x.npz") == nil)
        #expect(Self.read(Self.ascii("hello"), "notes.txt") == nil)
        #expect(Self.read([UInt8](repeating: 0, count: 10), "x.eval") == nil)
        // The magic wins over the name.
        #expect(Self.hdf5(Self.read(Self.hdf5V2(), "renamed.bin")) != nil)
    }
}
