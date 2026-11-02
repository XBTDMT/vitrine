import AppKit
import VitrineFormats
import VitrineUI

/// The map on the card's stage (S-23, format view F1, picked A): the file's tracks, routes and shapes drawn on a calm
/// map-coloured ground with a faint graticule (no tiles, nothing fetched), the start and end marked, waypoints as
/// pins, a dashed caution stretch where a track's segments break (the GPS lost signal), a scale bar, and the
/// elevation profile as a strip below the map. Hovering the profile lights the same spot on the route.
/// Projection: equirectangular, longitude scaled by the cosine of the middle latitude, fitted to the bounds with
/// padding. Everything is drawn in `draw(_:)` from token colours, so light and dark follow. roadmap: S-23
@MainActor
final class MapStageView: NSView {
    let summary: MediaMapSummary

    // Layout (view coordinates, flipped), worked out in `layout()`; internal for the tests.
    private(set) var mapRect: CGRect = .zero
    private(set) var profileRect: CGRect = .zero
    /// The profile's plotting area inside its panel.
    private(set) var plotRect: CGRect = .zero

    /// A profile distance in metres the pointer rests on; nil when nothing is hovered.
    var hoverDistance: Double? { didSet { if hoverDistance != oldValue { needsDisplay = true } } }

    private let chip: ChipView
    private var projection = Projection.identity
    private var trackingArea: NSTrackingArea?

    /// The drawable lines, kept in model space; projected each draw (at most 200 × 500 points, cheap).
    private let drawLines: [MediaPolyline]
    /// Where consecutive segments of one track break: the end of one and the start of the next.
    private let gaps: [(MediaCoordinate, MediaCoordinate)]
    /// The track as one walk (segments in order) with the distance at each point, for the hover dot.
    private let walk: [(MediaCoordinate, Double)]
    /// Walked distance at each gap, for the caution band on the profile.
    private let gapWalkDistances: [Double]
    private let profile: [MediaElevationSample]
    private let geoBounds: MediaBounds?

    init(summary: MediaMapSummary) {
        self.summary = summary
        drawLines = summary.lines.filter { $0.points.count >= 2 || $0.kind == .polygon && $0.points.count >= 3 }
        profile = summary.elevationProfile.filter { $0.distanceMeters.isFinite && $0.elevationMeters.isFinite }
        let trackLines = summary.lines.filter { $0.kind == .track && !$0.points.isEmpty }
        // Consecutive segments of one track are joined by a gap; the walk (and so the profile) does not count it.
        func sameTrack(_ a: MediaPolyline, _ b: MediaPolyline) -> Bool { summary.tracks.count == 1 || (a.name != nil && a.name == b.name) }
        var gaps: [(MediaCoordinate, MediaCoordinate)] = []
        var walk: [(MediaCoordinate, Double)] = []
        var gapWalk: [Double] = []
        var distance = 0.0
        for (index, line) in trackLines.enumerated() {
            if index > 0, sameTrack(trackLines[index - 1], line), let end = trackLines[index - 1].points.last, let start = line.points.first {
                gaps.append((end, start))
                gapWalk.append(distance)
            }
            var previous: MediaCoordinate?
            for p in line.points {
                if let q = previous { distance += Self.haversine(q, p) }
                walk.append((p, distance))
                previous = p
            }
        }
        self.gaps = gaps
        self.walk = walk
        gapWalkDistances = gapWalk
        geoBounds = summary.bounds ?? Self.bounds(of: summary.lines.flatMap(\.points) + summary.points + summary.waypoints.map(\.coordinate))
        chip = ChipView(text: String(localized: "Calm map · no tiles, nothing fetched", bundle: .previewKit,
                                     comment: "The glass chip on a map file's drawn map: the ground is drawn by Vitrine, nothing is downloaded."),
                        symbol: "map", fill: "glass", textColor: "t2", border: "hair")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(chip)
        NSLayoutConstraint.activate([
            chip.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            chip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(summary.headline)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let b = bounds
        if profile.count >= 2, b.height >= 220 {
            let h = min(136, max(100, (b.height * 0.3).rounded()))
            profileRect = CGRect(x: 12, y: b.maxY - h - 10, width: max(0, b.width - 24), height: h)
            mapRect = CGRect(x: 0, y: 0, width: b.width, height: max(0, profileRect.minY - 10))
            plotRect = CGRect(x: profileRect.minX + 12, y: profileRect.minY + 10,
                              width: max(0, profileRect.width - 24), height: max(0, profileRect.height - 10 - 22))
        } else {
            profileRect = .zero
            plotRect = .zero
            mapRect = b
        }
        projection = Projection(bounds: geoBounds, into: mapRect, padding: 40)
        if let trackingArea { removeTrackingArea(trackingArea) }
        if !profileRect.isEmpty {
            let area = NSTrackingArea(rect: profileRect, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .activeAlways],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoverDistance = nil }

    private func hover(at point: CGPoint) {
        guard plotRect.width > 0, let total = profile.last?.distanceMeters, total > 0,
              point.x >= plotRect.minX - 4, point.x <= plotRect.maxX + 4 else { hoverDistance = nil; return }
        let t = min(1, max(0, (point.x - plotRect.minX) / plotRect.width))
        hoverDistance = Double(t) * total
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: bounds)
        drawMap(ctx)
        if !profileRect.isEmpty { drawProfile(ctx) }
        ctx.restoreGState()
    }

    private func drawMap(_ ctx: CGContext) {
        guard !mapRect.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: mapRect)
        ctx.setFillColor(NSColor.token("map-land").cgColor)
        ctx.fill(mapRect)
        drawGraticule(ctx)

        // Areas first, then lines over them.
        for line in drawLines where line.kind == .polygon {
            let path = projected(line.points, close: true)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.token("map-area").cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.token("map-area2").cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokePath()
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let lines = drawLines.filter { $0.kind != .polygon }
        let heavy = lines.count <= 40
        for line in lines {
            let path = projected(line.points, close: false)
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.token("card").cgColor)
            ctx.setLineWidth(heavy ? 7 : 4.5)
            ctx.strokePath()
        }
        for line in lines {
            let path = projected(line.points, close: false)
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.token(line.kind == .route ? "series-3" : "series-1").cgColor)
            ctx.setLineWidth(heavy ? 4 : 2.5)
            if line.kind == .route { ctx.setLineDash(phase: 0, lengths: [7, 5]) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Where the signal was lost: a dotted caution stretch and one quiet chip on the longest.
        for (a, b) in gaps {
            ctx.move(to: projection.point(a))
            ctx.addLine(to: projection.point(b))
            ctx.setStrokeColor(NSColor.token("caution").cgColor)
            ctx.setLineWidth(3)
            ctx.setLineDash(phase: 0, lengths: [2, 5])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if let longest = gaps.max(by: { Self.haversine($0.0, $0.1) < Self.haversine($1.0, $1.1) }) {
            let a = projection.point(longest.0), b = projection.point(longest.1)
            drawPill(String(localized: "No signal", bundle: .previewKit,
                            comment: "A small chip on a map where a GPS track's segments break: the device lost its signal there."),
                     at: CGPoint(x: (a.x + b.x) / 2 + 10, y: (a.y + b.y) / 2 - 10), fill: "card", border: "caution-line",
                     text: "caution-text", font: tokenFont("fs-caption", weight: 600), ctx: ctx, anchorLeft: true)
        }

        // Start and end of the first track (or the first line when the file has no track).
        let ends = endpoints()
        if let end = ends?.end {
            var p = projection.point(end)
            if let start = ends?.start, hypot(projection.point(start).x - p.x, projection.point(start).y - p.y) < 14 { p.x += 18; p.y += 6 }
            let r = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.setFillColor(NSColor.token("t1").cgColor)
            ctx.setStrokeColor(NSColor.token("card").cgColor)
            ctx.setLineWidth(2.5)
            ctx.drawPath(using: .fillStroke)
        }
        if let start = ends?.start {
            let p = projection.point(start)
            ctx.addEllipse(in: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
            ctx.setFillColor(NSColor.token("map-start").cgColor)
            ctx.setStrokeColor(NSColor.token("card").cgColor)
            ctx.setLineWidth(2.5)
            ctx.drawPath(using: .fillStroke)
        }

        // Waypoints as pins with their names; plain points as small dots when there are no waypoints.
        if summary.waypoints.isEmpty {
            for p in summary.points.prefix(1_000) {
                let q = projection.point(p)
                ctx.addEllipse(in: CGRect(x: q.x - 4, y: q.y - 4, width: 8, height: 8))
                ctx.setFillColor(NSColor.token("accent").cgColor)
                ctx.setStrokeColor(NSColor.token("card").cgColor)
                ctx.setLineWidth(1.5)
                ctx.drawPath(using: .fillStroke)
            }
        } else {
            var taken: [CGRect] = []
            let font = tokenFont("fs-sub", weight: 600)
            for wpt in summary.waypoints.prefix(300) {
                let q = projection.point(wpt.coordinate)
                drawPin(at: q, ctx: ctx)
                guard summary.waypoints.count <= 40, let name = wpt.name, !name.isEmpty else { continue }
                let label = NSAttributedString(string: name, attributes: [.font: font])
                let size = label.size()
                let r = CGRect(x: q.x + 12, y: q.y - 14 - size.height / 2 - 6, width: size.width, height: size.height)
                guard mapRect.insetBy(dx: 4, dy: 4).contains(r), !taken.contains(where: { $0.intersects(r.insetBy(dx: -4, dy: -2)) }) else { continue }
                taken.append(r)
                drawHaloText(name, in: r, font: font, ctx: ctx)
            }
        }

        // The profile's hover lights the same spot on the route.
        if let d = hoverDistance, let spot = coordinate(atProfileDistance: d) {
            let p = projection.point(spot)
            ctx.addEllipse(in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
            ctx.setFillColor(NSColor.token("accent-soft").cgColor)
            ctx.setStrokeColor(NSColor.token("accent").cgColor)
            ctx.setLineWidth(2)
            ctx.drawPath(using: .fillStroke)
            ctx.addEllipse(in: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
            ctx.setFillColor(NSColor.token("accent").cgColor)
            ctx.fillPath()
        }

        drawScaleBar(ctx)
        ctx.restoreGState()
    }

    /// Faint lines at round degrees, about five across the longer side: a calm ground that still tells north.
    private func drawGraticule(_ ctx: CGContext) {
        guard geoBounds != nil else { return }
        let topLeft = projection.coordinate(CGPoint(x: mapRect.minX, y: mapRect.minY))
        let bottomRight = projection.coordinate(CGPoint(x: mapRect.maxX, y: mapRect.maxY))
        let latSpan = topLeft.latitude - bottomRight.latitude, lonSpan = bottomRight.longitude - topLeft.longitude
        guard latSpan > 0, lonSpan > 0, latSpan.isFinite, lonSpan.isFinite else { return }
        // The projection's own longitude factor, held at 0.01 or more near the poles, so the step follows the drawing
        // (S-16 F56: the unclamped cosine at a pole made the step far smaller than the longitudes it divides).
        let step = Self.niceStep(max(latSpan, lonSpan * projection.k) / 5)
        ctx.setStrokeColor(NSColor.token("map-line").cgColor)
        var i = 0
        var lat = (bottomRight.latitude / step).rounded(.down) * step
        while lat <= topLeft.latitude, i < 60 {
            let y = projection.point(MediaCoordinate(latitude: lat, longitude: topLeft.longitude)).y
            ctx.move(to: CGPoint(x: mapRect.minX, y: y)); ctx.addLine(to: CGPoint(x: mapRect.maxX, y: y))
            ctx.setLineWidth(Self.isMajorLine(lat, step: step) ? 1.2 : 0.7)
            ctx.strokePath()
            lat += step; i += 1
        }
        var lon = (topLeft.longitude / step).rounded(.down) * step
        i = 0
        while lon <= bottomRight.longitude, i < 60 {
            let x = projection.point(MediaCoordinate(latitude: topLeft.latitude, longitude: lon)).x
            ctx.move(to: CGPoint(x: x, y: mapRect.minY)); ctx.addLine(to: CGPoint(x: x, y: mapRect.maxY))
            ctx.setLineWidth(Self.isMajorLine(lon, step: step) ? 1.2 : 0.7)
            ctx.strokePath()
            lon += step; i += 1
        }
    }

    /// Every other graticule line, the one at an even multiple of the step, is drawn heavier. Decided in floating
    /// point: `value / step` from a file's coordinates can lie far outside Int's range, where `Int(_:)` traps.
    static func isMajorLine(_ value: Double, step: Double) -> Bool {
        let multiple = (value / step).rounded()
        guard multiple.isFinite else { return false }
        return multiple.truncatingRemainder(dividingBy: 2) == 0
    }

    private func drawScaleBar(_ ctx: CGContext) {
        let metresPerPoint = projection.metresPerPoint
        guard metresPerPoint.isFinite, metresPerPoint > 0 else { return }
        // The round distance whose bar is closest to 80 points long.
        let target = 80 * metresPerPoint
        let p = pow(10, floor(log10(target)))
        let metres = [1.0, 2, 5, 10].map { $0 * p }.min { abs(log($0 / target)) < abs(log($1 / target)) } ?? p
        let width = CGFloat(metres / metresPerPoint)
        guard width > 10, width < mapRect.width / 2 else { return }
        let x = mapRect.maxX - 30 - width, y = mapRect.maxY - 18
        ctx.setFillColor(NSColor.token("t2").withAlphaComponent(0.55).cgColor)
        ctx.fill(CGRect(x: x, y: y, width: width, height: 4))
        let text = Self.distanceText(metres)
        let attributed = NSAttributedString(string: text, attributes: [.font: tokenFont("fs-micro"), .foregroundColor: NSColor.token("t2")])
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: x, y: y - size.height - 1))
    }

    private func drawPin(at p: CGPoint, ctx: CGContext) {
        let pin = CGMutablePath()
        pin.move(to: p)
        pin.addCurve(to: CGPoint(x: p.x - 9, y: p.y - 16), control1: CGPoint(x: p.x - 6, y: p.y - 8), control2: CGPoint(x: p.x - 9, y: p.y - 11))
        pin.addArc(center: CGPoint(x: p.x, y: p.y - 16), radius: 9, startAngle: .pi, endAngle: 0, clockwise: false)
        pin.addCurve(to: p, control1: CGPoint(x: p.x + 9, y: p.y - 11), control2: CGPoint(x: p.x + 6, y: p.y - 8))
        pin.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: NSColor(white: 0, alpha: 0.18).cgColor)
        ctx.addPath(pin)
        ctx.setFillColor(NSColor.token("card").cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(pin)
        ctx.setStrokeColor(NSColor.token("hair").cgColor)
        ctx.setLineWidth(0.8)
        ctx.strokePath()
        ctx.addEllipse(in: CGRect(x: p.x - 3.4, y: p.y - 19.4, width: 6.8, height: 6.8))
        ctx.setFillColor(NSColor.token("accent").cgColor)
        ctx.fillPath()
    }

    /// A name over the map with a halo of the land colour, so it reads over lines.
    private func drawHaloText(_ text: String, in rect: CGRect, font: NSFont, ctx: CGContext) {
        let halo = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.token("map-land"),
                                                                 .strokeColor: NSColor.token("map-land"), .strokeWidth: 6])
        halo.draw(at: rect.origin)
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.token("t1")]).draw(at: rect.origin)
    }

    /// A rounded label; `anchorLeft` puts its left edge at the point, otherwise it is centred on it.
    private func drawPill(_ text: String, at p: CGPoint, fill: String, border: String, text color: String, font: NSFont,
                          ctx: CGContext, anchorLeft: Bool = false, radius: CGFloat? = nil) {
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.token(color)])
        let size = attributed.size()
        let h = ceil(size.height) + 6, w = ceil(size.width) + 18
        var r = CGRect(x: anchorLeft ? p.x : p.x - w / 2, y: p.y - h / 2, width: w, height: h)
        let limit = bounds.insetBy(dx: 4, dy: 4)
        r.origin.x = min(max(r.minX, limit.minX), limit.maxX - w)
        r.origin.y = min(max(r.minY, limit.minY), limit.maxY - h)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius ?? h / 2, cornerHeight: radius ?? h / 2, transform: nil))
        ctx.setFillColor(NSColor.token(fill).cgColor)
        ctx.setStrokeColor(NSColor.token(border).cgColor)
        ctx.setLineWidth(1)
        ctx.drawPath(using: .fillStroke)
        attributed.draw(at: CGPoint(x: r.minX + 9, y: r.minY + (h - size.height) / 2))
    }

    // MARK: Profile

    private func drawProfile(_ ctx: CGContext) {
        let panel = CGPath(roundedRect: profileRect, cornerWidth: Metric.value("r-card"), cornerHeight: Metric.value("r-card"), transform: nil)
        ctx.addPath(panel)
        ctx.setFillColor(NSColor.token("card").cgColor)
        ctx.fillPath()
        ctx.addPath(panel)
        ctx.setStrokeColor(NSColor.token("hair").cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokePath()

        guard let total = profile.last?.distanceMeters, total > 0, plotRect.width > 20, plotRect.height > 20 else { return }
        let lo = profile.map(\.elevationMeters).min() ?? 0, hi = profile.map(\.elevationMeters).max() ?? 0
        let step = Self.niceStep(max(hi - lo, 10) / 2.5)
        let axisLo = (lo / step).rounded(.down) * step - step * 0.25
        let axisHi = max((hi / step).rounded(.up) * step, axisLo + step)
        func x(_ d: Double) -> CGFloat { plotRect.minX + CGFloat(d / total) * plotRect.width }
        func y(_ e: Double) -> CGFloat { plotRect.maxY - CGFloat((e - axisLo) / (axisHi - axisLo)) * plotRect.height }

        // Grid lines with their heights at the right, as the design draws them.
        let small = tokenFont("fs-micro")
        var level = (axisLo / step).rounded(.up) * step
        var drawn = 0
        while level <= axisHi + 0.001, drawn < 6 {
            let yy = y(level)
            if yy >= plotRect.minY + 12, yy <= plotRect.maxY - 6 {
                ctx.move(to: CGPoint(x: plotRect.minX, y: yy)); ctx.addLine(to: CGPoint(x: plotRect.maxX, y: yy))
                ctx.setStrokeColor(NSColor.token("sep").cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
                let label = NSAttributedString(string: Self.heightText(level), attributes: [.font: small, .foregroundColor: NSColor.token("t3")])
                let size = label.size()
                label.draw(at: CGPoint(x: plotRect.maxX - size.width, y: yy - size.height - 1))
            }
            level += step; drawn += 1
        }

        // Where the signal was lost, a caution band (the stretch itself has no samples, so it is a few points wide).
        if let walked = walk.last?.1, walked > 0 {
            for g in gapWalkDistances {
                let gx = x(g / walked * total)
                ctx.setFillColor(NSColor.token("caution-soft").cgColor)
                ctx.fill(CGRect(x: gx - 5, y: plotRect.minY, width: 10, height: plotRect.height))
            }
        }

        let line = CGMutablePath()
        for (i, s) in profile.enumerated() {
            let p = CGPoint(x: x(s.distanceMeters), y: y(s.elevationMeters))
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        let area = line.mutableCopy()!
        area.addLine(to: CGPoint(x: x(total), y: plotRect.maxY))
        area.addLine(to: CGPoint(x: x(profile[0].distanceMeters), y: plotRect.maxY))
        area.closeSubpath()
        ctx.addPath(area)
        ctx.setFillColor(NSColor.token("series-1-soft").cgColor)
        ctx.fillPath()
        ctx.addPath(area)
        ctx.setFillColor(NSColor.token("series-1").withAlphaComponent(0.10).cgColor)
        ctx.fillPath()
        ctx.addPath(line)
        ctx.setStrokeColor(NSColor.token("series-1").cgColor)
        ctx.setLineWidth(1.8)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        // Distance ticks along the bottom: 0 km, round steps, the total.
        let tickFont = tokenFont("fs-micro")
        let tickY = plotRect.maxY + 5
        let kmStep = Self.tickStep(total, ticks: 4)
        var labels: [(Double, String)] = [(0, Self.distanceText(0, unitOf: total))]
        var d = kmStep
        while d < total - kmStep * 0.5 { labels.append((d, Self.distanceNumber(d, unitOf: total))); d += kmStep }
        labels.append((total, Self.distanceText(total)))
        for (i, (dist, text)) in labels.enumerated() {
            let label = NSAttributedString(string: text, attributes: [.font: tickFont, .foregroundColor: NSColor.token("t2")])
            let w = label.size().width
            let px: CGFloat = i == 0 ? x(dist) : i == labels.count - 1 ? x(dist) - w : x(dist) - w / 2
            label.draw(at: CGPoint(x: px, y: tickY))
        }

        if let hd = hoverDistance, let e = Self.elevation(at: hd, in: profile) {
            let hx = x(hd), hy = y(e)
            ctx.move(to: CGPoint(x: hx, y: plotRect.minY)); ctx.addLine(to: CGPoint(x: hx, y: plotRect.maxY))
            ctx.setStrokeColor(NSColor.token("accent").cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.addEllipse(in: CGRect(x: hx - 4, y: hy - 4, width: 8, height: 8))
            ctx.setFillColor(NSColor.token("card").cgColor)
            ctx.setStrokeColor(NSColor.token("accent").cgColor)
            ctx.setLineWidth(2)
            ctx.drawPath(using: .fillStroke)
            let text = "\(Self.distanceText(hd)) · \(Self.heightText(e))"
            let font = tokenFont("fs-caption", weight: 600)
            let w = NSAttributedString(string: text, attributes: [.font: font]).size().width + 18
            let left = hx + 8 + w > plotRect.maxX
            drawPill(text, at: CGPoint(x: left ? hx - 8 - w : hx + 8, y: plotRect.minY + 8), fill: "card", border: "hair",
                     text: "t1", font: font, ctx: ctx, anchorLeft: true, radius: 6)
        }
    }

    // MARK: Geometry

    private func projected(_ points: [MediaCoordinate], close: Bool) -> CGPath {
        let path = CGMutablePath()
        for (i, p) in points.enumerated() {
            let q = projection.point(p)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        if close { path.closeSubpath() }
        return path
    }

    private func endpoints() -> (start: MediaCoordinate, end: MediaCoordinate)? {
        let tracks = summary.lines.filter { $0.kind == .track && !$0.points.isEmpty }
        if let first = tracks.first?.points.first {
            // The end is where the first track's last segment ends (segments of one track are joined by its gaps).
            let group = summary.tracks.count == 1 ? tracks : tracks.filter { $0.name == tracks[0].name }
            if let last = (group.last ?? tracks[0]).points.last { return (first, last) }
        }
        if let line = drawLines.first(where: { $0.kind != .polygon }), let a = line.points.first, let b = line.points.last { return (a, b) }
        return nil
    }

    /// The point on the track at a profile distance; the drawn (simplified) track is shorter than the file's, so the
    /// distance is taken as a share of the whole.
    func coordinate(atProfileDistance d: Double) -> MediaCoordinate? {
        guard let total = profile.last?.distanceMeters, total > 0, let walked = walk.last?.1, walked > 0 else { return nil }
        let target = min(1, max(0, d / total)) * walked
        var lo = 0, hi = walk.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if walk[mid].1 < target { lo = mid + 1 } else { hi = mid } }
        guard lo > 0 else { return walk[0].0 }
        let (a, da) = walk[lo - 1], (b, db) = walk[lo]
        let t = db > da ? (target - da) / (db - da) : 0
        return MediaCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    static func elevation(at d: Double, in profile: [MediaElevationSample]) -> Double? {
        guard let first = profile.first else { return nil }
        if d <= first.distanceMeters { return first.elevationMeters }
        for (a, b) in zip(profile, profile.dropFirst()) where d <= b.distanceMeters {
            let span = b.distanceMeters - a.distanceMeters
            return span > 0 ? a.elevationMeters + (b.elevationMeters - a.elevationMeters) * (d - a.distanceMeters) / span : b.elevationMeters
        }
        return profile.last?.elevationMeters
    }

    static func haversine(_ a: MediaCoordinate, _ b: MediaCoordinate) -> Double {
        let r = 6_371_008.8
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    static func bounds(of points: [MediaCoordinate]) -> MediaBounds? {
        guard let first = points.first else { return nil }
        var b = MediaBounds(minLatitude: first.latitude, minLongitude: first.longitude, maxLatitude: first.latitude, maxLongitude: first.longitude)
        for p in points {
            b.minLatitude = min(b.minLatitude, p.latitude); b.maxLatitude = max(b.maxLatitude, p.latitude)
            b.minLongitude = min(b.minLongitude, p.longitude); b.maxLongitude = max(b.maxLongitude, p.longitude)
        }
        return b
    }

    static func midLatitude(_ b: MediaBounds) -> Double { (b.minLatitude + b.maxLatitude) / 2 }

    /// 1, 2 or 5 times a power of ten, at or above `x`.
    static func niceStep(_ x: Double) -> Double {
        guard x.isFinite, x > 0 else { return 1 }
        let p = pow(10, floor(log10(x)))
        for m in [1.0, 2, 5, 10] where m * p >= x { return m * p }
        return 10 * p
    }

    /// 1, 2 or 5 times a power of ten that cuts `span` into the number of pieces closest to `ticks`.
    static func tickStep(_ span: Double, ticks: Double) -> Double {
        guard span.isFinite, span > 0 else { return 1 }
        let p = pow(10, floor(log10(span / ticks)))
        return [1.0, 2, 5, 10].map { $0 * p }.min { abs(span / $0 - ticks) < abs(span / $1 - ticks) } ?? p
    }

    // MARK: Text (Foundation's measurement formatting, so units and digits follow the locale)

    static func distanceText(_ metres: Double, unitOf reference: Double? = nil) -> String {
        let km = (reference ?? metres) >= 1_000
        let value = km ? Measurement(value: metres / 1_000, unit: UnitLength.kilometers) : Measurement(value: metres, unit: UnitLength.meters)
        let digits = km && metres / 1_000 < 100 ? 1 : 0
        return value.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...digits))))
    }

    static func distanceNumber(_ metres: Double, unitOf reference: Double) -> String {
        let value = reference >= 1_000 ? metres / 1_000 : metres
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func heightText(_ metres: Double) -> String {
        Measurement(value: metres, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    // MARK: Projection

    /// Equirectangular: x is longitude times the cosine of the middle latitude, y is latitude (down the view).
    struct Projection {
        var originLon = 0.0, originLat = 0.0, k = 1.0, scale = 1.0
        var offset = CGPoint.zero

        static let identity = Projection()

        init() {}

        init(bounds: MediaBounds?, into rect: CGRect, padding: CGFloat) {
            guard let b = bounds, rect.width > 0, rect.height > 0 else { return }
            let mid = (b.minLatitude + b.maxLatitude) / 2
            k = max(0.01, cos(mid * .pi / 180))
            // A single point or a tiny file still gets a little ground around it (about 500 m).
            let minSpan = 0.005
            let latSpan = max(b.maxLatitude - b.minLatitude, minSpan)
            let lonSpan = max((b.maxLongitude - b.minLongitude) * k, minSpan)
            let pad = min(padding, rect.width / 6, rect.height / 6)
            scale = min(Double(rect.width - 2 * pad) / lonSpan, Double(rect.height - 2 * pad) / latSpan)
            originLon = (b.minLongitude + b.maxLongitude) / 2
            originLat = mid
            offset = CGPoint(x: rect.midX, y: rect.midY)
        }

        func point(_ c: MediaCoordinate) -> CGPoint {
            CGPoint(x: offset.x + CGFloat((c.longitude - originLon) * k * scale),
                    y: offset.y - CGFloat((c.latitude - originLat) * scale))
        }

        func coordinate(_ p: CGPoint) -> MediaCoordinate {
            MediaCoordinate(latitude: originLat - Double(p.y - offset.y) / scale,
                            longitude: originLon + Double(p.x - offset.x) / (k * scale))
        }

        /// Metres one point covers (a degree of latitude is about 111.32 km).
        var metresPerPoint: Double { 111_320 / scale }
    }
}
