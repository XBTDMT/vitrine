import Foundation
import Synchronization

/// The bytes the hex inspector shows, read on demand: a file through a FileHandle in 64 KB pages kept in a small
/// cache (at most 4 MB), so a file of any size opens at once and memory stays bounded; the whole file is never read.
/// Bytes already in memory (a renderer that holds them, a test) work the same way. Safe to share: the view reads pages
/// on the main thread while a search streams through its own handle (`chunks`). `bytesRead` counts every byte taken
/// from the file through the page cache, so a test can prove how little an open costs. roadmap: S-5
public final class HexByteSource: @unchecked Sendable {
    public static let pageSize = 64 * 1024
    /// Pages kept: 64 × 64 KB = 4 MB.
    public static let cachedPages = 64

    /// The file, or nil for bytes in memory.
    public let url: URL?
    /// The file's size when it was opened.
    public let count: Int64
    private let memory: Data?

    /// The open handle, the pages kept and the read count, behind one lock. roadmap: S-5
    private struct Cache {
        var handle: FileHandle?
        var pages: [Int64: [UInt8]] = [:]
        /// Least recently used first.
        var order: [Int64] = []
        var bytesRead: Int64 = 0
    }
    private let cache: Mutex<Cache>

    public init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        let size = try handle.seekToEnd()
        self.url = url
        count = Int64(size)
        memory = nil
        cache = Mutex(Cache(handle: handle))
    }

    public init(data: Data) {
        url = nil
        count = Int64(data.count)
        memory = data
        cache = Mutex(Cache())
    }

    deinit { cache.withLock { try? $0.handle?.close() } }

    /// Bytes taken from the file so far (memory sources count nothing).
    public var bytesRead: Int64 { cache.withLock { $0.bytesRead } }

    /// The bytes in `range`, clamped to the source; shorter at the end, empty past it.
    public func bytes(in range: Range<Int64>) -> [UInt8] {
        let lower = max(0, range.lowerBound), upper = min(count, range.upperBound)
        guard lower < upper else { return [] }
        if let memory {
            let start = memory.startIndex + Int(lower)
            return Array(memory[start..<start + Int(upper - lower)])
        }
        let size = Int64(Self.pageSize)
        var out: [UInt8] = []
        out.reserveCapacity(Int(upper - lower))
        var page = lower / size
        while page * size < upper {
            let bytes = self.page(page)
            let start = page * size
            let from = Int(max(lower, start) - start), to = Int(min(upper, start + Int64(bytes.count)) - start)
            if from < to { out.append(contentsOf: bytes[from..<to]) }
            // A file that shrank since it was opened ends early.
            if bytes.count < Self.pageSize { break }
            page += 1
        }
        return out
    }

    public func byte(at offset: Int64) -> UInt8? { bytes(in: offset..<offset + 1).first }

    private func page(_ index: Int64) -> [UInt8] {
        cache.withLock { c in
            if let hit = c.pages[index] {
                if let i = c.order.firstIndex(of: index) { c.order.remove(at: i) }
                c.order.append(index)
                return hit
            }
            guard let handle = c.handle else { return [] }
            let bytes: [UInt8]
            do {
                try handle.seek(toOffset: UInt64(index) * UInt64(Self.pageSize))
                bytes = [UInt8](try handle.read(upToCount: Self.pageSize) ?? Data())
            } catch {
                bytes = []
            }
            c.bytesRead += Int64(bytes.count)
            c.pages[index] = bytes
            c.order.append(index)
            if c.order.count > Self.cachedPages { c.pages[c.order.removeFirst()] = nil }
            return bytes
        }
    }

    /// A reader for one streaming pass (search): its own handle, so it never fills or evicts the view's pages.
    func chunks() throws -> HexChunkReader {
        if let memory { return HexChunkReader(memory: memory, handle: nil) }
        guard let url else { return HexChunkReader(memory: Data(), handle: nil) }
        return HexChunkReader(memory: nil, handle: try FileHandle(forReadingFrom: url))
    }
}

/// One streaming pass over a source, chunk by chunk, outside the page cache. roadmap: S-5
final class HexChunkReader {
    private let memory: Data?
    private let handle: FileHandle?

    init(memory: Data?, handle: FileHandle?) { self.memory = memory; self.handle = handle }
    deinit { try? handle?.close() }

    /// Up to `length` bytes at `offset`; fewer at the end of the file.
    func read(at offset: Int64, length: Int) -> [UInt8] {
        if let memory {
            guard offset < Int64(memory.count) else { return [] }
            let start = memory.startIndex + Int(offset)
            return Array(memory[start..<min(memory.endIndex, start + length)])
        }
        guard let handle else { return [] }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return [UInt8](try handle.read(upToCount: length) ?? Data())
        } catch {
            return []
        }
    }
}
