import Foundation

/// ZIP (PKWARE APPNOTE 6.3.10): the listing comes from the end of central directory record and the central
/// directory only, both at the end of the file, so the cost is the directory's size whatever the members weigh.
/// Local headers are read for one purpose: a Unix symlink's target lives in its member data (a few bytes), and the
/// safety report needs to know where links point.
public enum ZipReader {
    static let endSignature: UInt32 = 0x0605_4B50
    static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    static let zip64EndSignature: UInt32 = 0x0606_4B50
    static let centralSignature: UInt32 = 0x0201_4B50
    static let localSignature: UInt32 = 0x0403_4B50
    /// The end record is 22 bytes plus a comment of at most 65,535: the backwards search never looks further.
    static let maxEndSearch = 22 + 0xFFFF

    public static func list(source: any ArchiveByteSource, limits: ArchiveLimits = .default) throws -> ArchiveListing {
        let reader = WindowedReader(source, windowSize: 1024 * 1024)
        let end = try findEnd(reader)
        let directory = try locateDirectory(reader, end: end)

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(min(directory.declaredCount, limits.maxEntries))
        var coverage = ListingCoverage.complete
        var notes: [ListingNote] = []
        if directory.prepended > 0 { notes.append(.prependedData(bytes: directory.prepended)) }

        var position = directory.offset
        let stop = directory.offset + directory.size
        while position < stop {
            if entries.count >= limits.maxEntries {
                coverage = .partial(listed: entries.count, total: directory.declaredCount,
                                    reason: String(localized: "listing stops at \(limits.maxEntries.formatted()) entries", bundle: .module, comment: "Why the archive listing is partial."))
                break
            }
            do {
                let (entry, length) = try parseCentralRecord(reader, at: position, end: stop,
                                                             prepended: directory.prepended, index: entries.count)
                entries.append(entry)
                position += length
            } catch let error as ArchiveError {
                // A record that does not parse ends the listing. With nothing listed the archive is refused;
                // otherwise the members before it are shown and the damage is said.
                guard !entries.isEmpty else { throw error }
                let reason = String(localized: "the central directory is damaged after entry \(entries.count.formatted()): \(error.reason)", bundle: .module, comment: "Why the archive listing is partial. The second argument is the technical reason.")
                coverage = .partial(listed: entries.count, total: directory.declaredCount, reason: reason)
                break
            }
        }
        if coverage.isComplete, entries.count != directory.declaredCount,
           entries.count % 0x10000 != directory.declaredCount % 0x10000 {
            notes.append(.entryCountMismatch(declared: directory.declaredCount, found: entries.count))
        }

        let unread = readSymlinkTargets(&entries, reader: reader, limits: limits)
        if unread > 0 { notes.append(.symlinkTargetsNotRead(count: unread)) }

        let info = ZipInfo(comment: end.comment, isZip64: directory.isZip64, prependedBytes: directory.prepended,
                           declaredEntryCount: directory.declaredCount, centralDirectoryOffset: directory.offset,
                           centralDirectorySize: directory.size)
        return ArchiveListing(format: .zip, fileSize: source.size, entries: entries, coverage: coverage, notes: notes,
                              zip: info)
    }

    // MARK: - End of central directory

    struct EndRecord {
        var offset: Int64
        var disk: UInt16, directoryDisk: UInt16
        var entriesOnDisk: UInt16, totalEntries: UInt16
        var directorySize: UInt32, directoryOffset: UInt32
        var comment: String?
    }

    /// Searches backwards from the end, within the 64 KiB comment bound, for the end record. The last signature
    /// whose comment length reaches exactly to the end of the file wins (a comment can itself contain the
    /// signature bytes); failing that, the last one whose comment fits (bytes appended after the archive).
    static func findEnd(_ reader: WindowedReader) throws -> EndRecord {
        let size = reader.size
        let span = Int(min(size, Int64(maxEndSearch)))
        let tailStart = size - Int64(span)
        let tail = try reader.bytes(at: tailStart, count: span)
        var fallback: Int?
        var index = tail.count - 22
        var exact: Int?
        while index >= 0 {
            if tail.le32(at: index) == endSignature, let commentLength = tail.le16(at: index + 20) {
                let recordEnd = index + 22 + Int(commentLength)
                if recordEnd == tail.count { exact = index; break }
                if recordEnd < tail.count, fallback == nil { fallback = index }
            }
            index -= 1
        }
        guard let found = exact ?? fallback else {
            let head = try reader.bytes(at: 0, count: 4)
            if head.le32(at: 0) == localSignature {
                throw ArchiveError.truncated("the end of central directory record is missing")
            }
            throw ArchiveError.notAnArchive
        }
        var cursor = ByteCursor(tail, at: found + 4, what: "the end of central directory record")
        var record = EndRecord(offset: tailStart + Int64(found), disk: try cursor.u16(), directoryDisk: try cursor.u16(),
                               entriesOnDisk: try cursor.u16(), totalEntries: try cursor.u16(),
                               directorySize: try cursor.u32(), directoryOffset: try cursor.u32())
        let commentLength = Int(try cursor.u16())
        let commentBytes = try cursor.take(commentLength)
        if !commentBytes.isEmpty { record.comment = decodeText(commentBytes, utf8Flag: false, unixHost: true).0 }
        return record
    }

    struct Directory {
        var offset: Int64
        var size: Int64
        var declaredCount: Int
        var prepended: Int64
        var isZip64: Bool
    }

    /// Resolves where the central directory is, through the ZIP64 records when present, and corrects for bytes
    /// prepended to the archive (self-extractors), whose stored offsets do not count the stub.
    static func locateDirectory(_ reader: WindowedReader, end: EndRecord) throws -> Directory {
        var disk = UInt32(end.disk), directoryDisk = UInt32(end.directoryDisk)
        var onDisk = UInt64(end.entriesOnDisk), total = UInt64(end.totalEntries)
        var size = UInt64(end.directorySize), offset = UInt64(end.directoryOffset)
        var structureEnd = end.offset          // where the directory (or the ZIP64 end record) should stop
        var isZip64 = false
        var prepended: Int64 = 0

        let locatorOffset = end.offset - 20
        if locatorOffset >= 0, let locator = try? reader.exactly(20, at: locatorOffset, "the ZIP64 locator"),
           locator.le32(at: 0) == zip64LocatorSignature {
            var cursor = ByteCursor(locator, at: 4, what: "the ZIP64 locator")
            let recordDisk = try cursor.u32()
            let stated = try cursor.u64()
            let diskCount = try cursor.u32()
            guard recordDisk == 0, diskCount <= 1 else {
                throw ArchiveError.unsupported("a split or spanned ZIP64 archive (\(diskCount) disks)")
            }
            guard stated <= UInt64(Int64.max) else {
                throw ArchiveError.malformed("the ZIP64 locator points outside the file")
            }
            // The record normally sits right before the locator; a stub in front shifts it by the stub's length.
            var recordOffset = Int64(stated)
            if try reader.bytes(at: recordOffset, count: 4).le32(at: 0) != zip64EndSignature {
                let adjacent = locatorOffset - 56
                guard adjacent >= 0, try reader.bytes(at: adjacent, count: 4).le32(at: 0) == zip64EndSignature,
                      adjacent > recordOffset else {
                    throw ArchiveError.malformed("the ZIP64 end record is not where its locator says")
                }
                prepended = adjacent - recordOffset
                recordOffset = adjacent
            }
            var record = ByteCursor(try reader.exactly(56, at: recordOffset, "the ZIP64 end record"), at: 4,
                                    what: "the ZIP64 end record")
            _ = try record.u64()                     // size of the record
            _ = try record.u16(); _ = try record.u16()
            disk = try record.u32(); directoryDisk = try record.u32()
            onDisk = try record.u64(); total = try record.u64()
            size = try record.u64(); offset = try record.u64()
            structureEnd = recordOffset
            isZip64 = true
        }

        guard disk == 0, directoryDisk == 0, onDisk == total else {
            // `disk` is the file's own 32-bit value: widened before the +1, so 0xFFFFFFFF reads as damage, not a trap.
            throw ArchiveError.unsupported("a split or spanned zip set (this part is disk \(UInt64(disk) + 1))")
        }
        guard size <= UInt64(reader.size), offset <= UInt64(reader.size), total <= UInt64(Int.max) else {
            throw ArchiveError.malformed("the central directory lies outside the file")
        }
        let statedEnd = Int64(offset) + Int64(size)
        if !isZip64 {
            let gap = structureEnd - statedEnd
            guard gap >= 0 else { throw ArchiveError.malformed("the central directory overlaps its end record") }
            if total > 0, try reader.bytes(at: Int64(offset), count: 4).le32(at: 0) != centralSignature {
                guard gap > 0, try reader.bytes(at: Int64(offset) + gap, count: 4).le32(at: 0) == centralSignature else {
                    throw ArchiveError.malformed("the central directory is not where the end record says")
                }
                prepended = gap
            }
        } else {
            guard statedEnd + prepended <= structureEnd else {
                throw ArchiveError.malformed("the central directory overlaps the ZIP64 end record")
            }
        }
        return Directory(offset: Int64(offset) + prepended, size: Int64(size), declaredCount: Int(total),
                         prepended: prepended, isZip64: isZip64)
    }

    // MARK: - Central directory records

    /// One central directory record at `offset`, and its length.
    static func parseCentralRecord(_ reader: WindowedReader, at offset: Int64, end: Int64, prepended: Int64,
                                   index: Int) throws -> (ArchiveEntry, Int64) {
        let what = "central directory entry \(index + 1)"
        guard offset + 46 <= end else { throw ArchiveError.malformed("\(what) runs past the directory") }
        var c = ByteCursor(try reader.exactly(46, at: offset, what), what: what)
        guard try c.u32() == centralSignature else { throw ArchiveError.malformed("\(what) has a bad signature") }
        let madeBy = try c.u16()
        _ = try c.u16()                                         // version needed
        let flags = try c.u16()
        let methodCode = try c.u16()
        let dosTime = try c.u16(), dosDate = try c.u16()
        let crc = try c.u32()
        let compressed32 = try c.u32(), uncompressed32 = try c.u32()
        let nameLength = Int(try c.u16()), extraLength = Int(try c.u16()), commentLength = Int(try c.u16())
        let diskStart = try c.u16()
        _ = try c.u16()                                         // internal attributes
        let external = try c.u32()
        let localOffset32 = try c.u32()

        let variable = nameLength + extraLength + commentLength
        let length = Int64(46 + variable)
        guard offset + length <= end else { throw ArchiveError.malformed("\(what) runs past the directory") }
        var v = ByteCursor(try reader.exactly(variable, at: offset + 46, what), what: what)
        let nameBytes = try v.take(nameLength)
        let extra = try v.take(extraLength)
        let commentBytes = try v.take(commentLength)

        let extras = try ZipExtras(extra, needUncompressed: uncompressed32 == 0xFFFF_FFFF,
                                   needCompressed: compressed32 == 0xFFFF_FFFF, needOffset: localOffset32 == 0xFFFF_FFFF,
                                   needDisk: diskStart == 0xFFFF, what: what)
        let uncompressed = extras.uncompressedSize ?? UInt64(uncompressed32)
        let compressed = extras.compressedSize ?? UInt64(compressed32)
        let localOffset = extras.localHeaderOffset ?? UInt64(localOffset32)
        guard uncompressed <= UInt64(Int64.max), compressed <= UInt64(Int64.max),
              localOffset <= UInt64(Int64.max - prepended) else {
            throw ArchiveError.malformed("\(what) has sizes beyond any file")
        }

        let host = madeBy >> 8
        let unixHost = host == 3 || host == 19                  // Unix, OS X (Darwin)
        var path: String
        var encoding: PathEncoding
        if let unicode = extras.unicodePath, unicode.nameCRC == CRC32.checksum(nameBytes),
           let s = TextDecoding.strictUTF8(unicode.name) {
            (path, encoding) = (s, .utf8)
        } else {
            (path, encoding) = decodeText(nameBytes, utf8Flag: flags & 0x0800 != 0, unixHost: unixHost)
        }

        let unixMode = unixHost ? external >> 16 : 0
        var type: EntryType
        switch unixMode & 0o170000 {
        case 0o040000: type = .directory
        case 0o120000: type = .symlink
        case 0o020000: type = .characterDevice
        case 0o060000: type = .blockDevice
        case 0o010000: type = .fifo
        case 0o140000: type = .other(String(localized: "socket", bundle: .module, comment: "Kind of an archive member, shown in the archive's list."))
        default: type = .file
        }
        if type == .file, path.hasSuffix("/") || (!unixHost && external & 0x10 != 0) { type = .directory }

        var encryption: Encryption?
        if let aes = extras.aes {
            encryption = .aes(bits: aes.bits)
        } else if flags & 0x0001 != 0 {
            encryption = flags & 0x0040 != 0 ? .strong : .traditional
        }
        let method = extras.aes.map { CompressionMethod(zipCode: $0.method) } ?? CompressionMethod(zipCode: methodCode)

        var entry = ArchiveEntry(
            path: path, type: type, uncompressedSize: Int64(uncompressed), compressedSize: Int64(compressed),
            method: method, crc32: crc, modified: extras.modified ?? dosTimestamp(date: dosDate, time: dosTime),
            mode: unixMode == 0 ? nil : unixMode, encryption: encryption, uid: extras.uid, gid: extras.gid,
            pathEncoding: encoding, hasDataDescriptor: flags & 0x0008 != 0,
            headerOffset: Int64(localOffset) + prepended)
        if !commentBytes.isEmpty {
            entry.comment = decodeText(commentBytes, utf8Flag: flags & 0x0800 != 0, unixHost: unixHost).0
        }
        return (entry, length)
    }

    /// Zip names and comments: declared UTF-8 (bit 11); plain ASCII; undeclared but valid UTF-8 from a Unix or
    /// macOS writer (Archive Utility and `ditto` write UTF-8 without setting the bit); else code page 437.
    static func decodeText(_ bytes: [UInt8], utf8Flag: Bool, unixHost: Bool) -> (String, PathEncoding) {
        if utf8Flag {
            if let s = TextDecoding.strictUTF8(bytes) { return (s, .utf8) }
            return (String(decoding: bytes, as: UTF8.self), .invalidUTF8)
        }
        if TextDecoding.isASCII(bytes) { return (String(decoding: bytes, as: UTF8.self), .utf8) }
        if unixHost, let s = TextDecoding.strictUTF8(bytes) { return (s, .utf8) }
        return (TextDecoding.cp437(bytes), .cp437)
    }

    /// MS-DOS date and time: local wall-clock time, two-second resolution, no zone. Nil when zero or impossible.
    static func dosTimestamp(date: UInt16, time: UInt16) -> ArchiveTimestamp? {
        guard date != 0 else { return nil }
        let day = Int(date & 0x1F), month = Int((date >> 5) & 0x0F), year = Int(date >> 9) + 1980
        let second = Int(time & 0x1F) * 2, minute = Int((time >> 5) & 0x3F), hour = Int(time >> 11)
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        return .wallClock(DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }

    // MARK: - Symlink targets

    /// Reads the targets of stored or deflated Unix symlinks, within the limits. Returns how many were left unread.
    static func readSymlinkTargets(_ entries: inout [ArchiveEntry], reader: WindowedReader, limits: ArchiveLimits) -> Int {
        var read = 0, unread = 0
        for i in entries.indices where entries[i].type == .symlink && entries[i].linkTarget == nil {
            guard read < limits.maxSymlinkTargets, !entries[i].isEncrypted,
                  let target = try? symlinkTarget(entries[i], reader: reader, limit: limits.maxSymlinkTargetBytes)
            else { unread += 1; continue }
            entries[i].linkTarget = target
            read += 1
        }
        return unread
    }

    private static func symlinkTarget(_ entry: ArchiveEntry, reader: WindowedReader, limit: Int) throws -> String? {
        guard let compressed = entry.compressedSize, let uncompressed = entry.uncompressedSize,
              compressed <= Int64(limit), uncompressed <= Int64(limit) else { return nil }
        let header = try reader.exactly(30, at: entry.headerOffset, "a local header")
        guard header.le32(at: 0) == localSignature, let n = header.le16(at: 26), let m = header.le16(at: 28) else {
            return nil
        }
        let dataOffset = entry.headerOffset + 30 + Int64(n) + Int64(m)
        let data = try reader.exactly(Int(compressed), at: dataOffset, "a symbolic link's target")
        let bytes: [UInt8]
        switch entry.method {
        case .stored: bytes = data
        case .deflate:
            if uncompressed == 0 { bytes = [] } else {
                guard let inflated = RawInflater.inflate(data, limit: limit) else { return nil }
                bytes = inflated
            }
        default: return nil
        }
        return TextDecoding.utf8OrLatin1(bytes).0
    }
}

/// The central directory extra fields this reader understands (APPNOTE 4.5, Info-ZIP extra.fld).
struct ZipExtras {
    var uncompressedSize: UInt64?
    var compressedSize: UInt64?
    var localHeaderOffset: UInt64?
    var unicodePath: (nameCRC: UInt32, name: [UInt8])?
    var modified: ArchiveTimestamp?
    var aes: (bits: Int, method: UInt16)?
    var uid: Int64?
    var gid: Int64?

    /// The ZIP64 field (0x0001) holds, in order, only the values whose 32-bit fields are saturated; a saturated
    /// value with no ZIP64 field is damage. Other fields are best effort: a malformed one is ignored, as unzip does.
    init(_ bytes: [UInt8], needUncompressed: Bool, needCompressed: Bool, needOffset: Bool, needDisk: Bool,
         what: String) throws {
        var cursor = ByteCursor(bytes, what: "the extra field of \(what)")
        var sawZip64 = false
        var unixTime: Date?, ntfsTime: Date?, oldUnixTime: Date?
        while cursor.remaining >= 4 {
            let id = try cursor.u16()
            let length = Int(try cursor.u16())
            guard cursor.remaining >= length else { break }
            var field = ByteCursor(try cursor.take(length), what: "the extra field of \(what)")
            switch id {
            case 0x0001:
                sawZip64 = true
                if needUncompressed { uncompressedSize = try field.u64() }
                if needCompressed { compressedSize = try field.u64() }
                if needOffset { localHeaderOffset = try field.u64() }
                if needDisk, try field.u32() != 0 {
                    throw ArchiveError.unsupported("a split or spanned zip set")
                }
            case 0x5455:                                     // extended timestamp: flags, then mtime if bit 0
                if let flags = try? field.u8(), flags & 1 != 0, let t = try? field.u32() {
                    unixTime = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: t)))
                }
            case 0x5855:                                     // old Info-ZIP Unix: atime, mtime
                if (try? field.u32()) != nil, let t = try? field.u32() {
                    oldUnixTime = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: t)))
                }
            case 0x000A:                                     // NTFS: reserved, then tag 1 = mtime, atime, ctime
                _ = try? field.u32()
                while field.remaining >= 4, let tag = try? field.u16(), let size = try? field.u16() {
                    if tag == 1, size >= 8, let ticks = try? field.u64() {
                        // 100 ns ticks since 1601-01-01 UTC.
                        ntfsTime = Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
                        break
                    }
                    guard (try? field.skip(Int(size))) != nil else { break }
                }
            case 0x7075:                                     // Info-ZIP Unicode path
                if let version = try? field.u8(), version == 1, let crc = try? field.u32() {
                    unicodePath = (crc, (try? field.take(field.remaining)) ?? [])
                }
            case 0x7875:                                     // Info-ZIP Unix uid/gid, variable width
                if (try? field.u8()) == 1, let uidSize = try? field.u8(), let u = try? field.uint(width: Int(uidSize)),
                   let gidSize = try? field.u8(), let g = try? field.uint(width: Int(gidSize)) {
                    uid = Int64(truncatingIfNeeded: u); gid = Int64(truncatingIfNeeded: g)
                }
            case 0x9901:                                     // WinZip AES
                if (try? field.u16()) != nil, (try? field.take(2)) == Array("AE".utf8), let strength = try? field.u8(),
                   let method = try? field.u16() {
                    let bits = strength == 1 ? 128 : strength == 2 ? 192 : strength == 3 ? 256 : 0
                    aes = (bits, method)
                }
            default:
                break
            }
        }
        if (needUncompressed || needCompressed || needOffset), !sawZip64 {
            throw ArchiveError.malformed("\(what) needs a ZIP64 field it does not have")
        }
        modified = (unixTime ?? oldUnixTime ?? ntfsTime).map(ArchiveTimestamp.instant)
    }
}
