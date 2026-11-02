import Foundation

/// A provisioning profile (`.mobileprovision`, `.provisionprofile`): a property list inside a CMS signedData
/// message, decoded with Security's `CMSDecoder`. The signer status is computed with trust evaluation off — no
/// revocation or network lookup — so `signatureMatchesContent` says the content is what was signed, not that Apple's
/// chain is trusted today.
public struct ProvisioningProfile: Sendable, Equatable {
    public let name: String?
    public let uuid: String?
    public let appIDName: String?
    /// The application identifier entitlement (`TEAMID.bundle.id`, possibly with a `*` wildcard).
    public let applicationIdentifier: String?
    public let teamIdentifiers: [String]
    public let teamName: String?
    public let platforms: [String]
    public let creationDate: Date?
    public let expirationDate: Date?
    public let timeToLiveDays: Int?
    /// Devices the profile names (development and ad-hoc profiles).
    public let deviceCount: Int
    /// An enterprise (in-house) profile runs on any device.
    public let provisionsAllDevices: Bool
    public let isXcodeManaged: Bool
    public let entitlements: [String: PlistValue]
    public let developerCertificates: [CertificateSummary]
    /// The certificates that came with the CMS signature (Apple's signing chain).
    public let signerCertificates: [CertificateSummary]
    public let signatureMatchesContent: Bool?
    /// The profile's whole property list, for a raw view.
    public let properties: [String: PlistValue]

    public enum Distribution: String, Sendable, Equatable {
        case development = "development", adHoc = "ad hoc", appStore = "App Store", enterprise = "enterprise"

        /// The distribution in the reader's language, for display (the raw value stays the stable English id).
        public var localizedName: String {
            switch self {
            case .development: String(localized: "development", bundle: .module, comment: "How a provisioning profile distributes an app: for development.")
            case .adHoc: String(localized: "ad hoc", bundle: .module, comment: "How a provisioning profile distributes an app: ad hoc, to listed devices.")
            case .appStore: String(localized: "App Store", bundle: .module, comment: "How a provisioning profile distributes an app: through the App Store.")
            case .enterprise: String(localized: "enterprise", bundle: .module, comment: "How a provisioning profile distributes an app: in-house enterprise distribution.")
            }
        }
    }

    /// Inferred from the devices and `get-task-allow` (how Xcode tells them apart): all devices → enterprise;
    /// devices and debuggable → development; devices only → ad hoc; neither → App Store (or Developer ID on macOS).
    public var distribution: Distribution {
        if provisionsAllDevices { return .enterprise }
        let debuggable = entitlements["get-task-allow"]?.boolValue == true
        if deviceCount > 0 { return debuggable ? .development : .adHoc }
        return debuggable ? .development : .appStore
    }

    public func isExpired(at date: Date = Date()) -> Bool? { expirationDate.map { $0 < date } }
}

public enum ProvisioningProfileReader {
    public static func read(contentsOf url: URL, limits: BinaryLimits = .default) throws -> ProvisioningProfile {
        let source = try BinaryFileSource(url: url)
        guard source.size <= Int64(limits.maxPropertyListBytes) else {
            throw BinaryError.unsupported("the profile is \(source.size) bytes, more than the \(limits.maxPropertyListBytes)-byte cap")
        }
        return try read(bytes: try source.exactly(Int(source.size), at: 0, "the profile"), limits: limits)
    }

    /// Whether the profile's own CMS signature verifies, covers the content the profile was read from, and chains to
    /// an Apple root (S-16, G-34). `read` decodes the message without checking it, so the team it names is only a
    /// claim until this says verified.
    public static func signatureVerification(bytes: [UInt8]) -> PackageSignature.Verification {
        guard let decoder = AppSignatureCheck.decoder(bytes, detachedContent: nil) else {
            return .notVerified("its CMS signature could not be read")
        }
        let carried = AppSignatureCheck.carriedContent(decoder)
        guard !carried.isEmpty else { return .notVerified("its CMS signature carries no content") }
        guard let message = CMSMessage.decode(bytes), Data(message.content) == carried else {
            return .broken("its content is not what its signature covers")
        }
        return AppSignatureCheck.signerVerdict(decoder).verification
    }

    public static func read(bytes: [UInt8], limits: BinaryLimits = .default) throws -> ProvisioningProfile {
        guard bytes.first == 0x30 else { throw BinaryError.notRecognized("a provisioning profile (not a CMS message)") }
        guard let message = CMSMessage.decode(bytes) else {
            throw BinaryError.malformed("the profile's CMS signature could not be decoded")
        }
        guard !message.content.isEmpty else { throw BinaryError.malformed("the profile's CMS message has no content") }
        let plist = try PropertyListDecoder.dictionary(message.content, limit: limits.maxPropertyListBytes,
                                                       what: "the profile's property list")
        let entitlements = plist["Entitlements"]?.dictionaryValue ?? [:]
        let appID = entitlements["application-identifier"]?.stringValue
            ?? entitlements["com.apple.application-identifier"]?.stringValue
        let developerCertificates = (plist["DeveloperCertificates"]?.arrayValue ?? []).prefix(64)
            .compactMap { $0.dataValue.flatMap(CertificateSummary.init(der:)) }
        return ProvisioningProfile(
            name: plist["Name"]?.stringValue, uuid: plist["UUID"]?.stringValue,
            appIDName: plist["AppIDName"]?.stringValue, applicationIdentifier: appID,
            teamIdentifiers: plist["TeamIdentifier"]?.stringArray ?? [],
            teamName: plist["TeamName"]?.stringValue, platforms: plist["Platform"]?.stringArray ?? [],
            creationDate: plist["CreationDate"]?.dateValue, expirationDate: plist["ExpirationDate"]?.dateValue,
            timeToLiveDays: plist["TimeToLive"]?.integerValue.map { Int(clamping: $0) },
            deviceCount: plist["ProvisionedDevices"]?.arrayValue?.count ?? 0,
            provisionsAllDevices: plist["ProvisionsAllDevices"]?.boolValue ?? false,
            isXcodeManaged: plist["IsXcodeManaged"]?.boolValue ?? false, entitlements: entitlements,
            developerCertificates: developerCertificates, signerCertificates: message.certificates,
            signatureMatchesContent: message.signatureMatches, properties: plist)
    }
}
