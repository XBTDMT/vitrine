import Foundation
import Testing
import VitrineSupport
@testable import VitrineFormats

/// The module exists and links (S-21, S-23); each reader has its own suite. roadmap: S-21
@Suite struct VitrineFormatsTests {
    @Test func moduleLinks() { _ = VitrineFormats.self }

    /// The kind router names the readers' own extension lists (S-21, S-23).
    /// Agent sessions keep their own preview; other JSON Lines, MCP configs and model files go to the reader card (S-21).
    @Test func aiRoutingKeepsSessionsAndSendsTheRestToTheCard() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airoute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = dir.appendingPathComponent("s.jsonl"), batch = dir.appendingPathComponent("b.jsonl")
        try #"{"type":"user","sessionId":"invented","message":{"role":"user","content":"hi"}}"#.write(to: session, atomically: true, encoding: .utf8)
        try #"{"custom_id":"r1","method":"POST","url":"/v1/chat/completions","body":{}}"#.write(to: batch, atomically: true, encoding: .utf8)
        #expect(FileSniffer.readerKind(session) == nil)
        #expect(FileSniffer.readerKind(batch) == "aidata.file")
        #expect(FileSniffer.readerKind(URL(fileURLWithPath: "/p/.mcp.json")) == "ai.file")
        #expect(FileSniffer.readerKind(URL(fileURLWithPath: "/p/model.gguf")) == "ai.file")
        #expect(FileSniffer.readerKind(URL(fileURLWithPath: "/p/track.gpx")) == "media.file")
        #expect(FileSniffer.readerKind(URL(fileURLWithPath: "/p/invite.ics")) == "everyday.file")
    }

    @Test func routingListsAgreeWithTheReaders() {
        #expect(FileSniffer.everydayExtensions == EverydayReader.knownExtensions)
    }
}
