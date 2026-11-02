import Foundation
import VitrinePreviewKit

/// Spotlight runs an importer only on files that are new or changed, so the databases, notebooks and archives already
/// on a Mac would stay unsearchable after Vitrine's importer arrives (S-19, X-8). Once per importer version (the app's
/// build), the app asks Spotlight to re-read the types the importer claims, as `mdimport -r` documents; Spotlight does
/// the reading on its own schedule, on this Mac. roadmap: S-19
enum SpotlightReimport {
    static let key = "spotlight.reimportedBuild"

    /// The importer inside this copy of Vitrine.
    static var importer: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Spotlight/Vitrine.mdimporter") }

    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") + " (" +
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") + ")"
    }

    static func isNeeded(stored: String?, current: String) -> Bool { stored != current }

    /// Asks once for this build; a failed request is asked again at the next launch.
    @MainActor
    static func runIfNeeded() {
        let current = build
        guard isNeeded(stored: VitrineDefaults.shared.string(forKey: key), current: current),
              FileManager.default.fileExists(atPath: importer.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
        process.arguments = ["-r", importer.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { done in
            guard done.terminationStatus == 0 else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { VitrineDefaults.shared.set(current, forKey: key) } }
        }
        try? process.run()
    }
}
