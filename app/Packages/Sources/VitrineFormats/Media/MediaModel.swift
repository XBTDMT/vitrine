import Foundation

/// A point or size in model space (the file's own units). roadmap: S-23
public struct MediaVector3: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// An axis-aligned box around a model. roadmap: S-23
public struct MediaBox3: Sendable, Equatable {
    public var min: MediaVector3
    public var max: MediaVector3

    public init(min: MediaVector3, max: MediaVector3) {
        self.min = min
        self.max = max
    }

    /// Width, depth and height.
    public var size: MediaVector3 { MediaVector3(x: max.x - min.x, y: max.y - min.y, z: max.z - min.z) }
}

/// Triangles for the orbit renderer: at most 20,000, picked evenly through the file, as float positions
/// (nine per triangle: x, y, z of each corner). roadmap: S-23
public struct MediaMesh: Sendable, Equatable {
    public var positions: [Float]
    public var triangleCount: Int { positions.count / 9 }
    /// Triangles in the model before decimation.
    public var sourceTriangleCount: Int
}

/// What a glTF 2.0 or GLB file declares. roadmap: S-23
public struct MediaGLTFInfo: Sendable, Equatable {
    public var generator: String?
    public var version: String?
    public var minVersion: String?
    public var copyright: String?
    public var sceneCount: Int
    public var nodeCount: Int
    public var meshCount: Int
    public var primitiveCount: Int
    public var materialCount: Int
    public var textureCount: Int
    public var imageCount: Int
    public var animationCount: Int
    public var skinCount: Int
    public var cameraCount: Int
    public var accessorCount: Int
    public var bufferCount: Int
    /// URIs of buffers and images outside the file (never fetched).
    public var externalResources: [String]
    public var extensionsUsed: [String]
    public var extensionsRequired: [String]
    /// The GLB binary chunk's length.
    public var binaryChunkBytes: Int?
}

/// A 3D model (N-7): STL, OBJ, 3MF, glTF or GLB. roadmap: S-23
public struct MediaModelSummary: Sendable, Equatable {
    public var headline: String
    public var facts: [MediaFact]
    public var warnings: [MediaWarning]
    /// "STL (binary)", "STL (ASCII)", "OBJ", "3MF", "glTF" or "GLB".
    public var format: String
    public var triangleCount: Int
    public var vertexCount: Int?
    /// OBJ polygons before triangulation.
    public var faceCount: Int?
    public var bounds: MediaBox3?
    public var surfaceArea: Double?
    /// The enclosed volume (signed-tetrahedron sum); meaningful when the mesh is closed.
    public var volume: Double?
    /// Every edge is shared by exactly two triangles; nil when the check was not run (too many triangles, or glTF).
    public var isClosed: Bool?
    /// Edges used by one triangle only.
    public var openEdgeCount: Int?
    /// Edges used by more than two triangles.
    public var nonManifoldEdgeCount: Int?
    /// 3MF units ("millimeter"); nil when the format has none (STL, OBJ).
    public var units: String?
    public var objectCount: Int
    public var objects: [String]
    public var groups: [String]
    public var materials: [String]
    public var materialLibraries: [String]
    public var buildItemCount: Int?
    /// 3MF metadata (Title, Designer, Application …).
    public var metadata: [MediaFact]
    public var title: String?
    public var designer: String?
    public var gltf: MediaGLTFInfo?
    /// Triangles to draw (STL, OBJ, 3MF).
    public var mesh: MediaMesh?
    public var truncated: Bool
}

enum MediaModelReader {
    static let maxDrawTriangles = 20_000
    static let maxEdgeCheckTriangles = 1_000_000
    static let maxNames = 200

    static func read(_ data: Data, fileName: String, format: MediaFormat, inputCapped: Bool) -> MediaModelSummary? {
        var s: MediaModelSummary?
        switch format {
        case .stl: s = readSTL(data, fileName: fileName)
        case .obj: s = readOBJ(data, fileName: fileName)
        case .threeMF: s = read3MF(data, fileName: fileName)
        case .gltf: s = readGLTF(json: data, fileName: fileName, glb: nil)
        case .glb: s = readGLB(data, fileName: fileName)
        default: return nil
        }
        if inputCapped {
            s?.truncated = true
            s?.warnings.append(MediaWarning(.caution, String(localized: "Only the first 256 MB of this file were read.", bundle: .module, comment: "3D model card warning.")))
        }
        return s
    }

    static func blank(_ fileName: String, format: String) -> MediaModelSummary {
        MediaModelSummary(headline: MediaPath.base(fileName), facts: [], warnings: [], format: format, triangleCount: 0,
                          vertexCount: nil, faceCount: nil, bounds: nil, surfaceArea: nil, volume: nil, isClosed: nil,
                          openEdgeCount: nil, nonManifoldEdgeCount: nil, units: nil, objectCount: 0, objects: [],
                          groups: [], materials: [], materialLibraries: [], buildItemCount: nil, metadata: [],
                          title: nil, designer: nil, gltf: nil, mesh: nil, truncated: false)
    }

    // MARK: STL

    static func readSTL(_ data: Data, fileName: String) -> MediaModelSummary? {
        let b = MediaBytes(data)
        let declared = b.le32(80).map(Int.init)
        let exactBinary = declared.map { 84 + 50 * $0 == data.count } ?? false
        let head = String(decoding: b.bytes(0, 1024), as: UTF8.self)
        let looksASCII = head.drop(while: \.isWhitespace).hasPrefix("solid") && (head.contains("facet") || head.contains("endsolid") || data.count < 84)
        var builder = MediaMeshBuilder()
        var s: MediaModelSummary
        if !exactBinary && looksASCII {
            s = blank(fileName, format: "STL (ASCII)")
            let invalid = parseASCIISTL(data, into: &builder, name: &s.title)
            if builder.triangles == 0 {
                s.warnings.append(MediaWarning(.danger, String(localized: "No triangles could be read from this ASCII STL file.", bundle: .module, comment: "3D model card warning.")))
            }
            if invalid > 0 { s.warnings.append(MediaWarning(.danger, String(localized: "\(invalid) facets are damaged (a vertex is missing or not a number).", bundle: .module, comment: "3D card warning. The argument is a count."))) }
        } else {
            guard let declared else {
                var s = blank(fileName, format: "STL")
                s.warnings.append(MediaWarning(.danger, String(localized: "This file is too short to be an STL model (\(data.count) bytes).", bundle: .module, comment: "3D model card warning. Arguments are filled in at run time.")))
                return s
            }
            s = blank(fileName, format: "STL (binary)")
            let available = max(0, (data.count - 84) / 50)
            let count = min(declared, available)
            if declared > available {
                s.warnings.append(MediaWarning(.danger, String(localized: "The file is cut short: it declares \(declared) triangles but holds \(available).", bundle: .module, comment: "3D model card warning. Arguments are filled in at run time.")))
                s.truncated = true
            }
            builder.expected = count
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var tri = [Float](repeating: 0, count: 9)
                for i in 0..<count {
                    let o = 84 + i * 50 + 12
                    for k in 0..<9 {
                        tri[k] = Float(bitPattern: UInt32(littleEndian: base.loadUnaligned(fromByteOffset: o + k * 4, as: UInt32.self)))
                    }
                    builder.add(tri)
                }
            }
            let header = String(decoding: b.bytes(0, 80).prefix { $0 != 0 }, as: UTF8.self)
            if let h = MediaText.clean(header, max: 80), !h.hasPrefix("solid") || h.count > 6 {
                s.metadata.append(MediaFact(String(localized: "Header", bundle: .module, comment: "3D model card fact label."), h))
            }
        }
        builder.finish(into: &s)
        if s.isClosed == false {
            s.warnings.append(MediaWarning(.caution, String(localized: "The mesh is not closed (\(s.openEdgeCount ?? 0) open edges, \(s.nonManifoldEdgeCount ?? 0) shared by more than two faces): a 3D printer's slicer may reject or repair it.", bundle: .module, comment: "3D card warning. The arguments are counts.")))
        }
        finishFacts(&s, unitsKnown: false)
        return s
    }

    /// Reads `vertex x y z` lines, three per facet. Returns how many facets were damaged.
    static func parseASCIISTL(_ data: Data, into builder: inout MediaMeshBuilder, name: inout String?) -> Int {
        var invalid = 0
        data.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let n = raw.count
            var i = 0
            var tri = [Float](repeating: 0, count: 9)
            var corner = 0
            var first = true
            while i < n {
                while i < n, p[i] == 32 || p[i] == 9 || p[i] == 13 || p[i] == 10 { i += 1 }
                let lineStart = i
                while i < n, p[i] != 10 { i += 1 }
                let lineEnd = i
                var j = lineStart
                func word() -> (Int, Int) {
                    while j < lineEnd, p[j] == 32 || p[j] == 9 || p[j] == 13 { j += 1 }
                    let s = j
                    while j < lineEnd, p[j] != 32, p[j] != 9, p[j] != 13 { j += 1 }
                    return (s, j)
                }
                let (ws, we) = word()
                let len = we - ws
                if len == 6, memcmp(p + ws, "vertex", 6) == 0 {
                    var ok = true
                    for k in 0..<3 {
                        let (fs, fe) = word()
                        if let v = MediaNumber.parse(p, fs, fe) { tri[corner * 3 + k] = Float(v) } else { ok = false }
                    }
                    if !ok { invalid += 1; corner = -1 }
                    corner += 1
                    if corner == 3 { builder.add(tri); corner = 0 }
                } else if len == 5, memcmp(p + ws, "facet", 5) == 0 {
                    corner = 0
                } else if first, len == 5, memcmp(p + ws, "solid", 5) == 0 {
                    while j < lineEnd, p[j] == 32 || p[j] == 9 { j += 1 }
                    name = MediaText.clean(String(decoding: UnsafeBufferPointer(start: p + j, count: lineEnd - j), as: UTF8.self), max: 200)
                }
                first = false
            }
        }
        return invalid
    }

    // MARK: OBJ

    static func readOBJ(_ data: Data, fileName: String) -> MediaModelSummary? {
        var s = blank(fileName, format: "OBJ")
        var vertices: [Float] = []
        var normals = 0, texcoords = 0, faces = 0, lines = 0, badFaces = 0
        var triangles: [Int32] = []
        var groups: [String] = [], objects: [String] = [], materials: [String] = [], libraries: [String] = []
        var seenGroups = Set<String>(), seenObjects = Set<String>(), seenMaterials = Set<String>(), seenLibraries = Set<String>()
        func note(_ name: String, _ list: inout [String], _ seen: inout Set<String>) {
            guard let n = MediaText.clean(name, max: 200), !seen.contains(n) else { return }
            if list.count >= maxNames { s.truncated = true; return }
            seen.insert(n)
            list.append(n)
        }
        data.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let n = raw.count
            var i = 0
            var face: [Int32] = []
            while i < n {
                let lineStart = i
                while i < n, p[i] != 10 { i += 1 }
                var lineEnd = i
                i += 1
                if lineEnd > lineStart, p[lineEnd - 1] == 13 { lineEnd -= 1 }
                var j = lineStart
                while j < lineEnd, p[j] == 32 || p[j] == 9 { j += 1 }
                guard j < lineEnd, p[j] != 35 else { continue }               // blank or # comment
                let ks = j
                while j < lineEnd, p[j] != 32, p[j] != 9 { j += 1 }
                let key = String(decoding: UnsafeBufferPointer(start: p + ks, count: j - ks), as: UTF8.self)
                func rest() -> String {
                    String(decoding: UnsafeBufferPointer(start: p + j, count: lineEnd - j), as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                }
                func token() -> (Int, Int)? {
                    while j < lineEnd, p[j] == 32 || p[j] == 9 { j += 1 }
                    guard j < lineEnd else { return nil }
                    let s = j
                    while j < lineEnd, p[j] != 32, p[j] != 9 { j += 1 }
                    return (s, j)
                }
                switch key {
                case "v":
                    var xyz: [Float] = []
                    for _ in 0..<3 {
                        if let (a, b) = token(), let v = MediaNumber.parse(p, a, b) { xyz.append(Float(v)) }
                    }
                    if xyz.count == 3 { vertices.append(contentsOf: xyz) } else { vertices.append(contentsOf: [.nan, .nan, .nan]) }
                case "vn": normals += 1
                case "vt": texcoords += 1
                case "f":
                    faces += 1
                    face.removeAll(keepingCapacity: true)
                    let vcount = Int32(vertices.count / 3)
                    var bad = false
                    while let (a, b) = token() {
                        var e = a
                        while e < b, p[e] != 47 { e += 1 }                  // up to the first '/'
                        guard let raw = MediaNumber.parseInt(p, a, e) else { bad = true; break }
                        let index = raw < 0 ? vcount + Int32(clamping: raw) : Int32(clamping: raw) - 1
                        guard index >= 0, index < vcount else { bad = true; break }
                        face.append(index)
                    }
                    if bad || face.count < 3 { badFaces += 1; continue }
                    for k in 1..<(face.count - 1) { triangles.append(face[0]); triangles.append(face[k]); triangles.append(face[k + 1]) }
                case "l": lines += 1
                case "g": for g in rest().split(separator: " ") { note(String(g), &groups, &seenGroups) }
                case "o": note(rest(), &objects, &seenObjects)
                case "usemtl": note(rest(), &materials, &seenMaterials)
                case "mtllib": note(rest(), &libraries, &seenLibraries)
                default: break
                }
            }
        }
        var builder = MediaMeshBuilder()
        builder.expected = triangles.count / 3
        var tri = [Float](repeating: 0, count: 9)
        var t = 0
        while t + 2 < triangles.count {
            for c in 0..<3 {
                let v = Int(triangles[t + c]) * 3
                tri[c * 3] = vertices[v]; tri[c * 3 + 1] = vertices[v + 1]; tri[c * 3 + 2] = vertices[v + 2]
            }
            builder.add(tri)
            t += 3
        }
        builder.finish(into: &s, positionsForBounds: vertices)
        s.vertexCount = vertices.count / 3
        s.faceCount = faces
        s.groups = groups.filter { $0 != "default" }
        s.objects = objects
        s.objectCount = objects.count
        s.materials = materials
        s.materialLibraries = libraries
        if vertices.isEmpty {
            s.warnings.append(MediaWarning(.danger, String(localized: "No vertices could be read: this does not look like an OBJ model.", bundle: .module, comment: "3D model card warning.")))
        }
        if badFaces > 0 {
            s.warnings.append(MediaWarning(.danger, String(localized: "\(badFaces) faces point at vertices that do not exist and were skipped.", bundle: .module, comment: "3D card warning. The argument is a count.")))
        }
        if !libraries.isEmpty {
            s.warnings.append(MediaWarning(.caution, String(localized: "Materials live in a separate file (\(libraries.prefix(3).joined(separator: ", "))); the preview shows the shape without them.", bundle: .module, comment: "3D model card warning. Arguments are filled in at run time.")))
        }
        var extra: [MediaFact] = []
        if normals > 0 { extra.append(MediaFact(String(localized: "Normals", bundle: .module, comment: "3D model card fact label."), "\(normals)")) }
        if texcoords > 0 { extra.append(MediaFact(String(localized: "Texture coordinates", bundle: .module, comment: "3D model card fact label."), "\(texcoords)")) }
        if lines > 0 { extra.append(MediaFact(String(localized: "Lines", bundle: .module, comment: "3D model card fact label."), "\(lines)")) }
        finishFacts(&s, unitsKnown: false)
        s.facts.append(contentsOf: extra)
        return s
    }

    // MARK: 3MF

    static func read3MF(_ data: Data, fileName: String) -> MediaModelSummary? {
        guard let archive = MediaArchive.open(data, fileName: fileName) else { return nil }
        var s = blank(fileName, format: "3MF")
        var modelPath = "3D/3dmodel.model"
        if let rels = archive.read(path: "_rels/.rels", limit: MediaLimits.maxXMLPartBytes),
           let tree = MediaXMLElement.parse(rels),
           let target = tree.descendants("Relationship").first(where: { ($0.attribute("Type") ?? "").hasSuffix("/3dmodel") })?.attribute("Target") {
            modelPath = MediaPath.resolve(target, relativeTo: "")
        }
        guard let main = archive.index(of: modelPath) else {
            s.warnings.append(MediaWarning(.danger, String(localized: "This 3MF package has no model part (\(modelPath) is missing).", bundle: .module, comment: "3D model card warning. Arguments are filled in at run time.")))
            return s
        }
        var parts = [main]
        for i in archive.fileIndices where i != main && MediaPath.ext(archive.path(i)) == "model" && parts.count < 64 { parts.append(i) }
        let parser = Media3MFParser()
        for (n, index) in parts.enumerated() {
            guard let bytes = archive.read(index, limit: MediaLimits.maxInputBytes) else {
                let why = archive.readFailure(index, limit: MediaLimits.maxInputBytes) ?? MediaText.unknownReason
                s.warnings.append(MediaWarning(.danger, String(localized: "The model part \(archive.path(index)) cannot be read: \(why).", bundle: .module, comment: "3D model card warning. Arguments are filled in at run time.")))
                continue
            }
            parser.isMainPart = n == 0
            if !MediaXMLStream.run(bytes, delegate: parser), !parser.stopped {
                s.warnings.append(MediaWarning(.danger, String(localized: "The model part \(archive.path(index)) is damaged; what was read before the damage is shown.", bundle: .module, comment: "3D model card warning. Arguments are filled in at run time.")))
            }
        }
        parser.builder.finish(into: &s)
        s.units = parser.unit ?? "millimeter"
        s.vertexCount = parser.vertexTotal
        s.objectCount = parser.objectCount
        s.objects = parser.objectNames
        s.buildItemCount = parser.buildItems
        s.metadata = parser.metadata
        s.title = parser.metadata.first { $0.label.lowercased() == "title" }?.value
        s.designer = parser.metadata.first { $0.label.lowercased() == "designer" }?.value
        s.truncated = s.truncated || parser.truncated
        if parser.badTriangles > 0 {
            s.warnings.append(MediaWarning(.danger, String(localized: "\(parser.badTriangles) triangles point at vertices that do not exist and were skipped.", bundle: .module, comment: "3D card warning. The argument is a count.")))
        }
        if s.isClosed == false {
            s.warnings.append(MediaWarning(.caution, String(localized: "The mesh is not closed (\(s.openEdgeCount ?? 0) open edges): a 3D printer's slicer may reject or repair it.", bundle: .module, comment: "3D card warning. The argument is a count.")))
        }
        finishFacts(&s, unitsKnown: true)
        if let b = parser.buildItems as Int? { s.facts.append(MediaFact(String(localized: "Build items", bundle: .module, comment: "3D model card fact label."), "\(b)")) }
        if let d = s.designer { s.facts.append(MediaFact(String(localized: "Designer", bundle: .module, comment: "3D model card fact label."), d)) }
        if let t = s.title { s.headline = t }
        return s
    }

    // MARK: glTF

    static func readGLB(_ data: Data, fileName: String) -> MediaModelSummary? {
        let b = MediaBytes(data)
        guard b.matches("glTF", at: 0), let version = b.le32(4), let length = b.le32(8) else {
            var s = blank(fileName, format: "GLB")
            s.warnings.append(MediaWarning(.danger, String(localized: "This is not a GLB file: the \"glTF\" header is missing.", bundle: .module, comment: "3D model card warning.")))
            return s
        }
        guard version == 2 else {
            var s = blank(fileName, format: "GLB")
            s.warnings.append(MediaWarning(.danger, String(localized: "This is GLB version \(version); only glTF 2.0 is read.", bundle: .module, comment: "3D model card warning. Arguments are filled in at run time.")))
            return s
        }
        var offset = 12
        var json: Data?
        var binLength: Int?
        var chunks = 0
        while offset + 8 <= data.count, chunks < 64 {
            guard let len = b.le32(offset).map(Int.init), let type = b.le32(offset + 4) else { break }
            let body = offset + 8
            if type == 0x4E4F_534A { json = b.sub(body, len) }
            if type == 0x004E_4942 { binLength = min(len, max(0, data.count - body)) }
            offset = body + len
            chunks += 1
        }
        guard let json else {
            var s = blank(fileName, format: "GLB")
            s.warnings.append(MediaWarning(.danger, String(localized: "The GLB file has no JSON chunk.", bundle: .module, comment: "3D model card warning.")))
            return s
        }
        var s = readGLTF(json: json, fileName: fileName, glb: binLength) ?? blank(fileName, format: "GLB")
        if Int(length) > data.count || offset > data.count {
            s.warnings.append(MediaWarning(.danger, String(localized: "The file is cut short: it declares \(length) bytes but holds \(data.count).", bundle: .module, comment: "3D model card warning. Arguments are filled in at run time.")))
            s.truncated = true
        }
        return s
    }

    static func readGLTF(json: Data, fileName: String, glb: Int?) -> MediaModelSummary? {
        var s = blank(fileName, format: glb == nil ? "glTF" : "GLB")
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            s.warnings.append(MediaWarning(.danger, String(localized: "The glTF JSON is damaged and cannot be read.", bundle: .module, comment: "3D model card warning.")))
            return s
        }
        func array(_ key: String) -> [[String: Any]] { (root[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
        let asset = root["asset"] as? [String: Any]
        let accessors = array("accessors")
        let meshes = array("meshes")
        var info = MediaGLTFInfo(generator: MediaText.clean(asset?["generator"] as? String, max: 200),
                                 version: asset?["version"] as? String, minVersion: asset?["minVersion"] as? String,
                                 copyright: MediaText.clean(asset?["copyright"] as? String, max: 300),
                                 sceneCount: array("scenes").count, nodeCount: array("nodes").count, meshCount: meshes.count,
                                 primitiveCount: 0, materialCount: array("materials").count, textureCount: array("textures").count,
                                 imageCount: array("images").count, animationCount: array("animations").count,
                                 skinCount: array("skins").count, cameraCount: array("cameras").count,
                                 accessorCount: accessors.count, bufferCount: array("buffers").count, externalResources: [],
                                 extensionsUsed: ((root["extensionsUsed"] as? [Any]) ?? []).compactMap { $0 as? String }.prefix(100).map { $0 },
                                 extensionsRequired: ((root["extensionsRequired"] as? [Any]) ?? []).compactMap { $0 as? String }.prefix(100).map { $0 },
                                 binaryChunkBytes: glb)
        for item in array("buffers") + array("images") {
            if let uri = item["uri"] as? String, !uri.hasPrefix("data:") {
                if info.externalResources.count < maxNames { info.externalResources.append(MediaText.cap(uri, 300)) } else { s.truncated = true }
            }
        }
        func accessorCount(_ index: Any?) -> Int? {
            guard let i = (index as? NSNumber)?.intValue, accessors.indices.contains(i) else { return nil }
            return (accessors[i]["count"] as? NSNumber)?.intValue
        }
        var triangles = 0
        var lo = [Double.infinity, .infinity, .infinity], hi = [-Double.infinity, -.infinity, -.infinity]
        var badReferences = 0
        for mesh in meshes {
            for prim in ((mesh["primitives"] as? [Any]) ?? []).compactMap({ $0 as? [String: Any] }) {
                info.primitiveCount += 1
                let attrs = prim["attributes"] as? [String: Any]
                let mode = (prim["mode"] as? NSNumber)?.intValue ?? 4
                let count = prim["indices"] != nil ? accessorCount(prim["indices"]) : accessorCount(attrs?["POSITION"])
                guard let count, count >= 0 else {
                    if prim["extensions"] == nil { badReferences += 1 }
                    continue
                }
                switch mode {
                // Accessor counts come from the file's JSON and can be anything: the display total saturates.
                case 4: triangles = FormatMath.saturatingAdd(triangles, count / 3)
                case 5, 6: triangles = FormatMath.saturatingAdd(triangles, max(0, count - 2))
                default: break
                }
                if let p = (attrs?["POSITION"] as? NSNumber)?.intValue, accessors.indices.contains(p),
                   let mn = accessors[p]["min"] as? [Any], let mx = accessors[p]["max"] as? [Any], mn.count >= 3, mx.count >= 3 {
                    for k in 0..<3 {
                        if let a = (mn[k] as? NSNumber)?.doubleValue, let b = (mx[k] as? NSNumber)?.doubleValue, a.isFinite, b.isFinite {
                            lo[k] = min(lo[k], a); hi[k] = max(hi[k], b)
                        }
                    }
                }
            }
        }
        s.triangleCount = triangles
        if lo[0] <= hi[0], lo[1] <= hi[1], lo[2] <= hi[2] {
            s.bounds = MediaBox3(min: MediaVector3(x: lo[0], y: lo[1], z: lo[2]), max: MediaVector3(x: hi[0], y: hi[1], z: hi[2]))
        }
        s.vertexCount = nil
        s.objectCount = meshes.count
        s.objects = meshes.compactMap { MediaText.clean($0["name"] as? String, max: 200) }.prefix(maxNames).map { $0 }
        s.materials = array("materials").compactMap { MediaText.clean($0["name"] as? String, max: 200) }.prefix(maxNames).map { $0 }
        s.gltf = info
        s.title = MediaText.clean(((asset?["extras"] as? [String: Any])?["title"]) as? String, max: 200)

        if let v = info.version, !v.hasPrefix("2.") {
            s.warnings.append(MediaWarning(.danger, String(localized: "This is glTF \(v); only glTF 2.0 is read.", bundle: .module, comment: "3D model card warning. Arguments are filled in at run time.")))
        } else if info.version == nil {
            s.warnings.append(MediaWarning(.danger, String(localized: "The glTF file has no asset version; it may not be a glTF model.", bundle: .module, comment: "3D model card warning.")))
        }
        let compression = info.extensionsRequired.filter { ["KHR_draco_mesh_compression", "EXT_meshopt_compression", "KHR_meshopt_compression"].contains($0) }
        if !compression.isEmpty {
            s.warnings.append(MediaWarning(.caution, String(localized: "The meshes are compressed (\(compression.joined(separator: ", "))); the triangle count comes from the declared accessors.", bundle: .module, comment: "3D model card warning. Arguments are filled in at run time.")))
        }
        if !info.externalResources.isEmpty {
            s.warnings.append(MediaWarning(.caution, String(localized: "The model uses \(info.externalResources.count) files stored next to it (buffers or textures); Vitrine never opens them.", bundle: .module, comment: "3D card warning. The argument is a count.")))
        }
        if badReferences > 0 {
            s.warnings.append(MediaWarning(.danger, String(localized: "\(badReferences) primitives point at accessors that do not exist.", bundle: .module, comment: "3D card warning. The argument is a count.")))
        }

        var facts: [MediaFact] = [MediaFact(String(localized: "Triangles", bundle: .module, comment: "3D model card fact label."), triangles.formatted())]
        if let b = s.bounds { facts.append(MediaFact(String(localized: "Size", bundle: .module, comment: "3D model card fact label."), dimensions(b.size, units: nil))) }
        facts.append(MediaFact(String(localized: "Meshes", bundle: .module, comment: "3D model card fact label."), "\(info.meshCount) (\(info.primitiveCount) primitives)"))
        facts.append(MediaFact(String(localized: "Nodes", bundle: .module, comment: "3D model card fact label."), "\(info.nodeCount)"))
        if info.sceneCount > 0 { facts.append(MediaFact(String(localized: "Scenes", bundle: .module, comment: "3D model card fact label."), "\(info.sceneCount)")) }
        if info.materialCount > 0 { facts.append(MediaFact(String(localized: "Materials", bundle: .module, comment: "3D model card fact label."), "\(info.materialCount)")) }
        if info.textureCount > 0 { facts.append(MediaFact(String(localized: "Textures", bundle: .module, comment: "3D model card fact label."), "\(info.textureCount)")) }
        if info.animationCount > 0 { facts.append(MediaFact(String(localized: "Animations", bundle: .module, comment: "3D model card fact label."), "\(info.animationCount)")) }
        if info.skinCount > 0 { facts.append(MediaFact(String(localized: "Skins", bundle: .module, comment: "3D model card fact label."), "\(info.skinCount)")) }
        if let g = info.generator { facts.append(MediaFact(String(localized: "Made with", bundle: .module, comment: "3D model card fact label."), g)) }
        if !info.extensionsUsed.isEmpty { facts.append(MediaFact(String(localized: "Extensions", bundle: .module, comment: "3D model card fact label."), info.extensionsUsed.prefix(6).joined(separator: ", "))) }
        s.facts = facts
        if let t = s.title { s.headline = t }
        return s
    }

    // MARK: Facts

    static func dimensions(_ v: MediaVector3, units: String?) -> String {
        let suffix = units.map { " " + unitSymbol($0) } ?? ""
        return "\(MediaText.number(v.x, digits: 2)) × \(MediaText.number(v.y, digits: 2)) × \(MediaText.number(v.z, digits: 2))\(suffix)"
    }

    static func unitSymbol(_ unit: String) -> String {
        switch unit {
        case "micron": "µm"
        case "millimeter": "mm"
        case "centimeter": "cm"
        case "inch": "in"
        case "foot": "ft"
        case "meter": "m"
        default: unit
        }
    }

    static func finishFacts(_ s: inout MediaModelSummary, unitsKnown: Bool) {
        let unit = unitsKnown ? s.units : nil
        var facts: [MediaFact] = [MediaFact(String(localized: "Triangles", bundle: .module, comment: "3D model card fact label."), s.triangleCount.formatted())]
        if let v = s.vertexCount { facts.append(MediaFact(String(localized: "Vertices", bundle: .module, comment: "3D model card fact label."), v.formatted())) }
        if let f = s.faceCount { facts.append(MediaFact(String(localized: "Faces", bundle: .module, comment: "3D model card fact label."), f.formatted())) }
        if let b = s.bounds { facts.append(MediaFact(String(localized: "Size", bundle: .module, comment: "3D model card fact label."), dimensions(b.size, units: unit))) }
        let u = unit.map(unitSymbol)
        if let a = s.surfaceArea { facts.append(MediaFact(String(localized: "Surface area", bundle: .module, comment: "3D model card fact label."), "\(MediaText.number(a, digits: 2))\(u.map { " \($0)²" } ?? "")")) }
        if let v = s.volume, s.isClosed == true { facts.append(MediaFact(String(localized: "Volume", bundle: .module, comment: "3D model card fact label."), "\(MediaText.number(v, digits: 2))\(u.map { " \($0)³" } ?? "")")) }
        if let closed = s.isClosed { facts.append(MediaFact(String(localized: "Closed mesh", bundle: .module, comment: "3D card fact label."), closed ? String(localized: "Yes", bundle: .module, comment: "A yes/no fact value.") : String(localized: "No", bundle: .module, comment: "A yes/no fact value."))) }
        if s.objectCount > 0 { facts.append(MediaFact(String(localized: "Objects", bundle: .module, comment: "3D model card fact label."), "\(s.objectCount)")) }
        if !s.groups.isEmpty { facts.append(MediaFact(String(localized: "Groups", bundle: .module, comment: "3D model card fact label."), "\(s.groups.count)")) }
        if !s.materials.isEmpty { facts.append(MediaFact(String(localized: "Materials", bundle: .module, comment: "3D model card fact label."), s.materials.prefix(6).joined(separator: ", "))) }
        if let unit = s.units, unitsKnown { facts.append(MediaFact(String(localized: "Units", bundle: .module, comment: "3D model card fact label."), unit)) }
        s.facts = facts + (s.format.hasPrefix("STL") ? s.metadata : [])     // an STL's header line
        if s.headline == "", let t = s.title { s.headline = t }
        if let t = s.title, s.format.hasPrefix("STL") { s.headline = t }
    }
}

// MARK: - Mesh builder

/// Takes triangles one at a time and works out the bounds, surface area, volume, the closed-mesh check (edges
/// counted between deduplicated corner positions) and an evenly decimated copy for drawing: every k-th triangle is
/// kept, and k doubles whenever the copy reaches 20,000, so the result is deterministic and never larger.
struct MediaMeshBuilder {
    var expected: Int?
    var triangles = 0
    var invalid = 0
    var area = 0.0
    var volume = 0.0
    var lo = (Double.infinity, Double.infinity, Double.infinity)
    var hi = (-Double.infinity, -Double.infinity, -Double.infinity)
    var draw: [Float] = []
    var stride = 1
    var checkEdges = true
    var vertexIDs: [MediaVertexKey: UInt32] = [:]
    var edges: [UInt64: UInt8] = [:]

    mutating func add(_ t: [Float]) {
        for v in t where !v.isFinite { invalid += 1; return }
        let index = triangles
        triangles += 1
        let ax = Double(t[0]), ay = Double(t[1]), az = Double(t[2])
        let bx = Double(t[3]), by = Double(t[4]), bz = Double(t[5])
        let cx = Double(t[6]), cy = Double(t[7]), cz = Double(t[8])
        for (x, y, z) in [(ax, ay, az), (bx, by, bz), (cx, cy, cz)] {
            lo = (min(lo.0, x), min(lo.1, y), min(lo.2, z))
            hi = (max(hi.0, x), max(hi.1, y), max(hi.2, z))
        }
        let ux = bx - ax, uy = by - ay, uz = bz - az
        let vx = cx - ax, vy = cy - ay, vz = cz - az
        let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
        area += 0.5 * (nx * nx + ny * ny + nz * nz).squareRoot()
        volume += (ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx)) / 6

        if checkEdges {
            if triangles > MediaModelReader.maxEdgeCheckTriangles {
                checkEdges = false
                vertexIDs = [:]
                edges = [:]
            } else {
                let ids = (0..<3).map { c -> UInt32 in
                    let key = MediaVertexKey(t[c * 3], t[c * 3 + 1], t[c * 3 + 2])
                    if let id = vertexIDs[key] { return id }
                    let id = UInt32(vertexIDs.count)
                    vertexIDs[key] = id
                    return id
                }
                if ids[0] != ids[1], ids[1] != ids[2], ids[0] != ids[2] {
                    for (a, b) in [(ids[0], ids[1]), (ids[1], ids[2]), (ids[2], ids[0])] {
                        let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                        let n = edges[key] ?? 0
                        edges[key] = n == 255 ? 255 : n + 1
                    }
                }
            }
        }

        if index % stride == 0 {
            draw.append(contentsOf: t)
            if draw.count / 9 >= MediaModelReader.maxDrawTriangles {
                // Keep every other kept triangle: those whose index is a multiple of the doubled stride.
                var kept: [Float] = []
                kept.reserveCapacity(draw.count / 2)
                var k = 0
                while k < draw.count / 9 {
                    if k % 2 == 0 { kept.append(contentsOf: draw[(k * 9)..<(k * 9 + 9)]) }
                    k += 1
                }
                draw = kept
                stride *= 2
            }
        }
    }

    func finish(into s: inout MediaModelSummary, positionsForBounds: [Float]? = nil) {
        s.triangleCount = triangles
        var lo = self.lo, hi = self.hi
        if let p = positionsForBounds, triangles == 0 || lo.0 > hi.0 {
            var i = 0
            while i + 2 < p.count {
                let x = Double(p[i]), y = Double(p[i + 1]), z = Double(p[i + 2])
                if x.isFinite, y.isFinite, z.isFinite {
                    lo = (min(lo.0, x), min(lo.1, y), min(lo.2, z))
                    hi = (max(hi.0, x), max(hi.1, y), max(hi.2, z))
                }
                i += 3
            }
        }
        if lo.0 <= hi.0 {
            s.bounds = MediaBox3(min: MediaVector3(x: lo.0, y: lo.1, z: lo.2), max: MediaVector3(x: hi.0, y: hi.1, z: hi.2))
        }
        if triangles > 0 {
            s.surfaceArea = area
            s.volume = abs(volume)
            s.mesh = MediaMesh(positions: draw, sourceTriangleCount: triangles)
        }
        if checkEdges, triangles > 0 {
            var open = 0, over = 0
            for (_, n) in edges {
                if n == 1 { open += 1 } else if n > 2 { over += 1 }
            }
            s.openEdgeCount = open
            s.nonManifoldEdgeCount = over
            s.isClosed = open == 0 && over == 0
        }
        if invalid > 0 {
            s.warnings.append(MediaWarning(.danger, String(localized: "\(invalid) triangles have corners that are not numbers and were skipped.", bundle: .module, comment: "3D card warning. The argument is a count.")))
        }
    }
}

/// A corner position by its exact bits (with -0 folded into 0), for edge counting.
struct MediaVertexKey: Hashable {
    let x: UInt32, y: UInt32, z: UInt32
    init(_ x: Float, _ y: Float, _ z: Float) {
        self.x = (x == 0 ? 0 : x).bitPattern
        self.y = (y == 0 ? 0 : y).bitPattern
        self.z = (z == 0 ? 0 : z).bitPattern
    }
}

// MARK: - 3MF parser

/// Streams 3MF model XML: objects, vertices, triangles, components, build items and metadata.
final class Media3MFParser: NSObject, XMLParserDelegate {
    var builder = MediaMeshBuilder()
    var unit: String?
    var metadata: [MediaFact] = []
    var objectCount = 0
    var objectNames: [String] = []
    var buildItems = 0
    var vertexTotal = 0
    var badTriangles = 0
    var truncated = false
    var stopped = false
    var isMainPart = true

    private var vertices: [Float] = []
    private var metaName: String?
    private var text = ""
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        depth += 1
        if depth > 64 { stopped = true; truncated = true; parser.abortParsing(); return }
        switch MediaXMLElement.local(elementName) {
        case "model":
            if isMainPart { unit = attributes["unit"] }
        case "metadata":
            metaName = attributes["name"]
            text = ""
        case "object":
            objectCount += 1
            vertices.removeAll(keepingCapacity: true)
            if let name = MediaText.clean(attributes["name"], max: 200) {
                if objectNames.count < MediaModelReader.maxNames { objectNames.append(name) } else { truncated = true }
            }
        case "vertex":
            if let x = attributes["x"].flatMap(Float.init), let y = attributes["y"].flatMap(Float.init), let z = attributes["z"].flatMap(Float.init) {
                vertices.append(x); vertices.append(y); vertices.append(z)
            } else {
                vertices.append(.nan); vertices.append(.nan); vertices.append(.nan)
            }
            vertexTotal += 1
        case "triangle":
            let n = vertices.count / 3
            guard let a = attributes["v1"].flatMap(Int.init), let b = attributes["v2"].flatMap(Int.init),
                  let c = attributes["v3"].flatMap(Int.init), a >= 0, b >= 0, c >= 0, a < n, b < n, c < n else {
                badTriangles += 1
                return
            }
            builder.add([vertices[a * 3], vertices[a * 3 + 1], vertices[a * 3 + 2],
                         vertices[b * 3], vertices[b * 3 + 1], vertices[b * 3 + 2],
                         vertices[c * 3], vertices[c * 3 + 1], vertices[c * 3 + 2]])
        case "item":
            buildItems += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if metaName != nil, text.utf8.count < 10_000 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
        if MediaXMLElement.local(elementName) == "metadata", let name = metaName {
            if let value = MediaText.clean(text, max: 500), metadata.count < 50 { metadata.append(MediaFact(name, value)) }
            metaName = nil
        }
    }
}

// MARK: - Numbers

/// Number parsing straight from bytes, for text formats with millions of numbers (ASCII STL, OBJ).
enum MediaNumber {
    static func parse(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> Double? {
        var i = start
        guard i < end else { return nil }
        var negative = false
        if p[i] == 45 || p[i] == 43 { negative = p[i] == 45; i += 1 }
        var mantissa = 0.0
        var digits = 0
        var exponent = 0
        while i < end, p[i] >= 48, p[i] <= 57 { mantissa = mantissa * 10 + Double(p[i] - 48); i += 1; digits += 1 }
        if i < end, p[i] == 46 {
            i += 1
            while i < end, p[i] >= 48, p[i] <= 57 { mantissa = mantissa * 10 + Double(p[i] - 48); exponent -= 1; i += 1; digits += 1 }
        }
        guard digits > 0 else {
            // "nan", "inf" and the like.
            let word = String(decoding: UnsafeBufferPointer(start: p + start, count: end - start), as: UTF8.self)
            return Double(word)
        }
        if i < end, p[i] == 101 || p[i] == 69 {
            i += 1
            var eneg = false
            if i < end, p[i] == 45 || p[i] == 43 { eneg = p[i] == 45; i += 1 }
            var e = 0
            var edigits = 0
            while i < end, p[i] >= 48, p[i] <= 57 { if e < 10_000 { e = e * 10 + Int(p[i] - 48) }; i += 1; edigits += 1 }
            guard edigits > 0 else { return nil }
            exponent += eneg ? -e : e
        }
        guard i == end else { return nil }
        let value = exponent == 0 ? mantissa : mantissa * pow(10, Double(exponent))
        return negative ? -value : value
    }

    static func parseInt(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> Int? {
        var i = start
        guard i < end else { return nil }
        var negative = false
        if p[i] == 45 || p[i] == 43 { negative = p[i] == 45; i += 1 }
        guard i < end else { return nil }
        var v = 0
        while i < end {
            guard p[i] >= 48, p[i] <= 57 else { return nil }
            if v < 1_000_000_000_000 { v = v * 10 + Int(p[i] - 48) }
            i += 1
        }
        return negative ? -v : v
    }
}
