import Foundation
import VitrineData
import XCTest
@testable import VitrineCompare

/// The structural JSON compare against the design's state "Two files: structural JSON" (invented config files).
/// roadmap: S-7
final class StructuralCompareTests: XCTestCase {
    private let designOld = """
    {
      "version": 2,
      "theme": "light",
      "sync": { "enabled": true, "interval": 30, "endpoint": "https://api.example.com/v1" },
      "features": ["search", "export"],
      "telemetry": false,
      "editor": { "fontSize": 14, "wrap": true }
    }
    """

    private let designNew = """
    {
      "version": 3,
      "sync": { "enabled": true, "interval": 60, "retries": 3, "endpoint": "https://api.example.com/v2" },
      "features": ["search", "export", "offline"],
      "telemetry": false,
      "editor": { "wrap": true, "fontSize": 14 },
      "shortcuts": { "quickNote": "⌥⌘N" }
    }
    """

    private func run(_ a: String, _ b: String, format: StructuredFormat = .json,
                     limits: StructuralCompareLimits = .default) throws -> StructuralComparison {
        try JSONCompare.compare(old: Data(a.utf8), new: Data(b.utf8), format: format, limits: limits)
    }

    func testDesignStateCountsAndSummary() throws {
        let r = try run(designOld, designNew)
        XCTAssertEqual(r.counts.changed, 3)
        XCTAssertEqual(r.counts.added, 3)
        XCTAssertEqual(r.counts.removed, 1)
        XCTAssertEqual(r.counts.reorderedObjects, 1)
        XCTAssertEqual(r.counts.typeChanged, 0)
        // enabled, search, export, telemetry, wrap, fontSize
        XCTAssertEqual(r.counts.unchangedValues, 6)
        XCTAssertEqual(r.summary, "3 changed · 3 added · 1 removed · 1 object reordered")
        XCTAssertFalse(r.isEqual)
        XCTAssertTrue(r.isComplete)
        XCTAssertNil(r.incompleteReason)
        XCTAssertEqual(r.format, "json")
    }

    func testDesignStateChangesInDocumentOrder() throws {
        let r = try run(designOld, designNew)
        XCTAssertEqual(r.changes.map(\.path),
                       ["version", "theme", "sync.interval", "sync.retries", "sync.endpoint", "features[2]", "shortcuts"])
        XCTAssertEqual(r.changes.map(\.kind), [.changed, .removed, .changed, .added, .changed, .added, .added])
        XCTAssertEqual(r.changes[0].old, "2"); XCTAssertEqual(r.changes[0].new, "3")
        XCTAssertEqual(r.changes[1].old, "\"light\""); XCTAssertNil(r.changes[1].new)
        XCTAssertEqual(r.changes[4].old, "\"https://api.example.com/v1\"")
        XCTAssertEqual(r.changes[4].new, "\"https://api.example.com/v2\"")
        XCTAssertEqual(r.changes[5].new, "\"offline\"")
        XCTAssertEqual(r.changes[6].new, "{\"quickNote\":\"⌥⌘N\"}")
    }

    func testDesignStateTree() throws {
        let r = try run(designOld, designNew)
        let rows = r.nodes.map { "\($0.depth) \($0.key) \($0.mark.rawValue) \($0.summary ?? "")" }
        XCTAssertEqual(rows, [
            "0 version changed ",
            "0 theme removed ",
            "0 sync changed {4} · 3 changes",
            "1 enabled same ",
            "1 interval changed ",
            "1 retries added ",
            "1 endpoint changed ",
            "0 features changed [3] · 1 added",
            "1 0 same ",
            "1 1 same ",
            "1 2 added ",
            "0 telemetry same ",
            "0 editor reorderedOnly {2} · key order only, ignored",
            "1 wrap same ",
            "1 fontSize same ",
            "0 shortcuts added {1}",
        ])
        let interval = try XCTUnwrap(r.nodes.first { $0.key == "interval" })
        XCTAssertEqual(interval.old, "30"); XCTAssertEqual(interval.new, "60"); XCTAssertEqual(interval.kind, .value)
        XCTAssertEqual(r.nodes.first { $0.key == "sync" }?.kind, .object)
        XCTAssertEqual(r.nodes.first { $0.key == "features" }?.kind, .array)
        XCTAssertEqual(r.nodes.first { $0.key == "shortcuts" }?.new, "{\"quickNote\":\"⌥⌘N\"}")
        XCTAssertEqual(r.nodes.first { $0.key == "telemetry" }?.new, "false")
    }

    func testInsertionAtArrayStartIsOneAddition() throws {
        let r = try run(#"{"items": [{"id": 1}, {"id": 2}, {"id": 3}]}"#, #"{"items": [{"id": 0}, {"id": 1}, {"id": 2}, {"id": 3}]}"#)
        XCTAssertEqual(r.counts.added, 1)
        XCTAssertEqual(r.counts.changed, 0)
        XCTAssertEqual(r.changes.map(\.path), ["items[0]"])
        XCTAssertEqual(r.changes.first?.new, #"{"id":0}"#)
    }

    func testEditedArrayElementIsComparedInside() throws {
        let r = try run(#"{"users": [{"name": "Ada", "age": 36}, {"name": "Lin", "age": 40}]}"#,
                        #"{"users": [{"name": "Ada", "age": 36}, {"name": "Lin", "age": 41}]}"#)
        XCTAssertEqual(r.changes.map(\.path), ["users[1].age"])
        XCTAssertEqual(r.changes.first?.kind, .changed)
        XCTAssertEqual(r.nodes.first { $0.key == "users" }?.summary, "[2] · 1 changed")
    }

    func testRemovedArrayElementUsesOldIndex() throws {
        let r = try run(#"["a", "b", "c"]"#, #"["a", "c"]"#)
        XCTAssertEqual(r.changes.map(\.path), ["[1]"])
        XCTAssertEqual(r.changes.first?.kind, .removed)
        XCTAssertEqual(r.changes.first?.old, "\"b\"")
    }

    func testValuesComparedByType() throws {
        let r = try run(#"{"a": 1, "b": 1.0, "c": "1", "d": [1], "e": null}"#,
                        #"{"a": 1.0, "b": 1e0, "c": 1, "d": {"0": 1}, "e": false}"#)
        XCTAssertEqual(r.changes.map(\.path), ["c", "d", "e"])
        XCTAssertEqual(r.changes.map(\.kind), [.typeChanged, .typeChanged, .typeChanged])
        XCTAssertEqual(r.counts.typeChanged, 3)
        XCTAssertEqual(r.counts.changed, 3)
        XCTAssertEqual(r.changes[0].old, "\"1\""); XCTAssertEqual(r.changes[0].new, "1")
        XCTAssertEqual(r.changes[1].old, "[1]"); XCTAssertEqual(r.changes[1].new, #"{"0":1}"#)
        XCTAssertEqual(r.changes[2].old, "null"); XCTAssertEqual(r.changes[2].new, "false")
    }

    func testIdenticalAndReorderOnly() throws {
        let same = try run(#"{"a": 1, "b": [1, 2]}"#, #"{"a": 1, "b": [1, 2]}"#)
        XCTAssertTrue(same.isEqual)
        XCTAssertEqual(same.summary, "No differences")
        XCTAssertTrue(same.changes.isEmpty)

        let reordered = try run(#"{"a": 1, "b": 2}"#, #"{"b": 2, "a": 1}"#)
        XCTAssertTrue(reordered.isEqual)
        XCTAssertEqual(reordered.summary, "1 object reordered")
        XCTAssertTrue(reordered.changes.isEmpty)
    }

    func testOddKeysAreQuotedInPaths() throws {
        let r = try run(#"{"two words": {"x-y": 1}}"#, #"{"two words": {"x-y": 2}}"#)
        XCTAssertEqual(r.changes.first?.path, #"["two words"]["x-y"]"#)
    }

    func testScalarRootAndRootTypeChange() throws {
        let r = try run("42", "43")
        XCTAssertEqual(r.changes.first?.path, "$")
        XCTAssertEqual(r.nodes.first?.key, "$")
        let t = try run("[1]", #"{"a": 1}"#)
        XCTAssertEqual(t.changes.first?.kind, .typeChanged)
        XCTAssertEqual(t.changes.first?.path, "$")
    }

    func testLongValuesAreCutAt200Characters() throws {
        let long = String(repeating: "x", count: 500)
        let r = try run(#"{"note": "a"}"#, "{\"note\": \"\(long)\"}")
        let value = try XCTUnwrap(r.changes.first?.new)
        XCTAssertEqual(value.count, 200)
        XCTAssertTrue(value.hasSuffix("…"))
    }

    func testLongStringsDifferingPastThePreviewAreStillDifferent() throws {
        let base = String(repeating: "y", count: 70_000)
        let r = try run("{\"s\": \"\(base)a\"}", "{\"s\": \"\(base)b\"}")
        XCTAssertEqual(r.counts.changed, 1)
    }

    func testMalformedSideIsNamed() {
        XCTAssertThrowsError(try run(#"{"a": 1}"#, "{\n  \"a\": 1,\n  \"b\": \n}")) { error in
            let e = error as? CompareError
            XCTAssertEqual(e?.kind, .malformed)
            XCTAssertEqual(e?.side, .new)
            XCTAssertNotNil(e?.line)
            XCTAssertTrue(e?.description.hasPrefix("The new file: ") ?? false)
        }
        XCTAssertThrowsError(try run("{nope", "{}")) { error in
            XCTAssertEqual((error as? CompareError)?.side, .old)
        }
    }

    func testXMLIsRefused() {
        XCTAssertThrowsError(try run("<a/>", "<a/>", format: .xml)) { error in
            XCTAssertEqual((error as? CompareError)?.kind, .unsupported)
        }
    }

    func testDisplayBudgetMarksIncomplete() throws {
        let r = try run(designOld, designNew, limits: .init(maxDisplayNodes: 3))
        XCTAssertEqual(r.nodes.count, 3)
        XCTAssertFalse(r.isComplete)
        XCTAssertNotNil(r.incompleteReason)
        // Counts still cover the whole document.
        XCTAssertEqual(r.summary, "3 changed · 3 added · 1 removed · 1 object reordered")
    }

    func testParseNodeBudgetMarksIncomplete() throws {
        let r = try run(designOld, designNew, limits: .init(maxParsedNodes: 4))
        XCTAssertFalse(r.isComplete)
        XCTAssertTrue(r.incompleteReason?.contains("old file") ?? false)
    }

    func testTimeBudgetMarksIncomplete() throws {
        let items = (0..<20_000).map { "{\"id\": \($0), \"v\": \($0)}" }.joined(separator: ",")
        let changed = (0..<20_000).map { "{\"id\": \($0), \"v\": \($0 + 1)}" }.joined(separator: ",")
        let r = try run("[\(items)]", "[\(changed)]", limits: .init(timeLimit: .zero))
        XCTAssertFalse(r.isComplete)
        XCTAssertTrue(r.incompleteReason?.contains("time limit") ?? false)
    }

    func testYAMLAndTOMLUseTheSamePath() throws {
        let y = try run("name: app\nreplicas: 2\nports:\n  - 80\n", "name: app\nreplicas: 3\nports:\n  - 80\n  - 443\n",
                        format: .yaml)
        XCTAssertEqual(y.changes.map(\.path), ["replicas", "ports[1]"])
        XCTAssertEqual(y.format, "yaml")
        let t = try run("[server]\nport = 80\n", "[server]\nport = 8080\nhost = \"x\"\n", format: .toml)
        XCTAssertEqual(t.changes.map(\.path), ["server.port", "server.host"])
    }

    func testPropertyListUsesTheSamePath() throws {
        func plist(_ value: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        }
        let r = try JSONCompare.compare(old: plist(["CFBundleVersion": "1", "Debug": true]),
                                        new: plist(["CFBundleVersion": "2", "Debug": true]), format: .propertyList)
        XCTAssertEqual(r.changes.map(\.path), ["CFBundleVersion"])
    }

    func testJSONLinesDocumentsAreAligned() throws {
        let r = try run("{\"a\":1}\n{\"a\":2}\n", "{\"a\":1}\n{\"a\":3}\n{\"a\":4}\n", format: .jsonLines)
        XCTAssertEqual(r.changes.map(\.path), ["document 2: a", "document 3"])
    }

    func testResultIsCodable() throws {
        let r = try run(designOld, designNew)
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(StructuralComparison.self, from: data), r)
    }
}
