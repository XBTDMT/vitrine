import AppKit
import OSLog

/// "Open in…" (chrome): the apps that can open the previewed file, the default first. Launch Services decides
/// the list; the capsule hides the menu when it comes back empty, which a sandboxed extension may see. roadmap: S-24
struct OpenInApp: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let isDefault: Bool
    var id: URL { url }
}

@MainActor
enum OpenIn {
    private static let log = Logger(subsystem: "io.github.xbtdmt.vitrine", category: "chrome")

    static func apps(for file: URL, limit: Int = 12) -> [OpenInApp] {
        let workspace = NSWorkspace.shared
        let fallback = workspace.urlForApplication(toOpen: file)
        var seen = Set<String>()
        var apps: [OpenInApp] = []
        for url in [fallback].compactMap({ $0 }) + workspace.urlsForApplications(toOpen: file) {
            let id = Bundle(url: url)?.bundleIdentifier ?? url.path
            guard seen.insert(id).inserted, !id.hasPrefix("io.github.xbtdmt.vitrine") else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            apps.append(OpenInApp(url: url, name: name, isDefault: url == fallback))
            if apps.count == limit { break }
        }
        log.info("open in: \(apps.count, privacy: .public) apps")
        return apps
    }

    static func open(_ file: URL, with app: OpenInApp) {
        NSWorkspace.shared.open([file], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { log.error("open in failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)") }
        }
    }
}
