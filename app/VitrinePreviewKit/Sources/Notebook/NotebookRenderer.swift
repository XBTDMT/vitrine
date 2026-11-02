import AppKit
import OSLog
import VitrineCompare
import VitrineDocument
import VitrineSupport
import VitrineUI
import WebKit

/// Jupyter notebooks (A-8, parity B-3; design/mockups/unified/ai.html state 11): one locked-down page built by
/// `NotebookPage` — the header card, the out-of-order inset, every cell as a card with Markdown rendered, code
/// coloured by the code view's Shiki (`fences.js`, coloured in the system's syntax tokens), outputs as text, errors
/// with their tracebacks, images, and HTML rebuilt from an allowlist. The viewer switch offers Notebook, Code only
/// (the same page with prose and outputs folded away) and Source (the JSON, in the host's text view).
///
/// Safety: the page's CSP allows scripts only from Vitrine's own `vitrine:` scheme (never inline, so nothing in a
/// notebook runs), images only as `data:`, and no connections; the G-9 content rule list blocks every load that is not
/// `vitrine:` or `data:`; only the page's own first load may navigate. Outputs never run: HTML outputs are rebuilt by
/// `NotebookHTML.sanitize`, images are decoded from the notebook's base64 and re-encoded. A file that is not a
/// notebook Vitrine can read opens in the structured JSON view with the reason as a badge. roadmap: S-21
@MainActor
public final class NotebookRenderer: NSObject, Renderer, WKNavigationDelegate, WKScriptMessageHandler {
    /// Jupyter notebooks, and marimo notebooks (A-8): Python files marimo wrote, drawn on the same page.
    public static func canRender(_ kind: FileKind) -> Bool { kind == .code(language: "ipynb") || kind == .code(language: "marimo") }

    /// How long the first paint waits for the page to say it is ready before falling back to the JSON view.
    nonisolated(unsafe) static var readyTimeout: Duration = .seconds(3)
    private static let log = Logger(subsystem: "io.github.xbtdmt.vitrine", category: "notebook")

    private var webView: WKWebView?
    private var schemeHandler: PreviewSchemeHandler?
    private var ready: CheckedContinuation<Bool, Never>?
    private var lastScroll: Double = 0
    private var firstLoadAllowed = false
    /// Errors the page reported (window.onerror); tests read them.
    public private(set) var pageErrors: [String] = []
    /// Code blocks Shiki has coloured, as the page last reported.
    public private(set) var colouredBlocks = 0

    public override required init() { super.init() }

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        let built: NotebookPage
        do {
            built = try await Self.build(url: url, kind: kind)
        } catch let error as CompareError {
            return try await notANotebook(url: url, kind: kind, reason: error.description, context: context)
        }
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let handler = PreviewSchemeHandler(documentRoot: url.deletingLastPathComponent())
        schemeHandler = handler
        config.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.scheme)
        try await PageLockdown.apply(to: config)
        config.userContentController.add(WeakScriptHandler(self), name: "vitrine")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = NSColor.token("win")
        webView = web
        codeElements = Self.codeElementCount(in: built.body)
        web.loadHTMLString(Self.page(built, context: context), baseURL: PreviewSchemeHandler.documentBase)
        let started = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            ready = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.readyTimeout)
                self?.finish(false)
            }
        }
        guard started else {
            Self.log.error("notebook page did not start; showing the JSON view")
            return try await notANotebook(url: url, kind: kind, reason: String(localized: "The notebook page did not start", bundle: .previewKit,
                                                                   comment: "Why a notebook is shown as JSON: its page failed to load."),
                                          context: context)
        }
        // The controller applies scroll memory right after this returns; the reveal runs after that, so no jump.
        Task { @MainActor [weak web] in _ = try? await web?.evaluateJavaScript("window.vitrineNotebook.reveal(); true") }

        return RenderedPreview(
            view: web, document: built.document, owner: self,
            reload: { [weak self] url in
                let fresh = try await Self.build(url: url, kind: kind)
                // The first page's report may still be on its way: the bound covers both bodies.
                if let self { self.codeElements = max(self.codeElements, Self.codeElementCount(in: fresh.body)) }
                if let web = self?.webView {
                    _ = try? await web.callAsyncJavaScript("window.vitrineNotebook.replaceBody(h); return true;",
                                                           arguments: ["h": fresh.body], contentWorld: .page)
                }
                return fresh.document
            },
            scrollOffset: { [weak self] in self?.lastScroll },
            restoreScroll: { [weak self, weak web] y in
                self?.lastScroll = y
                Task { _ = try? await web?.evaluateJavaScript("window.vitrineNotebook.reveal(\(y)); true") }
            },
            find: { [weak web] query, forward in
                guard let web else { return FindResult(count: 0, index: -1) }
                let r = try? await web.callAsyncJavaScript("return window.vitrineNotebook.find(q, f);", arguments: ["q": query, "f": forward],
                                                           contentWorld: .page) as? [String: Any]
                let found = PageNumbers.matches(r)
                return FindResult(count: found.count, index: found.index)
            },
            clearFind: { [weak web] in Task { _ = try? await web?.evaluateJavaScript("window.vitrineNotebook.clearFind(); true") } },
            showView: { [weak web] index in
                // 0 Notebook and 1 Code only are this page; 2 Source is the host's text view.
                guard index <= 1 else { return false }
                Task { _ = try? await web?.callAsyncJavaScript("window.vitrineNotebook.setMode(m); return true;",
                                                                arguments: ["m": index == 1 ? "code" : "notebook"], contentWorld: .page) }
                return true
            })
    }

    static func build(url: URL, kind: FileKind = .code(language: "ipynb")) async throws -> NotebookPage {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if kind == .code(language: "marimo") {
                return try NotebookPage.make(marimo: data, fileName: url.lastPathComponent, fileSize: Int64(data.count))
            }
            return try NotebookPage.make(data: data, fileName: url.lastPathComponent, fileSize: Int64(data.count))
        }.value
    }

    /// Not a notebook Vitrine can draw (not JSON, nbformat 3, no cells; a .py that no longer reads as marimo): the
    /// file's own code view (JSON, or Python for marimo), with the reason in the pill.
    private func notANotebook(url: URL, kind: FileKind, reason: String, context: RenderContext) async throws -> RenderedPreview {
        let fallback: FileKind = kind == .code(language: "marimo") ? .code(language: "python") : .code(language: "json")
        guard let code = RendererRegistry.renderer(for: fallback) else { throw RenderError.unsupported(kind) }
        let preview = try await code.render(url: url, kind: fallback, context: context)
        var document = preview.document
        document.badges.insert(Badge(level: .caution, title: String(localized: "Not drawn as a notebook", bundle: .previewKit,
                                                                   comment: "Warning title: a notebook file shown as its code (JSON, or Python for a marimo notebook) because it cannot be drawn as a notebook."),
                                     detail: reason), at: 0)
        preview.updateDocument(document)
        return preview
    }

    // MARK: The page

    static func page(_ built: NotebookPage, context: RenderContext) -> String {
        let appearance = context.appearance == .dark ? "dark" : "light"
        let bundle = Bundle(for: NotebookRenderer.self)
        let css = bundle.url(forResource: "notebook", withExtension: "css", subdirectory: "web")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        // The card shadow is a design token (tokens.json shadow-card) the generated Swift tables do not carry yet.
        let shadow = context.appearance == .dark ? "0 0 0 .5px rgba(255,255,255,.10),0 1px 2px rgba(0,0,0,.3)"
                                                 : "0 0 0 .5px rgba(0,0,0,.10),0 1px 2px rgba(0,0,0,.05)"
        return """
        <!doctype html>
        <html data-theme="\(appearance)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src vitrine: 'wasm-unsafe-eval'; style-src vitrine: 'unsafe-inline'; img-src vitrine: data:; font-src vitrine: data:; connect-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'">
        <title>Vitrine Notebook</title>
        <link rel="stylesheet" href="\(PreviewSchemeHandler.vendorBase)/katex/katex.min.css">
        <style>
        :root { \(DesignTokens.systemCSS(for: context.appearance)) --v-shadow-card: \(shadow); color-scheme: \(appearance); }
        \(css)
        </style></head>
        <body>\(PageStrings.block(PageStrings.notebook))<main id="nb" class="veiled">\(built.body)</main>
        <script src="\(PreviewSchemeHandler.vendorBase)/katex/katex.min.js"></script>
        <script src="vitrine://app/notebook.js"></script>
        <script type="module" src="vitrine://app/code/fences.js"></script>
        </body></html>
        """
    }

    // MARK: Page messages

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any] else { return }
        receive(dict)
    }

    /// The `<code>` elements in the page's body, the most blocks `fences.js` can colour; counted from the HTML
    /// Swift built, never from the page.
    private(set) var codeElements = 0

    /// `<code` opening tags in `html` (any case): every block the fences script colours is one of them.
    nonisolated static func codeElementCount(in html: String) -> Int {
        html.lowercased().components(separatedBy: "<code").count - 1
    }

    /// One message from the page; its numbers go through `PageNumbers` (S-16).
    func receive(_ dict: [String: Any]) {
        guard let name = dict["name"] as? String else { return }
        switch name {
        case "ready": finish(true)
        case "scroll": if let y = PageNumbers.scrollOffset(dict["body"]) { lastScroll = y }
        case "fences":
            // The page reports once, after its first colouring, how many blocks it coloured: at most the page's
            // code elements. (It used to be added to the total, so a forged count could overflow it.)
            if let n = PageNumbers.integer(dict["body"], in: 0...codeElements) { colouredBlocks = n }
        case "error":
            let text = dict["body"] as? String ?? "?"
            pageErrors.append(text)
            Self.log.error("page error (\(text.count, privacy: .public) characters)")
        default: break
        }
    }

    private func finish(_ ok: Bool) {
        guard let ready else { return }
        self.ready = nil
        ready.resume(returning: ok)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(false) }

    /// Only the page's own first load, and jumps inside it (a footnote), may navigate; links and anything else a cell
    /// tries to open are cancelled.
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame == true, let url = action.request.url else { return .cancel }
        if !firstLoadAllowed, url == PreviewSchemeHandler.documentBase {
            firstLoadAllowed = true
            return .allow
        }
        var withoutFragment = URLComponents(url: url, resolvingAgainstBaseURL: false)
        withoutFragment?.fragment = nil
        if firstLoadAllowed, url.fragment != nil, withoutFragment?.url == PreviewSchemeHandler.documentBase { return .allow }
        return .cancel
    }
}
