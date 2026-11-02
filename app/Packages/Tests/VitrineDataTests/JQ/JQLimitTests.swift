import XCTest
@testable import VitrineData

/// Every run is bounded: outputs, steps, time, recursion, value depth, result size, and program nesting at compile
/// time. A limit stops the run with the outputs so far and says which limit it was; it is never caught by `try`.
final class JQLimitTests: XCTestCase {
    func testInfiniteRepeatStopsAtTheOutputLimit() throws {
        let run = try JQT.run("repeat(.)", "1")
        XCTAssertFalse(run.isComplete)
        XCTAssertEqual(run.outputs.count, 10_000)
        XCTAssertEqual(run.stoppedReason, "the output limit of 10000 results was reached")
    }

    func testInfiniteLoopInsideAnArrayStopsAtTheStepLimit() throws {
        var limits = JQLimits.default
        limits.maxSteps = 50_000
        let run = try JQT.run("[repeat(.)]", "1", limits: limits)
        XCTAssertFalse(run.isComplete)
        XCTAssertEqual(run.outputs, [])
        XCTAssertEqual(run.stoppedReason, "the step limit of 50000 steps was reached")
    }

    func testTimeLimit() throws {
        var limits = JQLimits.default
        limits.maxSteps = .max
        limits.timeLimit = .milliseconds(50)
        let started = ContinuousClock.now
        let run = try JQT.run("last(range(1e12))", "null", limits: limits)
        XCTAssertFalse(run.isComplete)
        XCTAssertEqual(run.stoppedReason, "the time limit of 0.05 seconds was reached")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testDeepRecursionStops() throws {
        let run = try JQT.run("def f: f + 1; f", "0")
        XCTAssertFalse(run.isComplete)
        XCTAssertEqual(run.stoppedReason, "the recursion depth limit of 512 calls was reached")

        var limits = JQLimits.default
        limits.maxDepth = 8
        let shallow = try JQT.run("def f: if . < 100 then . + 1 | f else . end; f", "0", limits: limits)
        XCTAssertEqual(shallow.stoppedReason, "the recursion depth limit of 8 calls was reached")
        XCTAssertEqual(try JQT.run("def f: if . < 100 then . + 1 | f else . end; f", "0").outputs, [.number(100)])
    }

    func testRecursionThroughOperatorsUsesLinearStack() throws {
        XCTAssertEqual(try JQT.outputs("def fib: if . < 2 then . else (. - 1 | fib) + (. - 2 | fib) end; fib", "20"), ["6765"])
        let deep = try JQT.run("def f: if . == 0 then 0 else (. - 1 | f) + 1 end; f", "500")
        XCTAssertEqual(deep.outputs, [.number(500)])
    }

    func testValueDepthIsBounded() throws {
        let run = try JQT.run("reduce range(100000) as $i (null; [.])", "null")
        XCTAssertFalse(run.isComplete)
        XCTAssertEqual(run.stoppedReason, "a value nested deeper than the depth limit of 576 levels")
        let viaObjects = try JQT.run("reduce range(100000) as $i (null; {a: .})", "null")
        XCTAssertEqual(viaObjects.stoppedReason, "a value nested deeper than the depth limit of 576 levels")
        let viaSetpath = try JQT.run(#"reduce range(100000) as $i (null; setpath(["a"]; .))"#, "null")
        XCTAssertEqual(viaSetpath.stoppedReason, "a value nested deeper than the depth limit of 576 levels")
        let longPath = try JQT.run("setpath([range(100000) | 0]; 1)", "null")
        XCTAssertEqual(longPath.stoppedReason, "a value nested deeper than the depth limit of 576 levels")
        let parsed = JQT.error("fromjson", "\"" + String(repeating: "[", count: 5000) + "\"")
        XCTAssertEqual(parsed?.kind, .runtime)
    }

    func testResultSizeIsBounded() throws {
        let repeated = try JQT.run(#""x" * 100000000"#, "null")
        XCTAssertFalse(repeated.isComplete)
        XCTAssertEqual(repeated.stoppedReason, "a string grew past the result size limit of 33554432 bytes")
        let doubling = try JQT.run(#"reduce range(40) as $i ("x"; . + .)"#, "null")
        XCTAssertEqual(doubling.stoppedReason, "a string grew past the result size limit of 33554432 bytes")
        let arrays = try JQT.run("reduce range(40) as $i ([1]; . + .)", "null")
        XCTAssertEqual(arrays.stoppedReason, "an array grew past the result size limit of 33554432 bytes")

        var limits = JQLimits.default
        limits.maxResultBytes = 1000
        let many = try JQT.run(#"range(1000) | "0123456789""#, "null", limits: limits)
        XCTAssertFalse(many.isComplete)
        XCTAssertEqual(many.stoppedReason, "the result size limit of 1000 bytes was reached")
        XCTAssertLessThan(many.outputs.count, 100)
    }

    func testOutputLimitIsExact() throws {
        var limits = JQLimits.default
        limits.maxOutputs = 5
        let stopped = try JQT.run("range(20)", "null", limits: limits)
        XCTAssertEqual(stopped.outputs.count, 5)
        XCTAssertFalse(stopped.isComplete)
        let exact = try JQT.run("range(5)", "null", limits: limits)
        XCTAssertEqual(exact.outputs.count, 5)
        XCTAssertTrue(exact.isComplete)
        XCTAssertNil(exact.stoppedReason)
    }

    func testLimitsAreNotCaughtByTry() throws {
        var limits = JQLimits.default
        limits.maxSteps = 10_000
        let run = try JQT.run("try last(range(1e9)) catch 1", "null", limits: limits)
        XCTAssertFalse(run.isComplete)
        XCTAssertEqual(run.outputs, [])
        let alt = try JQT.run("last(range(1e9)) // 1", "null", limits: limits)
        XCTAssertFalse(alt.isComplete)
    }

    func testHostileProgramsAreRefusedAtCompileTime() {
        let parens = String(repeating: "(", count: 5000) + "." + String(repeating: ")", count: 5000)
        XCTAssertEqual(JQT.error(parens)?.kind, .limit)
        let chain = "1" + String(repeating: " + 1", count: 5000)
        XCTAssertEqual(JQT.error(chain)?.kind, .limit)
        let pipes = Array(repeating: ".", count: 5000).joined(separator: " | ")
        XCTAssertEqual(JQT.error(pipes)?.kind, .limit)
        let reasonable = Array(repeating: ".a", count: 200).joined(separator: " | ")
        XCTAssertNil(JQT.error(reasonable))
    }

    func testCompileOnceRunMany() throws {
        let program = try JQ.compile(".n * 2")
        for n in 0..<50 {
            XCTAssertEqual(try program.run(.object(JQObject([("n", .number(Double(n)))]))).outputs, [.number(Double(n * 2))])
        }
    }

    /// ≈ 50 MB of invented records, generated here, parsed into a value and queried within the default limits.
    func testFiftyMegabyteInputWithinBudget() throws {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(52 * 1024 * 1024)
        bytes.append(UInt8(ascii: "["))
        var records = 0
        let bio = Array("Invented biography text for a placeholder account, only here to give each record some weight. ".utf8)
        while bytes.count < 50 * 1024 * 1024 {
            if records > 0 { bytes.append(UInt8(ascii: ",")) }
            let id = records
            bytes += Array("{\"id\":\(id),\"name\":\"user-\(id)\",\"score\":\(id % 1000).5,\"active\":\(id % 3 == 0),".utf8)
            bytes += Array("\"country\":\"c\(id % 7)\",\"tags\":[\"t\(id % 5)\",\(id % 11)],\"bio\":\"".utf8)
            bytes += bio
            bytes += Array("\"}".utf8)
            records += 1
        }
        bytes.append(UInt8(ascii: "]"))
        let parseStart = ContinuousClock.now
        let input = try JQValue(json: Data(bytes))
        let parseTime = ContinuousClock.now - parseStart
        bytes = []

        let queries: [(String, String)] = [
            ("length", "\(records)"),
            ("[.[] | select(.active)] | length", "\((records + 2) / 3)"),
            ("map(.score) | add > 0", "true"),
            ("group_by(.country) | map({c: .[0].country, n: length}) | length", "7"),
            (".[-1].id", "\(records - 1)"),
        ]
        for (query, expected) in queries {
            let start = ContinuousClock.now
            let run = try JQ.compile(query).run(input)
            XCTAssertTrue(run.isComplete, "\(query): \(run.stoppedReason ?? "")")
            XCTAssertEqual(run.outputs.map { $0.compactJSON() }, [expected], query)
            print("jq over \(records) records (50 MB, parsed in \(parseTime)): \(query) took \(ContinuousClock.now - start)")
        }
    }
}
