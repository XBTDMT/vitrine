import CryptoKit
import Foundation

/// Importing an editor theme (I-14, code state 15): a VS Code theme (`.json`, comments and trailing commas allowed),
/// a TextMate theme (`.tmTheme`) or a Zed theme (`.json` with `themes`), turned into the form Shiki reads (name, type,
/// colors, tokenColors) and kept in Vitrine's settings on this Mac. Only colours and font styles are read; nothing in
/// a theme file runs, and a VS Code theme that `include`s another file keeps only what it states itself.
/// roadmap: S-5
enum CodeThemeImport {
    struct Imported: Codable, Equatable {
        let id: String
        let name: String
        /// The theme in Shiki's form, as JSON.
        let theme: Data
    }

    enum Failure: Error, Equatable, LocalizedError {
        case tooLarge, unreadable, noColours
        var errorDescription: String? {
            switch self {
            case .tooLarge:
                String(localized: "That theme file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(CodeThemeImport.maxBytes), countStyle: .memory)).",
                       bundle: .previewKit, comment: "Theme import error; the argument is the size limit, such as '2 MB'.")
            case .unreadable:
                String(localized: "That file is not a VS Code, Zed or TextMate theme.", bundle: .previewKit, comment: "Theme import error.")
            case .noColours:
                String(localized: "That theme has no colours Vitrine can use.", bundle: .previewKit, comment: "Theme import error.")
            }
        }
    }

    static let maxBytes = 2 << 20
    static let key = "code.importedThemes"

    /// Every theme in the file (a Zed file can hold a light and a dark one).
    static func read(_ data: Data, fileName: String) throws -> [Imported] {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        let fallbackName = (fileName as NSString).deletingPathExtension
        var themes: [[String: Any]] = []
        if fileName.lowercased().hasSuffix(".tmtheme") || data.starts(with: Array("<?xml".utf8)) || data.starts(with: Array("bplist".utf8)) {
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw Failure.unreadable }
            themes = [fromTextMate(plist, fallbackName: fallbackName)]
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: Data(stripJSONC(String(decoding: data, as: UTF8.self)).utf8)) as? [String: Any]
            else { throw Failure.unreadable }
            if let zed = object["themes"] as? [[String: Any]] {
                themes = zed.map { fromZed($0, family: object["name"] as? String ?? fallbackName) }
            } else if object["tokenColors"] != nil || object["colors"] != nil {
                themes = [fromVSCode(object, fallbackName: fallbackName)]
            } else {
                throw Failure.unreadable
            }
        }
        let usable = themes.filter { !(($0["tokenColors"] as? [Any])?.isEmpty ?? true) }
        guard !usable.isEmpty else { throw Failure.noColours }
        return try usable.map { theme in
            let json = try JSONSerialization.data(withJSONObject: theme, options: [.sortedKeys])
            let name = theme["name"] as? String ?? fallbackName
            let digest = SHA256.hash(data: json).prefix(4).map { String(format: "%02x", $0) }.joined()
            return Imported(id: "imp-" + digest, name: name, theme: json)
        }
    }

    // MARK: Formats

    private static func fromVSCode(_ o: [String: Any], fallbackName: String) -> [String: Any] {
        var rules: [[String: Any]] = []
        for case let r as [String: Any] in o["tokenColors"] as? [Any] ?? [] {
            guard let settings = cleanSettings(r["settings"] as? [String: Any]) else { continue }
            var rule: [String: Any] = ["settings": settings]
            if let scope = r["scope"] as? String { rule["scope"] = scope } else if let scopes = r["scope"] as? [String] { rule["scope"] = scopes }
            rules.append(rule)
        }
        let colors = (o["colors"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? String).flatMap(color) }
        let type = (o["type"] as? String) == "light" ? "light" : (o["type"] as? String) == "dark" ? "dark" : guessType(colors["editor.background"])
        return ["name": o["name"] as? String ?? fallbackName, "type": type, "colors": colors, "tokenColors": rules]
    }

    private static func fromTextMate(_ p: [String: Any], fallbackName: String) -> [String: Any] {
        var rules: [[String: Any]] = []
        var colors: [String: String] = [:]
        for case let r as [String: Any] in p["settings"] as? [Any] ?? [] {
            let raw = r["settings"] as? [String: Any] ?? [:]
            if r["scope"] == nil {
                colors["editor.background"] = (raw["background"] as? String).flatMap(color)
                colors["editor.foreground"] = (raw["foreground"] as? String).flatMap(color)
                colors["editor.selectionBackground"] = (raw["selection"] as? String).flatMap(color)
                colors["editorLineNumber.foreground"] = (raw["gutterForeground"] as? String).flatMap(color)
                continue
            }
            guard let settings = cleanSettings(raw), let scope = r["scope"] as? String else { continue }
            rules.append(["scope": scope, "settings": settings])
        }
        return ["name": p["name"] as? String ?? fallbackName, "type": guessType(colors["editor.background"]),
                "colors": colors, "tokenColors": rules]
    }

    /// Zed's syntax names → the TextMate scopes Shiki's grammars use.
    static let zedScopes: [String: [String]] = [
        "attribute": ["entity.other.attribute-name"], "boolean": ["constant.language.boolean"],
        "comment": ["comment", "punctuation.definition.comment"], "comment.doc": ["comment.block.documentation"],
        "constant": ["constant", "variable.other.constant", "support.constant"], "constructor": ["entity.name.function.constructor"],
        "function": ["entity.name.function", "support.function"], "keyword": ["keyword", "storage", "storage.type", "storage.modifier"],
        "label": ["entity.name.label"], "number": ["constant.numeric"], "operator": ["keyword.operator"],
        "property": ["variable.other.property", "support.type.property-name", "meta.object-literal.key"],
        "punctuation": ["punctuation", "meta.brace"], "string": ["string", "punctuation.definition.string"],
        "string.escape": ["constant.character.escape"], "string.regex": ["string.regexp"], "tag": ["entity.name.tag"],
        "type": ["entity.name.type", "entity.name.class", "support.type", "support.class"], "variable": ["variable"],
        "variable.special": ["variable.language"],
    ]

    private static func fromZed(_ t: [String: Any], family: String) -> [String: Any] {
        let style = t["style"] as? [String: Any] ?? [:]
        var colors: [String: String] = [:]
        colors["editor.background"] = (style["editor.background"] as? String ?? style["background"] as? String).flatMap(color)
        colors["editor.foreground"] = (style["editor.foreground"] as? String ?? style["text"] as? String).flatMap(color)
        colors["editorLineNumber.foreground"] = (style["editor.line_number"] as? String).flatMap(color)
        colors["editorLineNumber.activeForeground"] = (style["editor.active_line_number"] as? String).flatMap(color)
        if let sel = (style["players"] as? [[String: Any]])?.first?["selection"] as? String { colors["editor.selectionBackground"] = color(sel) }
        var rules: [[String: Any]] = []
        for (name, value) in (style["syntax"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let scopes = zedScopes[name], let v = value as? [String: Any] else { continue }
            var settings: [String: Any] = [:]
            if let c = (v["color"] as? String).flatMap(color) { settings["foreground"] = c }
            var styles: [String] = []
            if (v["font_style"] as? String) == "italic" { styles.append("italic") }
            if let w = v["font_weight"] as? Double, w >= 600 { styles.append("bold") }
            if !styles.isEmpty { settings["fontStyle"] = styles.joined(separator: " ") }
            guard !settings.isEmpty else { continue }
            rules.append(["scope": scopes, "settings": settings])
        }
        let appearance = (t["appearance"] as? String) == "light" ? "light" : "dark"
        return ["name": t["name"] as? String ?? family, "type": appearance, "colors": colors, "tokenColors": rules]
    }

    // MARK: Cleaning

    /// Foreground and font style only, with colours checked.
    private static func cleanSettings(_ s: [String: Any]?) -> [String: Any]? {
        guard let s else { return nil }
        var out: [String: Any] = [:]
        if let f = (s["foreground"] as? String).flatMap(color) { out["foreground"] = f }
        if let st = s["fontStyle"] as? String {
            let words = st.split(separator: " ").filter { ["italic", "bold", "underline", "strikethrough"].contains($0) }
            if !words.isEmpty { out["fontStyle"] = words.joined(separator: " ") }
        }
        return out.isEmpty ? nil : out
    }

    /// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`; anything else is dropped.
    static func color(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("#"), [4, 5, 7, 9].contains(t.count), t.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return t
    }

    private static func guessType(_ background: String?) -> String {
        guard let bg = background, bg.count >= 7, let v = Int(bg.dropFirst().prefix(6), radix: 16) else { return "dark" }
        let r = Double((v >> 16) & 0xFF), g = Double((v >> 8) & 0xFF), b = Double(v & 0xFF)
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 140 ? "light" : "dark"
    }

    /// JSON with comments (`//`, `/* */`) and trailing commas, as VS Code writes, made plain JSON. Strings are kept.
    static func stripJSONC(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var chars = Array(s.unicodeScalars)[...]
        var inString = false
        while let c = chars.first {
            chars = chars.dropFirst()
            if inString {
                out.unicodeScalars.append(c)
                if c == "\\", let n = chars.first { out.unicodeScalars.append(n); chars = chars.dropFirst() } else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true; out.unicodeScalars.append(c); continue }
            if c == "/", chars.first == "/" { while let n = chars.first, n != "\n" { chars = chars.dropFirst() }; continue }
            if c == "/", chars.first == "*" {
                chars = chars.dropFirst()
                while let n = chars.first { chars = chars.dropFirst(); if n == "*", chars.first == "/" { chars = chars.dropFirst(); break } }
                continue
            }
            if c == "," {
                // A comma before `}` or `]` (skipping blanks and comments is enough for theme files) is dropped.
                let rest = chars.drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
                if rest.first == "}" || rest.first == "]" { continue }
            }
            out.unicodeScalars.append(c)
        }
        return out
    }

    // MARK: Keeping

    static func stored(_ defaults: UserDefaults) -> [Imported] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Imported].self, from: data)) ?? []
    }

    /// Adds (or replaces, by id) and keeps at most 40.
    static func store(_ new: [Imported], in defaults: UserDefaults) {
        var all = stored(defaults).filter { old in !new.contains { $0.id == old.id } } + new
        if all.count > 40 { all.removeFirst(all.count - 40) }
        defaults.set(try? JSONEncoder().encode(all), forKey: key)
    }
}
