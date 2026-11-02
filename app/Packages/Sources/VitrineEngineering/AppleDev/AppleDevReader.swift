import Foundation
import VitrineBinary

/// What `AppleDevReader` found in an Apple development file (E-5): one summary per format, each with a headline,
/// facts, its tables and its warnings for the card. roadmap: S-22
public enum AppleDevDocument: Sendable, Equatable {
    case stringCatalog(StringCatalogSummary)
    case assetCatalog(AssetCatalogSummary)
    case infoPlist(InfoPlistSummary)
    case entitlements(EntitlementsSummary)
    case crashReport(CrashReportSummary)
    case xcodeArchive(XcodeArchiveSummary)

    /// One line naming what the file is, for the card's title row.
    public var headline: String {
        switch self {
        case .stringCatalog(let s): s.headline
        case .assetCatalog(let s): s.headline
        case .infoPlist(let s): s.headline
        case .entitlements(let s): s.headline
        case .crashReport(let s): s.headline
        case .xcodeArchive(let s): s.headline
        }
    }

    /// The label and value pairs the card lists under the headline.
    public var facts: [AppleDevFact] {
        switch self {
        case .stringCatalog(let s): s.facts
        case .assetCatalog(let s): s.facts
        case .infoPlist(let s): s.facts
        case .entitlements(let s): s.facts
        case .crashReport(let s): s.facts
        case .xcodeArchive(let s): s.facts
        }
    }

    /// What deserves the reader's attention, most serious first.
    public var warnings: [AppleDevWarning] {
        switch self {
        case .stringCatalog(let s): s.warnings
        case .assetCatalog(let s): s.warnings
        case .infoPlist(let s): s.warnings
        case .entitlements(let s): s.warnings
        case .crashReport(let s): s.warnings
        case .xcodeArchive(let s): s.warnings
        }
    }
}

/// One label and value for a card's fact list ("Bundle ID" → "com.example.notes"). roadmap: S-22
public struct AppleDevFact: Sendable, Equatable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Something in an Apple development file worth a second look, with the reason in plain English.
/// roadmap: S-22
public struct AppleDevWarning: Sendable, Equatable {
    /// `caution`: worth knowing, usually fine on purpose. `danger`: likely to break the app or weaken its security.
    /// roadmap: S-22
    public enum Level: String, Sendable, Equatable, Comparable {
        case caution, danger

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs == .caution && rhs == .danger }
    }

    public var level: Level
    public var reason: String

    public init(_ level: Level, _ reason: String) {
        self.level = level
        self.reason = reason
    }
}

/// Reads Apple development files for the E-5 cards: String Catalogs (`.xcstrings`), asset catalogs (`.xcassets`
/// folders), Info.plist files, `.entitlements` files, crash reports (`.ips`, legacy `.crash`) and Xcode archives
/// (`.xcarchive` folders). Every input is untrusted: files above `maxBytes` are refused, every list and walk is
/// bounded and says when it stopped (`truncated`), nesting is bounded, nothing is fetched or started, and a folder
/// is read only inside itself (symbolic links are never followed, only `Contents.json` and property lists of at most
/// `maxSmallFileBytes` are opened). Damaged input gives nil or a partial summary with a warning, never a crash.
/// roadmap: S-22
public enum AppleDevReader {
    /// The most bytes of one file read through `read(data:fileName:)`; larger inputs give nil.
    public static let maxBytes = 16 * 1024 * 1024
    /// The deepest a folder walk goes below the folder it was given.
    public static let maxDepth = 8
    /// The most files and folders one folder walk visits.
    public static let maxEntries = 5_000
    /// The largest `Contents.json`, Info.plist or profile opened inside a folder.
    public static let maxSmallFileBytes = 1024 * 1024

    /// File extensions (lowercased) `read(data:fileName:)` recognises by name.
    public static let fileExtensions: Set<String> = ["xcstrings", "plist", "entitlements", "ips", "crash"]
    /// Folder extensions (lowercased) `read(directory:)` recognises by name.
    public static let directoryExtensions: Set<String> = ["xcassets", "xcarchive"]

    /// A file's summary, chosen by its name first and by its content where the name does not decide. nil when the
    /// bytes are not one of the formats above, are larger than `maxBytes`, or are too damaged to say anything.
    public static func read(data: Data, fileName: String) -> AppleDevDocument? {
        guard data.count <= maxBytes, !data.isEmpty else { return nil }
        let name = (fileName as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "xcstrings":
            return StringCatalogReader.read(data).map(AppleDevDocument.stringCatalog)
        case "ips", "crash":
            return CrashReportReader.read(data).map(AppleDevDocument.crashReport)
        case "entitlements":
            return EntitlementsReader.read(data).map(AppleDevDocument.entitlements)
        case "plist":
            return readPropertyList(data, name: name)
        default:
            if name.lowercased() == "info.plist" { return readPropertyList(data, name: name) }
            if let first = data.first(where: { !Self.isSpace($0) }) {
                if first == UInt8(ascii: "{"), let crash = CrashReportReader.read(data), crash.format == .json {
                    return .crashReport(crash)
                }
                if CrashReportReader.looksLikeLegacyText(data), let crash = CrashReportReader.read(data) {
                    return .crashReport(crash)
                }
            }
            return nil
        }
    }

    /// A folder's summary: an asset catalog or an Xcode archive, chosen by the folder's extension first and by
    /// what is inside it otherwise. nil when the folder is neither or cannot be read.
    public static func read(directory: URL) -> AppleDevDocument? {
        let folder = AppleDevFolder(root: directory)
        guard folder.rootIsDirectory else { return nil }
        switch directory.pathExtension.lowercased() {
        case "xcassets": return .assetCatalog(AssetCatalogReader.read(folder))
        case "xcarchive": return .xcodeArchive(XcodeArchiveReader.read(folder))
        default:
            // Sniffing spends part of the walk budget, so each read starts from a fresh walk.
            if XcodeArchiveReader.looksLikeArchive(folder) {
                return .xcodeArchive(XcodeArchiveReader.read(AppleDevFolder(root: directory)))
            }
            if AssetCatalogReader.looksLikeCatalog(folder) {
                return .assetCatalog(AssetCatalogReader.read(AppleDevFolder(root: directory)))
            }
            return nil
        }
    }

    /// A `.plist`: an Info.plist when its name or keys say so, an entitlements list when every key is one, else nil.
    static func readPropertyList(_ data: Data, name: String) -> AppleDevDocument? {
        guard let (plist, format) = AppleDevPlist.dictionary(data) else { return nil }
        let lower = name.lowercased()
        if lower.hasSuffix("info.plist") || InfoPlistReader.looksLikeInfoPlist(plist) {
            return .infoPlist(InfoPlistReader.summary(plist, format: format))
        }
        if EntitlementsReader.looksLikeEntitlements(plist) {
            return .entitlements(EntitlementsReader.summary(plist))
        }
        return nil
    }

    static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
}

// MARK: - Shared helpers

/// Small, bounded readers of untrusted property lists and JSON shared by the E-5 readers.
enum AppleDevPlist {
    /// The top-level dictionary of a property list (XML, binary or OpenStep) and its format.
    static func dictionary(_ data: Data) -> ([String: PlistValue], InfoPlistSummary.Format)? {
        guard data.count <= AppleDevReader.maxBytes else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              let value = PlistValue(propertyList: object), let dict = value.dictionaryValue else { return nil }
        let out: InfoPlistSummary.Format = switch format {
        case .binary: .binary
        case .openStep: .openStep
        default: .xml
        }
        return (dict, out)
    }
}

enum AppleDevJSON {
    /// A top-level JSON object, or nil. Foundation's parser bounds its own nesting.
    static func object(_ data: Data) -> [String: Any]? {
        guard data.count <= AppleDevReader.maxBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    /// A string, or a number written as one.
    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: s
        case let n as NSNumber: CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : n.stringValue
        default: nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber:
            CFGetTypeID(n) == CFBooleanGetTypeID() ? nil : (n.doubleValue.isFinite && abs(n.doubleValue) < 9e18 ? n.intValue : nil)
        case let s as String: Int(s)
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let n as NSNumber: n.boolValue
        case let s as String: s == "true" || s == "YES" ? true : (s == "false" || s == "NO" ? false : nil)
        default: nil
        }
    }
}

enum AppleDevText {
    /// "German (de)" for a language code, from English names so the reason reads the same everywhere.
    static func languageName(_ code: String) -> String {
        if let name = Locale.current.localizedString(forIdentifier: code), name != code {
            return String(localized: "\(name) (\(code))", bundle: .module,
                          comment: "A language in a String Catalog: its name, then its code in parentheses, like “German (de)”.")
        }
        return code
    }

    /// A short, single-line version of an untrusted string for a fact or a reason.
    static func clip(_ s: String, _ limit: Int = 200) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
