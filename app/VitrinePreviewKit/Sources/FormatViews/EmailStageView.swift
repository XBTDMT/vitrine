import AppKit
import VitrineFormats
import VitrineUI
import WebKit

/// Format view F6, option A (picked): the message as it renders, on a sheet standing on the card's lit stage, with a
/// red label across its top when the reader found it dangerous (a failed DMARC check, an attachment that runs code).
/// The HTML body is drawn by a locked WKWebView: page JavaScript off, the G-9 content rule list (every load that is
/// not `data:` or `about:blank` is blocked), a Content-Security-Policy that allows nothing but inline styles and
/// `data:` pictures, an ephemeral data store, no new windows, and every navigation after the first load cancelled,
/// so links are shown and never followed. Links that leave the sender's domain are ringed in the danger colour when
/// the message carries a warning. Without HTML, or when the lock cannot be set up (fail closed), the plain body
/// shows in a text view. The page is prepared off the main thread. roadmap: S-23
@MainActor
final class EmailStageView: NSView, WKNavigationDelegate, WKUIDelegate {
    let summary: EmailSummary
    /// The sheet's clipped inside: the danger label, then the web view or the text view.
    let sheetContent = DocStageSheetClip()
    private(set) var dangerLabel: DocStageDangerLabel?
    private(set) var webView: WKWebView?
    private(set) var textScroll: NSScrollView?
    private(set) var textView: NSTextView?
    /// The content rule list was installed on the web view's configuration before anything loaded.
    private(set) var isLockedDown = false
    /// Every navigation the web view asked about, with the answer: only the page's own `about:blank` is allowed.
    private(set) var navigationLog: [(url: URL?, allowed: Bool)] = []
    /// Remote pictures, backgrounds and stylesheets the HTML names (all blocked).
    private(set) var remoteReferences = 0
    private var loadTask: Task<Void, Never>?
    private var pageLoaded = false
    private var loaded: CheckedContinuation<Void, Never>?
    private var sheetFrame = NSRect.zero

    static let loadWait: Duration = .seconds(8)

    init(summary: EmailSummary) {
        self.summary = summary
        super.init(frame: .zero)
        addSubview(sheetContent)
        if let danger = summary.warnings.first(where: { $0.level == .danger }) {
            let label = DocStageDangerLabel(lead: Self.dangerLead(summary), reason: danger.reason)
            sheetContent.addSubview(label)
            dangerLabel = label
        }
        let html = summary.htmlBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if html.isEmpty {
            showPlain()
        } else {
            loadTask = Task { [weak self] in await self?.loadHTML(html) }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(summary.headline)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Waits until the message is drawn: the page loaded (bounded), or the plain text shown.
    func waitUntilLoaded() async { await loadTask?.value }

    /// The label's bold opening words, from what the reader found.
    static func dangerLead(_ summary: EmailSummary) -> String {
        let codes = Set(summary.warnings.map(\.code))
        if codes.contains("email.dmarcFail") || codes.contains("email.displayNameMismatch") {
            return String(localized: "Probably phishing.", bundle: .previewKit, comment: "Email stage danger label, opening words: the sender check failed.")
        }
        if codes.contains("email.riskyAttachment") {
            return String(localized: "Dangerous attachment.", bundle: .previewKit, comment: "Email stage danger label, opening words: an attachment can run code.")
        }
        return String(localized: "Be careful with this message.", bundle: .previewKit, comment: "Email stage danger label, opening words.")
    }

    // MARK: Layout and drawing

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let sheetW = min(w, max(min(420, w), min(640, (w * 0.64).rounded())))
        sheetFrame = NSRect(x: ((w - sheetW) / 2).rounded(), y: 2, width: sheetW, height: max(0, h - 2))
        sheetContent.frame = sheetFrame
        var y: CGFloat = 0
        if let dangerLabel {
            let labelH = dangerLabel.height(for: sheetW)
            dangerLabel.frame = NSRect(x: 0, y: 0, width: sheetW, height: labelH)
            y = labelH
        }
        let body = NSRect(x: 0, y: y, width: sheetW, height: max(0, sheetFrame.height - y))
        webView?.frame = body
        textScroll?.frame = body
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The sheet's shadow (the pop-over token), drawn under the clipped sheet: rounded at the top, square at the
        // foot, where the page runs on.
        guard sheetFrame.width > 0, sheetFrame.height > 0 else { return }
        let r: CGFloat = 10
        let path = NSBezierPath()
        path.move(to: NSPoint(x: sheetFrame.minX, y: sheetFrame.maxY))
        path.line(to: NSPoint(x: sheetFrame.minX, y: sheetFrame.minY + r))
        path.appendArc(withCenter: NSPoint(x: sheetFrame.minX + r, y: sheetFrame.minY + r), radius: r, startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: sheetFrame.maxX - r, y: sheetFrame.minY))
        path.appendArc(withCenter: NSPoint(x: sheetFrame.maxX - r, y: sheetFrame.minY + r), radius: r, startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: sheetFrame.maxX, y: sheetFrame.maxY))
        path.close()
        NSGraphicsContext.saveGraphicsState()
        DocStage.shadow("shadow-pop").drop?.set()
        NSColor.token("page").setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: The plain body

    /// The plain body in a read-only text view on the page colour, the subject above it; the fallback for every
    /// message without HTML and for every page that could not be locked down.
    private func showPlain() {
        webView?.removeFromSuperview()
        webView = nil
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.token("page")
        scroll.borderType = .noBorder
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = true
        text.backgroundColor = NSColor.token("page")
        text.textContainerInset = NSSize(width: 22, height: 18)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.layoutManager?.allowsNonContiguousLayout = true
        text.textStorage?.setAttributedString(Self.plainText(summary))
        text.setAccessibilityLabel(String(localized: "Message", bundle: .previewKit, comment: "Accessibility label: the email's text on its stage."))
        scroll.documentView = text
        sheetContent.addSubview(scroll)
        textScroll = scroll
        textView = text
        needsLayout = true
    }

    static let maxPlainCharacters = 200_000

    static func plainText(_ summary: EmailSummary) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let subject = summary.subject.flatMap { $0.isEmpty ? nil : $0 }
        if let subject {
            out.append(NSAttributedString(string: subject + "\n", attributes: [.font: tokenFont("fs-title3"), .foregroundColor: NSColor.token("t1")]))
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
        }
        let body = summary.plainBody.flatMap { $0.isEmpty ? nil : $0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.18
        if let body {
            out.append(NSAttributedString(string: String(body.prefix(maxPlainCharacters)), attributes: [
                .font: tokenFont("fs-body"), .foregroundColor: NSColor.token("t1"), .paragraphStyle: paragraph,
            ]))
        } else {
            out.append(NSAttributedString(string: String(localized: "This message has no text to show.", bundle: .previewKit,
                                                         comment: "Email stage: the message has neither a plain nor a safely shown HTML body."),
                                          attributes: [.font: tokenFont("fs-body"), .foregroundColor: NSColor.token("t3")]))
        }
        return out
    }

    // MARK: The HTML body

    /// The colours the page is drawn in: the message keeps the light page its sender designed for, as Mail does.
    struct PageColors: Sendable {
        var page: String, text: String, link: String, danger: String

        @MainActor static var current: PageColors {
            func light(_ name: String, _ fallback: String) -> String { GeneratedTokens.color(name)?.light ?? fallback }
            return PageColors(page: light("page", "#FFFFFF"), text: light("t1", "#1D1D1F"), link: light("update-text", "#0066D6"),
                              danger: light("danger", "#FF3B30"))
        }
    }

    /// The page around the message's HTML: our head first (charset, the CSP, base styles), so whatever the message
    /// writes later cannot loosen the policy; a nested `<html>` or `<head>` in the message merges into ours. Links
    /// to other hosts than the sender's organisation are ringed when `ringForeignLinks`. Runs off the main actor.
    nonisolated static func page(html: String, senderDomain: String?, ringForeignLinks: Bool, colors: PageColors) -> (html: String, remote: Int) {
        let remote = countRemote(html)
        var ring = ""
        if ringForeignLinks {
            let hosts = foreignLinkHosts(html, senderDomain: senderDomain)
            ring = hosts.map { "a[data-vitrine-href*=\"\(cssString($0))\" i]" }.joined(separator: ",")
            if !ring.isEmpty {
                ring += " { outline: 2px solid \(colors.danger); outline-offset: 3px; border-radius: 6px; }"
            }
        }
        let head = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; media-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
        <meta name="color-scheme" content="light only">
        <style>
        html { background: \(colors.page); color: \(colors.text); }
        body { margin: 0; padding: 22px 26px; font: 13px/1.5 -apple-system, system-ui, sans-serif; overflow-wrap: anywhere; }
        img { max-width: 100%; height: auto; }
        :where(a[data-vitrine-href], area[data-vitrine-href]) { color: \(colors.link); text-decoration: underline; }
        a, area, button, input, select, textarea { pointer-events: none; cursor: default; }
        \(ring)
        </style></head><body>
        """
        return (head + disarm(html) + "\n</body></html>", remote)
    }

    /// Links are shown, never followed: every `<a>` and `<area>` keeps its target as `data-vitrine-href` (so it can
    /// still be ringed) but loses `href`, so a click or a key press is no link activation at all and never reaches
    /// WebKit's navigation path; a `<meta http-equiv="refresh">` loses its meaning the same way. The CSS above stops
    /// pointer events on links and controls as a second lock; the navigation delegate is the third.
    nonisolated static func disarm(_ html: String) -> String {
        let out = rewritingTags(html, tag: linkTag) { tag in
            linkHref.stringByReplacingMatches(in: tag, range: NSRange(tag.startIndex..., in: tag), withTemplate: "$1data-vitrine-href$2")
        }
        return rewritingTags(out, tag: metaTag) { tag in
            metaRefresh.stringByReplacingMatches(in: tag, range: NSRange(tag.startIndex..., in: tag), withTemplate: "$1data-vitrine-http-equiv$2")
        }
    }

    // The message's HTML is the sender's and runs to 1,000,000 characters, so every pattern here is linear in it
    // (S-16 F55). A tag pattern always matches from its `<` to the next `>` (or the end of the text) and never fails,
    // so the search resumes after it and no character is scanned from more than one start; the attribute patterns
    // then run inside one tag; and every loop is possessive, so a run of spaces is never split between two loops.
    // They find what the earlier `<a\b[^>]*?\s…` patterns found, in one pass instead of one pass per start.

    /// The rest of a start tag as a browser reads it: quoted values may hold a `>`, so they are skipped whole (an
    /// unclosed quote runs to the end). Each alternative starts with a different character, so the loop is linear.
    nonisolated static let tagBody = #"(?:[^>"']++|"[^"]*+"?+|'[^']*+'?+)*+>?"#
    /// An `<a>` or `<area>` start tag, to its `>` or the end of the text.
    nonisolated static let linkTag = try! NSRegularExpression(pattern: #"(?i)<(?:a|area)\b"# + tagBody)
    /// An `<a>` start tag, to its `>` or the end of the text.
    nonisolated static let anchorTag = try! NSRegularExpression(pattern: #"(?i)<a\b"# + tagBody)
    /// A `<meta>` start tag, to its `>` or the end of the text.
    nonisolated static let metaTag = try! NSRegularExpression(pattern: #"(?i)<meta\b"# + tagBody)
    /// Inside one link tag: each `href=`. Browsers also start an attribute after `/` or straight after a closing
    /// quote (`<a/href=…>`, `<a title="x"href=…>`), so those count as separators too (S-16).
    nonisolated static let linkHref = try! NSRegularExpression(pattern: #"(?i)([\s/"'])href(\s*+=)"#)
    /// Inside one meta tag: `http-equiv="refresh"`.
    nonisolated static let metaRefresh = try! NSRegularExpression(pattern: #"(?i)([\s/"'])http-equiv(\s*+=\s*+["']?+\s*+refresh)"#)
    /// Inside one anchor tag: the host of an `http(s)` href.
    nonisolated static let anchorHost = try! NSRegularExpression(pattern: #"(?i)\bhref\s*+=\s*+["']?+\s*+https?://([^"'\s/?#>]++)"#)
    /// A `src=`, `background=`, `poster=` or `url(` that names a remote address.
    nonisolated static let remoteReference = try! NSRegularExpression(
        pattern: #"(?i)(?:\b(?:src|background|poster)\s*+=\s*+["']?+\s*+|url\(\s*+["']?+\s*+)(?:https?:)?//"#)

    /// `html` with each tag `tag` finds replaced by `rewrite` of it; the text between tags is kept as it is.
    nonisolated static func rewritingTags(_ html: String, tag: NSRegularExpression, _ rewrite: (String) -> String) -> String {
        let ns = html as NSString
        let matches = tag.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        let out = NSMutableString()
        var copied = 0
        for match in matches {
            out.append(ns.substring(with: NSRange(location: copied, length: match.range.location - copied)))
            out.append(rewrite(ns.substring(with: match.range)))
            copied = NSMaxRange(match.range)
        }
        out.append(ns.substring(from: copied))
        return out as String
    }

    /// How many `src=`, `background=` or `url(` references in the HTML name a remote address.
    nonisolated static func countRemote(_ html: String) -> Int {
        remoteReference.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html))
    }

    /// Hosts of `http(s)` links that are not the sender's organisation (the host itself or a subdomain either way),
    /// at most 50. A `user@host` link counts the real host after the `@`.
    nonisolated static func foreignLinkHosts(_ html: String, senderDomain: String?) -> [String] {
        var hosts: [String] = []
        for tag in anchorTag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let match = anchorHost.firstMatch(in: html, range: tag.range),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            var host = String(html[range]).lowercased()
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
            guard !host.isEmpty, !hosts.contains(host) else { continue }
            if let sender = senderDomain?.lowercased(), host == sender || host.hasSuffix("." + sender) || sender.hasSuffix("." + host) { continue }
            hosts.append(host)
            if hosts.count == 50 { break }
        }
        return hosts
    }

    /// A value safe inside a double-quoted CSS string.
    nonisolated static func cssString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "<", with: "\\3C ")
    }

    private func loadHTML(_ html: String) async {
        let colors = PageColors.current
        let sender = summary.from?.domain
        let ring = !summary.warnings.isEmpty
        let prepared = await Task.detached(priority: .userInitiated) {
            EmailStageView.page(html: html, senderDomain: sender, ringForeignLinks: ring, colors: colors)
        }.value
        remoteReferences = prepared.remote

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = false
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        do {
            try await PageLockdown.apply(to: config)
        } catch {
            // Fail closed: no lock, no page.
            showPlain()
            return
        }
        isLockedDown = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsLinkPreview = false
        web.allowsMagnification = false
        web.allowsBackForwardNavigationGestures = false
        web.underPageBackgroundColor = NSColor(css: colors.page) ?? .white
        web.setAccessibilityLabel(String(localized: "Message", bundle: .previewKit, comment: "Accessibility label: the email's text on its stage."))
        sheetContent.addSubview(web)
        webView = web
        needsLayout = true
        layoutSubtreeIfNeeded()
        web.loadHTMLString(prepared.html, baseURL: nil)

        let waiter = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.loadWait)
            self?.finishWaiting()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if pageLoaded { c.resume() } else { loaded = c }
        }
        waiter.cancel()
    }

    private func finishWaiting() {
        pageLoaded = true
        loaded?.resume()
        loaded = nil
    }

    // MARK: WKNavigationDelegate, WKUIDelegate

    /// The page's own load is the only navigation; a click, a refresh tag, a frame or a drop is cancelled.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let allow = !pageLoaded && navigationAction.targetFrame?.isMainFrame == true && url?.absoluteString == "about:blank"
        navigationLog.append((url, allow))
        return allow ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishWaiting() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishWaiting() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishWaiting() }

    /// A page process that ended (killed in a sandbox without WebKit's permission, G-9) drew nothing: show the text.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let wasLoading = !pageLoaded
        finishWaiting()
        if wasLoading || self.webView === webView { showPlain() }
    }

    /// No new windows, ever.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}

/// The sheet's inside, clipped to the sheet's rounded top corners (its foot runs on as if the page continued).
@MainActor
final class DocStageSheetClip: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 10
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.token("page").cgColor
        }
        roundTopCorners()
    }

    override func layout() {
        super.layout()
        roundTopCorners()
    }

    /// Rounds the top corners only. Where the top is in layer coordinates depends on whether AppKit flipped the
    /// backing layer's geometry for this flipped view.
    private func roundTopCorners() {
        guard let layer else { return }
        layer.maskedCorners = layer.isGeometryFlipped ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                                                      : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }
}

/// The red label (option A's danger rule and sentence) across the top of the message: a 3 pt strong-danger rule,
/// the danger-soft ground, the octagon glyph, the opening words in bold and the reader's reason. roadmap: S-23
@MainActor
final class DocStageDangerLabel: NSView {
    let text: NSTextField
    private let glyph: NSImageView

    init(lead: String, reason: String) {
        let sentence = NSMutableAttributedString(string: lead + " ", attributes: [
            .font: tokenFont("fs-callout", weight: 700), .foregroundColor: NSColor.token("danger-text"),
        ])
        sentence.append(NSAttributedString(string: reason, attributes: [
            .font: tokenFont("fs-callout", weight: 500), .foregroundColor: NSColor.token("danger-text"),
        ]))
        text = NSTextField(labelWithAttributedString: sentence)
        text.maximumNumberOfLines = 3
        text.lineBreakMode = .byWordWrapping
        text.cell?.wraps = true
        text.cell?.truncatesLastVisibleLine = true
        glyph = cardSymbol("exclamationmark.octagon.fill", size: 14, color: "danger", weight: .semibold)
        glyph.translatesAutoresizingMaskIntoConstraints = true
        super.init(frame: .zero)
        addSubview(glyph)
        addSubview(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(lead + " " + reason)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func height(for width: CGFloat) -> CGFloat {
        let textW = max(40, width - 40 - 16)
        return 3 + 10 + min(DocStage.height(text, width: textW), 3 * 17) + 10
    }

    override func layout() {
        super.layout()
        let textW = max(40, bounds.width - 40 - 16)
        glyph.frame = NSRect(x: 16, y: 3 + 11, width: 16, height: 16)
        text.frame = NSRect(x: 40, y: 3 + 10, width: textW, height: bounds.height - 3 - 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.token("card").setFill()
        bounds.fill()
        NSColor.token("danger-soft").setFill()
        bounds.fill()
        NSColor.token("danger-strong").setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 3).fill()
        NSColor.token("danger-line").setFill()
        NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
