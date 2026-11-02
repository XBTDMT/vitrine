import Foundation

/// What an archive holds, read from its directory or headers only. The preview's outline, summary and safety
/// badges are all derived from this one value; it is plain data, so it can be cached and sent to the CLI or MCP.
public struct ArchiveListing: Sendable, Equatable {
    public var format: Format
    /// The archive file's length in bytes (the compressed length, for gzip).
    public var fileSize: Int64
    public var entries: [ArchiveEntry]
    /// Whether `entries` is every member. A partial listing always says why on screen.
    public var coverage: ListingCoverage
    public var notes: [ListingNote]
    public var zip: ZipInfo?
    public var tar: TarInfo?
    public var gzip: GzipInfo?

    public init(format: Format, fileSize: Int64, entries: [ArchiveEntry], coverage: ListingCoverage = .complete,
                notes: [ListingNote] = [], zip: ZipInfo? = nil, tar: TarInfo? = nil, gzip: GzipInfo? = nil) {
        self.format = format; self.fileSize = fileSize; self.entries = entries; self.coverage = coverage
        self.notes = notes; self.zip = zip; self.tar = tar; self.gzip = gzip
    }

    public enum Format: Sendable, Equatable {
        case zip
        case tar(TarFormat)
        /// A gzip file whose content is not a tar: one member, described by its header and trailer.
        case gzip
        /// A gzip-compressed tar (`.tar.gz`, `.tgz`).
        case tarGzip(TarFormat)
        /// Read by the system libarchive (G-15): RAR, 7z, xz/zstd/lz4/lzma/bzip2/compress streams and tars, ISO 9660,
        /// cpio, RPM, ar (DEB), XAR, CAB, LHA.
        case libarchive(LibarchiveFormat)
        /// Files a manifest names with no archive around them (a torrent's), so the outline, summary and safety scan
        /// read them like members; there is no member data to read. The payload names the manifest.
        case fileList(String)

        public var name: String {
            switch self {
            case .zip: String(localized: "ZIP archive", bundle: .module, comment: "Archive format name shown in the archive preview.")
            case .tar(let f): String(localized: "Tar archive (\(f.name))", bundle: .module, comment: "Archive format name shown in the archive preview. The argument is the tar dialect: ustar, GNU or pax.")
            case .gzip: String(localized: "Gzip file", bundle: .module, comment: "Archive format name shown in the archive preview.")
            case .tarGzip(let f): String(localized: "Gzip-compressed tar (\(f.name))", bundle: .module, comment: "Archive format name shown in the archive preview. The argument is the tar dialect: ustar, GNU or pax.")
            case .libarchive(let f): f.name
            case .fileList(let what): what
            }
        }

        /// Whether the archive stores its members compressed, so its own size against the unpacked total is a ratio
        /// worth judging (a plain tar, cpio, ar or ISO only stores them).
        public var isCompressed: Bool {
            switch self {
            case .zip, .gzip, .tarGzip: true
            case .tar, .fileList: false
            case .libarchive(let f): f.isCompressed
            }
        }
    }
}

/// A container read by the system libarchive (G-15), and the compression filters wrapped around it. roadmap: S-8
public struct LibarchiveFormat: Sendable, Equatable {
    public enum Container: String, Sendable, Equatable {
        case rar, rar5, sevenZip, iso9660, cpio, ar, xar, cab, lha, tar, zip
        /// No container: one compressed stream (`notes.txt.xz`), listed as one member.
        case raw
        case other
    }

    public var container: Container
    /// libarchive's own name for what it read ("RAR5", "7-Zip", "ISO9660 with Rockridge extensions").
    public var formatName: String
    /// Stream compression around the container, outermost first, in libarchive's names ("rpm", "xz", "zstd").
    public var filters: [String]
    /// RAR's solid flag from its main header: every member is compressed as one stream, so reaching a name means
    /// decompressing all before it. Nil when the format has no such flag or the header could not be read.
    public var isSolid: Bool?
    /// The members of an ar archive are a Debian package's (`debian-binary` first).
    public var isDebianPackage: Bool

    public init(container: Container, formatName: String, filters: [String] = [], isSolid: Bool? = nil,
                isDebianPackage: Bool = false) {
        self.container = container; self.formatName = formatName; self.filters = filters; self.isSolid = isSolid
        self.isDebianPackage = isDebianPackage
    }

    /// The filters that compress (RPM's header wrapper does not).
    public var compressionFilters: [String] { filters.filter { $0 != "rpm" } }

    public var isCompressed: Bool {
        switch container {
        case .rar, .rar5, .sevenZip, .cab, .lha, .xar, .zip: true
        case .iso9660, .cpio, .ar, .tar, .raw, .other: !compressionFilters.isEmpty
        }
    }

    /// A filter as people write it: "zstd" → "Zstandard", "lz4" → "LZ4".
    public static func filterName(_ filter: String) -> String {
        switch filter {
        case "zstd": "Zstandard"
        case "lz4": "LZ4"
        case "lzma": "LZMA"
        default: filter
        }
    }

    public var name: String {
        let compression = compressionFilters.map(Self.filterName).joined(separator: ", ")
        let plain = compression.isEmpty
        switch container {
        case .rar: return isSolid == true ? String(localized: "RAR archive (solid)", bundle: .module, comment: "Archive format name shown in the archive preview.") : String(localized: "RAR archive", bundle: .module, comment: "Archive format name shown in the archive preview.")
        case .rar5: return isSolid == true ? String(localized: "RAR 5 archive (solid)", bundle: .module, comment: "Archive format name shown in the archive preview.") : String(localized: "RAR 5 archive", bundle: .module, comment: "Archive format name shown in the archive preview.")
        case .sevenZip: return String(localized: "7-Zip archive", bundle: .module, comment: "Archive format name shown in the archive preview.")
        case .iso9660: return String(localized: "ISO 9660 disc image", bundle: .module, comment: "Archive format name shown in the archive preview.")
        case .cpio where filters.contains("rpm"):
            return plain ? String(localized: "RPM package", bundle: .module, comment: "Archive format name shown in the archive preview.") : String(localized: "RPM package (\(compression))", bundle: .module, comment: "Archive format name shown in the archive preview. The argument names the compression, like xz or Zstandard.")
        case .cpio: return plain ? String(localized: "cpio archive", bundle: .module, comment: "Archive format name shown in the archive preview.") : String(localized: "cpio archive (\(compression))", bundle: .module, comment: "Archive format name shown in the archive preview. The argument names the compression, like xz or Zstandard.")
        case .ar where isDebianPackage: return String(localized: "Debian package", bundle: .module, comment: "Archive format name shown in the archive preview.")
        case .ar: return plain ? String(localized: "ar archive", bundle: .module, comment: "Archive format name shown in the archive preview.") : String(localized: "ar archive (\(compression))", bundle: .module, comment: "Archive format name shown in the archive preview. The argument names the compression, like xz or Zstandard.")
        case .xar: return String(localized: "XAR archive", bundle: .module, comment: "Archive format name shown in the archive preview.")
        case .cab: return String(localized: "Cabinet archive", bundle: .module, comment: "Archive format name shown in the archive preview.")
        case .lha: return String(localized: "LHA archive", bundle: .module, comment: "Archive format name shown in the archive preview.")
        case .tar: return plain ? String(localized: "Tar archive", bundle: .module, comment: "Archive format name shown in the archive preview.") : String(localized: "Tar archive (\(compression))", bundle: .module, comment: "Archive format name shown in the archive preview. The argument names the compression, like xz or Zstandard.")
        case .zip: return String(localized: "ZIP archive", bundle: .module, comment: "Archive format name shown in the archive preview.")
        case .raw: return plain ? String(localized: "Compressed file", bundle: .module, comment: "Archive format name shown in the archive preview.") : String(localized: "\(compression)-compressed file", bundle: .module, comment: "Archive format name shown in the archive preview. The argument names the compression, like xz or Zstandard.")
        case .other: return plain ? formatName : formatName + " (\(compression))"   // libarchive's own name, as data
        }
    }
}

/// Which tar dialect the headers use. A pax archive is ustar plus extended headers; GNU uses its own magic and
/// `././@LongLink` members for long names.
public enum TarFormat: Sendable, Equatable {
    case v7, ustar, gnu, pax

    public var name: String {
        switch self {
        case .v7: "V7"
        case .ustar: "ustar"
        case .gnu: "GNU"
        case .pax: "pax"
        }
    }
}

/// Whether a listing names every member.
public enum ListingCoverage: Sendable, Equatable {
    case complete
    /// `listed` members are shown of `total` (nil when the format cannot know the total without reading on).
    case partial(listed: Int, total: Int?, reason: String)

    public var isComplete: Bool { self == .complete }
}

/// Facts about the listing worth a line on screen. They never stop a listing; errors do that.
public enum ListingNote: Sendable, Equatable {
    /// Bytes before the zip's first record (a self-extractor stub); offsets were corrected for them.
    case prependedData(bytes: Int64)
    /// The zip's end record declares a different member count than its directory holds.
    case entryCountMismatch(declared: Int, found: Int)
    /// The tar has no end-of-archive marker: it was cut off at a header boundary or written by a tool that omits it.
    case missingEndMarker
    /// The tar ended with one zero block instead of two.
    case singleZeroBlockEnd
    /// The tar ends inside a member's data.
    case truncatedEntry(path: String)
    /// Bytes after the end of the archive (zero padding is not reported).
    case trailingData(bytes: Int64)
    /// A gzip ISIZE trailer records size modulo 2^32, and only for the last member of a multi-member file.
    case gzipSizeIsModulo4GiB
    /// While reading a `.tar.gz`, more than one gzip member was found (concatenated gzip files).
    case gzipMembers(count: Int)
    /// Zip symlink targets live in member data; these were not read (encrypted, compressed oddly, or over the cap).
    case symlinkTargetsNotRead(count: Int)
    /// The member names themselves are encrypted (7z `-mhe`, RAR `-hp`): nothing can be listed without the password.
    case encryptedHeaders
    /// A problem libarchive reported while reading a header and read past (a name it could not convert, a damaged
    /// optional field).
    case readWarning(String)

    public var message: String {
        switch self {
        case .prependedData(let n): String(localized: "\(n.formatted()) bytes precede the archive (a self-extractor stub).", bundle: .module, comment: "A note under the archive listing.")
        case .entryCountMismatch(let d, let f): String(localized: "The end record declares \(d.formatted()) entries; the directory holds \(f.formatted()).", bundle: .module, comment: "A note under the archive listing.")
        case .missingEndMarker: String(localized: "The archive has no end-of-archive marker.", bundle: .module, comment: "A note under the archive listing.")
        case .singleZeroBlockEnd: String(localized: "The archive ends with one zero block instead of two.", bundle: .module, comment: "A note under the archive listing.")
        case .truncatedEntry(let p): String(localized: "The archive ends inside the data of “\(p)”.", bundle: .module, comment: "A note under the archive listing. The argument is a member's path.")
        case .trailingData(let n): String(localized: "\(n.formatted()) bytes follow the end of the archive.", bundle: .module, comment: "A note under the archive listing.")
        case .gzipSizeIsModulo4GiB:
            String(localized: "The uncompressed size comes from the gzip trailer: it is modulo 4 GiB and covers only the last member.", bundle: .module, comment: "A note under the archive listing.")
        case .gzipMembers(let n): String(localized: "The file holds \(n.formatted()) concatenated gzip members.", bundle: .module, comment: "A note under the archive listing.")
        case .symlinkTargetsNotRead(let n): String(localized: "\(n.formatted()) symbolic link targets were not read.", bundle: .module, comment: "A note under the archive listing.")
        case .encryptedHeaders: String(localized: "The names inside are encrypted; listing them needs the password.", bundle: .module, comment: "A note under the archive listing.")
        case .readWarning(let why): String(localized: "While reading: \(why).", bundle: .module, comment: "A note under the archive listing. The argument is libarchive's own message, in English.")
        }
    }
}

/// Zip-level facts from the end of central directory record.
public struct ZipInfo: Sendable, Equatable {
    public var comment: String?
    public var isZip64: Bool
    /// Bytes before the archive proper (self-extractor stubs); offsets in entries already include them.
    public var prependedBytes: Int64
    /// What the end record says, which can differ from `entries.count` (16-bit wrap, damage).
    public var declaredEntryCount: Int
    public var centralDirectoryOffset: Int64
    public var centralDirectorySize: Int64

    public init(comment: String?, isZip64: Bool, prependedBytes: Int64, declaredEntryCount: Int,
                centralDirectoryOffset: Int64, centralDirectorySize: Int64) {
        self.comment = comment; self.isZip64 = isZip64; self.prependedBytes = prependedBytes
        self.declaredEntryCount = declaredEntryCount; self.centralDirectoryOffset = centralDirectoryOffset
        self.centralDirectorySize = centralDirectorySize
    }
}

/// Tar-level facts.
public struct TarInfo: Sendable, Equatable {
    public var format: TarFormat
    public var endMarker: EndMarker
    /// pax global (`g`) header records, last value per key.
    public var globalAttributes: [String: String]
    /// Tar bytes walked (for `.tar.gz`, decompressed bytes examined).
    public var bytesExamined: Int64

    public enum EndMarker: Sendable, Equatable { case twoZeroBlocks, oneZeroBlock, none }

    public init(format: TarFormat, endMarker: EndMarker, globalAttributes: [String: String], bytesExamined: Int64) {
        self.format = format; self.endMarker = endMarker; self.globalAttributes = globalAttributes
        self.bytesExamined = bytesExamined
    }
}

/// The first gzip member's header (RFC 1952) and the file's trailer.
public struct GzipInfo: Sendable, Equatable {
    /// FNAME: the name of the file that was compressed (ISO Latin-1 per the RFC).
    public var originalName: String?
    public var comment: String?
    /// MTIME, nil when zero ("no time stamp").
    public var modified: Date?
    public var operatingSystem: String
    /// XFL: 2 = maximum compression, 4 = fastest, else nil.
    public var compressionHint: String?
    /// FEXTRA subfield ids (two ASCII bytes each, e.g. "AP"), in order.
    public var extraSubfieldIDs: [String]
    public var hasHeaderCRC: Bool
    /// The header's length, where the deflate stream starts.
    public var headerLength: Int
    /// CRC32 and ISIZE from the last 8 bytes of the file.
    public var trailerCRC32: UInt32
    public var trailerSize: UInt32

    public init(originalName: String?, comment: String?, modified: Date?, operatingSystem: String,
                compressionHint: String?, extraSubfieldIDs: [String], hasHeaderCRC: Bool, headerLength: Int,
                trailerCRC32: UInt32, trailerSize: UInt32) {
        self.originalName = originalName; self.comment = comment; self.modified = modified
        self.operatingSystem = operatingSystem; self.compressionHint = compressionHint
        self.extraSubfieldIDs = extraSubfieldIDs; self.hasHeaderCRC = hasHeaderCRC; self.headerLength = headerLength
        self.trailerCRC32 = trailerCRC32; self.trailerSize = trailerSize
    }
}

/// Caps that keep a listing inside the preview budget (ARCHITECTURE §7) whatever the archive claims.
public struct ArchiveLimits: Sendable, Equatable {
    /// Members listed before the listing stops and reports partial coverage.
    public var maxEntries: Int
    /// Decompressed bytes a `.tar.gz` walk may examine; tar data inside gzip can only be skipped by inflating it.
    public var maxDecompressedBytes: Int64
    /// The largest tar metadata record (GNU long name, pax header) read into memory.
    public var maxMetadataRecordBytes: Int
    /// Zip symlink targets read from member data (each at most `maxSymlinkTargetBytes`).
    public var maxSymlinkTargets: Int
    public var maxSymlinkTargetBytes: Int
    /// Seconds a libarchive listing or member read may take before it stops and says how far it got. Walking a
    /// solid RAR or a compressed tar decompresses everything before each name, so time runs out before entries do.
    public var timeBudget: TimeInterval
    /// The largest member opened as a nested archive (`VitrineArchive.openNested`): it is read into memory whole.
    public var maxNestedArchiveBytes: Int

    public init(maxEntries: Int = 200_000, maxDecompressedBytes: Int64 = 256 * 1024 * 1024,
                maxMetadataRecordBytes: Int = 1024 * 1024, maxSymlinkTargets: Int = 1_000,
                maxSymlinkTargetBytes: Int = 4_096, timeBudget: TimeInterval = 5,
                maxNestedArchiveBytes: Int = 64 * 1024 * 1024) {
        self.maxEntries = max(1, maxEntries); self.maxDecompressedBytes = max(1024, maxDecompressedBytes)
        self.maxMetadataRecordBytes = max(512, maxMetadataRecordBytes)
        self.maxSymlinkTargets = max(0, maxSymlinkTargets); self.maxSymlinkTargetBytes = max(1, maxSymlinkTargetBytes)
        self.timeBudget = max(0.05, timeBudget); self.maxNestedArchiveBytes = max(0, maxNestedArchiveBytes)
    }

    public static let `default` = ArchiveLimits()
}
