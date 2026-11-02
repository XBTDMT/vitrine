import Foundation
import VitrineSupport

/// The Markdown dialects and the three other light markup languages Vitrine reads (M-11), each turned into the
/// Markdown the cmark pipeline draws (MarkdownHTML), before it runs:
/// - MDX and MDC: components are labelled blocks (`<div class="mdxc">`, the picked markdown design), MDX
///   imports and exports are hidden and counted, and a component's Markdown content still renders inside its block.
/// - Quarto and R Markdown: code chunks (```` ```{r label} ````) highlight as their language, with the chunk's label
///   and options as a caption; `::: {.callout-note}` blocks become the alert boxes GitHub alerts draw.
/// - reStructuredText, AsciiDoc and Org: headings, paragraphs, lists, code and literal blocks, quotes,
///   admonitions, links, images, inline markup and Org tables convert; anything else (grid tables, unknown
///   directives) is shown as source in a fenced block, never dropped.
/// Fenced code is never touched. Pure functions on strings, unit-tested directly. roadmap: S-4, S-12
public enum MarkdownDialects {
    /// The Markdown to render for `source` read as `dialect`.
    public static func prepare(_ source: String, dialect: FileKind.MarkdownDialect) -> String {
        let text = source.replacingOccurrences(of: "\r\n", with: "\n")
        switch dialect {
        case .commonMark: return text
        case .mdx, .mdc: return Components.transform(text, mdx: dialect == .mdx)
        case .quarto, .rMarkdown: return Chunks.transform(text)
        case .reStructuredText: return ReST.convert(text)
        case .asciiDoc: return AsciiDoc.convert(text)
        case .org: return Org.convert(text)
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A fence that cannot be closed early by the lines inside it.
    static func fence(_ lines: [String], language: String) -> [String] {
        var ticks = "```"
        while lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(ticks) }) { ticks += "`" }
        return [ticks + language] + lines + [ticks]
    }

    /// Lines with fenced code kept as they are; `body` sees the rest one line at a time.
    static func outsideFences(_ lines: [String], _ body: (String) -> [String]) -> [String] {
        var out: [String] = []
        var open: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = open {
                out.append(line)
                if trimmed.hasPrefix(marker), trimmed.allSatisfy({ $0 == marker.first }) { open = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                open = String(trimmed.prefix { $0 == trimmed.first })
                out.append(line)
                continue
            }
            out += body(line)
        }
        return out
    }

    /// Applies `transform` to inline text outside `code spans`.
    static func outsideCode(_ line: String, _ transform: (String) -> String) -> String {
        var out = "", chunk = "", inCode = false
        for ch in line {
            if ch == "`" {
                out += inCode ? chunk + "`" : transform(chunk) + "`"
                chunk = ""
                inCode.toggle()
            } else {
                chunk.append(ch)
            }
        }
        return out + (inCode ? chunk : transform(chunk))
    }

    static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// GitHub alert kinds the alert boxes draw.
    static func alertKind(_ name: String) -> String? {
        switch name.lowercased() {
        case "note", "info", "seealso": "NOTE"
        case "tip", "hint": "TIP"
        case "important": "IMPORTANT"
        case "warning": "WARNING"
        case "caution", "danger", "attention", "error": "CAUTION"
        default: nil
        }
    }

    static func alert(_ kind: String, _ body: [String]) -> [String] {
        ["> [!\(kind)]"] + body.map { $0.isEmpty ? ">" : "> " + $0 } + [""]
    }

    // MARK: MDX and MDC

    enum Components {
        static let caption = String(localized: "MDX component — rendered by your site, shown here as a labelled block", bundle: .module, comment: "Caption under an MDX component in a Markdown preview; MDX is a format name.")

        static func transform(_ text: String, mdx: Bool) -> String {
            var lines = text.components(separatedBy: "\n")
            var imports: [String] = []
            if mdx {
                // Top-level ESM: `import … from "…"` and `export …` lines, outside code, are hidden and counted.
                lines = outsideFences(lines) { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("import ") || t.hasPrefix("export ") { imports.append(t); return [] }
                    return [line]
                }
            }
            var out: [String] = []
            var openTags: [String] = []
            var fenceOpen: String?
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if let marker = fenceOpen {
                    out.append(line)
                    if t.hasPrefix(marker) { fenceOpen = nil }
                    continue
                }
                if t.hasPrefix("```") || t.hasPrefix("~~~") { fenceOpen = String(t.prefix { $0 == t.first }); out.append(line); continue }
                if mdx, let tag = jsxTag(t) {
                    switch tag.kind {
                    case .selfClosing:
                        out += ["", "<div class=\"mdxc\"><span class=\"mdxt\">\(escape(t))</span><p class=\"mdxn\">\(caption)</p></div>", ""]
                    case .open:
                        openTags.append(tag.name)
                        out += ["", "<div class=\"mdxc\"><span class=\"mdxt\">\(escape(t))</span>", ""]
                    case .close where openTags.last == tag.name:
                        openTags.removeLast()
                        out += ["", "</div>", ""]
                    case .close:
                        out.append(line)
                    }
                    continue
                }
                if !mdx, t.hasPrefix("::") {
                    // MDC: `::name{props}` opens a block, a bare `::` closes it; `:::` nests the same way.
                    let name = t.drop { $0 == ":" }
                    if name.isEmpty, !openTags.isEmpty {
                        openTags.removeLast()
                        out += ["", "</div>", ""]
                    } else if !name.isEmpty {
                        openTags.append(String(name))
                        out += ["", "<div class=\"mdxc\"><span class=\"mdxt\">\(escape(t))</span>", ""]
                    } else {
                        out.append(line)
                    }
                    continue
                }
                out.append(line)
            }
            for _ in openTags { out += ["", "</div>", ""] }
            if !imports.isEmpty {
                let first = escape(imports[0].hasPrefix("import ") ? String(imports[0].dropFirst(7)) : imports[0])
                let word = imports[0].hasPrefix("import ") ? "import" : "export"
                let count = imports.count == 1 ? String(localized: "1 import hidden", bundle: .module, comment: "MDX preview: one import line is hidden.")
                    : String(localized: "\(imports.count) imports and exports hidden", bundle: .module, comment: "MDX preview: how many import and export lines are hidden (2 or more).")
                out += ["", "<p class=\"mdxi\"><span class=\"mdxt\">\(word)</span> \(first) — \(count)</p>"]
            }
            return out.joined(separator: "\n")
        }

        enum Kind { case open, close, selfClosing }

        /// A line that is one JSX element tag of a capitalised component: `<Steps />`, `<Callout type="info">`, `</Callout>`.
        static func jsxTag(_ t: String) -> (name: String, kind: Kind)? {
            guard t.hasPrefix("<"), t.hasSuffix(">") else { return nil }
            let closing = t.hasPrefix("</")
            let start = t.index(t.startIndex, offsetBy: closing ? 2 : 1)
            guard start < t.endIndex, t[start].isUppercase else { return nil }
            let name = String(t[start...].prefix { $0.isLetter || $0.isNumber || $0 == "." })
            guard !name.isEmpty else { return nil }
            // One tag only: no second `<` after the first (inline content like `<B>x</B>` stays as it is).
            guard t.dropFirst().firstIndex(of: "<") == nil else { return nil }
            if closing { return (name, .close) }
            return (name, t.hasSuffix("/>") ? .selfClosing : .open)
        }
    }

    // MARK: Quarto and R Markdown

    enum Chunks {
        static func transform(_ text: String) -> String {
            var out: [String] = []
            var callouts = 0
            for line in text.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                // ```{r label, echo=FALSE} → ```r with the label and options as a caption above it.
                if t.hasPrefix("```{"), let close = t.firstIndex(of: "}") {
                    let inner = t[t.index(t.startIndex, offsetBy: 4)..<close]
                    let parts = inner.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let head = parts.first ?? ""
                    let language = head.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
                    let label = head.split(separator: " ").dropFirst().joined(separator: " ")
                    let options = parts.count > 1 ? parts[1] : ""
                    let caption = [label, options].filter { !$0.isEmpty }.joined(separator: " · ")
                    // A blank line after the caption: cmark ends an HTML block only there, or it would swallow the fence.
                    if !caption.isEmpty { out += ["", "<p class=\"mdxi\"><span class=\"mdxt\">\(escape(language))</span> \(escape(caption))</p>", ""] }
                    out.append("```" + language)
                    continue
                }
                // ::: {.callout-note} … ::: → an alert box; other fenced divs keep their content, without the fences.
                if t.hasPrefix(":::") {
                    let attrs = t.drop { $0 == ":" }.trimmingCharacters(in: .whitespaces)
                    if attrs.isEmpty {
                        if callouts > 0 { callouts -= 1; out.append("") }
                        continue
                    }
                    if let range = attrs.range(of: #"callout-([a-z]+)"#, options: .regularExpression),
                       let kind = alertKind(String(attrs[range].dropFirst(8))) {
                        callouts += 1
                        out += ["", "> [!\(kind)]"]
                        continue
                    }
                    continue
                }
                out.append(callouts > 0 ? (line.isEmpty ? ">" : "> " + line) : line)
            }
            return out.joined(separator: "\n")
        }
    }

    // MARK: reStructuredText

    enum ReST {
        static let adornment = CharacterSet(charactersIn: "=-~^\"'`#*+:.,_;!?<>$%&()[]{}|/\\@")

        static func isAdornment(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard t.count >= 3, let first = t.unicodeScalars.first, adornment.contains(first) else { return false }
            return t.unicodeScalars.allSatisfy { $0 == first }
        }

        static func convert(_ text: String) -> String {
            let lines = text.components(separatedBy: "\n")
            var out: [String] = []
            var levels: [String] = []
            var targets: [String: String] = [:]
            for line in lines {
                if let m = line.range(of: #"^\.\. _([^:]+):\s*(\S+)\s*$"#, options: .regularExpression) {
                    let body = line[m].dropFirst(4)
                    if let colon = body.firstIndex(of: ":") {
                        targets[body[..<colon].lowercased()] = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            var i = 0
            func indentedBlock(from start: Int) -> (lines: [String], next: Int) {
                var j = start
                var block: [String] = []
                while j < lines.count, lines[j].isEmpty { j += 1 }
                while j < lines.count, lines[j].isEmpty || lines[j].hasPrefix(" ") || lines[j].hasPrefix("\t") {
                    block.append(lines[j]); j += 1
                }
                while block.last?.isEmpty == true { block.removeLast() }
                let indent = block.filter { !$0.isEmpty }.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
                return (block.map { $0.isEmpty ? "" : String($0.dropFirst(indent)) }, j)
            }
            while i < lines.count {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                // Section titles: an underline (and optional overline) of one punctuation character.
                if i + 1 < lines.count, !t.isEmpty, !isAdornment(line), isAdornment(lines[i + 1]),
                   lines[i + 1].trimmingCharacters(in: .whitespaces).count >= t.count {
                    let style = String(lines[i + 1].trimmingCharacters(in: .whitespaces).first!) + (i > 0 && isAdornment(lines[i - 1]) ? "o" : "")
                    if !levels.contains(style) { levels.append(style) }
                    out.append(String(repeating: "#", count: min(6, levels.firstIndex(of: style)! + 1)) + " " + inline(t, targets))
                    i += 2
                    continue
                }
                if isAdornment(line), i + 1 < lines.count, i + 2 < lines.count, isAdornment(lines[i + 2]) { i += 1; continue }
                if t.hasPrefix(".. ") {
                    let directive = t.dropFirst(3)
                    if directive.hasPrefix("_") { i += 1; continue }   // hyperlink target, resolved inline
                    if let sep = directive.range(of: "::") {
                        let name = directive[..<sep.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
                        let argument = directive[sep.upperBound...].trimmingCharacters(in: .whitespaces)
                        let (block, next) = indentedBlock(from: i + 1)
                        let body = block.filter { !$0.hasPrefix(":") }
                        switch name {
                        case "code-block", "code", "sourcecode":
                            out += fence(body, language: argument.lowercased())
                        case "image", "figure":
                            out.append("![\(block.first { $0.hasPrefix(":alt:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) } ?? "")](\(argument))")
                            if name == "figure" { out += body.map { inline($0, targets) } }
                        case "admonition":
                            out += alert("NOTE", ["**\(inline(argument, targets))**", ""] + body.map { inline($0, targets) })
                        default:
                            if let kind = alertKind(name) {
                                out += alert(kind, (argument.isEmpty ? [] : [inline(argument, targets)]) + body.map { inline($0, targets) })
                            } else {
                                out += fence([line] + block.map { "   " + $0 }, language: "rst")
                            }
                        }
                        i = next
                        continue
                    }
                    // A comment: hidden, with its indented lines.
                    i = indentedBlock(from: i + 1).next
                    continue
                }
                // Literal block: a paragraph ending in `::` followed by an indented block.
                if t.hasSuffix("::"), i + 1 < lines.count {
                    let (block, next) = indentedBlock(from: i + 1)
                    if !block.isEmpty {
                        let lead = t == "::" ? "" : String(t.dropLast(t.hasSuffix(" ::") ? 3 : 1))
                        if !lead.isEmpty { out += [inline(lead, targets), ""] }
                        out += fence(block, language: "")
                        i = next
                        continue
                    }
                }
                // Grid and simple tables: shown as source.
                if t.hasPrefix("+-") || (t.hasPrefix("==") && t.contains(" ") && isTableRule(t)) {
                    var block: [String] = []
                    while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { block.append(lines[i]); i += 1 }
                    out += fence(block, language: "rst")
                    continue
                }
                // Enumerated lists written `#.` become numbered.
                var converted = line
                if let r = converted.range(of: #"^(\s*)#\. "#, options: .regularExpression) {
                    converted.replaceSubrange(r, with: converted[r].replacingOccurrences(of: "#.", with: "1."))
                }
                out.append(inline(converted, targets))
                i += 1
            }
            return out.joined(separator: "\n")
        }

        static func isTableRule(_ t: String) -> Bool { t.allSatisfy { $0 == "=" || $0 == " " } }

        static func inline(_ s: String, _ targets: [String: String]) -> String {
            var t = s
            // Single-backtick constructs first (they are not code in reST): `text <url>`_ links, then :role:`text`.
            t = replace(t, #"(?<!`)`([^`<]+?)\s*<([^>`]+)>`__?"#, "[$1]($2)")
            t = replace(t, #":[a-z:+-]+:`([^`]+)`"#, "``$1``")   // the role is dropped, its text kept as code
            // ``literal`` → `literal`, so its contents are protected below.
            t = replace(t, #"``([^`]+)``"#, "`$1`")
            return outsideCode(t) { part in
                var p = part
                if let re = try? NSRegularExpression(pattern: #"`([^`]+)`_\b|(\b[A-Za-z0-9-]+)_\b"#) {
                    let ns = p as NSString
                    var result = "", last = 0
                    for m in re.matches(in: p, range: NSRange(location: 0, length: ns.length)) {
                        let r1 = m.range(at: 1), r2 = m.range(at: 2)
                        let name = ns.substring(with: r1.location != NSNotFound ? r1 : r2)
                        guard let url = targets[name.lowercased()] else { continue }
                        result += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + "[\(name)](\(url))"
                        last = m.range.location + m.range.length
                    }
                    p = result + ns.substring(from: last)
                }
                return p
            }
        }
    }

    // MARK: AsciiDoc

    enum AsciiDoc {
        static func convert(_ text: String) -> String {
            let lines = text.components(separatedBy: "\n")
            var out: [String] = []
            var i = 0
            var pendingStyle: String?
            var inHeader = true
            while i < lines.count {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//"), !t.hasPrefix("////") { i += 1; continue }
                if t == "////" {   // comment block
                    i += 1
                    while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "////" { i += 1 }
                    i += 1
                    continue
                }
                if inHeader, t.hasPrefix(":"), t.dropFirst().contains(":") { i += 1; continue }   // document attributes
                if !t.isEmpty, !t.hasPrefix("=") { inHeader = false }
                if t.hasPrefix("["), t.hasSuffix("]"), !t.hasPrefix("[[") { pendingStyle = String(t.dropFirst().dropLast()); i += 1; continue }
                if let delimiter = ["----", "....", "====", "____", "****", "|==="].first(where: { t.hasPrefix($0) && t.allSatisfy { $0 == t.first } || t == $0 }) {
                    var block: [String] = []
                    i += 1
                    while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != t { block.append(lines[i]); i += 1 }
                    i += 1
                    let style = pendingStyle?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                    pendingStyle = nil
                    switch delimiter {
                    case "----": out += fence(block, language: style.first == "source" ? (style.count > 1 ? style[1].lowercased() : "") : "")
                    case "....": out += fence(block, language: "")
                    case "____": out += block.map { "> " + inline($0) } + [""]
                    case "====":
                        if let first = style.first, let kind = alertKind(first) { out += alert(kind, block.map(inline)) }
                        else { out += convert(block.joined(separator: "\n")).components(separatedBy: "\n") }
                    case "|===": out += fence([t] + block + [t], language: "asciidoc")
                    default: out += block.map(inline)   // sidebar: its content
                    }
                    continue
                }
                pendingStyle = nil
                if let level = heading(t) { out.append(String(repeating: "#", count: min(6, level)) + " " + inline(t.drop { $0 == "=" }.trimmingCharacters(in: .whitespaces))); i += 1; continue }
                if let colon = t.firstIndex(of: ":"), let kind = alertKind(String(t[..<colon])), t[t.index(after: colon)...].hasPrefix(" "),
                   t[..<colon].allSatisfy({ $0.isUppercase }) {
                    out += alert(kind, [inline(t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces))])
                    i += 1
                    continue
                }
                if t.hasPrefix("image::") { out.append(image(String(t.dropFirst(7)))); i += 1; continue }
                if t.hasPrefix("."), t.count > 1, !t.hasPrefix(".."), t.dropFirst().first?.isLetter == true { out += ["", "**\(inline(String(t.dropFirst())))**"]; i += 1; continue }
                // Lists: `*`, `**` nest; `.`, `..` numbered.
                if let r = t.range(of: #"^(\*+|\.+|-) "#, options: .regularExpression) {
                    let marker = t[r].dropLast()
                    let depth = max(0, marker.count - 1)
                    let ordered = marker.first == "."
                    out.append(String(repeating: "  ", count: depth) + (ordered ? "1. " : "- ") + inline(String(t[r.upperBound...])))
                    i += 1
                    continue
                }
                out.append(inline(line))
                i += 1
            }
            return out.joined(separator: "\n")
        }

        static func heading(_ t: String) -> Int? {
            let level = t.prefix { $0 == "=" }.count
            guard level > 0, t.dropFirst(level).hasPrefix(" ") else { return nil }
            return level
        }

        static func image(_ s: String) -> String {
            guard let open = s.firstIndex(of: "[") else { return "![](\(s))" }
            let alt = s[s.index(after: open)...].prefix { $0 != "]" }.split(separator: ",").first.map(String.init) ?? ""
            return "![\(alt)](\(s[..<open]))"
        }

        static func inline(_ s: String) -> String {
            var t = replace(s, #"\+([^+]+)\+"#, "`$1`")
            t = outsideCode(t) { part in
                var p = part
                p = replace(p, #"image:([^\[\s]+)\[([^\],]*)[^\]]*\]"#, "![$2]($1)")
                p = replace(p, #"link:([^\[\s]+)\[([^\]]*)\]"#, "[$2]($1)")
                p = replace(p, #"(https?://[^\[\s]+)\[([^\]]+)\]"#, "[$2]($1)")
                p = replace(p, #"<<([^,>]+),([^>]+)>>"#, "[$2](#$1)")
                p = replace(p, #"<<([^>]+)>>"#, "[$1](#$1)")
                p = replace(p, #"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#, "**$1**")
                p = replace(p, #"(?<![\w_])_([^_\n]+)_(?![\w_])"#, "*$1*")
                return p
            }
            return t
        }
    }

    // MARK: Org

    enum Org {
        static func convert(_ text: String) -> String {
            let lines = text.components(separatedBy: "\n")
            var out: [String] = []
            var i = 0
            // With a #+TITLE the title is the one top heading and `*` sections sit under it.
            let shift = lines.contains { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("#+TITLE:") } ? 1 : 0
            while i < lines.count {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                let upper = t.uppercased()
                if upper.hasPrefix("#+TITLE:") { out.append("# " + inline(t.dropFirst(8).trimmingCharacters(in: .whitespaces))); i += 1; continue }
                if upper.hasPrefix("#+BEGIN_") {
                    let kind = upper.dropFirst(8).prefix { !$0.isWhitespace }
                    let argument = t.dropFirst(8 + kind.count).trimmingCharacters(in: .whitespaces)
                    var block: [String] = []
                    i += 1
                    while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("#+END_\(kind)") { block.append(lines[i]); i += 1 }
                    i += 1
                    switch kind {
                    case "SRC": out += fence(block, language: argument.split(separator: " ").first.map { $0.lowercased() } ?? "")
                    case "EXAMPLE", "VERSE": out += fence(block, language: "")
                    case "QUOTE": out += block.map { "> " + inline($0) } + [""]
                    default:
                        if let alertKind = alertKind(String(kind)) { out += alert(alertKind, block.map(inline)) }
                        else { out += fence([t] + block + ["#+END_\(kind)"], language: "org") }
                    }
                    continue
                }
                if t.hasPrefix("#+") || (t.hasPrefix("# ") || t == "#") { i += 1; continue }   // keywords and comments
                if t == ":PROPERTIES:" || t == ":LOGBOOK:" {
                    while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != ":END:" { i += 1 }
                    i += 1
                    continue
                }
                if let level = heading(line) {
                    var title = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    title = replace(title, #"\s+:[\w@#%:]+:\s*$"#, "")   // tags
                    out.append(String(repeating: "#", count: min(6, level + shift)) + " " + inline(title))
                    i += 1
                    continue
                }
                // Tables: `|---+---|` rules become GitHub table rules; a table without one gets a rule after its first row.
                if t.hasPrefix("|") {
                    var rows: [String] = []
                    var ruled = false
                    while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                        let r = lines[i].trimmingCharacters(in: .whitespaces)
                        if r.hasPrefix("|-") {
                            if !ruled, !rows.isEmpty {
                                let cells = rows[0].split(separator: "|", omittingEmptySubsequences: false).count - 2
                                rows.append("|" + String(repeating: " --- |", count: max(1, cells)))
                                ruled = true
                            }
                        } else {
                            rows.append(inline(r))
                        }
                        i += 1
                    }
                    if !ruled, !rows.isEmpty {
                        let cells = rows[0].split(separator: "|", omittingEmptySubsequences: false).count - 2
                        rows.insert("|" + String(repeating: " --- |", count: max(1, cells)), at: 1)
                    }
                    out += [""] + rows + [""]
                    continue
                }
                var converted = line
                converted = replace(converted, #"^(\s*)(\d+)\) "#, "$1$2. ")
                converted = replace(converted, #"^(\s*)\+ "#, "$1- ")
                converted = replace(converted, #"^(\s*[-*] )\[X\] "#, "$1[x] ")
                out.append(inline(converted))
                i += 1
            }
            return out.joined(separator: "\n")
        }

        static func heading(_ line: String) -> Int? {
            let level = line.prefix { $0 == "*" }.count
            guard level > 0, line.dropFirst(level).hasPrefix(" ") else { return nil }
            return level
        }

        static func inline(_ s: String) -> String {
            var t = replace(s, #"(?<![\w=])=([^=\n]+)=(?![\w=])"#, "`$1`")
            t = replace(t, #"(?<![\w~])~([^~\n]+)~(?![\w~])"#, "`$1`")
            return outsideCode(t) { part in
                var p = part
                p = replace(p, #"\[\[([^\]]+)\]\[([^\]]+)\]\]"#, "[$2]($1)")
                p = replace(p, #"\[\[([^\]]+)\]\]"#, "<$1>")
                p = replace(p, #"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#, "**$1**")
                p = replace(p, #"(?<![\w/:])/([^/\n]+)/(?![\w/])"#, "*$1*")
                p = replace(p, #"(?<![\w+])\+([^+\n]+)\+(?![\w+])"#, "~~$1~~")
                return p
            }
        }
    }
}
