// Every way an update check or install can stop (G-21). Each case carries a plain reason the update banner shows as is;
// none of them carries a secret, a key or file contents. Any of them leaves the installed app untouched.
import Foundation
import OSLog

public enum UpdateError: Error, Equatable, Sendable {
    /// This build has no real update key or feed address (the placeholder values from project.yml).
    case notConfigured
    /// An address that is not HTTPS (the feed, a redirect or the download).
    case insecureURL(String)
    /// The server redirected to a different host or to plain HTTP; nothing from it was used.
    case redirectRefused(from: String, to: String)
    /// The request failed before an answer came (offline, DNS, TLS, timeout).
    case network(String)
    /// The server answered with something other than 200 OK.
    case httpStatus(Int)
    /// The feed is larger than any real feed is.
    case feedTooLarge
    /// The feed is not the signed-feed JSON.
    case feedMalformed
    /// The feed's signature does not verify with the key built into Vitrine.
    case badSignature
    /// The signed manifest is missing a field or holds an impossible value (named, never a value).
    case manifestInvalid(String)
    /// The manifest is for another app.
    case wrongApp(String)
    /// The update needs a newer macOS than this Mac runs.
    case systemTooOld(required: String)
    /// The offered version is not newer than the running one (no downgrade, no reinstall).
    case notNewer(offered: String, current: String)
    /// The download's size differs from the signed manifest's.
    case downloadSizeMismatch(expected: Int64, got: Int64)
    /// The download's SHA-256 differs from the signed manifest's.
    case downloadHashMismatch
    /// The disk image could not be opened read-only.
    case diskImage(String)
    /// The disk image does not hold exactly one app at its top level.
    case appMissingInImage
    /// The app in the update fails code-signature validation (damaged or altered).
    case signatureInvalid(String)
    /// The app in the update is validly signed, but not by the identity that signed this copy of Vitrine.
    case requirementNotMet
    /// This copy of Vitrine has no stable signature (ad-hoc), so no update can be shown to come from the same developer.
    case ownSignatureUnusable
    /// The app in the update is not built the way a release must be (hardened runtime, no exceptions).
    case unsafeBuild(String)
    /// The app in the update says a different version or bundle than the signed manifest.
    case versionMismatch(expected: String, found: String)
    /// Vitrine cannot replace itself where it is (read-only volume, translocated, no permission).
    case cannotReplace(String)
    /// A file step failed (temporary folder, copy, swap).
    case fileSystem(String)
    /// The install is done but the new copy could not be started.
    case relaunchFailed

    /// The sentence the update banner and the Check for Updates alert show.
    public var reason: String {
        switch self {
        case .notConfigured:
            String(localized: "This copy of Vitrine was built without an update key, so it can't check for new versions.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .insecureURL:
            String(localized: "The update address isn't a secure (HTTPS) address, so Vitrine didn't use it.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .redirectRefused(let from, let to):
            String(localized: "The update server at \(from) sent Vitrine to \(to). Vitrine only downloads from the address it was given.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .network(let detail):
            String(localized: "Vitrine couldn't reach the update server (\(detail)).", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .httpStatus(let code):
            String(localized: "The update server answered with error \(code).", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .feedTooLarge, .feedMalformed:
            String(localized: "The update information isn't in the expected format.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .badSignature:
            String(localized: "The update information isn't signed with Vitrine's update key, so Vitrine ignored it.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .manifestInvalid(let field):
            String(localized: "The signed update information has an invalid \(field).", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .wrongApp(let id):
            String(localized: "The update is for a different app (\(id)).", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .systemTooOld(let required):
            String(localized: "This update needs macOS \(required) or later.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .notNewer(let offered, let current):
            String(localized: "Version \(offered) isn't newer than the installed \(current).", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .downloadSizeMismatch, .downloadHashMismatch:
            String(localized: "The downloaded update doesn't match its signed description, so Vitrine discarded it.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .diskImage:
            String(localized: "The downloaded disk image couldn't be opened.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .appMissingInImage:
            String(localized: "The downloaded disk image doesn't hold the Vitrine app.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .signatureInvalid:
            String(localized: "The app in the update has a damaged or altered signature, so Vitrine discarded it.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .requirementNotMet:
            String(localized: "The app in the update isn't signed by the same developer as this copy, so Vitrine discarded it.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .ownSignatureUnusable:
            String(localized: "This copy of Vitrine isn't signed with a stable identity, so it can't verify updates. Download the new version yourself.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .unsafeBuild:
            String(localized: "The app in the update turns off a macOS code protection, so Vitrine discarded it.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .versionMismatch(let expected, let found):
            String(localized: "The app in the update is \(found), not the announced \(expected).", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .cannotReplace(let why):
            String(localized: "Vitrine can't replace itself here: \(why).", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .fileSystem:
            String(localized: "A file step of the update failed.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        case .relaunchFailed:
            String(localized: "The update is installed, but Vitrine couldn't relaunch. Open it again yourself.", bundle: .module, comment: "Why an update check or install failed; one sentence in the update alert.")
        }
    }
}

/// The update log: steps and reason codes only (never a key, a signature or file contents).
enum UpdateLog {
    static let logger = Logger(subsystem: "io.github.xbtdmt.vitrine", category: "update")
}
