import AppKit
import XCTest
@testable import VitrinePreviewKit
import VitrineUI

/// Format views F8 and F9 (option A): the trace waterfall and the dependency graph, drawn offscreen at 900 × 420 on the
/// card's lit stage, light and dark, written as PNGs to the temporary folder (paths printed) and checked for the
/// pixels that matter: the failed spans in red, the model calls' bars, the danger node's ring, dependents laid out to
/// the right of what they point at, a cycle drawn with one dashed edge, and cheap layout for big inputs. Content is
/// invented. roadmap: S-22
@MainActor
final class FormatViewsWaterfallGraphTests: XCTestCase {
    // MARK: Fixtures

    /// One run of an invented support agent: plan, a lookup, a refund tool call that fails with a 500 and is retried,
    /// then the answer, with tokens on the model calls.
    private let trace: [WaterfallRow] = [
        WaterfallRow(name: "invoke_agent support-agent", startMs: 0, durationMs: 8400, depth: 0, detail: "11.3K → 1.2K tokens"),
        WaterfallRow(name: "chat plan · example-model", startMs: 50, durationMs: 2050, depth: 1, detail: "3,312 → 220 tokens"),
        WaterfallRow(name: "execute_tool lookup_order", startMs: 2160, durationMs: 450, depth: 1),
        WaterfallRow(name: "GET orders.internal.example", startMs: 2190, durationMs: 400, depth: 2, detail: "200 · 14 KB"),
        WaterfallRow(name: "chat decide · example-model", startMs: 2650, durationMs: 1650, depth: 1, detail: "3,780 → 220 tokens"),
        WaterfallRow(name: "execute_tool issue_refund", startMs: 4350, durationMs: 1600, depth: 1, isError: true),
        WaterfallRow(name: "POST payments.internal.example", startMs: 4400, durationMs: 1500, depth: 2, detail: "500 · 1 KB", isError: true),
        WaterfallRow(name: "execute_tool issue_refund · retry", startMs: 6000, durationMs: 600, depth: 1),
        WaterfallRow(name: "POST payments.internal.example", startMs: 6020, durationMs: 530, depth: 2, detail: "200 · 2 KB"),
        WaterfallRow(name: "chat answer · example-model", startMs: 6700, durationMs: 1650, depth: 1, detail: "4,560 → 380 tokens"),
    ]

    /// An invented Compose stack: web → api → db and cache, a worker, and a privileged "agent" with danger.
    private let compose = StageGraph(nodes: [
        .init(id: "web", title: "web", subtitle: "nginx:1.27"),
        .init(id: "api", title: "api", subtitle: "build ./api"),
        .init(id: "worker", title: "worker", subtitle: "build ./worker"),
        .init(id: "db", title: "db", subtitle: "postgres:16.4"),
        .init(id: "cache", title: "cache", subtitle: "redis:7.4"),
        .init(id: "agent", title: "agent", subtitle: "acme/monitor:latest", warning: .danger),
    ], edges: [
        .init(from: "web", to: "api", label: "http"),
        .init(from: "api", to: "db"),
        .init(from: "api", to: "cache"),
        .init(from: "worker", to: "db"),
        .init(from: "worker", to: "cache"),
        .init(from: "agent", to: "db", label: "reads"),
    ])

    /// An invented release workflow with an action pinned to a branch (caution) on its last job.
    private let workflow = StageGraph(nodes: [
        .init(id: "lint", title: "lint", subtitle: "2 steps"),
        .init(id: "test", title: "test", subtitle: "matrix · 3 jobs"),
        .init(id: "build", title: "build", subtitle: "5 steps"),
        .init(id: "publish", title: "publish", subtitle: "uses 1 unpinned action", warning: .caution),
    ], edges: [
        .init(from: "lint", to: "build"), .init(from: "test", to: "build"), .init(from: "build", to: "publish"),
    ])

    /// A cycle: a → b → c → a, with c also feeding d, and a self-loop on d.
    private let cycle = StageGraph(nodes: [
        .init(id: "a", title: "gateway", subtitle: "a"),
        .init(id: "b", title: "auth", subtitle: "b"),
        .init(id: "c", title: "sessions", subtitle: "c", warning: .caution),
        .init(id: "d", title: "audit", subtitle: "d"),
    ], edges: [
        .init(from: "a", to: "b", label: "calls"), .init(from: "b", to: "c"), .init(from: "c", to: "a", label: "refresh"),
        .init(from: "c", to: "d"), .init(from: "d", to: "d", label: "retry"),
    ])

    // MARK: Rendering

    /// The card's lit stage behind the view, drawn (not a gradient layer) so cacheDisplay captures it.
    private final class Backdrop: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = GeneratedTokens.color("stage").map { dark ? $0.dark : $0.light } ?? "#F3F4F7"
            let stops = StageView.stops(value)
            NSGradient(colors: stops.count > 1 ? stops : stops + stops)?.draw(in: bounds, angle: 90)
        }
    }

    struct RGB { let r, g, b: Int }

    private struct Shot {
        let rep: NSBitmapImageRep
        let viewFrame: CGRect
        let backdrop: NSView
        /// Pixels per point.
        var scale: CGFloat { CGFloat(rep.pixelsWide) / backdrop.bounds.width }

        func rgb(_ x: Int, _ y: Int) -> RGB {
            let data = rep.bitmapData!
            let p = data + y * rep.bytesPerRow + x * (rep.bitsPerPixel / 8)
            return RGB(r: Int(p[0]), g: Int(p[1]), b: Int(p[2]))
        }

        /// How many pixels in a backdrop-space rectangle match.
        func count(in rect: CGRect, _ match: (RGB) -> Bool) -> Int {
            let r = rect.intersection(backdrop.bounds)
            guard !r.isNull else { return 0 }
            var n = 0
            for y in Int(r.minY * scale)..<Int(r.maxY * scale) {
                for x in Int(r.minX * scale)..<Int(r.maxX * scale) where match(rgb(x, y)) { n += 1 }
            }
            return n
        }

        /// Mean brightness (0…255) in a rectangle.
        func mean(in rect: CGRect) -> Double {
            var sum = 0, n = 0
            let r = rect.intersection(backdrop.bounds)
            for y in stride(from: Int(r.minY * scale), to: Int(r.maxY * scale), by: 2) {
                for x in stride(from: Int(r.minX * scale), to: Int(r.maxX * scale), by: 2) {
                    let c = rgb(x, y)
                    sum += c.r + c.g + c.b; n += 1
                }
            }
            return n == 0 ? 0 : Double(sum) / Double(3 * n)
        }

        func distinctColours(in rect: CGRect) -> Int {
            var set = Set<Int>()
            let r = rect.intersection(backdrop.bounds)
            for y in stride(from: Int(r.minY * scale), to: Int(r.maxY * scale), by: 2) {
                for x in stride(from: Int(r.minX * scale), to: Int(r.maxX * scale), by: 2) {
                    let c = rgb(x, y)
                    set.insert(c.r << 16 | c.g << 8 | c.b)
                }
            }
            return set.count
        }
    }

    /// Lays the view out at 900 × 420 on the stage (16 pt margins, 44 pt top, as the card places a format view),
    /// renders it with cacheDisplay and writes the PNG.
    private func shoot(_ view: NSView, _ name: String, dark: Bool) throws -> Shot {
        let backdrop = Backdrop(frame: NSRect(x: 0, y: 0, width: 932, height: 480))
        view.frame = NSRect(x: 16, y: 44, width: 900, height: 420)
        backdrop.addSubview(view)
        backdrop.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        backdrop.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        XCTAssertEqual(rep.bitsPerSample, 8)
        XCTAssertFalse(rep.bitmapFormat.contains(.alphaFirst))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-\(name)-\(dark ? "dark" : "light").png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("FORMAT-VIEW-PNG \(url.path)")
        let shot = Shot(rep: rep, viewFrame: view.frame, backdrop: backdrop)
        view.removeFromSuperview()
        return shot
    }

    private static let reddish: (RGB) -> Bool = { c in c.r > 190 && c.g < 110 && c.b < 110 }
    private static let purple: (RGB) -> Bool = { c in c.r > 140 && c.r < 215 && c.g < 140 && c.b > 190 }

    // MARK: Waterfall

    func testWaterfallDrawsTheTraceWithTheFailureMarkedLightAndDark() throws {
        for dark in [false, true] {
            let view = WaterfallStageView(rows: trace)
            XCTAssertEqual(view.selectedIndex, 5, "the first failed span opens in place")
            let shot = try shoot(view, "waterfall", dark: dark)
            let frame = shot.viewFrame
            XCTAssertGreaterThan(shot.distinctColours(in: frame), 60, "the card is drawn, not blank")
            // Bars live in the right part of the card; the two failed spans' bars are red there.
            let barsZone = CGRect(x: frame.minX + frame.width * 0.45, y: frame.minY + 26, width: frame.width * 0.55, height: frame.height - 26)
            XCTAssertGreaterThan(shot.count(in: barsZone, Self.reddish), 400, "the failed spans' bars are drawn in the danger colour")
            XCTAssertGreaterThan(shot.count(in: barsZone, Self.purple), 400, "the model calls' bars are drawn in series 2")
            // The opened detail sits under the selected row with the token-free timing line.
            let canvas = view.canvas
            XCTAssertEqual(canvas.top(of: 6), 6 * WaterfallCanvas.rowHeight + canvas.detailHeight, "rows under the opened one move down by its detail")
            XCTAssertGreaterThan(canvas.detailHeight, 40)
        }
    }

    func testWaterfallSelectionOpensTokenSplitAndClicksToggle() throws {
        let view = WaterfallStageView(rows: trace)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        view.layoutSubtreeIfNeeded()
        let canvas = view.canvas
        view.selectedIndex = 4
        let split = try XCTUnwrap(WaterfallModel.tokenSplit(trace[4].detail))
        XCTAssertEqual(split.input, "3,780")
        XCTAssertEqual(split.inValue, 3780)
        XCTAssertEqual(split.outValue, 220)
        XCTAssertEqual(canvas.frame.height, canvas.contentHeight)
        XCTAssertEqual(canvas.contentHeight, CGFloat(trace.count) * WaterfallCanvas.rowHeight + canvas.detailHeight)
        // The detail area belongs to the selected row; the row under it is the next one.
        let detailY = 5 * WaterfallCanvas.rowHeight + 4
        XCTAssertEqual(canvas.row(atY: detailY)?.index, 4)
        XCTAssertEqual(canvas.row(atY: detailY)?.inDetail, true)
        XCTAssertEqual(canvas.row(atY: 5 * WaterfallCanvas.rowHeight + canvas.detailHeight + 2)?.index, 5)
        XCTAssertNil(WaterfallModel.tokenSplit("200 · 14 KB"))
        XCTAssertEqual(WaterfallModel.tokenSplit("11.3K → 1.2K tokens")?.inValue, 11300)
        _ = try shoot(view, "waterfall-model-call", dark: false)

        // A real click through a window: on another row opens it, on the same row closes it.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = window.contentView!.bounds
        view.layoutSubtreeIfNeeded()
        func click(row: Int) {
            let local = NSPoint(x: 200, y: canvas.top(of: row) + 10)
            let point = canvas.convert(local, to: nil)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            canvas.mouseDown(with: event)
        }
        click(row: 2)
        XCTAssertEqual(view.selectedIndex, 2)
        click(row: 2)
        XCTAssertNil(view.selectedIndex)
        XCTAssertEqual(WaterfallModel.Kind.of("GET /api"), .request)
        XCTAssertEqual(WaterfallModel.Kind.of("chat example-model"), .model)
        XCTAssertEqual(WaterfallModel.Kind.of("execute_tool x"), .tool)
        XCTAssertEqual(WaterfallModel.Kind.of("invoke_agent y"), .agent)
    }

    func testWaterfallTwoThousandRowsStaysCheapAndScrolls() throws {
        let rows = (0..<2000).map { i in
            WaterfallRow(name: i % 7 == 0 ? "chat step \(i)" : "GET /items/\(i)", startMs: Double(i) * 37, durationMs: Double(40 + i % 300),
                         depth: i % 4, detail: i % 7 == 0 ? "\(1000 + i) → \(i % 400) tokens" : "200 · \(i % 90) KB", isError: i % 211 == 0)
        }
        let clock = ContinuousClock()
        var view: WaterfallStageView!
        let build = clock.measure {
            view = WaterfallStageView(rows: rows)
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
            view.layoutSubtreeIfNeeded()
        }
        print("FORMAT-VIEW-TIMING waterfall 2000 rows build+layout \(build)")
        XCTAssertLessThan(build, .milliseconds(50), "building and laying out 2,000 rows stays under the main-thread budget")
        XCTAssertEqual(view.canvas.contentHeight, 2000 * WaterfallCanvas.rowHeight + view.canvas.detailHeight)
        XCTAssertGreaterThan(view.canvas.frame.height, view.scrollView.contentSize.height, "a tall trace scrolls inside the stage")
        var shot: Shot!
        let draw = try clock.measure { shot = try shoot(view, "waterfall-2000", dark: false) }
        print("FORMAT-VIEW-TIMING waterfall 2000 rows draw \(draw)")
        XCTAssertLessThan(draw, .milliseconds(250), "only visible rows are drawn")
        XCTAssertGreaterThan(shot.distinctColours(in: shot.viewFrame), 40)
        // Scrolled to the far end, the last row is reachable.
        view.selectedIndex = 1999
        XCTAssertGreaterThan(view.scrollView.contentView.bounds.origin.y, 50_000)
    }

    // MARK: Graph

    func testComposeGraphPutsDependentsRightAndMarksTheDangerNode() throws {
        for dark in [false, true] {
            let view = GraphStageView(graph: compose)
            let layout = view.graphLayout
            for edge in compose.edges {
                let from = try XCTUnwrap(layout.nodes.firstIndex { $0.id == edge.from })
                let to = try XCTUnwrap(layout.nodes.firstIndex { $0.id == edge.to })
                XCTAssertGreaterThan(layout.nodeRects[to].minX, layout.nodeRects[from].maxX, "\(edge.to) sits right of \(edge.from)")
            }
            XCTAssertEqual(layout.edges.filter(\.isBack).count, 0)
            // api and worker both need db and cache: one crossing is the minimum for that pair (K2,2).
            XCTAssertLessThanOrEqual(layout.crossings, 1, "barycentre ordering untangles the stack")
            XCTAssertEqual(layout.warningNumber.compactMap { $0 }, [1])
            let agentIndex = try XCTUnwrap(layout.nodes.firstIndex { $0.id == "agent" })
            let dbIndex = try XCTUnwrap(layout.nodes.firstIndex { $0.id == "db" })
            XCTAssertEqual(layout.layer[agentIndex] + 1, layout.layer[dbIndex], "a lone source sits just before what it needs")
            assertNoOverlap(layout)

            let shot = try shoot(view, "graph-compose", dark: dark)
            // Fitted: the whole graph is inside the view, at full size.
            XCTAssertEqual(view.canvas.scale, 1)
            let agent = try XCTUnwrap(view.viewRect(forNode: "agent")).offsetBy(dx: shot.viewFrame.minX, dy: shot.viewFrame.minY)
            XCTAssertTrue(shot.viewFrame.contains(agent))
            XCTAssertGreaterThan(shot.count(in: agent.insetBy(dx: -9, dy: -9), Self.reddish), 150, "the danger ring and chip are drawn")
            let web = try XCTUnwrap(view.viewRect(forNode: "web")).offsetBy(dx: shot.viewFrame.minX, dy: shot.viewFrame.minY)
            XCTAssertEqual(shot.count(in: web.insetBy(dx: -4, dy: -4), Self.reddish), 0, "a calm node has no warning colour")
            XCTAssertGreaterThan(shot.distinctColours(in: shot.viewFrame), 30)
            // The card is lighter than the stage beside it, in both appearances (card #FFF on #F3F4F7, #2C2C30 on #26262B).
            let inside = shot.mean(in: web.insetBy(dx: 40, dy: 4)), beside = shot.mean(in: web.offsetBy(dx: 0, dy: -web.height - 20))
            XCTAssertGreaterThan(inside, beside + 3, "the node is a card on the stage")
        }
    }

    func testWorkflowGraphMarksTheCautionNode() throws {
        for dark in [false, true] {
            let view = GraphStageView(graph: workflow)
            let shot = try shoot(view, "graph-workflow", dark: dark)
            let publish = try XCTUnwrap(view.viewRect(forNode: "publish")).offsetBy(dx: shot.viewFrame.minX, dy: shot.viewFrame.minY)
            XCTAssertGreaterThan(shot.count(in: publish.insetBy(dx: -9, dy: -9), { c in c.r > 140 && c.g > 70 && c.g < 200 && c.b < 70 }), 150,
                                 "the caution ring and chip are drawn")
            let lint = try XCTUnwrap(view.viewRect(forNode: "lint")), build = try XCTUnwrap(view.viewRect(forNode: "build"))
            XCTAssertGreaterThan(build.minX, lint.maxX)
        }
    }

    func testCycleIsToleratedWithOneDashedEdge() throws {
        let view = GraphStageView(graph: cycle)
        let layout = view.graphLayout
        let back = layout.edges.filter(\.isBack)
        XCTAssertEqual(back.count, 1, "one edge of the cycle is set aside")
        XCTAssertEqual(back.first.map { layout.nodes[$0.from].id }, "c")
        XCTAssertEqual(layout.edges.filter(\.isSelfLoop).count, 1)
        for edge in layout.edges where !edge.isBack && !edge.isSelfLoop {
            XCTAssertGreaterThan(layout.nodeRects[edge.to].minX, layout.nodeRects[edge.from].maxX)
        }
        XCTAssertGreaterThan(layout.size.height, layout.nodeRects.map(\.maxY).max()!, "room under the graph for the dashed edge")
        for dark in [false, true] { _ = try shoot(view, "graph-cycle", dark: dark) }
    }

    func testTwoHundredNodesLayOutFastAndScroll() throws {
        var nodes: [StageGraph.Node] = [], edges: [StageGraph.Edge] = []
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        for i in 0..<200 { nodes.append(.init(id: "n\(i)", title: "service-\(i)", subtitle: "image:\(i)", warning: i % 50 == 7 ? .caution : nil)) }
        for i in 1..<200 {
            edges.append(.init(from: "n\(next(i))", to: "n\(i)"))
            if i % 3 == 0 { edges.append(.init(from: "n\(next(i))", to: "n\(i)")) }
        }
        // Every node descends from n0, so these close cycles.
        edges.append(.init(from: "n199", to: "n0"))
        edges.append(.init(from: "n150", to: "n0"))
        let graph = StageGraph(nodes: nodes, edges: edges)
        let clock = ContinuousClock()
        var view: GraphStageView!
        let build = clock.measure {
            view = GraphStageView(graph: graph)
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
            view.layoutSubtreeIfNeeded()
        }
        print("FORMAT-VIEW-TIMING graph 200 nodes build+layout \(build), crossings \(view.graphLayout.crossings)")
        XCTAssertLessThan(build, .milliseconds(50), "the layered layout of 200 nodes stays under the main-thread budget")
        let layout = view.graphLayout
        for edge in layout.edges where !edge.isBack && !edge.isSelfLoop {
            XCTAssertGreaterThan(layout.nodeRects[edge.to].minX, layout.nodeRects[edge.from].maxX)
        }
        XCTAssertEqual(layout.edges.filter(\.isBack).count, 2)
        XCTAssertGreaterThan(view.scrollView.contentView.bounds.origin.y, 0, "a tall graph opens on its first node, not the empty top")
        assertNoOverlap(layout)
        XCTAssertEqual(view.canvas.scale, GraphStageView.minimumScale, "too big to fit: shrunk to the floor, then scrolled")
        XCTAssertGreaterThan(view.canvas.frame.height, view.scrollView.contentSize.height)
        _ = try shoot(view, "graph-200", dark: false)
    }

    private func assertNoOverlap(_ layout: GraphLayout, file: StaticString = #filePath, line: UInt = #line) {
        let rects = layout.nodeRects
        for i in rects.indices {
            for j in rects.indices where j > i && rects[i].insetBy(dx: 1, dy: 1).intersects(rects[j].insetBy(dx: 1, dy: 1)) {
                XCTFail("nodes \(layout.nodes[i].id) and \(layout.nodes[j].id) overlap", file: file, line: line)
            }
        }
    }
}
