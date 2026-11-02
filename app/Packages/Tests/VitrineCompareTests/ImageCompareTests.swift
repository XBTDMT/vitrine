import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import VitrineCompare

/// The image compare against the design's states "Two images: 2-up / swipe / onion skin / difference", with images
/// drawn here by Core Graphics. roadmap: S-7
final class ImageCompareTests: XCTestCase {
    /// Draws a width × height image in a top-left coordinate space and encodes it.
    private func image(_ width: Int, _ height: Int, type: UTType = .png, background: CGColor = CGColor(gray: 1, alpha: 1),
                       draw: (CGContext) -> Void = { _ in }) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(false)
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        let cg = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func fill(_ context: CGContext, _ rect: CGRect, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(rect)
    }

    private func designPair() throws -> (Data, Data) {
        let old = try image(400, 300) { c in
            self.fill(c, CGRect(x: 40, y: 30, width: 180, height: 40), 0.1, 0.1, 0.1)   // headline
            self.fill(c, CGRect(x: 40, y: 220, width: 90, height: 24), 0.0, 0.4, 1.0)   // button
        }
        let new = try image(400, 300) { c in
            self.fill(c, CGRect(x: 40, y: 30, width: 200, height: 40), 0.1, 0.1, 0.1)   // headline grows by 20 px
            self.fill(c, CGRect(x: 40, y: 220, width: 90, height: 24), 0.0, 0.7, 0.3)   // button changes colour
            self.fill(c, CGRect(x: 300, y: 120, width: 50, height: 50), 0.9, 0.2, 0.2)  // badge added
        }
        return (old, new)
    }

    func testDesignStateRegionsAndSummary() throws {
        let (old, new) = try designPair()
        let r = try ImageCompare.compare(old: old, new: new)
        XCTAssertEqual(r.status, .different)
        XCTAssertEqual(r.regions.count, 3)
        // Reading order: headline strip, badge, button.
        XCTAssertEqual(r.regions.map { [$0.x, $0.y, $0.width, $0.height] },
                       [[220, 30, 20, 40], [300, 120, 50, 50], [40, 220, 90, 24]])
        XCTAssertEqual(r.regions.map(\.index), [1, 2, 3])
        XCTAssertEqual(r.regions[0].label, "Region 1 · 20 × 40 px")
        XCTAssertEqual(r.changedPixels, 20 * 40 + 50 * 50 + 90 * 24)
        XCTAssertEqual(r.changedFraction, Double(r.changedPixels) / Double(400 * 300), accuracy: 1e-12)
        XCTAssertTrue(r.summary.hasPrefix("3 regions changed"), r.summary)
        XCTAssertTrue(r.isComplete)
    }

    func testSidesAreDescribed() throws {
        let (old, new) = try designPair()
        let r = try ImageCompare.compare(old: old, new: new)
        XCTAssertEqual(r.old.width, 400); XCTAssertEqual(r.old.height, 300)
        XCTAssertEqual(r.old.byteSize, old.count); XCTAssertEqual(r.new.byteSize, new.count)
        XCTAssertEqual(r.old.format, "PNG"); XCTAssertEqual(r.old.typeIdentifier, "public.png")
        XCTAssertTrue(r.detail.hasPrefix("400 × 300 both · "), r.detail)
        let jpeg = try ImageCompare.compare(old: try image(10, 10, type: .jpeg), new: try image(10, 10, type: .jpeg) { c in
            self.fill(c, CGRect(x: 0, y: 0, width: 10, height: 10), 0, 0, 0)
        })
        XCTAssertEqual(jpeg.old.format, "JPEG")
    }

    func testSizeChangeWording() {
        XCTAssertEqual(ImageCompare.sizeChangeText(318_000, 296_000), "22 KB smaller")
        XCTAssertEqual(ImageCompare.sizeChangeText(1_000, 4_000), "3 KB larger")
        XCTAssertEqual(ImageCompare.sizeChangeText(5, 5), "")
    }

    func testDifferenceImage() throws {
        let (old, new) = try designPair()
        let r = try ImageCompare.compare(old: old, new: new)
        let png = try XCTUnwrap(r.differencePNG)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 400); XCTAssertEqual(decoded.height, 300)
        XCTAssertEqual(r.differenceScale, 1)

        let scaled = try ImageCompare.compare(old: old, new: new, limits: .init(maxDifferencePixels: 400 * 300 / 4))
        XCTAssertEqual(scaled.differenceScale, 2)
        let small = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(scaled.differencePNG) as CFData, nil)), 0, nil))
        XCTAssertEqual(small.width, 200)

        let none = try ImageCompare.compare(old: old, new: new, limits: .init(makeDifferenceImage: false))
        XCTAssertNil(none.differencePNG)
    }

    func testDimensionsDiffer() throws {
        let r = try ImageCompare.compare(old: try image(40, 30), new: try image(30, 40))
        XCTAssertEqual(r.status, .dimensionsDiffer)
        XCTAssertTrue(r.regions.isEmpty)
        XCTAssertNil(r.differencePNG)
        XCTAssertEqual(r.summary, "Dimensions differ: 40 × 30 → 30 × 40")
        XCTAssertTrue(r.detail.hasPrefix("40 × 30 → 30 × 40 · "))
    }

    func testIdenticalFilesAndIdenticalPixels() throws {
        let a = try image(20, 20)
        let same = try ImageCompare.compare(old: a, new: a)
        XCTAssertEqual(same.status, .identical)
        XCTAssertEqual(same.summary, "Identical files")
        let tiff = try image(20, 20, type: .tiff)
        let recoded = try ImageCompare.compare(old: a, new: tiff)
        XCTAssertEqual(recoded.status, .pixelsIdentical)
        XCTAssertTrue(recoded.summary.hasPrefix("Pixels identical"))
        XCTAssertTrue(recoded.regions.isEmpty)
        XCTAssertEqual(recoded.new.format, "TIFF")
    }

    func testThresholdIgnoresTinyShifts() throws {
        let a = try image(20, 20, background: CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        let b = try image(20, 20, background: CGColor(srgbRed: 0.52, green: 0.5, blue: 0.5, alpha: 1))
        XCTAssertEqual(try ImageCompare.compare(old: a, new: b).status, .pixelsIdentical)
        XCTAssertEqual(try ImageCompare.compare(old: a, new: b, limits: .init(threshold: 0)).regions.count, 1)
    }

    func testRegionsAreCappedByMerging() throws {
        let old = try image(600, 600)
        let new = try image(600, 600) { c in
            for k in 0..<12 {
                let x = (k % 4) * 150 + 20, y = (k / 4) * 200 + 20
                self.fill(c, CGRect(x: x, y: y, width: 10, height: 10), 0, 0, 0)
            }
        }
        let r = try ImageCompare.compare(old: old, new: new)
        XCTAssertEqual(r.regions.count, 8)
        XCTAssertEqual(r.changedPixels, 12 * 100)
        // Every changed pixel is still inside some region.
        for k in 0..<12 {
            let x = (k % 4) * 150 + 20, y = (k / 4) * 200 + 20
            XCTAssertTrue(r.regions.contains { x >= $0.x && y >= $0.y && x + 9 < $0.x + $0.width && y + 9 < $0.y + $0.height })
        }
        let three = try ImageCompare.compare(old: old, new: new, limits: .init(maxRegions: 3))
        XCTAssertEqual(three.regions.count, 3)
    }

    func testTooLargeIsDescribedNotCompared() throws {
        let r = try ImageCompare.compare(old: try image(100, 100), new: try image(100, 100) { c in
            self.fill(c, CGRect(x: 0, y: 0, width: 5, height: 5), 0, 0, 0)
        }, limits: .init(maxPixels: 5_000))
        XCTAssertEqual(r.status, .tooLarge)
        XCTAssertFalse(r.isComplete)
        XCTAssertNotNil(r.incompleteReason)
        XCTAssertTrue(r.regions.isEmpty)
        XCTAssertEqual(r.old.width, 100)
    }

    func testUnreadableSideIsNamed() throws {
        XCTAssertThrowsError(try ImageCompare.compare(old: try image(4, 4), new: Data("not an image".utf8))) { error in
            XCTAssertEqual((error as? CompareError)?.side, .new)
            XCTAssertEqual((error as? CompareError)?.kind, .malformed)
        }
    }

    func testResultIsCodable() throws {
        let (old, new) = try designPair()
        let r = try ImageCompare.compare(old: old, new: new)
        XCTAssertEqual(try JSONDecoder().decode(ImageComparison.self, from: try JSONEncoder().encode(r)), r)
    }
}
