import Foundation

/// A point on the Earth: degrees, and metres above sea level when the file gives them. roadmap: S-23
public struct MediaCoordinate: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var elevation: Double?

    public init(latitude: Double, longitude: Double, elevation: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
    }
}

/// The box around every coordinate of a map file. roadmap: S-23
public struct MediaBounds: Sendable, Equatable {
    public var minLatitude: Double
    public var minLongitude: Double
    public var maxLatitude: Double
    public var maxLongitude: Double

    public init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.minLongitude = minLongitude
        self.maxLatitude = maxLatitude
        self.maxLongitude = maxLongitude
    }
}

/// A line to draw on the map: a track, route, LineString or polygon ring, simplified to at most 500 points
/// (Douglas–Peucker). roadmap: S-23
public struct MediaPolyline: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case track, route, line, polygon }
    public var kind: Kind
    public var name: String?
    public var points: [MediaCoordinate]
    /// How many points the file had before simplification.
    public var originalPointCount: Int
}

/// One sample of an elevation profile: distance along the track and height there. roadmap: S-23
public struct MediaElevationSample: Sendable, Equatable {
    public var distanceMeters: Double
    public var elevationMeters: Double
}

/// A GPX track with its distance, elevation and timing. roadmap: S-23
public struct MediaTrack: Sendable, Equatable {
    public var name: String?
    public var segmentCount: Int
    public var pointCount: Int
    /// Haversine distance over consecutive points of each segment.
    public var distanceMeters: Double
    public var minElevation: Double?
    public var maxElevation: Double?
    /// Sum of every rise and every fall between consecutive points (raw, no smoothing).
    public var elevationGain: Double?
    public var elevationLoss: Double?
    public var startTime: Date?
    public var endTime: Date?
    /// Time spent between points while moving faster than 0.5 m/s.
    public var movingSeconds: Double?
}

/// A GPX route (planned, `rte`). roadmap: S-23
public struct MediaRoute: Sendable, Equatable {
    public var name: String?
    public var pointCount: Int
    public var distanceMeters: Double
}

/// A named point (a GPX waypoint, a KML or GeoJSON point). roadmap: S-23
public struct MediaWaypoint: Sendable, Equatable {
    public var name: String?
    public var coordinate: MediaCoordinate
}

/// A GeoJSON, GPX, KML or KMZ file (N-6): what it holds and what to draw. roadmap: S-23
public struct MediaMapSummary: Sendable, Equatable {
    public var headline: String
    public var facts: [MediaFact]
    public var warnings: [MediaWarning]
    /// "GeoJSON", "GPX", "KML" or "KMZ".
    public var format: String
    public var bounds: MediaBounds?
    /// Features or placemarks by geometry type ("LineString", 12), most frequent first.
    public var geometryCounts: [MediaCount]
    /// GeoJSON features, KML placemarks.
    public var featureCount: Int
    /// GeoJSON property keys, most frequent first, at most 100.
    public var propertyKeys: [String]
    public var tracks: [MediaTrack]
    public var routes: [MediaRoute]
    public var waypoints: [MediaWaypoint]
    public var folderCount: Int
    /// KML folder names, at most 100.
    public var folderNames: [String]
    /// The KML document's or GPX metadata's name.
    public var documentName: String?
    /// Lines to draw, each at most 500 points; at most 200 lines.
    public var lines: [MediaPolyline]
    /// Points to draw as markers, at most 1,000.
    public var points: [MediaCoordinate]
    /// GPX tracks' elevation along their distance, at most 300 samples.
    public var elevationProfile: [MediaElevationSample]
    public var truncated: Bool
}

enum MediaMapReader {
    static let maxLinePoints = 500
    static let maxLines = 200
    static let maxMarkers = 1_000
    static let maxProfileSamples = 300
    static let maxPropertyKeys = 100
    static let maxListed = 1_000
    static let maxCollectedPoints = 5_000_000

    static func read(_ data: Data, fileName: String, format: MediaFormat, inputCapped: Bool) -> MediaMapSummary? {
        var summary: MediaMapSummary?
        switch format {
        case .geoJSON: summary = readGeoJSON(data, fileName: fileName)
        case .gpx: summary = readGPX(data, fileName: fileName)
        case .kml: summary = readKML(data, fileName: fileName, label: "KML")
        case .kmz:
            guard let archive = MediaArchive.open(data, fileName: fileName) else { return nil }
            let kmls = archive.fileIndices.filter { MediaPath.ext(archive.path($0)) == "kml" }
            let main = archive.index(of: "doc.kml")
                ?? kmls.first { !archive.path($0).contains("/") } ?? kmls.first
            guard let main else {
                return empty(fileName: fileName, format: "KMZ", warning: MediaWarning(.danger, String(localized: "This KMZ holds no KML document (doc.kml is missing).", bundle: .module, comment: "Map card warning.")))
            }
            guard let kml = archive.read(main, limit: MediaLimits.maxInputBytes) else {
                let why = archive.readFailure(main, limit: MediaLimits.maxInputBytes) ?? MediaText.unknownReason
                return empty(fileName: fileName, format: "KMZ", warning: MediaWarning(.danger, String(localized: "The KMZ's KML document cannot be read: \(why).", bundle: .module, comment: "Map card warning. Arguments are filled in at run time.")))
            }
            summary = readKML(kml, fileName: fileName, label: "KMZ")
            let others = archive.fileIndices.count - 1
            if others > 0 { summary?.facts.append(MediaFact(String(localized: "Bundled files", bundle: .module, comment: "Map card fact label."), "\(others)")) }
        default: return nil
        }
        if inputCapped {
            summary?.truncated = true
            summary?.warnings.append(MediaWarning(.caution, String(localized: "Only the first 256 MB of this file were read.", bundle: .module, comment: "Map card warning.")))
        }
        return summary
    }

    static func empty(fileName: String, format: String, warning: MediaWarning) -> MediaMapSummary {
        MediaMapSummary(headline: MediaPath.base(fileName), facts: [], warnings: [warning], format: format, bounds: nil,
                        geometryCounts: [], featureCount: 0, propertyKeys: [], tracks: [], routes: [], waypoints: [],
                        folderCount: 0, folderNames: [], documentName: nil, lines: [], points: [], elevationProfile: [],
                        truncated: false)
    }

    // MARK: GeoJSON

    static func readGeoJSON(_ data: Data, fileName: String) -> MediaMapSummary? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return empty(fileName: fileName, format: "GeoJSON", warning: MediaWarning(.danger, String(localized: "This file is not valid JSON.", bundle: .module, comment: "Map card warning.")))
        }
        guard let root = json as? [String: Any], let type = root["type"] as? String else {
            return empty(fileName: fileName, format: "GeoJSON", warning: MediaWarning(.danger, String(localized: "This JSON is not GeoJSON: it has no \"type\" member.", bundle: .module, comment: "Map card warning.")))
        }
        var acc = MediaMapAccumulator()
        var keyCounts: [String: Int] = [:]
        var keyOrder: [String] = []
        var features = 0

        func feature(_ f: [String: Any]) {
            features += 1
            if let props = f["properties"] as? [String: Any] {
                for key in props.keys.sorted() {
                    if keyCounts[key] == nil {
                        if keyOrder.count >= 10_000 { continue }
                        keyOrder.append(key)
                    }
                    keyCounts[key, default: 0] += 1
                }
            }
            let name = (f["properties"] as? [String: Any]).flatMap { ($0["name"] ?? $0["title"]) as? String }
            if let g = f["geometry"] as? [String: Any] { geometry(g, name: name, depth: 0) } else { acc.count("None") }
        }

        func position(_ any: Any) -> MediaCoordinate? {
            guard let a = any as? [Any], a.count >= 2, let lon = (a[0] as? NSNumber)?.doubleValue,
                  let lat = (a[1] as? NSNumber)?.doubleValue, lon.isFinite, lat.isFinite else { return nil }
            let ele = a.count >= 3 ? (a[2] as? NSNumber)?.doubleValue : nil
            return MediaCoordinate(latitude: lat, longitude: lon, elevation: ele)
        }
        func line(_ any: Any) -> [MediaCoordinate] { (any as? [Any])?.compactMap(position) ?? [] }

        func geometry(_ g: [String: Any], name: String?, depth: Int) {
            guard let type = g["type"] as? String else { acc.malformed += 1; return }
            acc.count(type)
            let coords = g["coordinates"]
            switch type {
            case "Point":
                if let p = coords.flatMap(position) { acc.marker(p) } else { acc.malformed += 1 }
            case "MultiPoint":
                for p in coords.map(line) ?? [] { acc.marker(p) }
            case "LineString":
                acc.line(coords.map(line) ?? [], kind: .line, name: name)
            case "MultiLineString":
                for part in (coords as? [Any]) ?? [] { acc.line(line(part), kind: .line, name: name) }
            case "Polygon":
                for (i, ring) in ((coords as? [Any]) ?? []).enumerated() { acc.line(line(ring), kind: .polygon, name: name, draw: i == 0) }
            case "MultiPolygon":
                for poly in (coords as? [Any]) ?? [] {
                    for (i, ring) in ((poly as? [Any]) ?? []).enumerated() { acc.line(line(ring), kind: .polygon, name: name, draw: i == 0) }
                }
            case "GeometryCollection":
                guard depth < 16 else { acc.truncated = true; return }
                for sub in (g["geometries"] as? [Any]) ?? [] {
                    if let sub = sub as? [String: Any] { geometry(sub, name: name, depth: depth + 1) }
                }
            default:
                acc.malformed += 1
            }
        }

        switch type {
        case "FeatureCollection":
            for f in (root["features"] as? [Any]) ?? [] { if let f = f as? [String: Any] { feature(f) } }
        case "Feature":
            feature(root)
        default:
            geometry(root, name: nil, depth: 0)
            if acc.malformed > 0, acc.geometryCounts.count == 1 {
                return empty(fileName: fileName, format: "GeoJSON", warning: MediaWarning(.danger, String(localized: "This JSON is not GeoJSON: \"\(MediaText.cap(type, 40))\" is not a GeoJSON type.", bundle: .module, comment: "Map card warning. Arguments are filled in at run time.")))
            }
        }

        var s = acc.summary(fileName: fileName, format: "GeoJSON")
        s.featureCount = features
        let keys = keyOrder.sorted { (keyCounts[$0] ?? 0, $1) > (keyCounts[$1] ?? 0, $0) }
        s.propertyKeys = Array(keys.prefix(maxPropertyKeys))
        if keys.count > maxPropertyKeys { s.truncated = true }
        if root["crs"] != nil {
            s.warnings.append(MediaWarning(.caution, String(localized: "The file names a coordinate reference system (\"crs\"); GeoJSON today is always longitude/latitude (WGS 84), so positions may be misplaced.", bundle: .module, comment: "Map card warning.")))
        }
        var facts = [MediaFact(String(localized: "Features", bundle: .module, comment: "Map card fact label."), "\(features)")]
        facts += s.geometryCounts.prefix(6).map { MediaFact($0.name, "\($0.count)") }
        if !s.propertyKeys.isEmpty { facts.append(MediaFact(String(localized: "Properties", bundle: .module, comment: "Map card fact label."), s.propertyKeys.prefix(8).joined(separator: ", "))) }
        s.facts = facts + s.facts
        s.headline = features > 0 ? String(localized: "\(features) features", bundle: .module, comment: "Map card headline. The argument is a count.") : s.headline
        return s
    }

    // MARK: GPX

    static func readGPX(_ data: Data, fileName: String) -> MediaMapSummary? {
        let parser = MediaGPXParser()
        let ok = MediaXMLStream.run(data, delegate: parser)
        if !parser.sawRoot {
            return empty(fileName: fileName, format: "GPX", warning: MediaWarning(.danger, String(localized: "This is not a GPX file: its XML is damaged or has no <gpx> element.", bundle: .module, comment: "Map card warning.")))
        }
        var s = parser.acc.summary(fileName: fileName, format: "GPX")
        s.tracks = parser.tracks.map(\.track)
        s.routes = parser.routes
        s.waypoints = parser.waypoints
        s.documentName = parser.metadataName
        s.truncated = s.truncated || parser.truncated
        s.elevationProfile = profile(parser.profile)
        s.featureCount = parser.tracks.count + parser.routes.count + parser.waypointTotal
        s.geometryCounts = []
        if !ok {
            s.warnings.append(MediaWarning(.danger, String(localized: "The GPX file is damaged or cut short; what was read before the damage is shown.", bundle: .module, comment: "Map card warning.")))
        }

        let distance = s.tracks.reduce(0) { $0 + $1.distanceMeters }
        let points = s.tracks.reduce(0) { $0 + $1.pointCount }
        var facts: [MediaFact] = []
        facts.append(MediaFact(String(localized: "Tracks", bundle: .module, comment: "Map card fact label."), "\(s.tracks.count)"))
        if !s.tracks.isEmpty {
            facts.append(MediaFact(String(localized: "Track points", bundle: .module, comment: "Map card fact label."), "\(points)"))
            facts.append(MediaFact(String(localized: "Distance", bundle: .module, comment: "Map card fact label."), MediaText.meters(distance)))
            let mins = s.tracks.compactMap(\.minElevation), maxs = s.tracks.compactMap(\.maxElevation)
            if let lo = mins.min(), let hi = maxs.max() {
                facts.append(MediaFact(String(localized: "Elevation", bundle: .module, comment: "Map card fact label."), "\(MediaText.number(lo, digits: 0))–\(MediaText.number(hi, digits: 0)) m"))
                let gain = s.tracks.compactMap(\.elevationGain).reduce(0, +)
                let loss = s.tracks.compactMap(\.elevationLoss).reduce(0, +)
                facts.append(MediaFact(String(localized: "Climb", bundle: .module, comment: "Map card fact label."), "+\(MediaText.number(gain, digits: 0)) m / −\(MediaText.number(loss, digits: 0)) m"))
            }
            if let start = s.tracks.compactMap(\.startTime).min(), let end = s.tracks.compactMap(\.endTime).max() {
                facts.append(MediaFact(String(localized: "Start", bundle: .module, comment: "Map card fact label."), start.formatted(date: .abbreviated, time: .shortened)))
                facts.append(MediaFact(String(localized: "Elapsed", bundle: .module, comment: "Map card fact label."), MediaText.duration(end.timeIntervalSince(start))))
            }
            let moving = s.tracks.compactMap(\.movingSeconds).reduce(0, +)
            if moving > 0 { facts.append(MediaFact(String(localized: "Moving time", bundle: .module, comment: "Map card fact label."), MediaText.duration(moving))) }
        }
        if !s.routes.isEmpty { facts.append(MediaFact(String(localized: "Routes", bundle: .module, comment: "Map card fact label."), "\(s.routes.count)")) }
        if parser.waypointTotal > 0 { facts.append(MediaFact(String(localized: "Waypoints", bundle: .module, comment: "Map card fact label."), "\(parser.waypointTotal)")) }
        if let creator = parser.creator { facts.append(MediaFact(String(localized: "Created by", bundle: .module, comment: "Map card fact label."), creator)) }
        s.facts = facts + s.facts
        if let name = parser.metadataName ?? s.tracks.first?.name ?? s.routes.first?.name {
            s.headline = name
        } else if !s.tracks.isEmpty {
            s.headline = String(localized: "\(MediaText.meters(distance)) track", bundle: .module, comment: "Map card headline. The argument is a distance.")
        }
        return s
    }

    // MARK: KML

    static func readKML(_ data: Data, fileName: String, label: String) -> MediaMapSummary? {
        let parser = MediaKMLParser()
        let ok = MediaXMLStream.run(data, delegate: parser)
        if !parser.sawRoot {
            return empty(fileName: fileName, format: label, warning: MediaWarning(.danger, String(localized: "This is not a KML document: its XML is damaged or has no <kml> element.", bundle: .module, comment: "Map card warning.")))
        }
        var s = parser.acc.summary(fileName: fileName, format: label)
        s.featureCount = parser.placemarks
        s.folderCount = parser.folders
        s.folderNames = parser.folderNames
        s.documentName = parser.documentName
        s.truncated = s.truncated || parser.truncated
        if !ok {
            s.warnings.append(MediaWarning(.danger, String(localized: "The KML document is damaged or cut short; what was read before the damage is shown.", bundle: .module, comment: "Map card warning.")))
        }
        var facts = [MediaFact(String(localized: "Placemarks", bundle: .module, comment: "Map card fact label."), "\(parser.placemarks)")]
        facts += s.geometryCounts.prefix(6).map { MediaFact($0.name, "\($0.count)") }
        if parser.folders > 0 { facts.append(MediaFact(String(localized: "Folders", bundle: .module, comment: "Map card fact label."), "\(parser.folders)")) }
        s.facts = facts + s.facts
        if let name = parser.documentName { s.headline = name }
        return s
    }

    // MARK: Geometry

    /// Distance between two points on a sphere of the Earth's mean radius.
    static func haversine(_ a: MediaCoordinate, _ b: MediaCoordinate) -> Double {
        let r = 6_371_008.8
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Douglas–Peucker keeping at most `maxPoints`: segments are split in order of their farthest point's distance
    /// (largest first), so the result is the DP simplification at the tolerance that leaves `maxPoints` points.
    /// Inputs above 50,000 points are thinned evenly first, so the cost stays bounded.
    static func simplify(_ input: [MediaCoordinate], maxPoints: Int) -> [MediaCoordinate] {
        guard input.count > maxPoints, maxPoints >= 2 else { return input }
        var pts = input
        if pts.count > 50_000 {
            let step = Double(pts.count - 1) / Double(50_000 - 1)
            pts = (0..<50_000).map { input[Int((Double($0) * step).rounded())] }
        }
        let midLat = (pts.map(\.latitude).min()! + pts.map(\.latitude).max()!) / 2
        let kx = cos(midLat * .pi / 180)
        func dist(_ p: Int, _ a: Int, _ b: Int) -> Double {
            let ax = pts[a].longitude * kx, ay = pts[a].latitude
            let bx = pts[b].longitude * kx, by = pts[b].latitude
            let px = pts[p].longitude * kx, py = pts[p].latitude
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            if len2 == 0 { return hypot(px - ax, py - ay) }
            let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len2))
            return hypot(px - (ax + t * dx), py - (ay + t * dy))
        }
        struct Segment { var a: Int; var b: Int; var far: Int; var d: Double }
        func make(_ a: Int, _ b: Int) -> Segment? {
            guard b - a > 1 else { return nil }
            var best = -1.0, far = a + 1
            for i in (a + 1)..<b {
                let d = dist(i, a, b)
                if d > best { best = d; far = i }
            }
            return Segment(a: a, b: b, far: far, d: best)
        }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var kept = 2
        var heap: [Segment] = []                                          // max-heap on d
        func push(_ s: Segment) {
            heap.append(s)
            var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                if heap[parent].d >= heap[i].d { break }
                heap.swapAt(parent, i)
                i = parent
            }
        }
        func pop() -> Segment? {
            guard !heap.isEmpty else { return nil }
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < heap.count, heap[l].d > heap[m].d { m = l }
                    if r < heap.count, heap[r].d > heap[m].d { m = r }
                    if m == i { break }
                    heap.swapAt(i, m)
                    i = m
                }
            }
            return top
        }
        if let s = make(0, pts.count - 1) { push(s) }
        while kept < maxPoints, let s = pop() {
            keep[s.far] = true
            kept += 1
            if let l = make(s.a, s.far) { push(l) }
            if let r = make(s.far, s.b) { push(r) }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    /// At most 300 evenly spaced samples of (distance, elevation).
    static func profile(_ all: [MediaElevationSample]) -> [MediaElevationSample] {
        guard all.count > maxProfileSamples else { return all }
        let step = Double(all.count - 1) / Double(maxProfileSamples - 1)
        return (0..<maxProfileSamples).map { all[Int((Double($0) * step).rounded())] }
    }
}

/// Collects geometry while a map file is read: counts, bounds, lines and markers to draw.
struct MediaMapAccumulator {
    var counts: [String: Int] = [:]
    var countOrder: [String] = []
    var minLat = Double.infinity, maxLat = -Double.infinity, minLon = Double.infinity, maxLon = -Double.infinity
    var lines: [MediaPolyline] = []
    var markers: [MediaCoordinate] = []
    var truncated = false
    var malformed = 0
    var outOfRange = 0

    var geometryCounts: [MediaCount] {
        countOrder.map { MediaCount($0, counts[$0] ?? 0) }.sorted { $0.count > $1.count }
    }

    mutating func count(_ type: String) {
        if counts[type] == nil { countOrder.append(type) }
        counts[type, default: 0] += 1
    }

    mutating func include(_ p: MediaCoordinate) {
        guard p.latitude.isFinite, p.longitude.isFinite else { return }
        if abs(p.latitude) > 90 || abs(p.longitude) > 180 { outOfRange += 1 }
        minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
        minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
    }

    mutating func marker(_ p: MediaCoordinate) {
        include(p)
        if markers.count < MediaMapReader.maxMarkers { markers.append(p) } else { truncated = true }
    }

    mutating func line(_ pts: [MediaCoordinate], kind: MediaPolyline.Kind, name: String?, draw: Bool = true) {
        for p in pts { include(p) }
        guard draw, pts.count >= 2 else { return }
        guard lines.count < MediaMapReader.maxLines else { truncated = true; return }
        lines.append(MediaPolyline(kind: kind, name: name.flatMap { MediaText.clean($0, max: 200) },
                                   points: MediaMapReader.simplify(pts, maxPoints: MediaMapReader.maxLinePoints),
                                   originalPointCount: pts.count))
    }

    func summary(fileName: String, format: String) -> MediaMapSummary {
        var s = MediaMapReader.empty(fileName: fileName, format: format, warning: MediaWarning(.caution, ""))
        s.warnings = []
        if minLat <= maxLat {
            s.bounds = MediaBounds(minLatitude: minLat, minLongitude: minLon, maxLatitude: maxLat, maxLongitude: maxLon)
        }
        s.geometryCounts = geometryCounts
        s.lines = lines
        s.points = markers
        s.truncated = truncated
        if malformed > 0 {
            s.warnings.append(MediaWarning(.danger, String(localized: "\(malformed) geometries are damaged and could not be read.", bundle: .module, comment: "Map card warning. The argument is a count.")))
        }
        if outOfRange > 0 {
            s.warnings.append(MediaWarning(.caution, String(localized: "\(outOfRange) positions are outside the valid longitude/latitude range; the file may use a projected coordinate system.", bundle: .module, comment: "Map card warning. The argument is a count.")))
        }
        if let b = s.bounds {
            s.facts.append(MediaFact(String(localized: "Area", bundle: .module, comment: "Map card fact label."), String(format: "%.4f, %.4f to %.4f, %.4f", b.minLatitude, b.minLongitude, b.maxLatitude, b.maxLongitude)))
        }
        return s
    }
}

// MARK: - GPX parser

/// Streams a GPX document: tracks, routes and waypoints, with distance, elevation and time worked out as the points
/// arrive, so a track of a million points costs its drawing arrays and nothing more.
final class MediaGPXParser: NSObject, XMLParserDelegate {
    final class TrackState {
        var track = MediaTrack(name: nil, segmentCount: 0, pointCount: 0, distanceMeters: 0, minElevation: nil,
                               maxElevation: nil, elevationGain: nil, elevationLoss: nil, startTime: nil, endTime: nil,
                               movingSeconds: nil)
        var points: [MediaCoordinate] = []
        var previous: (MediaCoordinate, Date?)?
    }

    var acc = MediaMapAccumulator()
    var sawRoot = false
    var truncated = false
    var creator: String?
    var metadataName: String?
    var tracks: [TrackState] = []
    var routes: [MediaRoute] = []
    var waypoints: [MediaWaypoint] = []
    var waypointTotal = 0
    var profile: [MediaElevationSample] = []
    var profileDistance = 0.0
    var collected = 0

    private var stack: [String] = []
    private var text = ""
    private var collecting = false
    private var point: MediaCoordinate?
    private var pointTime: Date?
    private var pointName: String?
    private var route: (name: String?, points: [MediaCoordinate], distance: Double)?
    private var current: TrackState?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = MediaXMLElement.local(elementName)
        if stack.count > 64 { parser.abortParsing(); return }
        stack.append(name)
        switch name {
        case "gpx":
            sawRoot = true
            creator = MediaText.clean(attributes["creator"], max: 200)
        case "trk":
            if tracks.count >= MediaMapReader.maxListed { truncated = true; current = nil } else {
                let t = TrackState()
                tracks.append(t)
                current = t
            }
        case "trkseg":
            current?.track.segmentCount += 1
            current?.previous = nil
            if let c = current {
                // Each segment draws as its own line; a new segment flushes the previous one's points.
                if c.points.count >= 2 { acc.line(c.points, kind: .track, name: c.track.name) } else { c.points.forEach { acc.include($0) } }
                c.points = []
            }
        case "rte":
            route = (nil, [], 0)
        case "trkpt", "rtept", "wpt":
            if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
               lat.isFinite, lon.isFinite {
                point = MediaCoordinate(latitude: lat, longitude: lon)
            } else {
                point = nil
                acc.malformed += 1
            }
            pointTime = nil
            pointName = nil
        case "ele", "time", "name":
            collecting = true
            text = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting, text.utf8.count < 100_000 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = MediaXMLElement.local(elementName)
        guard !stack.isEmpty else { return }
        stack.removeLast()
        let parent = stack.last ?? ""
        switch name {
        case "ele":
            collecting = false
            if let v = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), v.isFinite { point?.elevation = v }
        case "time":
            collecting = false
            if ["trkpt", "rtept", "wpt"].contains(parent) { pointTime = MediaISODate.parse(text) }
        case "name":
            collecting = false
            let value = MediaText.clean(text, max: 200)
            switch parent {
            case "trkpt", "rtept", "wpt": pointName = value
            case "trk": current?.track.name = value
            case "rte": route?.name = value
            case "metadata": metadataName = value
            default: break
            }
        case "trkpt":
            if let p = point, let t = current { addTrackPoint(p, time: pointTime, to: t) }
            point = nil
        case "rtept":
            if let p = point, route != nil {
                if let last = route?.points.last { route?.distance += MediaMapReader.haversine(last, p) }
                if collected < MediaMapReader.maxCollectedPoints { route?.points.append(p); collected += 1 } else { truncated = true }
            }
            point = nil
        case "wpt":
            if let p = point {
                waypointTotal += 1
                acc.marker(p)
                if waypoints.count < MediaMapReader.maxListed { waypoints.append(MediaWaypoint(name: pointName, coordinate: p)) } else { truncated = true }
            }
            point = nil
        case "rte":
            if let r = route {
                if routes.count < MediaMapReader.maxListed {
                    routes.append(MediaRoute(name: r.name, pointCount: r.points.count, distanceMeters: r.distance))
                } else { truncated = true }
                acc.line(r.points, kind: .route, name: r.name)
            }
            route = nil
        case "trk":
            if let c = current {
                acc.line(c.points, kind: .track, name: c.track.name)
                c.points = []
            }
            current = nil
        default: break
        }
    }

    private func addTrackPoint(_ p: MediaCoordinate, time: Date?, to t: TrackState) {
        t.track.pointCount += 1
        if collected < MediaMapReader.maxCollectedPoints { t.points.append(p); collected += 1 } else { truncated = true; acc.include(p) }
        if let e = p.elevation {
            t.track.minElevation = min(t.track.minElevation ?? e, e)
            t.track.maxElevation = max(t.track.maxElevation ?? e, e)
        }
        if let time {
            t.track.startTime = min(t.track.startTime ?? time, time)
            t.track.endTime = max(t.track.endTime ?? time, time)
        }
        if let (prev, prevTime) = t.previous {
            let d = MediaMapReader.haversine(prev, p)
            t.track.distanceMeters += d
            profileDistance += d
            if let a = prev.elevation, let b = p.elevation {
                let delta = b - a
                if delta > 0 { t.track.elevationGain = (t.track.elevationGain ?? 0) + delta; t.track.elevationLoss = t.track.elevationLoss ?? 0 }
                else { t.track.elevationLoss = (t.track.elevationLoss ?? 0) - delta; t.track.elevationGain = t.track.elevationGain ?? 0 }
            }
            if let a = prevTime, let b = time {
                let dt = b.timeIntervalSince(a)
                if dt > 0, d / dt >= 0.5 { t.track.movingSeconds = (t.track.movingSeconds ?? 0) + dt }
                else if t.track.movingSeconds == nil { t.track.movingSeconds = 0 }
            }
        }
        if let e = p.elevation, profile.count < MediaMapReader.maxCollectedPoints {
            profile.append(MediaElevationSample(distanceMeters: profileDistance, elevationMeters: e))
        }
        t.previous = (p, time)
    }
}

// MARK: - KML parser

/// Streams a KML document: placemarks, folders, points, LineStrings, polygons and gx:Tracks.
final class MediaKMLParser: NSObject, XMLParserDelegate {
    var acc = MediaMapAccumulator()
    var sawRoot = false
    var truncated = false
    var placemarks = 0
    var folders = 0
    var folderNames: [String] = []
    var documentName: String?

    private var stack: [String] = []
    private var text = ""
    private var collecting = false
    private var placemarkName: String?
    private var trackCoords: [MediaCoordinate] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = MediaXMLElement.local(elementName)
        if stack.count > 96 { truncated = true; parser.abortParsing(); return }
        stack.append(name)
        switch name {
        case "kml": sawRoot = true
        case "Placemark": placemarks += 1; placemarkName = nil
        case "Folder": folders += 1
        case "Point", "LineString", "Polygon": acc.count(name)
        case "Track": acc.count("Track"); trackCoords = []
        case "coordinates", "name", "coord":
            collecting = true
            text = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = MediaXMLElement.local(elementName)
        guard !stack.isEmpty else { return }
        stack.removeLast()
        let parent = stack.last ?? ""
        switch name {
        case "name":
            collecting = false
            let value = MediaText.clean(text, max: 200)
            if parent == "Placemark" { placemarkName = value }
            else if parent == "Folder", let value {
                if folderNames.count < MediaMapReader.maxListed / 10 { folderNames.append(value) } else { truncated = true }
            } else if parent == "Document", documentName == nil { documentName = value }
        case "coordinates":
            collecting = false
            let coords = Self.coordinates(text)
            text = ""
            if stack.contains("Point") {
                for p in coords { acc.marker(p) }
            } else if stack.contains("LineString") {
                acc.line(coords, kind: .line, name: placemarkName)
            } else if stack.contains("LinearRing") {
                acc.line(coords, kind: .polygon, name: placemarkName, draw: stack.contains("outerBoundaryIs"))
            } else {
                for p in coords { acc.include(p) }
            }
        case "coord":
            collecting = false
            let parts = text.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            if parts.count >= 2 {
                trackCoords.append(MediaCoordinate(latitude: parts[1], longitude: parts[0], elevation: parts.count > 2 ? parts[2] : nil))
            }
        case "Track":
            acc.line(trackCoords, kind: .track, name: placemarkName)
            trackCoords = []
        default: break
        }
    }

    /// `lon,lat[,alt]` tuples separated by whitespace.
    static func coordinates(_ text: String) -> [MediaCoordinate] {
        var out: [MediaCoordinate] = []
        for tuple in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }) {
            let parts = tuple.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 2, let lon = Double(parts[0]), let lat = Double(parts[1]), lon.isFinite, lat.isFinite else { continue }
            out.append(MediaCoordinate(latitude: lat, longitude: lon, elevation: parts.count > 2 ? Double(parts[2]) : nil))
        }
        return out
    }
}

// MARK: - Dates

/// A fast ISO 8601 reader for GPX timestamps (`2026-05-01T10:00:00Z`, fractional seconds and offsets allowed);
/// a formatter per point would cost more than the rest of the parse.
enum MediaISODate {
    static func parse(_ raw: String) -> Date? {
        let s = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard s.count >= 19 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= s.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                guard s[i] >= 48, s[i] <= 57 else { return nil }
                v = v * 10 + Int(s[i] - 48)
            }
            return v
        }
        guard let y = num(0, 4), s[4] == 45, let mo = num(5, 2), s[7] == 45, let d = num(8, 2),
              s[10] == 84 || s[10] == 32, let h = num(11, 2), s[13] == 58, let mi = num(14, 2), s[16] == 58,
              let sec = num(17, 2), (1...12).contains(mo), (1...31).contains(d), h < 25, mi < 60, sec < 61 else { return nil }
        var i = 19
        var frac = 0.0
        if i < s.count, s[i] == 46 {
            i += 1
            var scale = 0.1
            while i < s.count, s[i] >= 48, s[i] <= 57 { frac += Double(s[i] - 48) * scale; scale /= 10; i += 1 }
        }
        var offset = 0
        if i < s.count {
            if s[i] == 90 { offset = 0 }
            else if s[i] == 43 || s[i] == 45, let oh = num(i + 1, 2) {
                let om = (i + 3 < s.count && s[i + 3] == 58) ? (num(i + 4, 2) ?? 0) : (num(i + 3, 2) ?? 0)
                offset = (oh * 3600 + om * 60) * (s[i] == 45 ? -1 : 1)
            }
        }
        // Days from the civil date (Howard Hinnant's algorithm).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = Double(days * 86_400 + h * 3600 + mi * 60 + sec - offset) + frac
        return Date(timeIntervalSince1970: seconds)
    }
}
