import AppKit
import Combine

/// Knows whether each Vitrine Quick Look extension is registered with the system, and can send the user to the
/// place to turn one on. Reads pluginkit, the same source the Extensions settings pane uses.
@MainActor
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()

    /// The raw value is the English word `--diagnose` prints; `title` is what the window shows.
    enum State: String, Sendable {
        case enabled = "Enabled", disabled = "Disabled", automatic = "Default (system picks)", missing = "Not registered"

        var title: String {
            switch self {
            case .enabled: String(localized: "Enabled", comment: "Welcome window: a Quick Look extension's state")
            case .disabled: String(localized: "Disabled", comment: "Welcome window: a Quick Look extension's state")
            case .automatic: String(localized: "Default (system picks)", comment: "Welcome window: a Quick Look extension's state, the user never chose")
            case .missing: String(localized: "Not registered", comment: "Welcome window: a Quick Look extension's state, macOS does not list it")
            }
        }
    }

    struct ExtensionStatus: Identifiable, Sendable {
        let id: String
        let name: String
        let state: State
        var enabled: Bool { state == .enabled || state == .automatic }
    }

    /// Each extension's identifier and its short name, as the Welcome window, the menu and Settings show it.
    nonisolated static let identifiers: [(String, String)] = [
        ("io.github.xbtdmt.vitrine.quicklook.markdown", "Markdown"),
        ("io.github.xbtdmt.vitrine.quicklook.code", String(localized: "Code", comment: "Short name of Vitrine's Quick Look extension for source code")),
        ("io.github.xbtdmt.vitrine.quicklook.data", String(localized: "Data", comment: "Short name of Vitrine's Quick Look extension for data files (CSV, SQLite)")),
        ("io.github.xbtdmt.vitrine.quicklook.packages", String(localized: "Packages", comment: "Short name of Vitrine's Quick Look extension for archives, apps and disk images")),
        ("io.github.xbtdmt.vitrine.quicklook.folders", String(localized: "Folders", comment: "Short name of Vitrine's Quick Look extension for folders")),
    ]

    @Published private(set) var extensions: [ExtensionStatus] = identifiers.map { .init(id: $0.0, name: $0.1, state: .missing) }

    func refreshExtensionStatus() {
        Task.detached {
            let output = Self.pluginkitMatches()
            let statuses = Self.statuses(from: output)
            await MainActor.run { self.extensions = statuses }
        }
    }

    /// pluginkit -m -v prints one line per plug-in: an optional state character ("+" the user enabled it, "-" the
    /// user disabled it, "!" unelected), then the identifier(version).
    nonisolated static func statuses(from output: [String]) -> [ExtensionStatus] {
        identifiers.map { id, name in
            guard let line = output.first(where: { $0.contains(id + "(") }) else {
                return ExtensionStatus(id: id, name: name, state: .missing)
            }
            let state: State
            switch line.first {
            case "+": state = .enabled
            case "-", "!": state = .disabled
            default: state = .automatic
            }
            return ExtensionStatus(id: id, name: name, state: state)
        }
    }

    nonisolated static func pluginkitMatches() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = ["-m", "-p", "com.apple.quicklook.preview", "-v"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func openExtensionsSettings() { Self.openQuickLookSettings() }

    nonisolated static func openQuickLookSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?QuickLook") {
            NSWorkspace.shared.open(url)
        }
    }

    /// "0.1.0 (1)", for the Diagnostics sidebar strip and the report.
    nonisolated static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?", build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// "27.2 (26C61)": the marketing version and the build, read from the system version file.
    nonisolated static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let short = v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let plist = NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist")
        if let build = plist?["ProductBuildVersion"] as? String { return "\(short) (\(build))" }
        return short
    }

    /// One line per owner for `--diagnose types`.
    nonisolated static func describe(_ owner: TypeOwner) -> String {
        switch owner {
        case .vitrine(let id): "Vitrine (\(id.components(separatedBy: ".").last ?? id))"
        case .otherApp(let id, let name, let app, let version): "other app: \(app) \(version) · \(name) (\(id))"
        case .macOS(let reason): "macOS: \(reason)"
        case .fallback(let id): "fallback: no previewer (\(id) not on)"
        case .notAsked(let reason): "not asked: \(reason)"
        }
    }
}
