import Foundation
import XCTest
@testable import VitrineData

/// Helpers for the jq engine tests. Every input is a small invented JSON text or generated in the test.
enum JQT {
    /// One jq case: a program, an input JSON text and the outputs as compact JSON (jq -c), in order.
    struct Case {
        let program: String
        let input: String
        let expected: [String]
        let line: UInt

        init(_ program: String, _ input: String, _ expected: [String], line: UInt = #line) {
            self.program = program; self.input = input; self.expected = expected; self.line = line
        }
    }

    static func run(_ program: String, _ input: String, limits: JQLimits = .default) throws -> JQRun {
        try JQ.compile(program).run(try JQValue(json: input), limits: limits)
    }

    static func outputs(_ program: String, _ input: String) throws -> [String] {
        try run(program, input).outputs.map { $0.compactJSON() }
    }

    static func check(_ cases: [Case], file: StaticString = #filePath) {
        for c in cases {
            do {
                let run = try JQT.run(c.program, c.input)
                XCTAssertTrue(run.isComplete, "\(c.program): stopped (\(run.stoppedReason ?? ""))", file: file, line: c.line)
                XCTAssertEqual(run.outputs.map { $0.compactJSON() }, c.expected, c.program, file: file, line: c.line)
            } catch {
                XCTFail("\(c.program) on \(c.input): \(error)", file: file, line: c.line)
            }
        }
    }

    /// The error a program raises (compile or run), or nil.
    static func error(_ program: String, _ input: String = "null") -> JQError? {
        do {
            _ = try run(program, input)
            return nil
        } catch let error as JQError {
            return error
        } catch {
            return JQError(.runtime, "unexpected \(error)")
        }
    }
}
