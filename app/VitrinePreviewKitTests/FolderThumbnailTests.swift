import AppKit
import XCTest
@testable import VitrinePreviewKit

/// The folder icon with its newest items drawn on it (O-3). Only the drawing is tested here; whether Finder asks a
/// thumbnail extension for folders is measured on the installed app. All content is invented here. roadmap: S-9, S-18
final class FolderThumbnailTests: XCTestCase {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-thumb-\(UUID().uuidString)/Lumen trip")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        return dir
    }

    private func png(_ url: URL, red: CGFloat) throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: red, green: 0.4, blue: 0.6, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage())).representation(using: .png, properties: [:])).write(to: url)
    }

    func testTheNewestThreeItemsAreChosenPicturesAsThemselves() throws {
        let dir = try folder()
        let names = ["old-notes.txt", "harbor.png", "packing.txt", "kyoto.png"]
        for (i, name) in names.enumerated() {
            let url = dir.appendingPathComponent(name)
            if name.hasSuffix(".png") { try png(url, red: CGFloat(i) / 4) } else { try "Packing list".write(to: url, atomically: true, encoding: .utf8) }
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 60)], ofItemAtPath: url.path)
        }
        try "hidden".write(to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        let items = FolderThumbnail.items(in: dir)
        XCTAssertEqual(items.map(\.name), ["kyoto.png", "packing.txt", "harbor.png"], "newest first, hidden skipped, three at most")
        XCTAssertEqual(items.map(\.isPreview), [true, false, true])
    }

    func testDrawingFillsTheIconAndAnEmptyFolderIsThePlainFolder() throws {
        let dir = try folder()
        try png(dir.appendingPathComponent("harbor.png"), red: 0.9)
        func render(_ items: [FolderThumbnail.Item]) throws -> NSBitmapImageRep {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
                                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let ctx = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
            FolderThumbnail.draw(items, in: ctx, size: CGSize(width: 256, height: 256))
            return rep
        }
        let plain = try render([])
        let withCards = try render(FolderThumbnail.items(in: dir))
        XCTAssertGreaterThan(plain.colorAt(x: 128, y: 160)?.alphaComponent ?? 0, 0.5, "the folder is drawn")
        XCTAssertNotEqual(plain.tiffRepresentation, withCards.tiffRepresentation, "the card changes the drawing")
    }
}
