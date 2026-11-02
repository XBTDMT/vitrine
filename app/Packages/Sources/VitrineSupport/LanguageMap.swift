import Foundation
import UniformTypeIdentifiers

/// Maps a filename extension (and, when the extension is unknown, a UTType) to the language id the code renderer
/// understands. Ids follow VS Code / Shiki naming so the web renderer needs no second table.
public enum LanguageMap {
    static let byExtension: [String: String] = [
        "swift": "swift", "m": "objective-c", "mm": "objective-cpp", "h": "c", "hpp": "cpp", "hh": "cpp", "c": "c",
        "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "py": "python", "pyw": "python", "rb": "ruby", "php": "php",
        "pl": "perl", "pm": "perl", "sh": "shell", "bash": "shell", "zsh": "shell", "fish": "fish", "lua": "lua",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "jsx", "ts": "typescript",
        "mts": "typescript", "cts": "typescript", "tsx": "tsx", "java": "java", "kt": "kotlin", "kts": "kotlin",
        "go": "go", "rs": "rust", "scss": "scss", "sass": "sass", "less": "less", "css": "css", "sql": "sql",
        "dart": "dart", "scala": "scala", "sc": "scala", "hs": "haskell", "lhs": "haskell", "clj": "clojure",
        "cljs": "clojure", "cljc": "clojure", "edn": "clojure", "ex": "elixir", "exs": "elixir", "ml": "ocaml",
        "mli": "ocaml", "lisp": "lisp", "lsp": "lisp", "cl": "lisp", "el": "lisp", "fs": "fsharp", "fsx": "fsharp",
        "fsi": "fsharp", "tex": "latex", "latex": "latex", "sty": "latex", "cls": "latex", "vue": "vue",
        "cs": "csharp", "r": "r", "groovy": "groovy", "gradle": "groovy", "erl": "erlang", "hrl": "erlang",
        "applescript": "applescript", "scpt": "applescript", "log": "log", "s": "asm", "asm": "asm",
        "yml": "yaml", "yaml": "yaml", "toml": "toml", "json": "json", "jsonc": "jsonc", "json5": "json5",
        "xml": "xml", "plist": "xml", "html": "html", "htm": "html", "ini": "ini", "cfg": "ini", "conf": "ini",
        "env": "dotenv", "properties": "properties", "nfo": "plaintext", "txt": "plaintext", "dockerfile": "docker",
        "makefile": "makefile", "mk": "makefile", "cmake": "cmake", "nix": "nix", "zig": "zig", "v": "verilog",
        "proto": "proto", "graphql": "graphql", "gql": "graphql", "tf": "terraform", "hcl": "hcl", "ps1": "powershell",
        "bat": "bat", "cmd": "bat", "diff": "diff", "patch": "diff", "csv": "csv", "tsv": "tsv",
        // A Jupyter notebook is JSON, but drawn as a notebook (NotebookRenderer, S-21), never as a JSON tree.
        "ipynb": "ipynb",
    ]

    /// Files known by their whole name rather than an extension: `.env`, `.env.local`, `production.env`, Dockerfile,
    /// Makefile and the dot-files that hold settings. nil when the name says nothing. roadmap: S-5
    public static func language(forFileName name: String) -> String? {
        let lower = name.lowercased()
        if lower == ".env" || lower.hasPrefix(".env.") || lower.hasSuffix(".env") { return "dotenv" }
        switch lower {
        case "dockerfile", "containerfile": return "docker"
        case "makefile", "gnumakefile": return "make"
        case ".npmrc", ".pypirc", ".netrc", ".gitconfig", ".editorconfig", ".yarnrc": return "ini"
        case "gemfile", "podfile", "rakefile", "fastfile", "brewfile": return "ruby"
        default: return nil
        }
    }

    public static func language(for ext: String, type: UTType?) -> String {
        if let hit = byExtension[ext.lowercased()] { return hit }
        if let type {
            if type.conforms(to: .swiftSource) { return "swift" }
            if type.conforms(to: .cSource) { return "c" }
            if type.conforms(to: .cPlusPlusSource) { return "cpp" }
            if type.conforms(to: .objectiveCSource) { return "objective-c" }
            if type.conforms(to: .pythonScript) { return "python" }
            if type.conforms(to: .rubyScript) { return "ruby" }
            if type.conforms(to: .shellScript) { return "shell" }
            if type.conforms(to: .javaScript) { return "javascript" }
            if type.conforms(to: .json) { return "json" }
            if type.conforms(to: .yaml) { return "yaml" }
            if type.conforms(to: .xml) { return "xml" }
            if type.conforms(to: .html) { return "html" }
        }
        return "plaintext"
    }

    static func language(for ext: String, type: UTType?) -> String? {
        let l: String = language(for: ext, type: type)
        return l == "plaintext" && byExtension[ext.lowercased()] == nil ? nil : l
    }

    private static let displayNames: [String: String] = [
        "javascript": "JavaScript", "typescript": "TypeScript", "jsx": "JSX", "tsx": "TSX", "objective-c": "Objective-C",
        "objective-cpp": "Objective-C++", "cpp": "C++", "c": "C", "csharp": "C#", "fsharp": "F#", "php": "PHP",
        "html": "HTML", "css": "CSS", "scss": "SCSS", "json": "JSON", "jsonc": "JSON", "yaml": "YAML", "toml": "TOML",
        "xml": "XML", "sql": "SQL", "shell": String(localized: "Shell script", bundle: .module, comment: "Language name shown in the preview's pill."), "powershell": "PowerShell", "graphql": "GraphQL",
        "dockerfile": "Dockerfile", "makefile": "Makefile", "ini": "INI", "lua": "Lua", "ocaml": "OCaml",
        "ipynb": String(localized: "Jupyter notebook", bundle: .module, comment: "Kind name shown in the preview's pill."),
        // A marimo notebook (A-8): a Python file marimo wrote, drawn as a notebook; marimo writes its name in lower case.
        "marimo": String(localized: "marimo notebook", bundle: .module, comment: "Kind name shown in the preview's pill: a marimo notebook (a Python file written by the marimo notebook app; 'marimo' is a product name, kept in lower case)."),
        "jsonl": "JSON Lines",
        "claude-code-session": String(localized: "Claude Code session", bundle: .module, comment: "Kind name: a Claude Code transcript file."),
        "codex-session": String(localized: "Codex session", bundle: .module, comment: "Kind name: an OpenAI Codex transcript file."),
        // Ids that are words rather than names, so the capitalising fallback would leave them in English.
        "plaintext": String(localized: "Plaintext", bundle: .module, comment: "Language name for unformatted text."),
        "log": String(localized: "Log", bundle: .module, comment: "Language name for a log file."),
        "diff": String(localized: "Diff", bundle: .module, comment: "Language name for a diff or patch file."),
        "properties": String(localized: "Properties", bundle: .module, comment: "Language name for a Java .properties file."),
    ]

    /// "swift" → "Swift", "objective-c" → "Objective-C"; unknown ids are capitalised.
    public static func displayName(for language: String) -> String {
        displayNames[language] ?? language.prefix(1).uppercased() + language.dropFirst()
    }
}
