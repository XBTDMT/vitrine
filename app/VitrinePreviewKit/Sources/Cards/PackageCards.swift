import Foundation
import VitrineDocument
import VitrineSupport

/// The Glass Case wording for torrents, configuration profiles and iOS and Android apps, from the facts PackageFacts
/// read. Where the trust design drew the state (trust r3-a: the torrent, the Wi-Fi profile, the ad hoc .ipa) its
/// questions and phrasing are followed; the Android card, which the design did not draw, asks the same kinds of
/// question in the same voice. The fact values compared here are PackageFacts.Word's, so the checks hold in every
/// language. roadmap: S-8
extension BinaryCard {
    // MARK: Torrent

    static func torrent(_ doc: PreviewDocument, fileName: String, top: Badge.Level?, worst: Badge?) -> BinaryCard {
        let v = { (key: String) in doc.fact(key)?.value }
        let name = v("name") ?? fileName
        let files = v("files") ?? "0"
        let filesPhrase = files == "1"
            ? String(localized: "1 file", bundle: .previewKit, comment: "A count of exactly one file.")
            : String(localized: "\(files) files", bundle: .previewKit, comment: "A count of files; e.g. “3 files”.")
        let size = v("downloadSize") ?? "?"
        let trackers = Int(v("trackers") ?? "") ?? 0
        let isPrivate = v("private") == PackageFacts.Word.privateTrackers
        let sharers: String
        switch (trackers, isPrivate) {
        case (0, _): sharers = String(localized: "peers it finds itself (no trackers listed)", bundle: .previewKit, comment: "Who shares a torrent that lists no trackers.")
        case (1, true): sharers = String(localized: "1 private tracker", bundle: .previewKit, comment: "Who shares a torrent: one private tracker.")
        case (1, false): sharers = String(localized: "1 public tracker", bundle: .previewKit, comment: "Who shares a torrent: one public tracker.")
        case (let n, true):
            let count = n.formatted()
            sharers = String(localized: "\(count) private trackers", bundle: .previewKit, comment: "Who shares a torrent; e.g. “2 private trackers”.")
        case (let n, false):
            let count = n.formatted()
            sharers = String(localized: "\(count) public trackers", bundle: .previewKit, comment: "Who shares a torrent; e.g. “2 public trackers”.")
        }
        let programs = Int(v("programs") ?? "0") ?? 0
        let sentence = String(localized: "A torrent for \(filesPhrase), \(size) in all, shared through \(sharers); Vitrine never contacts them.", bundle: .previewKit,
                              comment: "A torrent's sentence: its files, total size and who shares it; e.g. “A torrent for 3 files, 4 GB in all, shared through 2 public trackers; Vitrine never contacts them.”")
        let strip = firstThree([
            Stat(value: files, label: String(localized: "Files", bundle: .previewKit, comment: "Card label: how many files the torrent names.")),
            Stat(value: size, label: String(localized: "To download", bundle: .previewKit, comment: "Card label: the torrent's total download size.")),
            trackers > 0 ? Stat(value: trackers.formatted(), label: String(localized: "Trackers", bundle: .previewKit, comment: "Card label: how many trackers the torrent lists.")) : nil,
            v("pieceSize").map { Stat(value: $0, label: String(localized: "Piece size", bundle: .previewKit, comment: "Card label: the size of each piece of the torrent.")) },
        ])
        let programMark: Answer.Mark = programs == 0 ? .ok : (top == .danger ? .danger : .caution)
        let programsAnswer: String
        switch programs {
        case 0: programsAnswer = Phrase.no
        case 1: programsAnswer = String(localized: "Yes, 1 program", bundle: .previewKit, comment: "Trust card answer: one file in the torrent runs when opened.")
        default:
            let count = programs.formatted()
            programsAnswer = String(localized: "Yes, \(count) programs", bundle: .previewKit, comment: "Trust card answer: how many files in the torrent run when opened; e.g. “Yes, 3 programs”.")
        }
        var answers = [
            Answer(mark: .neutral, question: String(localized: "What will it download", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                   answer: String(localized: "\(filesPhrase), \(size) in total", bundle: .previewKit, comment: "Trust card answer: a torrent's files and size; e.g. “3 files, 4 GB in total”."),
                   evidence: v("largest")),
            Answer(mark: programMark, question: String(localized: "Is anything in it a program", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                   answer: programsAnswer, evidence: v("programNames")),
            Answer(mark: .neutral, question: String(localized: "Who shares it", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                   answer: sharers.prefix(1).uppercased() + sharers.dropFirst(), evidence: v("trackerHosts")),
        ]
        if top == .danger, let worst, worst.title != PackageFacts.programsInsideTitle(programs) {
            answers.insert(Answer(mark: .danger, question: String(localized: "Where would it write", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                  answer: worst.title, evidence: worst.detail), at: 0)
        }
        let filesCapitalized = filesPhrase.prefix(1).uppercased() + filesPhrase.dropFirst()
        return BinaryCard(kind: doc.kind, title: name, sentence: sentence, bold: [filesPhrase, size, sharers],
                          stageChip: String(localized: "Torrent", bundle: .previewKit, comment: "The kind chip on a torrent's card."),
                          strip: strip, rule: top,
                          verdict: verdict(worst, opening: String(localized: "Check before downloading", bundle: .previewKit, comment: "Verdict chip: a caution about a torrent."),
                                           calmTitle: programs == 0
                                               ? String(localized: "\(filesCapitalized), no programs", bundle: .previewKit, comment: "Calm verdict title for a torrent; e.g. “3 files, no programs”.")
                                               : String(localized: "No warnings for this torrent", bundle: .previewKit, comment: "Calm verdict title for a torrent with no findings."),
                                           calmReason: String(localized: "Nothing in it runs when opened; Vitrine never contacts its trackers.", bundle: .previewKit,
                                                              comment: "Calm verdict reason for a torrent.")),
                          answers: answers)
    }

    // MARK: Configuration profile

    static func configurationProfile(_ doc: PreviewDocument, fileName: String, top: Badge.Level?, worst: Badge?) -> BinaryCard {
        let v = { (key: String) in doc.fact(key)?.value }
        let name = v("name") ?? fileName
        let kinds = (v("payloadList") ?? "").components(separatedBy: "\n").compactMap { $0.components(separatedBy: ": ").first }
            .filter { !$0.isEmpty }
        let count = v("payloadCount") ?? "0"
        let encrypted = count == PackageFacts.Word.encrypted
        let what = kinds.isEmpty
            ? (encrypted ? String(localized: "encrypted payloads", bundle: .previewKit, comment: "What a configuration profile holds: encrypted payloads.")
                         : String(localized: "no payloads", bundle: .previewKit, comment: "What a configuration profile holds: nothing."))
            : naturalList(kinds.map(article))
        let signature = v("signed") ?? PackageFacts.Word.notSigned
        let signedClause: String
        switch signature {
        case PackageFacts.Word.signedAndTrusted:
            signedClause = String(localized: "it is signed and verified", bundle: .previewKit, comment: "End of a configuration profile's sentence: a trusted signature.")
        case PackageFacts.Word.broken:
            signedClause = String(localized: "its signature is broken", bundle: .previewKit, comment: "End of a configuration profile's sentence: the signature does not match.")
        case PackageFacts.Word.notSigned:
            signedClause = String(localized: "it is not signed", bundle: .previewKit, comment: "End of a configuration profile's sentence: no signature.")
        default:
            signedClause = String(localized: "it is signed, but macOS cannot verify the signer", bundle: .previewKit,
                                  comment: "End of a configuration profile's sentence: a signature macOS does not trust.")
        }
        let sentence = v("organization").map { organization in
            String(localized: "A configuration profile from \(organization) with \(what); \(signedClause).", bundle: .previewKit,
                   comment: "A configuration profile's sentence: who sent it, what it holds and its signature; e.g. “A configuration profile from Example Corp IT with Wi-Fi, a VPN and a root certificate; it is not signed.”")
        } ?? String(localized: "A configuration profile with \(what); \(signedClause).", bundle: .previewKit,
                    comment: "A configuration profile's sentence: what it holds and its signature.")
        let removable = v("removable") ?? PackageFacts.Word.yes
        let strip = firstThree([
            Stat(value: count, label: String(localized: "Payloads", bundle: .previewKit, comment: "Card label: how many payloads the profile has.")),
            Stat(value: removable, label: String(localized: "Removable", bundle: .previewKit, comment: "Card label: whether the profile can be removed.")),
            v("size").map { Stat(value: $0, label: String(localized: "Size", bundle: .previewKit, comment: "Card label: the file size.")) },
        ])
        let signer = v("signer")
        let whoMark: Answer.Mark
        let whoAnswer: String
        switch signature {
        case PackageFacts.Word.signedAndTrusted:
            whoMark = .ok
            whoAnswer = signer.map { String(localized: "Signed “\($0)”", bundle: .previewKit, comment: "Trust card answer to “Who sent it”: the signer's name in quotes.") }
                ?? String(localized: "Signed and verified", bundle: .previewKit, comment: "Trust card answer to “Who sent it”: a trusted signature.")
        case PackageFacts.Word.broken:
            whoMark = .danger
            whoAnswer = String(localized: "Its signature does not match its content", bundle: .previewKit, comment: "Trust card answer to “Who sent it”: a broken signature.")
        case PackageFacts.Word.notSigned:
            whoMark = .caution
            whoAnswer = Phrase.nobodyUnsigned
        default:
            whoMark = .caution
            whoAnswer = signer.map {
                String(localized: "Signed “\($0)”, but macOS cannot verify it", bundle: .previewKit, comment: "Trust card answer to “Who sent it”: an untrusted signer's name in quotes.")
            } ?? String(localized: "Signed, but macOS cannot verify it", bundle: .previewKit, comment: "Trust card answer to “Who sent it”: an untrusted signature.")
        }
        let sensitive = doc.badges.contains { $0.level == .caution && $0.title != PackageFacts.Word.cannotBeRemoved }
        let removeAnswer: String
        switch removable {
        case PackageFacts.Word.no:
            removeAnswer = String(localized: "No, only its administrator can", bundle: .previewKit, comment: "Trust card answer to “Can I remove it later”: no.")
        case PackageFacts.Word.yes:
            removeAnswer = PackageFacts.Word.yes
        default:
            removeAnswer = String(localized: "Yes, with its removal password", bundle: .previewKit, comment: "Trust card answer to “Can I remove it later”: with a password.")
        }
        let answers = [
            Answer(mark: whoMark, question: String(localized: "Who sent it", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                   answer: whoAnswer,
                   evidence: whoMark == .caution && signature != PackageFacts.Word.notSigned
                       ? String(localized: "signer certificate not in a trusted chain", bundle: .previewKit, comment: "Trust card evidence line: why the signer is not trusted.") : nil),
            Answer(mark: sensitive ? .caution : .neutral,
                   question: String(localized: "What does it change", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                   answer: v("payloadKinds") ?? what,
                   evidence: encrypted ? nil : PackageFacts.payloadsPhrase(Int(count) ?? 0)),
            Answer(mark: removable == PackageFacts.Word.no ? .caution : .ok,
                   question: String(localized: "Can I remove it later", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                   answer: removeAnswer),
        ]
        return BinaryCard(kind: doc.kind, title: name, sentence: sentence, bold: [what, signedClause],
                          stageChip: String(localized: "Configuration profile", bundle: .previewKit, comment: "The kind chip on a configuration profile's card."),
                          strip: strip, rule: top,
                          verdict: verdict(worst, opening: Phrase.checkBeforeInstalling,
                                           calmTitle: String(localized: "No warnings for this profile", bundle: .previewKit, comment: "Calm verdict title for a configuration profile."),
                                           calmReason: String(localized: "Installing it changes the settings listed; you can remove it in System Settings.", bundle: .previewKit,
                                                              comment: "Calm verdict reason for a configuration profile.")),
                          answers: answers)
    }

    /// "Wi-Fi" → "Wi-Fi", "VPN" → "a VPN", "Root certificate" → "a root certificate". English grammar, so applied only
    /// when the card speaks English; other languages list the payload kinds as their localized names.
    static func article(_ kind: String) -> String {
        if let language = Bundle.previewKit.preferredLocalizations.first, language != "Base", !language.hasPrefix("en") { return kind }
        switch kind {
        case "Wi-Fi", "Restrictions", "Custom settings", "Privacy permissions", "Notifications", "System extensions",
             "Kernel extensions", "Login and background items", "FileVault", "Software Update", "Encrypted DNS settings":
            return kind
        default:
            let lower = kind.first?.isUppercase == true && kind.dropFirst().first?.isLowercase == true ? kind.lowercased() : kind
            return (["a", "e", "i", "o", "u"].contains(lower.prefix(1).lowercased()) ? "an " : "a ") + lower
        }
    }

    /// "a, b and c", in the reader's language.
    static func naturalList(_ items: [String]) -> String { InfoCard.list(items) }

    // MARK: iOS app

    static func iosApp(_ doc: PreviewDocument, fileName: String, top: Badge.Level?, worst: Badge?) -> BinaryCard {
        let v = { (key: String) in doc.fact(key)?.value }
        let name = v("name") ?? fileName
        let version = v("version")
        let devices = v("devices").map { naturalList($0.components(separatedBy: ", ")) }
        let requires = v("minimumOS")
        let distribution = v("distribution")
        let team = v("team")
        let distPhrase: String
        if let distribution, distribution == PackageFacts.Word.appStoreEncrypted {
            distPhrase = String(localized: "downloaded from the App Store", bundle: .previewKit, comment: "End of an iOS app's sentence: it came from the App Store.")
        } else if let distribution {
            switch (startsWithVowel(distribution), team) {
            case let (true, team?):
                distPhrase = String(localized: "an \(distribution) build from \(team)", bundle: .previewKit, comment: "End of an iOS app's sentence; e.g. “an ad hoc build from Example Co”.")
            case let (false, team?):
                distPhrase = String(localized: "a \(distribution) build from \(team)", bundle: .previewKit, comment: "End of an iOS app's sentence; e.g. “a development build from Example Co”.")
            case (true, nil):
                distPhrase = String(localized: "an \(distribution) build", bundle: .previewKit, comment: "End of an iOS app's sentence; e.g. “an ad hoc build”.")
            case (false, nil):
                distPhrase = String(localized: "a \(distribution) build", bundle: .previewKit, comment: "End of an iOS app's sentence; e.g. “a development build”.")
            }
        } else {
            distPhrase = String(localized: "with no provisioning profile", bundle: .previewKit, comment: "End of an iOS app's sentence: it carries no profile.")
        }
        let sentence: String
        switch (version, devices, requires) {
        case let (version?, devices?, requires?):
            sentence = String(localized: "An iOS app, version \(version), for \(devices) on \(requires); \(distPhrase).", bundle: .previewKit,
                              comment: "An iOS app's sentence; e.g. “An iOS app, version 1.4 (12), for iPhone and iPad on iOS 17.0 or later; an ad hoc build from Example Co.”")
        case let (version?, devices?, nil):
            sentence = String(localized: "An iOS app, version \(version), for \(devices); \(distPhrase).", bundle: .previewKit, comment: "An iOS app's sentence: version, devices, distribution.")
        case let (version?, nil, requires?):
            sentence = String(localized: "An iOS app, version \(version), on \(requires); \(distPhrase).", bundle: .previewKit, comment: "An iOS app's sentence: version, minimum iOS, distribution.")
        case let (version?, nil, nil):
            sentence = String(localized: "An iOS app, version \(version); \(distPhrase).", bundle: .previewKit, comment: "An iOS app's sentence: version and distribution.")
        case let (nil, devices?, requires?):
            sentence = String(localized: "An iOS app for \(devices) on \(requires); \(distPhrase).", bundle: .previewKit, comment: "An iOS app's sentence: devices, minimum iOS, distribution.")
        case let (nil, devices?, nil):
            sentence = String(localized: "An iOS app for \(devices); \(distPhrase).", bundle: .previewKit, comment: "An iOS app's sentence: devices and distribution.")
        case let (nil, nil, requires?):
            sentence = String(localized: "An iOS app on \(requires); \(distPhrase).", bundle: .previewKit, comment: "An iOS app's sentence: minimum iOS and distribution.")
        case (nil, nil, nil):
            sentence = String(localized: "An iOS app; \(distPhrase).", bundle: .previewKit, comment: "An iOS app's sentence: its distribution.")
        }
        let strip = firstThree([
            version.map { Stat(value: String($0.split(separator: " ").first ?? ""), label: String(localized: "Version", bundle: .previewKit, comment: "Card label: the version.")) },
            requires.map { Stat(value: shortRequirement($0), label: String(localized: "Requires", bundle: .previewKit, comment: "Card label: the oldest system the app runs on.")) },
            v("expiresIn").map { left in
                Stat(value: String(localized: "in \(left)", bundle: .previewKit, comment: "How long until something expires; e.g. “in 41 days”."),
                     label: String(localized: "Profile expires", bundle: .previewKit, comment: "Card label: when the app's provisioning profile expires."))
            },
            v("size").map { Stat(value: $0, label: String(localized: "Size", bundle: .previewKit, comment: "Card label: the file size.")) },
        ])
        let expired = doc.badges.contains { $0.title == PackageFacts.Word.expired }
        // PackageFacts gives an .ipa the profile's caution first (Expired, or expiring within two weeks), then its
        // signature's (S-16 follow-up B): a caution that is not a signature's is the profile expiring soon.
        let signatureTitles: Set<String> = [BinaryFacts.notVerifiedWord, BinaryFacts.notVouchedBadge.title, PackageFacts.Word.notSigned]
        let expiringSoon = !expired && doc.badges.contains { $0.level == .caution && $0.title != PackageFacts.Word.expired && !signatureTitles.contains($0.title) }
        var answers: [Answer] = []
        if let expires = v("expires") {
            let evidence = [String(localized: "profile expires \(expires)", bundle: .previewKit, comment: "Trust card evidence line: the profile's expiry date."),
                            v("certificateExpires").map { String(localized: "certificate \($0)", bundle: .previewKit, comment: "Trust card evidence line: the certificate's expiry date.") }]
                .compactMap { $0 }.joined(separator: " · ")
            answers.append(Answer(mark: expired || expiringSoon ? .caution : .ok, question: Phrase.isItStillValid,
                                  answer: expired ? String(localized: "No, its profile expired on \(expires)", bundle: .previewKit,
                                                           comment: "Trust card answer: the app's profile has expired; the argument is the date.")
                                                  : (v("expiresIn").map(moreDays) ?? Phrase.yes),
                                  evidence: evidence))
        }
        // A maker only from a verified signature (G-34, S-16 follow-up B): the team when the profile vouches for it,
        // else the verified signer; a name nothing verified is the certificate's claim, with a caution mark.
        let signer = v("signer")
        let claimed = v("claimedSigner")
        if let maker = team ?? signer {
            answers.append(Answer(mark: .ok, question: Phrase.whoMadeIt, answer: maker, evidence: v("signatureScope")))
        } else if notVouched(v) {
            answers.append(Answer(mark: .caution, question: Phrase.whoMadeIt, answer: Phrase.notVouchedSigner, evidence: claimed.map(Phrase.claims)))
        } else if fact(v("signed"), is: "Not signed", PackageFacts.Word.notSigned) {
            answers.append(Answer(mark: .neutral, question: Phrase.whoMadeIt, answer: Phrase.nobodyUnsigned))
        } else if let claimed {
            answers.append(Answer(mark: .caution, question: Phrase.whoMadeIt, answer: Phrase.notVerified, evidence: Phrase.claims(claimed)))
        } else {
            answers.append(Answer(mark: .neutral, question: Phrase.whoMadeIt, answer: Phrase.unknown))
        }
        if let distribution {
            answers.append(Answer(mark: .neutral, question: Phrase.howIsItDistributed, answer: Phrase.distributed(distribution, devices: v("devicesRegistered"))))
        }
        if let uses = v("uses") {
            answers.append(Answer(mark: .neutral, question: Phrase.whatCanItDo, answer: uses.prefix(1).uppercased() + uses.dropFirst(),
                                  evidence: v("entitlementsFrom").map { String(localized: "entitlements from \($0)", bundle: .previewKit,
                                                                               comment: "Trust card evidence line: where the entitlements were read; e.g. “entitlements from the app's signature”.") }))
        }
        let opening = expired ? PackageFacts.Word.expired
            : (expiringSoon ? String(localized: "Expires soon", bundle: .previewKit, comment: "Verdict chip: the app's provisioning profile expires within two weeks.")
                            : Phrase.checkBeforeInstalling)
        return BinaryCard(kind: doc.kind, title: name, sentence: sentence, bold: [version, distPhrase].compactMap { $0 },
                          stageChip: String(localized: "iOS app", bundle: .previewKit, comment: "The kind chip on an iOS app's card."),
                          strip: strip, rule: top,
                          verdict: verdict(worst, opening: opening,
                                           calmTitle: team.map { String(localized: "Built by \($0)", bundle: .previewKit, comment: "Calm verdict title: the developer team; e.g. “Built by Example Co”.") }
                                               ?? signer.map(Phrase.signedBy) ?? Phrase.noWarningsForThisApp,
                                           calmReason: v("expiresIn").map { String(localized: "Its provisioning profile is valid for \($0) more.", bundle: .previewKit,
                                                                                   comment: "Calm verdict reason; e.g. “Its provisioning profile is valid for 41 days more.”") }
                                               ?? String(localized: "Install it through the App Store, TestFlight or your team's own channel.", bundle: .previewKit,
                                                         comment: "Calm verdict reason for an iOS app.")),
                          answers: answers)
    }

    /// "iOS 17.0 or later" → "iOS 17.0+": the version read back from the fact, so it works in any language.
    static func shortRequirement(_ requirement: String) -> String {
        guard let range = requirement.range(of: #"[0-9]+(\.[0-9]+)*"#, options: .regularExpression) else { return requirement }
        let version = String(requirement[range])
        return String(localized: "iOS \(version)+", bundle: .previewKit, comment: "The oldest iOS an app runs on, short; e.g. “iOS 17.0+”.")
    }

    // MARK: Android app

    static func androidApp(_ doc: PreviewDocument, fileName: String, top: Badge.Level?, worst: Badge?) -> BinaryCard {
        let v = { (key: String) in doc.fact(key)?.value }
        let name = v("name") ?? fileName
        let version = v("version")
        let permissions = Int(v("permissionCount") ?? "0") ?? 0
        let sensitive = v("dangerous")?.components(separatedBy: PackageFacts.listSeparator) ?? []
        let requires = v("minSDK")
        let permissionPhrase: String
        switch (permissions, sensitive.count) {
        case (0, _): permissionPhrase = String(localized: "asks for no permissions", bundle: .previewKit, comment: "Part of an Android app's sentence.")
        case (1, 0): permissionPhrase = String(localized: "asks for 1 permission, none sensitive", bundle: .previewKit, comment: "Part of an Android app's sentence.")
        case (1, _): permissionPhrase = String(localized: "asks for 1 permission, a sensitive one", bundle: .previewKit, comment: "Part of an Android app's sentence.")
        case (let n, 0):
            let count = n.formatted()
            permissionPhrase = String(localized: "asks for \(count) permissions, none sensitive", bundle: .previewKit,
                                      comment: "Part of an Android app's sentence; e.g. “asks for 3 permissions, none sensitive”.")
        case (let n, let k):
            let count = n.formatted(), sensitiveCount = k.formatted()
            permissionPhrase = String(localized: "asks for \(count) permissions, \(sensitiveCount) of them sensitive", bundle: .previewKit,
                                      comment: "Part of an Android app's sentence; e.g. “asks for 3 permissions, 2 of them sensitive”.")
        }
        let subject = v("package").map { String(localized: "An Android app (\($0))", bundle: .previewKit, comment: "Start of an Android app's sentence: its package name.") }
            ?? String(localized: "An Android app", bundle: .previewKit, comment: "Start of an Android app's sentence.")
        let sentence: String
        switch (version, requires) {
        case let (version?, requires?):
            sentence = String(localized: "\(subject), version \(version), for \(requires) and later; it \(permissionPhrase).", bundle: .previewKit,
                              comment: "An Android app's sentence; e.g. “An Android app (com.example.trailmap), version 3.1.0 (42), for Android 8.0 (API 26) and later; it asks for 3 permissions, 2 of them sensitive.”")
        case let (version?, nil):
            sentence = String(localized: "\(subject), version \(version); it \(permissionPhrase).", bundle: .previewKit, comment: "An Android app's sentence: version and permissions.")
        case let (nil, requires?):
            sentence = String(localized: "\(subject) for \(requires) and later; it \(permissionPhrase).", bundle: .previewKit, comment: "An Android app's sentence: minimum Android and permissions.")
        case (nil, nil):
            sentence = String(localized: "\(subject); it \(permissionPhrase).", bundle: .previewKit, comment: "An Android app's sentence: its permissions.")
        }
        let strip = firstThree([
            version.map { Stat(value: String($0.split(separator: " ").first ?? ""), label: String(localized: "Version", bundle: .previewKit, comment: "Card label: the version.")) },
            requires.map { Stat(value: $0.components(separatedBy: " (").first ?? $0, label: String(localized: "Requires", bundle: .previewKit, comment: "Card label: the oldest system the app runs on.")) },
            Stat(value: permissions.formatted(), label: String(localized: "Permissions", bundle: .previewKit, comment: "Card label: how many permissions the app asks for.")),
            v("size").map { Stat(value: $0, label: String(localized: "Size", bundle: .previewKit, comment: "Card label: the file size.")) },
        ])
        let signature = v("schemes") ?? PackageFacts.Word.notSigned
        let unsigned = signature == PackageFacts.Word.notSigned
        let debuggable = v("debuggable") == PackageFacts.Word.yes
        let list = naturalList(sensitive)
        let answers = [
            Answer(mark: sensitive.isEmpty ? .ok : .caution, question: Phrase.whatCanItDo,
                   answer: sensitive.isEmpty ? String(localized: "Nothing sensitive", bundle: .previewKit, comment: "Trust card answer to “What can it do”: no sensitive permissions.")
                                             : String(localized: "Use \(list)", bundle: .previewKit, comment: "Trust card answer to “What can it do”; e.g. “Use precise location and camera”."),
                   evidence: sensitive.isEmpty ? nil : v("permissions")),
            // An APK's certificate names itself and nothing verifies it (G-34, S-16 follow-up B): a claim, never a maker.
            v("claimedSigner").map { Answer(mark: .caution, question: Phrase.whoMadeIt, answer: Phrase.notVerified, evidence: Phrase.claims($0)) }
                ?? Answer(mark: .neutral, question: Phrase.whoMadeIt,
                          answer: unsigned ? Phrase.nobodyUnsigned
                                           : String(localized: "Unknown (no certificate read)", bundle: .previewKit, comment: "Trust card answer to “Who made it”: no certificate was read.")),
            Answer(mark: unsigned ? .caution : .neutral,
                   question: String(localized: "How is it signed", bundle: .previewKit, comment: "Trust card question (written without its question mark)."), answer: signature),
            Answer(mark: debuggable ? .caution : .ok,
                   question: String(localized: "Is it a debug build", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                   answer: debuggable ? String(localized: "Yes, it can be debugged on any phone", bundle: .previewKit, comment: "Trust card answer: a debuggable Android app.") : Phrase.no),
        ]
        return BinaryCard(kind: doc.kind, title: name, sentence: sentence, bold: [version, permissionPhrase].compactMap { $0 },
                          stageChip: String(localized: "Android app", bundle: .previewKit, comment: "The kind chip on an Android app's card."),
                          strip: strip, rule: top,
                          verdict: verdict(worst, opening: Phrase.checkBeforeInstalling,
                                           calmTitle: Phrase.noWarningsForThisApp,
                                           calmReason: String(localized: "It asks for nothing sensitive; Vitrine did not verify its signature.", bundle: .previewKit,
                                                              comment: "Calm verdict reason for an Android app.")),
                          answers: answers)
    }
}
