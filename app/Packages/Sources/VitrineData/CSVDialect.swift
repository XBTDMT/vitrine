import Foundation

/// The field separators Vitrine recognises. Each is one ASCII byte, which is what lets the scanner work on raw bytes
/// for every supported encoding (UTF-8 and Latin-1 agree on ASCII). roadmap: S-6
public enum CSVDelimiter: UInt8, Sendable, CaseIterable, Codable {
    case comma = 0x2C
    case tab = 0x09
    case semicolon = 0x3B
    case pipe = 0x7C

    /// The name the metadata strip shows.
    public var name: String {
        switch self {
        case .comma: String(localized: "Comma", bundle: .module, comment: "CSV field separator name.")
        case .tab: String(localized: "Tab", bundle: .module, comment: "CSV field separator name: the tab character.")
        case .semicolon: String(localized: "Semicolon", bundle: .module, comment: "CSV field separator name.")
        case .pipe: String(localized: "Pipe", bundle: .module, comment: "CSV field separator name: the | character.")
        }
    }

    public var character: Character { Character(Unicode.Scalar(rawValue)) }

    /// Maps `FileKind.csv(delimiter:)` back to a delimiter.
    public init?(_ character: Character) {
        guard let ascii = character.asciiValue, let value = CSVDelimiter(rawValue: ascii) else { return nil }
        self = value
    }

    /// What the file name promises. Only a hint: the sniffer overrides it when the sample clearly disagrees, because
    /// "semicolon CSV" files named `.csv` are common wherever the decimal separator is a comma.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "csv": self = .comma
        case "tsv", "tab": self = .tab
        case "psv": self = .pipe
        default: return nil
        }
    }
}

/// The quote character. Double quotes are RFC 4180; single quotes turn up in hand-written and some database exports.
public enum CSVQuote: UInt8, Sendable, Codable {
    case double = 0x22
    case single = 0x27
}

/// How records end. The parser accepts all three anywhere in a file (mixed files are common after copy and paste);
/// this is what the sample mostly used, for the metadata strip and the lint banner.
public enum CSVLineEnding: String, Sendable, Codable {
    case lf, crlf, cr

    public var displayName: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }
}

/// The text encoding fields are decoded with.
public enum CSVTextEncoding: String, Sendable, Codable {
    case utf8
    /// The fallback when the sample is not valid UTF-8. Decoded as Windows-1252, which is what "Latin-1" means in
    /// practice (WHATWG maps the label that way, and Excel's non-Unicode exports are Windows-1252): bytes 0x80–0x9F
    /// become curly quotes and dashes instead of invisible control characters. Every byte decodes, so a field can
    /// never fail to show.
    case latin1

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .latin1: "Latin-1 (Windows-1252)"
        }
    }
}

/// Everything the parser needs to know about a delimited file, decided once from a bounded sample.
public struct CSVDialect: Sendable, Equatable, Codable {
    public var delimiter: CSVDelimiter
    public var quote: CSVQuote
    /// Whether record 1 holds column names rather than data.
    public var hasHeader: Bool
    /// The terminator the sample used most; nil when the sample held no line break at all.
    public var lineEnding: CSVLineEnding?
    /// Whether the file starts with the UTF-8 byte order mark (skipped, never shown as part of the first field).
    public var hasBOM: Bool
    public var encoding: CSVTextEncoding
    /// True when a delimiter hint (the file extension) was given and the sample overruled it: a `.csv` that is really
    /// semicolon-separated. The lint banner says so.
    public var overrodeHint: Bool

    public init(delimiter: CSVDelimiter = .comma, quote: CSVQuote = .double, hasHeader: Bool = true,
                lineEnding: CSVLineEnding? = .lf, hasBOM: Bool = false, encoding: CSVTextEncoding = .utf8,
                overrodeHint: Bool = false) {
        self.delimiter = delimiter; self.quote = quote; self.hasHeader = hasHeader; self.lineEnding = lineEnding
        self.hasBOM = hasBOM; self.encoding = encoding; self.overrodeHint = overrodeHint
    }

    /// Where the first record starts: after the byte order mark, if any.
    public var contentOffset: Int64 { hasBOM ? 3 : 0 }

    /// Numbers in semicolon files usually use a decimal comma (`3,14`); the delimiter frees the comma for that.
    var allowsDecimalComma: Bool { delimiter == .semicolon }
}

/// Why a file cannot be read as delimited text. I/O errors from Foundation pass through unchanged.
public enum CSVError: Error, Sendable, Equatable {
    /// The file declares an encoding the byte scanner cannot read (UTF-16 and UTF-32 put NULs between ASCII bytes).
    case unsupportedEncoding(String)
    /// NUL bytes in the sample: this is not text. The caller falls back to the hex view.
    case binaryContent
}
