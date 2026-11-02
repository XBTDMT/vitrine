import Foundation

/// VitrineArchive: archive and container listings (ARCHITECTURE §3). Zip, tar and gzip are read by our own Swift
/// readers; everything else E-9 names (RAR, 7z, xz/zstd/lz4/lzma/bzip2/compress, ISO 9660, cpio, RPM, DEB, XAR, CAB,
/// LHA) by the system libarchive behind the same listing types (G-15). Readers take only the bytes they need: nothing
/// is written to disk and no member content is ever run or interpreted (ARCHITECTURE §8). roadmap: S-8
public enum VitrineArchive {
    /// The containers the readers recognise by their bytes.
    public enum Container: Sendable, Equatable { case zip, tar, gzip, libarchive }

    /// Lists the archive at `url`. The format comes from the bytes, not the extension; the name only breaks ties
    /// (an empty tar inside gzip) and names a lone gzip member when the header does not.
    public static func list(contentsOf url: URL, limits: ArchiveLimits = .default) throws -> ArchiveListing {
        try list(source: FileByteSource(url: url), fileName: url.lastPathComponent, limits: limits)
    }

    public static func list(source: any ArchiveByteSource, fileName: String? = nil,
                            limits: ArchiveLimits = .default) throws -> ArchiveListing {
        switch try detect(source: source, fileName: fileName) {
        case .zip: return try ZipReader.list(source: source, limits: limits)
        case .tar: return try TarReader.list(source: source, limits: limits)
        case .gzip: return try GzipReader.list(source: source, fileName: fileName, limits: limits)
        case .libarchive: return try LibarchiveReader.list(source: source, fileName: fileName, limits: limits)
        case nil: throw ArchiveError.notAnArchive
        }
    }

    /// Lists an archive held in memory: a member of another archive, an attachment.
    public static func list(bytes: [UInt8], fileName: String? = nil, limits: ArchiveLimits = .default) throws -> ArchiveListing {
        try list(source: DataByteSource(bytes), fileName: fileName, limits: limits)
    }

    /// Recognises a container from its first bytes. Zip is also recognised by its end record alone, which covers
    /// self-extracting archives and zips with a stub in front. Signatures that name a format outright come before
    /// tar's checksummed header; short or distant ones (cpio, LHA, ISO 9660) after it.
    public static func detect(source: any ArchiveByteSource, fileName: String? = nil) throws -> Container? {
        let head = try source.read(at: 0, count: 512)
        if head.count >= 4, head[0] == 0x50, head[1] == 0x4B,
           [[0x03, 0x04], [0x05, 0x06], [0x07, 0x08]].contains(Array(head[2..<4])) {
            return .zip
        }
        if head.count >= 2, head[0] == 0x1F, head[1] == 0x8B { return .gzip }
        if LibarchiveReader.hasStrongSignature(head) { return .libarchive }
        if TarReader.isValidHeader(head) { return .tar }
        if head.count == 512, head.allSatisfy({ $0 == 0 }), source.size % 512 == 0,
           let name = fileName?.lowercased(), name.hasSuffix(".tar") {
            return .tar                                            // an empty tar: only end-of-archive blocks
        }
        if try LibarchiveReader.hasWeakSignature(head, source: source, fileName: fileName) { return .libarchive }
        if (try? ZipReader.findEnd(WindowedReader(source))) != nil { return .zip }
        return nil
    }
}
