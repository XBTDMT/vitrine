import AppKit
import VitrineDocument
import VitrineUI
import WebKit

/// What the picture sits on, picked in the Inspector's Background control and remembered (`svg.background`).
enum SVGBackground: Int, CaseIterable, Sendable {
    case checker, light, dark

    static let key = "svg.background"
    var title: String {
        switch self {
        case .checker: String(localized: "Checker", bundle: .previewKit, comment: "SVG background choice: a transparency checkerboard.")
        case .light: String(localized: "Light", bundle: .previewKit, comment: "SVG background choice: a light ground.")
        case .dark: String(localized: "Dark", bundle: .previewKit, comment: "SVG background choice: a dark ground.")
        }
    }
}

/// The ground under the picture: the transparency checkerboard in `checker1`/`checker2` (5 pt squares, the design's
/// `.chk-bg`), or the light or dark `page` colour whatever the system appearance. Drawn in `draw(_:)`, where the
/// token colours resolve for the view's own appearance. roadmap: S-6
@MainActor
final class SVGCanvas: NSView {
    static let square: CGFloat = 5

    var background: SVGBackground = .checker { didSet { needsDisplay = true } }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        switch background {
        case .light, .dark:
            let page = GeneratedTokens.color("page")
            let css = background == .light ? page?.light : page?.dark
            (css.flatMap { NSColor(css: $0) } ?? .windowBackgroundColor).setFill()
            dirtyRect.fill()
        case .checker:
            NSColor.token("checker1").setFill()
            dirtyRect.fill()
            NSColor.token("checker2").setFill()
            let s = Self.square
            let x0 = Int((dirtyRect.minX / s).rounded(.down)), x1 = Int((dirtyRect.maxX / s).rounded(.up))
            let y0 = Int((dirtyRect.minY / s).rounded(.down)), y1 = Int((dirtyRect.maxY / s).rounded(.up))
            let squares = NSBezierPath()
            for y in y0..<max(y0, y1) {
                for x in x0..<max(x0, x1) where (x + y) % 2 != 0 {
                    squares.appendRect(NSRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s))
                }
            }
            squares.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The picture: a transparent WKWebView over the canvas, showing the file as an `<img>` (G-12). JavaScript is off,
/// the G-9 content rule list and a CSP allow nothing but the inline `data:` image, the data store is ephemeral, and
/// any navigation after the first load is cancelled, so a link or a drag inside the picture cannot open anything.
/// roadmap: S-6
@MainActor
final class SVGPicture: NSObject, WKNavigationDelegate, WKUIDelegate {
    enum Outcome: Equatable { case drawn, refused(Badge) }

    let canvas = SVGCanvas()
    private(set) var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Never>?
    private var pageLoaded = false
    private var terminated = false

    /// The page for `data`; `padding` keeps the picture off the panel's edges.
    static var notDrawn: String {
        String(localized: "Picture not drawn", bundle: .previewKit, comment: "SVG warning title: the picture could not be drawn, so the source shows.")
    }

    static func page(for data: Data, padding: CGFloat) -> String {
        let pad = Int(padding)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>
        html, body { margin: 0; height: 100%; background: transparent; overflow: hidden; }
        img { position: absolute; left: \(pad)px; top: \(pad)px; width: calc(100% - \(2 * pad)px); height: calc(100% - \(2 * pad)px);
              object-fit: contain; -webkit-user-drag: none; user-select: none; }
        </style></head>
        <body><img alt="" src="data:image/svg+xml;base64,\(data.base64EncodedString())"></body></html>
        """
    }

    /// Builds the locked web view, loads the picture and waits (bounded) for WebKit to finish.
    func draw(_ data: Data) async -> Outcome {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = false
        config.websiteDataStore = .nonPersistent()
        do {
            try await PageLockdown.apply(to: config)
        } catch {
            SVGRenderer.log.error("picture not locked down; not drawn")
            return .refused(Badge(level: .caution, title: Self.notDrawn,
                                  detail: String(localized: "The picture could not be locked down against loading anything, so only its source is shown.",
                                                 bundle: .previewKit, comment: "SVG warning detail: the network block failed, so the picture is not drawn.")))
        }
        let web = WKWebView(frame: canvas.bounds, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.allowsMagnification = true
        web.allowsBackForwardNavigationGestures = false
        web.autoresizingMask = [.width, .height]
        web.setAccessibilityLabel(String(localized: "Picture", bundle: .previewKit, comment: "Accessibility label: an SVG drawn as a picture."))
        canvas.addSubview(web)
        webView = web
        web.loadHTMLString(Self.page(for: data, padding: Metric.value("sp-32")), baseURL: nil)

        let waiter = Task { @MainActor [weak self] in
            try? await Task.sleep(for: SVGRenderer.Limits.loadWait)
            self?.finishWaiting()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if pageLoaded { c.resume() } else { loaded = c }
        }
        waiter.cancel()

        // A page process that ended (in a sandbox without WebKit's permission it is killed at launch, G-9) drew
        // nothing; say so rather than show an empty ground.
        if terminated {
            web.removeFromSuperview()
            webView = nil
            return .refused(Badge(level: .caution, title: Self.notDrawn,
                                  detail: String(localized: "WebKit stopped before drawing the picture, so its source is shown.", bundle: .previewKit,
                                                 comment: "SVG warning detail: the web view's process ended before drawing.")))
        }
        // WebKit shows a file it could not read as a broken image: complete, with no natural size. Ask from the
        // app's own script world (the page's JavaScript is off).
        let natural = try? await web.callAsyncJavaScript(
            "const i = document.images[0]; return i ? [i.complete ? 1 : 0, i.naturalWidth, i.naturalHeight] : [];",
            contentWorld: .defaultClient) as? [NSNumber]
        if let n = natural, n.count == 3, n[0].intValue == 1, n[1].intValue == 0, n[2].intValue == 0 {
            web.removeFromSuperview()
            webView = nil
            return .refused(Badge(level: .caution, title: Self.notDrawn,
                                  detail: String(localized: "WebKit could not draw this file as an image, so its source is shown.", bundle: .previewKit,
                                                 comment: "SVG warning detail: the file did not draw as an image.")))
        }
        return .drawn
    }

    private func finishWaiting() {
        pageLoaded = true
        loaded?.resume()
        loaded = nil
    }

    /// The picture's own load is the only navigation; anything after it (a link, a dropped file) is cancelled.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if !pageLoaded, navigationAction.targetFrame?.isMainFrame == true, navigationAction.request.url?.absoluteString == "about:blank" {
            return .allow
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishWaiting() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishWaiting() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishWaiting() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        SVGRenderer.log.error("picture process ended")
        if !pageLoaded { terminated = true }
        finishWaiting()
    }

    /// No new windows, ever.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}
