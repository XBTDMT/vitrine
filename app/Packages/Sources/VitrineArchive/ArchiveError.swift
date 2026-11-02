import Foundation

/// Why an archive could not be listed. Every case carries a reason a preview can show as is; no input, however
/// damaged, reaches a trap.
public enum ArchiveError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The file could not be opened or read (permissions, I/O).
    case unreadable(String)
    /// None of the formats this engine reads recognised the bytes.
    case notAnArchive
    /// The file ends before a structure it declares (an end record, a directory, a header).
    case truncated(String)
    /// A structure is present but contradicts itself or the file (bad signature, offsets outside the file).
    case malformed(String)
    /// A valid archive using a feature listing cannot honour (multi-disk zip sets).
    case unsupported(String)

    public var reason: String {
        switch self {
        case .unreadable(let why): String(localized: "Could not read the file: \(why).", bundle: .module, comment: "Archive preview refusal; the argument is a technical reason.")
        case .notAnArchive: String(localized: "Not an archive format Vitrine reads.", bundle: .module, comment: "Archive preview refusal.")
        case .truncated(let why): String(localized: "The archive is truncated: \(why).", bundle: .module, comment: "Archive preview refusal; the argument is a technical reason.")
        case .malformed(let why): String(localized: "The archive is damaged: \(why).", bundle: .module, comment: "Archive preview refusal; the argument is a technical reason.")
        case .unsupported(let why): String(localized: "Unsupported archive: \(why).", bundle: .module, comment: "Archive preview refusal; the argument is a technical reason.")
        }
    }

    public var description: String { reason }
}
