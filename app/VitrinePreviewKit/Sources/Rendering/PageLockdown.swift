import WebKit

/// G-9: the web-view extensions hold macOS's network permission only because WebKit will not start in a sandbox
/// without it. Every page also gets this content rule list, which blocks every load whose URL is not Vitrine's own
/// `vitrine:` scheme or inline `data:`, so nothing a preview shows can reach the network (the page's
/// Content-Security-Policy is the second lock). If the list cannot be compiled the page is not shown: fail closed.
/// roadmap: S-4 (the link guard: S-20, G-27)
@MainActor
enum PageLockdown {
    static let identifier = "io.github.xbtdmt.vitrine.lockdown.v1"

    /// Later rules win: block everything, then let the two local schemes through.
    static let rules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^vitrine:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "^about:blank"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """

    private static var compiled: WKContentRuleList?

    enum Failure: Error, LocalizedError {
        case unavailable
        var errorDescription: String? {
            String(localized: "The preview could not be locked down, so it is not shown", bundle: .previewKit,
                   comment: "Preview error: the web page's network block could not be set up, so the page is not shown.")
        }
    }

    static func ruleList() async throws -> WKContentRuleList {
        if let compiled { return compiled }
        guard let store = WKContentRuleListStore.default() else { throw Failure.unavailable }
        let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules)
        guard let list else { throw Failure.unavailable }
        compiled = list
        return list
    }

    /// Adds the lock to a page's configuration before anything loads: the content rule list for loads, and the link
    /// guard for navigations.
    static func apply(to config: WKWebViewConfiguration) async throws {
        config.userContentController.add(try await ruleList())
        config.userContentController.addUserScript(linkGuard)
        config.userContentController.add(LinkMessages.shared, contentWorld: guardWorld, name: "vitrineLink")
    }

    static let guardWorld = WKContentWorld.world(name: "io.github.xbtdmt.vitrine.link-guard")

    /// What a click on a parked link does (X-3): asks VitrineHelper to open it in the person's browser, for http,
    /// https and mailto only (G-31). Tests replace it, so no test opens a browser.
    static var linkOpener: @MainActor (String) -> Void = { link in Task { _ = await HelperClient.openLink(link) } }

    /// G-27: WebKit opens a connection to a link's host the moment the link is activated (a click, Return on a focused
    /// link, a scripted click), before the navigation delegate is asked and outside the content rule list; measured
    /// with a 127.0.0.1 listener on the Markdown and notebook pages (PageNetworkIsolationTests). So no page may hold
    /// an address that leaves Vitrine: from the first parsed node on, every `href`, `xlink:href`, `action`,
    /// `formaction` and `ping` whose target is not in the page (`#…`) or Vitrine's own `vitrine:`, `data:` or
    /// `about:` is moved to `data-vitrine-href` (the target stays readable as the link's tooltip), refresh tags are
    /// removed, and activation of anything still link-like is stopped. It runs in its own content world, so page
    /// scripts cannot see or undo it, and on every frame.
    static let linkGuard = WKUserScript(source: linkGuardSource, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                        in: guardWorld)

    static let linkGuardSource = #"""
    (() => {
      const XLINK = 'http://www.w3.org/1999/xlink';
      const NAMES = ['href', 'action', 'formaction', 'ping'];
      const local = (value) => {
        const v = (value || '').trim();
        if (v === '' || v.startsWith('#')) return true;
        let url;
        try { url = new URL(v, document.baseURI); } catch (e) { return false; }
        return url.protocol === 'vitrine:' || url.protocol === 'data:' || url.protocol === 'about:';
      };
      const park = (el, value) => {
        el.setAttribute('data-vitrine-href', value);
        if (!el.hasAttribute('title') && el.namespaceURI === 'http://www.w3.org/1999/xhtml') el.setAttribute('title', value);
        // A parked link stays a link for the person: focusable, announced, and opened through the helper (X-3).
        if (el.localName === 'a' || el.localName === 'area') {
          el.setAttribute('data-vitrine-link', '1');
          if (!el.hasAttribute('tabindex')) el.setAttribute('tabindex', '0');
          if (!el.hasAttribute('role')) el.setAttribute('role', 'link');
        }
      };
      const post = (target) => {
        try { window.webkit.messageHandlers.vitrineLink.postMessage(target); } catch (e) {}
      };
      const guard = (el) => {
        if (!el || el.nodeType !== 1) return;
        if (el.localName === 'meta' && /refresh/i.test(el.getAttribute('http-equiv') || '')) { el.remove(); return; }
        for (const name of NAMES) {
          const value = el.getAttribute(name);
          if (value !== null && (name === 'ping' || !local(value))) { el.removeAttribute(name); if (name !== 'ping') park(el, value); }
        }
        const xlink = el.getAttributeNS(XLINK, 'href');
        if (xlink !== null && !local(xlink)) { el.removeAttributeNS(XLINK, 'href'); park(el, xlink); }
      };
      const sweep = (root) => {
        guard(root);
        if (root.querySelectorAll) for (const el of root.querySelectorAll('[href],[action],[formaction],[ping],meta')) guard(el);
        if (root.querySelectorAll) for (const el of root.getElementsByTagName('*')) if (el.hasAttributeNS && el.hasAttributeNS(XLINK, 'href')) guard(el);
      };
      new MutationObserver((records) => {
        for (const r of records) {
          if (r.type === 'attributes') guard(r.target);
          else for (const n of r.addedNodes) sweep(n);
        }
      }).observe(document, { subtree: true, childList: true, attributes: true,
                             attributeFilter: ['href', 'xlink:href', 'action', 'formaction', 'ping', 'http-equiv'] });
      // A second lock: anything that is still a link to elsewhere does nothing when activated.
      const stop = (event) => {
        const path = event.composedPath ? event.composedPath() : [event.target];
        const activation = (event.type === 'click' && event.button === 0) || (event.type === 'keydown' && event.key === 'Enter');
        for (const el of path) {
          if (!el || el.nodeType !== 1) continue;
          // A link the guard parked: the person's plain click or Return asks the host to open it; nothing loads here.
          if (el.getAttribute('data-vitrine-link') === '1') {
            event.preventDefault(); event.stopImmediatePropagation();
            if (activation) post(el.getAttribute('data-vitrine-href'));
            return;
          }
          const target = el.getAttribute('href') ?? el.getAttributeNS(XLINK, 'href');
          if (target !== null && !local(target)) { event.preventDefault(); event.stopImmediatePropagation(); guard(el); return; }
        }
      };
      for (const type of ['click', 'auxclick', 'keydown']) {
        window.addEventListener(type, (e) => { if (type !== 'keydown' || e.key === 'Enter' || e.key === ' ') stop(e); }, true);
      }
      window.addEventListener('submit', (e) => { e.preventDefault(); e.stopImmediatePropagation(); }, true);
      document.addEventListener('DOMContentLoaded', () => sweep(document), true);
    })();
    """#
}

/// Receives the link guard's "open this" from its own content world, never from page scripts. roadmap: S-10 (X-3)
@MainActor
final class LinkMessages: NSObject, WKScriptMessageHandler {
    static let shared = LinkMessages()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world == PageLockdown.guardWorld, let link = message.body as? String, !link.isEmpty else { return }
        PageLockdown.linkOpener(link)
    }
}
