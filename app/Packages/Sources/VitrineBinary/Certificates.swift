import CryptoKit
import Foundation
import Security

/// What a preview shows about one X.509 certificate. Read with Security's certificate accessors, which parse the
/// DER locally: nothing here evaluates trust or touches the network.
public struct CertificateSummary: Sendable, Equatable {
    /// `SecCertificateCopySubjectSummary`: the common name, or the best human-readable subject part.
    public let summary: String
    public let commonName: String?
    /// The subject's organizational unit: the team identifier on Apple developer certificates.
    public let organizationalUnit: String?
    public let organization: String?
    public let issuerCommonName: String?
    public let notValidBefore: Date?
    public let notValidAfter: Date?
    public let serialNumber: String?
    /// SHA-256 of the DER bytes, hex (what Keychain Access shows as the fingerprint).
    public let sha256Fingerprint: String

    /// Expired at `date` (now by default); nil when the certificate states no end date.
    public func isExpired(at date: Date = Date()) -> Bool? { notValidAfter.map { $0 < date } }

    public init?(der: [UInt8]) {
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else { return nil }
        self.init(certificate: certificate, der: der)
    }

    init(certificate: SecCertificate, der: [UInt8]? = nil) {
        let bytes = der ?? [UInt8](SecCertificateCopyData(certificate) as Data)
        summary = (SecCertificateCopySubjectSummary(certificate) as String?) ?? String(localized: "certificate", bundle: .module, comment: "Shown for a certificate that has no subject name.")
        var common: CFString?
        commonName = SecCertificateCopyCommonName(certificate, &common) == errSecSuccess ? common as String? : nil
        notValidBefore = SecCertificateCopyNotValidBeforeDate(certificate) as Date?
        notValidAfter = SecCertificateCopyNotValidAfterDate(certificate) as Date?
        serialNumber = (SecCertificateCopySerialNumberData(certificate, nil) as Data?).map { [UInt8]($0).hexString }
        sha256Fingerprint = Array(SHA256.hash(data: bytes)).hexString
        let names = Self.nameParts(certificate)
        organizationalUnit = names.subject[Self.oidOrganizationalUnit]
        organization = names.subject[Self.oidOrganization]
        issuerCommonName = names.issuer[Self.oidCommonName]
    }

    static let oidCommonName = "2.5.4.3"
    static let oidOrganization = "2.5.4.10"
    static let oidOrganizationalUnit = "2.5.4.11"

    /// The first value of each attribute in the subject and issuer names, keyed by OID, via
    /// `SecCertificateCopyValues` (a local DER decode).
    private static func nameParts(_ certificate: SecCertificate) -> (subject: [String: String], issuer: [String: String]) {
        let keys = [kSecOIDX509V1SubjectName, kSecOIDX509V1IssuerName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any] else { return ([:], [:]) }
        func parts(_ key: CFString) -> [String: String] {
            guard let entry = values[key as String] as? [String: Any],
                  let list = entry[kSecPropertyKeyValue as String] as? [[String: Any]] else { return [:] }
            var out: [String: String] = [:]
            for item in list {
                guard let label = item[kSecPropertyKeyLabel as String] as? String,
                      let value = item[kSecPropertyKeyValue as String] as? String, out[label] == nil else { continue }
                out[label] = value
            }
            return out
        }
        return (parts(kSecOIDX509V1SubjectName), parts(kSecOIDX509V1IssuerName))
    }

    /// Apple's root certificate authorities, by the SHA-256 of their DER (Apple Root CA, G2 and G3, as this Mac's
    /// SystemRootCertificates keychain lists them, 2026-11-02).
    static let appleRootFingerprints: Set<String> = [
        "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",   // Apple Root CA
        "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",   // Apple Root CA - G2
        "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",   // Apple Root CA - G3
    ]
    /// Developer ID Certification Authority (the intermediate every Developer ID certificate is issued by).
    static let oidDeveloperIDIntermediate = "1.2.840.113635.100.6.2.6"
    /// A Developer ID Installer leaf.
    static let oidDeveloperIDInstallerLeaf = "1.2.840.113635.100.6.1.14"

    /// The certificate is one of Apple's roots: its DER, byte for byte (a self-made certificate with the same name
    /// does not match).
    static func isAppleRoot(_ certificate: SecCertificate) -> Bool {
        appleRootFingerprints.contains(Array(SHA256.hash(data: SecCertificateCopyData(certificate) as Data)).hexString)
    }

    /// The certificate carries an extension with this OID (a local DER decode).
    static func has(extension oid: String, _ certificate: SecCertificate) -> Bool {
        guard let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [String: Any] else { return false }
        return values[oid] != nil
    }

    /// The certificates inside a CMS (PKCS #7) message, as stored. Decoding a message does not verify it or fetch
    /// anything; an undecodable message yields none.
    static func fromCMS(_ bytes: [UInt8]) -> [CertificateSummary] {
        guard let decoded = CMSMessage.decode(bytes) else { return [] }
        return decoded.certificates
    }
}

/// A CMS (PKCS #7 signedData) message decoded with Security's `CMSDecoder`. The signer status is computed with
/// trust evaluation off, so it says whether the signature matches its content and signer certificate, not whether
/// that certificate chains to a trusted root — no revocation or network lookup happens.
struct CMSMessage {
    let content: [UInt8]
    let certificates: [CertificateSummary]
    let signerCount: Int
    /// The first signer's signature matches the content (`kCMSSignerValid`) — computed without trust evaluation.
    let signatureMatches: Bool?
    /// The first signer's certificate and its offline chain verdict, filled only by `decode(_:evaluateTrust:)`.
    var signer: CertificateSummary? = nil
    var trust: ConfigurationProfile.Trust? = nil

    static func decode(_ bytes: [UInt8]) -> CMSMessage? {
        var decoderRef: CMSDecoder?
        guard !bytes.isEmpty, CMSDecoderCreate(&decoderRef) == errSecSuccess, let decoder = decoderRef else { return nil }
        let updated = bytes.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, buffer.count)
        }
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }

        var contentRef: CFData?
        let content = CMSDecoderCopyContent(decoder, &contentRef) == errSecSuccess
            ? contentRef.map { [UInt8]($0 as Data) } ?? [] : []
        var certsRef: CFArray?
        var certificates: [CertificateSummary] = []
        if CMSDecoderCopyAllCerts(decoder, &certsRef) == errSecSuccess, let certs = certsRef as? [SecCertificate] {
            certificates = certs.prefix(64).map { CertificateSummary(certificate: $0) }
        }
        var signers = 0
        _ = CMSDecoderGetNumSigners(decoder, &signers)
        var matches: Bool?
        if signers > 0 {
            var status = CMSSignerStatus.unsigned
            let policy = SecPolicyCreateBasicX509()
            if CMSDecoderCopySignerStatus(decoder, 0, policy, false, &status, nil, nil) == errSecSuccess {
                matches = status == .valid
            }
        }
        return CMSMessage(content: content, certificates: certificates, signerCount: signers, signatureMatches: matches)
    }
}
