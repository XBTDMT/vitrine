import Foundation

/// A disk image (`.dmg`) read from its UDIF trailer — the `koly` block in the last 512 bytes — and the XML property
/// list it points at, whose `blkx` entries describe each partition's chunks. Never attached or mounted. An encrypted
/// image says only that it is encrypted (and its stated cipher parameters): its trailer and partition map are inside
/// the ciphertext.
public struct DiskImage: Sendable, Equatable {
    public enum Container: Sendable, Equatable {
        /// A plain UDIF image.
        case udif
        /// FileVault-style encrypted image, version 2 (`encrcdsa` at the start).
        case encryptedV2(EncryptionHeader)
        /// Encrypted image, version 1 (`cdsaencr` at the end).
        case encryptedV1
        /// Apple Encrypted Archive (`AEA1`), as macOS 15+ `hdiutil` can wrap images.
        case appleEncryptedArchive
    }

    public struct EncryptionHeader: Sendable, Equatable {
        public let version: UInt32
        public let keyBits: UInt32
        public let blockSize: UInt32
        public let encryptedDataSize: UInt64
        public let encryptedDataOffset: UInt64
    }

    public let container: Container
    public let fileSize: Int64
    /// The trailer, for plain images.
    public let trailer: UDIFTrailer?
    public let partitions: [Partition]
    /// The partition list stopped at `BinaryLimits.maxPartitions`.
    public let partitionsTruncated: Bool
    /// The embedded code signature (`codesign` on a disk image), parsed statically.
    public let codeSignature: EmbeddedSignature?
    /// The signature's index lists a ticket slot (`CSSLOT_TICKETSLOT`, where stapling puts a disk image's ticket). Its
    /// bytes are not verified and the slot lies outside the code directory, so anyone can add one: it is never
    /// "notarized". Only the Security framework's `notarized` requirement says that (`SignatureAssessment.notarization`).
    public var hasTicketSlot: Bool { codeSignature?.hasTicketSlot == true }
    public let notes: [String]

    public var isEncrypted: Bool { if case .udif = container { false } else { true } }

    /// The image format `hdiutil` would name from the chunk compression in use: UDZO (zlib), UDBZ (bzip2), ULFO
    /// (LZFSE), ULMO (LZMA), UDRO/UDRW (none) — or nil when the partitions mix methods or say nothing.
    public var inferredFormat: String? {
        let methods = Set(partitions.flatMap(\.compression)).subtracting(["raw", "zero fill", "ignored", "comment"])
        switch methods {
        case ["zlib"]: return "UDZO (zlib)"
        case ["bzip2"]: return "UDBZ (bzip2)"
        case ["LZFSE"]: return "ULFO (LZFSE)"
        case ["LZMA"]: return "ULMO (LZMA)"
        case []: return partitions.isEmpty ? nil : String(localized: "uncompressed (UDRO/UDRW)", bundle: .module, comment: "A disk image's format: not compressed.")
        default: return nil
        }
    }

    public var sectorCount: UInt64? { trailer?.sectorCount }
}

/// The `koly` trailer (UDIFResourceFile), big-endian, 512 bytes.
public struct UDIFTrailer: Sendable, Equatable {
    public let version: UInt32
    public let flags: UInt32
    public let dataForkOffset: UInt64
    public let dataForkLength: UInt64
    public let resourceForkOffset: UInt64
    public let resourceForkLength: UInt64
    public let segmentNumber: UInt32
    public let segmentCount: UInt32
    public let segmentID: UUID
    public let dataChecksumType: ChecksumType
    public let masterChecksumType: ChecksumType
    public let xmlOffset: UInt64
    public let xmlLength: UInt64
    /// Where `codesign` put the image's signature (0 when unsigned). Observed at trailer offset 0x128 on images
    /// this machine's `codesign` signed.
    public let codeSignatureOffset: UInt64
    public let codeSignatureLength: UInt64
    public let imageVariant: UInt32
    public let sectorCount: UInt64

    /// `kUDIFFlagsFlattened` (bit 0): the resource fork is folded into the XML plist.
    public var isFlattened: Bool { flags & 1 != 0 }
    /// `kUDIFFlagsInternetEnabled` (bit 2), long retired.
    public var isInternetEnabled: Bool { flags & 4 != 0 }
    public var isSegmented: Bool { segmentCount > 1 }

    public struct ChecksumType: Sendable, Equatable, CustomStringConvertible {
        public let rawValue: UInt32
        public let bits: UInt32
        public var name: String {
            switch rawValue {
            case 0: String(localized: "none", bundle: .module, comment: "A disk image's checksum type: no checksum.")
            case 2: "CRC-32"
            case 4: "MD5"
            case 5: "SHA-1"
            case 6: "SHA-256"
            case 7: "SHA-384"
            case 8: "SHA-512"
            default: String(localized: "checksum type \(rawValue)", bundle: .module, comment: "A disk image's checksum type, unknown, by number.")
            }
        }
        public var description: String { name }
    }
}

/// One `blkx` entry: a partition of the image and how its data is stored.
public struct Partition: Sendable, Equatable {
    public let name: String
    public let id: Int?
    /// 512-byte sectors the partition covers.
    public let sectorCount: UInt64
    /// Bytes its chunks occupy in the file.
    public let storedBytes: UInt64
    public let chunkCount: Int
    /// The chunk methods in use, in first-seen order (`zlib`, `LZFSE`, `raw`, `zero fill`, …).
    public let compression: [String]
    public var byteCount: UInt64 { sectorCount.multipliedReportingOverflow(by: 512).partialValue }
}

public enum DiskImageReader {
    static let kolyMagic: UInt32 = 0x6B6F_6C79            // "koly"

    public static func read(contentsOf url: URL, limits: BinaryLimits = .default) throws -> DiskImage {
        try read(source: BinaryFileSource(url: url), limits: limits)
    }

    public static func read(source: any BinaryByteSource, limits: BinaryLimits = .default) throws -> DiskImage {
        let head = try source.read(at: 0, count: 80)
        if head.count >= 8, head.prefix(8).elementsEqual("encrcdsa".utf8) {
            var c = ByteCursor(head, at: 8, bigEndian: true, what: "the encryption header")
            let version = try c.u32()
            try c.skip(12)                                    // IV size, mode, algorithm
            let keyBits = try c.u32()
            try c.skip(8 + 16)                                // PRNG algorithm and key size, UUID
            let blockSize = try c.u32()
            let dataSize = try c.u64(), dataOffset = try c.u64()
            let header = DiskImage.EncryptionHeader(version: version, keyBits: keyBits, blockSize: blockSize,
                                                    encryptedDataSize: dataSize, encryptedDataOffset: dataOffset)
            return encrypted(.encryptedV2(header), size: source.size)
        }
        if head.count >= 4, head.prefix(4).elementsEqual("AEA1".utf8) {
            return encrypted(.appleEncryptedArchive, size: source.size)
        }
        guard source.size >= 512 else { throw BinaryError.notRecognized("a disk image (too short for a UDIF trailer)") }
        let tail = try source.exactly(512, at: source.size - 512, "the UDIF trailer")
        if tail.be32(at: 0) != kolyMagic {
            if source.size >= 8, try source.read(at: source.size - 8, count: 8).elementsEqual("cdsaencr".utf8) {
                return encrypted(.encryptedV1, size: source.size)
            }
            throw BinaryError.notRecognized("a UDIF disk image (no koly trailer)")
        }
        let trailer = try parseTrailer(tail)
        var notes: [String] = []
        let trailerStart = UInt64(source.size - 512)
        func inside(_ offset: UInt64, _ length: UInt64) -> Bool {
            offset <= trailerStart && length <= trailerStart - offset
        }
        if !inside(trailer.dataForkOffset, trailer.dataForkLength) {
            notes.append("the data fork the trailer describes runs past the file")
        }

        var partitions: [Partition] = []
        var truncated = false
        if trailer.xmlLength > 0 {
            if !inside(trailer.xmlOffset, trailer.xmlLength) {
                notes.append("the partition list lies outside the file")
            } else if trailer.xmlLength > UInt64(limits.maxDiskImagePlistBytes) {
                notes.append("the partition list (\(trailer.xmlLength) bytes) is larger than the \(limits.maxDiskImagePlistBytes)-byte cap")
            } else {
                do {
                    let xml = try source.exactly(Int(trailer.xmlLength), at: Int64(trailer.xmlOffset), "the partition list")
                    (partitions, truncated) = try parsePartitions(xml, limits: limits)
                } catch let error as BinaryError {
                    notes.append(error.reason)
                }
            }
        } else if trailer.resourceForkLength > 0 {
            notes.append("the partition map is in a resource fork (an old-style image), which is not read")
        }

        let signature = readSignature(source: source, trailer: trailer, limits: limits, notes: &notes)
        return DiskImage(container: .udif, fileSize: source.size, trailer: trailer, partitions: partitions,
                         partitionsTruncated: truncated, codeSignature: signature, notes: notes)
    }

    /// The embedded signature a UDIF trailer points at, read without the partition list. Its bytes are the file's
    /// own and nothing in them is verified.
    static func readSignature(source: any BinaryByteSource, trailer: UDIFTrailer, limits: BinaryLimits,
                              notes: inout [String]) -> EmbeddedSignature? {
        guard trailer.codeSignatureLength > 0 else { return nil }
        let trailerStart = UInt64(source.size - 512)
        guard trailer.codeSignatureOffset <= trailerStart,
              trailer.codeSignatureLength <= trailerStart - trailer.codeSignatureOffset else {
            notes.append("the code signature lies outside the file")
            return nil
        }
        guard trailer.codeSignatureLength <= UInt64(limits.maxSignatureBytes) else {
            notes.append("the code signature is larger than the \(limits.maxSignatureBytes)-byte cap")
            return nil
        }
        do {
            let bytes = try source.exactly(Int(trailer.codeSignatureLength),
                                           at: Int64(trailer.codeSignatureOffset), "the code signature")
            return try EmbeddedSignature.parse(bytes, limits: limits)
        } catch let error as BinaryError {
            notes.append("code signature: \(error.reason)")
        } catch {
            notes.append("code signature: \(error.localizedDescription)")
        }
        return nil
    }

    /// A plain UDIF image's embedded signature alone (the ticket slot lookup); nil when the file is not a plain
    /// UDIF image.
    static func signatureOnly(source: any BinaryByteSource, limits: BinaryLimits = .default) -> (signature: EmbeddedSignature?, notes: [String])? {
        guard source.size >= 512, let tail = try? source.exactly(512, at: source.size - 512, "the UDIF trailer"),
              tail.be32(at: 0) == kolyMagic, let trailer = try? parseTrailer(tail) else { return nil }
        var notes: [String] = []
        let signature = readSignature(source: source, trailer: trailer, limits: limits, notes: &notes)
        return (signature, notes)
    }

    private static func encrypted(_ container: DiskImage.Container, size: Int64) -> DiskImage {
        DiskImage(container: container, fileSize: size, trailer: nil, partitions: [], partitionsTruncated: false,
                  codeSignature: nil, notes: [])
    }

    static func parseTrailer(_ k: [UInt8]) throws -> UDIFTrailer {
        var c = ByteCursor(k, at: 4, bigEndian: true, what: "the UDIF trailer")
        let version = try c.u32()
        let headerSize = try c.u32()
        guard headerSize == 512 else { throw BinaryError.malformed("the UDIF trailer states a size of \(headerSize)") }
        let flags = try c.u32()
        _ = try c.u64()                                       // running data fork offset
        let dataOffset = try c.u64(), dataLength = try c.u64()
        let rsrcOffset = try c.u64(), rsrcLength = try c.u64()
        let segmentNumber = try c.u32(), segmentCount = try c.u32()
        let id = try c.take(16)
        let segmentID = UUID(uuid: (id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7], id[8], id[9], id[10],
                                    id[11], id[12], id[13], id[14], id[15]))
        let dataChecksum = UDIFTrailer.ChecksumType(rawValue: try c.u32(), bits: try c.u32())
        try c.seek(216)
        let xmlOffset = try c.u64(), xmlLength = try c.u64()
        try c.seek(296)
        let signatureOffset = try c.u64(), signatureLength = try c.u64()
        try c.seek(352)
        let masterChecksum = UDIFTrailer.ChecksumType(rawValue: try c.u32(), bits: try c.u32())
        try c.seek(488)
        let variant = try c.u32()
        let sectors = try c.u64()
        return UDIFTrailer(version: version, flags: flags, dataForkOffset: dataOffset, dataForkLength: dataLength,
                           resourceForkOffset: rsrcOffset, resourceForkLength: rsrcLength,
                           segmentNumber: segmentNumber, segmentCount: segmentCount, segmentID: segmentID,
                           dataChecksumType: dataChecksum, masterChecksumType: masterChecksum, xmlOffset: xmlOffset,
                           xmlLength: xmlLength, codeSignatureOffset: signatureOffset,
                           codeSignatureLength: signatureLength, imageVariant: variant, sectorCount: sectors)
    }

    static func parsePartitions(_ xml: [UInt8], limits: BinaryLimits) throws -> ([Partition], Bool) {
        let plist = try PropertyListDecoder.dictionary(xml, limit: limits.maxDiskImagePlistBytes, what: "the partition list")
        guard let blkx = plist["resource-fork"]?.dictionaryValue?["blkx"]?.arrayValue else {
            throw BinaryError.malformed("the partition list has no blkx entries")
        }
        var out: [Partition] = []
        for entry in blkx {
            guard out.count < limits.maxPartitions else { return (out, true) }
            guard let dict = entry.dictionaryValue else { continue }
            let name = dict["CFName"]?.stringValue ?? dict["Name"]?.stringValue ?? "(unnamed)"
            let id = dict["ID"]?.stringValue.flatMap { Int($0) } ?? dict["ID"]?.integerValue.map { Int($0) }
            guard let data = dict["Data"]?.dataValue else {
                out.append(Partition(name: name, id: id, sectorCount: 0, storedBytes: 0, chunkCount: 0, compression: []))
                continue
            }
            out.append(try parseMish(data, name: name, id: id))
        }
        return (out, false)
    }

    /// A `mish` block table: a 204-byte header, then 40-byte chunk records.
    static func parseMish(_ data: [UInt8], name: String, id: Int?) throws -> Partition {
        guard data.be32(at: 0) == 0x6D69_7368 else { throw BinaryError.malformed("partition \(name) has no mish table") }
        var c = ByteCursor(data, at: 8, bigEndian: true, what: "partition \(name)'s block table")
        _ = try c.u64()                                       // first sector
        let sectors = try c.u64()
        try c.seek(200)
        let declared = Int(try c.u32())
        let count = min(declared, max(0, (data.count - 204) / 40))
        var stored: UInt64 = 0
        var methods: [String] = []
        for i in 0..<count {
            var chunk = ByteCursor(data, at: 204 + i * 40, bigEndian: true, what: "a chunk")
            let type = try chunk.u32()
            try chunk.skip(4 + 16)                            // comment, sector number, sector count
            _ = try chunk.u64()                               // compressed offset
            let length = try chunk.u64()
            if type == 0xFFFF_FFFF { continue }               // terminator
            stored = stored.addingReportingOverflow(length).partialValue
            let method = chunkMethod(type)
            if !methods.contains(method) { methods.append(method) }
        }
        return Partition(name: name, id: id, sectorCount: sectors, storedBytes: stored, chunkCount: count,
                         compression: methods)
    }

    static func chunkMethod(_ type: UInt32) -> String {
        switch type {
        case 0x0000_0000: "zero fill"
        case 0x0000_0001: "raw"
        case 0x0000_0002: "ignored"
        case 0x8000_0004: "ADC"
        case 0x8000_0005: "zlib"
        case 0x8000_0006: "bzip2"
        case 0x8000_0007: "LZFSE"
        case 0x8000_0008: "LZMA"
        case 0x7FFF_FFFE: "comment"
        default: String(format: "method 0x%08x", type)
        }
    }
}
