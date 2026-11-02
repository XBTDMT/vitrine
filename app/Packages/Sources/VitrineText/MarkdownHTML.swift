import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Markdown → HTML through cmark-gfm with the GitHub extensions on (tables, strikethrough, autolinks, task lists,
/// tag filter, footnotes), plus the three GitHub features cmark does not know: `[!NOTE]` alerts, `:emoji:`
/// shortcodes and `$math$`. Pure function; no view code, so it is unit-tested directly.
///
/// Pipeline: strip front matter → lift math out (fences and code spans are respected) → cmark parse → replace
/// shortcodes in text nodes only (never inside code) → render → put math back as KaTeX-ready spans → turn
/// alert blockquotes into `<div class="alert alert-note">`.
public enum MarkdownHTML {
    public struct Options: Sendable {
        public var hideFrontMatter = true
        public var smartPunctuation = false
        public var emoji = true
        public var math = true
        public init() {}
    }

    private static let extensionsRegistered: Void = { cmark_gfm_core_extensions_ensure_registered() }()

    public static func render(_ markdown: String, options: Options = Options()) -> String {
        _ = extensionsRegistered
        var source = options.hideFrontMatter ? stripFrontMatter(markdown) : markdown
        var math: [MathSpan] = []
        if options.math { (source, math) = Math.lift(source) }

        var flags = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES | CMARK_OPT_VALIDATE_UTF8
        if options.smartPunctuation { flags |= CMARK_OPT_SMART }
        guard let parser = cmark_parser_new(Int32(flags)) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist", "tagfilter"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        source.withCString { cmark_parser_feed(parser, $0, strlen($0)) }
        guard let doc = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(doc) }
        if options.emoji { Emoji.replaceShortcodes(in: doc) }
        guard let html = cmark_render_html(doc, Int32(flags), cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(html) }
        var out = String(cString: html)
        if !math.isEmpty { out = Math.restore(out, spans: math) }
        return Alerts.transform(out)
    }

    /// Removes a leading YAML front-matter block (`---` … `---`) so metadata never renders as a broken table.
    static func stripFrontMatter(_ text: String) -> String {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return text }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            return lines[(i + 1)...].joined(separator: "\n")
        }
        return text
    }

    // MARK: Headings

    /// Headings with ids, for the table of contents. Returns (level, text, id) in document order.
    public static func headings(in html: String) -> [(level: Int, text: String, id: String)] {
        let pattern = #"<h([1-6])[^>]*>(.*?)</h\1>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        var seen: [String: Int] = [:]
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { m in
            let level = Int(ns.substring(with: m.range(at: 1))) ?? 1
            let raw = ns.substring(with: m.range(at: 2))
            let text = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return (level, text, uniqueID(slug(text), seen: &seen))
        }
    }

    /// Adds `id` attributes to headings so TOC links work; cmark emits none.
    public static func addHeadingIDs(_ html: String) -> String {
        var result = html
        var seen: [String: Int] = [:]
        let pattern = #"<h([1-6])>(.*?)</h\1>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return html }
        let ns = html as NSString
        var offset = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let level = ns.substring(with: m.range(at: 1))
            let inner = ns.substring(with: m.range(at: 2))
            let text = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let id = uniqueID(slug(text), seen: &seen)
            let replacement = "<h\(level) id=\"\(id)\">\(inner)</h\(level)>"
            let r = NSRange(location: m.range.location + offset, length: m.range.length)
            result = (result as NSString).replacingCharacters(in: r, with: replacement)
            offset += (replacement as NSString).length - m.range.length
        }
        return result
    }

    private static func slug(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}\\s-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
    }
    private static func uniqueID(_ base: String, seen: inout [String: Int]) -> String {
        if let n = seen[base] { seen[base] = n + 1; return "\(base)-\(n)" }
        seen[base] = 1; return base
    }

    // MARK: Alerts

    /// GitHub alerts: a blockquote whose first paragraph starts with `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`,
    /// `[!WARNING]` or `[!CAUTION]`. cmark renders them as plain blockquotes with the marker as text; this rewrites
    /// that fixed shape (`<blockquote>\n<p>[!TYPE]` …) into a titled alert block.
    ///
    /// Each alert ends at the `</blockquote>` that matches its own opening (quotes inside it are counted), and the
    /// alerts nested inside it are rewritten by the same pass on its inner HTML, so an alert inside an alert renders
    /// as one inside the other. Matches that sit inside an alert already rewritten are skipped at the outer level, so
    /// every range starts at or after the cursor (S-16 F34: a nested alert used to build a negative-length range).
    enum Alerts {
        static let kinds: [String: String] = [
            "NOTE": String(localized: "Note", bundle: .module, comment: "Title of a Markdown alert box (GitHub's [!NOTE])."),
            "TIP": String(localized: "Tip", bundle: .module, comment: "Title of a Markdown alert box (GitHub's [!TIP])."),
            "IMPORTANT": String(localized: "Important", bundle: .module, comment: "Title of a Markdown alert box (GitHub's [!IMPORTANT])."),
            "WARNING": String(localized: "Warning", bundle: .module, comment: "Title of a Markdown alert box (GitHub's [!WARNING])."),
            "CAUTION": String(localized: "Caution", bundle: .module, comment: "Title of a Markdown alert box (GitHub's [!CAUTION])."),
        ]
        static let pattern = try! NSRegularExpression(pattern: #"<blockquote>\n<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:<br />)?\n?"#)

        /// How deep alerts inside alerts are rewritten; deeper ones stay plain quotes, so a pathological nest costs
        /// at most this many passes over its text.
        static let maxDepth = 16
        private static let closeTag = "</blockquote>"

        static func transform(_ html: String) -> String { transform(html, depth: 0) }

        private static func transform(_ html: String, depth: Int) -> String {
            let ns = html as NSString
            var out = ""
            var cursor = 0
            for m in pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                // Inside an alert this pass already rewrote; the recursion below handled it.
                guard m.range.location >= cursor else { continue }
                guard let close = matchingClose(in: ns, from: m.range.upperBound) else { continue }
                let kind = ns.substring(with: m.range(at: 1))
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                var inner = ns.substring(with: NSRange(location: m.range.upperBound, length: close - m.range.upperBound))
                if inner.hasPrefix("</p>") { inner.removeFirst(4) } else { inner = "<p>" + inner }   // marker was alone on its line
                if depth + 1 < maxDepth { inner = transform(inner, depth: depth + 1) }
                out += "<div class=\"alert alert-\(kind.lowercased())\" role=\"note\"><p class=\"alert-title\">\(kinds[kind] ?? kind)</p>\(inner)</div>"
                cursor = close + (closeTag as NSString).length
            }
            out += ns.substring(from: cursor)
            return out
        }

        /// The location of the `</blockquote>` that closes the quote opened just before `start`, counting the quotes
        /// opened and closed in between; nil when it never closes. Every location returned is ≥ `start`.
        static func matchingClose(in ns: NSString, from start: Int) -> Int? {
            let length = ns.length
            /// The next match of `needle` at or after `from`, or nil when there is none.
            func next(_ needle: String, from: Int) -> NSRange? {
                guard from < length else { return nil }
                let r = ns.range(of: needle, options: [.caseInsensitive], range: NSRange(location: from, length: length - from))
                return r.location == NSNotFound ? nil : r
            }
            var depth = 1
            // Each search result is kept until the scan passes it, so every character is searched at most twice.
            var open = next("<blockquote", from: start)
            var close = next(closeTag, from: start)
            while let c = close {
                if let o = open, o.location < c.location {
                    // Only a real opening tag counts (`<blockquote>` or `<blockquote …>`, not `<blockquotes>`).
                    let after = o.upperBound < length ? ns.character(at: o.upperBound) : 0
                    if [0x3E, 0x20, 0x0A, 0x09, 0x0D, 0x0C, 0x2F].contains(after) { depth += 1 }
                    open = next("<blockquote", from: o.upperBound)
                    continue
                }
                depth -= 1
                if depth == 0 { return c.location }
                close = next(closeTag, from: c.upperBound)
            }
            return nil
        }
    }

    // MARK: Emoji

    enum Emoji {
        static let pattern = try! NSRegularExpression(pattern: #":([a-z0-9_+-]+):"#)

        /// Walks the AST and replaces `:shortcode:` in text nodes only; code spans, code blocks and URLs are
        /// separate node types and are never touched.
        static func replaceShortcodes(in doc: UnsafeMutablePointer<cmark_node>) {
            guard let iter = cmark_iter_new(doc) else { return }
            defer { cmark_iter_free(iter) }
            while true {
                let ev = cmark_iter_next(iter)
                if ev == CMARK_EVENT_DONE { break }
                guard ev == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iter), cmark_node_get_type(node) == CMARK_NODE_TEXT,
                      let lit = cmark_node_get_literal(node) else { continue }
                let text = String(cString: lit)
                guard text.contains(":") else { continue }
                let replaced = replace(text)
                if replaced != text { _ = replaced.withCString { cmark_node_set_literal(node, $0) } }
            }
        }

        static func replace(_ text: String) -> String {
            let ns = text as NSString
            var out = ""; var cursor = 0
            for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let emoji = EmojiTable.shortcodes[ns.substring(with: m.range(at: 1))] else { continue }
                out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)) + emoji
                cursor = m.range.upperBound
            }
            return out + ns.substring(from: cursor)
        }
    }

    // MARK: Math

    struct MathSpan { let tex: String; let display: Bool }

    /// `$$ … $$` (display, may span lines) and `$ … $` (inline, one line, no space after the opening or before the
    /// closing dollar, as GitHub requires) are cut out before cmark sees them, because cmark would otherwise treat
    /// `_` and `*` inside TeX as emphasis. Fenced code blocks and inline code spans are skipped character by
    /// character, so a `$` in code is left alone. Each span becomes a private-use placeholder that survives
    /// parsing and is swapped for a KaTeX-ready element afterwards.
    enum Math {
        static let marker: Character = "\u{E000}"

        static func lift(_ src: String) -> (String, [MathSpan]) {
            var out = ""; out.reserveCapacity(src.utf8.count)
            var spans: [MathSpan] = []
            let chars = Array(src)
            var i = 0
            var fence: String? = nil        // inside ``` or ~~~ block
            var atLineStart = true
            while i < chars.count {
                let c = chars[i]
                if atLineStart {
                    // fence open/close
                    var j = i; while j < chars.count, chars[j] == " ", j - i < 3 { j += 1 }
                    if j < chars.count, chars[j] == "`" || chars[j] == "~" {
                        let f = chars[j]; var k = j; while k < chars.count, chars[k] == f { k += 1 }
                        if k - j >= 3 {
                            let run = String(repeating: f, count: k - j)
                            if let open = fence { if run.hasPrefix(open) { fence = nil } } else { fence = run }
                            let eol = chars[i...].firstIndex(of: "\n") ?? chars.count
                            out += String(chars[i..<eol]); i = eol; continue
                        }
                    }
                }
                if fence != nil { out.append(c); atLineStart = c == "\n"; i += 1; continue }
                if c == "`" {   // inline code: copy through the matching run of backticks
                    var k = i; while k < chars.count, chars[k] == "`" { k += 1 }
                    let run = String(chars[i..<k])
                    if let end = find(run, in: chars, from: k) {
                        out += String(chars[i..<end + run.count]); i = end + run.count; atLineStart = false; continue
                    }
                    out.append(c); i += 1; atLineStart = false; continue
                }
                if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" { out += "\\$"; i += 2; atLineStart = false; continue }
                if c == "$" {
                    if i + 1 < chars.count, chars[i + 1] == "$", let end = find("$$", in: chars, from: i + 2) {
                        spans.append(MathSpan(tex: String(chars[(i + 2)..<end]), display: true))
                        out += "\(marker)\(spans.count - 1)\(marker)"; i = end + 2; atLineStart = false; continue
                    }
                    if i + 1 < chars.count, chars[i + 1] != " ", chars[i + 1] != "\n", chars[i + 1] != "$",
                       let end = find("$", in: chars, from: i + 1, sameLine: true), end > i + 1, chars[end - 1] != " ",
                       end + 1 >= chars.count || !chars[end + 1].isNumber {
                        spans.append(MathSpan(tex: String(chars[(i + 1)..<end]), display: false))
                        out += "\(marker)\(spans.count - 1)\(marker)"; i = end + 1; atLineStart = false; continue
                    }
                }
                out.append(c); atLineStart = c == "\n"; i += 1
            }
            return (out, spans)
        }

        private static func find(_ needle: String, in chars: [Character], from: Int, sameLine: Bool = false) -> Int? {
            let n = Array(needle)
            var i = from
            while i + n.count <= chars.count {
                if sameLine, chars[i] == "\n" || chars[i] == "`" { return nil }   // inline math never crosses a line or a code span
                if chars[i] == "\\" { i += 2; continue }
                if Array(chars[i..<(i + n.count)]) == n { return i }
                i += 1
            }
            return nil
        }

        static func restore(_ html: String, spans: [MathSpan]) -> String {
            var out = html
            for (n, span) in spans.enumerated() {
                let tex = span.tex.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                let el = span.display ? "<div class=\"math math-display\">\(tex)</div>" : "<span class=\"math math-inline\">\(tex)</span>"
                out = out.replacingOccurrences(of: "\(marker)\(n)\(marker)", with: el)
                // cmark may have wrapped a lone display block in <p>…</p>; a div inside p is invalid HTML.
                out = out.replacingOccurrences(of: "<p>\(el)</p>", with: el)
            }
            return out
        }
    }
}
