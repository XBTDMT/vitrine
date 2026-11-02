import AppKit
import VitrineSupport
import VitrineText
import VitrineTrust

/// Copy as Prompt for Finder's selection (X-5, the I-11 format): each file as its path and line count, then its
/// numbered lines fenced in their language, the form the code view's "Copy as prompt" makes (CodeCopy.prompt); a
/// folder as its tree; secrets masked before the text is built; a first line with the files and the rough token count.
///
/// The text is for a language model and keeps one fixed form (not localized), like the code view's prompt.
/// Files that are not text (binaries, archives, pictures) and key material are named but never copied.
/// roadmap: S-10 (X-5), S-21 (I-11)
enum PromptCopy {
    struct Result: Equatable, Sendable {
        /// What goes on the clipboard.
        let text: String
        /// About four bytes a token over the whole text, as the code view counts (CodeCopy.tokens).
        let tokens: Int
        /// Files whose contents are in the text.
        let filesCopied: Int
        /// Secret values replaced by bullets.
        let secretsMasked: Int
    }

    struct Limits: Sendable {
        /// A file larger than this is named, not copied (the secret scanner's own limit, TextLens.maxBytes).
        var fileBytes = TextLens.maxBytes
        /// Contents stop being added past this many bytes in all; later files are named.
        var totalBytes = 8 << 20
        /// How deep a folder's tree goes, and how many entries it lists.
        var treeDepth = 4
        var treeEntries = 400
    }

    /// The text for `urls` (files and folders, in Finder's order; repeats dropped).
    static func build(_ urls: [URL], limits: Limits = Limits()) -> Result {
        var seen = Set<String>()
        var sections: [String] = []
        var copied = 0, masked = 0, used = 0
        for url in urls.map(\.standardizedFileURL) where seen.insert(url.path).inserted {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                sections.append("\(url.path): not found, not included.\n"); continue
            }
            let kind = FileSniffer.kind(of: url, readers: false)
            if isDirectory.boolValue && kind == .folder {
                sections.append(tree(of: url, limits: limits)); continue
            }
            switch section(for: url, kind: kind, limits: limits, budget: limits.totalBytes - used) {
            case .copied(let text, let secrets, let bytes):
                sections.append(text); copied += 1; masked += secrets; used += bytes
            case .named(let line):
                sections.append(line)
            }
        }
        let body = sections.joined(separator: "\n")
        var header = "\(copied) file\(copied == 1 ? "" : "s") from Vitrine · ≈ \(tokens(body)) tokens"
        if masked > 0 { header += " · \(masked) secret value\(masked == 1 ? "" : "s") masked" }
        let text = header + "\n\n" + body
        return Result(text: text, tokens: tokens(text), filesCopied: copied, secretsMasked: masked)
    }

    /// Puts the text on `pasteboard` as plain text, replacing what was there.
    @discardableResult
    static func write(_ result: Result, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(result.text, forType: .string)
    }

    /// About four bytes a token (CodeCopy.tokens).
    static func tokens(_ text: String) -> Int { max(1, (text.utf8.count + 2) / 4) }

    // MARK: One file

    enum Section: Equatable {
        case copied(String, secrets: Int, bytes: Int)
        case named(String)
    }

    /// The fence language for a text kind; nil when the kind is not text Vitrine copies.
    static func language(for kind: FileKind) -> String? {
        switch kind {
        case .code(let language): return language
        case .markdown: return "markdown"
        case .plainText: return "plaintext"
        case .csv: return "csv"
        case .diff: return "diff"
        case .svg: return "xml"
        default: return nil
        }
    }

    static func section(for url: URL, kind: FileKind, limits: Limits, budget: Int) -> Section {
        let path = url.path
        if kind == .keyMaterial { return .named("\(path): a key or certificate, never copied.\n") }
        guard let language = language(for: kind) else { return .named("\(path): not text, not included.\n") }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= limits.fileBytes else {
            return .named("\(path): \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)), too large to copy.\n")
        }
        guard size <= budget else { return .named("\(path): not included, the copy is already at its size limit.\n") }
        // A file the extension was not handed access to (the sandbox refuses it, S-16 F44) or cannot open is said to
        // be unreadable, not mistaken for a text-encoding problem.
        guard let data = try? Data(contentsOf: url) else { return .named("\(path): cannot be read, not included.\n") }
        guard let decoded = String(data: data, encoding: .utf8) else {
            return .named("\(path): not UTF-8 text, not included.\n")
        }
        var text = decoded.replacingOccurrences(of: "\r\n", with: "\n")
        var secrets = 0
        // The same two passes as the code view (CodeRenderer.readWhole): key = value files first, then the family's
        // detectors (T-4, G-23). SVG is read as XML.
        if SecretMask.languages.contains(language) {
            let result = SecretMask.mask(text)
            text = result.text; secrets += result.count
        }
        let lensKind: FileKind = kind == .svg ? .code(language: "xml") : kind
        let lens = LensPolicy.masked(text, kind: lensKind)
        text = lens.text; secrets += lens.count
        return .copied(prompt(path: path, language: language, text: text), secrets: secrets, bytes: data.count)
    }

    /// CodeCopy.prompt for a whole file: "path (N lines):", then the lines numbered from 1 and fenced in the language.
    static func prompt(path: String, language: String, text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { lines.removeLast() }
        if lines.isEmpty { lines = [""] }
        let width = String(lines.count).count
        let numbered = lines.enumerated().map { i, line in
            String(repeating: " ", count: width - String(i + 1).count) + "\(i + 1)  " + line
        }.joined(separator: "\n")
        let fence = numbered.contains("```") ? "````" : "```"
        return "\(path) (\(lines.count.formatted()) lines):\n\n\(fence)\(language == "plaintext" ? "" : language)\n\(numbered)\n\(fence)\n"
    }

    // MARK: A folder

    /// The folder's tree, hidden files left out, folders first then files, each in Finder's order.
    static func tree(of folder: URL, limits: Limits) -> String {
        var lines = [folder.lastPathComponent + "/"]
        var listed = 0, left = 0
        func walk(_ dir: URL, prefix: String, depth: Int) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
            func isFolder(_ url: URL) -> Bool {
                let values = try? url.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isPackage != true
            }
            let sorted = entries.sorted {
                let a = isFolder($0), b = isFolder($1)
                return a != b ? a : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            for (index, entry) in sorted.enumerated() {
                guard listed < limits.treeEntries else { left += sorted.count - index; return }
                let last = index == sorted.count - 1
                let folder = isFolder(entry)
                lines.append(prefix + (last ? "└── " : "├── ") + entry.lastPathComponent + (folder ? "/" : ""))
                listed += 1
                if folder {
                    if depth + 1 < limits.treeDepth {
                        walk(entry, prefix: prefix + (last ? "    " : "│   "), depth: depth + 1)
                    } else if let inside = try? FileManager.default.contentsOfDirectory(atPath: entry.path).filter({ !$0.hasPrefix(".") }), !inside.isEmpty {
                        lines.append(prefix + (last ? "    " : "│   ") + "└── … \(inside.count) more")
                    }
                }
            }
        }
        walk(folder, prefix: "", depth: 0)
        if left > 0 { lines.append("… \(left) more entries") }
        let fence = lines.contains { $0.contains("```") } ? "````" : "```"
        return "\(folder.path) (folder, \(listed.formatted()) entries shown):\n\n\(fence)text\n\(lines.joined(separator: "\n"))\n\(fence)\n"
    }
}
