import CryptoKit
import Foundation

/// An embedded code signature read statically: the SuperBlob `LC_CODE_SIGNATURE` points at (or the one a signed disk
/// image carries), its code directories, entitlements, requirements and CMS wrapper. Nothing is verified here; the
/// Security framework layer (`SignatureVerifier`) does that.
public struct EmbeddedSignature: Sendable, Equatable {
    /// Every blob the index lists, in index order.
    public let slots: [Slot]
    /// The primary code directory (slot 0) first, then alternates (slots 0x1000…).
    public let codeDirectories: [CodeDirectory]
    /// Entitlements from the XML blob, or the DER blob when no XML one is present.
    public let entitlements: [String: PlistValue]?
    /// Which blob `entitlements` came from.
    public let entitlementsSource: EntitlementsSource?
    /// The DER entitlements decoded separately, when present (they should equal the XML ones).
    public let derEntitlements: [String: PlistValue]?
    /// The requirement set blob is present, and how many requirements it holds.
    public let requirementCount: Int?
    /// Bytes of the CMS signature (slot 0x10000). Zero (an empty wrapper) for ad-hoc signatures.
    public let cmsSize: Int?
    /// Subject summaries of the certificates inside the CMS signature, leaf first as stored.
    public let cmsCertificates: [CertificateSummary]
    /// The index lists a ticket slot (`CSSLOT_TICKETSLOT`, 0x10002), where stapling puts a disk image's ticket. Nothing
    /// in it is verified, and it lies outside the code directory and the CMS signature, so it can be added to any
    /// signature without breaking it: this is never "notarized". Only the Security framework's `notarized` requirement
    /// says that (`SignatureAssessment.notarization`).
    public let hasTicketSlot: Bool
    /// Launch constraint blobs are present (self, parent, responsible, library).
    public let hasLaunchConstraints: Bool
    /// Problems that did not stop the read (a blob that would not decode).
    public let notes: [String]

    public enum EntitlementsSource: String, Sendable, Equatable { case xml, der }

    public struct Slot: Sendable, Equatable {
        public let type: UInt32
        public let offset: Int
        public let magic: UInt32
        public let length: Int

        public var name: String {
            switch type {
            case 0: "code directory"
            case 1: "info plist"
            case 2: "requirements"
            case 3: "resource directory"
            case 4: "application"
            case 5: "entitlements"
            case 6: "rep-specific"
            case 7: "DER entitlements"
            case 8: "launch constraint (self)"
            case 9: "launch constraint (parent)"
            case 10: "launch constraint (responsible)"
            case 11: "library constraint"
            case 0x1000...0x1004: "alternate code directory \(type - 0x1000 + 1)"
            case 0x10000: "CMS signature"
            case 0x10001: "identification"
            case 0x10002: "notarization ticket"
            default: String(format: "slot 0x%x", type)
            }
        }
    }

    /// The primary code directory.
    public var primary: CodeDirectory? { codeDirectories.first }
    /// The strongest hash any code directory uses (what `codesign` calls the chosen one).
    public var strongest: CodeDirectory? { codeDirectories.max { $0.hashType.strength < $1.hashType.strength } }
    /// Ad-hoc: the code directory says so, or the CMS wrapper is empty.
    public var isAdhoc: Bool { primary?.flags.contains(.adhoc) == true || cmsSize == 0 }
    public var identifier: String? { primary?.identifier }
    public var teamIdentifier: String? { codeDirectories.lazy.compactMap(\.teamIdentifier).first }

    static let superBlobMagic: UInt32 = 0xFADE_0CC0
    static let codeDirectoryMagic: UInt32 = 0xFADE_0C02
    static let requirementsMagic: UInt32 = 0xFADE_0C01
    static let entitlementsMagic: UInt32 = 0xFADE_7171
    static let derEntitlementsMagic: UInt32 = 0xFADE_7172
    static let blobWrapperMagic: UInt32 = 0xFADE_0B01
    static let maxSlots = 64
    /// `CSSLOT_TICKETSLOT`.
    static let ticketSlot: UInt32 = 0x10002

    /// Parses a SuperBlob (big-endian throughout, whatever the binary's byte order).
    public static func parse(_ bytes: [UInt8], limits: BinaryLimits = .default) throws -> EmbeddedSignature {
        guard let magic = bytes.be32(at: 0) else { throw BinaryError.truncated("the code signature is empty") }
        guard magic == superBlobMagic else {
            throw BinaryError.malformed(String(format: "the code signature has magic 0x%08x, not a SuperBlob", magic))
        }
        guard let declaredLength = bytes.be32(at: 4), let count = bytes.be32(at: 8) else {
            throw BinaryError.truncated("the code signature header ends early")
        }
        // The signature area is often padded; the SuperBlob's own length is what counts, never more than was read.
        let length = Int(min(UInt64(declaredLength), UInt64(bytes.count)))
        var notes: [String] = []
        if Int(declaredLength) > bytes.count { notes.append("the signature claims more bytes than the file holds") }
        guard count <= UInt32(maxSlots) else {
            throw BinaryError.malformed("the code signature lists \(count) blobs")
        }
        guard 12 + Int(count) * 8 <= length else { throw BinaryError.truncated("the signature index ends early") }

        var slots: [Slot] = []
        var directories: [(UInt32, CodeDirectory)] = []
        var xml: [String: PlistValue]?
        var der: [String: PlistValue]?
        var requirementCount: Int?
        var cmsSize: Int?
        var cmsCertificates: [CertificateSummary] = []
        var launchConstraints = false
        for i in 0..<Int(count) {
            guard let type = bytes.be32(at: 12 + i * 8), let offset32 = bytes.be32(at: 16 + i * 8) else { break }
            let offset = Int(offset32)
            guard offset >= 12 + Int(count) * 8, offset + 8 <= length,
                  let blobMagic = bytes.be32(at: offset), let blobLength32 = bytes.be32(at: offset + 4) else {
                notes.append(String(format: "blob 0x%x lies outside the signature", type))
                continue
            }
            let blobLength = Int(blobLength32)
            guard blobLength >= 8, blobLength <= length - offset else {
                notes.append(String(format: "blob 0x%x has an impossible length", type))
                continue
            }
            let slot = Slot(type: type, offset: offset, magic: blobMagic, length: blobLength)
            slots.append(slot)
            let blob = Array(bytes[offset..<(offset + blobLength)])
            do {
                switch (type, blobMagic) {
                case (0, codeDirectoryMagic), (0x1000...0x1004, codeDirectoryMagic):
                    directories.append((type, try CodeDirectory.parse(blob)))
                case (2, requirementsMagic):
                    requirementCount = Int(blob.be32(at: 8) ?? 0)
                case (5, entitlementsMagic):
                    xml = try PropertyListDecoder.dictionary(Array(blob[8...]), limit: limits.maxPropertyListBytes,
                                                             what: "the entitlements blob")
                case (7, derEntitlementsMagic):
                    der = try DEREntitlements.decode(Array(blob[8...]))
                case (8...11, _):
                    launchConstraints = true
                case (0x10000, blobWrapperMagic):
                    cmsSize = blobLength - 8
                    if blobLength > 8 { cmsCertificates = CertificateSummary.fromCMS(Array(blob[8...])) }
                default:
                    break
                }
            } catch let error as BinaryError {
                notes.append("\(slot.name): \(error.reason)")
            }
        }
        directories.sort { $0.0 < $1.0 }
        if let xml, let der, xml != der { notes.append("the XML and DER entitlements differ") }
        return EmbeddedSignature(slots: slots, codeDirectories: directories.map(\.1), entitlements: xml ?? der,
                                 entitlementsSource: xml != nil ? .xml : (der != nil ? .der : nil),
                                 derEntitlements: der, requirementCount: requirementCount, cmsSize: cmsSize,
                                 cmsCertificates: cmsCertificates,
                                 hasTicketSlot: slots.contains { $0.type == ticketSlot },
                                 hasLaunchConstraints: launchConstraints, notes: notes)
    }
}

/// One code directory (`CS_CodeDirectory`, versions 0x20001 through 0x20600).
public struct CodeDirectory: Sendable, Equatable {
    public let version: UInt32
    public let flags: CodeSignatureFlags
    public let identifier: String
    public let teamIdentifier: String?
    public let hashType: HashType
    public let hashSize: Int
    /// Page size in bytes (0 = one page for the whole file).
    public let pageSize: Int
    public let codeSlotCount: Int
    public let specialSlotCount: Int
    public let codeLimit: UInt64
    public let platform: Int
    /// The SDK the hardened runtime treats it as built against (version 0x20500+).
    public let runtimeVersion: MachOVersion?
    public let execSegmentFlags: UInt64?
    /// The code directory hash: the directory's own digest with its hash type, truncated to 20 bytes, hex.
    public let cdHash: String?

    public var versionString: String { String(version, radix: 16) }

    static func parse(_ blob: [UInt8]) throws -> CodeDirectory {
        var c = ByteCursor(blob, at: 8, bigEndian: true, what: "the code directory")
        let version = try c.u32()
        let flags = CodeSignatureFlags(rawValue: try c.u32())
        _ = try c.u32()                                        // hashOffset
        let identOffset = Int(try c.u32())
        let special = Int(try c.u32())
        let code = Int(try c.u32())
        let codeLimit32 = try c.u32()
        let hashSize = Int(try c.u8())
        let hashType = HashType(rawValue: try c.u8())
        let platform = Int(try c.u8())
        let pageShift = try c.u8()
        _ = try c.u32()                                        // spare2
        var teamOffset = 0
        var codeLimit = UInt64(codeLimit32)
        var execFlags: UInt64?
        var runtime: MachOVersion?
        if version >= 0x20100 { _ = try c.u32() }              // scatterOffset
        if version >= 0x20200 { teamOffset = Int(try c.u32()) }
        if version >= 0x20300 {
            _ = try c.u32()
            let limit64 = try c.u64()
            if limit64 != 0 { codeLimit = limit64 }
        }
        if version >= 0x20400 {
            _ = try c.u64(); _ = try c.u64()                   // execSegBase, execSegLimit
            execFlags = try c.u64()
        }
        if version >= 0x20500 { runtime = MachOVersion(packed: try c.u32()) }
        guard identOffset >= 8, identOffset < blob.count, let identifier = blob.cString(at: identOffset) else {
            throw BinaryError.malformed("the code directory's identifier lies outside it")
        }
        var team: String?
        if teamOffset != 0 {
            guard teamOffset < blob.count else { throw BinaryError.malformed("the team identifier lies outside it") }
            team = blob.cString(at: teamOffset)
        }
        let cdHash: String? = switch hashType.rawValue {
        case 1: Array(Insecure.SHA1.hash(data: blob)).prefix(20).hexString
        case 2, 3: Array(SHA256.hash(data: blob)).prefix(20).hexString
        case 4: Array(SHA384.hash(data: blob)).prefix(20).hexString
        case 5: Array(SHA512.hash(data: blob)).prefix(20).hexString
        default: nil
        }
        return CodeDirectory(version: version, flags: flags, identifier: identifier, teamIdentifier: team,
                             hashType: hashType, hashSize: hashSize, pageSize: pageShift == 0 ? 0 : 1 << Int(min(pageShift, 30)),
                             codeSlotCount: code, specialSlotCount: special, codeLimit: codeLimit, platform: platform,
                             runtimeVersion: runtime, execSegmentFlags: execFlags, cdHash: cdHash)
    }
}

extension ArraySlice where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// `CS_HASHTYPE_*`.
public struct HashType: Sendable, Equatable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public var name: String {
        switch rawValue {
        case 1: "SHA-1"
        case 2: "SHA-256"
        case 3: String(localized: "SHA-256 (truncated)", bundle: .module, comment: "A code signature's hash type.")
        case 4: "SHA-384"
        case 5: "SHA-512"
        default: String(localized: "hash type \(rawValue)", bundle: .module, comment: "A code signature's hash type, unknown, by number.")
        }
    }

    var strength: Int { [1: 1, 3: 2, 2: 3, 4: 4, 5: 5][Int(rawValue)] ?? 0 }

    public var description: String { name }
}

/// Code directory flags (`CS_ADHOC`, `CS_RUNTIME`, … in `<kern/cs_blobs.h>`; `kSecCodeSignature*` in Security).
public struct CodeSignatureFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let host = CodeSignatureFlags(rawValue: 0x1)
    public static let adhoc = CodeSignatureFlags(rawValue: 0x2)
    public static let forceHard = CodeSignatureFlags(rawValue: 0x100)
    public static let forceKill = CodeSignatureFlags(rawValue: 0x200)
    public static let forceExpiration = CodeSignatureFlags(rawValue: 0x400)
    public static let restrict = CodeSignatureFlags(rawValue: 0x800)
    public static let enforcement = CodeSignatureFlags(rawValue: 0x1000)
    public static let libraryValidation = CodeSignatureFlags(rawValue: 0x2000)
    /// The hardened runtime.
    public static let runtime = CodeSignatureFlags(rawValue: 0x1_0000)
    /// Signed by the linker (ad-hoc, made by `ld` on Apple silicon), not by `codesign`.
    public static let linkerSigned = CodeSignatureFlags(rawValue: 0x2_0000)

    static let names: [(UInt32, String)] = [
        (0x1, "host"), (0x2, "adhoc"), (0x100, "hard"), (0x200, "kill"), (0x400, "expires"), (0x800, "restrict"),
        (0x1000, "enforcement"), (0x2000, "library-validation"), (0x1_0000, "runtime"), (0x2_0000, "linker-signed"),
    ]

    /// The names `codesign -d` prints for the set bits, unknown bits as hex.
    public var names: [String] {
        var out: [String] = []
        var rest = rawValue
        for (bit, name) in Self.names where rawValue & bit != 0 {
            out.append(name); rest &= ~bit
        }
        if rest != 0 { out.append(String(format: "0x%x", rest)) }
        return out
    }

    public var isHardenedRuntime: Bool { contains(.runtime) }
}
