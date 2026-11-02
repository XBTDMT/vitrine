import AppIntents
import Foundation

/// Check Signature (X-6): who signed an app, installer package, disk image or Mach-O binary, whether it is notarized and
/// what Gatekeeper would do (SignatureCheck). The file is never run. roadmap: S-10
struct CheckSignatureIntent: AppIntent {
    static let title = LocalizedStringResource("Check Signature", comment: "Shortcuts action name: reports who signed an app, installer, disk image or binary.")
    static let description = IntentDescription(
        LocalizedStringResource("Says who signed an app, installer package, disk image or Mach-O binary, whether Apple notarized it and what Gatekeeper would do when it first opens. The file is never run, and nothing is looked up online.",
                                comment: "Shortcuts action description for Check Signature."),
        categoryName: LocalizedStringResource("Read files", comment: "Shortcuts category for Vitrine's actions that read files."))

    @Parameter(title: LocalizedStringResource("File", comment: "Shortcuts parameter: the file the action reads."),
               supportedContentTypes: [.item])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Check the signature of \(\.$file)")
    }

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await run().text)
    }

    @MainActor
    func run() async throws -> SignatureCheck {
        try await IntentInput.with(file) { input in
            let url = input.url, name = input.name
            // A deep check of a large app takes seconds: off the main thread.
            return try await Task.detached(priority: .userInitiated) { try SignatureCheck.read(url: url, name: name) }.value
        }
    }
}
