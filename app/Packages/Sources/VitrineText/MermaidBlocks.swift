import CryptoKit
import Foundation

/// The Mermaid diagrams in rendered Markdown HTML (cmark writes a ```mermaid fence as
/// `<pre><code class="language-mermaid">…</code></pre>`), and the one rewrite the SVG cache needs (G-2 route C):
/// a diagram already drawn for the same source, theme, appearance and mermaid version is put in place as its SVG;
/// any other keeps its code block, tagged with its cache key so the page can hand the drawing back.
public enum MermaidBlocks {
    public struct Block: Sendable, Equatable {
        public let source: String
        public let range: Range<String.Index>
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"<pre><code class="language-mermaid">(.*?)</code></pre>"#, options: [.dotMatchesLineSeparators])

    public static func find(in html: String) -> [Block] {
        pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { m in
            guard let whole = Range(m.range, in: html), let inner = Range(m.range(at: 1), in: html) else { return nil }
            return Block(source: unescape(String(html[inner])), range: whole)
        }
    }

    /// A stable cache key: what is drawn (the source) and everything that changes how it looks.
    public static func key(source: String, theme: String, appearance: String, mermaidVersion: String) -> String {
        let material = ["vitrine-mermaid-1", mermaidVersion, theme, appearance, source].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Replaces each block with its cached SVG when `cached(key)` has one, and otherwise tags it with its key.
    public static func rewrite(_ html: String, key: (String) -> String, cached: (String) -> String?) -> String {
        var out = html
        for block in find(in: html).reversed() {
            let k = key(block.source)
            let replacement: String
            if let svg = cached(k) {
                replacement = #"<div class="mermaid-block" data-cached="1">"# + svg + "</div>"
            } else {
                replacement = #"<pre data-mermaid-key=""# + k + #""><code class="language-mermaid">"#
                    + escape(block.source) + "</code></pre>"
            }
            out.replaceSubrange(block.range, with: replacement)
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
