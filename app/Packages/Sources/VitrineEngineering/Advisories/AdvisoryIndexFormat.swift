import Foundation

// The advisory index file (A-12, G-26), little-endian throughout:
//
//   header   64 bytes   magic "VTADVIDX", formatVersion u32, metaLength u32, packageCount u32, advisoryCount u32,
//                       packageTableOffset u64, advisoryTableOffset u64, blobOffset u64, blobLength u64, 8 zero bytes
//   meta     JSON       Meta and the build's skippedRecords
//   packages 24 × n     nameOffset u64, entriesOffset u64, nameLength u32, entriesLength u32, sorted by the name's
//                       UTF-8 bytes (offsets are into the blob)
//   advs     12 × m     offset u64, length u32 into the blob
//   blob                names, each package's affected entries and each advisory, varint-encoded
//
// A package's entries: count, then per entry the advisory number, the enumerated versions and the ranges (kind byte,
// events as kind byte + version). An advisory: id, aliases, summary (flag + text), severity byte, malicious byte.
// Lookups binary-search the package table and decode only the entries and advisories of the one package asked for.
// roadmap: S-22

enum AdvisoryIndexFormat {
    static let magic: [UInt8] = Array("VTADVIDX".utf8)
    static let version: UInt32 = 1
    static let headerSize = 64
    static let packageRowSize = 24
    static let advisoryRowSize = 12
}

/// Appends little-endian integers, LEB128 varints and length-prefixed strings. roadmap: S-22
struct AdvisoryByteWriter {
    var bytes: [UInt8] = []

    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func byte(_ v: UInt8) { bytes.append(v) }
    mutating func varint(_ value: Int) {
        var v = UInt64(max(0, value))
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }
    mutating func string(_ s: String) {
        let utf8 = Array(s.utf8)
        varint(utf8.count)
        bytes.append(contentsOf: utf8)
    }
}

/// Reads what `AdvisoryByteWriter` wrote from a bounded window of bytes; every read checks its bounds and returns
/// nil past the end, so a damaged file yields no advisories instead of a crash. roadmap: S-22
struct AdvisoryByteReader {
    let base: UnsafeRawBufferPointer
    var at: Int
    let end: Int

    init(_ base: UnsafeRawBufferPointer, from: Int, length: Int) {
        self.base = base
        self.at = max(0, from)
        self.end = min(base.count, max(0, from) + max(0, length))
    }

    mutating func byte() -> UInt8? {
        guard at < end else { return nil }
        defer { at += 1 }
        return base[at]
    }

    mutating func varint() -> Int? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 63 {
            guard let b = byte() else { return nil }
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result <= UInt64(Int32.max) ? Int(result) : nil }
            shift += 7
        }
        return nil
    }

    mutating func string() -> String? {
        guard let n = varint(), n <= end - at else { return nil }
        defer { at += n }
        return String(decoding: UnsafeRawBufferPointer(rebasing: base[at..<(at + n)]), as: UTF8.self)
    }

    static func u32(_ base: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    static func u64(_ base: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        UInt64(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
}

extension AdvisoryByteWriter {
    mutating func advisory(_ a: Advisory) {
        string(a.id)
        varint(a.aliases.count)
        for alias in a.aliases { string(alias) }
        if let s = a.summary { byte(1); string(s) } else { byte(0) }
        byte(UInt8(a.severity.rank))
        byte(a.isMalicious ? 1 : 0)
    }

    mutating func entries(_ list: [(advisory: Int, affected: OSVAffected)]) {
        varint(list.count)
        for (adv, affected) in list {
            varint(adv)
            varint(affected.versions.count)
            for v in affected.versions { string(v) }
            varint(affected.ranges.count)
            for r in affected.ranges {
                byte(r.kind.rawValue)
                varint(r.events.count)
                for e in r.events { byte(e.kind.rawValue); string(e.version) }
            }
        }
    }
}

extension AdvisoryByteReader {
    static let severities: [Advisory.Severity] = [.unknown, .low, .moderate, .high, .critical]

    mutating func advisory() -> Advisory? {
        guard let id = string(), let aliasCount = varint(), aliasCount <= OSVRecordReader.maxAliases else { return nil }
        var aliases: [String] = []
        for _ in 0..<aliasCount { guard let a = string() else { return nil }; aliases.append(a) }
        guard let hasSummary = byte() else { return nil }
        var summary: String?
        if hasSummary == 1 { guard let s = string() else { return nil }; summary = s }
        guard let sev = byte(), Int(sev) < Self.severities.count, let mal = byte() else { return nil }
        return Advisory(id: id, aliases: aliases, summary: summary, severity: Self.severities[Int(sev)],
                        isMalicious: mal == 1, fixed: [])
    }

    mutating func entries() -> [(advisory: Int, affected: OSVAffected)]? {
        guard let count = varint(), count <= end - at else { return nil }
        var out: [(advisory: Int, affected: OSVAffected)] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let adv = varint(), let vCount = varint(), vCount <= end - at else { return nil }
            var versions: [String] = []
            versions.reserveCapacity(vCount)
            for _ in 0..<vCount { guard let v = string() else { return nil }; versions.append(v) }
            guard let rCount = varint(), rCount <= end - at else { return nil }
            var ranges: [OSVRange] = []
            for _ in 0..<rCount {
                guard let k = byte(), let kind = OSVRange.Kind(rawValue: k), let eCount = varint(), eCount <= end - at else { return nil }
                var events: [OSVEvent] = []
                for _ in 0..<eCount {
                    guard let ek = byte(), let ekind = OSVEvent.Kind(rawValue: ek), let v = string() else { return nil }
                    events.append(OSVEvent(kind: ekind, version: v))
                }
                ranges.append(OSVRange(kind: kind, events: events))
            }
            out.append((adv, OSVAffected(name: "", versions: versions, ranges: ranges)))
        }
        return out
    }
}
