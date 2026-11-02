import AppKit
import OSLog
import UniformTypeIdentifiers
import VitrineDocument
import VitrineSupport
import VitrineText
import VitrineTrust
import VitrineTokenizers
import VitrineUI
import WebKit

/// Markdown family: cmark-gfm HTML inside a WKWebView styled from the design tokens and the chosen Markdown theme.
/// The page is built from a template in Resources/web/markdown.html with the CSS variables, TOC and body injected;
/// live reload swaps the body through JavaScript so the scroll position survives and nothing flickers. The article
/// starts veiled and is revealed only after the remembered scroll position is applied, so there is no jump.
/// JavaScript reports scroll offsets and the TOC width back through one `vitrine` message handler.
@MainActor
public final class MarkdownRenderer: NSObject, Renderer, WKNavigationDelegate, WKScriptMessageHandler {
    public static func canRender(_ kind: FileKind) -> Bool {
        // Every dialect: MarkdownDialects turns MDX, MDC, Quarto, R Markdown, reST, AsciiDoc and Org into Markdown (M-11).
        if case .markdown = kind { return true }
        return false
    }

    public enum Keys {
        public static let theme = "markdown.theme", toc = "markdown.tocEnabled", tocWidth = "markdown.tocWidth", hideFrontMatter = "markdown.hideFrontMatter"
        public static let textScale = "markdown.textScale"
        /// Diagram colours (H-1): "theme" follows the page; "light" and "dark" draw diagrams in the theme's light or
        /// dark colours whatever the page's appearance.
        public static let diagramTheme = "markdown.diagramTheme"
        public static let math = "markdown.mathEnabled", emoji = "markdown.emojiEnabled", smart = "markdown.smartPunctuation", imageMaxWidth = "markdown.imageMaxWidth"
    }

    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Never>?
    private var lastScroll: Double = 0
    private var defaultsSuite: String?
    /// Kept for redrawing the page in place when "Aa" changes the theme or the text size.
    private var lastDocument: PreviewDocument?
    private var lastContext: RenderContext?
    private var schemeHandler: PreviewSchemeHandler?
    private var diagramCache = MermaidCache.standard
    /// The cache keys handed to the page on screen, each bound to its diagram's source (S-16 F52).
    private var diagramTickets = MermaidTickets()
    /// A rules file's Agent view is on screen in place of the rendered body (A-3).
    private var showingAgent = false
    /// Counts only (milliseconds and a diagram count), never content.
    private static let log = Logger(subsystem: "io.github.xbtdmt.vitrine", category: "markdown")

    /// The last page's diagram timings, ms from finding the diagrams: script loaded, first diagram, all drawn.
    public struct MermaidTiming: Sendable, Equatable { public let load, first, total, count: Int }
    public private(set) var lastMermaidTiming: MermaidTiming?

    public override required init() { super.init() }

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        defaultsSuite = context.defaultsSuite
        if let dir = context.cachesDirectory { diagramCache = MermaidCache(directory: dir.appendingPathComponent("mermaid")) }
        let document = try Self.document(url: url, kind: kind, context: context)
        lastDocument = document
        lastContext = context
        let page = Self.buildPage(for: document, context: context, cache: diagramCache, tickets: &diagramTickets)
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let schemeHandler = PreviewSchemeHandler(documentRoot: url.deletingLastPathComponent())
        self.schemeHandler = schemeHandler
        config.setURLSchemeHandler(schemeHandler, forURLScheme: PreviewSchemeHandler.scheme)
        try await PageLockdown.apply(to: config)
        config.userContentController.add(WeakHandler(self), name: "vitrine")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        let theme = Self.theme(context)
        webView.underPageBackgroundColor = NSColor(css: theme.background(for: context.appearance)) ?? .textBackgroundColor
        self.webView = webView
        webView.loadHTMLString(page, baseURL: PreviewSchemeHandler.documentBase)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in loaded = c }
        fillExactTokens(document, url: url, context: context)
        // The controller applies scroll memory synchronously after this returns; the reveal runs after that.
        Task { @MainActor [weak webView] in _ = try? await webView?.evaluateJavaScript("window.vitrine.reveal();") }

        var toggleColumn: (@MainActor () -> Void)?
        if Self.hasColumn(document, context: context) {
            toggleColumn = { [weak webView] in
                Task { _ = try? await webView?.evaluateJavaScript("window.vitrine.toggleColumn(); true") }
            }
        }
        var agentSwitch: (@MainActor (Int) -> Bool)?
        if Self.agentView(in: document) != nil {
            agentSwitch = { [weak self] index in self?.showAgentView(index) ?? false }
        }
        return RenderedPreview(view: webView, document: document, owner: self,
            reload: { [weak self] url in
                let fresh = try Self.document(url: url, kind: kind, context: context)
                guard let self, let webView = self.webView, let html = Self.markdown(in: fresh)?.html else { return fresh }
                self.lastDocument = fresh
                let body: String
                if self.showingAgent { body = Self.agentView(in: fresh)?.html ?? html; self.diagramTickets = MermaidTickets() }
                else { body = Self.withCachedDiagrams(html, context: context, cache: self.diagramCache, tickets: &self.diagramTickets) }
                let json = try String(decoding: JSONEncoder().encode(body), as: UTF8.self)
                _ = try? await webView.evaluateJavaScript("window.vitrine.replaceBody(\(json));")
                return fresh
            },
            scrollOffset: { [weak self] in self?.lastScroll },
            restoreScroll: { [weak self] y in
                self?.lastScroll = y
                Task { _ = try? await webView.evaluateJavaScript("window.vitrine.reveal(\(y));") }
            },
            toggleInspector: toggleColumn,
            find: { [weak webView] query, forward in
                guard let webView else { return FindResult(count: 0, index: -1) }
                let r = try? await webView.callAsyncJavaScript("return window.vitrine.find(q, f);", arguments: ["q": query, "f": forward],
                                                               contentWorld: .page) as? [String: Any]
                let found = PageNumbers.matches(r)
                return FindResult(count: found.count, index: found.index)
            },
            clearFind: { [weak webView] in Task { _ = try? await webView?.evaluateJavaScript("window.vitrine.clearFind()") } },
            showView: agentSwitch)
    }

    /// The document a Markdown file previews as: the rendered body and source, plus a rules file's agent facts and
    /// Agent view (A-3).
    static func document(url: URL, kind: FileKind, context: RenderContext) throws -> PreviewDocument {
        let document = try MarkdownDocument.make(url: url, kind: kind, options: options(context), mask: { LensPolicy.masked($0, kind: kind).text })
        return RulesFacts.apply(to: document, url: url)
    }

    /// A rules file's Agent view, nil for any other Markdown.
    static func agentView(in document: PreviewDocument) -> MarkdownContent? {
        guard let titles = document.viewTitles, let index = titles.firstIndex(of: RulesFacts.agentViewTitle),
              document.views.indices.contains(index), case .markdown(let content) = document.views[index] else { return nil }
        return content
    }

    /// The viewer switch for a rules file: the Agent view swaps the page's body in place, so it reads in the same
    /// theme as the rendered file; Rendered puts the file back. Any other view is the controller's (Source).
    private func showAgentView(_ index: Int) -> Bool {
        guard let document = lastDocument, let webView else { return false }
        let wantsAgent = document.viewTitles?.indices.contains(index) == true && document.viewTitles?[index] == RulesFacts.agentViewTitle
        guard wantsAgent != showingAgent, index == 0 || wantsAgent else { return wantsAgent }
        let body: String
        if wantsAgent { body = Self.agentView(in: document)?.html ?? ""; diagramTickets = MermaidTickets() }
        else if let context = lastContext, let html = Self.markdown(in: document)?.html { body = Self.withCachedDiagrams(html, context: context, cache: diagramCache, tickets: &diagramTickets) }
        else { return false }
        showingAgent = wantsAgent
        if let json = try? String(decoding: JSONEncoder().encode(body), as: UTF8.self) {
            Task { _ = try? await webView.evaluateJavaScript("window.vitrine.replaceBody(\(json)); window.scrollTo(0, 0); true") }
        }
        return wantsAgent
    }

    /// G-29: the exact OpenAI count for the column's meter, counted off the main thread and set as text, when the
    /// person has it on (Settings › General) and the text is within O200kCounter's limit.
    private func fillExactTokens(_ document: PreviewDocument, url: URL, context: RenderContext) {
        let openAI = context.defaults.object(forKey: TokenMeterView.exactKey) as? Bool ?? true
        let text = document.searchText
        guard !text.isEmpty, text.utf8.count <= O200kCounter.maxBytes else { return }
        Task { @MainActor [weak self] in
            let lines = await Task.detached(priority: .utility) { TokenMeterView.exactLines(text, openAI: openAI, besides: url) }.value
            guard !lines.isEmpty, let web = self?.webView else { return }
            _ = try? await web.callAsyncJavaScript("const e = document.getElementById('vt-exact'); if (e) { e.innerText = t; e.hidden = false; } return true;",
                                                   arguments: ["t": lines.joined(separator: "\n")], contentWorld: .page)
        }
    }

    /// The second lock behind the link guard (G-27): the page's own loads (the first draw and the redraw after "Aa"
    /// changes the theme) and jumps inside it (contents, footnotes) navigate; a link to anywhere else, a frame or a
    /// form is cancelled.
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame == true, let url = action.request.url else { return .cancel }
        var bare = URLComponents(url: url, resolvingAgainstBaseURL: false)
        bare?.fragment = nil
        guard bare?.url == PreviewSchemeHandler.documentBase else { return .cancel }
        return action.navigationType == .other || url.fragment != nil ? .allow : .cancel
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume(); loaded = nil
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.log.error("page failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
        loaded?.resume(); loaded = nil
    }
    /// A load that fails before it starts (the scheme or the sandbox refused it) reports here, not in didFail;
    /// without this the render would wait forever.
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Self.log.error("page failed to start: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
        loaded?.resume(); loaded = nil
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.log.error("web content process ended")
        loaded?.resume(); loaded = nil
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let name = dict["name"] as? String else { return }
        receive(name, dict)
    }

    /// The contents column's width range, in points: what the page's resizer allows and what a saved width is held to.
    static let tocWidthRange = 160...360

    /// One message from the page. Everything in it is page-supplied, so each value is checked before it is used.
    func receive(_ name: String, _ dict: [String: Any]) {
        switch name {
        case "scroll": if let y = PageNumbers.scrollOffset(dict["body"]) { lastScroll = y }
        case "tocWidth":
            // The page clamps a drag to the range; anything else (NaN, an infinity, a forged size) is ignored.
            guard let width = PageNumbers.integer(dict["body"], in: Self.tocWidthRange) else { break }
            VitrineDefaults.defaults(suite: defaultsSuite).set(width, forKey: Keys.tocWidth)
        case "loadRemote":
            loadRemoteImages()
        case "copyCode":
            // A code card's Copy button (I-2): exactly the block's text, as plain text.
            guard let text = dict["body"] as? String else { break }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "setTheme":
            guard let id = dict["body"] as? String, MarkdownTheme.builtIn.contains(where: { $0.id == id }) else { break }
            VitrineDefaults.defaults(suite: defaultsSuite).set(id, forKey: Keys.theme)
            redraw()
        case "textScale":
            // -1 smaller, +1 larger, 0 back to the default; any other number means nothing.
            guard let step = PageNumbers.integer(dict["body"], in: -1...1) else { break }
            let d = VitrineDefaults.defaults(suite: defaultsSuite)
            let scales = MarkdownTheme.textScales
            let at = scales.firstIndex(of: MarkdownTheme.textScale(d.object(forKey: Keys.textScale) as? Double)) ?? 2
            let next = step == 0 ? 2 : max(0, min(scales.count - 1, at + step))
            d.set(scales[next], forKey: Keys.textScale)
            redraw()
        case "mermaidSVG":
            // Saved only under a key Swift issued to this page, for the very source it was issued for (F52).
            if let b = dict["body"] as? [String: Any], let key = b["key"] as? String, let source = b["source"] as? String, let svg = b["svg"] as? String {
                let saved = diagramCache.store(svg, for: key, source: source, tickets: diagramTickets)
                Self.log.debug("diagram \(saved ? "saved" : "not saved", privacy: .public) (\(svg.utf8.count, privacy: .public) bytes)")
            }
        case "mermaidTiming":
            guard let t = dict["body"] as? [String: Any] else { break }
            let n = { (k: String) in PageNumbers.integer(t[k], in: -1...86_400_000) ?? -1 }
            lastMermaidTiming = MermaidTiming(load: n("load"), first: n("first"), total: n("total"), count: n("count"))
            Self.log.info("mermaid load=\(n("load"), privacy: .public)ms first=\(n("first"), privacy: .public)ms total=\(n("total"), privacy: .public)ms diagrams=\(n("count"), privacy: .public)")
        default: break
        }
    }

    /// "Load once" (G-10 B): fetch the image URLs the document itself names (never a list the page sends), hand
    /// them to the page through the scheme handler, and tell the page which chips to swap.
    private func loadRemoteImages() {
        guard let document = lastDocument, let html = Self.markdown(in: document)?.html, let store = schemeHandler?.remote else { return }
        let images = RemoteImages.images(inHTML: html)
        Task { @MainActor [weak self] in
            let fetched = await RemoteImages.fetch(images)
            var map: [String: String] = [:]
            for f in fetched { map[f.src] = "vitrine://remote/" + store.add(f.data, mime: f.mime) }
            _ = try? await self?.webView?.callAsyncJavaScript("window.vitrine.showRemote(m, n); return true",
                                                              arguments: ["m": map, "n": images.count], contentWorld: .page)
        }
    }

    /// Rebuilds the page with the current settings and puts the reader back where they were.
    private func redraw() {
        guard let webView, let document = lastDocument, let context = lastContext else { return }
        let y = lastScroll
        let page = Self.buildPage(for: document, context: context, cache: diagramCache, tickets: &diagramTickets)
        webView.underPageBackgroundColor = NSColor(css: Self.theme(context).background(for: context.appearance)) ?? .textBackgroundColor
        webView.loadHTMLString(page, baseURL: PreviewSchemeHandler.documentBase)
        Task { @MainActor [weak webView] in
            try? await Task.sleep(for: .milliseconds(150))
            _ = try? await webView?.evaluateJavaScript("window.vitrine.reveal(\(y));")
            if self.showingAgent, let html = Self.agentView(in: document)?.html,
               let json = try? String(decoding: JSONEncoder().encode(html), as: UTF8.self) {
                _ = try? await webView?.evaluateJavaScript("window.vitrine.replaceBody(\(json)); true")
            }
        }
    }

    // MARK: Page building

    static func theme(_ context: RenderContext) -> MarkdownTheme {
        MarkdownTheme.theme(id: context.defaults.string(forKey: Keys.theme))
    }

    static func options(_ context: RenderContext) -> MarkdownHTML.Options {
        let d = context.defaults
        var o = MarkdownHTML.Options()
        o.hideFrontMatter = d.object(forKey: Keys.hideFrontMatter) as? Bool ?? true
        o.math = d.object(forKey: Keys.math) as? Bool ?? true
        o.emoji = d.object(forKey: Keys.emoji) as? Bool ?? true
        o.smartPunctuation = d.object(forKey: Keys.smart) as? Bool ?? false
        return o
    }

    static func markdown(in document: PreviewDocument) -> MarkdownContent? {
        for case .markdown(let m) in document.views { return m }
        return nil
    }

    /// Diagrams drawn before for the same source, theme and appearance go in as SVG; the rest are tagged with their
    /// cache key for the page to draw and hand back.
    /// The appearance diagrams are drawn in: the page's, or the one the Diagrams setting fixes.
    static func diagramAppearance(_ context: RenderContext) -> DesignTokens.Appearance {
        switch context.defaults.string(forKey: Keys.diagramTheme) {
        case "light": .light
        case "dark": .dark
        default: context.appearance
        }
    }

    static func withCachedDiagrams(_ html: String, context: RenderContext, cache: MermaidCache) -> String {
        var tickets = MermaidTickets()
        return withCachedDiagrams(html, context: context, cache: cache, tickets: &tickets)
    }

    /// As above, and `tickets` becomes the keys handed to the page for the diagrams it has to draw, each bound to its
    /// source; the page's drawings are saved only under those (S-16 F52).
    static func withCachedDiagrams(_ html: String, context: RenderContext, cache: MermaidCache, tickets: inout MermaidTickets) -> String {
        // Keyed on the appearance the diagrams are drawn in, so a light diagram is never reused for a dark one.
        let theme = theme(context).id, appearance = diagramAppearance(context).rawValue, version = MermaidCache.mermaidVersion
        var hits = 0, misses = 0
        var issued = MermaidTickets()
        let out = MermaidBlocks.rewrite(html, key: { source in
                                            let key = MermaidBlocks.key(source: source, theme: theme, appearance: appearance, mermaidVersion: version)
                                            issued.issue(key: key, source: source)
                                            return key
                                        },
                                        cached: { key in
                                            let svg = cache.svg(for: key)
                                            if svg == nil { misses += 1 } else { hits += 1; issued.revoke(key: key) }
                                            return svg
                                        })
        tickets = issued
        if hits + misses > 0 {
            log.info("diagrams: \(hits, privacy: .public) from cache, \(misses, privacy: .public) to draw")
        }
        return out
    }

    /// The column shows when the setting allows it and the document has at least three headings (short notes
    /// keep the whole width).
    static func hasColumn(_ document: PreviewDocument, context: RenderContext) -> Bool {
        let enabled = context.defaults.object(forKey: Keys.toc) as? Bool ?? true
        return enabled && (markdown(in: document)?.headings.count ?? 0) >= 3
    }

    static func buildPage(for document: PreviewDocument, context: RenderContext, cache: MermaidCache = .standard) -> String {
        var tickets = MermaidTickets()
        return buildPage(for: document, context: context, cache: cache, tickets: &tickets)
    }

    /// The page, with `tickets` set to the diagram keys it was handed (S-16 F52).
    static func buildPage(for document: PreviewDocument, context: RenderContext, cache: MermaidCache, tickets: inout MermaidTickets) -> String {
        let content = markdown(in: document) ?? MarkdownContent(html: "", headings: [])
        let body = withCachedDiagrams(content.html, context: context, cache: cache, tickets: &tickets)
        let bundle = Bundle(for: MarkdownRenderer.self)
        let theme = theme(context)
        let d = context.defaults
        let imageWidth = d.object(forKey: Keys.imageMaxWidth) as? Int ?? 100
        let tocWidth = d.object(forKey: Keys.tocWidth) as? Int ?? 200
        let scale = MarkdownTheme.textScale(d.object(forKey: Keys.textScale) as? Double)
        var css = theme.cssVariables(for: context.appearance, textScale: scale)
        css += " --img-max: \(max(10, min(100, imageWidth)))%; --toc-width: \(max(tocWidthRange.lowerBound, min(tocWidthRange.upperBound, tocWidth)))px;"
        css += " " + theme.diagramVariables(for: diagramAppearance(context))
        guard let templateURL = bundle.url(forResource: "markdown", withExtension: "html", subdirectory: "web"),
              let template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            // Shipped template missing is a packaging bug; render a bare page rather than nothing.
            return "<!doctype html><html><body style=\"\(css)\">\(body)</body></html>"
        }
        return template
            // The page's words, localized (H-6): a data block its scripts read, never executed. Filled first, so
            // nothing from the file can stand in for the placeholder.
            .replacingOccurrences(of: "<!--VT_STRINGS-->", with: PageStrings.block(PageStrings.markdown))
            .replacingOccurrences(of: "/*VT_TOKENS*/", with: css)
            .replacingOccurrences(of: "<!--VT_THEME-->", with: context.appearance.rawValue)
            .replacingOccurrences(of: "<!--VT_VENDOR-->", with: PreviewSchemeHandler.vendorBase)
            .replacingOccurrences(of: "<!--VT_TOC-->", with: hasColumn(document, context: context) ? MarkdownColumn.html(for: content, facts: document) : "")
            .replacingOccurrences(of: "<!--VT_THEMES-->", with: MarkdownColumn.themeData(current: theme.id, scale: scale, appearance: context.appearance))
            .replacingOccurrences(of: "<!--VT_BODY-->", with: body)
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the renderer.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

// MARK: Export as HTML (I-10)

extension MarkdownRenderer: HTMLExporting {
    /// The page as one file: the theme's colours and the design's styles, the document as drawn (diagrams already
    /// SVG, maths already laid out), its local pictures embedded, KaTeX's styles and fonts only when there is maths.
    /// No script and no Vitrine controls (copy buttons, find marks) travel with it. roadmap: S-24
    ///
    /// The drawn body is the document's own HTML, raw HTML included, so it is rebuilt from an allowlist before it is
    /// written (MarkdownExportHTML: no event handler, no script URL, no element or attribute outside the list), and
    /// the file carries a Content-Security-Policy that runs no script and fetches nothing, so the export is safe to
    /// open in any browser and to pass on (S-16 F1).
    public func exportHTML(title: String) async throws -> String {
        guard let webView, let handler = schemeHandler else { throw RenderError.cancelled }
        let script = """
        (function () {
          var body = document.getElementById('body').cloneNode(true);
          body.querySelectorAll('.copy, .vt-ruler').forEach(function (n) { n.remove(); });
          body.querySelectorAll('mark.vt-find').forEach(function (m) { m.replaceWith(document.createTextNode(m.textContent)); });
          // The link guard (G-27) parks every outside address on screen; the exported page gets its links back, and
          // the allowlist below keeps only web, mail and in-page ones.
          body.querySelectorAll('[data-vitrine-href]').forEach(function (n) {
            var target = n.getAttribute('data-vitrine-href');
            if (n.localName === 'a') n.setAttribute('href', target);
            if (n.getAttribute('title') === target) n.removeAttribute('title');
            ['data-vitrine-href', 'data-vitrine-link', 'tabindex'].forEach(function (a) { n.removeAttribute(a); });
            if (n.getAttribute('role') === 'link') n.removeAttribute('role');
          });
          body.classList.remove('veiled');
          return JSON.stringify({
            theme: document.documentElement.getAttribute('data-theme') || '',
            rootStyle: document.documentElement.getAttribute('style') || '',
            styles: Array.from(document.querySelectorAll('style')).map(function (s) { return s.textContent; }),
            body: body.outerHTML,
            math: !!document.querySelector('#body .katex')
          });
        })()
        """
        guard let json = try await webView.evaluateJavaScript(script) as? String,
              let page = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              var body = page["body"] as? String else { throw RenderError.cancelled }
        body = Self.embeddingImages(in: body, handler: handler)
        body = MarkdownExportHTML.sanitize(body)   // the last step before writing: nothing is added after it
        var styles = (page["styles"] as? [String] ?? [])
        if page["math"] as? Bool == true, let katex = Self.katexCSS(handler: handler) { styles.insert(katex, at: 0) }
        let escapedTitle = MarkdownExportHTML.escape(title)
        let theme = String((page["theme"] as? String ?? "").unicodeScalars.filter { ($0 >= "a" && $0 <= "z") || $0 == "-" })
        let rootStyle = MarkdownExportHTML.escape(MarkdownExportHTML.style(page["rootStyle"] as? String ?? "") ?? "")
        return """
        <!doctype html>
        <html data-theme="\(theme)" style="\(rootStyle)">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(MarkdownExportHTML.contentSecurityPolicy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Vitrine">
        <title>\(escapedTitle)</title>
        <style>
        \(MarkdownExportHTML.styleSheet(styles.joined(separator: "\n")))
        body { margin: 0; } .page { display: block; } #body { margin: 0 auto; padding: 32px 24px 48px; }
        </style>
        </head>
        <body>
        <div class="page">
        \(body)
        </div>
        </body>
        </html>

        """
    }

    /// The most a picture may add to an exported page; a bigger one is left out (its alt text stays), since the
    /// exported page loads nothing.
    static let embeddedImageLimit = 12 << 20

    /// Pictures beside the document become `data:` URLs; remote ones Vitrine loaded once (G-10) come from memory.
    /// A local picture is read through the scheme handler's confinement (S-16 F10): a regular file inside the
    /// document's folder once every symbolic link is followed, no larger than the limit, and named as a picture.
    static func embeddingImages(in html: String, handler: PreviewSchemeHandler) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"(<img\b[^>]*?\ssrc=")([^"]+)(")"#, options: .caseInsensitive) else { return html }
        var out = html
        for match in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            guard let range = Range(match.range(at: 2), in: out) else { continue }
            let src = String(out[range]).replacingOccurrences(of: "&amp;", with: "&")
            if src.hasPrefix("data:") || src.hasPrefix("http:") || src.hasPrefix("https:") { continue }
            let address = URL(string: src, relativeTo: PreviewSchemeHandler.documentBase)?.absoluteURL
            var data: Data?, mime = "application/octet-stream"
            if let address, address.host == "remote", let image = handler.remote.image(String(address.path.dropFirst())) {
                data = image.data; mime = image.mime
            } else if let address, address.host == "doc",
                      let type = UTType(filenameExtension: address.pathExtension), type.conforms(to: .image),
                      let found = handler.read(address, limit: embeddedImageLimit) {
                data = found.data
                mime = type.preferredMIMEType ?? mime
            }
            guard let data else { continue }
            out.replaceSubrange(range, with: "data:\(mime);base64,\(data.base64EncodedString())")
        }
        return out
    }

    /// KaTeX's style sheet with its fonts inside, for an exported page that has maths.
    static func katexCSS(handler: PreviewSchemeHandler) -> String? {
        guard let vendor = handler.vendorRoot, let css = try? String(contentsOf: vendor.appendingPathComponent("katex/katex.min.css"), encoding: .utf8),
              let pattern = try? NSRegularExpression(pattern: #"url\((fonts/[^)]+\.woff2)\)"#) else { return nil }
        var out = css
        for match in pattern.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed() {
            guard let whole = Range(match.range, in: out), let name = Range(match.range(at: 1), in: out) else { continue }
            guard let font = try? Data(contentsOf: vendor.appendingPathComponent("katex").appendingPathComponent(String(out[name]))) else { continue }
            out.replaceSubrange(whole, with: "url(data:font/woff2;base64,\(font.base64EncodedString()))")
        }
        return out
    }
}

/// What an exported Markdown page may hold (S-16 F1). The body is rebuilt with the notebook's allowlist rebuild
/// (NotebookHTML.sanitize) under this policy: the HTML a Markdown document renders to, the SVG mermaid and KaTeX
/// draw, and the MathML KaTeX writes for screen readers, each element with only the attributes listed here, and
/// every value checked. No event handler, script or script URL, frame, form, object or fetching attribute survives.
/// The file also carries `contentSecurityPolicy`: no script at all, nothing fetched, pictures and fonts only as
/// `data:` URLs and inline styles (the theme, KaTeX's layout, the code colours, mermaid's own style sheet).
/// roadmap: S-16
enum MarkdownExportHTML {
    static let contentSecurityPolicy = "default-src 'none'; script-src 'none'; object-src 'none'; frame-src 'none'; connect-src 'none'; "
        + "img-src data:; font-src data:; style-src 'unsafe-inline'; media-src 'none'; form-action 'none'; base-uri 'none'"

    static func sanitize(_ html: String) -> String { NotebookHTML.sanitize(html, policy: policy) }

    static let policy = NotebookHTML.Policy(
        allowed: html.union(svg).union(mathML),
        void: NotebookHTML.void.union(["input", "wbr"]),
        dropWithContent: NotebookHTML.dropWithContent.subtracting(["svg", "math", "style", "embed"])
            .union(["button", "annotation-xml", "image", "feimage", "animate", "animatemotion", "animatetransform", "set",
                    "discard", "mpath", "form", "portal", "dialog", "slot"]),
        keep: keep,
        required: ["input": "type"],
        rawText: ["style": "svg"],
        // HTML's void elements that must go: only the tag is removed, so what follows them stays.
        dropVoid: ["link", "meta", "base", "embed", "source", "track", "param", "area", "keygen"])

    static let html: Set<String> = NotebookHTML.allowed.union([
        "section", "article", "aside", "header", "footer", "main", "nav", "address", "cite", "dfn", "ruby", "rt", "rp",
        "bdi", "bdo", "wbr", "time", "input",
    ])
    static let svg: Set<String> = [
        "svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "textpath", "defs",
        "marker", "lineargradient", "radialgradient", "stop", "clippath", "mask", "pattern", "symbol", "use", "foreignobject",
        "desc", "filter", "feblend", "fecolormatrix", "fecomponenttransfer", "fecomposite", "fedropshadow", "feflood",
        "fefunca", "fefuncb", "fefuncg", "fefuncr", "fegaussianblur", "femerge", "femergenode", "femorphology", "feoffset",
        "fetile",
    ]
    static let mathML: Set<String> = [
        "math", "semantics", "annotation", "mrow", "mi", "mo", "mn", "ms", "mtext", "mspace", "msup", "msub", "msubsup",
        "mfrac", "msqrt", "mroot", "mover", "munder", "munderover", "mtable", "mtr", "mtd", "mlabeledtr", "mstyle",
        "mpadded", "mphantom", "menclose", "merror",
    ]
    /// Presentation attributes SVG elements keep (names as the tokenizer lowercases them).
    static let svgAttributes: Set<String> = [
        "d", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy", "width", "height", "viewbox",
        "transform", "transform-origin", "points", "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width",
        "stroke-dasharray", "stroke-dashoffset", "stroke-linecap", "stroke-linejoin", "stroke-opacity", "stroke-miterlimit",
        "opacity", "marker-start", "marker-mid", "marker-end", "markerwidth", "markerheight", "markerunits", "refx", "refy",
        "orient", "preserveaspectratio", "text-anchor", "dominant-baseline", "alignment-baseline", "baseline-shift",
        "font-family", "font-size", "font-weight", "font-style", "font-variant", "letter-spacing", "word-spacing",
        "text-decoration", "dx", "dy", "rotate", "textlength", "lengthadjust", "startoffset", "method", "spacing",
        "clip-path", "clip-rule", "clippathunits", "mask", "maskunits", "maskcontentunits", "filter", "filterunits",
        "primitiveunits", "offset", "stop-color", "stop-opacity", "gradientunits", "gradienttransform", "spreadmethod",
        "patternunits", "patterncontentunits", "patterntransform", "xml:space", "visibility", "display", "overflow",
        "color", "vector-effect", "pathlength", "shape-rendering", "text-rendering", "paint-order", "pointer-events",
        "writing-mode", "direction", "unicode-bidi", "version", "focusable", "in", "in2", "result", "stddeviation",
        "flood-color", "flood-opacity", "mode", "operator", "k1", "k2", "k3", "k4", "values", "type", "radius", "slope",
        "intercept", "amplitude", "exponent", "tablevalues", "edgemode", "name",
    ]
    /// The MathML attributes KaTeX writes (and their near kin); `href` is not among them.
    static let mathAttributes: Set<String> = [
        "display", "mathvariant", "stretchy", "fence", "separator", "lspace", "rspace", "accent", "accentunder",
        "columnalign", "rowalign", "rowspacing", "columnspacing", "columnlines", "rowlines", "frame", "framespacing",
        "width", "height", "depth", "voffset", "encoding", "scriptlevel", "displaystyle", "minsize", "maxsize",
        "movablelimits", "notation", "linethickness", "symmetric", "largeop", "mathcolor", "mathbackground", "mathsize",
        "align", "side", "columnspan", "rowspan",
    ]
    static let namespaces: Set<String> = ["http://www.w3.org/2000/svg", "http://www.w3.org/1999/xhtml", "http://www.w3.org/1998/Math/MathML"]
    static let xlinkNamespace = "http://www.w3.org/1999/xlink"

    /// The attribute value to write (already checked), or nil to drop the attribute.
    @Sendable static func keep(_ tag: String, _ name: String, _ raw: String) -> String? {
        let value = raw.replacingOccurrences(of: "&nbsp;", with: "\u{A0}")
        if name.hasPrefix("on") { return nil }   // never an event handler, whatever list it might seem to match
        switch name {
        case "class", "id", "title", "lang", "xml:lang", "dir", "role": return value
        case "style": return style(value)
        case "href", "xlink:href":
            if tag == "a", name == "href" { return link(value) }
            return (tag == "use" || tag == "textpath") && value.hasPrefix("#") ? value : nil   // a reference inside the drawing
        case "src": return tag == "img" && isDataImage(value) ? value : nil
        case "xmlns": return namespaces.contains(value) ? value : nil
        case "xmlns:xlink": return value == xlinkNamespace ? value : nil
        default: break
        }
        if name.hasPrefix("aria-") || name.hasPrefix("data-") {
            let rest = name.dropFirst(5)
            return !rest.isEmpty && rest.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) ? value : nil
        }
        switch (tag, name) {
        case ("input", "type"): return value.lowercased() == "checkbox" ? "checkbox" : nil   // the task list's boxes, nothing else
        case ("input", "checked"), ("input", "disabled"), ("details", "open"): return ""
        case ("img", "alt"), ("time", "datetime"): return value
        case ("img", "width"), ("img", "height"):
            let digits = value.hasSuffix("%") ? String(value.dropLast()) : value
            return !digits.isEmpty && digits.count <= 5 && digits.allSatisfy({ $0.isASCII && $0.isNumber }) ? value : nil
        case ("td", "colspan"), ("td", "rowspan"), ("th", "colspan"), ("th", "rowspan"), ("ol", "start"), ("li", "value"),
             ("col", "span"), ("colgroup", "span"):
            return !value.isEmpty && value.count <= 5 && value.allSatisfy({ $0.isASCII && $0.isNumber }) ? value : nil
        case ("td", "align"), ("th", "align"):
            return ["left", "right", "center"].contains(value.lowercased()) ? value.lowercased() : nil
        default: break
        }
        if svg.contains(tag), svgAttributes.contains(name) { return presentation(value) }
        if mathML.contains(tag), mathAttributes.contains(name) { return presentation(value) }
        return nil
    }

    /// Text with the characters that matter in HTML text and attribute values escaped.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The page's collected style sheets, made safe to sit inside one `<style>` element: no `</style` can end it.
    static func styleSheet(_ css: String) -> String {
        css.replacingOccurrences(of: "</style", with: "<\\/style", options: .caseInsensitive)
    }

    /// An inline style that can neither fetch nor run anything: no `url(` other than a reference inside the drawing
    /// (`url(#id)`), no `image-set(`, no `@import`, no legacy `expression(` or bindings, no escapes that could spell
    /// them. KaTeX's layout, the code colours and mermaid's inline styles need none of these.
    static func style(_ value: String) -> String? {
        let lower = value.lowercased()
        for banned in ["\\", "expression", "javascript:", "vbscript:", "@import", "behavior", "-moz-binding", "image-set(", "image(", "src(", "element("] where lower.contains(banned) {
            return nil
        }
        return onlyLocalURLs(lower) ? value : nil
    }

    /// An SVG or MathML presentation value: a colour, a length, a path, or a `url(#id)` reference inside the
    /// drawing; never a URL out.
    static func presentation(_ value: String) -> String? {
        let lower = value.lowercased()
        if lower.contains("javascript:") || lower.contains("vbscript:") || lower.contains("expression") || lower.contains("\\") { return nil }
        return onlyLocalURLs(lower) ? value : nil
    }

    /// True when every `url(` in `lower` is a fragment reference (`url(#…)`, quoted or not).
    private static func onlyLocalURLs(_ lower: String) -> Bool {
        var rest = lower[...]
        while let r = rest.range(of: "url(") {
            var after = rest[r.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\"" || $0 == "'" }
            guard after.first == "#" else { return false }
            after = after.dropFirst()
            rest = after
        }
        return true
    }

    /// A link's address: a jump inside the page, a web or mail address, or a relative path; never `javascript:`,
    /// `data:`, `vitrine:`, `file:` or any other scheme.
    static func link(_ value: String) -> String? {
        // Browsers ignore control characters and spaces around a URL and tabs and newlines inside it.
        let bare = String(value.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F })
        if bare.isEmpty || bare.hasPrefix("#") { return value }
        if let colon = bare.firstIndex(of: ":"), !bare[..<colon].contains(where: { "/?#".contains($0) }) {
            return ["http", "https", "mailto"].contains(bare[..<colon].lowercased()) ? value : nil
        }
        return value
    }

    /// A picture carried in the page itself: `data:image/<type>;base64,` and base64 only.
    static func isDataImage(_ value: String) -> Bool {
        guard value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ",") else { return false }
        let header = value[value.index(value.startIndex, offsetBy: 11)..<comma]
        guard header.hasSuffix(";base64") else { return false }
        let type = header.dropLast(7)
        guard !type.isEmpty, type.count <= 40, type.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".+-".contains($0)) }) else { return false }
        return value.utf8[value.utf8.index(after: comma)...].allSatisfy { b in
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2B || b == 0x2F || b == 0x3D
        }
    }
}
