import Compression
import CryptoKit
import Foundation
@testable import VitrineGit

/// Builds repositories for the tests without git: loose objects zlib-compressed here, packs and their `.idx`
/// written byte by byte, and the saved sample (`Fixtures/lumen-site`, invented content, its `.git` stored as
/// `dot-git`) copied into a temporary folder and renamed. No test runs git. roadmap: S-9
enum GitFixtures {
    /// A fresh copy of the saved sample repository, with `.git` and `.gitignore` restored to their real names.
    static func sample() throws -> URL {
        guard let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw GitError.unreadable("the Fixtures folder is missing from the test bundle")
        }
        let root = temporaryFolder("vt-git-sample")
        let repo = root.appendingPathComponent("lumen-site")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("lumen-site"), to: repo)
        try FileManager.default.moveItem(at: repo.appendingPathComponent("dot-git"), to: repo.appendingPathComponent(".git"))
        try FileManager.default.moveItem(at: repo.appendingPathComponent("dot-gitignore"), to: repo.appendingPathComponent(".gitignore"))
        return repo
    }

    static func fixture(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)?.appendingPathComponent(name) else {
            throw GitError.unreadable("missing fixture \(name)")
        }
        return url
    }

    static func temporaryFolder(_ prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: zlib

    static func zlib(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + 1024)
        let n = compression_encode_buffer(&out, out.count, data, data.count, nil, COMPRESSION_ZLIB)
        precondition(n > 0, "the test compressor failed")
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = b << 16 | a
        return [0x78, 0x9C] + out[0..<n] + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
    }

    // MARK: Loose objects

    /// Writes a loose object and returns its name.
    @discardableResult
    static func writeLoose(_ type: String, _ content: [UInt8], objects: URL) throws -> GitObjectID {
        let id = GitObjectID.hash(type: type, content: content)
        let dir = objects.appendingPathComponent(String(id.hex.prefix(2)))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(zlib(Array("\(type) \(content.count)\0".utf8) + content)).write(to: dir.appendingPathComponent(String(id.hex.dropFirst(2))))
        return id
    }

    static func commitText(tree: GitObjectID, parents: [GitObjectID], author: String, seconds: Int, subject: String, extraHeaders: String = "") -> [UInt8] {
        var s = "tree \(tree.hex)\n"
        for p in parents { s += "parent \(p.hex)\n" }
        s += "author \(author) \(seconds) +0200\ncommitter \(author) \(seconds) +0200\n" + extraHeaders + "\n\(subject)\n\nBody text.\n"
        return Array(s.utf8)
    }

    static func treeContent(_ entries: [(mode: String, name: String, id: GitObjectID)]) -> [UInt8] {
        var out: [UInt8] = []
        for e in entries.sorted(by: { $0.name < $1.name }) { out += Array("\(e.mode) \(e.name)\0".utf8) + e.id.bytes }
        return out
    }

    // MARK: Packs

    enum PackEntry {
        case whole(type: Int, content: [UInt8])
        /// A delta against the entry at `baseIndex`, stored as OFS_DELTA.
        case ofs(baseIndex: Int, delta: [UInt8])
        /// A delta against a named object, stored as REF_DELTA.
        case ref(base: GitObjectID, delta: [UInt8])
    }

    static func entryHeader(type: Int, size: Int) -> [UInt8] {
        var out: [UInt8] = []
        var n = size >> 4
        var first = UInt8(type << 4) | UInt8(size & 15)
        if n > 0 { first |= 0x80 }
        out.append(first)
        while n > 0 {
            var b = UInt8(n & 0x7F)
            n >>= 7
            if n > 0 { b |= 0x80 }
            out.append(b)
        }
        return out
    }

    static func offsetEncoding(_ distance: Int) -> [UInt8] {
        var n = distance
        var bytes = [UInt8(n & 0x7F)]
        n >>= 7
        while n > 0 {
            n -= 1
            bytes.insert(0x80 | UInt8(n & 0x7F), at: 0)
            n >>= 7
        }
        return bytes
    }

    static func sizeVarint(_ value: Int) -> [UInt8] {
        var n = value, out: [UInt8] = []
        repeat {
            var b = UInt8(n & 0x7F); n >>= 7
            if n > 0 { b |= 0x80 }
            out.append(b)
        } while n > 0
        return out
    }

    /// A delta that copies `base[copy]` then inserts `insert`.
    static func delta(base: [UInt8], copy: Range<Int>, insert: [UInt8], resultSize: Int? = nil) -> [UInt8] {
        var d = sizeVarint(base.count) + sizeVarint(resultSize ?? (copy.count + insert.count))
        var op: UInt8 = 0x80
        var args: [UInt8] = []
        for i in 0..<4 where (copy.lowerBound >> (8 * i)) & 0xFF != 0 { op |= 1 << i; args.append(UInt8((copy.lowerBound >> (8 * i)) & 0xFF)) }
        for i in 0..<3 where (copy.count >> (8 * i)) & 0xFF != 0 { op |= 1 << (4 + i); args.append(UInt8((copy.count >> (8 * i)) & 0xFF)) }
        d += [op] + args
        if !insert.isEmpty { d += [UInt8(insert.count)] + insert }
        return d
    }

    /// Writes `pack-<name>.pack` and its v2 `.idx` into `objects/pack`; `ids` names each entry (the id of the
    /// object it resolves to), which the test knows.
    static func writePack(_ entries: [PackEntry], ids: [GitObjectID], objects: URL, name: String = "test") throws {
        var body: [UInt8] = Array("PACK".utf8) + be32(2) + be32(UInt32(entries.count))
        var offsets: [Int] = []
        for e in entries {
            offsets.append(body.count)
            switch e {
            case .whole(let type, let content):
                body += entryHeader(type: type, size: content.count) + zlib(content)
            case .ofs(let baseIndex, let delta):
                body += entryHeader(type: 6, size: delta.count) + offsetEncoding(offsets.last! - offsets[baseIndex]) + zlib(delta)
            case .ref(let base, let delta):
                body += entryHeader(type: 7, size: delta.count) + base.bytes + zlib(delta)
            }
        }
        let packSum = Array(Insecure.SHA1.hash(data: body))
        body += packSum
        let dir = objects.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(body).write(to: dir.appendingPathComponent("pack-\(name).pack"))

        let sorted = zip(ids, offsets).sorted { $0.0 < $1.0 }
        var idx: [UInt8] = [0xFF, 0x74, 0x4F, 0x63] + be32(2)
        for b in 0..<256 { idx += be32(UInt32(sorted.filter { Int($0.0.bytes[0]) <= b }.count)) }
        for (id, _) in sorted { idx += id.bytes }
        for _ in sorted { idx += be32(0) }                                   // CRCs are not checked
        for (_, offset) in sorted { idx += be32(UInt32(offset)) }
        idx += packSum
        idx += Array(Insecure.SHA1.hash(data: idx))
        try Data(idx).write(to: dir.appendingPathComponent("pack-\(name).idx"))
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

    // MARK: Index files

    struct IndexItem {
        var path: String
        var id: GitObjectID
        var size: UInt32
        var mtime: UInt32 = 1
        var mode: UInt32 = 0o100644
        var stage: Int = 0
        var intentToAdd = false
    }

    /// An index in version 2, 3 or 4, written by hand.
    static func index(_ items: [IndexItem], version: Int) -> [UInt8] {
        var out: [UInt8] = Array("DIRC".utf8) + be32(UInt32(version)) + be32(UInt32(items.count))
        var previous: [UInt8] = []
        for item in items.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            let start = out.count
            out += be32(item.mtime) + be32(0) + be32(item.mtime) + be32(0)          // ctime, mtime
            out += be32(1) + be32(1) + be32(item.mode) + be32(501) + be32(20) + be32(item.size)
            out += item.id.bytes
            let path = Array(item.path.utf8)
            var flags = UInt16(min(path.count, 0xFFF)) | UInt16(item.stage << 12)
            let extended = item.intentToAdd
            if extended { flags |= 0x4000 }
            out += be16(flags)
            if extended { out += be16(0x2000) }
            if version == 4 {
                let common = zip(previous, path).prefix { $0 == $1 }.count
                out += offsetEncoding(previous.count - common) + path[common...] + [0]
            } else {
                out += path
                let length = out.count - start
                out += [UInt8](repeating: 0, count: ((length + 8) & ~7) - length)
            }
            previous = path
        }
        out += Array(Insecure.SHA1.hash(data: out))
        return out
    }
}
