import SwiftUI
import VitrineEngineering

/// Settings › Privacy › Advisory lists on this Mac (G-26): what is installed and when, the download in progress, and
/// Update Now / Cancel. roadmap: S-22
struct AdvisoryUpdateControl: View {
    @ObservedObject private var updater = AdvisoryUpdater.shared
    @AppStorage("advisories.enabled", store: UserDefaults(suiteName: AdvisoryStore.suite)) private var enabled = false

    var body: some View {
        HStack(spacing: 10) {
            Text(status).font(.v("caption")).foregroundStyle(Color.token("t2")).lineLimit(2).multilineTextAlignment(.trailing)
            if updater.isBusy {
                Button { updater.cancel() } label: { Text("Cancel", comment: "Settings › Privacy: stops a vulnerability list download.") }.buttonStyle(.vitrine)
            } else {
                Button { updater.updateNow() } label: { Text("Update Now", comment: "Settings › Privacy: downloads the chosen vulnerability lists.") }
                    .buttonStyle(.vitrine).disabled(!enabled)
            }
        }
    }

    var status: String {
        switch updater.phase {
        case .downloading(let e, let fraction):
            let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
            return String(localized: "Downloading \(e.rawValue) · \(percent)", comment: "Settings › Privacy: a vulnerability list is downloading; the ecosystem and how far.")
        case .building(let e):
            return String(localized: "Indexing \(e.rawValue)…", comment: "Settings › Privacy: a downloaded vulnerability list is being indexed.")
        case .failed(let message):
            return message
        case .idle:
            guard !updater.installed.isEmpty else {
                return String(localized: "None yet", comment: "Settings › Privacy: no vulnerability list is installed.")
            }
            let oldest = updater.installed.values.map(\.builtAt).min() ?? Date()
            let names = updater.installed.keys.map(\.rawValue).sorted().joined(separator: ", ")
            let date = oldest.formatted(date: .abbreviated, time: .omitted)
            return String(localized: "\(names) · updated \(date)", comment: "Settings › Privacy: the installed vulnerability lists and the oldest update date.")
        }
    }
}
