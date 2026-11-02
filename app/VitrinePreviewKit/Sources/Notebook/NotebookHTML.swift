import Foundation

/// Text helpers for the notebook page: escaping, the terminal colour codes kernels put in tracebacks, and the
/// allowlist that rebuilds an HTML output before it reaches the page. roadmap: S-21
///
/// Why HTML outputs are rebuilt rather than passed through: an output is whatever the kernel printed, and a notebook
/// from anywhere can carry `<script>`, event handlers, `<iframe>`, forms, styles that cover the page, or remote
/// images. The page's CSP and the G-9 content rule list already stop scripts and every load; the rebuild also keeps
/// out styles and markup that could dress up as Vitrine's own interface. Only the tags below survive, each with only
/// its listed attributes; text is re-escaped; the elements in `dropWithContent` go with everything inside them.
enum NotebookHTML {
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for ch in text.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    // MARK: Terminal text

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[@-Z\\\\-_])")

    /// Removes terminal colour and cursor codes (IPython colours every traceback), and applies carriage returns the
    /// way a terminal would, so a progress bar shows its last state instead of every step.
    static func terminalText(_ text: String) -> String {
        var s = text
        if s.contains("\u{1B}") {
            s = ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            s = s.replacingOccurrences(of: "\u{1B}", with: "")
        }
        guard s.contains("\r") else { return s }
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        return s.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let last = line.lastIndex(of: "\r") else { return String(line) }
            let after = line[line.index(after: last)...]
            return after.isEmpty ? String(line.split(separator: "\r").last ?? "") : String(after)
        }.joined(separator: "\n")
    }

    // MARK: The allowlist

    static let allowed: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "caption", "code", "col", "colgroup", "dd", "del", "details", "div", "dl", "dt",
        "em", "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd", "li", "mark", "ol",
        "p", "pre", "q", "s", "samp", "small", "span", "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot",
        "th", "thead", "tr", "u", "ul", "var",
    ]
    static let void: Set<String> = ["br", "col", "hr", "img"]
    /// Elements removed together with everything inside them. Never a void element: it has no content and no closing
    /// tag, so the rebuild would look for `</name>` that never comes and take the rest of the output with it
    /// (`dropVoid` holds those).
    static let dropWithContent: Set<String> = [
        "script", "style", "template", "iframe", "object", "noscript", "svg", "math", "textarea", "title", "head",
        "select", "canvas", "video", "audio", "applet", "frameset", "noembed", "noframes", "xmp", "plaintext",
    ]
    /// Void elements removed: only the tag itself goes (S-16 follow-up A).
    static let dropVoid: Set<String> = ["embed", "frame"]

    /// HTML's void elements (the HTML Standard's list, with the obsolete ones browsers still parse as void). A
    /// policy that lists one in `dropWithContent` still drops only its tag, for the reason above.
    static let htmlVoid: Set<String> = [
        "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "image", "img", "input", "keygen", "link",
        "meta", "param", "source", "track", "wbr",
    ]
    /// Foreign elements a browser closes on `/>` (`<svg/>` has no content): dropped with their content, they too
    /// drop only the tag when written self-closing.
    static let selfClosingForeign: Set<String> = ["svg", "math"]

    /// What one rebuild keeps. The notebook's own is `notebook`; other pages reuse the same rebuild with theirs
    /// (MarkdownExportHTML, for an exported Markdown page, S-16 F1). roadmap: S-21, S-16
    struct Policy: Sendable {
        /// The tags that survive, each with only the attributes `keep` returns a value for.
        var allowed: Set<String>
        /// Allowed tags that never take content or a closing tag.
        var void: Set<String>
        /// Elements removed together with everything inside them.
        var dropWithContent: Set<String>
        /// `keep(tag, attribute, value)`: the value to write (checked, entities already decoded), or nil to drop it.
        var keep: @Sendable (_ tag: String, _ name: String, _ value: String) -> String?
        /// A tag that goes when it kept none of the attribute named here (an image with no source it may show).
        var required: [String: String] = ["img": "src"]
        /// Elements whose content is kept only as escaped text, never read as markup, and only inside an open
        /// element of the named kind (an SVG's `<style>`, inside `svg`); anywhere else they go with their content.
        var rawText: [String: String] = [:]
        /// Void elements that go (they have no content and no closing tag, so only the tag itself is removed).
        var dropVoid: Set<String> = []
    }

    /// The notebook's policy: the tags and attributes above, nothing else.
    static let notebook = Policy(allowed: allowed, void: void, dropWithContent: dropWithContent, keep: keep, dropVoid: dropVoid)

    /// The attributes a tag may keep, and how each value is checked.
    private static func keep(_ tag: String, _ name: String, _ value: String) -> String? {
        let digits = { (v: String) in !v.isEmpty && v.count <= 5 && v.allSatisfy(\.isASCII) && v.allSatisfy(\.isNumber) ? v : nil }
        switch (tag, name) {
        case ("td", "colspan"), ("td", "rowspan"), ("th", "colspan"), ("th", "rowspan"), ("ol", "start"),
             ("img", "width"), ("img", "height"):
            return digits(value)
        case ("td", "align"), ("th", "align"):
            return ["left", "right", "center"].contains(value.lowercased()) ? value.lowercased() : nil
        case ("img", "alt"), ("abbr", "title"):
            return value
        case ("img", "src"):
            // Only an image carried in the output itself; a URL would be a load (blocked anyway) or a tracker.
            return value.range(of: #"^data:image/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=\s]+$"#, options: .regularExpression) != nil ? value : nil
        default:
            return nil
        }
    }

    private static let entity = try! NSRegularExpression(pattern: "^&(?:#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});")

    /// Rebuilds `html` from the notebook's allowlist. The result is balanced: every element it opens, it closes.
    static func sanitize(_ html: String) -> String { sanitize(html, policy: notebook) }

    /// Rebuilds `html` from `policy`. The result is balanced: every element it opens, it closes.
    static func sanitize(_ html: String, policy: Policy) -> String {
        let s = Array(html.unicodeScalars)
        var out = String.UnicodeScalarView()
        var open: [String] = []
        var i = 0
        func emit(_ text: String) { out.append(contentsOf: text.unicodeScalars) }
        func lower(_ c: Unicode.Scalar) -> Unicode.Scalar { (c >= "A" && c <= "Z") ? Unicode.Scalar(c.value + 32)! : c }
        func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\u{0C}" }
        func isNameStart(_ c: Unicode.Scalar) -> Bool { (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") }
        func isName(_ c: Unicode.Scalar) -> Bool { isNameStart(c) || (c >= "0" && c <= "9") || c == "-" || c == ":" }
        /// Index just past the next `>` from `j` that is not inside quotes; s.count when there is none.
        func endOfTag(_ j: Int) -> Int {
            var k = j, quote: Unicode.Scalar?
            while k < s.count {
                let c = s[k]
                if let q = quote { if c == q { quote = nil } } else if c == "\"" || c == "'" { quote = c } else if c == ">" { return k + 1 }
                k += 1
            }
            return s.count
        }
        /// Index of the `<` of the next `</name` (case-insensitive) from `j`; s.count when it never closes.
        func closingTag(_ name: String, from j: Int) -> Int {
            let needle = Array(("</" + name).unicodeScalars)
            var k = j
            while k + needle.count <= s.count {
                var hit = true
                for (n, c) in needle.enumerated() where lower(s[k + n]) != c { hit = false; break }
                if hit, k + needle.count == s.count || !isName(s[k + needle.count]) { return k }
                k += 1
            }
            return s.count
        }
        /// Index just past `</name …>` (case-insensitive) from `j`; s.count when it never closes.
        func pastClosing(_ name: String, from j: Int) -> Int {
            let k = closingTag(name, from: j)
            return k == s.count ? s.count : endOfTag(k + 2 + name.unicodeScalars.count)
        }

        while i < s.count {
            let c = s[i]
            if c != "<" {
                switch c {
                case "&":
                    let rest = String(String.UnicodeScalarView(s[i..<min(s.count, i + 40)]))
                    if let m = entity.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)), let r = Range(m.range, in: rest) {
                        emit(String(rest[r])); i += rest[r].unicodeScalars.count; continue
                    }
                    emit("&amp;")
                case ">": emit("&gt;")
                case "\"": emit("&quot;")
                default: out.append(c)
                }
                i += 1
                continue
            }
            // Comments, doctypes and processing instructions go.
            if i + 3 < s.count, s[i + 1] == "!", s[i + 2] == "-", s[i + 3] == "-" {
                var k = i + 4
                while k + 2 < s.count, !(s[k] == "-" && s[k + 1] == "-" && s[k + 2] == ">") { k += 1 }
                i = min(s.count, k + 3)
                continue
            }
            if i + 1 < s.count, s[i + 1] == "!" || s[i + 1] == "?" { i = endOfTag(i + 1); continue }
            let closing = i + 1 < s.count && s[i + 1] == "/"
            var k = i + (closing ? 2 : 1)
            guard k < s.count, isNameStart(s[k]) else { emit("&lt;"); i += 1; continue }
            var name = ""
            while k < s.count, isName(s[k]) { name.unicodeScalars.append(lower(s[k])); k += 1 }
            // Attributes, read the way a browser would (so a quoted ">" cannot end the tag early).
            var attributes: [(String, String)] = []
            // The tag ends in "/>", the "/" right before the ">" (one inside an unquoted value is the value's).
            var selfClosing = false
            while k < s.count, s[k] != ">" {
                if isSpace(s[k]) || s[k] == "/" { selfClosing = s[k] == "/"; k += 1; continue }
                selfClosing = false
                var attr = ""
                while k < s.count, !isSpace(s[k]), s[k] != ">", s[k] != "=", s[k] != "/" { attr.unicodeScalars.append(lower(s[k])); k += 1 }
                if attr.isEmpty { k += 1; continue }
                while k < s.count, isSpace(s[k]) { k += 1 }
                var value = ""
                if k < s.count, s[k] == "=" {
                    k += 1
                    while k < s.count, isSpace(s[k]) { k += 1 }
                    if k < s.count, s[k] == "\"" || s[k] == "'" {
                        let q = s[k]; k += 1
                        while k < s.count, s[k] != q { value.unicodeScalars.append(s[k]); k += 1 }
                        k += 1
                    } else {
                        while k < s.count, !isSpace(s[k]), s[k] != ">" { value.unicodeScalars.append(s[k]); k += 1 }
                    }
                }
                attributes.append((attr, value))
            }
            let next = min(s.count, k + 1)
            // An element with no content goes alone: a void element, or a foreign one written `<svg/>`. Searching
            // for a closing tag it never has would drop the rest of the output.
            if policy.dropVoid.contains(name)
                || (policy.dropWithContent.contains(name) && (htmlVoid.contains(name) || (selfClosing && selfClosingForeign.contains(name)))) {
                i = next; continue
            }
            if policy.dropWithContent.contains(name) {
                i = closing ? next : pastClosing(name, from: next)
                continue
            }
            if let parent = policy.rawText[name] {
                // Text only, up to its own closing tag; kept escaped, and only inside the element it belongs to.
                if closing { i = next; continue }
                let close = closingTag(name, from: next)   // where the content stops
                let end = pastClosing(name, from: next)
                if open.contains(parent) {
                    emit("<\(name)>")
                    var t = next
                    while t < close {
                        let ch = s[t]
                        switch ch {
                        case "&":
                            let rest = String(String.UnicodeScalarView(s[t..<min(close, t + 40)]))
                            if let m = entity.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)), let r = Range(m.range, in: rest) {
                                emit(String(rest[r])); t += rest[r].unicodeScalars.count; continue
                            }
                            emit("&amp;")
                        case "<": emit("&lt;")
                        case ">": emit("&gt;")
                        default: out.append(ch)
                        }
                        t += 1
                    }
                    emit("</\(name)>")
                }
                i = end
                continue
            }
            i = next
            guard policy.allowed.contains(name) else { continue }   // the tag goes, its text stays
            if closing {
                guard let at = open.lastIndex(of: name) else { continue }
                for tag in open[at...].reversed() { emit("</\(tag)>") }
                open.removeSubrange(at...)
                continue
            }
            var tag = "<" + name
            var keptNames: Set<String> = []
            for (attr, value) in attributes {
                guard let kept = policy.keep(name, attr, decodeBasicEntities(value)) else { continue }
                tag += " \(attr)=\"\(escape(kept))\""
                keptNames.insert(attr)
            }
            // An element without what it needs goes (notebook: an image with nothing it may show).
            if let needed = policy.required[name], !keptNames.contains(needed) { continue }
            emit(tag + ">")
            if !policy.void.contains(name) { open.append(name) }
        }
        for tag in open.reversed() { emit("</\(tag)>") }
        return String(out)
    }

    /// The few entities attribute values commonly use, so a checked value is checked as the browser would read it.
    private static func decodeBasicEntities(_ v: String) -> String {
        guard v.contains("&") else { return v }
        return v.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Whether rebuilt HTML still shows anything (text or an image); an output that was only scripts shows nothing.
    static func hasVisibleContent(_ sanitized: String) -> Bool {
        if sanitized.contains("<img ") { return true }
        let text = sanitized.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        return text.contains { !$0.isWhitespace }
    }
}
