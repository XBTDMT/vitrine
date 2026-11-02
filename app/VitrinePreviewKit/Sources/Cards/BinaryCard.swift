import Foundation
import VitrineDocument
import VitrineSupport

/// What the Glass Case card says about an app, installer, disk image or provisioning profile, worked out from the
/// facts and badges BinaryFacts already read (cards r3-a, trust r3-a Verdict first). Pure data, so the wording is
/// tested without drawing anything. Where the trust design has words for a case they are used as drawn ("Checks
/// passed", "Check before opening", "Gatekeeper will open it without a warning."); the rest is plain words of our
/// own. Every sentence is one localized phrase with its parts as arguments; the bold parts are those arguments, or
/// words localized on their own that match the sentence. roadmap: S-8, S-22
struct BinaryCard: Equatable {
    struct Stat: Equatable { var value: String; var label: String }

    /// One question the trust card answers (trust r3-a 4): a mark, the question, the answer and, under a finding, the
    /// evidence line the answer rests on.
    struct Answer: Equatable {
        enum Mark: Equatable { case ok, neutral, caution, danger }
        var mark: Mark
        /// Written without the question mark: the calm list drops it, the caution and danger rows add it.
        var question: String
        var answer: String
        var evidence: String?
        /// The row is a question (it gets its question mark in full rows); a format reader's rows are labels and
        /// subjects ("Services", "agent") and turn it off.
        var asksQuestion = true

        /// A finding: a reason to look twice, numbered on the card.
        var isFinding: Bool { mark == .caution || mark == .danger }
    }

    struct Verdict: Equatable {
        enum Level: Equatable { case calm, caution, danger }
        var level: Level
        var title: String
        var reason: String
        var chip: String
    }

    var kind: FileKind
    var title: String
    /// The museum label's sentence; the `bold` parts are drawn in t1 and semibold.
    var sentence: String
    var bold: [String]
    /// The one glass chip on the stage: the kind, in words (system.html's calm card).
    var stageChip: String
    /// At most three numbers (cards r3-a: "three numbers").
    var strip: [Stat]
    /// The 3 pt top rule: the most serious badge, nil when nothing is above info.
    var rule: Badge.Level?
    var verdict: Verdict
    var answers: [Answer]

    /// Caution and danger: the findings first, worst first, numbered from 1 (trust r3-a "wrong answers first with
    /// numbered evidence"); then the rest unnumbered. Calm: every answer, unnumbered, in the tight list.
    var numberedAnswers: [(number: Int?, answer: Answer)] {
        guard verdict.level != .calm else { return answers.map { (nil, $0) } }
        let findings = answers.filter { $0.mark == .danger } + answers.filter { $0.mark == .caution }
        return findings.enumerated().map { (Optional($0.offset + 1), $0.element) } + answers.filter { !$0.isFinding }.map { (nil, $0) }
    }

    /// The questions and answers several cards share, each one localized phrase.
    enum Phrase {
        static var whoMadeIt: String { String(localized: "Who made it", bundle: .previewKit, comment: "Trust card question (written without its question mark).") }
        static var isItStillValid: String { String(localized: "Is it still valid", bundle: .previewKit, comment: "Trust card question (written without its question mark).") }
        static var howIsItDistributed: String { String(localized: "How is it distributed", bundle: .previewKit, comment: "Trust card question (written without its question mark).") }
        static var whatCanItDo: String { String(localized: "What can it do", bundle: .previewKit, comment: "Trust card question (written without its question mark).") }
        static var whatIsInside: String { String(localized: "What is inside", bundle: .previewKit, comment: "Trust card question (written without its question mark).") }
        static var hasAppleCheckedIt: String { String(localized: "Has Apple checked it", bundle: .previewKit, comment: "Trust card question (written without its question mark).") }
        static var yes: String { String(localized: "Yes", bundle: .previewKit, comment: "A fact's value: yes.") }
        static var no: String { String(localized: "No", bundle: .previewKit, comment: "A fact's value: no.") }
        static var unknown: String { String(localized: "Unknown", bundle: .previewKit, comment: "Trust card answer: who made it is not known.") }
        static var nobodyUnsigned: String {
            String(localized: "Nobody you can check: it is not signed", bundle: .previewKit, comment: "Trust card answer to “Who made it”: the file has no signature.")
        }
        static var noTicketStapled: String {
            String(localized: "No ticket stapled; macOS may check online", bundle: .previewKit, comment: "Trust card answer to “Has Apple checked it”: no notarization ticket in the file.")
        }
        static var checkBeforeInstalling: String { String(localized: "Check before installing", bundle: .previewKit, comment: "Verdict chip: a caution about something you install.") }
        static var checkBeforeOpening: String { String(localized: "Check before opening", bundle: .previewKit, comment: "Verdict chip: a caution about something you open.") }
        static var noWarningsForThisApp: String { String(localized: "No warnings for this app", bundle: .previewKit, comment: "Calm verdict title for an app with no findings.") }

        static var notVouchedSigner: String {
            String(localized: "Someone Apple does not vouch for", bundle: .previewKit, comment: "Trust card answer to “Who made it”: the signing certificate does not chain to Apple.")
        }
        static var notVerified: String {
            String(localized: "Not verified", bundle: .previewKit, comment: "Trust card answer to “Who made it”: a signature names someone, but nothing confirmed it.")
        }
        static var ticketNotVerified: String {
            String(localized: "Not verified: a ticket file is present, but macOS did not confirm it", bundle: .previewKit,
                   comment: "Trust card answer to “Has Apple checked it”: something shaped like a notarization ticket is present, but the system did not verify it.")
        }
        /// The evidence under a name nothing vouched for: the certificate's own words, quoted.
        static func claims(_ name: String) -> String {
            String(localized: "the certificate calls itself “\(name)”, which nothing verified", bundle: .previewKit,
                   comment: "Trust card evidence: the name a signing certificate gives itself, which nothing vouched for; e.g. “the certificate calls itself “Example Co”, which nothing verified”.")
        }

        static func signedBy(_ signer: String) -> String {
            String(localized: "Signed by \(signer)", bundle: .previewKit, comment: "Calm verdict title: who signed it; e.g. “Signed by Developer ID Application: Example Co”.")
        }

        /// "Development, to 12 registered devices": the distribution, capitalized, and the devices it names.
        static func distributed(_ distribution: String, devices: String?) -> String {
            let dist = distribution.prefix(1).uppercased() + distribution.dropFirst()
            guard let devices else { return dist }
            if devices == "1" {
                return String(localized: "\(dist), to 1 registered device", bundle: .previewKit,
                              comment: "How an app is distributed and to how many devices; e.g. “Ad hoc, to 1 registered device”.")
            }
            return String(localized: "\(dist), to \(devices) registered devices", bundle: .previewKit,
                          comment: "How an app is distributed and to how many devices; e.g. “Ad hoc, to 12 registered devices”.")
        }
    }

    /// Whether a fact BinaryFacts wrote has this value: its English form, or the same word localized (the facts may be
    /// written in either; the key is the same English word in the shared catalog).
    static func fact(_ value: String?, is english: String, _ localized: String) -> Bool {
        guard let value else { return false }
        return value == english || value == localized
    }

    /// Whether a fact BinaryFacts wrote starts with this word, in English or localized.
    static func fact(_ value: String?, startsWith english: String, _ localized: String) -> Bool {
        guard let value else { return false }
        return value.hasPrefix(english) || value.hasPrefix(localized)
    }

    /// Apple's ticket checked out (G-34): BinaryFacts writes these words only when the `notarized` requirement held.
    static func notarized(_ value: String?) -> Bool {
        fact(value, startsWith: "Stapled", BinaryFacts.stapledVerifiedWord) || fact(value, startsWith: "Notarized", BinaryFacts.notarizedWord)
    }

    /// A ticket-shaped file or slot that macOS did not verify.
    static func ticketUnverified(_ value: String?) -> Bool {
        fact(value, is: "Ticket present, not verified", BinaryFacts.ticketUnverifiedWord)
    }

    /// The signing certificate does not chain to Apple.
    static func notVouched(_ v: (String) -> String?) -> Bool {
        fact(v("signerKind"), is: "Not vouched for by Apple", BinaryFacts.notVouchedWord)
    }

    /// A signer Gatekeeper opens a download from without asking (Apple's own, Developer ID, App Store), as far as the
    /// facts say: a kind of certificate known to be anything else is not one.
    static func distributionIdentity(_ v: (String) -> String?) -> Bool {
        guard let kind = v("signerKind") else { return true }
        return !fact(kind, is: "Not vouched for by Apple", BinaryFacts.notVouchedWord)
            && !fact(kind, is: "Issued by Apple, not a Developer ID", BinaryFacts.appleIssuedWord)
    }

    static func make(document doc: PreviewDocument, url: URL) -> BinaryCard {
        let v = { (key: String) in doc.fact(key)?.value }
        let top = doc.badges.map(\.level).filter { $0 != .info }.max()
        let worst = doc.badges.filter { $0.level == top }.first
        let fileName = url.deletingPathExtension().lastPathComponent
        let notSignedWord = PackageFacts.Word.notSigned
        switch doc.kind {
        case .installerPackage:
            let id = v("identifier") ?? fileName
            let scripts = v("scripts")?.components(separatedBy: ", ") ?? []
            // BinaryFacts names the signer only when the whole signature verified (G-34, F58); a name nothing vouched
            // for is the claimed signer, never the answer.
            let signer = v("signer")
            let claimed = v("claimedSigner")
            let unsigned = fact(v("signed"), is: "Not signed", notSignedWord)
            let brokenSignature = fact(v("signed"), startsWith: "Broken", PackageFacts.Word.broken)
            let notVouchedSigner = notVouched(v)
            let signedPhrase: String
            if unsigned { signedPhrase = String(localized: "is not signed", bundle: .previewKit, comment: "End of an installer's sentence: “…; it runs no install scripts and is not signed.”") }
            else if let signer {
                signedPhrase = String(localized: "is signed by \(signer)", bundle: .previewKit, comment: "End of an installer's sentence: who signed it; e.g. “is signed by Developer ID Installer: Example Co”.")
            } else if notVouchedSigner {
                signedPhrase = String(localized: "is signed by someone Apple does not vouch for", bundle: .previewKit,
                                      comment: "End of an installer's sentence: its signing certificate does not chain to Apple.")
            } else if v("signed") != nil {
                signedPhrase = String(localized: "has a signature that is not verified", bundle: .previewKit,
                                      comment: "End of an installer's sentence: it carries a signature that could not be verified.")
            } else { signedPhrase = String(localized: "is signed", bundle: .previewKit, comment: "End of an installer's sentence: it carries a signature.") }
            let scriptPhrase: String
            switch scripts.count {
            case 0: scriptPhrase = String(localized: "runs no install scripts", bundle: .previewKit, comment: "Part of an installer's sentence: it runs no scripts.")
            case 1: scriptPhrase = String(localized: "runs 1 install script", bundle: .previewKit, comment: "Part of an installer's sentence: it runs one script.")
            default:
                let n = scripts.count.formatted()
                scriptPhrase = String(localized: "runs \(n) install scripts", bundle: .previewKit, comment: "Part of an installer's sentence: how many scripts it runs; e.g. “runs 2 install scripts”.")
            }
            let sentence: String
            switch (v("version"), v("installLocation")) {
            case let (version?, location?):
                sentence = String(localized: "An installer for \(id) version \(version) that copies files into \(location); it \(scriptPhrase) and \(signedPhrase).", bundle: .previewKit,
                                  comment: "An installer's sentence: package id, version, install location, then what it runs and its signature; e.g. “An installer for com.example.app version 3.1 that copies files into /Applications; it runs no install scripts and is signed.”")
            case let (version?, nil):
                sentence = String(localized: "An installer for \(id) version \(version) that copies files; it \(scriptPhrase) and \(signedPhrase).", bundle: .previewKit,
                                  comment: "An installer's sentence: package id and version, then what it runs and its signature.")
            case let (nil, location?):
                sentence = String(localized: "An installer for \(id) that copies files into \(location); it \(scriptPhrase) and \(signedPhrase).", bundle: .previewKit,
                                  comment: "An installer's sentence: package id and install location, then what it runs and its signature.")
            case (nil, nil):
                sentence = String(localized: "An installer for \(id) that copies files; it \(scriptPhrase) and \(signedPhrase).", bundle: .previewKit,
                                  comment: "An installer's sentence: package id, then what it runs and its signature.")
            }
            let strip = firstThree([
                v("version").map { Stat(value: $0, label: String(localized: "Version", bundle: .previewKit, comment: "Card label: the version.")) },
                Stat(value: scripts.count.formatted(), label: String(localized: "Scripts", bundle: .previewKit, comment: "Card label: how many install scripts run.")),
                v("installLocation").map { Stat(value: $0, label: String(localized: "Installs to", bundle: .previewKit, comment: "Card label: where the installer puts its files.")) },
                v("size").map { Stat(value: $0, label: String(localized: "Size", bundle: .previewKit, comment: "Card label: the file size.")) },
            ])
            let runs: String
            switch scripts.count {
            case 0: runs = String(localized: "Nothing; it only copies files", bundle: .previewKit, comment: "Trust card answer to “What else does it do”: the installer runs no scripts.")
            case 1: runs = String(localized: "Runs 1 install script", bundle: .previewKit, comment: "Trust card answer to “What else does it do”.")
            default:
                let n = scripts.count.formatted()
                runs = String(localized: "Runs \(n) install scripts", bundle: .previewKit, comment: "Trust card answer to “What else does it do”; e.g. “Runs 2 install scripts”.")
            }
            // What the scripts would do, when the lens read them (T-2): the first finding answers, the rest are the evidence.
            let findings = v("scriptFindings")?.components(separatedBy: "\n") ?? []
            let dangerousScript = doc.badges.contains { $0.level == .danger }
            // Where it was downloaded from (T-1), beside who signed it: the address is the only origin an unsigned file has.
            let downloaded = v("downloadedFrom").map { from in
                v("downloadedWith").map { String(localized: "downloaded from \(from) with \($0)", bundle: .previewKit,
                                                 comment: "Trust card evidence: the address a file came from and the app that downloaded it; e.g. “downloaded from example.com/app.pkg with Safari”.") }
                    ?? String(localized: "downloaded from \(from)", bundle: .previewKit, comment: "Trust card evidence: the address a file came from.")
            }
            var answers = [
                Answer(mark: scripts.isEmpty ? .ok : (dangerousScript ? .danger : .caution),
                       question: String(localized: "What else does it do", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                       answer: findings.first ?? runs,
                       evidence: findings.isEmpty ? (scripts.isEmpty ? nil : scripts.joined(separator: ", "))
                           : (findings.count > 1 ? findings.dropFirst().joined(separator: " · ") : nil)),
                Answer(mark: signer != nil ? .ok : (unsigned ? .caution : (brokenSignature ? .danger : (v("signed") != nil ? .caution : .neutral))),
                       question: String(localized: "Where does it come from", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                       answer: signer ?? (unsigned ? Phrase.nobodyUnsigned
                                          : (notVouchedSigner ? Phrase.notVouchedSigner : (v("signed") != nil ? Phrase.notVerified : Phrase.unknown))),
                       evidence: [unsigned ? nil : v("signed"), signer == nil ? claimed.map(Phrase.claims) : nil, downloaded].compactMap { $0 }.isEmpty ? nil
                           : [unsigned ? nil : v("signed"), signer == nil ? claimed.map(Phrase.claims) : nil, downloaded].compactMap { $0 }.joined(separator: " · ")),
            ]
            // What it lays down, and whether it asks for an administrator (trust r3-a's installer answers).
            if let installs = v("componentList") {
                let components = installs.components(separatedBy: "\n").count
                let installed: String
                switch (v("payloadFiles"), components) {
                case let (files?, 1):
                    installed = String(localized: "\(files) files, in 1 component", bundle: .previewKit, comment: "What an installer lays down; e.g. “120 files, in 1 component”.")
                case let (files?, n):
                    let count = n.formatted()
                    installed = String(localized: "\(files) files, in \(count) components", bundle: .previewKit, comment: "What an installer lays down; e.g. “120 files, in 3 components”.")
                case (nil, 1):
                    installed = String(localized: "1 component", bundle: .previewKit, comment: "What an installer lays down: one component.")
                case let (nil, n):
                    let count = n.formatted()
                    installed = String(localized: "\(count) components", bundle: .previewKit, comment: "What an installer lays down; e.g. “3 components”.")
                }
                answers.append(Answer(mark: .neutral,
                                      question: String(localized: "What does it install", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                      answer: installed, evidence: installs.replacingOccurrences(of: "\n", with: "; ")))
            }
            if fact(v("administrator"), is: "Yes", Phrase.yes) {
                answers.append(Answer(mark: .neutral,
                                      question: String(localized: "Does it need an administrator", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                      answer: String(localized: "Yes, it asks for an administrator's password", bundle: .previewKit,
                                                     comment: "Trust card answer: installing needs an administrator.")))
            }
            if let gate = gatekeeper(v, signed: signer != nil || (!unsigned && v("signed") == nil), stapled: false) { answers.append(gate) }
            return BinaryCard(kind: doc.kind, title: id, sentence: sentence, bold: [id, scriptPhrase, signedPhrase].filter { !$0.isEmpty },
                              stageChip: String(localized: "Installer", bundle: .previewKit, comment: "The kind chip on an installer package's card."),
                              strip: strip, rule: top,
                              verdict: verdict(worst, opening: Phrase.checkBeforeInstalling,
                                               danger: String(localized: "Do not install", bundle: .previewKit, comment: "Verdict chip: an installer with a danger finding."),
                                               calmTitle: signer.map(Phrase.signedBy)
                                                   ?? String(localized: "No warnings for this installer", bundle: .previewKit, comment: "Calm verdict title for an installer with no findings."),
                                               calmReason: scripts.isEmpty ? String(localized: "It only copies files; no script runs when it installs.", bundle: .previewKit,
                                                                                    comment: "Calm verdict reason for an installer without scripts.") : ""),
                              answers: answers)
        case .diskImage:
            let format = v("format") ?? String(localized: "disk image", bundle: .previewKit, comment: "A disk image's format when the file does not say.")
            let encrypted = fact(v("encrypted"), is: "Yes", Phrase.yes)
            let signed = fact(v("signed"), is: "Signed", String(localized: "Signed", bundle: .previewKit, comment: "A signature fact's value: the file is signed."))
            let partitions = v("partitions").flatMap(Int.init)
            let subject: String
            switch partitions {
            case 1?:
                subject = String(localized: "A \(format) disk image, with 1 partition", bundle: .previewKit, comment: "Start of a disk image's sentence: its format and one partition; e.g. “A UDZO disk image, with 1 partition”.")
            case let n?:
                let count = n.formatted()
                subject = String(localized: "A \(format) disk image, with \(count) partitions", bundle: .previewKit,
                                 comment: "Start of a disk image's sentence: its format and partitions; e.g. “A UDZO disk image, with 3 partitions”.")
            case nil:
                subject = String(localized: "A \(format) disk image", bundle: .previewKit, comment: "Start of a disk image's sentence: its format; e.g. “A UDZO disk image”.")
            }
            let sentence: String
            switch (encrypted, signed) {
            case (true, true): sentence = String(localized: "\(subject); it is encrypted and signed.", bundle: .previewKit, comment: "A disk image's sentence; the argument is its start.")
            case (true, false): sentence = String(localized: "\(subject); it is encrypted and not signed.", bundle: .previewKit, comment: "A disk image's sentence; the argument is its start.")
            case (false, true): sentence = String(localized: "\(subject); it is not encrypted and signed.", bundle: .previewKit, comment: "A disk image's sentence; the argument is its start.")
            case (false, false): sentence = String(localized: "\(subject); it is not encrypted and not signed.", bundle: .previewKit, comment: "A disk image's sentence; the argument is its start.")
            }
            let encryptionWord = encrypted
                ? String(localized: "encrypted", bundle: .previewKit, comment: "Bold part of a disk image's sentence; must match the words of the sentence.")
                : String(localized: "not encrypted", bundle: .previewKit, comment: "Bold part of a disk image's sentence; must match the words of the sentence.")
            let strip = firstThree([
                Stat(value: format, label: String(localized: "Format", bundle: .previewKit, comment: "Card label: the disk image's format.")),
                Stat(value: encrypted ? Phrase.yes : Phrase.no, label: String(localized: "Encrypted", bundle: .previewKit, comment: "Card label: whether the disk image is encrypted.")),
                partitions.map { Stat(value: $0.formatted(), label: String(localized: "Partitions", bundle: .previewKit, comment: "Card label: how many partitions the disk image has.")) },
                v("size").map { Stat(value: $0, label: String(localized: "Size", bundle: .previewKit, comment: "Card label: the file size.")) },
            ])
            // "Signed", the signer and the ticket come from the Security framework's assessment of the image (G-34,
            // F3, F8, F12): anything short of a whole signature is a finding with the state BinaryFacts wrote.
            let notarization = v("notarization")
            let stapled = notarized(notarization)
            let unsignedImage = v("signed").map { fact($0, is: "Not signed", notSignedWord) } ?? true
            let brokenImage = fact(v("signed"), startsWith: "Broken", PackageFacts.Word.broken)
            var answers = [
                Answer(mark: signed ? .ok : (unsignedImage ? .neutral : (brokenImage ? .danger : .caution)),
                       question: String(localized: "Is it signed", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                       answer: signed ? Phrase.yes : (unsignedImage ? Phrase.no : (v("signed") ?? Phrase.no))),
            ]
            // Who signed it and Apple's ticket, as the trust design's disk image card asks (trust r3-a).
            if let signer = v("signer") {
                answers.append(Answer(mark: .ok, question: Phrase.whoMadeIt, answer: v("team").map { "\(signer) (\($0))" } ?? signer))
            } else if notVouched(v) {
                answers.append(Answer(mark: .caution, question: Phrase.whoMadeIt, answer: Phrase.notVouchedSigner,
                                      evidence: v("claimedSigner").map(Phrase.claims)))
            } else if let claimed = v("claimedSigner") {
                answers.append(Answer(mark: .caution, question: Phrase.whoMadeIt, answer: Phrase.notVerified, evidence: Phrase.claims(claimed)))
            }
            if stapled {
                answers.append(Answer(mark: .ok, question: Phrase.hasAppleCheckedIt,
                                      answer: fact(notarization, startsWith: "Notarized", BinaryFacts.notarizedWord)
                                          ? String(localized: "Yes, notarized", bundle: .previewKit, comment: "Trust card answer to “Has Apple checked it”: notarized.")
                                          : String(localized: "Yes, a notarization ticket is stapled", bundle: .previewKit,
                                                   comment: "Trust card answer to “Has Apple checked it”: Apple's ticket is in the file.")))
            } else if ticketUnverified(notarization) {
                answers.append(Answer(mark: .caution, question: Phrase.hasAppleCheckedIt, answer: Phrase.ticketNotVerified))
            } else if signed {
                answers.append(Answer(mark: .neutral, question: Phrase.hasAppleCheckedIt, answer: Phrase.noTicketStapled))
            }
            answers += [
                Answer(mark: .neutral, question: String(localized: "Is it encrypted", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                       answer: encrypted ? String(localized: "Yes, it asks for a password", bundle: .previewKit, comment: "Trust card answer: the disk image is encrypted.") : Phrase.no),
                // The files inside need the image mounted; a preview never mounts anything.
                Answer(mark: .neutral, question: Phrase.whatIsInside,
                       answer: String(localized: "Not listed: Vitrine never mounts a disk image", bundle: .previewKit, comment: "Trust card answer: a disk image's files are not listed."),
                       evidence: String(localized: "Open it to see its files", bundle: .previewKit, comment: "Trust card evidence line under a disk image's contents answer.")),
                Answer(mark: .neutral, question: String(localized: "What happens when it opens", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                       answer: encrypted
                           ? String(localized: "It asks for the password, then mounts like a drive", bundle: .previewKit, comment: "Trust card answer: an encrypted disk image when opened.")
                           : String(localized: "It mounts like a drive", bundle: .previewKit, comment: "Trust card answer: a disk image when opened.")),
            ]
            if let gate = gatekeeper(v, signed: signed && distributionIdentity(v), stapled: stapled) { answers.append(gate) }
            return BinaryCard(kind: doc.kind, title: fileName, sentence: sentence, bold: [format, encryptionWord],
                              stageChip: String(localized: "Disk image", bundle: .previewKit, comment: "The kind chip on a disk image's card."),
                              strip: strip, rule: top,
                              verdict: verdict(worst, opening: Phrase.checkBeforeOpening,
                                               calmTitle: signed ? String(localized: "Signed disk image", bundle: .previewKit, comment: "Calm verdict title: a signed disk image.")
                                                                 : String(localized: "No warnings for this disk image", bundle: .previewKit, comment: "Calm verdict title for a disk image with no findings."),
                                               calmReason: String(localized: "Opening it only mounts it; check the apps inside before you run them.", bundle: .previewKit,
                                                                  comment: "Calm verdict reason for a disk image.")),
                              answers: answers)
        case .provisioningProfile:
            return provisioningProfile(doc, fileName: fileName, top: top, worst: worst)
        case .torrent:
            return torrent(doc, fileName: fileName, top: top, worst: worst)
        case .configurationProfile:
            return configurationProfile(doc, fileName: fileName, top: top, worst: worst)
        case .keyMaterial:
            return keyMaterial(doc, fileName: fileName, top: top, worst: worst)
        case .reader:
            return reader(doc, fileName: url.lastPathComponent, top: top, worst: worst)
        case .lockfile:
            // A lockfile's name is the whole name: "Cargo.lock", not "Cargo".
            return lockfile(doc, fileName: url.lastPathComponent, top: top, worst: worst)
        case .archive(.ipa):
            return iosApp(doc, fileName: fileName, top: top, worst: worst)
        case .archive(.apk):
            return androidApp(doc, fileName: fileName, top: top, worst: worst)
        default:
            return app(doc, fileName: fileName, top: top, worst: worst)
        }
    }

    // MARK: Provisioning profile

    static func provisioningProfile(_ doc: PreviewDocument, fileName: String, top: Badge.Level?, worst: Badge?) -> BinaryCard {
        let v = { (key: String) in doc.fact(key)?.value }
        let name = v("name") ?? fileName
        let expired = doc.badges.contains { fact($0.title, is: "Expired", PackageFacts.Word.expired) }
        let expiry: String
        if expired {
            expiry = v("expires").map { String(localized: "expired on \($0)", bundle: .previewKit, comment: "Part of a profile's sentence: when it expired; e.g. “expired on 6 Dec 2025”.") }
                ?? String(localized: "has expired", bundle: .previewKit, comment: "Part of a profile's sentence: it has expired.")
        } else if let left = v("expiresIn") {
            expiry = String(localized: "expires in \(left)", bundle: .previewKit, comment: "Part of a profile's sentence: how long it has left; e.g. “expires in 41 days”.")
        } else {
            expiry = v("expires").map { String(localized: "expires on \($0)", bundle: .previewKit, comment: "Part of a profile's sentence: when it expires; e.g. “expires on 6 Dec 2026”.") }
                ?? String(localized: "has no expiry date", bundle: .previewKit, comment: "Part of a profile's sentence: it never expires.")
        }
        let distribution = v("distribution")
        let kindWords = distribution.map {
            String(localized: "\($0) profile", bundle: .previewKit, comment: "Bold part of a profile's sentence, e.g. “development profile”; must match the words of the sentence.")
        }
        let what: String
        if let distribution {
            what = startsWithVowel(distribution)
                ? String(localized: "An \(distribution) profile", bundle: .previewKit, comment: "Start of a profile's sentence: its distribution; e.g. “An ad hoc profile” (English says “An” before a vowel).")
                : String(localized: "A \(distribution) profile", bundle: .previewKit, comment: "Start of a profile's sentence: its distribution; e.g. “A development profile”.")
        } else {
            what = String(localized: "A provisioning profile", bundle: .previewKit, comment: "Start of a profile's sentence when its distribution is not known.")
        }
        let named = (v("appName") ?? v("appID")).map {
            String(localized: "\(what) for \($0)", bundle: .previewKit, comment: "A profile's subject and the app it is for; e.g. “A development profile for Orbit”.")
        } ?? what
        let described: String
        if let devices = v("devices").flatMap(Int.init) {
            let devicesPhrase = PackageFacts.devicesPhrase(devices)
            if let certificates = v("certificates").flatMap(Int.init) {
                let certificatesPhrase: String
                if certificates == 1 {
                    certificatesPhrase = String(localized: "1 certificate", bundle: .previewKit, comment: "A profile that names exactly one signing certificate.")
                } else {
                    let count = certificates.formatted()
                    certificatesPhrase = String(localized: "\(count) certificates", bundle: .previewKit, comment: "How many signing certificates a profile names; e.g. “2 certificates”.")
                }
                described = String(localized: "\(named) that lets \(devicesPhrase) run builds signed by \(certificatesPhrase)", bundle: .previewKit,
                                   comment: "A profile's subject, its devices and certificates; e.g. “A development profile for Orbit that lets 12 devices run builds signed by 2 certificates”.")
            } else {
                described = String(localized: "\(named) that lets \(devicesPhrase) run builds", bundle: .previewKit,
                                   comment: "A profile's subject and its devices; e.g. “A development profile for Orbit that lets 12 devices run builds”.")
            }
        } else {
            described = named
        }
        let sentence = String(localized: "\(described); it \(expiry).", bundle: .previewKit,
                              comment: "A profile's sentence: its start, then when it expires; e.g. “A development profile for Orbit; it expires in 41 days.”")
        let expiresLabel = String(localized: "Expires", bundle: .previewKit, comment: "Card label: when the profile expires.")
        let strip = firstThree([
            expired ? v("expires").map { Stat(value: $0, label: PackageFacts.Word.expired) }
                    : (v("expiresIn").map { left in
                        Stat(value: String(localized: "in \(left)", bundle: .previewKit, comment: "How long until something expires; e.g. “in 41 days”."), label: expiresLabel)
                    } ?? v("expires").map { Stat(value: $0, label: expiresLabel) }),
            v("devices").map { Stat(value: $0, label: String(localized: "Devices", bundle: .previewKit, comment: "Card label: how many devices the profile names.")) },
            v("platforms").map { Stat(value: $0, label: String(localized: "Platforms", bundle: .previewKit, comment: "Card label: the platforms the profile is for.")) },
            v("created").map { Stat(value: $0, label: String(localized: "Created", bundle: .previewKit, comment: "Card label: when the profile was made.")) },
        ])
        var answers = [
            Answer(mark: expired ? .caution : .ok, question: Phrase.isItStillValid,
                   answer: expired ? String(localized: "No, \(expiry)", bundle: .previewKit, comment: "Trust card answer: the profile is not valid; e.g. “No, expired on 6 Dec 2025”.")
                                   : (v("expiresIn").map(moreDays)
                                      ?? String(localized: "Yes, it \(expiry)", bundle: .previewKit, comment: "Trust card answer: the profile is valid; e.g. “Yes, it expires on 6 Dec 2026”.")),
                   evidence: v("expires").map { String(localized: "profile expires \($0)", bundle: .previewKit, comment: "Trust card evidence line: the profile's expiry date.") }),
            v("team").map { Answer(mark: .ok, question: Phrase.whoMadeIt, answer: $0) }
                ?? v("claimedTeam").map { Answer(mark: .caution, question: Phrase.whoMadeIt, answer: Phrase.notVerified, evidence: Phrase.claims($0)) }
                ?? Answer(mark: .neutral, question: Phrase.whoMadeIt, answer: Phrase.unknown),
        ]
        if let distribution {
            answers.append(Answer(mark: .neutral, question: Phrase.howIsItDistributed, answer: Phrase.distributed(distribution, devices: v("devices"))))
        }
        return BinaryCard(kind: doc.kind, title: name, sentence: sentence, bold: [kindWords, expiry].compactMap { $0 },
                          stageChip: String(localized: "Profile", bundle: .previewKit, comment: "The kind chip on a provisioning profile's card."),
                          strip: strip, rule: top,
                          verdict: verdict(worst, opening: Phrase.checkBeforeInstalling,
                                           calmTitle: String(localized: "This profile is valid", bundle: .previewKit, comment: "Calm verdict title for a provisioning profile."),
                                           calmReason: String(localized: "It \(expiry).", bundle: .previewKit, comment: "Calm verdict reason: when the profile expires; e.g. “It expires in 41 days.”")),
                          answers: answers)
    }

    // MARK: App

    static func app(_ doc: PreviewDocument, fileName: String, top: Badge.Level?, worst: Badge?) -> BinaryCard {
        let v = { (key: String) in doc.fact(key)?.value }
        let name = v("name") ?? fileName
        let version = v("version").map { String($0.split(separator: " ").first ?? "") }
        let arch = archWords(v("architectures"))
        let signature = v("signature") ?? Phrase.unknown
        let signer = v("signer")
        let valid = fact(signature, startsWith: "Valid", String(localized: "Valid", bundle: .previewKit, comment: "A code signature's state: valid."))
        let broken = fact(signature, startsWith: "Broken", PackageFacts.Word.broken)
        let adHoc = fact(signature, startsWith: "Ad-hoc", String(localized: "Ad-hoc", bundle: .previewKit, comment: "A code signature's state: signed ad hoc, with no identity."))
        let notSigned = fact(signature, is: "Not signed", PackageFacts.Word.notSigned)
        // The quick check finished but the full one did not (G-34): the signer is known, "valid" is not said.
        let partly = fact(signature, startsWith: "Partly checked", BinaryFacts.partlyCheckedWord)
        let notChecked = fact(signature, startsWith: "Not checked", BinaryFacts.notCheckedWord)
        let notVouchedSigner = notVouched(v)
        let claimed = v("claimedSigner")
        let signedPhrase: String
        if valid || partly {
            if let signer {
                signedPhrase = String(localized: "signed by \(signer)", bundle: .previewKit, comment: "Part of an app's sentence: who signed it; e.g. “signed by Developer ID Application: Example Co”.")
            } else if notVouchedSigner {
                signedPhrase = String(localized: "signed by a certificate Apple does not vouch for", bundle: .previewKit,
                                      comment: "Part of an app's sentence: its signing certificate does not chain to Apple.")
            } else {
                signedPhrase = String(localized: "signed", bundle: .previewKit, comment: "Part of an app's sentence: it is signed.")
            }
        } else if notChecked {
            signedPhrase = String(localized: "its signature was not checked in time", bundle: .previewKit,
                                  comment: "Part of an app's sentence: the signature check did not finish in time for the preview.")
        } else if adHoc {
            signedPhrase = String(localized: "signed ad-hoc, with no developer identity", bundle: .previewKit, comment: "Part of an app's sentence: an ad hoc signature.")
        } else if broken {
            signedPhrase = String(localized: "its signature is broken", bundle: .previewKit, comment: "Part of an app's sentence: the signature does not match.")
        } else {
            signedPhrase = String(localized: "not signed", bundle: .previewKit, comment: "Part of an app's sentence: it has no signature.")
        }
        let subject = version.map { String(localized: "Version \($0)", bundle: .previewKit, comment: "Start of an app's sentence: its version; e.g. “Version 2.4.0”.") }
            ?? String(localized: "An app", bundle: .previewKit, comment: "Start of an app's sentence when it has no version.")
        let sentence: String
        switch (arch, v("minimumSystem")) {
        case let (arch?, system?):
            sentence = String(localized: "\(subject) for \(arch), \(signedPhrase); it needs macOS \(system) or later.", bundle: .previewKit,
                              comment: "An app's sentence: version, architectures, signature and minimum macOS; e.g. “Version 2.4.0 for Apple silicon and Intel, signed by Example Co; it needs macOS 14.0 or later.”")
        case let (arch?, nil):
            sentence = String(localized: "\(subject) for \(arch), \(signedPhrase).", bundle: .previewKit,
                              comment: "An app's sentence: version, architectures and signature.")
        case let (nil, system?):
            sentence = String(localized: "\(subject), \(signedPhrase); it needs macOS \(system) or later.", bundle: .previewKit,
                              comment: "An app's sentence: version, signature and minimum macOS; e.g. “Version 2.4.0, not signed; it needs macOS 14.0 or later.”")
        case (nil, nil):
            sentence = String(localized: "\(subject), \(signedPhrase).", bundle: .previewKit, comment: "An app's sentence: version and signature.")
        }
        let strip = firstThree([
            version.map { Stat(value: $0, label: String(localized: "Version", bundle: .previewKit, comment: "Card label: the version.")) },
            arch.map { Stat(value: $0, label: String(localized: "Runs on", bundle: .previewKit, comment: "Card label: the Macs the app runs on (Apple silicon, Intel).")) },
            v("minimumSystem").map { Stat(value: "macOS \($0)", label: String(localized: "Requires", bundle: .previewKit, comment: "Card label: the oldest macOS the app runs on.")) },
            v("size").map { Stat(value: $0, label: String(localized: "Size", bundle: .previewKit, comment: "Card label: the file size.")) },
        ])
        let notarization = v("notarization")
        // "Notarized" only when macOS verified Apple's ticket (G-34, F2, F9); a ticket-shaped file is a finding.
        let stapled = notarized(notarization)
        // A broken signature is the danger finding; no signature (or no identity) is the caution one.
        let signatureMark: Answer.Mark = valid ? .ok : (broken ? .danger : .caution)
        let whoMade: String
        let whoMark: Answer.Mark
        var whoEvidence: String?
        if let signer, valid || partly { whoMade = v("team").map { "\(signer) (\($0))" } ?? signer; whoMark = .ok }
        else if notVouchedSigner { whoMade = Phrase.notVouchedSigner; whoMark = .caution; whoEvidence = claimed.map(Phrase.claims) }
        else if notSigned { whoMade = Phrase.nobodyUnsigned; whoMark = signatureMark }
        else {
            whoMade = String(localized: "Unknown, \(signedPhrase)", bundle: .previewKit, comment: "Trust card answer to “Who made it”; e.g. “Unknown, signed ad-hoc, with no developer identity”.")
            whoMark = signatureMark
            whoEvidence = claimed.map(Phrase.claims)
        }
        let checked: Answer
        if stapled {
            checked = Answer(mark: .ok, question: Phrase.hasAppleCheckedIt,
                             answer: String(localized: "Yes, notarized", bundle: .previewKit, comment: "Trust card answer to “Has Apple checked it”: notarized."))
        } else if ticketUnverified(notarization) {
            checked = Answer(mark: .caution, question: Phrase.hasAppleCheckedIt, answer: Phrase.ticketNotVerified)
        } else {
            checked = Answer(mark: .neutral, question: Phrase.hasAppleCheckedIt,
                             answer: notarization.map { _ in Phrase.noTicketStapled }
                                ?? String(localized: "No ticket found", bundle: .previewKit, comment: "Trust card answer to “Has Apple checked it”: no ticket at all."))
        }
        var answers = [
            Answer(mark: whoMark, question: Phrase.whoMadeIt, answer: whoMade, evidence: whoEvidence),
            Answer(mark: signatureMark, question: String(localized: "Is the signature intact", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                   answer: signature),
            checked,
        ]
        if let s = v("sandboxed") {
            let sandboxed = fact(s, is: "Yes", Phrase.yes)
            answers.append(Answer(mark: sandboxed ? .ok : .neutral,
                                  question: String(localized: "Is it sandboxed", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                  answer: sandboxed ? String(localized: "Yes, it runs in the App Sandbox", bundle: .previewKit, comment: "Trust card answer: the app is sandboxed.") : Phrase.no))
            // What it may reach (T-1): a sandboxed app names it; an app outside the sandbox can reach what its user can.
            let reach = sandboxed
                ? v("uses").map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    ?? String(localized: "Only its own files", bundle: .previewKit, comment: "Trust card answer: a sandboxed app that asks for nothing more.")
                : String(localized: "What your account can: it is not sandboxed", bundle: .previewKit, comment: "Trust card answer to “What can it do” for an app outside the App Sandbox.")
            answers.append(Answer(mark: .neutral, question: Phrase.whatCanItDo, answer: reach,
                                  evidence: v("loosened").map { String(localized: "turns off: \($0)", bundle: .previewKit,
                                                                       comment: "Trust card evidence: hardened-runtime protections the app turns off; e.g. “turns off: loads code signed by others”.") }))
        }
        if let gate = gatekeeper(v, signed: (valid || partly) && distributionIdentity(v), stapled: stapled) { answers.append(gate) }
        if let s = v("embedded") { answers.append(Answer(mark: .neutral, question: Phrase.whatIsInside, answer: s)) }
        let calmTitle: String
        if let signer {
            calmTitle = stapled
                ? String(localized: "Signed by \(signer) and notarized by Apple", bundle: .previewKit,
                         comment: "Calm verdict title: who signed the app, and Apple notarized it; e.g. “Signed by Developer ID Application: Example Co and notarized by Apple”.")
                : Phrase.signedBy(signer)
        } else {
            calmTitle = String(localized: "The signature checks out", bundle: .previewKit, comment: "Calm verdict title: the app's signature is valid.")
        }
        let calmReason = stapled
            ? String(localized: "Gatekeeper will open it without a warning.", bundle: .previewKit, comment: "Calm verdict reason: a notarized app (Gatekeeper is macOS's check).")
            : String(localized: "The signature is valid; macOS may still check it online the first time.", bundle: .previewKit, comment: "Calm verdict reason: a signed app without a ticket.")
        return BinaryCard(kind: doc.kind, title: name, sentence: sentence, bold: [version, arch, signedPhrase].compactMap { $0 },
                          stageChip: String(localized: "Application", bundle: .previewKit, comment: "The kind chip on an app's card."),
                          strip: strip, rule: top,
                          verdict: verdict(worst, opening: Phrase.checkBeforeOpening, calmTitle: calmTitle, calmReason: calmReason), answers: answers)
    }

    // MARK: Pieces

    /// "9 days" → "Yes, for 9 more days" (trust r3-a state 7).
    static func moreDays(_ left: String) -> String {
        let parts = left.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else {
            return String(localized: "Yes, for \(left)", bundle: .previewKit, comment: "Trust card answer: valid for how long; e.g. “Yes, for 9 days”.")
        }
        let number = String(parts[0]), unit = String(parts[1])
        return String(localized: "Yes, for \(number) more \(unit)", bundle: .previewKit,
                      comment: "Trust card answer: still valid; the arguments are a number and its unit, e.g. “Yes, for 9 more days”.")
    }

    /// English says "an" before a vowel sound; used only to choose between the "A …" and "An …" phrases.
    static func startsWithVowel(_ word: String) -> Bool {
        guard let c = word.lowercased().first else { return false }
        return "aeiou".contains(c)
    }

    static func firstThree(_ stats: [Stat?]) -> [Stat] { Array(stats.compactMap { $0 }.prefix(3)) }

    /// The verdict's words: the worst badge's own title and detail for caution and danger, with the trust design's
    /// chips ("Do not open", "Check before opening" / "Check before installing", "Checks passed").
    static func verdict(_ worst: Badge?, opening: String, danger: String? = nil, calmTitle: String, calmReason: String) -> Verdict {
        switch worst?.level {
        case .danger?:
            return Verdict(level: .danger, title: worst!.title, reason: worst!.detail,
                           chip: danger ?? String(localized: "Do not open", bundle: .previewKit, comment: "Verdict chip: a danger finding."))
        case .caution?: return Verdict(level: .caution, title: worst!.title, reason: worst!.detail, chip: opening)
        default:
            return Verdict(level: .calm, title: calmTitle, reason: calmReason,
                           chip: String(localized: "Checks passed", bundle: .previewKit, comment: "Verdict chip: nothing to worry about."))
        }
    }

    /// "Will macOS open it" (T-1, G-24): Gatekeeper's first-open check, predicted from what the file carries, offline.
    /// Only for a file macOS marked as downloaded (Gatekeeper never checks the rest). A ticket macOS verified opens
    /// without a warning (`stapled` is true only then, G-34); a Developer ID signature without one depends on Apple's
    /// records, which macOS looks up online at first open; no signature, or one from a certificate that is not a
    /// distribution identity (`signed` false), is blocked until allowed in System Settings.
    static func gatekeeper(_ v: (String) -> String?, signed: Bool, stapled: Bool) -> Answer? {
        guard v("quarantined") != nil else { return nil }
        let question = String(localized: "Will macOS open it", bundle: .previewKit, comment: "Trust card question about Gatekeeper's first-open check (written without its question mark).")
        if stapled && signed {
            return Answer(mark: .ok, question: question,
                          answer: String(localized: "Yes, without a warning: Apple's ticket is stapled", bundle: .previewKit, comment: "Trust card answer: Gatekeeper opens a notarized, stapled download."))
        }
        if signed {
            return Answer(mark: .neutral, question: question,
                          answer: String(localized: "If Apple notarized it: macOS checks online the first time", bundle: .previewKit,
                                         comment: "Trust card answer: a signed download without a stapled ticket; Gatekeeper looks the ticket up online."))
        }
        return Answer(mark: .caution, question: question,
                      answer: String(localized: "No, macOS blocks it until you allow it in System Settings", bundle: .previewKit,
                                     comment: "Trust card answer: Gatekeeper blocks an unsigned download at first open."))
    }

    /// "arm64, x86_64" → "Apple silicon and Intel".
    static func archWords(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let a = Set(raw.components(separatedBy: ", "))
        let arm = a.contains { $0.hasPrefix("arm64") }, intel = a.contains { $0.hasPrefix("x86_64") || $0 == "i386" }
        if arm && intel { return String(localized: "Apple silicon and Intel", bundle: .previewKit, comment: "The Macs an app runs on: both kinds of processor.") }
        if arm { return "Apple silicon" }
        if intel { return "Intel" }
        return raw
    }
}
