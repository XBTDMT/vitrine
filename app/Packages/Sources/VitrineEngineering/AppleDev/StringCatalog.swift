import Foundation

/// A String Catalog (`.xcstrings`): its source language, every language it holds, how far each translation has
/// come, where plural, device and substitution variations are used, and a translation table (key, comment and each
/// language's state and text) of at most `StringCatalogSummary.maxRows` keys. roadmap: S-22
public struct StringCatalogSummary: Sendable, Equatable {
    /// The most keys kept in `rows`; every key is still counted.
    public static let maxRows = 5_000

    /// Where one key stands in one language. `missing` means the language has no entry for the key at all.
    /// roadmap: S-22
    public enum State: String, Sendable, Equatable {
        case translated, needsReview = "needs_review", new, stale, missing

        /// Plain words for the table ("needs review").
        public var label: String {
            switch self {
            case .translated: String(localized: "translated", bundle: .module, comment: "State of a string in a String Catalog's translation table.")
            case .needsReview: String(localized: "needs review", bundle: .module, comment: "State of a string in a String Catalog's translation table: translated, but a person should check it.")
            case .new: String(localized: "new", bundle: .module, comment: "State of a string in a String Catalog's translation table: not translated yet.")
            case .stale: String(localized: "stale", bundle: .module, comment: "State of a string in a String Catalog's translation table: the source text changed or went away.")
            case .missing: String(localized: "missing", bundle: .module, comment: "State of a string in a String Catalog's translation table: the language has no entry at all.")
            }
        }
    }

    /// One language's progress over the keys that are meant to be translated. The five counts add up to `total`.
    /// roadmap: S-22
    public struct Coverage: Sendable, Equatable {
        public var language: String
        public var translated = 0
        public var needsReview = 0
        public var new = 0
        public var stale = 0
        public var missing = 0

        public init(language: String) { self.language = language }

        public var total: Int { translated + needsReview + new + stale + missing }
        /// Translated keys over all translatable keys, 0…1 (1 when there is nothing to translate).
        public var fraction: Double { total == 0 ? 1 : Double(translated) / Double(total) }
    }

    /// One key's text in one language: its state, the text (for plural or device variations the "other" form, or
    /// the first one) and whether it varies. roadmap: S-22
    public struct Cell: Sendable, Equatable {
        public var state: State
        public var value: String?
        public var hasVariations: Bool

        public init(state: State, value: String?, hasVariations: Bool = false) {
            self.state = state
            self.value = value
            self.hasVariations = hasVariations
        }
    }

    /// One key of the translation table. roadmap: S-22
    public struct Row: Sendable, Equatable {
        public var key: String
        public var comment: String?
        /// Xcode's `extractionState` ("manual", "stale", "extracted_with_value", "migrated"), when written.
        public var extractionState: String?
        /// false when the key is marked "Don't translate".
        public var shouldTranslate: Bool
        /// Language code → cell, for every language in `languages`.
        public var cells: [String: Cell]
    }

    public var sourceLanguage: String?
    /// The catalog's own format version ("1.0", "1.1").
    public var version: String?
    /// The source language first, then the others in code order.
    public var languages: [String]
    public var keyCount: Int
    /// Keys marked "Don't translate".
    public var doNotTranslateCount: Int
    /// Keys Xcode marks stale: the code no longer uses them.
    public var staleKeyCount: Int
    /// One entry per language, in `languages` order.
    public var coverage: [Coverage]
    /// Keys whose text varies by plural form in at least one language.
    public var pluralKeyCount: Int
    /// Keys whose text varies by device in at least one language.
    public var deviceKeyCount: Int
    /// Keys with at least one substitution (`%#@name@`), and the substitutions counted over all keys and languages.
    public var substitutionKeyCount: Int
    public var substitutionCount: Int
    /// Translations whose format placeholders (`%@`, `%lld`, `%1$@` …) do not match the source text's.
    public var placeholderMismatchCount: Int
    /// Keys in key order, at most `maxRows`.
    public var rows: [Row]
    /// More keys exist than `rows` holds.
    public var truncated: Bool
    public var warnings: [AppleDevWarning]

    public var headline: String {
        let keys = keyCount, count = languages.count
        return String(localized: "String Catalog — \(keys) keys in \(count) languages", bundle: .module,
                      comment: "Headline of a String Catalog card: how many keys, in how many languages.")
    }

    public var facts: [AppleDevFact] {
        var out: [AppleDevFact] = []
        if let sourceLanguage {
            out.append(.init(String(localized: "Source language", bundle: .module, comment: "Fact label on a String Catalog card."),
                             AppleDevText.languageName(sourceLanguage)))
        }
        out.append(.init(String(localized: "Languages", bundle: .module, comment: "Fact label on a String Catalog card."),
                         languages.joined(separator: ", ")))
        out.append(.init(String(localized: "Keys", bundle: .module, comment: "Fact label on a String Catalog card: how many strings it holds."),
                         keyCount.formatted()))
        if doNotTranslateCount > 0 {
            out.append(.init(String(localized: "Not translated on purpose", bundle: .module, comment: "Fact label on a String Catalog card: keys marked “Don't translate”."),
                             doNotTranslateCount.formatted()))
        }
        if staleKeyCount > 0 {
            out.append(.init(String(localized: "Stale keys", bundle: .module, comment: "Fact label on a String Catalog card: keys the code no longer uses."),
                             staleKeyCount.formatted()))
        }
        if pluralKeyCount > 0 {
            let n = pluralKeyCount
            out.append(.init(String(localized: "Plural variations", bundle: .module, comment: "Fact label on a String Catalog card."),
                             String(localized: "\(n) keys", bundle: .module, comment: "A count of keys in a String Catalog.")))
        }
        if deviceKeyCount > 0 {
            let n = deviceKeyCount
            out.append(.init(String(localized: "Device variations", bundle: .module, comment: "Fact label on a String Catalog card."),
                             String(localized: "\(n) keys", bundle: .module, comment: "A count of keys in a String Catalog.")))
        }
        if substitutionKeyCount > 0 {
            let n = substitutionKeyCount
            out.append(.init(String(localized: "Substitutions", bundle: .module, comment: "Fact label on a String Catalog card: keys that fill one string into another."),
                             String(localized: "\(n) keys", bundle: .module, comment: "A count of keys in a String Catalog.")))
        }
        for c in coverage where c.language != sourceLanguage {
            let percent = Int((c.fraction * 100).rounded(.down))
            out.append(.init(AppleDevText.languageName(c.language),
                             String(localized: "\(percent)% translated", bundle: .module, comment: "How far one language of a String Catalog is translated, as a whole percentage.")))
        }
        if let version {
            out.append(.init(String(localized: "Format version", bundle: .module, comment: "Fact label on a String Catalog card: the file format's version."), version))
        }
        return out
    }
}

enum StringCatalogReader {
    static let maxVariationDepth = 8

    /// What one localization (a stringUnit, or variations and substitutions around them) adds up to.
    struct Leafs {
        var states: [StringCatalogSummary.State] = []
        /// (variation path such as "plural.one", text) for each leaf with text.
        var values: [(path: String, text: String)] = []
        var plural = false
        var device = false
        var substitutions = 0
    }

    static func read(_ data: Data) -> StringCatalogSummary? {
        guard let root = AppleDevJSON.object(data), let strings = root["strings"] as? [String: Any] else { return nil }
        let source = AppleDevJSON.string(root["sourceLanguage"])
        let version = AppleDevJSON.string(root["version"])

        // Languages: the source first, then every language any key has.
        var languageSet = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let locs = entry["localizations"] as? [String: Any] { languageSet.formUnion(locs.keys) }
        }
        if let source { languageSet.remove(source) }
        let languages = (source.map { [$0] } ?? []) + languageSet.sorted()

        var coverage = Dictionary(uniqueKeysWithValues: languages.map { ($0, StringCatalogSummary.Coverage(language: $0)) })
        var rows: [StringCatalogSummary.Row] = []
        var doNotTranslate = 0, staleKeys = 0, pluralKeys = 0, deviceKeys = 0, substitutionKeys = 0, substitutions = 0
        var mismatches: [(key: String, language: String)] = []
        var needsReviewKeys: [String: Int] = [:]

        let keys = strings.keys.sorted()
        for key in keys {
            let entry = strings[key] as? [String: Any] ?? [:]
            let shouldTranslate = AppleDevJSON.bool(entry["shouldTranslate"]) ?? true
            let extraction = AppleDevJSON.string(entry["extractionState"])
            if !shouldTranslate { doNotTranslate += 1 }
            if extraction == "stale" { staleKeys += 1 }
            let locs = entry["localizations"] as? [String: Any] ?? [:]

            var cells: [String: StringCatalogSummary.Cell] = [:]
            var keyPlural = false, keyDevice = false, keySubs = false
            var leafsByLanguage: [String: Leafs] = [:]
            for language in languages {
                guard let loc = locs[language] as? [String: Any] else { continue }
                var leafs = Leafs()
                collect(loc, path: "", depth: 0, into: &leafs)
                leafsByLanguage[language] = leafs
                keyPlural = keyPlural || leafs.plural
                keyDevice = keyDevice || leafs.device
                keySubs = keySubs || leafs.substitutions > 0
                substitutions += leafs.substitutions
            }
            if keyPlural { pluralKeys += 1 }
            if keyDevice { deviceKeys += 1 }
            if keySubs { substitutionKeys += 1 }

            // The source text placeholders are compared against: the source's own leaves, or the key itself.
            let sourceLeafs = source.flatMap { leafsByLanguage[$0] }
            for language in languages {
                let cell: StringCatalogSummary.Cell
                if let leafs = leafsByLanguage[language] {
                    let state = worst(leafs.states) ?? (language == source ? .translated : .new)
                    let shown = leafs.values.first { $0.path.hasSuffix("other") }?.text ?? leafs.values.first?.text
                    cell = .init(state: state, value: shown, hasVariations: leafs.plural || leafs.device || leafs.substitutions > 0)
                    if language != source, hasMismatch(leafs, source: sourceLeafs, key: key) {
                        mismatches.append((key, language))
                    }
                } else if language == source {
                    // Xcode uses the key itself as the source text when the source has no entry.
                    cell = .init(state: .translated, value: key)
                } else {
                    cell = .init(state: .missing, value: nil)
                }
                cells[language] = cell
                if shouldTranslate { coverage[language]?.add(cell.state) }
                if shouldTranslate, cell.state == .needsReview { needsReviewKeys[language, default: 0] += 1 }
            }
            if rows.count < StringCatalogSummary.maxRows {
                rows.append(.init(key: key, comment: AppleDevJSON.string(entry["comment"]), extractionState: extraction,
                                  shouldTranslate: shouldTranslate, cells: cells))
            }
        }

        let ordered = languages.compactMap { coverage[$0] }
        var warnings: [AppleDevWarning] = []
        if !mismatches.isEmpty {
            let first = mismatches[0], count = mismatches.count
            let key = AppleDevText.clip(first.key, 60), language = AppleDevText.languageName(first.language)
            warnings.append(.init(.danger, String(
                localized: "\(count) translations use placeholders that do not match the source text (first: “\(key)” in \(language)). When the app fills them in it can show the wrong value or crash.",
                bundle: .module, comment: "Warning on a String Catalog card. Placeholders are format codes such as %@ or %lld; the arguments are a count, a key and a language name.")))
        }
        if source == nil {
            warnings.append(.init(.caution, String(localized: "The catalog does not name its source language.", bundle: .module,
                                                   comment: "Warning on a String Catalog card.")))
        }
        for c in ordered where c.language != source && c.translated < c.total {
            var parts: [String] = []
            let missing = c.missing, new = c.new, review = c.needsReview, stale = c.stale
            if missing > 0 { parts.append(String(localized: "\(missing) missing", bundle: .module, comment: "Part of a String Catalog warning: how many strings a language has no entry for.")) }
            if new > 0 { parts.append(String(localized: "\(new) new", bundle: .module, comment: "Part of a String Catalog warning: how many strings are not translated yet.")) }
            if review > 0 { parts.append(String(localized: "\(review) need review", bundle: .module, comment: "Part of a String Catalog warning: how many translations a person should check.")) }
            if stale > 0 { parts.append(String(localized: "\(stale) stale", bundle: .module, comment: "Part of a String Catalog warning: how many translations are out of date.")) }
            let language = AppleDevText.languageName(c.language), untranslated = c.total - c.translated, total = c.total
            let detail = parts.joined(separator: ", ")
            warnings.append(.init(.caution, String(
                localized: "\(language): \(untranslated) of \(total) strings not translated yet (\(detail)). People using the app in this language see the source text instead.",
                bundle: .module, comment: "Warning on a String Catalog card. Arguments: a language name, two counts, then a list such as “2 missing, 1 new”.")))
        }
        if staleKeys > 0 {
            let n = staleKeys
            warnings.append(.init(.caution, String(
                localized: "\(n) keys are stale: the code no longer uses them, so they can be removed.",
                bundle: .module, comment: "Warning on a String Catalog card.")))
        }
        return StringCatalogSummary(
            sourceLanguage: source, version: version, languages: languages, keyCount: keys.count,
            doNotTranslateCount: doNotTranslate, staleKeyCount: staleKeys, coverage: ordered, pluralKeyCount: pluralKeys,
            deviceKeyCount: deviceKeys, substitutionKeyCount: substitutionKeys, substitutionCount: substitutions,
            placeholderMismatchCount: mismatches.count, rows: rows, truncated: keys.count > rows.count,
            warnings: warnings.sorted { $0.level > $1.level })
    }

    /// Walks a localization: a `stringUnit`, `variations` (plural or device, which may nest) and `substitutions`.
    static func collect(_ loc: [String: Any], path: String, depth: Int, into leafs: inout Leafs) {
        guard depth < maxVariationDepth else { return }
        if let unit = loc["stringUnit"] as? [String: Any] {
            leafs.states.append(state(AppleDevJSON.string(unit["state"])))
            if let value = AppleDevJSON.string(unit["value"]) { leafs.values.append((path, value)) }
        }
        if let variations = loc["variations"] as? [String: Any] {
            for (kind, cases) in variations.sorted(by: { $0.key < $1.key }) {
                if kind == "plural" { leafs.plural = true }
                if kind == "device" { leafs.device = true }
                guard let cases = cases as? [String: Any] else { continue }
                for (name, nested) in cases.sorted(by: { $0.key < $1.key }) {
                    guard let nested = nested as? [String: Any] else { continue }
                    collect(nested, path: path.isEmpty ? "\(kind).\(name)" : "\(path).\(kind).\(name)", depth: depth + 1, into: &leafs)
                }
            }
        }
        if let subs = loc["substitutions"] as? [String: Any] {
            for (name, sub) in subs.sorted(by: { $0.key < $1.key }) {
                leafs.substitutions += 1
                guard let sub = sub as? [String: Any] else { continue }
                // A substitution's own variations decide its state but not the shown text.
                var inner = Leafs()
                collect(sub, path: "sub.\(name)", depth: depth + 1, into: &inner)
                leafs.states += inner.states
                leafs.plural = leafs.plural || inner.plural
                leafs.device = leafs.device || inner.device
            }
        }
    }

    static func state(_ raw: String?) -> StringCatalogSummary.State {
        switch raw {
        case "needs_review": .needsReview
        case "new": .new
        case "stale": .stale
        default: .translated
        }
    }

    /// The state that most needs attention: new, then needs review, then stale, then translated.
    static func worst(_ states: [StringCatalogSummary.State]) -> StringCatalogSummary.State? {
        let rank: [StringCatalogSummary.State: Int] = [.translated: 0, .stale: 1, .needsReview: 2, .new: 3, .missing: 4]
        return states.max { (rank[$0] ?? 0) < (rank[$1] ?? 0) }
    }

    /// True when a translated leaf uses a placeholder the source does not have at that position, or with another type.
    /// A leaf that leaves a placeholder out ("One file") is fine.
    static func hasMismatch(_ leafs: Leafs, source: Leafs?, key: String) -> Bool {
        let sourceValues = source?.values ?? []
        let fallback = sourceValues.first { $0.path.hasSuffix("other") }?.text ?? sourceValues.first?.text ?? key
        for leaf in leafs.values {
            let reference = sourceValues.first { $0.path == leaf.path }?.text ?? fallback
            let allowed = Set(placeholders(reference))
            if !Set(placeholders(leaf.text)).isSubset(of: allowed) { return true }
        }
        return false
    }

    /// The placeholders of a format string as (position, kind) strings: "1:object", "2:int", "sub:files".
    static func placeholders(_ text: String) -> [String] {
        var out: [String] = []
        let chars = Array(text.unicodeScalars)
        var i = 0, sequential = 0
        while i < chars.count, out.count < 64 {
            guard chars[i] == "%" else { i += 1; continue }
            var j = i + 1
            guard j < chars.count else { break }
            if chars[j] == "%" { i = j + 1; continue }
            // Substitution: %#@name@
            if chars[j] == "#", j + 1 < chars.count, chars[j + 1] == "@" {
                var k = j + 2, name = ""
                while k < chars.count, chars[k] != "@", name.count < 64 { name.unicodeScalars.append(chars[k]); k += 1 }
                out.append("sub:\(name)")
                i = k + 1
                continue
            }
            // Optional position "n$".
            var digits = ""
            var k = j
            while k < chars.count, ("0"..."9").contains(chars[k]) { digits.unicodeScalars.append(chars[k]); k += 1 }
            var position: Int?
            if k < chars.count, chars[k] == "$", let n = Int(digits) { position = n; j = k + 1 }
            // Flags, width, precision, length.
            while j < chars.count, "-+ #0123456789.*'".unicodeScalars.contains(chars[j]) { j += 1 }
            while j < chars.count, "hlqLzjt".unicodeScalars.contains(chars[j]) { j += 1 }
            guard j < chars.count else { break }
            let kind: String? = switch chars[j] {
            case "@": "object"
            case "d", "D", "i", "u", "U", "x", "X", "o", "O": "int"
            case "f", "F", "e", "E", "g", "G", "a", "A": "float"
            case "s", "S": "cstring"
            case "c", "C": "char"
            case "p": "pointer"
            default: nil
            }
            if let kind {
                sequential += 1
                out.append("\(position ?? sequential):\(kind)")
            }
            i = j + 1
        }
        return out
    }
}

extension StringCatalogSummary.Coverage {
    mutating func add(_ state: StringCatalogSummary.State) {
        switch state {
        case .translated: translated += 1
        case .needsReview: needsReview += 1
        case .new: new += 1
        case .stale: stale += 1
        case .missing: missing += 1
        }
    }
}
