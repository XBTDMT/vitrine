import CArchive
import Foundation

/// The archives the Swift readers do not cover, listed by the system libarchive (G-15): RAR 4 and 5, 7z, tars and
/// lone streams compressed with xz, LZMA, lzip, bzip2 or compress (.Z), ISO 9660, cpio, RPM, ar (DEB), XAR, CAB and
/// LHA; Zstandard and LZ4 frames too, decoded by the vendored decoders (DecodedStream) where the library would start
/// the `zstd` or `lz4` program instead, as macOS 27.2's does. Only headers are walked; member data is skipped, which for a compressed stream or a solid RAR
/// means decompressing and discarding it, so a listing runs under `ArchiveLimits.timeBudget` and the decompressed-
/// bytes cap and says where it stopped. libarchive reads through callbacks over the same `ArchiveByteSource` the
/// other readers use (a file or bytes in memory), never a path, and nothing it reads is written anywhere.
/// roadmap: S-8
public enum LibarchiveReader {
    /// Lists `source`. `fileName` names a lone compressed stream's member (`notes.txt.xz` → `notes.txt`).
    public static func list(source: any ArchiveByteSource, fileName: String? = nil,
                            limits: ArchiveLimits = .default) throws -> ArchiveListing {
        let head = try source.read(at: 0, count: 64)
        if let missing = missingDecoder(head) {
            throw ArchiveError.unsupported(String(localized: "this Mac's libarchive decodes \(missing) only through an external program, which Vitrine never starts",
                                                  bundle: .module, comment: "Why an archive cannot be listed; the argument names a compression format, like “the old LZ4 format”."))
        }
        let peek = RARPeek(head)
        let session = try LibarchiveSession(source: source, formats: .listing, timeBudget: limits.timeBudget)
        let a = session.archive

        var entries: [ArchiveEntry] = []
        var notes: [ListingNote] = []
        var coverage = ListingCoverage.complete
        var format: LibarchiveFormat?
        var retries = 0
        var rawFileSizeKnown = false

        func describe() -> LibarchiveFormat {
            if let format { return format }
            var made = Self.format(a, peek: peek)
            // A stream decoded here is invisible to libarchive's own filter list.
            if let outer = session.outerFilter { made.filters.insert(outer, at: 0) }
            format = made
            return made
        }

        func stopReason(_ stop: LibarchiveSession.Stop) -> String {
            switch stop {
            case .timeBudget:
                let seconds = limits.timeBudget.formatted(.number.precision(.fractionLength(0...1)))
                if describe().isSolid == true {
                    return String(localized: "Stopped after \(seconds) s; in a solid archive each name is reached only by decompressing everything before it", bundle: .module, comment: "Why the archive listing is partial. The argument is a number of seconds.")
                } else if !describe().compressionFilters.isEmpty {
                    return String(localized: "Stopped after \(seconds) s; in a compressed stream each name is reached only by decompressing what comes before it", bundle: .module, comment: "Why the archive listing is partial. The argument is a number of seconds.")
                }
                return String(localized: "Stopped after \(seconds) s", bundle: .module, comment: "Why the archive listing is partial. The argument is a number of seconds.")
            case .cancelled: return String(localized: "Cancelled", bundle: .module, comment: "Why the archive listing is partial.")
            case .readFailed(let why): return String(localized: "The file could not be read further: \(why)", bundle: .module, comment: "Why the archive listing is partial. The argument is a technical reason.")
            }
        }

        while true {
            if Task.isCancelled { throw CancellationError() }
            if entries.count >= limits.maxEntries {
                coverage = .partial(listed: entries.count, total: nil,
                                    reason: String(localized: "Only the first \(limits.maxEntries.formatted()) entries are listed", bundle: .module, comment: "Why the archive listing is partial."))
                break
            }
            if let stop = session.checkBudget() {
                if stop == .cancelled { throw CancellationError() }
                coverage = .partial(listed: entries.count, total: nil, reason: stopReason(stop))
                break
            }
            var handle: OpaquePointer?
            let status = archive_read_next_header(a, &handle)
            if status == VITRINE_ARCHIVE_EOF { break }
            if status == VITRINE_ARCHIVE_RETRY {
                retries += 1
                if retries < 16 { continue }
            }
            if status < VITRINE_ARCHIVE_WARN || handle == nil {
                if session.stop == .cancelled { throw CancellationError() }
                if let stop = session.stop {
                    coverage = .partial(listed: entries.count, total: nil, reason: stopReason(stop))
                    break
                }
                let message = Self.errorString(a)
                if Self.saysEncrypted(message) || peek.headersEncrypted || archive_read_has_encrypted_entries(a) > 0 {
                    notes.append(.encryptedHeaders)
                    coverage = .partial(listed: entries.count, total: nil,
                                        reason: String(localized: "The names are encrypted; listing them needs the password", bundle: .module, comment: "Why the archive listing is partial."))
                    break
                }
                if entries.isEmpty {
                    throw ArchiveError.malformed(message.isEmpty ? "libarchive could not read the first header" : message)
                }
                coverage = .partial(listed: entries.count, total: nil, reason: String(localized: "The archive is damaged after this point: \(message)", bundle: .module, comment: "Why the archive listing is partial. The argument is libarchive's own message, in English."))
                break
            }
            if status == VITRINE_ARCHIVE_WARN {
                let message = Self.errorString(a)
                if !message.isEmpty, notes.count < 8, !notes.contains(.readWarning(message)) {
                    notes.append(.readWarning(message))
                }
            }
            guard let handle else { break }
            let described = describe()
            // The raw reader accepts any bytes; without a decompression filter in front it would "list" the file
            // itself as one member.
            if described.container == .raw, described.compressionFilters.isEmpty { throw ArchiveError.notAnArchive }
            var entry = Self.entry(handle, headerOffset: max(0, archive_read_header_position(a)), format: described)
            if described.container == .raw {
                entry.path = Self.strippedName(fileName) ?? entry.path
                // A lone stream states no size: count it by decompressing, under the same budget as the walk.
                if let size = session.countData(limit: limits.maxDecompressedBytes) {
                    entry.uncompressedSize = size
                    rawFileSizeKnown = true
                }
            }
            entries.append(entry)
            if !described.compressionFilters.isEmpty, archive_filter_bytes(a, 0) > limits.maxDecompressedBytes {
                let examined = ByteCountFormatter.string(fromByteCount: limits.maxDecompressedBytes, countStyle: .file)
                coverage = .partial(listed: entries.count, total: nil,
                                    reason: String(localized: "Stopped after decompressing \(examined)", bundle: .module, comment: "Why the archive listing is partial. The argument is a size, like 2 GB."))
                break
            }
        }

        var described = describe()
        if described.container == .ar, entries.first?.path == "debian-binary" {
            described.isDebianPackage = true
        }
        if described.container == .raw, !rawFileSizeKnown, coverage.isComplete, let stop = session.stop {
            coverage = .partial(listed: entries.count, total: 1, reason: String(localized: "\(stopReason(stop)); its size is unknown", bundle: .module, comment: "Why the archive listing is partial. The argument is the reason the reading stopped."))
        }
        if archive_read_has_encrypted_entries(a) > 0, !notes.contains(.encryptedHeaders),
           !entries.contains(where: \.isEncrypted), entries.isEmpty {
            notes.append(.encryptedHeaders)
        }
        return ArchiveListing(format: .libarchive(described), fileSize: source.size, entries: entries,
                              coverage: coverage, notes: notes)
    }

    /// The first `limit` bytes of the member at `index` in the order this reader lists them (or, for a zip read here
    /// because its method is one Apple's decompressor lacks, the member at `path`).
    static func memberData(source: any ArchiveByteSource, index: Int?, path: String?, zip: Bool, limit: Int,
                           limits: ArchiveLimits) throws -> MemberData {
        let session = try LibarchiveSession(source: source, formats: zip ? .zip : .listing, timeBudget: limits.timeBudget)
        let a = session.archive
        let wanted = path.map(ArchivePath.normalized)
        var position = 0
        while true {
            if Task.isCancelled { throw CancellationError() }
            if let stop = session.checkBudget() {
                if stop == .cancelled { throw CancellationError() }
                throw ArchiveError.unsupported(String(localized: "the member was not reached within the time budget", bundle: .module, comment: "Why a member inside an archive cannot be opened."))
            }
            var handle: OpaquePointer?
            let status = archive_read_next_header(a, &handle)
            if status == VITRINE_ARCHIVE_EOF { throw ArchiveError.malformed("the member is not in the archive") }
            guard status >= VITRINE_ARCHIVE_WARN, let handle else {
                if session.stop == .cancelled { throw CancellationError() }
                throw ArchiveError.malformed(Self.errorString(a))
            }
            defer { position += 1 }
            let matches: Bool
            if let wanted {
                let name = Self.text(archive_entry_pathname_utf8(handle), archive_entry_pathname(handle))?.0 ?? ""
                matches = ArchivePath.normalized(name) == wanted
            } else {
                matches = position == index
            }
            guard matches else { continue }
            let size: Int64? = archive_entry_size_is_set(handle) != 0 ? archive_entry_size(handle) : nil
            if archive_entry_is_data_encrypted(handle) != 0 || archive_entry_is_encrypted(handle) != 0 {
                throw ArchiveError.unsupported(String(localized: "the member is encrypted", bundle: .module, comment: "Why a member inside an archive cannot be opened."))
            }
            let bytes = try session.readData(limit: limit)
            return MemberData(bytes: Array(bytes.prefix(limit)), memberSize: size, isComplete: bytes.count <= limit)
        }
    }

    // MARK: Recognising the formats

    /// The stream format `head` starts with when this Mac's libarchive cannot decode it in-process.
    /// Streams neither libarchive nor Vitrine decodes in the process: only LZ4's legacy format (Zstandard and LZ4
    /// frames are decoded by DecodedStream when libarchive would need an outside program).
    static func missingDecoder(_ head: [UInt8]) -> String? {
        if head.starts(with: [0x02, 0x21, 0x4C, 0x18]), !LibarchiveSession.decodesLZ4 {
            return String(localized: "the old LZ4 format", bundle: .module, comment: "A compression format, named inside a sentence about decoding it.")
        }
        return nil
    }

    /// Signatures that name a format outright, checked before tar (whose header could hold any of these bytes only
    /// with a failing checksum).
    static func hasStrongSignature(_ head: [UInt8]) -> Bool {
        func starts(_ magic: [UInt8]) -> Bool { head.count >= magic.count && Array(head.prefix(magic.count)) == magic }
        return starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])            // Rar! (4: …00, 5: …01 00)
            || starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])            // 7z
            || starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])            // xz
            || starts([0x28, 0xB5, 0x2F, 0xFD])                        // Zstandard frame
            || starts([0x04, 0x22, 0x4D, 0x18])                        // LZ4 frame
            || starts([0x02, 0x21, 0x4C, 0x18])                        // LZ4 legacy frame
            || starts(Array("LZIP".utf8))
            || (starts(Array("BZh".utf8)) && head.count > 3 && (0x31...0x39).contains(head[3]))
            || starts([0x1F, 0x9D])                                    // compress (.Z)
            || starts([0xED, 0xAB, 0xEE, 0xDB])                        // RPM lead
            || starts(Array("xar!".utf8))
            || starts([0x4D, 0x53, 0x43, 0x46, 0, 0, 0, 0])            // MSCF: a Microsoft cabinet
            || starts(Array("!<arch>\n".utf8))                         // ar (and so DEB)
    }

    /// Signatures too short or too far in to win over tar: cpio, LHA, ISO 9660 (`CD001` at 32,769), and LZMA's
    /// header-only "alone" format, which has no magic and is believed only under its own extension.
    static func hasWeakSignature(_ head: [UInt8], source: any ArchiveByteSource, fileName: String?) throws -> Bool {
        func starts(_ magic: [UInt8]) -> Bool { head.count >= magic.count && Array(head.prefix(magic.count)) == magic }
        if starts(Array("070707".utf8)) || starts(Array("070701".utf8)) || starts(Array("070702".utf8))
            || starts([0xC7, 0x71]) || starts([0x71, 0xC7]) {
            return true
        }
        if head.count >= 7, head[2] == 0x2D, head[3] == 0x6C, [0x68, 0x7A].contains(head[4]), head[6] == 0x2D {
            return true                                                // "-lh5-", "-lz4-" at offset 2
        }
        for offset: Int64 in [0x8001, 0x8801, 0x9001] where source.size >= offset + 5 {
            if try source.read(at: offset, count: 5) == Array("CD001".utf8) { return true }
        }
        let name = fileName?.lowercased() ?? ""
        if (name.hasSuffix(".lzma") || name.hasSuffix(".tlz")), let first = head.first, first < 225, head.count >= 13 {
            return true
        }
        return false
    }

    /// `notes.txt.xz` → `notes.txt`, `bundle.txz` → `bundle.tar`.
    static func strippedName(_ fileName: String?) -> String? {
        guard let fileName, !fileName.isEmpty else { return nil }
        let ns = fileName as NSString
        switch ns.pathExtension.lowercased() {
        case "xz", "zst", "zstd", "lz4", "lzma", "lz", "bz2", "z": return ns.deletingPathExtension
        case "txz", "tzst", "tlz", "tbz", "tbz2", "taz": return ns.deletingPathExtension + ".tar"
        default: return nil
        }
    }

    // MARK: What libarchive reports

    static func format(_ a: OpaquePointer, peek: RARPeek) -> LibarchiveFormat {
        let code = archive_format(a)
        let container: LibarchiveFormat.Container
        switch code & 0xFF0000 {
        case 0x10000: container = .cpio
        case 0x30000: container = .tar
        case 0x40000: container = .iso9660
        case 0x50000: container = .zip
        case 0x70000: container = .ar
        case 0x90000: container = .raw
        case 0xA0000: container = .xar
        case 0xB0000: container = .lha
        case 0xC0000: container = .cab
        case 0xD0000: container = .rar
        case 0xE0000: container = .sevenZip
        case 0x100000: container = .rar5
        default: container = .other
        }
        var filters: [String] = []
        for i in 0..<max(0, archive_filter_count(a)) {
            guard archive_filter_code(a, i) != 0, let name = archive_filter_name(a, i) else { continue }
            filters.append(String(cString: name))
        }
        let name = archive_format_name(a).map { String(cString: $0) } ?? "unknown"
        let solid = container == .rar || container == .rar5 ? peek.isSolid : nil
        return LibarchiveFormat(container: container, formatName: name, filters: filters.reversed(), isSolid: solid)
    }

    /// `headerOffset` is libarchive's header position (in the decompressed stream, for a compressed one).
    static func entry(_ e: OpaquePointer, headerOffset: Int64, format: LibarchiveFormat) -> ArchiveEntry {
        let (path, encoding) = text(archive_entry_pathname_utf8(e), archive_entry_pathname(e)) ?? ("", .utf8)
        let hardlink = text(archive_entry_hardlink_utf8(e), archive_entry_hardlink(e))?.0
        let symlink = text(archive_entry_symlink_utf8(e), archive_entry_symlink(e))?.0
        let filetype = UInt32(archive_entry_filetype(e)) & 0o170000
        let type: EntryType
        if let hardlink, !hardlink.isEmpty {
            type = .hardlink
        } else {
            switch filetype {
            case 0o040000: type = .directory
            case 0o120000: type = .symlink
            case 0o020000: type = .characterDevice
            case 0o060000: type = .blockDevice
            case 0o010000: type = .fifo
            case 0o140000: type = .other(String(localized: "socket", bundle: .module, comment: "Kind of an archive member, shown in the archive's list."))
            default: type = path.hasSuffix("/") ? .directory : .file
            }
        }
        var mode: UInt32?
        if archive_entry_perm_is_set(e) != 0 {
            mode = (UInt32(archive_entry_mode(e)) & 0o7777) | type.modeTypeBits
        }
        var modified: ArchiveTimestamp?
        if archive_entry_mtime_is_set(e) != 0 {
            let seconds = Double(archive_entry_mtime(e)) + Double(archive_entry_mtime_nsec(e)) / 1_000_000_000
            modified = .instant(Date(timeIntervalSince1970: seconds))
        }
        var device: DeviceNumber?
        if type == .characterDevice || type == .blockDevice {
            device = DeviceNumber(major: Int64(archive_entry_rdevmajor(e)), minor: Int64(archive_entry_rdevminor(e)))
        }
        let encrypted = archive_entry_is_encrypted(e) != 0
        return ArchiveEntry(
            path: path, type: type,
            uncompressedSize: type == .file && archive_entry_size_is_set(e) != 0 ? max(0, archive_entry_size(e)) : nil,
            modified: modified, mode: mode, linkTarget: type == .hardlink ? hardlink : (type == .symlink ? symlink : nil),
            encryption: encrypted ? .format(encryptionLabel(format)) : nil,
            uid: archive_entry_uid_is_set(e) != 0 ? archive_entry_uid(e) : nil,
            gid: archive_entry_gid_is_set(e) != 0 ? archive_entry_gid(e) : nil,
            userName: archive_entry_uname(e).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 },
            groupName: archive_entry_gname(e).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 },
            device: device, pathEncoding: encoding, headerOffset: headerOffset)
    }

    static func encryptionLabel(_ format: LibarchiveFormat) -> String {
        switch format.container {
        case .rar: "RAR"
        case .rar5: "RAR 5"
        case .sevenZip: "7-Zip"
        case .zip: "ZIP"
        default: format.formatName
        }
    }

    /// libarchive's UTF-8 form when it has one, else the stored bytes as UTF-8 or, failing that, Latin-1.
    static func text(_ utf8: UnsafePointer<CChar>?, _ raw: UnsafePointer<CChar>?) -> (String, PathEncoding)? {
        if let utf8 { return (String(cString: utf8), .utf8) }
        guard let raw else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self),
                                              count: strlen(raw)))
        return TextDecoding.utf8OrLatin1(bytes)
    }

    static func errorString(_ a: OpaquePointer) -> String {
        archive_error_string(a).map { String(cString: $0) } ?? ""
    }

    static func saysEncrypted(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("encrypt") || m.contains("passphrase") || m.contains("password")
    }
}

/// RAR's main header, read before libarchive: whether the archive is solid (RAR 4 `MHD_SOLID`, RAR 5 archive flag
/// 0x0004) and whether its headers are encrypted (RAR 4 `MHD_PASSWORD`, RAR 5 an archive encryption header first).
/// roadmap: S-8
struct RARPeek {
    var isSolid: Bool?
    var headersEncrypted = false

    init(_ head: [UInt8]) {
        let rar4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        let rar5: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
        if head.starts(with: rar5) {
            var i = 8 + 4                                              // signature, header CRC32
            guard Self.vint(head, &i) != nil, let type = Self.vint(head, &i), let flags = Self.vint(head, &i) else { return }
            if type == 4 { headersEncrypted = true; return }
            guard type == 1 else { return }
            if flags & 0x01 != 0 { guard Self.vint(head, &i) != nil else { return } }   // extra area size
            if flags & 0x02 != 0 { guard Self.vint(head, &i) != nil else { return } }   // data size
            guard let archiveFlags = Self.vint(head, &i) else { return }
            isSolid = archiveFlags & 0x0004 != 0
        } else if head.starts(with: rar4), head.count >= 12, head[9] == 0x73 {
            let flags = UInt16(head[10]) | UInt16(head[11]) << 8
            isSolid = flags & 0x0008 != 0
            headersEncrypted = flags & 0x0080 != 0
        }
    }

    /// RAR 5's variable-length integer: 7 bits per byte, low first, the high bit set on all but the last.
    static func vint(_ bytes: [UInt8], _ i: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for shift in stride(from: 0, to: 64, by: 7) {
            guard i < bytes.count else { return nil }
            let b = bytes[i]; i += 1
            value |= UInt64(b & 0x7F) << UInt64(shift)
            if b & 0x80 == 0 { return value }
        }
        return nil
    }
}

/// One libarchive read handle over an `ArchiveByteSource`, with the time budget and cancellation checked inside the
/// read callback, so even a long skip through one member stops on time. One per listing or member read; not shared
/// across threads. roadmap: S-8
final class LibarchiveSession {
    enum Formats { case listing, zip }
    enum Stop: Equatable { case timeBudget, cancelled, readFailed(String) }

    let archive: OpaquePointer
    private let source: any ArchiveByteSource
    private var position: Int64 = 0
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize = 128 * 1024
    private let deadline: ContinuousClock.Instant
    private(set) var stop: Stop?
    /// A Zstandard or LZ4 stream this libarchive cannot decode itself, decoded here and handed over as plain bytes.
    private let decoded: DecodedStream?
    /// The codec's name for the format line ("zstd", "lz4"), when the stream is decoded here.
    var outerFilter: String? { decoded?.codec.rawValue }

    init(source: any ArchiveByteSource, formats: Formats, timeBudget: TimeInterval) throws {
        guard let a = archive_read_new() else { throw ArchiveError.unreadable("libarchive did not start") }
        archive = a
        self.source = source
        let head = (try? source.read(at: 0, count: 4)) ?? []
        if let codec = DecodedStream.codec(forHead: head),
           codec == .zstd ? !Self.decodesZstandard : !Self.decodesLZ4 {
            decoded = try DecodedStream(source: source, codec: codec)
        } else {
            decoded = nil
        }
        buffer = .allocate(capacity: bufferSize)
        deadline = ContinuousClock.now + .milliseconds(Int(timeBudget * 1000))
        switch formats {
        case .listing:
            for enable in Self.inProcessFilters { _ = enable(a) }
            for enable in [archive_read_support_format_7zip, archive_read_support_format_ar,
                           archive_read_support_format_cab, archive_read_support_format_cpio,
                           archive_read_support_format_iso9660, archive_read_support_format_lha,
                           archive_read_support_format_rar, archive_read_support_format_rar5,
                           archive_read_support_format_tar, archive_read_support_format_xar,
                           archive_read_support_format_raw] { _ = enable(a) }
        case .zip:
            _ = archive_read_support_format_zip_seekable(a)
        }
        archive_read_set_read_callback(a, libarchiveRead)
        archive_read_set_skip_callback(a, libarchiveSkip)
        // A decoded stream only goes forward: libarchive reads through what it would skip, and never seeks.
        if decoded == nil { archive_read_set_seek_callback(a, libarchiveSeek) }
        archive_read_set_callback_data(a, Unmanaged.passUnretained(self).toOpaque())
        guard archive_read_open1(a) == VITRINE_ARCHIVE_OK else {
            let message = LibarchiveReader.errorString(a)
            switch stop {
            case .cancelled?: throw CancellationError()
            case .timeBudget?: throw ArchiveError.unsupported("the format was not recognised within the time budget")
            case .readFailed(let why)?: throw ArchiveError.unreadable(why)
            case nil: break
            }
            throw message.lowercased().contains("unrecognized") || message.isEmpty
                ? ArchiveError.notAnArchive : ArchiveError.malformed(message)
        }
    }

    typealias Enable = @convention(c) (OpaquePointer?) -> Int32

    /// The decompression filters this Mac's libarchive runs in-process. A support call that answers ARCHIVE_WARN
    /// ("Using external zstd program") would start a helper binary to decode, which Vitrine never does (and the
    /// sandbox forbids), so each filter is tried once on a scratch handle and enabled only if it answered OK. On
    /// macOS 27.2 (libarchive 3.7.4 with zlib, liblzma and bz2lib) that leaves out Zstandard and LZ4.
    static let inProcessFilters: [Enable] = {
        let candidates: [Enable] = [archive_read_support_filter_bzip2, archive_read_support_filter_compress,
                                    archive_read_support_filter_gzip, archive_read_support_filter_lz4,
                                    archive_read_support_filter_lzip, archive_read_support_filter_lzma,
                                    archive_read_support_filter_xz, archive_read_support_filter_zstd,
                                    archive_read_support_filter_rpm]
        return candidates.filter(decodesInProcess)
    }()

    static let decodesZstandard = decodesInProcess(archive_read_support_filter_zstd)
    static let decodesLZ4 = decodesInProcess(archive_read_support_filter_lz4)

    /// Whether this Mac's libarchive decodes with `enable`'s filter itself rather than through a helper program.
    static func decodesInProcess(_ enable: Enable) -> Bool {
        guard let scratch = archive_read_new() else { return false }
        defer { archive_read_free(scratch) }
        return enable(scratch) == VITRINE_ARCHIVE_OK
    }

    deinit {
        archive_read_free(archive)
        buffer.deallocate()
    }

    /// Records and returns why reading must stop now, if it must.
    @discardableResult
    func checkBudget() -> Stop? {
        if stop == nil {
            if Task.isCancelled { stop = .cancelled } else if ContinuousClock.now >= deadline { stop = .timeBudget }
        }
        return stop
    }

    /// Up to `limit + 1` bytes of the current member's data (one past the limit tells the caller it was cut).
    func readData(limit: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        let want = limit == Int.max ? limit : limit + 1
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 8)
        defer { scratch.deallocate() }
        while out.count < want {
            let n = archive_read_data(archive, scratch, min(64 * 1024, want - out.count))
            if n == 0 { break }
            if n < 0 {
                if stop == .cancelled { throw CancellationError() }
                if stop == .timeBudget { throw ArchiveError.unsupported(String(localized: "reading the member ran past the time budget", bundle: .module, comment: "Why a member inside an archive cannot be opened.")) }
                let message = LibarchiveReader.errorString(archive)
                throw LibarchiveReader.saysEncrypted(message) ? ArchiveError.unsupported(String(localized: "the member is encrypted", bundle: .module, comment: "Why a member inside an archive cannot be opened."))
                    : ArchiveError.malformed(message)
            }
            out.append(contentsOf: UnsafeRawBufferPointer(start: scratch, count: n))
        }
        return out
    }

    /// Counts the current member's bytes by decompressing them, up to `limit`; nil when the budget, the limit or an
    /// error stopped it first.
    func countData(limit: Int64) -> Int64? {
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 8)
        defer { scratch.deallocate() }
        var total: Int64 = 0
        while total <= limit {
            let n = archive_read_data(archive, scratch, 64 * 1024)
            if n == 0 { return total }
            if n < 0 { return nil }
            total += Int64(n)
        }
        return nil
    }

    // Called by libarchive through the C callbacks below.

    fileprivate func fill(_ out: UnsafeMutablePointer<UnsafeRawPointer?>) -> Int {
        if checkBudget() != nil { return -1 }
        if let decoded {
            do {
                let n = try decoded.read(into: buffer, capacity: bufferSize)
                position += Int64(n)
                out.pointee = UnsafeRawPointer(buffer)
                return n
            } catch {
                stop = .readFailed((error as? ArchiveError)?.reason ?? "\(error)")
                return -1
            }
        }
        let count = Int(min(Int64(bufferSize), max(0, source.size - position)))
        guard count > 0 else { return 0 }
        do {
            let bytes = try source.read(at: position, count: count)
            bytes.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: $0.count) }
            position += Int64(bytes.count)
            out.pointee = UnsafeRawPointer(buffer)
            return bytes.count
        } catch {
            stop = .readFailed((error as? ArchiveError)?.reason ?? "\(error)")
            return -1
        }
    }

    fileprivate func skip(_ request: Int64) -> Int64 {
        if decoded != nil { return 0 }
        let n = max(0, min(request, source.size - position))
        position += n
        return n
    }

    fileprivate func seek(_ offset: Int64, whence: Int32) -> Int64 {
        let base: Int64
        switch whence {
        case SEEK_SET: base = 0
        case SEEK_CUR: base = position
        case SEEK_END: base = source.size
        default: return Int64(VITRINE_ARCHIVE_FATAL)
        }
        let (target, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, target >= 0 else { return Int64(VITRINE_ARCHIVE_FATAL) }
        position = min(target, source.size)
        return position
    }
}

private func libarchiveRead(_ a: OpaquePointer?, _ client: UnsafeMutableRawPointer?,
                            _ buffer: UnsafeMutablePointer<UnsafeRawPointer?>?) -> Int {
    guard let client, let buffer else { return -1 }
    return Unmanaged<LibarchiveSession>.fromOpaque(client).takeUnretainedValue().fill(buffer)
}

private func libarchiveSkip(_ a: OpaquePointer?, _ client: UnsafeMutableRawPointer?, _ request: Int64) -> Int64 {
    guard let client else { return 0 }
    return Unmanaged<LibarchiveSession>.fromOpaque(client).takeUnretainedValue().skip(request)
}

private func libarchiveSeek(_ a: OpaquePointer?, _ client: UnsafeMutableRawPointer?, _ offset: Int64,
                            _ whence: Int32) -> Int64 {
    guard let client else { return Int64(VITRINE_ARCHIVE_FATAL) }
    return Unmanaged<LibarchiveSession>.fromOpaque(client).takeUnretainedValue().seek(offset, whence: whence)
}
