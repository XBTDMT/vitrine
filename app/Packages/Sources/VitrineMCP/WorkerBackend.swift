import Foundation

/// Answers each tool call in a fresh worker process (G-22 route A): `vitrine mcp` checks the arguments, starts the
/// worker (the Vitrine app binary with `--mcp-call`), writes the request to its standard input and reads one JSON
/// answer from its standard output. A worker that crashes or hangs on a hostile file costs that one call (R-6); the
/// server goes on. roadmap: S-11
public struct WorkerBackend: MCPBackend {
    /// The worker's executable and the arguments before the request (tests pass a stand-in).
    public let executable: URL
    public let arguments: [String]
    public let timeout: Double
    let home: URL

    public init(executable: URL, arguments: [String] = WorkerBackend.workerArguments, timeout: Double = ConnectorLimits.workerSeconds,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.executable = executable; self.arguments = arguments; self.timeout = timeout; self.home = home
    }

    /// The worker answers in English whatever the Mac's language: what Claude reads stays one vocabulary.
    public static let workerArguments = ["--mcp-call", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

    public func call(_ tool: String, _ arguments: [String: Any]) async -> MCPResult {
        let request: WorkerRequest
        switch Self.request(tool: tool, arguments: arguments, home: home) {
        case .failure(let message): return .error(message.text)
        case .success(let r): request = r
        }
        guard let input = try? JSONEncoder().encode(request) else { return .error("The request could not be encoded.") }
        switch await run(input) {
        case .failure(let message): return .error(message.text)
        case .success(let output):
            guard let response = try? JSONDecoder().decode(WorkerResponse.self, from: output) else {
                return .error("Vitrine's reader gave no answer for \(request.path).")
            }
            return response.result
        }
    }

    struct Message: Error { let text: String }

    /// Checks the arguments against the tool's schema and resolves the path; refuses before any process starts.
    static func request(tool: String, arguments: [String: Any], home: URL) -> Result<WorkerRequest, Message> {
        guard var path = arguments["path"] as? String, !path.isEmpty else { return .failure(Message(text: "path is required.")) }
        if path == "~" { path = home.path } else if path.hasPrefix("~/") { path = home.appendingPathComponent(String(path.dropFirst(2))).path }
        guard path.hasPrefix("/") else { return .failure(Message(text: "path must be absolute: \(path)")) }
        path = URL(fileURLWithPath: path).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return .failure(Message(text: "No file at \(path).")) }
        guard FileManager.default.isReadableFile(atPath: path) else { return .failure(Message(text: "This Mac does not let Vitrine read \(path).")) }
        var request = WorkerRequest(tool: tool, path: path)
        if tool == ConnectorTools.render {
            let format = arguments["format"] as? String ?? "text"
            guard ["text", "image"].contains(format) else { return .failure(Message(text: "format is \"text\" or \"image\".")) }
            request.format = format
            if let offset = arguments["offset"] {
                guard let n = offset as? Int, n >= 0 else { return .failure(Message(text: "offset is a whole number from 0.")) }
                request.offset = n
            }
            if let limit = arguments["limit"] {
                guard let n = limit as? Int, (1...ConnectorLimits.maxLines).contains(n) else {
                    return .failure(Message(text: "limit is a whole number from 1 to \(ConnectorLimits.maxLines)."))
                }
                request.limit = n
            }
            let appearance = arguments["appearance"] as? String ?? "light"
            guard ["light", "dark"].contains(appearance) else { return .failure(Message(text: "appearance is \"light\" or \"dark\".")) }
            request.appearance = appearance
            let secrets = arguments["secrets"] as? String ?? "masked"
            guard ["masked", "show"].contains(secrets) else { return .failure(Message(text: "secrets is \"masked\" or \"show\".")) }
            request.secrets = secrets
        }
        return .success(request)
    }

    /// Runs the worker once: input on its standard input, its standard output back; a time limit, then a stop.
    func run(_ input: Data) async -> Result<Data, Message> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        // Both pipes are drained while the worker runs, so a large answer never blocks it on a full pipe.
        let collected = Collected()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { collected.append(chunk) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        let finished = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in finished.continuation.yield(); finished.continuation.finish() }
        do { try process.run() } catch {
            return .failure(Message(text: "Vitrine's reader could not start (\(error.localizedDescription))."))
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        let seconds = timeout
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in finished.stream {}; return false }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return true }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if timedOut {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            stdout.fileHandleForReading.readabilityHandler = nil
            return .failure(Message(text: "Vitrine stopped reading this file after \(Int(seconds)) seconds; nothing was returned."))
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        collected.append(stdout.fileHandleForReading.readDataToEndOfFile())
        if process.terminationReason == .uncaughtSignal {
            return .failure(Message(text: "Vitrine's reader stopped on this file (signal \(process.terminationStatus)); nothing was returned."))
        }
        return .success(collected.data)
    }
}

/// Bytes gathered from a pipe's handler thread.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ chunk: Data) { lock.lock(); buffer.append(chunk); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}
