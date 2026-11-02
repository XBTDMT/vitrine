import Foundation
import VitrineBinary

/// An entitlements file (`.entitlements`, or a property list holding only entitlements): every key in plain words
/// from a table of common macOS and iOS entitlements, keys the table does not know listed as they are, and warnings
/// for the hardened-runtime exceptions, sandbox exceptions, debugging and Apple-private keys. roadmap: S-22
public struct EntitlementsSummary: Sendable, Equatable {
    /// The family an entitlement belongs to, for grouping on the card (the raw value is a stable id).
    /// roadmap: S-22
    public enum Category: String, Sendable, Equatable, CaseIterable {
        case sandbox, network, files, devices, personalData, identity, services, hardenedRuntime, sandboxException
        case debugging, system, privateApple, other

        /// The family's heading in the reader's language.
        public var label: String {
            switch self {
            case .sandbox: String(localized: "Sandbox", bundle: .module, comment: "Heading for a group of entitlements: the App Sandbox.")
            case .network: String(localized: "Network", bundle: .module, comment: "Heading for a group of entitlements.")
            case .files: String(localized: "Files", bundle: .module, comment: "Heading for a group of entitlements.")
            case .devices: String(localized: "Devices", bundle: .module, comment: "Heading for a group of entitlements: camera, USB, Bluetooth and so on.")
            case .personalData: String(localized: "Personal data", bundle: .module, comment: "Heading for a group of entitlements: contacts, location, health and so on.")
            case .identity: String(localized: "Identity and sharing", bundle: .module, comment: "Heading for a group of entitlements: team, app ID, keychain and app groups.")
            case .services: String(localized: "App services", bundle: .module, comment: "Heading for a group of entitlements: iCloud, push, Apple Pay and so on.")
            case .hardenedRuntime: String(localized: "Hardened runtime exceptions", bundle: .module, comment: "Heading for a group of entitlements that relax macOS's hardened runtime.")
            case .sandboxException: String(localized: "Sandbox exceptions", bundle: .module, comment: "Heading for a group of entitlements that reach past the App Sandbox.")
            case .debugging: String(localized: "Debugging", bundle: .module, comment: "Heading for a group of entitlements.")
            case .system: String(localized: "System extensions", bundle: .module, comment: "Heading for a group of entitlements: drivers, virtualization, security tools.")
            case .privateApple: String(localized: "Apple-private", bundle: .module, comment: "Heading for a group of entitlements only Apple's own software may use.")
            case .other: String(localized: "Other", bundle: .module, comment: "Heading for entitlements the preview does not know.")
            }
        }
    }

    /// One key. roadmap: S-22
    public struct Entry: Sendable, Equatable {
        public var key: String
        /// Plain words for the key ("Outgoing network connections"); nil for keys the table does not know.
        public var name: String?
        /// What it lets the app do, in a sentence; nil for keys the table does not know.
        public var meaning: String?
        public var category: Category
        public var value: PlistValue
        /// The value for display: "yes"/"no", a list, a string, or a count for a dictionary.
        public var valueText: String
        public var isKnown: Bool { name != nil }
    }

    /// Every key, grouped by category order, then by key.
    public var entries: [Entry]
    /// `com.apple.security.app-sandbox`: true, false, or nil when the file does not say.
    public var isSandboxed: Bool?
    /// Keys present and switched on from the hardened-runtime exception family (`com.apple.security.cs.*`).
    public var hardenedRuntimeExceptions: [String]
    /// Keys the table does not know, as written.
    public var unknownKeys: [String]
    /// The file had more keys than were listed (`EntitlementsReader.maxKeys`).
    public var truncated: Bool
    public var warnings: [AppleDevWarning]

    public var headline: String {
        let n = entries.count
        return String(localized: "Entitlements — \(n) keys", bundle: .module, comment: "Headline of an entitlements card: how many keys the file holds.")
    }

    public var facts: [AppleDevFact] {
        var out: [AppleDevFact] = []
        let sandbox = switch isSandboxed {
        case true?: String(localized: "on", bundle: .module, comment: "Entitlements fact value: the App Sandbox is on.")
        case false?: String(localized: "off", bundle: .module, comment: "Entitlements fact value: the App Sandbox is off.")
        case nil: String(localized: "not stated", bundle: .module, comment: "Entitlements fact value: the file does not say whether the app is sandboxed.")
        }
        out.append(.init(String(localized: "App Sandbox", bundle: .module, comment: "Fact label on an entitlements card (Apple's feature name)."), sandbox))
        let groups = Dictionary(grouping: entries, by: \.category)
        for category in Category.allCases {
            guard let items = groups[category], !items.isEmpty else { continue }
            out.append(.init(category.label, items.map { $0.name ?? $0.key }.joined(separator: ", ")))
        }
        return out
    }
}

enum EntitlementsReader {
    static let maxKeys = 2_000

    struct Known {
        var name: String
        var meaning: String
        var category: EntitlementsSummary.Category
    }

    static func read(_ data: Data) -> EntitlementsSummary? {
        guard let (plist, _) = AppleDevPlist.dictionary(data) else { return nil }
        return summary(plist)
    }

    /// Every key looks like an entitlement (and there is at least one).
    static func looksLikeEntitlements(_ plist: [String: PlistValue]) -> Bool {
        !plist.isEmpty && plist.keys.allSatisfy { key in
            known[key] != nil || key.hasPrefix("com.apple.") || key == "get-task-allow" || key == "keychain-access-groups"
                || key == "application-identifier" || key == "aps-environment" || key == "beta-reports-active"
        }
    }

    static func summary(_ plist: [String: PlistValue]) -> EntitlementsSummary {
        let order = Dictionary(uniqueKeysWithValues: EntitlementsSummary.Category.allCases.enumerated().map { ($1, $0) })
        let keys = plist.keys.sorted()
        var entries: [EntitlementsSummary.Entry] = []
        for key in keys.prefix(maxKeys) {
            guard let value = plist[key] else { continue }
            let info = describe(key)
            entries.append(.init(key: key, name: info?.name, meaning: info?.meaning,
                                 category: info?.category ?? .other, value: value, valueText: text(value)))
        }
        entries.sort { (order[$0.category] ?? 0, $0.key) < (order[$1.category] ?? 0, $1.key) }

        func on(_ key: String) -> Bool { isOn(plist[key]) }
        var warnings: [AppleDevWarning] = []
        let runtime = keys.filter { $0.hasPrefix("com.apple.security.cs.") && on($0) }
        for key in runtime {
            let (level, why): (AppleDevWarning.Level, String) = switch key {
            case "com.apple.security.cs.disable-executable-page-protection":
                (.danger, String(localized: "switches off executable memory protection entirely, the weakest hardened-runtime setting", bundle: .module, comment: "Why a hardened-runtime entitlement matters; follows “Hardened-runtime exception (key):”."))
            case "com.apple.security.cs.allow-dyld-environment-variables":
                (.danger, String(localized: "lets DYLD_ environment variables inject code into the app when it starts", bundle: .module, comment: "Why a hardened-runtime entitlement matters; follows “Hardened-runtime exception (key):”. DYLD_ stays as is."))
            case "com.apple.security.cs.disable-library-validation":
                (.caution, String(localized: "lets the app load plug-ins and libraries signed by anyone, not only its own team", bundle: .module, comment: "Why a hardened-runtime entitlement matters; follows “Hardened-runtime exception (key):”."))
            case "com.apple.security.cs.allow-unsigned-executable-memory":
                (.caution, String(localized: "lets the app create executable memory without code-signing checks", bundle: .module, comment: "Why a hardened-runtime entitlement matters; follows “Hardened-runtime exception (key):”."))
            case "com.apple.security.cs.allow-jit":
                (.caution, String(localized: "lets the app generate code at run time (JIT), as browsers and emulators do", bundle: .module, comment: "Why a hardened-runtime entitlement matters; follows “Hardened-runtime exception (key):”."))
            case "com.apple.security.cs.debugger":
                (.caution, String(localized: "lets the app attach to and control other processes as a debugger", bundle: .module, comment: "Why a hardened-runtime entitlement matters; follows “Hardened-runtime exception (key):”."))
            default:
                (.caution, String(localized: "relaxes a hardened-runtime protection", bundle: .module, comment: "Why a hardened-runtime entitlement matters; follows “Hardened-runtime exception (key):”."))
            }
            warnings.append(.init(level, String(localized: "Hardened-runtime exception (\(key)): \(why).", bundle: .module,
                                                comment: "Warning on an entitlements card. Arguments: the entitlement key (stays as is) and why it matters.")))
        }
        if on("com.apple.security.get-task-allow") || on("get-task-allow") {
            warnings.append(.init(.caution, String(
                localized: "The app can be debugged (get-task-allow): other processes may attach to it. Development builds have this; a build for release should not.",
                bundle: .module, comment: "Warning on an entitlements card. get-task-allow is a key name and stays as is.")))
        }
        let prefix = "com.apple.security.temporary-exception."
        let exceptions = keys.filter { $0.hasPrefix(prefix) }
        if !exceptions.isEmpty {
            let count = exceptions.count
            let names = exceptions.prefix(3).map { String($0.dropFirst(prefix.count)) }.joined(separator: ", ")
                + (exceptions.count > 3 ? ", …" : "")
            warnings.append(.init(.caution, String(
                localized: "\(count) sandbox exceptions (\(names)): the app reaches past its sandbox, and App Review asks why.",
                bundle: .module, comment: "Warning on an entitlements card. Arguments: a count, then the exceptions' key names.")))
        }
        let privateKeys = keys.filter { $0.hasPrefix("com.apple.private.") }
        if !privateKeys.isEmpty {
            let count = privateKeys.count
            let names = privateKeys.prefix(3).joined(separator: ", ") + (privateKeys.count > 3 ? ", …" : "")
            warnings.append(.init(.caution, String(
                localized: "\(count) Apple-private entitlements (\(names)): macOS honours these only in software Apple signs, so in another app they do nothing or stop it from launching.",
                bundle: .module, comment: "Warning on an entitlements card. Arguments: a count, then the key names.")))
        }
        if plist["com.apple.security.app-sandbox"] != nil, !on("com.apple.security.app-sandbox") {
            warnings.append(.init(.caution, String(
                localized: "The App Sandbox is switched off: the app can read and change everything the signed-in user can.",
                bundle: .module, comment: "Warning on an entitlements card.")))
        }
        let sandbox: Bool? = plist["com.apple.security.app-sandbox"].map { isOn($0) }
        return EntitlementsSummary(
            entries: entries, isSandboxed: sandbox, hardenedRuntimeExceptions: runtime,
            unknownKeys: entries.filter { !$0.isKnown }.map(\.key), truncated: keys.count > maxKeys,
            warnings: warnings.sorted { $0.level > $1.level })
    }

    static func isOn(_ value: PlistValue?) -> Bool {
        switch value {
        case .bool(let b): b
        case .integer(let i): i != 0
        case .string(let s): ["yes", "true", "1"].contains(s.lowercased())
        case .array(let a): !a.isEmpty
        case .dictionary(let d): !d.isEmpty
        default: false
        }
    }

    static func text(_ value: PlistValue) -> String {
        switch value {
        case .bool(let b):
            return b ? String(localized: "yes", bundle: .module, comment: "An entitlement's value: switched on.")
                : String(localized: "no", bundle: .module, comment: "An entitlement's value: switched off.")
        case .array(let a):
            if a.isEmpty { return String(localized: "none", bundle: .module, comment: "An entitlement's value: an empty list.") }
            let shown = a.prefix(20).map { item -> String in
                if case .string(let s) = item { return AppleDevText.clip(s, 120) }
                return AppleDevText.clip(item.description, 120)
            }.joined(separator: ", ")
            guard a.count > 20 else { return shown }
            let more = a.count - 20
            return String(localized: "\(shown) … and \(more) more", bundle: .module, comment: "An entitlement's value: the first items of a long list, then how many more.")
        case .dictionary(let d):
            let n = d.count
            return String(localized: "\(n) entries", bundle: .module, comment: "An entitlement's value: a dictionary, shown as how many entries it has.")
        case .string(let s): return AppleDevText.clip(s)
        default: return AppleDevText.clip(value.description)
        }
    }

    /// The table entry for `key`, falling back to the families named by prefix.
    static func describe(_ key: String) -> Known? {
        if let k = known[key] { return k }
        if key.hasPrefix("com.apple.security.temporary-exception.") {
            let rest = String(key.dropFirst("com.apple.security.temporary-exception.".count))
            return Known(name: String(localized: "Sandbox exception: \(rest)", bundle: .module, comment: "Plain name of a sandbox exception entitlement; the argument is the rest of its key."),
                         meaning: String(localized: "Reaches past the sandbox for this one resource (a temporary exception).", bundle: .module, comment: "What an entitlement lets an app do."),
                         category: .sandboxException)
        }
        if key.hasPrefix("com.apple.private.") {
            return Known(name: String(localized: "Apple-private entitlement", bundle: .module, comment: "Plain name of an entitlement only Apple's software may use."),
                         meaning: String(localized: "Reserved for Apple's own software.", bundle: .module, comment: "What an entitlement lets an app do."),
                         category: .privateApple)
        }
        if key.hasPrefix("com.apple.developer.driverkit") {
            return Known(name: String(localized: "DriverKit", bundle: .module, comment: "Plain name of an entitlement (Apple's framework name)."),
                         meaning: String(localized: "Lets a driver extension talk to a kind of hardware.", bundle: .module, comment: "What an entitlement lets an app do."),
                         category: .system)
        }
        if key.hasPrefix("com.apple.developer.carplay") {
            return Known(name: String(localized: "CarPlay", bundle: .module, comment: "Plain name of an entitlement (Apple's feature name)."),
                         meaning: String(localized: "Lets the app show its interface in CarPlay.", bundle: .module, comment: "What an entitlement lets an app do."),
                         category: .services)
        }
        return nil
    }

    /// Common macOS and iOS entitlements: plain name, what each lets the app do, and its family.
    static let known: [String: Known] = {
        func k(_ name: String, _ meaning: String, _ category: EntitlementsSummary.Category) -> Known {
            Known(name: name, meaning: meaning, category: category)
        }
        let debuggable = k(String(localized: "Can be debugged", bundle: .module, comment: "Plain name of an entitlement."),
                           String(localized: "Lets debuggers attach to the app (development builds).", bundle: .module, comment: "What an entitlement lets an app do."), .debugging)
        let appID = k(String(localized: "App ID", bundle: .module, comment: "Plain name of an entitlement."),
                      String(localized: "The team and bundle ID the app is signed as.", bundle: .module, comment: "What an entitlement lets an app do."), .identity)
        let push = k(String(localized: "Push notifications", bundle: .module, comment: "Plain name of an entitlement."),
                     String(localized: "Receives push notifications (development or production server).", bundle: .module, comment: "What an entitlement lets an app do."), .services)
        return [
            // Sandbox and its resources (macOS).
            "com.apple.security.app-sandbox": k(String(localized: "App Sandbox", bundle: .module, comment: "Plain name of an entitlement (Apple's feature name)."), String(localized: "Runs the app in a sandbox that reaches only what the other keys allow.", bundle: .module, comment: "What an entitlement lets an app do."), .sandbox),
            "com.apple.security.inherit": k(String(localized: "Inherits the parent's sandbox", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "A helper tool that runs inside the sandbox of the app that started it.", bundle: .module, comment: "What an entitlement lets an app do."), .sandbox),
            "com.apple.security.network.client": k(String(localized: "Outgoing network connections", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Lets the app connect to servers.", bundle: .module, comment: "What an entitlement lets an app do."), .network),
            "com.apple.security.network.server": k(String(localized: "Incoming network connections", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Lets the app listen for connections, as a server.", bundle: .module, comment: "What an entitlement lets an app do."), .network),
            "com.apple.security.files.user-selected.read-only": k(String(localized: "Files you choose (read only)", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads files and folders you pick in an Open panel or drag in.", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.files.user-selected.read-write": k(String(localized: "Files you choose (read and write)", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads and changes files and folders you pick or drag in.", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.files.user-selected.executable": k(String(localized: "Files you choose can be made executable", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Saved files may be marked as programs that can run.", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.files.downloads.read-only": k(String(localized: "Downloads folder (read only)", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads your Downloads folder.", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.files.downloads.read-write": k(String(localized: "Downloads folder (read and write)", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads and changes your Downloads folder.", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.assets.pictures.read-only": k(String(localized: "Pictures folder (read only)", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads your Pictures folder.", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.assets.pictures.read-write": k(String(localized: "Pictures folder (read and write)", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads and changes your Pictures folder.", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.assets.music.read-only": k(String(localized: "Music folder (read only)", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads your Music folder.", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.assets.music.read-write": k(String(localized: "Music folder (read and write)", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads and changes your Music folder.", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.assets.movies.read-only": k(String(localized: "Movies folder (read only)", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads your Movies folder.", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.assets.movies.read-write": k(String(localized: "Movies folder (read and write)", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads and changes your Movies folder.", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.files.bookmarks.app-scope": k(String(localized: "Remembers file access", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Keeps access to files you chose across launches (app-scoped bookmarks).", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.files.bookmarks.document-scope": k(String(localized: "Remembers files a document uses", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Keeps access to files a document refers to (document-scoped bookmarks).", bundle: .module, comment: "What an entitlement lets an app do."), .files),
            "com.apple.security.device.camera": k(String(localized: "Camera", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Uses the camera.", bundle: .module, comment: "What an entitlement lets an app do."), .devices),
            "com.apple.security.device.microphone": k(String(localized: "Microphone", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Records from the microphone.", bundle: .module, comment: "What an entitlement lets an app do."), .devices),
            "com.apple.security.device.audio-input": k(String(localized: "Audio input", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Records audio, including from the microphone.", bundle: .module, comment: "What an entitlement lets an app do."), .devices),
            "com.apple.security.device.usb": k(String(localized: "USB devices", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Talks to USB devices directly.", bundle: .module, comment: "What an entitlement lets an app do."), .devices),
            "com.apple.security.device.bluetooth": k(String(localized: "Bluetooth", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Talks to Bluetooth devices.", bundle: .module, comment: "What an entitlement lets an app do."), .devices),
            "com.apple.security.device.serial": k(String(localized: "Serial ports", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Talks to serial devices.", bundle: .module, comment: "What an entitlement lets an app do."), .devices),
            "com.apple.security.device.firewire": k(String(localized: "FireWire devices", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Talks to FireWire devices.", bundle: .module, comment: "What an entitlement lets an app do."), .devices),
            "com.apple.security.print": k(String(localized: "Printing", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Prints.", bundle: .module, comment: "What an entitlement lets an app do."), .devices),
            "com.apple.security.smartcard": k(String(localized: "Smart cards", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Uses smart cards and their readers.", bundle: .module, comment: "What an entitlement lets an app do."), .devices),
            "com.apple.security.personal-information.location": k(String(localized: "Location", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Asks where the Mac is.", bundle: .module, comment: "What an entitlement lets an app do."), .personalData),
            "com.apple.security.personal-information.addressbook": k(String(localized: "Contacts", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads and changes your contacts.", bundle: .module, comment: "What an entitlement lets an app do."), .personalData),
            "com.apple.security.personal-information.calendars": k(String(localized: "Calendars", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads and changes your calendars.", bundle: .module, comment: "What an entitlement lets an app do."), .personalData),
            "com.apple.security.personal-information.photos-library": k(String(localized: "Photos library", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads your Photos library.", bundle: .module, comment: "What an entitlement lets an app do."), .personalData),
            "com.apple.security.automation.apple-events": k(String(localized: "Controls other apps", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Sends Apple events to script other apps (you are asked first).", bundle: .module, comment: "What an entitlement lets an app do."), .personalData),
            "com.apple.security.scripting-targets": k(String(localized: "Scripts named apps", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Sends selected Apple events to the apps it names.", bundle: .module, comment: "What an entitlement lets an app do."), .personalData),
            "com.apple.security.application-groups": k(String(localized: "App groups", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Shares a container, preferences and messages with the other apps in these groups.", bundle: .module, comment: "What an entitlement lets an app do."), .identity),
            "com.apple.security.hypervisor": k(String(localized: "Hypervisor", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Runs virtual machines with Hypervisor.framework.", bundle: .module, comment: "What an entitlement lets an app do."), .system),
            "com.apple.security.virtualization": k(String(localized: "Virtualization", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Runs virtual machines with Virtualization.framework.", bundle: .module, comment: "What an entitlement lets an app do."), .system),
            // Hardened runtime.
            "com.apple.security.cs.allow-jit": k(String(localized: "Run-time code generation (JIT)", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Creates executable code while running, as browsers and emulators do.", bundle: .module, comment: "What an entitlement lets an app do."), .hardenedRuntime),
            "com.apple.security.cs.allow-unsigned-executable-memory": k(String(localized: "Unsigned executable memory", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Creates executable memory without code-signing checks.", bundle: .module, comment: "What an entitlement lets an app do."), .hardenedRuntime),
            "com.apple.security.cs.allow-dyld-environment-variables": k(String(localized: "DYLD environment variables", bundle: .module, comment: "Plain name of an entitlement. DYLD stays as is."), String(localized: "Lets DYLD_ variables change which code the app loads at launch.", bundle: .module, comment: "What an entitlement lets an app do."), .hardenedRuntime),
            "com.apple.security.cs.disable-library-validation": k(String(localized: "Loads libraries from anyone", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Loads plug-ins and libraries not signed by the same team.", bundle: .module, comment: "What an entitlement lets an app do."), .hardenedRuntime),
            "com.apple.security.cs.disable-executable-page-protection": k(String(localized: "No executable memory protection", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Switches off executable memory protection entirely.", bundle: .module, comment: "What an entitlement lets an app do."), .hardenedRuntime),
            "com.apple.security.cs.debugger": k(String(localized: "Debugger", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Attaches to other processes as a debugger.", bundle: .module, comment: "What an entitlement lets an app do."), .hardenedRuntime),
            "com.apple.security.get-task-allow": debuggable,
            "get-task-allow": debuggable,
            // Identity.
            "application-identifier": appID,
            "com.apple.application-identifier": appID,
            "com.apple.developer.team-identifier": k(String(localized: "Team ID", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "The developer team that signed the app.", bundle: .module, comment: "What an entitlement lets an app do."), .identity),
            "keychain-access-groups": k(String(localized: "Keychain groups", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Shares saved passwords and keys with the apps in these groups.", bundle: .module, comment: "What an entitlement lets an app do."), .identity),
            "com.apple.developer.associated-domains": k(String(localized: "Associated domains", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Links these websites to the app: universal links, shared passwords, App Clips.", bundle: .module, comment: "What an entitlement lets an app do."), .identity),
            "com.apple.developer.associated-domains.mdm-managed": k(String(localized: "Managed associated domains", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Associated domains set by the organisation that manages the device.", bundle: .module, comment: "What an entitlement lets an app do."), .identity),
            "com.apple.developer.associated-appclip-app-identifiers": k(String(localized: "App Clip", bundle: .module, comment: "Plain name of an entitlement (Apple's feature name)."), String(localized: "The App Clip that belongs to this app.", bundle: .module, comment: "What an entitlement lets an app do."), .identity),
            "com.apple.developer.parent-application-identifiers": k(String(localized: "Parent app", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "The full app this App Clip belongs to.", bundle: .module, comment: "What an entitlement lets an app do."), .identity),
            "com.apple.developer.applesignin": k(String(localized: "Sign in with Apple", bundle: .module, comment: "Plain name of an entitlement (Apple's feature name)."), String(localized: "Lets people sign in with their Apple Account.", bundle: .module, comment: "What an entitlement lets an app do."), .identity),
            "com.apple.developer.authentication-services.autofill-credential-provider": k(String(localized: "Password AutoFill provider", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Offers its saved passwords to other apps and websites.", bundle: .module, comment: "What an entitlement lets an app do."), .identity),
            "com.apple.developer.web-browser": k(String(localized: "Default web browser", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Can be chosen as the default web browser.", bundle: .module, comment: "What an entitlement lets an app do."), .identity),
            "com.apple.developer.default-data-protection": k(String(localized: "Data protection", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "How strongly the app's files are encrypted while the device is locked.", bundle: .module, comment: "What an entitlement lets an app do."), .identity),
            "com.apple.developer.devicecheck.appattest-environment": k(String(localized: "App Attest", bundle: .module, comment: "Plain name of an entitlement (Apple's feature name)."), String(localized: "Proves to its server that requests come from a genuine copy of the app.", bundle: .module, comment: "What an entitlement lets an app do."), .identity),
            // Services.
            "aps-environment": push,
            "com.apple.developer.aps-environment": push,
            "com.apple.developer.usernotifications.time-sensitive": k(String(localized: "Time-sensitive notifications", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Notifications that can break through Focus.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.usernotifications.communication": k(String(localized: "Communication notifications", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Shows messages and calls with the sender's picture.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.usernotifications.critical-alerts": k(String(localized: "Critical alerts", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Alerts that play a sound even when the device is muted.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.icloud-container-identifiers": k(String(localized: "iCloud containers", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Stores data in these iCloud containers.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.icloud-container-development-container-identifiers": k(String(localized: "iCloud development containers", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "iCloud containers used while developing.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.icloud-container-environment": k(String(localized: "iCloud environment", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Which iCloud environment (development or production) the app uses.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.icloud-services": k(String(localized: "iCloud services", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Uses these iCloud services (CloudKit, iCloud Documents).", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.ubiquity-container-identifiers": k(String(localized: "iCloud Drive containers", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Keeps documents in these iCloud Drive containers.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.ubiquity-kvstore-identifier": k(String(localized: "iCloud key-value store", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Syncs small settings through iCloud.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.in-app-payments": k(String(localized: "Apple Pay", bundle: .module, comment: "Plain name of an entitlement (Apple's feature name)."), String(localized: "Takes payments with Apple Pay for these merchant IDs.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.pass-type-identifiers": k(String(localized: "Wallet passes", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Adds and reads Wallet passes of these types.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.healthkit": k(String(localized: "HealthKit", bundle: .module, comment: "Plain name of an entitlement (Apple's framework name)."), String(localized: "Reads or writes Health data (you are asked first).", bundle: .module, comment: "What an entitlement lets an app do."), .personalData),
            "com.apple.developer.healthkit.access": k(String(localized: "Health records", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads clinical health records.", bundle: .module, comment: "What an entitlement lets an app do."), .personalData),
            "com.apple.developer.healthkit.background-delivery": k(String(localized: "Health updates in the background", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Is woken when new Health data arrives.", bundle: .module, comment: "What an entitlement lets an app do."), .personalData),
            "com.apple.developer.homekit": k(String(localized: "HomeKit", bundle: .module, comment: "Plain name of an entitlement (Apple's framework name)."), String(localized: "Controls home accessories.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.siri": k(String(localized: "Siri", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Handles requests from Siri.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.game-center": k(String(localized: "Game Center", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Uses Game Center.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.maps": k(String(localized: "Maps routing", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Provides routes to Maps.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.weatherkit": k(String(localized: "WeatherKit", bundle: .module, comment: "Plain name of an entitlement (Apple's framework name)."), String(localized: "Uses Apple's weather service.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.ClassKit-environment": k(String(localized: "ClassKit", bundle: .module, comment: "Plain name of an entitlement (Apple's framework name)."), String(localized: "Shares progress with Schoolwork.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.nfc.readersession.formats": k(String(localized: "NFC tag reading", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads NFC tags of these formats.", bundle: .module, comment: "What an entitlement lets an app do."), .devices),
            "com.apple.developer.networking.networkextension": k(String(localized: "Network extensions", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Provides VPN, content-filter, DNS or proxy extensions.", bundle: .module, comment: "What an entitlement lets an app do."), .network),
            "com.apple.developer.networking.vpn.api": k(String(localized: "Personal VPN", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Sets up a VPN configuration.", bundle: .module, comment: "What an entitlement lets an app do."), .network),
            "com.apple.developer.networking.wifi-info": k(String(localized: "Wi-Fi information", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads the name of the Wi-Fi network.", bundle: .module, comment: "What an entitlement lets an app do."), .network),
            "com.apple.developer.networking.multicast": k(String(localized: "Multicast networking", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Sends and receives multicast and broadcast traffic on the local network.", bundle: .module, comment: "What an entitlement lets an app do."), .network),
            "com.apple.developer.networking.HotspotConfiguration": k(String(localized: "Hotspot configuration", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Joins Wi-Fi networks it configures.", bundle: .module, comment: "What an entitlement lets an app do."), .network),
            "com.apple.developer.family-controls": k(String(localized: "Screen Time controls", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Uses Family Controls to limit apps and websites.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.kernel.increased-memory-limit": k(String(localized: "More memory", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Asks for a higher memory limit.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.kernel.extended-virtual-addressing": k(String(localized: "Extended address space", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Uses a larger virtual address space.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.user-fonts": k(String(localized: "Installs fonts", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Installs fonts for other apps to use.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.contacts.notes": k(String(localized: "Contact notes", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Reads the notes field of contacts.", bundle: .module, comment: "What an entitlement lets an app do."), .personalData),
            "com.apple.developer.group-session": k(String(localized: "SharePlay", bundle: .module, comment: "Plain name of an entitlement (Apple's feature name)."), String(localized: "Shares activities in FaceTime with SharePlay.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.shared-with-you": k(String(localized: "Shared with You", bundle: .module, comment: "Plain name of an entitlement (Apple's feature name)."), String(localized: "Shows content people shared in Messages.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.coremedia.hls.low-latency": k(String(localized: "Low-latency streaming", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Plays low-latency HLS streams.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.push-to-talk": k(String(localized: "Push to talk", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Works as a walkie-talkie app.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            "com.apple.developer.location.push": k(String(localized: "Location push", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Answers location requests sent by push.", bundle: .module, comment: "What an entitlement lets an app do."), .personalData),
            "com.apple.developer.fileprovider.testing-mode": k(String(localized: "File provider testing", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Test mode for a file provider extension.", bundle: .module, comment: "What an entitlement lets an app do."), .debugging),
            "beta-reports-active": k(String(localized: "TestFlight", bundle: .module, comment: "Plain name of an entitlement (Apple's service name)."), String(localized: "The build can be distributed with TestFlight.", bundle: .module, comment: "What an entitlement lets an app do."), .services),
            // System extensions.
            "com.apple.developer.endpoint-security.client": k(String(localized: "Endpoint Security", bundle: .module, comment: "Plain name of an entitlement (Apple's framework name)."), String(localized: "Watches processes and files across the system, as security tools do.", bundle: .module, comment: "What an entitlement lets an app do."), .system),
            "com.apple.developer.system-extension.install": k(String(localized: "Installs system extensions", bundle: .module, comment: "Plain name of an entitlement."), String(localized: "Installs drivers, network or security extensions.", bundle: .module, comment: "What an entitlement lets an app do."), .system),
            "com.apple.developer.driverkit": k(String(localized: "DriverKit", bundle: .module, comment: "Plain name of an entitlement (Apple's framework name)."), String(localized: "Is a driver extension.", bundle: .module, comment: "What an entitlement lets an app do."), .system),
        ]
    }()
}
