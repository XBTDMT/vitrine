import AppIntents
import Foundation
import VitrineDocument

/// What Count Tokens counts.
enum TokenInput: String, AppEnum {
    case file
    case text

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Count input", comment: "Shortcuts parameter type: whether Count Tokens counts a file or text."))
    static let caseDisplayRepresentations: [TokenInput: DisplayRepresentation] = [
        .file: DisplayRepresentation(title: LocalizedStringResource("File", comment: "Count Tokens input choice: a file.")),
        .text: DisplayRepresentation(title: LocalizedStringResource("Text", comment: "Count Tokens input choice: text typed or passed in.")),
    ]
}

/// Count Tokens (X-6): about how many language-model tokens a file or a text is, with the counter the preview's token
/// meter uses (TokenCounting) and the meter's own words (TokenMeter): the number, whether it is an estimate, the share
/// of the common context windows and how it was counted. The value is the number, for a shortcut to compare.
/// roadmap: S-10
struct CountTokensIntent: AppIntent {
    static let title = LocalizedStringResource("Count Tokens", comment: "Shortcuts action name: estimates the language-model tokens in a file or text.")
    static let description = IntentDescription(
        LocalizedStringResource("Estimates how many language-model tokens a file or a text takes, with the same count as Vitrine's token meter, and how much of a context window that is.",
                                comment: "Shortcuts action description for Count Tokens."),
        categoryName: LocalizedStringResource("Read files", comment: "Shortcuts category for Vitrine's actions that read files."))

    @Parameter(title: LocalizedStringResource("Count", comment: "Shortcuts parameter: whether to count a file or text."), default: .file)
    var input: TokenInput

    @Parameter(title: LocalizedStringResource("File", comment: "Shortcuts parameter: the file the action reads."),
               supportedContentTypes: [.item])
    var file: IntentFile?

    @Parameter(title: LocalizedStringResource("Text", comment: "Shortcuts parameter: the text Count Tokens counts."),
               inputOptions: String.IntentInputOptions(multiline: true))
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Switch(\.$input) {
            Case(.text) {
                Summary("Count tokens in \(\.$text)") { \.$input }
            }
            DefaultCase {
                Summary("Count tokens in \(\.$file)") { \.$input }
            }
        }
    }

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let (count, report) = try await run()
        return .result(value: count.value, dialog: IntentDialog(LocalizedStringResource(stringLiteral: report)))
    }

    /// The count and the sentence said with it, for perform and the tests.
    @MainActor
    func run() async throws -> (TokenCount, String) {
        switch input {
        case .text:
            guard let text, !text.isEmpty else { throw VitrineIntentError.noText }
            let count = TokenCounting.count(.text(text))
            return (count, Self.report(count, name: nil))
        case .file:
            return try await IntentInput.with(file) { input in
                let count = try await Self.count(input)
                return (count, Self.report(count, name: input.name))
            }
        }
    }

    /// The count the preview's meter shows for the file: the renderer's own when it made one (from the file's size for
    /// text, from the readable text for notebooks), otherwise the default counter over the text Vitrine reads from it
    /// (a table's rows, an app's facts) — the file's own words for a text file, as the connector counts them.
    @MainActor
    static func count(_ input: IntentInput) async throws -> TokenCount {
        let document = try await IntentDocuments.document(for: input)
        if let tokens = document.tokens { return tokens }
        let text = ConnectorWorker.fileText(input.url, kind: document.kind) ?? document.searchText
        return TokenCounting.count(.text(text))
    }

    /// "notes.md: ≈ 1,250 Claude tokens, estimate · 0.6% of a 200K window · 0.1% of a 1M window. Estimated at about …"
    static func report(_ count: TokenCount, name: String?) -> String {
        let meter = TokenMeter(count)
        let number = "\(meter.number) \(meter.unit)"
        let headline = name.map {
            String(localized: "\($0): \(number)", comment: "Count Tokens result. Arguments: the file's name, then the count with its label, such as “≈ 1,250 Claude tokens, estimate”.")
        } ?? number
        let rows = meter.rows.map(\.text).joined(separator: " · ")
        return String(localized: "\(headline) · \(rows). \(meter.method)",
                      comment: "Count Tokens result sentence. Arguments: the count (with the file's name), the shares of the context windows, then how the count was made.")
    }
}
