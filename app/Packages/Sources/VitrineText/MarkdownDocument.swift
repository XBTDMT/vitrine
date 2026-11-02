import Foundation
import VitrineDocument
import VitrineSupport

/// Parses a Markdown file into the document model: the rendered body with its outline first, the source second,
/// and the facts the metadata strip shows.
public enum MarkdownDocument {
    /// `mask` replaces secret values before anything draws them (T-4, G-23: the previews pass the trust lens's masker).
    public static func make(url: URL, kind: FileKind, options: MarkdownHTML.Options,
                            mask: (@Sendable (String) -> String)? = nil) throws -> PreviewDocument {
        guard let data = try? Data(contentsOf: url) else { throw DocumentError.unreadable(url) }
        // UTF-8 first; Latin-1 decodes any bytes, so a mis-encoded file still previews.
        let utf8 = String(data: data, encoding: .utf8)
        let read = utf8 ?? String(data: data, encoding: .isoLatin1) ?? ""
        let source = mask?(read) ?? read
        // MDX, MDC, Quarto, R Markdown, reStructuredText, AsciiDoc and Org become the Markdown the pipeline draws (M-11).
        let markdown = { if case .markdown(let dialect) = kind { return MarkdownDialects.prepare(source, dialect: dialect) } else { return source } }()
        let html = MarkdownHTML.addHeadingIDs(MarkdownHTML.render(markdown, options: options))
        let headings = MarkdownHTML.headings(in: html).map { MarkdownContent.Heading(level: $0.level, text: $0.text, id: $0.id) }
        let words = wordCount(html: html)
        let refs = references(in: html, folder: url.deletingLastPathComponent())
        var document = PreviewDocument(
            kind: kind,
            facts: [Fact(key: "words", label: String(localized: "Words", bundle: .module, comment: "Fact label for a Markdown document. The number of words."), value: words.formatted()),
                    Fact(key: "readingTime", label: String(localized: "Reading time", bundle: .module, comment: "Fact label for a Markdown document. About how long the text takes to read."), value: DocumentFacts.readingTime(words: words)),
                    DocumentFacts.size(Int64(data.count)),
                    Fact(key: "encoding", label: String(localized: "Encoding", bundle: .module, comment: "Fact label: the text encoding."), value: utf8 == nil ? "Latin-1" : "UTF-8"),
                    Fact(key: "images", label: String(localized: "Images", bundle: .module, comment: "Fact label for a Markdown document."), value: refs.images.formatted()),
                    Fact(key: "remoteImages", label: String(localized: "Remote images", bundle: .module, comment: "Fact label for a Markdown document. Images loaded from the web."), value: refs.remoteImages.formatted()),
                    Fact(key: "links", label: String(localized: "Links", bundle: .module, comment: "Fact label for a Markdown document."), value: refs.links.formatted()),
                    Fact(key: "missingLinks", label: String(localized: "Missing links", bundle: .module, comment: "Fact label for a Markdown document. Links to files beside the document that do not exist."), value: refs.missingLinks.formatted())],
            views: [.markdown(MarkdownContent(html: html, headings: headings)), .text(source)])
        // A-4: the count the pill, the column and the context-fit meter read (the `tokens` fact comes last, as before).
        document.setTokens(TokenCounting.count(.byteCount(data.count)))
        return document
    }

    struct References: Equatable { var images = 0, remoteImages = 0, links = 0, missingLinks = 0 }

    /// Images and links in the rendered page. A link is missing when it points at a file beside the document
    /// (no scheme, not an in-page anchor) and no file is there; web and mail links are counted, never checked.
    static func references(in html: String, folder: URL) -> References {
        var r = References()
        for src in attributes("img", "src", in: html) {
            r.images += 1
            if src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("//") { r.remoteImages += 1 }
        }
        for href in attributes("a", "href", in: html) where !href.hasPrefix("#") {
            r.links += 1
            guard !href.contains(":"), !href.hasPrefix("//") else { continue }
            let path = String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
            guard !path.isEmpty else { continue }
            let decoded = path.removingPercentEncoding ?? path
            let target = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : folder.appendingPathComponent(decoded)
            if !FileManager.default.fileExists(atPath: target.path) { r.missingLinks += 1 }
        }
        return r
    }

    private static func attributes(_ tag: String, _ attribute: String, in html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)\\b[^>]*\\s\(attribute)=\"([^\"]*)\"", options: [.caseInsensitive]) else { return [] }
        return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { MermaidBlocks.unescape(String(html[$0])) }
        }
    }

    /// Words a reader sees: the rendered text without tags or Markdown symbols, counting runs that hold a letter
    /// or a digit, so `#`, `-` and `|` are not words.
    static func wordCount(html: String) -> Int {
        let text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return text.split { $0.isWhitespace }.filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }
}
