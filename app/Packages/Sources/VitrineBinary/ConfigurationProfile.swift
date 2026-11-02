import Foundation
import Security

/// A configuration profile (`.mobileconfig`): a property list of payloads, plain or inside a CMS signedData message.
/// What it would change is read from the payloads; the signature is checked twice, both offline: does it match the
/// content, and does the signer chain to a root this Mac trusts (network fetching off, so no revocation lookup or
/// missing-intermediate download happens). Nothing is installed. roadmap: S-8
public struct ConfigurationProfile: Sendable, Equatable {
    public struct Payload: Sendable, Equatable {
        /// `PayloadType`: `com.apple.wifi.managed`, `com.apple.security.root` …
        public let type: String
        /// The type in plain words ("Wi-Fi", "Root certificate").
        public let kind: String
        public let displayName: String?
        public let identifier: String?
        /// The one setting that says what this payload does: the network name, the VPN server, the certificate.
        public let summary: String?
        /// Payloads that let someone else see or steer this Mac's traffic or settings (a root certificate, device
        /// management, a proxy, DNS, a content filter, privacy permissions, kernel or system extensions).
        public let isSensitive: Bool
    }

    public enum Trust: Sendable, Equatable {
        /// The signer chains to a root this Mac trusts, judged offline.
        case trusted
        /// It does not; the reason is the trust evaluation's own words.
        case untrusted(String)
    }

    public struct Signature: Sendable, Equatable {
        /// The signer's certificate first when it can be told apart, then the rest the message carries.
        public let certificates: [CertificateSummary]
        /// The signature matches the content (`kCMSSignerValid` with trust evaluation off).
        public let matchesContent: Bool?
        public let trust: Trust?
        public var signer: CertificateSummary? { certificates.first }
    }

    public let displayName: String?
    public let identifier: String?
    public let organization: String?
    public let description: String?
    public let uuid: String?
    /// `PayloadScope`: System or User.
    public let scope: String?
    public let removalDisallowed: Bool
    /// A removal password payload (`com.apple.profileRemovalPassword`) or `RemovalPassword` key is present.
    public let hasRemovalPassword: Bool
    public let removalDate: Date?
    public let expirationDate: Date?
    public let payloads: [Payload]
    /// `EncryptedPayloadContent`: the payloads are encrypted to one device and cannot be listed.
    public let payloadsEncrypted: Bool
    /// Nil for an unsigned profile.
    public let signature: Signature?
    public let properties: [String: PlistValue]

    public var sensitivePayloads: [Payload] { payloads.filter(\.isSensitive) }

    /// The words a VPN payload's `summary` carries when the VPN connects on demand, always; callers test the summary
    /// against this rather than a literal, so the check holds in every language.
    public static let alwaysOnLabel = String(localized: "always on", bundle: .module, comment: "A VPN payload's summary: the VPN connects on demand, always.")
}

/// Reads a `.mobileconfig`, plain or CMS-signed. roadmap: S-8
public enum ConfigurationProfileReader {
    public static func read(contentsOf url: URL, limits: BinaryLimits = .default) throws -> ConfigurationProfile {
        let source = try BinaryFileSource(url: url)
        guard source.size <= Int64(limits.maxPropertyListBytes) else {
            throw BinaryError.unsupported("the profile is \(source.size) bytes, more than the \(limits.maxPropertyListBytes)-byte cap")
        }
        return try read(bytes: try source.exactly(Int(source.size), at: 0, "the profile"), limits: limits)
    }

    public static func read(bytes: [UInt8], limits: BinaryLimits = .default) throws -> ConfigurationProfile {
        var plistBytes = bytes
        var signature: ConfigurationProfile.Signature?
        if bytes.first == 0x30 {                                           // DER: a CMS signedData message
            guard let message = CMSMessage.decode(bytes, evaluateTrust: true) else {
                throw BinaryError.malformed("the profile's CMS signature could not be decoded")
            }
            plistBytes = message.content
            signature = .init(certificates: message.signerFirstCertificates, matchesContent: message.signatureMatches,
                              trust: message.trust)
        }
        let plist = try PropertyListDecoder.dictionary(plistBytes, limit: limits.maxPropertyListBytes,
                                                       what: "the profile's property list")
        guard plist["PayloadType"]?.stringValue == "Configuration" || plist["PayloadContent"] != nil
                || plist["EncryptedPayloadContent"] != nil else {
            throw BinaryError.notRecognized("a configuration profile")
        }
        let contents = (plist["PayloadContent"]?.arrayValue ?? []).prefix(1000).compactMap(\.dictionaryValue)
        let payloads = contents.map(payload)
        return ConfigurationProfile(
            displayName: plist["PayloadDisplayName"]?.stringValue, identifier: plist["PayloadIdentifier"]?.stringValue,
            organization: plist["PayloadOrganization"]?.stringValue, description: plist["PayloadDescription"]?.stringValue,
            uuid: plist["PayloadUUID"]?.stringValue, scope: plist["PayloadScope"]?.stringValue,
            removalDisallowed: plist["PayloadRemovalDisallowed"]?.boolValue ?? false,
            hasRemovalPassword: plist["RemovalPassword"] != nil
                || payloads.contains { $0.type == "com.apple.profileRemovalPassword" },
            removalDate: plist["RemovalDate"]?.dateValue, expirationDate: plist["PayloadExpirationDate"]?.dateValue,
            payloads: payloads, payloadsEncrypted: plist["EncryptedPayloadContent"] != nil, signature: signature,
            properties: plist)
    }

    static func payload(_ p: [String: PlistValue]) -> ConfigurationProfile.Payload {
        let type = p["PayloadType"]?.stringValue ?? "unknown"
        let (kind, sensitive) = describe(type)
        return .init(type: type, kind: kind, displayName: p["PayloadDisplayName"]?.stringValue,
                     identifier: p["PayloadIdentifier"]?.stringValue, summary: summary(type, p), isSensitive: sensitive)
    }

    /// The payload type in plain words, and whether it lets someone else see or steer the Mac.
    static func describe(_ type: String) -> (String, Bool) {
        switch type {
        case "com.apple.wifi.managed": (String(localized: "Wi-Fi", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.vpn.managed", "com.apple.vpn.managed.applayer": (String(localized: "VPN", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.security.root": (String(localized: "Root certificate", bundle: .module, comment: "A configuration profile payload type, in plain words."), true)
        case "com.apple.security.pem", "com.apple.security.pkcs1": (String(localized: "Certificate", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.security.pkcs12": (String(localized: "Identity (certificate and private key)", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.security.scep", "com.apple.security.acme": (String(localized: "Certificate request", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.mdm": (String(localized: "Device management (MDM)", bundle: .module, comment: "A configuration profile payload type, in plain words."), true)
        case "com.apple.dnsSettings.managed": (String(localized: "Encrypted DNS settings", bundle: .module, comment: "A configuration profile payload type, in plain words."), true)
        case "com.apple.proxy.http.global": (String(localized: "Global HTTP proxy", bundle: .module, comment: "A configuration profile payload type, in plain words."), true)
        case "com.apple.webcontent-filter": (String(localized: "Content filter", bundle: .module, comment: "A configuration profile payload type, in plain words."), true)
        case "com.apple.TCC.configuration-profile-policy": (String(localized: "Privacy permissions", bundle: .module, comment: "A configuration profile payload type, in plain words."), true)
        case "com.apple.system-extension-policy": (String(localized: "System extensions", bundle: .module, comment: "A configuration profile payload type, in plain words."), true)
        case "com.apple.syspolicy.kernel-extension-policy": (String(localized: "Kernel extensions", bundle: .module, comment: "A configuration profile payload type, in plain words."), true)
        case "com.apple.servicemanagement": (String(localized: "Login and background items", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.applicationaccess": (String(localized: "Restrictions", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.mail.managed": (String(localized: "Mail account", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.eas.account": (String(localized: "Exchange account", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.caldav.account": (String(localized: "Calendar account", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.carddav.account": (String(localized: "Contacts account", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.ldap.account": (String(localized: "Directory account", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.ManagedClient.preferences": (String(localized: "Custom settings", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.security.firewall": (String(localized: "Firewall", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.MCX.FileVault2": (String(localized: "FileVault", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.SoftwareUpdate": (String(localized: "Software Update", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.profileRemovalPassword": (String(localized: "Removal password", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.screensaver": (String(localized: "Screen saver", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.dock": (String(localized: "Dock", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.loginwindow": (String(localized: "Login window", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.notificationsettings": (String(localized: "Notifications", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        case "com.apple.font": (String(localized: "Font", bundle: .module, comment: "A configuration profile payload type, in plain words."), false)
        default: (type, false)
        }
    }

    static func summary(_ type: String, _ p: [String: PlistValue]) -> String? {
        switch type {
        case "com.apple.wifi.managed":
            let ssid = p["SSID_STR"]?.stringValue.map { "“\($0)”" }
            return [ssid, p["EncryptionType"]?.stringValue].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case "com.apple.vpn.managed", "com.apple.vpn.managed.applayer":
            let settings = ["VPN", "IPSec", "IKEv2", "PPP"].compactMap { p[$0]?.dictionaryValue }.first
            let server = settings?["RemoteAddress"]?.stringValue ?? settings?["CommRemoteAddress"]?.stringValue
            let always = settings?["OnDemandEnabled"]?.integerValue == 1 ? ConfigurationProfile.alwaysOnLabel : nil
            return [server ?? p["UserDefinedName"]?.stringValue, always].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case "com.apple.security.root", "com.apple.security.pem", "com.apple.security.pkcs1":
            let cert = p["PayloadContent"]?.dataValue.flatMap(CertificateSummary.init(der:))
            let expiry = cert?.notValidAfter.map {
                String(localized: "expires \($0.formatted(.dateTime.year()))", bundle: .module,
                       comment: "A certificate payload's summary: the year its certificate expires.")
            }
            return [cert?.summary ?? p["PayloadCertificateFileName"]?.stringValue, expiry].compactMap { $0 }
                .joined(separator: " · ").nilIfEmpty
        case "com.apple.mdm":
            return p["ServerURL"]?.stringValue.flatMap { URL(string: $0)?.host }
        case "com.apple.proxy.http.global":
            if let server = p["ProxyServer"]?.stringValue {
                return p["ProxyServerPort"]?.integerValue.map { "\(server):\($0)" } ?? server
            }
            return p["ProxyPACURL"]?.stringValue
        case "com.apple.dnsSettings.managed":
            let dns = p["DNSSettings"]?.dictionaryValue
            return [dns?["DNSProtocol"]?.stringValue, dns?["ServerName"]?.stringValue ?? dns?["ServerURL"]?.stringValue]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case "com.apple.mail.managed":
            return p["EmailAddress"]?.stringValue ?? p["IncomingMailServerHostName"]?.stringValue
        case "com.apple.eas.account":
            return p["Host"]?.stringValue
        default:
            return nil
        }
    }
}

/// The signer and its offline trust verdict, for configuration profiles. roadmap: S-8
extension CMSMessage {
    /// The message, plus (when `evaluateTrust`) whether its first signer chains to a root this Mac trusts, decided
    /// offline: network fetching is switched off on the trust object before it is evaluated.
    static func decode(_ bytes: [UInt8], evaluateTrust: Bool) -> CMSMessage? {
        guard var message = decode(bytes) else { return nil }
        guard evaluateTrust, message.signerCount > 0 else { return message }
        var decoderRef: CMSDecoder?
        guard CMSDecoderCreate(&decoderRef) == errSecSuccess, let decoder = decoderRef else { return message }
        let updated = bytes.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, buffer.count)
        }
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return message }
        var status = CMSSignerStatus.unsigned
        var trustRef: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        guard CMSDecoderCopySignerStatus(decoder, 0, policy, false, &status, &trustRef, nil) == errSecSuccess,
              let trust = trustRef else { return message }
        var signerRef: SecCertificate?
        if CMSDecoderCopySignerCert(decoder, 0, &signerRef) == errSecSuccess, let signer = signerRef {
            message.signer = CertificateSummary(certificate: signer)
        }
        SecTrustSetNetworkFetchAllowed(trust, false)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            message.trust = .trusted
        } else {
            let reason = error.map { CFErrorCopyDescription($0) as String } ?? String(localized: "the chain could not be checked", bundle: .module, comment: "Why a configuration profile's signer is not trusted, when the system gives no reason.")
            message.trust = .untrusted(reason)
        }
        return message
    }

    /// The signer's certificate first (when known), then the others in the message.
    var signerFirstCertificates: [CertificateSummary] {
        guard let signer else { return certificates }
        return [signer] + certificates.filter { $0.sha256Fingerprint != signer.sha256Fingerprint }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
