import AppIntents
import Foundation
import UniformTypeIdentifiers

/// What Extract Table gives back.
enum TableOutput: String, AppEnum {
    case csvFile
    case text

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Table output", comment: "Shortcuts parameter type: what Extract Table gives back."))
    static let caseDisplayRepresentations: [TableOutput: DisplayRepresentation] = [
        .csvFile: DisplayRepresentation(title: LocalizedStringResource("CSV file", comment: "Extract Table output choice: a .csv file.")),
        .text: DisplayRepresentation(title: LocalizedStringResource("Text", comment: "Extract Table output choice: the rows as text (a Markdown table).")),
    ]
}

/// Extract Table (X-6): one table of a CSV, TSV, SQLite, Parquet, Arrow, Feather or Excel file as a CSV file or as
/// text, its rows capped. The table or sheet is picked by name; without one, the first. roadmap: S-10
struct ExtractTableIntent: AppIntent {
    static let title = LocalizedStringResource("Extract Table", comment: "Shortcuts action name: reads the rows of a table from a data file.")
    static let description = IntentDescription(
        LocalizedStringResource("Reads the rows of a table from a CSV, TSV, SQLite, Parquet, Arrow, Feather or Excel file and gives them back as a CSV file or as text. Name a table or sheet, or leave it empty for the first one.",
                                comment: "Shortcuts action description for Extract Table. Format names stay as they are."),
        categoryName: LocalizedStringResource("Read files", comment: "Shortcuts category for Vitrine's actions that read files."))

    @Parameter(title: LocalizedStringResource("File", comment: "Shortcuts parameter: the file the action reads."),
               supportedContentTypes: [.item])
    var file: IntentFile

    @Parameter(title: LocalizedStringResource("Table or sheet", comment: "Shortcuts parameter: the name of the table or sheet to read; empty means the first."))
    var table: String?

    @Parameter(title: LocalizedStringResource("Output", comment: "Shortcuts parameter: what Extract Table gives back."), default: .csvFile)
    var output: TableOutput

    @Parameter(title: LocalizedStringResource("Row limit", comment: "Shortcuts parameter: the most rows Extract Table reads."),
               default: 1_000, inclusiveRange: (1, 100_000))
    var rowLimit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Extract \(\.$table) from \(\.$file) as \(\.$output)") {
            \.$rowLimit
        }
    }

    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        .result(value: try await run())
    }

    @MainActor
    func run() async throws -> IntentFile {
        let output = self.output, wanted = table, limit = rowLimit
        return try await IntentInput.with(file) { input in
            let url = input.url, name = input.name
            // The readers block on the file; they run off the main thread so the app stays responsive.
            let extracted = try await Task.detached(priority: .userInitiated) {
                try TableExtraction.extract(url: url, name: name, table: wanted, limit: limit)
            }.value
            switch output {
            case .csvFile:
                return IntentOutput.file(Data(extracted.csv().utf8), named: IntentOutput.filename(base: extracted.name, extension: "csv"),
                                         type: .commaSeparatedText)
            case .text:
                return IntentOutput.file(Data(extracted.markdown().utf8), named: IntentOutput.filename(base: extracted.name, extension: "txt"),
                                         type: .utf8PlainText)
            }
        }
    }
}
