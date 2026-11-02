import AppKit
import VitrineArchive
import VitrineBinary
import VitrineDocument
import VitrineSupport

/// Torrents, configuration profiles and iOS and Android apps for the Glass Case card (cards r3-a, trust r3-a states
/// for the torrent, the profile and the .ipa): the facts the card's sentence, numbers and answers are worded from, the
/// badges that set its verdict, and what the card shows one switch away (the app's or torrent's files in the archive
/// outline). Everything is read statically: no tracker is contacted, no profile installed, no app run. Installers
/// get their contents here too (the package's own xar listing). roadmap: S-8
enum PackageFacts {
    /// What the card shows beside the document: the object's own picture and the listing behind "Contents".
    struct Extras {
        var icon: NSImage?
        var contents: ArchiveListing?
        /// The bytes contents are read from (nested archives); nil for a torrent, which only names its files.
        var contentsSource: (any ArchiveByteSource)?
        /// The viewer switch's name for the contents: "Contents", or "Files" for a torrent.
        var contentsTitle = "Contents"
        /// An installer's scripts as text, for the Scripts view (T-2): name and text, in the package's order.
        var scripts: [(name: String, text: String)] = []
        /// More views the viewer switch offers after the card (and its contents): a lockfile's Packages and Source.
        var extraViews: [(title: String, view: DocumentView)] = []
        /// A format view for the stage (format views F1–F9): built on the main actor when the card is.
        var stage: StageFactory?
    }

    /// Fact values the cards read back (PackageCards compares against them). Each is one localized string, so the
    /// fact written here and the card's check agree in every language.
    enum Word {
        static var yes: String { String(localized: "Yes", bundle: .previewKit, comment: "A fact's value: yes.") }
        static var no: String { String(localized: "No", bundle: .previewKit, comment: "A fact's value: no.") }
        static var notSigned: String { String(localized: "Not signed", bundle: .previewKit, comment: "A signature fact's value, and a badge: the file has no signature.") }
        static var encrypted: String { String(localized: "Encrypted", bundle: .previewKit, comment: "A configuration profile's payload count when its payloads are encrypted.") }
        static var withPassword: String { String(localized: "With a password", bundle: .previewKit, comment: "Whether a configuration profile can be removed: only with its removal password.") }
        static var signedAndTrusted: String { String(localized: "Signed and trusted", bundle: .previewKit, comment: "A configuration profile's signature: signed by a certificate macOS trusts.") }
        static var broken: String { String(localized: "Broken", bundle: .previewKit, comment: "A signature's state: it does not match the content.") }
        static var signedUnverified: String { String(localized: "Signed, but macOS cannot verify it", bundle: .previewKit, comment: "A configuration profile's signature: signed by a certificate macOS does not trust.") }
        static var signedNotChecked: String { String(localized: "Signed (not checked)", bundle: .previewKit, comment: "A configuration profile's signature: signed, trust not evaluated.") }
        static var appStoreEncrypted: String { String(localized: "App Store (encrypted)", bundle: .previewKit, comment: "An iOS app's distribution: downloaded from the App Store, its code encrypted.") }
        static var privateTrackers: String { String(localized: "Yes, only its trackers", bundle: .previewKit, comment: "Whether a torrent is private: only its own trackers share it.") }
        static var expired: String { String(localized: "Expired", bundle: .previewKit, comment: "Badge, verdict chip and card label: the provisioning profile has expired.") }
        static var cannotBeRemoved: String { String(localized: "Cannot be removed", bundle: .previewKit, comment: "Badge: once installed, the configuration profile cannot be removed.") }
    }

    /// Facts and lines in step: each fact is also a line of the copyable text view.
    struct Builder {
        var facts: [Fact] = []
        var lines: [String] = []
        var badges: [Badge] = []

        mutating func add(_ key: String, _ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            facts.append(Fact(key: key, label: label, value: value))
            lines.append(label.padding(toLength: 22, withPad: " ", startingAt: 0) + value)
        }

        mutating func headline(_ value: String) {
            facts.insert(Fact(key: "headline", label: String(localized: "Summary", bundle: .previewKit, comment: "Fact label: the one-line summary of the file."),
                              value: value), at: 0)
        }

        func document(kind: FileKind) -> PreviewDocument {
            PreviewDocument(kind: kind, facts: facts, badges: badges, views: [.text(lines.joined(separator: "\n"))])
        }
    }

    static func read(url: URL, kind: FileKind) throws -> (PreviewDocument, Extras)? {
        switch kind {
        case .torrent: return try torrent(url: url, kind: kind)
        case .configurationProfile: return try configurationProfile(url: url, kind: kind)
        case .keyMaterial: return try keyMaterial(url: url, kind: kind)
        case .lockfile: return try lockfile(url: url, kind: kind)
        case .reader(let id): return try reader(url: url, kind: kind, id: id)
        case .archive(.ipa): return try iosApp(url: url, kind: kind)
        case .archive(.apk): return try androidApp(url: url, kind: kind)
        default: return nil
        }
    }

    /// An installer's own listing (a xar, read by libarchive), for its Contents view.
    static func installerContents(url: URL) -> Extras {
        guard let source = try? FileByteSource(url: url), let listing = try? VitrineArchive.list(source: source, fileName: url.lastPathComponent)
        else { return Extras() }
        return Extras(contents: listing, contentsSource: source)
    }

    static func size(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    static func date(_ d: Date?) -> String? { d.map { $0.formatted(date: .abbreviated, time: .omitted) } }

    /// The separator between the items of a list, in the reader's language.
    static var listSeparator: String { String(localized: ", ", bundle: .previewKit, comment: "Separator between the items of a list.") }

    // MARK: Counted phrases (the singular and the plural are separate phrases)

    static func filesPhrase(_ n: Int) -> String {
        if n == 1 { return String(localized: "1 file", bundle: .previewKit, comment: "A count of exactly one file.") }
        let count = n.formatted()
        return String(localized: "\(count) files", bundle: .previewKit, comment: "A count of files; e.g. “3 files”.")
    }

    static func payloadsPhrase(_ n: Int) -> String {
        if n == 1 { return String(localized: "1 payload", bundle: .previewKit, comment: "A configuration profile with exactly one payload.") }
        let count = n.formatted()
        return String(localized: "\(count) payloads", bundle: .previewKit, comment: "How many payloads a configuration profile has; e.g. “3 payloads”.")
    }

    static func devicesPhrase(_ n: Int) -> String {
        if n == 1 { return String(localized: "1 device", bundle: .previewKit, comment: "A provisioning profile that names exactly one device.") }
        let count = n.formatted()
        return String(localized: "\(count) devices", bundle: .previewKit, comment: "How many devices a provisioning profile names; e.g. “12 devices”.")
    }

    static func permissionsPhrase(_ n: Int) -> String {
        if n == 1 { return String(localized: "1 permission", bundle: .previewKit, comment: "An Android app that asks for exactly one permission.") }
        let count = n.formatted()
        return String(localized: "\(count) permissions", bundle: .previewKit, comment: "How many permissions an Android app asks for; e.g. “3 permissions”.")
    }

    /// The torrent's caution badge title: "1 program inside", "3 programs inside".
    static func programsInsideTitle(_ n: Int) -> String {
        if n == 1 { return String(localized: "1 program inside", bundle: .previewKit, comment: "Badge: one file in the torrent runs when opened.") }
        let count = n.formatted()
        return String(localized: "\(count) programs inside", bundle: .previewKit, comment: "Badge: how many files in the torrent run when opened; e.g. “3 programs inside”.")
    }

    // MARK: Torrent (P-4)

    static func torrent(url: URL, kind: FileKind) throws -> (PreviewDocument, Extras) {
        let t = try TorrentReader.read(contentsOf: url)
        var b = Builder()
        let files = t.files.filter { !$0.isPadding }
        b.add("name", String(localized: "Name", bundle: .previewKit, comment: "Fact label: the torrent's name."), t.name ?? url.deletingPathExtension().lastPathComponent)
        b.add("files", String(localized: "Files", bundle: .previewKit, comment: "Fact label: how many files the torrent names."),
              files.count.formatted() + (t.filesTruncated ? "+" : ""))
        b.add("downloadSize", String(localized: "Download size", bundle: .previewKit, comment: "Fact label: the total size the torrent downloads."), size(t.totalSize))
        b.add("size", String(localized: "Size", bundle: .previewKit, comment: "Fact label: the .torrent file's own size."), BinaryFacts.fileSize(url))
        b.add("trackers", String(localized: "Trackers", bundle: .previewKit, comment: "Fact label: how many trackers the torrent lists."),
              t.trackers.isEmpty ? nil : t.trackers.count.formatted())
        b.add("trackerHosts", String(localized: "Shared through", bundle: .previewKit, comment: "Fact label: the trackers' host names."),
              t.trackers.compactMap { URL(string: $0)?.host }.uniqued.joined(separator: listSeparator))
        b.add("private", String(localized: "Private", bundle: .previewKit, comment: "Fact label: whether the torrent is private."), t.isPrivate ? Word.privateTrackers : Word.no)
        b.add("webSeeds", String(localized: "Web seeds", bundle: .previewKit, comment: "Fact label: how many web seeds the torrent lists."),
              t.webSeeds.isEmpty ? nil : t.webSeeds.count.formatted())
        b.add("pieceSize", String(localized: "Piece size", bundle: .previewKit, comment: "Fact label: the size of each piece of the torrent."), t.pieceLength.map(size))
        b.add("pieces", String(localized: "Pieces", bundle: .previewKit, comment: "Fact label: how many pieces the torrent has."), t.pieceCount?.formatted())
        b.add("version", String(localized: "Torrent version", bundle: .previewKit, comment: "Fact label: the BitTorrent format version (v1, v2, hybrid)."), t.version.rawValue)
        b.add("infoHash", String(localized: "Info-hash", bundle: .previewKit, comment: "Fact label: the torrent's info-hash."), t.infoHashV1 ?? t.infoHashV2)
        b.add("infoHashV2", String(localized: "Info-hash (v2)", bundle: .previewKit, comment: "Fact label: the torrent's version 2 info-hash."),
              t.infoHashV1 != nil ? t.infoHashV2 : nil)
        b.add("createdBy", String(localized: "Created by", bundle: .previewKit, comment: "Fact label: the program that made the torrent."), t.createdBy)
        b.add("created", String(localized: "Created", bundle: .previewKit, comment: "Fact label: when the torrent was made."), date(t.creationDate))
        b.add("comment", String(localized: "Comment", bundle: .previewKit, comment: "Fact label: the torrent's comment."), t.comment)
        b.add("source", String(localized: "Source", bundle: .previewKit, comment: "Fact label: the torrent's source field."), t.source)
        let largest = files.sorted { $0.size > $1.size }.prefix(3)
        b.add("largest", String(localized: "Largest", bundle: .previewKit, comment: "Fact label: the largest files the torrent names, with their sizes."),
              largest.map { "\(ArchivePath.components($0.path).last ?? $0.path) (\(size($0.size)))" }.joined(separator: listSeparator))

        // The files the torrent names, judged like an archive's members: what extraction (here, downloading) would
        // write, and whether any of it runs.
        let entries = t.files.map { ArchiveEntry(path: $0.path, type: .file, uncompressedSize: $0.size) }
        let listing = ArchiveListing(format: .fileList("Torrent"), fileSize: 0, entries: entries,
                                     coverage: t.filesTruncated
                                         ? .partial(listed: entries.count, total: nil,
                                                    reason: String(localized: "Long file list", bundle: .previewKit, comment: "Why a torrent's file list is shown in part: it is very long."))
                                         : .complete)
        let report = ArchiveSafety.scan(listing)
        let programs = (report.finding(.program)?.count ?? 0) + (report.finding(.disguisedProgram)?.count ?? 0)
        b.add("programs", String(localized: "Programs", bundle: .previewKit, comment: "Fact label: how many files in the torrent run when opened."), programs.formatted())
        let programPaths = (report.finding(.disguisedProgram)?.paths ?? []) + (report.finding(.program)?.paths ?? [])
        b.add("programNames", String(localized: "Programs inside", bundle: .previewKit, comment: "Fact label: the names of the files that run when opened."),
              programPaths.prefix(3).map { ArchivePath.components($0).last ?? $0 }.joined(separator: listSeparator))
        for f in report.findings where f.level == .danger {
            b.badges.append(Badge(level: .danger, title: f.title, detail: f.detail))
        }
        if programs > 0, !b.badges.contains(where: { $0.level == .danger }) {
            b.badges.append(Badge(level: .caution, title: programsInsideTitle(programs),
                                  detail: String(localized: "Downloading it brings files that run when opened; check where it came from.", bundle: .previewKit,
                                                 comment: "Badge detail: the torrent holds programs.")))
        }
        let total = size(t.totalSize)
        b.headline(files.count == 1
            ? String(localized: "1 file, \(total) to download", bundle: .previewKit, comment: "A torrent's summary: one file and its size; e.g. “1 file, 4 GB to download”.")
            : String(localized: "\(files.count.formatted()) files, \(total) to download", bundle: .previewKit,
                     comment: "A torrent's summary: how many files and their total size; e.g. “3 files, 4 GB to download”."))
        return (b.document(kind: kind), Extras(contents: listing, contentsTitle: "Files"))   // a view identifier; CapsuleView.displayTitle translates it
    }

    // MARK: Configuration profile (P-4)

    static func configurationProfile(url: URL, kind: FileKind) throws -> (PreviewDocument, Extras) {
        let p = try ConfigurationProfileReader.read(contentsOf: url)
        var b = Builder()
        b.add("name", String(localized: "Name", bundle: .previewKit, comment: "Fact label: the configuration profile's name."),
              p.displayName ?? url.deletingPathExtension().lastPathComponent)
        b.add("identifier", String(localized: "Identifier", bundle: .previewKit, comment: "Fact label: the profile's identifier."), p.identifier)
        b.add("organization", String(localized: "Organization", bundle: .previewKit, comment: "Fact label: the organization that made the profile."), p.organization)
        b.add("description", String(localized: "Description", bundle: .previewKit, comment: "Fact label: the profile's description."), p.description)
        b.add("payloadCount", String(localized: "Payloads", bundle: .previewKit, comment: "Fact label: how many payloads the profile has."),
              p.payloadsEncrypted ? Word.encrypted : p.payloads.count.formatted())
        b.add("payloadKinds", String(localized: "Changes", bundle: .previewKit, comment: "Fact label: what installing the profile changes."), phrase(p.payloads))
        b.add("payloadList", String(localized: "Payload list", bundle: .previewKit, comment: "Fact label: every payload, one a line."),
              p.payloads.map { [$0.kind, $0.summary].compactMap { $0 }.joined(separator: ": ") }.joined(separator: "\n"))
        b.add("size", String(localized: "Size", bundle: .previewKit, comment: "Fact label: the file size."), BinaryFacts.fileSize(url))
        b.add("scope", String(localized: "Scope", bundle: .previewKit, comment: "Fact label: whether the profile applies to the user or the system."), p.scope)
        b.add("removable", String(localized: "Removable", bundle: .previewKit, comment: "Fact label: whether the profile can be removed."),
              p.removalDisallowed ? Word.no : (p.hasRemovalPassword ? Word.withPassword : Word.yes))
        b.add("expires", String(localized: "Expires", bundle: .previewKit, comment: "Fact label: when the profile expires."), date(p.expirationDate))
        b.add("removalDate", String(localized: "Removed on", bundle: .previewKit, comment: "Fact label: when the profile removes itself."), date(p.removalDate))
        let signature = p.signature
        b.add("signed", String(localized: "Signature", bundle: .previewKit, comment: "Fact label: the profile's signature state."),
              signature == nil ? Word.notSigned : signatureWords(signature!))
        b.add("signer", String(localized: "Signed by", bundle: .previewKit, comment: "Fact label: who signed the profile."),
              signature?.signer?.commonName ?? signature?.signer?.summary)
        b.add("trustReason", String(localized: "Trust", bundle: .previewKit, comment: "Fact label: why macOS does not trust the signer."),
              signature?.trust.flatMap { if case .untrusted(let why) = $0 { why } else { nil } })

        let unverified = signature == nil || signature?.trust != .trusted
        if signature?.matchesContent == false {
            b.badges.append(Badge(level: .danger, title: String(localized: "Signature broken", bundle: .previewKit, comment: "Badge: the signature does not match the content."),
                                  detail: String(localized: "The profile was changed after it was signed.", bundle: .previewKit, comment: "Badge detail: a broken profile signature.")))
        }
        for payload in p.sensitivePayloads.prefix(4) {
            switch payload.type {
            case "com.apple.security.root":
                b.badges.append(Badge(level: .caution,
                                      title: unverified
                                          ? String(localized: "Unverified profile that also installs a root certificate", bundle: .previewKit,
                                                   comment: "Badge: an unsigned or untrusted profile installs a root certificate.")
                                          : String(localized: "Installs a root certificate", bundle: .previewKit, comment: "Badge: the profile installs a root certificate."),
                                      detail: String(localized: "A trusted root certificate lets its owner read secure web traffic on this Mac. Install only if your IT team sent it.",
                                                     bundle: .previewKit, comment: "Badge detail: why a root certificate matters.")))
            case "com.apple.mdm":
                b.badges.append(Badge(level: .caution,
                                      title: String(localized: "Enrols this Mac in device management", bundle: .previewKit, comment: "Badge: the profile enrols the Mac in MDM."),
                                      detail: String(localized: "Its server could then install apps, change settings and lock or erase the Mac.", bundle: .previewKit,
                                                     comment: "Badge detail: what device management allows.")))
            case "com.apple.proxy.http.global", "com.apple.dnsSettings.managed", "com.apple.webcontent-filter":
                let what = payload.kind
                let server = payload.summary
                b.badges.append(Badge(level: .caution,
                                      title: String(localized: "Routes this Mac's traffic", bundle: .previewKit, comment: "Badge: the profile sends web traffic through a proxy, DNS or filter."),
                                      detail: server.map {
                                          String(localized: "\(what) sends web traffic through \($0).", bundle: .previewKit,
                                                 comment: "Badge detail: the payload kind, then the server it names; e.g. “Global HTTP proxy sends web traffic through proxy.example.com:8080.”")
                                      } ?? String(localized: "\(what) sends web traffic through a server the profile names.", bundle: .previewKit,
                                                  comment: "Badge detail: the payload kind sends traffic through a server; e.g. “Encrypted DNS settings sends web traffic through a server the profile names.”")))
            default:
                let what = payload.kind
                b.badges.append(Badge(level: .caution,
                                      title: String(localized: "Changes \(what)", bundle: .previewKit, comment: "Badge: the profile changes a sensitive setting; the argument is the payload kind’s localized name, e.g. “Changes Privacy permissions”."),
                                      detail: String(localized: "It grants what only an administrator should: check who sent it.", bundle: .previewKit,
                                                     comment: "Badge detail: a sensitive payload.")))
            }
        }
        if p.removalDisallowed {
            b.badges.append(Badge(level: .caution, title: Word.cannotBeRemoved,
                                  detail: String(localized: "Once installed, only its administrator can remove it.", bundle: .previewKit, comment: "Badge detail: a profile that cannot be removed.")))
        }
        b.headline(p.payloadsEncrypted
            ? String(localized: "Encrypted payloads", bundle: .previewKit, comment: "A configuration profile's summary when its payloads are encrypted.")
            : payloadsPhrase(p.payloads.count))
        return (b.document(kind: kind), Extras())
    }

    static func signatureWords(_ s: ConfigurationProfile.Signature) -> String {
        if s.matchesContent == false { return Word.broken }
        switch s.trust {
        case .trusted?: return Word.signedAndTrusted
        case .untrusted?: return Word.signedUnverified
        case nil: return Word.signedNotChecked
        }
    }

    /// "Joins Wi-Fi “ExampleCorp”, adds an always-on VPN, trusts a new root certificate".
    static func phrase(_ payloads: [ConfigurationProfile.Payload]) -> String? {
        let parts: [String] = payloads.prefix(6).map { p in
            switch p.type {
            case "com.apple.wifi.managed":
                let network = p.summary?.components(separatedBy: " · ").first ?? ""
                return String(localized: "joins Wi-Fi \(network)", bundle: .previewKit, comment: "What a profile changes: it joins a Wi-Fi network; the argument is its quoted name.")
            case "com.apple.vpn.managed", "com.apple.vpn.managed.applayer":
                return p.summary?.contains(ConfigurationProfile.alwaysOnLabel) == true
                    ? String(localized: "adds an always-on VPN", bundle: .previewKit, comment: "What a profile changes: it adds a VPN that is always on.")
                    : String(localized: "adds a VPN", bundle: .previewKit, comment: "What a profile changes: it adds a VPN.")
            case "com.apple.security.root":
                return String(localized: "trusts a new root certificate", bundle: .previewKit, comment: "What a profile changes: it trusts a new root certificate.")
            case "com.apple.mdm":
                return String(localized: "enrols the Mac in device management", bundle: .previewKit, comment: "What a profile changes: it enrols the Mac in MDM.")
            default:
                let what = p.kind
                return String(localized: "sets \(what)", bundle: .previewKit, comment: "What a profile changes: it sets a kind of setting; the argument is the payload kind’s localized name, e.g. “sets Restrictions”.")
            }
        }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: listSeparator)
        let text = payloads.count > 6
            ? String(localized: "\(joined), and more", bundle: .previewKit, comment: "The end of a list of changes that goes on; the argument is the list.")
            : joined
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: iOS app (P-2)

    static func iosApp(url: URL, kind: FileKind) throws -> (PreviewDocument, Extras) {
        let source = try FileByteSource(url: url)
        let ipa = try IOSAppArchiveReader.read(source: source, fileName: url.lastPathComponent)
        var b = Builder()
        b.add("name", String(localized: "Name", bundle: .previewKit, comment: "Fact label: the app's name."), ipa.name ?? url.deletingPathExtension().lastPathComponent)
        b.add("identifier", String(localized: "Identifier", bundle: .previewKit, comment: "Fact label: the app's bundle identifier."), ipa.identifier)
        b.add("version", String(localized: "Version", bundle: .previewKit, comment: "Fact label: the app's version and build."),
              [ipa.shortVersion, ipa.buildVersion.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
        b.add("minimumOS", String(localized: "Requires", bundle: .previewKit, comment: "Fact label: the oldest iOS the app runs on."),
              ipa.minimumOSVersion.map { version in String(localized: "iOS \(version) or later", bundle: .previewKit, comment: "The oldest iOS an app runs on; e.g. “iOS 17.0 or later”.") })
        b.add("devices", String(localized: "Devices", bundle: .previewKit, comment: "Fact label: the device families the app is made for."),
              ipa.deviceFamilies.joined(separator: ", "))
        b.add("architectures", String(localized: "Architectures", bundle: .previewKit, comment: "Fact label: the CPU architectures in the app."),
              ipa.architectures.joined(separator: ", "))
        b.add("size", String(localized: "Size", bundle: .previewKit, comment: "Fact label: the file size."), BinaryFacts.fileSize(url))
        // Who signed it (G-34, S-16 follow-up B): a certificate is the signer, and the profile's team the maker, only
        // when the app's signature verified in process (and, for the team, the profile vouches for it). Everything
        // else is the certificate's or profile's own claim, labelled so.
        var signatureBadges: [Badge] = []
        let verified = ipa.signature?.verification.isVerified == true
        if let signature = ipa.signature {
            let package = PackageSignature(styles: ["CMS"], certificates: signature.certificates, size: nil, verification: signature.verification)
            BinaryFacts.installerSignatureFacts(package, add: { key, label, value in b.add(key, label, value) }, badges: &signatureBadges)
            if verified {
                let leaf = signature.certificates.first
                if let id = signature.teamIdentifier, ipa.profileVouchesForSigner || leaf?.organizationalUnit == id {
                    b.add("teamIdentifier", String(localized: "Team ID", bundle: .previewKit, comment: "Fact label: the Apple developer team identifier the verified signature names."), id)
                }
                b.add("signatureScope", String(localized: "Checked", bundle: .previewKit, comment: "Fact label: which parts of an iOS app its verified signature check covered."),
                      signature.unchecked.contains(.encryptedCode)
                          ? String(localized: "Its Info.plist and unencrypted code; not its App Store–encrypted code or its other files", bundle: .previewKit,
                                   comment: "What an iOS app's signature check covered: Info.plist and the code the App Store did not encrypt; the encrypted code and the other files were not checked.")
                          : String(localized: "Its code and Info.plist; not its other files, which iOS checks when it installs the app", bundle: .previewKit,
                                   comment: "What an iOS app's signature check covered: the code and Info.plist; the other files were not checked."))
            }
        } else if ipa.isExecutableSigned == false {
            b.add("signed", String(localized: "Signature", bundle: .previewKit, comment: "Fact label: the code signature's state."), Word.notSigned)
            signatureBadges.append(Badge(level: .caution, title: Word.notSigned,
                                         detail: String(localized: "iOS will not install an unsigned app.", bundle: .previewKit, comment: "Badge detail: an unsigned iOS app.")))
        } else {
            signatureBadges.append(Badge(level: .caution, title: BinaryFacts.notVerifiedWord,
                                         detail: String(localized: "Its executable is larger than Vitrine reads, so its signature was not checked.", bundle: .previewKit,
                                                        comment: "Badge detail: an iOS app's executable is too large for its signature to be checked.")))
        }
        if ipa.signature == nil {
            let claimed = ipa.signerCertificates.first ?? ipa.profile?.developerCertificates.first
            b.add("claimedSigner", BinaryFacts.claimedSignerLabel, claimed.map { $0.commonName ?? $0.summary })
        }
        b.add("certificateExpires", String(localized: "Certificate expires", bundle: .previewKit, comment: "Fact label: when the signing certificate expires."),
              date(ipa.profile?.developerCertificates.first?.notValidAfter))
        if let profile = ipa.profile {
            b.add("profile", String(localized: "Profile", bundle: .previewKit, comment: "Fact label: the embedded provisioning profile."),
                  [profile.name, profile.distribution.localizedName, profile.deviceCount > 0 ? devicesPhrase(profile.deviceCount) : nil]
                      .compactMap { $0 }.joined(separator: " · "))
            b.add("distribution", String(localized: "Distribution", bundle: .previewKit, comment: "Fact label: how the app is distributed."), profile.distribution.localizedName)
            b.add("devicesRegistered", String(localized: "Registered devices", bundle: .previewKit, comment: "Fact label: how many devices the profile names."),
                  profile.deviceCount > 0 ? profile.deviceCount.formatted() : nil)
            if verified, ipa.profileVouchesForSigner {
                b.add("team", String(localized: "Team", bundle: .previewKit, comment: "Fact label: the developer team."), profile.teamName ?? profile.teamIdentifiers.first)
            } else {
                b.add("claimedTeam", String(localized: "Team (not verified)", bundle: .previewKit,
                                            comment: "Fact label: the developer team a provisioning profile names, which nothing verified for this app."),
                      profile.teamName ?? profile.teamIdentifiers.first)
            }
            b.add("expires", String(localized: "Profile expires", bundle: .previewKit, comment: "Fact label: when the provisioning profile expires."), date(profile.expirationDate))
            b.add("expiresIn", String(localized: "Expires in", bundle: .previewKit, comment: "Fact label: how long until the profile expires."),
                  profile.expirationDate.flatMap { BinaryFacts.daysLeft(until: $0) })
            if let expiry = profile.expirationDate {
                let when = date(expiry) ?? ""
                if expiry < Date() {
                    b.badges.append(Badge(level: .caution, title: Word.expired,
                                          detail: String(localized: "Its provisioning profile expired \(when); it no longer opens.", bundle: .previewKit,
                                                         comment: "Badge detail: the app's profile expired; the argument is the date.")))
                } else if let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day, days <= 14 {
                    let dist = profile.distribution.localizedName.prefix(1).uppercased() + profile.distribution.localizedName.dropFirst()
                    let title: String
                    if days == 1 {
                        title = String(localized: "\(dist) build: its provisioning profile expires in 1 day", bundle: .previewKit,
                                       comment: "Badge: the app's profile expires tomorrow; the argument is the distribution, e.g. “Ad hoc”.")
                    } else {
                        let count = days.formatted()
                        title = String(localized: "\(dist) build: its provisioning profile expires in \(count) days", bundle: .previewKit,
                                       comment: "Badge: the app's profile expires soon; the arguments are the distribution (e.g. “Ad hoc”) and the days left.")
                    }
                    let detail: String
                    switch profile.deviceCount {
                    case 0:
                        detail = String(localized: "After \(when) it will stop opening.", bundle: .previewKit, comment: "Badge detail: the app stops opening after the date.")
                    case 1:
                        detail = String(localized: "After \(when) it will stop opening on the 1 test device.", bundle: .previewKit,
                                        comment: "Badge detail: the app stops opening on its one test device after the date.")
                    default:
                        let count = profile.deviceCount.formatted()
                        detail = String(localized: "After \(when) it will stop opening on the \(count) test devices.", bundle: .previewKit,
                                        comment: "Badge detail: the app stops opening on its test devices after the date; e.g. “After 6 Dec 2026 it will stop opening on the 12 test devices.”")
                    }
                    b.badges.append(Badge(level: .caution, title: title, detail: detail))
                }
            }
        } else if ipa.isAppStoreEncrypted == true {
            b.add("distribution", String(localized: "Distribution", bundle: .previewKit, comment: "Fact label: how the app is distributed."), Word.appStoreEncrypted)
        }
        // After the profile's: the card reads an expiring profile from the first caution, and these follow it.
        b.badges += signatureBadges
        b.add("entitlementsFrom", String(localized: "Entitlements from", bundle: .previewKit, comment: "Fact label: where the entitlements were read from."),
              ipa.entitlementsSource?.localizedName)
        b.add("uses", String(localized: "What it may use", bundle: .previewKit, comment: "Fact label: the app's permissions and capabilities in plain words."),
              (ipa.usageDescriptions.map(\.what) + entitlementWords(ipa.entitlements)).uniqued.joined(separator: listSeparator))
        for usage in ipa.usageDescriptions.prefix(12) { b.add("usage.\(usage.key)", usage.what, usage.reason) }
        if let e = ipa.entitlements {
            b.add("entitlements", String(localized: "Entitlements", bundle: .previewKit, comment: "Fact label: the entitlement keys."), e.keys.sorted().joined(separator: ", "))
        }
        for note in ipa.notes { b.add("note", String(localized: "Note", bundle: .previewKit, comment: "Fact label: a note about the app."), note) }
        if ipa.entitlements?["get-task-allow"]?.boolValue == true {
            b.add("debuggable", String(localized: "Debuggable", bundle: .previewKit, comment: "Fact label: whether a debugger can attach."),
                  String(localized: "Yes (development build)", bundle: .previewKit, comment: "An iOS app can be debugged: it is a development build."))
        }
        let headlineVersion = ipa.shortVersion.map { version in
            String(localized: "Version \(version)", bundle: .previewKit, comment: "An app's version in its summary; e.g. “Version 2.4”.")
        }
        let headlineExpiry = ipa.profile?.expirationDate.flatMap { BinaryFacts.daysLeft(until: $0) }.map { left in
            String(localized: "expires in \(left)", bundle: .previewKit, comment: "When an app's profile expires, in its summary; e.g. “expires in 9 days”.")
        }
        b.headline([headlineVersion, headlineExpiry].compactMap { $0 }.joined(separator: " · ").nonEmpty
            ?? String(localized: "iOS app", bundle: .previewKit, comment: "An iOS app's summary when it has no version."))
        let icon = ipa.iconData.flatMap { NSImage(data: Data($0)) }
        return (b.document(kind: kind), Extras(icon: icon, contents: ipa.listing, contentsSource: source))
    }

    /// The entitlements people would recognise, in plain words.
    static func entitlementWords(_ e: [String: PlistValue]?) -> [String] {
        guard let e else { return [] }
        var out: [String] = []
        if e["aps-environment"] != nil { out.append(String(localized: "notifications", bundle: .previewKit, comment: "What an iOS app may use: push notifications.")) }
        if e["keychain-access-groups"] != nil { out.append(String(localized: "a shared keychain", bundle: .previewKit, comment: "What an iOS app may use: a keychain shared with other apps.")) }
        if e["com.apple.developer.icloud-container-identifiers"] != nil { out.append("iCloud") }
        if e["com.apple.developer.associated-domains"] != nil { out.append(String(localized: "associated domains", bundle: .previewKit, comment: "What an iOS app may use: web domains tied to the app.")) }
        if e["com.apple.developer.healthkit"] != nil { out.append(String(localized: "Health", bundle: .previewKit, comment: "What an iOS app may use: Apple's Health data (the Health app's name).")) }
        if e["com.apple.developer.networking.networkextension"] != nil { out.append(String(localized: "network extensions", bundle: .previewKit, comment: "What an iOS app may use: VPN and network filter extensions.")) }
        if e["com.apple.developer.in-app-payments"] != nil { out.append("Apple Pay") }
        return out
    }

    /// A Mac app's entitlements in plain words (T-1): what the sandbox lets it reach, and which of the hardened
    /// runtime's protections it turns off. Keys people would not recognise are left to the Details list.
    static func macEntitlementWords(_ e: [String: PlistValue]?) -> (uses: [String], loosened: [String]) {
        guard let e else { return ([], []) }
        func on(_ key: String) -> Bool { e[key]?.boolValue == true }
        var uses: [String] = []
        let reach: [(String, String)] = [
            ("com.apple.security.network.client", String(localized: "the internet", bundle: .previewKit, comment: "What a Mac app may use: outgoing network connections.")),
            ("com.apple.security.network.server", String(localized: "incoming connections", bundle: .previewKit, comment: "What a Mac app may use: it may accept network connections.")),
            ("com.apple.security.device.camera", String(localized: "the camera", bundle: .previewKit, comment: "What a Mac app may use.")),
            ("com.apple.security.device.audio-input", String(localized: "the microphone", bundle: .previewKit, comment: "What a Mac app may use.")),
            ("com.apple.security.device.usb", String(localized: "USB devices", bundle: .previewKit, comment: "What a Mac app may use.")),
            ("com.apple.security.device.bluetooth", "Bluetooth"),
            ("com.apple.security.personal-information.location", String(localized: "your location", bundle: .previewKit, comment: "What a Mac app may use.")),
            ("com.apple.security.personal-information.addressbook", String(localized: "your contacts", bundle: .previewKit, comment: "What a Mac app may use.")),
            ("com.apple.security.personal-information.calendars", String(localized: "your calendars", bundle: .previewKit, comment: "What a Mac app may use.")),
            ("com.apple.security.personal-information.photos-library", String(localized: "your photos", bundle: .previewKit, comment: "What a Mac app may use.")),
            ("com.apple.security.files.user-selected.read-write", String(localized: "files you choose", bundle: .previewKit, comment: "What a Mac app may use: files the person picks in an Open or Save panel.")),
            ("com.apple.security.files.downloads.read-write", String(localized: "your Downloads folder", bundle: .previewKit, comment: "What a Mac app may use.")),
            ("com.apple.security.automation.apple-events", String(localized: "control of other apps", bundle: .previewKit, comment: "What a Mac app may use: it may send Apple events to other apps.")),
        ]
        for (key, words) in reach where on(key) { uses.append(words) }
        if e["com.apple.developer.icloud-container-identifiers"] != nil { uses.append("iCloud") }
        if e["com.apple.developer.endpoint-security.client"] != nil {
            uses.append(String(localized: "watching every app that runs", bundle: .previewKit, comment: "What a Mac app may use: Endpoint Security, which sees every process start."))
        }
        var loosened: [String] = []
        if on("com.apple.security.cs.disable-library-validation") {
            loosened.append(String(localized: "loads code signed by others", bundle: .previewKit, comment: "A hardened-runtime protection a Mac app turns off: library validation."))
        }
        if on("com.apple.security.cs.allow-unsigned-executable-memory") || on("com.apple.security.cs.disable-executable-page-protection") {
            loosened.append(String(localized: "runs code it writes in memory", bundle: .previewKit, comment: "A hardened-runtime protection a Mac app turns off: unsigned executable memory."))
        }
        if on("com.apple.security.cs.allow-dyld-environment-variables") {
            loosened.append(String(localized: "lets the environment inject code", bundle: .previewKit, comment: "A hardened-runtime protection a Mac app turns off: DYLD environment variables."))
        }
        if on("com.apple.security.get-task-allow") {
            loosened.append(String(localized: "lets a debugger attach", bundle: .previewKit, comment: "A Mac app that allows debugging: usually a developer build."))
        }
        return (uses, loosened)
    }

    // MARK: Android app (P-2)

    static func androidApp(url: URL, kind: FileKind) throws -> (PreviewDocument, Extras) {
        let source = try FileByteSource(url: url)
        let apk = try AndroidPackageReader.read(source: source, fileName: url.lastPathComponent)
        var b = Builder()
        b.add("name", String(localized: "Name", bundle: .previewKit, comment: "Fact label: the app's name."),
              apk.label ?? apk.packageName ?? url.deletingPathExtension().lastPathComponent)
        b.add("label", String(localized: "App name", bundle: .previewKit, comment: "Fact label: the Android app's label."),
              apk.label ?? (apk.labelIsResource ? String(localized: "In the app's resources (not read)", bundle: .previewKit,
                                                         comment: "An Android app's name when it lives in its resource table, which Vitrine does not read.") : nil))
        b.add("package", String(localized: "Package", bundle: .previewKit, comment: "Fact label: the Android package name."), apk.packageName)
        b.add("version", String(localized: "Version", bundle: .previewKit, comment: "Fact label: the app's version and version code."),
              [apk.versionName, apk.versionCode.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
        b.add("minSDK", String(localized: "Requires", bundle: .previewKit, comment: "Fact label: the oldest Android the app runs on."), apk.minSDK.map(androidVersion))
        b.add("targetSDK", String(localized: "Targets", bundle: .previewKit, comment: "Fact label: the Android version the app is built for."), apk.targetSDK.map(androidVersion))
        b.add("size", String(localized: "Size", bundle: .previewKit, comment: "Fact label: the file size."), BinaryFacts.fileSize(url))
        b.add("permissionCount", String(localized: "Permissions", bundle: .previewKit, comment: "Fact label: how many permissions the app asks for."),
              apk.permissions.count.formatted())
        b.add("dangerous", String(localized: "Sensitive permissions", bundle: .previewKit, comment: "Fact label: the sensitive permissions, in plain words."),
              apk.dangerousPermissions.map(permissionWords).joined(separator: listSeparator))
        b.add("permissions", String(localized: "All permissions", bundle: .previewKit, comment: "Fact label: every permission the app asks for, as Android names it."),
              apk.permissions.map { $0.replacingOccurrences(of: "android.permission.", with: "") }.joined(separator: ", "))
        b.add("components", String(localized: "Components", bundle: .previewKit, comment: "Fact label: the app's activities, services, receivers and providers."),
              [activitiesPhrase(apk.activityCount), servicesPhrase(apk.serviceCount), receiversPhrase(apk.receiverCount), providersPhrase(apk.providerCount)]
                  .joined(separator: listSeparator))
        b.add("abis", String(localized: "Native code", bundle: .previewKit, comment: "Fact label: the CPU architectures of the app's native code."),
              apk.nativeABIs.joined(separator: ", "))
        let schemes = apk.signatureSchemes.joined(separator: ", ")
        b.add("schemes", String(localized: "Signature", bundle: .previewKit, comment: "Fact label: the APK signature schemes."),
              apk.signatureSchemes.isEmpty ? Word.notSigned
                  : String(localized: "\(schemes) (not verified)", bundle: .previewKit, comment: "An APK's signature schemes, which Vitrine does not verify; e.g. “v2, v3 (not verified)”."))
        // An APK's certificates are self-signed by design, and nothing here verifies the signature: the name is always
        // the certificate's claim (G-34, S-16 follow-up B). Android knows a signer by the certificate's digest.
        b.add("claimedSigner", BinaryFacts.claimedSignerLabel, apk.certificates.first.map { $0.commonName ?? $0.summary })
        b.add("certificateDigest", String(localized: "Certificate SHA-256", bundle: .previewKit,
                                          comment: "Fact label: the SHA-256 digest of an Android app's signing certificate, which is how Android identifies the signer."),
              apk.certificates.first?.sha256Fingerprint)
        b.add("debuggable", String(localized: "Debuggable", bundle: .previewKit, comment: "Fact label: whether a debugger can attach."), apk.debuggable ? Word.yes : nil)
        b.add("cleartext", String(localized: "Plain HTTP allowed", bundle: .previewKit, comment: "Fact label: whether the app may use unencrypted HTTP."),
              apk.usesCleartextTraffic.map { $0 ? Word.yes : Word.no })
        if !apk.dangerousPermissions.isEmpty {
            let n = apk.dangerousPermissions.count
            let list = apk.dangerousPermissions.map(permissionWords).joined(separator: listSeparator)
            let title: String
            if n == 1 {
                title = String(localized: "Asks for 1 sensitive permission", bundle: .previewKit, comment: "Badge: the Android app asks for one sensitive permission.")
            } else {
                let count = n.formatted()
                title = String(localized: "Asks for \(count) sensitive permissions", bundle: .previewKit,
                               comment: "Badge: how many sensitive permissions the Android app asks for; e.g. “Asks for 2 sensitive permissions”.")
            }
            b.badges.append(Badge(level: .caution, title: title,
                                  detail: String(localized: "\(list).", bundle: .previewKit, comment: "Badge detail: the list of sensitive permissions, as a sentence.")))
        }
        if apk.debuggable {
            b.badges.append(Badge(level: .caution, title: String(localized: "Debug build", bundle: .previewKit, comment: "Badge: the Android app is a debug build."),
                                  detail: String(localized: "Anyone with the phone can attach a debugger to it.", bundle: .previewKit, comment: "Badge detail: a debuggable Android app.")))
        }
        if apk.signatureSchemes.isEmpty {
            b.badges.append(Badge(level: .caution, title: Word.notSigned,
                                  detail: String(localized: "Android will not install an unsigned app.", bundle: .previewKit, comment: "Badge detail: an unsigned Android app.")))
        }
        let headlineVersion = apk.versionName.map { version in
            String(localized: "Version \(version)", bundle: .previewKit, comment: "An app's version in its summary; e.g. “Version 2.4”.")
        }
        b.headline([headlineVersion, permissionsPhrase(apk.permissions.count)].compactMap { $0 }.joined(separator: " · "))
        return (b.document(kind: kind), Extras(contents: apk.listing, contentsSource: source))
    }

    static func activitiesPhrase(_ n: Int) -> String {
        if n == 1 { return String(localized: "1 activity", bundle: .previewKit, comment: "An Android app with exactly one activity (a screen).") }
        let count = n.formatted()
        return String(localized: "\(count) activities", bundle: .previewKit, comment: "How many activities (screens) an Android app has; e.g. “12 activities”.")
    }

    static func servicesPhrase(_ n: Int) -> String {
        if n == 1 { return String(localized: "1 service", bundle: .previewKit, comment: "An Android app with exactly one service.") }
        let count = n.formatted()
        return String(localized: "\(count) services", bundle: .previewKit, comment: "How many services an Android app has; e.g. “3 services”.")
    }

    static func receiversPhrase(_ n: Int) -> String {
        if n == 1 { return String(localized: "1 receiver", bundle: .previewKit, comment: "An Android app with exactly one broadcast receiver.") }
        let count = n.formatted()
        return String(localized: "\(count) receivers", bundle: .previewKit, comment: "How many broadcast receivers an Android app has; e.g. “2 receivers”.")
    }

    static func providersPhrase(_ n: Int) -> String {
        if n == 1 { return String(localized: "1 provider", bundle: .previewKit, comment: "An Android app with exactly one content provider.") }
        let count = n.formatted()
        return String(localized: "\(count) providers", bundle: .previewKit, comment: "How many content providers an Android app has; e.g. “2 providers”.")
    }

    /// API level → "Android 8.0 (API 26)". Product names and the API number, the same in every language.
    static func androidVersion(_ api: Int) -> String {
        let names = [21: "5.0", 22: "5.1", 23: "6.0", 24: "7.0", 25: "7.1", 26: "8.0", 27: "8.1", 28: "9", 29: "10", 30: "11",
                     31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16"]
        return names[api].map { "Android \($0) (API \(api))" } ?? "API \(api)"
    }

    /// `android.permission.ACCESS_FINE_LOCATION` → "precise location". A permission with no plain words keeps its
    /// own name, lowercased.
    static func permissionWords(_ p: String) -> String {
        let short = p.replacingOccurrences(of: "android.permission.", with: "")
        switch short {
        case "ACCESS_FINE_LOCATION": return String(localized: "precise location", bundle: .previewKit, comment: "Android permission in plain words.")
        case "ACCESS_COARSE_LOCATION": return String(localized: "approximate location", bundle: .previewKit, comment: "Android permission in plain words.")
        case "ACCESS_BACKGROUND_LOCATION": return String(localized: "location in the background", bundle: .previewKit, comment: "Android permission in plain words.")
        case "CAMERA": return String(localized: "camera", bundle: .previewKit, comment: "Android permission in plain words.")
        case "RECORD_AUDIO": return String(localized: "microphone", bundle: .previewKit, comment: "Android permission in plain words.")
        case "READ_CONTACTS": return String(localized: "contacts", bundle: .previewKit, comment: "Android permission in plain words.")
        case "WRITE_CONTACTS": return String(localized: "changing contacts", bundle: .previewKit, comment: "Android permission in plain words.")
        case "READ_SMS": return String(localized: "text messages", bundle: .previewKit, comment: "Android permission in plain words.")
        case "SEND_SMS": return String(localized: "sending texts", bundle: .previewKit, comment: "Android permission in plain words.")
        case "RECEIVE_SMS": return String(localized: "incoming texts", bundle: .previewKit, comment: "Android permission in plain words.")
        case "READ_CALL_LOG": return String(localized: "call log", bundle: .previewKit, comment: "Android permission in plain words.")
        case "CALL_PHONE": return String(localized: "making calls", bundle: .previewKit, comment: "Android permission in plain words.")
        case "READ_PHONE_STATE": return String(localized: "phone status", bundle: .previewKit, comment: "Android permission in plain words.")
        case "READ_CALENDAR": return String(localized: "calendar", bundle: .previewKit, comment: "Android permission in plain words.")
        case "BODY_SENSORS": return String(localized: "body sensors", bundle: .previewKit, comment: "Android permission in plain words.")
        case "READ_EXTERNAL_STORAGE": return String(localized: "shared storage", bundle: .previewKit, comment: "Android permission in plain words.")
        case "WRITE_EXTERNAL_STORAGE": return String(localized: "writing shared storage", bundle: .previewKit, comment: "Android permission in plain words.")
        case "MANAGE_EXTERNAL_STORAGE": return String(localized: "all files", bundle: .previewKit, comment: "Android permission in plain words.")
        case "POST_NOTIFICATIONS": return String(localized: "notifications", bundle: .previewKit, comment: "Android permission in plain words.")
        case "SYSTEM_ALERT_WINDOW": return String(localized: "drawing over other apps", bundle: .previewKit, comment: "Android permission in plain words.")
        case "REQUEST_INSTALL_PACKAGES": return String(localized: "installing other apps", bundle: .previewKit, comment: "Android permission in plain words.")
        case "BIND_ACCESSIBILITY_SERVICE": return String(localized: "accessibility control", bundle: .previewKit, comment: "Android permission in plain words.")
        case "BIND_DEVICE_ADMIN": return String(localized: "device administration", bundle: .previewKit, comment: "Android permission in plain words.")
        case "QUERY_ALL_PACKAGES": return String(localized: "seeing every installed app", bundle: .previewKit, comment: "Android permission in plain words.")
        case "PACKAGE_USAGE_STATS": return String(localized: "app usage history", bundle: .previewKit, comment: "Android permission in plain words.")
        case "BIND_NOTIFICATION_LISTENER_SERVICE": return String(localized: "reading notifications", bundle: .previewKit, comment: "Android permission in plain words.")
        case "READ_MEDIA_IMAGES": return String(localized: "photos", bundle: .previewKit, comment: "Android permission in plain words.")
        case "READ_MEDIA_VIDEO": return String(localized: "videos", bundle: .previewKit, comment: "Android permission in plain words.")
        case "READ_MEDIA_AUDIO": return String(localized: "music and audio", bundle: .previewKit, comment: "Android permission in plain words.")
        case "BLUETOOTH_SCAN": return String(localized: "nearby Bluetooth devices", bundle: .previewKit, comment: "Android permission in plain words.")
        case "BLUETOOTH_CONNECT": return String(localized: "connecting Bluetooth devices", bundle: .previewKit, comment: "Android permission in plain words.")
        case "NEARBY_WIFI_DEVICES": return String(localized: "nearby Wi-Fi devices", bundle: .previewKit, comment: "Android permission in plain words.")
        case "ACTIVITY_RECOGNITION": return String(localized: "physical activity", bundle: .previewKit, comment: "Android permission in plain words.")
        case "GET_ACCOUNTS": return String(localized: "accounts on the phone", bundle: .previewKit, comment: "Android permission in plain words.")
        default: return short.lowercased().replacingOccurrences(of: "_", with: " ")
        }
    }
}

extension Array where Element: Hashable {
    /// The elements in order, each once.
    var uniqued: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
