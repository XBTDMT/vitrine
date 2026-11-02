import AppIntents
import Foundation
import UniformTypeIdentifiers
import VitrineDocument
import VitrinePreviewKit

// What every Vitrine App Intent shares (X-6): the file Shortcuts or Spotlight hands over, the errors in plain sentences,
// and the files the intents give back. The intents read with the engines the previews and the Claude connector already
// use (ConnectorWorker, ConnectorText, VitrineData, VitrineBinary, PreviewExport); nothing here parses a format.
// Vitrine never runs, opens or mounts the file it is given. roadmap: S-10

/// Why an intent could not answer, in sentences a person reads in Shortcuts or Spotlight.
enum VitrineIntentError: Error, Equatable, LocalizedError, CustomLocalizedStringResourceConvertible {
    /// No file reached the intent.
    case noFile
    /// The file could not be read at all.
    case unreadable(name: String)
    /// Vitrine has no preview for this kind of file.
    case unsupported(name: String)
    /// Extract Table was given a file that holds no table.
    case notATable(name: String)
    /// The file has tables, but none by the name asked for.
    case tableNotFound(name: String, requested: String, available: [String])
    /// A database or workbook with nothing in it to read.
    case noTables(name: String)
    /// Count Tokens was asked to count text and given none.
    case noText
    /// Check Signature was given something that carries no code signature.
    case notSignable(name: String)
    /// HTML and PDF come from Markdown only.
    case needsMarkdown(name: String)
    /// A reader or the export failed; the reason is the engine's own sentence.
    case failed(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .noFile:
            return String(localized: "Choose a file for Vitrine to read.",
                          comment: "Shortcuts error: the action ran without a file.")
        case .unreadable(let name):
            return String(localized: "Vitrine could not read “\(name)”.",
                          comment: "Shortcuts error; the argument is the file's name.")
        case .unsupported(let name):
            return String(localized: "Vitrine has no preview for “\(name)”.",
                          comment: "Shortcuts error: Vitrine does not read this kind of file; the argument is the file's name.")
        case .notATable(let name):
            return String(localized: "“\(name)” is not a table. Extract Table reads CSV, TSV, SQLite, Parquet, Arrow, Feather and Excel files.",
                          comment: "Shortcuts error for Extract Table; the argument is the file's name. Format names stay as they are.")
        case .tableNotFound(let name, let requested, let available):
            let list = available.formatted(.list(type: .and, width: .narrow))
            return String(localized: "“\(name)” has no table or sheet named “\(requested)”. It has \(list).",
                          comment: "Shortcuts error for Extract Table. Arguments: the file's name, the name asked for, then the names it has as a list.")
        case .noTables(let name):
            return String(localized: "“\(name)” has no tables or sheets to read.",
                          comment: "Shortcuts error for Extract Table: an empty database or workbook; the argument is the file's name.")
        case .noText:
            return String(localized: "Give Count Tokens a file or some text to count.",
                          comment: "Shortcuts error: Count Tokens ran with nothing to count.")
        case .notSignable(let name):
            return String(localized: "“\(name)” is not an app, installer package, disk image or Mach-O binary, so it carries no code signature to check.",
                          comment: "Shortcuts error for Check Signature; the argument is the file's name.")
        case .needsMarkdown(let name):
            return String(localized: "Only Markdown converts to HTML or PDF. “\(name)” can be converted to a PNG picture.",
                          comment: "Shortcuts error for Convert; the argument is the file's name.")
        case .failed(let name, let reason):
            return String(localized: "Vitrine could not read “\(name)”: \(reason)",
                          comment: "Shortcuts error. Arguments: the file's name, then the reason in the reader's own words.")
        }
    }

    /// What Shortcuts and Spotlight show: the sentence above, already in the person's language.
    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: errorDescription ?? "")
    }

    /// A reader's error as the intent reports it: the engine's own sentence when it has one.
    static func wrapping(_ error: Error, name: String) -> VitrineIntentError {
        if let own = error as? VitrineIntentError { return own }
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return .failed(name: name, reason: reason)
    }
}

/// The file an intent was given, as a path the engines can read. A file Shortcuts passes by reference is read where it
/// is; one passed only as data (text from another action, a file from the web) is written to a private temporary
/// folder for the call and removed afterwards.
@MainActor
struct IntentInput {
    /// Where the engines read the file.
    let url: URL
    /// The name the person knows the file by.
    let name: String
    /// The path `describe` prints: the file's own path, or its name when it arrived as data.
    let displayPath: String

    static func with<T>(_ file: IntentFile?, _ body: (IntentInput) async throws -> T) async throws -> T {
        guard let file else { throw VitrineIntentError.noFile }
        if let url = file.fileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VitrineIntentError.unreadable(name: url.lastPathComponent)
            }
            return try await body(IntentInput(url: url, name: url.lastPathComponent, displayPath: url.path))
        }
        let name = safeName(file.filename)
        let folder = try IntentOutput.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        do { try file.data.write(to: url, options: .atomic) } catch { throw VitrineIntentError.unreadable(name: name) }
        return try await body(IntentInput(url: url, name: name, displayPath: name))
    }

    /// The last path component of a name that arrived from elsewhere, never a path out of the temporary folder.
    static func safeName(_ filename: String) -> String {
        let last = (filename as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !last.isEmpty, last != ".", last != "..", !last.contains("/") else {
            return String(localized: "Untitled", comment: "Name of a file handed to a Shortcuts action without a name.")
        }
        return last
    }
}

/// The files the intents give back. They are returned as data, so nothing is left behind in a temporary folder.
enum IntentOutput {
    /// A fresh private folder under the temporary directory, for one call.
    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vitrine-intents", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// "report.md" → "report.html".
    static func filename(for name: String, extension ext: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? name : base) + "." + ext
    }

    /// A table's or sheet's name as a file name: "orders" → "orders.csv"; a slash or colon becomes a dash.
    static func filename(base: String, extension ext: String) -> String {
        let cleaned = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "table" : cleaned) + "." + ext
    }

    static func file(_ data: Data, named filename: String, type: UTType) -> IntentFile {
        IntentFile(data: data, filename: filename, type: type)
    }
}

/// The document the preview is drawn from, through the connector worker's own path (the same sniffing and renderer the
/// Quick Look controller uses), with its errors said as the intents say them.
@MainActor
enum IntentDocuments {
    static func document(for input: IntentInput) async throws -> PreviewDocument {
        do {
            return try await ConnectorWorker.document(for: input.url)
        } catch RenderError.unsupported {
            throw VitrineIntentError.unsupported(name: input.name)
        } catch {
            throw VitrineIntentError.wrapping(error, name: input.name)
        }
    }
}
