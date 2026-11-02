import AppKit

/// The process's entry point. The connector's worker (`--mcp-call`, X-9, G-22) runs before SwiftUI starts, so it never
/// creates the app's scenes (the Welcome window), its menu bar or its background parts; everything else is the app.
/// roadmap: S-11
@main
enum VitrineMain {
    @MainActor
    static func main() {
        if ConnectorWorker.isRequested { ConnectorWorker.run() }
        // A command run (`--helper …`, `--diagnose`, `--snapshot …`) is not a session to restore. With restoration on,
        // a run that ended abnormally made every later launch stop at macOS's "reopen windows?" alert, which a command
        // cannot answer (measured 2026-11-02: `--helper status` waited in NSAlert runModal until killed).
        if isCommandRun(CommandLine.arguments) { UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true]) }
        VitrineApp.main()
    }

    /// Whether the process was started as a command: any argument after the executable that starts with "--".
    /// Finder and Xcode pass single-dash arguments (`-psn_…`, `-NSDocumentRevisionsDebugMode`).
    static func isCommandRun(_ arguments: [String]) -> Bool { arguments.dropFirst().contains { $0.hasPrefix("--") } }
}
