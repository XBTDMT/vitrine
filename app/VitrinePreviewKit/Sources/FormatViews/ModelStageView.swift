import AppKit
import SceneKit
import VitrineFormats
import VitrineUI

/// The 3D model on the card's stage (S-23, format view F2, picked A): the part alone on the lit stage, lit by a soft
/// key light with a floor shadow and a faint floor grid, turnable (drag to orbit, scroll to zoom), with size callouts
/// along its edges, an axis gizmo, a hint chip and a Lit / Wire / Fit switch. The geometry is the reader's decimated
/// mesh (STL, OBJ, 3MF) with flat normals; a glTF or GLB file, whose buffers are not read here, is shown as its
/// bounding box with its counts. Nothing is fetched and no file is written; the scene draws the card's stage
/// gradient (the `stage` token) as its own background, so it sits seamlessly on the card's stage. roadmap: S-23
@MainActor
final class ModelStageView: NSView {
    let summary: MediaModelSummary
    let fileURL: URL

    let scnView: SCNView
    private let scene = SCNScene()
    /// Holds the model (or its box), turned so the file's up axis is up, scaled so its largest side is 1.
    private(set) var modelNode = SCNNode()
    private let cameraNode = SCNNode()
    private var homeTransform = SCNMatrix4Identity
    private var target = SCNVector3Zero
    private var modelMaterial: SCNMaterial?
    private let gridNode = SCNNode()
    private let calloutLines = SCNNode()

    /// Overlays drawn by AppKit above the 3D view: callout pills, gizmo, hint chip, the mode switch, the caption.
    private let overlay = OverlayView()
    private(set) var pills: [(view: CalloutPill, anchor: SCNVector3)] = []
    private let gizmo = AxisGizmoView()
    private let hint: ChipView
    private(set) var modes: ModeSwitch!
    private(set) var caption: ChipView?
    private var watcher: RenderWatcher?
    private var lastCamera: SCNMatrix4?

    /// True when the view draws the reader's mesh; false when it shows the bounds box (glTF, GLB, no mesh).
    private(set) var drawsMesh = false

    init(summary: MediaModelSummary, fileURL: URL) {
        self.summary = summary
        self.fileURL = fileURL
        scnView = SCNView(frame: .zero, options: nil)
        hint = ChipView(text: String(localized: "Drag to turn · scroll to zoom", bundle: .previewKit,
                                     comment: "The glass hint chip on a 3D model's stage: how to turn and zoom the model."),
                        symbol: "rotate.3d", fill: "glass", textColor: "t2", border: "hair")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        scnView.scene = scene
        scnView.wantsLayer = true
        scnView.antialiasingMode = .multisampling4X
        scnView.allowsCameraControl = true
        scnView.rendersContinuously = false
        scnView.autoresizingMask = [.width, .height]
        addSubview(scnView)

        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        overlay.addSubview(gizmo)
        overlay.addSubview(hint)
        modes = ModeSwitch(titles: [
            String(localized: "Lit", bundle: .previewKit, comment: "3D stage mode switch: the shaded model."),
            String(localized: "Wire", bundle: .previewKit, comment: "3D stage mode switch: the model's triangles as lines."),
            String(localized: "Fit", bundle: .previewKit, comment: "3D stage button: turn the camera back to the first view."),
        ]) { [weak self] index in self?.modeChosen(index) }
        overlay.addSubview(modes)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
        ])

        buildScene()
        refreshColors()
        let watcher = RenderWatcher { [weak self] in
            Task { @MainActor in self?.cameraMaybeMoved() }
        }
        self.watcher = watcher
        scnView.delegate = watcher

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(summary.title ?? fileURL.lastPathComponent)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func layout() {
        super.layout()
        scnView.frame = bounds
        overlay.frame = bounds
        gizmo.frame = CGRect(x: 12, y: 8, width: 54, height: 54)
        let size = modes.fittingSize
        modes.frame = CGRect(x: bounds.maxX - 12 - size.width, y: 12, width: size.width, height: size.height)
        updateOverlays()
    }

    // MARK: Scene

    /// The model's size in the file's own axes (width, depth, height for a Z-up format).
    private var box: MediaBox3? { summary.bounds ?? meshBounds }
    private lazy var meshBounds: MediaBox3? = {
        guard let p = summary.mesh?.positions, p.count >= 9 else { return nil }
        var lo = [Float.infinity, .infinity, .infinity], hi = [-Float.infinity, -.infinity, -.infinity]
        for i in stride(from: 0, to: p.count - 2, by: 3) {
            for k in 0..<3 where p[i + k].isFinite { lo[k] = min(lo[k], p[i + k]); hi[k] = max(hi[k], p[i + k]) }
        }
        guard lo[0] <= hi[0], lo[1] <= hi[1], lo[2] <= hi[2] else { return nil }
        return MediaBox3(min: MediaVector3(x: Double(lo[0]), y: Double(lo[1]), z: Double(lo[2])),
                         max: MediaVector3(x: Double(hi[0]), y: Double(hi[1]), z: Double(hi[2])))
    }()

    /// STL and 3MF are Z-up (the printing world); OBJ and glTF are Y-up.
    var isZUp: Bool { summary.format.hasPrefix("STL") || summary.format == "3MF" }

    private func buildScene() {
        scene.rootNode.addChildNode(modelNode)
        let content = SCNNode()
        modelNode.addChildNode(content)

        var size = SIMD3<Double>(1, 1, 1)
        var center = SIMD3<Double>(0, 0, 0)
        if let b = box {
            size = SIMD3(max(b.size.x, 0), max(b.size.y, 0), max(b.size.z, 0))
            center = SIMD3((b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, (b.min.z + b.max.z) / 2)
        }
        let largest = max(size.x, size.y, size.z)
        let scale = largest > 0 && largest.isFinite ? 1 / largest : 1
        content.position = SCNVector3(-center.x, -center.y, -center.z)
        modelNode.scale = SCNVector3(scale, scale, scale)
        if isZUp { modelNode.eulerAngles.x = -.pi / 2 }

        if let mesh = summary.mesh, mesh.triangleCount > 0, let geometry = Self.geometry(mesh) {
            let material = SCNMaterial()
            material.lightingModel = .blinn
            material.diffuse.contents = NSColor(srgbRed: 0.86, green: 0.88, blue: 0.91, alpha: 1)
            material.specular.contents = NSColor(white: 0.25, alpha: 1)
            material.shininess = 0.2
            material.isDoubleSided = true
            geometry.materials = [material]
            modelMaterial = material
            let node = SCNNode(geometry: geometry)
            node.castsShadow = false
            content.addChildNode(node)
            drawsMesh = true
        } else if box != nil {
            let boxNode = boundsBox(size: size)
            boxNode.position = SCNVector3(center.x, center.y, center.z)   // the content node moves the centre to the origin
            content.addChildNode(boxNode)
            caption = makeCaption()
        } else {
            caption = makeCaption()
        }
        if let caption {
            overlay.addSubview(caption)
            let fit = caption.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -12)
            fit.priority = .defaultHigh
            NSLayoutConstraint.activate([
                caption.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 12),
                caption.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12), fit,
            ])
        }

        // World extents after turning and scaling: half width (x), height (y), half depth (z).
        let world: SIMD3<Double> = isZUp ? SIMD3(size.x, size.z, size.y) * scale : size * scale
        let hx = world.x / 2, hy = world.y / 2, hz = world.z / 2
        // Stand the model on the floor (y = 0).
        modelNode.position = SCNVector3(0, hy, 0)
        target = SCNVector3(0, hy, 0)

        // The floor: a soft contact shadow under the footprint (the design's blurred ellipse, cheaper and steadier
        // than a shadow map) and a faint grid that fades out.
        let blob = SCNNode(geometry: SCNPlane(width: max(0.2, 2 * hx * 1.45), height: max(0.2, 2 * hz * 1.7)))
        blob.eulerAngles.x = -.pi / 2
        blob.position = SCNVector3(0, 0.001, 0)
        blob.castsShadow = false
        blob.renderingOrder = -5
        let blobMaterial = SCNMaterial()
        blobMaterial.lightingModel = .constant
        blobMaterial.diffuse.contents = NSColor(srgbRed: 0.08, green: 0.12, blue: 0.2, alpha: 1)
        blobMaterial.transparent.contents = Self.blobImage()
        blobMaterial.transparencyMode = .aOne
        blobMaterial.writesToDepthBuffer = false
        blob.geometry?.materials = [blobMaterial]
        blob.isHidden = box == nil
        scene.rootNode.addChildNode(blob)

        gridNode.position = SCNVector3(0, -0.002, 0)
        gridNode.castsShadow = false
        gridNode.renderingOrder = -10
        gridNode.isHidden = box == nil
        scene.rootNode.addChildNode(gridNode)

        // Lights: a soft key from the upper front left, a fill from the right, ambient.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.position = SCNVector3(-1.2, 3.0, 1.6)
        key.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 260
        fill.position = SCNVector3(2.5, 1.0, 0.5)
        fill.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fill)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 260
        scene.rootNode.addChildNode(ambient)

        // Size callouts along three edges: width at the front bottom, depth at the right bottom, height at the
        // front left, a little outside the box.
        if box != nil, let b = box {
            let off = 0.06
            let unit = unitSymbol
            let widthText = Self.lengthText(b.size.x, unit: unit)
            let depthText = Self.lengthText(isZUp ? b.size.y : b.size.z, unit: unit)
            let heightText = Self.lengthText(isZUp ? b.size.z : b.size.y, unit: unit)
            let w0 = SCNVector3(-hx, 0.002, hz + off), w1 = SCNVector3(hx, 0.002, hz + off)
            let d0 = SCNVector3(hx + off, 0.002, -hz), d1 = SCNVector3(hx + off, 0.002, hz)
            let h0 = SCNVector3(-hx - off, 0, hz), h1 = SCNVector3(-hx - off, 2 * hy, hz)
            calloutLines.geometry = Self.lines([(w0, w1), (d0, d1), (h0, h1)], ticks: 0.025)
            calloutLines.castsShadow = false
            scene.rootNode.addChildNode(calloutLines)
            for (text, a, c) in [(widthText, w0, w1), (depthText, d0, d1), (heightText, h0, h1)] {
                let pill = CalloutPill(text: text)
                overlay.addSubview(pill)
                pills.append((pill, SCNVector3((a.x + c.x) / 2, (a.y + c.y) / 2, (a.z + c.z) / 2)))
            }
        }

        // Camera: from the front right and above, framing the bounding sphere.
        let camera = SCNCamera()
        camera.fieldOfView = 28
        camera.zNear = 0.01
        camera.zFar = 100
        cameraNode.camera = camera
        let radius = max(0.3, sqrt(hx * hx + hy * hy + hz * hz))
        let distance = radius / sin(Double(camera.fieldOfView) / 2 * .pi / 180) * 1.14
        let azimuth = 38.0 * .pi / 180, elevation = 24.0 * .pi / 180
        cameraNode.position = SCNVector3(target.x + distance * cos(elevation) * sin(azimuth),
                                         target.y + distance * sin(elevation),
                                         target.z + distance * cos(elevation) * cos(azimuth))
        cameraNode.look(at: target)
        homeTransform = cameraNode.transform
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
        let controller = scnView.defaultCameraController
        controller.interactionMode = .orbitTurntable
        controller.target = target
        controller.inertiaEnabled = true
        controller.maximumVerticalAngle = 85
        controller.minimumVerticalAngle = -5
    }

    /// The file's length unit: 3MF says it; STL is read as millimetres (the printing convention), glTF is metres by
    /// its specification; OBJ has none.
    var unitSymbol: String? {
        if let u = summary.units {
            switch u {
            case "micron": return "µm"
            case "millimeter": return "mm"
            case "centimeter": return "cm"
            case "inch": return "in"
            case "foot": return "ft"
            case "meter": return "m"
            default: return u
            }
        }
        if summary.format.hasPrefix("STL") { return "mm" }
        if summary.format == "glTF" || summary.format == "GLB" { return "m" }
        return nil
    }

    static func lengthText(_ value: Double, unit: String?) -> String {
        let digits = value >= 100 ? 0 : value >= 10 ? 1 : 2
        let number = value.formatted(.number.precision(.fractionLength(0...digits)))
        return unit.map { "\(number) \($0)" } ?? number
    }

    private func boundsBox(size: SIMD3<Double>) -> SCNNode {
        let node = SCNNode()
        let (x, y, z) = (size.x / 2, size.y / 2, size.z / 2)
        let solid = SCNNode(geometry: SCNBox(width: size.x, height: size.y, length: size.z, chamferRadius: 0))
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = NSColor(srgbRed: 0.86, green: 0.88, blue: 0.91, alpha: 1)
        m.transparency = 0.5
        m.writesToDepthBuffer = false
        solid.geometry?.materials = [m]
        solid.castsShadow = false
        node.addChildNode(solid)
        let c = [SCNVector3(-x, -y, -z), SCNVector3(x, -y, -z), SCNVector3(x, y, -z), SCNVector3(-x, y, -z),
                 SCNVector3(-x, -y, z), SCNVector3(x, -y, z), SCNVector3(x, y, z), SCNVector3(-x, y, z)]
        let edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
        let wire = SCNNode(geometry: Self.lines(edges.map { (c[$0.0], c[$0.1]) }, ticks: 0))
        wire.name = "bounds-edges"
        node.addChildNode(wire)
        return node
    }

    private func makeCaption() -> ChipView {
        var parts = [String(localized: "Shown as its bounding box", bundle: .previewKit,
                            comment: "Caption on a glTF/GLB model's stage: its geometry is not drawn, only the box around it.")]
        if box == nil {
            parts = [String(localized: "No geometry to draw", bundle: .previewKit,
                            comment: "Caption on a 3D model's stage when the file gives neither triangles nor a size.")]
        }
        if let g = summary.gltf {
            parts.append("\(String(localized: "Meshes", bundle: .previewKit, comment: "A count label on a glTF model's stage caption.")) \(g.meshCount.formatted())")
            if g.materialCount > 0 {
                parts.append("\(String(localized: "Materials", bundle: .previewKit, comment: "A count label on a glTF model's stage caption.")) \(g.materialCount.formatted())")
            }
        }
        if summary.triangleCount > 0 {
            parts.append("\(String(localized: "Triangles", bundle: .previewKit, comment: "A count label on a 3D model's stage caption.")) \(summary.triangleCount.formatted())")
        }
        let chip = ChipView(text: parts.joined(separator: "  ·  "), symbol: "cube.transparent", fill: "glass", textColor: "t2", border: "hair")
        chip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return chip
    }

    /// Triangles with one flat normal each (corners are not shared, so the facets read crisply).
    static func geometry(_ mesh: MediaMesh) -> SCNGeometry? {
        let p = mesh.positions
        let n = p.count / 9
        guard n > 0 else { return nil }
        var normals = [Float](repeating: 0, count: n * 9)
        for t in 0..<n {
            let i = t * 9
            let ax = p[i + 3] - p[i], ay = p[i + 4] - p[i + 1], az = p[i + 5] - p[i + 2]
            let bx = p[i + 6] - p[i], by = p[i + 7] - p[i + 1], bz = p[i + 8] - p[i + 2]
            var nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx
            let len = (nx * nx + ny * ny + nz * nz).squareRoot()
            if len > 0, len.isFinite { nx /= len; ny /= len; nz /= len } else { nx = 0; ny = 0; nz = 1 }
            for k in 0..<3 { normals[i + k * 3] = nx; normals[i + k * 3 + 1] = ny; normals[i + k * 3 + 2] = nz }
        }
        let positions = p.prefix(n * 9).map { $0.isFinite ? $0 : 0 }
        let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let normalData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertices = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: n * 3, usesFloatComponents: true,
                                         componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let normalSource = SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: n * 3, usesFloatComponents: true,
                                             componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let indices = (0..<UInt32(n * 3)).map { $0 }
        let element = SCNGeometryElement(data: indices.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                                         primitiveCount: n, bytesPerIndex: 4)
        return SCNGeometry(sources: [vertices, normalSource], elements: [element])
    }

    /// Line segments, each with small end ticks across it (in the floor plane, or sideways for a vertical line).
    static func lines(_ segments: [(SCNVector3, SCNVector3)], ticks: Double) -> SCNGeometry {
        var points: [SCNVector3] = []
        for (a, b) in segments {
            points += [a, b]
            guard ticks > 0 else { continue }
            let dx = b.x - a.x, dz = b.z - a.z
            let len = (dx * dx + dz * dz).squareRoot()
            // Across the line in the floor plane; a vertical line ticks along x.
            let (tx, tz) = len > 1e-6 ? (-dz / len * ticks, dx / len * ticks) : (ticks, 0)
            for p in [a, b] {
                points += [SCNVector3(p.x - tx, p.y, p.z - tz), SCNVector3(p.x + tx, p.y, p.z + tz)]
            }
        }
        let source = SCNGeometrySource(vertices: points)
        let indices = (0..<Int32(points.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let m = SCNMaterial()
        m.lightingModel = .constant
        geometry.materials = [m]
        return geometry
    }

    // MARK: Colours

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let line = NSColor.token("t2").usingColorSpace(.sRGB) ?? .gray
            calloutLines.geometry?.firstMaterial?.diffuse.contents = line
            modelNode.childNode(withName: "bounds-edges", recursively: true)?.geometry?.firstMaterial?.diffuse.contents =
                line
            // The grid's lines are the `sep` token laid over the stage's lower colour, fading into it towards the rim
            // (opaque vertex colours: a texture grid shimmers at the grazing angle, and blending needs no sorting).
            let sep = NSColor.token("sep").usingColorSpace(.sRGB) ?? .gray
            let stops = StageView.stops(GeneratedTokens.color("stage").map { isDark ? $0.dark : $0.light } ?? "")
                .compactMap { $0.usingColorSpace(.sRGB) }
            let ground = stops.count >= 2 ? Self.mix(stops[0], stops[stops.count - 1], 0.75) : (stops.first ?? .gray)
            // The scene draws the stage gradient itself (the same token stops as the card's StageView behind it), so
            // lines and soft edges blend against the real ground rather than a transparent layer.
            scene.background.contents = Self.stageImage(stops.isEmpty ? [.gray] : stops)
            gridNode.geometry = Self.grid(line: sep.withAlphaComponent(1), strength: sep.alphaComponent * (isDark ? 0.55 : 0.85), ground: ground)
        }
        gizmo.needsDisplay = true
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// A vertical gradient image, top stop first.
    static func stageImage(_ stops: [NSColor]) -> CGImage? {
        let colors = (stops.count == 1 ? stops + stops : stops).map(\.cgColor) as CFArray
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 4, height: 256, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: colors, locations: nil) else { return nil }
        // CoreGraphics' y runs up: the first stop (the top) is drawn at y = 256.
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 256), end: .zero, options: [])
        return ctx.makeImage()
    }

    static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t, green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
    }

    /// The floor grid as line segments in the floor plane, 0.1 apart out to 1.6, each vertex coloured `line` laid at
    /// `strength` over `ground` and fading to `ground` from the middle out.
    static func grid(line: NSColor, strength: CGFloat, ground: NSColor) -> SCNGeometry {
        let reach: Float = 1.6, step: Float = 0.1, pieces = 24
        var positions: [Float] = [], colors: [Float] = []
        func color(_ x: Float, _ z: Float) -> NSColor {
            let r = CGFloat((x * x + z * z).squareRoot() / reach)
            let t = min(1, max(0, (r - 0.3) / 0.65))
            let fade = 1 - t * t * (3 - 2 * t)
            return mix(ground, line, strength * fade)
        }
        func add(_ x: Float, _ z: Float) {
            positions += [x, 0, z]
            let c = color(x, z)
            // SceneKit reads vertex colours as linear light; the tokens are sRGB.
            func linear(_ v: CGFloat) -> Float { Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) }
            colors += [linear(c.redComponent), linear(c.greenComponent), linear(c.blueComponent), 1]
        }
        let count = Int(reach / step)
        for i in -count...count {
            let k = Float(i) * step
            for j in 0..<pieces {
                let a = -reach + 2 * reach * Float(j) / Float(pieces), b = -reach + 2 * reach * Float(j + 1) / Float(pieces)
                add(a, k); add(b, k)
                add(k, a); add(k, b)
            }
        }
        let n = positions.count / 3
        let vertices = SCNGeometrySource(data: positions.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex, vectorCount: n,
                                         usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let colorSource = SCNGeometrySource(data: colors.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color, vectorCount: n,
                                            usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let indices = (0..<Int32(n)).map { $0 }
        let geometry = SCNGeometry(sources: [vertices, colorSource], elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.white
        m.writesToDepthBuffer = false
        geometry.materials = [m]
        return geometry
    }

    /// An ellipse that fades to nothing: the contact shadow's mask (its colour is the material's).
    static func blobImage() -> CGImage? {
        let px = 256
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.42), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.2),
                      CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1]) else { return nil }
        let c = CGPoint(x: px / 2, y: px / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(px) / 2, options: [])
        return ctx.makeImage()
    }

    // MARK: Interaction

    private func modeChosen(_ index: Int) {
        switch index {
        case 0:
            modelMaterial?.fillMode = .fill
            modes.selected = 0
        case 1:
            modelMaterial?.fillMode = .lines
            modes.selected = 1
        default:
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.35
            cameraNode.transform = homeTransform
            SCNTransaction.commit()
            scnView.defaultCameraController.target = target
            scnView.defaultCameraController.clearRoll()
        }
    }

    private func cameraMaybeMoved() {
        let pov = scnView.pointOfView?.presentation.worldTransform ?? cameraNode.worldTransform
        if let last = lastCamera, SCNMatrix4EqualToMatrix4(last, pov) { return }
        lastCamera = pov
        updateOverlays()
    }

    /// Places the callout pills where their edges' middles project, and turns the gizmo with the camera.
    func updateOverlays() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        for (pill, anchor) in pills {
            let p = scnView.projectPoint(anchor)
            let size = pill.fittingSize
            let inView = p.z > 0 && p.z < 1
            pill.isHidden = !inView
            // SCNView's points run up from the bottom like the overlay's (neither is flipped).
            let local = overlay.convert(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), from: scnView)
            var r = CGRect(x: local.x - size.width / 2, y: local.y - size.height / 2, width: size.width, height: size.height)
            r.origin.x = min(max(r.minX, 4), bounds.maxX - 4 - size.width)
            r.origin.y = min(max(r.minY, 4), bounds.maxY - 4 - size.height)
            pill.frame = r.integral
        }
        // The file's axes as the camera sees them.
        let pov = scnView.pointOfView ?? cameraNode
        var axes: [(CGVector, Int)] = []
        for (i, v) in [SCNVector3(1, 0, 0), SCNVector3(0, 1, 0), SCNVector3(0, 0, 1)].enumerated() {
            let world = modelNode.presentation.convertVector(v, to: nil)
            let cam = pov.presentation.convertVector(world, from: nil)
            let len = (cam.x * cam.x + cam.y * cam.y + cam.z * cam.z).squareRoot()
            axes.append((len > 0 ? CGVector(dx: cam.x / len, dy: cam.y / len) : .zero, i))
        }
        gizmo.axes = axes
    }

    /// The 3D picture with its overlays on a transparent background, as the screen shows it: SceneKit's content is
    /// in a Metal layer that `cacheDisplay` cannot read, so the scene comes from the view's own snapshot. For tests
    /// and exports.
    func renderedImage() -> NSImage? {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        // Commit this turn's scene changes; the view's first snapshot comes back empty (its renderer warms up on
        // it), so the second is the picture.
        SCNTransaction.flush()
        _ = scnView.snapshot()
        // Copied into a bitmap at once: the snapshot's image is backed by the renderer's surface, which drawing the
        // overlays below may reuse.
        guard let picture = scnView.snapshot().tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else { return nil }
        updateOverlays()
        let image = NSImage(size: size)
        guard let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) else { return nil }
        overlay.cacheDisplay(in: overlay.bounds, to: rep)
        image.lockFocus()
        // An image rep draws with `.copy` unless told otherwise; the overlays go over the picture.
        let all = CGRect(origin: .zero, size: size)
        picture.draw(in: all, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        rep.draw(in: all, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        image.unlockFocus()
        return image
    }
}

// MARK: - Parts

/// Lets clicks through to the 3D view except on its own controls.
@MainActor
final class OverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit is CalloutPill || hit is AxisGizmoView ? nil : hit
    }
}

/// A size callout: the card-coloured pill of the design ("84 mm").
@MainActor
final class CalloutPill: TokenBox {
    let label: NSTextField

    init(text: String) {
        label = cardLabel(text, font: tabularFigures(tokenFont("fs-caption", weight: 600)), color: "t1")
        label.alignment = .center
        super.init(fill: "card", radius: 9, border: "hair", borderWidth: 1)
        translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var fittingSize: NSSize {
        let s = label.intrinsicContentSize
        return NSSize(width: ceil(s.width) + 18, height: 18)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The small X / Y / Z gizmo in the stage's corner, turning with the camera; colours are the system's red, green
/// and blue tokens.
@MainActor
final class AxisGizmoView: NSView {
    var axes: [(CGVector, Int)] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let names = ["X", "Y", "Z"], colors = ["danger", "ok", "update"]
        let font = tokenFont("fs-micro", weight: 600)
        for (v, i) in axes {
            let end = CGPoint(x: c.x + v.dx * 19, y: c.y + v.dy * 19)
            let path = NSBezierPath()
            path.move(to: c); path.line(to: end)
            path.lineWidth = 2
            path.lineCapStyle = .round
            NSColor.token(colors[i]).setStroke()
            path.stroke()
            let label = NSAttributedString(string: names[i], attributes: [.font: font, .foregroundColor: NSColor.token(colors[i])])
            let s = label.size()
            label.draw(at: CGPoint(x: end.x + v.dx * 6 - s.width / 2, y: end.y + v.dy * 6 - s.height / 2))
        }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A small glass segmented switch (`.glass` + `.ib`): the chosen segment on the control fill.
@MainActor
final class ModeSwitch: NSView {
    let titles: [String]
    var selected = 0 { didSet { needsDisplay = true } }
    private let action: (Int) -> Void
    private var font: NSFont { tokenFont("fs-sub", weight: 500) }

    init(titles: [String], action: @escaping (Int) -> Void) {
        self.titles = titles
        self.action = action
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }

    required init?(coder: NSCoder) { nil }

    private var segmentWidths: [CGFloat] {
        titles.map { ceil(NSAttributedString(string: $0, attributes: [.font: font]).size().width) + 16 }
    }

    override var fittingSize: NSSize { NSSize(width: segmentWidths.reduce(4, +), height: 26) }

    private func segmentRects() -> [CGRect] {
        var x: CGFloat = 2
        return segmentWidths.map { w in defer { x += w }; return CGRect(x: x, y: 2, width: w, height: bounds.height - 4) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor.token("glass").setFill(); outer.fill()
        NSColor.token("hair").setStroke(); outer.lineWidth = 0.5; outer.stroke()
        for (i, r) in segmentRects().enumerated() {
            if i == selected {
                let p = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
                NSColor.token("segsel").setFill(); p.fill()
                NSColor.token("hair").setStroke(); p.lineWidth = 0.5; p.stroke()
            }
            let label = NSAttributedString(string: titles[i], attributes: [.font: font, .foregroundColor: NSColor.token(i == selected ? "t1" : "t2")])
            let s = label.size()
            label.draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = segmentRects().firstIndex(where: { $0.contains(p) }) { action(i) }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// SceneKit's render callback (on its render thread) passed on as a plain closure, so the view can follow the camera.
final class RenderWatcher: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    let onRender: @Sendable () -> Void
    init(onRender: @escaping @Sendable () -> Void) { self.onRender = onRender }
    func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) { onRender() }
}
