import CryptoKit
import Foundation
import Security

/// A flat installer package (`.pkg`): a xar archive whose zlib-compressed XML table of contents lists the members
/// (Distribution, component PackageInfo files, Bom, Payload, Scripts) and any signature. Read statically; nothing is
/// installed, expanded to disk or run, and the package's JavaScript (Distribution) and scripts are reported, never
/// evaluated.
public struct InstallerPackage: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// A product archive (`productbuild`): a Distribution file and one or more component packages.
        case product
        /// A component package (`pkgbuild`): PackageInfo, Bom, Payload and Scripts at the top level.
        case component
        /// A xar archive that is neither.
        case other
    }

    public let kind: Kind
    public let header: XarHeader
    /// Members of the archive (files and folders), capped at `BinaryLimits.maxXarMembers`.
    public let members: [XarMember]
    /// The table of contents lists more members than were kept.
    public let membersTruncated: Bool
    public let distribution: Distribution?
    public let components: [ComponentPackage]
    /// The xar signature section, if the package carries one, and whether it verified (`PackageSignature.verification`):
    /// in process, offline, with the Security framework.
    public let signature: PackageSignature?
    public let creationTime: String?
    public let notes: [String]

    /// Every install script any component declares or carries (preinstall, postinstall …): a safety fact.
    public var scriptNames: [String] {
        var seen = Set<String>(), out: [String] = []
        for component in components {
            // "._name" is the AppleDouble sidecar pkgbuild packs for a script's extended attributes; the installer
            // never runs it, so it is not a script.
            for name in component.declaredScripts.map(\.name) + component.scriptFiles.map(\.name)
            where !(name as NSString).lastPathComponent.hasPrefix("._") && seen.insert(name).inserted {
                out.append(name)
            }
        }
        return out
    }

    public var hasInstallScripts: Bool { components.contains { !$0.declaredScripts.isEmpty || !$0.scriptFiles.isEmpty } }
    public var isSigned: Bool { signature != nil }
}

public struct XarHeader: Sendable, Equatable {
    public let headerSize: Int
    public let version: Int
    public let tableOfContentsCompressedSize: UInt64
    public let tableOfContentsSize: UInt64
    /// The checksum algorithm the header names: none, SHA-1, MD5 or the named "other" one.
    public let checksumAlgorithm: String
}

public struct XarMember: Sendable, Equatable {
    public let path: String
    /// `file`, `directory`, `symlink`, …
    public let type: String
    /// Bytes stored in the heap, and bytes once decoded. Zero for folders.
    public let archivedSize: UInt64
    public let extractedSize: UInt64
    /// The member encoding (`application/x-gzip` = zlib, `application/octet-stream` = stored, …).
    public let encoding: String?
    public let heapOffset: UInt64?
}

/// The facts a Distribution file states (`installer-gui-script`).
public struct Distribution: Sendable, Equatable {
    public let title: String?
    public let minSpecVersion: String?
    public let hostArchitectures: [String]
    /// `allowed-os-versions` ranges as `min`–`before` text.
    public let allowedOSVersions: [String]
    public let packageReferences: [PackageReference]
    /// Number of `<script>` elements: JavaScript the Installer runs while the package is opened. A safety fact.
    public let javaScriptBlocks: Int
    /// The installation-check and volume-check scripts the Installer evaluates, by function call (may be nil).
    public let installationCheck: String?
    public let volumeCheck: String?
    public let customize: String?
    /// The domains the user may choose (`localSystem`, `currentUserHome`, `anywhere`) when stated.
    public let domains: [String]

    public struct PackageReference: Sendable, Equatable {
        public let identifier: String
        public let version: String?
        public let installKBytes: Int?
        /// Where the component is (`#comp.pkg` = inside this archive).
        public let location: String?
    }
}

/// One component package's PackageInfo and payload facts.
public struct ComponentPackage: Sendable, Equatable {
    /// The component's folder inside the archive ("" for a component package's own top level).
    public let path: String
    public let identifier: String?
    public let version: String?
    public let installLocation: String?
    /// `root` when the Installer will ask for an administrator.
    public let authorization: String?
    /// The scripts PackageInfo names (`<scripts><postinstall file=…/>`): name and file.
    public let declaredScripts: [DeclaredScript]
    /// Files inside the Scripts archive, when it could be listed: name, size, executable bit.
    public let scriptFiles: [ScriptFile]
    /// The Scripts archive held more than could be listed within the caps.
    public let scriptFilesTruncated: Bool
    public let payload: Payload?
    /// Bundles PackageInfo lists as installed (`<bundle id=… path=…>`).
    public let bundles: [BundleReference]

    public struct DeclaredScript: Sendable, Equatable {
        public let name: String
        public let file: String?
    }

    public struct ScriptFile: Sendable, Equatable {
        public let name: String
        public let size: UInt64
        public let isExecutable: Bool
        /// The script's text, for one up to `CPIO.maxScriptText` bytes that reads as text (T-2: readable scripts).
        public var text: String?
    }

    public struct Payload: Sendable, Equatable {
        public let archivedSize: UInt64
        public let extractedSize: UInt64
        public let numberOfFiles: Int?
        public let installKBytes: Int?
        /// The Payload's own container: `gzip cpio`, `pbzx`, `cpio`, or unknown.
        public let format: String?
    }

    public struct BundleReference: Sendable, Equatable {
        public let identifier: String?
        public let path: String?
        public let version: String?
    }
}

public struct PackageSignature: Sendable, Equatable {
    /// `RSA` for the classic xar signature; `CMS` for an `x-signature` section.
    public let styles: [String]
    /// The certificates the table of contents carries, leaf first, as stored. Their names are the signer's own words:
    /// show them as the signer only when `verification` is `.verified`.
    public let certificates: [CertificateSummary]
    /// The signature bytes' size in the heap.
    public let size: UInt64?
    public let verification: Verification

    /// What the signature check found (G-34, S-16): the table of contents' checksum against the hash of the compressed
    /// table of contents, the RSA signature over that checksum with the leaf certificate's public key, and the
    /// certificate chain evaluated by `SecTrust` against the system's roots, offline.
    public enum Verification: Sendable, Equatable {
        /// All three checked out, and the chain ends at an Apple root.
        case verified(Signer)
        /// The checksum and the signature check out, but the chain does not end at an Apple root (self-signed, or
        /// another authority): the package is intact, and nobody Apple vouches for stands behind it.
        case notVouched
        /// The checksum or the signature does not match: the package changed after it was signed, or the signature
        /// was never made with that certificate's key. The reason.
        case broken(String)
        /// It could not be checked all the way (an unsupported algorithm, an expired or unreadable certificate). The
        /// reason. Treat as not verified.
        case notVerified(String)

        public var isVerified: Bool { if case .verified = self { true } else { false } }
    }

    /// Who vouches for a verified package's signer.
    public enum Signer: Sendable, Equatable {
        /// Developer ID Installer: the leaf carries 1.2.840.113635.100.6.1.14 and its issuer 1.2.840.113635.100.6.2.6.
        case developerID
        /// Another certificate that chains to an Apple root (Apple's own software, Mac App Store, …).
        case appleIssued
    }

    public init(styles: [String], certificates: [CertificateSummary], size: UInt64?, verification: Verification) {
        self.styles = styles; self.certificates = certificates; self.size = size; self.verification = verification
    }
}

public enum InstallerPackageReader {
    static let magic: UInt32 = 0x7861_7221        // "xar!"

    public static func read(contentsOf url: URL, limits: BinaryLimits = .default) throws -> InstallerPackage {
        try read(source: BinaryFileSource(url: url), limits: limits)
    }

    public static func read(source: any BinaryByteSource, limits: BinaryLimits = .default) throws -> InstallerPackage {
        let head = try source.read(at: 0, count: 28)
        guard head.be32(at: 0) == magic else { throw BinaryError.notRecognized("a flat installer package (xar)") }
        var c = ByteCursor(head, at: 4, bigEndian: true, what: "the xar header")
        let headerSize = Int(try c.u16())
        let version = Int(try c.u16())
        let compressed = try c.u64()
        let uncompressed = try c.u64()
        let algorithm = try c.u32()
        guard headerSize >= 28, Int64(headerSize) <= source.size else {
            throw BinaryError.malformed("the xar header states a size of \(headerSize) bytes")
        }
        var checksumName = ["none", "SHA-1", "MD5"].indices.contains(Int(algorithm))
            ? ["none", "SHA-1", "MD5"][Int(algorithm)] : "algorithm \(algorithm)"
        if algorithm == 3, headerSize > 28 {
            checksumName = (try source.read(at: 28, count: min(headerSize - 28, 64))).cString(at: 0) ?? "other"
        }
        guard compressed <= UInt64(limits.maxTableOfContentsBytes), uncompressed <= UInt64(limits.maxTableOfContentsBytes)
        else { throw BinaryError.unsupported("the table of contents is larger than the \(limits.maxTableOfContentsBytes)-byte cap") }
        guard UInt64(headerSize) + compressed <= UInt64(source.size) else {
            throw BinaryError.truncated("the file ends inside the table of contents")
        }
        let header = XarHeader(headerSize: headerSize, version: version, tableOfContentsCompressedSize: compressed,
                               tableOfContentsSize: uncompressed, checksumAlgorithm: checksumName)
        let tocBytes = try source.exactly(Int(compressed), at: Int64(headerSize), "the table of contents")
        let inflated = try Decompression.zlib(tocBytes, limit: limits.maxTableOfContentsBytes)
        guard inflated.complete else { throw BinaryError.truncated("the table of contents does not decompress fully") }
        var notes: [String] = []
        if UInt64(inflated.bytes.count) != uncompressed {
            notes.append("the table of contents is \(inflated.bytes.count) bytes, not the \(uncompressed) its header states")
        }
        let root = try MarkupElement.parse(inflated.bytes, what: "the table of contents")
        guard root.name == "xar", let toc = root.child("toc") else {
            throw BinaryError.malformed("the table of contents has no <xar><toc>")
        }
        let heapStart = UInt64(headerSize) + compressed
        let context = Context(source: source, heapStart: heapStart, limits: limits)

        var members: [XarMember] = []
        var truncated = false
        collect(toc.children("file"), prefix: "", into: &members, truncated: &truncated, limit: limits.maxXarMembers)

        let distributionMember = members.first { $0.path == "Distribution" }
        var distribution: Distribution?
        if let distributionMember {
            do { distribution = try readDistribution(try context.small(distributionMember)) }
            catch let error as BinaryError { notes.append("Distribution: \(error.reason)") }
        }
        var components: [ComponentPackage] = []
        for info in members where info.path == "PackageInfo" || info.path.hasSuffix("/PackageInfo") {
            let folder = info.path == "PackageInfo" ? "" : String(info.path.dropLast("/PackageInfo".count))
            do { components.append(try readComponent(folder: folder, info: info, members: members, context: context)) }
            catch let error as BinaryError { notes.append("\(info.path): \(error.reason)") }
        }
        let kind: InstallerPackage.Kind = distributionMember != nil ? .product
            : (members.contains { $0.path == "PackageInfo" } ? .component : .other)
        let inputs = PackageSignatureCheck.Inputs(compressedTOC: tocBytes, algorithm: algorithm, algorithmName: checksumName,
                                                  context: context)
        return InstallerPackage(kind: kind, header: header, members: members, membersTruncated: truncated,
                                distribution: distribution, components: components,
                                signature: readSignature(toc, inputs: inputs), creationTime: toc.value("creation-time"),
                                notes: notes)
    }

    // MARK: - Members

    struct Context {
        let source: any BinaryByteSource
        let heapStart: UInt64
        let limits: BinaryLimits

        /// The archived bytes of a member, refused past `cap`.
        func archived(_ member: XarMember, cap: Int) throws -> [UInt8] {
            guard let offset = member.heapOffset else { throw BinaryError.malformed("\(member.path) has no data") }
            guard member.archivedSize <= UInt64(cap) else {
                throw BinaryError.unsupported("\(member.path) is \(member.archivedSize) bytes, more than the \(cap)-byte cap")
            }
            let (start, overflow) = heapStart.addingReportingOverflow(offset)
            guard !overflow, start <= UInt64(source.size), member.archivedSize <= UInt64(source.size) - start else {
                throw BinaryError.malformed("\(member.path) lies outside the file")
            }
            return try source.exactly(Int(member.archivedSize), at: Int64(start), member.path)
        }

        /// A small member decoded (Distribution, PackageInfo).
        func small(_ member: XarMember) throws -> [UInt8] {
            let cap = limits.maxPackageXMLBytes
            let raw = try archived(member, cap: cap)
            switch member.encoding {
            case "application/x-gzip":
                let out = try Decompression.zlib(raw, limit: cap)
                guard out.complete else { throw BinaryError.unsupported("\(member.path) decodes past the \(cap)-byte cap") }
                return out.bytes
            case nil, "application/octet-stream":
                return raw
            case let other?:
                throw BinaryError.unsupported("\(member.path) uses the \(other) encoding")
            }
        }
    }

    static func collect(_ files: [MarkupElement], prefix: String, into members: inout [XarMember], truncated: inout Bool,
                        limit: Int) {
        for file in files {
            guard members.count < limit else { truncated = true; return }
            let name = file.value("name") ?? "(unnamed)"
            let path = prefix.isEmpty ? name : prefix + "/" + name
            let data = file.child("data")
            members.append(XarMember(path: path, type: file.value("type") ?? "file",
                                     archivedSize: data?.value("length").flatMap { UInt64($0) } ?? 0,
                                     extractedSize: data?.value("size").flatMap { UInt64($0) } ?? 0,
                                     encoding: data?.child("encoding")?.attributes["style"],
                                     heapOffset: data?.value("offset").flatMap { UInt64($0) }))
            collect(file.children("file"), prefix: path, into: &members, truncated: &truncated, limit: limit)
        }
    }

    // MARK: - Distribution and PackageInfo

    static func readDistribution(_ bytes: [UInt8]) throws -> Distribution {
        let root = try MarkupElement.parse(bytes, what: "the Distribution file")
        guard root.name == "installer-gui-script" || root.name == "installer-script" else {
            throw BinaryError.malformed("the Distribution file's root is <\(root.name)>")
        }
        var refs: [String: Distribution.PackageReference] = [:]
        var order: [String] = []
        for ref in root.descendants("pkg-ref") {
            guard let id = ref.attributes["id"] else { continue }
            let old = refs[id]
            if old == nil { order.append(id) }
            let text = ref.text.trimmingCharacters(in: .whitespacesAndNewlines)
            refs[id] = Distribution.PackageReference(
                identifier: id, version: ref.attributes["version"] ?? old?.version,
                installKBytes: ref.attributes["installKBytes"].flatMap { Int($0) } ?? old?.installKBytes,
                location: text.isEmpty ? old?.location : text)
        }
        let options = root.child("options")
        let ranges = root.descendants("os-version").map { v in
            [v.attributes["min"].map { "≥ \($0)" }, v.attributes["before"].map { "< \($0)" }]
                .compactMap { $0 }.joined(separator: ", ")
        }
        var domains: [String] = []
        if let d = root.child("domains") {
            for (key, name) in [("enable_localSystem", "localSystem"), ("enable_currentUserHome", "currentUserHome"),
                                ("enable_anywhere", "anywhere")] where d.attributes[key] == "true" {
                domains.append(name)
            }
        }
        return Distribution(title: root.value("title"), minSpecVersion: root.attributes["minSpecVersion"],
                            hostArchitectures: (options?.attributes["hostArchitectures"] ?? "")
                                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty },
                            allowedOSVersions: ranges, packageReferences: order.compactMap { refs[$0] },
                            javaScriptBlocks: root.descendants("script").count + (root.name == "script" ? 1 : 0),
                            installationCheck: root.child("installation-check")?.attributes["script"],
                            volumeCheck: root.child("volume-check")?.attributes["script"],
                            customize: options?.attributes["customize"], domains: domains)
    }

    static func readComponent(folder: String, info: XarMember, members: [XarMember],
                              context: Context) throws -> ComponentPackage {
        let root = try MarkupElement.parse(try context.small(info), what: "PackageInfo")
        guard root.name == "pkg-info" else { throw BinaryError.malformed("PackageInfo's root is <\(root.name)>") }
        let declared = (root.child("scripts")?.children ?? []).map {
            ComponentPackage.DeclaredScript(name: $0.name, file: $0.attributes["file"])
        }
        func member(_ name: String) -> XarMember? {
            let path = folder.isEmpty ? name : folder + "/" + name
            return members.first { $0.path == path }
        }
        var scriptFiles: [ComponentPackage.ScriptFile] = []
        var scriptsTruncated = false
        if let scripts = member("Scripts") {
            (scriptFiles, scriptsTruncated) = listScripts(scripts, context: context)
        }
        var payload: ComponentPackage.Payload?
        let payloadInfo = root.child("payload")
        if let p = member("Payload") {
            let head = (try? context.archived(XarMember(path: p.path, type: p.type, archivedSize: min(p.archivedSize, 6),
                                                        extractedSize: 0, encoding: p.encoding, heapOffset: p.heapOffset),
                                              cap: 6)) ?? []
            payload = .init(archivedSize: p.archivedSize, extractedSize: p.extractedSize,
                            numberOfFiles: payloadInfo?.attributes["numberOfFiles"].flatMap { Int($0) },
                            installKBytes: payloadInfo?.attributes["installKBytes"].flatMap { Int($0) },
                            format: containerFormat(head))
        }
        let bundles = root.descendants("bundle").map {
            ComponentPackage.BundleReference(identifier: $0.attributes["id"], path: $0.attributes["path"],
                                             version: $0.attributes["CFBundleShortVersionString"])
        }
        return ComponentPackage(path: folder, identifier: root.attributes["identifier"],
                                version: root.attributes["version"], installLocation: root.attributes["install-location"],
                                authorization: root.attributes["auth"], declaredScripts: declared,
                                scriptFiles: scriptFiles, scriptFilesTruncated: scriptsTruncated, payload: payload,
                                bundles: bundles)
    }

    static func containerFormat(_ head: [UInt8]) -> String? {
        if head.count >= 2, head[0] == 0x1F, head[1] == 0x8B { return "gzip cpio" }
        if head.count >= 4, head.prefix(4).elementsEqual("pbzx".utf8) { return "pbzx" }
        if head.count >= 6, head.prefix(5).elementsEqual("07070".utf8) { return "cpio" }
        return head.isEmpty ? nil : "unknown"
    }

    /// Lists the files in a Scripts archive (gzip'd or plain cpio) by name, size and executable bit. Contents are
    /// never kept or shown.
    static func listScripts(_ member: XarMember, context: Context) -> ([ComponentPackage.ScriptFile], Bool) {
        let cap = context.limits.maxScriptArchiveBytes
        guard let raw = try? context.archived(member, cap: cap) else { return ([], true) }
        var bytes = raw
        var complete = true
        if member.encoding == "application/x-gzip" {
            guard let out = try? Decompression.zlib(bytes, limit: cap) else { return ([], true) }
            bytes = out.bytes; complete = out.complete
        }
        if bytes.count >= 2, bytes[0] == 0x1F, bytes[1] == 0x8B {
            guard let out = try? Decompression.gzip(bytes, limit: cap) else { return ([], true) }
            bytes = out.bytes; complete = complete && out.complete
        }
        let (files, cpioComplete) = CPIO.list(bytes)
        return (files, !(complete && cpioComplete))
    }

    // MARK: - Signature

    static func readSignature(_ toc: MarkupElement, inputs: PackageSignatureCheck.Inputs) -> PackageSignature? {
        let sections = toc.children("signature") + toc.children("x-signature")
        guard !sections.isEmpty else { return nil }
        var certificates: [CertificateSummary] = []
        for section in sections {
            for der in PackageSignatureCheck.certificateDER(section) {
                if let summary = CertificateSummary(der: der),
                   !certificates.contains(where: { $0.sha256Fingerprint == summary.sha256Fingerprint }) {
                    certificates.append(summary)
                }
            }
        }
        return PackageSignature(styles: sections.compactMap { $0.attributes["style"] }, certificates: certificates,
                                size: sections.first?.value("size").flatMap { UInt64($0) },
                                verification: PackageSignatureCheck.verify(toc: toc, inputs: inputs))
    }
}

/// The xar signature check, in process with the Security framework and offline (G-34, S-16; no `pkgutil`, which a
/// sandboxed preview cannot run). xar signs its table of contents: the header names a checksum algorithm, the
/// `<checksum>` element points at the digest of the compressed table of contents in the heap, and the `<signature
/// style="RSA">` element points at a PKCS #1 v1.5 signature over that digest, made with the key of the first
/// `X509Certificate` it lists. The table of contents names every member's offset, length and own checksum, so a
/// signature that verifies binds the whole package. An `x-signature` (CMS) section, which `productsign` adds beside
/// the RSA one, is not needed for the verdict and is not read.
enum PackageSignatureCheck {
    struct Inputs {
        let compressedTOC: [UInt8]
        let algorithm: UInt32
        let algorithmName: String
        let context: InstallerPackageReader.Context
    }

    /// The DER of each `X509Certificate` a section lists, in order (at most 16).
    static func certificateDER(_ section: MarkupElement) -> [[UInt8]] {
        section.descendants("X509Certificate").prefix(16).compactMap { cert in
            Data(base64Encoded: cert.text.filter { !$0.isWhitespace }).map { [UInt8]($0) }
        }
    }

    static func verify(toc: MarkupElement, inputs: Inputs) -> PackageSignature.Verification {
        guard let section = toc.children("signature").first(where: { $0.attributes["style"]?.uppercased() == "RSA" }) else {
            let styles = (toc.children("signature") + toc.children("x-signature")).compactMap { $0.attributes["style"] }
            return .notVerified("its signature style (\(styles.joined(separator: ", "))) is not one Vitrine checks")
        }
        // 1. The checksum: the stored digest equals the digest of the compressed table of contents.
        guard let checksum = toc.child("checksum") else { return .broken("the table of contents has no checksum") }
        let digest: [UInt8]
        switch Self.digest(inputs) {
        case .success(let value): digest = value
        case .failure(let reason): return .notVerified(reason.text)
        }
        if let style = checksum.attributes["style"], normalized(style) != normalized(digestName(inputs)) {
            return .broken("the table of contents names a \(style) checksum, its header \(digestName(inputs))")
        }
        guard let stored = heap(checksum, cap: 1024, inputs) else { return .broken("the checksum lies outside the file") }
        guard stored == digest else { return .broken("the table of contents does not match its checksum") }

        // 2. The signature over the checksum, with the leaf certificate's key.
        let certificates = certificateDER(section).compactMap { SecCertificateCreateWithData(nil, Data($0) as CFData) }
        guard let leaf = certificates.first else { return .broken("the signature carries no certificate") }
        guard let signature = heap(section, cap: 16 * 1024, inputs) else { return .broken("the signature lies outside the file") }
        guard rsaVerifies(leaf, digest: digest, signature: signature) else {
            return .broken("the signature was not made over this package with its certificate's key")
        }

        // 3. The chain, against the system's roots, with no network fetch.
        return evaluate(certificates)
    }

    struct Reason: Error { let text: String }

    static func digestName(_ inputs: Inputs) -> String {
        switch inputs.algorithm {
        case 1: "sha1"
        case 2: "md5"
        case 0: "none"
        default: inputs.algorithmName
        }
    }

    static func normalized(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func digest(_ inputs: Inputs) -> Result<[UInt8], Reason> {
        let data = inputs.compressedTOC
        switch normalized(digestName(inputs)) {
        case "sha1": return .success(Array(Insecure.SHA1.hash(data: data)))
        case "sha256": return .success(Array(SHA256.hash(data: data)))
        case "sha384": return .success(Array(SHA384.hash(data: data)))
        case "sha512": return .success(Array(SHA512.hash(data: data)))
        case "none": return .failure(Reason(text: "its table of contents has no checksum to sign"))
        default: return .failure(Reason(text: "its checksum algorithm (\(digestName(inputs))) is not one Vitrine trusts"))
        }
    }

    /// The heap bytes an element's `<offset>` and `<size>` point at, refused past `cap` or outside the file.
    static func heap(_ element: MarkupElement, cap: Int, _ inputs: Inputs) -> [UInt8]? {
        guard let offset = element.value("offset").flatMap({ UInt64($0) }),
              let size = element.value("size").flatMap({ UInt64($0) }), size > 0 else { return nil }
        let member = XarMember(path: "the signature data", type: "file", archivedSize: size, extractedSize: size,
                               encoding: nil, heapOffset: offset)
        return try? inputs.context.archived(member, cap: cap)
    }

    /// PKCS #1 v1.5 over the digest (a DigestInfo of the checksum's own algorithm).
    static func rsaVerifies(_ leaf: SecCertificate, digest: [UInt8], signature: [UInt8]) -> Bool {
        guard let key = SecCertificateCopyKey(leaf) else { return false }
        let algorithm: SecKeyAlgorithm
        switch digest.count {
        case 20: algorithm = .rsaSignatureDigestPKCS1v15SHA1
        case 32: algorithm = .rsaSignatureDigestPKCS1v15SHA256
        case 48: algorithm = .rsaSignatureDigestPKCS1v15SHA384
        case 64: algorithm = .rsaSignatureDigestPKCS1v15SHA512
        default: return false
        }
        guard SecKeyIsAlgorithmSupported(key, .verify, algorithm) else { return false }
        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(key, algorithm, Data(digest) as CFData, Data(signature) as CFData, &error)
        error?.release()
        return verified
    }

    /// `SecTrust` with the basic X.509 policy, the system's roots and no network. Trusted and ending at an Apple root
    /// is verified; ending anywhere else is not vouched for; ending at an Apple root but failing (an expired
    /// certificate) is not verified, with the reason.
    static func evaluate(_ certificates: [SecCertificate]) -> PackageSignature.Verification {
        var trustRef: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trustRef) == errSecSuccess,
              let trust = trustRef else { return .notVerified("its certificates could not be evaluated") }
        SecTrustSetNetworkFetchAllowed(trust, false)
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? certificates
        guard let root = chain.last, CertificateSummary.isAppleRoot(root) else { return .notVouched }
        guard trusted else {
            let reason = error.map { CFErrorCopyDescription($0) as String } ?? "the certificate chain did not evaluate"
            return .notVerified(reason)
        }
        if chain.count >= 2,
           CertificateSummary.has(extension: CertificateSummary.oidDeveloperIDInstallerLeaf, chain[0]),
           CertificateSummary.has(extension: CertificateSummary.oidDeveloperIDIntermediate, chain[1]) {
            return .verified(.developerID)
        }
        return .verified(.appleIssued)
    }
}


/// The two ASCII cpio formats packages use: odc (`070707`, pkgbuild's Scripts and Payload) and newc (`070701`).
enum CPIO {
    static let maxEntries = 10_000

    static func list(_ bytes: [UInt8]) -> ([ComponentPackage.ScriptFile], Bool) {
        var files: [ComponentPackage.ScriptFile] = []
        var i = 0
        while i + 6 <= bytes.count, files.count < maxEntries {
            let magic = String(decoding: bytes[i..<(i + 6)], as: UTF8.self)
            let entry: (name: String, mode: UInt64, size: UInt64, next: Int, data: Int)?
            switch magic {
            case "070707": entry = odc(bytes, at: i)
            case "070701", "070702": entry = newc(bytes, at: i)
            default: entry = nil
            }
            guard let e = entry else { return (files, false) }
            if e.name == "TRAILER!!!" { return (files, true) }
            if e.mode & 0o170000 == 0o100000 {
                let name = e.name.hasPrefix("./") ? String(e.name.dropFirst(2)) : e.name
                files.append(.init(name: name, size: e.size, isExecutable: e.mode & 0o111 != 0, text: text(bytes, at: e.data, size: e.size)))
            }
            i = e.next
        }
        return (files, false)
    }

    /// Scripts are read as text up to this size; a larger or binary member keeps its name and size only.
    static let maxScriptText: UInt64 = 256 << 10

    static func text(_ bytes: [UInt8], at start: Int, size: UInt64) -> String? {
        guard size > 0, size <= maxScriptText, start >= 0, start + Int(size) <= bytes.count else { return nil }
        let body = bytes[start..<(start + Int(size))]
        guard !body.contains(0), let s = String(bytes: body, encoding: .utf8) else { return nil }
        return s
    }

    private static func number(_ bytes: [UInt8], _ at: Int, _ width: Int, radix: Int) -> UInt64? {
        guard at + width <= bytes.count else { return nil }
        return UInt64(String(decoding: bytes[at..<(at + width)], as: UTF8.self), radix: radix)
    }

    private static func odc(_ b: [UInt8], at i: Int) -> (String, UInt64, UInt64, Int, Int)? {
        guard let mode = number(b, i + 18, 6, radix: 8), let nameSize = number(b, i + 59, 6, radix: 8),
              let size = number(b, i + 65, 11, radix: 8) else { return nil }
        let nameStart = i + 76
        guard nameSize > 0, nameSize < 4096, UInt64(nameStart) + nameSize <= UInt64(b.count) else { return nil }
        let name = b.cString(at: nameStart, limit: nameStart + Int(nameSize)) ?? ""
        let (next, overflow) = UInt64(nameStart + Int(nameSize)).addingReportingOverflow(size)
        guard !overflow, next <= UInt64(b.count) else { return nil }
        return (name, mode, size, Int(next), nameStart + Int(nameSize))
    }

    private static func newc(_ b: [UInt8], at i: Int) -> (String, UInt64, UInt64, Int, Int)? {
        guard let mode = number(b, i + 14, 8, radix: 16), let size = number(b, i + 54, 8, radix: 16),
              let nameSize = number(b, i + 94, 8, radix: 16) else { return nil }
        let nameStart = i + 110
        guard nameSize > 0, nameSize < 4096, UInt64(nameStart) + nameSize <= UInt64(b.count) else { return nil }
        let name = b.cString(at: nameStart, limit: nameStart + Int(nameSize)) ?? ""
        let dataStart = (nameStart + Int(nameSize) + 3) & ~3
        let (end, overflow) = UInt64(dataStart).addingReportingOverflow(size)
        guard !overflow, end <= UInt64(b.count) else { return nil }
        return (name, mode, size, (Int(end) + 3) & ~3, dataStart)
    }
}
