import AppKit

/// The Diagnostics window's repair actions (S-10, H-4). Each one changes system registration state, so each runs only
/// from a click in the window (a Use Vitrine sheet is confirmed first) and is never called by tests or at launch.
enum DiagnosticsRepair {
    static let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

    struct Outcome: Sendable {
        let ok: Bool
        let message: String
    }

    private static func run(_ tool: String, _ args: [String]) -> DiagnosticsProbe.ToolResult {
        DiagnosticsProbe.run(tool, args, timeout: 60)
    }

    private static func outcome(_ results: [DiagnosticsProbe.ToolResult], ok: String, failed: String) -> Outcome {
        if let bad = results.first(where: { $0.status != 0 }) {
            let detail = bad.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = String(detail.prefix(160))
            return Outcome(ok: false, message: detail.isEmpty ? failed
                           : String(localized: "\(failed): \(shown)", comment: "Diagnostics: a repair's failure, then what the macOS tool printed"))
        }
        return Outcome(ok: true, message: ok)
    }

    /// The running app's own Quick Look extensions.
    static func ownExtensionPaths() -> [String] {
        guard let dir = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "appex" }.map(\.path).sorted()
    }

    /// Re-register Vitrine with macOS: Launch Services registration of this app (`lsregister -f`), then each of its
    /// extensions with PlugInKit (`pluginkit -a`). Nothing is deleted.
    static func reRegister() -> Outcome {
        var results = [run(lsregisterPath, ["-f", Bundle.main.bundlePath])]
        let paths = ownExtensionPaths()
        if !paths.isEmpty { results.append(run(DiagnosticsProbe.pluginkitPath, ["-a"] + paths)) }
        return outcome(results, ok: String(localized: "Vitrine is registered again", comment: "Diagnostics: message after Re-register"),
                       failed: String(localized: "Registration failed", comment: "Diagnostics: message when Re-register fails"))
    }

    /// Restart Quick Look: `qlmanage -r` resets the Quick Look server and reloads its previewers.
    static func restartQuickLook() -> Outcome {
        outcome([run(DiagnosticsProbe.qlmanagePath, ["-r"])],
                ok: String(localized: "Quick Look restarted", comment: "Diagnostics: message after Restart Quick Look"),
                failed: String(localized: "Quick Look did not restart", comment: "Diagnostics: message when Restart Quick Look fails"))
    }

    /// Clear thumbnail cache: `qlmanage -r cache`.
    static func clearThumbnailCache() -> Outcome {
        outcome([run(DiagnosticsProbe.qlmanagePath, ["-r", "cache"])],
                ok: String(localized: "Thumbnail cache cleared", comment: "Diagnostics: message after Clear thumbnail cache"),
                failed: String(localized: "The cache was not cleared", comment: "Diagnostics: message when Clear thumbnail cache fails"))
    }

    /// Set another app's extension aside so Vitrine answers (`pluginkit -e ignore -i <id>`); `undo` puts it back
    /// with `pluginkit -e use -i <id>`.
    static func setAside(_ identifiers: [String]) -> Outcome {
        outcome(identifiers.map { run(DiagnosticsProbe.pluginkitPath, ["-e", "ignore", "-i", $0]) },
                ok: String(localized: "Set aside", comment: "Diagnostics: message after another app's extension is set aside"),
                failed: String(localized: "The other extension was not set aside", comment: "Diagnostics: message when Use Vitrine fails"))
    }

    static func undoSetAside(_ identifiers: [String]) -> Outcome {
        outcome(identifiers.map { run(DiagnosticsProbe.pluginkitPath, ["-e", "use", "-i", $0]) },
                ok: String(localized: "Put back", comment: "Diagnostics: message after Undo puts another app's extension back"),
                failed: String(localized: "The other extension was not put back", comment: "Diagnostics: message when Undo fails"))
    }

    /// Unregister another copy of Vitrine: remove its extensions from PlugInKit (`pluginkit -r`) and the app from
    /// Launch Services (`lsregister -u`). The copy's files stay where they are.
    static func unregister(_ copy: OtherCopy) -> Outcome {
        var results: [DiagnosticsProbe.ToolResult] = []
        if !copy.extensionPaths.isEmpty { results.append(run(DiagnosticsProbe.pluginkitPath, ["-r"] + copy.extensionPaths)) }
        if FileManager.default.fileExists(atPath: copy.appPath) { results.append(run(lsregisterPath, ["-u", copy.appPath])) }
        return outcome(results, ok: String(localized: "Unregistered", comment: "Diagnostics: message after Unregister"),
                       failed: String(localized: "Unregister failed", comment: "Diagnostics: message when Unregister fails"))
    }

    @MainActor static func showInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()]) }
    }
}
