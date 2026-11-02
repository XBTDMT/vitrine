import Foundation
import VitrineBinary
import VitrineDocument
import VitrineSupport
import VitrineTrust

/// Apps, installers, disk images and provisioning profiles before their card view exists: a readable summary in the
/// text view, the facts in the pill, and the warnings that matter (an unsigned or tampered app, an installer that
/// runs scripts, an expired profile). Everything is read statically and the signature check never goes online
/// (VitrineBinary). roadmap: S-8, S-22
enum BinaryFacts {
    /// The document and what the card shows beside it (the object's picture, its contents one switch away).
    /// `assessSignature` gives the verdict of the code's signature; by default the full check within
    /// `signatureBudget`, waited for on the calling thread. The card (BinaryCardRenderer) passes its own, which
    /// never makes the main thread wait, and builds the document again once the full check has finished (G-34, S-16).
    static func read(url: URL, kind: FileKind,
                     assessSignature: (URL) -> SignatureAssessment = BinaryFacts.previewSignature) throws -> (PreviewDocument, PackageFacts.Extras) {
        if let package = try PackageFacts.read(url: url, kind: kind) { return package }
        let document = try document(url: url, kind: kind, assessSignature: assessSignature)
        guard kind == .installerPackage else { return (document, PackageFacts.Extras()) }
        var extras = PackageFacts.installerContents(url: url)
        // The scripts it would run, readable (T-2): the package's Scripts archive, read as text, never run.
        extras.scripts = ((try? InstallerPackageReader.read(contentsOf: url))?.components ?? [])
            .flatMap(\.scriptFiles).compactMap { f in f.text.map { (f.name, $0) } }
        return (document, extras)
    }

    /// The full signature check within `signatureBudget`, on the calling thread (text views, export, tests).
    static func previewSignature(_ url: URL) -> SignatureAssessment { SignatureVerifier.assess(url: url, budget: signatureBudget) }

    /// Whether building a document of `kind` asks for a code signature verdict: an app bundle, a disk image, and
    /// whatever else VitrineBinary reads as a bundle or Mach-O (everything PackageFacts does not handle, except
    /// installers and provisioning profiles, which carry no code signature). The card starts the check early for these.
    static func assessesSignature(_ kind: FileKind) -> Bool {
        if case .reader = kind { return false }
        return ![.installerPackage, .provisioningProfile, .configurationProfile, .torrent, .keyMaterial, .lockfile,
                 .archive(.ipa), .archive(.apk)].contains(kind)
    }

    static func document(url: URL, kind: FileKind, assessSignature: (URL) -> SignatureAssessment = BinaryFacts.previewSignature) throws -> PreviewDocument {
        // Torrents, configuration profiles and iOS and Android apps (S-8, P-2, P-4).
        if let package = try PackageFacts.read(url: url, kind: kind) { return package.0 }
        var lines: [String] = []
        var facts: [Fact] = []
        var badges: [Badge] = []
        func add(_ key: String, _ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            facts.append(Fact(key: key, label: label, value: value))
            lines.append(label.padding(toLength: 22, withPad: " ", startingAt: 0) + value)
        }
        let date: (Date?) -> String? = { $0.map { $0.formatted(date: .abbreviated, time: .omitted) } }
        let yes = String(localized: "Yes", bundle: .previewKit, comment: "A yes/no fact's value.")
        let no = String(localized: "No", bundle: .previewKit, comment: "A yes/no fact's value.")
        let signatureLabel = String(localized: "Signature", bundle: .previewKit, comment: "Fact label: the code signature's state.")
        let sizeLabel = String(localized: "Size", bundle: .previewKit, comment: "Fact label: the file's size.")
        let versionLabel = String(localized: "Version", bundle: .previewKit, comment: "Fact label: a version number.")
        let teamLabel = String(localized: "Team", bundle: .previewKit, comment: "Fact label: the Apple developer team.")
        let notarizationLabel = String(localized: "Notarization ticket", bundle: .previewKit,
                                       comment: "Fact label: whether Apple's notarization ticket is stapled to the file.")
        let notSigned = String(localized: "Not signed", bundle: .previewKit, comment: "Signature fact value and warning title: the file has no code signature.")
        let runsOn = String(localized: "Runs on", bundle: .previewKit, comment: "Fact label: the processor architectures a binary runs on.")
        let nameLabel = String(localized: "Name", bundle: .previewKit, comment: "Fact label: the name of an app or profile.")

        switch try VitrineBinary.inspect(url) {
        case .bundle(let b):
            let name = b.info.displayName ?? b.info.name ?? url.deletingPathExtension().lastPathComponent
            add("name", nameLabel, name)
            add("identifier", String(localized: "Bundle ID", bundle: .previewKit, comment: "Fact label: an app's bundle identifier."), b.info.identifier)
            add("version", versionLabel, [b.info.shortVersion, b.info.buildVersion.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
            add("minimumSystem", String(localized: "Requires macOS", bundle: .previewKit, comment: "Fact label: the oldest macOS an app runs on."),
                b.info.minimumSystemVersion)
            add("architectures", runsOn, b.architectures.isEmpty ? nil : b.architectures.formatted(.list(type: .and, width: .narrow)))
            add("category", String(localized: "Category", bundle: .previewKit, comment: "Fact label: an app's App Store category."), b.info.categoryName)
            add("sandboxed", String(localized: "Sandboxed", bundle: .previewKit, comment: "Fact label: whether an app runs in the App Sandbox."),
                b.isSandboxed.map { $0 ? yes : no })
            // Its entitlements in plain words (T-1): what a sandboxed app may reach, and protections any app turns off.
            let words = PackageFacts.macEntitlementWords(b.entitlements)
            add("uses", String(localized: "What it may use", bundle: .previewKit, comment: "Fact label: the app's permissions and capabilities in plain words."),
                b.isSandboxed == true && !words.uses.isEmpty ? words.uses.formatted(.list(type: .and, width: .narrow)) : nil)
            add("loosened", String(localized: "Protections it turns off", bundle: .previewKit, comment: "Fact label: hardened-runtime protections a Mac app turns off, in plain words."),
                words.loosened.isEmpty ? nil : words.loosened.formatted(.list(type: .and, width: .narrow)))
            if let e = b.entitlements, !e.isEmpty {
                add("entitlements", String(localized: "Entitlements", bundle: .previewKit, comment: "Fact label: the entitlement keys."), e.keys.sorted().joined(separator: ", "))
            }
            add("size", sizeLabel, ByteCountFormatter.string(fromByteCount: Int64(b.size.logicalBytes), countStyle: .file))
            // The full check, off the main thread within the preview's budget (G-34): "Valid" only when it finished.
            let signature = assessSignature(url)
            add("signature", signatureLabel, verdict(signature, badges: &badges))
            signerFacts(signature, embedded: [], add: add, badges: &badges)
            add("notarization", notarizationLabel, notarization(signature, notTicket: stapled(signature.ticketFile), badges: &badges))
            if !b.embedded.isEmpty {
                add("embedded", String(localized: "Inside", bundle: .previewKit, comment: "Fact label: what an app bundle embeds."),
                    String(localized: "\(b.embedded.count) embedded items", bundle: .previewKit,
                           comment: "Fact value: how many apps, extensions and frameworks an app bundle embeds."))
            }
            facts.insert(Fact(key: "headline", label: FamilyFacts.summaryLabel,
                              value: [b.info.shortVersion, signatureWord(signature)].compactMap { $0 }.joined(separator: " · ")), at: 0)
        case .installerPackage(let p):
            add("identifier", String(localized: "Package", bundle: .previewKit, comment: "Fact label: an installer package's identifier."),
                p.components.first?.identifier)
            add("version", versionLabel, p.components.first?.version)
            add("size", sizeLabel, fileSize(url))
            add("installLocation", String(localized: "Installs to", bundle: .previewKit, comment: "Fact label: the folder an installer installs into."),
                p.components.first?.installLocation)
            add("components", String(localized: "Components", bundle: .previewKit, comment: "Fact label: how many components an installer holds."),
                p.components.count > 1 ? p.components.count.formatted() : nil)
            // The xar signature, verified in process (G-34, F58): the signer is named only when all of it checked out.
            if let signature = p.signature {
                installerSignatureFacts(signature, add: add, badges: &badges)
            } else {
                add("signed", signatureLabel, notSigned)
                // As for apps: macOS refuses an unsigned installer by default, so the pill says so before you try.
                badges.append(Badge(level: .caution, title: notSigned,
                                    detail: String(localized: "macOS cannot tell who made this installer.", bundle: .previewKit,
                                                   comment: "Warning detail for an unsigned installer.")))
            }
            // What the trust design's installer card adds (trust r3-a, the AcmeSync state): whether it asks for an
            // administrator, how many files it lays down and where each component goes.
            add("administrator", String(localized: "Needs an administrator", bundle: .previewKit,
                                        comment: "Fact label: the installer asks for an administrator's password."),
                p.components.contains { $0.authorization == "root" } ? yes : nil)
            let payloadFiles = p.components.compactMap { $0.payload?.numberOfFiles }
            add("payloadFiles", String(localized: "Files", bundle: .previewKit, comment: "Fact label: how many files an installer lays down."),
                payloadFiles.isEmpty ? nil : payloadFiles.reduce(0, +).formatted())
            add("componentList", String(localized: "Installs", bundle: .previewKit, comment: "Fact label: the list of an installer's components."),
                p.components.map { c in
                    [c.identifier,
                     c.payload?.numberOfFiles.map { String(localized: "\($0) files", bundle: .previewKit, comment: "How many files one installer component lays down.") },
                     c.installLocation]
                        .compactMap { $0 }.joined(separator: " · ")
                }.filter { !$0.isEmpty }.joined(separator: "\n"))
            let scripts = p.scriptNames
            // What the scripts would do (T-2 with the script lens, T-3): "postinstall: Starts at every login (line 12)".
            var dangerous: [String] = []
            let findings = p.components.flatMap(\.scriptFiles).flatMap { file -> [String] in
                guard let text = file.text, let report = ScriptLens.scan(script: text, launcher: false) else { return [] }
                return report.findings.map { f in
                    let line = f.line.map { String(localized: "\(file.name): \(f.title) (line \($0))", bundle: .previewKit,
                                                   comment: "An installer script finding: the script's name, what it does, its line.") }
                        ?? "\(file.name): \(f.title)"
                    if f.level == .danger { dangerous.append(line) }
                    return line
                }
            }
            add("scriptFindings", String(localized: "What the scripts do", bundle: .previewKit, comment: "Fact label: what an installer's scripts would do when run."),
                findings.isEmpty ? nil : findings.joined(separator: "\n"))
            // A script that downloads and runs code, or hides it, outweighs a missing signature: the verdict says so.
            if let first = dangerous.first {
                badges.append(Badge(level: .danger,
                                    title: String(localized: "Its install script is dangerous", bundle: .previewKit,
                                                  comment: "Danger verdict title: an installer's script downloads and runs code, hides code or removes macOS's download warning."),
                                    detail: first))
            }
            if !scripts.isEmpty {
                let names = scripts.formatted(.list(type: .and, width: .narrow))
                add("scripts", String(localized: "Runs scripts", bundle: .previewKit, comment: "Fact label: the scripts an installer runs."), names)
                badges.append(Badge(level: .caution,
                                    title: String(localized: "Runs install scripts", bundle: .previewKit, comment: "Warning title: an installer runs scripts."),
                                    detail: String(localized: "Installing runs \(names) with the installer's rights.", bundle: .previewKit,
                                                   comment: "Warning detail; the argument lists the script names.")))
            }
            facts.insert(Fact(key: "headline", label: FamilyFacts.summaryLabel,
                              value: scripts.isEmpty
                                ? String(localized: "No install scripts", bundle: .previewKit, comment: "Installer pill headline: it runs no scripts.")
                                : String(localized: "\(scripts.count) install scripts", bundle: .previewKit,
                                         comment: "Installer pill headline: how many scripts it runs.")), at: 0)
        case .diskImage(let d):
            add("format", String(localized: "Format", bundle: .previewKit, comment: "Fact label: a disk image's format."), d.inferredFormat)
            add("size", sizeLabel, fileSize(url))
            add("encrypted", String(localized: "Encrypted", bundle: .previewKit, comment: "Fact label: whether a disk image is encrypted."),
                d.isEncrypted ? yes : no)
            add("partitions", String(localized: "Partitions", bundle: .previewKit, comment: "Fact label: how many partitions a disk image holds."),
                d.partitions.isEmpty ? nil : d.partitions.count.formatted())
            // The trust design's disk image card also names its signer and Apple's ticket (trust r3-a), from the
            // Security framework's assessment of the image (G-34, F3, F8): the signature the trailer points at is only
            // bytes in the file until that check says otherwise. Its file tree needs the image mounted, which a
            // sandboxed preview never does: the card says so instead.
            if d.codeSignature != nil || (d.trailer?.codeSignatureLength ?? 0) > 0 {
                let signature = assessSignature(url)
                let embedded = d.codeSignature?.cmsCertificates ?? []
                if signature.status == .unsigned {
                    // The trailer points at a signature the Security framework does not read as one.
                    add("signed", signatureLabel, String(localized: "Not verified: macOS does not accept this signature", bundle: .previewKit,
                                                         comment: "Disk image signature fact: the image carries signature bytes the system does not read as a signature."))
                    badges.append(Badge(level: .caution, title: Self.notVerifiedWord,
                                        detail: String(localized: "The disk image carries a signature macOS does not accept, so who signed it is not known.", bundle: .previewKit,
                                                       comment: "Warning detail: a disk image's signature bytes are not a signature the system accepts.")))
                } else {
                    add("signed", signatureLabel, signature.isFullyValid
                        ? String(localized: "Signed", bundle: .previewKit, comment: "Disk image signature fact: the image is signed.")
                        : verdict(signature, badges: &badges))
                }
                signerFacts(signature, embedded: embedded, add: add, badges: &badges)
                add("notarization", notarizationLabel,
                    notarization(signature, notTicket: String(localized: "Not stapled", bundle: .previewKit,
                                                              comment: "Notarization fact: no ticket is stapled to the disk image."), badges: &badges))
            } else {
                add("signed", signatureLabel, notSigned)
            }
            add("contents", String(localized: "Contents", bundle: .previewKit, comment: "Fact label: what a disk image contains."),
                String(localized: "Not listed: Vitrine never mounts a disk image", bundle: .previewKit,
                       comment: "Disk image contents fact: why the files are not listed."))
            facts.insert(Fact(key: "headline", label: FamilyFacts.summaryLabel,
                              value: d.isEncrypted ? String(localized: "Encrypted", bundle: .previewKit, comment: "Disk image pill headline: the image is encrypted.")
                                : (d.inferredFormat ?? String(localized: "Disk image", bundle: .previewKit, comment: "Disk image pill headline when its format is unknown."))),
                         at: 0)
        case .provisioningProfile(let p):
            add("name", nameLabel, p.name)
            add("appID", String(localized: "App ID", bundle: .previewKit, comment: "Fact label: a provisioning profile's app identifier."),
                p.applicationIdentifier)
            let team = [p.teamName, p.teamIdentifiers.first.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            // The team is the profile's claim until its own signature checks out against Apple (S-16, G-34).
            let profileSignature = (try? Data(contentsOf: url, options: .mappedIfSafe)).map { ProvisioningProfileReader.signatureVerification(bytes: [UInt8]($0)) }
                ?? .notVerified("the profile could not be read again")
            if profileSignature.isVerified {
                add("team", teamLabel, team)
            } else {
                add("claimedTeam", String(localized: "Team (not verified)", bundle: .previewKit,
                                          comment: "Fact label: the developer team a provisioning profile names, which nothing verified for this app."), team)
                badges.append(Badge(level: .caution, title: Self.notVerifiedWord,
                                    detail: String(localized: "The profile's own signature does not check out against Apple, so the team it names is not confirmed.",
                                                   bundle: .previewKit, comment: "Warning detail: a provisioning profile's signature was not verified.")))
            }
            add("platforms", String(localized: "Platforms", bundle: .previewKit, comment: "Fact label: the platforms a profile is for."),
                p.platforms.formatted(.list(type: .and, width: .narrow)))
            add("created", String(localized: "Created", bundle: .previewKit, comment: "Fact label: when a profile was made."), date(p.creationDate))
            add("expires", String(localized: "Expires", bundle: .previewKit, comment: "Fact label: when a profile expires."), date(p.expirationDate))
            add("devices", String(localized: "Devices", bundle: .previewKit, comment: "Fact label: how many devices a profile names."),
                p.deviceCount > 0 ? p.deviceCount.formatted() : nil)
            // What the card's sentence and answers name (cards r3-a profile card, trust r3-a state 7): the app, how
            // the profile is distributed, how many certificates may sign for it, and the days it has left.
            add("appName", String(localized: "App", bundle: .previewKit, comment: "Fact label: the app a profile is for."), p.appIDName)
            add("distribution", String(localized: "Distribution", bundle: .previewKit, comment: "Fact label: how a profile is distributed."),
                p.distribution.rawValue)
            add("certificates", String(localized: "Certificates", bundle: .previewKit, comment: "Fact label: how many certificates may sign for a profile."),
                p.developerCertificates.isEmpty ? nil : p.developerCertificates.count.formatted())
            add("expiresIn", String(localized: "Expires in", bundle: .previewKit, comment: "Fact label: the days a profile has left."),
                p.expirationDate.flatMap { daysLeft(until: $0) })
            let expired = p.expirationDate.map { $0 < Date() } ?? false
            let expiredWord = String(localized: "Expired", bundle: .previewKit, comment: "Warning title and pill headline: a provisioning profile has expired.")
            if expired {
                badges.append(Badge(level: .caution, title: expiredWord,
                                    detail: String(localized: "This profile expired \(date(p.expirationDate) ?? "").", bundle: .previewKit,
                                                   comment: "Warning detail; the argument is the expiry date.")))
            }
            facts.insert(Fact(key: "headline", label: FamilyFacts.summaryLabel,
                              value: expired ? expiredWord
                                : String(localized: "Expires \(date(p.expirationDate) ?? "?")", bundle: .previewKit,
                                         comment: "Profile pill headline; the argument is the expiry date.")), at: 0)
        case .machO(let m):
            add("architectures", runsOn, m.architectures.formatted(.list(type: .and, width: .narrow)))
            let signature = assessSignature(url)
            add("signature", signatureLabel, verdict(signature, badges: &badges))
            signerFacts(signature, embedded: [], add: add, badges: &badges)
            // A Mach-O file cannot be stapled; macOS may still hold Apple's ticket for it, which the requirement finds.
            if signature.notarization == .verified {
                add("notarization", notarizationLabel, notarization(signature, notTicket: nil, badges: &badges))
            }
            // Architecture names (arm64 + x86_64) are identifiers, joined with a plus sign.
            facts.insert(Fact(key: "headline", label: FamilyFacts.summaryLabel, value: m.architectures.joined(separator: " + ")), at: 0)
        }
        return PreviewDocument(kind: kind, facts: facts, badges: badges, views: [.text(lines.joined(separator: "\n"))])
    }

    /// The longest a preview waits for the full signature check before it shows what had finished (G-34, S-16).
    /// Measured 2026-11-02 on this Mac: most apps finish in 0.3–2 s (Telegram 1.9 s, Lightroom Classic 2.9 s);
    /// Xcode (3.9 GB) takes 6.5 s and is shown as partly checked.
    static let signatureBudget: Duration = .seconds(4)

    /// The signature fact for code the Security framework assessed (G-34): "Valid" only after the full check, a
    /// caution for everything that is not a whole, identified signature, a danger for a broken one.
    static func verdict(_ s: SignatureAssessment, badges: inout [Badge]) -> String {
        switch s.status {
        case .valid where s.depth == .full:
            return s.isHardenedRuntime
                ? String(localized: "Valid · hardened runtime", bundle: .previewKit, comment: "Signature fact: valid, with the hardened runtime on.")
                : String(localized: "Valid", bundle: .previewKit, comment: "Signature fact: the code signature is valid.")
        case .valid:
            badges.append(notFullyCheckedBadge)
            return Self.partlyCheckedWord
        case .adhoc:
            badges.append(Badge(level: .caution, title: String(localized: "No developer identity", bundle: .previewKit,
                                                               comment: "Warning title: the code is signed ad hoc, with no identity."),
                                detail: String(localized: "An ad-hoc signature says the code has not changed since it was signed, not who signed it.", bundle: .previewKit,
                                               comment: "Warning detail for an ad hoc signature.")))
            if s.depth == .quick { badges.append(notFullyCheckedBadge) }
            return String(localized: "Ad-hoc (no developer identity)", bundle: .previewKit, comment: "Signature fact: signed ad hoc, with no developer identity.")
        case .unsigned:
            let notSigned = String(localized: "Not signed", bundle: .previewKit, comment: "Signature fact value and warning title: the file has no code signature.")
            badges.append(Badge(level: .caution, title: notSigned,
                                detail: String(localized: "macOS cannot tell who made this.", bundle: .previewKit, comment: "Warning detail for unsigned code.")))
            return notSigned
        case .invalid(let reason, _):
            badges.append(Badge(level: .danger, title: Self.signatureBrokenWord, detail: reason))
            return String(localized: "Broken: \(reason)", bundle: .previewKit, comment: "Signature fact: broken, then the system's reason.")
        case .notChecked:
            badges.append(Badge(level: .caution, title: String(localized: "Signature not checked", bundle: .previewKit,
                                                               comment: "Warning title: the signature check did not finish in time for the preview."),
                                detail: String(localized: "Checking this signature takes longer than a preview allows, so nothing about it is known yet.", bundle: .previewKit,
                                               comment: "Warning detail: the signature check did not finish in time for the preview.")))
            return Self.notCheckedWord
        }
    }

    /// Who signed it, as far as the Security framework vouched (G-34): the kind of certificate from the requirements
    /// it satisfied; the certificate's name as the signer only under a kind Apple vouches for; otherwise the name the
    /// signature claims, labelled as not verified.
    static func signerFacts(_ s: SignatureAssessment, embedded: [CertificateSummary],
                            add: (String, String, String?) -> Void, badges: inout [Badge]) {
        if let kind = signerKindWord(s.anchor) {
            add("signerKind", String(localized: "Signing certificate", bundle: .previewKit, comment: "Fact label: what kind of certificate signed the code (Developer ID, Apple's own, …)."), kind)
        }
        let leaf = s.certificates.first ?? embedded.first
        if s.anchor.isVouchedByApple {
            add("signer", Self.signedByLabel, leaf?.commonName)
            add("team", String(localized: "Team", bundle: .previewKit, comment: "Fact label: the Apple developer team."), s.teamIdentifier)
            return
        }
        add("claimedSigner", Self.claimedSignerLabel, leaf?.commonName ?? leaf?.summary)
        if s.anchor == .notVouched { badges.append(notVouchedBadge) }
    }

    /// "Developer ID", "Apple's own", … for a signer the requirements classified; nil when there is none.
    static func signerKindWord(_ anchor: SignatureAssessment.Anchor) -> String? {
        switch anchor {
        case .apple: String(localized: "Apple's own", bundle: .previewKit, comment: "Signing certificate fact: Apple signed the code itself.")
        case .developerID: String(localized: "Developer ID", bundle: .previewKit, comment: "Signing certificate fact: a Developer ID certificate Apple issued.")
        case .macAppStore: String(localized: "Mac App Store", bundle: .previewKit, comment: "Signing certificate fact: signed for the Mac App Store.")
        case .appleIssued: Self.appleIssuedWord
        case .notVouched: Self.notVouchedWord
        case .none: nil
        }
    }

    /// The notarization fact (G-34): "Stapled and verified" or "Notarized" only when the `notarized` requirement
    /// held; a ticket-shaped file or slot without that is a caution, never a calm word.
    static func notarization(_ s: SignatureAssessment, notTicket: String?, badges: inout [Badge]) -> String? {
        switch s.notarization {
        case .verified where s.ticketFile.isPresent:
            return Self.stapledVerifiedWord
        case .verified:
            return Self.notarizedWord
        case .ticketUnverified:
            badges.append(Badge(level: .caution, title: String(localized: "Notarization not verified", bundle: .previewKit,
                                                               comment: "Warning title: something shaped like a notarization ticket is present, but the system did not verify it."),
                                detail: String(localized: "It carries something shaped like Apple's notarization ticket, but macOS did not confirm it belongs to this code.", bundle: .previewKit,
                                               comment: "Warning detail: a ticket-shaped file is present, but the system did not verify it.")))
            return Self.ticketUnverifiedWord
        case .none:
            return notTicket
        }
    }

    /// An installer's signature facts from the in-process xar check (G-34, F58).
    static func installerSignatureFacts(_ signature: PackageSignature, add: (String, String, String?) -> Void, badges: inout [Badge]) {
        let label = String(localized: "Signature", bundle: .previewKit, comment: "Fact label: the code signature's state.")
        let leaf = signature.certificates.first.map { $0.commonName ?? $0.summary }
        switch signature.verification {
        case .verified(let signer):
            add("signed", label, String(localized: "Signed and verified", bundle: .previewKit,
                                        comment: "Installer signature fact: the signature and its certificate chain checked out."))
            add("signerKind", String(localized: "Signing certificate", bundle: .previewKit, comment: "Fact label: what kind of certificate signed the code (Developer ID, Apple's own, …)."),
                signer == .developerID ? String(localized: "Developer ID", bundle: .previewKit, comment: "Signing certificate fact: a Developer ID certificate Apple issued.")
                                       : Self.appleIssuedWord)
            add("signer", Self.signedByLabel, leaf)
        case .notVouched:
            add("signed", label, String(localized: "Signed by a certificate Apple does not vouch for", bundle: .previewKit,
                                        comment: "Installer signature fact: the signature checks out, but its certificate does not chain to Apple."))
            add("signerKind", String(localized: "Signing certificate", bundle: .previewKit, comment: "Fact label: what kind of certificate signed the code (Developer ID, Apple's own, …)."),
                Self.notVouchedWord)
            add("claimedSigner", Self.claimedSignerLabel, leaf)
            badges.append(notVouchedBadge)
        case .broken(let reason):
            add("signed", label, String(localized: "Broken: \(reason)", bundle: .previewKit, comment: "Signature fact: broken, then the system's reason."))
            add("claimedSigner", Self.claimedSignerLabel, leaf)
            badges.append(Badge(level: .danger, title: Self.signatureBrokenWord, detail: reason))
        case .notVerified(let reason):
            add("signed", label, String(localized: "Signed (not verified): \(reason)", bundle: .previewKit,
                                        comment: "Installer signature fact: signed, but the signature could not be verified; then the reason."))
            add("claimedSigner", Self.claimedSignerLabel, leaf)
            badges.append(Badge(level: .caution, title: Self.notVerifiedWord, detail: reason))
        }
    }

    static var stapledVerifiedWord: String {
        String(localized: "Stapled and verified by macOS", bundle: .previewKit,
               comment: "Notarization fact: Apple's ticket is stapled to the file and the system verified it.")
    }
    static var notarizedWord: String {
        String(localized: "Notarized (verified by macOS)", bundle: .previewKit,
               comment: "Notarization fact: the system verified Apple's notarization for this code, from a ticket it already holds.")
    }
    static var ticketUnverifiedWord: String {
        String(localized: "Ticket present, not verified", bundle: .previewKit,
               comment: "Notarization fact: a ticket-shaped file is present, but the system did not verify it.")
    }
    static var notCheckedWord: String {
        String(localized: "Not checked: the check did not finish in time", bundle: .previewKit,
               comment: "Signature fact: the signature check did not finish in time for the preview.")
    }
    static var signedByLabel: String { String(localized: "Signed by", bundle: .previewKit, comment: "Fact label: who signed the code.") }
    static var claimedSignerLabel: String {
        String(localized: "Certificate name (not verified)", bundle: .previewKit, comment: "Fact label: the name a signing certificate gives itself, which nothing vouched for.")
    }
    static var appleIssuedWord: String {
        String(localized: "Issued by Apple, not a Developer ID", bundle: .previewKit, comment: "Signing certificate fact: an Apple-issued development or other certificate, not a Developer ID.")
    }
    static var notVouchedWord: String {
        String(localized: "Not vouched for by Apple", bundle: .previewKit, comment: "Signing certificate fact: the certificate does not chain to Apple (self-signed or another authority).")
    }
    static var notVerifiedWord: String {
        String(localized: "Signature not verified", bundle: .previewKit, comment: "Warning title: a signature is present but could not be verified.")
    }
    static var signatureBrokenWord: String {
        String(localized: "Signature broken", bundle: .previewKit, comment: "Warning title: the code signature does not match the code.")
    }
    static var partlyCheckedWord: String {
        String(localized: "Partly checked: its other files were not checked in time", bundle: .previewKit,
               comment: "Signature fact: only the main code's signature was checked; the check of the other files did not finish in time.")
    }
    static var notFullyCheckedBadge: Badge {
        Badge(level: .caution, title: String(localized: "Not fully checked", bundle: .previewKit,
                                             comment: "Warning title: only part of the signature was checked in time for the preview."),
              detail: String(localized: "Checking every file inside takes longer than a preview allows, so only the main code's signature was checked.", bundle: .previewKit,
                             comment: "Warning detail: only the main code's signature was checked in time for the preview."))
    }
    static var notVouchedBadge: Badge {
        Badge(level: .caution, title: String(localized: "Apple does not vouch for the signer", bundle: .previewKit,
                                             comment: "Warning title: the signing certificate does not chain to Apple."),
              detail: String(localized: "It is signed by a certificate that does not chain to Apple, so nobody Apple checked stands behind it.", bundle: .previewKit,
                             comment: "Warning detail: the signing certificate does not chain to Apple (self-signed or another authority)."))
    }

    /// "41 days" from today to a future date (calendar days, "1 day", "0 days" on the day itself); nil once it has
    /// passed. roadmap: S-22
    static func daysLeft(until date: Date, from now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard date >= now else { return nil }
        let days = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0)
        return String(localized: "\(days) days", bundle: .previewKit, comment: "How many calendar days a profile or certificate has left.")
    }

    /// A flat file's size on disk, for installers and disk images (the card's number strip).
    static func fileSize(_ url: URL) -> String? {
        guard let n = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func signatureWord(_ s: SignatureAssessment) -> String {
        switch s.status {
        case .valid: String(localized: "signed", bundle: .previewKit, comment: "App pill, after the version (lower case): the app is signed.")
        case .adhoc: String(localized: "ad-hoc signed", bundle: .previewKit, comment: "App pill, after the version (lower case): signed ad hoc.")
        case .unsigned: String(localized: "not signed", bundle: .previewKit, comment: "App pill, after the version (lower case): no signature.")
        case .invalid: String(localized: "signature broken", bundle: .previewKit, comment: "App pill, after the version (lower case): the signature is broken.")
        default: String(localized: "signature unknown", bundle: .previewKit, comment: "App pill, after the version (lower case): the signature state is unknown.")
        }
    }

    /// The notarization fact for a bundle with no verified ticket: what its bytes carry. A ticket-shaped file is
    /// never named here; `notarization(_:notTicket:badges:)` turns it into "not verified".
    static func stapled(_ t: StapledTicket) -> String? {
        switch t {
        case .present: nil
        case .notStapled: String(localized: "Not stapled (macOS may still check online)", bundle: .previewKit,
                                 comment: "Notarization fact: no ticket is stapled; macOS may still look it up online.")
        case .unrecognized(let why): String(localized: "Unrecognised: \(why)", bundle: .previewKit,
                                            comment: "Notarization fact: the stapled ticket is not understood; then the reason.")
        case .notApplicable: nil
        }
    }
}
