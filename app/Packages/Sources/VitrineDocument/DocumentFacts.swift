import Foundation

/// Facts several families share, written the same way everywhere.
public enum DocumentFacts {
    public static func size(_ bytes: Int64) -> Fact {
        Fact(key: "size", label: String(localized: "Size", bundle: .module, comment: "Fact label: the file size."), value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }

    /// At 230 words a minute, rounded up, never "0 min".
    public static func readingTime(words: Int) -> String {
        let minutes = max(1, Int((Double(words) / 230).rounded(.up)))
        return String(localized: "\(minutes) min", bundle: .module, comment: "Reading time value, in whole minutes; at least 1.")
    }

    /// A rough token count for language models from the default counter (about four bytes a token); shown with "≈".
    public static func tokens(bytes: Int) -> Fact {
        tokens(TokenCounting.count(.byteCount(bytes)))
    }

    /// The `tokens` fact for a count: "≈ 3,180" for an estimate, the bare number for an exact count (A-4).
    public static func tokens(_ count: TokenCount) -> Fact {
        Fact(key: "tokens", label: String(localized: "Tokens", bundle: .module, comment: "Fact label: approximate language-model token count."),
             value: count.formatted)
    }

    public static func lines(in text: String) -> Fact {
        let n = text.isEmpty ? 0 : text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } } - (text.hasSuffix("\n") ? 1 : 0)
        return Fact(key: "lines", label: String(localized: "Lines", bundle: .module, comment: "Fact label: number of lines."), value: n.formatted())
    }
}

/// Why a document could not be made. Surfaces show `errorDescription`.
public enum DocumentError: Error, LocalizedError, Sendable, Equatable {
    case unreadable(URL)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return String(localized: "Cannot read \(url.lastPathComponent)", bundle: .module, comment: "Error shown when a file cannot be read; the argument is the file name.")
        }
    }
}
