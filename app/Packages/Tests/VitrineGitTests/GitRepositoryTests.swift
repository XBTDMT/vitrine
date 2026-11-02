import Foundation
import VitrineSupport
import XCTest
@testable import VitrineGit

/// The repository reader against the saved sample (made once with invented content, packed with real OFS_DELTA
/// entries, two loose commits on top) and against repositories written by hand. No test runs git. roadmap: S-9
final class GitRepositoryTests: XCTestCase {
    let head = GitObjectID(hex: "ee18afa4777092ba715c05db767eb6a948eeb3b3")!
    let upstream = GitObjectID(hex: "9fd48f7e952cd9e5432e0a478888b3f018efc4ac")!

    // MARK: The sample repository

    func testSampleSummaryReadsBranchCommitsUpstreamTagAndReadme() throws {
        let repo = try GitFixtures.sample()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let git = try XCTUnwrap(GitRepository(folder: repo))
        XCTAssertEqual(git.location.layout, .standard)
        let s = git.summary(.all)
        XCTAssertEqual(s.objectFormat, .sha1)
        XCTAssertEqual(s.head, .branch("main", head), "the loose ref wins over the older packed one")
        XCTAssertEqual(s.headCommit?.subject, "Fix hero image sizes on narrow screens")
        XCTAssertEqual(s.headCommit?.author?.name, "Ada Example")
        XCTAssertEqual(s.headCommit?.author?.email, "ada@example.com")
        XCTAssertEqual(s.headCommit?.author?.timeZoneMinutes, 60)
        XCTAssertEqual(s.headCommit?.author?.date, ISO8601DateFormatter().date(from: "2026-10-28T07:05:00Z"))
        XCTAssertEqual(s.recent.map(\.subject), ["Fix hero image sizes on narrow screens", "Add hero component", "Add pricing page draft",
                                                 "Bump version to 1.1", "Write README quick start", "ci: add workflow", "Initial site scaffold"])
        XCTAssertEqual(s.upstream, "origin/main")
        XCTAssertEqual(s.ahead, 2)
        XCTAssertEqual(s.behind, 0)
        XCTAssertEqual(s.notPushed, Set(s.recent.prefix(2).map(\.id)))
        XCTAssertEqual(s.commitCount, 7)
        XCTAssertFalse(s.commitCountIsFloor)
        XCTAssertEqual(s.nearestTag, "v1.1.0", "the annotated tag, peeled through packed-refs")
        XCTAssertFalse(s.tagOnHead)
        XCTAssertEqual(s.trackedFiles, 10)
        XCTAssertEqual(s.packCount, 1)
        XCTAssertEqual(s.readme?.name, "README.md")
        XCTAssertTrue(s.readme?.text.hasPrefix("# Lumen site") == true)
        XCTAssertEqual(s.lastTouch.mapValues(\.subject), [
            "public": "Fix hero image sizes on narrow screens", "src": "Add hero component", "package.json": "Bump version to 1.1",
            "README.md": "Write README quick start", ".github": "ci: add workflow", "tsconfig.json": "Initial site scaffold",
            "astro.config.mjs": "Initial site scaffold",
        ])
        XCTAssertTrue(s.notes.isEmpty, "\(s.notes)")
    }

    func testSampleStatusMatchesGitStatusShort() throws {
        let repo = try GitFixtures.sample()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let status = try XCTUnwrap(GitRepository(folder: repo)?.summary(.status).status)
        // git status --short said: "A  .gitignore", " M src/pages/index.astro", "?? notes/" (debug.log and
        // node_modules/ are ignored).
        XCTAssertEqual(status.changes.map { "\($0.kind.rawValue) \($0.path)" }, ["A .gitignore", "? notes/", "M src/pages/index.astro"])
        XCTAssertEqual(status.count, 3)
        XCTAssertTrue(status.complete)
        XCTAssertTrue(status.untrackedCounted)
        let gitignore = try XCTUnwrap(status.changes.first)
        XCTAssertTrue(gitignore.staged)
        XCTAssertFalse(gitignore.unstaged)
        let edited = try XCTUnwrap(status.changes.last)
        XCTAssertTrue(edited.unstaged)
        XCTAssertNotNil(edited.indexID)
    }

    func testEditsAfterTheCopyAreSeenAndAnUntouchedFileIsClean() throws {
        let repo = try GitFixtures.sample()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        // Same size, different content: only the hash can tell.
        let css = repo.appendingPathComponent("public/site.css")
        var text = try String(contentsOf: css, encoding: .utf8)
        text = text.replacingOccurrences(of: "line 1 of", with: "LINE 1 of")
        try text.write(to: css, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("tsconfig.json"))
        let status = try XCTUnwrap(GitRepository(folder: repo)?.summary(.status).status)
        XCTAssertEqual(status.changes.map { "\($0.kind.rawValue) \($0.path)" },
                       ["A .gitignore", "? notes/", "M public/site.css", "M src/pages/index.astro", "D tsconfig.json"])
    }

    func testEveryPackedObjectHashesToItsName() throws {
        let repo = try GitFixtures.sample()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let packDir = repo.appendingPathComponent(".git/objects/pack")
        let idxName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: packDir.path).first { $0.hasSuffix(".idx") })
        let idx = [UInt8](try Data(contentsOf: packDir.appendingPathComponent(idxName)))
        let count = Int(idx[8 + 1020]) << 24 | Int(idx[8 + 1021]) << 16 | Int(idx[8 + 1022]) << 8 | Int(idx[8 + 1023])
        XCTAssertEqual(count, 29)
        let store = GitObjectStore(objectsDirectory: repo.appendingPathComponent(".git/objects"))
        for n in 0..<count {
            let id = try XCTUnwrap(GitObjectID(bytes: Array(idx[(8 + 1024 + n * 20)..<(8 + 1024 + n * 20 + 20)])))
            let object = try store.read(id, maxBytes: 1 << 20, depth: 0)
            XCTAssertEqual(GitObjectID.hash(type: object.type.rawValue, content: object.content), id, "object \(id.short)")
        }
        // The deepest chain in this pack is 3 (a tree), and one blob is a delta of the stylesheet.
        let tree = try store.read(GitObjectID(hex: "54f2c9b86483168d3e88145b9c2a023312602a82")!, maxBytes: 1 << 20, depth: 0)
        XCTAssertEqual(tree.type, .tree)
    }

    func testIndexVersionsTwoThreeAndFourAgree() throws {
        let repo = try GitFixtures.sample()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let v2 = try GitIndex.parse([UInt8](Data(contentsOf: repo.appendingPathComponent(".git/index"))), maxEntries: 1000)
        let v3 = try GitIndex.parse([UInt8](Data(contentsOf: GitFixtures.fixture("index-v3"))), maxEntries: 1000)
        let v4 = try GitIndex.parse([UInt8](Data(contentsOf: GitFixtures.fixture("index-v4"))), maxEntries: 1000)
        XCTAssertEqual([v2.version, v3.version, v4.version], [2, 3, 4])
        XCTAssertEqual(v2.entries.count, 10)
        XCTAssertEqual(v4.entries.map(\.path), v2.entries.map(\.path), "prefix-compressed paths expand to the same list")
        XCTAssertEqual(v4.entries.map(\.id), v2.entries.map(\.id))
        XCTAssertFalse(v2.cacheTree.isEmpty, "git writes the cache tree")
        let ita = try XCTUnwrap(v3.entries.first { $0.path == "notes/todo.md" })
        XCTAssertTrue(ita.intentToAdd, "git add -N writes version 3 with the extended flag")
        XCTAssertEqual(v3.entries.count, 11)

        // With the v3 index in place, notes/todo.md is an intended add, not an untracked folder.
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git/index"))
        try FileManager.default.copyItem(at: GitFixtures.fixture("index-v3"), to: repo.appendingPathComponent(".git/index"))
        let status = try XCTUnwrap(GitRepository(folder: repo)?.summary(.status).status)
        XCTAssertEqual(status.changes.map { "\($0.kind.rawValue) \($0.path)" }, ["A .gitignore", "A notes/todo.md", "M src/pages/index.astro"])

        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git/index"))
        try FileManager.default.copyItem(at: GitFixtures.fixture("index-v4"), to: repo.appendingPathComponent(".git/index"))
        let status4 = try XCTUnwrap(GitRepository(folder: repo)?.summary(.status).status)
        XCTAssertEqual(status4.changes.map { "\($0.kind.rawValue) \($0.path)" }, ["A .gitignore", "? notes/", "M src/pages/index.astro"])
    }

    func testBareRepositoryReadsTheReadmeFromHeadsTree() throws {
        let repo = try GitFixtures.sample()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let bare = repo.deletingLastPathComponent().appendingPathComponent("lumen.git")
        try FileManager.default.moveItem(at: repo.appendingPathComponent(".git"), to: bare)
        let git = try XCTUnwrap(GitRepository(folder: bare))
        XCTAssertEqual(git.location.layout, .bare)
        XCTAssertNil(git.location.workTree)
        let s = git.summary(.all)
        XCTAssertEqual(s.headCommit?.id, head)
        XCTAssertNil(s.status, "no work tree, no status")
        XCTAssertEqual(s.readme?.name, "README.md")
        XCTAssertTrue(s.readme?.text.contains("Lumen Notes") == true)
        XCTAssertNil(GitRepository(folder: repo), "the work tree without its .git is just a folder")
    }

    func testLinkedWorktreeFollowsGitdirAndCommondir() throws {
        let repo = try GitFixtures.sample()
        let root = repo.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let admin = repo.appendingPathComponent(".git/worktrees/feature")
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: admin.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: admin.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let wt = root.appendingPathComponent("feature")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: ../lumen-site/.git/worktrees/feature\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "# Feature\n".write(to: wt.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let git = try XCTUnwrap(GitRepository(folder: wt))
        XCTAssertEqual(git.location.layout, .gitFile)
        XCTAssertEqual(git.location.commonDir.standardizedFileURL.path, repo.appendingPathComponent(".git").standardizedFileURL.path)
        let s = git.summary(.all)
        XCTAssertEqual(s.head, .branch("main", head), "HEAD from the worktree's own folder, the ref from the shared one")
        XCTAssertEqual(s.readme?.text, "# Feature\n")
        XCTAssertNotNil(s.status, "no index of its own: everything in HEAD reads as staged deletions, without a crash")

        // A gitdir that leads nowhere is not a repository.
        try "gitdir: /nonexistent/place\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertNil(GitRepository(folder: wt))
    }

    // MARK: Hand-built repositories

    func testLooseObjectsWrittenByHand() throws {
        let root = GitFixtures.temporaryFolder("vt-git-loose")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git"), objects = git.appendingPathComponent("objects")
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        let blob = try GitFixtures.writeLoose("blob", Array("hello\n".utf8), objects: objects)
        XCTAssertEqual(blob.hex, "ce013625030ba8dba906f756967f9e9ca394464a", "git's own name for this blob")
        let tree = try GitFixtures.writeLoose("tree", GitFixtures.treeContent([("100644", "hello.txt", blob)]), objects: objects)
        let first = try GitFixtures.writeLoose("commit", GitFixtures.commitText(tree: tree, parents: [], author: "Ada Example <ada@example.com>",
                                                                                 seconds: 1_800_000_000, subject: "First"), objects: objects)
        let signed = "gpgsig -----BEGIN PGP SIGNATURE-----\n \n abc\n -----END PGP SIGNATURE-----\n"
        let second = try GitFixtures.writeLoose("commit", GitFixtures.commitText(tree: tree, parents: [first], author: "Bo Sample <bo@example.org>",
                                                                                  seconds: 1_800_000_100, subject: "Second", extraHeaders: signed), objects: objects)
        try "\(second.hex)\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        try "hello\n".write(to: root.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)

        let s = try XCTUnwrap(GitRepository(folder: root)).summary(.all)
        XCTAssertEqual(s.head, .detached(second))
        XCTAssertEqual(s.recent.map(\.subject), ["Second", "First"], "a signature header's continuation lines are skipped")
        XCTAssertEqual(s.recent.first?.author?.name, "Bo Sample")
        XCTAssertEqual(s.commitCount, 2)
        XCTAssertNil(s.upstream)
        // No index: the HEAD file is a staged deletion and the file on disk is untracked (git lists both lines;
        // the card lists the path once, as untracked, with both flags).
        let change = try XCTUnwrap(s.status?.changes.first)
        XCTAssertEqual(s.status?.count, 1)
        XCTAssertEqual(change.path, "hello.txt")
        XCTAssertEqual(change.kind, .untracked)
        XCTAssertTrue(change.staged)
    }

    func testHandBuiltPackResolvesRefAndOfsDeltas() throws {
        let root = GitFixtures.temporaryFolder("vt-git-pack")
        defer { try? FileManager.default.removeItem(at: root) }
        let objects = root.appendingPathComponent("objects")
        let a = Array("The quick brown fox jumps over the lazy dog.\n".utf8)
        let b = Array(a[0..<20]) + Array("cat sleeps.\n".utf8)
        let c = Array(b[0..<10]) + Array("red fox.\n".utf8)
        let ida = GitObjectID.hash(type: "blob", content: a), idb = GitObjectID.hash(type: "blob", content: b)
        let idc = GitObjectID.hash(type: "blob", content: c)
        try GitFixtures.writePack([
            .whole(type: 3, content: a),
            .ref(base: ida, delta: GitFixtures.delta(base: a, copy: 0..<20, insert: Array("cat sleeps.\n".utf8))),
            .ofs(baseIndex: 1, delta: GitFixtures.delta(base: b, copy: 0..<10, insert: Array("red fox.\n".utf8))),
        ], ids: [ida, idb, idc], objects: objects)
        let store = GitObjectStore(objectsDirectory: objects)
        XCTAssertEqual(store.object(ida, maxBytes: 1024)?.content, a)
        XCTAssertEqual(store.object(idb, maxBytes: 1024)?.content, b, "REF_DELTA against a named base")
        XCTAssertEqual(store.object(idc, maxBytes: 1024)?.content, c, "OFS_DELTA on top of a REF_DELTA")
        XCTAssertEqual(store.object(idc, maxBytes: 1024)?.type, .blob)
        XCTAssertNil(store.object(ida, maxBytes: 10), "over the size bound: nothing, not a crash")
        XCTAssertNil(store.object(GitObjectID(hex: String(repeating: "ab", count: 20))!, maxBytes: 1024))
    }

    func testDeltaRefusesWhatDoesNotAddUp() {
        let base = Array("0123456789".utf8)
        XCTAssertEqual(try GitDelta.apply(GitFixtures.delta(base: base, copy: 2..<5, insert: Array("xy".utf8)), to: base, maxBytes: 100),
                       Array("234xy".utf8))
        // Copies past the base, a wrong base size, a short result, the reserved opcode, a truncated insert.
        XCTAssertThrowsError(try GitDelta.apply(GitFixtures.delta(base: base, copy: 5..<15, insert: []), to: base, maxBytes: 100))
        XCTAssertThrowsError(try GitDelta.apply(GitFixtures.delta(base: base, copy: 0..<2, insert: []), to: Array(base.prefix(9)), maxBytes: 100))
        XCTAssertThrowsError(try GitDelta.apply(GitFixtures.delta(base: base, copy: 0..<2, insert: [], resultSize: 3), to: base, maxBytes: 100))
        XCTAssertThrowsError(try GitDelta.apply(GitFixtures.sizeVarint(10) + GitFixtures.sizeVarint(1) + [0], to: base, maxBytes: 100))
        XCTAssertThrowsError(try GitDelta.apply(GitFixtures.sizeVarint(10) + GitFixtures.sizeVarint(5) + [5, 0x41], to: base, maxBytes: 100))
        XCTAssertThrowsError(try GitDelta.apply(GitFixtures.delta(base: base, copy: 0..<5, insert: []), to: base, maxBytes: 4), "over the size bound")
    }

    func testHandWrittenIndexInEveryVersion() throws {
        let id = GitObjectID.hash(type: "blob", content: Array("x\n".utf8))
        let items = [GitFixtures.IndexItem(path: "src/app/main.swift", id: id, size: 2),
                     GitFixtures.IndexItem(path: "src/app/model.swift", id: id, size: 2),
                     GitFixtures.IndexItem(path: "src/lib.swift", id: id, size: 2, intentToAdd: true),
                     GitFixtures.IndexItem(path: "conflict.txt", id: id, size: 2, stage: 2)]
        for version in [3, 4] {
            let index = try GitIndex.parse(GitFixtures.index(items, version: version), maxEntries: 100)
            XCTAssertEqual(index.entries.map(\.path), ["conflict.txt", "src/app/main.swift", "src/app/model.swift", "src/lib.swift"], "v\(version)")
            XCTAssertEqual(index.entries.first?.stage, 2)
            XCTAssertEqual(index.entries.last?.intentToAdd, true)
        }
        let plain = items.map { var i = $0; i.intentToAdd = false; return i }
        let v2 = try GitIndex.parse(GitFixtures.index(plain, version: 2), maxEntries: 100)
        XCTAssertEqual(v2.entries.count, 4)
        XCTAssertEqual(v2.trackedFiles.count, 3, "the conflict stage is not a tracked file")
        let capped = try GitIndex.parse(GitFixtures.index(plain, version: 2), maxEntries: 2)
        XCTAssertEqual(capped.entries.count, 2)
        XCTAssertEqual(capped.declaredCount, 4)
        // An extended flag in a version 2 index, a cut file, a wrong signature: errors, never traps.
        XCTAssertThrowsError(try GitIndex.parse(GitFixtures.index(items, version: 2), maxEntries: 100))
        XCTAssertThrowsError(try GitIndex.parse(Array(GitFixtures.index(plain, version: 2).prefix(100)), maxEntries: 100))
        XCTAssertThrowsError(try GitIndex.parse(Array("DIRX".utf8) + [UInt8](repeating: 0, count: 40), maxEntries: 100))
    }

    // MARK: Unusual and damaged repositories

    func testSHA256RepositoryIsDetectedNotMisread() throws {
        let root = GitFixtures.temporaryFolder("vt-git-256")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try "ref: refs/heads/trunk\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "[core]\n\trepositoryformatversion = 1\n[extensions]\n\tobjectFormat = sha256\n".write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let s = try XCTUnwrap(GitRepository(folder: root)).summary(.all)
        XCTAssertEqual(s.objectFormat, .sha256)
        XCTAssertEqual(s.head.branchName, "trunk")
        XCTAssertNil(s.headCommit)
        XCTAssertTrue(s.notes.contains { $0.contains("SHA-256") })
    }

    func testDamagedRepositoriesDegradeToFewerFacts() throws {
        let repo = try GitFixtures.sample()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        let git = repo.appendingPathComponent(".git")
        // A garbage pack index, a cut index, a loose object full of noise, and a HEAD trying to leave .git.
        let packDir = git.appendingPathComponent("objects/pack")
        let idx = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: packDir.path).first { $0.hasSuffix(".idx") })
        try Data(repeating: 0x5A, count: 3000).write(to: packDir.appendingPathComponent(idx))
        let index = try Data(contentsOf: git.appendingPathComponent("index"))
        try index.prefix(200).write(to: git.appendingPathComponent("index"))
        let loose = git.appendingPathComponent("objects/ee/18afa4777092ba715c05db767eb6a948eeb3b3")
        try Data(repeating: 0x78, count: 64).write(to: loose)
        let s = try XCTUnwrap(GitRepository(folder: repo)).summary(.all)
        XCTAssertEqual(s.head.branchName, "main")
        XCTAssertNil(s.headCommit)
        XCTAssertTrue(s.notes.contains("1 pack file could not be read"))
        XCTAssertTrue(s.notes.contains("the index could not be read"))

        try "ref: refs/../../../etc/passwd\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try XCTUnwrap(GitRepository(folder: repo)).summary().head, .unknown)
        try "ref: refs/heads/a\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/b\n".write(to: git.appendingPathComponent("refs/heads/a"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/a\n".write(to: git.appendingPathComponent("refs/heads/b"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try XCTUnwrap(GitRepository(folder: repo)).summary().head, .branch("a", nil), "a symbolic loop ends")
    }

    func testAZeroTimeBudgetStopsEveryStage() throws {
        let repo = try GitFixtures.sample()
        defer { try? FileManager.default.removeItem(at: repo.deletingLastPathComponent()) }
        var limits = GitLimits.standard
        limits.timeBudget = .zero
        let s = try XCTUnwrap(GitRepository(folder: repo, limits: limits)).summary(.all)
        XCTAssertEqual(s.head.branchName, "main", "HEAD is read before any loop")
        XCTAssertTrue(s.recent.isEmpty)
        XCTAssertEqual(s.status?.complete, false)
        XCTAssertTrue(s.notes.contains("the time budget ran out"))
    }

    // MARK: Pieces

    func testIgnoreRules() {
        var ignore = GitIgnore()
        ignore.add("# comment\n*.log\n!keep.log\nbuild/\n/root-only\ndocs/**/*.tmp\n**/cache\na/**\n\\#hash\n", base: "")
        ignore.add("*.swp\n", base: "sub")
        XCTAssertTrue(ignore.isIgnored("debug.log", isDirectory: false))
        XCTAssertTrue(ignore.isIgnored("deep/x/trace.log", isDirectory: false), "an unanchored pattern matches the name at any depth")
        XCTAssertFalse(ignore.isIgnored("keep.log", isDirectory: false), "the later negation wins")
        XCTAssertTrue(ignore.isIgnored("x/build", isDirectory: true))
        XCTAssertFalse(ignore.isIgnored("x/build", isDirectory: false), "a trailing slash means directories only")
        XCTAssertTrue(ignore.isIgnored("root-only", isDirectory: false))
        XCTAssertFalse(ignore.isIgnored("x/root-only", isDirectory: false), "a leading slash anchors")
        XCTAssertTrue(ignore.isIgnored("docs/a/b/c.tmp", isDirectory: false))
        XCTAssertTrue(ignore.isIgnored("docs/c.tmp", isDirectory: false), "**/ matches zero directories")
        XCTAssertTrue(ignore.isIgnored("p/q/cache", isDirectory: true))
        XCTAssertTrue(ignore.isIgnored("a/b", isDirectory: false))
        XCTAssertFalse(ignore.isIgnored("a", isDirectory: true), "a/** is everything inside a, not a")
        XCTAssertTrue(ignore.isIgnored("#hash", isDirectory: false))
        XCTAssertTrue(ignore.isIgnored("sub/x.swp", isDirectory: false))
        XCTAssertFalse(ignore.isIgnored("x.swp", isDirectory: false), "a nested file's rules stay in its folder")
        var steps = 0
        XCTAssertTrue(GitIgnore.match(Array("[a-c]?[!x]".utf8), 0, Array("bqy".utf8), 0, &steps))
        steps = 0
        XCTAssertFalse(GitIgnore.match(Array(String(repeating: "*a", count: 40).utf8), 0, Array(String(repeating: "a", count: 60).utf8 + [0x62]), 0, &steps),
                       "a pathological pattern ends on its step budget")
    }

    func testConfigAndSignatures() {
        let c = GitConfig(text: "[Core]\n\tBare = false ; comment\n[branch \"Feature/X\"]\n\tremote = origin\n\tmerge = \"refs/heads/feature/x\"\n[remote.origin]\nurl=x\n")
        XCTAssertEqual(c.bool("core", nil, "bare"), false)
        XCTAssertEqual(c.value("branch", "Feature/X", "merge"), "refs/heads/feature/x")
        XCTAssertNil(c.value("branch", "feature/x", "remote"), "subsections are case-sensitive")
        XCTAssertEqual(c.value("remote", "origin", "url"), "x")
        let sig = GitSignature.parse("Ada Q. Example <ada@example.com> 1700000000 -0130")
        XCTAssertEqual(sig?.name, "Ada Q. Example")
        XCTAssertEqual(sig?.timeZoneMinutes, -90)
        XCTAssertNil(GitSignature.parse("no email here 12"))
        XCTAssertEqual(GitRepository.decode(Array("héllo".utf8) + [0xC3]), "héllo", "a cut character is dropped")
    }

    func testZlibStreamsThatLieAboutTheirSize() throws {
        let data = Array("tree entries and more".utf8)
        let z = GitFixtures.zlib(data)
        let src = MemorySource(z)
        XCTAssertEqual(try GitZlib.inflate(src, at: 0, expected: data.count), data)
        XCTAssertThrowsError(try GitZlib.inflate(src, at: 0, expected: data.count + 5), "the stream is shorter than declared")
        XCTAssertThrowsError(try GitZlib.inflate(src, at: 0, expected: data.count - 5), "the stream is longer than declared")
        XCTAssertThrowsError(try GitZlib.inflate(MemorySource([0x00, 0x01] + z), at: 0, expected: data.count), "not a zlib header")
        XCTAssertThrowsError(try GitZlib.inflate(MemorySource(Array(z.prefix(6))), at: 0, expected: data.count), "cut short")
        XCTAssertEqual(GitZlib.inflateAll(z, limit: 100), data)
        XCTAssertNil(GitZlib.inflateAll(z, limit: 5))
    }
}

private typealias MemorySource = MemoryByteSource
