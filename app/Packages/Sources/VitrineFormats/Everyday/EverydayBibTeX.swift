import Foundation

/// The entries of a BibTeX file (`.bib`) (E-11): each entry's type, citation key and fields, with `@string` macros
/// expanded and `#` concatenations joined, and each formatted as an author–year citation for the card's list.
/// roadmap: S-23
public struct BibliographySummary: Sendable, Equatable {
    /// One field of an entry. roadmap: S-23
    public struct Field: Sendable, Equatable {
        /// Lowercased.
        public var name: String
        /// The value with macros expanded and concatenations joined, braces and quotes kept off, TeX left as written.
        public var value: String
    }

    /// One bibliography entry. roadmap: S-23
    public struct Entry: Sendable, Equatable {
        /// Lowercased (`article`, `inproceedings`, `book`…).
        public var type: String
        public var key: String
        public var fields: [Field]
        /// The author (or, failing that, editor) names in the file's order, as plain text.
        public var authors: [String]
        /// "Lima, A., & Okafor, B. (2024). A title. Journal of Examples, 12(3), 45–67."
        public var citation: String

        /// A field's raw value by (lowercased) name.
        public func field(_ name: String) -> String? { fields.first { $0.name == name }?.value }
    }

    public static let maxEntries = 20_000
    public static let maxFields = 200

    public var entries: [Entry]
    /// Every entry counted, even past `maxEntries`.
    public var entryCount: Int
    /// `@string` macros the file defines.
    public var macroCount: Int
    /// Entry type → count, most common first.
    public var typeCounts: [EverydayFact]
    public var warnings: [EverydayWarning]
    public var truncated: Bool

    public var headline: String {
        String(localized: "\(entryCount) references", bundle: .module, comment: "Headline of a BibTeX card; the argument is a count of entries.")
    }

    /// The entry-type counts come after the first fact with the BibTeX type names (`article`, `book`) as labels.
    public var facts: [EverydayFact] {
        var facts = [EverydayFact(String(localized: "Entries", bundle: .module, comment: "Fact label on a BibTeX card: number of entries."), "\(entryCount)")]
        facts += typeCounts.prefix(6)
        if macroCount > 0 {
            facts.append(EverydayFact(String(localized: "String macros", bundle: .module, comment: "Fact label on a BibTeX card: @string definitions."),
                                      "\(macroCount)"))
        }
        let years = entries.compactMap { EverydayBibTeX.year(of: $0).flatMap { Int($0) } }
        if let low = years.min(), let high = years.max() {
            facts.append(EverydayFact(String(localized: "Years", bundle: .module, comment: "Fact label on a BibTeX card: the span of publication years."),
                                      low == high ? "\(low)" : "\(low)–\(high)"))
        }
        return facts
    }
}

/// The BibTeX parser and citation formatter behind `BibliographySummary`. It works on UTF-8 bytes (the syntax is
/// ASCII) with explicit brace counters, so nesting never recurses.
enum EverydayBibTeX {
    static func looksLikeBibTeX(_ head: String) -> Bool {
        head.firstMatch(of: /^@[A-Za-z]+\s*[{(]/) != nil
    }

    static let defaultMacros: [String: String] = [
        "jan": "January", "feb": "February", "mar": "March", "apr": "April", "may": "May", "jun": "June",
        "jul": "July", "aug": "August", "sep": "September", "oct": "October", "nov": "November", "dec": "December",
    ]

    static func read(_ raw: [UInt8]) -> BibliographySummary? {
        let bytes = Array(EverydayText.decode(raw).utf8)
        var parser = Parser(bytes: bytes)
        parser.run()
        guard parser.sawEntry else { return nil }
        var summary = BibliographySummary(entries: [], entryCount: parser.entryCount, macroCount: parser.macros.count - defaultMacros.count,
                                          typeCounts: [], warnings: [], truncated: parser.truncated)
        var types: [String: Int] = [:]
        var seen: [String: Int] = [:]
        var duplicates: [String] = []
        for var entry in parser.entries {
            types[entry.type, default: 0] += 1
            let lowerKey = entry.key.lowercased()
            seen[lowerKey, default: 0] += 1
            if seen[lowerKey] == 2, duplicates.count < 20 { duplicates.append(entry.key) }
            format(&entry)
            summary.entries.append(entry)
        }
        summary.typeCounts = types.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { EverydayFact($0.key, "\($0.value)") }
        if !duplicates.isEmpty {
            let keys = duplicates.prefix(5).joined(separator: ", ")
            summary.warnings.append(EverydayWarning(.caution, code: "bibtex.duplicateKey",
                reason: String(localized: "These citation keys are used more than once, and LaTeX will use only one entry for each: \(keys).", bundle: .module,
                               comment: "Warning on a BibTeX card; the argument is one or more citation keys.")))
        }
        if !parser.undefinedMacros.isEmpty {
            let names = parser.undefinedMacros.prefix(5).joined(separator: ", ")
            summary.warnings.append(EverydayWarning(.caution, code: "bibtex.undefinedMacro",
                reason: String(localized: "These string macros are used but never defined: \(names).", bundle: .module,
                               comment: "Warning on a BibTeX card; the argument is one or more @string macro names.")))
        }
        if parser.syntaxErrors > 0 {
            let count = parser.syntaxErrors
            summary.warnings.append(EverydayWarning(.caution, code: "bibtex.syntax",
                reason: String(localized: "\(count) entries are not well formed (an unclosed brace or quote, or a missing key); the rest was read.", bundle: .module,
                               comment: "Warning on a BibTeX card; the argument is a count of entries.")))
        }
        return summary
    }

    // MARK: Parsing

    struct Parser {
        let bytes: [UInt8]
        var i = 0
        var macros: [String: String] = EverydayBibTeX.defaultMacros
        var entries: [BibliographySummary.Entry] = []
        var entryCount = 0
        var sawEntry = false
        var truncated = false
        var syntaxErrors = 0
        var undefinedMacros: [String] = []

        init(bytes: [UInt8]) { self.bytes = bytes }

        static let maxValueBytes = 256 * 1024

        mutating func run() {
            while let at = nextAt() {
                i = at + 1
                let type = identifier().lowercased()
                skipSpace()
                guard !type.isEmpty, i < bytes.count, bytes[i] == UInt8(ascii: "{") || bytes[i] == UInt8(ascii: "(") else { continue }
                let closer = bytes[i] == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: ")")
                let open = i
                i += 1
                sawEntry = true
                switch type {
                case "comment", "preamble":
                    if !skipBalanced(from: open) { syntaxErrors += 1 }
                case "string":
                    skipSpace()
                    let name = identifier().lowercased()
                    skipSpace()
                    guard !name.isEmpty, i < bytes.count, bytes[i] == UInt8(ascii: "=") else { syntaxErrors += 1; resync(); continue }
                    i += 1
                    guard let value = valueExpression(closer: closer) else { syntaxErrors += 1; resync(); continue }
                    macros[name] = value
                    skipSpace()
                    if i < bytes.count, bytes[i] == closer { i += 1 }
                default:
                    if !entry(type: type, closer: closer) { syntaxErrors += 1; resync() }
                }
            }
        }

        /// The next `@` that starts an entry (BibTeX ignores everything between entries).
        func nextAt() -> Int? {
            var j = i
            while j < bytes.count {
                if bytes[j] == UInt8(ascii: "@") { return j }
                j += 1
            }
            return nil
        }

        /// After an error: carry on from the next line that starts with `@`.
        mutating func resync() {
            // Already at the next entry (an unclosed value stopped at it).
            if i < bytes.count, bytes[i] == UInt8(ascii: "@"), i == 0 || bytes[i - 1] == UInt8(ascii: "\n") { return }
            while i < bytes.count {
                if bytes[i] == UInt8(ascii: "\n"), i + 1 < bytes.count {
                    var j = i + 1
                    while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
                    if j < bytes.count, bytes[j] == UInt8(ascii: "@") { i = j; return }
                }
                i += 1
            }
        }

        mutating func entry(type: String, closer: UInt8) -> Bool {
            skipSpace()
            let keyStart = i
            while i < bytes.count, bytes[i] != UInt8(ascii: ","), bytes[i] != closer, bytes[i] != UInt8(ascii: "\n") || i == keyStart { i += 1 }
            let key = String(decoding: bytes[keyStart..<i], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard i < bytes.count else { return false }
            var fields: [BibliographySummary.Field] = []
            while i < bytes.count {
                skipSpace()
                guard i < bytes.count else { return false }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == closer { i += 1; break }
                let name = identifier().lowercased()
                skipSpace()
                guard !name.isEmpty, i < bytes.count, bytes[i] == UInt8(ascii: "=") else { return false }
                i += 1
                guard let value = valueExpression(closer: closer) else { return false }
                if fields.count < BibliographySummary.maxFields { fields.append(.init(name: name, value: value)) } else { truncated = true }
            }
            if key.isEmpty { return false }
            entryCount += 1
            if entries.count < BibliographySummary.maxEntries {
                entries.append(.init(type: type, key: key, fields: fields, authors: [], citation: ""))
            } else {
                truncated = true
            }
            return true
        }

        /// `{…}`, `"…"`, numbers and macro names joined by `#`.
        mutating func valueExpression(closer: UInt8) -> String? {
            var value = ""
            while true {
                skipSpace()
                guard i < bytes.count else { return nil }
                let b = bytes[i]
                if b == UInt8(ascii: "{") {
                    guard let piece = delimited(open: UInt8(ascii: "{"), close: UInt8(ascii: "}")) else { return nil }
                    value += piece
                } else if b == UInt8(ascii: "\"") {
                    guard let piece = quoted() else { return nil }
                    value += piece
                } else {
                    let start = i
                    while i < bytes.count, isNameByte(bytes[i]) { i += 1 }
                    guard i > start else { return nil }
                    let word = String(decoding: bytes[start..<i], as: UTF8.self)
                    if word.allSatisfy(\.isNumber) {
                        value += word
                    } else if let expansion = macros[word.lowercased()] {
                        value += expansion
                    } else {
                        if !undefinedMacros.contains(word), undefinedMacros.count < 50 { undefinedMacros.append(word) }
                        value += word
                    }
                }
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "#") { i += 1; continue }
                return EverydayText.collapse(value)
            }
        }

        /// A braced value: its content with the outer braces off and inner braces kept.
        mutating func delimited(open: UInt8, close: UInt8) -> String? {
            let start = i + 1
            var depth = 0
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\\") { i += 2; continue }
                if b == open { depth += 1 } else if b == close {
                    depth -= 1
                    if depth == 0 {
                        let end = i
                        i += 1
                        return text(start, end)
                    }
                } else if b == UInt8(ascii: "@"), depth == 1, i > 0, bytes[i - 1] == UInt8(ascii: "\n") {
                    return nil      // an unclosed brace ran into the next entry
                }
                i += 1
            }
            return nil
        }

        /// A quoted value: braces inside may hold quotes.
        mutating func quoted() -> String? {
            let start = i + 1
            i += 1
            var depth = 0
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\\") { i += 2; continue }
                if b == UInt8(ascii: "{") { depth += 1 } else if b == UInt8(ascii: "}") { depth = max(0, depth - 1) } else if b == UInt8(ascii: "\""), depth == 0 {
                    let end = i
                    i += 1
                    return text(start, end)
                } else if b == UInt8(ascii: "@"), i > 0, bytes[i - 1] == UInt8(ascii: "\n") {
                    return nil
                }
                i += 1
            }
            return nil
        }

        func text(_ start: Int, _ end: Int) -> String {
            let clipped = min(end, start + Self.maxValueBytes)
            // Not trimmed here: `jex # " Letters"` keeps its space; the joined value is collapsed once.
            return String(decoding: bytes[start..<max(start, clipped)], as: UTF8.self)
        }

        mutating func skipBalanced(from open: Int) -> Bool {
            i = open
            let opener = bytes[open]
            let closer = opener == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: ")")
            var depth = 0
            while i < bytes.count {
                if bytes[i] == opener { depth += 1 } else if bytes[i] == closer {
                    depth -= 1
                    if depth == 0 { i += 1; return true }
                }
                i += 1
            }
            return false
        }

        mutating func identifier() -> String {
            let start = i
            while i < bytes.count, isNameByte(bytes[i]) { i += 1 }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        func isNameByte(_ b: UInt8) -> Bool {
            switch b {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x80...0xFF: true
            case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: ":"), UInt8(ascii: "."), UInt8(ascii: "+"),
                 UInt8(ascii: "/"), UInt8(ascii: "'"), UInt8(ascii: "!"), UInt8(ascii: "?"), UInt8(ascii: "&"), UInt8(ascii: "*"):
                true
            default: false
            }
        }

        mutating func skipSpace() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D { i += 1 }
        }
    }

    // MARK: Citations

    static func year(of entry: BibliographySummary.Entry) -> String? {
        if let year = entry.field("year").map(EverydayText.plainTeX), !year.isEmpty { return year }
        if let date = entry.field("date"), date.count >= 4 { return String(date.prefix(4)) }
        return nil
    }

    static func format(_ entry: inout BibliographySummary.Entry) {
        var names = entry.field("author").map(splitNames) ?? []
        var editors = false
        if names.isEmpty, let editor = entry.field("editor") { names = splitNames(editor); editors = !names.isEmpty }
        entry.authors = names.map { $0.lowercased() == "others" ? etAlWords : EverydayText.plainTeX($0) }
        var pieces: [String] = []
        let people = names.filter { $0.lowercased() != "others" }
        var authorText = joinAuthors(people.map(shortName), etAl: people.count < names.count)
        if editors, !authorText.isEmpty {
            authorText = people.count == 1
                ? String(localized: "\(authorText) (Ed.)", bundle: .module,
                         comment: "A citation's editor (author-year style); the argument is the editor's name like Lima, A. Ed. abbreviates editor.")
                : String(localized: "\(authorText) (Eds.)", bundle: .module,
                         comment: "A citation's editors (author-year style); the argument is the editors' names. Eds. abbreviates editors.")
        }
        if !authorText.isEmpty { pieces.append(authorText) }
        let noDate = String(localized: "n.d.", bundle: .module, comment: "In a citation, in place of the year when the entry has none (no date).")
        pieces.append("(\(year(of: entry) ?? noDate))")
        var citation = pieces.joined(separator: " ") + "."
        if let title = entry.field("title").map(EverydayText.plainTeX), !title.isEmpty {
            citation += " " + withPeriod(title)
        }
        let venueKeys = ["journal", "journaltitle", "booktitle", "publisher", "school", "institution", "organization", "howpublished"]
        let current = entry
        var venue = venueKeys.compactMap { current.field($0) }.first.map(EverydayText.plainTeX) ?? ""
        if venue.isEmpty, let eprint = entry.field("eprint") {
            venue = (entry.field("archiveprefix") ?? entry.field("eprinttype") ?? "arXiv") + ":" + eprint
        }
        if let volume = entry.field("volume").map(EverydayText.plainTeX), !volume.isEmpty {
            venue += (venue.isEmpty ? "" : ", ") + volume
            if let number = (entry.field("number") ?? entry.field("issue")).map(EverydayText.plainTeX), !number.isEmpty {
                venue += "(\(number))"
            }
        }
        if let pages = entry.field("pages").map(EverydayText.plainTeX), !pages.isEmpty {
            venue += (venue.isEmpty ? "" : ", ") + pages.replacingOccurrences(of: "-", with: "–").replacingOccurrences(of: "––", with: "–")
        }
        if !venue.isEmpty { citation += " " + withPeriod(venue) }
        entry.citation = citation
    }

    static func withPeriod(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".?!".contains(last) ? text : text + "."
    }

    /// Names split on " and " outside braces.
    static func splitNames(_ field: String) -> [String] {
        let bytes = Array(field.utf8)
        var names: [String] = []
        var depth = 0
        var start = 0
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "{") { depth += 1 } else if b == UInt8(ascii: "}") { depth = max(0, depth - 1) } else if depth == 0,
                b == 0x20 || b == 0x09 || b == 0x0A, i + 5 <= bytes.count,
                String(decoding: bytes[(i + 1)..<min(bytes.count, i + 4)], as: UTF8.self).lowercased() == "and",
                i + 4 < bytes.count, bytes[i + 4] == 0x20 || bytes[i + 4] == 0x09 || bytes[i + 4] == 0x0A {
                names.append(String(decoding: bytes[start..<i], as: UTF8.self))
                i += 5
                start = i
                continue
            }
            i += 1
        }
        names.append(String(decoding: bytes[start..<bytes.count], as: UTF8.self))
        return names.map { EverydayText.collapse($0) }.filter { !$0.isEmpty }.prefix(500).map { $0 }
    }

    /// "Ana María Lima" / "Lima, Ana María" → "Lima, A. M."; "{World Health Organization}" stays whole;
    /// "Ludwig van Beethoven" → "van Beethoven, L.". ("others" is handled by the caller.)
    static func shortName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), topLevelWords(String(trimmed.dropFirst().dropLast())).count >= 1,
           !trimmed.dropFirst().dropLast().contains("}") {
            return EverydayText.plainTeX(trimmed)
        }
        let commaParts = splitTopLevel(trimmed, on: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var last: String, first: String
        if commaParts.count >= 2 {
            last = commaParts[0]
            first = commaParts[commaParts.count - 1]
            if commaParts.count >= 3 { last += ", " + commaParts[1] }
        } else {
            let words = topLevelWords(trimmed)
            guard words.count > 1 else { return EverydayText.plainTeX(trimmed) }
            // The von part starts at the first lowercase word before the last word.
            let vonIndex = words.dropLast().firstIndex { word in
                guard let c = EverydayText.plainTeX(word).first else { return false }
                return c.isLowercase
            }
            let lastStart = vonIndex ?? words.count - 1
            last = words[lastStart...].joined(separator: " ")
            first = words[..<lastStart].joined(separator: " ")
        }
        let initials = topLevelWords(first).map { initial(EverydayText.plainTeX($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
        let lastPlain = EverydayText.plainTeX(last)
        return initials.isEmpty ? lastPlain : "\(lastPlain), \(initials)"
    }

    /// "Jean-Paul" → "J.-P.", "R." → "R.", "Émile" → "É.".
    static func initial(_ name: String) -> String {
        name.split(separator: "-").compactMap { part in part.first(where: { $0.isLetter }).map { "\($0)." } }.joined(separator: "-")
    }

    static var etAlWords: String {
        String(localized: "et al.", bundle: .module, comment: "In a citation, after the first authors when there are more (and others).")
    }

    /// "Lima, A." / "Lima, A., & Okafor, B." / "Lima, A., Okafor, B., & Chen, C." / six names then "et al.".
    static func joinAuthors(_ names: [String], etAl: Bool) -> String {
        switch names.count {
        case 0: return ""
        case 1 where !etAl: return names[0]
        default:
            if names.count > 7 || etAl {
                let head = names.prefix(6).joined(separator: ", ")
                return String(localized: "\(head), et al.", bundle: .module,
                              comment: "A citation's authors when there are more than are listed; the argument is the first authors' names, comma-separated.")
            }
            let head = names.dropLast().joined(separator: ", ")
            let last = names[names.count - 1]
            return String(localized: "\(head), & \(last)", bundle: .module,
                          comment: "Joins the last author of a citation (author-year style: Lima, A., & Okafor, B.); the first argument is the authors before, comma-separated.")
        }
    }

    static func splitTopLevel(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for c in text {
            if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) }
            if c == separator, depth == 0 { parts.append(current); current = ""; continue }
            current.append(c)
        }
        parts.append(current)
        return parts
    }

    static func topLevelWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var depth = 0
        for c in text {
            if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) }
            if c.isWhitespace, depth == 0 {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
