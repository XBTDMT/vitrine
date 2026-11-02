import AppKit
import SceneKit
import XCTest
@testable import VitrinePreviewKit
import VitrineFormats

/// The map and 3D stage views (S-23, format views F1 and F2, picked A), built from invented files read by the real
/// readers, laid out at 900 × 420 in an offscreen window, drawn in light and dark, and written as PNGs to the temporary
/// folder (paths printed) so they can be compared with the design. roadmap: S-23
@MainActor
final class FormatViewsMapModelTests: XCTestCase {
    // MARK: Invented files

    /// A loop ride: two segments of one track (the GPS lost its signal in between), elevation and times, waypoints.
    static func gpx(withElevation: Bool = true) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Invented Bike Computer" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><name>Saturday loop — Hollow Ridge</name></metadata>
        <wpt lat="45.0420" lon="6.0070"><name>Twin Falls</name></wpt>
        <wpt lat="45.0350" lon="6.0880"><name>Hollow Lookout</name></wpt>
        <wpt lat="44.9930" lon="6.0450"><name>Fern Bridge</name></wpt>
        <trk><name>Saturday loop</name><trkseg>

        """
        let start = Date(timeIntervalSince1970: 1_792_828_800)
        let n = 360, gapFrom = 196, gapTo = 210
        let formatter = ISO8601DateFormatter()
        for i in 0..<n {
            if i >= gapFrom && i < gapTo { continue }
            if i == gapTo { xml += "</trkseg><trkseg>\n" }
            let t = Double(i) / Double(n) * 2 * .pi
            let lat = 45.015 + 0.028 * sin(t) + 0.004 * sin(3 * t)
            let lon = 6.045 - 0.055 * cos(t) + 0.006 * cos(2 * t)
            let ele = 180 + 90 * sin(t * 1.3) + 25 * sin(t * 5) + 40 * sin(t * 0.5)
            let time = formatter.string(from: start.addingTimeInterval(Double(i) * 18.7))
            xml += "<trkpt lat=\"\(lat)\" lon=\"\(lon)\">" + (withElevation ? "<ele>\(ele)</ele>" : "") + "<time>\(time)</time></trkpt>\n"
        }
        xml += "</trkseg></trk></gpx>\n"
        return Data(xml.utf8)
    }

    /// A wall bracket as a binary STL: a base plate, an upright back wall and a gusset, 84 × 40 × 28 mm.
    static func stl() -> Data {
        var triangles: [[Float]] = []
        func box(_ x0: Float, _ y0: Float, _ z0: Float, _ x1: Float, _ y1: Float, _ z1: Float) {
            let v: [[Float]] = [[x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0], [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]]
            let faces = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4), (2, 3, 7), (2, 7, 6), (1, 2, 6), (1, 6, 5), (0, 4, 7), (0, 7, 3)]
            for f in faces { triangles.append(v[f.0] + v[f.1] + v[f.2]) }
        }
        box(0, 0, 0, 84, 40, 6)       // base plate
        box(0, 34, 6, 84, 40, 28)     // back wall
        // A triangular gusset in the middle, as a small wedge of triangles.
        let g: [[Float]] = [[38, 34, 6], [46, 34, 6], [46, 14, 6], [38, 14, 6], [38, 34, 24], [46, 34, 24]]
        for f in [(0, 1, 5), (0, 5, 4), (3, 4, 5), (3, 5, 2), (0, 4, 3), (1, 2, 5), (0, 3, 2), (0, 2, 1)] {
            triangles.append(g[f.0] + g[f.1] + g[f.2])
        }
        var data = Data(count: 80)
        var count = UInt32(triangles.count).littleEndian
        data.append(Data(bytes: &count, count: 4))
        for t in triangles {
            var floats: [Float] = [0, 0, 0] + t
            data.append(floats.withUnsafeMutableBytes { Data($0) })
            data.append(contentsOf: [0, 0])
        }
        return data
    }

    /// A glTF whose buffer is a separate file (never read): the view shows its bounds and counts.
    static func gltf() -> Data {
        let json = """
        {"asset":{"version":"2.0","generator":"Invented Exporter"},
         "scenes":[{"nodes":[0]}],"nodes":[{"mesh":0},{"mesh":1}],
         "meshes":[{"name":"Chair seat","primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]},
                   {"name":"Chair legs","primitives":[{"attributes":{"POSITION":2},"indices":3,"material":1}]}],
         "materials":[{"name":"Oak"},{"name":"Steel"}],
         "accessors":[{"bufferView":0,"componentType":5126,"count":2400,"type":"VEC3","min":[-0.23,0.42,-0.22],"max":[0.23,0.48,0.22]},
                      {"bufferView":1,"componentType":5123,"count":7200,"type":"SCALAR"},
                      {"bufferView":2,"componentType":5126,"count":1800,"type":"VEC3","min":[-0.22,0.0,-0.21],"max":[0.22,0.88,0.21]},
                      {"bufferView":3,"componentType":5123,"count":5400,"type":"SCALAR"}],
         "bufferViews":[{"buffer":0,"byteLength":28800},{"buffer":0,"byteLength":14400},{"buffer":0,"byteLength":21600},{"buffer":0,"byteLength":10800}],
         "buffers":[{"uri":"chair.bin","byteLength":75600}]}
        """
        return Data(json.utf8)
    }

    // MARK: Helpers

    private func mapSummary(_ data: Data, name: String = "Saturday loop — Hollow Ridge.gpx") throws -> MediaMapSummary {
        guard case .map(let s)? = MediaReader.read(data: data, fileName: name) else { throw XCTSkip("not read as a map") }
        return s
    }

    private func modelSummary(_ data: Data, name: String) throws -> MediaModelSummary {
        guard case .model(let s)? = MediaReader.read(data: data, fileName: name) else { throw XCTSkip("not read as a model") }
        return s
    }

    /// Puts the view on a stage (the card's StageView) in an offscreen window of 900 × 420.
    private func host(_ view: NSView, appearance: NSAppearance.Name) -> (NSWindow, StageView) {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 420), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let stage = StageView()
        stage.translatesAutoresizingMaskIntoConstraints = true
        stage.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        window.contentView = stage
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = stage.bounds
        stage.addSubview(view)
        stage.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        return (window, stage)
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = image.size
        return rep
    }

    @discardableResult
    private func write(_ rep: NSBitmapImageRep, _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitrine-formatviews-\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("FORMAT VIEW PNG: \(url.path)")
        return url
    }

    /// The bitmap as 8-bit sRGB RGBA, top row first, with its scale (pixels per point).
    private struct Pixels {
        let width: Int, height: Int, scale: CGFloat
        let bytes: [UInt8]
        init(_ rep: NSBitmapImageRep) {
            let width = rep.pixelsWide, height = rep.pixelsHigh
            self.width = width; self.height = height; scale = CGFloat(rep.pixelsWide) / rep.size.width
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            if let cg = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) {
                buffer.withUnsafeMutableBytes { raw in
                    let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
            }
            bytes = buffer
        }
        func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
            let i = (y * width + x) * 4
            return (CGFloat(bytes[i]) / 255, CGFloat(bytes[i + 1]) / 255, CGFloat(bytes[i + 2]) / 255)
        }
        /// Pixels in `rect` (points, top-left origin), every other one, for which `test` holds.
        func count(in rect: CGRect, where test: ((CGFloat, CGFloat, CGFloat)) -> Bool) -> Int {
            var n = 0
            for y in stride(from: max(0, Int(rect.minY * scale)), to: min(height, Int(rect.maxY * scale)), by: 2) {
                for x in stride(from: max(0, Int(rect.minX * scale)), to: min(width, Int(rect.maxX * scale)), by: 2) where test(rgb(x, y)) { n += 1 }
            }
            return n
        }
    }

    private func components(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let s = c.usingColorSpace(.sRGB) ?? c
        return (s.redComponent, s.greenComponent, s.blueComponent)
    }

    /// How many pixels in `rect` are within `tolerance` of `color` per channel.
    private func count(_ rep: NSBitmapImageRep, in rect: CGRect, near color: NSColor, tolerance: CGFloat = 0.12) -> Int {
        let t = components(color)
        return Pixels(rep).count(in: rect) { abs($0.0 - t.0) <= tolerance && abs($0.1 - t.1) <= tolerance && abs($0.2 - t.2) <= tolerance }
    }

    /// Pixels in `rect` that differ from `background` by more than `threshold` in any channel.
    private func differing(_ rep: NSBitmapImageRep, in rect: CGRect, from background: (CGFloat, CGFloat, CGFloat), threshold: CGFloat = 0.08) -> Int {
        Pixels(rep).count(in: rect) { abs($0.0 - background.0) > threshold || abs($0.1 - background.1) > threshold || abs($0.2 - background.2) > threshold }
    }

    private func resolved(_ token: String, _ appearance: NSAppearance.Name) -> NSColor {
        var c = NSColor.clear
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance { c = NSColor.token(token).usingColorSpace(.sRGB) ?? .clear }
        return c
    }

    // MARK: Map

    func testMapDrawsRouteMarkersAndElevationStrip() throws {
        let summary = try mapSummary(Self.gpx())
        XCTAssertGreaterThanOrEqual(summary.lines.count, 2, "two segments draw as two lines")
        XCTAssertGreaterThan(summary.elevationProfile.count, 50)
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = MapStageView(summary: summary)
            let (window, stage) = host(view, appearance: appearance)
            defer { window.close() }
            XCTAssertFalse(view.profileRect.isEmpty, "the elevation strip has room at 420 tall")
            XCTAssertTrue(view.bounds.contains(view.profileRect) && view.bounds.contains(view.mapRect), "nothing outside the bounds")
            XCTAssertLessThanOrEqual(view.mapRect.maxY, view.profileRect.minY)
            let rep = try bitmap(stage)
            try write(rep, "map-\(mode)")

            let series = resolved("series-1", appearance)
            let onMap = count(rep, in: view.mapRect, near: series)
            let onProfile = count(rep, in: view.profileRect, near: series)
            XCTAssertGreaterThan(onMap, 300, "\(mode): the route is drawn on the map")
            XCTAssertGreaterThan(onProfile, 100, "\(mode): the elevation line is drawn in the strip")
            XCTAssertGreaterThan(count(rep, in: view.mapRect, near: resolved("map-land", appearance), tolerance: 0.02), 20_000,
                                 "\(mode): the calm map ground fills the map")
            XCTAssertGreaterThan(count(rep, in: view.mapRect, near: resolved("map-start", appearance), tolerance: 0.08), 10, "\(mode): start marker")
            XCTAssertGreaterThan(count(rep, in: view.mapRect, near: resolved("caution", appearance), tolerance: 0.1), 10, "\(mode): the no-signal stretch")

            // Hover state: the profile's pointer lights the same spot on the map.
            view.hoverDistance = (summary.elevationProfile.last?.distanceMeters ?? 0) * 0.38
            XCTAssertNotNil(view.coordinate(atProfileDistance: view.hoverDistance!))
            view.display()
            let hovered = try bitmap(stage)
            try write(hovered, "map-hover-\(mode)")
            XCTAssertGreaterThan(count(hovered, in: view.profileRect, near: resolved("accent", appearance), tolerance: 0.08), 10)
        }
    }

    func testMapWithoutElevationGivesTheWholeStageToTheMap() throws {
        let summary = try mapSummary(Self.gpx(withElevation: false))
        let view = MapStageView(summary: summary)
        let (window, stage) = host(view, appearance: .aqua)
        defer { window.close() }
        XCTAssertTrue(view.profileRect.isEmpty)
        XCTAssertEqual(view.mapRect, view.bounds)
        let rep = try bitmap(stage)
        try write(rep, "map-noelevation-light")
        XCTAssertGreaterThan(count(rep, in: view.mapRect, near: resolved("series-1", .aqua)), 300)
    }

    func testMapProjectionKeepsShapeAndFitsBounds() {
        let b = MediaBounds(minLatitude: 60, minLongitude: 10, maxLatitude: 61, maxLongitude: 12)
        let rect = CGRect(x: 0, y: 0, width: 900, height: 300)
        let p = MapStageView.Projection(bounds: b, into: rect, padding: 40)
        let a = p.point(MediaCoordinate(latitude: 60, longitude: 10)), c = p.point(MediaCoordinate(latitude: 61, longitude: 12))
        // At 60.5° a degree of longitude is about half a degree of latitude: the box is about as wide as tall.
        XCTAssertEqual(abs(c.x - a.x) / abs(c.y - a.y), 2 * cos(60.5 * .pi / 180), accuracy: 0.01)
        XCTAssertTrue(rect.insetBy(dx: 39, dy: 39).contains(a) && rect.insetBy(dx: 39, dy: 39).contains(c))
        XCTAssertEqual(MapStageView.niceStep(0.37), 0.5)
        XCTAssertEqual(MapStageView.niceStep(1_400), 2_000)
    }

    // MARK: Model

    func testModelStageDrawsTheLitPartWithCallouts() throws {
        let summary = try modelSummary(Self.stl(), name: "wall-bracket-v3.stl")
        XCTAssertNotNil(summary.mesh)
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = ModelStageView(summary: summary, fileURL: URL(fileURLWithPath: "/tmp/wall-bracket-v3.stl"))
            let (window, stage) = host(view, appearance: appearance)
            defer { window.close() }
            XCTAssertTrue(view.drawsMesh)
            XCTAssertTrue(view.isZUp)
            XCTAssertEqual(view.pills.count, 3)
            XCTAssertEqual(Set(view.pills.map(\.view.label.stringValue)), ["84 mm", "40 mm", "28 mm"])

            // The stage behind, then the rendered scene with its overlays.
            view.isHidden = true
            let background = try bitmap(stage)
            view.isHidden = false
            let image = try XCTUnwrap(view.renderedImage())
            let composite = NSImage(size: stage.bounds.size)
            composite.lockFocus()
            background.draw(in: stage.bounds)
            image.draw(in: stage.bounds)
            composite.unlockFocus()
            let rep = try bitmap(composite)
            try write(rep, "model-\(mode)")

            let stageColor = Pixels(rep).rgb(8, rep.pixelsHigh / 2)
            let middle = CGRect(x: 300, y: 110, width: 300, height: 200)
            XCTAssertGreaterThan(differing(rep, in: middle, from: stageColor), 2_000, "\(mode): the part is drawn in the middle of the stage")
            for (pill, _) in view.pills {
                XCTAssertFalse(pill.isHidden)
                XCTAssertTrue(view.bounds.contains(pill.frame), "\(mode): callout \(pill.label.stringValue) inside the stage")
            }
            let wire = view.scnView.scene?.rootNode.childNodes.contains { $0.geometry?.elements.first?.primitiveType == .line } ?? false
            XCTAssertTrue(wire, "the callout lines are in the scene")
        }
    }

    func testGLTFWithoutMeshShowsItsBoundsAndCounts() throws {
        let summary = try modelSummary(Self.gltf(), name: "chair.gltf")
        XCTAssertNil(summary.mesh)
        XCTAssertNotNil(summary.bounds)
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = ModelStageView(summary: summary, fileURL: URL(fileURLWithPath: "/tmp/chair.gltf"))
            let (window, stage) = host(view, appearance: appearance)
            defer { window.close() }
            XCTAssertFalse(view.drawsMesh)
            let caption = try XCTUnwrap(view.caption)
            XCTAssertTrue(caption.label.stringValue.contains("2"), caption.label.stringValue)
            XCTAssertTrue(view.bounds.contains(caption.frame))
            XCTAssertEqual(view.pills.count, 3)
            XCTAssertTrue(view.pills.contains { $0.view.label.stringValue == "0.88 m" })

            view.isHidden = true
            let background = try bitmap(stage)
            view.isHidden = false
            let image = try XCTUnwrap(view.renderedImage())
            let composite = NSImage(size: stage.bounds.size)
            composite.lockFocus()
            background.draw(in: stage.bounds)
            image.draw(in: stage.bounds)
            composite.unlockFocus()
            let rep = try bitmap(composite)
            try write(rep, "model-gltf-\(mode)")
            let stageColor = Pixels(rep).rgb(8, rep.pixelsHigh / 2)
            XCTAssertGreaterThan(differing(rep, in: CGRect(x: 330, y: 80, width: 240, height: 240), from: stageColor, threshold: 0.04), 500,
                                 "\(mode): the bounds box is drawn")
        }
    }

    func testFlatNormalsPointOutOfEachFace() throws {
        let mesh = MediaReader.read(data: Self.stl(), fileName: "b.stl").flatMap { doc -> MediaMesh? in
            if case .model(let s) = doc { return s.mesh } else { return nil }
        }
        let geometry = try XCTUnwrap(ModelStageView.geometry(try XCTUnwrap(mesh)))
        let normals = try XCTUnwrap(geometry.sources(for: .normal).first)
        XCTAssertEqual(normals.vectorCount, try XCTUnwrap(mesh).triangleCount * 3)
        // The base plate's bottom face (first triangle, wound clockwise from above) faces down: -z.
        let z = normals.data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Float.self) }
        XCTAssertEqual(z, -1, accuracy: 0.001)
    }
}
