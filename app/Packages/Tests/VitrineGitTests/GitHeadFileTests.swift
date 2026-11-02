import XCTest
@testable import VitrineGit

/// A file as it is in the last commit, for the code view's changed-line gutter (S-5, I-16). The repository is built
/// from invented objects by the test; no git runs. roadmap: S-5
final class GitHeadFileTests: XCTestCase {
    func testFindsTheRepositoryAboveAFileAndReadsItAtHead() throws {
        let root = GitFixtures.temporaryFolder("vt-headfile")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git"), objects = git.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        let committed = Array("struct Orbit {\n    var stops = 2\n}\n".utf8)
        let blob = try GitFixtures.writeLoose("blob", committed, objects: objects)
        let sources = try GitFixtures.writeLoose("tree", GitFixtures.treeContent([("100644", "Orbit.swift", blob)]), objects: objects)
        let tree = try GitFixtures.writeLoose("tree", GitFixtures.treeContent([("40000", "Sources", sources)]), objects: objects)
        let commit = try GitFixtures.writeLoose("commit", GitFixtures.commitText(tree: tree, parents: [], author: "Ada Example <ada@example.invalid>",
                                                                                 seconds: 1_790_000_000, subject: "Plan orbits"), objects: objects)
        try FileManager.default.createDirectory(at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try (commit.hex + "\n").write(to: git.appendingPathComponent("refs/heads/main"), atomically: true, encoding: .utf8)
        let file = root.appendingPathComponent("Sources/Orbit.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "struct Orbit {\n    var stops = 3\n}\n".write(to: file, atomically: true, encoding: .utf8)

        let found = try XCTUnwrap(GitRepository.containing(file))
        XCTAssertEqual(found.path, "Sources/Orbit.swift")
        XCTAssertEqual(found.repository.headFile(found.path), committed)
        XCTAssertNil(found.repository.headFile("Sources/Missing.swift"))
        XCTAssertNil(found.repository.headFile("Sources"), "a folder is not a file")
    }

    func testAFileOutsideAnyRepositoryHasNone() throws {
        let root = GitFixtures.temporaryFolder("vt-headfile-none")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try "lumen".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(GitRepository.containing(file)?.repository.headFile("notes.txt"))
    }
}
