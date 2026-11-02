import Foundation
import ServiceManagement
import VitrineHelperKit
import VitrinePreviewKit

/// `Vitrine --helper register|unregister|status|ping|reconcile` (X-3): registers VitrineHelper with SMAppService, removes it,
/// says its state, or calls it over XPC. Settings and Diagnostics use the same calls; this is their command-line form
/// for tests and support. roadmap: S-10 (X-3)
enum HelperControl {
    static var service: SMAppService { SMAppService.agent(plistName: HelperService.launchAgentPlistName) }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "requires approval in System Settings › General › Login Items"
        case .notFound: "not found (the property list is missing from the app)"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    /// Runs the command and exits the process.
    @MainActor static func run(_ command: String) {
        switch command {
        case "register":
            do { try service.register(); print("registered: \(describe(service.status))"); exit(0) }
            catch { FileHandle.standardError.write(Data("register failed: \(error)\n".utf8)); exit(1) }
        case "unregister":
            Task { @MainActor in
                do { try await service.unregister(); print("unregistered: \(describe(service.status))"); exit(0) }
                catch { FileHandle.standardError.write(Data("unregister failed: \(error)\n".utf8)); exit(1) }
            }
        case "status":
            print(describe(service.status)); exit(0)
        case "ping":
            Task { @MainActor in
                guard let answer = await HelperLifecycle.ping(timeout: 10) else {
                    FileHandle.standardError.write(Data("the helper did not answer\n".utf8)); exit(2)
                }
                let current = answer.fingerprint == HelperLifecycle.bundledFingerprint ? "this build" : "another build"
                print("helper answered: protocol \(answer.version), executable \(answer.fingerprint) (\(current))"); exit(0)
            }
        case "reconcile":
            Task { @MainActor in
                await HelperLifecycle.shared.reconcileAtLaunch()
                print("\(describe(service.status)); answering: \(HelperLifecycle.shared.answered != nil ? "yes" : "no")"); exit(0)
            }
        case "summarize", "open", "link", "extract":
            Task { @MainActor in await runAction(command, Array(CommandLine.arguments.drop { $0 != command }.dropFirst())) }
        default:
            FileHandle.standardError.write(Data("usage: Vitrine --helper register|unregister|status|ping|reconcile|summarize <file>|open <file> <app>|link <url>|extract <archive> <member>\n".utf8)); exit(64)
        }
    }

    /// The helper's actions from the command line, for support and tests: each prints the outcome or the refusal.
    @MainActor static func runAction(_ command: String, _ args: [String]) async {
        func finish(_ error: String?, _ ok: String) -> Never {
            if let error { FileHandle.standardError.write(Data("refused: \(error)\n".utf8)); exit(3) }
            print(ok); exit(0)
        }
        switch (command, args.count) {
        case ("summarize", 1...):
            guard let text = try? String(contentsOf: URL(fileURLWithPath: args[0]), encoding: .utf8) else { finish("unreadable file", "") }
            let result = await HelperClient.summarize(text)
            finish(result.error, result.summary ?? "")
        case ("open", 2...):
            finish(await HelperClient.open(URL(fileURLWithPath: args[0]), with: URL(fileURLWithPath: args[1])), "opened")
        case ("link", 1...):
            finish(await HelperClient.openLink(args[0]), "opened")
        case ("extract", 2...):
            let result = await HelperClient.extract(member: args[1], from: URL(fileURLWithPath: args[0]))
            finish(result.error, "saved to \(result.destination?.path ?? "?")")
        default:
            FileHandle.standardError.write(Data("missing arguments for \(command)\n".utf8)); exit(64)
        }
    }
}
