import Foundation

/// Why a binary, bundle, profile, package or disk image could not be read. Every case carries a reason a preview
/// can show as is; no input, however damaged or hostile, reaches a trap.
public enum BinaryError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The file could not be opened or read (permissions, I/O, not a regular file).
    case unreadable(String)
    /// The bytes are not the format the reader was asked for (names what was expected).
    case notRecognized(String)
    /// The file ends before a structure it declares.
    case truncated(String)
    /// A structure is present but contradicts itself or the file (bad magic, offsets outside the file).
    case malformed(String)
    /// A valid file using a feature this engine does not read.
    case unsupported(String)

    public var reason: String {
        switch self {
        case .unreadable(let why): String(localized: "Could not read the file: \(why).", bundle: .module, comment: "Preview refusal for an app, binary, package or profile; the argument is a technical reason.")
        case .notRecognized(let what): String(localized: "Not \(what).", bundle: .module, comment: "Preview refusal; the argument names the expected format, like “a Mach-O binary”.")
        case .truncated(let why): String(localized: "The file is truncated: \(why).", bundle: .module, comment: "Preview refusal for an app, binary, package or profile; the argument is a technical reason.")
        case .malformed(let why): String(localized: "The file is damaged: \(why).", bundle: .module, comment: "Preview refusal for an app, binary, package or profile; the argument is a technical reason.")
        case .unsupported(let why): String(localized: "Unsupported: \(why).", bundle: .module, comment: "Preview refusal for an app, binary, package or profile; the argument is a technical reason.")
        }
    }

    public var description: String { reason }
}

/// The bounds every reader in this module honours. Inputs are untrusted: each count a file declares is capped
/// before anything is allocated for it, and each walk stops at its cap with the shortfall said.
public struct BinaryLimits: Sendable, Equatable {
    /// Architectures in a universal binary. Real ones carry at most a handful; a larger count is refused, which also
    /// keeps Java class files (same magic, count = class version ≥ 45) from being read as universal binaries.
    public var maxFatSlices: Int = 32
    /// Load commands read per slice (real binaries carry tens to a few hundred).
    public var maxLoadCommands: Int = 4096
    /// Bytes of load commands read per slice (`sizeofcmds`).
    public var maxLoadCommandBytes: Int = 4 * 1024 * 1024
    /// Bytes of one embedded code signature read (the code directories' hash slots are most of it).
    public var maxSignatureBytes: Int = 64 * 1024 * 1024
    /// Bytes of an entitlements blob, Info.plist, profile or other property list decoded.
    public var maxPropertyListBytes: Int = 8 * 1024 * 1024
    /// Files and folders visited when measuring a bundle's size on disk.
    public var maxWalkEntries: Int = 200_000
    /// Embedded frameworks, plug-ins, extensions and helpers listed per bundle.
    public var maxEmbeddedItems: Int = 1000
    /// Compressed and decompressed bytes of a xar table of contents.
    public var maxTableOfContentsBytes: Int = 32 * 1024 * 1024
    /// Members of a xar archive listed.
    public var maxXarMembers: Int = 100_000
    /// Decompressed bytes of a package's small XML members (Distribution, PackageInfo).
    public var maxPackageXMLBytes: Int = 4 * 1024 * 1024
    /// Decompressed bytes of a package's Scripts archive read to list its script names.
    public var maxScriptArchiveBytes: Int = 16 * 1024 * 1024
    /// Bytes of a disk image's XML property list read.
    public var maxDiskImagePlistBytes: Int = 64 * 1024 * 1024
    /// Partitions listed from a disk image.
    public var maxPartitions: Int = 1024

    public init() {}

    public static let `default` = BinaryLimits()
}
