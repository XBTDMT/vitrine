import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import VitrinePreviewKit
import VitrineDocument
import VitrineSupport

/// Pictures on the facts card (S-23, N-9, parity B-6). Every picture is invented here: ImageIO writes JPEG, HEIC,
/// PNG (and APNG), GIF, TIFF and AVIF with EXIF and GPS dictionaries made up for the test; ImageIO cannot write WebP
/// on this SDK (`CGImageDestinationCopyTypeIdentifiers` has no WebP), so the WebP files are assembled from the
/// container and VP8L specs (lossless, one colour per frame) and read back through ImageIO.
@MainActor
final class ImageCardTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: Invented pictures

    private func picture(_ w: Int, _ h: Int, alpha: Bool = false, red: CGFloat = 0.8) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
        ctx.setFillColor(red: red, green: 0.4, blue: 0.3, alpha: alpha ? 0.5 : 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private static let camera: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 2.0, kCGImagePropertyExifExposureTime: 0.004,
                                         kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifExposureBiasValue: 0.0,
                                         kCGImagePropertyExifFocalLength: 35.0, kCGImagePropertyExifFlash: 16,
                                         kCGImagePropertyExifDateTimeOriginal: "2026:10:11 17:42:00", kCGImagePropertyExifLensModel: "Example 35mm f/2"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Halden", kCGImagePropertyTIFFModel: "Halden F2"],
    ]

    private static func gps(lat: Double, _ latRef: String, lon: Double, _ lonRef: String, altitude: Double? = nil) -> [CFString: Any] {
        var d: [CFString: Any] = [kCGImagePropertyGPSLatitude: lat, kCGImagePropertyGPSLatitudeRef: latRef,
                                  kCGImagePropertyGPSLongitude: lon, kCGImagePropertyGPSLongitudeRef: lonRef]
        if let altitude { d[kCGImagePropertyGPSAltitude] = altitude; d[kCGImagePropertyGPSAltitudeRef] = 0 }
        return [kCGImagePropertyGPSDictionary: d]
    }

    @discardableResult
    private func write(_ name: String, type: UTType, frames: [CGImage], properties: [CFString: Any] = [:],
                       frameProperties: [CFString: Any]? = nil, container: [CFString: Any]? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let d = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames.count, nil), "\(type)")
        if let container { CGImageDestinationSetProperties(d, container as CFDictionary) }
        for frame in frames {
            CGImageDestinationAddImage(d, frame, (frameProperties ?? properties) as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(d), "\(type) written")
        return url
    }

    private func render(_ url: URL, width: CGFloat = 900, height: CGFloat = 640) async throws -> (RenderedPreview, InfoCardView) {
        let preview = try await ImageRenderer().render(url: url, kind: .image, context: RenderContext(appearance: .light, defaultsSuite: "vt-image"))
        let view = try XCTUnwrap(preview.view as? InfoCardView)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        return (preview, view)
    }

    // MARK: WebP from the spec

    /// A lossless VP8L bitstream of one colour: five one-symbol prefix codes, so every pixel costs no bits.
    static func vp8l(width: Int, height: Int, argb: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var out: [UInt8] = [], acc = 0, n = 0
        func put(_ value: Int, _ count: Int) {
            for i in 0..<count {
                acc |= ((value >> i) & 1) << n; n += 1
                if n == 8 { out.append(UInt8(acc)); acc = 0; n = 0 }
            }
        }
        put(0x2F, 8); put(width - 1, 14); put(height - 1, 14); put(argb.0 == 255 ? 0 : 1, 1); put(0, 3)
        put(0, 1); put(0, 1); put(0, 1)   // no transform, no colour cache, no meta prefix codes
        for symbol in [argb.2, argb.1, argb.3, argb.0, 0] {   // green, red, blue, alpha, distance
            put(1, 1); put(0, 1); put(1, 1); put(Int(symbol), 8)
        }
        if n > 0 { out.append(UInt8(acc)) }
        return out
    }

    static func chunk(_ tag: String, _ body: [UInt8]) -> [UInt8] {
        let size = UInt32(body.count)
        return Array(tag.utf8) + [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)] + body + (body.count % 2 == 1 ? [0] : [])
    }

    static func riff(_ chunks: [[UInt8]]) -> Data {
        let body = Array("WEBP".utf8) + chunks.flatMap { $0 }
        let size = UInt32(body.count)
        return Data(Array("RIFF".utf8) + [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)] + body)
    }

    static func u24(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF)] }

    static func webP(width: Int, height: Int) -> Data {
        riff([chunk("VP8L", vp8l(width: width, height: height, argb: (255, 200, 50, 50)))])
    }

    static func animatedWebP(width: Int, height: Int, frames: Int, milliseconds: Int, loops: Int) -> Data {
        var chunks = [chunk("VP8X", [0x02 | 0x10, 0, 0, 0] + u24(width - 1) + u24(height - 1)),
                      chunk("ANIM", [255, 255, 255, 255, UInt8(loops & 0xFF), UInt8(loops >> 8)])]
        for i in 0..<frames {
            let colour = UInt8(40 * i % 255)
            chunks.append(chunk("ANMF", u24(0) + u24(0) + u24(width - 1) + u24(height - 1) + u24(milliseconds) + [0]
                                + chunk("VP8L", vp8l(width: width, height: height, argb: (255, colour, 100, 200)))))
        }
        return riff(chunks)
    }

    // MARK: Routing

    func testRegistryRoutesPicturesAndFontsToTheirCards() {
        XCTAssertTrue(RendererRegistry.renderer(for: .image) is ImageRenderer)
        XCTAssertTrue(RendererRegistry.renderer(for: .font) is FontRenderer)
        XCTAssertTrue(RendererRegistry.renderer(for: .svg) is SVGRenderer, "SVG keeps its own renderer")
    }

    // MARK: Photos

    func testJPEGPhotoReadsTheCameraTheExposureAndTheLocation() throws {
        let url = try write("IMG_0001.jpg", type: .jpeg, frames: [picture(600, 400)],
                            properties: Self.camera.merging(Self.gps(lat: 33.8688, "S", lon: 151.2093, "E", altitude: 58)) { a, _ in a })
        let info = try ImageInfo.read(url: url)
        XCTAssertEqual(info.kind, .photo)
        XCTAssertEqual(info.formatName, "JPEG")
        XCTAssertEqual(info.width, 600); XCTAssertEqual(info.height, 400)
        XCTAssertEqual(info.model, "Halden F2"); XCTAssertEqual(info.lens, "Example 35mm f/2")
        XCTAssertEqual(info.fNumber, 2); XCTAssertEqual(info.iso, 200); XCTAssertEqual(info.flashFired, false)
        XCTAssertEqual(info.dateTaken, "2026:10:11 17:42:00")
        XCTAssertEqual(info.compression, "lossy")
        let location = try XCTUnwrap(info.location)
        XCTAssertEqual(location.latitude, -33.8688, accuracy: 0.0001, "S is south: negative")
        XCTAssertEqual(location.longitude, 151.2093, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(location.altitude), 58, accuracy: 0.5)

        let card = ImageCard.make(info, fileName: "IMG_0001", fileSize: 1, locale: Locale(identifier: "en_GB"), now: Self.date("2026-10-30"))
        XCTAssertEqual(card.kindName, "Photo")
        XCTAssertEqual(card.sentence, "A photo taken Sunday 11 October at 17:42 on a Halden F2; it carries its GPS location.",
                       "0.24 MP says no megapixels; Halden F2 already names its maker")
        XCTAssertEqual(card.strip.map(\.label), ["Camera", "Exposure", "Pixels"])
        XCTAssertEqual(card.strip[1].value, "ƒ/2 · 1/250 s · ISO 200")
        XCTAssertEqual(card.actions.map(\.title), ["Copy coordinates", "Open in Photos"])
        XCTAssertEqual(card.sections.map(\.title), ["Exposure", "Image", "Location"])
        XCTAssertEqual(card.sections[0].content, .chips(["35 mm", "ƒ/2.0", "1/250 s", "ISO 200", "0 ev", "Flash off"]))
        guard case .rows(let rows) = card.sections[2].content else { return XCTFail("location rows") }
        XCTAssertEqual(rows[0], .init(key: "Coordinates", value: "33.8688° S, 151.2093° E", flagged: true, number: 1))
        XCTAssertEqual(rows[1], .init(key: "Altitude", value: "58 m"))
        let badges = ImageCard.badges(info)
        XCTAssertEqual(badges.map(\.level), [.info])
        XCTAssertEqual(badges.first?.title, "Carries a GPS location")
        XCTAssertEqual(ImageCard.facts(info, card: card, fileSize: 1).first { $0.key == "location" }?.value, "33.8688° S, 151.2093° E")
    }

    func testAPhotoWithoutGPSSaysItCarriesNoLocationAndOffersNoCoordinates() throws {
        let url = try write("IMG_0002.heic", type: .heic, frames: [picture(4000, 3000)], properties: Self.camera)
        let info = try ImageInfo.read(url: url)
        XCTAssertEqual(info.formatName, "HEIC")
        XCTAssertNil(info.location)
        let card = ImageCard.make(info, fileName: "IMG_0002", fileSize: 1, locale: Locale(identifier: "en_GB"), now: Self.date("2027-01-02"))
        XCTAssertEqual(card.sentence, "A 12 MP photo taken Sunday, 11 October 2026 at 17:42 on a Halden F2; it carries no location.",
                       "another year's date names the year")
        XCTAssertEqual(card.actions.map(\.id), ["openInPhotos"])
        XCTAssertFalse(card.sections.contains { $0.title == "Location" })
        XCTAssertEqual(ImageCard.badges(info), [])
    }

    func testOutOfRangeCoordinatesAreNotALocation() throws {
        let url = try write("bad-gps.jpg", type: .jpeg, frames: [picture(64, 64)],
                            properties: Self.camera.merging(Self.gps(lat: 123, "N", lon: 10, "E")) { a, _ in a })
        XCTAssertNil(try ImageInfo.read(url: url).location)
    }

    func testAQuarterTurnOrientationSwapsWidthAndHeight() throws {
        var properties = Self.camera
        properties[kCGImagePropertyOrientation] = 6
        let url = try write("turned.jpg", type: .jpeg, frames: [picture(300, 200)], properties: properties)
        let info = try ImageInfo.read(url: url)
        XCTAssertEqual(info.width, 200); XCTAssertEqual(info.height, 300)
    }

    // MARK: Other pictures

    func testAPNGWithTransparencyIsAnImageInItsColourWithTransparency() throws {
        let url = try write("swatch.png", type: .png, frames: [picture(1280, 800, alpha: true)])
        let info = try ImageInfo.read(url: url)
        XCTAssertEqual(info.kind, .image)
        XCTAssertTrue(info.hasAlpha)
        XCTAssertEqual(info.compression, "lossless")
        let card = ImageCard.make(info, fileName: "swatch", fileSize: 2048)
        XCTAssertEqual(card.kindName, "Image")
        XCTAssertTrue(card.sentence.hasPrefix("A 1280 × 800 PNG image in "), card.sentence)
        XCTAssertTrue(card.sentence.hasSuffix(", with transparency."), card.sentence)
        XCTAssertEqual(card.strip.map(\.label), ["Pixels", "Colour", "Size"])
        XCTAssertEqual(card.actions, [])
    }

    func testTIFFNamesItsCompression() throws {
        let url = try write("scan.tiff", type: .tiff, frames: [picture(120, 80)],
                            properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]])
        XCTAssertEqual(try ImageInfo.read(url: url).compression, "LZW, lossless")
    }

    func testAVIFReads() throws {
        let url = try write("frame.avif", type: try XCTUnwrap(UTType("public.avif")), frames: [picture(320, 240)])
        let info = try ImageInfo.read(url: url)
        XCTAssertEqual(info.formatName, "AVIF")
        XCTAssertEqual(info.width, 320)
    }

    // MARK: Animations

    func testAnimatedGIFSaysItsLengthRateAndLoops() throws {
        let frame: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
        let container: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        let url = try write("spinner.gif", type: .gif, frames: (0..<4).map { picture(48, 48, red: CGFloat($0) / 4) },
                            frameProperties: frame, container: container)
        let info = try ImageInfo.read(url: url)
        XCTAssertEqual(info.kind, .animated)
        let a = try XCTUnwrap(info.animation)
        XCTAssertEqual(a.frames, 4)
        XCTAssertEqual(a.duration, 0.4, accuracy: 0.001)
        XCTAssertEqual(a.loops, 0)
        XCTAssertTrue(a.evenTiming)
        let card = ImageCard.make(info, fileName: "spinner", fileSize: 1)
        XCTAssertEqual(card.kindName, "Animated image")
        XCTAssertEqual(card.sentence, "An animated image, 0.4 seconds long at 10 frames a second, looping forever.")
        XCTAssertEqual(card.strip.map(\.value), ["4", "10 fps", "48 × 48"])
        guard case .rows(let rows) = card.sections[0].content else { return XCTFail("animation rows") }
        XCTAssertEqual(rows.map(\.key), ["Frames", "Rate", "Loops", "Size", "Compression"])
        XCTAssertEqual(rows.map(\.value).prefix(3), ["4 · 0.4 s", "10 fps, even timing", "forever"])
        XCTAssertTrue(rows[3].value.hasPrefix("48 × 48"), "ImageIO's GIF writer may add a transparent colour: \(rows[3].value)")
    }

    func testAPNGWrittenByImageIOPlaysItsCount() throws {
        let frame: [CFString: Any] = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.05]]
        let container: [CFString: Any] = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 3]]
        let url = try write("pulse.png", type: .png, frames: (0..<6).map { picture(32, 32, red: CGFloat($0) / 6) },
                            frameProperties: frame, container: container)
        let info = try ImageInfo.read(url: url)
        XCTAssertEqual(info.formatName, "APNG")
        XCTAssertEqual(info.animation?.frames, 6)
        XCTAssertEqual(info.animation?.loops, 3)
        XCTAssertTrue(ImageCard.make(info, fileName: "pulse", fileSize: 1).sentence.hasSuffix("playing 3 times."))
    }

    func testWebPStillAndAnimationAssembledFromTheSpecReadThroughImageIO() throws {
        let still = dir.appendingPathComponent("tile.webp")
        try Self.webP(width: 40, height: 30).write(to: still)
        let s = try ImageInfo.read(url: still)
        XCTAssertEqual(s.formatName, "WebP")
        XCTAssertEqual(s.width, 40); XCTAssertEqual(s.height, 30)
        XCTAssertEqual(s.compression, "lossless")
        XCTAssertEqual(s.kind, .image)

        let moving = dir.appendingPathComponent("loading-spinner.webp")
        try Self.animatedWebP(width: 16, height: 16, frames: 5, milliseconds: 40, loops: 0).write(to: moving)
        let m = try ImageInfo.read(url: moving)
        XCTAssertEqual(m.kind, .animated)
        XCTAssertEqual(m.animation?.frames, 5)
        XCTAssertEqual(try XCTUnwrap(m.animation?.duration), 0.2, accuracy: 0.001)
        XCTAssertEqual(m.animation?.loops, 0)
        XCTAssertEqual(m.compression, "lossless", "the first ANMF frame's VP8L chunk")
        XCTAssertEqual(ImageCard.make(m, fileName: "loading-spinner", fileSize: 1).sentence,
                       "An animated image, 0.2 seconds long at 25 frames a second, looping forever.")
    }

    // MARK: The card drawn

    func testRendererDrawsThePhotoCardWithPhotoAndInfoViews() async throws {
        let url = try write("IMG_0003.jpg", type: .jpeg, frames: [picture(1200, 800)],
                            properties: Self.camera.merging(Self.gps(lat: 30.2672, "N", lon: 97.7431, "W")) { a, _ in a })
        let (preview, view) = try await render(url)
        XCTAssertEqual(preview.document.kind, .image)
        XCTAssertEqual(preview.document.viewTitles, ["Photo", "Info"])
        XCTAssertEqual(preview.document.fact("kindName")?.value, "Photo")
        XCTAssertEqual(preview.document.badges.first?.title, "Carries a GPS location")
        XCTAssertEqual(preview.showView?(0), true, "the card is drawn natively")
        XCTAssertEqual(preview.showView?(1), false, "Info is the host's text view")
        guard case .text(let info) = preview.document.views[1] else { return XCTFail("Info is text") }
        XCTAssertTrue(info.contains("GPS"), "every property, GPS included")
        XCTAssertEqual(view.titleField.stringValue, "IMG_0003")
        XCTAssertEqual(view.actionButtons.map(\.label.stringValue), ["Copy coordinates", "Open in Photos"])
        let flagged = view.sectionViews.flatMap(\.rowViews).filter(\.row.flagged)
        XCTAssertEqual(flagged.map(\.valueField.stringValue), ["30.2672° N, 97.7431° W"])
        XCTAssertNotNil(flagged.first?.badge, "the numbered badge")
        let stage = try XCTUnwrap(view.stageContent as? ImageStageView)
        XCTAssertEqual(stage.frames?.images.count, 1)
        XCTAssertLessThanOrEqual(stage.frames?.images.first?.width ?? .max, 2560, "the stage holds a downsampled picture")
        XCTAssertEqual(stage.pictureRect(), stage.bounds, "a photo fills the stage")
        XCTAssertGreaterThan(view.stage.frame.height, 150)
        // Copy coordinates is not pressed here: the test would overwrite the person's clipboard.
    }

    func testAnimationPlaysOnTheStageAtTheFileTiming() async throws {
        let frame: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]]
        let url = try write("blink.gif", type: .gif, frames: (0..<3).map { picture(40, 40, red: CGFloat($0) / 3) },
                            frameProperties: frame, container: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]])
        let (preview, view) = try await render(url)
        XCTAssertEqual(preview.document.viewTitles, ["Image", "Info"])
        XCTAssertEqual(preview.document.fact("kindName")?.value, "Animated image")
        let stage = try XCTUnwrap(view.stageContent as? ImageStageView)
        XCTAssertEqual(stage.frames?.images.count, 3)
        XCTAssertTrue(stage.isAnimating)
        let rect = stage.pictureRect()
        XCTAssertEqual(rect.width, 40, "a small picture is never scaled up")
    }

    func testFinderPaneWidthStacksTheCardInOneColumn() async throws {
        let url = try write("IMG_0004.jpg", type: .jpeg, frames: [picture(800, 600)],
                            properties: Self.camera.merging(Self.gps(lat: 1, "N", lon: 1, "E")) { a, _ in a })
        let (_, view) = try await render(url, width: 320, height: 600)
        XCTAssertTrue(view.isNarrow)
        XCTAssertEqual(view.stage.frame.height, 118, accuracy: 0.5, "the grouped card keeps a short stage for a photo")
        XCTAssertEqual(view.stripCells.filter { !$0.isHidden }.count, 2)
        XCTAssertTrue(view.actionButtons.allSatisfy { $0.superview?.isHidden == true })
        let xs = Set(view.sectionViews.map { $0.convert(NSPoint.zero, to: view).x.rounded() })
        XCTAssertEqual(xs.count, 1, "one column")
    }

    func testUnreadablePictureThrows() async throws {
        let url = dir.appendingPathComponent("broken.jpg")
        try Data("not a picture".utf8).write(to: url)
        do {
            _ = try await ImageRenderer().render(url: url, kind: .image, context: RenderContext(appearance: .light, defaultsSuite: "vt-image"))
            XCTFail("expected a throw")
        } catch {}
    }

    // MARK: Words

    func testArticlesBeforeNumbers() {
        for (text, article) in [("8 MP", "an"), ("11 MP", "an"), ("18 MP", "an"), ("80 MP", "an"), ("24 MP", "a"), ("1.2 MP", "a"),
                                ("180 MP", "a"), ("11,000", "an"), ("100", "a")] {
            XCTAssertEqual(InfoCard.article(beforeNumber: text), article, text)
        }
    }

    func testShutterAndBiasWording() {
        XCTAssertEqual(ImageCard.shutter(0.004), "1/250 s")
        XCTAssertEqual(ImageCard.shutter(2), "2 s")
        XCTAssertEqual(ImageCard.shutter(1.5), "1.5 s")
        var info = try! ImageInfo.read(url: try! write("b.jpg", type: .jpeg, frames: [picture(8, 8)],
                                                       properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureBiasValue: -0.67]]))
        XCTAssertTrue(ImageCard.exposureChips(info).contains("−0.7 ev"))
        info.exposureBias = 1
        XCTAssertTrue(ImageCard.exposureChips(info).contains("+1 ev"))
    }

    private static func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)!
    }
}
