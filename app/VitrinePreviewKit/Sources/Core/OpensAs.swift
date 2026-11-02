import Foundation
import VitrineSupport

/// What each kind of file opens as (I-3, settings r3-a File Types): the kinds whose previews offer more than one view,
/// the view identifiers their renderers name (the viewer switch's titles, CapsuleView.displayTitle translates them),
/// and the Settings key each choice lives under. The controller opens a preview on the chosen view when the preview
/// has it; otherwise on its own first view. roadmap: S-24
public enum OpensAs {
    public static let keyPrefix = "opensAs."

    /// Kind group → its views in the renderer's own order; the first is the default.
    public static let views: [String: [String]] = [
        "markdown": ["Rendered", "Source"],
        "code": ["Code", "Hex"],
        "structured": ["Tree", "Code"],
        "log": ["Log", "Text", "Hex"],
        "diff": ["Unified", "Split"],
        "csv": ["Table", "Text"],
        "sqlite": ["Rows", "Schema"],
        "dataset": ["Table", "Schema"],
        "session": ["Conversation", "Changes", "Source"],
        "notebook": ["Notebook", "Code only", "Source"],
        "card": ["Card", "Contents"],
        "folder": ["List", "Icons"],
        "image": ["Image", "Info"],
        "font": ["Glyphs", "Text", "Info"],
        "svg": ["Picture", "Source"],
        "binary": ["Hex", "Strings"],
    ]

    static let structuredLanguages: Set<String> = ["json", "json5", "jsonc", "yaml", "toml", "xml", "plist"]

    /// The group a kind of file belongs to, or nil when its preview has one view.
    public static func group(for kind: FileKind) -> String? {
        switch kind {
        case .markdown: return "markdown"
        case .code(let language):
            if language == "log" { return "log" }
            if language == "ipynb" || language == "marimo" { return "notebook" }
            if language.hasSuffix("-session") { return "session" }
            if structuredLanguages.contains(language) { return "structured" }
            if language == "jsonl" { return nil }
            return "code"
        case .diff: return "diff"
        case .csv: return "csv"
        case .sqlite: return "sqlite"
        case .dataset: return "dataset"
        case .appBundle, .installerPackage, .diskImage, .provisioningProfile, .configurationProfile, .torrent, .keyMaterial, .lockfile, .reader: return "card"
        case .folder: return "folder"
        case .image: return "image"
        case .font: return "font"
        case .svg: return "svg"
        case .binary: return "binary"
        case .plainText, .archive: return nil
        }
    }

    /// The view a preview should open on: the person's choice when the preview offers it, else nil (its first view).
    public static func preferredIndex(kind: FileKind, titles: [String], defaults: UserDefaults) -> Int? {
        guard let group = group(for: kind), let wanted = defaults.string(forKey: keyPrefix + group),
              let index = titles.firstIndex(of: wanted), index != 0 else { return nil }
        return index
    }
}
