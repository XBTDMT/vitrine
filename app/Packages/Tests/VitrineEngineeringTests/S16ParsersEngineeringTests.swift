import Foundation
import Testing
@testable import VitrineEngineering

/// S-16 hardening: a `.proto` enum value of Int.min negated twice (F32), HAR sizes that overflow their sum (F33) and
/// a HAR time beyond Int64 (F42). Each used to trap the preview. Every fixture is invented here. roadmap: S-16
@Suite struct S16ParsersEngineeringTests {
    // MARK: F32

    @Test func protoIntegersReadSignAndMagnitudeTogether() {
        #expect(ProtoParser.integer("-9223372036854775808") == Int.min)
        #expect(ProtoParser.integer("9223372036854775807") == Int.max)
        #expect(ProtoParser.integer("9223372036854775808") == nil)
        #expect(ProtoParser.integer("-9223372036854775809") == nil)
        #expect(ProtoParser.integer("--9223372036854775808") == nil, "a second sign is not a number")
        #expect(ProtoParser.integer("+-5") == nil)
        #expect(ProtoParser.integer("-+5") == nil)
        #expect(ProtoParser.integer("0x7FFFFFFFFFFFFFFF") == Int.max)
        #expect(ProtoParser.integer("-0x8000000000000000") == Int.min)
        #expect(ProtoParser.integer("0x8000000000000000") == nil)
        #expect(ProtoParser.integer("0x-1") == nil)
        #expect(ProtoParser.integer("017") == 15)
        #expect(ProtoParser.integer("-42") == -42)
        #expect(ProtoParser.integer("0") == 0)
        #expect(ProtoParser.integer("") == nil)
    }

    @Test func protoEnumWithDoubleNegatedIntMinReadsWithoutTrapping() throws {
        let text = "syntax = \"proto3\";\nenum Edge { A = --9223372036854775808; B = -9223372036854775808; C = 1; }\n"
        let spec = try #require(APISpecReader.read(data: Data(text.utf8), fileName: "edge.proto"))
        guard case .protobuf(let s) = spec else { Issue.record("not protobuf"); return }
        let values = try #require(s.enums.first?.values)
        #expect(values.map(\.name) == ["A", "B", "C"])
        #expect(values.map(\.number) == [nil, Int.min, 1])
    }

    // MARK: F33, F42

    private func har(_ entries: String) -> HARSummary? {
        let text = "{\"log\": {\"version\": \"1.2\", \"creator\": {\"name\": \"Acme\"}, \"entries\": [\(entries)]}}"
        guard case .har(let s)? = InfraReader.read(data: Data(text.utf8), fileName: "edge.har", path: nil) else { return nil }
        return s
    }

    @Test func responseSizesThatOverflowTheirSumSaturate() throws {
        let entry = "{\"startedDateTime\": \"2026-03-01T10:00:00Z\", \"time\": 1, \"request\": {\"method\": \"GET\", \"url\": \"https://a.example/\"}, \"response\": {\"status\": 200, \"content\": {\"size\": 9223372036854775807}}}"
        let s = try #require(har("\(entry), \(entry)"))
        #expect(s.totalResponseBytes == Int.max)
        #expect(s.entries.map(\.responseSize) == [Int.max, Int.max])
    }

    @Test func aTimeBeyondAnyIntegerIsUnknownNotATrap() throws {
        let entry = "{\"startedDateTime\": \"2024-01-01T00:00:00Z\", \"time\": 1e20, \"request\": {}, \"response\": {}}"
        let s = try #require(har(entry))
        #expect(s.entries.first?.durationMs == nil, "1e20 ms is no request's duration")
        #expect(s.totalTimeMs == 0)
        #expect(s.facts.first { $0.id == "totalTime" } != nil)
        let huge = "{\"startedDateTime\": \"2024-01-01T00:00:00Z\", \"time\": 1.7e308, \"request\": {}, \"response\": {}}"
        #expect(har(huge)?.entries.first?.durationMs == nil)
        let ordinary = "{\"startedDateTime\": \"2024-01-01T00:00:00Z\", \"time\": 86400000, \"request\": {}, \"response\": {}}"
        #expect(har(ordinary)?.entries.first?.durationMs == 86_400_000, "a day-long request is still a duration")
    }

    @Test func millisecondsTextNeverTraps() {
        #expect(HARReader.millisecondsText(1010) == Duration.milliseconds(1010).formatted(.units(allowed: [.milliseconds], width: .abbreviated)))
        for value in [1e19, 1e300, Double.greatestFiniteMagnitude, Double.infinity, -1e30] {
            #expect(!HARReader.millisecondsText(value).isEmpty)
        }
    }
}
