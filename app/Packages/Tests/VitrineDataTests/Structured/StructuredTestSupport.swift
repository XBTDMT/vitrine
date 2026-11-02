import Foundation
import XCTest
@testable import VitrineData

/// Helpers for the structured-engine tests. Every fixture is generated in the test from invented values.
enum ST {
    static func parse(_ text: String, _ format: StructuredFormat = .json,
                      configure: (inout StructuredOptions) -> Void = { _ in }) -> StructuredParseResult {
        var options = StructuredOptions()
        configure(&options)
        return StructuredParser.parse(Data(text.utf8), format: format, options: options)
    }

    /// The node whose path is `path`, if any.
    static func node(_ result: StructuredParseResult, _ path: String) -> StructuredNode? {
        let tree = result.tree
        return tree.nodes.indices.first { tree.path(of: $0) == path }.map { tree[$0] }
    }

    static func index(_ result: StructuredParseResult, _ path: String) -> Int? {
        result.tree.nodes.indices.first { result.tree.path(of: $0) == path }
    }

    /// "path kind=preview" for every node, for compact whole-tree assertions.
    static func summary(_ tree: StructuredTree) -> [String] {
        tree.nodes.indices.map { i in
            let node = tree[i]
            return "\(tree.path(of: i)) \(node.kind)" + (node.preview.isEmpty ? "" : "=\(node.preview)")
        }
    }

    /// Structural problems in a tree; empty when every index, count and range agrees.
    static func problems(_ tree: StructuredTree) -> [String] {
        var issues: [String] = []
        for i in tree.nodes.indices {
            let node = tree[i]
            if let parent = node.parent {
                if parent >= i { issues.append("\(i): parent \(parent) not before it") }
                if node.depth != tree[parent].depth + 1 { issues.append("\(i): depth \(node.depth) under \(tree[parent].depth)") }
                if i >= tree[parent].subtreeEnd { issues.append("\(i): outside its parent's subtree") }
                if tree.child(node.indexInParent, of: parent) != i { issues.append("\(i): indexInParent mismatch") }
            } else {
                if node.depth != 0 { issues.append("\(i): root at depth \(node.depth)") }
                if node.indexInParent >= tree.roots.count || tree.roots[node.indexInParent] != i { issues.append("\(i): root index mismatch") }
            }
            if node.subtreeEnd <= i || node.subtreeEnd > tree.count { issues.append("\(i): subtreeEnd \(node.subtreeEnd)") }
            if node.childCount > node.sourceChildCount { issues.append("\(i): more kept children than source children") }
            if !node.kind.isContainer, node.childCount != 0 { issues.append("\(i): scalar with children") }
            let children = tree.children(of: i)
            if children.count != node.childCount { issues.append("\(i): child list length") }
            var previous = i
            for child in children {
                if child <= previous { issues.append("\(i): children out of order") }
                if tree[child].parent != i { issues.append("\(i): child \(child) has another parent") }
                if tree[child].subtreeEnd > node.subtreeEnd { issues.append("\(i): child subtree escapes") }
                previous = child
            }
        }
        return issues
    }

    /// Runs `body` on a thread with a 512 KB stack (what a secondary thread gets by default), so a parser that
    /// recursed per nesting level would crash the test run rather than pass on the main thread's 8 MB.
    static func onSmallStack(_ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
    }
}

/// A value a background thread hands back to the test.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
