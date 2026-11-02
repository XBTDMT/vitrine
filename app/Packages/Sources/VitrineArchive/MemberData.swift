import Foundation
import VitrineSupport

/// The first bytes of one member, read into memory without writing anything to disk (the peek drawer's text, a
/// nested archive, an app's Info.plist). Bounded by the caller's limit, the decompressed-bytes cap and the time
/// budget. roadmap: S-8
public struct MemberData: Sendable, Equatable {
    /// At most the limit asked for.
    public var bytes: [UInt8]
    /// The member's full size when the archive states it.
    public var memberSize: Int64?
    /// `bytes` is the whole member; false when the limit cut it short.
    public var isComplete: Bool

    public init(bytes: [UInt8], memberSize: Int64?, isComplete: Bool) {
        self.bytes = bytes; self.memberSize = memberSize; self.isComplete = isComplete
    }
}

/// An archive that is a member of another, opened from memory (DEB's data.tar.xz, a zip inside a zip). The member is
/// read whole, so only members up to `ArchiveLimits.maxNestedArchiveBytes` (64 MB by default) open. roadmap: S-8
public struct NestedArchive: Sendable {
    /// The member's path in its parent archive.
    public let path: String
    /// The member's file name, the nested archive's name in a breadcrumb.
    public var name: String { ArchivePath.components(path).last ?? path }
    /// The member's bytes: the source for this level's own member reads and deeper nesting.
    public let source: DataByteSource
    public let listing: ArchiveListing
}

/// Member reads and nested archives across every reader. roadmap: S-8
extension VitrineArchive {
    /// The first `limit` bytes of the member at `entryIndex` in `listing` (a listing of `source`).
    public static func memberData(source: any ArchiveByteSource, fileName: String? = nil, listing: ArchiveListing,
                                  entryIndex: Int, limit: Int, limits: ArchiveLimits = .default) throws -> MemberData {
        guard listing.entries.indices.contains(entryIndex) else { throw ArchiveError.malformed("no such member") }
        let entry = listing.entries[entryIndex]
        guard entry.type == .file || entry.type == .hardlink else {
            throw ArchiveError.unsupported("“\(ArchivePath.visible(entry.path))” is a \(entry.type.name), not a file")
        }
        guard !entry.isEncrypted else { throw ArchiveError.unsupported(String(localized: "the member is encrypted", bundle: .module, comment: "Why a member inside an archive cannot be opened.")) }
        // Never more than a listing may decompress, whatever the caller asks for.
        let limit = Int(min(Int64(max(0, limit)), limits.maxDecompressedBytes))
        switch listing.format {
        case .zip:
            return try zipMemberData(source: source, entry: entry, limit: limit, limits: limits)
        case .tar:
            guard let offset = entry.dataOffset, let size = entry.uncompressedSize else {
                throw ArchiveError.malformed("the member's data offset is unknown")
            }
            let available = max(0, min(size, source.size - offset))
            let bytes = try source.read(at: offset, count: Int(min(available, Int64(limit))))
            return MemberData(bytes: bytes, memberSize: size, isComplete: Int64(bytes.count) == size)
        case .tarGzip:
            guard let offset = entry.dataOffset, let size = entry.uncompressedSize, let gzip = listing.gzip else {
                throw ArchiveError.malformed("the member's data offset is unknown")
            }
            let stream = try GzipForwardReader(source: source, start: Int64(gzip.headerLength), cap: limits.maxDecompressedBytes)
            guard try stream.skip(offset) == offset else {
                throw ArchiveError.unsupported("the member lies past the \(limits.maxDecompressedBytes)-byte decompression cap")
            }
            let bytes = try stream.read(Int(min(size, Int64(limit))))
            return MemberData(bytes: bytes, memberSize: size, isComplete: Int64(bytes.count) == size)
        case .gzip:
            let stream = try GzipForwardReader(source: source, start: entry.dataOffset ?? Int64(listing.gzip?.headerLength ?? 10),
                                               cap: limits.maxDecompressedBytes)
            let bytes = try stream.read(limit + 1)
            let complete = bytes.count <= limit && !stream.stoppedByCap
            return MemberData(bytes: Array(bytes.prefix(limit)), memberSize: complete ? Int64(bytes.count) : nil,
                              isComplete: complete)
        case .libarchive:
            return try LibarchiveReader.memberData(source: source, index: entryIndex, path: nil, zip: false,
                                                   limit: limit, limits: limits)
        case .fileList(let what):
            throw ArchiveError.unsupported("a \(what) names its files; it does not hold them")
        }
    }

    /// The first `limit` bytes of the member at `path` (the last one of that name, the one extraction would keep).
    public static func memberData(source: any ArchiveByteSource, fileName: String? = nil, path: String, limit: Int,
                                  limits: ArchiveLimits = .default) throws -> MemberData {
        let listing = try list(source: source, fileName: fileName, limits: limits)
        let wanted = ArchivePath.normalized(path)
        guard let index = listing.entries.lastIndex(where: { ArchivePath.normalized($0.path) == wanted && $0.type != .directory }) else {
            throw ArchiveError.malformed(String(localized: "“\(ArchivePath.visible(path))” is not in the archive", bundle: .module, comment: "Why a member inside an archive cannot be opened. The argument is a path."))
        }
        return try memberData(source: source, fileName: fileName, listing: listing, entryIndex: index, limit: limit, limits: limits)
    }

    /// Opens the member at `entryIndex` of `listing` as an archive of its own, from memory. Members larger than
    /// `limits.maxNestedArchiveBytes` are refused with the size and the limit in the reason, never read.
    public static func openNested(source: any ArchiveByteSource, fileName: String? = nil, listing: ArchiveListing,
                                  entryIndex: Int, limits: ArchiveLimits = .default) throws -> NestedArchive {
        guard listing.entries.indices.contains(entryIndex) else { throw ArchiveError.malformed("no such member") }
        let entry = listing.entries[entryIndex]
        let cap = limits.maxNestedArchiveBytes
        func tooLarge(_ size: Int64?) -> ArchiveError {
            let path = ArchivePath.visible(entry.path)
            let limit = ByteCountFormatter.string(fromByteCount: Int64(cap), countStyle: .file)
            guard let size else {
                return .unsupported(String(localized: "“\(path)” is larger than that; archives inside archives open up to \(limit)", bundle: .module, comment: "Why a member inside an archive cannot be opened. The first argument is a path, the second a size limit."))
            }
            let shown = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            return .unsupported(String(localized: "“\(path)” is \(shown); archives inside archives open up to \(limit)", bundle: .module, comment: "Why a member inside an archive cannot be opened. A path, its size, then the size limit."))
        }
        if let size = entry.uncompressedSize, size > Int64(cap), !entry.uncompressedSizeIsModulo4GiB { throw tooLarge(size) }
        let data = try memberData(source: source, fileName: fileName, listing: listing, entryIndex: entryIndex,
                                  limit: cap, limits: limits)
        guard data.isComplete else { throw tooLarge(data.memberSize) }
        let inner = DataByteSource(data.bytes)
        let name = ArchivePath.components(entry.path).last ?? entry.path
        return NestedArchive(path: entry.path, source: inner, listing: try list(source: inner, fileName: name, limits: limits))
    }

    // MARK: Zip

    /// Stored and deflated members are read here (Apple's decompressor); other methods go to libarchive's zip reader.
    static func zipMemberData(source: any ArchiveByteSource, entry: ArchiveEntry, limit: Int,
                              limits: ArchiveLimits) throws -> MemberData {
        let size = entry.uncompressedSize
        guard entry.method == .stored || entry.method == .deflate, let compressed = entry.compressedSize else {
            return try LibarchiveReader.memberData(source: source, index: nil, path: entry.path, zip: true,
                                                   limit: limit, limits: limits)
        }
        let reader = WindowedReader(source, windowSize: 4 * 1024)
        let header = try reader.exactly(30, at: entry.headerOffset, "a local header")
        guard header.le32(at: 0) == ZipReader.localSignature, let n = header.le16(at: 26), let m = header.le16(at: 28) else {
            throw ArchiveError.malformed("the member's local header is missing")
        }
        // The 30-byte header was read, so `headerOffset + 30` lies within the file and this sum cannot overflow.
        let dataOffset = entry.headerOffset + 30 + Int64(n) + Int64(m)
        // `compressed` comes from the directory (a ZIP64 size may be near Int64.max): compared against what is left
        // of the file, never added to the offset, so a lying size reads as damage instead of trapping.
        guard compressed >= 0, dataOffset <= source.size, compressed <= source.size - dataOffset else {
            throw ArchiveError.truncated("the file ends inside the member")
        }
        if entry.method == .stored {
            let bytes = try source.read(at: dataOffset, count: Int(min(compressed, Int64(limit))))
            return MemberData(bytes: bytes, memberSize: size, isComplete: Int64(bytes.count) == compressed)
        }
        // Deflate: stream the compressed span through the inflater, stopping once `limit` bytes are out.
        let inflater = try RawInflater()
        var out: [UInt8] = []
        var input: [UInt8] = []
        var inputStart = 0
        var next = dataOffset
        let end = dataOffset + compressed
        var finished = false
        var stalls = 0
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = ContinuousClock.now + .milliseconds(Int(limits.timeBudget * 1000))
        while out.count < limit, !finished {
            if Task.isCancelled { throw CancellationError() }
            if ContinuousClock.now >= deadline { throw ArchiveError.unsupported(String(localized: "reading the member ran past the time budget", bundle: .module, comment: "Why a member inside an archive cannot be opened.")) }
            if inputStart == input.count {
                guard next < end else { break }
                input = try source.read(at: next, count: Int(min(64 * 1024, end - next)))
                inputStart = 0
                next += Int64(input.count)
                if input.isEmpty { break }
            }
            let last = next >= end
            let step = try input.withUnsafeBufferPointer { inBuffer in
                try scratch.withUnsafeMutableBufferPointer { outBuffer in
                    try inflater.step(input: UnsafeBufferPointer(rebasing: inBuffer[inputStart...]), output: outBuffer, last: last)
                }
            }
            inputStart += step.consumed
            out.append(contentsOf: scratch[0..<min(step.produced, limit - out.count)])
            finished = step.finished
            // A decoder that takes nothing and gives nothing twice running has nothing more to say.
            stalls = step.consumed == 0 && step.produced == 0 ? stalls + 1 : 0
            if stalls > 1 { break }
        }
        let complete = finished || (size.map { Int64(out.count) == $0 } ?? false)
        return MemberData(bytes: out, memberSize: size, isComplete: complete && (size.map { Int64(out.count) == $0 } ?? true))
    }
}
