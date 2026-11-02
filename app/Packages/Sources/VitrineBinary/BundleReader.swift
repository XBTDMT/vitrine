import Foundation

/// What a preview shows for an `.app` or other bundle: Info.plist facts, the main executable's architectures and
/// signature (read statically), what it embeds, the privacy strings it declares, whether it is sandboxed and its size
/// on disk. Nothing is launched, registered with Launch Services or loaded.
public struct BundleFacts: Sendable, Equatable {
    public enum Layout: String, Sendable, Equatable {
        /// `Contents/Info.plist`, `Contents/MacOS/…` (macOS).
        case macOS
        /// `Info.plist` at the top (iOS, watchOS, and Mac Catalyst-free iOS apps).
        case flat
        /// A framework's `Resources/Info.plist` (or `Versions/Current/Resources`).
        case framework
    }

    public let url: URL
    public let layout: Layout
    public let info: BundleInfo
    /// The main executable, when the bundle names one that exists.
    public let executableURL: URL?
    public let executable: MachOFile?
    public let executableProblem: String?
    public let embedded: [EmbeddedItem]
    /// More embedded items exist than were listed.
    public let embeddedTruncated: Bool
    /// Entitlements from the main executable's signature (first architecture that has them).
    public let entitlements: [String: PlistValue]?
    public let size: DiskUsage
    public let notarization: StapledTicket

    /// `com.apple.security.app-sandbox` is true; nil when the executable carries no entitlements to say.
    public var isSandboxed: Bool? {
        guard let entitlements else { return executable?.slices.contains { $0.hasCodeSignature } == true ? false : nil }
        return entitlements["com.apple.security.app-sandbox"]?.boolValue == true
    }

    public var architectures: [String] { executable?.architectures ?? [] }
    /// The primary slice's embedded signature.
    public var signature: EmbeddedSignature? { executable?.slices.lazy.compactMap(\.codeSignature).first }
}

/// Info.plist facts.
public struct BundleInfo: Sendable, Equatable {
    public let name: String?
    public let displayName: String?
    public let identifier: String?
    public let shortVersion: String?
    public let buildVersion: String?
    public let executableName: String?
    public let packageType: String?
    public let minimumSystemVersion: String?
    /// `LSApplicationCategoryType` and its readable name (`public.app-category.developer-tools` → Developer Tools).
    public let category: String?
    public var categoryName: String? { category.map(Self.categoryName) }
    public let copyright: String?
    /// `LSUIElement` / `LSBackgroundOnly`: no Dock icon.
    public let isAgent: Bool
    public let documentTypes: [DocumentType]
    public let exportedTypes: [DeclaredType]
    public let importedTypes: [DeclaredType]
    public let urlSchemes: [String]
    /// `NS…UsageDescription` keys and the purpose text the app shows with the permission prompt.
    public let privacyUsage: [PrivacyUsage]
    /// For app extensions: `NSExtensionPointIdentifier` or `EXExtensionPointIdentifier`.
    public let extensionPoint: String?
    public let supportedPlatforms: [String]
    /// The whole Info.plist, for a raw view.
    public let properties: [String: PlistValue]

    public struct DocumentType: Sendable, Equatable {
        public let name: String?
        public let role: String?
        public let contentTypes: [String]
        public let extensions: [String]
        public let handlerRank: String?
    }

    public struct DeclaredType: Sendable, Equatable {
        public let identifier: String
        public let description: String?
        public let conformsTo: [String]
        public let extensions: [String]
    }

    public struct PrivacyUsage: Sendable, Equatable {
        public let key: String
        public let purpose: String
        /// `NSCameraUsageDescription` → "Camera".
        public var resource: String {
            var core = key
            if core.hasPrefix("NS") { core.removeFirst(2) }
            if core.hasSuffix("UsageDescription") { core.removeLast("UsageDescription".count) }
            var out = ""
            for (i, ch) in core.enumerated() {
                if i > 0, ch.isUppercase, let prev = out.last, prev.isLowercase { out.append(" ") }
                out.append(ch)
            }
            return out
        }
    }

    init(_ p: [String: PlistValue]) {
        properties = p
        name = p["CFBundleName"]?.stringValue
        displayName = p["CFBundleDisplayName"]?.stringValue
        identifier = p["CFBundleIdentifier"]?.stringValue
        shortVersion = p["CFBundleShortVersionString"]?.stringValue
        buildVersion = p["CFBundleVersion"]?.stringValue
        executableName = p["CFBundleExecutable"]?.stringValue
        packageType = p["CFBundlePackageType"]?.stringValue
        minimumSystemVersion = p["LSMinimumSystemVersion"]?.stringValue ?? p["MinimumOSVersion"]?.stringValue
        category = p["LSApplicationCategoryType"]?.stringValue
        copyright = p["NSHumanReadableCopyright"]?.stringValue
        isAgent = p["LSUIElement"]?.boolValue == true || p["LSUIElement"]?.stringValue == "1"
            || p["LSBackgroundOnly"]?.boolValue == true
        documentTypes = (p["CFBundleDocumentTypes"]?.arrayValue ?? []).prefix(500).compactMap { item in
            guard let d = item.dictionaryValue else { return nil }
            return DocumentType(name: d["CFBundleTypeName"]?.stringValue, role: d["CFBundleTypeRole"]?.stringValue,
                                contentTypes: d["LSItemContentTypes"]?.stringArray ?? [],
                                extensions: d["CFBundleTypeExtensions"]?.stringArray ?? [],
                                handlerRank: d["LSHandlerRank"]?.stringValue)
        }
        func declared(_ key: String) -> [DeclaredType] {
            (p[key]?.arrayValue ?? []).prefix(500).compactMap { item in
                guard let d = item.dictionaryValue, let id = d["UTTypeIdentifier"]?.stringValue else { return nil }
                let tags = d["UTTypeTagSpecification"]?.dictionaryValue
                return DeclaredType(identifier: id, description: d["UTTypeDescription"]?.stringValue,
                                    conformsTo: d["UTTypeConformsTo"]?.stringArray ?? [],
                                    extensions: tags?["public.filename-extension"]?.stringArray ?? [])
            }
        }
        exportedTypes = declared("UTExportedTypeDeclarations")
        importedTypes = declared("UTImportedTypeDeclarations")
        urlSchemes = (p["CFBundleURLTypes"]?.arrayValue ?? []).flatMap {
            $0.dictionaryValue?["CFBundleURLSchemes"]?.stringArray ?? []
        }
        privacyUsage = p.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }.sorted().map {
            PrivacyUsage(key: $0, purpose: p[$0]?.stringValue ?? "")
        }
        let ns = p["NSExtension"]?.dictionaryValue?["NSExtensionPointIdentifier"]?.stringValue
        let ex = p["EXAppExtensionAttributes"]?.dictionaryValue?["EXExtensionPointIdentifier"]?.stringValue
        extensionPoint = ns ?? ex
        supportedPlatforms = p["CFBundleSupportedPlatforms"]?.stringArray ?? []
    }

    static func categoryName(_ raw: String) -> String {
        let prefix = "public.app-category."
        guard raw.hasPrefix(prefix) else { return raw }
        return raw.dropFirst(prefix.count).split(separator: "-").map { word in
            word == "and" ? "&" : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}

/// A framework, plug-in, app extension, XPC service, helper app, login item or dylib inside a bundle.
public struct EmbeddedItem: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case framework, dylib, plugIn = "plug-in", appExtension = "app extension", xpcService = "XPC service"
        case helperApp = "helper app", loginItem = "login item", launchService = "launch service"
        case quickLook = "Quick Look plug-in", spotlight = "Spotlight importer", other

        /// The kind in the reader's language, for display (the raw value stays the stable English id).
        public var localizedName: String {
            switch self {
            case .framework: String(localized: "framework", bundle: .module, comment: "Kind of item embedded in an app bundle.")
            case .dylib: String(localized: "dylib", bundle: .module, comment: "Kind of item embedded in an app bundle. A dynamic library.")
            case .plugIn: String(localized: "plug-in", bundle: .module, comment: "Kind of item embedded in an app bundle.")
            case .appExtension: String(localized: "app extension", bundle: .module, comment: "Kind of item embedded in an app bundle.")
            case .xpcService: String(localized: "XPC service", bundle: .module, comment: "Kind of item embedded in an app bundle.")
            case .helperApp: String(localized: "helper app", bundle: .module, comment: "Kind of item embedded in an app bundle.")
            case .loginItem: String(localized: "login item", bundle: .module, comment: "Kind of item embedded in an app bundle.")
            case .launchService: String(localized: "launch service", bundle: .module, comment: "Kind of item embedded in an app bundle.")
            case .quickLook: String(localized: "Quick Look plug-in", bundle: .module, comment: "Kind of item embedded in an app bundle.")
            case .spotlight: String(localized: "Spotlight importer", bundle: .module, comment: "Kind of item embedded in an app bundle.")
            case .other: String(localized: "other", bundle: .module, comment: "Kind of item embedded in an app bundle. Anything else.")
            }
        }
    }

    public let relativePath: String
    public let kind: Kind
    public let identifier: String?
    public let version: String?
    public let extensionPoint: String?
}

/// Size on disk from a bounded walk that never follows symbolic links.
public struct DiskUsage: Sendable, Equatable {
    /// Sum of file lengths.
    public let logicalBytes: UInt64
    /// Sum of allocated sizes (what Finder's "on disk" shows; less than logical for compressed files).
    public let allocatedBytes: UInt64
    public let fileCount: Int
    public let folderCount: Int
    /// The walk stopped at the entry cap before visiting everything.
    public let isPartial: Bool
}

public enum BundleReader {
    public static func read(contentsOf url: URL, limits: BinaryLimits = .default) throws -> BundleFacts {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BinaryError.notRecognized("a bundle (not a folder)")
        }
        guard let (layout, plistURL) = locateInfoPlist(url) else {
            throw BinaryError.notRecognized("a bundle (no Info.plist)")
        }
        let plistSource = try BinaryFileSource(url: plistURL)
        guard plistSource.size <= Int64(limits.maxPropertyListBytes) else {
            throw BinaryError.unsupported("Info.plist is larger than the \(limits.maxPropertyListBytes)-byte cap")
        }
        let info = BundleInfo(try PropertyListDecoder.dictionary(
            try plistSource.exactly(Int(plistSource.size), at: 0, "Info.plist"),
            limit: limits.maxPropertyListBytes, what: "Info.plist"))

        var executableURL: URL?
        var executable: MachOFile?
        var problem: String?
        if let name = info.executableName, !name.isEmpty, !name.contains("/") {
            let folder: URL = switch layout {
            case .macOS: url.appendingPathComponent("Contents/MacOS", isDirectory: true)
            case .flat, .framework: url
            }
            let candidate = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                executableURL = candidate
                do { executable = try MachOReader.read(contentsOf: candidate, limits: limits) }
                catch let error as BinaryError { problem = error.reason }
            } else {
                problem = String(localized: "the executable \(name) named by Info.plist is missing", bundle: .module, comment: "A problem with an app bundle; the argument is the executable's file name.")
            }
        }
        let entitlements = executable?.slices.lazy.compactMap { $0.codeSignature?.entitlements }.first
        let (embedded, truncated) = listEmbedded(url, layout: layout, limit: limits.maxEmbeddedItems)
        return BundleFacts(url: url, layout: layout, info: info, executableURL: executableURL, executable: executable,
                           executableProblem: problem, embedded: embedded, embeddedTruncated: truncated,
                           entitlements: entitlements, size: measure(url, limit: limits.maxWalkEntries),
                           notarization: StapledTicket.detect(at: url))
    }

    static func locateInfoPlist(_ url: URL) -> (BundleFacts.Layout, URL)? {
        let fm = FileManager.default
        let candidates: [(BundleFacts.Layout, String)] = [
            (.macOS, "Contents/Info.plist"), (.flat, "Info.plist"),
            (.framework, "Resources/Info.plist"), (.framework, "Versions/Current/Resources/Info.plist"),
        ]
        for (layout, path) in candidates {
            let candidate = url.appendingPathComponent(path)
            if fm.fileExists(atPath: candidate.path) { return (layout, candidate) }
        }
        return nil
    }

    /// The bundle's embedded code, one level deep, from the folders macOS and iOS bundles keep it in.
    static func listEmbedded(_ url: URL, layout: BundleFacts.Layout, limit: Int) -> ([EmbeddedItem], Bool) {
        let base = layout == .macOS ? "Contents/" : ""
        let places: [(String, EmbeddedItem.Kind?)] = [
            ("Frameworks", nil), ("PlugIns", nil), ("Extensions", .appExtension), ("XPCServices", .xpcService),
            ("Library/LoginItems", .loginItem), ("Library/LaunchServices", .launchService),
            ("Library/QuickLook", .quickLook), ("Library/Spotlight", .spotlight), ("Helpers", nil),
            ("Library/SystemExtensions", nil),
        ]
        var out: [EmbeddedItem] = []
        let fm = FileManager.default
        for (folder, fixedKind) in places {
            let dir = url.appendingPathComponent(base + folder, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                guard out.count < limit else { return (out, true) }
                let item = dir.appendingPathComponent(name)
                let ext = (name as NSString).pathExtension.lowercased()
                let kind: EmbeddedItem.Kind
                switch ext {
                case "framework": kind = .framework
                case "dylib": kind = .dylib
                case "appex": kind = .appExtension
                case "xpc": kind = .xpcService
                case "app": kind = fixedKind ?? .helperApp
                case "qlgenerator": kind = .quickLook
                case "mdimporter": kind = .spotlight
                case "bundle", "plugin": kind = fixedKind ?? .plugIn
                default: kind = fixedKind ?? .other
                }
                if kind == .other, fixedKind == nil, folder == "Frameworks" { continue }   // stray resources
                var identifier: String?, version: String?, point: String?
                if ext != "dylib", let (_, plist) = locateInfoPlist(item),
                   let source = try? BinaryFileSource(url: plist), source.size <= 1024 * 1024,
                   let bytes = try? source.exactly(Int(source.size), at: 0, "Info.plist"),
                   let dict = try? PropertyListDecoder.dictionary(bytes, limit: 1024 * 1024, what: "Info.plist") {
                    let info = BundleInfo(dict)
                    identifier = info.identifier
                    version = info.shortVersion ?? info.buildVersion
                    point = info.extensionPoint
                }
                out.append(EmbeddedItem(relativePath: base + folder + "/" + name, kind: kind, identifier: identifier,
                                        version: version, extensionPoint: point))
            }
        }
        return (out, false)
    }

    /// Size on disk without following links, stopping at `limit` entries.
    static func measure(_ url: URL, limit: Int) -> DiskUsage {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in true }) else {
            return DiskUsage(logicalBytes: 0, allocatedBytes: 0, fileCount: 0, folderCount: 0, isPartial: true)
        }
        var logical: UInt64 = 0, allocated: UInt64 = 0, files = 0, folders = 0, seen = 0
        var partial = false
        while let next = walker.nextObject() as? URL {
            seen += 1
            if seen > limit { partial = true; break }
            guard let values = try? next.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true { folders += 1; continue }
            if values.isRegularFile == true {
                files += 1
                logical &+= UInt64(max(0, values.fileSize ?? 0))
                allocated &+= UInt64(max(0, values.totalFileAllocatedSize ?? 0))
            }
        }
        return DiskUsage(logicalBytes: logical, allocatedBytes: allocated, fileCount: files, folderCount: folders,
                         isPartial: partial)
    }
}
