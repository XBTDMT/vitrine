import Foundation

/// jq for the query box (I-8, G-17 route A): a memory-safe jq 1.7 engine in Swift. Programs compile once and run on
/// any number of inputs; every run is bounded in steps, time, outputs, result size and depth, and runs on its own
/// thread with a large stack so a hostile program or file can never overflow the caller's. Anything outside the
/// supported language fails at compile time, by name. roadmap: S-5
public enum JQ {
    /// Parses a jq program once; throws `JQError` (`.syntax`, `.unsupported`, `.limit` for a program nested too
    /// deeply) with the offset of the problem.
    public static func compile(_ program: String) throws -> JQProgram {
        let outcome: Result<JQProgram, JQError> = JQThread.run {
            do {
                var parser = JQParser(program, builtin: false)
                let root = try parser.parseProgram()
                try JQResolver.resolveProgram(root, source: program)
                return .success(JQProgram(root: root, source: program))
            } catch let error as JQError {
                return .failure(error)
            } catch {
                return .failure(JQError(.syntax, "\(error)"))
            }
        }
        return try outcome.get()
    }
}

/// A compiled jq program. roadmap: S-5
public struct JQProgram: Sendable {
    let root: JQNode
    /// The program text as written.
    let source: String

    /// Runs on one input value and returns every output (jq is a generator). A limit stops the run early with the
    /// outputs so far (`isComplete` false, `stoppedReason` set); a jq error (`error(...)`, `.a` on a number) throws
    /// `JQError(.runtime)`.
    public func run(_ input: JQValue, limits: JQLimits = .default) throws -> JQRun {
        let root = self.root
        let outcome: Result<JQRun, JQError> = JQThread.run {
            JQInterpreter(limits: limits).run(root, input: input)
        }
        return try outcome.get()
    }
}

/// What one run produced. roadmap: S-5
public struct JQRun: Sendable, Equatable {
    public var outputs: [JQValue]
    /// False when a limit stopped the run before the program finished.
    public var isComplete: Bool
    /// Which limit stopped it: "the output limit of 10000 results was reached", and so on.
    public var stoppedReason: String?
}

/// The bounds one run works within. roadmap: S-5
public struct JQLimits: Sendable, Equatable {
    /// Outputs kept; one more stops the run.
    public var maxOutputs: Int
    /// Evaluation steps (one per expression evaluated and per value a loop or iteration produces).
    public var maxSteps: Int
    /// Wall-clock time for one run.
    public var timeLimit: Duration
    /// Nesting of calls to functions the program defines (recursion), and the base of the bound on how deeply a
    /// value may nest (`maxDepth` + 64) and on evaluation nesting overall.
    public var maxDepth: Int
    /// Total size of the outputs, measured as compact JSON (approximately), and the largest string or array one
    /// operation may build.
    public var maxResultBytes: Int

    public init(maxOutputs: Int = 10_000, maxSteps: Int = 5_000_000, timeLimit: Duration = .seconds(2),
                maxDepth: Int = 512, maxResultBytes: Int = 32 * 1024 * 1024) {
        self.maxOutputs = maxOutputs; self.maxSteps = maxSteps; self.timeLimit = timeLimit
        self.maxDepth = maxDepth; self.maxResultBytes = maxResultBytes
    }

    public static let `default` = JQLimits()
}

/// A jq failure. `description` reads like jq's own: `jq: error: Cannot index number with "a"`. roadmap: S-5
public struct JQError: Error, Equatable, CustomStringConvertible, Sendable {
    /// What kind of failure it is. roadmap: S-5
    public enum Kind: String, Sendable, Equatable {
        /// The program does not parse, or names a function, variable, label or format that does not exist.
        case syntax
        /// Valid jq that Vitrine does not run (input streams, the environment, the clock, modules, …), by name.
        case unsupported
        /// An error raised while running: `error(...)`, a type error, a bad path.
        case runtime
        /// A bound was hit where a partial result makes no sense (a program nested too deeply to compile).
        case limit
    }

    public var kind: Kind
    public var message: String
    /// Byte offset in the program (syntax and unsupported errors); nil for runtime errors.
    public var offset: Int?

    public init(_ kind: Kind, _ message: String, offset: Int? = nil) {
        self.kind = kind; self.message = message; self.offset = offset
    }

    public var description: String {
        kind == .unsupported ? "jq: \(message)" : "jq: error: \(message)"
    }

    /// A syntax error at `offset` in `source`, its message ending in "at line L, column C".
    static func syntax(_ reason: String, at offset: Int, in source: [UInt8]) -> JQError {
        let (line, column) = position(of: offset, in: source)
        return JQError(.syntax, "syntax error: \(reason) at line \(line), column \(column)", offset: offset)
    }

    static func position(of offset: Int, in source: [UInt8]) -> (Int, Int) {
        var line = 1, column = 1
        for i in 0..<min(max(0, offset), source.count) {
            if source[i] == 0x0A { line += 1; column = 1 } else if source[i] & 0xC0 != 0x80 { column += 1 }
        }
        return (line, column)
    }
}

/// Runs work on a dedicated thread with a large stack, so the evaluator's recursion depth is bounded by the engine's
/// own limits, never by whichever thread (a 512 KB secondary thread, say) called it. Only pages actually touched are
/// committed. roadmap: S-5
enum JQThread {
    static let stackSize = 512 * 1024 * 1024

    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    static func run<T>(_ body: @escaping @Sendable () -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.stackSize = stackSize
        thread.qualityOfService = .userInitiated
        thread.name = "Vitrine jq"
        thread.start()
        done.wait()
        return box.value!
    }
}
