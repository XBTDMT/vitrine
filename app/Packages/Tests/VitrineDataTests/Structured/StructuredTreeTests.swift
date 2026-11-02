import XCTest
@testable import VitrineData

/// The flat tree model: indices, child pages, paths and how the builder applies its limits.
final class StructuredTreeTests: XCTestCase {
    func testFlatPreOrderTreeWithChildIndex() throws {
        let result = ST.parse(#"{"users":[{"name":"Ada","age":36},{"name":"Lin","tags":["x","y"]}],"ok":true}"#)
        let tree = result.tree
        XCTAssertNil(result.error)
        XCTAssertEqual(tree.roots, [0])
        XCTAssertEqual(ST.problems(tree), [])
        XCTAssertEqual(tree.count, 11)
        let users = try XCTUnwrap(ST.index(result, "$.users"))
        XCTAssertEqual(tree[users].kind, .array)
        XCTAssertEqual(tree[users].childCount, 2)
        XCTAssertEqual(tree.children(of: 0).map { tree[$0].name }, ["users", "ok"])
        let second = try XCTUnwrap(tree.child(1, of: users))
        XCTAssertEqual(tree.path(of: second), "$.users[1]")
        XCTAssertEqual(tree.children(of: second, in: 1..<5).map { tree[$0].name }, ["tags"])
        XCTAssertNil(tree.child(2, of: users))
        XCTAssertEqual(tree[second].subtreeEnd - second, 5)
        XCTAssertEqual(ST.node(result, "$.users[1].tags[1]")?.preview, "y")
        XCTAssertEqual(tree.root(of: second), 0)
    }

    func testJSONPathQuotesKeysThatAreNotIdentifiers() {
        let result = ST.parse(#"{"a b":{"x\"y":1,"$ok_1":2,"9lives":3,"":4}}"#)
        let paths = result.tree.nodes.indices.map { result.tree.path(of: $0) }
        XCTAssertEqual(paths, ["$", #"$["a b"]"#, #"$["a b"]["x\"y"]"#, #"$["a b"]["$ok_1"]"#, #"$["a b"]["9lives"]"#, #"$["a b"][""]"#])
    }

    func testQualifiedPathNamesTheDocument() throws {
        let result = ST.parse("a: 1\n---\nb: 2\n", .yaml)
        let b = try XCTUnwrap(ST.index(result, "$.b"))
        XCTAssertEqual(result.tree.qualifiedPath(of: b), "document 2: $.b")
        XCTAssertEqual(result.tree.qualifiedPath(of: b) { _ in "custom" }, "custom: $.b")
    }

    func testNodeLimitKeepsCountingForTheTotal() {
        let items = (0..<100).map(String.init).joined(separator: ",")
        let result = ST.parse("[\(items)]") { $0.maxNodes = 10 }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.tree.count, 10)
        XCTAssertEqual(result.sourceNodeCount, 101)
        XCTAssertEqual(result.coverage, .partial(shownNodes: 10, totalNodes: 101, reasons: [.nodeLimit(10)]))
        XCTAssertEqual(result.coverage.note, "Showing 10 of 101 nodes: the node limit (10) was reached.")
        let root = result.tree[0]
        XCTAssertEqual(root.childCount, 9)
        XCTAssertEqual(root.sourceChildCount, 100)
        XCTAssertTrue(root.childrenOmitted)
        XCTAssertEqual(ST.problems(result.tree), [])
    }

    func testDepthLimitCutsOneBranchAndKeepsItsSiblings() {
        let result = ST.parse(#"{"deep":[[[[[1]]]]],"next":2}"#) { $0.maxDepth = 3 }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.maxDepth, 6)
        XCTAssertEqual(result.tree.maxStoredDepth, 3)
        XCTAssertEqual(ST.node(result, "$.next")?.preview, "2")
        let cut = ST.node(result, "$.deep[0][0]")
        XCTAssertEqual(cut?.childrenOmitted, true)
        XCTAssertEqual(cut?.sourceChildCount, 1)
        XCTAssertEqual(cut?.childCount, 0)
        XCTAssertEqual(result.coverage.reasons, [.depthLimit(3)])
        XCTAssertEqual(ST.problems(result.tree), [])
    }

    func testPreviewIsCutAtACharacterBoundary() {
        let text = String(repeating: "é", count: 300)
        let result = ST.parse("\"\(text)\"") { $0.maxPreviewBytes = 11 }
        let node = result.tree[0]
        XCTAssertTrue(node.isPreviewTruncated)
        XCTAssertEqual(node.preview, String(repeating: "é", count: 5))
        let escaped = ST.parse(#""éééééé""#) { $0.maxPreviewBytes = 5 }
        XCTAssertEqual(escaped.tree[0].preview, "éé")
        XCTAssertTrue(escaped.tree[0].isPreviewTruncated)
    }

    func testSpansPointAtTheSource() throws {
        let text = "{\n  \"name\": \"Ada\",\n  \"list\": [1, 22]\n}"
        let result = ST.parse(text)
        let name = try XCTUnwrap(ST.node(result, "$.name"))
        XCTAssertEqual(name.span.line, 2)
        XCTAssertEqual(name.span.column, 11)
        let bytes = Array(text.utf8)
        let offset = Int(try XCTUnwrap(name.span.byteOffset)), length = Int(try XCTUnwrap(name.span.byteLength))
        XCTAssertEqual(String(decoding: bytes[offset..<(offset + length)], as: UTF8.self), "\"Ada\"")
        let list = try XCTUnwrap(ST.node(result, "$.list"))
        let lo = Int(list.span.byteOffset!), hi = lo + Int(list.span.byteLength!)
        XCTAssertEqual(String(decoding: bytes[lo..<hi], as: UTF8.self), "[1, 22]")
        XCTAssertEqual(result.tree[0].span.byteLength, Int64(bytes.count))
    }

    func testRollbackForgetsALine() {
        var builder = StructuredTreeBuilder(options: StructuredOptions(), pathStyle: .jsonPath)
        builder.leaf(.number, name: nil, preview: "1", span: .unknown)
        let mark = builder.mark()
        builder.open(.object, name: nil, span: .unknown)
        builder.leaf(.string, name: "a", preview: "x", span: .unknown)
        builder.rollback(to: mark)
        builder.leaf(.bool, name: nil, preview: "true", span: .unknown)
        let tree = builder.finish(inputEndedEarly: false)
        XCTAssertEqual(tree.roots, [0, 1])
        XCTAssertEqual(tree.nodes.map(\.kind), [.number, .bool])
        XCTAssertEqual(ST.problems(tree), [])
    }
}
