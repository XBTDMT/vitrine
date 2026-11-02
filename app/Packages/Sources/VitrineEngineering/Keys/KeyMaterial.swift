import CryptoKit
import Foundation
import Security
import VitrineBinary

/// Certificates and keys (T-10): what a PEM bundle, a DER certificate, a signing request, an SSH public key or an
/// `authorized_keys` / `known_hosts` list holds — subjects, issuers, expiry, the chain's order, key types and
/// fingerprints. Private keys are recognised and described (their kind, whether a passphrase protects them, and an
/// OpenSSH key's public fingerprint, which its file carries in the clear), never kept or shown. Local decoding only:
/// no trust evaluation, no network. roadmap: S-22
public struct KeyMaterial: Sendable, Equatable {
    public enum Item: Sendable, Equatable {
        case certificate(CertificateSummary, key: KeyInfo?)
        case signingRequest
        case publicKey(KeyInfo)
        case sshPublicKey(SSHKey)
        /// A private key: its format and algorithm, whether it is encrypted, and for an OpenSSH key the fingerprint
        /// of its public half. Never its bytes.
        case privateKey(PrivateKey)
    }

    public struct KeyInfo: Sendable, Equatable {
        /// "RSA", "EC", "Ed25519", …
        public var algorithm: String
        public var bits: Int?
    }

    public struct SSHKey: Sendable, Equatable {
        /// `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`, `sk-ssh-ed25519@openssh.com` …
        public var type: String
        public var bits: Int?
        /// `SHA256:…`, as `ssh-keygen -l` prints it.
        public var fingerprint: String
        public var comment: String?
        /// `authorized_keys` options (`command=`, `from=`, `no-pty` …), or the host patterns of a `known_hosts` line.
        public var options: String?
        public var hashedHost = false
    }

    public struct PrivateKey: Sendable, Equatable {
        /// "OpenSSH", "PKCS#8", "PKCS#1", "SEC 1", "PKCS#8 (encrypted)" …
        public var format: String
        public var algorithm: String?
        public var encrypted: Bool
        public var publicFingerprint: String?
    }

    public enum Container: String, Sendable { case pem, der, sshPublicKey, authorizedKeys, knownHosts }

    public var container: Container
    public var items: [Item]
    /// Blocks or lines that could not be read.
    public var unreadable = 0

    public static let maxBytes = 4 << 20
    public static let maxItems = 500

    public var certificates: [CertificateSummary] { items.compactMap { if case .certificate(let c, _) = $0 { c } else { nil } } }
    public var containsPrivateKey: Bool { items.contains { if case .privateKey = $0 { true } else { false } } }

    /// The certificates in the order a chain runs, leaf first, when each one's issuer is the next one's subject.
    public var chainIsOrdered: Bool {
        let certs = certificates
        guard certs.count > 1 else { return true }
        return zip(certs, certs.dropFirst()).allSatisfy { $0.issuerCommonName != nil && $0.issuerCommonName == $1.commonName }
    }

    // MARK: Reading

    /// nil when the bytes hold none of the forms above.
    public static func read(data: Data, fileName: String) -> KeyMaterial? {
        let bytes = data.prefix(maxBytes)
        let name = fileName.lowercased()
        if let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .ascii) {
            if text.contains("-----BEGIN ") { return readPEM(text) }
            if name == "known_hosts" || name.hasPrefix("known_hosts") { return readSSHLines(text, container: .knownHosts) }
            if name == "authorized_keys" || name.hasPrefix("authorized_keys") { return readSSHLines(text, container: .authorizedKeys) }
            if let lines = readSSHLines(text, container: .sshPublicKey), !lines.items.isEmpty {
                return lines.items.count == 1 ? lines : KeyMaterial(container: .authorizedKeys, items: lines.items, unreadable: lines.unreadable)
            }
        }
        // A DER certificate: a SEQUENCE the certificate decoder accepts.
        if bytes.first == 0x30, let cert = CertificateSummary(der: [UInt8](bytes)) {
            return KeyMaterial(container: .der, items: [.certificate(cert, key: certificateKey([UInt8](bytes)))])
        }
        return nil
    }

    static func readPEM(_ text: String) -> KeyMaterial? {
        var items: [Item] = [], unreadable = 0
        var rest = Substring(text)
        while items.count < maxItems, let begin = rest.range(of: "-----BEGIN ") {
            guard let labelEnd = rest[begin.upperBound...].range(of: "-----") else { break }
            let label = String(rest[begin.upperBound..<labelEnd.lowerBound])
            guard let end = rest[labelEnd.upperBound...].range(of: "-----END \(label)-----") else { unreadable += 1; break }
            let body = rest[labelEnd.upperBound..<end.lowerBound]
            rest = rest[end.upperBound...]
            // Headers (Proc-Type: 4,ENCRYPTED …) sit before a blank line in legacy PEM.
            let encryptedHeader = body.contains("ENCRYPTED")
            let base64 = body.split(whereSeparator: \.isNewline).filter { !$0.contains(":") }.joined()
            guard let der = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { unreadable += 1; continue }
            switch label {
            case "CERTIFICATE", "TRUSTED CERTIFICATE", "X509 CERTIFICATE":
                if let cert = CertificateSummary(der: [UInt8](der)) { items.append(.certificate(cert, key: certificateKey([UInt8](der)))) } else { unreadable += 1 }
            case "CERTIFICATE REQUEST", "NEW CERTIFICATE REQUEST":
                items.append(.signingRequest)
            case "PUBLIC KEY":
                items.append(.publicKey(spkiInfo([UInt8](der)) ?? KeyInfo(algorithm: "?", bits: nil)))
            case "RSA PUBLIC KEY":
                items.append(.publicKey(KeyInfo(algorithm: "RSA", bits: rsaBits(pkcs1: [UInt8](der)))))
            case "OPENSSH PRIVATE KEY":
                items.append(.privateKey(openSSHPrivate([UInt8](der))))
            case "ENCRYPTED PRIVATE KEY":
                items.append(.privateKey(PrivateKey(format: "PKCS#8", algorithm: nil, encrypted: true)))
            case "PRIVATE KEY":
                items.append(.privateKey(PrivateKey(format: "PKCS#8", algorithm: pkcs8Algorithm([UInt8](der)), encrypted: false)))
            case "RSA PRIVATE KEY":
                items.append(.privateKey(PrivateKey(format: "PKCS#1", algorithm: "RSA", encrypted: encryptedHeader)))
            case "EC PRIVATE KEY":
                items.append(.privateKey(PrivateKey(format: "SEC 1", algorithm: "EC", encrypted: encryptedHeader)))
            case "DSA PRIVATE KEY":
                items.append(.privateKey(PrivateKey(format: "PKCS#1", algorithm: "DSA", encrypted: encryptedHeader)))
            default:
                unreadable += 1
            }
        }
        return items.isEmpty && unreadable == 0 ? nil : KeyMaterial(container: .pem, items: items, unreadable: unreadable)
    }

    // MARK: SSH

    static let sshTypes: Set<String> = ["ssh-ed25519", "ssh-rsa", "ssh-dss", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
                                        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"]

    /// One key per line: `[options|hosts] type base64 [comment]`. Comments and blank lines are skipped.
    static func readSSHLines(_ text: String, container: Container) -> KeyMaterial? {
        var items: [Item] = [], unreadable = 0
        for raw in text.split(whereSeparator: \.isNewline).prefix(maxItems * 4) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = splitOutsideQuotes(line)
            guard let t = fields.firstIndex(where: { sshTypes.contains($0) || $0.hasSuffix("-cert-v01@openssh.com") }), t + 1 < fields.count,
                  let blob = Data(base64Encoded: fields[t + 1]) else { unreadable += 1; continue }
            let prefix = fields[..<t].joined(separator: " ")
            let comment = fields.count > t + 2 ? fields[(t + 2)...].joined(separator: " ") : nil
            items.append(.sshPublicKey(SSHKey(type: fields[t], bits: sshBits(type: fields[t], blob: [UInt8](blob)),
                                              fingerprint: sshFingerprint([UInt8](blob)), comment: comment,
                                              options: prefix.isEmpty ? nil : prefix, hashedHost: prefix.hasPrefix("|1|"))))
            if items.count >= maxItems { break }
        }
        if items.isEmpty && container == .sshPublicKey { return nil }
        return KeyMaterial(container: container, items: items, unreadable: unreadable)
    }

    static func splitOutsideQuotes(_ line: String) -> [String] {
        var out: [String] = [], current = "", quoted = false
        for c in line {
            if c == "\"" { quoted.toggle(); current.append(c) }
            else if (c == " " || c == "\t") && !quoted { if !current.isEmpty { out.append(current); current = "" } }
            else { current.append(c) }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func sshFingerprint(_ blob: [UInt8]) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// SSH wire strings: a 4-byte big-endian length, then the bytes.
    static func sshStrings(_ b: [UInt8], count: Int) -> [[UInt8]]? {
        var out: [[UInt8]] = [], i = 0
        while out.count < count {
            guard i + 4 <= b.count else { return nil }
            let n = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]); i += 4
            guard n >= 0, i + n <= b.count else { return nil }
            out.append(Array(b[i..<(i + n)])); i += n
        }
        return out
    }

    static func sshBits(type: String, blob: [UInt8]) -> Int? {
        switch type {
        case "ssh-ed25519", "sk-ssh-ed25519@openssh.com": return 256
        case "ecdsa-sha2-nistp256", "sk-ecdsa-sha2-nistp256@openssh.com": return 256
        case "ecdsa-sha2-nistp384": return 384
        case "ecdsa-sha2-nistp521": return 521
        case "ssh-rsa":
            // string "ssh-rsa", mpint e, mpint n
            guard let parts = sshStrings(blob, count: 3) else { return nil }
            return bitLength(parts[2])
        case "ssh-dss": return sshStrings(blob, count: 2).map { bitLength($0[1]) }
        default: return nil
        }
    }

    static func bitLength(_ magnitude: [UInt8]) -> Int {
        let trimmed = magnitude.drop { $0 == 0 }
        guard let first = trimmed.first else { return 0 }
        return (trimmed.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }

    /// `openssh-key-v1\0`, cipher, kdf, kdf options, key count, then the public keys in the clear and the private
    /// section (encrypted when the cipher is not "none"). Only the clear part is read.
    static func openSSHPrivate(_ b: [UInt8]) -> PrivateKey {
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard b.starts(with: magic), let head = sshStrings(Array(b.dropFirst(magic.count)), count: 3) else {
            return PrivateKey(format: "OpenSSH", algorithm: nil, encrypted: false)
        }
        let cipher = String(decoding: head[0], as: UTF8.self)
        var offset = magic.count + head.reduce(0) { $0 + 4 + $1.count }
        guard offset + 4 <= b.count else { return PrivateKey(format: "OpenSSH", algorithm: nil, encrypted: cipher != "none") }
        offset += 4 // number of keys
        guard let pub = sshStrings(Array(b[offset...]), count: 1)?.first,
              let type = sshStrings(pub, count: 1)?.first.map({ String(decoding: $0, as: UTF8.self) }) else {
            return PrivateKey(format: "OpenSSH", algorithm: nil, encrypted: cipher != "none")
        }
        return PrivateKey(format: "OpenSSH", algorithm: type, encrypted: cipher != "none", publicFingerprint: sshFingerprint(pub))
    }

    // MARK: DER

    /// The key in a certificate, through Security (local).
    static func certificateKey(_ der: [UInt8]) -> KeyInfo? {
        guard let cert = SecCertificateCreateWithData(nil, Data(der) as CFData), let key = SecCertificateCopyKey(cert),
              let attributes = SecKeyCopyAttributes(key) as? [String: Any] else { return nil }
        let bits = attributes[kSecAttrKeySizeInBits as String] as? Int
        let type = attributes[kSecAttrKeyType as String] as? String
        let algorithm: String
        switch type {
        case String(kSecAttrKeyTypeRSA): algorithm = "RSA"
        case String(kSecAttrKeyTypeECSECPrimeRandom): algorithm = "EC"
        default: algorithm = spkiAlgorithmInCertificate(der) ?? "?"
        }
        return KeyInfo(algorithm: algorithm, bits: bits)
    }

    static let algorithmOIDs: [[UInt8]: String] = [
        [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]: "RSA",
        [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]: "EC",
        [0x2B, 0x65, 0x70]: "Ed25519",
        [0x2B, 0x65, 0x71]: "Ed448",
        [0x2B, 0x65, 0x6E]: "X25519",
        [0x2A, 0x86, 0x48, 0xCE, 0x38, 0x04, 0x01]: "DSA",
    ]

    /// The first algorithm OID found in the bytes (an OID TLV: 0x06, length, value).
    static func firstAlgorithm(_ b: [UInt8], limit: Int = 64) -> String? {
        var i = 0
        while i + 2 < min(b.count, limit) {
            if b[i] == 0x06 {
                let n = Int(b[i + 1])
                if n > 0, n < 16, i + 2 + n <= b.count, let name = algorithmOIDs[Array(b[(i + 2)..<(i + 2 + n)])] { return name }
            }
            i += 1
        }
        return nil
    }

    static func spkiAlgorithmInCertificate(_ der: [UInt8]) -> String? {
        // The SPKI's algorithm is the first known key algorithm after the signature algorithm; scan the whole TBS.
        var i = 0, found: [String] = []
        while i + 2 < der.count, found.count < 3 {
            if der[i] == 0x06 {
                let n = Int(der[i + 1])
                if n > 0, n < 16, i + 2 + n <= der.count, let name = algorithmOIDs[Array(der[(i + 2)..<(i + 2 + n)])] { found.append(name) }
            }
            i += 1
        }
        return found.last
    }

    static func spkiInfo(_ der: [UInt8]) -> KeyInfo? {
        guard let algorithm = firstAlgorithm(der) else { return nil }
        var bits: Int?
        switch algorithm {
        case "Ed25519", "X25519": bits = 256
        case "Ed448": bits = 448
        case "RSA":
            if let key = SecKeyCreateWithData(Data(der) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil)
                ?? spkiInner(der).flatMap({ SecKeyCreateWithData(Data($0) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) }) {
                bits = (SecKeyCopyAttributes(key) as? [String: Any])?[kSecAttrKeySizeInBits as String] as? Int
            }
        default: break
        }
        return KeyInfo(algorithm: algorithm, bits: bits)
    }

    /// The BIT STRING inside a SubjectPublicKeyInfo (the PKCS#1 key for RSA).
    static func spkiInner(_ der: [UInt8]) -> [UInt8]? {
        guard let i = der.lastIndex(of: 0x03) else { return nil }
        var j = i + 1
        guard j < der.count else { return nil }
        var length = Int(der[j]); j += 1
        if length & 0x80 != 0 {
            let n = length & 0x7F; length = 0
            for _ in 0..<n { guard j < der.count else { return nil }; length = length << 8 | Int(der[j]); j += 1 }
        }
        guard j < der.count, der[j] == 0 else { return nil }
        return Array(der[(j + 1)...])
    }

    static func rsaBits(pkcs1 der: [UInt8]) -> Int? {
        guard let key = SecKeyCreateWithData(Data(der) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) else { return nil }
        return (SecKeyCopyAttributes(key) as? [String: Any])?[kSecAttrKeySizeInBits as String] as? Int
    }

    /// PKCS#8: version, then the AlgorithmIdentifier; only its OID is read.
    static func pkcs8Algorithm(_ der: [UInt8]) -> String? { firstAlgorithm(der, limit: 32) }
}
