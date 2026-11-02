import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bounds and tolerances for one image compare. roadmap: S-7
public struct ImageCompareLimits: Sendable, Equatable {
    /// Pixels of each side above which no pixels are compared (the sides are still described).
    public var maxPixels: Int
    /// A pixel counts as changed when any channel (premultiplied sRGB, 0–255) differs by more than this.
    public var threshold: Int
    /// Regions reported at most; nearby regions are merged until this many remain.
    public var maxRegions: Int
    /// Whether to make `differencePNG`.
    public var makeDifferenceImage: Bool
    /// Pixels of the difference image; a larger compare gets a difference image scaled down by a whole factor.
    public var maxDifferencePixels: Int

    public init(maxPixels: Int = 40_000_000, threshold: Int = 16, maxRegions: Int = 8, makeDifferenceImage: Bool = true,
                maxDifferencePixels: Int = 4_000_000) {
        self.maxPixels = max(1, maxPixels); self.threshold = min(254, max(0, threshold))
        self.maxRegions = max(1, maxRegions); self.makeDifferenceImage = makeDifferenceImage
        self.maxDifferencePixels = max(1, maxDifferencePixels)
    }

    public static let `default` = ImageCompareLimits()
}

/// Two images compared pixel by pixel (design/mockups/unified/diff.html, "Two images: 2-up / swipe / onion skin /
/// difference"): each side described (dimensions, bytes, format), and when the dimensions match, the changed pixels
/// grouped into at most a few rectangular regions in reading order. Regions carry geometry only; what changed in
/// them is for a person to say. roadmap: S-7
public struct ImageComparison: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Equatable, Codable {
        /// The files' bytes are equal.
        case identical
        /// Different files with the same pixels (re-encoded, metadata changed).
        case pixelsIdentical
        case different
        /// Different sizes: no pixel compare, no regions.
        case dimensionsDiffer
        /// A side is larger than `ImageCompareLimits.maxPixels`: described, not compared.
        case tooLarge
    }

    public struct ImageInfo: Sendable, Equatable, Codable {
        public var width: Int
        public var height: Int
        public var byteSize: Int
        /// "PNG", "JPEG", "HEIC" …
        public var format: String
        /// The uniform type identifier ImageIO read ("public.png").
        public var typeIdentifier: String
    }

    /// A changed area in pixels, top-left origin.
    public struct Region: Sendable, Equatable, Codable {
        /// 1-based, in reading order (top to bottom, then left to right).
        public var index: Int
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        /// "Region 1 · 680 × 160 px".
        public var label: String
    }

    public var old: ImageInfo
    public var new: ImageInfo
    public var status: Status
    public var regions: [Region]
    public var changedPixels: Int
    /// Changed pixels over all pixels (0…1); 0 when not compared.
    public var changedFraction: Double
    /// "3 regions changed, 22 KB smaller", "Dimensions differ: 1440 × 900 → 1280 × 800", "Identical files".
    public var summary: String
    /// "1440 × 900 both · 318 KB → 296 KB".
    public var detail: String
    /// |old − new| per channel, opaque, as PNG; nil when not made or not compared.
    public var differencePNG: Data?
    /// 1 when the difference image is full size, n when every n-th pixel was kept.
    public var differenceScale: Int
    public var isComplete: Bool
    public var incompleteReason: String?
}

/// The image compare engine. roadmap: S-7
public enum ImageCompare {
    public static func compare(old: Data, new: Data, limits: ImageCompareLimits = .default) throws -> ImageComparison {
        let a = try ImageSide(old, side: .old), b = try ImageSide(new, side: .new)
        let sizeChange = sizeChangeText(old.count, new.count)
        let sameSize = a.info.width == b.info.width && a.info.height == b.info.height
        let detail = sameSize
            ? String(localized: "\(dimensions(a.info)) both · \(bytes(old.count)) → \(bytes(new.count))", bundle: .module, comment: "Image compare detail: the shared pixel size such as 800 × 600, then the file sizes before and after.")
            : String(localized: "\(dimensions(a.info)) → \(dimensions(b.info)) · \(bytes(old.count)) → \(bytes(new.count))", bundle: .module, comment: "Image compare detail: the pixel sizes before and after, then the file sizes before and after.")
        var result = ImageComparison(old: a.info, new: b.info, status: .different, regions: [], changedPixels: 0,
                                     changedFraction: 0, summary: "", detail: detail, differencePNG: nil,
                                     differenceScale: 1, isComplete: true, incompleteReason: nil)
        if old == new {
            result.status = .identical
            result.summary = String(localized: "Identical files", bundle: .module, comment: "Summary line of an image compare.")
            return result
        }
        guard sameSize else {
            result.status = .dimensionsDiffer
            result.summary = String(localized: "Dimensions differ: \(dimensions(a.info)) → \(dimensions(b.info))", bundle: .module, comment: "Summary line of an image compare. The arguments are pixel sizes such as 800 × 600.")
            return result
        }
        let pixels = a.info.width * a.info.height
        guard pixels <= limits.maxPixels else {
            result.status = .tooLarge
            result.summary = withSizeChange(String(localized: "Too large to compare pixels", bundle: .module, comment: "Summary line of an image compare."), sizeChange)
            result.isComplete = false
            let mp = Double(pixels) / 1_000_000
            result.incompleteReason = String(localized: "each side is \(mp.formatted(.number.precision(.fractionLength(1)))) MP; pixels are compared up to \((Double(limits.maxPixels) / 1_000_000).formatted()) MP", bundle: .module, comment: "Why an image compare is incomplete; MP = megapixels; lower-case, no final period.")
            return result
        }
        let pa = try a.pixels(side: .old), pb = try b.pixels(side: .new)
        let map = PixelDiff.run(pa, pb, width: a.info.width, height: a.info.height, limits: limits)
        result.changedPixels = map.changed
        result.changedFraction = pixels > 0 ? Double(map.changed) / Double(pixels) : 0
        result.regions = map.boxes.enumerated().map { k, box in
            .init(index: k + 1, x: box.x0, y: box.y0, width: box.x1 - box.x0 + 1, height: box.y1 - box.y0 + 1,
                  label: String(localized: "Region \(k + 1) · \(box.x1 - box.x0 + 1) × \(box.y1 - box.y0 + 1) px", bundle: .module, comment: "Label of a changed region in an image compare: its number, then its width × height in pixels."))
        }
        if map.changed == 0 {
            result.status = .pixelsIdentical
            result.summary = withSizeChange(String(localized: "Pixels identical", bundle: .module, comment: "Summary line of an image compare. The files differ but every pixel is the same."), sizeChange)
        } else {
            let regions = result.regions.count
            result.summary = withSizeChange(regions == 1 ? String(localized: "1 region changed", bundle: .module, comment: "Summary line of an image compare.")
                : String(localized: "\(regions) regions changed", bundle: .module, comment: "Summary line of an image compare. The argument is how many regions (not 1)."), sizeChange)
            if limits.makeDifferenceImage {
                let scale = max(1, Int((Double(pixels) / Double(limits.maxDifferencePixels)).squareRoot().rounded(.up)))
                result.differencePNG = PixelDiff.differencePNG(pa, pb, width: a.info.width, height: a.info.height, scale: scale)
                result.differenceScale = scale
            }
        }
        return result
    }

    static func dimensions(_ info: ImageComparison.ImageInfo) -> String { "\(info.width) × \(info.height)" }

    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    /// "22 KB smaller", "3 KB larger", "" when the sizes match.
    static func sizeChangeText(_ old: Int, _ new: Int) -> String {
        guard old != new else { return "" }
        let amount = bytes(abs(old - new))
        return new < old ? String(localized: "\(amount) smaller", bundle: .module, comment: "How much smaller the new image file is, such as 22 KB smaller.")
            : String(localized: "\(amount) larger", bundle: .module, comment: "How much larger the new image file is, such as 3 KB larger.")
    }

    /// "Pixels identical, 22 KB smaller": a summary and the file size change, when there is one.
    static func withSizeChange(_ summary: String, _ sizeChange: String) -> String {
        sizeChange.isEmpty ? summary
            : String(localized: "\(summary), \(sizeChange)", bundle: .module, comment: "An image compare summary, then how the file size changed, such as 22 KB smaller.")
    }
}

/// One side, read with ImageIO: described from its properties first, decoded only when asked. roadmap: S-7
struct ImageSide {
    let source: CGImageSource
    let info: ImageComparison.ImageInfo

    init(_ data: Data, side: CompareSide) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else {
            throw CompareError(.malformed, side: side, reason: String(localized: "not an image this Mac can read", bundle: .module, comment: "A compare could not start: lower-case reason."))
        }
        let uti = CGImageSourceGetType(source) as String? ?? "public.image"
        let type = UTType(uti)
        let format = (type?.preferredFilenameExtension ?? type?.localizedDescription ?? "image").uppercased()
        self.source = source
        info = .init(width: width, height: height, byteSize: data.count, format: format, typeIdentifier: uti)
    }

    /// RGBA, 8 bits per channel, premultiplied, in sRGB, rows top to bottom.
    func pixels(side: CompareSide) throws -> [UInt8] {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CompareError(.malformed, side: side, reason: String(localized: "the image could not be decoded", bundle: .module, comment: "A compare could not start: lower-case reason."))
        }
        let width = info.width, height = info.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw CompareError(.malformed, side: side, reason: String(localized: "the image could not be decoded", bundle: .module, comment: "A compare could not start: lower-case reason.")) }
        return buffer
    }
}

/// The per-pixel difference, its regions and its picture. roadmap: S-7
enum PixelDiff {
    /// A box in pixels, inclusive.
    struct Box: Equatable {
        var x0: Int, y0: Int, x1: Int, y1: Int
        var area: Int { (x1 - x0 + 1) * (y1 - y0 + 1) }
        func union(_ o: Box) -> Box { Box(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1)) }
        /// Overlapping or touching.
        func meets(_ o: Box) -> Bool { x0 <= o.x1 + 1 && o.x0 <= x1 + 1 && y0 <= o.y1 + 1 && o.y0 <= y1 + 1 }
    }

    struct Map {
        var changed: Int
        var boxes: [Box]
    }

    /// Changed pixels are gathered into a coarse grid (about 256 cells on the long side); changed cells within two
    /// cells of each other join one region, each region's box is tightened to its changed pixels, touching boxes
    /// merge, and while more than `maxRegions` remain the pair whose union grows least is merged.
    static func run(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, limits: ImageCompareLimits) -> Map {
        let cell = max(4, (max(width, height) + 255) / 256)
        let gw = (width + cell - 1) / cell, gh = (height + cell - 1) / cell
        var cellBox = [Box?](repeating: nil, count: gw * gh)
        var changed = 0
        let threshold = limits.threshold
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for y in 0..<height {
                    let row = y * width * 4
                    let gy = y / cell
                    for x in 0..<width {
                        let p = row + x * 4
                        let d = max(max(abs(Int(pa[p]) - Int(pb[p])), abs(Int(pa[p + 1]) - Int(pb[p + 1]))),
                                    max(abs(Int(pa[p + 2]) - Int(pb[p + 2])), abs(Int(pa[p + 3]) - Int(pb[p + 3]))))
                        guard d > threshold else { continue }
                        changed += 1
                        let g = gy * gw + x / cell
                        if let box = cellBox[g] {
                            cellBox[g] = Box(x0: min(box.x0, x), y0: min(box.y0, y), x1: max(box.x1, x), y1: max(box.y1, y))
                        } else {
                            cellBox[g] = Box(x0: x, y0: y, x1: x, y1: y)
                        }
                    }
                }
            }
        }
        guard changed > 0 else { return Map(changed: 0, boxes: []) }

        // Connected changed cells (Chebyshev distance ≤ 2), iteratively.
        var seen = [Bool](repeating: false, count: gw * gh)
        var boxes: [Box] = []
        for start in 0..<(gw * gh) where cellBox[start] != nil && !seen[start] {
            var stack = [start]
            seen[start] = true
            var box = cellBox[start]!
            while let g = stack.popLast() {
                let gx = g % gw, gy = g / gw
                for ny in max(0, gy - 2)...min(gh - 1, gy + 2) {
                    for nx in max(0, gx - 2)...min(gw - 1, gx + 2) {
                        let n = ny * gw + nx
                        guard !seen[n], let other = cellBox[n] else { continue }
                        seen[n] = true
                        box = box.union(other)
                        stack.append(n)
                    }
                }
            }
            boxes.append(box)
        }

        // Touching boxes merge; then the cheapest merges until few enough remain.
        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<boxes.count {
                for j in (i + 1)..<boxes.count where boxes[i].meets(boxes[j]) {
                    boxes[i] = boxes[i].union(boxes[j]); boxes.remove(at: j); merged = true
                    break outer
                }
            }
        }
        while boxes.count > limits.maxRegions {
            var best = (0, 1), bestCost = Int.max
            for i in 0..<boxes.count {
                for j in (i + 1)..<boxes.count {
                    let cost = boxes[i].union(boxes[j]).area - boxes[i].area - boxes[j].area
                    if cost < bestCost { bestCost = cost; best = (i, j) }
                }
            }
            boxes[best.0] = boxes[best.0].union(boxes[best.1])
            boxes.remove(at: best.1)
        }
        boxes.sort { ($0.y0, $0.x0) < ($1.y0, $1.x0) }
        return Map(changed: changed, boxes: boxes)
    }

    /// |old − new| per channel, opaque, every `scale`-th pixel, as PNG.
    static func differencePNG(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, scale: Int) -> Data? {
        let w = (width + scale - 1) / scale, h = (height + scale - 1) / scale
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let p = ((y * scale) * width + x * scale) * 4, q = (y * w + x) * 4
                for c in 0..<3 { out[q + c] = UInt8(abs(Int(a[p + c]) - Int(b[p + c]))) }
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let image: CGImage? = out.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        guard let image else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
