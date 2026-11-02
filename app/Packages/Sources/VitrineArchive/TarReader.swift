import Foundation

/// Tar (V7, ustar, GNU, pax). The walk reads each 512-byte header and skips the member's data by its size, so a
/// plain `.tar` costs one window per header and member data is never read. Metadata members (GNU long names and
/// links, pax extended and global headers) are read, under `ArchiveLimits.maxMetadataRecordBytes`, because they
/// carry the next member's real name and size.
public enum TarReader {
    static let blockSize = 512

    public static func list(source: any ArchiveByteSource, limits: ArchiveLimits = .default) throws -> ArchiveListing {
        let reader = FileForwardReader(WindowedReader(source, windowSize: 64 * 1024))
        return try walk(reader, fileSize: source.size, limits: limits, compressed: false)
    }

    /// Whether `block` is a tar header: not all zero, and its checksum matches (unsigned, or the signed sum some
    /// old writers used).
    static func isValidHeader(_ block: [UInt8]) -> Bool {
        guard block.count == blockSize, block.contains(where: { $0 != 0 }) else { return false }
        guard let stored = parseNumber(block[148..<156]) else { return false }
        // The checksum field itself counts as eight spaces.
        var unsigned = 8 * 0x20, signed = 8 * 0x20
        block.withUnsafeBufferPointer { bytes in
            for i in 0..<blockSize where i < 148 || i >= 156 {
                unsigned &+= Int(bytes[i])
                signed &+= Int(Int8(bitPattern: bytes[i]))
            }
        }
        return stored == Int64(unsigned) || stored == Int64(signed)
    }

    // MARK: - The walk

    /// The state a metadata member leaves for the member after it.
    private struct Pending {
        var longName: [UInt8]?
        var longLink: [UInt8]?
        var pax: [String: String] = [:]
    }

    static func walk(_ reader: any ForwardReader, fileSize: Int64, limits: ArchiveLimits,
                     compressed: Bool) throws -> ArchiveListing {
        var entries: [ArchiveEntry] = []
        var notes: [ListingNote] = []
        var coverage = ListingCoverage.complete
        var format: TarFormat?
        var sawPax = false, sawGNU = false, seenHeader = false
        var global: [String: String] = [:]
        var pending = Pending()
        var endMarker = TarInfo.EndMarker.none

        func capReason() -> String {
            let examined = ByteCountFormatter.string(fromByteCount: reader.position, countStyle: .binary)
            return String(localized: "stopped after examining \(examined) of decompressed data", bundle: .module, comment: "Why the archive listing is partial. The argument is a size, like 2 GB.")
        }

        walking: while true {
            if entries.count >= limits.maxEntries {
                coverage = .partial(listed: entries.count, total: nil,
                                    reason: String(localized: "listing stops at \(limits.maxEntries.formatted()) entries", bundle: .module, comment: "Why the archive listing is partial."))
                break
            }
            do {
                let headerOffset = reader.position
                let block = try reader.read(blockSize)
                if block.count < blockSize {
                    if reader.stoppedByCap {
                        coverage = .partial(listed: entries.count, total: nil, reason: capReason())
                    } else if block.isEmpty {
                        guard seenHeader || compressed else { throw ArchiveError.notAnArchive }
                        if seenHeader { notes.append(.missingEndMarker) }
                    } else {
                        guard seenHeader else { throw ArchiveError.truncated("the file ends inside the first header") }
                        coverage = .partial(listed: entries.count, total: nil, reason: String(localized: "the archive ends inside a header", bundle: .module, comment: "Why the archive listing is partial."))
                    }
                    break walking
                }
                if block.allSatisfy({ $0 == 0 }) {
                    let next = try reader.read(blockSize)
                    if next.count == blockSize, next.allSatisfy({ $0 == 0 }) {
                        endMarker = .twoZeroBlocks
                    } else {
                        endMarker = .oneZeroBlock
                        notes.append(.singleZeroBlockEnd)
                        if !next.isEmpty, !next.allSatisfy({ $0 == 0 }) {
                            notes.append(.trailingData(bytes: Int64(next.count)))
                        }
                    }
                    break walking
                }
                guard isValidHeader(block) else {
                    guard seenHeader else { throw ArchiveError.notAnArchive }
                    throw ArchiveError.malformed("the header at offset \(headerOffset) fails its checksum")
                }
                seenHeader = true
                if format == nil { format = magicFormat(block) }
                let flag = block[156]
                guard let headerSize = parseNumber(block[124..<136]), headerSize >= 0 else {
                    throw ArchiveError.malformed("the header at offset \(headerOffset) has an unreadable size")
                }

                switch flag {
                case UInt8(ascii: "L"), UInt8(ascii: "K"):
                    sawGNU = true
                    var value = try readRecord(reader, size: headerSize, limits: limits, what: "a GNU long name")
                    if let zero = value.firstIndex(of: 0) { value.removeSubrange(zero...) }
                    if flag == UInt8(ascii: "L") { pending.longName = value } else { pending.longLink = value }
                    continue walking
                case UInt8(ascii: "x"), UInt8(ascii: "X"):
                    sawPax = true
                    let record = try readRecord(reader, size: headerSize, limits: limits, what: "a pax header")
                    pending.pax.merge(try parsePax(record)) { $1 }
                    continue walking
                case UInt8(ascii: "g"):
                    sawPax = true
                    let record = try readRecord(reader, size: headerSize, limits: limits, what: "a pax global header")
                    for (key, value) in try parsePax(record) {
                        if value.isEmpty { global.removeValue(forKey: key) } else { global[key] = value }
                    }
                    continue walking
                default:
                    break
                }

                var (entry, stored) = try makeEntry(block, flag: flag, headerSize: headerSize, offset: headerOffset,
                                                    pending: pending, global: global)
                pending = Pending()

                // Old GNU sparse members list extra sparse maps in blocks between the header and the data.
                if flag == UInt8(ascii: "S"), block[482] != 0 {
                    var more = true
                    while more {
                        let ext = try reader.read(blockSize)
                        guard ext.count == blockSize else {
                            throw ArchiveError.truncated("the file ends inside a sparse map")
                        }
                        more = ext[504] != 0
                    }
                }
                entry.dataOffset = reader.position

                let unit = Int64(blockSize)
                let padded = stored > Int64.max - unit ? stored : (stored + unit - 1) / unit * unit
                let skipped = try reader.skip(padded)
                if skipped < stored {
                    if reader.stoppedByCap {
                        entries.append(entry)
                        coverage = .partial(listed: entries.count, total: nil, reason: capReason())
                    } else {
                        entry.isTruncated = true
                        entries.append(entry)
                        notes.append(.truncatedEntry(path: entry.path))
                        coverage = .partial(listed: entries.count, total: nil,
                                            reason: String(localized: "the archive ends inside the data of “\(entry.path)”", bundle: .module, comment: "Why the archive listing is partial. The argument is a member's path."))
                    }
                    break walking
                }
                entries.append(entry)
                if skipped < padded {           // the data is all there but the last block's padding is not
                    notes.append(.missingEndMarker)
                    break walking
                }
            } catch let error as ArchiveError {
                guard seenHeader else { throw error }
                coverage = .partial(listed: entries.count, total: nil,
                                    reason: reader.stoppedByCap ? capReason() : error.reason)
                break walking
            }
        }

        // Writers pad to a record size (bsdtar: 10 KB) with zeros; anything else after the marker is worth a line.
        if endMarker == .twoZeroBlocks, coverage.isComplete {
            let trailing = try reader.trailingBytes()
            if trailing.count > 0, !trailing.allZero { notes.append(.trailingData(bytes: trailing.count)) }
        }
        let dialect: TarFormat = sawPax ? .pax : sawGNU ? .gnu : (format ?? .ustar)
        let info = TarInfo(format: dialect, endMarker: endMarker, globalAttributes: global, bytesExamined: reader.position)
        return ArchiveListing(format: compressed ? .tarGzip(dialect) : .tar(dialect), fileSize: fileSize,
                              entries: entries, coverage: coverage, notes: notes, tar: info)
    }

    private static func readRecord(_ reader: any ForwardReader, size: Int64, limits: ArchiveLimits,
                                   what: String) throws -> [UInt8] {
        guard size <= Int64(limits.maxMetadataRecordBytes) else {
            throw ArchiveError.malformed("\(what) is \(size) bytes, over the \(limits.maxMetadataRecordBytes)-byte limit")
        }
        let bytes = try reader.read(Int(size))
        guard bytes.count == Int(size) else { throw ArchiveError.truncated("the file ends inside \(what)") }
        let padding = (Int64(blockSize) - size % Int64(blockSize)) % Int64(blockSize)
        _ = try reader.skip(padding)
        return bytes
    }

    private static func magicFormat(_ block: [UInt8]) -> TarFormat {
        let magic = Array(block[257..<265])
        if magic == Array("ustar  \0".utf8) { return .gnu }
        if Array(magic[0..<6]) == Array("ustar\0".utf8) { return .ustar }
        if Array(magic[0..<5]) == Array("ustar".utf8) { return .ustar }
        return .v7
    }

    /// The member a header describes, and how many data bytes follow the header. pax `size` overrides the header
    /// (it exists for sizes the 12-byte field cannot hold); GNU sparse members store only their non-hole data, so
    /// what follows is the stored size while the listed size is the real one.
    private static func makeEntry(_ block: [UInt8], flag: UInt8, headerSize: Int64, offset: Int64,
                                  pending: Pending, global: [String: String]) throws -> (ArchiveEntry, Int64) {
        // pax precedence: this member's `x` record, then the `g` globals, then the header itself.
        var pax = global
        for (key, value) in pending.pax { if value.isEmpty { pax.removeValue(forKey: key) } else { pax[key] = value } }
        let format = magicFormat(block)

        var pathEncoding = PathEncoding.utf8
        var path: String
        if let p = pax["GNU.sparse.name"] ?? pax["path"] {
            path = p
        } else if let long = pending.longName {
            (path, pathEncoding) = TextDecoding.utf8OrLatin1(long)
        } else {
            var nameBytes = field(block, 0, 100)
            if format == .ustar {
                let prefix = field(block, 345, 155)
                if !prefix.isEmpty { nameBytes = prefix + [UInt8(ascii: "/")] + nameBytes }
            }
            (path, pathEncoding) = TextDecoding.utf8OrLatin1(nameBytes)
        }

        var link: String?
        if let l = pax["linkpath"] {
            link = l
        } else if let long = pending.longLink {
            link = TextDecoding.utf8OrLatin1(long).0
        } else {
            let bytes = field(block, 157, 100)
            if !bytes.isEmpty { link = TextDecoding.utf8OrLatin1(bytes).0 }
        }

        var type = entryType(flag)
        if type == .file, flag != UInt8(ascii: "S"), path.hasSuffix("/") { type = .directory }  // V7 directories

        let permissions = UInt32(truncatingIfNeeded: (parseNumber(block[100..<108]) ?? 0) & 0o7777)
        var entry = ArchiveEntry(path: path, type: type, mode: type.modeTypeBits | permissions,
                                 pathEncoding: pathEncoding, headerOffset: offset)
        if type == .symlink || type == .hardlink { entry.linkTarget = link }

        var stored = headerSize
        if let s = pax["size"] {
            guard let v = Int64(s), v >= 0 else { throw ArchiveError.malformed("a pax size is not a number") }
            stored = v
        }
        var size = stored
        if flag == UInt8(ascii: "S"), let real = parseNumber(block[483..<495]) { size = real }
        if let real = pax["GNU.sparse.realsize"] ?? pax["GNU.sparse.size"], let v = Int64(real) { size = v }
        switch type {
        case .file, .other: entry.uncompressedSize = size
        case .hardlink: entry.uncompressedSize = size > 0 ? size : nil
        case .directory, .symlink, .characterDevice, .blockDevice, .fifo: entry.uncompressedSize = 0
        }

        if let m = pax["mtime"], let seconds = Double(m), seconds.isFinite {
            entry.modified = .instant(Date(timeIntervalSince1970: seconds))
        } else if let seconds = parseNumber(block[136..<148]) {
            entry.modified = .instant(Date(timeIntervalSince1970: TimeInterval(seconds)))
        }
        entry.uid = pax["uid"].flatMap { Int64($0) } ?? parseNumber(block[108..<116])
        entry.gid = pax["gid"].flatMap { Int64($0) } ?? parseNumber(block[116..<124])
        if format != .v7 {
            let uname = field(block, 265, 32), gname = field(block, 297, 32)
            entry.userName = pax["uname"] ?? (uname.isEmpty ? nil : TextDecoding.utf8OrLatin1(uname).0)
            entry.groupName = pax["gname"] ?? (gname.isEmpty ? nil : TextDecoding.utf8OrLatin1(gname).0)
            if type == .characterDevice || type == .blockDevice,
               let major = parseNumber(block[329..<337]), let minor = parseNumber(block[337..<345]) {
                entry.device = DeviceNumber(major: major, minor: minor)
            }
        } else {
            entry.userName = pax["uname"]; entry.groupName = pax["gname"]
        }
        return (entry, stored)
    }

    static func entryType(_ flag: UInt8) -> EntryType {
        switch flag {
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"), UInt8(ascii: "S"): .file
        case UInt8(ascii: "1"): .hardlink
        case UInt8(ascii: "2"): .symlink
        case UInt8(ascii: "3"): .characterDevice
        case UInt8(ascii: "4"): .blockDevice
        case UInt8(ascii: "5"), UInt8(ascii: "D"): .directory
        case UInt8(ascii: "6"): .fifo
        case UInt8(ascii: "V"): .other(String(localized: "volume label", bundle: .module, comment: "Kind of an archive member, shown in the archive's list."))
        case UInt8(ascii: "M"): .other(String(localized: "multi-volume continuation", bundle: .module, comment: "Kind of an archive member, shown in the archive's list."))
        default:
            if (0x20..<0x7F).contains(flag) {
                .other(String(localized: "tar type ‘\(String(Character(Unicode.Scalar(flag))))’", bundle: .module,
                              comment: "Kind of an archive member: an unknown tar type flag, shown as its character."))
            } else {
                .other(String(localized: "tar type \(flag)", bundle: .module, comment: "Kind of an archive member: an unknown tar type flag, by number."))
            }
        }
    }

    /// A NUL-terminated header field.
    private static func field(_ block: [UInt8], _ start: Int, _ length: Int) -> [UInt8] {
        let slice = block[start..<(start + length)]
        return Array(slice.prefix { $0 != 0 })
    }

    /// A numeric header field: octal ASCII (padded with spaces or NULs), or GNU base-256 when the high bit of the
    /// first byte is set. Nil when the field is neither.
    static func parseNumber(_ field: ArraySlice<UInt8>) -> Int64? {
        guard let first = field.first else { return 0 }
        if first == 0xFF {
            // Negative base-256: big-endian two's complement over the whole field (pre-1970 mtimes).
            var value: Int64 = -1
            for b in field.dropFirst() {
                guard value >= Int64.min >> 8 else { return nil }
                value = value << 8 | Int64(b)
            }
            return value
        }
        if first & 0x80 != 0 {
            var value = Int64(first & 0x7F)
            for b in field.dropFirst() {
                guard value <= Int64.max >> 8 else { return nil }
                value = value << 8 | Int64(b)
            }
            return value
        }
        var value: Int64 = 0
        var started = false
        for b in field {
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                started = true
                let (shifted, overflow) = value.multipliedReportingOverflow(by: 8)
                guard !overflow else { return nil }
                value = shifted + Int64(b - UInt8(ascii: "0"))
            case 0x20, 0:
                if started { return value }
            default:
                return nil
            }
        }
        return value
    }

    /// pax records: `"<length> <key>=<value>\n"`, where the length counts the whole record.
    static func parsePax(_ bytes: [UInt8]) throws -> [String: String] {
        var result: [String: String] = [:]
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0 { break }                      // NUL padding after the last record
            var length = 0, j = i
            while j < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[j]) {
                length = length * 10 + Int(bytes[j] - UInt8(ascii: "0"))
                guard length <= bytes.count else { throw ArchiveError.malformed("a pax record overstates its length") }
                j += 1
            }
            guard j > i, j < bytes.count, bytes[j] == 0x20, length > j - i + 1, i + length <= bytes.count,
                  bytes[i + length - 1] == 0x0A else {
                throw ArchiveError.malformed("a pax record is not in “length key=value” form")
            }
            let body = bytes[(j + 1)..<(i + length - 1)]
            guard let eq = body.firstIndex(of: UInt8(ascii: "=")) else {
                throw ArchiveError.malformed("a pax record has no “=”")
            }
            let key = TextDecoding.utf8OrLatin1(Array(body[body.startIndex..<eq])).0
            let value = TextDecoding.utf8OrLatin1(Array(body[(eq + 1)...])).0
            result[key] = value
            i += length
        }
        return result
    }
}
