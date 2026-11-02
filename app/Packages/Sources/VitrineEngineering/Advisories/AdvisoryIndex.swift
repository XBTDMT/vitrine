import Foundation

/// A compact on-disk index of one OSV ecosystem's advisories (A-12, G-26): built by the host app from the records in
/// OSV's `<ECOSYSTEM>/all.zip`, written once, then opened by the sandboxed preview for every lockfile it shows. The
/// file is memory-mapped and holds a sorted package table, so opening it reads only a header and each lookup decodes
/// only the one package's entries. Nothing here touches the network or any file except the URL it is given.
/// roadmap: S-22
public struct AdvisoryIndex: Sendable {
    /// What an index was built from and when, so the card can date every hint honestly. roadmap: S-22
    public struct Meta: Sendable, Equatable, Codable {
        public var ecosystem: OSVEcosystem
        public var builtAt: Date
        /// The zip's Last-Modified, passed in by the downloader.
        public var sourceLastModified: Date?
        /// Records indexed (withdrawn ones and ones without an entry for this ecosystem are not counted).
        public var records: Int
        /// Distinct package names with at least one advisory.
        public var packages: Int
        public var formatVersion: Int

        public init(ecosystem: OSVEcosystem, builtAt: Date, sourceLastModified: Date?, records: Int, packages: Int, formatVersion: Int) {
            self.ecosystem = ecosystem
            self.builtAt = builtAt
            self.sourceLastModified = sourceLastModified
            self.records = records
            self.packages = packages
            self.formatVersion = formatVersion
        }
    }

    /// Why an index file could not be opened or written. roadmap: S-22
    public enum IndexError: Error, Equatable, Sendable {
        /// Not an advisory index, or cut short.
        case notAnIndex
        /// Written by a newer or older format; the host app rebuilds it.
        case unsupportedFormat(Int)
        /// The tables point outside the file.
        case damaged
    }

    /// The most matches `matches(_:)` returns.
    public static let maxMatches = 200

    public private(set) var meta: Meta
    /// Records that could not be read during build.
    public private(set) var skippedRecords: Int

    /// The whole file image (memory-mapped after `read`), and where its tables start.
    private let image: Data
    private let packageCount: Int
    private let advisoryCount: Int
    private let packageTable: Int
    private let advisoryTable: Int
    private let blob: Int
    private let blobLength: Int

    private struct StoredMeta: Codable {
        var meta: Meta
        var skippedRecords: Int
    }

    // MARK: Build

    /// Builds from OSV JSON records (each element is one record's bytes, as found in `<ECOSYSTEM>/all.zip`).
    /// Records with `withdrawn` set, or with no `affected` entry for this ecosystem, are skipped; malformed records
    /// are counted and skipped.
    public static func build(ecosystem: OSVEcosystem, records: some Sequence<Data>, sourceLastModified: Date?) -> AdvisoryIndex {
        var advisories: [Advisory] = []
        var byName: [String: [(advisory: Int, affected: OSVAffected)]] = [:]
        var skipped = 0
        for data in records {
            switch OSVRecordReader.read(data, ecosystem: ecosystem) {
            case .record(let record):
                let number = advisories.count
                advisories.append(record.advisory)
                for affected in record.affected { byName[affected.name, default: []].append((number, affected)) }
            case .notApplicable:
                continue
            case .unreadable:
                skipped += 1
            }
        }
        let meta = Meta(ecosystem: ecosystem, builtAt: Date(), sourceLastModified: sourceLastModified,
                        records: advisories.count, packages: byName.count, formatVersion: Int(AdvisoryIndexFormat.version))
        let image = encode(meta: StoredMeta(meta: meta, skippedRecords: skipped), advisories: advisories, byName: byName)
        // The image was just made by `encode`, so opening it cannot fail; the fallback keeps the signature total.
        return (try? AdvisoryIndex(image: image)) ?? AdvisoryIndex(empty: meta, skipped: skipped)
    }

    private static func encode(meta: StoredMeta, advisories: [Advisory],
                               byName: [String: [(advisory: Int, affected: OSVAffected)]]) -> Data {
        let names = byName.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var blob = AdvisoryByteWriter()
        var packageRows = AdvisoryByteWriter()
        for name in names {
            let nameOffset = blob.bytes.count
            blob.bytes.append(contentsOf: name.utf8)
            let nameLength = blob.bytes.count - nameOffset
            let entriesOffset = blob.bytes.count
            blob.entries(byName[name] ?? [])
            packageRows.u64(UInt64(nameOffset))
            packageRows.u64(UInt64(entriesOffset))
            packageRows.u32(UInt32(clamping: nameLength))
            packageRows.u32(UInt32(clamping: blob.bytes.count - entriesOffset))
        }
        var advisoryRows = AdvisoryByteWriter()
        for a in advisories {
            let offset = blob.bytes.count
            blob.advisory(a)
            advisoryRows.u64(UInt64(offset))
            advisoryRows.u32(UInt32(clamping: blob.bytes.count - offset))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        let metaBytes = (try? encoder.encode(meta)) ?? Data()

        let packageTable = AdvisoryIndexFormat.headerSize + metaBytes.count
        let advisoryTable = packageTable + packageRows.bytes.count
        let blobOffset = advisoryTable + advisoryRows.bytes.count
        var out = AdvisoryByteWriter()
        out.bytes.reserveCapacity(blobOffset + blob.bytes.count)
        out.bytes.append(contentsOf: AdvisoryIndexFormat.magic)
        out.u32(AdvisoryIndexFormat.version)
        out.u32(UInt32(metaBytes.count))
        out.u32(UInt32(clamping: names.count))
        out.u32(UInt32(clamping: advisories.count))
        out.u64(UInt64(packageTable))
        out.u64(UInt64(advisoryTable))
        out.u64(UInt64(blobOffset))
        out.u64(UInt64(blob.bytes.count))
        out.bytes.append(contentsOf: [UInt8](repeating: 0, count: AdvisoryIndexFormat.headerSize - out.bytes.count))
        out.bytes.append(contentsOf: metaBytes)
        out.bytes.append(contentsOf: packageRows.bytes)
        out.bytes.append(contentsOf: advisoryRows.bytes)
        out.bytes.append(contentsOf: blob.bytes)
        return Data(out.bytes)
    }

    // MARK: Write and read

    /// Writes the index atomically (a temporary file renamed over `url`).
    public func write(to url: URL) throws {
        try image.write(to: url, options: .atomic)
    }

    /// Opens an index memory-mapped: reads the header and meta, checks that every table lies inside the file, and
    /// decodes nothing else until a lookup asks.
    public static func read(from url: URL) throws -> AdvisoryIndex {
        try AdvisoryIndex(image: Data(contentsOf: url, options: .alwaysMapped))
    }

    private init(image: Data) throws {
        let header = AdvisoryIndexFormat.headerSize
        guard image.count >= header else { throw IndexError.notAnIndex }
        let fields: (UInt32, UInt32, UInt32, UInt32, UInt64, UInt64, UInt64, UInt64)? = image.withUnsafeBytes { raw in
            guard raw.prefix(8).elementsEqual(AdvisoryIndexFormat.magic) else { return nil }
            return (AdvisoryByteReader.u32(raw, 8), AdvisoryByteReader.u32(raw, 12), AdvisoryByteReader.u32(raw, 16),
                    AdvisoryByteReader.u32(raw, 20), AdvisoryByteReader.u64(raw, 24), AdvisoryByteReader.u64(raw, 32),
                    AdvisoryByteReader.u64(raw, 40), AdvisoryByteReader.u64(raw, 48))
        }
        guard let (version, metaLength, packages, advisories, pTable, aTable, blobAt, blobLen) = fields else {
            throw IndexError.notAnIndex
        }
        guard version == AdvisoryIndexFormat.version else { throw IndexError.unsupportedFormat(Int(version)) }
        let size = UInt64(image.count)
        let metaEnd = UInt64(header) + UInt64(metaLength)
        guard metaEnd <= size,
              pTable >= metaEnd, pTable <= size, UInt64(packages) * UInt64(AdvisoryIndexFormat.packageRowSize) <= size - pTable,
              aTable >= pTable, aTable <= size, UInt64(advisories) * UInt64(AdvisoryIndexFormat.advisoryRowSize) <= size - aTable,
              blobAt <= size, blobLen <= size - blobAt
        else { throw IndexError.damaged }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let stored = try? decoder.decode(StoredMeta.self, from: image.subdata(in: header..<Int(metaEnd))) else {
            throw IndexError.damaged
        }
        self.image = image
        self.meta = stored.meta
        self.skippedRecords = stored.skippedRecords
        self.packageCount = Int(packages)
        self.advisoryCount = Int(advisories)
        self.packageTable = Int(pTable)
        self.advisoryTable = Int(aTable)
        self.blob = Int(blobAt)
        self.blobLength = Int(blobLen)
    }

    private init(empty meta: Meta, skipped: Int) {
        self.image = Data()
        self.meta = meta
        self.skippedRecords = skipped
        packageCount = 0
        advisoryCount = 0
        packageTable = 0
        advisoryTable = 0
        blob = 0
        blobLength = 0
    }

    // MARK: Lookup

    /// The advisories that affect `version` of the package `name` (normalised for this index's ecosystem), malicious
    /// first, then severity descending; empty when the database knows none.
    public func advisories(name: String, version: String) -> [Advisory] {
        let eco = meta.ecosystem
        return advisories(key: eco.normalizedName(name), version: eco.normalizedVersion(version))
    }

    private func advisories(key: String, version: String) -> [Advisory] {
        guard !key.isEmpty, !version.isEmpty, packageCount > 0 else { return [] }
        let eco = meta.ecosystem
        return image.withUnsafeBytes { raw -> [Advisory] in
            guard let row = findPackage(raw, key: key) else { return [] }
            let entriesOffset = Int(AdvisoryByteReader.u64(raw, row + 8))
            let entriesLength = Int(AdvisoryByteReader.u32(raw, row + 20))
            guard entriesOffset <= blobLength, entriesLength <= blobLength - entriesOffset else { return [] }
            var reader = AdvisoryByteReader(raw, from: blob + entriesOffset, length: entriesLength)
            guard let entries = reader.entries() else { return [] }

            var fixedByAdvisory: [Int: [String]] = [:]
            for (number, affected) in entries where number < advisoryCount {
                let listed = affected.versions.contains { VersionOrdering.equal($0, version, ecosystem: eco) }
                let inRange = affected.ranges.contains { range in
                    // ECOSYSTEM ranges stand aside when the record enumerates the affected versions.
                    if range.kind == .ecosystem, !affected.versions.isEmpty { return false }
                    return OSVRangeEvaluator.isAffected(version, range: range, ecosystem: eco)
                }
                guard listed || inRange else { continue }
                let fixed = affected.ranges.flatMap { $0.events.filter { $0.kind == .fixed }.map(\.version) }
                fixedByAdvisory[number, default: []].append(contentsOf: fixed)
            }
            var out: [Advisory] = []
            for (number, fixed) in fixedByAdvisory {
                let at = advisoryTable + number * AdvisoryIndexFormat.advisoryRowSize
                let offset = Int(AdvisoryByteReader.u64(raw, at))
                let length = Int(AdvisoryByteReader.u32(raw, at + 8))
                guard offset <= blobLength, length <= blobLength - offset else { continue }
                var r = AdvisoryByteReader(raw, from: blob + offset, length: length)
                guard var advisory = r.advisory() else { continue }
                advisory.fixed = Array(VersionOrdering.sortedUnique(fixed, ecosystem: eco).prefix(5))
                out.append(advisory)
            }
            return out.sorted(by: Advisory.ordered)
        }
    }

    /// Binary search over the sorted package table; returns the row's byte offset.
    private func findPackage(_ raw: UnsafeRawBufferPointer, key: String) -> Int? {
        var key = key
        return key.withUTF8 { k -> Int? in
            var lo = 0, hi = packageCount - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let row = packageTable + mid * AdvisoryIndexFormat.packageRowSize
                let nameOffset = Int(AdvisoryByteReader.u64(raw, row))
                let nameLength = Int(AdvisoryByteReader.u32(raw, row + 16))
                guard nameOffset <= blobLength, nameLength <= blobLength - nameOffset else { return nil }
                let name = UnsafeRawBufferPointer(rebasing: raw[(blob + nameOffset)..<(blob + nameOffset + nameLength)])
                let c = Self.compareBytes(name, UnsafeRawBufferPointer(k))
                if c == 0 { return row }
                if c < 0 { lo = mid + 1 } else { hi = mid - 1 }
            }
            return nil
        }
    }

    private static func compareBytes(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Int {
        let n = min(a.count, b.count)
        if n > 0, let pa = a.baseAddress, let pb = b.baseAddress {
            let c = memcmp(pa, pb, n)
            if c != 0 { return c < 0 ? -1 : 1 }
        }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    /// Every package name in the index, in table order, read one row at a time for `body`; `body` returns false to
    /// stop. Used for SwiftPM pins, whose lockfile summary names a package by identity rather than by URL.
    private func forEachName(_ body: (String) -> Bool) {
        image.withUnsafeBytes { raw in
            for k in 0..<packageCount {
                let row = packageTable + k * AdvisoryIndexFormat.packageRowSize
                let nameOffset = Int(AdvisoryByteReader.u64(raw, row))
                let nameLength = Int(AdvisoryByteReader.u32(raw, row + 16))
                guard nameOffset <= blobLength, nameLength <= blobLength - nameOffset else { return }
                let bytes = UnsafeRawBufferPointer(rebasing: raw[(blob + nameOffset)..<(blob + nameOffset + nameLength)])
                if !body(String(decoding: bytes, as: UTF8.self)) { return }
            }
        }
    }

    // MARK: Lockfiles

    /// The locked packages with advisories, capped at 200 matches; packages without a version are skipped. A
    /// lockfile from another ecosystem matches nothing. Each name and version pair is looked up once; the matches
    /// are ordered worst first (malicious, then highest severity), lockfile order breaking ties, before the cap.
    ///
    /// SwiftPM pins match by their repository URL (`Package.locator`) exactly. A pin without one (an older reader's
    /// summary) falls back to its identity: the SwiftURL packages whose last path component is that identity and,
    /// when the summary names a host, whose host is that host.
    public func matches(_ summary: LockfileSummary) -> [AdvisoryMatch] {
        guard packageCount > 0, OSVEcosystem.forLockfile(summary.ecosystem) == meta.ecosystem else { return [] }
        let eco = meta.ecosystem
        var identityKeys: [String: [String]]?
        if eco == .swiftURL {
            var map: [String: [String]] = [:]
            forEachName { name in
                if let last = name.split(separator: "/").last { map[String(last), default: []].append(name) }
                return true
            }
            identityKeys = map
        }
        var seen = Set<String>()
        var found: [(order: Int, match: AdvisoryMatch)] = []
        for (position, package) in summary.packages.enumerated() {
            guard let rawVersion = package.version else { continue }
            let version = eco.normalizedVersion(rawVersion)
            guard !version.isEmpty, seen.insert("\(package.name)\u{0}\(version)").inserted else { continue }
            var advisories: [Advisory]
            if eco == .swiftURL, let locator = package.locator {
                // The pin's repository URL: an exact key, no guessing.
                advisories = self.advisories(key: eco.normalizedName(locator), version: version)
            } else if let identityKeys, !package.name.contains("/") {
                let identity = eco.normalizedName(package.name)
                let host = package.source.map { $0.lowercased() }
                var merged: [String: Advisory] = [:]
                for key in identityKeys[identity] ?? [] {
                    if let host, key.split(separator: "/").first.map(String.init) != host { continue }
                    for a in self.advisories(key: key, version: version) where merged[a.id] == nil { merged[a.id] = a }
                }
                advisories = merged.values.sorted(by: Advisory.ordered)
            } else {
                advisories = self.advisories(key: eco.normalizedName(package.name), version: version)
            }
            if !advisories.isEmpty {
                found.append((position, AdvisoryMatch(package: package.name, version: rawVersion, advisories: advisories)))
            }
        }
        found.sort { a, b in
            let x = a.match.advisories[0], y = b.match.advisories[0]
            if x.isMalicious != y.isMalicious { return x.isMalicious }
            if x.severity != y.severity { return x.severity > y.severity }
            return a.order < b.order
        }
        return found.prefix(Self.maxMatches).map(\.match)
    }
}
