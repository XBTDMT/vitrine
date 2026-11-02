import AppKit

/// The code view's display options (state 15, C-4): theme, font, size, line height, tab width and the six toggles,
/// kept in Vitrine's settings as `code.<key>` so every code file opens the way the last was left. Settings › Code and
/// Text (S-10) will show the same keys. roadmap: S-5
struct CodeOptions: Encodable, Equatable {
    var theme = "vitrine"
    var font = "SF Mono"
    var fontSize = 12
    var lineHeight = "normal"
    var tabSize = 4
    var wrap = false
    var lineNumbers = true
    var indentGuides = true
    var changedLines = true
    var sticky = true
    var minimap = false

    /// The keys the page may set; anything else it sends is ignored.
    static let keys: Set<String> = ["theme", "font", "fontSize", "lineHeight", "tabSize", "wrap", "lineNumbers", "indentGuides",
                                    "changedLines", "sticky", "minimap"]

    init() {}

    init(defaults d: UserDefaults) {
        func string(_ k: String, _ allowed: Set<String>? = nil) -> String? {
            guard let v = d.string(forKey: "code." + k), allowed?.contains(v) ?? true else { return nil }
            return v
        }
        func bool(_ k: String) -> Bool? { d.object(forKey: "code." + k) as? Bool }
        theme = string("theme") ?? theme
        font = string("font") ?? font
        if let s = d.object(forKey: "code.fontSize") as? Int { fontSize = min(24, max(9, s)) }
        lineHeight = string("lineHeight", ["tight", "normal", "roomy"]) ?? lineHeight
        if let t = d.object(forKey: "code.tabSize") as? Int, [2, 4, 8].contains(t) { tabSize = t }
        wrap = bool("wrap") ?? wrap
        lineNumbers = bool("lineNumbers") ?? lineNumbers
        indentGuides = bool("indentGuides") ?? indentGuides
        changedLines = bool("changedLines") ?? changedLines
        sticky = bool("sticky") ?? sticky
        minimap = bool("minimap") ?? minimap
    }

    /// SF Mono (the system's, always present) and the well-known code fonts installed on this Mac.
    static func installedFonts() -> [String] {
        let families = Set(NSFontManager.shared.availableFontFamilies)
        let known = ["Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Cascadia Code", "IBM Plex Mono", "Source Code Pro",
                     "Iosevka", "Hack", "Input Mono", "Berkeley Mono", "Commit Mono", "Geist Mono", "PT Mono", "Andale Mono", "Courier New"]
        return ["SF Mono"] + known.filter(families.contains)
    }
}

/// A JSON value from JSONSerialization, encoded back as it was (imported themes go to the page unchanged).
struct AnyJSON: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as NSNumber where CFGetTypeID(v) == CFBooleanGetTypeID(): try c.encode(v.boolValue)
        case let v as NSNumber: try c.encode(v.doubleValue)
        case let v as String: try c.encode(v)
        case let v as [Any]: try c.encode(v.map(AnyJSON.init))
        case let v as [String: Any]: try c.encode(v.mapValues(AnyJSON.init))
        default: try c.encodeNil()
        }
    }
}
