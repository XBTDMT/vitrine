import XCTest
@testable import VitrineArchive

final class SummaryAndTreeTests: XCTestCase {
    private func listing(_ items: [(String, Int64)], format: ArchiveListing.Format = .tar(.ustar)) -> ArchiveListing {
        ArchiveListing(format: format, fileSize: 1, entries: items.map { path, size in
            ArchiveEntry(path: path, type: path.hasSuffix("/") ? .directory : .file, uncompressedSize: size)
        })
    }

    func testSummaryOfAToolMadeZip() throws {
        let folder = try FixtureFolder()
        try folder.write("album/cover.bin", noise(9_000))
        try folder.write("album/tracks/01.bin", noise(5_000))
        try folder.write("album/tracks/02.bin", noise(7_000))
        try folder.write("album/tracks/03.bin", noise(1_000))
        try folder.write("album/notes/liner.txt", "invented liner notes")
        try folder.write("album/notes/credits.txt", "nobody real")
        try folder.symlink("album/latest", to: "tracks/03.bin")
        try folder.run("/usr/bin/zip", ["-q", "-r", "-y", "album.zip", "album"])
        let summary = ArchiveSummary(try folder.list("album.zip"))

        XCTAssertEqual(summary.entryCount, 10)
        XCTAssertEqual(summary.fileCount, 6)
        XCTAssertEqual(summary.folderCount, 3)
        XCTAssertEqual(summary.symlinkCount, 1)
        XCTAssertEqual(summary.totalUncompressedSize, 22_000 + 20 + 11 + 13)
        XCTAssertNotNil(summary.totalCompressedSize)
        XCTAssertEqual(summary.largestEntries.map(\.path),
                       ["album/cover.bin", "album/tracks/02.bin", "album/tracks/01.bin", "album/tracks/03.bin",
                        "album/notes/liner.txt"])
        XCTAssertEqual(summary.topLevelFolders, ["album"])
        XCTAssertEqual(summary.singleTopFolder, "album")
    }

    func testImpliedFoldersSpillAndResourceForks() {
        let spill = ArchiveSummary(listing([("a/b/c.txt", 3), ("top.txt", 1), ("z/", 0)]))
        XCTAssertEqual(spill.folderCount, 3, "a, a/b and z")
        XCTAssertEqual(spill.topLevelFolders, ["a", "z"])
        XCTAssertEqual(spill.topLevelFiles, ["top.txt"])
        XCTAssertNil(spill.singleTopFolder)
        XCTAssertNil(spill.totalCompressedSize)

        let mac = ArchiveSummary(listing([("Photos/", 0), ("Photos/a.jpg", 10), ("__MACOSX/", 0),
                                          ("__MACOSX/Photos/._a.jpg", 4)]))
        XCTAssertEqual(mac.singleTopFolder, "Photos", "AppleDouble folders do not count against a single folder")
        XCTAssertEqual(mac.appleDoubleCount, 2)

        let dotted = ArchiveSummary(listing([("./pkg/one", 1), ("./pkg/two", 2)]))
        XCTAssertEqual(dotted.singleTopFolder, "pkg")
        XCTAssertTrue(ArchiveSummary(listing([])).largestEntries.isEmpty)
    }

    func testTreeSortsFoldersFirstCaseInsensitiveAndNumeric() {
        let paths = ["b/", "a/z.txt", "a/B.txt", "file10.txt", "file2.txt", "A.txt", "dir/sub/deep.txt", "Zeta/"]
        let tree = ArchiveTree(paths: paths)
        XCTAssertEqual(tree.children(of: tree.root).map(\.name), ["a", "b", "dir", "Zeta", "A.txt", "file2.txt", "file10.txt"])
        let a = tree.children(of: tree.root)[0]
        XCTAssertTrue(a.isImplied)
        XCTAssertEqual(tree.children(of: a).map(\.name), ["B.txt", "z.txt"])
        XCTAssertEqual(a.descendantCount, 2)
        let b = tree.children(of: tree.root)[1]
        XCTAssertFalse(b.isImplied, "b/ is a stored folder")
        XCTAssertEqual(b.entryIndex, 0)
        let deep = tree.node(at: "dir/sub/deep.txt")
        XCTAssertEqual(deep?.entryIndex, 6)
        XCTAssertEqual(deep?.depth, 3)
        XCTAssertEqual(deep.map(tree.path(of:)), "dir/sub/deep.txt")
        XCTAssertEqual(tree.root.descendantCount, 6)
        XCTAssertNil(tree.node(at: "nope"))
    }

    func testTreeFromEntriesTotalsSizesAndKeepsDuplicates() {
        let entries = listing([("src/", 0), ("src/a.swift", 100), ("src/lib/b.swift", 50), ("src/a.swift", 7),
                               ("./README", 3), ("/", 0)]).entries
        let tree = ArchiveTree(entries: entries)
        let src = tree.children(of: tree.root).first { $0.name == "src" }
        XCTAssertEqual(src?.totalSize, 157)
        XCTAssertEqual(src?.entryIndex, 0)
        XCTAssertEqual(src.map { tree.children(of: $0).filter { $0.name == "a.swift" }.count }, 2,
                       "duplicate files stay visible as siblings")
        XCTAssertEqual(tree.root.totalSize, 160)
        XCTAssertEqual(tree.node(at: "README")?.entryIndex, 4)
        for (i, node) in tree.nodes.enumerated() {
            for child in node.children { XCTAssertGreaterThan(child, i); XCTAssertEqual(tree.nodes[child].parent, i) }
        }
    }

    func testVeryDeepPathsNeedNoRecursion() {
        let deep = Array(repeating: "d", count: 30_000).joined(separator: "/") + "/leaf.txt"
        let tree = ArchiveTree(paths: [deep])
        XCTAssertEqual(tree.nodes.count, 30_002)
        XCTAssertEqual(tree.nodes.last?.depth, 30_001)
        XCTAssertEqual(tree.root.descendantCount, 1)
        XCTAssertEqual(tree, ArchiveTree(paths: [deep]))
        XCTAssertEqual(tree.nodes.last.map(tree.path(of:)), deep)
    }

    func testDeepNamesCostTheirLengthInTheSummary() {
        // A zip name can be 64 KB: about 32,000 segments. Counting folders by joined prefixes would build a
        // gigabyte of strings for one such entry; the summary must stay linear.
        let deep = Array(repeating: "x", count: 32_000).joined(separator: "/") + "/end.bin"
        let entries = (0..<20).map { ArchiveEntry(path: "\($0)/" + deep, type: .file, uncompressedSize: 1) }
        let clock = ContinuousClock()
        var summary: ArchiveSummary?
        let time = clock.measure { summary = ArchiveSummary(ArchiveListing(format: .zip, fileSize: 1, entries: entries)) }
        XCTAssertEqual(summary?.folderCount, 20 * 32_001)
        XCTAssertLessThan(time, .seconds(10))
    }

    func testFileSourceRefusesSpecialFiles() throws {
        let folder = try FixtureFolder()
        try folder.run("/usr/bin/mkfifo", ["pipe"])
        assertArchiveError(try FileByteSource(url: folder.path("pipe")), matching: {
            if case .unreadable = $0 { true } else { false }
        }, "a FIFO must be refused without blocking")
        assertArchiveError(try FileByteSource(url: folder.url), matching: {
            if case .unreadable = $0 { true } else { false }
        })
    }
}
