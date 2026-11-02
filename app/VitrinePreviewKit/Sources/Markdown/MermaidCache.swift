import Foundation

/// Drawn Mermaid diagrams on disk (G-2 route C), so a file's diagrams appear at once from its second open on. One
/// SVG per key (`MermaidBlocks.key`: source, theme, appearance, mermaid version), in the Markdown extension's own
/// caches folder; nothing is shared or sent. Only what mermaid drew is stored, and it is checked to be an SVG.
/// The folder is pruned to `limit` bytes, oldest first. roadmap: S-4
struct MermaidCache: Sendable {
    let directory: URL
    var limit: Int = 32 * 1024 * 1024
    static let maxItem = 2 * 1024 * 1024

    static var standard: MermaidCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return MermaidCache(directory: base.appendingPathComponent("io.github.xbtdmt.vitrine/mermaid", isDirectory: true))
    }

    /// The vendored mermaid version, from `web/vendor/mermaid/VERSION` ("mermaid 12.2.0 (MIT) …").
    static let mermaidVersion: String = {
        let bundle = Bundle(for: MarkdownRenderer.self)
        guard let url = bundle.url(forResource: "VERSION", withExtension: nil, subdirectory: "web/vendor/mermaid"),
              let line = try? String(contentsOf: url, encoding: .utf8) else { return "unknown" }
        let parts = line.split(separator: " ")
        return parts.count > 1 ? String(parts[1]) : "unknown"
    }()

    private func file(_ key: String) -> URL? {
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { return nil }
        return directory.appendingPathComponent(key + ".svg")
    }

    func svg(for key: String) -> String? {
        guard let url = file(key), let data = try? Data(contentsOf: url), let svg = String(data: data, encoding: .utf8) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)   // recently used
        return svg
    }

    /// Saves a drawing; false when it is not an SVG, too large, the key is malformed, or the write failed.
    @discardableResult
    func store(_ svg: String, for key: String) -> Bool {
        guard let url = file(key), svg.hasPrefix("<svg"), svg.hasSuffix("</svg>"), svg.utf8.count <= Self.maxItem else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(svg.utf8).write(to: url, options: .atomic)
        } catch {
            return false
        }
        prune()
        return true
    }

    /// Saves what a page drew only when `tickets` says this page was handed that key for that source (S-16 F52).
    @discardableResult
    func store(_ svg: String, for key: String, source: String, tickets: MermaidTickets) -> Bool {
        guard tickets.accepts(key: key, source: source) else { return false }
        return store(svg, for: key)
    }

    func prune() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > limit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}

/// The cache keys Swift handed one page, each bound to the diagram source it was computed from (S-16 F52). The key
/// is `MermaidBlocks.key` over the source Swift put in the page with that page's theme, appearance and mermaid
/// version; the page only echoes it back with the source it drew, and a drawing is saved only when both match an
/// issued pair. So a document cannot choose a key (a raw-HTML `data-mermaid-key` of its own is never issued) nor
/// rebind an issued key to another drawing (a different source does not match), and a late message from a page
/// drawn in another theme carries a key the current page was never issued. roadmap: S-16
struct MermaidTickets: Sendable, Equatable {
    private var issued: [String: String] = [:]

    var isEmpty: Bool { issued.isEmpty }

    mutating func issue(key: String, source: String) { issued[key] = Self.normalized(source) }
    mutating func revoke(key: String) { issued[key] = nil }

    func accepts(key: String, source: String) -> Bool {
        guard let expected = issued[key] else { return false }
        return expected == Self.normalized(source)
    }

    /// The page reads the source back from the DOM, where the HTML parser has turned CR LF and CR into LF.
    static func normalized(_ source: String) -> String {
        source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
