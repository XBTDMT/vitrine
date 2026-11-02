import Foundation
import VitrineDocument
import VitrineUI

/// The picked Markdown design's column (r3-a Clear Sidebar, design/mockups/unified/markdown.html): the contents at
/// its head and the document's facts at its foot, drawn from the `PreviewDocument`. It steps aside on short notes
/// (fewer than three headings) and, through the page's CSS, in narrow panels. roadmap: S-4
enum MarkdownColumn {
    static func html(for content: MarkdownContent, facts document: PreviewDocument) -> String {
        let items = content.headings.map { h in
            "<li class=\"l\(min(h.level, 3))\"><a href=\"#\(h.id)\"><span>\(h.text)</span></a></li>"
        }.joined()
        let esc = NotebookHTML.escape
        let aside = esc(String(localized: "Contents and facts", bundle: .previewKit, comment: "Accessibility label of a Markdown page's side column."))
        let contents = esc(String(localized: "Contents", bundle: .previewKit, comment: "Heading of a Markdown page's table of contents."))
        let aa = esc(String(localized: "Theme and text size", bundle: .previewKit, comment: "The Aa popover of a Markdown page."))
        return """
        <aside class="sa-side" aria-label="\(aside)"><div class="sa-top"><span class="sa-h">\(contents)</span><span style="flex:1"></span>\
        <button class="ib" id="vt-aa" title="\(aa)" aria-label="\(aa)" aria-haspopup="dialog">\(Icon.aa)</button></div>\
        <ul class="toc">\(items)</ul><div class="sa-foot">\(factRows(document))</div><div class="sa-edge" aria-hidden="true"></div></aside>
        """
    }

    /// The column's foot: each row one whole localized phrase (H-6); the counts come back from the facts as numbers.
    static func factRows(_ d: PreviewDocument) -> String {
        let esc = NotebookHTML.escape
        func v(_ key: String) -> String? { d.fact(key)?.value }
        func n(_ key: String) -> Int { Int(v(key)?.filter(\.isNumber) ?? "") ?? 0 }
        var rows: [(String, String)] = []
        if let words = v("words"), let time = v("readingTime") {
            rows.append((Icon.lines, esc(String(localized: "\(words) words · \(time)", bundle: .previewKit,
                                                comment: "Markdown column: the word count (formatted) and the reading time."))))
        }
        if let size = v("size") { rows.append((Icon.ruler, esc([size, v("encoding")].compactMap { $0 }.joined(separator: " · ")))) }
        if n("images") > 0 {
            let images = n("images"), remote = n("remoteImages")
            rows.append((Icon.image, esc(remote > 0
                ? String(localized: "\(images) images · \(remote) remote", bundle: .previewKit,
                         comment: "Markdown column: how many images, then how many of them are on the web.")
                : String(localized: "\(images) images", bundle: .previewKit, comment: "Markdown column: how many images the file shows."))))
        }
        if n("links") > 0 {
            let links = n("links"), missing = n("missingLinks")
            let linkText = esc(String(localized: "\(links) links", bundle: .previewKit, comment: "Markdown column: how many links the file has."))
            if missing > 0 {
                let missingText = esc(String(localized: "\(missing) missing", bundle: .previewKit,
                                             comment: "Markdown column, after the link count: how many local links point nowhere."))
                rows.append((Icon.link, "\(linkText) · <b class=\"sa-w\">\(missingText)</b>"))
            } else {
                rows.append((Icon.link, linkText))
            }
        }
        let meter = d.tokenMeter
        if meter == nil, let tokens = v("tokens") {
            rows.append((Icon.tokens, esc(String(localized: "\(tokens) tokens", bundle: .previewKit,
                                                 comment: "Markdown column: the approximate token count, formatted ('≈ 3,201')."))))
        }
        return rows.map { "<div class=\"sa-f\">\($0.0)<span>\($0.1)</span></div>" }.joined() + (meter.map(meterRows) ?? "")
    }

    /// The context-fit meter (A-4) at the column's foot, from the same `TokenMeter` the Details inspector draws: the
    /// count with its label, a small bar per window (caution when the file does not fit), and the method on hover.
    static func meterRows(_ meter: TokenMeter) -> String {
        let esc = NotebookHTML.escape
        var h = "<div class=\"sa-tok\" role=\"group\" aria-label=\"\(esc(meter.accessibilityLabel))\" title=\"\(esc(meter.method))\">"
        h += "<div class=\"sa-f sa-th\">\(Icon.tokens)<span><b class=\"sa-n\">\(esc(meter.number))</b> \(esc(meter.unit))</span></div>"
        for row in meter.rows {
            // A share too small to see still shows a sliver, as the native bar does; the column's narrow rows use the
            // compact words, the full sentence on hover.
            let percent = row.fill <= 0 ? 0 : max(5, row.fill * 100)
            let width = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), min(100, percent))
            h += "<div class=\"sa-f sa-m\(row.fits ? "" : " over")\" title=\"\(esc(row.text))\"><span class=\"vt-meter\" aria-hidden=\"true\"><i style=\"width:\(width)%\"></i></span>"
                + "<span>\(esc(row.compactText))</span></div>"
        }
        // G-29: the exact OpenAI count arrives after the page loads (MarkdownRenderer.fillExactTokens), as text.
        return h + "<div class=\"sa-f sa-mm\"><span>\(esc(meter.method))</span></div><div class=\"sa-f sa-mm\" id=\"vt-exact\" hidden></div></div>"
    }

    /// The data "Aa" draws its theme tiles from: every theme's ground, text, accent and heading type in the current
    /// appearance, plus the current theme and text scale. A JSON data block, never executed (the page CSP allows
    /// no inline script).
    static func themeData(current: String, scale: Double, appearance: DesignTokens.Appearance) -> String {
        struct Tile: Encodable { let id, name, bg, fg, fg2, acc, hfont: String; let hw: Int }
        struct Data: Encodable { let current: String; let scale: Double; let scales: [Double]; let themes: [Tile] }
        let tiles = MarkdownTheme.builtIn.map { t -> Tile in
            let c = t.spec.colors(for: appearance)
            return Tile(id: t.id, name: t.name, bg: c.bg, fg: c.fg, fg2: c.fg2, acc: c.acc, hfont: t.spec.headingFont, hw: t.spec.headingWeight)
        }
        let json = (try? JSONEncoder().encode(Data(current: current, scale: scale, scales: MarkdownTheme.textScales, themes: tiles)))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // `</` cannot end the block early.
        return "<script type=\"application/json\" id=\"vt-themes\">\(json.replacingOccurrences(of: "</", with: "<\\/"))</script>"
    }

    /// The design's 12 pt fact icons (Vitrine's own drawings).
    enum Icon {
        private static func svg(_ body: String) -> String {
            "<svg class=\"pi\" width=\"12\" height=\"12\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.35\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\">\(body)</svg>"
        }
        static let aa = "<svg class=\"pi\" width=\"15\" height=\"15\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.35\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><path d=\"M1.8 12.5 5 3.6l3.2 8.9M2.9 9.6h4.2\"/><path d=\"M13.6 12.5V9.4a1.9 1.9 0 0 0-3.4-1.1M13.6 10.6c-2.4-.3-3.8.3-3.8 1.2s.8 1.2 1.6 1c1.2-.2 2.2-1.1 2.2-2.2\"/></svg>"
        static let lines = svg("<path d=\"M5.5 4.5h8M5.5 8h8M5.5 11.5h8M2.4 4.5h.8M2.4 8h.8M2.4 11.5h.8\"/>")
        static let ruler = svg("<rect x=\"1.8\" y=\"5.2\" width=\"12.4\" height=\"5.6\" rx=\"1\"/><path d=\"M4.4 5.2v2M7 5.2v2.8M9.6 5.2v2M12.2 5.2v2.8\"/>")
        static let image = svg("<rect x=\"2\" y=\"3\" width=\"12\" height=\"10\" rx=\"1.8\"/><circle cx=\"5.6\" cy=\"6.4\" r=\"1.1\"/><path d=\"M2.4 11.8 6 8.4l2.6 2.5 1.9-1.8 3.1 2.8\"/>")
        static let link = svg("<path d=\"M6.8 9.2a2.8 2.8 0 0 0 4 0l2-2a2.8 2.8 0 0 0-4-4l-.9.9M9.2 6.8a2.8 2.8 0 0 0-4 0l-2 2a2.8 2.8 0 0 0 4 4l.9-.9\"/>")
        static let tokens = svg("<path d=\"M5.6 5.6h4.8v4.8H5.6zM5.6 5.6V4.2a1.6 1.6 0 1 0-1.6 1.4h1.6M10.4 5.6V4.2A1.6 1.6 0 1 1 12 5.6h-1.6M10.4 10.4v1.4a1.6 1.6 0 1 0 1.6-1.4h-1.6M5.6 10.4v1.4A1.6 1.6 0 1 1 4 10.4h1.6\"/>")
    }
}
