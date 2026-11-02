import Foundation
import VitrineSupport

/// How serious a finding on an AI-format card is: `caution` asks for a second look, `danger` means opening or running
/// the file the usual way could hurt this Mac or leak something. roadmap: S-21
public enum AIWarningLevel: String, Sendable, Equatable, Comparable, CaseIterable {
    case caution, danger

    public static func < (a: AIWarningLevel, b: AIWarningLevel) -> Bool { a == .caution && b == .danger }
}

/// One finding a card shows: a level, a plain-English reason a person can act on, and what it is about (a server, an
/// import, a key name) when there is one. Never holds a secret's value. roadmap: S-21
public struct AIWarning: Sendable, Equatable {
    public var level: AIWarningLevel
    /// A complete sentence in plain English.
    public var reason: String
    /// The server, import, key or path the finding is about.
    public var subject: String?

    public init(_ level: AIWarningLevel, _ reason: String, subject: String? = nil) {
        self.level = level; self.reason = reason; self.subject = subject
    }
}

/// One labelled line of a card ("Architecture: llama"). roadmap: S-21
public struct AIFact: Sendable, Equatable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

/// What the AI-formats reader made of a file: one summary per family, each with a headline, facts and warnings for
/// its card. roadmap: S-21
public enum AIDocument: Sendable, Equatable {
    case rules(RulesFileSummary)
    case mcpConfig(MCPConfigSummary)
    case pickle(PickleSummary)
    case gguf(GGUFSummary)
    case safetensors(SafetensorsSummary)
    case tokenizer(TokenizerSummary)
    case onnx(ONNXSummary)
    case coreML(CoreMLSummary)

    public var headline: String {
        switch self {
        case .rules(let s): s.headline
        case .mcpConfig(let s): s.headline
        case .pickle(let s): s.headline
        case .gguf(let s): s.headline
        case .safetensors(let s): s.headline
        case .tokenizer(let s): s.headline
        case .onnx(let s): s.headline
        case .coreML(let s): s.headline
        }
    }

    public var facts: [AIFact] {
        switch self {
        case .rules(let s): s.facts
        case .mcpConfig(let s): s.facts
        case .pickle(let s): s.facts
        case .gguf(let s): s.facts
        case .safetensors(let s): s.facts
        case .tokenizer(let s): s.facts
        case .onnx(let s): s.facts
        case .coreML(let s): s.facts
        }
    }

    public var warnings: [AIWarning] {
        switch self {
        case .rules(let s): s.warnings
        case .mcpConfig(let s): s.warnings
        case .pickle(let s): s.warnings
        case .gguf(let s): s.warnings
        case .safetensors(let s): s.warnings
        case .tokenizer(let s): s.warnings
        case .onnx(let s): s.warnings
        case .coreML(let s): s.warnings
        }
    }

    /// The most serious warning's level, nil when there is none.
    public var highestLevel: AIWarningLevel? { warnings.map(\.level).max() }
}

/// The families the reader recognises, from a file's name and path (and, for GGUF, its first bytes). roadmap: S-21
public enum AIFormatKind: Sendable, Equatable {
    case rules(RulesFlavor)
    case mcpConfig
    case pickle
    case gguf
    case safetensors
    case tokenizer
    case onnx
    case coreML
}

/// The input bounds every AI-format reader keeps. Model headers read at most 64 MB, and only their header region;
/// everything else at most 8 MB. roadmap: S-21
public enum AIFormatsLimits {
    public static let maxModelHeaderBytes: Int64 = 64 * 1024 * 1024
    public static let maxOtherBytes: Int64 = 8 * 1024 * 1024
    /// Lists (imports, servers, tensors, metadata entries) stop here and say `truncated`.
    public static let maxListItems = 1_000
}

/// The entry point: rules and skills files, MCP configs, pickles and model headers (S-21 rows A-3, T-6, T-7, A-6).
/// Pure readers: no network, no process, nothing unpickled or run; the only file access is `read(directory:)`
/// (bounded reads inside an `.mlpackage`) and `resolve(imports:relativeTo:)` (existence checks only). roadmap: S-21
public enum AIFormatsReader {
    /// Reads `data` (the start of the file, or all of it) named `fileName`. `path` (the full path, when known) tells
    /// `.cursor/mcp.json` from any `mcp.json` and a `.claude/rules/` file from any Markdown. Nil when the file is not one
    /// of these formats.
    public static func read(data: Data, fileName: String, path: String?) -> AIDocument? {
        read(source: MemoryByteSource(data), fileName: fileName, path: path)
    }

    /// Reads from random-access bytes, so a model header is read without touching the weights behind it (an ONNX
    /// file's initializers, a GGUF's tensor data). Nil when the file is not one of these formats.
    public static func read(source: any ByteSource, fileName: String, path: String?) -> AIDocument? {
        guard let kind = kind(fileName: fileName, path: path, source: source) else { return nil }
        switch kind {
        case .rules(let flavor):
            guard let bytes = try? source.read(at: 0, count: Int(AIFormatsLimits.maxOtherBytes)) else { return nil }
            return .rules(RulesFileReader.read(bytes: bytes, fileName: fileName, flavor: flavor,
                                               fileSize: source.size))
        case .mcpConfig:
            guard let bytes = try? source.read(at: 0, count: Int(AIFormatsLimits.maxOtherBytes)) else { return nil }
            return MCPConfigReader.read(bytes: bytes, fileName: fileName, path: path, fileSize: source.size).map { .mcpConfig($0) }
        case .pickle:
            return PickleReader.read(source: source, fileName: fileName).map { .pickle($0) }
        case .gguf:
            return GGUFReader.read(source: source).map { .gguf($0) }
        case .safetensors:
            return SafetensorsReader.read(source: source).map { .safetensors($0) }
        case .tokenizer:
            guard let bytes = try? source.read(at: 0, count: Int(AIFormatsLimits.maxModelHeaderBytes)) else { return nil }
            return TokenizerReader.read(bytes: bytes, fileSize: source.size).map { .tokenizer($0) }
        case .onnx:
            return ONNXReader.read(source: source).map { .onnx($0) }
        case .coreML:
            return CoreMLReader.read(source: source, fileName: fileName).map { .coreML($0) }
        }
    }

    /// Reads a folder that is one document: an `.mlpackage` (its Manifest.json, then the model spec it names, with
    /// bounded reads that never leave the package). Nil for any other folder.
    public static func read(directory: URL) -> AIDocument? {
        guard directory.pathExtension.lowercased() == "mlpackage" else { return nil }
        return CoreMLReader.readPackage(directory).map { .coreML($0) }
    }

    /// Whether each import names a file that exists. `relativeTo` is the folder holding the rules file; `~/` means the
    /// user's home. The one file access is `FileManager.fileExists`: nothing is opened or read.
    public static func resolve(imports: [RulesImport], relativeTo base: URL) -> [ResolvedImport] {
        RulesFileReader.resolve(imports: imports, relativeTo: base)
    }

    /// The family a name and path point at, nil for none. GGUF is also recognised by its magic when `source` is
    /// given.
    public static func kind(fileName: String, path: String?, source: (any ByteSource)? = nil) -> AIFormatKind? {
        let lower = fileName.lowercased()
        let lowerPath = (path ?? fileName).lowercased()
        let ext = (lower as NSString).pathExtension
        if let flavor = RulesFlavor(fileName: lower, path: lowerPath) { return .rules(flavor) }
        if MCPConfigReader.recognises(fileName: lower, path: lowerPath) { return .mcpConfig }
        if lower == "tokenizer.json" { return .tokenizer }
        switch ext {
        case "gguf": return .gguf
        case "safetensors": return .safetensors
        case "onnx": return .onnx
        case "mlmodel": return .coreML
        case "pkl", "pickle", "joblib", "pt", "pth", "bin", "npy", "ckpt": return .pickle
        default: break
        }
        if let source, let head = try? source.read(at: 0, count: 4), head == Array("GGUF".utf8) { return .gguf }
        return nil
    }
}
