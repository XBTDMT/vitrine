import Foundation
import VitrineCompare
import VitrineDocument
import VitrineSupport
import VitrineText

/// What the notebook page draws (design/mockups/unified/ai.html, state 11 "Notebook", pick r3-b Glass case), made in
/// Swift from `NotebookReader`: the header card (kind tile, title, the line of counts, the facts read from the file),
/// the caution inset when the cells ran out of order, then every cell as a card — Markdown rendered by `MarkdownHTML`,
/// code with its execution count in the gutter and its language for Shiki, outputs under it. Pure: no WebKit, so it is
/// tested directly and built off the main thread. roadmap: S-21
struct NotebookPage: Sendable {
    /// The page's `<main>`: header and cells.
    let body: String
    let document: PreviewDocument
    /// Shiki's id for the code cells' language; nil = not coloured.
    let language: String?

    /// Per-output bounds: longer text is cut with a line saying how much; a larger image is described, not drawn.
    struct Limits: Sendable {
        var maxOutputCharacters = 50_000
        var maxImageBase64 = 16 * 1024 * 1024
        var maxCells = 5_000
        static let standard = Limits()
    }

    /// Facts about the run order: the cells that ran after a cell below them, and the first such pair for the inset.
    struct RunOrder: Sendable, Equatable {
        /// Indexes (into the notebook's cells) of code cells whose count is higher than a count below them.
        var stale: Set<Int>
        /// The first stale cell's count and the lowest count below it.
        var first: (above: Int, below: Int)?
        static func == (a: RunOrder, b: RunOrder) -> Bool { a.stale == b.stale && a.first?.above == b.first?.above && a.first?.below == b.first?.below }
    }

    static func runOrder(_ cells: [NotebookReader.Cell]) -> RunOrder {
        let counted = cells.enumerated().compactMap { i, c in c.kind == .code ? c.executionCount.map { (i, $0) } : nil }
        var stale = Set<Int>()
        var first: (Int, Int)?
        var lowestBelow = Int.max
        var lowestFor: [Int: Int] = [:]
        for (i, n) in counted.reversed() {
            if n > lowestBelow { stale.insert(i); lowestFor[i] = lowestBelow }
            lowestBelow = min(lowestBelow, n)
        }
        if let i = counted.first(where: { stale.contains($0.0) }) { first = (i.1, lowestFor[i.0] ?? 0) }
        return RunOrder(stale: stale, first: first)
    }

    static func make(data: Data, fileName: String, fileSize: Int64, limits: Limits = .standard) throws -> NotebookPage {
        let notebook = try NotebookReader.read(data, side: nil, limits: NotebookCompareLimits(maxCells: limits.maxCells))
        return make(notebook: notebook, source: String(decoding: data, as: UTF8.self), fileName: fileName, fileSize: fileSize, limits: limits)
    }

    /// A marimo notebook (A-8): the same page, read from its Python text. marimo stores no outputs.
    static func make(marimo data: Data, fileName: String, fileSize: Int64, limits: Limits = .standard) throws -> NotebookPage {
        let notebook = try MarimoReader.read(data, limits: MarimoReader.Limits(maxCells: limits.maxCells))
        return make(notebook: notebook.notebookShape, source: String(decoding: data, as: UTF8.self), fileName: fileName,
                    fileSize: fileSize, limits: limits, marimo: notebook)
    }

    static func make(notebook nb: NotebookReader.Notebook, source: String, fileName: String, fileSize: Int64,
                     limits: Limits = .standard, marimo: MarimoReader.Notebook? = nil) -> NotebookPage {
        let language = shikiLanguage(nb)
        let order = runOrder(nb.cells)
        let code = nb.cells.filter { $0.kind == .code }.count
        let text = nb.cells.filter { $0.kind == .markdown }.count
        let raw = nb.cells.count - code - text
        let outputs = nb.cells.reduce(0) { $0 + mergedStreams($1.outputs).count }
        let images = nb.cells.reduce(0) { $0 + $1.outputs.filter { $0.type == .image }.count }
        let errors = nb.cells.reduce(0) { $0 + $1.outputs.filter { $0.type == .error }.count }
        let title = nb.title ?? firstHeading(nb.cells) ?? (fileName as NSString).deletingPathExtension
        let languageLabel = nb.language.map { lang in
            LanguageMap.displayName(for: lang.lowercased()) + (nb.languageVersion.map { " " + majorMinor($0) } ?? "")
        }

        // The header line: "Jupyter notebook · Python 3.12 · 14 cells · 9 code, 5 text · 6 outputs · 1 image, 1 error · 2.3 MB".
        // Each part is one whole localized phrase (H-6); " · " is the header's list separator.
        var line = [marimo == nil ? String(localized: "Jupyter notebook", bundle: .previewKit, comment: "Notebook header: the kind of file.")
                                  : String(localized: "marimo notebook", bundle: .previewKit, comment: "Notebook header: the kind of file. 'marimo' is a product name, kept in lower case.")]
        if let languageLabel { line.append(languageLabel) }
        line.append(cellCount(nb.totalCells))
        var kindParts: [String] = []
        if code > 0 { kindParts.append(String(localized: "\(code) code", bundle: .previewKit, comment: "Notebook header: how many code cells.")) }
        if text > 0 { kindParts.append(String(localized: "\(text) text", bundle: .previewKit, comment: "Notebook header: how many Markdown text cells.")) }
        if raw > 0 { kindParts.append(String(localized: "\(raw) raw", bundle: .previewKit, comment: "Notebook header: how many raw cells.")) }
        let kinds = kindParts.formatted(.list(type: .and, width: .narrow))
        if !kindParts.isEmpty { line.append(kinds) }
        let outputCount = marimo == nil
            ? String(localized: "\(outputs) outputs", bundle: .previewKit, comment: "Notebook header: how many cell outputs.")
            : String(localized: "no stored outputs", bundle: .previewKit, comment: "Notebook header for a marimo notebook: marimo saves code only, never outputs.")
        line.append(outputCount)
        var notable: [String] = []
        if images > 0 { notable.append(String(localized: "\(images) images", bundle: .previewKit, comment: "Notebook header: how many image outputs.")) }
        if errors > 0 { notable.append(String(localized: "\(errors) errors", bundle: .previewKit, comment: "Notebook header: how many error outputs.")) }
        if !notable.isEmpty { line.append(notable.formatted(.list(type: .and, width: .narrow))) }
        line.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))

        // The facts read from the file (.kv, CHANGES.md ai 1): a stable key, a label for people, the value.
        var kv: [(key: String, label: String, value: String)] = []
        if let kernel = nb.kernelDisplayName ?? nb.kernelName {
            kv.append(("kernel", String(localized: "Kernel", bundle: .previewKit, comment: "Notebook fact label: the Jupyter kernel."), kernel))
        }
        // nbformat is the file format's own name.
        if let format = nb.format {
            kv.append(("format", String(localized: "Format", bundle: .previewKit, comment: "Notebook fact label: the notebook format version."), "nbformat \(format)"))
        }
        if let run = runSpan(nb.cells) {
            kv.append(("ran", String(localized: "Ran", bundle: .previewKit, comment: "Notebook fact label: when the cells were run."), run))
        }
        if let marimo {
            if let version = marimo.version {
                kv.append(("marimo", String(localized: "Written by", bundle: .previewKit, comment: "Notebook fact label: the app and version that wrote a marimo notebook."), "marimo \(version)"))
            }
            if let width = marimo.width {
                kv.append(("width", String(localized: "Width", bundle: .previewKit, comment: "Notebook fact label: a marimo notebook's page width setting (medium, full, columns)."), width))
            }
        }
        let outOfOrder = String(localized: "Ran out of order", bundle: .previewKit,
                                comment: "Notebook warning: a cell ran after a cell below it.")

        var html = "<header class=\"nbhead\"><div class=\"hcard\"><span class=\"htile\" aria-hidden=\"true\">\(Icon.notebook)</span>"
        html += "<div class=\"htx\"><div class=\"ht\">\(NotebookHTML.escape(title))</div>"
        html += "<div class=\"hs\">\(NotebookHTML.escape(line.joined(separator: " · ")))</div>"
        if !kv.isEmpty {
            html += "<div class=\"kv hkv\">" + kv.map {
                "<span class=\"k\">\(NotebookHTML.escape($0.label))</span><span class=\"v\">\(NotebookHTML.escape($0.value))</span>"
            }.joined() + "</div>"
        }
        html += "</div></div>"
        if let first = order.first {
            html += "<div class=\"ginset bad cg\" role=\"status\"><div class=\"gr caution\"><span class=\"btile caution\" aria-hidden=\"true\">\(Icon.caution)</span>"
            html += "<div class=\"gk\"><div><b>\(NotebookHTML.escape(outOfOrder))</b></div><div class=\"gsub\">\(NotebookHTML.escape(outOfOrderSentence(first)))</div></div></div></div>"
        }
        if marimo != nil {
            html += note(String(localized: "marimo stores no outputs; the code is shown as written.", bundle: .previewKit,
                                comment: "Under a marimo notebook's header: the file holds code only, so nothing ran here and no results are shown."))
        }
        if nb.cut {
            let shown = String(localized: "Showing the first \(nb.cells.count) of \(nb.totalCells) cells", bundle: .previewKit,
                               comment: "Notebook notice: only the first cells of a very long notebook are drawn.")
            let rest = String(localized: "The rest of the notebook is in Source.", bundle: .previewKit,
                              comment: "Notebook notice: where the cells not drawn can be read. 'Source' is the viewer switch's Source view.")
            html += "<div class=\"ginset bad\" role=\"status\"><div class=\"gr\"><div class=\"gk\"><div><b>\(NotebookHTML.escape(shown))</b></div>"
            html += "<div class=\"gsub\">\(NotebookHTML.escape(rest))</div></div></div></div>"
        }
        html += "</header><div class=\"hbody plain\" id=\"cells\">"
        for (i, cell) in nb.cells.enumerated() {
            if let marimo, i < marimo.cells.count { html += marimoNote(marimo.cells[i]) }
            html += cellHTML(cell, index: i, language: language, stale: order.stale.contains(i), limits: limits, runCounter: marimo == nil)
        }
        if nb.cells.isEmpty {
            html += "<p class=\"nbempty\">\(NotebookHTML.escape(String(localized: "This notebook has no cells.", bundle: .previewKit, comment: "An empty notebook.")))</p>"
        }
        html += "</div>"

        // The document: pill facts, the badge, the switch (Notebook / Code only / Source).
        let cellsLabel = String(localized: "Cells", bundle: .previewKit, comment: "Notebook fact label: the cells and their kinds.")
        var facts: [Fact] = [Fact(key: "headline",
                                  label: order.first == nil ? cellsLabel
                                    : String(localized: "Run order", bundle: .previewKit, comment: "Notebook fact label: whether the cells ran in order."),
                                  value: order.first == nil ? cellCount(nb.totalCells) : outOfOrder)]
        facts.append(DocumentFacts.size(fileSize))
        let readable = readableText(nb.cells)
        facts.append(DocumentFacts.tokens(bytes: readable.utf8.count))
        if let languageLabel {
            facts.append(Fact(key: "language", label: String(localized: "Language", bundle: .previewKit, comment: "Notebook fact label: the programming language."),
                              value: languageLabel))
        }
        for (key, label, value) in kv { facts.append(Fact(key: key, label: label, value: value)) }
        facts.append(Fact(key: "cells", label: cellsLabel,
                          value: kindParts.isEmpty ? String(localized: "none", bundle: .previewKit, comment: "Notebook cells fact: there are no cells.") : kinds))
        facts.append(Fact(key: "outputs", label: String(localized: "Outputs", bundle: .previewKit, comment: "Notebook fact label: the cell outputs."),
                          value: ([outputCount] + notable).formatted(.list(type: .and, width: .narrow))))
        var badges: [Badge] = []
        if let first = order.first {
            badges.append(Badge(level: .caution, title: outOfOrder, detail: outOfOrderSentence(first)))
        }
        let codeOnly = nb.cells.filter { $0.kind == .code }.map { c in
            (marimo == nil ? "# %% [\(c.executionCount.map(String.init) ?? " ")]\n" : "# %% \(c.id ?? "")\n") + c.source
        }.joined(separator: "\n\n")
        var document = PreviewDocument(kind: .code(language: marimo == nil ? "ipynb" : "marimo"),
                                       dialect: marimo.map { "marimo-\($0.version ?? "unknown")" } ?? "jupyter-nbformat-\(nb.format ?? "4")",
                                       facts: facts, badges: badges,
                                       views: [.text(readable), .code(codeOnly, language: language ?? "plaintext"),
                                               marimo == nil ? .text(source) : .code(source, language: "python")],
                                       coverage: nb.cut ? .partial(shown: Int64(nb.cells.count), total: Int64(nb.totalCells), unit: .rows,
                                                                    reason: String(localized: "the first \(nb.cells.count) cells are drawn", bundle: .previewKit,
                                                                                   comment: "Why a long notebook is shown in part.")) : .complete)
        // The views' titles are identifiers the viewer switch shows in the person's language (CapsuleView).
        document.viewTitles = ["Notebook", "Code only", "Source"]
        // A-4: the readable text's estimate, kept in the `tokens` fact's place, for the Details meter.
        document.setTokens(TokenCounting.count(.text(readable)))
        return NotebookPage(body: html, document: document, language: language)
    }

    /// Above a marimo cell: its name when the author gave one, and that its code is hidden when the notebook runs as
    /// an app.
    static func marimoNote(_ cell: MarimoReader.Cell) -> String {
        var parts: [String] = []
        if cell.isNamed { parts.append(cell.name) }
        if cell.hideCode {
            parts.append(String(localized: "code hidden in the app", bundle: .previewKit,
                                comment: "Above a marimo cell: hide_code=True, so the code is hidden when the notebook runs as an app."))
        }
        return parts.isEmpty ? "" : note(parts.joined(separator: " · "))
    }

    /// "14 cells".
    static func cellCount(_ n: Int) -> String {
        String(localized: "\(n) cells", bundle: .previewKit, comment: "How many cells a notebook holds.")
    }

    /// "Cell [7] ran after cell [4] below it; the outputs may not match the code above them."
    static func outOfOrderSentence(_ first: (above: Int, below: Int)) -> String {
        // Execution counts are shown as Jupyter writes them, plain digits in brackets.
        String(localized: "Cell [\(String(first.above))] ran after cell [\(String(first.below))] below it; the outputs may not match the code above them.",
               bundle: .previewKit, comment: "Notebook warning detail; the arguments are Jupyter execution counts.")
    }

    // MARK: Cells

    /// `runCounter: false` for a marimo notebook, which never stores runs, so a code cell shows no `[ ]`.
    static func cellHTML(_ cell: NotebookReader.Cell, index: Int, language: String?, stale: Bool, limits: Limits,
                         runCounter: Bool = true) -> String {
        switch cell.kind {
        case .markdown:
            var options = MarkdownHTML.Options()
            options.hideFrontMatter = false   // a cell that starts with --- is a rule, not front matter
            let rendered = withAttachments(MarkdownHTML.render(cell.source, options: options), cell.attachments)
            return "<div class=\"nbc md cards\" id=\"cell-\(index + 1)\"><div class=\"nbg\"></div><div class=\"nbb nbmd\">\(rendered)</div></div>"
        case .raw:
            return "<div class=\"nbc raw cards\" id=\"cell-\(index + 1)\"><div class=\"nbg\"></div><div class=\"nbb\"><pre class=\"nbraw\">\(NotebookHTML.escape(cell.source))</pre></div></div>"
        case .code:
            let failed = cell.outputs.contains { $0.type == .error }
            let prompt = runCounter ? "[\(cell.executionCount.map(String.init) ?? " ")]" : ""
            var html = "<div class=\"nbc cards\(failed ? " bad" : "")\" id=\"cell-\(index + 1)\">"
            let staleTitle = NotebookHTML.escape(String(localized: "Ran after a cell below it", bundle: .previewKit,
                                                        comment: "Tooltip of a notebook cell's prompt when it ran out of order."))
            html += "<div class=\"nbg\(stale ? " stale" : "")\"\(stale ? " title=\"\(staleTitle)\"" : "")>\(prompt)</div><div class=\"nbb\">"
            let lang = language.map { " class=\"language-\(NotebookHTML.escape($0))\"" } ?? ""
            html += "<div class=\"nbsrc\"><div class=\"cb\"><pre><code\(lang)>\(NotebookHTML.escape(cell.source))</code></pre></div>"
            if failed {
                let word = String(localized: "error", bundle: .previewKit, comment: "Status beside a notebook cell whose run failed (lower case).")
                html += "<span class=\"nbst err\">\(Icon.cross) \(NotebookHTML.escape(word))</span>"
            } else if let seconds = cell.duration {
                let ran = String(localized: "Ran in \(duration(seconds))", bundle: .previewKit,
                                 comment: "Tooltip of a notebook cell's run time; the argument is a duration such as '0.4 s'.")
                html += "<span class=\"nbst ok\" title=\"\(NotebookHTML.escape(ran))\">\(Icon.check) \(NotebookHTML.escape(duration(seconds)))</span>"
            }
            html += "</div>"
            let outs = mergedStreams(cell.outputs)
            if !outs.isEmpty {
                html += "<div class=\"nbout\">" + outs.map { outputHTML($0, limits: limits) }.joined() + "</div>"
            }
            return html + "</div></div>"
        }
    }

    /// Consecutive stream outputs of one stream read as one block, as Jupyter shows them.
    static func mergedStreams(_ outputs: [NotebookReader.Output]) -> [NotebookReader.Output] {
        var out: [NotebookReader.Output] = []
        for o in outputs {
            if o.type == .stream, let last = out.last, last.type == .stream, last.mime == o.mime {
                out[out.count - 1].text += o.text
            } else {
                out.append(o)
            }
        }
        return out
    }

    static func outputHTML(_ o: NotebookReader.Output, limits: Limits) -> String {
        switch o.type {
        case .stream:
            return "<pre class=\"nbtext\(o.mime == "stderr" ? " stderr" : "")\">\(cut(NotebookHTML.terminalText(o.text), limits))</pre>"
        case .error:
            let name = o.errorName ?? o.mime ?? errorWord, value = NotebookHTML.terminalText(o.errorValue ?? "")
            var trace = (o.traceback.isEmpty ? [] : NotebookHTML.terminalText(o.traceback.joined(separator: "\n")).components(separatedBy: "\n"))
                .filter { line in !line.allSatisfy { $0 == "-" || $0 == " " } || line.isEmpty }
            // IPython ends the traceback with the "Name: value" line the header already shows.
            while let last = trace.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.hasPrefix(name + ":") || last == name { trace.removeLast() }
            while let firstLine = trace.first, firstLine.trimmingCharacters(in: .whitespaces).isEmpty { trace.removeFirst() }
            var html = "<div class=\"nberr\"><b>\(NotebookHTML.escape(name))</b>" + (value.isEmpty ? "" : ": " + NotebookHTML.escape(value))
            if !trace.isEmpty { html += "<pre class=\"nbtb t2\">\(cut(trace.joined(separator: "\n"), limits))</pre>" }
            return html + "</div>"
        case .image:
            return imageHTML(mime: o.mime ?? "", base64: o.text, alt: o.bundle["text/plain"], limits: limits)
        case .html:
            let clean = NotebookHTML.sanitize(o.text)
            if NotebookHTML.hasVisibleContent(clean) { return "<div class=\"nbhtml\">\(clean)</div>" }
            if let plain = o.bundle["text/plain"] { return "<pre class=\"nbtext\">\(cut(NotebookHTML.terminalText(plain), limits))</pre>" }
            return note(String(localized: "Interactive output: its scripts are not run in a preview.", bundle: .previewKit,
                               comment: "In place of a notebook's interactive HTML output."))
        case .text, .other:
            if let md = o.bundle["text/markdown"] {
                var options = MarkdownHTML.Options()
                options.hideFrontMatter = false
                return "<div class=\"nbmd\">\(MarkdownHTML.render(md, options: options))</div>"
            }
            if let latex = o.bundle["text/latex"] {
                let tex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^\$\$?|\$\$?$"#, with: "", options: .regularExpression)
                return "<div class=\"math math-display\">\(NotebookHTML.escape(tex))</div>"
            }
            if let plain = o.bundle["text/plain"] ?? (o.type == .text ? o.text : nil) {
                return "<pre class=\"nbtext\">\(cut(NotebookHTML.terminalText(plain), limits))</pre>"
            }
            if let json = o.bundle.first(where: { $0.key.hasSuffix("json") })?.value {
                return "<pre class=\"nbtext\">\(cut(json, limits))</pre>"
            }
            return o.mime.map {
                note(String(localized: "\($0) output, not shown in a preview.", bundle: .previewKit,
                            comment: "In place of a notebook output Vitrine does not draw; the argument is its MIME type."))
            } ?? ""
        }
    }

    /// A quiet note in place of an output, escaped.
    static func note(_ text: String) -> String { "<p class=\"nbnote\">\(NotebookHTML.escape(text))</p>" }

    /// The name of an error output that names none.
    static var errorWord: String { String(localized: "Error", bundle: .previewKit, comment: "Name of a notebook error output that gives no name.") }

    /// An image output, decoded from the notebook's own base64 and re-encoded, so only bytes that really are that kind
    /// of image reach the page, and only as a `data:` URL (nothing is fetched).
    static func imageHTML(mime: String, base64: String, alt: String?, limits: Limits) -> String {
        guard base64.utf8.count <= limits.maxImageBase64 else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(base64.utf8.count * 3 / 4), countStyle: .file)
            return note(String(localized: "\(mime) · \(size), too large to draw in a preview.", bundle: .previewKit,
                               comment: "In place of a very large notebook image; the arguments are its MIME type and size."))
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), looksLike(mime, data) else {
            return note(String(localized: "An \(mime) output that could not be read.", bundle: .previewKit,
                               comment: "In place of a notebook image that does not decode; the argument is its MIME type."))
        }
        let altText = NotebookHTML.escape(alt.map { String($0.prefix(200)) }
            ?? String(localized: "Output image", bundle: .previewKit, comment: "Alt text of a notebook image output that has none."))
        return "<img class=\"nbimg\" alt=\"\(altText)\" src=\"data:\(mime);base64,\(data.base64EncodedString())\">"
    }

    static func looksLike(_ mime: String, _ data: Data) -> Bool {
        let b = [UInt8](data.prefix(12))
        func starts(_ m: [UInt8]) -> Bool { b.count >= m.count && Array(b.prefix(m.count)) == m }
        switch mime {
        case "image/png": return starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/jpeg": return starts([0xFF, 0xD8, 0xFF])
        case "image/gif": return starts(Array("GIF8".utf8))
        case "image/webp": return starts(Array("RIFF".utf8)) && b.count >= 12 && Array(b[8..<12]) == Array("WEBP".utf8)
        // WebKit draws an <img> SVG as a picture: its scripts never run and nothing it names is loaded (G-12).
        case "image/svg+xml": return String(decoding: data.prefix(4096), as: UTF8.self).contains("<svg")
        default: return false
        }
    }

    /// `![chart](attachment:chart.png)` in a Markdown cell points at an image the cell carries.
    static func withAttachments(_ html: String, _ attachments: [String: NotebookReader.Attachment]) -> String {
        guard html.contains("attachment:") else { return html }
        var out = html
        for (name, a) in attachments {
            guard let data = Data(base64Encoded: a.base64, options: .ignoreUnknownCharacters), looksLike(a.mime, data) else { continue }
            let escaped = NotebookHTML.escape(name)
            for form in [escaped, escaped.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? escaped] {
                out = out.replacingOccurrences(of: "src=\"attachment:\(form)\"", with: "src=\"data:\(a.mime);base64,\(data.base64EncodedString())\"")
            }
        }
        return out
    }

    // MARK: Text

    static func cut(_ text: String, _ limits: Limits) -> String {
        guard text.count > limits.maxOutputCharacters else { return NotebookHTML.escape(text) }
        let rest = text.count - limits.maxOutputCharacters
        return NotebookHTML.escape(String(text.prefix(limits.maxOutputCharacters)))
            + "\n<span class=\"nbcut\">\(NotebookHTML.escape(String(localized: "… \(rest) more characters (the whole output is in Source)", bundle: .previewKit, comment: "After a cut notebook output: how many characters are not shown and where to read them.")))</span>"
    }

    /// The notebook as a reader would copy it: Markdown and code sources, then their text outputs.
    static func readableText(_ cells: [NotebookReader.Cell]) -> String {
        cells.map { c in
            var parts = [c.source]
            for o in mergedStreams(c.outputs) {
                switch o.type {
                case .stream: parts.append(NotebookHTML.terminalText(o.text))
                case .error: parts.append([o.errorName ?? errorWord, o.errorValue ?? ""].filter { !$0.isEmpty }.joined(separator: ": "))
                case .text, .html, .other, .image: if let plain = o.bundle["text/plain"] { parts.append(plain) }
                }
            }
            return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func firstHeading(_ cells: [NotebookReader.Cell]) -> String? {
        for cell in cells where cell.kind == .markdown {
            for line in cell.source.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("#") else { continue }
                let heading = t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty, t.prefix(while: { $0 == "#" }).count <= 6 { return heading }
            }
        }
        return nil
    }

    /// Shiki's id for the notebook's language: language_info's name, else the kernel's name read as one.
    static func shikiLanguage(_ nb: NotebookReader.Notebook) -> String? {
        if let l = nb.language?.lowercased(), !l.isEmpty { return l == "ir" ? "r" : l }
        guard let kernel = nb.kernelName?.lowercased() else { return nil }
        for (prefix, id) in [("python", "python"), ("ir", "r"), ("julia", "julia"), ("scala", "scala"), ("javascript", "javascript"),
                             ("typescript", "typescript"), ("bash", "shellscript"), ("rust", "rust"), ("go", "go")] where kernel.hasPrefix(prefix) {
            return id
        }
        return nil
    }

    static func majorMinor(_ version: String) -> String {
        let parts = version.split(separator: ".")
        return parts.count >= 2 ? "\(parts[0]).\(parts[1])" : version
    }

    /// "< 0.1 s", "0.4 s", "12 s", "4 min 12 s", "1 h 4 min".
    static func duration(_ s: Double) -> String {
        if s < 0.05 {
            return String(localized: "< \(0.1, format: .number.precision(.fractionLength(1))) s", bundle: .previewKit,
                          comment: "A notebook cell's run time under a tenth of a second.")
        }
        if s < 10 {
            return String(localized: "\(s, format: .number.precision(.fractionLength(1))) s", bundle: .previewKit,
                          comment: "A notebook cell's run time in seconds, one decimal.")
        }
        if s < 60 {
            return String(localized: "\(Int(s.rounded())) s", bundle: .previewKit, comment: "A notebook cell's run time in whole seconds.")
        }
        let total = Int(s.rounded())
        if total < 3600 {
            return total % 60 == 0
                ? String(localized: "\(total / 60) min", bundle: .previewKit, comment: "A run time in whole minutes.")
                : String(localized: "\(total / 60) min \(total % 60) s", bundle: .previewKit, comment: "A run time in minutes and seconds.")
        }
        return String(localized: "\(total / 3600) h \((total % 3600) / 60) min", bundle: .previewKit, comment: "A run time in hours and minutes.")
    }

    /// The span of the recorded runs: "12 Oct 2026, 14:05 → 14:19" (the end's date is added when it differs).
    static func runSpan(_ cells: [NotebookReader.Cell]) -> String? {
        guard let start = cells.compactMap(\.started).min(), let end = cells.compactMap(\.finished).max(), end >= start else { return nil }
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        let from = start.formatted(date: .abbreviated, time: .shortened)
        let to = sameDay ? end.formatted(date: .omitted, time: .shortened) : end.formatted(date: .abbreviated, time: .shortened)
        return sameDay && start.formatted(date: .omitted, time: .shortened) == to ? from : from + " → " + to
    }

    /// The design's line icons (ai.html state 11), drawn as inline SVG in the page's own markup.
    enum Icon {
        static let notebook = #"<svg width="18" height="18" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.4 3c2-.8 3.9-.8 5.6.6v10c-1.7-1.4-3.6-1.4-5.6-.6zM13.6 3c-2-.8-3.9-.8-5.6.6v10c1.7-1.4 3.6-1.4 5.6-.6z"/></svg>"#
        static let caution = #"<svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2 14.6 13.6H1.4z"/><path d="M8 6.4v3.2M8 11.6v.2"/></svg>"#
        static let check = #"<svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m3.2 8.4 3 3 6.6-6.8"/></svg>"#
        static let cross = #"<svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m4 4 8 8M12 4l-8 8"/></svg>"#
    }
}
