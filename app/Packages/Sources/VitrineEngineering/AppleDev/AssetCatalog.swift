import Foundation

/// An asset catalog (`.xcassets` folder): its image sets, app icon sets, color sets (each color resolved per
/// appearance), data sets and symbol sets, with every variant (idiom, scale, size, appearance) for a grid, and the
/// files a `Contents.json` names that are not there. Only `Contents.json` files are opened; image and data files are
/// listed by name, never read. roadmap: S-22
public struct AssetCatalogSummary: Sendable, Equatable {
    /// The most assets listed; the rest are still counted in `kindCounts` while the walk lasts.
    public static let maxAssets = 5_000

    /// What an asset folder holds, from its extension. roadmap: S-22
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case image = "imageset", appIcon = "appiconset", color = "colorset", data = "dataset", symbol = "symbolset"
        case other

        /// Plain words for a heading ("Image sets").
        public var label: String {
            switch self {
            case .image: String(localized: "Image sets", bundle: .module, comment: "Kind of asset in an asset catalog (Xcode's term).")
            case .appIcon: String(localized: "App icons", bundle: .module, comment: "Kind of asset in an asset catalog.")
            case .color: String(localized: "Colors", bundle: .module, comment: "Kind of asset in an asset catalog: color sets.")
            case .data: String(localized: "Data sets", bundle: .module, comment: "Kind of asset in an asset catalog (Xcode's term).")
            case .symbol: String(localized: "Symbols", bundle: .module, comment: "Kind of asset in an asset catalog: custom SF Symbols.")
            case .other: String(localized: "Other assets", bundle: .module, comment: "Kind of asset in an asset catalog: anything else.")
            }
        }
    }

    /// One image, icon, data or symbol file slot a `Contents.json` describes. roadmap: S-22
    public struct Variant: Sendable, Equatable {
        public var filename: String?
        /// The file named is in the asset's folder; nil when the slot names no file (an empty well in Xcode).
        public var fileExists: Bool?
        /// universal, iphone, ipad, mac, watch, tv, vision, car, ios-marketing …
        public var idiom: String?
        /// "1x", "2x", "3x".
        public var scale: String?
        /// An icon's size in points ("60x60", "1024x1024").
        public var size: String?
        public var platform: String?
        public var subtype: String?
        public var role: String?
        public var displayGamut: String?
        /// "dark", "light", "high contrast"; empty for the any-appearance slot.
        public var appearances: [String]
        /// A data set's content type.
        public var contentType: String?
    }

    /// One color of a color set, for one appearance. Components are 0…1 in the stated color space (not converted).
    /// roadmap: S-22
    public struct ColorVariant: Sendable, Equatable {
        public var idiom: String?
        public var appearances: [String]
        public var displayGamut: String?
        /// srgb, display-p3, extended-srgb, extended-linear-srgb, gray-gamma-22, extended-gray …
        public var colorSpace: String?
        public var red: Double?
        public var green: Double?
        public var blue: Double?
        public var alpha: Double?
        /// A system color the set points at instead of components ("systemBlueColor").
        public var systemColor: String?

        /// "#RRGGBB" (components clamped to 0…1), nil for a system color or missing components.
        public var hex: String? {
            guard let red, let green, let blue else { return nil }
            func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
            return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        }
    }

    /// One asset folder. roadmap: S-22
    public struct Asset: Sendable, Equatable {
        /// The name code uses: the folder name without its extension, behind any namespace folders ("Icons/Star").
        public var name: String
        /// The folder's path inside the catalog.
        public var path: String
        public var kind: Kind
        /// The folder's extension ("imageset", "launchimage" …).
        public var typeExtension: String
        public var variants: [Variant]
        public var colors: [ColorVariant]
        /// The files in the folder (not Contents.json), by name.
        public var files: [String]
        /// Files `Contents.json` names that the folder does not have.
        public var missingFiles: [String]
        /// Files in the folder no slot names.
        public var unreferencedFiles: [String]
        /// Selected properties ("template-rendering-intent" → "template", "preserves-vector-representation" → "true").
        public var properties: [String: String]
    }

    public var assets: [Asset]
    /// Assets per kind, over every asset the walk reached.
    public var kindCounts: [Kind: Int]
    /// Plain group folders (and containers such as sprite atlases) walked through.
    public var groupCount: Int
    /// Missing files over all assets.
    public var missingFileCount: Int
    /// The walk stopped at its depth or entry cap, or more than `maxAssets` assets exist.
    public var truncated: Bool
    public var warnings: [AppleDevWarning]

    public var headline: String {
        let n = kindCounts.values.reduce(0, +)
        return String(localized: "Asset catalog — \(n) assets", bundle: .module, comment: "Headline of an asset catalog card: how many assets it holds.")
    }

    public var facts: [AppleDevFact] {
        var out: [AppleDevFact] = []
        for kind in Kind.allCases { if let n = kindCounts[kind], n > 0 { out.append(.init(kind.label, n.formatted())) } }
        if groupCount > 0 {
            out.append(.init(String(localized: "Groups", bundle: .module, comment: "Fact label on an asset catalog card: folders that group assets."), groupCount.formatted()))
        }
        out.append(.init(String(localized: "Variants", bundle: .module, comment: "Fact label on an asset catalog card: image, icon and color variants (scales, appearances, devices)."),
                         assets.reduce(0) { $0 + $1.variants.count + $1.colors.count }.formatted()))
        if missingFileCount > 0 {
            out.append(.init(String(localized: "Missing files", bundle: .module, comment: "Fact label on an asset catalog card: files Contents.json names that are not there."),
                             missingFileCount.formatted()))
        }
        return out
    }
}

enum AssetCatalogReader {
    static let kinds: [String: AssetCatalogSummary.Kind] = [
        "imageset": .image, "appiconset": .appIcon, "colorset": .color, "dataset": .data, "symbolset": .symbol,
    ]
    /// Asset folders that are listed as `other`, without looking inside.
    static let otherAssets: Set<String> = [
        "launchimage", "stickersequence", "sticker", "textureset", "cubetextureset", "mipmapset", "arimageset",
        "arobject", "iconset", "imagestacklayer", "solidimagestacklayer", "gcleaderboard", "gcdashboardimage",
        "gcleaderboardset", "gcachievement", "symbolimageset", "appicon", "icon",
    ]
    /// Folders that hold assets like a group does.
    static let containers: Set<String> = [
        "spriteatlas", "complicationset", "brandassets", "imagestack", "stickerpack", "arresourcegroup",
    ]

    static let maxWarnings = 50

    final class State {
        var assets: [AssetCatalogSummary.Asset] = []
        var counts: [AssetCatalogSummary.Kind: Int] = [:]
        var groups = 0
        var missing = 0
        var tooMany = false
        var warnings: [AppleDevWarning] = []
        var linksSkipped = 0

        func warn(_ w: AppleDevWarning) {
            if warnings.count < maxWarnings { warnings.append(w) }
        }
    }

    static func looksLikeCatalog(_ folder: AppleDevFolder) -> Bool {
        guard folder.entry("Contents.json", in: folder.root)?.isRegularFile == true else { return false }
        return folder.children(of: folder.root, depth: 1).contains { entry in
            let ext = (entry.name as NSString).pathExtension.lowercased()
            return entry.isDirectory && (kinds[ext] != nil || containers.contains(ext))
        }
    }

    static func read(_ folder: AppleDevFolder) -> AssetCatalogSummary {
        let state = State()
        walk(folder.root, depth: 1, namespace: [], folder: folder, state: state)
        var warnings = state.warnings
        if state.linksSkipped > 0 {
            let n = state.linksSkipped
            warnings.append(.init(.caution, String(
                localized: "\(n) symbolic links inside the catalog were not followed.",
                bundle: .module, comment: "Warning on an asset catalog card: links are skipped so the preview stays inside the folder.")))
        }
        let truncated = folder.truncated || state.tooMany
        if truncated {
            let entries = AppleDevReader.maxEntries, depth = AppleDevReader.maxDepth
            warnings.append(.init(.caution, String(
                localized: "The catalog is larger than the preview reads (\(entries) entries, \(depth) folders deep); what is shown is part of it.",
                bundle: .module, comment: "Warning on an asset catalog card. Arguments: the entry limit and the folder depth limit.")))
        }
        return AssetCatalogSummary(assets: state.assets, kindCounts: state.counts, groupCount: state.groups,
                                   missingFileCount: state.missing, truncated: truncated,
                                   warnings: warnings.sorted { $0.level > $1.level })
    }

    static func walk(_ directory: URL, depth: Int, namespace: [String], folder: AppleDevFolder, state: State) {
        for entry in folder.children(of: directory, depth: depth) {
            if entry.isSymbolicLink { state.linksSkipped += 1; continue }
            guard entry.isDirectory, !entry.name.hasPrefix(".") else { continue }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            let base = (entry.name as NSString).deletingPathExtension
            if let kind = kinds[ext] {
                asset(entry, kind: kind, ext: ext, name: (namespace + [base]).joined(separator: "/"), depth: depth + 1,
                      folder: folder, state: state)
            } else if otherAssets.contains(ext) {
                asset(entry, kind: .other, ext: ext, name: (namespace + [base]).joined(separator: "/"), depth: depth + 1,
                      folder: folder, state: state)
            } else {
                // A group or a container: its Contents.json may give it a namespace.
                state.groups += 1
                var providesNamespace = false
                if case .data(let data) = folder.read(entry.url.appendingPathComponent("Contents.json")),
                   let json = AppleDevJSON.object(data),
                   let props = json["properties"] as? [String: Any] {
                    providesNamespace = AppleDevJSON.bool(props["provides-namespace"]) == true
                }
                walk(entry.url, depth: depth + 1, namespace: providesNamespace ? namespace + [base] : namespace,
                     folder: folder, state: state)
            }
        }
    }

    static func asset(_ entry: AppleDevFolder.Entry, kind: AssetCatalogSummary.Kind, ext: String, name: String, depth: Int,
                      folder: AppleDevFolder, state: State) {
        state.counts[kind, default: 0] += 1
        guard state.assets.count < AssetCatalogSummary.maxAssets else { state.tooMany = true; return }
        let children = folder.children(of: entry.url, depth: depth)
        let files = children.filter { !$0.isDirectory && !$0.name.hasPrefix(".") && $0.name != "Contents.json" }.map(\.name)
        let present = Set(files.map { $0.lowercased() })
        let path = folder.relativePath(entry.url)

        var json: [String: Any] = [:]
        switch folder.read(entry.url.appendingPathComponent("Contents.json")) {
        case .data(let data):
            if let object = AppleDevJSON.object(data) { json = object } else {
                state.warn(.init(.caution, String(
                    localized: "“\(path)/Contents.json” is not valid JSON, so Xcode cannot read this asset.",
                    bundle: .module, comment: "Warning on an asset catalog card; the argument is the asset folder's path. Contents.json is a file name and stays as is.")))
            }
        case .missing:
            state.warn(.init(.caution, String(
                localized: "“\(path)” has no Contents.json, so Xcode does not know what its files are for.",
                bundle: .module, comment: "Warning on an asset catalog card; the argument is the asset folder's path. Contents.json is a file name and stays as is.")))
        case .tooLarge(let size):
            let bytes = Int(clamping: size)
            state.warn(.init(.caution, String(
                localized: "“\(path)/Contents.json” is \(bytes) bytes, more than the preview reads.",
                bundle: .module, comment: "Warning on an asset catalog card. Arguments: the asset folder's path and the file's size in bytes.")))
        case .notAFile:
            state.warn(.init(.caution, String(
                localized: "“\(path)/Contents.json” is not a regular file and was not read.",
                bundle: .module, comment: "Warning on an asset catalog card: the file is a link, folder or device, which the preview does not open.")))
        }

        func exists(_ name: String?) -> Bool? {
            guard let name else { return nil }
            return !name.contains("/") && present.contains(name.lowercased())
        }
        let listKey: String? = switch kind {
        case .image, .appIcon: "images"
        case .data: "data"
        case .symbol: "symbols"
        case .color: nil
        case .other: json["images"] != nil ? "images" : nil
        }
        var variants: [AssetCatalogSummary.Variant] = []
        if let listKey {
            for case let item as [String: Any] in (json[listKey] as? [Any] ?? []).prefix(1_000) {
                let filename = AppleDevJSON.string(item["filename"])
                variants.append(.init(
                    filename: filename, fileExists: exists(filename), idiom: AppleDevJSON.string(item["idiom"]),
                    scale: AppleDevJSON.string(item["scale"]), size: AppleDevJSON.string(item["size"]),
                    platform: AppleDevJSON.string(item["platform"]), subtype: AppleDevJSON.string(item["subtype"]),
                    role: AppleDevJSON.string(item["role"]), displayGamut: AppleDevJSON.string(item["display-gamut"]),
                    appearances: appearances(item["appearances"]),
                    contentType: AppleDevJSON.string(item["universal-type-identifier"])))
            }
        }
        var colors: [AssetCatalogSummary.ColorVariant] = []
        if kind == .color {
            for case let item as [String: Any] in (json["colors"] as? [Any] ?? []).prefix(1_000) {
                colors.append(color(item))
            }
        }
        var properties: [String: String] = [:]
        if let props = json["properties"] as? [String: Any] {
            for (key, value) in props.prefix(50) {
                if let s = AppleDevJSON.string(value) { properties[key] = AppleDevText.clip(s, 120) }
                else if let b = AppleDevJSON.bool(value) { properties[key] = b ? "true" : "false" }
            }
        }

        let named = variants.compactMap(\.filename)
        let missing = Array(Set(named.filter { exists($0) == false })).sorted()
        let namedSet = Set(named.map { $0.lowercased() })
        let unreferenced = kind == .other ? [] : files.filter { !namedSet.contains($0.lowercased()) }

        if !missing.isEmpty {
            state.missing += missing.count
            let count = missing.count
            let files = missing.prefix(3).joined(separator: ", ") + (missing.count > 3 ? ", …" : "")
            state.warn(.init(.caution, String(
                localized: "“\(name)” names \(count) files that are not in its folder (\(files)). Xcode reports this when building, and the app goes without them.",
                bundle: .module, comment: "Warning on an asset catalog card. Arguments: the asset's name, how many files are missing, then their names.")))
        }
        if !json.isEmpty {
            if kind == .image || kind == .appIcon, named.isEmpty {
                state.warn(.init(.caution, String(localized: "“\(name)” has no image files assigned, so it is empty in the app.", bundle: .module,
                                                  comment: "Warning on an asset catalog card; the argument is an image set's or app icon's name.")))
            }
            if kind == .data, named.isEmpty {
                state.warn(.init(.caution, String(localized: "“\(name)” has no data files assigned, so it is empty in the app.", bundle: .module,
                                                  comment: "Warning on an asset catalog card; the argument is a data set's name.")))
            }
            if kind == .symbol, named.isEmpty {
                state.warn(.init(.caution, String(localized: "“\(name)” has no symbol files assigned, so it is empty in the app.", bundle: .module,
                                                  comment: "Warning on an asset catalog card; the argument is a symbol set's name.")))
            }
            if kind == .color, colors.isEmpty {
                state.warn(.init(.caution, String(localized: "“\(name)” defines no colors.", bundle: .module,
                                                  comment: "Warning on an asset catalog card; the argument is a color set's name.")))
            }
        }

        state.assets.append(.init(name: name, path: path, kind: kind, typeExtension: ext, variants: variants, colors: colors,
                                  files: Array(files.prefix(1_000)), missingFiles: missing,
                                  unreferencedFiles: Array(unreferenced.prefix(1_000)), properties: properties))
    }

    /// `[{"appearance": "luminosity", "value": "dark"}]` → ["dark"], in the reader's language; values Xcode does not
    /// write are kept as the file has them.
    static func appearances(_ raw: Any?) -> [String] {
        (raw as? [Any] ?? []).prefix(8).compactMap { item in
            guard let d = item as? [String: Any], let value = AppleDevJSON.string(d["value"]) else { return nil }
            switch (AppleDevJSON.string(d["appearance"]), value) {
            case ("luminosity", "dark"): return String(localized: "dark", bundle: .module, comment: "An asset variant's appearance: Dark Mode.")
            case ("luminosity", "light"): return String(localized: "light", bundle: .module, comment: "An asset variant's appearance: Light Mode.")
            case ("contrast", "high"): return String(localized: "high contrast", bundle: .module, comment: "An asset variant's appearance: Increase Contrast is on.")
            case (let kind?, _) where kind != "luminosity": return "\(kind) \(value)"
            default: return value
            }
        }
    }

    static func color(_ item: [String: Any]) -> AssetCatalogSummary.ColorVariant {
        let color = item["color"] as? [String: Any] ?? [:]
        let components = color["components"] as? [String: Any] ?? [:]
        var red = component(components["red"]), green = component(components["green"]), blue = component(components["blue"])
        if red == nil, green == nil, blue == nil, let white = component(components["white"]) {
            red = white; green = white; blue = white
        }
        return .init(idiom: AppleDevJSON.string(item["idiom"]), appearances: appearances(item["appearances"]),
                     displayGamut: AppleDevJSON.string(item["display-gamut"]),
                     colorSpace: AppleDevJSON.string(color["color-space"]), red: red, green: green, blue: blue,
                     alpha: component(components["alpha"], isAlpha: true),
                     systemColor: AppleDevJSON.string(color["reference"]))
    }

    /// Xcode writes components as floats ("0.502"), 8-bit integers ("128") or hex ("0x80"); all become 0…1.
    static func component(_ raw: Any?, isAlpha: Bool = false) -> Double? {
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return n.doubleValue.isFinite ? n.doubleValue : nil
        }
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.lowercased().hasPrefix("0x") {
            return UInt64(s.dropFirst(2), radix: 16).map { Double(min($0, 255)) / 255 }
        }
        if s.contains(".") || s.lowercased().contains("e") {
            return Double(s).flatMap { $0.isFinite ? $0 : nil }
        }
        guard let i = Int(s) else { return nil }
        if isAlpha, i <= 1 { return Double(max(i, 0)) }
        return Double(min(max(i, 0), 255)) / 255
    }
}
