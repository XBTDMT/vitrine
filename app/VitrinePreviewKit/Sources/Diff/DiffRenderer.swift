import AppKit
import VitrineDocument
import VitrineSupport
import VitrineText
import VitrineUI
import WebKit

/// Patches and diffs in the picked diff design (r3-b Summary sibling, G-16): a locked-down page (G-9) with the lead,
/// the Checks group, the "what changed" list that follows the detail, and every file's hunks with sticky headers,
/// folds, unified or split rows and intra-line marks, coloured by the code view's Shiki in the unified palette. The
/// patch is read by the engine (VitrineText/Diff) in Swift; each file's rows go to the page when it scrolls near
/// them. The capsule carries Unified / Split, find, Copy as and the gutter ("1 of 5" files, "40 of 1,284 files").
/// Fails visible: if the page does not start, the patch shows as text. roadmap: S-7
@MainActor
public final class DiffRenderer: NSObject, Renderer, WKNavigationDelegate, WKScriptMessageHandler {
    public static func canRender(_ kind: FileKind) -> Bool { kind == .diff }

    public override required init() { super.init() }

    nonisolated(unsafe) static var readyTimeout: Duration = .seconds(3)
    /// Files whose rows go with the first paint; the rest follow as they scroll near.
    static let firstFiles = 4

    private(set) var webView: WKWebView?
    private var schemeHandler: PreviewSchemeHandler?
    private var ready: CheckedContinuation<Bool, Never>?
    private weak var preview: RenderedPreview?
    private var lastScroll: Double?
    private var patch: Patch?
    /// The files the page's rows come from: the patch's, or the one file of a two-file compare.
    private var files: [DiffFile] = []
    private var comparison: TextComparison?
    private var checks = DiffChecks.Result(findings: [], masked: [:])
    private var sent = Set<Int>()
    private var fileURL: URL?
    /// The file the detail is showing (0-based), from the page.
    private(set) var currentFile = 0
    public private(set) var pageErrors: [String] = []

    public func render(url: URL, kind: FileKind, context: RenderContext) async throws -> RenderedPreview {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let parsed = await Task.detached(priority: .userInitiated) { PatchParser.parse(data) }.value
        let found = await Task.detached(priority: .userInitiated) { DiffChecks.scan(parsed) }.value
        patch = parsed
        files = parsed.files
        checks = found
        fileURL = url
        let model = DiffPage.make(patch: parsed, fileName: url.lastPathComponent, checks: found)
        let document = Self.document(url: url, patch: parsed, checks: found)
        return try await start(model: model, document: document, root: url.deletingLastPathComponent(), context: context) {
            try await PlainTextRenderer().render(url: url, kind: kind, context: context)
        }
    }

    /// Two files compared (X-11, the design's two-file states): text by lines, with identical and whitespace-only
    /// files said in words; the same lead, list and detail as a patch.
    public func compare(old: URL, new: URL, context: RenderContext) async throws -> RenderedPreview {
        let a = try Data(contentsOf: old, options: .mappedIfSafe), b = try Data(contentsOf: new, options: .mappedIfSafe)
        let (oldName, newName) = (old.lastPathComponent, new.lastPathComponent)
        let result = await Task.detached(priority: .userInitiated) {
            TextCompare.compare(old: a, new: b, oldName: oldName, newName: newName)
        }.value
        comparison = result
        files = result.status == .identical ? [] : [result.file]
        fileURL = new
        compareURLs = (old, new)
        var model = DiffPage.make(comparison: result, oldName: oldName, newName: newName, oldBytes: a, newBytes: b)
        var document = Self.document(comparison: result, oldName: oldName, newName: newName)
        // JSON, YAML, TOML, plists, Markdown, notebooks and images: compared by meaning, the line diff one switch away.
        let (rich, fallbackReason) = result.status == .identical ? (nil, nil)
            : await Task.detached(priority: .userInitiated) { RichCompare.make(old: old, new: new, a: a, b: b) }.value
        if let rich {
            let lead = rich.lead(oldName: oldName, newName: newName)
            model.rich = rich
            model.lead = DiffPage.Lead(state: "calm", sentence: lead.sentence, subject: nil, meta: lead.meta, message: nil,
                                       additions: 0, deletions: 0)
            model.compare = DiffPage.Compare(oldName: oldName, newName: newName, items: lead.items, hidden: false, reveal: nil)
            if rich.type == .image || rich.type == .notebook { files = [] }
            document.facts.removeAll { $0.key == "headline" }
            document.facts.insert(Fact(key: "headline", label: Self.compareLabel, value: lead.headline), at: 0)
            document.views = rich.modes.map { _ in .text("") }
            // The modes are identifiers the page knows them by; the viewer switch shows them localized (CapsuleView).
            document.viewTitles = rich.modes
            modes = rich.modes
            self.rich = true
        } else if let fallbackReason {
            model.notice = DiffPage.Notice(title: String(localized: "Compared as text", bundle: .previewKit,
                                                         comment: "Notice title: a compare by meaning failed, so the files are compared line by line."),
                                           detail: fallbackReason)
        }
        return try await start(model: model, document: document, root: new.deletingLastPathComponent(), context: context) {
            throw RenderError.unreadable(new)
        }
    }

    private var compareURLs: (URL, URL)?
    /// The viewer switch's modes, by the page's names (a patch's and a text compare's are Unified and Split).
    private var modes = ["Unified", "Split"]
    /// A compare by meaning is on the page (its list counts its own changes; the gutter stays quiet).
    private var rich = false

    /// The page, its first rows, and the capsule's wiring; `fallback` when the page does not start.
    private func start(model: DiffPage, document: PreviewDocument, root: URL, context: RenderContext,
                       fallback: () async throws -> RenderedPreview) async throws -> RenderedPreview {
        let first = (0..<min(Self.firstFiles, files.count)).map { DiffPage.rows(files[$0], index: $0, checks: checks) }
        sent = Set(first.map(\.index))
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false
        let handler = PreviewSchemeHandler(documentRoot: root)
        schemeHandler = handler
        config.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.scheme)
        try await PageLockdown.apply(to: config)
        config.userContentController.add(WeakScriptHandler(self), name: "vitrine")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = NSColor.token("page")
        webView = web
        web.loadHTMLString(Self.page(model: model, first: first, context: context), baseURL: PreviewSchemeHandler.documentBase)
        let started = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            ready = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.readyTimeout)
                self?.finish(false)
            }
        }
        guard started else { return try await fallback() }

        let views = document.viewTitles?.count ?? 1
        let preview = RenderedPreview(
            view: web, document: document, owner: self,
            scrollOffset: { [weak self] in self?.lastScroll },
            restoreScroll: { [weak web] y in Task { _ = try? await web?.evaluateJavaScript("window.vitrineDiff.reveal(\(y)); true") } },
            find: { [weak self] query, forward in await self?.find(query, forward: forward) ?? FindResult(count: 0, index: -1) },
            clearFind: { [weak web] in Task { _ = try? await web?.evaluateJavaScript("window.vitrineDiff.clearFind(); true") } },
            showView: { [weak self, weak web] index in
                guard let self, index < views, views > 1, index < self.modes.count else { return false }
                Task { _ = try? await web?.callAsyncJavaScript("window.vitrineDiff.setMode(m); return true;",
                                                                arguments: ["m": self.modes[index].lowercased()], contentWorld: .page) }
                return true
            })
        preview.copyFormats = { [weak self] in self?.copyOffer() ?? (CodeCopy.copyAsHeading, []) }
        if !files.isEmpty {
            preview.foldToMatches = { [weak web] on in
                Task { _ = try? await web?.callAsyncJavaScript("return window.vitrineDiff.foldToMatches(on);", arguments: ["on": on], contentWorld: .page) }
            }
        }
        self.preview = preview
        updateGutter()
        return preview
    }

    // MARK: The document (pill, viewer switch)

    static func document(comparison: TextComparison, oldName: String, newName: String) -> PreviewDocument {
        let headline: String
        switch comparison.status {
        case .identical:
            headline = String(localized: "Identical · \(comparison.newSize) bytes", bundle: .previewKit,
                              comment: "Compare pill headline: the two files are the same, then their size in bytes.")
        case .whitespaceOnly:
            headline = String(localized: "Whitespace only · \(comparison.newLineCount) lines", bundle: .previewKit,
                              comment: "Compare pill headline: only whitespace differs, then the line count.")
        case .binary: headline = String(localized: "Binary", bundle: .previewKit, comment: "Compare pill headline: the files are not text.")
        case .different:
            headline = String(localized: "\(comparison.changes.count) changes · +\(comparison.additions) −\(comparison.deletions)", bundle: .previewKit,
                              comment: "Compare pill headline: how many changes, lines added (+) and removed (−).")
        }
        var document = PreviewDocument(kind: .diff, facts: [Fact(key: "headline", label: compareLabel, value: headline),
                                                            Fact(key: "summary", label: changesLabel, value: DiffSummary(comparison: comparison).lead),
                                                            Fact(key: "files", label: String(localized: "Files", bundle: .previewKit,
                                                                                             comment: "Fact label: the two files a compare shows."),
                                                                 value: "\(oldName) ⇄ \(newName)")] + DiffFacts.facts(for: comparison),
                                       views: [.text("")])
        if comparison.status == .different || comparison.status == .whitespaceOnly {
            document.views = [.text(""), .text("")]
            document.viewTitles = ["Unified", "Split"]
        }
        return document
    }

    static func document(url: URL, patch: Patch, checks: DiffChecks.Result) -> PreviewDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let totals = patch.totals
        var headline = String(localized: "\(totals.files) files", bundle: .previewKit, comment: "Patch pill headline: how many files it changes.")
        if !checks.findings.isEmpty {
            let secrets = checks.findings.filter { $0.kind == .secret }.count
            let scripts = checks.findings.filter { $0.kind == .script }.count
            // Each part a whole phrase; " · " is the pill's list separator.
            headline = [secrets > 0 ? String(localized: "\(secrets) secrets", bundle: .previewKit, comment: "Patch pill: how many secrets the checks found.") : nil,
                        scripts > 0 ? String(localized: "\(scripts) risky scripts", bundle: .previewKit,
                                             comment: "Patch pill: how many risky scripts the checks found.") : nil]
                .compactMap { $0 }.joined(separator: " · ")
        } else if let cut = patch.issues.first(where: { if case .hunkTooShort = $0.kind { return true } else { return false } }),
                  case .hunkTooShort(let dOld, let dNew, let fOld, let fNew) = cut.kind {
            headline = String(localized: "Cut off · \(max(fOld, fNew)) of \(max(dOld, dNew)) lines", bundle: .previewKit,
                              comment: "Patch pill: the patch ends early; the lines that arrived of those declared.")
        }
        var facts = [Fact(key: "headline", label: FamilyFacts.summaryLabel, value: headline), DocumentFacts.size(size),
                     Fact(key: "summary", label: changesLabel, value: DiffSummary(patch: patch).lead)]
        facts += DiffFacts.facts(for: patch).filter { f in !facts.contains { $0.key == f.key } }
        var badges: [Badge] = []
        for finding in checks.findings {
            badges.append(Badge(level: finding.level == .danger ? .danger : .caution, title: finding.title, detail: finding.detail))
        }
        for issue in patch.issues where issue.severity == .error {
            badges.append(Badge(level: .caution, title: String(localized: "Patch problem", bundle: .previewKit,
                                                               comment: "Warning title: a patch file has a malformed part."),
                                detail: issue.message))
        }
        let text = String(decoding: (try? Data(contentsOf: url, options: .mappedIfSafe))?.prefix(8 << 20) ?? Data(), as: UTF8.self)
        var document = PreviewDocument(kind: .diff, facts: facts, views: [.code(text, language: "diff"), .code(text, language: "diff")],
                                       coverage: DiffFacts.coverage(for: patch))
        document.badges = badges
        document.viewTitles = ["Unified", "Split"]
        return document
    }

    static var compareLabel: String { String(localized: "Compare", bundle: .previewKit, comment: "Fact label: the summary of a two-file compare.") }
    static var changesLabel: String { String(localized: "Changes", bundle: .previewKit, comment: "Fact label: a patch's or compare's one-line summary.") }

    // MARK: Find

    /// Find over every file: rows not on the page yet are sent first, then the page marks and steps.
    private func find(_ query: String, forward: Bool) async -> FindResult {
        guard let web = webView else { return FindResult(count: 0, index: -1) }
        await sendAllRows()
        let r = try? await web.callAsyncJavaScript("return window.vitrineDiff.find(q, f);", arguments: ["q": query, "f": forward],
                                                   contentWorld: .page) as? [String: Any]
        let (count, index) = PageNumbers.matches(r)
        // The files the matches are in: no more than the matches, nor than the files on the page.
        let files = PageNumbers.integer(r?["files"], in: 0...min(count, self.files.count)) ?? 0
        let label = count == 0 ? nil
            : String(localized: "\(index + 1) of \(count) · \(files) files", bundle: .previewKit,
                     comment: "Find result in a patch: the current match of all matches, then how many files they are in.")
        return FindResult(count: count, index: index, label: label)
    }

    private func sendAllRows() async {
        for i in files.indices where !sent.contains(i) { await send(i) }
    }

    private func send(_ index: Int) async {
        guard files.indices.contains(index), !sent.contains(index), let web = webView else { return }
        sent.insert(index)
        let rows = DiffPage.rows(files[index], index: index, checks: checks)
        guard let data = try? JSONEncoder().encode(rows), let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await web.callAsyncJavaScript("window.vitrineDiff.setRows(JSON.parse(j)); return true;", arguments: ["j": json], contentWorld: .page)
    }

    // MARK: Copy as

    func copyOffer() -> (heading: String, formats: [CopyFormat]) {
        let heading = CodeCopy.copyAsHeading
        // The prompt texts are for a language model and keep one fixed form (not localized), like the diff they hold.
        if let comparison, let (old, new) = compareURLs {
            guard let file = files.first else { return (heading, []) }
            let text = Self.unifiedText(file, index: 0, checks: checks)
            let prompt = "Changes from \(old.lastPathComponent) to \(new.lastPathComponent) (\(DiffSummary(comparison: comparison).lead)):\n\n```diff\n\(text)```\n"
            return (heading, [CopyFormat(title: String(localized: "Unified diff", bundle: .previewKit, comment: "Copy as menu item: the compare as a unified diff.")) { text },
                              CopyFormat(title: String(localized: "As prompt · ≈ \(max(1, (prompt.utf8.count + 2) / 4)) tokens", bundle: .previewKit,
                                                       comment: "Copy as menu item: the diff as a prompt for a language model, with its approximate token count.")) { prompt }])
        }
        guard let patch, let url = fileURL else { return (heading, []) }
        let whole = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var formats = [CopyFormat(title: String(localized: "Patch", bundle: .previewKit, comment: "Copy as menu item: the whole patch file.")) { whole }]
        if patch.files.indices.contains(currentFile) {
            let file = patch.files[currentFile]
            let one = Self.unifiedText(file, index: currentFile, checks: checks)
            formats.append(CopyFormat(title: String(localized: "This file's change (\((file.path as NSString).lastPathComponent))", bundle: .previewKit,
                                                    comment: "Copy as menu item: the change to the file in view; the argument is its name.")) { one })
            let prompt = "Changes to \(file.path) from \(url.lastPathComponent):\n\n```diff\n\(one)```\n"
            formats.append(CopyFormat(title: String(localized: "As prompt, with the file's path · ≈ \(max(1, (prompt.utf8.count + 2) / 4)) tokens", bundle: .previewKit,
                                                    comment: "Copy as menu item: the file's change as a prompt for a language model, with its approximate token count.")) { prompt })
        }
        formats.append(CopyFormat(title: String(localized: "Reveal in Finder", bundle: .previewKit, comment: "Copy as menu item: shows the file in Finder.")) { _ in
            NSWorkspace.shared.activateFileViewerSelecting([url]); return false
        })
        return (heading, formats)
    }

    /// One file's change as unified diff text (secrets masked, as on the page).
    static func unifiedText(_ file: DiffFile, index: Int, checks: DiffChecks.Result) -> String {
        var out = "--- \(file.oldPath.map { "a/" + $0 } ?? "/dev/null")\n+++ \(file.newPath.map { "b/" + $0 } ?? "/dev/null")\n"
        for (h, hunk) in file.hunks.enumerated() {
            out += hunk.header + "\n"
            for (l, line) in hunk.lines.enumerated() {
                let sign = line.kind == .added ? "+" : line.kind == .deleted ? "-" : " "
                out += sign + (checks.maskedText(file: index, hunk: h, line: l) ?? line.text) + "\n"
            }
        }
        return out
    }

    // MARK: Gutter

    private func updateGutter() {
        if rich { preview?.updateGutter(nil); return }
        if let comparison {
            let n = comparison.changes.count
            preview?.updateGutter(n > 1 ? GutterStatus(trailing: String(localized: "\(n) changes", bundle: .previewKit,
                                                                        comment: "Gutter: how many changes a compare holds.")) : nil)
            return
        }
        guard let patch else { return }
        let total = max(patch.coverage.filesSeen, patch.files.count)
        let leading = total > patch.files.count
            ? String(localized: "\(patch.files.count) of \(total) files", bundle: .previewKit, comment: "Gutter: the files of a long patch that are drawn.")
            : nil
        let trailing = patch.files.count > 1
            ? String(localized: "\(currentFile + 1) of \(patch.files.count)", bundle: .previewKit, comment: "Gutter: the patch file in view of all its files.")
            : nil
        preview?.updateGutter(leading == nil && trailing == nil ? nil : GutterStatus(leading: leading, trailing: trailing))
    }

    // MARK: The page

    static func page(model: DiffPage, first: [DiffPage.FileRows], context: RenderContext) -> String {
        let appearance = context.appearance == .dark ? "dark" : "light"
        return """
        <!doctype html>
        <html data-appearance="\(appearance)"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src vitrine: 'wasm-unsafe-eval'; style-src 'unsafe-inline'; img-src data:; font-src vitrine: data:">
        <style>
        :root { \(DesignTokens.systemCSS(for: context.appearance)) color-scheme: \(appearance); }
        \(css)
        </style></head>
        <body>\(PageStrings.block(PageStrings.diff))<div id="vt-diff"></div>
        <script type="application/json" id="vt-model">\(CodeRenderer.scriptJSON(model))</script>
        <script type="application/json" id="vt-rows">\(CodeRenderer.scriptJSON(first))</script>
        <script type="module" src="vitrine://app/code/diff.js"></script>
        </body></html>
        """
    }

    static let css = """
    html, body { margin: 0; height: 100%; background: var(--v-page); color: var(--v-t1); font: 13px/1.38 -apple-system, system-ui, sans-serif; }
    #vt-diff { display: flex; flex-direction: column; height: 100%; position: relative; }
    .d-detail { margin-right: 12px; } .d-detail::-webkit-scrollbar:vertical { width: 0; }
    .vt-ruler { position: absolute; bottom: 0; right: 0; width: 12px; z-index: 5; border-left: .5px solid var(--v-sep); background: var(--v-page); cursor: default; }
    .vt-ruler i { position: absolute; left: 2px; right: 2px; height: 3px; border-radius: 1px; pointer-events: none; }
    .vt-ruler i.f { background: var(--v-find-cur); opacity: .75; } .vt-ruler i.fc { background: var(--v-find-cur); height: 4px; }
    .vt-ruler i.add { background: var(--v-diff-add); } .vt-ruler i.del { background: var(--v-diff-del); height: 2px; }
    .vt-ruler .thumb { position: absolute; left: 1px; right: 1px; border-radius: 4px; background: var(--v-fill2); min-height: 16px; }
    .vt-ruler .unshown { position: absolute; left: 0; right: 0; bottom: 0; background: repeating-linear-gradient(135deg, var(--v-fill2) 0 3px, transparent 3px 6px); }
    .d-head { flex: none; padding: 14px 18px 8px; border-bottom: .5px solid var(--v-sep); }
    .d-lead { display: flex; align-items: baseline; gap: 8px; }
    .d-dot { width: 8px; height: 8px; border-radius: 4px; background: var(--v-t3); flex: none; transform: translateY(-1px); }
    .d-dot.caution { background: var(--v-caution); } .d-dot.danger { background: var(--v-danger); }
    .d-sentence { font-size: 14px; font-weight: 650; }
    .d-meta { color: var(--v-t2); font-size: 12px; margin: 2px 0 0 16px; }
    .d-stat { font: 500 12px/1 var(--v-mono); margin-left: auto; white-space: nowrap; }
    .d-add { color: var(--v-diff-add-text); } .d-del { color: var(--v-diff-del-text); }
    .d-msg { color: var(--v-t2); font-size: 12.5px; margin: 6px 0 0 16px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
    .d-msg.open { -webkit-line-clamp: unset; }
    .d-more { all: unset; color: var(--v-accent-text); font-size: 12px; margin-left: 16px; cursor: default; }
    .d-notice { margin: 8px 0 0; padding: 7px 10px; border-radius: 8px; background: var(--v-caution-soft); color: var(--v-t1); font-size: 12.5px; }
    .d-notice b { display: block; font-weight: 650; }
    .d-group { margin-top: 10px; }
    .d-group h6 { margin: 0 0 4px; font-size: 11px; font-weight: 600; color: var(--v-t2); }
    .d-check { display: flex; align-items: baseline; gap: 8px; padding: 4px 0; font-size: 12.5px; }
    .d-bdg { flex: none; font: 600 11px/18px -apple-system, system-ui; height: 18px; padding: 0 6px; border-radius: 5px; }
    .d-bdg.caution { background: var(--v-caution-soft); color: var(--v-caution-text); }
    .d-bdg.danger { background: var(--v-danger-soft); color: var(--v-danger-text); }
    .d-check .t { font-weight: 600; } .d-check .s { color: var(--v-t2); }
    .d-check a { color: var(--v-accent-text); margin-left: auto; text-decoration: none; cursor: default; }
    .d-list { margin: 0; padding: 0; list-style: none; }
    .d-row { display: flex; align-items: center; gap: 8px; height: 24px; padding: 0 6px; border-radius: 6px; font-size: 12.5px; cursor: default; }
    .d-row.on { background: var(--v-sel); }
    .d-row[hidden], [hidden] { display: none !important; }
    .d-tile { flex: none; width: 16px; height: 16px; border-radius: 4px; font: 600 10px/16px var(--v-mono); text-align: center; }
    .d-tile.M { background: var(--v-diff-chg-bg); color: var(--v-diff-chg); }
    .d-tile.A { background: var(--v-diff-add-bg); color: var(--v-diff-add-text); }
    .d-tile.D { background: var(--v-diff-del-bg); color: var(--v-diff-del-text); }
    .d-tile.R, .d-tile.C, .d-tile.B { background: var(--v-fill); color: var(--v-t2); }
    .d-row .dir { color: var(--v-t3); } .d-row .nm { font-weight: 500; }
    .d-row .from { color: var(--v-t3); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .d-row .st { margin-left: auto; font: 11.5px var(--v-mono); white-space: nowrap; }
    .d-andmore { color: var(--v-t3); font-size: 12px; padding: 2px 6px; }
    .d-detail { flex: 1; min-height: 0; overflow: auto; }
    .dfh { position: sticky; top: 0; z-index: 3; display: flex; align-items: center; gap: 8px; height: 30px; padding: 0 14px;
           font: 600 12.5px/30px -apple-system, system-ui; background: color-mix(in srgb, var(--v-win) 86%, transparent);
           -webkit-backdrop-filter: blur(30px) saturate(1.6); border-bottom: .5px solid var(--v-sep); border-top: .5px solid var(--v-sep); }
    .dfh .dir { color: var(--v-t3); font-weight: 500; } .dfh .st { margin-left: auto; font: 500 11.5px var(--v-mono); }
    .d-file { padding-bottom: 6px; }
    .d-omit { padding: 10px 18px; color: var(--v-t3); font-size: 12px; }
    table.d-rows { border-collapse: collapse; width: 100%; font: var(--v-fs-mono)/1.55 var(--v-mono); table-layout: fixed; }
    .d-rows td { padding: 0 8px; white-space: pre; vertical-align: top; overflow: hidden; }
    .d-rows td.n { width: 3.2em; text-align: right; color: var(--v-t3); padding-right: 6px; user-select: none; font-variant-numeric: tabular-nums; }
    .d-rows td.sg { width: 1em; padding: 0 2px; color: var(--v-t3); user-select: none; }
    .d-rows tr.a td { background: var(--v-diff-add-bg); } .d-rows tr.d td { background: var(--v-diff-del-bg); }
    .d-rows tr.a td.sg { color: var(--v-diff-add-text); } .d-rows tr.d td.sg { color: var(--v-diff-del-text); }
    .d-rows td.ha { background: var(--v-diff-add-bg); } .d-rows td.hd { background: var(--v-diff-del-bg); }
    .d-rows td.gap { background: repeating-linear-gradient(135deg, var(--v-fill) 0 4px, transparent 4px 8px); }
    .d-rows tr.fold td { color: var(--v-t3); font: 11.5px/22px -apple-system, system-ui; background: var(--v-fill); padding-left: 14px; }
    .d-rows mark.hi-a { background: var(--v-diff-add-hi); color: inherit; border-radius: 2px; }
    .d-rows mark.hi-d { background: var(--v-diff-del-hi); color: inherit; border-radius: 2px; }
    .d-rows mark.find { background: var(--v-find); color: inherit; border-radius: 2px; }
    .d-rows mark.find.cur { background: var(--v-find-cur); box-shadow: 0 0 0 2px var(--v-find-cur); }
    .d-nomatch td { color: var(--v-t3); font: 11.5px/22px -apple-system, system-ui; background: var(--v-fill); padding-left: 14px; }
    .r-tree { font: var(--v-fs-mono)/1.7 var(--v-mono); padding: 8px 0 16px; }
    .r-node { white-space: pre; padding-right: 12px; }
    .r-node.changed .r-sign { color: var(--v-diff-chg); } .r-node.added { background: var(--v-diff-add-bg); } .r-node.removed { background: var(--v-diff-del-bg); }
    .r-node.added .r-sign { color: var(--v-diff-add-text); } .r-node.removed .r-sign { color: var(--v-diff-del-text); }
    .r-sign { display: inline-block; width: 1.4em; color: var(--v-t3); } .r-key { color: var(--v-syn-key); } .r-colon { color: var(--v-t3); }
    .r-sum { color: var(--v-t3); font: 11.5px -apple-system, system-ui; } .r-val { color: var(--v-t1); }
    .r-old { color: var(--v-diff-del-text); text-decoration: line-through; } .r-new { color: var(--v-diff-add-text); }
    .r-arrow::before { content: "→"; color: var(--v-t3); margin: 0 .4em; }
    .r-prose { max-width: 720px; padding: 12px 24px 32px; font: 14px/1.6 -apple-system, system-ui; }
    .r-prose ins { text-decoration: underline; text-decoration-color: var(--v-diff-add-text); background: var(--v-diff-add-hi); }
    .r-prose del { text-decoration: line-through; color: var(--v-diff-del-text); background: var(--v-diff-del-hi); }
    .r-prose .r-added { background: var(--v-diff-add-bg); } .r-prose .r-removed { background: var(--v-diff-del-bg); text-decoration: line-through; }
    .r-link { color: var(--v-t3); font-size: 12px; }
    .r-output { padding: 6px 14px 10px; } .r-olabel { color: var(--v-t3); font-size: 11.5px; margin-bottom: 4px; }
    .r-pair { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
    .r-side { border-radius: 8px; padding: 6px 8px; background: var(--v-fill); overflow: auto; }
    .r-side.r-was { background: var(--v-diff-del-bg); } .r-side.r-now { background: var(--v-diff-add-bg); }
    .r-side pre { margin: 0; font: 12px/1.5 var(--v-mono); white-space: pre-wrap; } .r-side img { max-width: 100%; }
    .r-none { color: var(--v-t3); font-size: 12px; }
    .r-stage { padding: 14px; } .r-stage.r-2-up { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
    .r-stage figure { margin: 0; } .r-stage figcaption { color: var(--v-t3); font-size: 11.5px; margin-top: 4px; }
    .r-stage img { display: block; max-width: 100%; background: repeating-conic-gradient(var(--v-fill) 0 25%, transparent 0 50%) 0 0 / 16px 16px; }
    .r-boxes, .r-frame { position: relative; display: inline-block; max-width: 100%; vertical-align: top; } .r-boxes { display: block; }
    .r-frame .r-over { position: absolute; inset: 0; width: 100%; height: 100%; } .r-frame .r-blend { mix-blend-mode: difference; }
    .r-stage input[type=range] { width: 100%; margin-top: 8px; }
    .r-box { position: absolute; border: 2px solid var(--v-diff-chg); border-radius: 3px; box-sizing: border-box; }
    .r-box span { position: absolute; top: -9px; left: -9px; width: 18px; height: 18px; border-radius: 9px; background: var(--v-accent); color: #fff; font: 600 10.5px/18px -apple-system; text-align: center; }
    .r-flash { outline: 3px solid var(--v-accent); outline-offset: 2px; }
    @media (max-width: 420px) {
      .d-head { padding: 10px 12px 6px; } .d-meta, .d-msg, .d-check .s { display: none; }
      .d-rows td.n.o { display: none; } .dfh .dir { display: none; }
    }
    """

    // MARK: Page messages

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        receive(body)
    }

    /// One message from the page. A file index it sends must be one of the files the page was built from (S-16):
    /// `send(_:)` and the gutter's "3 of 40" use it as is.
    func receive(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "ready": finish(true)
        case "rows":
            if let i = PageNumbers.index(body["index"], in: files.indices) { Task { await send(i) } }
        case "current":
            if let i = PageNumbers.index(body["index"], in: files.indices), i != currentFile { currentFile = i; updateGutter() }
        case "scroll": if let y = PageNumbers.scrollOffset(body["y"]) { lastScroll = y }
        case "error": pageErrors.append(body["message"] as? String ?? "?")
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

    /// Only the page's own first load is allowed; a link or anything else the page tries to open is cancelled.
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if !firstLoadAllowed, action.targetFrame?.isMainFrame == true, action.request.url == PreviewSchemeHandler.documentBase {
            firstLoadAllowed = true
            return .allow
        }
        return .cancel
    }
    private var firstLoadAllowed = false
}
