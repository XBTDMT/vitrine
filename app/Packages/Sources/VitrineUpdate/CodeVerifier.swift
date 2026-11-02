// Checks the app inside an update before it may replace the installed copy (G-21): its signature must be valid
// (every architecture, strict, nested code) and satisfy the designated requirement of the RUNNING Vitrine — the same
// signing identity — and it must be a hardened-runtime build with no code-protection exceptions. No network is used:
// revocation and notarization checks are left off, because they need network and a self-signed identity has neither.
public import Foundation
import Security

public protocol AppSignatureVerifying: Sendable {
    /// Throws unless the bundle at `app` is signed by the same identity as the running Vitrine and built as a release.
    func verify(_ app: URL) throws(UpdateError)
}

public struct SecCodeAppVerifier: AppSignatureVerifying {
    /// The requirement every update must meet, as text (Security's requirement language).
    public let requirement: String

    public init(requirement: String) { self.requirement = requirement }

    /// The running process's own designated requirement. Refused for an ad-hoc signature: its requirement names one
    /// exact binary (a cdhash), so no other build could ever meet it, and it says nothing about who signed it.
    public static func forRunningApp() throws(UpdateError) -> SecCodeAppVerifier {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { throw .ownSignatureUnusable }
        var staticMe: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe else { throw .ownSignatureUnusable }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], !certificates.isEmpty
        else { throw .ownSignatureUnusable }
        var designated: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticMe, [], &designated) == errSecSuccess, let designated else {
            throw .ownSignatureUnusable
        }
        var text: CFString?
        guard SecRequirementCopyString(designated, [], &text) == errSecSuccess, let text else { throw .ownSignatureUnusable }
        let requirement = text as String
        guard !requirement.contains("cdhash") else { throw .ownSignatureUnusable }
        return SecCodeAppVerifier(requirement: requirement)
    }

    /// Entitlements a release must never carry: any hardened-runtime exception, and the debugger door.
    static func forbiddenEntitlement(in entitlements: [String: Any]) -> String? {
        entitlements.keys.sorted().first { $0.hasPrefix("com.apple.security.cs.") || $0 == "com.apple.security.get-task-allow" }
    }

    public func verify(_ app: URL) throws(UpdateError) {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else {
            throw .signatureInvalid("requirement")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw .signatureInvalid("unreadable")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode
                                   | kSecCSRestrictSymlinks | kSecCSRestrictToAppLike)
        // First without the requirement: tells a damaged signature apart from a valid one by someone else.
        let valid = SecStaticCodeCheckValidity(code, flags, nil)
        guard valid == errSecSuccess else { throw .signatureInvalid("OSStatus \(valid)") }
        let meets = SecStaticCodeCheckValidity(code, flags, parsed)
        guard meets == errSecSuccess else {
            if meets == errSecCSReqFailed { throw .requirementNotMet }
            throw .signatureInvalid("OSStatus \(meets)")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &info)
                == errSecSuccess, let dict = info as? [String: Any] else { throw .signatureInvalid("no signing information") }
        let codeFlags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        guard codeFlags & SecCodeSignatureFlags.runtime.rawValue != 0 else { throw .unsafeBuild("hardened runtime off") }
        if let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
           let bad = Self.forbiddenEntitlement(in: entitlements) {
            throw .unsafeBuild(bad)
        }
    }
}

/// The app's verifier: reads the running Vitrine's own designated requirement at the moment of each check, so the
/// requirement is always the signature of the copy that is actually running.
public struct RunningAppVerifier: AppSignatureVerifying {
    public init() {}
    public func verify(_ app: URL) throws(UpdateError) {
        try SecCodeAppVerifier.forRunningApp().verify(app)
    }
}
