import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

/// VitrineHelper (X-3, ARCHITECTURE §2 and §8): the small background agent the sandboxed Quick Look extensions ask to
/// act for them (Open in…, Reveal, open a link, open at line, extract a member) and to run the on-device model for
/// A-9's summary (G-28, ruled 2026-11-01). It is registered by the app with SMAppService and listens on a mach
/// service named under the app group, the one prefix a sandboxed extension may look up. roadmap: S-10 (X-3), S-21 (A-9)
public enum HelperService {
    /// The app group the extensions and the helper share; a sandboxed process may only reach mach services whose names
    /// start with it.
    public static let appGroup = "MPD7MLYSRW.io.github.xbtdmt.vitrine"
    /// The helper's mach service.
    public static let machServiceName = appGroup + ".helper"
    /// The launchd property list SMAppService registers, inside the app at Contents/Library/LaunchAgents.
    public static let launchAgentPlistName = "io.github.xbtdmt.vitrine.helper.plist"
    /// The launchd label in that property list.
    public static let launchdLabel = "io.github.xbtdmt.vitrine.helper"
    /// Raised whenever the protocol changes, so an extension and a helper from different builds notice.
    public static let protocolVersion = 3
    /// Who may connect (G-33): code signed by exactly the certificate that signed this process — the app, its
    /// extensions and its command share it, whatever signs a release (a development certificate, a self-signed
    /// identity, a Developer ID later). nil for an ad-hoc signature, which has no certificate to match: the helper then
    /// answers no one (fails closed). The SHA-1 of the leaf's DER is the hash form code-signing requirements take.
    public static func clientRequirement(leafCertificateDER: Data?) -> String? {
        guard let der = leafCertificateDER, !der.isEmpty else { return nil }
        let hex = Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return "certificate leaf = H\"\(hex)\""
    }

    /// The leaf certificate that signed the running process, or nil when it is ad hoc or unsigned.
    public static func ownLeafCertificateDER() -> Data? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    /// The requirement each side puts on the other (G-33): the helper on its callers, and the previews on the helper
    /// they reach by name, so neither talks to code signed by any other certificate. Read once per process; nil when
    /// this process is ad hoc or unsigned, and then both sides fail closed.
    public static let ownSignerRequirement: String? = clientRequirement(leafCertificateDER: ownLeafCertificateDER())

    /// The interface the extensions call, for NSXPCConnection.
    public static func interface() -> NSXPCInterface { NSXPCInterface(with: VitrineHelperProtocol.self) }
}

/// What the helper offers over XPC. Every request will name a file the person previewed (a security-scoped bookmark,
/// checked by the helper); `ping` names nothing and does nothing but answer. roadmap: S-10 (X-3)
@objc public protocol VitrineHelperProtocol {
    /// The helper's protocol version and the fingerprint of the executable it runs from, so a caller can tell the
    /// helper is there, compatible, and the one this app ships (HelperRegistration).
    func ping(reply: @escaping @Sendable (_ protocolVersion: Int, _ fingerprint: String) -> Void)

    // Each action replies with nil when done, or a plain sentence saying why it was refused or failed (G-31).
    /// The apps that can open the file, default first, as [path, name, "1" when it is the default]; empty for a
    /// program or script (G-31), which the helper never opens.
    func applications(forOpening path: String, reply: @escaping @Sendable (_ apps: [[String]]) -> Void)
    /// Opens the file with an app Launch Services lists for it; never a program, script, installer or app.
    func open(_ path: String, withApplication appPath: String, reply: @escaping @Sendable (_ error: String?) -> Void)
    /// Selects the file in a Finder window.
    func reveal(_ path: String, reply: @escaping @Sendable (_ error: String?) -> Void)
    /// Opens an http, https or mailto link in the person's default app for it.
    func openLink(_ link: String, reply: @escaping @Sendable (_ error: String?) -> Void)
    /// Opens the file at a line in an installed editor (`HelperRules.Editor` raw value).
    func open(_ path: String, atLine line: Int, editor: String, reply: @escaping @Sendable (_ error: String?) -> Void)
    /// The editors of `HelperRules.Editor` installed on this Mac, as raw values.
    func installedEditors(reply: @escaping @Sendable (_ editors: [String]) -> Void)
    /// Writes one member of the archive into Downloads (unique name, quarantined), reveals it, never opens it.
    func extract(member: String, fromArchive path: String, reply: @escaping @Sendable (_ destination: String?, _ error: String?) -> Void)
    /// Whether Apple's on-device model is ready for a summary on this Mac (A-9); the strip is drawn only then.
    func canSummarize(reply: @escaping @Sendable (_ ready: Bool) -> Void)
    /// A short summary of the text from Apple's on-device model (A-9); nil and a reason when the model is missing.
    func summarize(_ text: String, reply: @escaping @Sendable (_ summary: String?, _ error: String?) -> Void)
}

/// When the app checks its helper at launch (X-3, SP-3): launchd will not start a replaced helper binary under the old
/// registration (exit 78 until it is registered again, measured 2026-11-01), so an app update must re-register. The
/// helper reports a fingerprint of its own executable; the app compares it with the helper inside its bundle.
/// A helper the person never turned on, or turned off, is left alone. roadmap: S-10 (X-3)
public enum HelperRegistration {
    public enum State: Equatable, Sendable { case notRegistered, enabled, requiresApproval, notFound }
    public enum Step: Equatable, Sendable { case nothing, reregister }

    /// `answeredFingerprint` is nil when the helper did not answer.
    public static func launchStep(state: State, answeredFingerprint: String?, bundledFingerprint: String?) -> Step {
        guard state == .enabled else { return .nothing }
        guard let answered = answeredFingerprint else { return .reregister }
        guard let bundled = bundledFingerprint else { return .nothing }
        return answered == bundled ? .nothing : .reregister
    }

    /// The fingerprint both sides compute: SHA-256 of the executable's bytes, hex, first 16 characters.
    public static func fingerprint(of data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// What each action may touch (G-31), as checks the helper runs and the tests hold. roadmap: S-10 (X-3)
public enum HelperRules {
    /// Why the helper refused, sent as `refusal:<code>` so the preview can say it in the person's language.
    public enum Refusal: String, Sendable, CaseIterable {
        case missing, runs, notAnApp, link, editor, member, tooLarge, model
        public var reply: String { "refusal:" + rawValue }
        public static func from(_ reply: String) -> Refusal? {
            reply.hasPrefix("refusal:") ? Refusal(rawValue: String(reply.dropFirst(8))) : nil
        }
    }

    /// Links the helper opens; anything else (file:, javascript:, a custom app scheme) is refused.
    public static let linkSchemes: Set<String> = ["http", "https", "mailto"]

    public static func allowedLink(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(),
              linkSchemes.contains(scheme) else { return nil }
        if scheme != "mailto", url.host?.isEmpty ?? true { return nil }
        return url
    }

    /// Types whose default app would run them: programs, apps, scripts, installers, workflows.
    public static let executableTypes: [UTType] = [
        .executable, .application, .applicationBundle, .script, .shellScript,
        UTType("com.apple.installer-package-archive"), UTType("com.apple.terminal.shell-script"),
        UTType("com.apple.automator-workflow"), UTType("com.apple.applescript.script"), UTType("com.apple.applescript.text"),
        UTType("com.apple.terminal.terminal-settings"), UTType("com.apple.shortcut"),
    ].compactMap { $0 }

    /// The file would run, not just open: an executable or script type, an app bundle, or an executable file that
    /// starts with `#!`.
    public static func isExecutableContent(_ url: URL, type: UTType?, isExecutableFile: Bool, firstBytes: [UInt8]) -> Bool {
        if let type, executableTypes.contains(where: { type.conforms(to: $0) }) { return true }
        if url.pathExtension.lowercased() == "app" { return true }
        return isExecutableFile && firstBytes.starts(with: [0x23, 0x21])
    }

    /// A member path that stays inside the archive's own tree: relative, no `..`, not empty.
    public static func safeMemberPath(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts.joined(separator: "/")
    }

    /// `name`, or `name 2`, `name 3` … before the extension, the first that does not exist in `folder`.
    public static func uniqueDestination(for name: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// At most this much text goes to the model (its window is 8,192 tokens, SP-4).
    public static let maxSummaryCharacters = 24_000

    public static func summaryInput(_ text: String) -> String { String(text.prefix(maxSummaryCharacters)) }

    /// The editors "open at line" knows (the code view's Copy-as menu, S-5), by the URL or tool each one takes.
    public enum Editor: String, CaseIterable, Sendable {
        case vscode, cursor, zed, bbedit, xcode

        public var bundleIdentifier: String {
            switch self {
            case .vscode: "com.microsoft.VSCode"
            case .cursor: "com.todesktop.230313mzl4w4u92"
            case .zed: "dev.zed.Zed"
            case .bbedit: "com.barebones.bbedit"
            case .xcode: "com.apple.dt.Xcode"
            }
        }

        public var displayName: String {
            switch self {
            case .vscode: "Visual Studio Code"
            case .cursor: "Cursor"
            case .zed: "Zed"
            case .bbedit: "BBEdit"
            case .xcode: "Xcode"
            }
        }

        /// The editor's own URL for a file at a line; nil for Xcode, which takes `xed --line`.
        public func url(file path: String, line: Int) -> URL? {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            switch self {
            case .vscode: return URL(string: "vscode://file\(encoded):\(max(1, line))")
            case .cursor: return URL(string: "cursor://file\(encoded):\(max(1, line))")
            case .zed: return URL(string: "zed://file\(encoded):\(max(1, line))")
            case .bbedit:
                let file = URL(fileURLWithPath: path).absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                return URL(string: "x-bbedit://open?url=\(file)&line=\(max(1, line))")
            case .xcode: return nil
            }
        }
    }
}
