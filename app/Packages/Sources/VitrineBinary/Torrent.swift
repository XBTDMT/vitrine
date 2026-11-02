import CryptoKit
import Foundation

/// A BitTorrent metainfo file (`.torrent`, BEP 3; BEP 52's version 2 file tree; hybrids carry both). Read with our
/// own bencode parser; the info-hash is computed locally (SHA-1 of the exact `info` bytes for v1, SHA-256 for v2).
/// Nothing is fetched: trackers and web seeds are listed, never contacted. roadmap: S-8
public struct TorrentFile: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        /// Folder parts joined with `/`, under the torrent's name for a multi-file torrent. Untrusted, like any
        /// archive path: it may climb out with `..`.
        public let path: String
        public let size: Int64
        /// BEP 47 padding files (`attr` contains `p`), which clients never write to disk.
        public let isPadding: Bool
    }

    public enum Version: String, Sendable, Equatable { case v1 = "v1", v2 = "v2", hybrid = "hybrid (v1 and v2)" }

    public let name: String?
    public let files: [File]
    /// More files were declared than were listed (`BinaryLimits.maxXarMembers` is the cap).
    public let filesTruncated: Bool
    /// Bytes of every listed file except padding. File lengths are the torrent's own numbers: the sum stops at
    /// Int64.max rather than wrapping to a negative or small total.
    public var totalSize: Int64 {
        files.filter { !$0.isPadding }.reduce(Int64(0)) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(file.size)
            return overflow ? .max : sum
        }
    }
    public let pieceLength: Int64?
    /// v1 pieces (`pieces` holds 20 bytes per piece).
    public let pieceCount: Int?
    /// `announce` then every `announce-list` tier, in order, without repeats.
    public let trackers: [String]
    /// `url-list` (BEP 19) web seeds.
    public let webSeeds: [String]
    public let createdBy: String?
    public let creationDate: Date?
    public let comment: String?
    /// `private = 1` (BEP 27): only the listed trackers may be used, no DHT or peer exchange.
    public let isPrivate: Bool
    public let source: String?
    public let version: Version
    /// Hex SHA-1 of the bencoded `info` dictionary, for v1 and hybrid torrents.
    public let infoHashV1: String?
    /// Hex SHA-256 of the bencoded `info` dictionary, for v2 and hybrid torrents.
    public let infoHashV2: String?
    /// The magnet link the info-hash gives (made here; nothing is opened).
    public var magnetLink: String? {
        let xt = infoHashV1.map { "urn:btih:\($0)" } ?? infoHashV2.map { "urn:btmh:1220\($0)" }
        return xt.map { "magnet:?xt=\($0)" }
    }
}

/// Reads a `.torrent` from a file or bytes, under `BinaryLimits.maxPropertyListBytes`. roadmap: S-8
public enum TorrentReader {
    public static func read(contentsOf url: URL, limits: BinaryLimits = .default) throws -> TorrentFile {
        let source = try BinaryFileSource(url: url)
        guard source.size <= Int64(limits.maxPropertyListBytes) else {
            throw BinaryError.unsupported("the torrent is \(source.size) bytes, more than the \(limits.maxPropertyListBytes)-byte cap")
        }
        return try read(bytes: try source.exactly(Int(source.size), at: 0, "the torrent"), limits: limits)
    }

    public static func read(bytes: [UInt8], limits: BinaryLimits = .default) throws -> TorrentFile {
        var parser = Bencode.Parser(bytes: bytes)
        let root = try parser.parseRoot()
        guard case .dictionary(let top) = root else { throw BinaryError.notRecognized("a torrent (no top-level dictionary)") }
        guard let infoValue = top["info"], case .dictionary(let info) = infoValue, let infoRange = parser.infoRange else {
            throw BinaryError.notRecognized("a torrent (no info dictionary)")
        }
        let infoBytes = Array(bytes[infoRange])
        let metaVersion = info["meta version"]?.integer ?? 1
        let hasV1 = info["pieces"] != nil
        let hasV2 = metaVersion == 2 && info["file tree"] != nil
        let version: TorrentFile.Version = hasV1 && hasV2 ? .hybrid : (hasV2 ? .v2 : .v1)

        let name = info["name.utf-8"]?.text ?? info["name"]?.text
        var files: [TorrentFile.File] = []
        var truncated = false
        let cap = limits.maxXarMembers
        if let list = info["files"]?.list {                                        // v1 multi-file
            for item in list {
                guard files.count < cap else { truncated = true; break }
                guard case .dictionary(let f) = item else { continue }
                let parts = (f["path.utf-8"]?.list ?? f["path"]?.list ?? []).compactMap(\.text)
                let path = ([name ?? ""] + parts).filter { !$0.isEmpty }.joined(separator: "/")
                files.append(.init(path: path, size: max(0, f["length"]?.integer ?? 0),
                                   isPadding: f["attr"]?.text?.contains("p") == true))
            }
        } else if hasV2, case .dictionary(let tree)? = info["file tree"] {         // v2 file tree
            var stack: [(prefix: [String], node: [String: Bencode.Value])] = [([name ?? ""].filter { !$0.isEmpty }, tree)]
            while let (prefix, node) = stack.popLast() {
                for key in node.keys.sorted().reversed() {
                    guard case .dictionary(let child)? = node[key] else { continue }
                    if key.isEmpty {
                        guard files.count < cap else { truncated = true; break }
                        files.append(.init(path: prefix.joined(separator: "/"), size: max(0, child["length"]?.integer ?? 0),
                                           isPadding: child["attr"]?.text?.contains("p") == true))
                    } else if prefix.count < 64 {
                        stack.append((prefix + [key], child))
                    }
                }
                if truncated { break }
            }
            files.sort { $0.path < $1.path }
        } else if let length = info["length"]?.integer {                           // v1 single file
            files.append(.init(path: name ?? "file", size: max(0, length), isPadding: false))
        }

        var trackers: [String] = []
        func addTracker(_ t: String?) { if let t, !t.isEmpty, !trackers.contains(t) { trackers.append(t) } }
        addTracker(top["announce"]?.text)
        for tier in top["announce-list"]?.list ?? [] { for t in tier.list ?? [] { addTracker(t.text) } }
        let seeds: [String]
        if let list = top["url-list"]?.list { seeds = list.compactMap(\.text) } else { seeds = top["url-list"]?.text.map { [$0] } ?? [] }

        let piecesLength = info["pieces"]?.bytes?.count
        return TorrentFile(
            name: name, files: files, filesTruncated: truncated, pieceLength: info["piece length"]?.integer,
            pieceCount: piecesLength.map { $0 / 20 }, trackers: Array(trackers.prefix(200)), webSeeds: Array(seeds.prefix(200)),
            createdBy: top["created by"]?.text, creationDate: top["creation date"]?.integer.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            comment: top["comment.utf-8"]?.text ?? top["comment"]?.text, isPrivate: info["private"]?.integer == 1,
            source: info["source"]?.text, version: version,
            infoHashV1: hasV1 || !hasV2 ? Array(Insecure.SHA1.hash(data: infoBytes)).hexString : nil,
            infoHashV2: hasV2 ? Array(SHA256.hash(data: infoBytes)).hexString : nil)
    }
}

/// Bencode (BEP 3): integers `i…e`, byte strings `<length>:<bytes>`, lists `l…e`, dictionaries `d…e` with byte-
/// string keys. The parser is bounded (nesting depth, element count, the input's own length) and records where the
/// top-level `info` value lies, because the info-hash is taken over those exact bytes. roadmap: S-8
enum Bencode {
    indirect enum Value: Sendable, Equatable {
        case integer(Int64)
        case bytes([UInt8])
        case list([Value])
        case dictionary([String: Value])

        var integer: Int64? { if case .integer(let i) = self { i } else { nil } }
        var bytes: [UInt8]? { if case .bytes(let b) = self { b } else { nil } }
        var list: [Value]? { if case .list(let l) = self { l } else { nil } }
        /// A byte string as text: UTF-8 when valid, else Latin-1 so every byte stays visible.
        var text: String? {
            guard case .bytes(let b) = self else { return nil }
            return String(validating: b, as: UTF8.self) ?? String(b.map { Character(Unicode.Scalar($0)) })
        }
    }

    struct Parser {
        let bytes: [UInt8]
        var index = 0
        var budget = 2_000_000
        static let maxDepth = 128
        private(set) var infoRange: Range<Int>?

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func parseRoot() throws -> Value {
            let value = try parse(depth: 0)
            return value
        }

        private mutating func parse(depth: Int) throws -> Value {
            guard depth < Self.maxDepth else { throw BinaryError.malformed("the torrent nests deeper than \(Self.maxDepth) levels") }
            budget -= 1
            guard budget > 0 else { throw BinaryError.unsupported("the torrent has too many elements") }
            guard index < bytes.count else { throw BinaryError.truncated("the torrent ends early") }
            switch bytes[index] {
            case UInt8(ascii: "i"):
                index += 1
                let end = try find(UInt8(ascii: "e"))
                guard let n = Int64(String(decoding: bytes[index..<end], as: UTF8.self)) else {
                    throw BinaryError.malformed("a bencoded integer is not a number")
                }
                index = end + 1
                return .integer(n)
            case UInt8(ascii: "l"):
                index += 1
                var items: [Value] = []
                while true {
                    guard index < bytes.count else { throw BinaryError.truncated("a list ends early") }
                    if bytes[index] == UInt8(ascii: "e") { index += 1; break }
                    items.append(try parse(depth: depth + 1))
                }
                return .list(items)
            case UInt8(ascii: "d"):
                index += 1
                var dict: [String: Value] = [:]
                while true {
                    guard index < bytes.count else { throw BinaryError.truncated("a dictionary ends early") }
                    if bytes[index] == UInt8(ascii: "e") { index += 1; break }
                    guard case .bytes(let keyBytes) = try parse(depth: depth + 1) else {
                        throw BinaryError.malformed("a dictionary key is not a string")
                    }
                    let key = String(decoding: keyBytes, as: UTF8.self)
                    let start = index
                    let value = try parse(depth: depth + 1)
                    if depth == 0, key == "info", infoRange == nil { infoRange = start..<index }
                    if dict[key] == nil { dict[key] = value }
                }
                return .dictionary(dict)
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                let colon = try find(UInt8(ascii: ":"))
                // The length is the file's own number (up to 23 digits): compared with what is left after the
                // colon, never added to an index, so Int.max reads as truncation instead of trapping.
                guard let length = Int(String(decoding: bytes[index..<colon], as: UTF8.self)), length >= 0,
                      length <= bytes.count - (colon + 1) else {
                    throw BinaryError.truncated("a byte string runs past the end of the torrent")
                }
                index = colon + 1 + length
                return .bytes(Array(bytes[(colon + 1)..<index]))
            default:
                throw BinaryError.malformed("unexpected byte \(bytes[index]) at \(index)")
            }
        }

        private func find(_ byte: UInt8) throws -> Int {
            // Numbers are short; a run of 24 digits without its terminator is damage, not a number.
            let limit = min(bytes.count, index + 24)
            guard let i = bytes[index..<limit].firstIndex(of: byte) else { throw BinaryError.malformed("a bencoded number is unterminated") }
            return i
        }
    }
}
