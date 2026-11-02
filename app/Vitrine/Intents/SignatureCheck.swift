import Foundation
import VitrineBinary
import VitrinePreviewKit

/// Check Signature (X-6): who signed an app, installer package, disk image or Mach-O binary, whether Apple's
/// notarization holds for it, and what Gatekeeper would do the first time it opens, read by the engines the trust card
/// uses — VitrineBinary for the file's own structure and its in-process installer signature check, SignatureVerifier
/// for the Security framework's offline check (`kSecCSNoNetworkAccess`), DownloadOrigin for macOS's downloaded mark.
/// Nothing is run, mounted or installed and nothing is looked up online. It claims only what the Security framework
/// verified (G-34, S-16): who vouches for the signer comes from the code requirements the signature satisfies, never
/// from a certificate's name; "notarized" only from the `notarized` requirement. The Gatekeeper rule is the trust
/// card's (BinaryCard.gatekeeper, T-1, G-24), with one addition: macOS opens a downloaded app without asking only when
/// it is signed with a Developer ID (or by Apple, or for the App Store). roadmap: S-10, S-16
struct SignatureCheck: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case app, bundle, binary, installer, diskImage }

    enum State: Sendable, Equatable {
        /// Signed with a certificate and the full offline check passed. Who stands behind it is `anchor`.
        case valid
        /// Signed with no identity (ad hoc); the check passed.
        case adHoc
        /// Signed, but the check failed (the reason).
        case broken(String)
        /// A signature is present but could not be verified all the way (the reason).
        case notVerified(String)
        case unsigned
    }

    enum Ticket: Sendable, Equatable {
        /// The code satisfies the `notarized` requirement: macOS verified Apple's ticket for it.
        case notarized
        /// Something shaped like a ticket travels with the file, but macOS did not verify it.
        case ticketUnverified
        case notStapled
        /// A Mach-O file cannot carry a stapled ticket.
        case cannotStaple
        /// Not read for this kind of file (installer packages).
        case unknown
    }

    enum Gatekeeper: Sendable, Equatable {
        case opens
        case checksOnline
        case otherIdentity
        case blocked
        case brokenSignature
        /// The signature could not be verified, so nothing can be predicted.
        case unverified
    }

    var name: String
    var kind: Kind
    var state: State
    /// Who vouches for the signer, from the requirements the signature satisfied (or the installer's chain).
    var anchor: SignatureAssessment.Anchor = .none
    /// The leaf certificate's common name, only under an anchor Apple vouches for:
    /// "Developer ID Application: Example Co (ABCDE12345)".
    var signer: String?
    /// The name a certificate nothing vouched for gives itself: shown labelled "not verified", never as the signer.
    var claimedSigner: String?
    /// The certificate chain, leaf first, only under an anchor Apple vouches for.
    var chain: [String]
    var identifier: String?
    var team: String?
    var hardenedRuntime: Bool?
    var ticket: Ticket
    var quarantined: Bool
    var downloadedFrom: String?

    // MARK: Reading

    /// Reads the file. Throws `notSignable` for anything that is not code (or a container of code).
    static func read(url: URL, name: String) throws -> SignatureCheck {
        let inspection: VitrineBinary.Inspection
        do { inspection = try VitrineBinary.inspect(url) } catch { throw VitrineIntentError.notSignable(name: name) }
        let origin = DownloadOrigin.read(url)
        var check = SignatureCheck(name: name, kind: .binary, state: .unsigned, signer: nil, chain: [], identifier: nil, team: nil,
                                   hardenedRuntime: nil, ticket: .unknown, quarantined: origin?.quarantined ?? false,
                                   downloadedFrom: origin?.url)
        switch inspection {
        case .bundle(let bundle):
            check.kind = bundle.url.pathExtension.lowercased() == "app" || bundle.info.packageType == "APPL" ? .app : .bundle
            check.apply(SignatureVerifier.assess(url: url, depth: .full))
            check.identifier = check.identifier ?? bundle.info.identifier
        case .machO:
            check.kind = .binary
            check.apply(SignatureVerifier.assess(url: url, depth: .full))
            // macOS may hold Apple's ticket for a binary, which the requirement finds; a binary never carries one.
            if check.ticket != .notarized { check.ticket = .cannotStaple }
        case .diskImage(let image):
            check.kind = .diskImage
            if image.codeSignature != nil || (image.trailer?.codeSignatureLength ?? 0) > 0 {
                let assessment = SignatureVerifier.assess(url: url, depth: .full)
                check.apply(assessment)
                if assessment.status == .unsigned {
                    check.state = .notVerified(String(localized: "macOS does not accept the signature this disk image carries",
                                                      comment: "Check Signature: a disk image carries signature bytes the system does not read as a signature."))
                }
                // The image's own signature bytes name someone; nothing vouched for that name (G-34, F3).
                if check.signer == nil, check.claimedSigner == nil {
                    check.claimedSigner = image.codeSignature?.cmsCertificates.first.map(Self.label)
                }
            } else {
                check.ticket = .notStapled
            }
        case .installerPackage(let package):
            check.kind = .installer
            if let signature = package.signature { check.apply(signature) }
            check.identifier = package.components.first?.identifier
            check.ticket = .unknown
        case .provisioningProfile:
            throw VitrineIntentError.notSignable(name: name)
        }
        return check
    }

    mutating func apply(_ assessment: SignatureAssessment) {
        switch assessment.status {
        case .valid: state = .valid
        case .adhoc: state = .adHoc
        case .invalid(let reason, _): state = .broken(reason)
        case .unsigned: state = .unsigned
        case .notChecked:
            state = .notVerified(String(localized: "the check did not finish", comment: "Check Signature: the signature check did not finish."))
        }
        anchor = assessment.anchor
        let leaf = assessment.certificates.first.map(Self.label)
        if assessment.anchor.isVouchedByApple {
            signer = leaf
            claimedSigner = nil
            chain = assessment.certificates.map(Self.label)
            team = assessment.teamIdentifier
        } else {
            // A name the signer chose, which nothing vouched for (G-34, F5, F7).
            signer = nil
            claimedSigner = leaf
            chain = []
            team = nil
        }
        identifier = assessment.identifier
        hardenedRuntime = state == .unsigned ? nil : assessment.isHardenedRuntime
        switch assessment.notarization {
        case .verified: ticket = .notarized
        case .ticketUnverified: ticket = .ticketUnverified
        case .none: ticket = .notStapled
        }
    }

    /// An installer's signature, from VitrineBinary's in-process xar check (G-34, F58).
    mutating func apply(_ signature: PackageSignature) {
        let leaf = signature.certificates.first.map(Self.label)
        switch signature.verification {
        case .verified(let who):
            state = .valid
            anchor = who == .developerID ? .developerID : .appleIssued
            signer = leaf
            chain = signature.certificates.map(Self.label)
            team = signature.certificates.first?.organizationalUnit
        case .notVouched:
            state = .valid
            anchor = .notVouched
            claimedSigner = leaf
        case .broken(let reason):
            state = .broken(reason)
            claimedSigner = leaf
        case .notVerified(let reason):
            state = .notVerified(reason)
            claimedSigner = leaf
        }
    }

    static func label(_ certificate: CertificateSummary) -> String { certificate.commonName ?? certificate.summary }

    // MARK: Gatekeeper

    /// What Gatekeeper does the first time the file opens after a download, predicted offline from what it carries:
    /// a distribution identity decided by requirements, and a ticket macOS verified.
    var gatekeeper: Gatekeeper {
        switch state {
        case .broken: return .brokenSignature
        case .unsigned, .adHoc: return .blocked
        case .notVerified: return .unverified
        case .valid:
            guard anchor.isDistributionIdentity else { return .otherIdentity }
            return ticket == .notarized ? .opens : .checksOnline
        }
    }

    // MARK: Words

    var kindWord: String {
        switch kind {
        case .app: String(localized: "app", comment: "Check Signature: the kind of file checked.")
        case .bundle: String(localized: "bundle", comment: "Check Signature: the kind of file checked (a framework, plug-in or other bundle).")
        case .binary: String(localized: "Mach-O binary", comment: "Check Signature: the kind of file checked (an executable or library).")
        case .installer: String(localized: "installer package", comment: "Check Signature: the kind of file checked.")
        case .diskImage: String(localized: "disk image", comment: "Check Signature: the kind of file checked.")
        }
    }

    var stateWord: String {
        switch state {
        case .valid: String(localized: "Valid (checked offline)", comment: "Check Signature: the signature checked out; nothing was looked up online.")
        case .adHoc: String(localized: "Ad-hoc: signed with no developer identity", comment: "Check Signature: an ad hoc signature.")
        case .broken(let reason): String(localized: "Broken: \(reason)", comment: "Check Signature: the signature does not match the file; the argument is the system's reason.")
        case .notVerified(let reason): String(localized: "Signed, not verified: \(reason)", comment: "Check Signature: a signature is present but could not be verified; the argument is the reason.")
        case .unsigned: String(localized: "Not signed", comment: "Check Signature: no code signature.")
        }
    }

    /// The kind of certificate, as the requirements (or the installer's chain) decided it.
    var anchorWord: String? {
        switch anchor {
        case .apple: String(localized: "Apple's own", comment: "Check Signature: Apple signed the code itself.")
        case .developerID: String(localized: "Developer ID", comment: "Check Signature: a Developer ID certificate Apple issued.")
        case .macAppStore: String(localized: "Mac App Store", comment: "Check Signature: signed for the Mac App Store.")
        case .appleIssued: String(localized: "Issued by Apple, not a Developer ID", comment: "Check Signature: an Apple-issued development or other certificate, not a Developer ID.")
        case .notVouched: String(localized: "Not vouched for by Apple: the certificate does not chain to Apple", comment: "Check Signature: the signing certificate is self-signed or from another authority.")
        case .none: nil
        }
    }

    var ticketWord: String {
        switch ticket {
        case .notarized: String(localized: "Notarized: macOS verified Apple's ticket", comment: "Check Signature: the system verified Apple's notarization ticket for this code.")
        case .ticketUnverified: String(localized: "Not verified: a ticket file is present, but macOS did not confirm it", comment: "Check Signature: something shaped like a notarization ticket is present, but the system did not verify it.")
        case .notStapled: String(localized: "No ticket stapled; macOS can still find one online", comment: "Check Signature: no notarization ticket in the file.")
        case .cannotStaple: String(localized: "A binary cannot carry a stapled ticket; macOS looks it up online", comment: "Check Signature: Mach-O files cannot be stapled.")
        case .unknown: String(localized: "Not read for installer packages", comment: "Check Signature: Vitrine does not read an installer's ticket.")
        }
    }

    var gatekeeperWord: String {
        switch gatekeeper {
        case .opens: String(localized: "Opens without a warning: macOS verified Apple's ticket", comment: "Check Signature: Gatekeeper's verdict for a download whose notarization the system verified.")
        case .checksOnline: String(localized: "Opens if Apple notarized it: macOS checks online the first time", comment: "Check Signature: Gatekeeper's verdict for a Developer ID download without a stapled ticket.")
        case .otherIdentity: String(localized: "Asks first: it is not signed with a Developer ID, so macOS blocks it until you allow it in System Settings", comment: "Check Signature: Gatekeeper's verdict for a download signed with a development or other identity.")
        case .blocked: String(localized: "Blocked until you allow it in System Settings: it has no developer signature", comment: "Check Signature: Gatekeeper's verdict for an unsigned or ad hoc signed download.")
        case .brokenSignature: String(localized: "Refused: the signature is broken, so the file changed after it was signed", comment: "Check Signature: Gatekeeper's verdict for a download whose signature does not match.")
        case .unverified: String(localized: "Cannot say: the signature could not be verified", comment: "Check Signature: Gatekeeper's verdict cannot be predicted because the signature could not be verified.")
        }
    }

    /// The report Shortcuts shows: one fact a line, the Gatekeeper prediction and whether macOS marked it downloaded.
    var text: String {
        let yes = String(localized: "Yes", comment: "A yes/no value in Check Signature's report.")
        let no = String(localized: "No", comment: "A yes/no value in Check Signature's report.")
        var lines = ["\(name) · \(kindWord)"]
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            lines.append("\(label): \(value)")
        }
        add(String(localized: "Signature", comment: "Check Signature report label."), stateWord)
        add(String(localized: "Signing certificate", comment: "Check Signature report label: what kind of certificate signed the code."), anchorWord)
        add(String(localized: "Signed by", comment: "Check Signature report label: the signing certificate's name."), signer)
        add(String(localized: "Certificate name (not verified)", comment: "Check Signature report label: the name a signing certificate gives itself, which nothing vouched for."), claimedSigner)
        if chain.count > 1 { add(String(localized: "Certificate chain", comment: "Check Signature report label: the certificates from the signer up to the root."), chain.joined(separator: " ← ")) }
        add(String(localized: "Team", comment: "Check Signature report label: the Apple developer team identifier."), team)
        add(String(localized: "Identifier", comment: "Check Signature report label: the code's or package's identifier."), identifier)
        add(String(localized: "Hardened runtime", comment: "Check Signature report label: whether the code opts into the hardened runtime."), hardenedRuntime.map { $0 ? yes : no })
        add(String(localized: "Notarization", comment: "Check Signature report label."), ticketWord)
        add(String(localized: "Gatekeeper", comment: "Check Signature report label: what macOS's first-open check would do."), gatekeeperWord)
        if quarantined {
            add(String(localized: "Downloaded", comment: "Check Signature report label: whether macOS marked the file as downloaded."),
                downloadedFrom.map { String(localized: "Yes, from \($0)", comment: "Check Signature: the file was downloaded; the argument is the address.") } ?? yes)
        } else {
            add(String(localized: "Downloaded", comment: "Check Signature report label: whether macOS marked the file as downloaded."),
                String(localized: "No: Gatekeeper checks only files macOS marked as downloaded, so this one opens without that check", comment: "Check Signature: the file has no download mark."))
        }
        lines.append(String(localized: "Vitrine read the file without running it and looked nothing up online.", comment: "Check Signature report's last line."))
        return lines.joined(separator: "\n")
    }
}
