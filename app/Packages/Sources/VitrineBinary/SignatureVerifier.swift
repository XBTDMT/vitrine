import Foundation
import Security
import Synchronization

/// The Security framework's view of a bundle's, binary's or disk image's signature: `SecStaticCodeCreateWithPath`,
/// `SecCodeCopySigningInformation` and `SecStaticCodeCheckValidity`. The validity checks — the only calls that can
/// reach for the network — always carry `kSecCSNoNetworkAccess`, so no OCSP, CRL or online notarization lookup is made
/// (creating a static code object rejects that flag as inappropriate, and neither it nor reading signing information
/// looks anything up). Static code objects never load or run the code they describe.
///
/// What it may claim, and only that (G-34): `status` says whether the signature is intact at `depth`; `anchor` says who
/// vouches for the signer, decided by evaluating code requirements against the signature, never by reading
/// certificate names (the signer chooses those); `notarization` is `.verified` only when the code satisfies the
/// `notarized` requirement. roadmap: S-16
public struct SignatureAssessment: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Signed with a certificate, and the check at `depth` passed offline. Says nothing about who signed it:
        /// `anchor` does. Only a `.full` depth makes it "valid" in words a person reads.
        case valid
        /// Ad-hoc signed (no certificate, no identity), and the check at `depth` passed.
        case adhoc
        /// Signed, but the check failed: the reason and the Security status code.
        case invalid(reason: String, code: Int32)
        /// No signature at all.
        case unsigned
        /// The check did not finish within the time it was given (`SignatureVerifier.assess(url:budget:)`): nothing
        /// about the signature is known yet.
        case notChecked
    }

    /// How much `SecStaticCodeCheckValidity` was asked to check.
    public enum Depth: Sendable, Equatable {
        /// The code directory, its CMS signature and certificate chain, and the main executable's pages, all
        /// architectures — but not the sealed resources or nested code. Never enough to call a signature valid.
        case quick
        /// Everything `codesign --verify --deep --strict` checks, offline: resources, nested code, all architectures.
        case full
    }

    /// Who vouches for the signing certificate, from code requirements the Security framework evaluated.
    public enum Anchor: Sendable, Equatable {
        /// `anchor apple`: Apple's own software.
        case apple
        /// A Developer ID Application certificate: `anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6]
        /// exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists`.
        case developerID
        /// Mac App Store distribution: `anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists`.
        case macAppStore
        /// Any other certificate Apple issued (`anchor apple generic`): Apple Development, Apple Distribution and the rest.
        case appleIssued
        /// A certificate whose chain does not reach Apple: self-signed (Vitrine's own release, G-3) or another CA's.
        /// The code is intact, but nobody Apple vouches for stands behind it.
        case notVouched
        /// Nothing to classify: ad hoc, unsigned, broken or not checked.
        case none

        /// Apple stands behind the certificate: certificate names may be shown as the signer.
        public var isVouchedByApple: Bool {
            switch self {
            case .apple, .developerID, .macAppStore, .appleIssued: true
            case .notVouched, .none: false
            }
        }

        /// The identities Gatekeeper opens a download from without asking (Apple's own, Developer ID, App Store).
        public var isDistributionIdentity: Bool {
            switch self {
            case .apple, .developerID, .macAppStore: true
            case .appleIssued, .notVouched, .none: false
            }
        }
    }

    public enum Notarization: Sendable, Equatable {
        /// The code satisfies the `notarized` requirement offline: the Security framework verified Apple's ticket for
        /// this code's hash (a stapled ticket, or one this Mac already holds).
        case verified
        /// Something shaped like a ticket travels with the file (a `Contents/CodeResources` ticket file or a disk image's
        /// ticket slot), but the Security framework did not verify it. Never "notarized".
        case ticketUnverified
        /// No ticket travels with the file and none was verified. macOS may still find one online.
        case none
    }

    public let status: Status
    public let depth: Depth
    /// The full check was asked for under a budget and did not finish in time: `status` and `depth` are what had
    /// finished by then (the quick check, or nothing).
    public let ranOutOfTime: Bool
    public let anchor: Anchor
    public let notarization: Notarization
    /// What the file carries that looks like a ticket, from its bytes alone: never a verdict.
    public let ticketFile: StapledTicket
    public let identifier: String?
    /// The team identifier the code directory states; meaningful only under an anchor Apple vouches for.
    public let teamIdentifier: String?
    /// `kSecCodeInfoFormat`, e.g. "bundle with Mach-O universal (x86_64 arm64)".
    public let format: String?
    /// The signer chain, leaf first, as the signature carries it. The names are the signer's own words: show them as
    /// the signer only when `anchor.isVouchedByApple`.
    public let certificates: [CertificateSummary]
    /// The signing time the signer claimed (`kSecCodeInfoTime`), unauthenticated.
    public let signingTime: Date?
    /// The secure timestamp from Apple's timestamp server (`kSecCodeInfoTimestamp`), present on Developer ID code.
    public let secureTimestamp: Date?
    public let flags: CodeSignatureFlags
    public let entitlements: [String: PlistValue]?
    /// The code directory hash of the chosen code directory, hex.
    public let cdHash: String?

    public var isHardenedRuntime: Bool { flags.isHardenedRuntime }

    /// The whole signature checked out with a certificate: every architecture, the sealed resources and nested code.
    /// The only state that may be called "valid".
    public var isFullyValid: Bool { status == .valid && depth == .full }

    public init(status: Status, depth: Depth, ranOutOfTime: Bool = false, anchor: Anchor = .none,
                notarization: Notarization = .none, ticketFile: StapledTicket = .notApplicable, identifier: String? = nil,
                teamIdentifier: String? = nil, format: String? = nil, certificates: [CertificateSummary] = [],
                signingTime: Date? = nil, secureTimestamp: Date? = nil, flags: CodeSignatureFlags = [],
                entitlements: [String: PlistValue]? = nil, cdHash: String? = nil) {
        self.status = status; self.depth = depth; self.ranOutOfTime = ranOutOfTime; self.anchor = anchor
        self.notarization = notarization; self.ticketFile = ticketFile; self.identifier = identifier
        self.teamIdentifier = teamIdentifier; self.format = format; self.certificates = certificates
        self.signingTime = signingTime; self.secureTimestamp = secureTimestamp; self.flags = flags
        self.entitlements = entitlements; self.cdHash = cdHash
    }
}

public enum SignatureVerifier {
    /// The requirement strings the anchor and notarization are decided by (G-34).
    enum Requirement {
        static let apple = "anchor apple"
        static let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        static let macAppStore = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"
        static let appleIssued = "anchor apple generic"
        static let notarized = "notarized"
    }

    /// Assesses the code at `url` (a bundle folder, a Mach-O file or a disk image) at `depth`, on the calling thread.
    /// Never throws: a file Security cannot read is reported as `.invalid` with its reason.
    public static func assess(url: URL, depth: SignatureAssessment.Depth = .full) -> SignatureAssessment {
        let ticket = StapledTicket.detect(at: url)
        switch staticCode(url) {
        case .failure(let error): return failure(error.status, depth: depth, ticket: ticket)
        case .success(let code):
            let quick = assess(code: code, depth: .quick, ticket: ticket)
            return depth == .quick ? quick : full(code: code, after: quick)
        }
    }

    /// The full check for a preview, given at most `budget` of the caller's time. The work runs on a worker thread;
    /// when the budget runs out first, the result is what had finished by then — the quick check (`depth == .quick`)
    /// or nothing (`.notChecked`) — with `ranOutOfTime` set, and the worker finishes on its own. A second call for
    /// the same file while the first is still checking joins it instead of starting another.
    public static func assess(url: URL, budget: Duration) -> SignatureAssessment {
        let ticket = StapledTicket.detect(at: url)
        return budgeted(key: url.standardizedFileURL.path, budget: budget, ticket: ticket,
                        quick: { () -> (SignatureAssessment, SecStaticCode?) in
                            switch staticCode(url) {
                            case .failure(let error): return (failure(error.status, depth: .full, ticket: ticket), nil)
                            case .success(let code): return (assess(code: code, depth: .quick, ticket: ticket), code)
                            }
                        },
                        full: { quick, code in code.map { full(code: $0, after: quick) } ?? quick })
    }

    // MARK: - The checks

    private static func staticCode(_ url: URL) -> Result<SecStaticCode, OSStatusError> {
        var codeRef: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &codeRef)
        guard created == errSecSuccess, let code = codeRef else { return .failure(OSStatusError(status: created)) }
        return .success(code)
    }

    struct OSStatusError: Error { let status: OSStatus }

    private static let offline = SecCSFlags.noNetworkAccess.rawValue | UInt32(kSecCSCheckAllArchitectures)
    private static let quickFlags = SecCSFlags(rawValue: offline | UInt32(kSecCSDoNotValidateResources))
    private static let fullFlags = SecCSFlags(rawValue: offline | UInt32(kSecCSCheckNestedCode) | UInt32(kSecCSStrictValidate))

    /// The quick check, then who vouches for the signer and whether Apple's ticket verifies — both evaluated as code
    /// requirements, which need only the code directory and its CMS signature, never the resources.
    private static func assess(code: SecStaticCode, depth: SignatureAssessment.Depth,
                               ticket: StapledTicket) -> SignatureAssessment {
        let validity = SecStaticCodeCheckValidity(code, depth == .quick ? quickFlags : fullFlags, nil)

        var infoRef: CFDictionary?
        let infoFlags = UInt32(kSecCSSigningInformation) | UInt32(kSecCSRequirementInformation)
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: infoFlags), &infoRef)
        let info = (infoStatus == errSecSuccess ? infoRef as? [String: Any] : nil) ?? [:]

        let flags = CodeSignatureFlags(rawValue: (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0)
        let certificates = (info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? [])
            .prefix(16).map { CertificateSummary(certificate: $0) }
        let entitlements = (info[kSecCodeInfoEntitlementsDict as String])
            .flatMap { PlistValue(propertyList: $0)?.dictionaryValue }
        let cdHash = (info[kSecCodeInfoUnique as String] as? Data).map { [UInt8]($0).hexString }

        let status: SignatureAssessment.Status
        if validity == errSecCSUnsigned {
            status = .unsigned
        } else if validity == errSecSuccess {
            status = flags.contains(.adhoc) || certificates.isEmpty ? .adhoc : .valid
        } else {
            status = .invalid(reason: message(validity), code: validity)
        }
        let anchor: SignatureAssessment.Anchor = status == .valid ? classify(code) : .none
        let notarized = status == .valid && satisfies(code, Requirement.notarized)
        return SignatureAssessment(status: status, depth: depth, anchor: anchor,
                                   notarization: notarization(verified: notarized, ticket: ticket), ticketFile: ticket,
                                   identifier: info[kSecCodeInfoIdentifier as String] as? String,
                                   teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
                                   format: info[kSecCodeInfoFormat as String] as? String,
                                   certificates: certificates,
                                   signingTime: info[kSecCodeInfoTime as String] as? Date,
                                   secureTimestamp: info[kSecCodeInfoTimestamp as String] as? Date,
                                   flags: flags, entitlements: entitlements, cdHash: cdHash)
    }

    /// The full check on top of a finished quick one: the sealed resources and nested code. The anchor and the ticket
    /// stand only while the whole signature does.
    private static func full(code: SecStaticCode, after quick: SignatureAssessment) -> SignatureAssessment {
        guard quick.status == .valid || quick.status == .adhoc else { return quick.at(.full) }
        let validity = SecStaticCodeCheckValidity(code, fullFlags, nil)
        guard validity != errSecSuccess else { return quick.at(.full) }
        return SignatureAssessment(status: .invalid(reason: message(validity), code: validity), depth: .full,
                                   notarization: notarization(verified: false, ticket: quick.ticketFile),
                                   ticketFile: quick.ticketFile, identifier: quick.identifier,
                                   teamIdentifier: quick.teamIdentifier, format: quick.format,
                                   certificates: quick.certificates, signingTime: quick.signingTime,
                                   secureTimestamp: quick.secureTimestamp, flags: quick.flags,
                                   entitlements: quick.entitlements, cdHash: quick.cdHash)
    }

    /// Who vouches for the signer, most specific first.
    private static func classify(_ code: SecStaticCode) -> SignatureAssessment.Anchor {
        if satisfies(code, Requirement.apple) { return .apple }
        if satisfies(code, Requirement.developerID) { return .developerID }
        if satisfies(code, Requirement.macAppStore) { return .macAppStore }
        if satisfies(code, Requirement.appleIssued) { return .appleIssued }
        return .notVouched
    }

    /// The code satisfies the requirement, evaluated offline. Uses the quick flags, so the validation the quick
    /// check already did is reused and only the requirement is evaluated.
    static func satisfies(_ code: SecStaticCode, _ text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, quickFlags, requirement) == errSecSuccess
    }

    private static func notarization(verified: Bool, ticket: StapledTicket) -> SignatureAssessment.Notarization {
        if verified { return .verified }
        return ticket.isPresent ? .ticketUnverified : .none
    }

    private static func failure(_ status: OSStatus, depth: SignatureAssessment.Depth,
                                ticket: StapledTicket) -> SignatureAssessment {
        let result: SignatureAssessment.Status = status == errSecCSUnsigned
            ? .unsigned : .invalid(reason: message(status), code: status)
        return SignatureAssessment(status: result, depth: depth,
                                   notarization: notarization(verified: false, ticket: ticket), ticketFile: ticket)
    }

    static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? String(localized: "Security error \(status)", bundle: .module, comment: "A code-signing check failed and the system gave no message; the argument is the error number.")
    }

    // MARK: - The budget

    /// One file's check in flight: the quick result once it is in, then the full one. Waiters read whichever has
    /// finished when their budget runs out.
    final class Job: @unchecked Sendable {
        private let condition = NSCondition()
        private var quick: SignatureAssessment?
        private var full: SignatureAssessment?

        func post(quick value: SignatureAssessment) { condition.lock(); quick = value; condition.broadcast(); condition.unlock() }
        func post(full value: SignatureAssessment) { condition.lock(); full = value; condition.broadcast(); condition.unlock() }

        func wait(_ budget: Duration, ticket: StapledTicket) -> SignatureAssessment {
            let seconds = Double(budget.components.seconds) + Double(budget.components.attoseconds) / 1e18
            let deadline = Date(timeIntervalSinceNow: max(0, seconds))
            condition.lock()
            defer { condition.unlock() }
            while full == nil, condition.wait(until: deadline) {}
            if let full { return full }
            if let quick { return quick.outOfTime() }
            return SignatureAssessment(status: .notChecked, depth: .quick, ranOutOfTime: true,
                                       notarization: notarization(verified: false, ticket: ticket), ticketFile: ticket)
        }
    }

    private static let jobs = Mutex<[String: Job]>([:])

    /// Runs `quick` then `full` on a worker thread (or joins the one already running for `key`) and waits at most
    /// `budget` for the full result. Internal so tests can stand in a slow check.
    static func budgeted(key: String, budget: Duration, ticket: StapledTicket,
                         quick: @escaping @Sendable () -> (SignatureAssessment, SecStaticCode?),
                         full: @escaping @Sendable (SignatureAssessment, SecStaticCode?) -> SignatureAssessment) -> SignatureAssessment {
        let (job, isNew) = jobs.withLock { running -> (Job, Bool) in
            if let job = running[key] { return (job, false) }
            let job = Job()
            running[key] = job
            return (job, true)
        }
        if isNew {
            let work = StaticCodeBox(quick: quick, full: full)
            DispatchQueue.global(qos: .userInitiated).async {
                let (first, code) = work.quick()
                job.post(quick: first)
                let last = work.full(first, code)
                job.post(full: last)
                _ = jobs.withLock { running in running.removeValue(forKey: key) }
            }
        }
        return job.wait(budget, ticket: ticket)
    }

    /// Carries the two stages to the worker thread; the static code object they pass between them never leaves it.
    private struct StaticCodeBox: @unchecked Sendable {
        let quick: @Sendable () -> (SignatureAssessment, SecStaticCode?)
        let full: @Sendable (SignatureAssessment, SecStaticCode?) -> SignatureAssessment
    }
}

extension SignatureAssessment {
    /// The same result, said to come from `depth`.
    func at(_ depth: Depth) -> SignatureAssessment {
        SignatureAssessment(status: status, depth: depth, ranOutOfTime: ranOutOfTime, anchor: anchor,
                            notarization: notarization, ticketFile: ticketFile, identifier: identifier,
                            teamIdentifier: teamIdentifier, format: format, certificates: certificates,
                            signingTime: signingTime, secureTimestamp: secureTimestamp, flags: flags,
                            entitlements: entitlements, cdHash: cdHash)
    }

    /// The same quick result, marked as all that finished within the budget.
    func outOfTime() -> SignatureAssessment {
        SignatureAssessment(status: status, depth: .quick, ranOutOfTime: true, anchor: anchor,
                            notarization: notarization, ticketFile: ticketFile, identifier: identifier,
                            teamIdentifier: teamIdentifier, format: format, certificates: certificates,
                            signingTime: signingTime, secureTimestamp: secureTimestamp, flags: flags,
                            entitlements: entitlements, cdHash: cdHash)
    }
}

/// What a file carries that looks like Apple's notarization ticket, read from its bytes and never verified: the
/// ticket's Apple signature and its binding to the code's hash are the Security framework's to check, through the
/// `notarized` requirement (`SignatureAssessment.notarization`). Anyone can write these bytes.
///
/// `stapler staple` writes an app's (or any bundle's) ticket to `Contents/CodeResources` — a file beside
/// `_CodeSignature/`, outside the resource seal — whose bytes start with the magic `s8ch` (seen on this machine's
/// stapled Developer ID apps, 2026-10-29). A disk image carries it in its code signature's ticket slot (0x10002).
public enum StapledTicket: Sendable, Equatable {
    /// A ticket-shaped file or slot is present: its version (from a bundle's file) and size. Not verified.
    case present(version: UInt32?, size: Int64)
    case notStapled
    /// A `Contents/CodeResources` file exists but is not ticket-shaped (its reason).
    case unrecognized(String)
    /// Neither a bundle nor a disk image: Mach-O files cannot be stapled.
    case notApplicable

    static let magic: [UInt8] = Array("s8ch".utf8)

    /// Looks for something ticket-shaped in the bundle or disk image at `url`.
    public static func detect(at url: URL) -> StapledTicket {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .notApplicable }
        guard isDirectory.boolValue else { return diskImage(at: url) }
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let ticketURL: URL
        if FileManager.default.fileExists(atPath: contents.path) {
            ticketURL = contents.appendingPathComponent("CodeResources")
        } else {
            // A flat (iOS-style) bundle has no Contents folder; its ticket would sit at the top level.
            ticketURL = url.appendingPathComponent("CodeResources")
        }
        guard let source = try? BinaryFileSource(url: ticketURL) else { return .notStapled }
        return parse(head: (try? source.read(at: 0, count: 8)) ?? [], size: source.size)
    }

    /// A disk image's ticket slot; `.notApplicable` for any other file.
    static func diskImage(at url: URL) -> StapledTicket {
        guard let source = try? BinaryFileSource(url: url), let image = DiskImageReader.signatureOnly(source: source) else {
            return .notApplicable
        }
        guard let slot = image.signature?.slots.first(where: { $0.type == EmbeddedSignature.ticketSlot }) else { return .notStapled }
        return .present(version: nil, size: Int64(slot.length))
    }

    static func parse(head: [UInt8], size: Int64) -> StapledTicket {
        guard head.count >= 8, Array(head[0..<4]) == magic else {
            return .unrecognized("Contents/CodeResources does not start with the ticket magic")
        }
        return .present(version: head.le32(at: 4), size: size)
    }

    /// Something ticket-shaped is present. Not a verdict: see `SignatureAssessment.notarization`.
    public var isPresent: Bool { if case .present = self { true } else { false } }
}
