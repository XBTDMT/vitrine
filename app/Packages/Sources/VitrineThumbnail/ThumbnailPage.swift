import Foundation
import VitrineSupport
import VitrineText
import VitrineTrust

/// What a Finder thumbnail shows for one file (S-18, thumbnails r3-a): the first lines, coloured, or a table's first
/// rows; the family's glyph and colour for the smallest sizes; and a state: empty, huge (it fades at the foot),
/// broken (an orange mark) or dangerous (a red mark). Built from the file's first bytes only, values masked by
/// G-23's policy, so it fits Quick Look's time budget and never shows a secret. roadmap: S-18
public struct ThumbnailPage: Sendable, Equatable {
    public enum Layout: Sendable, Equatable {
        /// Lines of runs; `numbered` shows the line gutter (source code), `prose` draws headings larger.
        case text(lines: [[CodeLexer.Run]], numbered: Bool, prose: Bool)
        case table(rows: [[String]])
    }

    public enum Mark: Sendable, Equatable {
        case none
        /// Orange: the file is broken (it does not parse).
        case caution(String)
        /// Red: opening or running it can hurt.
        case danger(String)
    }

    public var layout: Layout
    /// An SF Symbol for the glyph tier (32 pt and below).
    public var glyph: String
    /// The design token that colours the glyph and the silhouette's accents.
    public var tint: String
    /// The type label macOS draws at 64 pt and up (QLThumbnailReply.extensionBadge).
    public var badge: String
    public var isEmpty = false
    /// More than a thumbnail ever reads: the page fades at its foot (r3-a's huge-file state).
    public var isHuge = false
    public var mark: Mark = .none

    /// Bytes read from the front of a file; lines kept.
    public static let readBytes = 64 << 10
    public static let maxLines = 60
    public static let hugeBytes: Int64 = 1 << 20

    public init(layout: Layout, glyph: String, tint: String, badge: String, isEmpty: Bool = false, isHuge: Bool = false, mark: Mark = .none) {
        self.layout = layout; self.glyph = glyph; self.tint = tint; self.badge = badge
        self.isEmpty = isEmpty; self.isHuge = isHuge; self.mark = mark
    }

    /// A calm sheet with the kind's glyph and nothing on it: what a file Vitrine cannot read gets, instead of an
    /// error. An error makes Quick Look hand that type to another drawer for as long as its agent runs (measured
    /// 2026-11-01, SP-6), so the extension never fails a request it claimed.
    public static func placeholder(for url: URL) -> ThumbnailPage {
        let style = Style.of(textKind(url))
        let ext = url.pathExtension
        return ThumbnailPage(layout: .text(lines: [], numbered: false, prose: false), glyph: style.glyph, tint: style.tint,
                             badge: ext.isEmpty ? url.lastPathComponent.uppercased() : ext.uppercased())
    }

    /// The file as text: a file a format reader owns (a HAR, a Compose file, JSON Lines) is drawn and checked as the
    /// text it is, the way it was before the readers existed.
    public static func textKind(_ url: URL) -> FileKind {
        let kind = FileSniffer.kind(of: url)
        if case .reader = kind { return FileSniffer.kind(of: url, readers: false) }
        return kind
    }

    /// The page for a file on disk. Reads at most `readBytes`.
    public static func make(url: URL) throws -> ThumbnailPage {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: readBytes) ?? Data()
        return make(data: data, fileName: url.lastPathComponent, fileSize: size, kind: textKind(url))
    }

    public static func make(data: Data, fileName: String, fileSize: Int64, kind: FileKind) -> ThumbnailPage {
        let ext = (fileName as NSString).pathExtension
        let style = Style.of(kind)
        var page = ThumbnailPage(layout: .text(lines: [], numbered: false, prose: false), glyph: style.glyph, tint: style.tint,
                                 badge: ext.isEmpty ? fileName.uppercased() : ext.uppercased())
        page.isHuge = fileSize > hugeBytes
        let complete = Int64(data.count) >= fileSize
        // A binary property list is drawn as the XML it stands for, when that XML stays within the budget (F39).
        var text: String
        let object = style.language == "plist" && data.starts(with: Array("bplist".utf8))
            ? try? PropertyListSerialization.propertyList(from: data, format: nil) : nil
        if let object, !PlistBudget.fits(object) {
            page.mark = .caution(tooLargeToShow)
            return page
        }
        if let object, let xml = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) {
            text = String(decoding: xml, as: UTF8.self)
        } else {
            text = TextEncodingDetector.decode(data, partial: !complete).text
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            page.isEmpty = true
            return page
        }
        page.mark = mark(text, data: data, complete: complete, fileName: fileName, style: style)
        // Secrets never reach a picture Finder keeps for days (G-23). Key = value files first take the same key-name
        // mask the Code preview and Copy as Prompt run (SecretMask: DB_PASS, POSTGRES_PASSWORD …), so a password the
        // detectors' entropy or label checks pass over is masked here as it is there (S-16 F45).
        if case .code(let language) = kind, SecretMask.languages.contains(language) { text = SecretMask.mask(text).text }
        text = LensPolicy.masked(text, kind: kind).text
        var lines = Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines).map { String($0.prefix(240)) })
        if !complete, lines.count > 1 { lines.removeLast() }
        switch style.layout {
        case .table:
            page.layout = .table(rows: lines.prefix(40).map { $0.split(separator: style.delimiter, omittingEmptySubsequences: false).prefix(12).map(String.init) })
        case .prose:
            page.layout = .text(lines: lines.map(prose), numbered: false, prose: true)
        case .code(let numbered):
            var lexer = CodeLexer(language: style.language)
            page.layout = .text(lines: lexer.lex(lines), numbered: numbered, prose: false)
        }
        return page
    }

    /// Markdown-family prose: headings, fences and quotes take a token; the rest is plain.
    static func prose(_ line: String) -> [CodeLexer.Run] {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { return [.init(t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces), .keyword)] }
        if t.hasPrefix("```") || t.hasPrefix("~~~") || line.hasPrefix("    ") { return [.init(line, .string)] }
        if t.hasPrefix(">") { return [.init(line, .comment)] }
        if t.hasPrefix("- ") || t.hasPrefix("* ") { return [.init("• ", .punctuation), .init(String(t.dropFirst(2)), .plain)] }
        return [.init(line, .plain)]
    }

    /// Red for a script that downloads and runs code, hides code or removes macOS's download warning, and for hidden
    /// instructions (the trust lens, S-20); orange for a file that does not parse. Nothing for anything else.
    static func mark(_ text: String, data: Data, complete: Bool, fileName: String, style: Style) -> Mark {
        if style.isScript, let report = ScriptLens.scan(script: text, launcher: false), report.level == .danger {
            return .danger(report.findings.first(where: { $0.level == .danger })?.title ?? report.headline)
        }
        if let hidden = HiddenText.scan(text, fileName: fileName), hidden.level == .danger { return .danger(hidden.headline) }
        guard complete else { return .none }
        switch style.language {
        case "xml", "plist":
            if data.starts(with: Array("bplist".utf8)) {
                return (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil ? .caution(malformed(nil)) : .none
            }
            let parser = XMLParser(data: data)
            if !parser.parse() { return .caution(malformed(parser.lineNumber)) }
        case "jsonl":
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if (try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed])) == nil { return .caution(malformed(i + 1)) }
            }
        default: break
        }
        return .none
    }

    /// The warning band on a binary property list whose XML form would pass `PlistBudget` (F39).
    static var tooLargeToShow: String {
        String(localized: "Too large to show", bundle: .module, comment: "Finder thumbnail warning band: the file expands to more than a thumbnail can draw.")
    }

    /// The same budget as VitrineData's `PlistExpansion` (this module does not depend on VitrineData), for the XML a
    /// thumbnail draws from a binary property list. Core Foundation hands one shared object back for every reference
    /// to it, and its XML writer writes it out once per reference, so 21 KB could become 220 MB of XML (measured
    /// 2026-11-02: 108 s in this process before the budget). A thumbnail reads at most `readBytes`, so the floors
    /// apply: 500,000 values, and 8 MB of text where it only ever draws `maxLines` lines. roadmap: S-16
    enum PlistBudget {
        static let maxValues = 500_000
        static let maxTextBytes = 8 << 20

        /// The walk stops at the first budget it passes, so its own work is bounded by the budgets. Text is estimated:
        /// the UTF-16 length of strings and keys, 4/3 of data (base64), and 16 bytes of tags per value.
        static func fits(_ root: Any) -> Bool {
            var values = 0
            var text = 0
            var stack: [Any] = [root]
            func add(_ bytes: Int) -> Bool {
                text += bytes                  // never near Int.max: every step stops once past 8 MB
                return text <= maxTextBytes
            }
            while let value = stack.popLast() {
                values += 1
                guard values <= maxValues, add(16) else { return false }
                switch value {
                case let string as NSString:
                    guard add(string.length) else { return false }
                case let data as NSData:
                    guard add(data.length / 3 * 4 + 4) else { return false }
                case let array as NSArray:
                    for element in array { stack.append(element) }
                case let dictionary as NSDictionary:
                    for (key, element) in dictionary {
                        guard add((key as? NSString)?.length ?? 16) else { return false }
                        stack.append(element)
                    }
                default:
                    break
                }
            }
            return true
        }
    }

    static func malformed(_ line: Int?) -> String {
        guard let line, line > 0 else { return String(localized: "Does not parse", bundle: .module, comment: "Finder thumbnail warning band: the file is broken.") }
        return String(localized: "Does not parse at line \(line)", bundle: .module, comment: "Finder thumbnail warning band: the file is broken at this line.")
    }

    /// How a kind is drawn: its layout, language, glyph and colour.
    struct Style: Sendable {
        enum Kind: Sendable { case code(numbered: Bool), prose, table }
        var layout: Kind
        var language: String
        var glyph: String
        var tint: String
        var delimiter: Character = "\t"
        var isScript = false

        static let config: Set<String> = ["yaml", "toml", "ini", "properties", "dotenv", "conf", "hcl", "terraform", "nix", "json", "jsonc", "json5"]
        static let shells: Set<String> = ["shell", "bash", "zsh", "fish", "powershell", "applescript"]

        static func of(_ kind: FileKind) -> Style {
            switch kind {
            case .markdown: return Style(layout: .prose, language: "markdown", glyph: "text.alignleft", tint: "syn-fn")
            case .csv(let d): return Style(layout: .table, language: "tsv", glyph: "tablecells", tint: "syn-num", delimiter: d)
            case .plainText: return Style(layout: .code(numbered: false), language: "plaintext", glyph: "doc.plaintext", tint: "syn-com")
            case .code(let raw):
                let language = raw.lowercased()
                switch language {
                case _ where config.contains(language): return Style(layout: .code(numbered: false), language: language, glyph: "curlybraces", tint: "syn-const")
                case "jsonl", "json lines": return Style(layout: .code(numbered: false), language: "jsonl", glyph: "list.bullet.rectangle", tint: "syn-str")
                case "xml", "html", "svg": return Style(layout: .code(numbered: false), language: "xml", glyph: "chevron.left.forwardslash.chevron.right", tint: "syn-ty")
                case "plist": return Style(layout: .code(numbered: false), language: "plist", glyph: "list.bullet.indent", tint: "syn-ty")
                case "sql": return Style(layout: .code(numbered: true), language: language, glyph: "cylinder.split.1x2", tint: "syn-ty")
                case "latex": return Style(layout: .code(numbered: false), language: language, glyph: "function", tint: "syn-str")
                // A marimo notebook is Python (A-8); its thumbnail is drawn as the Python file it is.
                case "marimo": return Style(layout: .code(numbered: true), language: "python", glyph: "chevron.left.forwardslash.chevron.right", tint: "syn-kw")
                case "log", "plaintext", "nfo": return Style(layout: .code(numbered: false), language: "log", glyph: "doc.plaintext", tint: "syn-com")
                case _ where shells.contains(language):
                    return Style(layout: .code(numbered: true), language: language, glyph: "terminal", tint: "syn-kw", isScript: true)
                default: return Style(layout: .code(numbered: true), language: language, glyph: "chevron.left.forwardslash.chevron.right", tint: "syn-kw")
                }
            default: return Style(layout: .code(numbered: false), language: "plaintext", glyph: "doc", tint: "syn-com")
            }
        }
    }
}
