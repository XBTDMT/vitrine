import AppKit
import WebKit

/// Beautiful export (I-10, chrome r3-b's copy menu): any preview as a picture (copied, or saved as PNG) and as a PDF,
/// drawn exactly as it is on screen; Markdown also as a standalone HTML page (MarkdownRenderer.exportHTML). The same
/// picture path serves `Vitrine --snapshot` (PreviewSnapshot). roadmap: S-24
@MainActor
public enum PreviewExport {
    public enum Format: String, CaseIterable, Sendable {
        case pdf, html, png
        public var fileExtension: String { rawValue }
    }

    /// The view and everything in it as drawn: the native views through `cacheDisplay`, a web view's page painted on
    /// top from its own snapshot (a page does not draw through `cacheDisplay`).
    public static func image(of root: NSView) async throws -> NSImage {
        root.layoutSubtreeIfNeeded()
        guard root.bounds.width > 0, root.bounds.height > 0,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw RenderError.cancelled }
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = NSImage(size: root.bounds.size)
        image.addRepresentation(rep)
        if let web = webView(in: root), !web.isHidden {
            let config = WKSnapshotConfiguration(); config.rect = web.bounds
            let page = try await web.takeSnapshot(configuration: config)
            let frame = web.convert(web.bounds, to: root)
            image.lockFocusFlipped(root.isFlipped)
            page.draw(in: frame)
            image.unlockFocus()
        }
        return image
    }

    public static func png(of root: NSView) async throws -> Data {
        let image = try await image(of: root)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw RenderError.cancelled }
        return png
    }

    /// Copies the picture as PNG and TIFF, so every app can paste it.
    public static func copyImage(of root: NSView, to pasteboard: NSPasteboard) async -> Bool {
        guard let png = try? await png(of: root) else { return false }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        return true
    }

    /// A PDF of the preview. A web page is printed onto pages in its own colours; a native view is one page as drawn.
    /// The menu offers it only for documents whose page holds the whole file (Markdown): the code view, big diffs and
    /// tables draw only what is in view, so their PDF would be a fragment.
    public static func pdf(of root: NSView, to url: URL) async throws {
        if let web = webView(in: root), !web.isHidden, let window = web.window {
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
            // The page's own background and theme colours go onto the paper too.
            web.configuration.preferences.shouldPrintBackgrounds = true
            let operation = web.printOperation(with: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.view?.frame = web.bounds
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                let delegate = PrintDone { success in
                    success ? done.resume() : done.resume(throwing: RenderError.cancelled)
                }
                operation.runModal(for: window, delegate: delegate,
                                   didRun: #selector(PrintDone.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
                objc_setAssociatedObject(operation, &PrintDone.key, delegate, .OBJC_ASSOCIATION_RETAIN)
            }
            guard FileManager.default.fileExists(atPath: url.path) else { throw RenderError.cancelled }
            return
        }
        root.layoutSubtreeIfNeeded()
        try root.dataWithPDF(inside: root.bounds).write(to: url, options: .atomic)
    }

    static func webView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews { if let web = webView(in: sub) { return web } }
        return nil
    }
}

/// The print operation's completion, as a callback.
private final class PrintDone: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    let finish: (Bool) -> Void
    init(_ finish: @escaping (Bool) -> Void) { self.finish = finish }
    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) { finish(success) }
}
