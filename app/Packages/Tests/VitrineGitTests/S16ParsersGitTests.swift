import Foundation
import XCTest
@testable import VitrineGit

/// S-16 hardening: hostile `.git/index` files and object stores, built byte by byte with invented content. Each used
/// to trap the preview (F35, F36) or overflow the thread stack (F37, F38, and the ignore matcher). No test runs git.
/// roadmap: S-16
final class S16ParsersGitTests: XCTestCase {
    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    /// "DIRC", the version, one entry's 62-byte fixed part (flags 0), then `tail` and a 20-byte checksum.
    private func v4Index(entryTail: [UInt8], checksumFirst: UInt8 = 0) -> [UInt8] {
        var out = Array("DIRC".utf8) + be32(4) + be32(1)
        out += [UInt8](repeating: 0, count: 24) + be32(0o100644) + [UInt8](repeating: 0, count: 8) + be32(1)
        out += [UInt8](repeating: 0x11, count: 20) + [0, 0]
        out += entryTail
        out += [checksumFirst] + [UInt8](repeating: 0, count: 19)
        return out
    }

    /// Runs `body` on a thread with a 512 KB stack, the size of a Swift-concurrency worker's, and waits for it.
    private func onSmallStack(_ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { body(); done.signal() }
        thread.stackSize = 512 * 1024
        thread.start()
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
    }

    // F35: the v4 prefix varint was read past the entries into the checksum, leaving q > end, and bytes[q..<end]
    // trapped.
    func testV4PrefixVarintCannotReadIntoTheChecksum() {
        let index = v4Index(entryTail: [])
        XCTAssertEqual(index.count, 94)
        XCTAssertThrowsError(try GitIndex.parse(index, maxEntries: 10)) { error in
            guard case GitError.truncated = error else { return XCTFail("\(error)") }
        }
    }

    // F36: a nine-byte prefix varint wrapped to a negative strip length that passed `strip <= previous.count`.
    func testV4PrefixVarintThatWouldOverflowIsMalformed() {
        let index = v4Index(entryTail: [UInt8](repeating: 0xFF, count: 8) + [0x7F] + Array("a".utf8) + [0])
        XCTAssertThrowsError(try GitIndex.parse(index, maxEntries: 10)) { error in
            guard case GitError.malformed = error else { return XCTFail("\(error)") }
        }
        var i = 0
        XCTAssertThrowsError(try GitVarint.offset([UInt8](repeating: 0xFF, count: 8) + [0x7F], &i))
        i = 0
        XCTAssertEqual(try GitVarint.offset([0x80, 0x00], &i), 128, "git's +1 per continuation")
        i = 0
        XCTAssertThrowsError(try GitVarint.offset([0x85, 0x01], &i, end: 1), "the bound is honoured")
    }

    // F37: the TREE extension was parsed by recursion, one frame per declared nesting level.
    private func indexWithTree(_ tree: [UInt8]) -> [UInt8] {
        Array("DIRC".utf8) + be32(2) + be32(0) + Array("TREE".utf8) + be32(UInt32(tree.count)) + tree
            + [UInt8](repeating: 0, count: 20)
    }

    func testDeeplyNestedCacheTreeNeitherRecursesNorHangs() throws {
        // 200,000 levels of "\0-1 1\n": an empty name, no id, one subtree each.
        let deep = [UInt8]((0..<200_000).flatMap { _ in Array("\0-1 1\n".utf8) })
        let index = indexWithTree(deep)
        let clock = ContinuousClock(), start = clock.now
        let parsed = try GitIndex.parse(index, maxEntries: 10)
        XCTAssertLessThan(clock.now - start, .seconds(2))
        XCTAssertTrue(parsed.cacheTree.isEmpty)
        onSmallStack { _ = GitIndex.parseCacheTree(deep) }
    }

    func testCacheTreeStillReadsANormalTree() throws {
        func id(_ b: UInt8) -> [UInt8] { [UInt8](repeating: b, count: 20) }
        // root(2 subtrees) → src(1) → lib(0); docs(0, out of date).
        var tree: [UInt8] = Array("\u{0}3 2\n".utf8) + id(1)
        tree += Array("src\u{0}2 1\n".utf8) + id(2)
        tree += Array("lib\u{0}1 0\n".utf8) + id(3)
        tree += Array("docs\u{0}-1 0\n".utf8)
        let parsed = try GitIndex.parse(indexWithTree(tree), maxEntries: 10)
        XCTAssertEqual(parsed.cacheTree, ["": GitObjectID(bytes: id(1))!, "src": GitObjectID(bytes: id(2))!,
                                          "src/lib": GitObjectID(bytes: id(3))!])
    }

    // F38: annotated tags were peeled by recursion with only a self-reference check: A → B → A never ended.
    func testTagCycleNamesNoCommitAndDoesNotRecurse() throws {
        let root = GitFixtures.temporaryFolder("vt-git-tagcycle")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git"), objects = git.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        let a = String(repeating: "aa", count: 20), b = String(repeating: "bb", count: 20)
        // The store never checks that content hashes to its name, so each tag may name the other.
        func writeTag(named name: String, pointingAt target: String) throws {
            let content = Array("object \(target)\ntype tag\ntag loop\ntagger Ada Example <ada@example.com> 1800000000 +0000\n\nloop\n".utf8)
            let dir = objects.appendingPathComponent(String(name.prefix(2)))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(GitFixtures.zlib(Array("tag \(content.count)\0".utf8) + content))
                .write(to: dir.appendingPathComponent(String(name.dropFirst(2))))
        }
        try writeTag(named: a, pointingAt: b)
        try writeTag(named: b, pointingAt: a)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "\(a)\n".write(to: git.appendingPathComponent("refs/heads/main"), atomically: true, encoding: .utf8)
        try "\(a)\n".write(to: git.appendingPathComponent("refs/heads/tagged"), atomically: true, encoding: .utf8)

        let repository = try XCTUnwrap(GitRepository(folder: root))
        let summary = repository.summary(.all)
        XCTAssertNil(summary.headCommit)
        XCTAssertTrue(summary.notes.contains("the current commit could not be read"), "\(summary.notes)")
        onSmallStack { _ = repository.summary() }
    }

    func testTagChainOfOrdinaryLengthStillPeels() throws {
        let root = GitFixtures.temporaryFolder("vt-git-tagchain")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git"), objects = git.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        let blob = try GitFixtures.writeLoose("blob", Array("hi\n".utf8), objects: objects)
        let tree = try GitFixtures.writeLoose("tree", GitFixtures.treeContent([("100644", "hi.txt", blob)]), objects: objects)
        let commit = try GitFixtures.writeLoose("commit", GitFixtures.commitText(tree: tree, parents: [], author: "Ada Example <ada@example.com>",
                                                                                  seconds: 1_800_000_000, subject: "Only"), objects: objects)
        var target = commit
        for n in 0..<3 {
            target = try GitFixtures.writeLoose("tag", Array("object \(target.hex)\ntype \(n == 0 ? "commit" : "tag")\ntag t\(n)\n\nt\n".utf8), objects: objects)
        }
        try "\(target.hex)\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let summary = try XCTUnwrap(GitRepository(folder: root)).summary()
        XCTAssertEqual(summary.headCommit?.id, commit, "three tags peel to the commit")
    }

    // Sibling: the ignore matcher recursed once per `*` group, up to its 20,000-step budget.
    func testIgnoreMatcherDoesNotExhaustASmallStack() {
        let pattern = Array(String(repeating: "*a", count: 12_000).utf8)
        let subject = Array(String(repeating: "a", count: 12_000).utf8)
        onSmallStack {
            var steps = 0
            _ = GitIgnore.match(pattern, 0, subject, 0, &steps)
        }
        var steps = 0
        XCTAssertTrue(GitIgnore.match(Array("*a*b".utf8), 0, Array("xaxb".utf8), 0, &steps), "ordinary patterns still match")
    }
}
