import AppKit
import Combine
import Foundation
import VitrinePreviewKit

// The Settings window's model (S-10, parity H-1), drawn to design/mockups/unified/settings.html: which panes and rows
// exist, the defaults key each row writes and the value the renderer assumes when the key is unset. A row only exists
// here when a renderer or the app already reads its key; rows the design draws whose setting nothing reads yet are
// left out (the list is in the S-10 report). The window writes `VitrineDefaults.shared`; SettingsBridge (G-19 route B)
// carries every change into the extensions' containers. Foundation only, so the unit tests compile it on its own.
// roadmap: S-10

/// The keys the window writes. Where the reading side exports its key it is used directly; the rest are spelled out
/// because their owner keeps them internal (CodeOptions, FolderContentIcons) or lives in the app (MenuBarController),
/// and SettingsModelTests checks each one against the reader.
enum SettingsKey {
    /// Finder thumbnails on or off (S-18); the Thumbnails extension reads it as VitrineThumbnail.ThumbnailSettings.key.
    static let thumbnails = "thumbnails.enabled"
    static let resumePosition = "general.resumePosition"       // PreviewHostController
    static let showMenuBarIcon = "general.showMenuBarIcon"     // MenuBarController.showIconKey
    static let recordRecents = RecentPreviews.recordingKey

    static let markdownTheme = MarkdownRenderer.Keys.theme
    static let markdownTextScale = MarkdownRenderer.Keys.textScale
    static let markdownTOC = MarkdownRenderer.Keys.toc
    static let markdownHideFrontMatter = MarkdownRenderer.Keys.hideFrontMatter
    static let markdownMath = MarkdownRenderer.Keys.math
    static let markdownEmoji = MarkdownRenderer.Keys.emoji
    static let markdownSmart = MarkdownRenderer.Keys.smart
    static let markdownImageWidth = MarkdownRenderer.Keys.imageMaxWidth
    static let markdownDiagramTheme = MarkdownRenderer.Keys.diagramTheme
    /// Read by UpdateCoordinator (H-8, G-21).
    static let updatesCheckAutomatically = "general.updatesCheckAutomatically"

    // CodeOptions reads `code.<name>` for each of CodeOptions.keys.
    static let codeTheme = "code.theme"
    static let codeFont = "code.font"
    static let codeFontSize = "code.fontSize"
    static let codeTabSize = "code.tabSize"
    static let codeWrap = "code.wrap"
    static let codeLineNumbers = "code.lineNumbers"
    static let codeIndentGuides = "code.indentGuides"
    static let codeChangedLines = "code.changedLines"
    static let codeSticky = "code.sticky"
    static let codeMinimap = "code.minimap"
    /// Written by the code view's Import theme; read here only to list the imported themes by name.
    static let codeImportedThemes = "code.importedThemes"

    static let folderIconStyle = "folders.contentIconStyle"    // FolderContentIcons.styleKey
    /// The folders chosen in Finder; read here only to count them.
    static let folderIconList = "folders.contentIcons"
}

/// One stored value, typed the way its reader casts it (`as? Bool`, `as? Int`, `as? Double`, `string(forKey:)`).
enum SettingsValue: Equatable, Hashable, Sendable {
    case bool(Bool), int(Int), double(Double), string(String)

    var object: Any {
        switch self {
        case .bool(let v): v
        case .int(let v): v
        case .double(let v): v
        case .string(let v): v
        }
    }

    /// A stored object read as the same type as `like`; nil when it is missing or of another type.
    init?(_ object: Any?, like: SettingsValue) {
        switch (like, object) {
        case (.string, let s as String): self = .string(s)
        case (.bool, let n as NSNumber) where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case (.int, let n as NSNumber) where CFGetTypeID(n) != CFBooleanGetTypeID() && Double(n.intValue) == n.doubleValue: self = .int(n.intValue)
        case (.double, let n as NSNumber) where CFGetTypeID(n) != CFBooleanGetTypeID(): self = .double(n.doubleValue)
        default: return nil
        }
    }

    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var double: Double? {
        switch self {
        case .int(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }
    var string: String? { if case .string(let v) = self { v } else { nil } }
}

struct SettingsOption: Equatable, Hashable, Identifiable, Sendable {
    var value: SettingsValue
    var label: String
    var id: SettingsValue { value }
}

/// How a row is edited. Menus whose choices depend on this Mac (fonts, imported themes) carry them in the store.
enum SettingsControl: Equatable, Sendable {
    case toggle
    case segmented([SettingsOption])
    case menu([SettingsOption])
    case codeTheme
    case codeFont
    /// A slider over a range (`step` apart), its ends labelled `low` and `high`.
    case slider(min: Double, max: Double, step: Double, low: String, high: String)
    /// Markdown's text size: the seven steps of MarkdownTheme.textScales.
    case textScale
    /// The Markdown theme tiles.
    case markdownThemes
    /// A row the window draws itself (a button or a fact); `SettingsRow.id` says which.
    case custom
}

enum SettingsSection: Sendable {
    case top, previews, thisMac, vitrine

    /// The sidebar heading above the section's panes; the top section has none.
    var title: String {
        switch self {
        case .top: ""
        case .previews: String(localized: "Previews", comment: "Settings: sidebar heading above the Markdown, Code and Folders panes")
        case .thisMac: String(localized: "This Mac", comment: "Settings: sidebar heading above the Privacy pane")
        case .vitrine: "Vitrine"
        }
    }
}

/// The panes that have at least one working row, in the design's order. File Types, Data, Trust, AI Files, More
/// Formats, Integrations and Updates are not here: no renderer reads a setting of theirs yet.
enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, fileTypes, appearance, markdown, code, folders, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General", comment: "Settings: pane name in the sidebar")
        case .fileTypes: String(localized: "File Types", comment: "Settings: pane name in the sidebar")
        case .appearance: String(localized: "Appearance", comment: "Settings: pane name in the sidebar")
        case .markdown: "Markdown"
        case .code: String(localized: "Code and Text", comment: "Settings: pane name in the sidebar")
        case .folders: String(localized: "Archives and Folders", comment: "Settings: pane name in the sidebar")
        case .privacy: String(localized: "Privacy", comment: "Settings: pane name in the sidebar")
        case .about: String(localized: "About", comment: "Settings: pane name in the sidebar")
        }
    }

    var section: SettingsSection {
        switch self {
        case .general, .fileTypes, .appearance: .top
        case .markdown, .code, .folders: .previews
        case .privacy: .thisMac
        case .about: .vitrine
        }
    }

    /// The G19 sidebar tiles (design: "Markdown slate, Code blue, … Appearance graphite").
    var tile: String {
        switch self {
        case .general, .about: "tile-general"
        case .appearance: "tile-appearance"
        case .fileTypes: "kind-data"
        case .markdown: "kind-text"
        case .code: "kind-code"
        case .folders: "kind-archive"
        case .privacy: "tile-privacy"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .fileTypes: "doc.on.doc"
        case .appearance: "paintpalette"
        case .markdown: "doc.richtext"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .folders: "archivebox"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }
}

struct SettingsRow: Identifiable, Equatable, Sendable {
    var id: String
    var pane: SettingsPane
    var group: String
    var title: String
    var subtitle: String = ""
    var key: String?
    var defaultValue: SettingsValue?
    var control: SettingsControl
}

// MARK: - The catalog

enum SettingsCatalog {
    static func options(_ pairs: [(SettingsValue, String)]) -> [SettingsOption] { pairs.map { SettingsOption(value: $0.0, label: $0.1) } }

    /// Every row, pane by pane and group by group, in the design's order. Defaults are the readers' own fallbacks.
    /// Titles, subtitles, group names and choices are marked for translation (S-12, parity H-6); a group's name is
    /// compared to gather its rows, so every row of a group spells it the same.
    /// A viewer switch name as the menus show it (the same words as the viewer switch, CapsuleView.displayTitle).
    static func viewName(_ id: String) -> String {
        switch id {
        case "Rendered": String(localized: "Rendered", comment: "Settings › File Types: opens as, the rendered view")
        case "Source": String(localized: "Source", comment: "Settings › File Types: opens as, the file's source text")
        case "Code": String(localized: "Code", comment: "Settings › File Types: opens as, the highlighted code view")
        case "Hex": String(localized: "Hex", comment: "Settings › File Types: opens as, the hex dump")
        case "Tree": String(localized: "Tree", comment: "Settings › File Types: opens as, the outline tree")
        case "Log": String(localized: "Log", comment: "Settings › File Types: opens as, the coloured log view")
        case "Text": String(localized: "Text", comment: "Settings › File Types: opens as, plain text")
        case "Unified": String(localized: "Unified", comment: "Settings › File Types: opens as, a diff's one-column view")
        case "Split": String(localized: "Split", comment: "Settings › File Types: opens as, a diff's side-by-side view")
        case "Table": String(localized: "Table", comment: "Settings › File Types: opens as, the data table")
        case "Rows": String(localized: "Rows", comment: "Settings › File Types: opens as, a database's rows")
        case "Schema": String(localized: "Schema", comment: "Settings › File Types: opens as, the schema")
        case "Conversation": String(localized: "Conversation", comment: "Settings › File Types: opens as, an agent session's conversation")
        case "Changes": String(localized: "Changes", comment: "Settings › File Types: opens as, an agent session's edits as diffs")
        case "Notebook": String(localized: "Notebook", comment: "Settings › File Types: opens as, a notebook's cells and outputs")
        case "Code only": String(localized: "Code only", comment: "Settings › File Types: opens as, a notebook's code cells only")
        case "Card": String(localized: "Card", comment: "Settings › File Types: opens as, the app's or installer's card")
        case "Contents": String(localized: "Contents", comment: "Settings › File Types: opens as, the files inside")
        case "List": String(localized: "List", comment: "Settings › File Types: opens as, a folder as a list")
        case "Icons": String(localized: "Icons", comment: "Settings › File Types: opens as, a folder as icons")
        case "Image": String(localized: "Image", comment: "Settings › File Types: opens as, the picture's card")
        case "Info": String(localized: "Info", comment: "Settings › File Types: opens as, every property as text")
        case "Glyphs": String(localized: "Glyphs", comment: "Settings › File Types: opens as, a font's glyph grid")
        case "Picture": String(localized: "Picture", comment: "Settings › File Types: opens as, an SVG drawn as a picture")
        case "Strings": String(localized: "Strings", comment: "Settings › File Types: opens as, a binary's printable text")
        default: id
        }
    }

    /// One File Types row (I-3): the kind, its files, and a menu of its views; key `opensAs.<group>`, as OpensAs's.
    static func opensAs(_ group: String, heading: String, title: String, files: String, views: [String]) -> SettingsRow {
        SettingsRow(id: "opensAs." + group, pane: .fileTypes, group: heading, title: title, subtitle: files,
                    key: "opensAs." + group, defaultValue: .string(views[0]),
                    control: .menu(options(views.map { (.string($0), viewName($0)) })))
    }

    static let rows: [SettingsRow] = [
        // General
        // A-4, G-29 (ruled 2026-11-01, with this note at the maintainer's request): the meter's exact OpenAI line. The
        // subtitle says plainly that OpenAI has stated no licence for the word list. Key matches TokenMeterView's.
        SettingsRow(id: "tokens.openaiExact", pane: .general,
                    group: String(localized: "Token meter", comment: "Settings › General: group heading for the token count shown with text previews"),
                    title: String(localized: "Exact OpenAI token counts", comment: "Settings › General: row title"),
                    subtitle: String(localized: "Uses OpenAI's o200k word list from tiktoken, on this Mac. OpenAI has not stated a licence for the list itself.", comment: "Settings › General: subtitle; a small note that the bundled word list carries no stated licence"),
                    key: "tokens.openaiExact", defaultValue: .bool(true), control: .toggle),
        SettingsRow(id: "general.diagnostics", pane: .general,
                    group: String(localized: "Quick Look", comment: "Settings › General: group heading (the macOS feature)"),
                    title: String(localized: "Who owns each file type", comment: "Settings › General: row that opens Diagnostics"),
                    subtitle: String(localized: "Which previewer answers for each kind of file, and how to fix one", comment: "Settings › General: subtitle"),
                    control: .custom),
        // Agent sessions (S-11) and the command line (H-3): actions that change things outside Vitrine, so each is a button
        // that shows exactly what it will do before doing it.
        SettingsRow(id: "general.sessions.claude", pane: .general,
                    group: String(localized: "Agent sessions", comment: "Settings › General: group heading"),
                    title: String(localized: "Track Claude Code sessions", comment: "Settings › General: row title"),
                    subtitle: String(localized: "Adds one line to Claude Code's settings so the menu lists recent sessions; shown before it is written", comment: "Settings › General: subtitle"),
                    control: .custom),
        SettingsRow(id: "sessions.codex.watch", pane: .general,
                    group: String(localized: "Agent sessions", comment: "Settings › General: group heading"),
                    title: String(localized: "Watch Codex sessions", comment: "Settings › General: row title"),
                    subtitle: String(localized: "Reads ~/.codex/sessions for the menu; nothing is written", comment: "Settings › General: subtitle; keep the folder path"),
                    key: "sessions.codex.watch", defaultValue: .bool(false), control: .toggle),
        // The Claude connector (X-9, G-22): Claude asks Vitrine about files through `vitrine mcp`. Connecting changes Claude's
        // settings, so each is a button that shows the change first.
        SettingsRow(id: "general.connector.code", pane: .general,
                    group: String(localized: "Claude connector", comment: "Settings › General: group heading"),
                    title: String(localized: "Claude Code", comment: "Settings › General › Claude connector: row title (the product's name)"),
                    subtitle: String(localized: "Claude can describe, read, picture and scan files with Vitrine; read-only, nothing leaves this Mac", comment: "Settings › General › Claude connector: subtitle"),
                    control: .custom),
        SettingsRow(id: "general.connector.app", pane: .general,
                    group: String(localized: "Claude connector", comment: "Settings › General: group heading"),
                    title: String(localized: "Claude app", comment: "Settings › General › Claude connector: row title (the Claude desktop app)"),
                    subtitle: String(localized: "The same tools in the Claude app; reopen it after connecting", comment: "Settings › General › Claude connector: subtitle"),
                    control: .custom),
        SettingsRow(id: "general.commandline", pane: .general,
                    group: String(localized: "Command line", comment: "Settings › General: group heading"),
                    title: String(localized: "The vitrine command", comment: "Settings › General: row title; `vitrine` is the command's name"),
                    subtitle: String(localized: "Open files in Vitrine from Terminal; you choose where it is linked", comment: "Settings › General: subtitle"),
                    control: .custom),
        SettingsRow(id: SettingsKey.resumePosition, pane: .general,
                    group: String(localized: "Reading", comment: "Settings › General: group heading"),
                    title: String(localized: "Reopen previews where you left off", comment: "Settings › General: row title"),
                    subtitle: String(localized: "Long files open at the place you last read", comment: "Settings › General: subtitle"),
                    key: SettingsKey.resumePosition, defaultValue: .bool(true), control: .toggle),
        // Finder thumbnails (S-18): one switch for every kind the Thumbnails extension draws; off, macOS draws its own.
        SettingsRow(id: SettingsKey.thumbnails, pane: .fileTypes,
                    group: String(localized: "Finder", comment: "Settings › File Types: group heading"),
                    title: String(localized: "Draw Finder thumbnails", comment: "Settings › File Types: row title"),
                    subtitle: String(localized: "Code and configuration files show their first lines in Finder; macOS keeps Markdown, JSON and CSV, and draws no thumbnail for archives and databases",
                                     comment: "Settings › File Types: subtitle for the Finder thumbnails switch"),
                    key: SettingsKey.thumbnails, defaultValue: .bool(true), control: .toggle),
        // File Types (I-3, settings r3-a): what each kind opens as. Kinds whose preview has one view have no row; who
        // handles each type is Diagnostics' (the link at the end).
        opensAs("markdown", heading: String(localized: "Documents", comment: "Settings › File Types: group heading"),
                title: "Markdown", files: String(localized: ".md and 8 dialects", comment: "Settings › File Types: the files in the Markdown kind"), views: ["Rendered", "Source"]),
        opensAs("code", heading: String(localized: "Documents", comment: "Settings › File Types: group heading"),
                title: String(localized: "Source code", comment: "Settings › File Types: kind name"), files: String(localized: "200+ languages", comment: "Settings › File Types: the files in the source code kind"), views: ["Code", "Hex"]),
        opensAs("structured", heading: String(localized: "Documents", comment: "Settings › File Types: group heading"),
                title: "JSON, YAML, TOML, XML, plist", files: String(localized: "Data written as text", comment: "Settings › File Types: the files in the structured kind"), views: ["Tree", "Code"]),
        opensAs("log", heading: String(localized: "Documents", comment: "Settings › File Types: group heading"),
                title: String(localized: "Logs", comment: "Settings › File Types: kind name"), files: ".log", views: ["Log", "Text", "Hex"]),
        opensAs("diff", heading: String(localized: "Documents", comment: "Settings › File Types: group heading"),
                title: String(localized: "Diffs and patches", comment: "Settings › File Types: kind name"), files: ".diff, .patch", views: ["Unified", "Split"]),
        opensAs("csv", heading: String(localized: "Data", comment: "Settings › File Types: group heading"),
                title: String(localized: "CSV and TSV", comment: "Settings › File Types: kind name"), files: ".csv, .tsv, .tab", views: ["Table", "Text"]),
        opensAs("sqlite", heading: String(localized: "Data", comment: "Settings › File Types: group heading"),
                title: "SQLite", files: ".sqlite, .db, .sqlite3", views: ["Rows", "Schema"]),
        opensAs("dataset", heading: String(localized: "Data", comment: "Settings › File Types: group heading"),
                title: String(localized: "Datasets", comment: "Settings › File Types: kind name"), files: ".parquet, .arrow, .feather, .xlsx", views: ["Table", "Schema"]),
        opensAs("session", heading: String(localized: "AI", comment: "Settings › File Types: group heading"),
                title: String(localized: "Agent sessions", comment: "Settings › File Types: kind name"), files: "Claude Code, Codex", views: ["Conversation", "Changes", "Source"]),
        opensAs("notebook", heading: String(localized: "AI", comment: "Settings › File Types: group heading"),
                title: String(localized: "Notebooks", comment: "Settings › File Types: kind name"), files: ".ipynb, marimo .py", views: ["Notebook", "Code only", "Source"]),
        opensAs("card", heading: String(localized: "Packages and folders", comment: "Settings › File Types: group heading"),
                title: String(localized: "Apps, installers, disk images", comment: "Settings › File Types: kind name"), files: ".app, .pkg, .dmg, .ipa, .mobileconfig", views: ["Card", "Contents"]),
        opensAs("folder", heading: String(localized: "Packages and folders", comment: "Settings › File Types: group heading"),
                title: String(localized: "Folders", comment: "Settings › File Types: kind name"), files: String(localized: "Git repositories too", comment: "Settings › File Types: the folders kind"), views: ["List", "Icons"]),
        opensAs("image", heading: String(localized: "Everyday", comment: "Settings › File Types: group heading"),
                title: String(localized: "Images", comment: "Settings › File Types: kind name"), files: String(localized: "In the Vitrine window", comment: "Settings › File Types: where this kind shows (Apple keeps Quick Look for it)"), views: ["Image", "Info"]),
        opensAs("font", heading: String(localized: "Everyday", comment: "Settings › File Types: group heading"),
                title: String(localized: "Fonts", comment: "Settings › File Types: kind name"), files: String(localized: "In the Vitrine window", comment: "Settings › File Types: where this kind shows (Apple keeps Quick Look for it)"), views: ["Glyphs", "Text", "Info"]),
        opensAs("svg", heading: String(localized: "Everyday", comment: "Settings › File Types: group heading"),
                title: "SVG", files: String(localized: "In the Vitrine window", comment: "Settings › File Types: where this kind shows (Apple keeps Quick Look for it)"), views: ["Picture", "Source"]),
        opensAs("binary", heading: String(localized: "Everyday", comment: "Settings › File Types: group heading"),
                title: String(localized: "Other binary files", comment: "Settings › File Types: kind name"), files: String(localized: "Anything Vitrine has no reader for", comment: "Settings › File Types: the binary kind"), views: ["Hex", "Strings"]),
        SettingsRow(id: "fileTypes.owners", pane: .fileTypes,
                    group: String(localized: "Who handles them", comment: "Settings › File Types: group heading"),
                    title: String(localized: "Which previewer answers for each type", comment: "Settings › File Types: row that opens Diagnostics"),
                    subtitle: String(localized: "macOS keeps a few types for its own previewers; Diagnostics shows each one and how to fix it", comment: "Settings › File Types: subtitle"),
                    control: .custom),
        // The metadata strip (I-13, settings r3-a): the facts in the capsule's pill. Keys literal here, as MetadataStrip's.
        SettingsRow(id: "strip.show", pane: .general,
                    group: String(localized: "Metadata strip", comment: "Settings › General: group heading (the facts under a preview)"),
                    title: String(localized: "Show the strip", comment: "Settings › General › Metadata strip: row title"),
                    subtitle: String(localized: "Facts under the preview: quiet until you hover, never over the file", comment: "Settings › General › Metadata strip: subtitle"),
                    key: "strip.show", defaultValue: .string("hover"),
                    control: .segmented(options([(.string("hover"), String(localized: "On hover", comment: "Settings › Metadata strip: quiet until the pointer is over it")),
                                                 (.string("always"), String(localized: "Always", comment: "Settings › Metadata strip: always shown")),
                                                 (.string("never"), String(localized: "Never", comment: "Settings › Metadata strip: only the state dot"))]))),
        SettingsRow(id: "general.strip.facts", pane: .general,
                    group: String(localized: "Metadata strip", comment: "Settings › General: group heading (the facts under a preview)"),
                    title: String(localized: "Facts and their order", comment: "Settings › General › Metadata strip: row title"),
                    subtitle: String(localized: "Drag to reorder; click to hide", comment: "Settings › General › Metadata strip: subtitle"),
                    control: .custom),
        SettingsRow(id: SettingsKey.showMenuBarIcon, pane: .general,
                    group: String(localized: "Menu bar", comment: "Settings › General: group heading"),
                    title: String(localized: "Show Vitrine in the menu bar", comment: "Settings › General: row title"),
                    subtitle: String(localized: "Recent previews and extension health, one click away", comment: "Settings › General: subtitle"),
                    key: SettingsKey.showMenuBarIcon, defaultValue: .bool(true), control: .toggle),
        SettingsRow(id: SettingsKey.recordRecents, pane: .general,
                    group: String(localized: "Menu bar", comment: "Settings › General: group heading"),
                    title: String(localized: "Recent previews in the menu", comment: "Settings › General: row title"),
                    subtitle: String(localized: "The last ten files you previewed; when off, what is kept stays until you clear it", comment: "Settings › General: subtitle"),
                    key: SettingsKey.recordRecents, defaultValue: .bool(true), control: .toggle),

        // Appearance
        SettingsRow(id: "appearance.accent", pane: .appearance, group: "Vitrine",
                    title: String(localized: "Accent colour", comment: "Settings › Appearance: row title"),
                    subtitle: String(localized: "Buttons, switches and selections follow your Mac’s accent colour, as Mac apps do. With Multicolor they are sea glass.", comment: "Settings › Appearance: subtitle; Multicolor is the macOS accent colour setting"),
                    control: .custom),
        SettingsRow(id: SettingsKey.markdownTheme, pane: .appearance,
                    group: String(localized: "Markdown themes", comment: "Settings › Appearance: group heading"),
                    title: String(localized: "Markdown theme", comment: "Settings › Appearance: row title"),
                    key: SettingsKey.markdownTheme, defaultValue: .string(MarkdownTheme.defaultID), control: .markdownThemes),
        SettingsRow(id: SettingsKey.markdownTextScale, pane: .appearance,
                    group: String(localized: "Type", comment: "Settings › Appearance: group heading, as in typography"),
                    title: String(localized: "Text size", comment: "Settings › Appearance: row title"),
                    subtitle: String(localized: "Markdown text, from the theme’s own size", comment: "Settings › Appearance: subtitle"),
                    key: SettingsKey.markdownTextScale, defaultValue: .double(1), control: .textScale),
        SettingsRow(id: SettingsKey.codeFont, pane: .appearance,
                    group: String(localized: "Type", comment: "Settings › Appearance: group heading, as in typography"),
                    title: String(localized: "Code font", comment: "Settings › Appearance: row title"),
                    subtitle: String(localized: "SF Mono and the code fonts installed on this Mac", comment: "Settings › Appearance: subtitle; SF Mono is a font name"),
                    key: SettingsKey.codeFont, defaultValue: .string("SF Mono"), control: .codeFont),
        SettingsRow(id: SettingsKey.codeFontSize, pane: .appearance,
                    group: String(localized: "Type", comment: "Settings › Appearance: group heading, as in typography"),
                    title: String(localized: "Code size", comment: "Settings › Appearance: row title"),
                    key: SettingsKey.codeFontSize, defaultValue: .int(12),
                    control: .menu(options((9...24).map { (.int($0), String(localized: "\($0) pt", comment: "Settings › Appearance: a code font size in points")) }))),
        SettingsRow(id: SettingsKey.markdownDiagramTheme, pane: .appearance,
                    group: String(localized: "Diagrams", comment: "Settings › Appearance: the Diagrams group heading and its row's title"),
                    title: String(localized: "Diagrams", comment: "Settings › Appearance: the Diagrams group heading and its row's title"),
                    subtitle: String(localized: "Mermaid colours", comment: "Settings › Appearance: subtitle; Mermaid is the diagram language"),
                    key: SettingsKey.markdownDiagramTheme, defaultValue: .string("theme"),
                    control: .menu(options([(.string("theme"), String(localized: "Follow the theme", comment: "Settings › Diagrams: choice, Mermaid colours follow the Markdown theme")),
                                            (.string("light"), String(localized: "Light", comment: "Settings › Diagrams: choice, light colours")),
                                            (.string("dark"), String(localized: "Dark", comment: "Settings › Diagrams: choice, dark colours"))]))),

        // Markdown
        SettingsRow(id: SettingsKey.markdownTOC, pane: .markdown,
                    group: String(localized: "Opening", comment: "Settings › Markdown: group heading, how a file opens"),
                    title: String(localized: "Contents column", comment: "Settings › Markdown: row title, the table of contents beside the page"),
                    subtitle: String(localized: "Beside the page when it has three or more headings", comment: "Settings › Markdown: subtitle"),
                    key: SettingsKey.markdownTOC, defaultValue: .bool(true), control: .toggle),
        SettingsRow(id: SettingsKey.markdownHideFrontMatter, pane: .markdown,
                    group: String(localized: "Opening", comment: "Settings › Markdown: group heading, how a file opens"),
                    title: String(localized: "Front matter", comment: "Settings › Markdown: row title, the YAML header of a Markdown file"),
                    subtitle: String(localized: "The YAML block at the top of the file", comment: "Settings › Markdown: subtitle"),
                    key: SettingsKey.markdownHideFrontMatter, defaultValue: .bool(true),
                    control: .menu(options([(.bool(true), String(localized: "Hide", comment: "Settings › Front matter: choice")),
                                            (.bool(false), String(localized: "Show as text", comment: "Settings › Front matter: choice"))]))),
        SettingsRow(id: SettingsKey.markdownMath, pane: .markdown,
                    group: String(localized: "Extras", comment: "Settings › Markdown: group heading"),
                    title: String(localized: "Math", comment: "Settings › Markdown: row title, mathematical formulas"),
                    subtitle: String(localized: "KaTeX, bundled", comment: "Settings › Markdown: subtitle; KaTeX is the math renderer"),
                    key: SettingsKey.markdownMath, defaultValue: .bool(true), control: .toggle),
        SettingsRow(id: SettingsKey.markdownEmoji, pane: .markdown,
                    group: String(localized: "Extras", comment: "Settings › Markdown: group heading"),
                    title: String(localized: "Emoji shortcodes", comment: "Settings › Markdown: row title"),
                    subtitle: String(localized: ":rocket: becomes the emoji, outside code", comment: "Settings › Markdown: subtitle; keep :rocket: as written"),
                    key: SettingsKey.markdownEmoji, defaultValue: .bool(true), control: .toggle),
        SettingsRow(id: SettingsKey.markdownSmart, pane: .markdown,
                    group: String(localized: "Extras", comment: "Settings › Markdown: group heading"),
                    title: String(localized: "Smart punctuation", comment: "Settings › Markdown: row title"),
                    subtitle: String(localized: "Curly quotes and dashes", comment: "Settings › Markdown: subtitle"),
                    key: SettingsKey.markdownSmart, defaultValue: .bool(false), control: .toggle),
        SettingsRow(id: SettingsKey.markdownImageWidth, pane: .markdown,
                    group: String(localized: "Images and remote content", comment: "Settings › Markdown: group heading"),
                    title: String(localized: "Image width", comment: "Settings › Markdown: row title"),
                    subtitle: String(localized: "Largest width of an inline image", comment: "Settings › Markdown: subtitle"),
                    key: SettingsKey.markdownImageWidth, defaultValue: .int(100),
                    control: .slider(min: 25, max: 100, step: 5, low: 0.25.formatted(.percent), high: 1.0.formatted(.percent))),

        // Code and Text
        SettingsRow(id: SettingsKey.codeTheme, pane: .code,
                    group: String(localized: "Code themes", comment: "Settings › Code and Text: group heading"),
                    title: String(localized: "Code theme", comment: "Settings › Code and Text: row title"),
                    subtitle: String(localized: "A pair follows your Mac’s light and dark", comment: "Settings › Code and Text: subtitle, a theme pair follows Light and Dark appearance"),
                    key: SettingsKey.codeTheme, defaultValue: .string("vitrine"), control: .codeTheme),
        SettingsRow(id: SettingsKey.codeLineNumbers, pane: .code,
                    group: String(localized: "Editor look", comment: "Settings › Code and Text: group heading"),
                    title: String(localized: "Line numbers", comment: "Settings › Code and Text: row title"),
                    key: SettingsKey.codeLineNumbers, defaultValue: .bool(true), control: .toggle),
        SettingsRow(id: SettingsKey.codeWrap, pane: .code,
                    group: String(localized: "Editor look", comment: "Settings › Code and Text: group heading"),
                    title: String(localized: "Wrap long lines", comment: "Settings › Code and Text: row title"),
                    key: SettingsKey.codeWrap, defaultValue: .bool(false), control: .toggle),
        SettingsRow(id: SettingsKey.codeTabSize, pane: .code,
                    group: String(localized: "Editor look", comment: "Settings › Code and Text: group heading"),
                    title: String(localized: "Tab width", comment: "Settings › Code and Text: row title, spaces per tab"),
                    key: SettingsKey.codeTabSize, defaultValue: .int(4),
                    control: .segmented(options([2, 4, 8].map { (.int($0), $0.formatted()) }))),
        SettingsRow(id: SettingsKey.codeSticky, pane: .code,
                    group: String(localized: "Editor look", comment: "Settings › Code and Text: group heading"),
                    title: String(localized: "Sticky scope headers", comment: "Settings › Code and Text: row title"),
                    subtitle: String(localized: "The function or class you are in stays at the top", comment: "Settings › Code and Text: subtitle"),
                    key: SettingsKey.codeSticky, defaultValue: .bool(true), control: .toggle),
        SettingsRow(id: SettingsKey.codeIndentGuides, pane: .code,
                    group: String(localized: "Editor look", comment: "Settings › Code and Text: group heading"),
                    title: String(localized: "Indent guides", comment: "Settings › Code and Text: row title"),
                    key: SettingsKey.codeIndentGuides, defaultValue: .bool(true), control: .toggle),
        SettingsRow(id: SettingsKey.codeChangedLines, pane: .code,
                    group: String(localized: "Editor look", comment: "Settings › Code and Text: group heading"),
                    title: String(localized: "Changed lines from git", comment: "Settings › Code and Text: row title; git is the version control tool"),
                    subtitle: String(localized: "Marks on the scroll ruler for added and changed lines", comment: "Settings › Code and Text: subtitle"),
                    key: SettingsKey.codeChangedLines, defaultValue: .bool(true), control: .toggle),
        SettingsRow(id: SettingsKey.codeMinimap, pane: .code,
                    group: String(localized: "Editor look", comment: "Settings › Code and Text: group heading"),
                    title: String(localized: "Minimap", comment: "Settings › Code and Text: row title, the small overview of the whole file"),
                    key: SettingsKey.codeMinimap, defaultValue: .bool(false), control: .toggle),

        // Archives and Folders
        SettingsRow(id: SettingsKey.folderIconStyle, pane: .folders,
                    group: String(localized: "Folders", comment: "Settings › Archives and Folders: group heading"),
                    title: String(localized: "Folder contents on the Finder icon", comment: "Settings › Archives and Folders: row title"),
                    subtitle: String(localized: "For folders you choose: right-click one in Finder › Services › Show Contents on Folder Icon", comment: "Settings › Archives and Folders: subtitle; Show Contents on Folder Icon is the Services menu item"),
                    key: SettingsKey.folderIconStyle, defaultValue: .string("fan"),
                    control: .segmented(options([(.string("fan"), String(localized: "Fan", comment: "Settings › Folder icon style: files fanned out")),
                                                 (.string("front"), String(localized: "Front", comment: "Settings › Folder icon style: one file in front")),
                                                 (.string("grid"), String(localized: "Grid", comment: "Settings › Folder icon style: files in a grid"))]))),

        // Privacy
        SettingsRow(id: "privacy.recents", pane: .privacy,
                    group: String(localized: "Kept on this Mac", comment: "Settings › Privacy: group heading"),
                    title: String(localized: "Recent previews", comment: "Settings › Privacy: row title"),
                    subtitle: String(localized: "Path, kind and counts of the last ten files, for the menu bar", comment: "Settings › Privacy: subtitle"),
                    control: .custom),

        // On-device summaries (A-9, G-28): the Summarize offer above text previews; nothing is summarised until the person
        // presses it, and the model runs in VitrineHelper on this Mac. Key matches PreviewKit's SummaryModel.settingKey.
        SettingsRow(id: "summaries.offer", pane: .privacy,
                    group: String(localized: "Kept on this Mac", comment: "Settings › Privacy: group heading"),
                    title: String(localized: "Offer on-device summaries", comment: "Settings › Privacy: row title"),
                    subtitle: String(localized: "A Summarize button above text previews; Apple's model runs on this Mac and nothing leaves it", comment: "Settings › Privacy: subtitle"),
                    key: "summaries.offer", defaultValue: .bool(true), control: .toggle),

        // Vulnerability hints (G-26): off until turned on; the app downloads OSV's whole public list for each ecosystem
        // picked here and checks lockfiles against it on this Mac. Keys match VitrineEngineering.AdvisoryStore's.
        SettingsRow(id: "advisories.enabled", pane: .privacy,
                    group: String(localized: "Vulnerability hints", comment: "Settings › Privacy: group heading"),
                    title: String(localized: "Check lockfiles against known advisories", comment: "Settings › Privacy: row title"),
                    subtitle: String(localized: "Downloads OSV's public advisory lists for the ecosystems you pick; your packages never leave this Mac", comment: "Settings › Privacy: subtitle"),
                    key: "advisories.enabled", defaultValue: .bool(false), control: .toggle),
        SettingsRow(id: "advisories.eco.npm", pane: .privacy,
                    group: String(localized: "Vulnerability hints", comment: "Settings › Privacy: group heading"),
                    title: String(localized: "npm, Yarn, pnpm and Bun", comment: "Settings › Privacy: an ecosystem whose advisory list can be downloaded"),
                    subtitle: String(localized: "About 220 MB to download; most of it describes packages known to be malware", comment: "Settings › Privacy: the download size of an ecosystem's advisory list"),
                    key: "advisories.eco.npm", defaultValue: .bool(false), control: .toggle),
        SettingsRow(id: "advisories.eco.PyPI", pane: .privacy,
                    group: String(localized: "Vulnerability hints", comment: "Settings › Privacy: group heading"),
                    title: String(localized: "Python: pip, Poetry, uv and Pipenv", comment: "Settings › Privacy: an ecosystem whose advisory list can be downloaded"),
                    subtitle: String(localized: "About 38 MB to download", comment: "Settings › Privacy: the download size of an ecosystem's advisory list"),
                    key: "advisories.eco.PyPI", defaultValue: .bool(false), control: .toggle),
        SettingsRow(id: "advisories.eco.crates.io", pane: .privacy,
                    group: String(localized: "Vulnerability hints", comment: "Settings › Privacy: group heading"),
                    title: String(localized: "Rust: Cargo", comment: "Settings › Privacy: an ecosystem whose advisory list can be downloaded"),
                    subtitle: String(localized: "About 4 MB to download", comment: "Settings › Privacy: the download size of an ecosystem's advisory list"),
                    key: "advisories.eco.crates.io", defaultValue: .bool(false), control: .toggle),
        SettingsRow(id: "advisories.eco.Go", pane: .privacy,
                    group: String(localized: "Vulnerability hints", comment: "Settings › Privacy: group heading"),
                    title: String(localized: "Go modules", comment: "Settings › Privacy: an ecosystem whose advisory list can be downloaded"),
                    subtitle: String(localized: "About 13 MB to download", comment: "Settings › Privacy: the download size of an ecosystem's advisory list"),
                    key: "advisories.eco.Go", defaultValue: .bool(false), control: .toggle),
        SettingsRow(id: "advisories.eco.RubyGems", pane: .privacy,
                    group: String(localized: "Vulnerability hints", comment: "Settings › Privacy: group heading"),
                    title: String(localized: "Ruby: Bundler", comment: "Settings › Privacy: an ecosystem whose advisory list can be downloaded"),
                    subtitle: String(localized: "About 5 MB to download", comment: "Settings › Privacy: the download size of an ecosystem's advisory list"),
                    key: "advisories.eco.RubyGems", defaultValue: .bool(false), control: .toggle),
        SettingsRow(id: "advisories.eco.Packagist", pane: .privacy,
                    group: String(localized: "Vulnerability hints", comment: "Settings › Privacy: group heading"),
                    title: String(localized: "PHP: Composer", comment: "Settings › Privacy: an ecosystem whose advisory list can be downloaded"),
                    subtitle: String(localized: "About 11 MB to download", comment: "Settings › Privacy: the download size of an ecosystem's advisory list"),
                    key: "advisories.eco.Packagist", defaultValue: .bool(false), control: .toggle),
        SettingsRow(id: "advisories.eco.SwiftURL", pane: .privacy,
                    group: String(localized: "Vulnerability hints", comment: "Settings › Privacy: group heading"),
                    title: String(localized: "Swift Package Manager", comment: "Settings › Privacy: an ecosystem whose advisory list can be downloaded"),
                    subtitle: String(localized: "Under 1 MB to download", comment: "Settings › Privacy: the download size of an ecosystem's advisory list"),
                    key: "advisories.eco.SwiftURL", defaultValue: .bool(false), control: .toggle),
        SettingsRow(id: "advisories.update", pane: .privacy,
                    group: String(localized: "Vulnerability hints", comment: "Settings › Privacy: group heading"),
                    title: String(localized: "Advisory lists on this Mac", comment: "Settings › Privacy: row title"),
                    subtitle: String(localized: "Downloaded only when you press Update Now, or weekly if you turn that on below", comment: "Settings › Privacy: subtitle"),
                    control: .custom),
        SettingsRow(id: "advisories.weekly", pane: .privacy,
                    group: String(localized: "Vulnerability hints", comment: "Settings › Privacy: group heading"),
                    title: String(localized: "Refresh every week", comment: "Settings › Privacy: row title"),
                    subtitle: String(localized: "When Vitrine opens and the lists are a week old", comment: "Settings › Privacy: subtitle"),
                    key: "advisories.weekly", defaultValue: .bool(false), control: .toggle),

        // About
        SettingsRow(id: SettingsKey.updatesCheckAutomatically, pane: .about,
                    group: String(localized: "Updates", comment: "Settings › About: group heading"),
                    title: String(localized: "Check for updates automatically", comment: "Settings › About: row title"),
                    subtitle: String(localized: "At most once a day; one small signed file, no identifiers sent", comment: "Settings › About: subtitle"),
                    key: SettingsKey.updatesCheckAutomatically, defaultValue: .bool(true), control: .toggle),
        SettingsRow(id: "about.update", pane: .about,
                    group: String(localized: "Updates", comment: "Settings › About: group heading"),
                    title: String(localized: "Check for updates now", comment: "Settings › About: row title"),
                    subtitle: String(localized: "Installs only a release signed by the same developer as this copy", comment: "Settings › About: subtitle"),
                    control: .custom),
        SettingsRow(id: "about.osv", pane: .about,
                    group: String(localized: "Free and open", comment: "Settings › About: group heading, free and open-source software"),
                    title: String(localized: "Vulnerability data", comment: "Settings › About: row title"),
                    subtitle: String(localized: "Advisories from OSV.dev, under each source's licence (CC-BY 4.0 or CC0)", comment: "Settings › About: credit for the vulnerability data"),
                    control: .custom),
        SettingsRow(id: "about.tiktoken", pane: .about,
                    group: String(localized: "Free and open", comment: "Settings › About: group heading, free and open-source software"),
                    title: String(localized: "OpenAI token counts", comment: "Settings › About: row title"),
                    subtitle: String(localized: "o200k word list from tiktoken (MIT, © 2022 OpenAI, Shantanu Jain); no licence stated for the list itself", comment: "Settings › About: credit for the bundled tokenizer data"),
                    control: .custom),
        SettingsRow(id: "about.report", pane: .about,
                    group: String(localized: "Free and open", comment: "Settings › About: group heading, free and open-source software"),
                    title: String(localized: "Report a problem", comment: "Settings › About: row title"),
                    subtitle: String(localized: "Opens Diagnostics with a report you can read before you send it", comment: "Settings › About: subtitle"),
                    control: .custom),
    ]

    static func rows(in pane: SettingsPane) -> [SettingsRow] { rows.filter { $0.pane == pane } }

    /// The pane's groups in order, each with its rows.
    static func groups(in pane: SettingsPane) -> [(name: String, rows: [SettingsRow])] {
        groups(of: rows(in: pane))
    }

    static func groups(of list: [SettingsRow]) -> [(name: String, rows: [SettingsRow])] {
        var out: [(name: String, rows: [SettingsRow])] = []
        for row in list {
            if let i = out.firstIndex(where: { $0.name == row.group }) { out[i].rows.append(row) } else { out.append((row.group, [row])) }
        }
        return out
    }

    /// Rows whose title, subtitle, group or pane holds every word of the query, ignoring case and accents.
    static func search(_ query: String) -> [SettingsRow] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return rows.filter { row in
            let text = [row.title, row.subtitle, row.group, row.pane.title].joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    // MARK: Choices that live elsewhere

    /// The code view's built-in themes and its "More themes", in its order (web-src/code/appearance.js, BUILT_IN and
    /// MORE). The page falls back to the first for an id it does not know.
    static let codeThemes: [(id: String, name: String)] = [
        ("vitrine", String(localized: "Vitrine (auto)", comment: "Settings: the default code theme, which follows light and dark")), ("porcelain", "Porcelain"), ("graphite", "Graphite"), ("harbor", "Harbor"), ("ember", "Ember"),
        ("github", "GitHub"), ("github-hc", "GitHub High Contrast"), ("vscode", "VS Code"), ("one", "One"), ("solarized", "Solarized"),
        ("catppuccin", "Catppuccin"), ("rose-pine", "Rosé Pine"), ("vitesse", "Vitesse"), ("gruvbox", "Gruvbox"),
        ("everforest", "Everforest"), ("ayu", "Ayu"), ("kanagawa", "Kanagawa"), ("night-owl", "Night Owl"), ("min", "Min"),
        ("material", "Material"), ("dracula", "Dracula"), ("nord", "Nord"), ("tokyo-night", "Tokyo Night"), ("monokai", "Monokai"),
    ]
    static let moreCodeThemes: [(id: String, name: String)] = [
        ("github-default", "GitHub Default"), ("github-dimmed", "GitHub Dimmed"), ("horizon", "Horizon"), ("slack", "Slack"),
        ("rose-pine-moon", "Rosé Pine Moon"), ("catppuccin-frappe", "Catppuccin Frappé"), ("catppuccin-macchiato", "Catppuccin Macchiato"),
        ("kanagawa-dragon", "Kanagawa Dragon"), ("gruvbox-hard", "Gruvbox Hard"), ("gruvbox-soft", "Gruvbox Soft"), ("ayu-dark", "Ayu Dark"),
        ("vitesse-black", "Vitesse Black"), ("material-ocean", "Material Ocean"), ("material-palenight", "Material Palenight"),
        ("dracula-soft", "Dracula Soft"), ("poimandres", "Poimandres"), ("vesper", "Vesper"), ("houston", "Houston"),
        ("synthwave-84", "Synthwave ’84"), ("snazzy", "Snazzy Light"), ("andromeeda", "Andromeeda"), ("aurora-x", "Aurora X"),
        ("laserwave", "Laserwave"), ("plastic", "Plastic"),
    ]

    /// The code fonts the code view offers (CodeOptions.installedFonts): SF Mono, then the well-known ones installed.
    static let knownCodeFonts = ["Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Cascadia Code", "IBM Plex Mono", "Source Code Pro",
                                 "Iosevka", "Hack", "Input Mono", "Berkeley Mono", "Commit Mono", "Geist Mono", "PT Mono", "Andale Mono", "Courier New"]

    static func installedCodeFonts(families: Set<String> = Set(NSFontManager.shared.availableFontFamilies)) -> [String] {
        ["SF Mono"] + knownCodeFonts.filter(families.contains)
    }
}

// MARK: - The store

/// The window's view of one defaults store: typed reads with the readers' fallbacks, writes, Reset, and "changed by
/// you". The app passes `VitrineDefaults.shared`; tests and snapshots pass a private suite.
@MainActor
final class SettingsStore: ObservableObject {
    let defaults: UserDefaults
    private var observer: AnyCancellable?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        // Changes made elsewhere (a preview's own Aa menu, folded back by SettingsBridge; the menu's Pause Recents)
        // redraw the window.
        observer = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// The stored value, or the row's default when nothing (or something of another type) is stored.
    func value(_ row: SettingsRow) -> SettingsValue? {
        guard let key = row.key, let fallback = row.defaultValue else { return nil }
        return SettingsValue(defaults.object(forKey: key), like: fallback) ?? fallback
    }

    func set(_ value: SettingsValue, for row: SettingsRow) {
        guard let key = row.key else { return }
        objectWillChange.send()
        defaults.set(value.object, forKey: key)
    }

    /// Back to the default: the key is removed, so the reader's own fallback applies.
    func reset(_ row: SettingsRow) {
        guard let key = row.key else { return }
        objectWillChange.send()
        defaults.removeObject(forKey: key)
    }

    /// Stored and different from the default.
    func isChanged(_ row: SettingsRow) -> Bool {
        guard let key = row.key, let fallback = row.defaultValue, let stored = SettingsValue(defaults.object(forKey: key), like: fallback) else { return false }
        return stored != fallback
    }

    var changedRows: [SettingsRow] { SettingsCatalog.rows.filter(isChanged) }

    func bool(_ key: String) -> Bool {
        guard let row = SettingsCatalog.rows.first(where: { $0.key == key }) else { return false }
        return value(row)?.bool ?? false
    }

    func string(_ key: String) -> String {
        guard let row = SettingsCatalog.rows.first(where: { $0.key == key }) else { return "" }
        return value(row)?.string ?? ""
    }

    func number(_ key: String) -> Double {
        guard let row = SettingsCatalog.rows.first(where: { $0.key == key }) else { return 0 }
        return value(row)?.double ?? 0
    }

    // MARK: Facts for the window

    /// Themes the person imported in the code view (`code.importedThemes`), by id and name only.
    var importedCodeThemes: [(id: String, name: String)] {
        struct Named: Decodable { let id: String; let name: String }
        guard let data = defaults.data(forKey: SettingsKey.codeImportedThemes),
              let list = try? JSONDecoder().decode([Named].self, from: data) else { return [] }
        return list.map { ($0.id, $0.name) }
    }

    func codeThemeName(_ id: String) -> String {
        if let t = (SettingsCatalog.codeThemes + SettingsCatalog.moreCodeThemes).first(where: { $0.id == id }) { return t.name }
        if let t = importedCodeThemes.first(where: { $0.id == id }) { return t.name }
        return SettingsCatalog.codeThemes[0].name
    }

    var markdownTheme: MarkdownTheme { MarkdownTheme.theme(id: string(SettingsKey.markdownTheme)) }

    var chosenFolderCount: Int { defaults.stringArray(forKey: SettingsKey.folderIconList)?.count ?? 0 }
}
