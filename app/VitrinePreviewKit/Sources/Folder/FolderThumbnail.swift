import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A folder's Finder icon with what is inside drawn on it (O-3): the system folder, and on its front up to three cards
/// for the most recently changed items — a picture's own pixels, any other item's icon. Read with a small budget
/// (the folder's listing and at most three images, each decoded at icon size), so a folder of any size draws at once;
/// an empty folder, or one that cannot be read, is the plain folder. Thumbnails use the light look in both Finder
/// appearances, as the thumbnail design rules (one cached image serves both). roadmap: S-9, S-18
public enum FolderThumbnail {
    /// How the items stand on the folder (G-18's look, the maintainer's visual call): a fan of three cards, the newest item
    /// alone and large, or a grid of the four newest.
    public enum Style: String, CaseIterable, Sendable {
        case fan, front, grid
        /// How many items the look shows.
        public var itemCount: Int { switch self { case .fan: 3; case .front: 1; case .grid: 4 } }
    }

    public struct Item {
        public let name: String
        public let image: CGImage
        /// A picture of the file itself (an image), not its kind's icon.
        public let isPreview: Bool
    }

    /// Items the thumbnail shows, newest first; hidden items and packages' insides are skipped.
    public static func items(in folder: URL, limit: Int = 3, pixelSize: Int = 256) -> [Item] {
        let keys: [URLResourceKey] = [.isHiddenKey, .contentModificationDateKey, .isDirectoryKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        // Only the first 500 names are weighed: a huge folder draws as quickly as a small one.
        let dated = urls.prefix(500).map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        return dated.prefix(limit).compactMap { url, _ in
            if let picture = picture(url, pixelSize: pixelSize) { return Item(name: url.lastPathComponent, image: picture, isPreview: true) }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            var rect = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
            guard let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
            return Item(name: url.lastPathComponent, image: cg, isPreview: false)
        }
    }

    /// An image file decoded at icon size (ImageIO's thumbnail, never the full picture); nil for anything else.
    static func picture(_ url: URL, pixelSize: Int) -> CGImage? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
              (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 < 64 << 20,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// Draws the folder and its cards into `context` (origin bottom-left, `size` in points).
    public static func draw(_ items: [Item], in context: CGContext, size: CGSize, style: Style = .fan) {
        let side = min(size.width, size.height)
        let frame = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        let folder = NSWorkspace.shared.icon(for: .folder)
        var rect = CGRect(origin: .zero, size: frame.size)
        if let cg = folder.cgImage(forProposedRect: &rect, context: nil, hints: nil) { context.draw(cg, in: frame) }
        // Below 48 pixels (Finder's 16 pt list rows, and 32 pt without Retina) there is no room for cards: the folder
        // alone reads best.
        guard !items.isEmpty, side >= 48 else { return }
        switch style {
        case .fan: break
        case .front: return drawFront(items[0], in: context, frame: frame)
        case .grid: return drawGrid(Array(items.prefix(4)), in: context, frame: frame)
        }
        // The folder's front face sits in roughly its lower 70 %; the cards stand in it, overlapping like a fan.
        let card = side * 0.36
        let baseY = frame.minY + side * 0.2
        let count = items.count
        for (i, item) in items.enumerated().reversed() {
            let offset = CGFloat(i) - CGFloat(count - 1) / 2
            let x = frame.midX - card / 2 + offset * card * 0.62
            let y = baseY + abs(offset) * side * 0.02
            context.saveGState()
            context.translateBy(x: x + card / 2, y: y + card / 2)
            context.rotate(by: -offset * 0.12)
            let r = CGRect(x: -card / 2, y: -card / 2, width: card, height: card * 1.18)
            if item.isPreview {
                // A photo or picture: on a white card with a soft shadow, fitted.
                context.setShadow(offset: CGSize(width: 0, height: -side * 0.01), blur: side * 0.03,
                                  color: CGColor(gray: 0, alpha: 0.28))
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.addPath(CGPath(roundedRect: r, cornerWidth: side * 0.02, cornerHeight: side * 0.02, transform: nil))
                context.fillPath()
                context.setShadow(offset: .zero, blur: 0)
                let inset = r.insetBy(dx: card * 0.06, dy: card * 0.06)
                context.draw(item.image, in: aspectFit(item.image, in: inset))
            } else {
                context.setShadow(offset: CGSize(width: 0, height: -side * 0.008), blur: side * 0.02,
                                  color: CGColor(gray: 0, alpha: 0.22))
                context.draw(item.image, in: CGRect(x: -card / 2, y: -card / 2, width: card, height: card))
            }
            context.restoreGState()
        }
    }

    /// The newest item alone, large, standing in the folder's front face.
    static func drawFront(_ item: Item, in context: CGContext, frame: CGRect) {
        let side = frame.width
        context.saveGState()
        if item.isPreview {
            let w = side * 0.56, h = side * 0.46
            let r = CGRect(x: frame.midX - w / 2, y: frame.minY + side * 0.19, width: w, height: h)
            context.setShadow(offset: CGSize(width: 0, height: -side * 0.01), blur: side * 0.035, color: CGColor(gray: 0, alpha: 0.3))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(CGPath(roundedRect: r, cornerWidth: side * 0.025, cornerHeight: side * 0.025, transform: nil))
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0)
            let inner = r.insetBy(dx: side * 0.025, dy: side * 0.025)
            context.addPath(CGPath(roundedRect: inner, cornerWidth: side * 0.012, cornerHeight: side * 0.012, transform: nil))
            context.clip()
            context.draw(item.image, in: aspectFill(item.image, in: inner))
        } else {
            let s = side * 0.5
            context.setShadow(offset: CGSize(width: 0, height: -side * 0.008), blur: side * 0.025, color: CGColor(gray: 0, alpha: 0.25))
            context.draw(item.image, in: CGRect(x: frame.midX - s / 2, y: frame.minY + side * 0.16, width: s, height: s))
        }
        context.restoreGState()
    }

    /// The four newest items as square tiles, two by two, in the folder's front face.
    static func drawGrid(_ items: [Item], in context: CGContext, frame: CGRect) {
        let side = frame.width
        let tile = side * 0.255, gap = side * 0.022
        let left = frame.midX - tile - gap / 2, bottom = frame.minY + side * 0.15
        for (i, item) in items.enumerated() {
            let col = CGFloat(i % 2), row = CGFloat(1 - i / 2)
            let r = CGRect(x: left + col * (tile + gap), y: bottom + row * (tile + gap), width: tile, height: tile)
            context.saveGState()
            if item.isPreview {
                context.setShadow(offset: CGSize(width: 0, height: -side * 0.006), blur: side * 0.018, color: CGColor(gray: 0, alpha: 0.28))
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                let path = CGPath(roundedRect: r, cornerWidth: side * 0.02, cornerHeight: side * 0.02, transform: nil)
                context.addPath(path); context.fillPath()
                context.setShadow(offset: .zero, blur: 0)
                let inner = r.insetBy(dx: side * 0.012, dy: side * 0.012)
                context.addPath(CGPath(roundedRect: inner, cornerWidth: side * 0.012, cornerHeight: side * 0.012, transform: nil))
                context.clip()
                context.draw(item.image, in: aspectFill(item.image, in: inner))
            } else {
                context.setFillColor(CGColor(gray: 1, alpha: 0.55))
                context.addPath(CGPath(roundedRect: r, cornerWidth: side * 0.02, cornerHeight: side * 0.02, transform: nil))
                context.fillPath()
                context.setShadow(offset: CGSize(width: 0, height: -side * 0.004), blur: side * 0.01, color: CGColor(gray: 0, alpha: 0.2))
                context.draw(item.image, in: r.insetBy(dx: tile * 0.1, dy: tile * 0.1))
            }
            context.restoreGState()
        }
    }

    static func aspectFill(_ image: CGImage, in rect: CGRect) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return rect }
        let scale = max(rect.width / w, rect.height / h)
        let size = CGSize(width: w * scale, height: h * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func aspectFit(_ image: CGImage, in rect: CGRect) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return rect }
        let scale = min(rect.width / w, rect.height / h)
        let size = CGSize(width: w * scale, height: h * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}
