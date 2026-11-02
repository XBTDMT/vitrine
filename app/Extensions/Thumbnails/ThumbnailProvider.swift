import QuickLookThumbnailing
import VitrinePreviewKit
import VitrineThumbnail

/// Finder's thumbnails for the text files Vitrine understands (S-18, thumbnails r3-a). The drawing is
/// VitrineThumbnail's; folders reach Finder's icon through FolderContentIcons (G-18), since Quick Look never asks a
/// thumbnail extension for a folder. With the switch off in Settings, macOS draws what it would without Vitrine.
/// roadmap: S-18
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard ThumbnailSettings.isOn else { return handler(nil, CocoaError(.featureUnsupported)) }
        // A file it cannot read still gets a sheet: an error sends the type to another drawer for as long as Quick
        // Look's agent runs (SP-6).
        let page = (try? ThumbnailPage.make(url: request.fileURL)) ?? ThumbnailPage.placeholder(for: request.fileURL)
        let size = request.maximumSize
        let reply = QLThumbnailReply(contextSize: size) { context in
            // Quick Look hands over a bitmap in pixels (measured 2026-11-01: a 256 pt request at 2x is a 512 px
            // context with an identity transform); the drawing is in points.
            let scale = context.width > 0 ? CGFloat(context.width) / size.width : 1
            if scale > 1.01 { context.scaleBy(x: scale, y: scale) }
            ThumbnailRenderer.draw(page, in: context, size: size)
            return true
        }
        // macOS draws the type label from 64 pt (r3-a); the glyph already names the type below that.
        if min(size.width, size.height) >= 64 { reply.extensionBadge = page.badge }
        handler(reply, nil)
    }
}
