import AppKit
import XCTest
@testable import VitrinePreviewKit
import VitrineFormats

/// S-16 F56: a map file's coordinates cannot make the graticule's Double-to-Int conversion trap. Invented GPX tracks
/// on the pole at longitudes far past ±180 (the reader keeps any finite longitude and warns), drawn offscreen at
/// several sizes, with and without the elevation strip. Nothing is written to disk. roadmap: S-16
@MainActor
final class S16MiscMapTests: XCTestCase {
    /// Two points one representable step apart at longitude 2^exponent, one on the pole.
    static func polarGPX(exponent: Int, elevation: Bool) -> Data {
        let far = Double(sign: .plus, exponent: exponent, significand: 1)
        func point(_ lat: Double, _ lon: Double, _ ele: Int) -> String {
            "<trkpt lat=\"\(lat)\" lon=\"\(lon)\">" + (elevation ? "<ele>\(ele)</ele>" : "") + "</trkpt>"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Invented" xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>Pole</name><trkseg>\(point(89.9, far.nextDown, 10))\(point(90, far, 20))</trkseg></trk></gpx>
        """
        return Data(xml.utf8)
    }

    func draw(_ summary: MediaMapSummary, width: CGFloat, height: CGFloat) throws {
        let view = MapStageView(summary: summary)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        view.layout()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    func testFarLongitudesOnThePoleDrawWithoutTrapping() throws {
        var drawn = 0
        for exponent in stride(from: 90, through: 130, by: 1) {
            for elevation in [true, false] {
                guard case .map(let summary)? = MediaReader.read(data: Self.polarGPX(exponent: exponent, elevation: elevation),
                                                                 fileName: "pole.gpx") else { continue }
                for (width, height) in [(900.0, 420.0), (768.0, 300.0), (1200.0, 260.0)] {
                    try draw(summary, width: width, height: height)
                    drawn += 1
                }
            }
        }
        XCTAssertGreaterThan(drawn, 0, "the invented tracks were read as maps")
    }

    func testTheHeavierLineIsDecidedWithoutAnIntConversion() {
        XCTAssertTrue(MapStageView.isMajorLine(4, step: 2))
        XCTAssertFalse(MapStageView.isMajorLine(2, step: 2))
        XCTAssertTrue(MapStageView.isMajorLine(-4, step: 1))
        XCTAssertFalse(MapStageView.isMajorLine(-3, step: 1))
        XCTAssertTrue(MapStageView.isMajorLine(0, step: 0.5))
        // Far past Int's range: no trap, and an answer (every such double is an even whole number).
        XCTAssertTrue(MapStageView.isMajorLine(0x1p100, step: 1e-11))
        XCTAssertFalse(MapStageView.isMajorLine(.infinity, step: 1))
        XCTAssertFalse(MapStageView.isMajorLine(1, step: 0))
        XCTAssertFalse(MapStageView.isMajorLine(.nan, step: 1))
    }
}
