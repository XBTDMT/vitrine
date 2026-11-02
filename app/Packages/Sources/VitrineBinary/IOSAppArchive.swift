import CryptoKit
import Foundation
import Security
import VitrineArchive

/// An iOS app archive (`.ipa`): a zip holding `Payload/<Name>.app`. Read from memory without extracting: the app's
/// Info.plist, its icon (a PNG in the bundle when there is one; icons kept only in `Assets.car` are not decoded),
/// `embedded.mobileprovision`, and the main executable's signature (entitlements, signer, architectures, App Store
/// encryption) when the executable is at most `maxExecutableBytes`; above that the entitlements shown are the
/// profile's, and the reader says so. The executable's signature is verified in process (`AppSignatureCheck`, S-16):
/// a certificate is the signer only when that check verified it. roadmap: S-8
public struct IOSAppArchive: Sendable, Equatable {
    public struct UsageDescription: Sendable, Equatable {
        /// `NSCameraUsageDescription` …
        public let key: String
        /// What the key asks for, in plain words ("Camera").
        public let what: String
        /// The app's own reason, as written in Info.plist.
        public let reason: String
    }

    public enum EntitlementsSource: String, Sendable, Equatable {
        case signature = "the app's signature"
        case profile = "the provisioning profile"

        /// Where the entitlements came from, in the reader's language, for display.
        public var localizedName: String {
            switch self {
            case .signature: String(localized: "the app's signature", bundle: .module, comment: "Where an iOS app's entitlements were read from.")
            case .profile: String(localized: "the provisioning profile", bundle: .module, comment: "Where an iOS app's entitlements were read from.")
            }
        }
    }

    /// `Payload/<Name>.app`.
    public let bundlePath: String
    public let info: [String: PlistValue]
    public var name: String? { info["CFBundleDisplayName"]?.stringValue ?? info["CFBundleName"]?.stringValue }
    public var identifier: String? { info["CFBundleIdentifier"]?.stringValue }
    public var shortVersion: String? { info["CFBundleShortVersionString"]?.stringValue }
    public var buildVersion: String? { info["CFBundleVersion"]?.stringValue }
    public var minimumOSVersion: String? { info["MinimumOSVersion"]?.stringValue }
    /// "iPhone", "iPad" from `UIDeviceFamily`.
    public var deviceFamilies: [String] {
        (info["UIDeviceFamily"]?.arrayValue ?? []).compactMap(\.integerValue).compactMap {
            switch $0 { case 1: "iPhone"; case 2: "iPad"; case 3: "Apple TV"; case 4: "Apple Watch"; case 6: "Mac"; case 7: "Vision"; default: nil }
        }
    }
    public let usageDescriptions: [UsageDescription]
    /// PNG bytes of the largest icon the bundle names and holds as a file.
    public let iconData: [UInt8]?
    public let profile: ProvisioningProfile?
    public let entitlements: [String: PlistValue]?
    public let entitlementsSource: EntitlementsSource?
    public let architectures: [String]
    /// The certificates the executable's CMS signature carries, leaf first, as stored. Their names are the signer's own
    /// words: show one as the signer only when `signature` is verified (G-34).
    public let signerCertificates: [CertificateSummary]
    /// The executable carries a code signature; nil when the executable was not read (missing, or past
    /// `maxExecutableBytes`).
    public let isExecutableSigned: Bool?
    /// What the in-process check of the executable's signature found; nil when it is not signed or was not read.
    public let signature: AppSignature?
    /// The embedded profile's own CMS signature verifies to an Apple root, and it lists the app's verified signing
    /// certificate and its code directory's team: only then are the profile's team name and team the app's maker.
    public let profileVouchesForSigner: Bool
    /// The executable is encrypted by the App Store (FairPlay `cryptid` set): downloaded from the store, not built.
    public let isAppStoreEncrypted: Bool?
    /// What could not be read, in plain words.
    public let notes: [String]
    public let listing: ArchiveListing
}

/// Reads an `.ipa` from a file or bytes. roadmap: S-8
public enum IOSAppArchiveReader {
    /// The largest executable read into memory for its signature.
    public static let maxExecutableBytes = 64 * 1024 * 1024

    public static func read(contentsOf url: URL, limits: BinaryLimits = .default) throws -> IOSAppArchive {
        try read(source: try BinaryFileSource(url: url), fileName: url.lastPathComponent, limits: limits)
    }

    public static func read(source: any BinaryByteSource, fileName: String? = nil,
                            limits: BinaryLimits = .default) throws -> IOSAppArchive {
        let listing: ArchiveListing
        do { listing = try VitrineArchive.list(source: source, fileName: fileName) } catch let error as ArchiveError {
            throw BinaryError.malformed("the app archive is not a readable zip: \(error.reason)")
        }
        guard listing.format == .zip else { throw BinaryError.notRecognized("an iOS app archive (not a zip)") }
        // The bundle: Payload/<Name>.app/Info.plist, one level down.
        guard let infoIndex = listing.entries.firstIndex(where: { entry in
            let parts = ArchivePath.components(entry.path)
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else { throw BinaryError.notRecognized("an iOS app archive (no Payload/<Name>.app/Info.plist)") }
        let bundle = ArchivePath.components(listing.entries[infoIndex].path).prefix(2).joined(separator: "/")
        func member(_ relative: String) -> Int? {
            let wanted = "\(bundle)/\(relative)"
            return listing.entries.lastIndex { ArchivePath.normalized($0.path) == wanted && $0.type == .file }
        }
        func read(_ index: Int, limit: Int) -> [UInt8]? {
            guard let data = try? VitrineArchive.memberData(source: source, listing: listing, entryIndex: index, limit: limit),
                  data.isComplete else { return nil }
            return data.bytes
        }

        guard let infoBytes = read(infoIndex, limit: limits.maxPropertyListBytes) else {
            throw BinaryError.malformed("the app's Info.plist could not be read")
        }
        let info = try PropertyListDecoder.dictionary(infoBytes, limit: limits.maxPropertyListBytes, what: "the app's Info.plist")
        var notes: [String] = []

        let profileBytes = member("embedded.mobileprovision").flatMap { read($0, limit: limits.maxPropertyListBytes) }
        let profile = profileBytes.flatMap { try? ProvisioningProfileReader.read(bytes: $0, limits: limits) }

        var entitlements: [String: PlistValue]?
        var source_: IOSAppArchive.EntitlementsSource?
        var architectures: [String] = []
        var certificates: [CertificateSummary] = []
        var encrypted: Bool?
        var signed: Bool?
        var signature: AppSignature?
        if let executable = info["CFBundleExecutable"]?.stringValue, let index = member(executable) {
            let size = listing.entries[index].uncompressedSize ?? Int64.max
            if size <= Int64(maxExecutableBytes), let bytes = read(index, limit: maxExecutableBytes),
               let macho = try? MachOReader.read(source: BinaryDataSource(bytes), limits: limits) {
                architectures = macho.architectures
                let slice = macho.slices.first
                if let embedded = slice?.codeSignature {
                    entitlements = embedded.entitlements ?? embedded.derEntitlements
                    certificates = embedded.cmsCertificates
                    if entitlements != nil { source_ = .signature }
                }
                signed = macho.slices.contains { $0.hasCodeSignature }
                let resources = member("_CodeSignature/CodeResources").flatMap { read($0, limit: limits.maxPropertyListBytes) }
                signature = AppSignatureCheck.verify(executable: bytes, macho: macho, infoPlist: infoBytes, codeResources: resources)
                encrypted = macho.slices.contains { ($0.encryption?.cryptID ?? 0) != 0 }
            } else {
                let what = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                let cap = ByteCountFormatter.string(fromByteCount: Int64(maxExecutableBytes), countStyle: .file)
                notes.append("The app's executable (\(what)) is larger than the \(cap) read for its signature.")
            }
        }
        if entitlements == nil, let profile, !profile.entitlements.isEmpty {
            entitlements = profile.entitlements
            source_ = .profile
        }

        let vouches = profile.flatMap { profile in
            profileBytes.map { AppSignatureCheck.profileVouches(for: signature, profileBytes: $0, profile: profile) }
        } ?? false

        return IOSAppArchive(bundlePath: bundle, info: info, usageDescriptions: usageDescriptions(info),
                             iconData: icon(info: info, bundle: bundle, listing: listing, read: read),
                             profile: profile, entitlements: entitlements, entitlementsSource: source_,
                             architectures: architectures, signerCertificates: certificates,
                             isExecutableSigned: signed, signature: signature, profileVouchesForSigner: vouches,
                             isAppStoreEncrypted: encrypted, notes: notes, listing: listing)
    }

    /// The largest PNG at the bundle's top level whose name starts with an icon name Info.plist gives
    /// (`CFBundleIcons` → `CFBundlePrimaryIcon` → `CFBundleIconFiles`, or `CFBundleIconFiles` / `CFBundleIconFile`).
    static func icon(info: [String: PlistValue], bundle: String, listing: ArchiveListing,
                     read: (Int, Int) -> [UInt8]?) -> [UInt8]? {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let primary = info[key]?.dictionaryValue?["CFBundlePrimaryIcon"]
            names += primary?.dictionaryValue?["CFBundleIconFiles"]?.stringArray ?? []
            if let name = primary?.dictionaryValue?["CFBundleIconName"]?.stringValue { names.append(name) }
        }
        names += info["CFBundleIconFiles"]?.stringArray ?? []
        if let file = info["CFBundleIconFile"]?.stringValue { names.append(file) }
        names = names.map { ($0 as NSString).deletingPathExtension }.filter { !$0.isEmpty }
        let candidates = listing.entries.indices.filter { i in
            let parts = ArchivePath.components(listing.entries[i].path)
            guard parts.count == 3, parts[0] + "/" + parts[1] == bundle, parts[2].lowercased().hasSuffix(".png") else { return false }
            return names.contains { parts[2].hasPrefix($0) }
        }
        guard let best = candidates.max(by: { (listing.entries[$0].uncompressedSize ?? 0) < (listing.entries[$1].uncompressedSize ?? 0) })
        else { return nil }
        return read(best, 4 * 1024 * 1024)
    }

    /// The `NS…UsageDescription` keys: what the app may ask for, with its stated reason.
    static func usageDescriptions(_ info: [String: PlistValue]) -> [IOSAppArchive.UsageDescription] {
        info.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }.sorted().compactMap { key in
            guard let reason = info[key]?.stringValue else { return nil }
            return .init(key: key, what: usageName(key), reason: reason)
        }
    }

    /// `NSLocationWhenInUseUsageDescription` → "Location while in use".
    static func usageName(_ key: String) -> String {
        switch key {
        case "NSCameraUsageDescription": return "Camera"
        case "NSMicrophoneUsageDescription": return "Microphone"
        case "NSPhotoLibraryUsageDescription": return "Photos"
        case "NSPhotoLibraryAddUsageDescription": return "Adding to Photos"
        case "NSLocationWhenInUseUsageDescription": return "Location while in use"
        case "NSLocationAlwaysAndWhenInUseUsageDescription", "NSLocationAlwaysUsageDescription": return "Location at all times"
        case "NSContactsUsageDescription": return "Contacts"
        case "NSCalendarsUsageDescription", "NSCalendarsFullAccessUsageDescription": return "Calendars"
        case "NSRemindersUsageDescription", "NSRemindersFullAccessUsageDescription": return "Reminders"
        case "NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription": return "Bluetooth"
        case "NSFaceIDUsageDescription": return "Face ID"
        case "NSHealthShareUsageDescription": return "Reading Health data"
        case "NSHealthUpdateUsageDescription": return "Writing Health data"
        case "NSMotionUsageDescription": return "Motion and fitness"
        case "NSSpeechRecognitionUsageDescription": return "Speech recognition"
        case "NSLocalNetworkUsageDescription": return "Local network"
        case "NSUserTrackingUsageDescription": return "Tracking across apps"
        case "NSHomeKitUsageDescription": return "Home"
        case "NSAppleMusicUsageDescription": return "Media library"
        case "NSNearbyInteractionUsageDescription": return "Nearby devices"
        default:
            let core = key.dropFirst(2).dropLast("UsageDescription".count)
            return core.reduce(into: "") { s, ch in
                if ch.isUppercase, !s.isEmpty { s += " " }
                s.append(s.isEmpty ? ch : Character(ch.lowercased()))
            }
        }
    }
}

// MARK: - The app's signature, verified in process (S-16 follow-up B, G-34)

/// What the in-process check of an iOS app's main executable found (G-34: a card names a signer only when that
/// signature was verified). roadmap: S-16
public struct AppSignature: Sendable, Equatable {
    /// `.verified` only when, in every architecture, the CMS signature was made over the code directory with its
    /// signer's key, the code directory's hashes match the code page by page, its Info.plist, its sealed resource list
    /// and the signature's own parts, and the signer's chain ends at an Apple root (evaluated offline by `SecTrust`).
    /// `.notVouched`: all of that, but the chain ends elsewhere. `.broken`: something does not match. `.notVerified`:
    /// it could not be checked all the way (signed ad hoc, an expired certificate, a form Vitrine does not check).
    public let verification: PackageSignature.Verification
    /// The certificates the CMS signature carries, its signer first when one was found. A name is the signer's own
    /// words except under `.verified`.
    public let certificates: [CertificateSummary]
    /// The team identifier the signed code directory names; the signer's statement, meaningful under `.verified`.
    public let teamIdentifier: String?
    /// What the check does not cover even when the rest verified: the files of the app other than its code, Info.plist
    /// and resource list (iOS checks them when it installs the app), and code the App Store encrypted (its pages are
    /// hashed decrypted, so they cannot be compared here).
    public let unchecked: [UncheckedPart]

    public enum UncheckedPart: String, Sendable, Equatable { case encryptedCode, resources }
}

/// Verifies an iOS app's executable signature the way the trust card needs it, with the Security framework and no
/// network (`PackageSignatureCheck` does the same for installer packages). roadmap: S-16
enum AppSignatureCheck {
    static let codeDirectoryMagic: UInt32 = 0xFADE_0C02
    static let blobWrapperMagic: UInt32 = 0xFADE_0B01

    /// The verdict for every signed architecture of the executable, the worst one winning; nil when no architecture
    /// is signed.
    static func verify(executable: [UInt8], macho: MachOFile, infoPlist: [UInt8]?, codeResources: [UInt8]?) -> AppSignature? {
        let signed = macho.slices.filter(\.hasCodeSignature)
        guard !signed.isEmpty else { return nil }
        var verdicts: [PackageSignature.Verification] = []
        if !macho.unreadableSlices.isEmpty { verdicts.append(.notVerified("one of its architectures could not be read")) }
        if signed.count < macho.slices.count { verdicts.append(.broken("one of its architectures is not signed")) }
        var certificates: [CertificateSummary] = []
        var team: String?
        var signer: String?
        var skippedEncrypted = false
        for (index, slice) in signed.enumerated() {
            let result = verify(slice, executable: executable, infoPlist: infoPlist, codeResources: codeResources)
            verdicts.append(result.verification)
            skippedEncrypted = skippedEncrypted || result.skippedEncrypted
            if index == 0 { certificates = result.certificates; team = result.team; signer = result.signer }
            if let other = result.signer, let signer, other != signer {
                verdicts.append(.broken("its architectures are signed by different certificates"))
            }
        }
        var unchecked: [AppSignature.UncheckedPart] = []
        if skippedEncrypted { unchecked.append(.encryptedCode) }
        if codeResources != nil { unchecked.append(.resources) }
        return AppSignature(verification: worst(verdicts), certificates: certificates, teamIdentifier: team, unchecked: unchecked)
    }

    /// Broken, then not verified, then not vouched for, then verified; the first of the worst kind.
    static func worst(_ verdicts: [PackageSignature.Verification]) -> PackageSignature.Verification {
        func rank(_ v: PackageSignature.Verification) -> Int {
            switch v {
            case .broken: 3
            case .notVerified: 2
            case .notVouched: 1
            case .verified: 0
            }
        }
        return verdicts.max { rank($0) < rank($1) } ?? .notVerified("nothing was checked")
    }

    struct SliceResult {
        var verification: PackageSignature.Verification
        var certificates: [CertificateSummary] = []
        var team: String?
        /// The SHA-256 of the CMS signer's certificate, when it was found.
        var signer: String?
        var skippedEncrypted = false
    }

    static func verify(_ slice: MachOSlice, executable: [UInt8], infoPlist: [UInt8]?, codeResources: [UInt8]?) -> SliceResult {
        guard let embedded = slice.codeSignature, let range = slice.codeSignatureRange else {
            return SliceResult(verification: .broken("its signature cannot be read: \(slice.codeSignatureProblem ?? "damaged")"))
        }
        var result = SliceResult(verification: .notVerified("not checked"), certificates: embedded.cmsCertificates,
                                 team: embedded.primary?.teamIdentifier)
        // The slice, and the signature inside it, within the bytes read.
        guard slice.fileOffset >= 0, slice.fileSize >= 0, slice.fileOffset <= Int64(executable.count),
              slice.fileSize <= Int64(executable.count) - slice.fileOffset,
              range.offset >= 0, range.length > 0, range.offset <= slice.fileSize, range.length <= slice.fileSize - range.offset else {
            result.verification = .broken("its signature lies outside the executable")
            return result
        }
        let codeStart = Int(slice.fileOffset)
        let code = executable[codeStart..<(codeStart + Int(slice.fileSize))]
        let signatureStart = codeStart + Int(range.offset)
        let signature = Array(executable[signatureStart..<(signatureStart + Int(range.length))])
        var blobs: [UInt32: (magic: UInt32, bytes: [UInt8])] = [:]
        for slot in embedded.slots where blobs[slot.type] == nil {
            blobs[slot.type] = (slot.magic, Array(signature[slot.offset..<(slot.offset + slot.length)]))
        }

        guard let cms = blobs[0x10000], cms.magic == blobWrapperMagic, cms.bytes.count > 8, !embedded.isAdhoc else {
            result.verification = .notVerified("it is signed ad hoc, with no developer identity")
            return result
        }
        guard let primary = blobs[0], primary.magic == codeDirectoryMagic else {
            result.verification = .broken("its signature has no code directory")
            return result
        }

        // 1. Every code directory's hashes: the code page by page, Info.plist, the resource list, the signature's parts.
        func special(_ type: Int) -> [UInt8]? {
            switch type {
            case 1: infoPlist
            case 3: codeResources
            default: blobs[UInt32(type)]?.bytes
            }
        }
        let specialTypes = Set((1...11).filter { special($0) != nil })
        let directories = embedded.slots.filter { ($0.type == 0 || (0x1000...0x1004).contains($0.type)) && $0.magic == codeDirectoryMagic }
        for slot in directories {
            guard let directory = blobs[slot.type]?.bytes else { continue }
            switch check(directory: directory, code: code, signatureOffset: Int(range.offset), encryption: slice.encryption,
                         special: special, specialTypes: specialTypes) {
            case .matches(let skipped): result.skippedEncrypted = result.skippedEncrypted || skipped
            case .broken(let reason): result.verification = .broken(reason); return result
            case .notVerified(let reason): result.verification = .notVerified(reason); return result
            }
        }

        // 2. The CMS signature over the primary code directory, and 3. its signer's chain.
        let cmsResult = verifyCMS(Array(cms.bytes[8...]), content: primary.bytes)
        if !cmsResult.certificates.isEmpty { result.certificates = cmsResult.certificates }
        result.signer = cmsResult.signer
        result.verification = cmsResult.verification
        return result
    }

    enum DirectoryResult: Equatable { case matches(skippedEncrypted: Bool), broken(String), notVerified(String) }

    /// One code directory (`CS_CodeDirectory`) against the code it describes: its own fields bounded, every code page
    /// hashed, and every special slot compared with what it seals. A slot of all zeros seals nothing; a part that is
    /// present but unsealed, or sealed but missing, is broken.
    static func check(directory d: [UInt8], code: ArraySlice<UInt8>, signatureOffset: Int, encryption: EncryptionInfo?,
                      special: (Int) -> [UInt8]?, specialTypes: Set<Int>) -> DirectoryResult {
        guard let version = d.be32(at: 8), let hashOffset32 = d.be32(at: 16), let specialCount32 = d.be32(at: 24),
              let codeCount32 = d.be32(at: 28), let codeLimit32 = d.be32(at: 32), d.count >= 44 else {
            return .broken("its code directory is damaged")
        }
        let hashSize = Int(d[36]), hashType = d[37], pageShift = Int(d[39])
        var headerEnd = 44
        var codeLimit = UInt64(codeLimit32)
        if version >= 0x20100 {
            headerEnd = 48
            guard let scatter = d.be32(at: 44) else { return .broken("its code directory is damaged") }
            if scatter != 0 { return .notVerified("its code directory uses a scatter vector, which Vitrine does not check") }
        }
        if version >= 0x20200 { headerEnd = 52 }
        if version >= 0x20300 {
            headerEnd = 64
            guard let limit64 = d.be64(at: 56) else { return .broken("its code directory is damaged") }
            if limit64 != 0 { codeLimit = limit64 }
        }
        guard d.count >= headerEnd else { return .broken("its code directory is damaged") }

        let digest: (ArraySlice<UInt8>) -> [UInt8]
        let expectedSize: Int
        switch hashType {
        case 1: digest = { Array(Insecure.SHA1.hash(data: $0)) }; expectedSize = 20
        case 2: digest = { Array(SHA256.hash(data: $0)) }; expectedSize = 32
        case 3: digest = { Array(SHA256.hash(data: $0)) }; expectedSize = 20
        case 4: digest = { Array(SHA384.hash(data: $0)) }; expectedSize = 48
        default: return .notVerified("its code directory uses hash type \(hashType), which Vitrine does not check")
        }
        guard hashSize == expectedSize else { return .broken("its code directory's hash size does not match its hash type") }

        // The directory must cover every byte before the signature, in whole pages.
        guard codeLimit == UInt64(signatureOffset) else { return .broken("its signature does not cover all of the code before it") }
        let pageSize: Int
        if pageShift == 0 {
            pageSize = max(1, signatureOffset)
        } else {
            guard (9...24).contains(pageShift) else { return .broken("its code directory names an impossible page size") }
            pageSize = 1 << pageShift
        }
        let codeCount = Int(codeCount32), specialCount = Int(specialCount32), hashOffset = Int(hashOffset32)
        let expectedPages = signatureOffset == 0 ? 0 : (signatureOffset + pageSize - 1) / pageSize
        guard codeCount == expectedPages else { return .broken("its code directory does not describe its code page by page") }
        guard specialCount <= 64, hashOffset - specialCount * hashSize >= headerEnd,
              hashOffset <= d.count, codeCount <= (d.count - hashOffset) / hashSize else {
            return .broken("its code directory's hashes lie outside it")
        }

        // Pages the App Store encrypted are hashed decrypted: they are skipped, and said to be.
        var encrypted: Range<Int>?
        if let e = encryption, e.isEncrypted, e.size > 0 { encrypted = Int(e.offset)..<(Int(e.offset) + Int(e.size)) }
        var skipped = false
        for page in 0..<codeCount {
            let start = page * pageSize, end = min(start + pageSize, signatureOffset)
            if let encrypted, encrypted.overlaps(start..<end) { skipped = true; continue }
            let stored = d[(hashOffset + page * hashSize)..<(hashOffset + (page + 1) * hashSize)]
            let base = code.startIndex
            guard digest(code[(base + start)..<(base + end)]).prefix(hashSize).elementsEqual(stored) else {
                return .broken("its code does not match its signature")
            }
        }

        func what(_ type: Int) -> String {
            switch type {
            case 1: "its Info.plist"
            case 2: "its signing requirements"
            case 3: "its sealed resource list"
            case 5: "its entitlements"
            case 7: "its DER entitlements"
            default: "part \(type) of its signature"
            }
        }
        for type in specialTypes where type > specialCount { return .broken("\(what(type)) is not sealed by its signature") }
        if specialCount > 0 {
            for type in 1...specialCount {
                let at = hashOffset - type * hashSize
                let stored = d[at..<(at + hashSize)]
                let sealsNothing = stored.allSatisfy { $0 == 0 }
                switch (special(type), sealsNothing) {
                case (nil, true):
                    continue
                case (nil, false):
                    if [4, 6].contains(type) || type > 11 { return .notVerified("its signature seals \(what(type)), which Vitrine does not check") }
                    return .broken("\(what(type)) is missing")
                case (_?, true):
                    return .broken("\(what(type)) is not sealed by its signature")
                case (let bytes?, false):
                    guard digest(bytes[...]).prefix(hashSize).elementsEqual(stored) else { return .broken("\(what(type)) does not match its signature") }
                }
            }
        }
        return .matches(skippedEncrypted: skipped)
    }

    struct CMSResult {
        var verification: PackageSignature.Verification
        /// Signer first, then the others the message carries (at most 16).
        var certificates: [CertificateSummary] = []
        var signer: String?
    }

    /// A detached CMS signature over `content` (the code directory): it must not carry content of its own, its first
    /// signer's signature must match, and that signer's chain is evaluated by `PackageSignatureCheck.evaluate`.
    static func verifyCMS(_ cms: [UInt8], content: [UInt8]) -> CMSResult {
        guard let decoder = decoder(cms, detachedContent: content) else { return CMSResult(verification: .broken("its CMS signature is damaged")) }
        guard carriedContent(decoder).isEmpty else {
            return CMSResult(verification: .broken("its CMS signature carries content of its own instead of signing the code directory"))
        }
        return signerVerdict(decoder)
    }

    /// The first signer's status, certificates and chain verdict of a finalized decoder.
    static func signerVerdict(_ decoder: CMSDecoder) -> CMSResult {
        var signers = 0
        guard CMSDecoderGetNumSigners(decoder, &signers) == errSecSuccess, signers > 0 else {
            return CMSResult(verification: .broken("its CMS signature has no signer"))
        }
        var all: CFArray?
        let carried = CMSDecoderCopyAllCerts(decoder, &all) == errSecSuccess ? Array(((all as? [SecCertificate]) ?? []).prefix(16)) : []
        var signerRef: SecCertificate?
        _ = CMSDecoderCopySignerCert(decoder, 0, &signerRef)
        let ordered: [SecCertificate]
        if let signer = signerRef {
            let der = SecCertificateCopyData(signer) as Data
            ordered = [signer] + carried.filter { SecCertificateCopyData($0) as Data != der }
        } else {
            ordered = carried
        }
        var result = CMSResult(verification: .notVerified("its CMS signature could not be checked"),
                               certificates: ordered.map { CertificateSummary(certificate: $0) })
        result.signer = signerRef.map { CertificateSummary(certificate: $0).sha256Fingerprint }
        var status = CMSSignerStatus.unsigned
        var verifyResult: OSStatus = errSecSuccess
        guard signerRef != nil,
              CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &status, nil, &verifyResult) == errSecSuccess else {
            return result
        }
        guard status == .valid else {
            result.verification = .broken("its signature was not made over this code with its certificate's key")
            return result
        }
        result.verification = PackageSignatureCheck.evaluate(ordered)
        return result
    }

    /// A finalized decoder over `bytes`, with detached content when given; nil when the message does not decode.
    static func decoder(_ bytes: [UInt8], detachedContent: [UInt8]?) -> CMSDecoder? {
        var decoderRef: CMSDecoder?
        guard !bytes.isEmpty, CMSDecoderCreate(&decoderRef) == errSecSuccess, let decoder = decoderRef else { return nil }
        let updated = bytes.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, buffer.count)
        }
        guard updated == errSecSuccess else { return nil }
        if let detachedContent, CMSDecoderSetDetachedContent(decoder, Data(detachedContent) as CFData) != errSecSuccess { return nil }
        guard CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        return decoder
    }

    /// The profile vouches for the app's maker only when the app's signature verified, the profile's own CMS signature
    /// (over its content) verifies to an Apple root, and the profile lists the app's signing certificate and the team
    /// its signed code directory names. A profile copied from another app, or one nobody Apple signed, does not.
    static func profileVouches(for signature: AppSignature?, profileBytes: [UInt8], profile: ProvisioningProfile) -> Bool {
        guard let signature, signature.verification.isVerified, let leaf = signature.certificates.first,
              let team = signature.teamIdentifier, profile.teamIdentifiers.contains(team),
              profile.developerCertificates.contains(where: { $0.sha256Fingerprint == leaf.sha256Fingerprint }),
              let decoder = decoder(profileBytes, detachedContent: nil) else { return false }
        guard !carriedContent(decoder).isEmpty else { return false }
        return signerVerdict(decoder).verification.isVerified
    }

    /// The content a finalized message carries itself; empty for a detached signature (`CMSDecoderCopyContent`
    /// returns none for one).
    static func carriedContent(_ decoder: CMSDecoder) -> Data {
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return Data() }
        return content as Data
    }
}
