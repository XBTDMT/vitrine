import AppKit
import QuickLookThumbnailing
import VitrineUI

/// Small rendered pictures for the recent rows: QLThumbnailGenerator in the host app (not sandboxed, so any path the
/// extensions recorded can be read), drawn on the design's plate: `--v-page` ground, `--v-hair` edge, radius 6,
/// 32 × 24. Until a thumbnail arrives the row shows the file's Finder icon on the same plate. roadmap: S-10 (H-2)
@MainActor
final class MenuBarThumbnails {
    private var cache: [String: NSImage] = [:]
    private var pending: Set<String> = []

    /// The picture for a file now (cached thumbnail, else its icon on the plate); `update` gets the thumbnail when
    /// it is made, on the main actor.
    func image(for url: URL, update: @escaping @MainActor (NSImage) -> Void) -> NSImage {
        let key = Self.key(for: url)
        if let hit = cache[key] { return hit }
        let placeholder = Self.plate(content: NSWorkspace.shared.icon(forFile: url.path), isIcon: true)
        guard !pending.contains(key) else { return placeholder }
        pending.insert(key)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 48, height: 48),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            let image = rep?.nsImage
            Task { @MainActor in
                guard let self else { return }
                self.pending.remove(key)
                guard let image else { return }
                let plated = Self.plate(content: image, isIcon: false)
                self.cache[key] = plated
                update(plated)
            }
        }
        return placeholder
    }

    /// Path plus modification date, so an edited file gets a new picture.
    static func key(for url: URL) -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)#\(modified)"
    }

    /// Drawn on demand, so the plate follows light and dark like the menu does. A thumbnail fills the plate from its
    /// top (the start of the page shows); an icon sits centred at 20 pt.
    static func plate(content: NSImage, isIcon: Bool) -> NSImage {
        let size = MenuBarMetrics.thumbnail
        let image = NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
            NSColor.token("page").setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let source = content.size
            if isIcon || source.width <= 0 || source.height <= 0 {
                let side: CGFloat = 20
                content.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
            } else {
                let scale = max(rect.width / source.width, rect.height / source.height)
                let w = source.width * scale, h = source.height * scale
                content.draw(in: NSRect(x: rect.midX - w / 2, y: rect.maxY - h, width: w, height: h))
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.token("hair").setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
            return true
        }
        image.accessibilityDescription = nil
        return image
    }
}
