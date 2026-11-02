import Foundation

/// One member of an archive, as its directory or header describes it. Nothing here comes from the member's data
/// except a zip symlink's target (a few bytes, read so the safety report can say where the link points). Optional
/// fields are nil when the format does not record them, never guessed.
public struct ArchiveEntry: Sendable, Equatable {
    /// The path as stored, decoded per `pathEncoding`. Untrusted: it may hold `..`, a leading `/`, backslashes,
    /// control characters or bidi overrides; `ArchiveSafety` reports those, and nothing here cleans them.
    public var path: String
    public var type: EntryType
    /// Bytes the member expands to. For a lone gzip member this is the ISIZE trailer, see
    /// `uncompressedSizeIsModulo4GiB`.
    public var uncompressedSize: Int64?
    /// Bytes the member occupies in the archive (zip and gzip only; tar stores members uncompressed, and libarchive
    /// reports no per-member packed size for the formats it reads, so it stays nil there rather than estimated).
    public var compressedSize: Int64?
    /// How the member's data is compressed (zip and gzip).
    public var method: CompressionMethod?
    public var crc32: UInt32?
    public var modified: ArchiveTimestamp?
    /// `st_mode`-style bits: the file type (`S_IFDIR`, `S_IFLNK` …) plus permissions, when the archive records Unix
    /// modes. Nil for zips made on systems without them.
    public var mode: UInt32?
    /// Where a symlink points, or which earlier member a hardlink names.
    public var linkTarget: String?
    /// Nil when the member is not encrypted.
    public var encryption: Encryption?
    public var uid: Int64?
    public var gid: Int64?
    public var userName: String?
    public var groupName: String?
    /// Device numbers of a character or block device entry (tar).
    public var device: DeviceNumber?
    public var pathEncoding: PathEncoding
    /// A zip member's own comment.
    public var comment: String?
    /// The zip member's sizes and CRC follow its data (general-purpose bit 3); the central directory still has them.
    public var hasDataDescriptor: Bool
    /// Where the member's header starts: a zip local header, a tar header (for `.tar.gz`, an offset in the
    /// decompressed stream). Kept so a later single-member read can go straight there.
    public var headerOffset: Int64
    /// Where a tar member's data starts (same coordinate space as `headerOffset`).
    public var dataOffset: Int64?
    /// The archive ends before this member's data does.
    public var isTruncated: Bool
    /// True for a lone gzip member: ISIZE stores the size modulo 2^32, so a file of 4 GiB or more reads smaller.
    public var uncompressedSizeIsModulo4GiB: Bool

    public init(path: String, type: EntryType, uncompressedSize: Int64? = nil, compressedSize: Int64? = nil,
                method: CompressionMethod? = nil, crc32: UInt32? = nil, modified: ArchiveTimestamp? = nil,
                mode: UInt32? = nil, linkTarget: String? = nil, encryption: Encryption? = nil, uid: Int64? = nil,
                gid: Int64? = nil, userName: String? = nil, groupName: String? = nil, device: DeviceNumber? = nil,
                pathEncoding: PathEncoding = .utf8, comment: String? = nil, hasDataDescriptor: Bool = false,
                headerOffset: Int64 = 0, dataOffset: Int64? = nil, isTruncated: Bool = false,
                uncompressedSizeIsModulo4GiB: Bool = false) {
        self.path = path; self.type = type; self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize; self.method = method; self.crc32 = crc32; self.modified = modified
        self.mode = mode; self.linkTarget = linkTarget; self.encryption = encryption; self.uid = uid; self.gid = gid
        self.userName = userName; self.groupName = groupName; self.device = device; self.pathEncoding = pathEncoding
        self.comment = comment; self.hasDataDescriptor = hasDataDescriptor; self.headerOffset = headerOffset
        self.dataOffset = dataOffset; self.isTruncated = isTruncated
        self.uncompressedSizeIsModulo4GiB = uncompressedSizeIsModulo4GiB
    }

    public var isEncrypted: Bool { encryption != nil }
    public var isDirectory: Bool { type == .directory }
    /// Permission bits only (including setuid, setgid and sticky).
    public var permissions: UInt32? { mode.map { $0 & 0o7777 } }
    public var isSetUID: Bool { (mode ?? 0) & 0o4000 != 0 }
    public var isSetGID: Bool { (mode ?? 0) & 0o2000 != 0 }

    /// Uncompressed over compressed size, when both are known and the compressed size is not zero.
    public var compressionRatio: Double? {
        guard let u = uncompressedSize, let c = compressedSize, c > 0 else { return nil }
        return Double(u) / Double(c)
    }
}

/// What kind of filesystem object a member would become.
public enum EntryType: Sendable, Equatable, Hashable {
    case file, directory, symlink, hardlink, characterDevice, blockDevice, fifo
    /// Anything else (a socket mode, a tar volume label, an unknown type flag); the payload names it.
    case other(String)

    public var name: String {
        switch self {
        case .file: String(localized: "file", bundle: .module, comment: "Kind of an archive member, shown in the archive's list.")
        case .directory: String(localized: "folder", bundle: .module, comment: "Kind of an archive member, shown in the archive's list.")
        case .symlink: String(localized: "symbolic link", bundle: .module, comment: "Kind of an archive member, shown in the archive's list.")
        case .hardlink: String(localized: "hard link", bundle: .module, comment: "Kind of an archive member, shown in the archive's list.")
        case .characterDevice: String(localized: "character device", bundle: .module, comment: "Kind of an archive member, shown in the archive's list.")
        case .blockDevice: String(localized: "block device", bundle: .module, comment: "Kind of an archive member, shown in the archive's list.")
        case .fifo: String(localized: "named pipe", bundle: .module, comment: "Kind of an archive member, shown in the archive's list.")
        case .other(let what): what
        }
    }

    /// `S_IFMT` bits for this type, so tar entries carry the same `mode` shape as zip entries.
    var modeTypeBits: UInt32 {
        switch self {
        case .file, .hardlink, .other: 0o100000
        case .directory: 0o040000
        case .symlink: 0o120000
        case .characterDevice: 0o020000
        case .blockDevice: 0o060000
        case .fifo: 0o010000
        }
    }
}

/// A zip or gzip member's compression method (APPNOTE 4.4.5).
public enum CompressionMethod: Sendable, Equatable, Hashable {
    case stored, shrunk, reduced(factor: Int), imploded, deflate, deflate64, bzip2, lzma, zstd, xz, jpeg, wavpack
    case ppmd
    /// Method 99 without its AES extra field, so the real method is unknown.
    case aesWrapped
    case other(UInt16)

    init(zipCode: UInt16) {
        switch zipCode {
        case 0: self = .stored
        case 1: self = .shrunk
        case 2...5: self = .reduced(factor: Int(zipCode) - 1)
        case 6: self = .imploded
        case 8: self = .deflate
        case 9: self = .deflate64
        case 12: self = .bzip2
        case 14: self = .lzma
        case 93: self = .zstd
        case 95: self = .xz
        case 96: self = .jpeg
        case 97: self = .wavpack
        case 98: self = .ppmd
        case 99: self = .aesWrapped
        default: self = .other(zipCode)
        }
    }

    public var name: String {
        switch self {
        case .stored: String(localized: "Stored", bundle: .module, comment: "Zip compression method of an archive member.")
        case .shrunk: String(localized: "Shrunk", bundle: .module, comment: "Zip compression method of an archive member.")
        case .reduced(let f): String(localized: "Reduced (factor \(f))", bundle: .module, comment: "Zip compression method of an archive member. The argument is the reduction factor, 1 to 4.")
        case .imploded: String(localized: "Imploded", bundle: .module, comment: "Zip compression method of an archive member.")
        case .deflate: "Deflate"
        case .deflate64: "Deflate64"
        case .bzip2: "BZIP2"
        case .lzma: "LZMA"
        case .zstd: "Zstandard"
        case .xz: "XZ"
        case .jpeg: "JPEG"
        case .wavpack: "WavPack"
        case .ppmd: "PPMd"
        case .aesWrapped: String(localized: "AES-wrapped", bundle: .module, comment: "Zip compression method of an archive member.")
        case .other(let code): String(localized: "Method \(code)", bundle: .module, comment: "Zip compression method of an archive member. An unknown method, by its number.")
        }
    }
}

/// How a member is encrypted. Listing never needs the key: names and sizes are in the clear for all of these
/// (except PKWARE central-directory encryption, whose masked names are shown as stored).
public enum Encryption: Sendable, Equatable, Hashable {
    /// PKWARE traditional ("ZipCrypto"); weak.
    case traditional
    /// WinZip AES (extra field 0x9901) with the key length in bits.
    case aes(bits: Int)
    /// PKWARE strong encryption (general-purpose bit 6).
    case strong
    /// Encrypted by the archive format itself, as libarchive reports it (7-Zip and RAR use AES); the payload names
    /// the format.
    case format(String)

    public var name: String {
        switch self {
        case .traditional: "ZipCrypto"
        case .aes(let bits): "AES-\(bits)"
        case .strong: String(localized: "PKWARE strong encryption", bundle: .module, comment: "How an archive member is encrypted.")
        case .format(let format): String(localized: "\(format) encryption", bundle: .module, comment: "How an archive member is encrypted; the argument is a format name like 7-Zip or RAR.")
        }
    }
}

/// When a member was last modified. Zip's DOS fields carry no time zone, so they stay a wall-clock reading until
/// someone picks the zone (Archive Utility and `unzip` use the viewer's); every other source is an instant.
public enum ArchiveTimestamp: Sendable, Equatable {
    case instant(Date)
    case wallClock(DateComponents)

    /// The moment, reading a wall-clock value in `timeZone`.
    public func date(in timeZone: TimeZone = .current) -> Date? {
        switch self {
        case .instant(let date): return date
        case .wallClock(var parts):
            parts.timeZone = timeZone
            return Calendar(identifier: .gregorian).date(from: parts)
        }
    }

    public var isWallClock: Bool { if case .wallClock = self { true } else { false } }
}

public struct DeviceNumber: Sendable, Equatable, Hashable {
    public var major: Int64
    public var minor: Int64
    public init(major: Int64, minor: Int64) { self.major = major; self.minor = minor }
}

/// How a member's stored name bytes became `path`.
public enum PathEncoding: Sendable, Equatable, Hashable {
    /// Declared UTF-8 (zip bit 11, Info-ZIP Unicode path field, pax) or valid UTF-8 from a Unix tool.
    case utf8
    /// Zip's historical default, IBM code page 437.
    case cp437
    /// Tar bytes that are not UTF-8, read as ISO Latin-1 so every byte stays visible.
    case latin1
    /// Declared UTF-8 but invalid; bad sequences became U+FFFD.
    case invalidUTF8
}
