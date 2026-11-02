import AppKit
import VitrineHelperKit
import UniformTypeIdentifiers
import VitrineDocument
import VitrineSupport
import VitrineText
import VitrineTrust
import VitrineUI
import WebKit

/// The code view (S-5, G-14; code design r3-a): CodeMirror 6 in a locked-down web view (G-9), coloured by Shiki's
/// TextMate grammars in the unified syntax palette, with sticky scope lines, folding by indentation, capsule find and
/// the line-selection readout on the gutter's right ("Ln 40–47 · 8 lines"). The text, its encoding and how much of a
/// large file is shown come from the plain-text engine, so facts and coverage match the native view. If the page
/// cannot start (WebKit unavailable, a load failure, no answer within `readyTimeout`) the file shows in the native
/// text view instead: a preview is never blank. roadmap: S-5
@MainActor
public final class CodeRenderer: NSObject, Renderer, WKNavigationDelegate, WKScriptMessageHandler {
    /// Source code in any language; plain text (`.txt`, `.nfo`) stays in the lighter native text view.
    public static func canRender(_ kind: FileKind) -> Bool {
        if case .code(let language) = kind { return language != "plaintext" }
        return false
    }

    public override required init() { super.init() }

    /// How long the first paint waits for the page before the native text view is shown instead.
    nonisolated(unsafe) static var readyTimeout: Duration = .seconds(3)

    private(set) var webView: WKWebView?
    private var schemeHandler: PreviewSchemeHandler?
    private var ready: CheckedContinuation<Bool, Never>?
    private weak var preview: RenderedPreview?
    private var lastScroll: Double?
    /// The page's report after its first paint: milliseconds from script start, and the Shiki language used.
    public private(set) var readyReport: (ms: Int, language: String?)?
    public private(set) var pageErrors: [String] = []

    /// Files larger than this open as windows of lines (state 14); smaller ones load whole.
    nonisolated(unsafe) static var windowThreshold: Int64 = PlainTextRenderer.streamingThreshold
    /// Lines in one window of a huge file.
    nonisolated(unsafe) static var windowLines = 4_096
    /// The huge file being read in windows; nil for a file loaded whole.
    private var large: LargeTextFile?
    private var indexing: Task<Void, Never>?
    private var finding: Task<Void, Never>?
    private var findState = (query: "", lines: [Int](), index: -1, done: true, capped: false)
    /// What the window holds now (file lines).
    private var shownWindow = (first: 1, count: 0)

    /// A minified file's own text when the page shows it formatted (state 4); nil = shown as it is.
    private var original: String?
    private var originalLines = 0

    /// A file read whole: decoded, its secrets masked (state 16), formatted when minified (C-5, state 4).
    func readWhole(url: URL, kind: FileKind) throws -> (PreviewDocument, String, String) {
        var read = try PlainTextRenderer.textDocument(url: url, kind: kind, encoding: encoding)
        var body: String
        var language = "plaintext"
        switch read.primaryView {
        case .code(let s, let l): body = s; language = l
        case .text(let s), .formatted(let s, _): body = s
        case .markdown: body = read.searchText
        }
        // Secrets in config files are masked here, before the page, the copy menu or the pill see them.
        if SecretMask.languages.contains(language) {
            let masked = SecretMask.mask(body)
            body = masked.text
            read.views = [.code(body, language: language)]
            if masked.count > 0 {
                read.facts.append(Fact(key: "headline",
                                       label: String(localized: "Secrets", bundle: .previewKit, comment: "Fact label: secrets hidden in a config file."),
                                       value: String(localized: "\(masked.count) secrets masked", bundle: .previewKit,
                                                     comment: "Capsule pill headline: how many secrets (keys, tokens) Vitrine hid in a config file.")))
            }
        }
        // Secret values in any file, by its family's detectors (T-4, G-23): format detectors in code, every enabled one
        // in configuration and scripts.
        let detected = LensPolicy.masked(body, kind: kind)
        if detected.count > 0 {
            body = detected.text
            read.views = [.code(body, language: language)]
        }
        // Minified CSS and SQL open laid out for reading; the original is one click away.
        original = nil
        if let formatted = CodeFormatter.format(body, language: language) {
            original = body
            originalLines = body.split(separator: "\n", omittingEmptySubsequences: true).count
            read.views = [.code(formatted, language: language)]
            body = formatted
        }
        return (read, body, language)
    }

    /// The document as the capsule shows it: Code (or Log and Text) and Hex.
    static func shaped(_ document: PreviewDocument, text: String, language: String) -> PreviewDocument {
        var shown = document
        let base: [DocumentView] = language == "log" ? [.code(text, language: "log"), .code(text, language: "log")] : [.code(text, language: language)]
        shown.views = base + [.text("")]
        shown.viewTitles = (language == "log" ? ["Log", "Text"] : ["Code"]) + ["Hex"]
        return shown
    }

    /// The encoding the reader picked with "Reopen as…"; nil = detected.
    var encoding: String.Encoding?

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        var window: PageWindow?
        var document: PreviewDocument
        var text: String
        var language = "plaintext"
        if size > Self.windowThreshold, case .code(let l) = kind {
            // State 14: never the whole file. The first window now, the line count in the background.
            let file = try LargeTextFile(url: url)
            large = file
            let first = try await file.window(from: 1, count: Self.windowLines)
            shownWindow = (1, first.count)
            let estimate = await file.lineCount
            window = PageWindow(first: 1, total: estimate.count, exact: estimate.exact, size: Self.windowLines)
            text = first.text
            language = l
            document = PreviewDocument(kind: kind, facts: [DocumentFacts.size(size)], views: [.code(text, language: l)],
                                       coverage: .partial(shown: first.byteRange.upperBound, total: size, unit: .bytes,
                                                          reason: String(localized: "Huge file: read \(Self.windowLines) lines at a time", bundle: .previewKit,
                                                                         comment: "Why a huge code file is shown in windows.")))
            document.setTokens(TokenCounting.count(.byteCount(Int(size))))
        } else {
            (document, text, language) = try readWhole(url: url, kind: kind)
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
        web.underPageBackgroundColor = NSColor.token("page")
        webView = web
        defaults = context.defaults
        // Changed lines against HEAD (I-16): for a file loaded whole, read off the main thread, bounded by the diff.
        let changes: [CodeChanges.Run] = large == nil
            ? await Task.detached(priority: .userInitiated) { CodeChanges.runs(for: url, text: text) }.value : []
        let extras = PageExtras(options: CodeOptions(defaults: context.defaults), fonts: CodeOptions.installedFonts(),
                                imported: CodeThemeImport.stored(context.defaults).compactMap(PageTheme.init), changes: changes,
                                notice: Self.notice(for: document, url: url, language: language), fileName: url.lastPathComponent,
                                original: original.map { Original(text: $0, lines: originalLines) })
        fileURL = url
        fileKind = kind
        fileLanguage = language
        shownText = (text, 1)
        web.loadHTMLString(Self.page(text: text, language: Self.shikiLanguage(language), window: window, extras: extras, context: context),
                           baseURL: PreviewSchemeHandler.documentBase)
        let started = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            ready = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.readyTimeout)
                self?.finish(false)
            }
        }
        guard started else {
            // Fail visible, not blank: the native text view draws the same document.
            return try await PlainTextRenderer().render(url: url, kind: kind, context: context)
        }
        // A log opens in the Log view (state 11), with Text one switch away; every code file has Hex last (state 13).
        let shown = Self.shaped(document, text: text, language: language)
        let hexIndex = language == "log" ? 2 : 1
        let container = CodeContainer(web: web)
        self.container = container
        let preview = RenderedPreview(
            view: container, document: shown, owner: self,
            reload: { [weak self] url in
                guard let self else { throw RenderError.unreadable(url) }
                return try await self.reloadFile(url)
            },
            scrollOffset: { [weak self] in self?.lastScroll },
            restoreScroll: { [weak web] y in
                Task { _ = try? await web?.evaluateJavaScript("window.vitrine.reveal(\(y)); true") }
            },
            // The hex view's byte decoder when Hex is shown; otherwise the host's Details with the token meter (A-4).
            toggleInspector: { [weak self, weak container] in
                if container?.hex?.isHidden == false { container?.hex?.toggleInspector() } else { self?.preview?.toggleHostDetails() }
            },
            find: { [weak self, weak web, weak container] query, forward in
                if let hex = container?.shownHex { return await hex.find(query, forward: forward) }
                guard let web else { return FindResult(count: 0, index: -1) }
                // A prefix (":42", "@flush") is the page's; plain text in a huge file streams through Swift.
                let prefixed = query.hasPrefix(":") || query.hasPrefix("@") || query.lowercased().hasPrefix("level:")
                if let self, self.large != nil, !prefixed { return self.streamingFind(query, forward: forward) }
                let r = try? await web.callAsyncJavaScript("return window.vitrine.find(q, f);", arguments: ["q": query, "f": forward],
                                                           contentWorld: .page) as? [String: Any]
                let found = PageNumbers.matches(r)
                return FindResult(count: found.count, index: found.index,
                                  searchedAll: (r?["searchedAll"] as? Bool) ?? true, label: r?["label"] as? String)
            },
            clearFind: { [weak self, weak web, weak container] in
                container?.hex?.clearFind()
                self?.resetFind()
                Task { _ = try? await web?.evaluateJavaScript("window.vitrine.clearFind(); true") }
            },
            showView: { [weak self, weak web] index in
                guard let self, index <= hexIndex else { return false }
                if index == hexIndex { return self.showHex() }
                self.container?.show(hex: false)
                self.preview?.updateGutter(self.pageGutter)
                if language == "log" {
                    Task { _ = try? await web?.callAsyncJavaScript("window.vitrine.showLog(on); return true;", arguments: ["on": index == 0], contentWorld: .page) }
                }
                return true
            })
        preview.copyFormats = { [weak self] in
            if let hex = self?.container?.shownHex { return hex.copyOffer() }
            return self?.copyOffer() ?? (CodeCopy.copyAsHeading, [])
        }
        preview.findPrefixes = language == "log" ? [FindPrefix.line, .symbol, .level] : [FindPrefix.line, .symbol]
        preview.foldToMatches = { [weak web] on in
            Task { _ = try? await web?.callAsyncJavaScript("return window.vitrine.foldToMatches(on);", arguments: ["on": on], contentWorld: .page) }
        }
        preview.displayOptions = { [weak web] in
            Task { _ = try? await web?.evaluateJavaScript("window.vitrine.toggleAppearance(); true") }
        }
        preview.cancelWork = { [weak self] in
            if let hex = self?.container?.shownHex { hex.cancelSearch() } else { self?.stopFind() }
        }
        preview.defersToHostDetails = true
        self.preview = preview
        applyLogHeadline()
        if large != nil { startIndexing() }
        Task { @MainActor [weak self] in self?.installedEditors = await HelperClient.installedEditors() }
        reportAction = { [weak preview] error in
            guard let error, let preview else { return }
            let previous = preview.gutter
            preview.updateGutter(GutterStatus(leading: error))
            Task { @MainActor [weak preview] in
                try? await Task.sleep(for: .seconds(6))
                if preview?.gutter?.leading == error { preview?.updateGutter(previous) }
            }
        }
        return preview
    }

    // MARK: The page

    /// Vitrine's language ids follow Shiki's, with a few names of our own.
    nonisolated static func shikiLanguage(_ id: String) -> String {
        switch id {
        case "shell": return "shellscript"
        case "objective-c": return "objective-c"
        case "plaintext", "nfo": return "plaintext"
        default: return id
        }
    }

    /// A JSON string literal that is safe inside a `<script>` element: `<` is escaped, so "</script>" or "<!--" in
    /// the file cannot end or confuse the element.
    static func scriptJSON(_ value: some Encodable) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }

    /// A huge file's first window, for the page (state 14).
    /// A minified file shown formatted: its own text and line count, for "Show original".
    struct Original: Encodable { let text: String; let lines: Int }
    struct PageWindow: Encodable { let first: Int; let total: Int; let exact: Bool; let size: Int }
    /// An imported theme for the page: its id, name and the theme in Shiki's form.
    struct PageTheme: Encodable {
        let id: String, name: String, theme: AnyJSON
        init?(_ t: CodeThemeImport.Imported) {
            guard let o = try? JSONSerialization.jsonObject(with: t.theme) else { return nil }
            id = t.id; name = t.name; theme = AnyJSON(o)
        }
    }
    /// What the page needs beside the text: the display options, the fonts on this Mac, imported themes, changed lines.
    struct PageExtras {
        var options = CodeOptions()
        var fonts: [String] = CodeOptions.installedFonts()
        var imported: [PageTheme] = []
        var changes: [CodeChanges.Run] = []
        var notice: PageNotice?
        var fileName = ""
        var original: Original?
    }
    /// The strip above the code (state 3): how the bytes were read and where the language came from, with
    /// "Reopen as…" over the encodings TextEncodingDetector offers.
    struct PageNotice: Encodable, Equatable {
        struct Choice: Encodable, Equatable { let raw: UInt; let name: String }
        let text: String
        let encodings: [Choice]
        let current: UInt
    }

    static func notice(for document: PreviewDocument, url: URL, language: String) -> PageNotice? {
        var parts: [String] = []
        if let note = document.fact("encodingNote")?.value { parts.append(note) }
        if url.pathExtension.isEmpty, language != "plaintext",
           let head = try? FileHandle(forReadingFrom: url).read(upToCount: 2), head == Data("#!".utf8) {
            parts.append(String(localized: "Language from the #! line: \(LanguageMap.displayName(for: language)).", bundle: .previewKit,
                                comment: "Code notice: the language was read from the file's first line (#!); the argument is the language's name."))
        }
        guard !parts.isEmpty else { return nil }
        // The encoding fact says the name, or the name "with BOM" in the person's language (PlainTextRenderer).
        let value = document.fact("encoding")?.value ?? "UTF-8"
        let current = TextEncodingDetector.choices.first { choice in
            let name = TextEncodingDetector.name(of: choice)
            return value == name || value == PlainTextRenderer.withBOM(name)
        } ?? .utf8
        return PageNotice(text: parts.joined(separator: " "),
                          encodings: TextEncodingDetector.choices.map { .init(raw: $0.rawValue, name: TextEncodingDetector.name(of: $0)) },
                          current: current.rawValue)
    }
    struct PageConfig: Encodable {
        let lang: String; let fileName: String; let log: Bool; let original: Original?; let window: PageWindow?; let options: CodeOptions; let fonts: [String]
        let imported: [PageTheme]; let changes: [CodeChanges.Run]; let notice: PageNotice?
    }

    static func page(text: String, language: String, window: PageWindow? = nil, extras: PageExtras = PageExtras(),
                     context: RenderContext) -> String {
        let appearance = context.appearance == .dark ? "dark" : "light"
        return """
        <!doctype html>
        <html data-appearance="\(appearance)"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src vitrine: 'wasm-unsafe-eval'; style-src 'unsafe-inline'; img-src data:; font-src vitrine: data:">
        <style>
        :root { \(DesignTokens.systemCSS(for: context.appearance)) color-scheme: \(appearance); }
        html, body { margin: 0; height: 100%; background: var(--v-page); }
        body { display: flex; flex-direction: column; }
        #vt-code { flex: 1; min-height: 0; }
        #vt-note { display: none; align-items: center; gap: 10px; padding: 6px 14px; font: 12px/1.4 -apple-system, system-ui;
                   color: var(--v-t2); background: var(--v-card2, var(--v-fill)); border-bottom: .5px solid var(--v-sep); }
        #vt-note select { font: inherit; margin-left: auto; }
        .cm-editor { height: 100%; background: var(--v-page); color: var(--v-t1); font: var(--v-fs-mono)/var(--v-fs-mono-lh) var(--v-mono); }
        .cm-editor.cm-focused { outline: none; }
        .cm-scroller { font-family: var(--v-mono); line-height: var(--v-fs-mono-lh); }
        .cm-gutters { background: var(--v-page); border: none; color: var(--v-t3); }
        .cm-lineNumbers .cm-gutterElement { padding: 0 10px 0 14px; font-variant-numeric: tabular-nums; }
        .cm-activeLineGutter { background: transparent; color: var(--v-t2); }
        .cm-content { padding: 6px 0 24px; }
        .cm-selectionBackground, .cm-focused .cm-selectionBackground, ::selection { background: var(--v-sel) !important; }
        .cm-searchMatch { background: var(--v-find); border-radius: 2px; }
        .cm-searchMatch-selected { background: var(--v-find-cur); }
        .cm-foldGutter .cm-gutterElement { width: 14px; color: var(--v-t3); cursor: default; text-align: center; }
        .vt-fold { font-size: 11px; }
        .cm-foldPlaceholder { background: var(--v-fill); border: none; color: var(--v-t2); border-radius: 4px; padding: 0 4px; }
        .cm-panels { display: none; }
        .vt-sticky { position: absolute; top: 0; left: 0; right: 0; z-index: 5; display: none; background: var(--v-page);
                     border-bottom: 0.5px solid var(--v-sep); box-shadow: 0 1px 3px rgba(0,0,0,.06); padding-left: 52px; }
        .vt-sticky-line { white-space: pre; overflow: hidden; text-overflow: ellipsis; color: var(--v-t2);
                          font: var(--v-fs-mono)/var(--v-fs-mono-lh) var(--v-mono); padding: 0 12px 0 6px; cursor: pointer; }
        .vt-sticky-line:hover { color: var(--v-t1); }
        .vt-ig { background-image: repeating-linear-gradient(to right, var(--vt-guide, var(--v-sep)) 0 1px, transparent 1px calc(var(--vt-tab, 4) * 1ch));
                 background-size: calc(var(--vt-depth) * var(--vt-tab, 4) * 1ch) 100%; background-repeat: no-repeat; background-position: 6px 0; }
        .vt-chg .cm-gutterElement { width: 3px; padding: 0 2px 0 4px; }
        .vt-chg-add, .vt-chg-mod { display: block; width: 3px; height: 100%; border-radius: 1px; }
        .vt-chg-add { background: var(--v-diff-add, #34C759); }
        .vt-chg-mod { background: var(--v-diff-chg, #007AFF); }
        .vt-chg-del { display: block; width: 0; height: 0; margin-top: calc(var(--v-fs-mono-lh) * 1em - 4px);
                      border-left: 4px solid var(--v-t3); border-top: 4px solid transparent; border-bottom: 4px solid transparent; }
        .vt-minimap { position: absolute; top: 0; right: 12px; width: 64px; z-index: 4; cursor: default; }
        .vt-has-minimap .cm-scroller { margin-right: 76px; }
        /* The shared ruler (C-8): the vertical scrollbar, drawn by Vitrine with its marks. */
        .vt-has-ruler .cm-scroller { margin-right: 12px; }
        .vt-has-ruler .cm-scroller::-webkit-scrollbar:vertical { width: 0; }
        .vt-ruler { position: absolute; top: 0; bottom: 0; right: 0; width: 12px; z-index: 5; border-left: .5px solid var(--v-sep);
                    background: var(--v-page); cursor: default; }
        .vt-ruler i { position: absolute; left: 2px; right: 2px; height: 3px; border-radius: 1px; pointer-events: none; }
        .vt-ruler i.f { background: var(--v-find-cur); opacity: .75; } .vt-ruler i.fc { background: var(--v-find-cur); height: 4px; }
        .vt-ruler i.caution { background: var(--v-caution); } .vt-ruler i.danger { background: var(--v-danger); }
        .vt-ruler i.add { background: var(--v-diff-add); } .vt-ruler i.chg { background: var(--v-diff-chg); }
        .vt-ruler i.del { background: var(--v-diff-del); height: 2px; } .vt-ruler i.sel { background: var(--v-accent); height: 4px; }
        .vt-ruler .thumb { position: absolute; left: 1px; right: 1px; border-radius: 4px; background: var(--v-fill2); min-height: 16px; }
        .vt-ruler:hover .thumb { background: var(--v-t3); opacity: .5; }
        .vt-tpop { position: fixed; right: 16px; bottom: 16px; z-index: 20; width: 312px; box-sizing: border-box; padding: 12px;
                   border-radius: 12px; font: 12px/1.35 -apple-system, system-ui, sans-serif; color: var(--v-t1);
                   background: var(--v-pop, var(--v-card)); box-shadow: var(--v-shadow-pop, 0 8px 30px rgba(0,0,0,.18)), 0 0 0 .5px var(--v-hair);
                   -webkit-backdrop-filter: blur(40px) saturate(1.8); max-height: calc(100% - 32px); overflow: auto; }
        .vt-tpop h6 { margin: 0 0 8px; font-size: 13px; font-weight: 650; }
        .vt-thg { display: grid; grid-template-columns: repeat(3, 1fr); gap: 6px; margin-bottom: 10px; }
        .vt-thw { all: unset; box-sizing: border-box; border-radius: 6px; padding: 5px 6px 4px; font: 10.5px/1.25 var(--v-mono);
                  box-shadow: 0 0 0 .5px var(--v-hair); white-space: nowrap; overflow: hidden; cursor: default; background: var(--v-card); }
        .vt-thw.on { box-shadow: 0 0 0 2px var(--v-accent); }
        .vt-morebtn { display: block; margin: 0 0 8px; font-size: 11.5px; }
        .vt-thn { display: block; font: 10.5px/1.3 -apple-system, system-ui; margin-top: 3px; overflow: hidden; text-overflow: ellipsis; }
        .vt-orow { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin: 6px 0; }
        .vt-olab { color: var(--v-t2); }
        .vt-font { display: flex; align-items: center; gap: 4px; }
        .vt-font select { font: inherit; max-width: 130px; }
        .vt-step { all: unset; width: 20px; height: 20px; text-align: center; border-radius: 5px; background: var(--v-fill); }
        .vt-size { min-width: 38px; text-align: center; font-variant-numeric: tabular-nums; }
        .vt-seg { display: inline-flex; background: var(--v-fill); border-radius: 7px; padding: 2px; }
        .vt-seg button { all: unset; padding: 1px 9px; border-radius: 5px; color: var(--v-t2); }
        .vt-seg button.on { background: var(--v-control, #fff); color: var(--v-t1); box-shadow: 0 0 0 .5px var(--v-hair); }
        .vt-togs { display: grid; grid-template-columns: 1fr 1fr; gap: 4px 10px; margin: 8px 0; }
        .vt-tog { display: flex; align-items: center; gap: 6px; }
        .vt-ofoot { display: flex; align-items: center; gap: 8px; border-top: .5px solid var(--v-sep); padding-top: 8px; margin-top: 4px; }
        .vt-btn { all: unset; padding: 2px 9px; border-radius: 6px; background: var(--v-fill); white-space: nowrap; }
        .vt-onote { color: var(--v-t3); font-size: 11px; }
        .vt-nomatch, .vt-level, .vt-run { font: 11px/1.6 -apple-system, system-ui; padding: 0 8px; color: var(--v-t3); background: var(--v-fill); }
        .vt-run { color: var(--v-t2); }
        .vt-lv { font-size: var(--v-fs-micro, 10.5px); font-weight: 500; }
        /* The level's colour wins over the grammar's colour on the same word (the Shiki span sits inside). */
        .vt-lv-warn, .vt-lv-warn * { color: var(--v-caution-text, #A05A00) !important; }
        .vt-lv-error, .vt-lv-error *, .vt-lv-fatal, .vt-lv-fatal * { color: var(--v-danger-text, #C4271B) !important; }
        .vt-lv-debug, .vt-lv-debug *, .vt-lv-trace, .vt-lv-trace * { color: var(--v-t2) !important; }
        .vt-lv-info, .vt-lv-info *, .vt-lv-notice, .vt-lv-notice * { color: var(--v-t2) !important; }
        .vt-gap { margin: 2px 0 2px 6px; font: 11px/1.8 -apple-system, system-ui; color: var(--v-t3);
                  border-top: .5px dashed var(--v-sep); border-bottom: .5px dashed var(--v-sep); padding-left: 6px; }
        #vt-syms { position: fixed; left: 50%; bottom: 14px; transform: translateX(-50%); z-index: 19; width: 300px; padding: 8px;
                   border-radius: 12px; font: 12px/1.35 -apple-system, system-ui; color: var(--v-t1); background: var(--v-pop, var(--v-card));
                   box-shadow: var(--v-shadow-pop, 0 8px 30px rgba(0,0,0,.18)), 0 0 0 .5px var(--v-hair); -webkit-backdrop-filter: blur(40px) saturate(1.8); }
        #vt-syms h6 { margin: 0 4px 6px; font-size: 11px; font-weight: 600; color: var(--v-t2); }
        .vt-sym { display: flex; align-items: center; gap: 8px; padding: 3px 6px; border-radius: 6px; }
        .vt-sym.on { background: var(--v-sel); }
        .vt-sk { width: 16px; height: 16px; border-radius: 4px; font: 600 9px/16px var(--v-mono); text-align: center; color: #fff; }
        .vt-sk-M { background: var(--v-syn-fn); } .vt-sk-C { background: var(--v-syn-ty); } .vt-sk-P { background: var(--v-syn-prop); }
        .vt-sn { flex: 1; font-family: var(--v-mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .vt-sl { color: var(--v-t3); font-size: 11px; font-variant-numeric: tabular-nums; }
        .vt-sym-none { color: var(--v-t3); padding: 3px 6px; }
        #vt-follow { all: unset; position: fixed; left: 50%; bottom: 14px; transform: translateX(-50%); z-index: 18; display: none;
                     padding: 3px 11px; border-radius: 11px; font: 500 11.5px/16px -apple-system, system-ui; color: var(--v-accent-text, #0A60D8);
                     background: var(--v-accent-soft, rgba(10,96,216,.12)); box-shadow: 0 0 0 .5px var(--v-hair); cursor: default; }
        #vt-loading { position: absolute; top: 0; left: 0; right: 0; z-index: 6; display: none; padding: 4px 14px;
                      font: 500 11px/16px var(--v-ui, -apple-system); color: var(--v-t2); background: var(--v-page);
                      border-bottom: 0.5px solid var(--v-sep); }
        </style></head>
        <body>\(PageStrings.block(PageStrings.code))<div id="vt-loading"></div><div id="vt-note"></div><div id="vt-code"></div>
        <script type="application/json" id="vt-config">\(scriptJSON(PageConfig(lang: language, fileName: extras.fileName, log: language == "log", original: extras.original, window: window, options: extras.options, fonts: extras.fonts,
                                                                       imported: extras.imported, changes: extras.changes, notice: extras.notice)))</script>
        <script type="application/json" id="vt-source">\(scriptJSON(text))</script>
        <script type="module" src="vitrine://app/code/code.js"></script>
        </body></html>
        """
    }

    // MARK: Page messages

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        receive(body)
    }

    /// The most milliseconds a first-paint report may claim (a day); a longer or broken one is not a measurement.
    static let maxReportedMilliseconds = 86_400_000

    /// One message from the page. Every number in it goes through `PageNumbers` with the range it can honestly have
    /// (S-16): a line inside the lines the page holds, a count no larger than those lines, an encoding from the list
    /// the page was offered. A message with a number outside its range is ignored.
    func receive(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            readyReport = (PageNumbers.integer(body["ms"], in: -1...Self.maxReportedMilliseconds) ?? -1, body["lang"] as? String)
            finish(true)
        case "selection":
            // "Ln 40–47 · 8 lines" on the gutter's right while more than one line is selected (code 1).
            let empty = body["empty"] as? Bool ?? true
            // File numbering: the page's first line is the shown text's first line.
            let lines = shownText.first...(shownText.first + shownLineCount - 1)
            guard let from = PageNumbers.integer(body["from"], in: lines),
                  let to = PageNumbers.integer(body["to"], in: from...lines.upperBound) else {
                // Not lines the page holds: nothing is offered as selected.
                selectedLines = nil
                setPageGutter(nil)
                break
            }
            selectedLines = empty ? nil : (from, to)
            if empty || from == to {
                setPageGutter(empty ? nil : GutterStatus(trailing: String(localized: "Ln \(from)", bundle: .previewKit,
                                                                                    comment: "Gutter: the line the cursor is on ('Ln' is short for line).")))
            } else {
                setPageGutter(GutterStatus(trailing: String(localized: "Ln \(from)–\(to) · \(to - from + 1) lines", bundle: .previewKit,
                                                            comment: "Gutter: the selected lines, then how many ('Ln' is short for line).")))
            }
        case "scroll":
            if let y = PageNumbers.scrollOffset(body["y"]) { lastScroll = y }
        case "window":
            // A window of a huge file (state 14): lines of that file, and no file has more lines than bytes plus one.
            guard let large else { break }
            let lines = 1...max(1, Int(clamping: large.size) &+ 1)
            guard let line = PageNumbers.integer(body["line"], in: lines), let first = PageNumbers.integer(body["first"], in: lines),
                  let dy = PageNumbers.number(body["dy"] ?? 0, in: -PageNumbers.maxPoints...PageNumbers.maxPoints) else { break }
            Task { await loadWindow(first: first, keeping: line, dy: dy, reveal: body["reveal"] as? Bool ?? false) }
        case "error":
            pageErrors.append(body["message"] as? String ?? "?")
        case "option":
            // Kept for every code file after this one (state 15); only a value of the kind the option takes.
            if let key = body["key"] as? String, let value = Self.optionValue(body["value"], for: key) { defaults?.set(value, forKey: "code." + key) }
        case "importTheme":
            importTheme()
        case "log":
            // Lines counted by level: no more of either than the lines the page holds.
            guard let errors = PageNumbers.integer(body["errors"] ?? 0, in: 0...shownLineCount),
                  let warnings = PageNumbers.integer(body["warnings"] ?? 0, in: 0...shownLineCount) else { break }
            logCounts = (errors, warnings)
            applyLogHeadline()
        case "formatted":
            // The page switched between the formatted text and the file's own; copy follows what is shown.
            if let on = body["on"] as? Bool, let original, case .code(let formatted, _)? = preview?.document.views.first {
                shownText = (on ? formatted : original, 1)
            }
        case "reopen":
            // Only an encoding the page was offered (`notice(for:url:language:)` lists TextEncodingDetector's choices).
            guard let raw = PageNumbers.integer(body["encoding"], in: 0...Int(UInt32.max)),
                  let encoding = TextEncodingDetector.choices.first(where: { $0.rawValue == UInt(raw) }) else { break }
            Task { await reopen(as: encoding) }
        default:
            break
        }
    }

    /// The value a display option may be saved with, checked as `CodeOptions(defaults:)` reads it back: a size in
    /// its range, a tab width it offers, a toggle as a boolean, a name as a short string. nil for an unknown key or a
    /// value of another kind (a null or a nested object would not even be a valid setting).
    static func optionValue(_ value: Any?, for key: String) -> Any? {
        switch key {
        case "fontSize": return PageNumbers.integer(value, in: 9...24)
        case "tabSize": return PageNumbers.integer(value, in: 2...8).flatMap { [2, 4, 8].contains($0) ? $0 : nil }
        case "wrap", "lineNumbers", "indentGuides", "changedLines", "sticky", "minimap":
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        case "lineHeight": return (value as? String).flatMap { ["tight", "normal", "roomy"].contains($0) ? $0 : nil }
        case "theme", "font": return (value as? String).flatMap { !$0.isEmpty && $0.count <= 200 ? $0 : nil }
        default: return nil
        }
    }

    // MARK: Huge files (state 14)

    /// Counts the lines in the background; the gutter says how far it has read, then which lines are shown.
    private func startIndexing() {
        guard let large else { return }
        let owner = WeakRef(self)
        indexing = Task { [weak self] in
            let all = ByteCountFormatter.string(fromByteCount: large.size, countStyle: .file)
            try? await large.index { _, bytes in
                Task { @MainActor in
                    guard let self = owner.value, self.findState.done else { return }
                    let read = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    self.setPageGutter(GutterStatus(leading: String(localized: "Counting lines… \(read) of \(all)", bundle: .previewKit,
                                                                    comment: "Gutter while a huge file's lines are counted: bytes read of the file's size.")))
                }
            }
            guard let self, !Task.isCancelled else { return }
            let total = await large.lineCount
            _ = try? await self.webView?.evaluateJavaScript("window.vitrine.setTotal(\(total.count), \(total.exact)); true")
            self.showWindowReadout()
        }
    }

    /// "Lines 1–4,096 of ≈31.2 M" on the gutter's left (the pill keeps the bytes shown).
    private func showWindowReadout() {
        guard let large else { return }
        Task { [weak self] in
            let total = await large.lineCount
            guard let self, self.findState.done else { return }
            let a = self.shownWindow.first, b = self.shownWindow.first + max(0, self.shownWindow.count - 1)
            let readout = total.exact
                ? String(localized: "Lines \(a)–\(b) of \(total.count)", bundle: .previewKit,
                         comment: "Gutter for a huge file: the lines shown of all its lines.")
                : String(localized: "Lines \(a)–\(b) of ≈\(total.count.formatted(.number.notation(.compactName)))", bundle: .previewKit,
                         comment: "Gutter for a huge file while its lines are still being counted: the lines shown of an estimate such as '31.2M'.")
            self.setPageGutter(GutterStatus(leading: readout))
        }
    }

    /// Reads the window from `first` and hands it to the page, keeping file line `line` where it was on screen.
    private func loadWindow(first: Int, keeping line: Int, dy: Double, reveal: Bool) async {
        guard let large, let web = webView else { return }
        // A jump past what has been counted waits for the count to get there.
        while await large.linesKnown < first, await !large.isIndexed { try? await Task.sleep(for: .milliseconds(50)) }
        guard let w = try? await large.window(from: first, count: Self.windowLines) else { return }
        let total = await large.lineCount
        shownWindow = (w.first, w.count)
        shownText = (w.text, w.first)
        let args: [String: Any] = ["first": w.first, "text": w.text, "total": total.count, "exact": total.exact,
                                   "line": line, "dy": dy, "reveal": reveal]
        _ = try? await web.callAsyncJavaScript("window.vitrine.setWindow(w); return true;", arguments: ["w": args], contentWorld: .page)
        showWindowReadout()
    }

    /// Find over a huge file: Swift reads the file in chunks, the capsule's count grows ("18 so far"), the gutter
    /// says how much has been searched and offers Cancel; Return steps through the matching lines, loading the window
    /// around each.
    private func streamingFind(_ query: String, forward: Bool) -> FindResult {
        guard let large else { return FindResult(count: 0, index: -1) }
        if query != findState.query {
            resetFind()
            findState = (query, [], -1, false, false)
            let size = large.size
            let owner = WeakRef(self)
            finding = Task { [weak self] in
                let final = try? await large.find(query) { progress in
                    Task { @MainActor in owner.value?.findProgressed(progress, size: size, query: query) }
                }
                guard let self, !Task.isCancelled, let final, self.findState.query == query else { return }
                self.findProgressed(final, size: size, query: query)
            }
            return FindResult(count: 0, index: -1, searchedAll: false, inProgress: true)
        }
        let n = findState.lines.count
        guard n > 0 else { return currentFindResult }
        findState.index = forward ? (findState.index + 1) % n : (findState.index - 1 + n) % n
        reveal(match: findState.lines[findState.index])
        return currentFindResult
    }

    private var currentFindResult: FindResult {
        FindResult(count: findState.lines.count, index: findState.index, searchedAll: !findState.capped,
                   inProgress: !findState.done)
    }

    private func findProgressed(_ p: LargeTextFile.FindProgress, size: Int64, query: String) {
        guard findState.query == query else { return }
        let firstMatch = findState.lines.isEmpty && !p.lines.isEmpty
        findState.lines = p.lines
        findState.done = p.done || p.capped
        findState.capped = p.capped
        if firstMatch { findState.index = 0; reveal(match: p.lines[0]) }
        preview?.updateFindResult(currentFindResult)
        if findState.done {
            showWindowReadout()
        } else {
            let read = ByteCountFormatter.string(fromByteCount: p.bytesSearched, countStyle: .file)
            let all = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            setPageGutter(GutterStatus(leading: String(localized: "Searching… \(read) of \(all)", bundle: .previewKit,
                                                       comment: "Gutter while find reads a huge file: bytes searched of the file's size."),
                                       busy: true))
        }
    }

    private func reveal(match line: Int) {
        guard let web = webView else { return }
        let q = findState.query
        Task { [weak self] in
            guard let self else { return }
            if line < self.shownWindow.first || line >= self.shownWindow.first + self.shownWindow.count {
                await self.loadWindow(first: max(1, line - Self.windowLines / 2), keeping: line, dy: 0, reveal: true)
            }
            _ = try? await web.callAsyncJavaScript("return window.vitrine.markMatch(q, n);", arguments: ["q": q, "n": line],
                                                   contentWorld: .page)
        }
    }

    /// Cancel (the gutter's) or Done: the search stops where it is; what it found stays counted.
    private func stopFind() {
        finding?.cancel()
        finding = nil
        if !findState.done {
            findState.done = true
            preview?.updateFindResult(currentFindResult)
        }
        if large != nil { showWindowReadout() }
    }

    /// Done, or the field emptied: the search stops and is forgotten.
    private func resetFind() {
        finding?.cancel()
        finding = nil
        findState = ("", [], -1, true, false)
        if large != nil { showWindowReadout() }
    }

    isolated deinit {
        indexing?.cancel()
        finding?.cancel()
    }

    // MARK: Hex (state 13)

    private(set) var container: CodeContainer?

    /// The page's own gutter line: shown unless Hex is, and put back when Hex is left.
    private var pageGutter: GutterStatus?

    private func setPageGutter(_ status: GutterStatus?) {
        pageGutter = status
        if container?.shownHex == nil { preview?.updateGutter(status) }
    }

    /// The same file in the hex inspector, made the first time it is asked for; nil = it could not be read.
    private func showHex() -> Bool {
        guard let url = fileURL, let container else { return false }
        if container.hex == nil {
            guard let hex = try? HexView.make(url: url) else { return false }
            hex.onGutter = { [weak self] status in
                guard let self, self.container?.shownHex != nil else { return }
                self.preview?.updateGutter(status)
            }
            container.hex = hex
        }
        container.show(hex: true)
        preview?.updateGutter(container.hex?.gutterStatus())
        return true
    }

    // MARK: Follow tail (state 12)

    /// The file changed on disk (FileMonitor): lines added at the end are appended and followed when the view was at
    /// the end; anything else replaces the text where it stands. A huge file is counted again from its new size.
    func reloadFile(_ url: URL) async throws -> PreviewDocument {
        guard let web = webView, let kind = fileKind, let current = preview?.document else { throw RenderError.unreadable(url) }
        if large != nil {
            indexing?.cancel()
            large = try LargeTextFile(url: url)
            startIndexing()
            var document = current
            let size = large?.size ?? 0
            document.facts.removeAll { $0.key == "size" }
            document.facts.insert(DocumentFacts.size(size), at: 0)
            return document
        }
        let (document, text, language) = try readWhole(url: url, kind: kind)
        let before = shownText.text
        if original == nil, text.count > before.count, text.hasPrefix(before) {
            let tail = String(text.dropFirst(before.count))
            _ = try? await web.callAsyncJavaScript("return window.vitrine.appendText(t);", arguments: ["t": tail], contentWorld: .page)
            growing = true
        } else {
            _ = try? await web.callAsyncJavaScript("window.vitrine.replaceText(t, null); return true;", arguments: ["t": text], contentWorld: .page)
        }
        shownText = (text, 1)
        let shown = Self.shaped(document, text: text, language: language)
        return language == "log" ? withLogHeadline(shown) : shown
    }

    /// The file has grown while it was open (the pill adds "growing").
    private var growing = false

    // MARK: Logs (state 11)

    /// Errors and warnings the page counted; nil until it has.
    private var logCounts: (errors: Int, warnings: Int)?

    /// The pill: "1,204 lines · 3 errors" (or warnings when there are no errors), "growing" once lines arrive.
    private func applyLogHeadline() {
        guard logCounts != nil, let document = preview?.document else { return }
        let next = withLogHeadline(document)
        guard next.fact("headline")?.value != document.fact("headline")?.value else { return }
        preview?.updateDocument(next)
    }

    private func withLogHeadline(_ document: PreviewDocument) -> PreviewDocument {
        guard let counts = logCounts else { return document }
        var document = document
        // Each part one whole phrase (H-6); " · " is the pill's list separator.
        var parts: [String] = []
        if let lines = document.fact("lines")?.value {
            // The line count arrives formatted, so the one-line phrase is its own.
            parts.append(lines == "1"
                         ? String(localized: "1 line", bundle: .previewKit, comment: "Log pill: the file has one line.")
                         : String(localized: "\(lines) lines", bundle: .previewKit, comment: "Log pill: how many lines; the count arrives formatted."))
        }
        if growing { parts.append(String(localized: "growing", bundle: .previewKit, comment: "Log pill: lines are still being added to the file (lower case).")) }
        if counts.errors > 0 {
            parts.append(String(localized: "\(counts.errors) errors", bundle: .previewKit, comment: "Log pill: how many error lines."))
        } else if counts.warnings > 0 {
            parts.append(String(localized: "\(counts.warnings) warnings", bundle: .previewKit, comment: "Log pill: how many warning lines."))
        }
        document.facts.removeAll { $0.key == "headline" }
        document.facts.append(Fact(key: "headline", label: String(localized: "Log", bundle: .previewKit, comment: "Fact label: a log file's summary."),
                                   value: parts.joined(separator: " · ")))
        return document
    }

    // MARK: Encoding (state 3)

    private(set) var fileURL: URL?
    private(set) var fileLanguage = "plaintext"
    /// What the page holds now: its text and the file line of its first line (1 unless a window of a huge file).
    private(set) var shownText = (text: "", first: 1) {
        didSet { shownLineCount = Self.lineCount(shownText.text) }
    }
    /// The lines in `shownText`, counted as the page's editor counts them; a selection or a log count the page
    /// reports is held to them.
    private(set) var shownLineCount = 1

    /// Lines as CodeMirror splits a document: at "\r\n", "\r" and "\n"; an empty text is one line.
    nonisolated static func lineCount(_ text: String) -> Int {
        var lines = 1
        var afterCR = false
        for byte in text.utf8 {
            if byte == 0x0D || (byte == 0x0A && !afterCR) { lines += 1 }
            afterCR = byte == 0x0D
        }
        return lines
    }
    /// The selected lines in file numbering; nil when nothing is selected.
    private(set) var selectedLines: (from: Int, to: Int)?
    /// The editors "open at line" offers (X-3), asked of VitrineHelper once the page is up.
    var installedEditors: [HelperRules.Editor] = []
    /// Where a helper action's refusal is shown: the gutter, for a few seconds.
    var reportAction: (String?) -> Void = { _ in }
    private var fileKind: FileKind?

    /// "Reopen as…": the file read again in the chosen encoding, the text replaced in place.
    func reopen(as encoding: String.Encoding) async {
        guard let url = fileURL, let kind = fileKind, large == nil, let web = webView,
              let document = try? PlainTextRenderer.textDocument(url: url, kind: kind, encoding: encoding) else { return }
        self.encoding = encoding
        let text = PlainTextRenderer.shownText(document)
        shownText = (text, 1)
        let note = String(localized: "Read as \(TextEncodingDetector.name(of: encoding)), chosen.", bundle: .previewKit,
                          comment: "Encoding notice after Reopen as: the encoding the person chose.")
        _ = try? await web.callAsyncJavaScript("window.vitrine.replaceText(t, n); return true;", arguments: ["t": text, "n": note],
                                               contentWorld: .page)
        preview?.updateDocument(document)
    }

    // MARK: Themes (state 15)

    private var defaults: UserDefaults?

    /// Import theme…: in the Vitrine window an open panel; a Quick Look preview cannot show one, so it says where.
    private func importTheme() {
        guard let web = webView else { return }
        guard !Bundle.main.bundlePath.hasSuffix(".appex"), let window = web.window else {
            showPageNote(String(localized: "Import editor themes in the Vitrine app's window; they then appear here.", bundle: .previewKit,
                                comment: "Note in a Quick Look preview, which cannot show an open panel."))
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .propertyList, UTType(filenameExtension: "tmTheme") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a VS Code, Zed or TextMate theme. It stays on this Mac.", bundle: .previewKit,
                               comment: "Message of the open panel for importing an editor theme.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self, let defaults = self.defaults else { return }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let themes = try CodeThemeImport.read(data, fileName: url.lastPathComponent)
                CodeThemeImport.store(themes, in: defaults)
                self.showPageNote(String(localized: "Imported \(themes.map(\.name).formatted(.list(type: .and))). It is in the theme list from the next file.",
                                         bundle: .previewKit, comment: "Note after importing editor themes; the argument lists their names."))
            } catch {
                self.showPageNote((error as? LocalizedError)?.errorDescription
                                  ?? String(localized: "That theme could not be read.", bundle: .previewKit, comment: "Note when an imported theme file fails."))
            }
        }
    }

    private func showPageNote(_ text: String) {
        Task { [weak webView] in
            _ = try? await webView?.callAsyncJavaScript(
                "const n = document.querySelector('.vt-onote'); if (n) n.textContent = t; return true;",
                arguments: ["t": text], contentWorld: .page)
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

    /// Only the page's own first load is allowed (the HTML string at `documentBase`); a link or anything the page
    /// tries to open afterwards is cancelled.
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if !firstLoadAllowed, action.targetFrame?.isMainFrame == true, action.request.url == PreviewSchemeHandler.documentBase {
            firstLoadAllowed = true
            return .allow
        }
        return .cancel
    }
    private var firstLoadAllowed = false
}

/// The code view's root: the page, and the hex inspector over it when Hex is picked (state 13). roadmap: S-5
@MainActor
final class CodeContainer: NSView {
    let web: WKWebView
    var hex: HexView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let hex else { return }
            hex.translatesAutoresizingMaskIntoConstraints = false
            hex.isHidden = true
            addSubview(hex)
            NSLayoutConstraint.activate([hex.leadingAnchor.constraint(equalTo: leadingAnchor), hex.trailingAnchor.constraint(equalTo: trailingAnchor),
                                         hex.topAnchor.constraint(equalTo: topAnchor), hex.bottomAnchor.constraint(equalTo: bottomAnchor)])
        }
    }
    /// The hex inspector when it is the view on screen.
    var shownHex: HexView? { hex?.isHidden == false ? hex : nil }

    init(web: WKWebView) {
        self.web = web
        super.init(frame: .zero)
        web.translatesAutoresizingMaskIntoConstraints = false
        addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: leadingAnchor), web.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     web.topAnchor.constraint(equalTo: topAnchor), web.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(hex on: Bool) {
        hex?.isHidden = !on
        web.isHidden = on
    }
}

/// A weak reference a progress closure can carry across actors; read only on the main actor.
private final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Keeps the page's message handler from retaining the renderer (WKUserContentController holds it strongly).
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}
