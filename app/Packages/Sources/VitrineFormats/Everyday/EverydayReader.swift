import Foundation

/// Reads everyday files — subtitles, calendar invites, contact cards, email, BibTeX and LaTeX — into summaries for
/// their cards (N-3, N-4, N-5, E-11). The format is chosen by the file's extension first and by its first bytes only
/// when the extension is not one it knows. Every file is untrusted input: at most `maxBytes` are read, lists are
/// capped (and say so with `truncated`), nesting is bounded, nothing is fetched, started or written, and malformed
/// input gives nil or a partial summary with warnings, never a crash. roadmap: S-23
public enum EverydayReader {
    /// The most bytes read from one file; past this the summary is marked `truncated`.
    public static let maxBytes = 32 * 1024 * 1024

    /// Extensions (lowercased, without the dot) the reader recognises, for the preview's kind routing.
    public static let knownExtensions: Set<String> = [
        "srt", "vtt", "webvtt", "ass", "ssa", "ttml", "dfxp", "lrc",
        "ics", "ical", "icalendar", "ifb", "vcf", "vcard",
        "eml", "msg", "bib", "tex", "ltx", "latex",
    ]

    /// nil when the file is not one this reader knows (by extension first, then by its first bytes), or when its
    /// content does not have the shape its extension promises.
    public static func read(data: Data, fileName: String) -> EverydayDocument? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let capped = data.count > maxBytes
        let bytes = [UInt8](data.prefix(maxBytes))
        guard let kind = knownExtensions.contains(ext) ? kind(forExtension: ext) : sniff(bytes) else { return nil }
        guard var document = parse(kind, bytes) else { return nil }
        if capped { document.markTruncated() }
        return document
    }

    // MARK: Routing

    enum Kind: Equatable {
        case subtitles(SubtitleSummary.Format?), calendar, contacts, eml, msg, bibtex, latex
    }

    static func kind(forExtension ext: String) -> Kind? {
        switch ext {
        case "srt": return .subtitles(.srt)
        case "vtt", "webvtt": return .subtitles(.webVTT)
        case "ass": return .subtitles(.ass)
        case "ssa": return .subtitles(.ssa)
        case "ttml", "dfxp": return .subtitles(.ttml)
        case "lrc": return .subtitles(.lrc)
        case "ics", "ical", "icalendar", "ifb": return .calendar
        case "vcf", "vcard": return .contacts
        case "eml": return .eml
        case "msg": return .msg
        case "bib": return .bibtex
        case "tex", "ltx", "latex": return .latex
        default: return nil
        }
    }

    /// The first bytes' shape, for files whose extension says nothing.
    static func sniff(_ bytes: [UInt8]) -> Kind? {
        if bytes.starts(with: EverydayCFB.magic) { return .msg }
        let head = EverydayText.decode(Array(bytes.prefix(4096)))
        let trimmed = head.drop { $0.isWhitespace }
        let upper = trimmed.prefix(64).uppercased()
        if upper.hasPrefix("WEBVTT") { return .subtitles(.webVTT) }
        if upper.hasPrefix("BEGIN:VCALENDAR") { return .calendar }
        if upper.hasPrefix("BEGIN:VCARD") { return .contacts }
        if upper.hasPrefix("[SCRIPT INFO]") { return .subtitles(nil) }
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<tt") {
            if head.contains("<tt ") || head.contains("<tt>") || head.contains("<tt:tt") { return .subtitles(.ttml) }
            return nil
        }
        if trimmed.hasPrefix("\\documentclass") { return .latex }
        if let first = trimmed.first, first == "@", EverydayBibTeX.looksLikeBibTeX(String(trimmed.prefix(200))) { return .bibtex }
        if EverydaySubtitles.looksLikeSRT(String(trimmed.prefix(400))) { return .subtitles(.srt) }
        if EverydayMail.looksLikeMail(String(head.prefix(2048))) { return .eml }
        return nil
    }

    static func parse(_ kind: Kind, _ bytes: [UInt8]) -> EverydayDocument? {
        switch kind {
        case .subtitles(let format): return EverydaySubtitles.read(bytes, format: format).map(EverydayDocument.subtitles)
        case .calendar: return EverydayCalendar.read(bytes).map(EverydayDocument.calendar)
        case .contacts: return EverydayContacts.read(bytes).map(EverydayDocument.contacts)
        case .eml: return EverydayMail.read(bytes).map(EverydayDocument.email)
        case .msg: return EverydayOutlook.read(bytes).map(EverydayDocument.email)
        case .bibtex: return EverydayBibTeX.read(bytes).map(EverydayDocument.bibliography)
        case .latex: return EverydayLaTeX.read(bytes).map(EverydayDocument.latex)
        }
    }
}

/// One everyday file read into the summary its card shows. roadmap: S-23
public enum EverydayDocument: Sendable, Equatable {
    case subtitles(SubtitleSummary)
    case calendar(CalendarSummary)
    case contacts(ContactsSummary)
    case email(EmailSummary)
    case bibliography(BibliographySummary)
    case latex(LaTeXSummary)

    /// One line for the card's title.
    public var headline: String {
        switch self {
        case .subtitles(let s): s.headline
        case .calendar(let s): s.headline
        case .contacts(let s): s.headline
        case .email(let s): s.headline
        case .bibliography(let s): s.headline
        case .latex(let s): s.headline
        }
    }

    /// Label–value pairs for the card's facts grid, in display order.
    public var facts: [EverydayFact] {
        switch self {
        case .subtitles(let s): s.facts
        case .calendar(let s): s.facts
        case .contacts(let s): s.facts
        case .email(let s): s.facts
        case .bibliography(let s): s.facts
        case .latex(let s): s.facts
        }
    }

    public var warnings: [EverydayWarning] {
        switch self {
        case .subtitles(let s): s.warnings
        case .calendar(let s): s.warnings
        case .contacts(let s): s.warnings
        case .email(let s): s.warnings
        case .bibliography(let s): s.warnings
        case .latex(let s): s.warnings
        }
    }

    /// The input passed a limit (size, list length, nesting) or ended early, so the summary covers part of it.
    public var truncated: Bool {
        switch self {
        case .subtitles(let s): s.truncated
        case .calendar(let s): s.truncated
        case .contacts(let s): s.truncated
        case .email(let s): s.truncated
        case .bibliography(let s): s.truncated
        case .latex(let s): s.truncated
        }
    }

    mutating func markTruncated() {
        switch self {
        case .subtitles(var s): s.truncated = true; self = .subtitles(s)
        case .calendar(var s): s.truncated = true; self = .calendar(s)
        case .contacts(var s): s.truncated = true; self = .contacts(s)
        case .email(var s): s.truncated = true; self = .email(s)
        case .bibliography(var s): s.truncated = true; self = .bibliography(s)
        case .latex(var s): s.truncated = true; self = .latex(s)
        }
    }
}

/// A problem or risk worth showing on an everyday file's card, in plain English. `code` is a stable identifier
/// (for example `subtitles.hardToRead`) the app can key a translation on; `reason` is the English sentence.
/// roadmap: S-23
public struct EverydayWarning: Sendable, Equatable {
    /// How loud the card should be about it. roadmap: S-23
    public enum Level: String, Sendable, Equatable {
        case caution, danger
    }

    public var level: Level
    public var code: String
    public var reason: String

    public init(_ level: Level, code: String, reason: String) {
        self.level = level
        self.code = code
        self.reason = reason
    }
}

/// One label–value pair for a card's facts grid (English labels; the app may key translations on `label`).
/// roadmap: S-23
public struct EverydayFact: Sendable, Equatable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

// MARK: - Shared text helpers

/// Byte-to-text decoding shared by the everyday readers: BOMs, UTF-8, named charsets, and Windows-1252 as the
/// fallback for old files that are not UTF-8.
enum EverydayText {
    static func decode(_ bytes: [UInt8]) -> String {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: bytes.dropFirst(3), as: UTF8.self) }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: Data(bytes.dropFirst(2)), encoding: .utf16LittleEndian) ?? latin1(bytes)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian) ?? latin1(bytes)
        }
        if let text = String(validating: bytes, as: UTF8.self) { return text }
        return String(data: Data(bytes), encoding: .windowsCP1252) ?? latin1(bytes)
    }

    static func decode<C: Collection>(_ bytes: C, charset: String?) -> String where C.Element == UInt8 {
        let array = Array(bytes)
        guard let charset = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased(),
              !charset.isEmpty else { return decode(array) }
        switch charset {
        case "utf-8", "utf8": return String(validating: array, as: UTF8.self) ?? decode(array)
        case "us-ascii", "ascii": return String(validating: array, as: UTF8.self) ?? decode(array)
        default: break
        }
        if let encoding = encoding(forCharset: charset), let text = String(data: Data(array), encoding: encoding) {
            return text
        }
        return decode(array)
    }

    static func encoding(forCharset name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func latin1<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    /// Lines split on CRLF, CR or LF; the separators are dropped.
    static func lines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
    }

    /// Runs of whitespace collapsed to one space, ends trimmed.
    static func collapse<S: StringProtocol>(_ text: S) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Cuts `text` to at most `limit` characters, marking the cut with an ellipsis.
    static func cap(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// The value of base64 text, ignoring whitespace; nil when it is not base64.
    static func base64(_ text: some StringProtocol) -> [UInt8]? {
        var cleaned = String(text.filter { !$0.isWhitespace })
        let remainder = cleaned.count % 4
        if remainder == 2 { cleaned += "==" } else if remainder == 3 { cleaned += "=" }
        return Data(base64Encoded: cleaned).map { [UInt8]($0) }
    }

    /// The decoded size of base64 text without decoding it.
    static func base64Size(_ text: some StringProtocol) -> Int {
        var count = 0, padding = 0
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            count += 1
            if scalar == "=" { padding += 1 }
        }
        return max(0, count / 4 * 3 + (count % 4 == 0 ? 0 : max(0, count % 4 - 1)) - padding)
    }

    /// Quoted-printable bytes decoded (soft line breaks removed).
    static func quotedPrintable(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D {      // "="
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { i += 3; continue }
                if i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
                    out.append(hi << 4 | lo)
                    i += 3
                    continue
                }
                // A soft break with trailing whitespace before the newline.
                var j = i + 1
                while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
                if j < bytes.count, bytes[j] == 0x0A { i = j + 1; continue }
                if j + 1 < bytes.count, bytes[j] == 0x0D, bytes[j + 1] == 0x0A { i = j + 2; continue }
                if j >= bytes.count { break }
            }
            out.append(b)
            i += 1
        }
        return out
    }

    static func hex(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: b - 0x30
        case 0x41...0x46: b - 0x37
        case 0x61...0x66: b - 0x57
        default: nil
        }
    }

    /// LaTeX accent commands and markup in BibTeX and LaTeX values turned into plain text: `{\"o}` → ö,
    /// `\'e` → é, `--` → –, braces dropped, other commands dropped with their argument kept.
    static func plainTeX(_ text: String) -> String {
        let accents: [Character: [Character: String]] = [
            "\"": ["a": "ä", "o": "ö", "u": "ü", "e": "ë", "i": "ï", "A": "Ä", "O": "Ö", "U": "Ü", "y": "ÿ"],
            "'": ["a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý", "c": "ć", "n": "ń", "s": "ś", "z": "ź",
                  "A": "Á", "E": "É", "I": "Í", "O": "Ó", "U": "Ú"],
            "`": ["a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù", "A": "À", "E": "È"],
            "^": ["a": "â", "e": "ê", "i": "î", "o": "ô", "u": "û", "A": "Â", "E": "Ê", "O": "Ô"],
            "~": ["a": "ã", "n": "ñ", "o": "õ", "A": "Ã", "N": "Ñ", "O": "Õ"],
            "c": ["c": "ç", "C": "Ç", "s": "ş"],
            "v": ["c": "č", "s": "š", "z": "ž", "r": "ř", "e": "ě", "C": "Č", "S": "Š", "Z": "Ž"],
            "=": ["a": "ā", "e": "ē", "o": "ō", "u": "ū"],
            ".": ["z": "ż", "Z": "Ż"],
            "H": ["o": "ő", "u": "ű", "O": "Ő", "U": "Ű"],
            "r": ["a": "å", "A": "Å"],
        ]
        let symbols: [String: String] = [
            "ss": "ß", "o": "ø", "O": "Ø", "ae": "æ", "AE": "Æ", "oe": "œ", "OE": "Œ", "aa": "å", "AA": "Å",
            "l": "ł", "L": "Ł", "i": "ı", "&": "&", "%": "%", "$": "$", "#": "#", "_": "_", "{": "{", "}": "}",
            "textendash": "–", "textemdash": "—", "LaTeX": "LaTeX", "TeX": "TeX", "ldots": "…", "dots": "…",
        ]
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if let table = accents[next], !next.isLetter || (i + 2 < chars.count && (chars[i + 2] == "{" || chars[i + 2] == " ")) {
                    // \"o, \"{o}, \c{c}, \v s
                    var j = i + 2
                    if j < chars.count, chars[j] == " ", next.isLetter { j += 1 }
                    var braced = false
                    if j < chars.count, chars[j] == "{" { braced = true; j += 1 }
                    if j < chars.count, chars[j] == "\\", j + 1 < chars.count, chars[j + 1] == "i" { j += 1 }
                    if j < chars.count, let mapped = table[chars[j]] {
                        out += mapped
                        j += 1
                        if braced, j < chars.count, chars[j] == "}" { j += 1 }
                        i = j
                        continue
                    }
                }
                if !next.isLetter {
                    if let symbol = symbols[String(next)] { out += symbol } else if next == "\\" { out += " " } else { out.append(next) }
                    i += 2
                    continue
                }
                var j = i + 1
                var name = ""
                while j < chars.count, chars[j].isLetter { name.append(chars[j]); j += 1 }
                if let symbol = symbols[name] {
                    out += symbol
                    if j < chars.count, chars[j] == " " { j += 1 }
                } else if j < chars.count, chars[j] == " " {
                    j += 1      // a command eats the space after it
                }
                i = j
                continue
            }
            if c == "{" || c == "}" { i += 1; continue }
            if c == "~" { out += " "; i += 1; continue }
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                if i + 2 < chars.count, chars[i + 2] == "-" { out += "—"; i += 3 } else { out += "–"; i += 2 }
                continue
            }
            out.append(c)
            i += 1
        }
        return collapse(out)
    }
}
