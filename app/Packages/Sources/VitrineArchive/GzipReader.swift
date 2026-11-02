import Foundation

/// Gzip (RFC 1952): the header and trailer describe a single compressed file. When the content is a tar, the tar
/// inside is listed by inflating only as far as its headers need, under `ArchiveLimits.maxDecompressedBytes`.
public enum GzipReader {
    static let magic: [UInt8] = [0x1F, 0x8B]
    /// The longest FNAME or FCOMMENT read; the RFC sets no bound, a preview must.
    static let maxHeaderString = 64 * 1024

    struct Header {
        var originalName: String?
        var comment: String?
        var modified: Date?
        var operatingSystem: String
        var compressionHint: String?
        var extraSubfieldIDs: [String]
        var hasHeaderCRC: Bool
        var headerLength: Int
    }

    /// Lists a gzip file. `fileName` (the file's own name) is the fallback member name and a tar hint.
    public static func list(source: any ArchiveByteSource, fileName: String? = nil,
                            limits: ArchiveLimits = .default) throws -> ArchiveListing {
        let reader = WindowedReader(source, windowSize: 16 * 1024)
        let header = try parseHeader(reader, at: 0)
        guard source.size >= Int64(header.headerLength) + 8 else {
            throw ArchiveError.truncated("the file ends before the gzip trailer")
        }
        var trailer = ByteCursor(try reader.exactly(8, at: source.size - 8, "the gzip trailer"), what: "the trailer")
        let trailerCRC = try trailer.u32()
        let isize = try trailer.u32()
        let info = GzipInfo(originalName: header.originalName, comment: header.comment, modified: header.modified,
                            operatingSystem: header.operatingSystem, compressionHint: header.compressionHint,
                            extraSubfieldIDs: header.extraSubfieldIDs, hasHeaderCRC: header.hasHeaderCRC,
                            headerLength: header.headerLength, trailerCRC32: trailerCRC, trailerSize: isize)

        if try containsTar(source: source, header: header, fileName: fileName) {
            let stream = try GzipForwardReader(source: source, start: Int64(header.headerLength),
                                               cap: limits.maxDecompressedBytes)
            var listing = try TarReader.walk(stream, fileSize: source.size, limits: limits, compressed: true)
            listing.gzip = info
            if stream.memberCount > 1 { listing.notes.append(.gzipMembers(count: stream.memberCount)) }
            if stream.trailingCompressedBytes > 0 {
                listing.notes.append(.trailingData(bytes: stream.trailingCompressedBytes))
            }
            return listing
        }

        let name = header.originalName.flatMap { $0.isEmpty ? nil : $0 } ?? strippedName(fileName) ?? "data"
        let entry = ArchiveEntry(
            path: name, type: .file, uncompressedSize: Int64(isize),
            compressedSize: source.size - Int64(header.headerLength) - 8, method: .deflate, crc32: trailerCRC,
            modified: header.modified.map(ArchiveTimestamp.instant), pathEncoding: .latin1,
            headerOffset: 0, dataOffset: Int64(header.headerLength), uncompressedSizeIsModulo4GiB: true)
        return ArchiveListing(format: .gzip, fileSize: source.size, entries: [entry],
                              notes: [.gzipSizeIsModulo4GiB], gzip: info)
    }

    /// `report.txt.gz` → `report.txt`; `bundle.tgz` → `bundle.tar`.
    static func strippedName(_ fileName: String?) -> String? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let lower = fileName.lowercased()
        if lower.hasSuffix(".tgz") { return String(fileName.dropLast(4)) + ".tar" }
        for ext in [".gz", ".gzip", ".z"] where lower.hasSuffix(ext) { return String(fileName.dropLast(ext.count)) }
        return fileName
    }

    /// Whether the decompressed content is a tar: the first 512 bytes form a valid tar header (or are a zero
    /// block, for an empty tar whose names say tar). Inflates one block, nothing more.
    static func containsTar(source: any ArchiveByteSource, header: Header, fileName: String?) throws -> Bool {
        let probe = try GzipForwardReader(source: source, start: Int64(header.headerLength), cap: 4096)
        let block: [UInt8]
        do { block = try probe.read(512) } catch { return false }
        guard block.count == 512 else { return false }
        if TarReader.isValidHeader(block) { return true }
        guard block.allSatisfy({ $0 == 0 }) else { return false }
        let names = [header.originalName, fileName].compactMap { $0?.lowercased() }
        return names.contains { $0.hasSuffix(".tar") || $0.hasSuffix(".tgz") || $0.hasSuffix(".tar.gz") }
    }

    /// Parses a gzip member header at `offset`.
    static func parseHeader(_ reader: WindowedReader, at offset: Int64) throws -> Header {
        var fixed = ByteCursor(try reader.exactly(10, at: offset, "the gzip header"), what: "the gzip header")
        let id1 = try fixed.u8(), id2 = try fixed.u8()
        guard id1 == 0x1F, id2 == 0x8B else { throw ArchiveError.notAnArchive }
        let method = try fixed.u8()
        guard method == 8 else { throw ArchiveError.unsupported("gzip compression method \(method) is not deflate") }
        let flags = try fixed.u8()
        guard flags & 0xE0 == 0 else { throw ArchiveError.malformed("the gzip header sets reserved flags") }
        let mtime = try fixed.u32()
        let xfl = try fixed.u8()
        let os = try fixed.u8()
        var position = offset + 10
        var subfields: [String] = []

        if flags & 0x04 != 0 {                                     // FEXTRA
            var lenCursor = ByteCursor(try reader.exactly(2, at: position, "the gzip extra field"), what: "FEXTRA")
            let xlen = Int(try lenCursor.u16())
            let extra = try reader.exactly(xlen, at: position + 2, "the gzip extra field")
            position += 2 + Int64(xlen)
            var cursor = ByteCursor(extra, what: "the gzip extra field")
            while cursor.remaining >= 4 {
                let si = try cursor.take(2)
                let len = Int(try cursor.u16())
                guard cursor.remaining >= len else { break }
                try cursor.skip(len)
                subfields.append(TextDecoding.latin1(si))
            }
        }
        var name: String?
        if flags & 0x08 != 0 {                                     // FNAME
            let (bytes, next) = try zeroTerminated(reader, at: position, what: "the original file name")
            name = TextDecoding.latin1(bytes)
            position = next
        }
        var comment: String?
        if flags & 0x10 != 0 {                                     // FCOMMENT
            let (bytes, next) = try zeroTerminated(reader, at: position, what: "the gzip comment")
            comment = TextDecoding.latin1(bytes)
            position = next
        }
        let hasCRC = flags & 0x02 != 0
        if hasCRC {                                                // FHCRC
            _ = try reader.exactly(2, at: position, "the gzip header CRC")
            position += 2
        }
        return Header(originalName: name, comment: comment,
                      modified: mtime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(mtime)),
                      operatingSystem: operatingSystemName(os),
                      compressionHint: xfl == 2 ? String(localized: "maximum compression", bundle: .module, comment: "Gzip header detail shown in the archive preview. The compressor's setting.")
                          : xfl == 4 ? String(localized: "fastest", bundle: .module, comment: "Gzip header detail shown in the archive preview. The compressor's setting.") : nil,
                      extraSubfieldIDs: subfields, hasHeaderCRC: hasCRC, headerLength: Int(position - offset))
    }

    private static func zeroTerminated(_ reader: WindowedReader, at offset: Int64,
                                       what: String) throws -> ([UInt8], Int64) {
        var collected: [UInt8] = []
        var position = offset
        while collected.count <= maxHeaderString {
            let chunk = try reader.bytes(at: position, count: 4096)
            guard !chunk.isEmpty else { throw ArchiveError.truncated("the file ends inside \(what)") }
            if let zero = chunk.firstIndex(of: 0) {
                collected.append(contentsOf: chunk[..<zero])
                guard collected.count <= maxHeaderString else { break }
                return (collected, position + Int64(zero) + 1)
            }
            collected.append(contentsOf: chunk)
            position += Int64(chunk.count)
        }
        throw ArchiveError.malformed("\(what) is longer than \(maxHeaderString) bytes")
    }

    static func operatingSystemName(_ code: UInt8) -> String {
        switch code {
        case 0: "FAT"
        case 1: "Amiga"
        case 2: "VMS"
        case 3: "Unix"
        case 4: "VM/CMS"
        case 5: "Atari TOS"
        case 6: "HPFS"
        case 7: "Macintosh"
        case 8: "Z-System"
        case 9: "CP/M"
        case 10: "TOPS-20"
        case 11: "NTFS"
        case 12: "QDOS"
        case 13: "Acorn RISCOS"
        case 255: String(localized: "unknown", bundle: .module, comment: "Gzip header detail shown in the archive preview. The operating system that wrote the file is not recorded.")
        default: String(localized: "system \(code)", bundle: .module, comment: "Gzip header detail shown in the archive preview. An operating system by its number in the gzip header.")
        }
    }
}
