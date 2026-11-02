import AppKit
import VitrineDocument
import VitrineSupport
import VitrineUI
import WebKit

/// Agent sessions (parity H-5 preview, B-9; design ai.html states 1, 3 and 4): a Claude Code or Codex transcript
/// opens as its conversation; the capsule's viewer switch adds Changes (every edit the session made, as the diff page
/// draws a patch, through DiffRenderer) and Source (the JSONL itself, in the native text view).
///
/// Which files: `.jsonl` / `.ndjson` whose first lines are a Claude Code or Codex transcript (SessionParser.detect).
/// The registry sends it `.code(language: "jsonl")` (see canRender); a JSON Lines file that is not a session goes on
/// to the structured tree (read as JSON Lines), so only agent sessions look different.
/// The page is static and locked down (G-9): no script runs in it; find and the ⌥↑/⌥↓ prompt jumps are evaluated from
/// here. roadmap: S-11
@MainActor
public final class SessionRenderer: NSObject, Renderer, WKNavigationDelegate {
    /// JSON Lines by kind: `.code(language: "jsonl")`, which FileSniffer gives `.jsonl` / `.ndjson` once it maps
    /// them (a one-line hook outside this family: today they sniff as plain text, so the registry does not route them
    /// here yet). Plain text and JSON are not taken: the registry keeps sending those where it did.
    public static func canRender(_ kind: FileKind) -> Bool {
        if case .code(let language) = kind {
            return ["jsonl", SessionSource.claudeCode.kindLanguage, SessionSource.codex.kindLanguage].contains(language)
        }
        return false
    }

    /// File extensions a transcript can have.
    static let extensions: Set<String> = ["jsonl", "ndjson"]

    public override required init() { super.init() }

    nonisolated(unsafe) static var readyTimeout: Duration = .seconds(3)

    private(set) var session: AgentSession?
    private(set) var files: [SessionChanges.File] = []
    private(set) var conversation: SessionWebView?
    private var container: SessionContainerView?
    /// The Changes view: the diff page's own preview, made the first time it is asked for.
    private(set) var changes: RenderedPreview?
    private var changesRenderer: DiffRenderer?
    private var changesTask: Task<Void, Never>?
    private var context: RenderContext?
    private var url: URL?
    private var ready: CheckedContinuation<Bool, Never>?
    private var firstLoadAllowed = false
    /// 0 = Conversation, 1 = Changes (only when the session changed files).
    private(set) var shown = 0
    /// The viewer switch's titles, in order.
    private(set) var titles: [String] = []

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        let named = Self.extensions.contains(url.pathExtension.lowercased())
        let isSessionKind: Bool = { if case .code(let l) = kind { return l.hasSuffix("-session") } else { return false } }()
        let parsed: AgentSession? = named || isSessionKind
            ? try? await Task.detached(priority: .userInitiated) { try SessionParser.parse(url: url, limits: .preview) }.value
            : nil
        guard let parsed else { return try await Self.delegate(url: url, kind: kind, context: context) }
        let built = await Task.detached(priority: .userInitiated) { () -> ([SessionChanges.File], String) in
            let files = SessionChanges.files(parsed)
            return (files, SessionPage.html(parsed, files: files, appearance: context.appearance))
        }.value
        session = parsed
        files = built.0
        self.context = context
        self.url = url
        titles = ["Conversation"]
            + (files.isEmpty ? [] : ["Changes"])
            + ["Source"]
        let document = Self.document(url: url, session: parsed, files: files, titles: titles)

        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        try await PageLockdown.apply(to: config)
        let web = SessionWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = NSColor.token("win")
        web.onJump = { [weak self] forward in self?.jump(forward: forward) }
        conversation = web
        web.loadHTMLString(built.1, baseURL: PreviewSchemeHandler.documentBase)
        let started = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            ready = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.readyTimeout)
                self?.finish(false)
            }
        }
        guard started else { return try await Self.delegate(url: url, kind: kind, context: context) }

        let container = SessionContainerView(main: web)
        self.container = container
        let preview = RenderedPreview(
            view: container, document: document, owner: self,
            find: { [weak self] q, forward in await self?.find(q, forward: forward) ?? FindResult(count: 0, index: -1) },
            clearFind: { [weak self] in self?.clearFind() },
            showView: { [weak self] index in self?.show(index) ?? false })
        preview.copyFormats = { [weak self] in
            self?.copyOffer() ?? (String(localized: "Copy as", bundle: .previewKit, comment: "Heading of the Copy as menu."), [])
        }
        if let leading = Self.coverageLine(parsed) { preview.updateGutter(GutterStatus(leading: leading)) }
        return preview
    }

    /// The renderer the registry picks when this one is left out.
    static func delegate(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        // Any other JSON Lines file: the structured tree, which reads `.jsonl` by its extension.
        let kind = kind == .code(language: "jsonl") ? .code(language: "json") : kind
        guard let other = RendererRegistry.renderers.first(where: { ObjectIdentifier($0) != ObjectIdentifier(SessionRenderer.self) && $0.canRender(kind) })
        else { throw RenderError.unsupported(kind) }
        return try await other.init().render(url: url, kind: kind, context: context)
    }

    // MARK: Document

    static func document(url: URL, session s: AgentSession, files: [SessionChanges.File], titles: [String]) -> PreviewDocument {
        let size = s.fileSize
        var facts = [DocumentFacts.size(size), DocumentFacts.tokens(bytes: Int(size))]
        facts.append(Fact(key: "title", label: String(localized: "Title", bundle: .previewKit, comment: "Fact label: the session's title."), value: s.title))
        if let p = s.project {
            facts.append(Fact(key: "project", label: String(localized: "Project", bundle: .previewKit, comment: "Fact label: the project folder the session ran in."), value: p))
        }
        if let b = s.branch {
            facts.append(Fact(key: "branch", label: String(localized: "Branch", bundle: .previewKit, comment: "Fact label: the current git branch."), value: b))
        }
        if let m = s.model {
            facts.append(Fact(key: "model", label: String(localized: "Model", bundle: .previewKit, comment: "Fact label: the AI model the session used."), value: SessionParser.modelName(m)))
        }
        facts.append(Fact(key: "turns", label: String(localized: "Turns", bundle: .previewKit, comment: "Session header fact label: how many turns the session took."), value: s.turns.formatted()))
        let adds = files.reduce(0) { $0 + $1.additions }, dels = files.reduce(0) { $0 + $1.deletions }
        let fileCount = files.count.formatted(), added = adds.formatted(), removed = dels.formatted()
        let changes = files.isEmpty ? String(localized: "No files", bundle: .previewKit, comment: "Session header: no files were edited.")
            : files.count == 1 ? String(localized: "\(fileCount) file · +\(added) −\(removed)", bundle: .previewKit, comment: "Fact value: one file edited, lines added and removed.")
            : String(localized: "\(fileCount) files · +\(added) −\(removed)", bundle: .previewKit, comment: "Fact value: how many files were edited, lines added and removed.")
        facts.append(Fact(key: "changes", label: String(localized: "Edited", bundle: .previewKit, comment: "Session header fact label: the files the session edited."), value: changes))
        facts.append(Fact(key: "toolCalls", label: String(localized: "Tool calls", bundle: .previewKit, comment: "Session header fact label: how many tools the agent called."), value: s.tools.count.formatted()))
        if let started = s.started {
            facts.append(Fact(key: "started", label: String(localized: "Started", bundle: .previewKit, comment: "Fact label: when the session started."),
                              value: started.formatted(date: .abbreviated, time: .shortened)))
        }
        var badges: [Badge] = []
        if s.maskedSecrets > 0 {
            let count = s.maskedSecrets.formatted()
            badges.append(Badge(level: .danger,
                                title: s.maskedSecrets == 1
                                    ? String(localized: "\(count) secret in this session", bundle: .previewKit, comment: "Session danger group title: one secret was masked.")
                                    : String(localized: "\(count) secrets in this session", bundle: .previewKit, comment: "Session danger group title: how many secrets were masked."),
                                detail: String(localized: "Masked in the preview; Vitrine never shows the value.", bundle: .previewKit, comment: "Badge detail: secrets in a session are masked.")))
        }
        let failed = s.tools.filter(\.isError).count
        if failed > 0 {
            let count = failed.formatted()
            badges.append(Badge(level: .caution,
                                title: failed == 1
                                    ? String(localized: "\(count) tool call failed", bundle: .previewKit, comment: "Badge title: one of the session's tool calls failed.")
                                    : String(localized: "\(count) tool calls failed", bundle: .previewKit, comment: "Badge title: how many of the session's tool calls failed."),
                                detail: String(localized: "Shown on the danger inset; Show opens its output.", bundle: .previewKit, comment: "Badge detail: where failed tool calls are drawn; “Show” is the button on them.")))
        }
        let source = String(decoding: (try? Data(contentsOf: url, options: .mappedIfSafe))?.prefix(8 << 20) ?? Data(), as: UTF8.self)
        // The renderer draws the Conversation and Changes views itself; their text is what find, copying, token
        // counts and the Claude connector read: the conversation as text first (X-9).
        var views: [DocumentView] = titles.dropLast().enumerated().map { $0.offset == 0 ? .text(SessionText.transcript(s)) : .text("") }
        views.append(.code(source, language: "json"))
        var document = PreviewDocument(kind: .code(language: s.source.kindLanguage), facts: facts, badges: badges, views: views,
                                       coverage: s.isComplete ? .complete : .partial(shown: s.bytesRead, total: s.fileSize, unit: .bytes, reason: String(localized: "Read from the start", bundle: .previewKit, comment: "Coverage note: a large session is read from its start, up to a limit.")))
        document.viewTitles = titles
        // A-4: the whole file's estimate, kept in the `tokens` fact's place, for the Details meter.
        document.setTokens(TokenCounting.count(.byteCount(Int(size))))
        return document
    }

    static func coverageLine(_ s: AgentSession) -> String? {
        if !s.isComplete { return SessionPage.readText(s) }
        if s.itemsCut {
            let count = s.items.count.formatted()
            return String(localized: "\(count) rows drawn", bundle: .previewKit, comment: "Status line: only this many rows of a long session are drawn.")
        }
        return nil
    }

    // MARK: Views

    /// The viewer switch: Conversation, Changes (drawn here), Source (false: the host shows it as text).
    func show(_ index: Int) -> Bool {
        guard let container else { return false }
        let changesIndex = files.isEmpty ? nil : 1
        if index == 0 {
            shown = 0
            container.showMain()
            return true
        }
        guard index == changesIndex else { return false }
        shown = 1
        if let changes { container.showOther(changes.view); return true }
        container.showOther(nil)
        if changesTask == nil { changesTask = Task { [weak self] in await self?.makeChanges() } }
        return true
    }

    /// Writes the session's patch to a temporary file and has the diff page draw it.
    func makeChanges() async {
        guard let session, let context else { return }
        let patch = SessionChanges.patch(session, mail: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Vitrine Sessions", isDirectory: true)
        let name = (session.id ?? UUID().uuidString).replacingOccurrences(of: "/", with: "-")
        let file = folder.appendingPathComponent("\(name) changes.patch")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(patch.utf8).write(to: file, options: .atomic)
            let renderer = DiffRenderer()
            let preview = try await renderer.render(url: file, kind: .diff, context: context)
            changesRenderer = renderer
            changes = preview
            if shown == 1 { container?.showOther(preview.view) }
        } catch {
            NSLog("Vitrine could not draw the session's changes: %@", "\(error)")
        }
        changesTask = nil
    }

    /// Waits until the Changes view is drawn (tests and the snapshot path).
    func changesReady() async { await changesTask?.value }

    // MARK: Find and jumps

    func find(_ query: String, forward: Bool) async -> FindResult {
        if shown == 1, let changes, let find = changes.find { return await find(query, forward) }
        guard let web = conversation else { return FindResult(count: 0, index: -1) }
        let r = try? await web.callAsyncJavaScript(Self.findScript, arguments: ["q": query, "f": forward], contentWorld: .page) as? [String: Any]
        let found = PageNumbers.matches(r)
        return FindResult(count: found.count, index: found.index)
    }

    func clearFind() {
        if shown == 1 { changes?.clearFind?(); return }
        Task { _ = try? await conversation?.callAsyncJavaScript(Self.clearScript, arguments: [:], contentWorld: .page) }
    }

    /// ⌥↓ / ⌥↑: the next or previous prompt brought to the top.
    func jump(forward: Bool) {
        Task { _ = try? await conversation?.callAsyncJavaScript(Self.jumpScript, arguments: ["f": forward], contentWorld: .page) }
    }

    /// Marks every match in the conversation (opening folded rows that hold the current one) and steps through them.
    static let findScript = """
    const root = document.getElementById('vt-s');
    let st = window.__vtFind;
    if (!st || st.q !== q) {
      for (const m of root.querySelectorAll('mark.vt-find')) { m.replaceWith(document.createTextNode(m.textContent)); }
      root.normalize();
      st = window.__vtFind = { q: q, marks: [], cur: -1 };
      if (q.length) {
        const lower = q.toLowerCase();
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        const nodes = []; let n;
        while ((n = walker.nextNode())) nodes.push(n);
        for (const node of nodes) {
          const text = node.nodeValue, low = text.toLowerCase();
          let at = low.indexOf(lower); if (at < 0) continue;
          const frag = document.createDocumentFragment(); let last = 0;
          while (at >= 0) {
            frag.appendChild(document.createTextNode(text.slice(last, at)));
            const m = document.createElement('mark'); m.className = 'vt-find'; m.textContent = text.slice(at, at + q.length);
            frag.appendChild(m); st.marks.push(m); last = at + q.length; at = low.indexOf(lower, last);
          }
          frag.appendChild(document.createTextNode(text.slice(last)));
          node.replaceWith(frag);
        }
      }
    }
    if (!st.marks.length) return { count: 0, index: -1 };
    if (st.cur >= 0) st.marks[st.cur].classList.remove('cur');
    st.cur = st.cur < 0 ? (f ? 0 : st.marks.length - 1) : (st.cur + (f ? 1 : -1) + st.marks.length) % st.marks.length;
    const cur = st.marks[st.cur]; cur.classList.add('cur');
    for (let p = cur.parentElement; p; p = p.parentElement) { if (p.tagName === 'DETAILS') p.open = true; }
    cur.scrollIntoView({ block: 'center' });
    return { count: st.marks.length, index: st.cur };
    """

    static let clearScript = """
    const root = document.getElementById('vt-s');
    for (const m of root.querySelectorAll('mark.vt-find')) { m.replaceWith(document.createTextNode(m.textContent)); }
    root.normalize(); window.__vtFind = null; return true;
    """

    static let jumpScript = """
    const prompts = Array.from(document.querySelectorAll('.rr.user'));
    if (!prompts.length) return -1;
    const y = window.scrollY + 4;
    const tops = prompts.map(p => p.getBoundingClientRect().top + window.scrollY);
    let i = f ? tops.findIndex(t => t > y + 2) : tops.map((t, k) => [t, k]).filter(([t]) => t < y - 2).map(([, k]) => k).pop();
    if (i === undefined || i < 0) i = f ? prompts.length - 1 : 0;
    window.scrollTo(0, tops[i] - 8);
    return i;
    """

    // MARK: Copy as

    func copyOffer() -> (heading: String, formats: [CopyFormat]) {
        let heading = String(localized: "Copy as", bundle: .previewKit, comment: "Heading of the Copy as menu.")
        guard let session else { return (heading, []) }
        var formats = [CopyFormat(title: String(localized: "Conversation as Markdown", bundle: .previewKit, comment: "Copy as menu item: the session's prompts and replies as Markdown.")) { Self.markdown(session) }]
        if !files.isEmpty {
            let patch = SessionChanges.patch(session)
            let count = files.count.formatted()
            let title = files.count == 1
                ? String(localized: "Changes as a patch (\(count) file)", bundle: .previewKit, comment: "Copy as menu item: the session's file changes as a patch, one file.")
                : String(localized: "Changes as a patch (\(count) files)", bundle: .previewKit, comment: "Copy as menu item: the session's file changes as a patch; the argument is how many files.")
            formats.append(CopyFormat(title: title) { patch })
        }
        if let url {
            formats.append(CopyFormat(title: String(localized: "Reveal in Finder", bundle: .previewKit, comment: "Copy as menu item: show the session file in Finder.")) { _ in
                NSWorkspace.shared.activateFileViewerSelecting([url]); return false
            })
        }
        return (heading, formats)
    }

    /// Prompts and replies, with one line per tool call; secrets stay masked.
    static func markdown(_ s: AgentSession) -> String {
        var out = ["# \(s.title)", ""]
        let you = String(localized: "You", bundle: .previewKit, comment: "Session conversation: the person's own prompts are labelled You.")
        for item in s.items {
            switch item {
            case .prompt(let t, _): out += ["**\(you):** \(t)", ""]
            case .reply(let t, _): out += [t, ""]
            case .tool(let i): out.append("- \(s.tools[i].name) `\(s.tools[i].argument)`" + (s.tools[i].result.map { " — \($0)" } ?? ""))
            case .note(let t, _): out.append("_\(t)_")
            case .thinking: break
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Navigation

    private func finish(_ ok: Bool) {
        guard let ready else { return }
        self.ready = nil
        ready.resume(returning: ok)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(false) }

    /// Only the page's own first load; every link or other navigation is cancelled.
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if !firstLoadAllowed, action.targetFrame?.isMainFrame == true {
            firstLoadAllowed = true
            return .allow
        }
        return .cancel
    }
}

/// The conversation's web view: ⌥↑ and ⌥↓ jump between prompts; every other key goes to WebKit.
final class SessionWebView: WKWebView {
    var onJump: ((Bool) -> Void)?
    override func keyDown(with event: NSEvent) {
        let option = event.modifierFlags.intersection([.option, .command, .control, .shift]) == .option
        if option, event.keyCode == 126 || event.keyCode == 125 { onJump?(event.keyCode == 125); return }
        super.keyDown(with: event)
    }
}

/// Holds the conversation and, once asked for, the Changes page; one shows at a time.
final class SessionContainerView: NSView {
    let main: NSView
    private(set) var other: NSView?

    init(main: NSView) {
        self.main = main
        super.init(frame: .zero)
        fill(main)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func fill(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }

    func showMain() {
        other?.isHidden = true
        main.isHidden = false
    }

    /// Shows `view` in place of the conversation (nil: nothing yet, while the page is made).
    func showOther(_ view: NSView?) {
        main.isHidden = true
        if let view, view !== other {
            other?.removeFromSuperview()
            other = view
            fill(view)
        }
        other?.isHidden = view == nil
    }
}
