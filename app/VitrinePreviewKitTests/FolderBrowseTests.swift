import AppKit
import XCTest
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineSupport

/// The folder family's browse features (S-9): arrangement and Finder tags (O-2), the icon grid (O-1), the
/// background count, the storage overview and navigation (N-10), the peek drawer, skill folders (P-5), the
/// repository's languages (E-6) and the bounded-honesty lines (R-4). Every folder is invented in a temp folder;
/// no test runs git. roadmap: S-9
@MainActor
final class FolderBrowseTests: XCTestCase {
    private var made: [URL] = []

    override func tearDown() {
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
        FolderNode.cap = 5_000
        FolderView.sizerBudget = FolderSizer.Budget()
        FolderIcons.thumbnailsEnabled = true
        FolderRenderer.firstPaintWait = .milliseconds(250)
        super.tearDown()
    }

    /// A temp folder holding `files` (path → text); paths ending in "/" are folders.
    private func folder(_ files: [String: String], name: String = "lumen-workspace") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vt-browse-\(UUID().uuidString)").appendingPathComponent(name)
        made.append(root.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            if path.hasSuffix("/") { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    private func render(_ url: URL) async throws -> (FolderRenderer, RenderedPreview, FolderView) {
        let renderer = FolderRenderer()
        let preview = try await renderer.render(url: url, kind: .folder, context: RenderContext(appearance: .light, defaultsSuite: "vt-browse"))
        return (renderer, preview, try XCTUnwrap(renderer.viewForTesting))
    }

    private func node(_ name: String, folder: Bool = false, size: Int64 = 0, kind: String = "Document", modified: Date? = nil,
                      added: Date? = nil, tags: [FinderTag] = []) -> FolderNode {
        FolderNode(url: URL(fileURLWithPath: "/tmp/vt-invented/\(name)"), isFolder: folder, size: size, kind: kind, modified: modified, added: added, tags: tags)
    }

    // MARK: O-2 sort and group

    func testGroupsByDateAddedNewestFirstWithCounts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_000_000)          // 2026-10-26 (a Monday), UTC
        let day: TimeInterval = 86_400
        let nodes = [node("orbit-sdk.zip", added: now.addingTimeInterval(-3_600)),
                     node("lumen-notes.md", added: now.addingTimeInterval(-day)),
                     node("quarterly-orders.csv", added: now.addingTimeInterval(-day - 60)),
                     node("OrbitPlanner.swift", added: now.addingTimeInterval(-4 * day)),
                     node("fieldwork.dmg", added: now.addingTimeInterval(-60 * day)),
                     node("old-sketch.png", added: now.addingTimeInterval(-400 * day)),
                     node("undated.txt")]
        var a = FolderArrangement()
        a.sort = .added
        a.ascending = false
        a.group = .added
        let rows = a.rows(nodes, size: { $0.size }, now: now, calendar: calendar)
        let headers = rows.compactMap { if case .group(let t, let c) = $0 { "\(t) \(c)" } else { nil } }
        XCTAssertEqual(headers, ["Today 1", "Yesterday 2", "Previous 7 Days 1", calendar.standaloneMonthSymbols[7] + " 1", "2025 1", "No Date 1"])
        let names = rows.compactMap { if case .node(let n) = $0 { n.name } else { nil } }
        XCTAssertEqual(names.prefix(3), ["orbit-sdk.zip", "lumen-notes.md", "quarterly-orders.csv"], "newest first inside each group")
        XCTAssertEqual(a.dateColumn, .added, "the date column follows the arrangement")
    }

    func testSortsBySizeKindAndTags() {
        let nodes = [node("b-folder", folder: true, kind: "Folder"), node("small.txt", size: 10, kind: "Plain Text"),
                     node("big.mov", size: 9_000, kind: "QuickTime movie"),
                     node("tagged.csv", size: 500, kind: "CSV text", tags: [FinderTag(name: "Lumen", color: 4)])]
        var a = FolderArrangement()
        a.sort = .size
        a.ascending = false
        XCTAssertEqual(a.sorted(nodes, size: { $0.isFolder ? nil : $0.size }).map(\.name), ["big.mov", "tagged.csv", "small.txt", "b-folder"],
                       "largest first, a folder still counted goes last")
        a.ascending = true
        XCTAssertEqual(a.sorted(nodes, size: { $0.isFolder ? 1_000 : $0.size }).map(\.name), ["small.txt", "tagged.csv", "b-folder", "big.mov"])
        a.sort = .tags
        XCTAssertEqual(a.sorted(nodes, size: { $0.size }).first?.name, "tagged.csv", "tagged items before untagged")
        a.group = .kind
        a.sort = .name
        let groups = a.rows(nodes, size: { $0.size }).compactMap { if case .group(let t, _) = $0 { t } else { nil } }
        XCTAssertEqual(groups, ["CSV text", "Folder", "Plain Text", "QuickTime movie"])
        a.group = .size
        let sizeGroups = a.rows(nodes, size: { $0.isFolder ? nil : $0.size }).compactMap { if case .group(let t, _) = $0 { t } else { nil } }
        XCTAssertEqual(sizeGroups, ["Less Than 100 KB", "Size Not Known Yet"])
    }

    func testHeaderClickSortsAndShowsTheChevron() async throws {
        let url = try folder(["alpha.txt": "a", "beta.txt": String(repeating: "b", count: 4_000), "gamma/": ""])
        let (renderer, _, _) = try await render(url)
        let outline = try XCTUnwrap(renderer.outlineForTesting)
        let size = try XCTUnwrap(outline.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("size")))
        XCTAssertNotNil(outline.table.indicatorImage(in: try XCTUnwrap(outline.table.tableColumn(withIdentifier: .init("name")))), "sorted by name at first")
        outline.table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        XCTAssertEqual(outline.arrangement.sort, .size)
        XCTAssertFalse(outline.arrangement.ascending)
        XCTAssertNotNil(outline.table.indicatorImage(in: size), "the clicked header carries the chevron")
        XCTAssertEqual((outline.table.item(atRow: 0) as? FolderNode)?.name, "beta.txt")
    }

    func testFinderTagsKeepTheirColours() async throws {
        let url = try folder(["receipt-0192.pdf": "x", "plain.txt": "y"])
        let tagged = url.appendingPathComponent("receipt-0192.pdf")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Lumen\n6", "Draft"], format: .binary, options: 0)
        let status = plist.withUnsafeBytes { setxattr(tagged.path, FinderTag.attribute, $0.baseAddress, plist.count, 0, 0) }
        XCTAssertEqual(status, 0)
        XCTAssertEqual(FinderTag.parse(plist), [FinderTag(name: "Lumen", color: 6), FinderTag(name: "Draft", color: 0)])
        let (renderer, _, _) = try await render(url)
        let outline = try XCTUnwrap(renderer.outlineForTesting)
        let receipt = try XCTUnwrap(outline.root.children().first { $0.name == "receipt-0192.pdf" })
        XCTAssertEqual(receipt.tags, [FinderTag(name: "Lumen", color: 6), FinderTag(name: "Draft", color: 0)])
        XCTAssertEqual(receipt.tags.first?.nsColor, .systemRed)
        XCTAssertEqual(outline.root.children().first { $0.name == "plain.txt" }?.tags, [])
    }

    // MARK: N-10 sizes, overview, navigation

    func testAHardLinkedFileCountsOnce() throws {
        let url = try folder(["photos/lisbon.png": String(repeating: "p", count: 400), "notes.md": String(repeating: "m", count: 50)])
        // A second name for the same bytes, inside the folder and at its top (as Time Machine and package managers make).
        try FileManager.default.linkItem(at: url.appendingPathComponent("photos/lisbon.png"), to: url.appendingPathComponent("photos/lisbon-copy.png"))
        try FileManager.default.linkItem(at: url.appendingPathComponent("photos/lisbon.png"), to: url.appendingPathComponent("lisbon-top.png"))
        let sizes = FolderSizer.measure(url)
        XCTAssertEqual(sizes.totalBytes, 450, "the 400 bytes are on disk once")
        XCTAssertEqual(sizes.totalItems, 5, "every name is still an item")
    }

    func testSizerCountsByKindAndSaysWhenItStopped() throws {
        let url = try folder(["OrbitPlanner.swift": String(repeating: "s", count: 300), "docs/lumen-notes.md": String(repeating: "m", count: 200),
                              "docs/deep/diagram.png": String(repeating: "p", count: 100), ".hidden-cache": "hh"])
        let full = FolderSizer.measure(url)
        XCTAssertTrue(full.complete)
        XCTAssertEqual(full.totalBytes, 602)
        XCTAssertEqual(full.totalItems, 6, "files, the folders inside and the hidden file")
        XCTAssertEqual(full.children["docs"], FolderSizes.Entry(bytes: 300, items: 3, complete: true))
        XCTAssertEqual(full.byKind["kind-code"]?.bytes, 300)
        XCTAssertEqual(full.byKind["kind-image"]?.items, 1)
        XCTAssertEqual(FolderOverview.totalText(full, limit: 10), ByteCountFormatter.string(fromByteCount: 602, countStyle: .file) + " in 6 items")

        var snapshots = 0
        let cut = FolderSizer.measure(url, budget: FolderSizer.Budget(maxItems: 2, time: .seconds(5), reportEvery: 1), progress: { _ in snapshots += 1 })
        XCTAssertTrue(cut.finished)
        XCTAssertFalse(cut.complete, "past the budget the totals are floors")
        XCTAssertTrue(FolderOverview.totalText(cut, limit: 2).hasPrefix("At least"))
        XCTAssertEqual(FolderRenderer.sizeText(cut).prefix(8), "at least")
        XCTAssertGreaterThan(snapshots, 1, "progress goes out while counting")
        let cancelled = FolderSizer.measure(url, budget: FolderSizer.Budget(maxItems: 1_000, time: .seconds(5), reportEvery: 1_000), isCancelled: { true })
        XCTAssertTrue(cancelled.finished)
        XCTAssertFalse(cancelled.complete, "a cancelled count is a floor")
        XCTAssertEqual(cancelled.totalItems, 0)
    }

    func testSizesArriveAfterTheFirstPaint() async throws {
        let url = try folder(["lumen-brand-kit/logo.svg": String(repeating: "l", count: 1_000), "lumen-brand-kit/fonts/Lumen.otf": String(repeating: "f", count: 2_000),
                              "quarterly-orders.csv": String(repeating: "c", count: 500)])
        let (renderer, preview, view) = try await render(url)
        XCTAssertNil(preview.document.fact("size"), "the first paint never waits for the count")
        await view.waitForSizing()
        let total = ByteCountFormatter.string(fromByteCount: 3_500, countStyle: .file)
        XCTAssertEqual(preview.document.fact("size")?.value, total, "the pill learns the total when the count lands")
        let outline = try XCTUnwrap(renderer.outlineForTesting)
        let kit = try XCTUnwrap(outline.root.children().first { $0.name == "lumen-brand-kit" })
        XCTAssertEqual(outline.text(for: kit, column: "size"), ByteCountFormatter.string(fromByteCount: 3_000, countStyle: .file))
        XCTAssertNil(view.gutterStatus(), "nothing left to say once everything is counted and shown")
    }

    func testOverviewOpensInPlaceAndLeadsIntoSubfolders() async throws {
        let url = try folder(["conference-talks/keynote.mov": String(repeating: "k", count: 4_000), "screenshots/one.png": String(repeating: "o", count: 900),
                              "fieldwork.dmg": String(repeating: "d", count: 3_000), "lumen-notes.md": "notes"])
        let (renderer, preview, view) = try await render(url)
        await view.waitForSizing()
        XCTAssertTrue(view.overview.isHidden)
        view.hairline.onToggle?()
        XCTAssertFalse(view.overview.isHidden, "the hairline opens the overview in place")
        XCTAssertTrue(view.hairline.isHidden)
        XCTAssertEqual(view.overview.largestNames, ["conference-talks", "fieldwork.dmg", "screenshots", "lumen-notes.md"])
        XCTAssertEqual(view.overview.folderNames, ["conference-talks", "screenshots"])
        XCTAssertTrue(view.overview.totalLine.hasSuffix("in 6 items"), view.overview.totalLine)
        var pushed: [PreviewDocument] = []
        preview.documentChanged = { pushed.append($0) }
        let talks = try XCTUnwrap(renderer.outlineForTesting?.root.children().first { $0.name == "conference-talks" })
        view.open(talks)
        XCTAssertEqual(view.pathRow.titles.suffix(2), ["lumen-workspace", "conference-talks"])
        XCTAssertEqual(renderer.outlineForTesting?.root.children().map(\.name), ["keynote.mov"])
        XCTAssertEqual(pushed.last?.searchText, "keynote.mov", "the pill and copy text follow the place")
        view.pathRow.activateCrumb(0)
        XCTAssertTrue(view.trail.isEmpty, "the first crumb leads back out")
        XCTAssertEqual(renderer.outlineForTesting?.root.url, url)
        view.toggleOverview()
        XCTAssertTrue(view.overview.isHidden)
    }

    func testHugeFolderSaysHowMuchItShows() async throws {
        FolderNode.cap = 3
        let url = try folder(Dictionary(uniqueKeysWithValues: (1...7).map { ("orbit-\($0).log", "x") }))
        let (_, preview, view) = try await render(url)
        XCTAssertEqual(preview.document.coverage, .partial(shown: 3, total: 7, unit: .members, reason: "Large folder"))
        XCTAssertEqual(preview.document.fact("headline")?.value, "7 items")
        XCTAssertEqual(view.gutterStatus()?.leading, "3 of 7 items")
    }

    // MARK: O-1 icons

    func testIconsViewIsTheSecondView() async throws {
        FolderIcons.thumbnailsEnabled = false
        let url = try folder(["OrbitPlanner.swift": "let x = 1", "sketch.png": "p", "drafts/": ""])
        let (_, preview, view) = try await render(url)
        XCTAssertEqual(preview.document.viewTitles, ["List", "Icons"])
        XCTAssertEqual(preview.showView?(1), true)
        XCTAssertNotNil(view.icons.scroll.superview)
        XCTAssertNil(view.scroll.superview, "the list leaves while the grid shows")
        XCTAssertEqual(view.icons.grid.numberOfItems(inSection: 0), 3)
        XCTAssertEqual(view.icons.nodes.map(\.name), ["drafts", "OrbitPlanner.swift", "sketch.png"])
        XCTAssertEqual(preview.showView?(0), true)
        XCTAssertNotNil(view.scroll.superview)
        let png = try XCTUnwrap(view.outline.root.children().first { $0.name == "sketch.png" })
        let swift = try XCTUnwrap(view.outline.root.children().first { $0.name == "OrbitPlanner.swift" })
        XCTAssertTrue(FolderIcons.wantsThumbnail(png))
        XCTAssertFalse(FolderIcons.wantsThumbnail(swift))
        let cloud = FolderNode(url: url.appendingPathComponent("trip.heic"), isFolder: false, size: 10, kind: "HEIF image", isCloudOnly: true)
        XCTAssertFalse(FolderIcons.wantsThumbnail(cloud), "an iCloud placeholder is never thumbnailed (that would download it)")
        do { _ = try await cloud.loadPeek(maxBytes: 10); XCTFail("a placeholder is never read") } catch {}
    }

    // MARK: Peek

    func testPeekReadsTextImagesAndFacts() throws {
        let url = try folder(["OrbitPlanner.swift": "struct OrbitPlanner {}\n", "lumen-notes.md": "# Lumen\n\nNotes.\n",
                              "big.log": String(repeating: "line\n", count: 20_000)])
        guard case .text(let code, let md, _, _) = PeekContent.make(name: "OrbitPlanner.swift", payload: .file(url.appendingPathComponent("OrbitPlanner.swift"))) else {
            return XCTFail("code is text")
        }
        XCTAssertEqual(code, "struct OrbitPlanner {}\n")
        XCTAssertFalse(md)
        guard case .text(_, true, _, _) = PeekContent.make(name: "lumen-notes.md", payload: .file(url.appendingPathComponent("lumen-notes.md"))) else {
            return XCTFail("Markdown is drawn in the README styles")
        }
        guard case .text(_, _, let shown, let total) = PeekContent.make(name: "big.log", payload: .file(url.appendingPathComponent("big.log"))) else {
            return XCTFail("a log is text")
        }
        XCTAssertEqual(shown, PeekContent.maxTextBytes, "bounded to the first 64 KB")
        XCTAssertEqual(total, 100_000)
        guard case .text(let member, _, let memberShown, let memberTotal) = PeekContent.make(name: "member.txt", payload: .data(Data("hello".utf8), total: 4_000)) else {
            return XCTFail("bytes from an archive member peek the same way")
        }
        XCTAssertEqual(member, "hello")
        XCTAssertEqual(memberShown, 5)
        XCTAssertEqual(memberTotal, 4_000)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        guard case .image(let image) = PeekContent.make(name: "swatch.png", payload: .data(png, total: nil)) else { return XCTFail("an image") }
        XCTAssertEqual(image.cgImage.width, 4)
        guard case .facts = PeekContent.make(name: "blob.bin", payload: .data(Data([0, 1, 2, 0, 255]), total: nil)) else { return XCTFail("binary gets facts") }
        guard case .facts = PeekContent.make(name: "drafts", payload: .file(url)) else { return XCTFail("a folder gets facts") }
    }

    func testPeekDrawerFollowsTheListAndEscapeCloses() async throws {
        let url = try folder(["a-OrbitPlanner.swift": "let orbit = 1\n", "b-lumen-notes.md": "# Lumen\n", "c-readme.txt": "plain words\n"])
        let (renderer, _, view) = try await render(url)
        var gutters: [GutterStatus?] = []
        view.onGutter = { gutters.append($0) }
        let outline = try XCTUnwrap(renderer.outlineForTesting)
        let first = try XCTUnwrap(outline.root.children().first)
        view.peek(first)
        XCTAssertFalse(view.drawer.isHidden)
        await view.drawer.waitForLoad()
        XCTAssertEqual(view.drawer.headerText.name, "a-OrbitPlanner.swift")
        guard case .text("let orbit = 1\n", false, _, _)? = view.drawer.content else { return XCTFail("the code shows as text") }
        XCTAssertEqual(gutters.last??.trailing, "esc back to the list")
        view.drawer.onStep?(1)                                  // ↓ in the drawer: the list moves, the drawer follows
        await view.drawer.waitForLoad()
        XCTAssertEqual(outline.selectedNode?.name, "b-lumen-notes.md")
        XCTAssertEqual(view.drawer.headerText.name, "b-lumen-notes.md")
        guard case .text(_, true, _, _)? = view.drawer.content else { return XCTFail("Markdown in the README styles") }
        XCTAssertEqual(outline.table.onEscape?(), true, "escape closes the peek")
        XCTAssertTrue(view.drawer.isHidden)
        XCTAssertEqual(outline.table.onEscape?(), false, "with the peek closed, escape is Quick Look's again")
    }

    /// The drawer and the overview fit a short panel: nothing is pushed out of view, the window keeps its size.
    func testDrawerAndOverviewFitAShortPanel() async throws {
        let url = try folder(["SKILL.md": "---\nname: orbit-helper\ndescription: Plans orbits for invented tests.\n---\n", "scripts/plan.sh": "echo hi\n",
                              "OrbitPlanner.swift": "let x = 1\n", "docs/lumen-notes.md": "# Notes\n"])
        let (_, preview, view) = try await render(url)
        await view.waitForSizing()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        let host = try XCTUnwrap(window.contentView)
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(preview.view)
        NSLayoutConstraint.activate([
            preview.view.leadingAnchor.constraint(equalTo: host.leadingAnchor), preview.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            preview.view.topAnchor.constraint(equalTo: host.topAnchor), preview.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        view.toggleOverview()
        view.peek(try XCTUnwrap(view.outline.root.children().first { $0.name == "OrbitPlanner.swift" }))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.height, 300)
        XCTAssertEqual(preview.view.frame, NSRect(x: 0, y: 0, width: 640, height: 300))
        for sub in preview.view.subviews where !sub.isHidden {
            XCTAssertTrue(preview.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(sub.frame), "\(type(of: sub)) at \(sub.frame) is outside \(preview.view.bounds)")
        }
        XCTAssertEqual(view.drawer.frame.width, PeekDrawer.width(for: 640))
        XCTAssertEqual(view.drawer.frame.minX, 640 - PeekDrawer.width(for: 640), "the drawer sits beside the list, which stays in view")
    }

    // MARK: P-5 skill folders

    func testSkillFolderGetsAHeaderCard() async throws {
        let url = try folder(["SKILL.md": "---\nname: orbit-helper\ndescription: >\n  Plans orbits for\n  invented tests.\n---\n\n# Orbit helper\n",
                              "scripts/plan.sh": "echo plan\n", "helper.py": "print(1)\n", "reference/lumen-notes.md": "notes\n"])
        let info = try XCTUnwrap(SkillInfo.read(url))
        XCTAssertEqual(info.name, "orbit-helper")
        XCTAssertEqual(info.description, "Plans orbits for invented tests.")
        XCTAssertEqual(info.scripts, ["helper.py", "scripts/plan.sh"])
        XCTAssertEqual(info.fileCount, 4)
        XCTAssertEqual(info.shipsLine, "4 files · 2 scripts")
        let (_, _, view) = try await render(url)
        XCTAssertEqual(view.skillCard?.info, info)

        let agents = try folder(["AGENTS.md": "# Lumen agents\n\nKeep the **notes** short and invented.\n\n- one\n"], name: "lumen-agents")
        let a = try XCTUnwrap(SkillInfo.read(agents))
        XCTAssertEqual(a.badge, "Agent instructions")
        XCTAssertEqual(a.name, "lumen-agents")
        XCTAssertEqual(a.description, "Keep the notes short and invented.")
        XCTAssertNil(SkillInfo.read(try folder(["plain.txt": "x"])))
    }

    func testRepositoryKeepsItsPageOverAgentInstructions() async throws {
        let root = try FolderRepositoryTests.makeRepository()
        made.append(root)
        try "# Claude\n\nInvented instructions.\n".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        FolderRenderer.firstPaintWait = .seconds(5)
        let (_, _, view) = try await render(root)
        XCTAssertNil(view.skillCard, "a repository's page is its README; no second header card")
        XCTAssertNotNil(view.repository)
    }

    // MARK: E-6 the repository's language bar and path

    func testRepositoryLanguagesAndPathRow() async throws {
        let shares = RepositoryLanguage.shares(["Swift": 460, "Markdown": 310, "Shell": 180, "YAML": 30, "JSON": 20])
        XCTAssertEqual(shares.map(\.name), ["Swift", "Markdown", "Shell", "Other"])
        XCTAssertEqual(shares.map(\.token), ["series-1", "series-2", "series-3", "kind-other"])
        XCTAssertEqual(shares.last?.share ?? 0, 0.05, accuracy: 0.0001)

        let root = try FolderRepositoryTests.makeRepository()
        made.append(root)
        FolderRenderer.firstPaintWait = .seconds(5)
        let (_, _, view) = try await render(root)
        XCTAssertEqual(view.read?.languages.map(\.name), ["Markdown"], "README.md is the one tracked file in a known language")
        XCTAssertEqual(view.hairline.shares.map(\.token), ["series-1"], "the repository's hairline is its languages")
        XCTAssertEqual(view.pathRow.titles.last, FileManager.default.displayName(atPath: root.path))
        XCTAssertGreaterThanOrEqual(view.pathRow.titles.count, 2, "the parent folder gives context, as in Projects › lumen-site")
    }
}
