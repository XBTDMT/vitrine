import AppKit
import VitrineData

/// jq over the file in view (I-8, G-17): the query box's jq mode on a structured file's Tree. The program runs over
/// each document as jq would over its inputs (one for JSON, TOML and a property list; one per line of JSON Lines and
/// per YAML document), and its outputs replace the tree, one top-level item per output, until the query is cleared.
/// The values are read whole for the query, not from the tree's cut previews: JSON and JSON Lines through
/// `JQValue(json:)`, other formats through a second parse with no preview cut. Bounded by `JQLimits` (outputs, steps,
/// time, depth, bytes) across all inputs together; a limit keeps what was found and says so. roadmap: S-5
@MainActor
final class StructuredQueryController {
    /// Formats jq reads; XML has no single JSON reading, so it keeps Find only. JSON Lines files are not drawn as a
    /// tree (their table is A-5); the JSON Lines reader below is for that table's jq filter.
    static let formats: Set<StructuredFormat> = [.json, .jsonLines, .yaml, .toml, .propertyList]

    private weak var view: StructuredView?
    /// The gutter shows the outcome or jq's message, as the SQL query does.
    private weak var preview: RenderedPreview?
    private let source: Data
    private let format: StructuredFormat
    private var inputs: Inputs?
    private var generation = 0

    /// What the program runs over, read once on the first query.
    struct Inputs: Sendable {
        var values: [JQValue]
        /// Said after every result ("1 line is not JSON"); nil when every input was read whole.
        var note: String?
    }

    init(view: StructuredView, source: Data, format: StructuredFormat) {
        self.view = view
        self.source = source
        self.format = format
    }

    /// Adds the jq mode to a rendered structured preview when the file opens on a valid Tree.
    static func attach(to preview: RenderedPreview, view: StructuredView, built: StructuredRenderer.Built) {
        guard built.treeIndex == 0, let format = built.format, formats.contains(format) else { return }
        let controller = StructuredQueryController(view: view, source: built.source, format: format)
        view.queryController = controller
        controller.preview = preview
        preview.findModes = [preview.findStyle, .query]
        // The language's name and the sample programs are code, never translated.
        preview.queryLanguage = "jq"
        preview.queryPlaceholder = format == .jsonLines ? "select(.status != \"ok\")" : ".[] | select(.name)"
        preview.query = { [weak controller] program in
            await controller?.run(program) ?? .failed(String(localized: "This preview cannot run jq.", bundle: .previewKit,
                                                             comment: "Query message when the tree has no jq engine attached."))
        }
        preview.clearQuery = { [weak controller] in controller?.clear() }
    }

    func run(_ text: String) async -> QueryOutcome {
        generation += 1
        let generation = self.generation
        let started = ContinuousClock.now
        let source = self.source, format = self.format, cached = inputs
        let work = Task.detached(priority: .userInitiated) { () throws -> (Inputs, Ran) in
            let program = try JQ.compile(text)
            let inputs = try cached ?? Self.read(source, format: format)
            return (inputs, Self.run(program, over: inputs.values))
        }
        do {
            let (inputs, run) = try await work.value
            guard generation == self.generation else { return .failed(Self.replaced) }
            self.inputs = inputs
            let elapsed = started.duration(to: .now)
            let ms = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            // An error before any output is the answer itself; after some, the outputs show and the error is said.
            if let error = run.error, run.outputs.isEmpty { return failed(error) }
            view?.showQueryResult(run.outputs)
            let stopped = (run.error ?? run.stoppedReason).map {
                String(localized: "stopped: \($0)", bundle: .previewKit, comment: "After a jq result count (lower case): why the run stopped early.")
            }
            let outcome = QueryOutcome(rows: run.outputs.count, isCapped: run.stoppedReason != nil, milliseconds: ms, unit: .results,
                                       note: [inputs.note, stopped].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
            preview?.updateGutter(GutterStatus(leading: outcome.summary, trailing: Self.readOnly))
            return outcome
        } catch {
            guard generation == self.generation else { return .failed(Self.replaced) }
            // jq's own error text is the engine's data, shown as it comes.
            return failed((error as? JQError)?.description ?? (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private static var replaced: String {
        String(localized: "A newer query replaced this one.", bundle: .previewKit, comment: "Query message when a newer query superseded a running one.")
    }

    static var readOnly: String {
        String(localized: "jq · read-only · the file is never written", bundle: .previewKit,
               comment: "Gutter beside a jq result: the query cannot change the file. 'jq' is a program's name.")
    }

    /// jq's message in the gutter (the capsule says "Didn't run"); whatever tree was shown stays.
    private func failed(_ message: String) -> QueryOutcome {
        preview?.updateGutter(GutterStatus(leading: message, trailing: Self.readOnly))
        return .failed(message)
    }

    func clear() {
        generation += 1
        view?.showQueryResult(nil)
        preview?.updateGutter(nil)
    }

    // MARK: Off the main thread

    struct ReadError: LocalizedError {
        let errorDescription: String?
    }

    /// The file's documents as jq values, read whole.
    nonisolated static func read(_ data: Data, format: StructuredFormat) throws -> Inputs {
        switch format {
        case .json:
            if let value = try? JQValue(json: data) { return Inputs(values: [value]) }
            // JSONC or JSON5: the lenient parser reads it; below.
            return try readTree(data, format: format)
        case .jsonLines:
            var values: [JQValue] = []
            var bad: [Int] = []
            var lineNumber = 0
            for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
                lineNumber += 1
                let trimmed = line.drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
                guard !trimmed.isEmpty, !trimmed.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { continue }
                if let value = try? JQValue(json: Data(line)) { values.append(value) } else { bad.append(lineNumber) }
            }
            let note: String? = switch bad.count {
            case 0: nil
            case 1: String(localized: "1 line is not JSON · line \(bad[0])", bundle: .previewKit,
                           comment: "jq note on a JSON Lines file: one line does not parse, then which.")
            default: String(localized: "\(bad.count) lines are not JSON · first at line \(bad[0])", bundle: .previewKit,
                            comment: "jq note on a JSON Lines file: how many lines do not parse, then the first.")
            }
            return Inputs(values: values, note: note)
        default:
            return try readTree(data, format: format)
        }
    }

    /// A second parse with no preview cut, so strings reach jq whole; a node or depth limit is said, never hidden.
    nonisolated static func readTree(_ data: Data, format: StructuredFormat) throws -> Inputs {
        var options = StructuredOptions()
        options.maxInputBytes = FamilyFacts.parseLimit
        options.maxPreviewBytes = Int(FamilyFacts.parseLimit)
        options.maxNodes = 5_000_000
        let result = StructuredParser.parse(data, format: format, options: options, fileSize: Int64(data.count))
        guard result.isValid else {
            throw ReadError(errorDescription: String(localized: "jq needs the whole document, and this file stops at a syntax error.", bundle: .previewKit,
                                                     comment: "Query message: jq cannot run on a file that does not parse."))
        }
        let tree = result.tree
        let whole = tree.roots.allSatisfy { JQValue.isLossless(tree: tree, node: $0) }
        return Inputs(values: tree.roots.map { JQValue(tree: tree, node: $0) },
                      note: whole ? nil : String(localized: "part of the file was beyond the reading limit, so jq saw it cut", bundle: .previewKit,
                                                 comment: "jq note (lower case): the input was cut by a size limit."))
    }

    /// What a run over all inputs produced: the outputs, and whether a limit (`stoppedReason`) or a jq error ended it.
    struct Ran: Sendable, Equatable {
        var outputs: [JQValue]
        var stoppedReason: String?
        var error: String?
    }

    /// Runs the program over every input in turn, the limits shared by all of them.
    nonisolated static func run(_ program: JQProgram, over values: [JQValue], limits: JQLimits = .default) -> Ran {
        var outputs: [JQValue] = []
        let deadline = ContinuousClock.now + limits.timeLimit
        for value in values {
            var remaining = limits
            remaining.maxOutputs = limits.maxOutputs - outputs.count
            remaining.timeLimit = ContinuousClock.now.duration(to: deadline)
            guard remaining.maxOutputs > 0, remaining.timeLimit > .zero else {
                let reason = remaining.maxOutputs <= 0
                    ? String(localized: "the output limit of \(limits.maxOutputs) results was reached", bundle: .previewKit,
                             comment: "Why a jq run stopped (lower case, after 'stopped:').")
                    : String(localized: "the time limit was reached", bundle: .previewKit, comment: "Why a jq run stopped (lower case, after 'stopped:').")
                return Ran(outputs: outputs, stoppedReason: reason)
            }
            do {
                let run = try program.run(value, limits: remaining)
                outputs += run.outputs
                if !run.isComplete {
                    return Ran(outputs: outputs, stoppedReason: run.stoppedReason
                               ?? String(localized: "a limit was reached", bundle: .previewKit, comment: "Why a jq run stopped (lower case, after 'stopped:')."))
                }
            } catch {
                // jq stops at the first error; the results so far stay, and the error is what is said.
                return Ran(outputs: outputs, error: (error as? JQError)?.description ?? "\(error)")
            }
        }
        return Ran(outputs: outputs)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
