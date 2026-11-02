import Foundation
import VitrineDetect
import VitrineSupport

/// Which detectors run on which files (G-23, measured): the ones that recognise a credential's own format run on
/// every text; the labelled-value (`config`) and personal detectors run on prose and configuration, where `KEY=value`
/// and an email address mean what they say, and not on source code, where `let key = …` is just code (39 false
/// alarms in 169 of Vitrine's own source files with every detector on). roadmap: S-20
public enum LensPolicy {
    public enum Family: Sendable { case prose, config, code }

    static let configLanguages: Set<String> = ["dotenv", "properties", "ini", "conf", "yaml", "toml", "json", "jsonc", "json5", "xml", "plist",
                                               "shell", "bash", "zsh", "sh", "fish", "powershell", "dockerfile", "makefile", "nginx", "hcl", "terraform", "sql", "log"]

    public static func family(for kind: FileKind) -> Family? {
        switch kind {
        case .markdown, .plainText, .csv: return .prose
        case .code(let language):
            if language.hasSuffix("-session") || language == "ipynb" { return .prose }
            return configLanguages.contains(language) ? .config : .code
        case .diff: return .config
        default: return nil
        }
    }

    static let codeOff: Set<Detector.Category> = [.config, .personal, .network]

    nonisolated(unsafe) private static var cache: [Family: VitrineDetect.Scanner] = [:]
    private static let lock = NSLock()

    /// The scanner for a family, compiled once.
    public static func scanner(for family: Family) -> VitrineDetect.Scanner? {
        lock.lock(); defer { lock.unlock() }
        if let s = cache[family] { return s }
        let state = family == .code
            ? Dictionary(uniqueKeysWithValues: Catalogue.builtIn.map { ($0.id, $0.enabledByDefault && !codeOff.contains($0.category)) })
            : [:]
        guard let catalogue = try? Catalogue.resolved(state: state) else { return nil }
        let scanner = VitrineDetect.Scanner(catalogue: catalogue, input: .exact)
        cache[family] = scanner
        return scanner
    }

    /// The text with the family's secrets masked; unchanged (and 0) past `TextLens.maxBytes` or for kinds it does not read.
    public static func masked(_ text: String, kind: FileKind) -> (text: String, count: Int) {
        guard text.utf8.count <= TextLens.maxBytes, let family = family(for: kind), let scanner = scanner(for: family) else { return (text, 0) }
        return SecretRedaction.mask(text, scanner: scanner)
    }
}
