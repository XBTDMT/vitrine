import AppKit
import VitrineHelperKit
import VitrineDocument
import WebKit
import VitrineSupport

/// What the code view's Copy-as menu offers (code state 2; I-2, I-11, I-10): the selected lines (or the file), the
/// same as a prompt with the path and line numbers and its rough token count, an image of them, opening the file at
/// the first line in a code editor that takes a line in its link, and Reveal in Finder. roadmap: S-5
enum CodeCopy {
    /// The text a selection covers: lines `from`…`to` (file numbering) of `text`, whose first line is `first`.
    static func lines(_ text: String, first: Int, from: Int, to: Int) -> [Substring] {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        let a = max(0, from - first), b = min(all.count - 1, to - first)
        guard a <= b else { return [] }
        return Array(all[a...b])
    }

    /// The Copy-as menu's heading when there is nothing to offer.
    static var copyAsHeading: String {
        String(localized: "Copy as", bundle: .previewKit, comment: "Heading of the Copy as menu.")
    }

    /// The prompt form: where the lines come from, then the lines numbered as in the file, fenced in their language.
    /// Text for a language model, kept in one fixed form (not localized), like the code fence around it.
    static func prompt(path: String, language: String, from: Int, lines: [Substring], whole: Bool) -> String {
        let to = from + lines.count - 1
        let width = String(to).count
        let numbered = lines.enumerated().map { i, l in
            String(repeating: " ", count: width - String(from + i).count) + "\(from + i)  " + l
        }.joined(separator: "\n")
        let place = whole ? "\(path) (\(lines.count.formatted()) lines)" : "\(path), lines \(from)–\(to)"
        let fence = numbered.contains("```") ? "````" : "```"
        return "\(place):\n\n\(fence)\(language == "plaintext" ? "" : language)\n\(numbered)\n\(fence)\n"
    }

    /// About four bytes a token, as the pill's token fact counts.
    static func tokens(_ text: String) -> Int { max(1, (text.utf8.count + 2) / 4) }

    /// Code editors whose links open a file at a line; only those installed are offered.
    private static func encode(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }
}

extension CodeRenderer {
    /// The Copy-as menu for the current selection (or the whole file when nothing is selected).
    func copyOffer() -> (heading: String, formats: [CopyFormat]) {
        guard let url = fileURL else { return (CodeCopy.copyAsHeading, []) }
        let language = fileLanguage
        let shown = shownText
        let selection = selectedLines
        let from = selection?.from ?? shown.first
        let lines = selection.map { CodeCopy.lines(shown.text, first: shown.first, from: $0.from, to: $0.to) }
            ?? shown.text.split(separator: "\n", omittingEmptySubsequences: false)
        let text = lines.joined(separator: "\n")
        let prompt = CodeCopy.prompt(path: url.path, language: language, from: from, lines: lines, whole: selection == nil)
        let heading = selection.map {
            $0.from == $0.to
                ? String(localized: "Line \($0.from)", bundle: .previewKit, comment: "Copy as menu heading: the one selected line.")
                : String(localized: "Lines \($0.from)–\($0.to)", bundle: .previewKit, comment: "Copy as menu heading: the selected lines.")
        } ?? String(localized: "Copy file as", bundle: .previewKit, comment: "Copy as menu heading when nothing is selected.")
        var formats = [
            CopyFormat(title: selection == nil
                       ? String(localized: "Text", bundle: .previewKit, comment: "Copy as menu item: the file's text.")
                       : String(localized: "Copy lines", bundle: .previewKit, comment: "Copy as menu item: the selected lines.")) { text },
            CopyFormat(title: String(localized: "Copy as prompt, with path and line numbers · ≈ \(CodeCopy.tokens(prompt)) tokens", bundle: .previewKit,
                                     comment: "Copy as menu item: the lines with the file path and line numbers, for a language model; then the approximate token count.")) { prompt },
            {
                var image = CopyFormat(title: String(localized: "Copy as image", bundle: .previewKit, comment: "Copy as menu item: a picture of the lines.")) { [weak self] pasteboard in
                    await self?.copyImage(to: pasteboard) ?? false
                }
                image.isImage = true
                return image
            }(),
        ]
        // Through VitrineHelper (X-3, G-31): a sandboxed extension cannot open an editor or Finder itself.
        for editor in installedEditors {
            formats.append(CopyFormat(title: String(localized: "Open at line \(from) in \(editor.displayName)", bundle: .previewKit,
                                                    comment: "Copy as menu item: opens the file at the line in a code editor; the second argument is the editor's name.")) { [weak self] _ in
                let error = await HelperClient.open(url, atLine: from, in: editor)
                self?.reportAction(error)
                return false
            })
        }
        formats.append(CopyFormat(title: String(localized: "Reveal in Finder", bundle: .previewKit, comment: "Copy as menu item: shows the file in Finder.")) { [weak self] _ in
            self?.reportAction(await HelperClient.reveal(url))
            return false
        })
        return (heading, formats)
    }

    /// The page's selection rectangle, checked (finite numbers, through PageNumbers) and held inside the web view:
    /// a page could otherwise ask for an infinite or enormous snapshot (S-16). nil means "what is in view".
    static func snapshotRect(_ r: [String: Any], bounds: CGRect) -> CGRect? {
        let span = -PageNumbers.maxPoints...PageNumbers.maxPoints
        guard let x = PageNumbers.number(r["x"], in: span), let y = PageNumbers.number(r["y"], in: span),
              let w = PageNumbers.number(r["w"], in: 0...PageNumbers.maxPoints), let h = PageNumbers.number(r["h"], in: 0...PageNumbers.maxPoints),
              w > 0, h > 0 else { return nil }
        let clip = CGRect(x: x, y: y, width: w, height: h).intersection(CGRect(origin: .zero, size: bounds.size))
        return clip.isNull || clip.isEmpty ? nil : clip
    }

    /// A picture of the selected lines as they are drawn (theme and all), or of what is in view.
    func copyImage(to pasteboard: NSPasteboard) async -> Bool {
        guard let web = webView else { return false }
        let rect = try? await web.callAsyncJavaScript("return window.vitrine.selectionRect();", contentWorld: .page) as? [String: Any]
        let config = WKSnapshotConfiguration()
        if let r = rect, let clip = Self.snapshotRect(r, bounds: web.bounds) { config.rect = clip }
        guard let image = try? await web.takeSnapshot(configuration: config) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }
}
