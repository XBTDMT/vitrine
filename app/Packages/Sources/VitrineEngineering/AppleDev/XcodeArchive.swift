import Foundation
import VitrineBinary

/// An Xcode archive (`.xcarchive` folder): what its Info.plist says about the app (bundle ID, version, build,
/// signing identity, team), when and from which scheme it was made, the products it holds, how many dSYMs came with
/// it, and the main app's embedded provisioning profile when it has one (read with VitrineBinary). Only the archive's
/// Info.plist and that profile are opened; everything else is listed by name. roadmap: S-22
public struct XcodeArchiveSummary: Sendable, Equatable {
    /// The most products listed.
    public static let maxProducts = 500

    /// One built product inside `Products/`. roadmap: S-22
    public struct Product: Sendable, Equatable {
        /// What a product is, from its extension. roadmap: S-22
        public enum Kind: String, Sendable, Equatable {
            case application, framework, appExtension, xpcService, bundle, tool, library
            case other

            /// The kind in the reader's language (the raw value is a stable id).
            public var label: String {
                switch self {
                case .application: String(localized: "application", bundle: .module, comment: "Kind of product in an Xcode archive.")
                case .framework: String(localized: "framework", bundle: .module, comment: "Kind of product in an Xcode archive.")
                case .appExtension: String(localized: "app extension", bundle: .module, comment: "Kind of product in an Xcode archive.")
                case .xpcService: String(localized: "XPC service", bundle: .module, comment: "Kind of product in an Xcode archive.")
                case .bundle: String(localized: "bundle", bundle: .module, comment: "Kind of product in an Xcode archive: a plug-in or other loadable bundle.")
                case .tool: String(localized: "command-line tool", bundle: .module, comment: "Kind of product in an Xcode archive.")
                case .library: String(localized: "library", bundle: .module, comment: "Kind of product in an Xcode archive.")
                case .other: String(localized: "other", bundle: .module, comment: "Kind of product in an Xcode archive: anything else.")
                }
            }
        }

        /// The path inside `Products/` ("Applications/Notes Lite.app").
        public var path: String
        public var kind: Kind
        public var name: String { (path as NSString).lastPathComponent }
    }

    /// `Name`: the archive's name in the Organizer.
    public var name: String?
    public var schemeName: String?
    public var creationDate: Date?
    public var archiveVersion: Int?
    public var comment: String?
    public var bundleIdentifier: String?
    public var shortVersion: String?
    public var buildVersion: String?
    public var signingIdentity: String?
    public var team: String?
    public var architectures: [String]
    /// `ApplicationPath` inside `Products/`.
    public var applicationPath: String?
    public var products: [Product]
    public var dsymCount: Int
    /// dSYM bundle names, at most `maxProducts`.
    public var dsyms: [String]
    /// The main app's embedded provisioning profile, when it has one that could be read.
    public var profile: ProvisioningProfile?
    /// The walk stopped at its depth or entry cap, or more than `maxProducts` products exist.
    public var truncated: Bool
    public var warnings: [AppleDevWarning]

    public var headline: String {
        let title = name ?? bundleIdentifier
            ?? String(localized: "Archive", bundle: .module, comment: "Xcode archive card headline when the archive names no app.")
        if let shortVersion, let buildVersion {
            return String(localized: "Xcode archive — \(title) \(shortVersion) (\(buildVersion))", bundle: .module,
                          comment: "Headline of an Xcode archive card: the archive's name, version and build.")
        }
        if let version = shortVersion ?? buildVersion {
            return String(localized: "Xcode archive — \(title) \(version)", bundle: .module,
                          comment: "Headline of an Xcode archive card: the archive's name and version.")
        }
        return String(localized: "Xcode archive — \(title)", bundle: .module, comment: "Headline of an Xcode archive card: the archive's name.")
    }

    public var facts: [AppleDevFact] {
        var out: [AppleDevFact] = []
        func add(_ label: String, _ value: String?) { if let value, !value.isEmpty { out.append(.init(label, value)) } }
        add(String(localized: "Name", bundle: .module, comment: "Fact label on an Xcode archive card: the archive's name."), name)
        add(String(localized: "Bundle ID", bundle: .module, comment: "Fact label on an Xcode archive card."), bundleIdentifier)
        add(String(localized: "Version", bundle: .module, comment: "Fact label on an Xcode archive card."), shortVersion)
        add(String(localized: "Build", bundle: .module, comment: "Fact label on an Xcode archive card: the build number."), buildVersion)
        add(String(localized: "Scheme", bundle: .module, comment: "Fact label on an Xcode archive card: the Xcode scheme it was built from."), schemeName)
        add(String(localized: "Created", bundle: .module, comment: "Fact label on an Xcode archive card: when it was made."),
            creationDate.map { $0.formatted(date: .abbreviated, time: .shortened) })
        add(String(localized: "Signing identity", bundle: .module, comment: "Fact label on an Xcode archive card: the certificate it was signed with."), signingIdentity)
        add(String(localized: "Team", bundle: .module, comment: "Fact label on an Xcode archive card: the developer team ID."), team)
        add(String(localized: "Architectures", bundle: .module, comment: "Fact label on an Xcode archive card: arm64, x86_64 and so on."),
            architectures.isEmpty ? nil : architectures.joined(separator: ", "))
        add(String(localized: "Products", bundle: .module, comment: "Fact label on an Xcode archive card: the apps and tools it holds."),
            products.isEmpty ? nil : products.map(\.name).joined(separator: ", "))
        out.append(.init(String(localized: "dSYMs", bundle: .module, comment: "Fact label on an Xcode archive card: how many debug-symbol bundles came with it."),
                         dsymCount.formatted()))
        if let profile {
            add(String(localized: "Profile", bundle: .module, comment: "Fact label on an Xcode archive card: the app's provisioning profile."), profile.name)
            add(String(localized: "Profile expires", bundle: .module, comment: "Fact label on an Xcode archive card."),
                profile.expirationDate.map { $0.formatted(date: .abbreviated, time: .omitted) })
        }
        add(String(localized: "Comment", bundle: .module, comment: "Fact label on an Xcode archive card: the note written in Xcode's Organizer."), comment)
        return out
    }
}

enum XcodeArchiveReader {
    static let bundleKinds: [String: XcodeArchiveSummary.Product.Kind] = [
        "app": .application, "framework": .framework, "appex": .appExtension, "xpc": .xpcService, "bundle": .bundle,
        "plugin": .bundle, "kext": .bundle, "systemextension": .bundle, "dext": .bundle, "qlgenerator": .bundle,
        "mdimporter": .bundle, "prefpane": .bundle, "saver": .bundle,
    ]

    static func looksLikeArchive(_ folder: AppleDevFolder) -> Bool {
        if case .data(let data) = folder.read(folder.root.appendingPathComponent("Info.plist")),
           let (plist, _) = AppleDevPlist.dictionary(data),
           plist["ApplicationProperties"] != nil || plist["ArchiveVersion"] != nil {
            return true
        }
        return folder.entry("Products", in: folder.root)?.isDirectory == true
            && folder.entry("dSYMs", in: folder.root)?.isDirectory == true
    }

    static func read(_ folder: AppleDevFolder) -> XcodeArchiveSummary {
        var warnings: [AppleDevWarning] = []
        var plist: [String: PlistValue] = [:]
        switch folder.read(folder.root.appendingPathComponent("Info.plist")) {
        case .data(let data):
            if let (dict, _) = AppleDevPlist.dictionary(data) { plist = dict } else {
                warnings.append(.init(.caution, String(
                    localized: "The archive's Info.plist is damaged, so its app details are unknown.",
                    bundle: .module, comment: "Warning on an Xcode archive card. Info.plist is a file name and stays as is.")))
            }
        case .missing:
            warnings.append(.init(.caution, String(
                localized: "The archive has no Info.plist, so Xcode's Organizer does not list it.",
                bundle: .module, comment: "Warning on an Xcode archive card. Info.plist is a file name and stays as is.")))
        case .tooLarge, .notAFile:
            warnings.append(.init(.caution, String(
                localized: "The archive's Info.plist is not a small regular file and was not read.",
                bundle: .module, comment: "Warning on an Xcode archive card: the file is too large, a link or not a file.")))
        }
        let app = plist["ApplicationProperties"]?.dictionaryValue ?? [:]

        // Products: bundles are listed without looking inside them; loose files are tools or libraries.
        var products: [XcodeArchiveSummary.Product] = [], productURLs: [String: URL] = [:], tooMany = false
        func walkProducts(_ directory: URL, depth: Int) {
            for entry in folder.children(of: directory, depth: depth) {
                if entry.isSymbolicLink || entry.name.hasPrefix(".") { continue }
                let ext = (entry.name as NSString).pathExtension.lowercased()
                let kind: XcodeArchiveSummary.Product.Kind?
                if entry.isDirectory {
                    kind = bundleKinds[ext] ?? (ext == "dsym" ? .other : nil)
                    if kind == nil { walkProducts(entry.url, depth: depth + 1); continue }
                } else if entry.isRegularFile {
                    kind = ["dylib", "a", "so"].contains(ext) ? .library : ext.isEmpty ? .tool : .other
                } else { continue }
                guard products.count < XcodeArchiveSummary.maxProducts else { tooMany = true; return }
                let path = String(folder.relativePath(entry.url).dropFirst("Products/".count))
                products.append(.init(path: path, kind: kind ?? .other))
                productURLs[path] = entry.url
            }
        }
        if let productsDir = folder.entry("Products", in: folder.root), productsDir.isDirectory {
            walkProducts(productsDir.url, depth: 2)
        }

        var dsyms: [String] = []
        var dsymCount = 0
        if let dir = folder.entry("dSYMs", in: folder.root), dir.isDirectory {
            for entry in folder.children(of: dir.url, depth: 2) where entry.isDirectory && entry.name.lowercased().hasSuffix(".dsym") {
                dsymCount += 1
                if dsyms.count < XcodeArchiveSummary.maxProducts { dsyms.append(entry.name) }
            }
        }

        let applicationPath = app["ApplicationPath"]?.stringValue
        var profile: ProvisioningProfile?
        if let applicationPath {
            if let appURL = productURLs[applicationPath] {
                profile = readProfile(appURL, folder: folder)
            } else if !folder.truncated {
                let path = AppleDevText.clip(applicationPath, 120)
                warnings.append(.init(.caution, String(
                    localized: "The archive's Info.plist names the app “\(path)”, but Products does not hold it.",
                    bundle: .module, comment: "Warning on an Xcode archive card; the argument is a path. Info.plist and Products are names and stay as is.")))
            }
        }
        if products.isEmpty, !folder.truncated {
            warnings.append(.init(.caution, String(localized: "The archive holds no products.", bundle: .module,
                                                   comment: "Warning on an Xcode archive card: no apps, tools or frameworks inside.")))
        }
        if dsymCount == 0, !products.isEmpty {
            warnings.append(.init(.caution, String(
                localized: "The archive has no dSYMs: crash reports from this build cannot be turned back into function names and lines.",
                bundle: .module, comment: "Warning on an Xcode archive card. dSYMs are the debug-symbol files Xcode makes with a build.")))
        }
        if let profile, profile.isExpired() == true {
            let name = profile.name ?? profile.uuid ?? "?"
            warnings.append(.init(.caution, String(
                localized: "The app's provisioning profile “\(name)” has expired, so this build can no longer be installed or exported with it.",
                bundle: .module, comment: "Warning on an Xcode archive card; the argument is the profile's name.")))
        }
        let truncated = folder.truncated || tooMany
        if truncated {
            warnings.append(.init(.caution, String(
                localized: "The archive is larger than the preview walks; some products may be missing from the list.",
                bundle: .module, comment: "Warning on an Xcode archive card.")))
        }

        return XcodeArchiveSummary(
            name: plist["Name"]?.stringValue, schemeName: plist["SchemeName"]?.stringValue,
            creationDate: plist["CreationDate"]?.dateValue,
            archiveVersion: plist["ArchiveVersion"]?.integerValue.map { Int(clamping: $0) },
            comment: plist["Comment"]?.stringValue,
            bundleIdentifier: app["CFBundleIdentifier"]?.stringValue,
            shortVersion: app["CFBundleShortVersionString"]?.stringValue, buildVersion: app["CFBundleVersion"]?.stringValue,
            signingIdentity: app["SigningIdentity"]?.stringValue, team: app["Team"]?.stringValue,
            architectures: Array((app["Architectures"]?.stringArray ?? []).prefix(16)), applicationPath: applicationPath,
            products: products, dsymCount: dsymCount, dsyms: dsyms, profile: profile, truncated: truncated,
            warnings: warnings.sorted { $0.level > $1.level })
    }

    /// `embedded.mobileprovision` (iOS layout) or `Contents/embedded.provisionprofile` (macOS layout), never
    /// through a link.
    static func readProfile(_ app: URL, folder: AppleDevFolder) -> ProvisioningProfile? {
        var candidates = [app.appendingPathComponent("embedded.mobileprovision")]
        if let contents = folder.entry("Contents", in: app), contents.isDirectory {
            candidates.append(contents.url.appendingPathComponent("embedded.provisionprofile"))
        }
        for url in candidates {
            if case .data(let data) = folder.read(url) {
                return try? ProvisioningProfileReader.read(bytes: [UInt8](data))
            }
        }
        return nil
    }
}
