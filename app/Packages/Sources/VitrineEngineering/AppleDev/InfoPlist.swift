import Foundation
import VitrineBinary

/// An Info.plist (XML, binary or OpenStep): who the bundle is, its versions and minimum OS, the private data it may
/// ask for and why, the links and documents it opens, what it keeps running in the background, and where it relaxes
/// App Transport Security. Values written as build settings (`$(PRODUCT_BUNDLE_IDENTIFIER)`) are shown as written.
/// roadmap: S-22
public struct InfoPlistSummary: Sendable, Equatable {
    /// How the property list is stored. roadmap: S-22
    public enum Format: String, Sendable, Equatable {
        case xml = "XML", binary = "binary", openStep = "OpenStep"

        /// The format in the reader's language.
        public var label: String {
            switch self {
            case .xml: String(localized: "XML", bundle: .module, comment: "How a property list is stored: as XML text.")
            case .binary: String(localized: "binary", bundle: .module, comment: "How a property list is stored: Apple's binary format.")
            case .openStep: String(localized: "OpenStep", bundle: .module, comment: "How a property list is stored: the old OpenStep text format.")
            }
        }
    }

    /// An `NS…UsageDescription` key: what the app may ask for, and the reason it shows in the permission prompt.
    /// roadmap: S-22
    public struct PrivacyUsage: Sendable, Equatable {
        public var key: String
        /// "Camera", "Location while in use" …
        public var what: String
        public var reason: String
    }

    /// One `CFBundleURLTypes` entry: the links of these schemes open the app. roadmap: S-22
    public struct URLType: Sendable, Equatable {
        public var name: String?
        public var role: String?
        public var schemes: [String]
    }

    /// One `CFBundleDocumentTypes` entry. roadmap: S-22
    public struct DocumentType: Sendable, Equatable {
        public var name: String?
        /// Editor, Viewer, Shell, None.
        public var role: String?
        public var contentTypes: [String]
        public var extensions: [String]
    }

    /// One `UIBackgroundModes` value with its plain meaning. roadmap: S-22
    public struct BackgroundMode: Sendable, Equatable {
        public var key: String
        public var what: String
    }

    /// `NSAppTransportSecurity`: where the app allows connections weaker than HTTPS with modern TLS.
    /// roadmap: S-22
    public struct TransportSecurity: Sendable, Equatable {
        /// One `NSExceptionDomains` entry. roadmap: S-22
        public struct Domain: Sendable, Equatable {
            public var name: String
            public var includesSubdomains: Bool
            public var allowsInsecureHTTP: Bool
            /// `NSExceptionMinimumTLSVersion` ("TLSv1.0" …), when lowered.
            public var minimumTLSVersion: String?
            public var requiresForwardSecrecy: Bool
        }

        public var allowsArbitraryLoads: Bool
        public var allowsArbitraryLoadsInWebContent: Bool
        public var allowsArbitraryLoadsForMedia: Bool
        public var allowsLocalNetworking: Bool
        public var exceptionDomains: [Domain]
    }

    public var format: Format
    public var bundleIdentifier: String?
    public var name: String?
    public var displayName: String?
    public var executable: String?
    public var shortVersion: String?
    public var buildVersion: String?
    /// `LSMinimumSystemVersion` (macOS) or `MinimumOSVersion` (iOS and its relatives).
    public var minimumOSVersion: String?
    /// `CFBundlePackageType`: APPL, FMWK, BNDL, XPC! …
    public var packageType: String?
    public var supportedPlatforms: [String]
    /// From `UIDeviceFamily`: iPhone, iPad, Apple TV, Apple Watch, Mac, Vision.
    public var deviceFamilies: [String]
    public var category: String?
    public var copyright: String?
    /// `LSUIElement` or `LSBackgroundOnly`: no Dock icon.
    public var isAgent: Bool
    public var privacyUsages: [PrivacyUsage]
    public var urlTypes: [URLType]
    /// `LSApplicationQueriesSchemes`: other apps' schemes this app checks for.
    public var queriedSchemes: [String]
    public var documentTypes: [DocumentType]
    /// `UTExportedTypeDeclarations` identifiers.
    public var exportedTypes: [String]
    /// `UTImportedTypeDeclarations` identifiers.
    public var importedTypes: [String]
    public var backgroundModes: [BackgroundMode]
    public var transportSecurity: TransportSecurity?
    /// `UIRequiredDeviceCapabilities`.
    public var requiredCapabilities: [String]
    /// Some values are Xcode build settings (`$(…)`), so this is a project's source Info.plist, not a built one.
    public var usesBuildSettings: Bool
    public var keyCount: Int
    /// The whole property list, for a raw view.
    public var properties: [String: PlistValue]
    public var warnings: [AppleDevWarning]

    public var headline: String {
        let title = displayName ?? name ?? bundleIdentifier
            ?? String(localized: "Bundle", bundle: .module, comment: "Info.plist card headline when the plist names no app.")
        if let shortVersion, let buildVersion {
            return String(localized: "Info.plist — \(title) \(shortVersion) (\(buildVersion))", bundle: .module,
                          comment: "Headline of an Info.plist card: the app's name, version and build.")
        }
        if let version = shortVersion ?? buildVersion {
            return String(localized: "Info.plist — \(title) \(version)", bundle: .module,
                          comment: "Headline of an Info.plist card: the app's name and version.")
        }
        return String(localized: "Info.plist — \(title)", bundle: .module, comment: "Headline of an Info.plist card: the app's name.")
    }

    public var facts: [AppleDevFact] {
        var out: [AppleDevFact] = []
        func add(_ label: String, _ value: String?) { if let value, !value.isEmpty { out.append(.init(label, value)) } }
        add(String(localized: "Bundle ID", bundle: .module, comment: "Fact label on an Info.plist card."), bundleIdentifier)
        add(String(localized: "Name", bundle: .module, comment: "Fact label on an Info.plist card: the app's name."), displayName ?? name)
        add(String(localized: "Version", bundle: .module, comment: "Fact label on an Info.plist card."), shortVersion)
        add(String(localized: "Build", bundle: .module, comment: "Fact label on an Info.plist card: the build number."), buildVersion)
        add(String(localized: "Minimum OS", bundle: .module, comment: "Fact label on an Info.plist card: the oldest system the app runs on."), minimumOSVersion)
        add(String(localized: "Executable", bundle: .module, comment: "Fact label on an Info.plist card: the main program's file name."), executable)
        add(String(localized: "Package type", bundle: .module, comment: "Fact label on an Info.plist card."), packageType.map(Self.packageTypeName))
        add(String(localized: "Platforms", bundle: .module, comment: "Fact label on an Info.plist card."),
            supportedPlatforms.isEmpty ? nil : supportedPlatforms.joined(separator: ", "))
        add(String(localized: "Devices", bundle: .module, comment: "Fact label on an Info.plist card: iPhone, iPad and so on."),
            deviceFamilies.isEmpty ? nil : deviceFamilies.joined(separator: ", "))
        add(String(localized: "Category", bundle: .module, comment: "Fact label on an Info.plist card: the App Store category."), category)
        if isAgent {
            add(String(localized: "Dock icon", bundle: .module, comment: "Fact label on an Info.plist card."),
                String(localized: "none (runs in the background or menu bar)", bundle: .module, comment: "Info.plist fact value: the app shows no Dock icon."))
        }
        add(String(localized: "Privacy prompts", bundle: .module, comment: "Fact label on an Info.plist card: the private data the app may ask for."),
            privacyUsages.isEmpty ? nil : privacyUsages.map(\.what).joined(separator: ", "))
        let schemes = urlTypes.flatMap(\.schemes)
        add(String(localized: "URL schemes", bundle: .module, comment: "Fact label on an Info.plist card: the link schemes that open the app."),
            schemes.isEmpty ? nil : schemes.joined(separator: ", "))
        add(String(localized: "Document types", bundle: .module, comment: "Fact label on an Info.plist card."),
            documentTypes.isEmpty ? nil : documentTypes.count.formatted())
        add(String(localized: "Background modes", bundle: .module, comment: "Fact label on an Info.plist card: what the app keeps doing in the background."),
            backgroundModes.isEmpty ? nil : backgroundModes.map(\.what).joined(separator: ", "))
        if let ats = transportSecurity {
            let n = ats.exceptionDomains.count
            let value = ats.allowsArbitraryLoads
                ? String(localized: "off (plain HTTP allowed)", bundle: .module, comment: "Info.plist fact value: App Transport Security is switched off.")
                : n == 0 ? String(localized: "on", bundle: .module, comment: "Info.plist fact value: App Transport Security is on.")
                : String(localized: "on, with \(n) exceptions", bundle: .module, comment: "Info.plist fact value: App Transport Security is on, except for some domains.")
            add(String(localized: "App Transport Security", bundle: .module, comment: "Fact label on an Info.plist card (Apple's name for the HTTPS requirement)."), value)
        }
        if usesBuildSettings {
            add(String(localized: "Build settings", bundle: .module, comment: "Fact label on an Info.plist card."),
                String(localized: "values are filled in by Xcode when the app is built", bundle: .module, comment: "Info.plist fact value: some values are Xcode build settings such as $(PRODUCT_NAME)."))
        }
        add(String(localized: "Format", bundle: .module, comment: "Fact label on an Info.plist card: how the property list is stored."), format.label)
        return out
    }

    static func packageTypeName(_ raw: String) -> String {
        switch raw {
        case "APPL": String(localized: "application (APPL)", bundle: .module, comment: "A bundle's package type; the code in parentheses stays as is.")
        case "FMWK": String(localized: "framework (FMWK)", bundle: .module, comment: "A bundle's package type; the code in parentheses stays as is.")
        case "BNDL": String(localized: "bundle (BNDL)", bundle: .module, comment: "A bundle's package type; the code in parentheses stays as is.")
        case "XPC!": String(localized: "XPC service (XPC!)", bundle: .module, comment: "A bundle's package type; the code in parentheses stays as is.")
        case "KEXT": String(localized: "kernel extension (KEXT)", bundle: .module, comment: "A bundle's package type; the code in parentheses stays as is.")
        default: raw
        }
    }
}

enum InfoPlistReader {
    static let maxListed = 500

    static let bundleKeys: Set<String> = [
        "CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType", "CFBundleShortVersionString",
        "CFBundleVersion", "CFBundleName", "CFBundleInfoDictionaryVersion",
    ]

    static func looksLikeInfoPlist(_ plist: [String: PlistValue]) -> Bool {
        plist.keys.filter(bundleKeys.contains).count >= 2
    }

    static func summary(_ p: [String: PlistValue], format: InfoPlistSummary.Format) -> InfoPlistSummary {
        var warnings: [AppleDevWarning] = []
        let privacy: [InfoPlistSummary.PrivacyUsage] = p.keys
            .filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }.sorted().prefix(maxListed).map {
                .init(key: $0, what: usageName($0), reason: p[$0]?.stringValue ?? "")
            }
        for usage in privacy where usage.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let what = usage.what, key = usage.key
            warnings.append(.init(.caution, String(
                localized: "The permission “\(what)” has no reason written for the prompt (\(key)). App Review rejects this, and people are asked without being told why.",
                bundle: .module, comment: "Warning on an Info.plist card. Arguments: what the app asks for (like “Camera”) and the Info.plist key, which stays as is.")))
        }

        let urlTypes: [InfoPlistSummary.URLType] = (p["CFBundleURLTypes"]?.arrayValue ?? []).prefix(maxListed).compactMap {
            guard let d = $0.dictionaryValue else { return nil }
            return .init(name: d["CFBundleURLName"]?.stringValue, role: d["CFBundleTypeRole"]?.stringValue,
                         schemes: Array((d["CFBundleURLSchemes"]?.stringArray ?? []).prefix(maxListed)))
        }
        let documents: [InfoPlistSummary.DocumentType] = (p["CFBundleDocumentTypes"]?.arrayValue ?? []).prefix(maxListed).compactMap {
            guard let d = $0.dictionaryValue else { return nil }
            return .init(name: d["CFBundleTypeName"]?.stringValue, role: d["CFBundleTypeRole"]?.stringValue,
                         contentTypes: Array((d["LSItemContentTypes"]?.stringArray ?? []).prefix(maxListed)),
                         extensions: Array((d["CFBundleTypeExtensions"]?.stringArray ?? []).prefix(maxListed)))
        }
        func declared(_ key: String) -> [String] {
            (p[key]?.arrayValue ?? []).prefix(maxListed).compactMap { $0.dictionaryValue?["UTTypeIdentifier"]?.stringValue }
        }
        let modes: [InfoPlistSummary.BackgroundMode] = (p["UIBackgroundModes"]?.stringArray ?? []).prefix(maxListed).map {
            .init(key: $0, what: backgroundModeName($0))
        }
        let families: [String] = (p["UIDeviceFamily"]?.arrayValue ?? []).prefix(16).compactMap { value in
            let n = value.integerValue ?? value.stringValue.flatMap { Int64($0) }
            return switch n { case 1: "iPhone"; case 2: "iPad"; case 3: "Apple TV"; case 4: "Apple Watch"; case 6: "Mac"; case 7: "Vision"; default: nil }
        }
        let capabilities: [String] = {
            if let d = p["UIRequiredDeviceCapabilities"]?.dictionaryValue {
                return d.keys.filter { d[$0]?.boolValue == true }.sorted()
            }
            return Array((p["UIRequiredDeviceCapabilities"]?.stringArray ?? []).prefix(maxListed))
        }()

        let ats = transportSecurity(p["NSAppTransportSecurity"]?.dictionaryValue, warnings: &warnings)
        let name = p["CFBundleName"]?.stringValue
        return InfoPlistSummary(
            format: format, bundleIdentifier: p["CFBundleIdentifier"]?.stringValue, name: name,
            displayName: p["CFBundleDisplayName"]?.stringValue, executable: p["CFBundleExecutable"]?.stringValue,
            shortVersion: p["CFBundleShortVersionString"]?.stringValue, buildVersion: p["CFBundleVersion"]?.stringValue,
            minimumOSVersion: p["LSMinimumSystemVersion"]?.stringValue ?? p["MinimumOSVersion"]?.stringValue,
            packageType: p["CFBundlePackageType"]?.stringValue,
            supportedPlatforms: Array((p["CFBundleSupportedPlatforms"]?.stringArray ?? []).prefix(16)),
            deviceFamilies: families, category: p["LSApplicationCategoryType"]?.stringValue.map(categoryName),
            copyright: p["NSHumanReadableCopyright"]?.stringValue,
            isAgent: p["LSUIElement"]?.boolValue == true || p["LSUIElement"]?.stringValue == "1"
                || p["LSBackgroundOnly"]?.boolValue == true,
            privacyUsages: Array(privacy), urlTypes: urlTypes,
            queriedSchemes: Array((p["LSApplicationQueriesSchemes"]?.stringArray ?? []).prefix(maxListed)),
            documentTypes: documents, exportedTypes: declared("UTExportedTypeDeclarations"),
            importedTypes: declared("UTImportedTypeDeclarations"), backgroundModes: modes, transportSecurity: ats,
            requiredCapabilities: capabilities, usesBuildSettings: usesBuildSettings(p), keyCount: p.count,
            properties: p, warnings: warnings.sorted { $0.level > $1.level })
    }

    static func transportSecurity(_ d: [String: PlistValue]?, warnings: inout [AppleDevWarning]) -> InfoPlistSummary.TransportSecurity? {
        guard let d else { return nil }
        func flag(_ dict: [String: PlistValue], _ key: String) -> Bool {
            dict[key]?.boolValue == true || dict[key]?.stringValue?.uppercased() == "YES"
        }
        let domains: [InfoPlistSummary.TransportSecurity.Domain] = (d["NSExceptionDomains"]?.dictionaryValue ?? [:])
            .sorted { $0.key < $1.key }.prefix(maxListed).map { name, value in
                let e = value.dictionaryValue ?? [:]
                return .init(name: name, includesSubdomains: flag(e, "NSIncludesSubdomains"),
                             allowsInsecureHTTP: flag(e, "NSExceptionAllowsInsecureHTTPLoads")
                                || flag(e, "NSThirdPartyExceptionAllowsInsecureHTTPLoads"),
                             minimumTLSVersion: e["NSExceptionMinimumTLSVersion"]?.stringValue
                                ?? e["NSThirdPartyExceptionMinimumTLSVersion"]?.stringValue,
                             requiresForwardSecrecy: e["NSExceptionRequiresForwardSecrecy"]?.boolValue ?? true)
            }
        let ats = InfoPlistSummary.TransportSecurity(
            allowsArbitraryLoads: flag(d, "NSAllowsArbitraryLoads"),
            allowsArbitraryLoadsInWebContent: flag(d, "NSAllowsArbitraryLoadsInWebContent"),
            allowsArbitraryLoadsForMedia: flag(d, "NSAllowsArbitraryLoadsForMedia"),
            allowsLocalNetworking: flag(d, "NSAllowsLocalNetworking"), exceptionDomains: domains)
        if ats.allowsArbitraryLoads {
            warnings.append(.init(.caution, String(
                localized: "App Transport Security is switched off (NSAllowsArbitraryLoads): the app may connect over plain HTTP, where others on the network can read and change what it sends and receives.",
                bundle: .module, comment: "Warning on an Info.plist card. NSAllowsArbitraryLoads is a key name and stays as is.")))
        }
        let insecure = domains.filter(\.allowsInsecureHTTP).map(\.name)
        if !insecure.isEmpty {
            let hosts = Self.hostList(insecure), count = insecure.count
            warnings.append(.init(.caution, String(
                localized: "Plain HTTP is allowed to \(count) domains (\(hosts)): what the app exchanges with them is not encrypted.",
                bundle: .module, comment: "Warning on an Info.plist card. Arguments: how many domains, then their names.")))
        }
        let weakTLS = domains.filter { ["TLSv1.0", "TLSv1.1"].contains($0.minimumTLSVersion ?? "") }.map(\.name)
        if !weakTLS.isEmpty {
            let hosts = Self.hostList(weakTLS), count = weakTLS.count
            warnings.append(.init(.caution, String(
                localized: "Outdated TLS (1.0 or 1.1) is accepted for \(count) domains (\(hosts)): these versions have known weaknesses.",
                bundle: .module, comment: "Warning on an Info.plist card. Arguments: how many domains, then their names.")))
        }
        return ats
    }

    /// At most five names, then "…" when there are more.
    static func hostList(_ names: [String]) -> String {
        names.prefix(5).joined(separator: ", ") + (names.count > 5 ? ", …" : "")
    }

    static func usesBuildSettings(_ p: [String: PlistValue]) -> Bool {
        var budget = 10_000
        func walk(_ v: PlistValue) -> Bool {
            budget -= 1
            guard budget > 0 else { return false }
            switch v {
            case .string(let s): return s.contains("$(") || s.contains("${")
            case .array(let a): return a.contains(where: walk)
            case .dictionary(let d): return d.values.contains(where: walk)
            default: return false
            }
        }
        return p.values.contains(where: walk)
    }

    static func categoryName(_ raw: String) -> String {
        let prefix = "public.app-category."
        guard raw.hasPrefix(prefix) else { return raw }
        return raw.dropFirst(prefix.count).split(separator: "-").map { word in
            word == "and" ? "&" : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// `NSLocationWhenInUseUsageDescription` → "Location while in use"; unknown keys are split into words.
    static func usageName(_ key: String) -> String {
        if let known = usageNames[key] { return known }
        guard key.count > "NSUsageDescription".count else { return key }
        let core = key.dropFirst(2).dropLast("UsageDescription".count)
        var out = ""
        for ch in core {
            if ch.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
            out.append(out.isEmpty ? ch : Character(ch.lowercased()))
        }
        return out
    }

    /// What each `NS…UsageDescription` key asks for, in the reader's language.
    static let usageNames: [String: String] = [
        "NSCameraUsageDescription": String(localized: "Camera", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSMicrophoneUsageDescription": String(localized: "Microphone", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSPhotoLibraryUsageDescription": String(localized: "Photos", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key): the photo library."),
        "NSPhotoLibraryAddUsageDescription": String(localized: "Adding to Photos", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSLocationWhenInUseUsageDescription": String(localized: "Location while in use", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSLocationAlwaysAndWhenInUseUsageDescription": String(localized: "Location at all times", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSLocationAlwaysUsageDescription": String(localized: "Location at all times", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSLocationUsageDescription": String(localized: "Location", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSLocationTemporaryUsageDescriptionDictionary": String(localized: "Precise location, once", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSContactsUsageDescription": String(localized: "Contacts", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSCalendarsUsageDescription": String(localized: "Calendars", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSCalendarsFullAccessUsageDescription": String(localized: "Calendars (full access)", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSCalendarsWriteOnlyAccessUsageDescription": String(localized: "Adding calendar events", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSRemindersUsageDescription": String(localized: "Reminders", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSRemindersFullAccessUsageDescription": String(localized: "Reminders (full access)", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSBluetoothAlwaysUsageDescription": String(localized: "Bluetooth", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSBluetoothPeripheralUsageDescription": String(localized: "Bluetooth accessories", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSFaceIDUsageDescription": String(localized: "Face ID", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSHealthShareUsageDescription": String(localized: "Reading Health data", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSHealthUpdateUsageDescription": String(localized: "Writing Health data", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSHealthClinicalHealthRecordsShareUsageDescription": String(localized: "Health records", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSMotionUsageDescription": String(localized: "Motion and fitness", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSSpeechRecognitionUsageDescription": String(localized: "Speech recognition", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSLocalNetworkUsageDescription": String(localized: "Local network", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSUserTrackingUsageDescription": String(localized: "Tracking across apps and websites", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSHomeKitUsageDescription": String(localized: "Home", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key): home accessories."),
        "NSAppleMusicUsageDescription": String(localized: "Media library", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSNearbyInteractionUsageDescription": String(localized: "Nearby devices", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSNearbyInteractionAllowOnceUsageDescription": String(localized: "Nearby devices, once", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSSiriUsageDescription": String(localized: "Siri", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSAppleEventsUsageDescription": String(localized: "Controlling other apps", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key): Apple events."),
        "NSSystemAdministrationUsageDescription": String(localized: "Administrator actions", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSDesktopFolderUsageDescription": String(localized: "Desktop folder", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSDocumentsFolderUsageDescription": String(localized: "Documents folder", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSDownloadsFolderUsageDescription": String(localized: "Downloads folder", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSNetworkVolumesUsageDescription": String(localized: "Network volumes", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSRemovableVolumesUsageDescription": String(localized: "Removable volumes", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSFileProviderDomainUsageDescription": String(localized: "Files from other apps", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSFileProviderPresenceUsageDescription": String(localized: "File provider presence", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSSensorKitUsageDescription": String(localized: "Research sensors", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSFocusStatusUsageDescription": String(localized: "Focus status", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSIdentityUsageDescription": String(localized: "Identity documents", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSVideoSubscriberAccountUsageDescription": String(localized: "TV provider account", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSGKFriendListUsageDescription": String(localized: "Game Center friends", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSFallDetectionUsageDescription": String(localized: "Fall detection", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSWorldSensingUsageDescription": String(localized: "Surroundings (world sensing)", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSHandsTrackingUsageDescription": String(localized: "Hand tracking", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSAudioCaptureUsageDescription": String(localized: "System audio recording", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
        "NSScreenCaptureUsageDescription": String(localized: "Screen recording", bundle: .module, comment: "What an app may ask permission for (Info.plist privacy key)."),
    ]

    static func backgroundModeName(_ key: String) -> String {
        switch key {
        case "audio": String(localized: "plays audio in the background", bundle: .module, comment: "What an app keeps doing in the background (UIBackgroundModes value).")
        case "location": String(localized: "location updates", bundle: .module, comment: "What an app keeps doing in the background (UIBackgroundModes value).")
        case "voip": String(localized: "internet calls", bundle: .module, comment: "What an app keeps doing in the background (UIBackgroundModes value).")
        case "fetch": String(localized: "background fetch", bundle: .module, comment: "What an app keeps doing in the background (UIBackgroundModes value).")
        case "remote-notification": String(localized: "silent push notifications", bundle: .module, comment: "What an app keeps doing in the background (UIBackgroundModes value).")
        case "processing": String(localized: "background processing", bundle: .module, comment: "What an app keeps doing in the background (UIBackgroundModes value).")
        case "bluetooth-central": String(localized: "Bluetooth accessories", bundle: .module, comment: "What an app keeps doing in the background (UIBackgroundModes value).")
        case "bluetooth-peripheral": String(localized: "acts as a Bluetooth accessory", bundle: .module, comment: "What an app keeps doing in the background (UIBackgroundModes value).")
        case "external-accessory": String(localized: "external accessories", bundle: .module, comment: "What an app keeps doing in the background (UIBackgroundModes value).")
        case "newsstand-content": String(localized: "Newsstand downloads", bundle: .module, comment: "What an app keeps doing in the background (UIBackgroundModes value).")
        case "nearby-interaction": String(localized: "nearby interaction", bundle: .module, comment: "What an app keeps doing in the background (UIBackgroundModes value).")
        case "push-to-talk": String(localized: "push to talk", bundle: .module, comment: "What an app keeps doing in the background (UIBackgroundModes value).")
        default: key
        }
    }
}
