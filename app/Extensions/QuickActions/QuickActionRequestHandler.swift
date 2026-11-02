import AppKit
import UniformTypeIdentifiers

/// The principal class of the four Quick Action extensions (X-5). Finder hands it the selection; it reads the file
/// URLs and does the action this bundle is (QuickAction.current): Copy as Prompt here, the others through the app's
/// Services entry. It shows no interface and returns nothing, so Finder never changes the files. roadmap: S-10 (X-5)
final class QuickActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let box = ContextBox(context)
        Task { @MainActor in
            let providers = (box.context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            let urls = await Self.fileURLs(from: providers)
            do {
                try Self.perform(QuickAction.current(), on: urls, pasteboard: .general)
                box.context.completeRequest(returningItems: nil, completionHandler: nil)
            } catch {
                box.context.cancelRequest(withError: error)
            }
        }
    }

    /// Runs `action` on `urls`. Copy as Prompt writes `pasteboard`; the others hand the files to the app.
    @MainActor
    static func perform(_ action: QuickAction?, on urls: [URL], pasteboard: NSPasteboard,
                        performService: (String, NSPasteboard) -> Bool = { NSPerformService($0, $1) }) throws {
        guard let action else { throw Failure.unknownAction }
        guard !urls.isEmpty else { throw Failure.noFiles }
        let files = Array(urls.prefix(QuickAction.maxFiles))
        guard let service = action.serviceName else {
            PromptCopy.write(PromptCopy.build(files), to: pasteboard)
            return
        }
        // A private pasteboard carries the selection to the app's service; it is released when the call returns.
        let carrier = NSPasteboard(name: NSPasteboard.Name("io.github.xbtdmt.vitrine.quickaction.\(UUID().uuidString)"))
        defer { carrier.releaseGlobally() }
        carrier.clearContents()
        carrier.writeObjects(files as [NSURL])
        guard performService(service, carrier) else { throw Failure.appUnreachable }
    }

    /// The file URLs among the host's attachments, in order.
    ///
    /// What the extension may then read is decided by the sandbox, not here (S-16, F44): the Quick Actions carry no
    /// read exception (Config/QuickAction.entitlements, the sandbox only), so a file is readable only when the item
    /// provider handed the extension a sandbox extension for it, which the system issues with the host's own rights.
    /// A path the host merely names, in whatever form, is refused by the sandbox and comes out as "cannot be read".
    /// (A provider made from a file, as Finder's are, delivers its URL as bytes, so both forms are taken.)
    @MainActor
    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) else { continue }
            if let url = item as? URL, url.isFileURL { urls.append(url) }
            else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL { urls.append(url) }
        }
        return urls
    }

    enum Failure: LocalizedError, Equatable {
        case unknownAction, noFiles, appUnreachable

        var errorDescription: String? {
            switch self {
            case .unknownAction:
                return String(localized: "This Vitrine Quick Action does not know what to do.",
                              comment: "Finder Quick Action error: the extension bundle names no action (a build fault).")
            case .noFiles:
                return String(localized: "Select one or more files in Finder first.",
                              comment: "Finder Quick Action error: Finder passed no files to the action.")
            case .appUnreachable:
                return String(localized: "Vitrine did not answer. Open Vitrine once, then try again.",
                              comment: "Finder Quick Action error: the Vitrine app's service could not be reached.")
            }
        }
    }
}

/// NSExtensionContext is not Sendable; the request's context is only touched on the main actor.
private final class ContextBox: @unchecked Sendable {
    let context: NSExtensionContext
    init(_ context: NSExtensionContext) { self.context = context }
}
