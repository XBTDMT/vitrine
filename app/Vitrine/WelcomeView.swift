import ServiceManagement
import SwiftUI
import VitrinePreviewKit

struct WelcomeView: View {
    @ObservedObject private var diagnostics = Diagnostics.shared
    @ObservedObject private var helper = HelperLifecycle.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.and.text.magnifyingglass")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Vitrine").font(.system(size: 26, weight: .semibold))
                    Text("Press Space on a file in Finder. It just renders.").foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Quick Look extensions").font(.headline)
            ForEach(diagnostics.extensions) { ext in
                HStack {
                    Image(systemName: ext.enabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(ext.enabled ? Color.green : Color.secondary)
                    Text(ext.name)
                    Spacer()
                    Text(ext.state.title).foregroundStyle(.secondary).font(.caption)
                }
            }
            if diagnostics.extensions.contains(where: { !$0.enabled }) {
                Text("If an extension is not registered, move Vitrine to /Applications, open it once, then enable it under System Settings › General › Login Items & Extensions › Quick Look.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HelperRow(helper: helper)
            Spacer()
            HStack {
                Button("Open Quick Look Settings…") { diagnostics.openExtensionsSettings() }
                Button("Diagnostics…") { openWindow(id: "diagnostics") }
                Spacer()
                Button("Re-check") { diagnostics.refreshExtensionStatus() }
            }
        }
        .padding(28)
        .task { await helper.refresh() }
        .onAppear {
            // `Vitrine --diagnostics` (S-10): open the Diagnostics window once the app is up.
            if DiagnosticsStore.openOnLaunch {
                DiagnosticsStore.openOnLaunch = false
                openWindow(id: "diagnostics")
            }
        }
    }
}

/// VitrineHelper's row (X-3, onboarding r3-a step 4): what it is for, whether it is on and answering, and the switch.
/// Turning it on registers a background item; macOS says so and lists it in Login Items. roadmap: S-10 (X-3)
struct HelperRow: View {
    @ObservedObject var helper: HelperLifecycle

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: helper.isWorking ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(helper.isWorking ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vitrine Helper").font(.headline)
                Text("Lets previews open files in other apps, reveal them in Finder, open links and code at a line, extract one file from an archive, and make on-device summaries. Runs in the background; nothing leaves this Mac.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(Self.status(helper)).font(.caption).foregroundStyle(helper.isWorking ? Color.secondary : Color.orange)
            }
            Spacer()
            if helper.state == .enabled {
                Button("Turn Off") { Task { await helper.turnOff() } }
            } else if helper.state == .requiresApproval {
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            } else {
                Button("Turn On") { Task { await helper.turnOn() } }.buttonStyle(.borderedProminent)
            }
        }
    }

    static func status(_ helper: HelperLifecycle) -> String {
        if let error = helper.lastError { return error }
        switch helper.state {
        case .enabled: return helper.answered != nil ? String(localized: "On and answering", comment: "Welcome › Vitrine Helper: status")
                                                     : String(localized: "On, but not answering yet", comment: "Welcome › Vitrine Helper: status")
        case .requiresApproval: return String(localized: "Waiting for approval in System Settings › General › Login Items", comment: "Welcome › Vitrine Helper: status")
        case .notFound: return String(localized: "Missing from this copy of Vitrine", comment: "Welcome › Vitrine Helper: status")
        case .notRegistered: return String(localized: "Off", comment: "Welcome › Vitrine Helper: status")
        }
    }
}
