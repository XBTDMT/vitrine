import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import VitrineFormats

// Every fixture here is invented and built in the test: zips assembled byte by byte, synthetic meshes, tag streams
// and images drawn with Core Graphics. Nothing is read from disk. roadmap: S-23

// MARK: - Byte helpers

fileprivate struct Bytes {
    var b: [UInt8] = []
    mutating func u8(_ v: UInt8) { b.append(v) }
    mutating func le16(_ v: Int) { b += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    mutating func le32(_ v: Int) { for i in 0..<4 { b.append(UInt8((v >> (8 * i)) & 0xFF)) } }
    mutating func le64(_ v: UInt64) { for i in 0..<8 { b.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    mutating func be16(_ v: Int) { b += [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    mutating func be24(_ v: Int) { b += [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    mutating func be32(_ v: Int) { for i in (0..<4).reversed() { b.append(UInt8((v >> (8 * i)) & 0xFF)) } }
    mutating func be64(_ v: UInt64) { for i in (0..<8).reversed() { b.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
    mutating func f32(_ v: Float) { le32(Int(v.bitPattern)) }
    mutating func ascii(_ s: String) { b += Array(s.utf8) }
    mutating func bytes(_ x: [UInt8]) { b += x }
    var data: Data { Data(b) }
}

fileprivate func crc32(_ bytes: [UInt8]) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        table[i] = c
    }
    var crc: UInt32 = 0xFFFF_FFFF
    for x in bytes { crc = table[Int((crc ^ UInt32(x)) & 0xFF)] ^ (crc >> 8) }
    return crc ^ 0xFFFF_FFFF
}

/// A stored (uncompressed) zip with a correct central directory.
fileprivate func makeZip(_ files: [(String, [UInt8])]) -> Data {
    var out = Bytes()
    var central = Bytes()
    for (name, data) in files {
        let offset = out.b.count
        let crc = Int(crc32(data))
        out.le32(0x0403_4B50); out.le16(20); out.le16(0); out.le16(0); out.le16(0); out.le16(0x21)
        out.le32(crc); out.le32(data.count); out.le32(data.count); out.le16(name.utf8.count); out.le16(0)
        out.ascii(name); out.bytes(data)
        central.le32(0x0201_4B50); central.le16(20); central.le16(20); central.le16(0); central.le16(0); central.le16(0)
        central.le16(0x21); central.le32(crc); central.le32(data.count); central.le32(data.count)
        central.le16(name.utf8.count); central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(0)
        central.le32(offset); central.ascii(name)
    }
    let cdOffset = out.b.count
    out.bytes(central.b)
    out.le32(0x0605_4B50); out.le16(0); out.le16(0); out.le16(files.count); out.le16(files.count)
    out.le32(central.b.count); out.le32(cdOffset); out.le16(0)
    return out.data
}

fileprivate func utf8(_ s: String) -> [UInt8] { Array(s.utf8) }

/// A tiny invented "PNG" used as a cover inside books and comics (only its signature matters there).
fileprivate let fakePNG: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 7, count: 24)
fileprivate let fakeJPEG: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 1, count: 20)

/// Every prefix length worth trying on a fixture: never crash, whatever is cut.
fileprivate func truncations(_ data: Data) -> [Data] {
    let n = data.count
    let cuts = Set([0, 1, 4, 8, 12, 16, 27, 33, 64, 100, n / 3, n / 2, n - 128, n - 22, n - 1].filter { $0 >= 0 && $0 < n })
    return cuts.sorted().map { data.prefix($0) }
}

/// Deterministic pseudo-random bytes.
fileprivate func noise(_ count: Int, seed: UInt64) -> Data {
    var x = seed
    return Data((0..<count).map { _ in
        x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: x >> 33)
    })
}

// MARK: - EPUB and comics

fileprivate func epub3(nested depth: Int = 5) -> Data {
    let container = """
    <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """
    let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>The Invented Lighthouse</dc:title>
        <dc:creator id="a1">Ada Example</dc:creator>
        <meta refines="#a1" property="role" scheme="marc:relators">aut</meta>
        <dc:creator id="t1">Bo Translator</dc:creator>
        <meta refines="#t1" property="role">trl</meta>
        <dc:language>en</dc:language>
        <dc:publisher>Nowhere Press</dc:publisher>
        <dc:date>2026-01-02</dc:date>
        <dc:identifier id="id">urn:uuid:00000000-1111-2222-3333-444444444444</dc:identifier>
        <dc:description>&lt;p&gt;A &lt;b&gt;short&lt;/b&gt; tale.&lt;/p&gt;</dc:description>
      </metadata>
      <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="cov" href="images/cover%20art.png" media-type="image/png" properties="cover-image"/>
        <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml" properties="scripted"/>
      </manifest>
      <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
    </package>
    """
    func level(_ d: Int) -> String {
        guard d <= depth else { return "" }
        return "<ol><li><a href=\"text/ch1.xhtml#l\(d)\">Level&nbsp;\(d)</a>\(level(d + 1))</li><li><span>Part \(d)b</span></li></ol>"
    }
    let nav = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
    <nav epub:type="landmarks"><ol><li><a href="x">Not this</a></li></ol></nav>
    <nav epub:type="toc"><h1>Contents</h1>\(level(1))</nav></body></html>
    """
    return makeZip([("mimetype", utf8("application/epub+zip")), ("META-INF/container.xml", utf8(container)),
                    ("OEBPS/content.opf", utf8(opf)), ("OEBPS/nav.xhtml", utf8(nav)),
                    ("OEBPS/images/cover art.png", fakePNG), ("OEBPS/text/ch1.xhtml", utf8("<html/>")),
                    ("OEBPS/text/ch2.xhtml", utf8("<html/>"))])
}

fileprivate func epub2Protected() -> Data {
    let container = """
    <container><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """
    let opf = """
    <package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>Old Format</dc:title><dc:creator opf:role="aut">Cy Writer</dc:creator><meta name="cover" content="cimg"/></metadata>
    <manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="cimg" href="c.jpg" media-type="image/jpeg"/>
    <item id="p1" href="p1.html" media-type="application/xhtml+xml"/></manifest><spine toc="ncx"><itemref idref="p1"/></spine></package>
    """
    let ncx = """
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
    <navPoint id="a"><navLabel><text>Chapter One</text></navLabel><content src="p1.html"/>
      <navPoint id="b"><navLabel><text>Section 1.1</text></navLabel><content src="p1.html#s"/></navPoint></navPoint>
    <navPoint id="c"><navLabel><text>Chapter Two</text></navLabel><content src="p1.html#2"/></navPoint></navMap></ncx>
    """
    let encryption = """
    <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
    <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></enc:EncryptedData></encryption>
    """
    return makeZip([("mimetype", utf8("application/epub+zip")), ("META-INF/container.xml", utf8(container)),
                    ("META-INF/encryption.xml", utf8(encryption)), ("book.opf", utf8(opf)), ("toc.ncx", utf8(ncx)),
                    ("c.jpg", fakeJPEG), ("p1.html", utf8("<html/>"))])
}

fileprivate func cbz() -> Data {
    let info = """
    <?xml version="1.0"?><ComicInfo><Series>Invented Heroes</Series><Number>7</Number><Title>The Test</Title>
    <Writer>Dee Author</Writer><Penciller>Eve Artist</Penciller><Year>2025</Year></ComicInfo>
    """
    return makeZip([("pages/page10.png", fakePNG + [10]), ("pages/page2.png", fakePNG + [2]),
                    ("pages/page1.jpg", fakeJPEG), ("__MACOSX/pages/._page1.jpg", [0, 1, 2]),
                    ("pages/.hidden.png", fakePNG), ("ComicInfo.xml", utf8(info))])
}

@Suite struct MediaBookTests {
    @Test func epub3MetadataCoverAndNav() throws {
        guard case .book(let s) = MediaReader.read(data: epub3(), fileName: "lighthouse.epub") else { Issue.record("not a book"); return }
        #expect(s.title == "The Invented Lighthouse")
        #expect(s.headline == "The Invented Lighthouse")
        #expect(s.creators == [MediaBookCreator(name: "Ada Example", role: "aut"), MediaBookCreator(name: "Bo Translator", role: "trl")])
        #expect(s.language == "en")
        #expect(s.publisher == "Nowhere Press")
        #expect(s.date == "2026-01-02")
        #expect(s.identifiers == ["urn:uuid:00000000-1111-2222-3333-444444444444"])
        #expect(s.description == "A short tale.")
        #expect(s.epubVersion == "3.0")
        #expect(s.spineLength == 2)
        #expect(s.cover?.data == Data(fakePNG))
        #expect(s.cover?.mimeType == "image/png")
        #expect(s.tableOfContentsSource == "nav")
        // Depth is capped at 4: levels 1–4 and their siblings, never level 5.
        #expect(s.tableOfContents.first == MediaTOCEntry(title: "Level 1", depth: 1, target: "OEBPS/text/ch1.xhtml"))
        #expect(s.tableOfContents.map(\.depth).max() == 4)
        #expect(!s.tableOfContents.contains { $0.title == "Level 5" })
        #expect(!s.tableOfContents.contains { $0.title == "Not this" })
        #expect(s.truncated)
        #expect(!s.isProtected)
        #expect(s.warnings.contains { $0.level == .caution && $0.reason.contains("scripts") })
    }

    @Test func epub2NCXCoverAndDRM() throws {
        guard case .book(let s) = MediaReader.read(data: epub2Protected(), fileName: "old.epub") else { Issue.record("not a book"); return }
        #expect(s.title == "Old Format")
        #expect(s.creators.first?.role == "aut")
        #expect(s.cover?.data == Data(fakeJPEG))
        #expect(s.tableOfContentsSource == "ncx")
        #expect(s.tableOfContents.map(\.title) == ["Chapter One", "Section 1.1", "Chapter Two"])
        #expect(s.tableOfContents.map(\.depth) == [1, 2, 1])
        #expect(s.isProtected)
        #expect(s.warnings.contains { $0.level == .caution && $0.reason.contains("DRM") })
    }

    @Test func epubMalformedAndTruncated() {
        let noContainer = makeZip([("mimetype", utf8("application/epub+zip")), ("x.html", utf8("<p/>"))])
        guard case .book(let s) = MediaReader.read(data: noContainer, fileName: "bad.epub") else { Issue.record("no summary"); return }
        #expect(s.warnings.contains { $0.level == .danger })
        #expect(MediaReader.read(data: Data("not a zip".utf8), fileName: "bad.epub") == nil)
        for cut in truncations(epub3()) { _ = MediaReader.read(data: cut, fileName: "cut.epub") }
    }

    @Test func cbzPagesCoverAndComicInfo() {
        guard case .comic(let s) = MediaReader.read(data: cbz(), fileName: "heroes.cbz") else { Issue.record("not a comic"); return }
        #expect(s.container == "ZIP")
        #expect(s.pageCount == 3)
        #expect(s.pages == ["pages/page1.jpg", "pages/page2.png", "pages/page10.png"])
        #expect(s.cover?.data == Data(fakeJPEG))
        #expect(s.cover?.mimeType == "image/jpeg")
        #expect(s.series == "Invented Heroes")
        #expect(s.number == "7")
        #expect(s.writer == "Dee Author")
        #expect(s.artist == "Eve Artist")
        #expect(s.headline == "Invented Heroes #7 — The Test")
    }

    @Test func cbrNamedZipEmptyAndGarbage() {
        guard case .comic(let s) = MediaReader.read(data: cbz(), fileName: "really-a-zip.cbr") else { Issue.record("not a comic"); return }
        #expect(s.container == "ZIP")
        #expect(s.pageCount == 3)
        guard case .comic(let empty) = MediaReader.read(data: makeZip([("readme.txt", utf8("hi"))]), fileName: "e.cbz") else { Issue.record("no summary"); return }
        #expect(empty.pageCount == 0)
        #expect(empty.warnings.contains { $0.level == .danger })
        #expect(MediaReader.read(data: noise(4096, seed: 3), fileName: "junk.cbr") == nil)
        for cut in truncations(cbz()) { _ = MediaReader.read(data: cut, fileName: "cut.cbz") }
    }
}

// MARK: - Maps

fileprivate func gpx(points: Int = 11, cutAt: Int? = nil) -> Data {
    var trk = ""
    for i in 0..<points {
        let ele = [100.0, 110, 105, 120][i % 4]
        let t = String(format: "2026-05-01T10:%02d:%02dZ", (i * 10) / 60, (i * 10) % 60)
        trk += "<trkpt lat=\"0\" lon=\"\(Double(i) * 0.001)\"><ele>\(ele)</ele><time>\(t)</time></trkpt>"
        if i == points / 2 { trk += "</trkseg><trkseg>" }
    }
    var text = """
    <?xml version="1.0"?><gpx version="1.1" creator="Invented Logger" xmlns="http://www.topografix.com/GPX/1/1">
    <metadata><name>Morning Test Walk</name></metadata>
    <wpt lat="1.5" lon="2.5"><name>Camp</name></wpt>
    <rte><name>Plan</name><rtept lat="0" lon="0"/><rtept lat="0" lon="0.01"/></rte>
    <trk><name>Walk</name><trkseg>\(trk)</trkseg></trk></gpx>
    """
    if let cutAt { text = String(text.prefix(cutAt)) }
    return Data(text.utf8)
}

@Suite struct MediaMapTests {
    @Test func geoJSONCountsBoundsKeysAndSimplification() {
        let line = (0..<1000).map { i in "[\(Double(i) * 0.01), \(sin(Double(i) / 30))]" }.joined(separator: ",")
        let json = """
        {"type":"FeatureCollection","features":[
         {"type":"Feature","properties":{"name":"Peak","ele":1200},"geometry":{"type":"Point","coordinates":[10.5,45.25,1200]}},
         {"type":"Feature","properties":{"name":"Wiggle","kind":"line"},"geometry":{"type":"LineString","coordinates":[\(line)]}},
         {"type":"Feature","properties":{"name":"Field"},"geometry":{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,1],[0,0]]]}},
         {"type":"Feature","properties":null,"geometry":null}]}
        """
        guard case .map(let s) = MediaReader.read(data: Data(json.utf8), fileName: "places.geojson") else { Issue.record("not a map"); return }
        #expect(s.format == "GeoJSON")
        #expect(s.featureCount == 4)
        #expect(s.geometryCounts.contains(MediaCount("Point", 1)))
        #expect(s.geometryCounts.contains(MediaCount("LineString", 1)))
        #expect(s.geometryCounts.contains(MediaCount("Polygon", 1)))
        #expect(s.propertyKeys.first == "name")
        #expect(Set(s.propertyKeys) == ["name", "ele", "kind"])
        #expect(s.bounds?.minLongitude == 0)
        #expect(abs((s.bounds?.maxLongitude ?? 0) - 10.5) < 1e-9)
        #expect(s.points.count == 1)
        let wiggle = s.lines.first { $0.name == "Wiggle" }
        #expect(wiggle?.originalPointCount == 1000)
        #expect((wiggle?.points.count ?? 999) <= 500)
        #expect(wiggle?.points.first?.longitude == 0)
        #expect(abs((wiggle?.points.last?.longitude ?? 0) - 9.99) < 1e-9)
        #expect(s.lines.contains { $0.kind == .polygon })
    }

    @Test func geoJSONMalformed() {
        guard case .map(let bad) = MediaReader.read(data: Data("{not json".utf8), fileName: "x.geojson") else { Issue.record("no summary"); return }
        #expect(bad.warnings.first?.level == .danger)
        guard case .map(let other) = MediaReader.read(data: Data("{\"type\":\"Banana\"}".utf8), fileName: "x.geojson") else { Issue.record("no summary"); return }
        #expect(other.warnings.first?.level == .danger)
        let deep = String(repeating: "{\"type\":\"GeometryCollection\",\"geometries\":[", count: 40) + String(repeating: "]}", count: 40)
        _ = MediaReader.read(data: Data(deep.utf8), fileName: "deep.geojson")
    }

    @Test func gpxDistanceElevationTimeAndProfile() throws {
        guard case .map(let s) = MediaReader.read(data: gpx(), fileName: "walk.gpx") else { Issue.record("not a map"); return }
        #expect(s.format == "GPX")
        #expect(s.headline == "Morning Test Walk")
        let t = try #require(s.tracks.first)
        #expect(t.name == "Walk")
        #expect(t.segmentCount == 2)
        #expect(t.pointCount == 11)
        // Ten steps of 0.001° on the equator, minus the one step that crosses the segment break.
        #expect(abs(t.distanceMeters - 9 * 111.19508) < 0.05)
        #expect(t.minElevation == 100)
        #expect(t.maxElevation == 120)
        #expect(t.startTime == MediaISODate.parse("2026-05-01T10:00:00Z"))
        #expect(t.endTime == MediaISODate.parse("2026-05-01T10:01:40Z"))
        #expect(t.movingSeconds == 90)
        #expect((t.elevationGain ?? 0) > 0 && (t.elevationLoss ?? 0) > 0)
        #expect(s.waypoints == [MediaWaypoint(name: "Camp", coordinate: MediaCoordinate(latitude: 1.5, longitude: 2.5))])
        #expect(s.routes.first?.name == "Plan")
        #expect(abs((s.routes.first?.distanceMeters ?? 0) - 1111.95) < 0.1)
        #expect(s.lines.filter { $0.kind == .track }.count == 2)
        #expect(s.elevationProfile.count == 11)

        guard case .map(let long) = MediaReader.read(data: gpx(points: 2000), fileName: "long.gpx") else { return }
        #expect(long.elevationProfile.count == 300)
        #expect(long.lines.allSatisfy { $0.points.count <= 500 })
    }

    @Test func gpxDamagedAndNotGPX() {
        let cut = gpx(cutAt: 700)
        guard case .map(let s) = MediaReader.read(data: cut, fileName: "cut.gpx") else { Issue.record("no summary"); return }
        #expect(s.warnings.contains { $0.level == .danger })
        guard case .map(let other) = MediaReader.read(data: Data("<html/>".utf8), fileName: "x.gpx") else { Issue.record("no summary"); return }
        #expect(other.warnings.first?.level == .danger)
        for c in truncations(gpx()) { _ = MediaReader.read(data: c, fileName: "t.gpx") }
    }

    @Test func kmlAndKMZ() {
        let kml = """
        <?xml version="1.0"?><kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2"><Document><name>Invented Trip</name>
        <Folder><name>Stops</name><Placemark><name>A</name><Point><coordinates>4.5,50.25,0</coordinates></Point></Placemark></Folder>
        <Folder><name>Ways</name>
        <Placemark><name>Road</name><LineString><coordinates>4,50 4.1,50.1 4.2,50.3</coordinates></LineString></Placemark>
        <Placemark><name>Park</name><Polygon><outerBoundaryIs><LinearRing><coordinates>4,50 4.01,50 4.01,50.01 4,50</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>
        <Placemark><gx:Track><when>2026-01-01T00:00:00Z</when><gx:coord>4 50 10</gx:coord><gx:coord>4.3 50.2 12</gx:coord></gx:Track></Placemark>
        </Folder></Document></kml>
        """
        guard case .map(let s) = MediaReader.read(data: Data(kml.utf8), fileName: "trip.kml") else { Issue.record("not a map"); return }
        #expect(s.headline == "Invented Trip")
        #expect(s.featureCount == 4)
        #expect(s.folderCount == 2)
        #expect(s.folderNames == ["Stops", "Ways"])
        #expect(s.geometryCounts.contains(MediaCount("Point", 1)))
        #expect(s.geometryCounts.contains(MediaCount("LineString", 1)))
        #expect(s.geometryCounts.contains(MediaCount("Polygon", 1)))
        #expect(s.geometryCounts.contains(MediaCount("Track", 1)))
        #expect(s.lines.count == 3)
        #expect(s.points == [MediaCoordinate(latitude: 50.25, longitude: 4.5, elevation: 0)])
        #expect(s.bounds?.maxLatitude == 50.3)

        guard case .map(let z) = MediaReader.read(data: makeZip([("doc.kml", utf8(kml)), ("files/icon.png", fakePNG)]), fileName: "trip.kmz") else { Issue.record("not a map"); return }
        #expect(z.format == "KMZ")
        #expect(z.featureCount == 4)
        guard case .map(let empty) = MediaReader.read(data: makeZip([("readme.txt", utf8("x"))]), fileName: "e.kmz") else { Issue.record("no summary"); return }
        #expect(empty.warnings.first?.level == .danger)
        #expect(MediaReader.read(data: noise(512, seed: 9), fileName: "junk.kmz") == nil)
        for c in truncations(Data(kml.utf8)) { _ = MediaReader.read(data: c, fileName: "t.kml") }
    }

    @Test func douglasPeuckerKeepsTheSpike() {
        var pts = (0..<101).map { MediaCoordinate(latitude: 0, longitude: Double($0) * 0.001) }
        pts[50].latitude = 0.05
        let out = MediaMapReader.simplify(pts, maxPoints: 3)
        #expect(out.count == 3)
        #expect(out[1].latitude == 0.05)
        #expect(MediaMapReader.simplify(Array(pts.prefix(2)), maxPoints: 500).count == 2)
    }
}

// MARK: - 3D

fileprivate let cubeTriangles: [[Float]] = {
    let v: [[Float]] = [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0], [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]]
    let faces = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]]
    return faces.map { f in f.flatMap { v[$0] } }
}()

fileprivate func binarySTL(_ tris: [[Float]], declared: Int? = nil) -> Data {
    var b = Bytes()
    b.bytes(Array("binary invented cube".utf8) + [UInt8](repeating: 0, count: 60))
    b.le32(declared ?? tris.count)
    for t in tris {
        for _ in 0..<3 { b.f32(0) }
        for x in t { b.f32(x) }
        b.le16(0)
    }
    return b.data
}

@Suite struct MediaModelTests {
    @Test func binarySTLCube() throws {
        guard case .model(let s) = MediaReader.read(data: binarySTL(cubeTriangles), fileName: "cube.stl") else { Issue.record("not a model"); return }
        #expect(s.format == "STL (binary)")
        #expect(s.triangleCount == 12)
        #expect(s.bounds?.size == MediaVector3(x: 1, y: 1, z: 1))
        #expect(abs((s.surfaceArea ?? 0) - 6) < 1e-9)
        #expect(abs((s.volume ?? 0) - 1) < 1e-9)
        #expect(s.isClosed == true)
        #expect(s.openEdgeCount == 0)
        #expect(s.mesh?.triangleCount == 12)
        #expect(s.warnings.isEmpty)
    }

    @Test func binarySTLTruncatedAndDecimated() {
        let cut = binarySTL(Array(cubeTriangles.prefix(5)), declared: 12)
        guard case .model(let s) = MediaReader.read(data: cut, fileName: "cut.stl") else { Issue.record("no summary"); return }
        #expect(s.triangleCount == 5)
        #expect(s.truncated)
        #expect(s.warnings.contains { $0.level == .danger })
        #expect(s.isClosed == false)

        let many = (0..<50_000).map { i -> [Float] in let x = Float(i); return [x, 0, 0, x + 1, 0, 0, x, 1, 0] }
        guard case .model(let big) = MediaReader.read(data: binarySTL(many), fileName: "big.stl") else { Issue.record("no summary"); return }
        #expect(big.triangleCount == 50_000)
        #expect((big.mesh?.triangleCount ?? 0) <= 20_000)
        #expect((big.mesh?.triangleCount ?? 0) >= 10_000)
        #expect(big.mesh?.sourceTriangleCount == 50_000)

        guard case .model(let tiny) = MediaReader.read(data: Data([1, 2, 3]), fileName: "tiny.stl") else { Issue.record("no summary"); return }
        #expect(tiny.warnings.first?.level == .danger)
        for c in truncations(binarySTL(cubeTriangles)) { _ = MediaReader.read(data: c, fileName: "t.stl") }
    }

    @Test func asciiSTLOpenMesh() {
        // A tetrahedron with one face missing: three triangles, three open edges.
        let text = """
        solid invented_tetra
          facet normal 0 0 0
            outer loop
              vertex 0 0 0
              vertex 1 0 0
              vertex 0 1 0
            endloop
          endfacet
          facet normal 0 0 0
            outer loop
              vertex 0 0 0
              vertex 0 1 0
              vertex 0 0 1.5e0
            endloop
          endfacet
          facet normal 0 0 0
            outer loop
              vertex 0 0 0
              vertex 0 0 1.5
              vertex 1 0 0
            endloop
          endfacet
          facet normal 0 0 0
            outer loop
              vertex 1 0 0
              vertex oops 1 0
              vertex 0 0 1.5
            endloop
          endfacet
        endsolid invented_tetra
        """
        guard case .model(let s) = MediaReader.read(data: Data(text.utf8), fileName: "tetra.stl") else { Issue.record("not a model"); return }
        #expect(s.format == "STL (ASCII)")
        #expect(s.headline == "invented_tetra")
        #expect(s.triangleCount == 3)
        #expect(s.isClosed == false)
        #expect(s.openEdgeCount == 3)
        #expect(s.bounds?.max.z == 1.5)
        #expect(s.warnings.contains { $0.level == .caution })
        #expect(s.warnings.contains { $0.level == .danger })
    }

    @Test func objCubeWithGroupsAndMaterials() {
        let obj = """
        # invented cube
        mtllib cube.mtl
        o Cube
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        v 0 0 1
        v 1 0 1
        v 1 1 1
        v 0 1 1
        vn 0 0 1
        vt 0 0
        g bottom
        usemtl Red
        f 1 4 3 2
        g top sides
        usemtl Blue
        f 5/1/1 6/1/1 7/1/1 8/1/1
        f 1 2 6 5
        f 2 3 7 6
        f -5 -1 -2 -6
        f 4 1 5 8
        f 1 2 99
        """
        guard case .model(let s) = MediaReader.read(data: Data(obj.utf8), fileName: "cube.obj") else { Issue.record("not a model"); return }
        #expect(s.vertexCount == 8)
        #expect(s.faceCount == 7)
        #expect(s.triangleCount == 12)
        #expect(s.isClosed == true)
        #expect(abs((s.volume ?? 0) - 1) < 1e-6)
        #expect(s.groups == ["bottom", "top", "sides"])
        #expect(s.objects == ["Cube"])
        #expect(s.materials == ["Red", "Blue"])
        #expect(s.materialLibraries == ["cube.mtl"])
        #expect(s.warnings.contains { $0.level == .danger })
        #expect(s.warnings.contains { $0.level == .caution })
        for c in truncations(Data(obj.utf8)) { _ = MediaReader.read(data: c, fileName: "t.obj") }
        _ = MediaReader.read(data: noise(10_000, seed: 5), fileName: "n.obj")
    }

    @Test func threeMFPackage() {
        var verts = ""
        for v in [[0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0], [0, 0, 10], [10, 0, 10], [10, 10, 10], [0, 10, 10]] {
            verts += "<vertex x=\"\(v[0])\" y=\"\(v[1])\" z=\"\(v[2])\"/>"
        }
        let faces = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]]
        let tris = faces.map { "<triangle v1=\"\($0[0])\" v2=\"\($0[1])\" v3=\"\($0[2])\"/>" }.joined()
        let model = """
        <?xml version="1.0" encoding="UTF-8"?><model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        <metadata name="Title">Invented Box</metadata><metadata name="Designer">Fay Maker</metadata>
        <resources><object id="1" type="model" name="Box"><mesh><vertices>\(verts)</vertices><triangles>\(tris)<triangle v1="0" v2="1" v3="42"/></triangles></mesh></object></resources>
        <build><item objectid="1"/></build></model>
        """
        let rels = """
        <?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Target="/3D/box.model" Id="r0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
        """
        let data = makeZip([("[Content_Types].xml", utf8("<Types/>")), ("_rels/.rels", utf8(rels)), ("3D/box.model", utf8(model))])
        guard case .model(let s) = MediaReader.read(data: data, fileName: "box.3mf") else { Issue.record("not a model"); return }
        #expect(s.format == "3MF")
        #expect(s.headline == "Invented Box")
        #expect(s.designer == "Fay Maker")
        #expect(s.units == "millimeter")
        #expect(s.triangleCount == 12)
        #expect(s.vertexCount == 8)
        #expect(s.objectCount == 1)
        #expect(s.objects == ["Box"])
        #expect(s.buildItemCount == 1)
        #expect(s.isClosed == true)
        #expect(abs((s.volume ?? 0) - 1000) < 1e-6)
        #expect(s.warnings.contains { $0.level == .danger })                // the triangle pointing at vertex 42

        guard case .model(let missing) = MediaReader.read(data: makeZip([("x.txt", utf8("x"))]), fileName: "e.3mf") else { Issue.record("no summary"); return }
        #expect(missing.warnings.first?.level == .danger)
        for c in truncations(data) { _ = MediaReader.read(data: c, fileName: "t.3mf") }
    }

    fileprivate static let gltfJSON = """
    {"asset":{"version":"2.0","generator":"Invented Exporter 1.0"},"scene":0,"scenes":[{"nodes":[0,1]}],
     "nodes":[{"mesh":0},{"mesh":1}],
     "meshes":[{"name":"Body","primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]},
               {"name":"Strip","primitives":[{"attributes":{"POSITION":2},"mode":5},{"attributes":{"POSITION":2},"mode":1}]}],
     "accessors":[{"count":24,"min":[-1,-2,-3],"max":[1,2,3],"type":"VEC3","componentType":5126},
                  {"count":36,"type":"SCALAR","componentType":5123},
                  {"count":10,"min":[0,0,0],"max":[5,1,1],"type":"VEC3","componentType":5126}],
     "materials":[{"name":"Steel"}],"textures":[{"source":0}],"images":[{"uri":"steel.png"}],
     "buffers":[{"byteLength":1000,"uri":"body.bin"}],"animations":[{}],"skins":[],
     "extensionsUsed":["KHR_materials_unlit"],"extensionsRequired":[]}
    """

    @Test func gltfCounts() throws {
        guard case .model(let s) = MediaReader.read(data: Data(Self.gltfJSON.utf8), fileName: "thing.gltf") else { Issue.record("not a model"); return }
        let g = try #require(s.gltf)
        #expect(s.format == "glTF")
        #expect(g.generator == "Invented Exporter 1.0")
        #expect(g.version == "2.0")
        #expect(g.sceneCount == 1)
        #expect(g.nodeCount == 2)
        #expect(g.meshCount == 2)
        #expect(g.primitiveCount == 3)
        #expect(g.materialCount == 1)
        #expect(g.textureCount == 1)
        #expect(g.animationCount == 1)
        #expect(g.extensionsUsed == ["KHR_materials_unlit"])
        #expect(g.externalResources == ["body.bin", "steel.png"])
        #expect(s.triangleCount == 12 + 8)
        #expect(s.bounds == MediaBox3(min: MediaVector3(x: -1, y: -2, z: -3), max: MediaVector3(x: 5, y: 2, z: 3)))
        #expect(s.materials == ["Steel"])
        #expect(s.warnings.contains { $0.level == .caution })
    }

    @Test func glbContainerTruncationAndDamage() throws {
        func glb(_ json: String, declaredExtra: Int = 0) -> Data {
            var j = Array(json.utf8)
            while j.count % 4 != 0 { j.append(0x20) }
            let bin = [UInt8](repeating: 0, count: 16)
            var b = Bytes()
            b.ascii("glTF"); b.le32(2); b.le32(12 + 8 + j.count + 8 + bin.count + declaredExtra)
            b.le32(j.count); b.le32(0x4E4F_534A); b.bytes(j)
            b.le32(bin.count); b.le32(0x004E_4942); b.bytes(bin)
            return b.data
        }
        let json = #"{"asset":{"version":"2.0"},"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"accessors":[{"count":9}],"buffers":[{"byteLength":16}]}"#
        guard case .model(let s) = MediaReader.read(data: glb(json), fileName: "a.glb") else { Issue.record("not a model"); return }
        #expect(s.format == "GLB")
        #expect(s.triangleCount == 3)
        #expect(s.gltf?.binaryChunkBytes == 16)
        #expect(s.gltf?.externalResources == [])
        #expect(s.warnings.isEmpty)

        guard case .model(let cut) = MediaReader.read(data: glb(json, declaredExtra: 100), fileName: "c.glb") else { Issue.record("no summary"); return }
        #expect(cut.warnings.contains { $0.level == .danger })
        guard case .model(let bad) = MediaReader.read(data: Data("{oops".utf8), fileName: "b.gltf") else { Issue.record("no summary"); return }
        #expect(bad.warnings.first?.level == .danger)
        guard case .model(let old) = MediaReader.read(data: Data(#"{"asset":{"version":"1.0"}}"#.utf8), fileName: "o.gltf") else { return }
        #expect(old.warnings.contains { $0.level == .danger })
        for c in truncations(glb(json)) { _ = MediaReader.read(data: c, fileName: "t.glb") }
    }
}

// MARK: - Audio

fileprivate func id3Frame(_ id: String, _ body: [UInt8], v4: Bool = false) -> [UInt8] {
    var b = Bytes()
    b.ascii(id)
    if v4 { b.bytes([UInt8((body.count >> 21) & 0x7F), UInt8((body.count >> 14) & 0x7F), UInt8((body.count >> 7) & 0x7F), UInt8(body.count & 0x7F)]) }
    else { b.be32(body.count) }
    b.be16(0)
    b.bytes(body)
    return b.b
}

fileprivate func id3Tag(major: UInt8, _ frames: [UInt8], declaredExtra: Int = 0) -> [UInt8] {
    let size = frames.count + declaredExtra
    return Array("ID3".utf8) + [major, 0, 0, UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)] + frames
}

/// Two MPEG-1 Layer III frames: 128 kbps, 44.1 kHz, joint stereo, 417 bytes each.
fileprivate let mpegFrames: [UInt8] = {
    let frame = [0xFF, 0xFB, 0x90, 0x64] + [UInt8](repeating: 0, count: 413)
    return frame + frame
}()

fileprivate func id3v1(title: String, track: UInt8, genre: UInt8) -> [UInt8] {
    func field(_ s: String, _ n: Int) -> [UInt8] { Array(Array(s.utf8).prefix(n)) + [UInt8](repeating: 0, count: max(0, n - s.utf8.count)) }
    return Array("TAG".utf8) + field(title, 30) + field("V1 Artist", 30) + field("V1 Album", 30) + field("1999", 4)
        + field("v1 comment", 28) + [0, track, genre]
}

fileprivate func atom(_ type: [UInt8], _ body: [UInt8]) -> [UInt8] {
    var b = Bytes()
    b.be32(8 + body.count)
    b.bytes(type)
    b.bytes(body)
    return b.b
}
fileprivate func atom(_ type: String, _ body: [UInt8]) -> [UInt8] { atom(Array(type.utf8), body) }
fileprivate func ilstItem(_ key: [UInt8], type: Int, _ payload: [UInt8]) -> [UInt8] {
    var d = Bytes()
    d.be32(type); d.be32(0); d.bytes(payload)
    return atom(key, atom("data", d.b))
}

fileprivate func vorbisComment(_ entries: [String], extra: [[UInt8]] = []) -> [UInt8] {
    var b = Bytes()
    b.le32(8); b.ascii("Invented")
    b.le32(entries.count + extra.count)
    for e in entries { b.le32(e.utf8.count); b.ascii(e) }
    for e in extra { b.le32(e.count); b.bytes(e) }
    return b.b
}

fileprivate func flacPicture(_ data: [UInt8], type: Int = 3) -> [UInt8] {
    var b = Bytes()
    b.be32(type); b.be32(9); b.ascii("image/png"); b.be32(5); b.ascii("front")
    b.be32(1); b.be32(1); b.be32(24); b.be32(0); b.be32(data.count); b.bytes(data)
    return b.b
}

fileprivate func oggPage(serial: Int, seq: Int, granule: UInt64, type: UInt8, packets: [[UInt8]]) -> [UInt8] {
    var lacing: [UInt8] = []
    var body: [UInt8] = []
    for p in packets {
        var n = p.count
        while n >= 255 { lacing.append(255); n -= 255 }
        lacing.append(UInt8(n))
        body += p
    }
    var b = Bytes()
    b.ascii("OggS"); b.u8(0); b.u8(type); b.le64(granule); b.le32(serial); b.le32(seq); b.le32(0)
    b.u8(UInt8(lacing.count)); b.bytes(lacing); b.bytes(body)
    return b.b
}

@Suite struct MediaAudioTests {
    @Test func mp3ID3v23WithCoverAndV1() throws {
        var frames: [UInt8] = []
        frames += id3Frame("TIT2", [0] + utf8("Invented Song"))
        frames += id3Frame("TPE1", [1, 0xFF, 0xFE] + Array("Ann".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
        frames += id3Frame("TALB", [0] + utf8("Test Album"))
        frames += id3Frame("TRCK", [0] + utf8("3/12"))
        frames += id3Frame("TCON", [0] + utf8("(17)"))
        frames += id3Frame("COMM", [0] + utf8("eng") + [0] + utf8("Nice one"))
        frames += id3Frame("COMM", [0] + utf8("eng") + utf8("iTunNORM") + [0] + utf8(" 0000"))
        frames += id3Frame("USLT", [0] + utf8("eng") + [0] + utf8("la la"))
        frames += id3Frame("APIC", [0] + utf8("image/jpeg") + [0, 4] + [0] + fakeJPEG)        // back cover
        frames += id3Frame("APIC", [0] + utf8("image/png") + [0, 3] + utf8("Cover") + [0] + fakePNG)
        let file = Data(id3Tag(major: 3, frames + [0, 0, 0, 0]) + mpegFrames + id3v1(title: "Ignored", track: 9, genre: 0))
        guard case .audio(let s) = MediaReader.read(data: file, fileName: "song.mp3") else { Issue.record("not audio"); return }
        #expect(s.format == "MP3")
        #expect(s.tagFormats == ["ID3v2.3", "ID3v1"])
        #expect(s.tags.title == "Invented Song")
        #expect(s.tags.artist == "Ann")
        #expect(s.tags.album == "Test Album")
        #expect(s.tags.track == 3)
        #expect(s.tags.trackTotal == 12)
        #expect(s.tags.genre == "Rock")
        #expect(s.tags.comment == "Nice one")
        #expect(s.tags.year == "1999")                                      // only ID3v1 has it
        #expect(s.tags.hasLyrics)
        #expect(s.cover?.data == Data(fakePNG))
        #expect(s.cover?.pictureType == "Front cover")
        #expect(s.cover?.description == "Cover")
        #expect(s.stream.codec == "MP3")
        #expect(s.stream.sampleRate == 44_100)
        #expect(s.stream.channels == 2)
        #expect(s.stream.bitrate == 128_000)
        #expect(s.headline == "Invented Song — Ann")
    }

    @Test func id3v24AndV22() {
        let v4 = id3Frame("TIT2", [3] + utf8("Ünïcode"), v4: true) + id3Frame("TDRC", [3] + utf8("2026"), v4: true)
            + id3Frame("TPE2", [3] + utf8("Band") + [0] + utf8("Guest"), v4: true)
        guard case .audio(let a) = MediaReader.read(data: Data(id3Tag(major: 4, v4) + mpegFrames), fileName: "a.mp3") else { Issue.record("not audio"); return }
        #expect(a.tagFormats.first == "ID3v2.4")
        #expect(a.tags.title == "Ünïcode")
        #expect(a.tags.year == "2026")
        #expect(a.tags.albumArtist == "Band; Guest")

        var v2: [UInt8] = []
        for (id, body) in [("TT2", [0] + utf8("Old Title")), ("TP1", [0] + utf8("Old Artist")), ("PIC", [0] + utf8("PNG") + [3, 0] + fakePNG)] {
            var b = Bytes(); b.ascii(id); b.be24(body.count); b.bytes(body); v2 += b.b
        }
        guard case .audio(let b) = MediaReader.read(data: Data(id3Tag(major: 2, v2) + mpegFrames), fileName: "b.mp3") else { Issue.record("not audio"); return }
        #expect(b.tagFormats.first == "ID3v2.2")
        #expect(b.tags.title == "Old Title")
        #expect(b.cover?.mimeType == "image/png")
    }

    @Test func mp3TruncatedAndNoFrames() {
        let tag = id3Tag(major: 3, id3Frame("TIT2", [0] + utf8("Cut")), declaredExtra: 500)
        guard case .audio(let s) = MediaReader.read(data: Data(tag), fileName: "cut.mp3") else { Issue.record("no summary"); return }
        #expect(s.tags.title == "Cut")
        #expect(s.warnings.contains { $0.level == .danger })
        #expect(s.truncated)
        let file = Data(id3Tag(major: 3, id3Frame("TIT2", [0] + utf8("T"))) + mpegFrames)
        for c in truncations(file) { _ = MediaReader.read(data: c, fileName: "t.mp3") }
        _ = MediaReader.read(data: noise(5000, seed: 11), fileName: "n.mp3")
    }

    @Test func mp4AtomsDurationCodecAndCover() throws {
        var mvhd = Bytes(); mvhd.be32(0); mvhd.be32(0); mvhd.be32(0); mvhd.be32(1000); mvhd.be32(185_000); mvhd.bytes([UInt8](repeating: 0, count: 80))
        var hdlr = Bytes(); hdlr.be32(0); hdlr.be32(0); hdlr.ascii("soun"); hdlr.bytes([UInt8](repeating: 0, count: 13))
        var entry = Bytes(); entry.bytes([0, 0, 0, 0, 0, 0]); entry.be16(1); entry.be16(0); entry.be16(0); entry.be32(0)
        entry.be16(2); entry.be16(16); entry.be16(0); entry.be16(0); entry.be32(44_100 << 16)
        var stsd = Bytes(); stsd.be32(0); stsd.be32(1); stsd.bytes(atom("mp4a", entry.b))
        let trak = atom("trak", atom("mdia", atom("hdlr", hdlr.b) + atom("minf", atom("stbl", atom("stsd", stsd.b)))))
        var metaHdlr = Bytes(); metaHdlr.be32(0); metaHdlr.be32(0); metaHdlr.ascii("mdir"); metaHdlr.bytes([UInt8](repeating: 0, count: 13))
        let ilst = atom("ilst", ilstItem([0xA9] + utf8("nam"), type: 1, utf8("Invented Track"))
            + ilstItem([0xA9] + utf8("ART"), type: 1, utf8("Mo Artist"))
            + ilstItem(utf8("trkn"), type: 0, [0, 0, 0, 2, 0, 10, 0, 0])
            + ilstItem(utf8("gnre"), type: 0, [0, 10])
            + ilstItem(utf8("covr"), type: 14, fakePNG))
        let meta = atom("meta", [0, 0, 0, 0] + atom("hdlr", metaHdlr.b) + ilst)
        var ftyp = Bytes(); ftyp.ascii("M4A "); ftyp.be32(0); ftyp.ascii("M4A isom")
        let file = Data(atom("ftyp", ftyp.b) + atom("moov", atom("mvhd", mvhd.b) + trak + atom("udta", meta)) + atom("mdat", [1, 2, 3]))
        guard case .audio(let s) = MediaReader.read(data: file, fileName: "track.m4a") else { Issue.record("not audio"); return }
        #expect(s.format == "MP4")
        #expect(s.tagFormats == ["iTunes"])
        #expect(s.stream.durationSeconds == 185)
        #expect(s.stream.codec == "AAC")
        #expect(s.stream.channels == 2)
        #expect(s.stream.sampleRate == 44_100)
        #expect(s.tags.title == "Invented Track")
        #expect(s.tags.artist == "Mo Artist")
        #expect(s.tags.track == 2)
        #expect(s.tags.trackTotal == 10)
        #expect(s.tags.genre == "Metal")
        #expect(s.cover?.mimeType == "image/png")
        #expect(s.cover?.data == Data(fakePNG))
        for c in truncations(file) { _ = MediaReader.read(data: c, fileName: "t.m4a") }
        guard case .audio(let bad) = MediaReader.read(data: Data(repeating: 0x41, count: 64), fileName: "bad.m4a") else { return }
        #expect(bad.warnings.first?.level == .danger)
    }

    @Test func flacStreamInfoCommentsAndPicture() throws {
        var info = Bytes()
        info.be16(4096); info.be16(4096); info.be24(0); info.be24(0)
        info.be64(UInt64(44_100) << 44 | UInt64(1) << 41 | UInt64(15) << 36 | UInt64(441_000))
        info.bytes([UInt8](repeating: 0, count: 16))
        let comments = vorbisComment(["TITLE=Invented FLAC", "ARTIST=Flo", "TRACKNUMBER=4", "TRACKTOTAL=9", "DATE=2024", "LYRICS=words"])
        let picture = flacPicture(fakePNG)
        var b = Bytes()
        b.ascii("fLaC")
        b.u8(0); b.be24(info.b.count); b.bytes(info.b)
        b.u8(4); b.be24(comments.count); b.bytes(comments)
        b.u8(0x80 | 6); b.be24(picture.count); b.bytes(picture)
        b.bytes([0xFF, 0xF8, 0, 0])
        guard case .audio(let s) = MediaReader.read(data: b.data, fileName: "x.flac") else { Issue.record("not audio"); return }
        #expect(s.format == "FLAC")
        #expect(s.stream.sampleRate == 44_100)
        #expect(s.stream.channels == 2)
        #expect(s.stream.bitsPerSample == 16)
        #expect(s.stream.durationSeconds == 10)
        #expect(s.tags.title == "Invented FLAC")
        #expect(s.tags.track == 4)
        #expect(s.tags.trackTotal == 9)
        #expect(s.tags.year == "2024")
        #expect(s.tags.hasLyrics)
        #expect(s.cover?.description == "front")
        #expect(s.tagFormats == ["Vorbis comments"])
        for c in truncations(b.data) { _ = MediaReader.read(data: c, fileName: "t.flac") }
        guard case .audio(let bad) = MediaReader.read(data: Data(id3Tag(major: 3, [])) + Data("nope".utf8), fileName: "b.flac") else { return }
        #expect(bad.warnings.first?.level == .danger)
    }

    @Test func oggVorbisAndOpus() throws {
        var ident = Bytes()
        ident.u8(1); ident.ascii("vorbis"); ident.le32(0); ident.u8(2); ident.le32(44_100); ident.le32(0); ident.le32(128_000); ident.le32(0); ident.u8(0xB8); ident.u8(1)
        let picture = Array(flacPicture(fakePNG))
        let pictureEntry = Array("METADATA_BLOCK_PICTURE=".utf8) + Array(Data(picture).base64EncodedString().utf8)
        let comment = [3] + utf8("vorbis") + vorbisComment(["TITLE=Invented Ogg", "ALBUMARTIST=Group"], extra: [pictureEntry]) + [1]
        let vorbis = oggPage(serial: 7, seq: 0, granule: 0, type: 2, packets: [ident.b])
            + oggPage(serial: 7, seq: 1, granule: 0, type: 0, packets: [comment])
            + oggPage(serial: 7, seq: 2, granule: 441_000, type: 4, packets: [[0, 0, 0]])
        guard case .audio(let s) = MediaReader.read(data: Data(vorbis), fileName: "x.ogg") else { Issue.record("not audio"); return }
        #expect(s.format == "Ogg Vorbis")
        #expect(s.stream.channels == 2)
        #expect(s.stream.sampleRate == 44_100)
        #expect(s.stream.durationSeconds == 10)
        #expect(s.stream.bitrate == 128_000)
        #expect(s.tags.title == "Invented Ogg")
        #expect(s.tags.albumArtist == "Group")
        #expect(s.cover?.data == Data(fakePNG))

        var head = Bytes()
        head.ascii("OpusHead"); head.u8(1); head.u8(2); head.le16(312); head.le32(48_000); head.le16(0); head.u8(0)
        let tags = utf8("OpusTags") + vorbisComment(["TITLE=Invented Opus"])
        let opus = oggPage(serial: 9, seq: 0, granule: 0, type: 2, packets: [head.b])
            + oggPage(serial: 9, seq: 1, granule: 0, type: 0, packets: [tags])
            + oggPage(serial: 9, seq: 2, granule: 48_000 * 5 + 312, type: 4, packets: [[0]])
        guard case .audio(let o) = MediaReader.read(data: Data(opus), fileName: "x.opus") else { Issue.record("not audio"); return }
        #expect(o.format == "Opus")
        #expect(o.stream.durationSeconds == 5)
        #expect(o.tags.title == "Invented Opus")
        for c in truncations(Data(vorbis)) { _ = MediaReader.read(data: c, fileName: "t.ogg") }
        guard case .audio(let bad) = MediaReader.read(data: Data("OggS".utf8) + noise(40, seed: 2), fileName: "b.ogg") else { return }
        #expect(!bad.warnings.isEmpty)
    }

    @Test func wavFormatInfoAndDuration() throws {
        func wav(dataBytes: Int, declared: Int? = nil) -> Data {
            var info = Bytes()
            info.ascii("INFO"); info.ascii("INAM"); info.le32(13); info.ascii("Invented Wav"); info.u8(0); info.u8(0)
            info.ascii("IART"); info.le32(4); info.ascii("Wes"); info.u8(0)
            var b = Bytes()
            b.ascii("RIFF"); b.le32(0); b.ascii("WAVE")
            b.ascii("fmt "); b.le32(16); b.le16(1); b.le16(2); b.le32(44_100); b.le32(176_400); b.le16(4); b.le16(16)
            b.ascii("LIST"); b.le32(info.b.count); b.bytes(info.b)
            b.ascii("data"); b.le32(declared ?? dataBytes); b.bytes([UInt8](repeating: 0, count: dataBytes))
            return b.data
        }
        guard case .audio(let s) = MediaReader.read(data: wav(dataBytes: 176_400), fileName: "x.wav") else { Issue.record("not audio"); return }
        #expect(s.format == "WAV")
        #expect(s.stream.codec == "PCM")
        #expect(s.stream.channels == 2)
        #expect(s.stream.bitsPerSample == 16)
        #expect(s.stream.durationSeconds == 1)
        #expect(s.tags.title == "Invented Wav")
        #expect(s.tags.artist == "Wes")
        #expect(s.tagFormats == ["RIFF INFO"])
        #expect(s.warnings.isEmpty)
        guard case .audio(let cut) = MediaReader.read(data: wav(dataBytes: 100, declared: 176_400), fileName: "c.wav") else { Issue.record("no summary"); return }
        #expect(cut.truncated)
        #expect(cut.warnings.contains { $0.level == .caution })
        for c in truncations(wav(dataBytes: 400)) { _ = MediaReader.read(data: c, fileName: "t.wav") }
    }
}

// MARK: - Images and provenance

fileprivate func drawnImage(type: String, width: Int = 4, height: Int = 3, properties: [CFString: Any] = [:], frames: Int = 1,
                            frameProperties: [CFString: Any] = [:]) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type as CFString, frames, nil)!
    if !properties.isEmpty { CGImageDestinationSetProperties(dest, properties as CFDictionary) }
    for _ in 0..<frames { CGImageDestinationAddImage(dest, image, (frameProperties.isEmpty ? properties : frameProperties) as CFDictionary) }
    CGImageDestinationFinalize(dest)
    return out as Data
}

fileprivate func pngChunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
    var b = Bytes()
    b.be32(body.count); b.ascii(type); b.bytes(body)
    b.be32(Int(crc32(Array(type.utf8) + body)))
    return b.b
}

/// Inserts chunks right after IHDR.
fileprivate func pngWith(_ chunks: [[UInt8]]) -> Data {
    let png = [UInt8](drawnImage(type: "public.png"))
    return Data(Array(png[0..<33]) + chunks.flatMap { $0 } + Array(png[33...]))
}

/// zlib data with one stored DEFLATE block (no compression library needed to build it).
fileprivate func zlibStored(_ data: [UInt8]) -> [UInt8] {
    var b = Bytes()
    b.u8(0x78); b.u8(0x01); b.u8(1); b.le16(data.count); b.le16(~data.count & 0xFFFF); b.bytes(data)
    var a: UInt32 = 1, c: UInt32 = 0
    for x in data { a = (a + UInt32(x)) % 65521; c = (c + a) % 65521 }
    b.be32(Int(c << 16 | a))
    return b.b
}

// A minimal CBOR writer for the invented manifests.
fileprivate indirect enum CBOR { case text(String), uint(Int), bytes(Int), array([CBOR]), map([(String, CBOR)]) }
fileprivate func cbor(_ v: CBOR) -> [UInt8] {
    func head(_ major: UInt8, _ n: Int) -> [UInt8] {
        if n < 24 { return [major << 5 | UInt8(n)] }
        if n < 256 { return [major << 5 | 24, UInt8(n)] }
        return [major << 5 | 25, UInt8(n >> 8), UInt8(n & 0xFF)]
    }
    switch v {
    case .text(let s): return head(3, s.utf8.count) + Array(s.utf8)
    case .uint(let n): return head(0, n)
    case .bytes(let n): return head(2, n) + [UInt8](repeating: 0xAB, count: n)
    case .array(let a): return head(4, a.count) + a.flatMap(cbor)
    case .map(let m): return head(5, m.count) + m.flatMap { cbor(.text($0.0)) + cbor($0.1) }
    }
}

fileprivate func jumbBox(_ uuidPrefix: String, label: String, _ content: [[UInt8]]) -> [UInt8] {
    var d = Array(uuidPrefix.utf8) + [0x00, 0x11, 0x00, 0x10, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71]
    d += [0x03] + Array(label.utf8) + [0]
    var jumd = Bytes(); jumd.be32(8 + d.count); jumd.ascii("jumd"); jumd.bytes(d)
    let body = jumd.b + content.flatMap { $0 }
    var b = Bytes(); b.be32(8 + body.count); b.ascii("jumb"); b.bytes(body)
    return b.b
}
fileprivate func contentBox(_ type: String, _ body: [UInt8]) -> [UInt8] {
    var b = Bytes(); b.be32(8 + body.count); b.ascii(type); b.bytes(body)
    return b.b
}

fileprivate func c2paStore(sourceType: String = "trainedAlgorithmicMedia", signed: Bool = true) -> [UInt8] {
    let actions = cbor(.map([("actions", .array([.map([("action", .text("c2pa.created")),
        ("digitalSourceType", .text("http://cv.iptc.org/newscodes/digitalsourcetype/\(sourceType)")),
        ("softwareAgent", .map([("name", .text("Invented Model"))]))])]))]))
    let claim = cbor(.map([("claim_generator", .text("Invented Generator/1.0")), ("dc:title", .text("made.png")),
                           ("dc:format", .text("image/png")), ("signature", .text("self#jumbf=c2pa.signature")),
                           ("assertions", .array([.map([("url", .text("self#jumbf=c2pa.assertions/c2pa.actions"))])]))]))
    let assertions = jumbBox("c2as", label: "c2pa.assertions", [
        jumbBox("cbor", label: "c2pa.actions", [contentBox("cbor", actions)]),
        jumbBox("cbor", label: "c2pa.hash.data", [contentBox("cbor", cbor(.map([("alg", .text("sha256"))])))]),
    ])
    let manifest = jumbBox("c2ma", label: "urn:uuid:11111111-2222-3333-4444-555555555555", [
        assertions,
        jumbBox("c2cl", label: "c2pa.claim", [contentBox("cbor", claim)]),
        jumbBox("c2cs", label: "c2pa.signature", signed ? [contentBox("cbor", cbor(.bytes(40)))] : []),
    ])
    return jumbBox("c2pa", label: "c2pa", [manifest])
}

@Suite struct MediaImageTests {
    @Test func imageIODetailsCameraAndGPS() throws {
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Invented", kCGImagePropertyTIFFModel: "Cam 1"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifExposureTime: 0.004,
                                             kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifFocalLength: 35.0,
                                             kCGImagePropertyExifDateTimeOriginal: "2026:05:01 10:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5, kCGImagePropertyGPSLatitudeRef: "S",
                                            kCGImagePropertyGPSLongitude: 45.25, kCGImagePropertyGPSLongitudeRef: "E"],
        ]
        let jpeg = drawnImage(type: "public.jpeg", width: 8, height: 6, properties: props)
        guard case .image(let s) = MediaReader.read(data: jpeg, fileName: "photo.jpg") else { Issue.record("not an image"); return }
        #expect(s.width == 8)
        #expect(s.height == 6)
        #expect(s.headline == "8 × 6")
        #expect(s.cameraMake == "Invented")
        #expect(s.cameraModel == "Cam 1")
        #expect(s.fNumber == 2.8)
        #expect(s.iso == 200)
        #expect(s.dateTaken == "2026:05:01 10:00:00")
        #expect(s.location?.latitude == -12.5)
        #expect(s.location?.longitude == 45.25)
        #expect(s.warnings.contains { $0.level == .caution && $0.reason.contains("GPS") })
        #expect(s.provenance == nil)
    }

    @Test func animatedGIFFramesLoopAndDuration() {
        let gif = drawnImage(type: "com.compuserve.gif", properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
                             frames: 3, frameProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]])
        guard case .image(let s) = MediaReader.read(data: gif, fileName: "anim.gif") else { Issue.record("not an image"); return }
        #expect(s.frameCount == 3)
        #expect(s.loopCount == 0)
        #expect(abs((s.animationDuration ?? 0) - 0.3) < 0.001)
    }

    @Test func automatic1111Parameters() throws {
        let params = """
        a lighthouse at dusk, <lora:invented_style:0.8>, oil paint
        Negative prompt: blurry,
        low quality
        Steps: 20, Sampler: Euler a, Schedule type: Karras, CFG scale: 7, Seed: 1234, Size: 512x768, Model hash: abc123def, Model: invented-v1, Lora hashes: "invented_style: 0011, other: 22", Version: v1.10.0
        """
        let png = pngWith([pngChunk("tEXt", utf8("parameters") + [0] + Array(params.utf8))])
        guard case .image(let s) = MediaReader.read(data: png, fileName: "gen.png") else { Issue.record("not an image"); return }
        #expect(s.width == 4)
        let p = try #require(s.provenance)
        let g = try #require(p.generation)
        #expect(p.generator == "Automatic1111 / Forge")
        #expect(p.isAIGenerated)
        #expect(g.prompt == "a lighthouse at dusk, <lora:invented_style:0.8>, oil paint")
        #expect(g.negativePrompt == "blurry,\nlow quality")
        #expect(g.steps == 20)
        #expect(g.sampler == "Euler a")
        #expect(g.scheduler == "Karras")
        #expect(g.cfgScale == 7)
        #expect(g.seed == "1234")
        #expect(g.size == "512x768")
        #expect(g.model == "invented-v1")
        #expect(g.modelHash == "abc123def")
        #expect(g.loras == ["invented_style", "other"])
        #expect(g.otherSettings.contains(MediaFact("Version", "v1.10.0")))
        #expect(p.textKeys == ["parameters"])
        #expect(s.warnings.contains { $0.reason.contains("made with AI") })
    }

    @Test func comfyUIPromptAndWorkflowInCompressedChunks() throws {
        let prompt = """
        {"3":{"class_type":"KSampler","inputs":{"seed":987654321987,"steps":30,"cfg":6.5,"sampler_name":"dpmpp_2m","scheduler":"karras","positive":["6",0],"negative":["7",0],"model":["4",0]}},
         "4":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"invented_xl.safetensors"}},
         "5":{"class_type":"LoraLoader","inputs":{"lora_name":"invented_lora.safetensors","model":["4",0]}},
         "6":{"class_type":"CLIPTextEncode","inputs":{"text":"a red fox in snow","clip":["4",1]}},
         "7":{"class_type":"CLIPTextEncode","inputs":{"text":"watermark","clip":["4",1]}},
         "8":{"class_type":"VAEDecode","inputs":{"samples":["3",0]}}}
        """
        let ztxt = pngChunk("zTXt", utf8("prompt") + [0, 0] + zlibStored(Array(prompt.utf8)))
        guard case .image(let s) = MediaReader.read(data: pngWith([ztxt]), fileName: "comfy.png") else { Issue.record("not an image"); return }
        let c = try #require(s.provenance?.comfy)
        #expect(s.provenance?.generator == "ComfyUI")
        #expect(c.source == "prompt")
        #expect(c.nodeCount == 6)
        #expect(c.nodeTypes.first == MediaCount("CLIPTextEncode", 2))
        #expect(c.checkpoints == ["invented_xl.safetensors"])
        #expect(c.loras == ["invented_lora.safetensors"])
        #expect(c.seeds == ["987654321987"])
        #expect(c.steps == [30])
        #expect(c.cfgScales == [6.5])
        #expect(c.samplers == ["dpmpp_2m"])
        #expect(c.positivePrompts == ["a red fox in snow"])
        #expect(c.negativePrompts == ["watermark"])

        let workflow = """
        {"nodes":[{"id":1,"type":"CheckpointLoaderSimple","widgets_values":["wf_model.ckpt"]},
         {"id":2,"type":"CLIPTextEncode","widgets_values":["castle on a hill"]},
         {"id":3,"type":"CLIPTextEncode","widgets_values":["fog"]},
         {"id":4,"type":"KSampler","widgets_values":[42,"fixed",25,8,"euler","normal",1],
          "inputs":[{"name":"positive","link":10},{"name":"negative","link":11}]}],
         "links":[[10,2,0,4,1,"CONDITIONING"],[11,3,0,4,2,"CONDITIONING"]]}
        """
        let itxt = pngChunk("iTXt", utf8("workflow") + [0, 1, 0] + [0] + [0] + zlibStored(Array(workflow.utf8)))
        guard case .image(let w) = MediaReader.read(data: pngWith([itxt]), fileName: "wf.png") else { Issue.record("not an image"); return }
        let wc = try #require(w.provenance?.comfy)
        #expect(wc.source == "workflow")
        #expect(wc.checkpoints == ["wf_model.ckpt"])
        #expect(wc.seeds == ["42"])
        #expect(wc.steps == [25])
        #expect(wc.positivePrompts == ["castle on a hill"])
        #expect(wc.negativePrompts == ["fog"])
    }

    @Test func c2paInPNGAndSplitAcrossJPEGSegments() throws {
        let store = c2paStore()
        guard case .image(let s) = MediaReader.read(data: pngWith([pngChunk("caBX", store)]), fileName: "cred.png") else { Issue.record("not an image"); return }
        let c = try #require(s.provenance?.c2pa)
        #expect(c.container == "PNG caBX")
        #expect(c.manifestCount == 1)
        #expect(c.activeManifestLabel == "urn:uuid:11111111-2222-3333-4444-555555555555")
        #expect(c.claimGenerator == "Invented Generator/1.0")
        #expect(c.title == "made.png")
        #expect(c.assertions == ["c2pa.actions", "c2pa.hash.data"])
        #expect(c.actions == [MediaC2PAAction(action: "c2pa.created", digitalSourceType: "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia",
                                              softwareAgent: "Invented Model", when: nil)])
        #expect(c.madeWithAI)
        #expect(c.aiSourceType == "trainedAlgorithmicMedia")
        #expect(c.signaturePresent)
        #expect(!c.signatureVerified)
        #expect(s.provenance?.isAIGenerated == true)
        #expect(s.provenance?.headline.contains("not verified") == true)

        // JPEG APP11: the store split over two segments, the second repeating the box header.
        let jpeg = [UInt8](drawnImage(type: "public.jpeg"))
        let half = store.count / 2
        func app11(_ z: Int, _ payload: [UInt8]) -> [UInt8] {
            var b = Bytes()
            b.u8(0xFF); b.u8(0xEB); b.be16(2 + 8 + payload.count); b.ascii("JP"); b.be16(1); b.be32(z); b.bytes(payload)
            return b.b
        }
        let segs = app11(2, Array(store[0..<8]) + Array(store[half...])) + app11(1, Array(store[0..<half]))
        let spliced = Data(Array(jpeg[0..<2]) + segs + Array(jpeg[2...]))
        guard case .image(let j) = MediaReader.read(data: spliced, fileName: "cred.jpg") else { Issue.record("not an image"); return }
        #expect(j.provenance?.c2pa?.container == "JPEG APP11")
        #expect(j.provenance?.c2pa?.madeWithAI == true)

        // Unsigned and not AI: present, not made with AI, and said to be unsigned.
        let plain = c2paStore(sourceType: "digitalCapture", signed: false)
        guard case .image(let u) = MediaReader.read(data: pngWith([pngChunk("caBX", plain)]), fileName: "u.png") else { return }
        #expect(u.provenance?.c2pa?.madeWithAI == false)
        #expect(u.provenance?.c2pa?.signaturePresent == false)
        #expect(u.provenance?.isAIGenerated == false)
    }

    @Test func xmpDigitalSourceType() {
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
         Iptc4xmpExt:DigitalSourceType="http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia"
         xmp:CreatorTool="Invented Editor 2"/></rdf:RDF></x:xmpmeta>
        """
        let png = pngWith([pngChunk("iTXt", utf8("XML:com.adobe.xmp") + [0, 0, 0, 0, 0] + Array(xmp.utf8))])
        let p = MediaReader.provenance(data: png)
        #expect(p?.xmpDigitalSourceType == "compositeWithTrainedAlgorithmicMedia")
        #expect(p?.xmpCreatorTool == "Invented Editor 2")
        #expect(p?.isAIGenerated == true)
    }

    @Test func malformedImagesNeverCrash() {
        #expect(MediaReader.read(data: noise(2048, seed: 77), fileName: "x.png") == nil)
        #expect(MediaReader.provenance(data: Data()) == nil)
        let png = pngWith([pngChunk("tEXt", utf8("parameters") + [0] + utf8("x\nSteps: 1")), pngChunk("caBX", c2paStore())])
        for c in truncations(png) { _ = MediaReader.read(data: c, fileName: "t.png") }
        // A caBX chunk of garbage, a zTXt chunk that does not inflate, a lying chunk length.
        _ = MediaReader.read(data: pngWith([pngChunk("caBX", [0, 0, 0, 9] + utf8("jumb") + [1]), pngChunk("zTXt", utf8("k") + [0, 0, 1, 2, 3])]), fileName: "g.png")
        var lying = [UInt8](pngWith([]))
        lying[33] = 0x7F
        _ = MediaReader.read(data: Data(lying), fileName: "l.png")
    }
}

// MARK: - Shared pieces

@Suite struct MediaCommonTests {
    @Test func cborDecodesAndRefusesBombs() {
        let value = MediaCBOR.decode(cbor(.map([("a", .array([.uint(1), .text("x")])), ("b", .bytes(100))])))
        #expect(value?["a"]?.arrayValue?.count == 2)
        if case .bytes(let n, let prefix)? = value?["b"] { #expect(n == 100); #expect(prefix.count == 64) } else { Issue.record("bytes") }
        // Indefinite map and text.
        #expect(MediaCBOR.decode([0xBF, 0x61, 0x6B, 0x7F, 0x61, 0x76, 0xFF, 0xFF])?["k"]?.string == "v")
        // 1,000 nested arrays: past the depth cap, refused rather than recursed.
        #expect(MediaCBOR.decode([UInt8](repeating: 0x81, count: 1000) + [0x01]) == nil)
        // A length that claims more than the input.
        #expect(MediaCBOR.decode([0x9B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == nil)
    }

    @Test func isoDates() {
        #expect(MediaISODate.parse("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
        #expect(MediaISODate.parse("2026-05-01T12:00:00.5+02:00") == Date(timeIntervalSince1970: 1_777_629_600.5))
        #expect(MediaISODate.parse("garbage") == nil)
    }

    @Test func sniffingAndUnknown() {
        #expect(MediaReader.read(data: Data("hello".utf8), fileName: "notes.txt") == nil)
        if case .audio = MediaReader.read(data: Data(id3Tag(major: 3, []) + mpegFrames), fileName: "noext") {} else { Issue.record("ID3 sniff") }
        if case .map = MediaReader.read(data: gpx(), fileName: "track.xml") {} else { Issue.record("GPX sniff") }
        if case .book = MediaReader.read(data: epub3(), fileName: "book.zip") {} else { Issue.record("EPUB sniff") }
    }

    @Test func randomBytesForEveryExtension() {
        let exts = ["epub", "cbz", "cbr", "geojson", "gpx", "kml", "kmz", "stl", "obj", "3mf", "gltf", "glb",
                    "mp3", "m4a", "flac", "ogg", "opus", "wav", "png", "jpg", "webp", "heic", "gif"]
        for (i, ext) in exts.enumerated() {
            for size in [0, 1, 7, 64, 700, 5000] {
                _ = MediaReader.read(data: noise(size, seed: UInt64(i * 31 + size)), fileName: "f.\(ext)")
            }
        }
    }
}
