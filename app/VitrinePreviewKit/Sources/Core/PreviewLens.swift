import Foundation
import VitrineDetect
import VitrineDocument
import VitrineSupport
import VitrineText
import VitrineTrust

/// Which trust lenses (S-20) run for a file, and what they found: link files are read for where they lead; scripts
/// for what running them would do; every text file for secrets and hidden characters. Text is read from the file as
/// written (the preview's own text has masked values where a config file holds secrets), up to TextLens.maxBytes.
/// Pure and thread-free, so the controller runs it off the main thread after the preview is shown. roadmap: S-20
public enum PreviewLens {
    public static func report(for kind: FileKind, url: URL, fallbackText: String) -> LensReport? {
        let ext = url.pathExtension.lowercased(), name = url.lastPathComponent
        if ScriptLens.linkExtensions.contains(ext) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 1 << 20 else { return nil }
            return ScriptLens.scan(link: data) ?? .nothingFound
        }
        guard isText(kind) || ScriptLens.scriptExtensions.contains(ext) else { return nil }
        let text = fileText(url) ?? fallbackText
        var reports: [LensReport] = []
        if isScript(kind, ext: ext, text: text) {
            let script = ext == "terminal" ? terminalCommand(url) ?? text : text
            if let r = ScriptLens.scan(script: script, launcher: ["command", "terminal", "tool"].contains(ext)) { reports.append(r) }
        }
        if let r = HiddenText.scan(text, fileName: name) { reports.append(r) }
        if let family = LensPolicy.family(for: kind), let scanner = LensPolicy.scanner(for: family),
           let r = TextLens.scan(text, scanner: scanner, masked: masks(kind)) { reports.append(r) }
        return LensReport.combine(reports) ?? .nothingFound
    }

    /// The previews that draw text mask its secrets (G-23); tables are counted only.
    static func masks(_ kind: FileKind) -> Bool {
        switch kind {
        case .markdown, .plainText, .code: return true
        default: return false
        }
    }

    static func isText(_ kind: FileKind) -> Bool {
        switch kind {
        case .markdown, .plainText, .csv: return true
        case .code(let language): return !language.hasSuffix("-session") && language != "ipynb"
        default: return false
        }
    }

    static let shellLanguages: Set<String> = ["shell", "bash", "zsh", "sh", "fish", "applescript", "powershell"]

    static func isScript(_ kind: FileKind, ext: String, text: String) -> Bool {
        if ScriptLens.scriptExtensions.contains(ext) { return true }
        if case .code(let language) = kind, shellLanguages.contains(language) { return true }
        return text.hasPrefix("#!")
    }

    /// The file's own words, decoded as the code view decodes them; nil past the size the lens reads.
    static func fileText(_ url: URL) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size <= TextLens.maxBytes, let data = try? Data(contentsOf: url) else { return nil }
        return TextEncodingDetector.decode(data).text
    }

    /// A `.terminal` file is Terminal's settings; the command it runs is its `CommandString`.
    static func terminalCommand(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CommandString"] as? String
    }

    /// The document with the lens's verdict as its badge: the state dot, the pill's tooltip and describe read it.
    public static func badged(_ document: PreviewDocument, with report: LensReport) -> PreviewDocument {
        guard report.level > .calm else { return document }
        var d = document
        let detail = report.findings.prefix(3).map { f in f.line.map { "\(f.title) (\(lineWord) \($0))" } ?? f.title }.joined(separator: "; ")
        d.badges.append(Badge(level: report.level == .danger ? .danger : .caution, title: report.headline, detail: detail))
        return d
    }

    static var lineWord: String { String(localized: "line", bundle: .previewKit, comment: "Word before a line number in a trust finding, e.g. 'Downloads and runs code (line 5)'.") }
}
