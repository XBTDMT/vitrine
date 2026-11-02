import AppIntents
import Foundation
import VitrineConnector

/// Describe File (X-6): the file's kind, headline, facts and warnings, word for word what the Claude connector's
/// `describe_file` says (ConnectorText.describe over the document the preview is drawn from). roadmap: S-10
struct DescribeFileIntent: AppIntent {
    static let title = LocalizedStringResource("Describe File", comment: "Shortcuts action name: describes a file's kind, facts and warnings.")
    static let description = IntentDescription(
        LocalizedStringResource("Says what a file is: its kind, its summary, its facts and any warnings, as Vitrine's preview reads it. The file is never opened or run.",
                                comment: "Shortcuts action description for Describe File."),
        categoryName: LocalizedStringResource("Read files", comment: "Shortcuts category for Vitrine's actions that read files."))

    @Parameter(title: LocalizedStringResource("File", comment: "Shortcuts parameter: the file the action reads."),
               supportedContentTypes: [.item])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Describe \(\.$file)")
    }

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await run())
    }

    /// The description, for perform and the tests.
    @MainActor
    func run() async throws -> String {
        try await IntentInput.with(file) { input in
            try await Self.describe(input)
        }
    }

    @MainActor
    static func describe(_ input: IntentInput) async throws -> String {
        ConnectorText.describe(try await IntentDocuments.document(for: input), name: input.name, path: input.displayPath)
    }
}
