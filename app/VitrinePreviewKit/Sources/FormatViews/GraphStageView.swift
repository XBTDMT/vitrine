import AppKit
import VitrineUI

/// The dependency graph (format view F9, option A; design/mockups/formats/decisions.html): services or jobs as calm
/// cards on a dotted stage, left to right, with curved arrows from each node to the nodes it points at and the edge
/// labels on the curves. A node with a warning carries the caution or danger ring and a numbered chip (warning nodes
/// are numbered 1, 2, … in the order the graph lists them, so a card's "To check" rows can carry the same numbers).
/// A cycle is tolerated: one edge per cycle is set aside for the layering and drawn dashed, under the graph. The
/// layout is fitted to the stage with padding (shrunk to no less than 60 %) and scrolls past that. Click selects a
/// node and lights its edges. The dots are drawn over a clear ground, so the card's lit stage shows through.
/// roadmap: S-22
@MainActor
final class GraphStageView: NSView {
    let graph: StageGraph
    let graphLayout: GraphLayout
    let canvas: GraphCanvas
    let scrollView = NSScrollView()
    static let padding: CGFloat = 24
    static let minimumScale: CGFloat = 0.6

    /// The selected node's id, nil when none.
    var selectedNodeID: String? {
        get { canvas.selected.map { graphLayout.nodes[$0].id } }
        set { canvas.selected = newValue.flatMap { id in graphLayout.nodes.firstIndex { $0.id == id } } }
    }

    init(graph: StageGraph) {
        self.graph = graph
        graphLayout = GraphLayout(graph: graph)
        canvas = GraphCanvas(layout: graphLayout)
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = canvas
        addSubview(scrollView)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Graph", bundle: .previewKit, comment: "Accessibility name of the dependency graph view."))
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let clip = scrollView.contentSize
        let size = graphLayout.size
        let pad = Self.padding
        var scale: CGFloat = 1
        if size.width > 0, size.height > 0 {
            scale = min(1, max(1, clip.width - 2 * pad) / size.width, max(1, clip.height - 2 * pad) / size.height)
        }
        scale = max(scale, Self.minimumScale)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        let document = NSSize(width: max(clip.width, scaled.width + 2 * pad), height: max(clip.height, scaled.height + 2 * pad))
        canvas.scale = scale
        canvas.origin = CGPoint(x: floor((document.width - scaled.width) / 2), y: floor((document.height - scaled.height) / 2))
        canvas.setFrameSize(document)
        canvas.needsDisplay = true
        // A graph bigger than the stage opens on its first node (column one, top of the order), not on empty space.
        if !scrolledToStart, clip.width > 1, document.height > clip.height + 1 || document.width > clip.width + 1 {
            scrolledToStart = true
            if let first = graphLayout.nodeRects.indices.min(by: { (graphLayout.layer[$0], graphLayout.nodeRects[$0].minY) < (graphLayout.layer[$1], graphLayout.nodeRects[$1].minY) }) {
                let rect = canvas.canvasRect(graphLayout.nodeRects[first])
                let y = min(max(0, rect.midY - clip.height / 2), document.height - clip.height)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    private var scrolledToStart = false

    /// A node's card in this view's coordinates (for tests and for a card that ties a row to the picture).
    func viewRect(forNode id: String) -> CGRect? {
        guard let index = graphLayout.nodes.firstIndex(where: { $0.id == id }) else { return nil }
        return convert(canvas.canvasRect(graphLayout.nodeRects[index]), from: canvas)
    }
}

/// A layered (Sugiyama-style) layout of a StageGraph: depth-first search sets one edge per cycle aside, longest-path
/// layering puts every edge's target in a later column (sources pulled next to what they point at), long edges get
/// dummy points, barycentre sweeps order each column to cut crossings (the best of 16 sweeps is kept), and a few
/// alignment passes centre each node on its neighbours. Pure and nonisolated, so it is measured in tests; ~200 nodes
/// lay out in a few milliseconds.
struct GraphLayout {
    struct Edge {
        var from: Int
        var to: Int
        var label: String?
        /// Forward: the source's right middle, two points per crossed column, the target's left middle.
        /// Back (a cycle's set-aside edge): the source's bottom middle and the target's bottom middle.
        var points: [CGPoint]
        var isBack = false
        var isSelfLoop = false
        /// A back edge's lowest y: it runs under every node between its ends.
        var dip: CGFloat = 0
    }

    static let nodeHeight: CGFloat = 48
    static let columnGap: CGFloat = 96
    static let rowGap: CGFloat = 22
    static let dummyHeight: CGFloat = 8

    /// One card size for every node: wide enough for the widest title or subtitle, between 150 and 220 pt.
    private(set) var nodeSize = CGSize(width: 150, height: GraphLayout.nodeHeight)
    private(set) var nodes: [StageGraph.Node] = []
    /// Each node's card, in layout coordinates (flipped, origin top left).
    private(set) var nodeRects: [CGRect] = []
    private(set) var layer: [Int] = []
    private(set) var edges: [Edge] = []
    /// Warning nodes numbered 1, 2, … in graph order.
    private(set) var warningNumber: [Int?] = []
    private(set) var size: CGSize = .zero
    /// Edge crossings between adjacent columns after ordering (diagnostic).
    private(set) var crossings = 0

    init(graph: StageGraph) {
        var index: [String: Int] = [:]
        for node in graph.nodes where index[node.id] == nil {
            index[node.id] = nodes.count
            nodes.append(node)
        }
        let n = nodes.count
        guard n > 0 else { return }
        let titleFont = Self.titleFont(), subtitleFont = Self.subtitleFont()
        let widest = nodes.reduce(CGFloat(0)) { widest, node in
            let title = (node.title as NSString).size(withAttributes: [.font: titleFont]).width
            let subtitle = ((node.subtitle ?? "") as NSString).size(withAttributes: [.font: subtitleFont]).width
            return max(widest, title, subtitle)
        }
        nodeSize.width = min(220, max(150, ceil(widest) + 46))
        var count = 0
        warningNumber = nodes.map { node in
            guard node.warning != nil else { return nil }
            count += 1
            return count
        }

        struct Raw { var u: Int; var v: Int; var label: String? }
        let raw: [Raw] = graph.edges.compactMap { edge in
            guard let u = index[edge.from], let v = index[edge.to] else { return nil }
            return Raw(u: u, v: v, label: edge.label)
        }

        // 1. Cycles: an iterative depth-first search in graph order; an edge into a node still on the stack closes a
        // cycle and is set aside (drawn dashed), which breaks exactly one edge per cycle it finds.
        var outgoing = [[Int]](repeating: [], count: n)
        for (k, edge) in raw.enumerated() where edge.u != edge.v { outgoing[edge.u].append(k) }
        var state = [UInt8](repeating: 0, count: n)
        var isBack = [Bool](repeating: false, count: raw.count)
        for root in 0..<n where state[root] == 0 {
            var stack: [(node: Int, next: Int)] = [(root, 0)]
            state[root] = 1
            while let top = stack.last {
                if top.next < outgoing[top.node].count {
                    stack[stack.count - 1].next += 1
                    let k = outgoing[top.node][top.next]
                    let w = raw[k].v
                    if state[w] == 1 { isBack[k] = true } else if state[w] == 0 { state[w] = 1; stack.append((w, 0)) }
                } else {
                    state[top.node] = 2
                    stack.removeLast()
                }
            }
        }

        // 2. Layers: longest path from the sources over the forward edges; then each source moves right to sit just
        // before the nearest node it points at, so a lone service does not trail a long edge across the stage.
        var successors = [[Int]](repeating: [], count: n), predecessors = [[Int]](repeating: [], count: n)
        var pairs = Set<Int>()
        for (k, edge) in raw.enumerated() where edge.u != edge.v && !isBack[k] && pairs.insert(edge.u * n + edge.v).inserted {
            successors[edge.u].append(edge.v)
            predecessors[edge.v].append(edge.u)
        }
        var indegree = predecessors.map(\.count)
        var order = (0..<n).filter { indegree[$0] == 0 }
        var cursor = 0
        while cursor < order.count {
            for w in successors[order[cursor]] {
                indegree[w] -= 1
                if indegree[w] == 0 { order.append(w) }
            }
            cursor += 1
        }
        layer = [Int](repeating: 0, count: n)
        for v in order { for w in successors[v] { layer[w] = max(layer[w], layer[v] + 1) } }
        for v in order.reversed() where predecessors[v].isEmpty && !successors[v].isEmpty {
            layer[v] = max(layer[v], (successors[v].map { layer[$0] }.min() ?? 1) - 1)
        }
        let layerCount = (layer.max() ?? 0) + 1

        // 3. Dummy points on edges that cross columns, so ordering and drawing see them.
        var vLayer = layer
        var chains: [Int: [Int]] = [:]
        for (k, edge) in raw.enumerated() where edge.u != edge.v && !isBack[k] {
            var chain = [edge.u]
            if layer[edge.v] - layer[edge.u] > 1 {
                for l in (layer[edge.u] + 1)..<layer[edge.v] {
                    chain.append(vLayer.count)
                    vLayer.append(l)
                }
            }
            chain.append(edge.v)
            chains[k] = chain
        }
        let vn = vLayer.count
        var up = [[Int]](repeating: [], count: vn), down = [[Int]](repeating: [], count: vn)
        for k in chains.keys.sorted() {
            let chain = chains[k]!
            for (a, b) in zip(chain, chain.dropFirst()) {
                down[a].append(b)
                up[b].append(a)
            }
        }

        // 4. Order within columns: barycentre sweeps down and up, keeping the order with the fewest crossings.
        var columns = [[Int]](repeating: [], count: layerCount)
        for v in 0..<vn { columns[vLayer[v]].append(v) }
        var position = [Int](repeating: 0, count: vn)
        func renumber(_ l: Int) { for (i, v) in columns[l].enumerated() { position[v] = i } }
        for l in 0..<layerCount { renumber(l) }
        func countCrossings() -> Int {
            var total = 0
            for l in 0..<max(0, layerCount - 1) {
                var segments: [(Int, Int)] = []
                for v in columns[l] { for w in down[v] { segments.append((position[v], position[w])) } }
                total += GraphLayout.crossings(segments, targets: columns[l + 1].count)
            }
            return total
        }
        var best = columns
        var bestCrossings = countCrossings()
        if layerCount > 1 {
            for sweep in 0..<16 where bestCrossings > 0 {
                let downward = sweep % 2 == 0
                let range: [Int] = downward ? Array(1..<layerCount) : Array((0..<(layerCount - 1)).reversed())
                for l in range {
                    let keyed = columns[l].map { v -> (v: Int, key: Double, at: Int) in
                        let neighbours = downward ? up[v] : down[v]
                        let key = neighbours.isEmpty ? Double(position[v])
                            : Double(neighbours.reduce(0) { $0 + position[$1] }) / Double(neighbours.count)
                        return (v, key, position[v])
                    }
                    columns[l] = keyed.sorted { $0.key != $1.key ? $0.key < $1.key : $0.at < $1.at }.map(\.v)
                    renumber(l)
                }
                let crossings = countCrossings()
                if crossings < bestCrossings { bestCrossings = crossings; best = columns }
            }
        }
        columns = best
        for l in 0..<layerCount { renumber(l) }
        crossings = bestCrossings

        // 5. Coordinates: columns left to right; in a column, nodes stacked in order, then pulled toward the mean of
        // their neighbours' centres (alternating sweeps) without breaking order or spacing.
        let real = n
        let nodeSize = self.nodeSize
        func height(_ v: Int) -> CGFloat { v < real ? nodeSize.height : Self.dummyHeight }
        func gap(_ a: Int, _ b: Int) -> CGFloat { a < real && b < real ? Self.rowGap : 8 }
        var top = [CGFloat](repeating: 0, count: vn)
        var columnHeight = [CGFloat](repeating: 0, count: layerCount)
        for l in 0..<layerCount {
            var y: CGFloat = 0
            for (i, v) in columns[l].enumerated() {
                if i > 0 { y += gap(columns[l][i - 1], v) }
                top[v] = y
                y += height(v)
            }
            columnHeight[l] = y
        }
        let tallest = columnHeight.max() ?? 0
        for l in 0..<layerCount { for v in columns[l] { top[v] += (tallest - columnHeight[l]) / 2 } }
        func centre(_ v: Int) -> CGFloat { top[v] + height(v) / 2 }
        for pass in 0..<6 {
            let downward = pass % 2 == 0
            let range: [Int] = downward ? Array(0..<layerCount) : Array((0..<layerCount).reversed())
            for l in range where !columns[l].isEmpty {
                let column = columns[l]
                let desired: [CGFloat] = column.map { v in
                    let neighbours = (downward ? up[v] : down[v]) + (pass >= 4 ? (downward ? down[v] : up[v]) : [])
                    guard !neighbours.isEmpty else { return top[v] }
                    return neighbours.reduce(0) { $0 + centre($1) } / CGFloat(neighbours.count) - height(v) / 2
                }
                var placed = desired
                for i in 1..<max(1, column.count) {
                    placed[i] = max(placed[i], placed[i - 1] + height(column[i - 1]) + gap(column[i - 1], column[i]))
                }
                let shift = zip(placed, desired).reduce(0) { $0 + ($1.0 - $1.1) } / CGFloat(column.count)
                for (i, v) in column.enumerated() { top[v] = placed[i] - shift }
            }
        }
        let minTop = top.min() ?? 0
        for v in 0..<vn { top[v] -= minTop }

        func columnX(_ l: Int) -> CGFloat { CGFloat(l) * (nodeSize.width + Self.columnGap) }
        nodeRects = (0..<n).map { v in CGRect(x: columnX(layer[v]), y: top[v], width: nodeSize.width, height: nodeSize.height) }
        var bottom = (0..<vn).map { top[$0] + height($0) }.max() ?? 0
        let width = columnX(layerCount - 1) + nodeSize.width

        // 6. Edge geometry.
        for (k, edge) in raw.enumerated() {
            if edge.u == edge.v {
                let r = nodeRects[edge.u]
                edges.append(Edge(from: edge.u, to: edge.v, label: edge.label,
                                  points: [CGPoint(x: r.maxX - 40, y: r.minY), CGPoint(x: r.maxX - 16, y: r.minY)], isSelfLoop: true))
            } else if isBack[k] {
                let ru = nodeRects[edge.u], rv = nodeRects[edge.v]
                let low = min(layer[edge.u], layer[edge.v]), high = max(layer[edge.u], layer[edge.v])
                let lowest = (0..<vn).filter { (low...high).contains(vLayer[$0]) }.map { top[$0] + height($0) }.max() ?? max(ru.maxY, rv.maxY)
                let dip = lowest + 30
                edges.append(Edge(from: edge.u, to: edge.v, label: edge.label,
                                  points: [CGPoint(x: ru.midX, y: ru.maxY), CGPoint(x: rv.midX, y: rv.maxY)], isBack: true, dip: dip))
                bottom = max(bottom, dip - 4)
            } else if let chain = chains[k] {
                let ru = nodeRects[edge.u], rv = nodeRects[edge.v]
                var points = [CGPoint(x: ru.maxX, y: ru.midY)]
                for d in chain.dropFirst().dropLast() {
                    let y = centre(d)
                    points.append(CGPoint(x: columnX(vLayer[d]), y: y))
                    points.append(CGPoint(x: columnX(vLayer[d]) + nodeSize.width, y: y))
                }
                points.append(CGPoint(x: rv.minX, y: rv.midY))
                edges.append(Edge(from: edge.u, to: edge.v, label: edge.label, points: points))
            }
        }
        size = CGSize(width: width, height: bottom)
    }

    /// The node title's font (mockup `.gnode b`) and the subtitle's (`.gnode span.mono`), shared by layout and drawing.
    static func titleFont() -> NSFont { systemFont(Metric.value("fs-callout"), cssWeight: 600) }
    static func subtitleFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: Metric.value("fs-mono-xs"), weight: .regular) }

    /// Crossings between two adjacent columns' segments (source position, target position): pairs whose ends come
    /// in opposite orders, counted as inversions with a Fenwick tree in O(m log n).
    static func crossings(_ segments: [(Int, Int)], targets: Int) -> Int {
        guard segments.count > 1 else { return 0 }
        let sorted = segments.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var tree = [Int](repeating: 0, count: targets + 2)
        var inserted = 0, total = 0, i = 0
        while i < sorted.count {
            var j = i
            // Segments from the same source never cross each other: query the whole group before inserting it.
            while j < sorted.count && sorted[j].0 == sorted[i].0 {
                var k = sorted[j].1 + 1, notGreater = 0
                while k > 0 { notGreater += tree[k]; k -= k & -k }
                total += inserted - notGreater
                j += 1
            }
            for g in i..<j {
                var k = sorted[g].1 + 1
                while k < tree.count { tree[k] += 1; k += k & -k }
                inserted += 1
            }
            i = j
        }
        return total
    }
}

/// The drawn graph: dots on the whole canvas, then the laid-out graph at `origin`, scaled by `scale`.
@MainActor
final class GraphCanvas: NSView {
    private let graph: GraphLayout
    var scale: CGFloat = 1
    var origin: CGPoint = .zero
    var selected: Int? { didSet { if selected != oldValue { needsDisplay = true } } }
    private let titleFont = GraphLayout.titleFont()
    private let subtitleFont = GraphLayout.subtitleFont()
    private let labelFont = systemFont(10.5, cssWeight: 500)
    private let chipFont = systemFont(10.5, cssWeight: 700)
    private lazy var icon: NSImage? = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))

    init(layout: GraphLayout) {
        graph = layout
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// A layout rectangle in canvas coordinates.
    func canvasRect(_ rect: CGRect) -> CGRect {
        CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let local = CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
        let hit = graph.nodeRects.firstIndex { $0.contains(local) }
        selected = hit == selected ? nil : hit
    }

    override func draw(_ dirtyRect: NSRect) {
        drawDots(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, !graph.nodes.isEmpty else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        let visible = CGRect(x: (dirtyRect.minX - origin.x) / scale, y: (dirtyRect.minY - origin.y) / scale,
                             width: dirtyRect.width / scale, height: dirtyRect.height / scale).insetBy(dx: -12, dy: -12)
        for edge in graph.edges { drawEdge(edge) }
        for edge in graph.edges where edge.label?.isEmpty == false { drawLabel(edge) }
        for (index, rect) in graph.nodeRects.enumerated() where rect.intersects(visible) { drawNode(index, rect) }
        context.restoreGState()
    }

    /// The dotted stage (mockup `.stage.dots`): a 1 pt dot every 16 pt, in the hairline colour.
    private func drawDots(_ dirty: NSRect) {
        let step: CGFloat = 16
        let path = NSBezierPath()
        var y = floor(dirty.minY / step) * step + 8
        while y < dirty.maxY + step {
            var x = floor(dirty.minX / step) * step + 8
            while x < dirty.maxX + step {
                path.appendOval(in: NSRect(x: x - 1, y: y - 1, width: 2, height: 2))
                x += step
            }
            y += step
        }
        NSColor.token("hair").setFill()
        path.fill()
    }

    private func touchesSelection(_ edge: GraphLayout.Edge) -> Bool {
        guard let selected else { return false }
        return edge.from == selected || edge.to == selected
    }

    private func drawEdge(_ edge: GraphLayout.Edge) {
        let color = NSColor.token(touchesSelection(edge) ? "accent-text" : "t3")
        let path = NSBezierPath()
        path.lineWidth = touchesSelection(edge) ? 1.8 : 1.3
        path.lineCapStyle = .round
        let tip: CGPoint, direction: CGVector
        if edge.isSelfLoop {
            let a = edge.points[0], b = edge.points[1]
            tip = b
            direction = CGVector(dx: 0, dy: 1)
            path.move(to: a)
            path.curve(to: CGPoint(x: b.x, y: b.y - 5), controlPoint1: CGPoint(x: a.x, y: a.y - 26), controlPoint2: CGPoint(x: b.x, y: b.y - 26))
        } else if edge.isBack {
            let a = edge.points[0], b = edge.points[1]
            tip = b
            direction = CGVector(dx: 0, dy: -1)
            path.move(to: a)
            path.curve(to: CGPoint(x: b.x, y: b.y + 5), controlPoint1: CGPoint(x: a.x, y: edge.dip + 10), controlPoint2: CGPoint(x: b.x, y: edge.dip + 10))
        } else {
            var points = edge.points
            guard points.count >= 2 else { return }
            tip = points[points.count - 1]
            direction = CGVector(dx: 1, dy: 0)
            points[points.count - 1].x -= 5
            path.move(to: points[0])
            for (a, b) in zip(points, points.dropFirst()) {
                if abs(a.y - b.y) < 0.5 {
                    path.line(to: b)
                } else {
                    let mid = (b.x - a.x) / 2
                    path.curve(to: b, controlPoint1: CGPoint(x: a.x + mid, y: a.y), controlPoint2: CGPoint(x: b.x - mid, y: b.y))
                }
            }
        }
        if edge.isBack || edge.isSelfLoop { path.setLineDash([5, 4], count: 2, phase: 0) }
        color.setStroke()
        path.stroke()
        // Arrowhead (mockup marker `#ah`): a filled 7 pt triangle with its tip on the target.
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let base = CGPoint(x: tip.x - direction.dx * 7, y: tip.y - direction.dy * 7)
        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: CGPoint(x: base.x + normal.dx * 3.5, y: base.y + normal.dy * 3.5))
        head.line(to: CGPoint(x: base.x - normal.dx * 3.5, y: base.y - normal.dy * 3.5))
        head.close()
        color.setFill()
        head.fill()
    }

    /// An edge's label in a small pill on the curve: the middle of its first column gap, or the bottom of a back
    /// edge, or above a loop.
    private func drawLabel(_ edge: GraphLayout.Edge) {
        guard let text = edge.label, edge.points.count >= 2 else { return }
        let a = edge.points[0], b = edge.points[1]
        let centre: CGPoint, maxWidth: CGFloat
        if edge.isSelfLoop {
            centre = CGPoint(x: (a.x + b.x) / 2, y: a.y - 26)
            maxWidth = graph.nodeSize.width
        } else if edge.isBack {
            centre = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 8 + (edge.dip + 10) * 6 / 8)
            maxWidth = max(60, abs(a.x - b.x) - 20)
        } else {
            centre = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            maxWidth = GraphLayout.columnGap - 8
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.token("t2")]
        let width = min(ceil((text as NSString).size(withAttributes: attributes).width), maxWidth - 10)
        let pill = NSRect(x: centre.x - width / 2 - 5, y: centre.y - 8, width: width + 10, height: 16)
        let shape = NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5)
        NSColor.token("card").setFill()
        shape.fill()
        NSColor.token("hair").setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
        drawText(text, attributes: attributes, in: NSRect(x: pill.minX + 5, y: pill.minY + 1.5, width: width, height: 14), alignment: .center)
    }

    /// A node as a calm card (mockup `.gnode`): `card` ground, hairline ring and a soft shadow; a warning adds the
    /// caution or danger ring and its numbered chip; selection adds the accent ring and focus halo.
    private func drawNode(_ index: Int, _ rect: CGRect) {
        let node = graph.nodes[index]
        let radius: CGFloat = 10
        let isSelected = index == selected
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.10)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 6
        shadow.set()
        let outer: CGFloat = isSelected ? 5 : (node.warning != nil ? 1.5 : 0.5)
        let outerColor: NSColor = isSelected ? NSColor.token("focus") : node.warning.map { NSColor.token($0 == .danger ? "danger" : "caution") } ?? NSColor.token("hair")
        outerColor.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -outer, dy: -outer), xRadius: radius + outer, yRadius: radius + outer).fill()
        NSGraphicsContext.restoreGraphicsState()
        if isSelected {
            NSColor.token(node.warning == .danger ? "danger" : node.warning == .caution ? "caution" : "accent").setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: radius + 2, yRadius: radius + 2).fill()
        }
        NSColor.token("card").setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        if let icon {
            NSGraphicsContext.saveGraphicsState()
            let size = icon.size
            let iconRect = NSRect(x: rect.minX + 10, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            let tinted = NSImage(size: size, flipped: false) { bounds in
                icon.draw(in: bounds)
                NSColor.token("t2").set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let textX = rect.minX + 32, textWidth = rect.maxX - 10 - textX
        if let subtitle = node.subtitle, !subtitle.isEmpty {
            drawText(node.title, attributes: [.font: titleFont, .foregroundColor: NSColor.token("t1")],
                     in: NSRect(x: textX, y: rect.midY - 16, width: textWidth, height: 17), alignment: .left)
            drawText(subtitle, attributes: [.font: subtitleFont, .foregroundColor: NSColor.token("t2")],
                     in: NSRect(x: textX, y: rect.midY + 1, width: textWidth, height: 15), alignment: .left)
        } else {
            drawText(node.title, attributes: [.font: titleFont, .foregroundColor: NSColor.token("t1")],
                     in: NSRect(x: textX, y: rect.midY - 8.5, width: textWidth, height: 17), alignment: .left)
        }

        // The numbered chip (mockup `.nchip`), top right, half outside the card.
        if let warning = node.warning, let number = graph.warningNumber[index] {
            let text = "\(number)"
            let attributes: [NSAttributedString.Key: Any] = [.font: chipFont, .foregroundColor: NSColor.white]
            let width = max(16, ceil((text as NSString).size(withAttributes: attributes).width) + 8)
            let chip = NSRect(x: rect.maxX + 7 - width, y: rect.minY - 7, width: width, height: 16)
            NSColor.token(warning == .danger ? "danger-strong" : "caution-strong").setFill()
            NSBezierPath(roundedRect: chip, xRadius: 8, yRadius: 8).fill()
            drawText(text, attributes: attributes, in: NSRect(x: chip.minX, y: chip.minY + 1.5, width: chip.width, height: 14), alignment: .center)
        }
    }
}
