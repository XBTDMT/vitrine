import Foundation

/// What a LaTeX source file (`.tex`) holds (E-11): its document class and options, packages, title, author and date,
/// a section outline (part … subsubsection), the citation keys it cites, the files it pulls in, how many figures and
/// tables it has, an estimate of its word count (prose only: commands, math and comments left out), and commands
/// that reach outside the document when it is compiled. roadmap: S-23
public struct LaTeXSummary: Sendable, Equatable {
    /// A `\usepackage` line's package with its options. roadmap: S-23
    public struct Package: Sendable, Equatable {
        public var name: String
        public var options: [String]
    }

    /// One heading of the outline. roadmap: S-23
    public struct Section: Sendable, Equatable {
        /// The heading level. roadmap: S-23
        public enum Level: Int, Sendable, Equatable, Comparable {
            case part = 0, chapter, section, subsection, subsubsection

            public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        }

        public var level: Level
        /// The heading's text as plain text.
        public var title: String
        /// `\section*`: not numbered and not in the table of contents.
        public var isStarred: Bool
    }

    public static let maxOutline = 2_000
    public static let maxCiteKeys = 5_000
    public static let maxPackages = 500
    public static let maxInputs = 500

    public var documentClass: String?
    public var classOptions: [String]
    public var packages: [Package]
    public var title: String?
    public var author: String?
    public var date: String?
    public var outline: [Section]
    /// Distinct citation keys in order of first use.
    public var citeKeys: [String]
    /// `\cite`-family commands counted.
    public var citationCount: Int
    /// Files named by `\input`, `\include`, `\subfile` and `\import`.
    public var inputs: [String]
    /// `\bibliography` and `\addbibresource` files.
    public var bibliographies: [String]
    public var figureCount: Int
    public var tableCount: Int
    public var graphicsCount: Int
    /// Words of prose in the document body (all of the file when it has no `\begin{document}`).
    public var wordCount: Int
    public var warnings: [EverydayWarning]
    public var truncated: Bool

    public var headline: String {
        if let title, !title.isEmpty { return title }
        if let documentClass {
            return String(localized: "LaTeX \(documentClass) document", bundle: .module,
                          comment: "Headline of a LaTeX file card with no title; the argument is the document class (article, book…).")
        }
        return String(localized: "LaTeX source", bundle: .module, comment: "Headline of a LaTeX file card with no title and no document class.")
    }

    public var facts: [EverydayFact] {
        var facts: [EverydayFact] = []
        if let documentClass {
            let value = classOptions.isEmpty ? documentClass : "\(documentClass) [\(classOptions.joined(separator: ", "))]"
            facts.append(EverydayFact(String(localized: "Class", bundle: .module, comment: "Fact label on a LaTeX card: the document class."), value))
        }
        if let author { facts.append(EverydayFact(String(localized: "Author", bundle: .module, comment: "Fact label on a LaTeX card."), author)) }
        if let date { facts.append(EverydayFact(String(localized: "Date", bundle: .module, comment: "Fact label on a LaTeX card: the \\date the document states."), date)) }
        facts.append(EverydayFact(String(localized: "Words", bundle: .module, comment: "Fact label on a LaTeX card: estimated word count."),
                                  String(localized: "about \(wordCount)", bundle: .module, comment: "Value of the Words fact on a LaTeX card: an estimated word count.")))
        if !outline.isEmpty { facts.append(EverydayFact(String(localized: "Sections", bundle: .module, comment: "Fact label on a LaTeX card: headings in the outline."), "\(outline.count)")) }
        if !packages.isEmpty { facts.append(EverydayFact(String(localized: "Packages", bundle: .module, comment: "Fact label on a LaTeX card: \\usepackage count."), "\(packages.count)")) }
        if !citeKeys.isEmpty { facts.append(EverydayFact(String(localized: "Citations", bundle: .module, comment: "Fact label on a LaTeX card: distinct citation keys."), "\(citeKeys.count)")) }
        if figureCount > 0 { facts.append(EverydayFact(String(localized: "Figures", bundle: .module, comment: "Fact label on a LaTeX card."), "\(figureCount)")) }
        if tableCount > 0 { facts.append(EverydayFact(String(localized: "Tables", bundle: .module, comment: "Fact label on a LaTeX card."), "\(tableCount)")) }
        if !inputs.isEmpty { facts.append(EverydayFact(String(localized: "Included files", bundle: .module, comment: "Fact label on a LaTeX card: files pulled in with \\input or \\include."), "\(inputs.count)")) }
        return facts
    }
}

/// The LaTeX scanner behind `LaTeXSummary`. It works on UTF-8 bytes with explicit brace counters (no recursion).
enum EverydayLaTeX {
    static let sectionLevels: [String: LaTeXSummary.Section.Level] = [
        "part": .part, "chapter": .chapter, "section": .section, "subsection": .subsection, "subsubsection": .subsubsection,
    ]
    static let mathEnvironments: Set<String> = [
        "equation", "equation*", "align", "align*", "gather", "gather*", "multline", "multline*", "eqnarray", "eqnarray*",
        "math", "displaymath", "flalign", "flalign*", "alignat", "alignat*",
    ]
    static let verbatimEnvironments: Set<String> = ["verbatim", "verbatim*", "lstlisting", "minted", "comment", "Verbatim"]
    /// Commands whose arguments are not prose: their brace groups are skipped in the word count.
    static let nonProseCommands: [String: Int] = [
        "label": 1, "ref": 1, "eqref": 1, "pageref": 1, "autoref": 1, "cref": 1, "Cref": 1, "nameref": 1,
        "includegraphics": 1, "input": 1, "include": 1, "subfile": 1, "import": 2, "usepackage": 1, "RequirePackage": 1,
        "documentclass": 1, "bibliography": 1, "bibliographystyle": 1, "addbibresource": 1, "url": 1, "href": 1,
        "vspace": 1, "hspace": 1, "setlength": 2, "addtolength": 2, "setcounter": 2, "newcommand": 2, "renewcommand": 2,
        "providecommand": 2, "newenvironment": 3, "renewenvironment": 3, "color": 1, "textcolor": 1, "pagestyle": 1,
        "thispagestyle": 1, "numberwithin": 2, "graphicspath": 1, "hypersetup": 1, "geometry": 1, "title": 1,
        "author": 1, "date": 1, "linespread": 1, "newtheorem": 2, "DeclareMathOperator": 2, "crefname": 3,
    ]

    static func isCiteCommand(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix("cite") || lower.hasSuffix("cites") || lower.hasPrefix("cite") || lower == "nocite"
    }

    static func read(_ raw: [UInt8]) -> LaTeXSummary? {
        let source = Array(EverydayText.decode(raw).utf8)
        guard !source.contains(0) else { return nil }
        let bytes = stripComments(source)
        var s = LaTeXSummary(classOptions: [], packages: [], outline: [], citeKeys: [], citationCount: 0, inputs: [],
                             bibliographies: [], figureCount: 0, tableCount: 0, graphicsCount: 0, wordCount: 0,
                             warnings: [], truncated: false)
        var scanner = Scanner(bytes: bytes)
        var bodyStart: Int?
        var bodyEnd: Int?
        var shellEscape = false, luaCode = false, writesFiles = false
        var outsideReads: [String] = []
        var citeSet = Set<String>()
        var depth = 0
        var unbalanced = false

        while scanner.i < bytes.count {
            let b = bytes[scanner.i]
            if b == UInt8(ascii: "{") { depth += 1; scanner.i += 1; continue }
            if b == UInt8(ascii: "}") { depth -= 1; if depth < 0 { unbalanced = true; depth = 0 }; scanner.i += 1; continue }
            guard b == UInt8(ascii: "\\") else { scanner.i += 1; continue }
            let commandStart = scanner.i
            let name = scanner.commandName()
            switch name {
            case "documentclass":
                let options = scanner.optional()
                if let cls = scanner.group() {
                    s.documentClass = EverydayText.collapse(cls)
                    s.classOptions = options.map(list) ?? []
                }
            case "usepackage", "RequirePackage":
                let options = scanner.optional().map(list) ?? []
                if let names = scanner.group() {
                    for package in list(names) where s.packages.count < LaTeXSummary.maxPackages {
                        s.packages.append(.init(name: package, options: options))
                    }
                    if s.packages.count >= LaTeXSummary.maxPackages { s.truncated = true }
                }
            case "title":
                _ = scanner.optional()
                if let value = scanner.group() { s.title = plain(value) }
            case "author":
                _ = scanner.optional()
                if let value = scanner.group() {
                    let cleaned = value.replacing(/\\thanks\s*\{[^{}]*\}/, with: "").replacingOccurrences(of: "\\and", with: ",")
                        .replacingOccurrences(of: "\\\\", with: " ")
                    s.author = plain(cleaned).replacingOccurrences(of: " ,", with: ",")
                }
            case "date":
                if let value = scanner.group() {
                    let text = plain(value)
                    s.date = text.isEmpty ? nil : text
                }
            case "begin":
                guard let env = scanner.group()?.trimmingCharacters(in: .whitespaces) else { break }
                switch env {
                case "document": bodyStart = scanner.i
                case "figure", "figure*", "wrapfigure", "subfigure", "SCfigure": s.figureCount += 1
                case "table", "table*", "wraptable", "longtable", "sidewaystable": s.tableCount += 1
                default:
                    if verbatimEnvironments.contains(env) { scanner.skipToEnd(of: env) }
                }
            case "end":
                if let env = scanner.group()?.trimmingCharacters(in: .whitespaces), env == "document", bodyEnd == nil {
                    bodyEnd = commandStart
                }
            case "input", "include", "subfile", "import", "subimport", "includeonly":
                scanner.skipSpaces()
                var files: [String] = []
                if name == "import" || name == "subimport" {
                    let dir = scanner.group() ?? ""
                    if let file = scanner.group() { files = [dir + file] }
                } else if let group = scanner.group() {
                    files = name == "includeonly" ? list(group) : [group.trimmingCharacters(in: .whitespaces)]
                } else if name == "input" {
                    files = [scanner.bareWord()].filter { !$0.isEmpty }
                }
                if name == "includeonly" { break }
                for file in files where !file.isEmpty {
                    if s.inputs.count < LaTeXSummary.maxInputs, !s.inputs.contains(file) { s.inputs.append(file) }
                    if (file.hasPrefix("/") || file.hasPrefix("~") || file.contains("../")), outsideReads.count < 5 {
                        outsideReads.append(file)
                    }
                }
            case "bibliography", "addbibresource":
                _ = scanner.optional()
                if let group = scanner.group() {
                    for file in list(group) where s.bibliographies.count < 100 { s.bibliographies.append(file) }
                }
            case "includegraphics":
                s.graphicsCount += 1
            case "write":
                scanner.skipSpaces()
                if scanner.peek("18") { shellEscape = true }
            case "ShellEscape", "shellescape", "immediateshellescape":
                shellEscape = true
            case "directlua", "luaexec", "luadirect":
                luaCode = true
            case "openout":
                writesFiles = true
            default:
                if let level = sectionLevels[name] {
                    let starred = scanner.star()
                    _ = scanner.optional()
                    if let title = scanner.group() {
                        if s.outline.count < LaTeXSummary.maxOutline {
                            s.outline.append(.init(level: level, title: plain(title), isStarred: starred))
                        } else {
                            s.truncated = true
                        }
                    }
                } else if isCiteCommand(name) {
                    s.citationCount += 1
                    _ = scanner.star()
                    _ = scanner.optional()
                    _ = scanner.optional()
                    var groups = 0
                    while groups < 20, let keys = scanner.group() {
                        groups += 1
                        for key in list(keys) where !citeSet.contains(key) {
                            if s.citeKeys.count < LaTeXSummary.maxCiteKeys {
                                citeSet.insert(key)
                                s.citeKeys.append(key)
                            } else {
                                s.truncated = true
                            }
                        }
                        if !name.lowercased().hasSuffix("cites") { break }
                        _ = scanner.optional()
                        _ = scanner.optional()
                    }
                }
            }
        }
        if depth != 0 { unbalanced = true }
        if scanner.exhausted { s.truncated = true }

        let start = bodyStart ?? 0
        let end = max(start, min(bodyEnd ?? bytes.count, bytes.count))
        let (words, wordsCut) = countWords(Array(bytes[start..<end]))
        s.wordCount = words
        if wordsCut { s.truncated = true }

        guard s.documentClass != nil || !s.outline.isEmpty || !s.packages.isEmpty || bodyStart != nil
                || source.contains(UInt8(ascii: "\\")) else { return nil }

        if shellEscape {
            s.warnings.append(EverydayWarning(.danger, code: "latex.shellEscape",
                reason: String(localized: "The document runs shell commands (\\write18) when it is compiled with shell escape on.", bundle: .module,
                               comment: "Warning on a LaTeX card. \\write18 is a LaTeX command and stays as it is.")))
        }
        if luaCode {
            s.warnings.append(EverydayWarning(.caution, code: "latex.luaCode",
                reason: String(localized: "The document runs Lua code when it is compiled with LuaLaTeX.", bundle: .module,
                               comment: "Warning on a LaTeX card.")))
        }
        if writesFiles {
            s.warnings.append(EverydayWarning(.caution, code: "latex.writesFiles",
                reason: String(localized: "The document writes files of its own when it is compiled (\\openout).", bundle: .module,
                               comment: "Warning on a LaTeX card. \\openout is a TeX command and stays as it is.")))
        }
        if let file = outsideReads.first {
            s.warnings.append(EverydayWarning(.caution, code: "latex.readsOutside",
                reason: String(localized: "The document reads a file outside its folder: \(file).", bundle: .module,
                               comment: "Warning on a LaTeX card; the argument is the file path the document includes.")))
        }
        if unbalanced {
            s.warnings.append(EverydayWarning(.caution, code: "latex.unbalancedBraces",
                reason: String(localized: "The braces { } do not balance, so the document will not compile as it is.", bundle: .module,
                               comment: "Warning on a LaTeX card.")))
        }
        if s.documentClass != nil, bodyStart == nil {
            s.warnings.append(EverydayWarning(.caution, code: "latex.noDocument",
                reason: String(localized: "The file has a \\documentclass but no \\begin{document}.", bundle: .module,
                               comment: "Warning on a LaTeX card. The LaTeX commands stay as they are.")))
        }
        return s
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { EverydayText.collapse($0) }.filter { !$0.isEmpty }
    }

    static func plain(_ text: String) -> String {
        EverydayText.plainTeX(text.replacingOccurrences(of: "\\\\", with: " ").replacingOccurrences(of: "\\newline", with: " "))
    }

    /// Comments (`%` to the end of the line, the line break included) removed; `\%` kept.
    static func stripComments(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\\"), i + 1 < bytes.count {
                out.append(b)
                out.append(bytes[i + 1])
                i += 2
                continue
            }
            if b == UInt8(ascii: "%") {
                while i < bytes.count, bytes[i] != 0x0A { i += 1 }
                i += 1
                continue
            }
            out.append(b)
            i += 1
        }
        return out
    }

    /// Words of prose: commands dropped (and the arguments of commands that are not prose), math and verbatim
    /// skipped, words being runs of letters and digits (with inner hyphens and apostrophes).
    /// The count, and whether the lookahead budget ran out (the count is then a lower-quality estimate).
    static func countWords(_ bytes: [UInt8]) -> (Int, Bool) {
        var scanner = Scanner(bytes: bytes)
        var count = 0
        var inWord = false
        var wordHasLetter = false
        func flush() {
            if inWord, wordHasLetter { count += 1 }
            inWord = false
            wordHasLetter = false
        }
        while scanner.i < bytes.count {
            let b = bytes[scanner.i]
            if b == UInt8(ascii: "\\") {
                let start = scanner.i
                let name = scanner.commandName()
                if name.count == 1, let c = name.utf8.first, "'\"^`~=.".utf8.contains(c) { continue }   // accents
                flush()
                if name == "[" { scanner.skip(past: Array("\\]".utf8)); continue }
                if name == "(" { scanner.skip(past: Array("\\)".utf8)); continue }
                if name == "begin" {
                    if let env = scanner.group()?.trimmingCharacters(in: .whitespaces) {
                        if mathEnvironments.contains(env) || verbatimEnvironments.contains(env) { scanner.skipToEnd(of: env) }
                        _ = scanner.optional()
                    }
                    continue
                }
                if name == "end" { _ = scanner.group(); continue }
                if name == "write" {        // \write18{…}, \write\file{…}: what is written is not prose
                    while scanner.i < bytes.count, (0x30...0x39).contains(bytes[scanner.i]) { scanner.i += 1 }
                    _ = scanner.group()
                    continue
                }
                if let groups = nonProseCommands[name] ?? (isCiteCommand(name) ? 1 : nil) {
                    _ = scanner.star()
                    _ = scanner.optional()
                    for _ in 0..<groups {
                        _ = scanner.optional()
                        guard scanner.group() != nil else { break }
                    }
                    continue
                }
                if sectionLevels[name] != nil || name == "item" || name == "caption" || name == "footnote" {
                    _ = scanner.star()
                    if name != "item" { _ = scanner.optional() }   // a short title repeats the heading
                }
                if scanner.i == start { scanner.i += 1 }
                continue
            }
            if b == UInt8(ascii: "$") {
                flush()
                if scanner.i + 1 < bytes.count, bytes[scanner.i + 1] == UInt8(ascii: "$") {
                    scanner.i += 2
                    scanner.skip(past: Array("$$".utf8))
                } else {
                    scanner.i += 1
                    scanner.skip(past: [UInt8(ascii: "$")])
                }
                continue
            }
            if b == UInt8(ascii: "{") || b == UInt8(ascii: "}") { scanner.i += 1; continue }
            let isLetter = (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b >= 0x80
            if isLetter {
                inWord = true
                wordHasLetter = true
            } else if inWord, b == UInt8(ascii: "-") || b == UInt8(ascii: "'") {
                // inside a word
            } else {
                flush()
            }
            scanner.i += 1
        }
        flush()
        return (count, scanner.exhausted)
    }

    /// A cursor over LaTeX bytes that reads command names, `*`, `[…]` and `{…}` arguments.
    struct Scanner {
        let bytes: [UInt8]
        var i = 0
        static let maxGroupBytes = 64 * 1024
        /// Bytes the `[…]` and `{…}` lookaheads may read in all. An unclosed brace makes every later lookahead read to
        /// the end of the file; the budget keeps that linear, and once it is spent no more arguments are read
        /// (`exhausted`, reported as `truncated`).
        var budget: Int
        private(set) var exhausted = false

        init(bytes: [UInt8]) {
            self.bytes = bytes
            budget = bytes.count * 4 + 1_048_576
        }

        /// Spends one byte of lookahead; false once the budget is gone.
        mutating func spend() -> Bool {
            budget -= 1
            if budget < 0 { exhausted = true }
            return !exhausted
        }

        /// At a backslash: the command's name (letters, or one other character), with the cursor after it.
        mutating func commandName() -> String {
            i += 1
            let start = i
            while i < bytes.count, (0x41...0x5A).contains(bytes[i]) || (0x61...0x7A).contains(bytes[i]) || bytes[i] == UInt8(ascii: "@") { i += 1 }
            if i == start, i < bytes.count { i += 1 }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        mutating func skipSpaces() {
            var newlines = 0
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0D || bytes[i] == 0x0A {
                if bytes[i] == 0x0A { newlines += 1; if newlines > 1 { return } }
                i += 1
            }
        }

        mutating func star() -> Bool {
            if i < bytes.count, bytes[i] == UInt8(ascii: "*") { i += 1; return true }
            return false
        }

        func peek(_ text: String) -> Bool {
            let pattern = Array(text.utf8)
            return i + pattern.count <= bytes.count && bytes[i..<(i + pattern.count)].elementsEqual(pattern)
        }

        /// `[…]` (brackets inside braces do not end it); nil when there is none.
        mutating func optional() -> String? {
            let save = i
            skipSpaces()
            guard !exhausted, i < bytes.count, bytes[i] == UInt8(ascii: "[") else { i = save; return nil }
            let start = i + 1
            var depth = 0
            var j = start
            while j < bytes.count {
                guard spend() else { break }
                let b = bytes[j]
                if b == UInt8(ascii: "\\") { j += 2; continue }
                if b == UInt8(ascii: "{") { depth += 1 } else if b == UInt8(ascii: "}") { depth -= 1 } else if b == UInt8(ascii: "]"), depth <= 0 {
                    i = j + 1
                    return String(decoding: bytes[start..<min(j, start + Self.maxGroupBytes)], as: UTF8.self)
                }
                j += 1
            }
            i = save
            return nil
        }

        /// `{…}` with nested braces; nil when there is none (the cursor stays put).
        mutating func group() -> String? {
            let save = i
            skipSpaces()
            guard !exhausted, i < bytes.count, bytes[i] == UInt8(ascii: "{") else { i = save; return nil }
            let start = i + 1
            var depth = 0
            var j = i
            while j < bytes.count {
                guard spend() else { break }
                let b = bytes[j]
                if b == UInt8(ascii: "\\") { j += 2; continue }
                if b == UInt8(ascii: "{") { depth += 1 } else if b == UInt8(ascii: "}") {
                    depth -= 1
                    if depth == 0 {
                        i = j + 1
                        return String(decoding: bytes[start..<min(j, start + Self.maxGroupBytes)], as: UTF8.self)
                    }
                }
                j += 1
            }
            i = save
            return nil
        }

        /// `\input file.tex` without braces: the word up to whitespace.
        mutating func bareWord() -> String {
            let start = i
            while i < bytes.count, bytes[i] > 0x20, bytes[i] != UInt8(ascii: "\\"), bytes[i] != UInt8(ascii: "{"), bytes[i] != UInt8(ascii: "}") { i += 1 }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        mutating func skip(past pattern: [UInt8]) {
            while i < bytes.count {
                if bytes[i] == UInt8(ascii: "\\"), pattern.first != UInt8(ascii: "\\") { i += 2; continue }
                if bytes[i] == pattern[0], i + pattern.count <= bytes.count, bytes[i..<(i + pattern.count)].elementsEqual(pattern) {
                    i += pattern.count
                    return
                }
                i += 1
            }
        }

        mutating func skipToEnd(of environment: String) {
            skip(past: Array("\\end{\(environment)}".utf8))
        }
    }
}
