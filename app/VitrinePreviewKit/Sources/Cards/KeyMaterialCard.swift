import Foundation
import VitrineBinary
import VitrineDocument
import VitrineEngineering
import VitrineSupport

/// Certificates and keys on the card (T-10, cards r3-a): who a certificate is for, who vouches for it, until when, the
/// chain's order and fingerprints; SSH keys by type, size, fingerprint and comment; `authorized_keys` and
/// `known_hosts` as lists. A private key is described by its kind and protection only: its contents are never read
/// into a view. Nothing is checked online (trust and revocation are the system's). roadmap: S-22
extension PackageFacts {
    static func keyMaterial(url: URL, kind: FileKind) throws -> (PreviewDocument, Extras) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: KeyMaterial.maxBytes) ?? Data()
        var b = Builder()
        guard let m = KeyMaterial.read(data: data, fileName: url.lastPathComponent) else {
            b.add("form", Key.form, Key.unreadable)
            return (b.document(kind: kind), Extras())
        }
        b.add("container", "container", m.container.rawValue)
        let certs = m.certificates
        if let leaf = certs.first {
            b.add("subject", Key.subject, leaf.commonName ?? leaf.summary)
            b.add("organization", Key.organization, leaf.organization)
            let selfSigned = leaf.issuerCommonName != nil && leaf.issuerCommonName == leaf.commonName
            b.add("issuer", Key.issuer, selfSigned ? Key.selfSigned : leaf.issuerCommonName)
            if let end = leaf.notValidAfter {
                b.add("validUntil", Key.validUntil, end.formatted(date: .abbreviated, time: .omitted))
                let days = Int((end.timeIntervalSinceNow / 86_400).rounded(.down))
                b.add("daysLeft", "daysLeft", String(days))
                if days < 0 {
                    b.badges.append(Badge(level: .caution, title: String(localized: "Expired on \(end.formatted(date: .abbreviated, time: .omitted))", bundle: .previewKit,
                                                                          comment: "Warning title: a certificate's end date has passed; the argument is the date."),
                                          detail: String(localized: "Software that checks certificates will refuse it.", bundle: .previewKit, comment: "Warning detail for an expired certificate.")))
                } else if days <= 30 {
                    b.badges.append(Badge(level: .caution, title: String(localized: "Expires in \(days) days", bundle: .previewKit, comment: "Warning title: a certificate ends within a month."),
                                          detail: String(localized: "Renew it before then.", bundle: .previewKit, comment: "Warning detail for a certificate that ends soon.")))
                }
            }
            if case .certificate(_, let key?) = m.items.first(where: { if case .certificate = $0 { true } else { false } }) {
                b.add("key", Key.key, [key.algorithm, key.bits.map { "\($0)-bit" }].compactMap { $0 }.joined(separator: " "))
            }
            b.add("certificates", Key.certificates, certs.count.formatted())
            b.add("chain", Key.chain, certs.map { $0.commonName ?? $0.summary }.joined(separator: " → "))
            if !m.chainIsOrdered {
                b.badges.append(Badge(level: .caution, title: String(localized: "The chain is out of order", bundle: .previewKit, comment: "Warning title: certificates in a bundle are not leaf first."),
                                      detail: String(localized: "Servers send the certificates as listed; some clients reject a chain that does not run leaf first.", bundle: .previewKit,
                                                     comment: "Warning detail for a certificate chain out of order.")))
            }
            b.add("fingerprint", Key.fingerprint, grouped(leaf.sha256Fingerprint))
            b.add("serial", Key.serial, leaf.serialNumber)
        }
        for item in m.items {
            switch item {
            case .privateKey(let p):
                b.add("privateFormat", Key.privateKey, [p.format, p.algorithm].compactMap { $0 }.joined(separator: " · "))
                b.add("passphrase", Key.passphrase, p.encrypted ? Word.yes : Word.no)
                b.add("publicFingerprint", Key.publicFingerprint, p.publicFingerprint)
                b.badges.append(p.encrypted
                    ? Badge(level: .info, title: String(localized: "Holds a private key", bundle: .previewKit, comment: "Note title: the file contains a private key."),
                            detail: String(localized: "It is protected by a passphrase; Vitrine never shows its contents.", bundle: .previewKit, comment: "Note detail for an encrypted private key."))
                    : Badge(level: .caution, title: String(localized: "A private key with no passphrase", bundle: .previewKit, comment: "Warning title: an unencrypted private key."),
                            detail: String(localized: "Anyone with a copy of this file can use the key; Vitrine never shows its contents.", bundle: .previewKit,
                                           comment: "Warning detail for an unencrypted private key.")))
            case .sshPublicKey(let k) where m.container == .sshPublicKey:
                b.add("sshType", Key.type, k.type)
                b.add("bits", Key.bits, k.bits.map { $0.formatted() })
                b.add("sshFingerprint", Key.fingerprint, k.fingerprint)
                b.add("comment", Key.comment, k.comment)
            case .publicKey(let k):
                b.add("publicKey", Key.key, [k.algorithm, k.bits.map { "\($0)-bit" }].compactMap { $0 }.joined(separator: " "))
            case .signingRequest:
                b.add("request", Key.form, Key.signingRequest)
            default: break
            }
        }
        if m.container == .authorizedKeys || m.container == .knownHosts {
            let keys = m.items.compactMap { if case .sshPublicKey(let k) = $0 { k } else { nil } }
            b.add("keyCount", Key.keys, keys.count.formatted())
            b.add("types", Key.type, Dictionary(grouping: keys, by: \.type).sorted { $0.value.count > $1.value.count }
                .map { "\($0.key) ×\($0.value.count)" }.joined(separator: ", "))
            b.add("withOptions", Key.withOptions, m.container == .authorizedKeys ? keys.filter { $0.options != nil }.count.formatted() : nil)
            b.add("hashed", Key.hashed, m.container == .knownHosts ? keys.filter(\.hashedHost).count.formatted() : nil)
            b.add("comments", Key.comment, keys.compactMap { m.container == .knownHosts ? ($0.hashedHost ? nil : $0.options) : $0.comment }
                .prefix(12).joined(separator: ", "))
            b.add("options", Key.restrictions, keys.compactMap(\.options).prefix(6).joined(separator: "; "))
        }
        if m.unreadable > 0 { b.add("unreadable", Key.unreadableCount, m.unreadable.formatted()) }
        b.headline(headline(m))
        return (b.document(kind: kind), Extras())
    }

    /// The pill's summary: what the file is, in a few words.
    static func headline(_ m: KeyMaterial) -> String {
        let certs = m.certificates
        if let leaf = certs.first, let end = leaf.notValidAfter {
            let days = Int((end.timeIntervalSinceNow / 86_400).rounded(.down))
            if days < 0 { return String(localized: "Expired", bundle: .previewKit, comment: "Pill summary: a certificate that has expired.") }
            return certs.count == 1
                ? String(localized: "Valid \(days) more days", bundle: .previewKit, comment: "Pill summary: days left on a certificate; e.g. “Valid 19 more days”.")
                : String(localized: "\(certs.count) certificates · \(days) days left", bundle: .previewKit, comment: "Pill summary: a chain and the days left on its first certificate.")
        }
        for item in m.items {
            switch item {
            case .privateKey(let p):
                return p.encrypted ? String(localized: "Private key · passphrase", bundle: .previewKit, comment: "Pill summary: an encrypted private key.")
                                   : String(localized: "Private key · no passphrase", bundle: .previewKit, comment: "Pill summary: an unencrypted private key.")
            case .sshPublicKey(let k) where m.container == .sshPublicKey: return k.type
            case .signingRequest: return String(localized: "Signing request", bundle: .previewKit, comment: "Pill summary: a certificate signing request.")
            case .publicKey(let k): return k.algorithm
            default: continue
            }
        }
        let keys = m.items.count
        return String(localized: "\(keys) keys", bundle: .previewKit, comment: "Pill summary: how many SSH keys a list holds.")
    }

    /// `AB12CD…` → `AB 12 CD …`, as Keychain Access shows a fingerprint.
    static func grouped(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 2).map { i in
            let a = hex.index(hex.startIndex, offsetBy: i), b = hex.index(a, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            return String(hex[a..<b]).uppercased()
        }.joined(separator: " ")
    }

    enum Key {
        static var form: String { String(localized: "Contains", bundle: .previewKit, comment: "Fact label: what a certificate or key file holds.") }
        static var unreadable: String { String(localized: "Nothing Vitrine can read", bundle: .previewKit, comment: "Fact value: the file is not a certificate or key Vitrine knows.") }
        static var subject: String { String(localized: "Issued to", bundle: .previewKit, comment: "Fact label: who a certificate is for.") }
        static var organization: String { String(localized: "Organization", bundle: .previewKit, comment: "Fact label: the organization named in a certificate.") }
        static var issuer: String { String(localized: "Issued by", bundle: .previewKit, comment: "Fact label: who issued a certificate.") }
        static var selfSigned: String { String(localized: "Itself (self-signed)", bundle: .previewKit, comment: "Fact value: a certificate signed by its own key.") }
        static var validUntil: String { String(localized: "Valid until", bundle: .previewKit, comment: "Fact label: a certificate's end date.") }
        static var key: String { String(localized: "Key", bundle: .previewKit, comment: "Fact label: a key's algorithm and size.") }
        static var certificates: String { String(localized: "Certificates", bundle: .previewKit, comment: "Fact label: how many certificates the file holds.") }
        static var chain: String { String(localized: "Chain", bundle: .previewKit, comment: "Fact label: the certificates in order, leaf first.") }
        static var fingerprint: String { String(localized: "Fingerprint", bundle: .previewKit, comment: "Fact label: a certificate's or key's fingerprint.") }
        static var serial: String { String(localized: "Serial number", bundle: .previewKit, comment: "Fact label: a certificate's serial number.") }
        static var privateKey: String { String(localized: "Private key", bundle: .previewKit, comment: "Fact label: a private key's format and algorithm.") }
        static var passphrase: String { String(localized: "Passphrase", bundle: .previewKit, comment: "Fact label: whether a private key is protected by a passphrase.") }
        static var publicFingerprint: String { String(localized: "Public key fingerprint", bundle: .previewKit, comment: "Fact label: the fingerprint of a private key's public half.") }
        static var type: String { String(localized: "Type", bundle: .previewKit, comment: "Fact label: an SSH key's type.") }
        static var bits: String { String(localized: "Bits", bundle: .previewKit, comment: "Fact label: a key's size in bits.") }
        static var comment: String { String(localized: "Comment", bundle: .previewKit, comment: "Fact label: an SSH key's comment (often user@host).") }
        static var signingRequest: String { String(localized: "A certificate signing request", bundle: .previewKit, comment: "Fact value: the file asks a certificate authority for a certificate.") }
        static var keys: String { String(localized: "Keys", bundle: .previewKit, comment: "Fact label: how many keys a list holds.") }
        static var withOptions: String { String(localized: "With restrictions", bundle: .previewKit, comment: "Fact label: how many authorized keys carry options such as command= or from=.") }
        static var hashed: String { String(localized: "Hashed host names", bundle: .previewKit, comment: "Fact label: how many known_hosts lines hide their host name.") }
        static var restrictions: String { String(localized: "Restrictions", bundle: .previewKit, comment: "Fact label: the options of authorized keys.") }
        static var unreadableCount: String { String(localized: "Unreadable entries", bundle: .previewKit, comment: "Fact label: how many blocks or lines could not be read.") }
    }
}

extension BinaryCard {
    static func keyMaterial(_ doc: PreviewDocument, fileName: String, top: Badge.Level?, worst: Badge?) -> BinaryCard {
        let v = { (key: String) in doc.fact(key)?.value }
        let opening = String(localized: "Check before trusting", bundle: .previewKit, comment: "Verdict chip: a caution about a certificate or key.")
        let chip = String(localized: "Certificate", bundle: .previewKit, comment: "The kind chip on a certificate or key card.")
        let local = String(localized: "Read on this Mac; whether it is trusted or revoked is the system's to check.", bundle: .previewKit,
                           comment: "Calm verdict reason on a certificate card.")
        var answers: [Answer] = []

        // A certificate or a chain.
        if let subject = v("subject") {
            let count = Int(v("certificates") ?? "1") ?? 1
            let issuer = v("issuer") ?? Phrase.unknown
            let until = v("validUntil")
            let days = v("daysLeft").flatMap(Int.init)
            let selfSigned = issuer == PackageFacts.Key.selfSigned
            let sentence: String
            switch (count, selfSigned, until) {
            case (1, true, let u?): sentence = String(localized: "A self-signed certificate for \(subject), valid until \(u).", bundle: .previewKit, comment: "A certificate's sentence; e.g. “A self-signed certificate for example.com, valid until 1 Dec 2026.”")
            case (1, false, let u?): sentence = String(localized: "A certificate for \(subject), issued by \(issuer), valid until \(u).", bundle: .previewKit, comment: "A certificate's sentence: subject, issuer, end date.")
            case (_, _, let u?):
                let n = count.formatted()
                sentence = String(localized: "A chain of \(n) certificates for \(subject), issued by \(issuer), valid until \(u).", bundle: .previewKit, comment: "A certificate chain's sentence; e.g. “A chain of 3 certificates for example.com, issued by Example CA, valid until 1 Dec 2026.”")
            default: sentence = String(localized: "A certificate for \(subject), issued by \(issuer).", bundle: .previewKit, comment: "A certificate's sentence without an end date.")
            }
            answers.append(Answer(mark: .neutral, question: String(localized: "Who is it for", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                  answer: subject, evidence: v("organization")))
            answers.append(Answer(mark: selfSigned ? .neutral : .ok, question: String(localized: "Who vouches for it", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                  answer: selfSigned ? String(localized: "Nobody else: it is self-signed", bundle: .previewKit, comment: "Trust card answer for a self-signed certificate.") : issuer))
            if let until, let days {
                answers.append(Answer(mark: days < 0 ? .caution : (days <= 30 ? .caution : .ok), question: Phrase.isItStillValid,
                                      answer: days < 0 ? String(localized: "No, it expired on \(until)", bundle: .previewKit, comment: "Trust card answer: an expired certificate; the argument is the date.")
                                                       : String(localized: "Yes, until \(until)", bundle: .previewKit, comment: "Trust card answer: a valid certificate's end date.")))
            }
            if count > 1, let chain = v("chain") {
                let ordered = !doc.badges.contains { $0.title == String(localized: "The chain is out of order", bundle: .previewKit, comment: "Warning title: certificates in a bundle are not leaf first.") }
                answers.append(Answer(mark: ordered ? .ok : .caution, question: String(localized: "What is in the chain", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                      answer: ordered ? String(localized: "Leaf first, then each issuer", bundle: .previewKit, comment: "Trust card answer: a chain in the right order.")
                                                      : String(localized: "Out of order", bundle: .previewKit, comment: "Trust card answer: a chain not leaf first."), evidence: chain))
            }
            if v("privateFormat") != nil {
                answers.append(Answer(mark: v("passphrase") == PackageFacts.Word.yes ? .neutral : .caution,
                                      question: String(localized: "Does it hold a private key", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                      answer: v("passphrase") == PackageFacts.Word.yes ? String(localized: "Yes, protected by a passphrase", bundle: .previewKit, comment: "Trust card answer: an encrypted private key is in the file.")
                                                                                       : String(localized: "Yes, with no passphrase", bundle: .previewKit, comment: "Trust card answer: an unencrypted private key is in the file.")))
            }
            let strip = firstThree([
                until.map { Stat(value: $0, label: String(localized: "Valid until", bundle: .previewKit, comment: "Card label: a certificate's end date.")) },
                v("key").map { Stat(value: $0, label: String(localized: "Key", bundle: .previewKit, comment: "Card label: a key's algorithm and size.")) },
                Stat(value: count.formatted(), label: String(localized: "Certificates", bundle: .previewKit, comment: "Card label: how many certificates.")),
            ])
            let fingerprintAnswer = v("fingerprint").map { Answer(mark: .neutral, question: String(localized: "What is its fingerprint", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                                                  answer: "SHA-256", evidence: $0) }
            if let fingerprintAnswer { answers.append(fingerprintAnswer) }
            return BinaryCard(kind: doc.kind, title: subject, sentence: sentence, bold: [subject, issuer, until].compactMap { $0 },
                              stageChip: chip, strip: strip, rule: top,
                              verdict: verdict(worst, opening: opening,
                                               calmTitle: until.map { String(localized: "Valid until \($0)", bundle: .previewKit, comment: "Calm verdict title on a certificate card; the argument is the end date.") }
                                                   ?? String(localized: "No warnings for this certificate", bundle: .previewKit, comment: "Calm verdict title for a certificate."),
                                               calmReason: local),
                              answers: answers)
        }

        // A private key alone.
        if let format = v("privateFormat") {
            let protected = v("passphrase") == PackageFacts.Word.yes
            let sentence = protected
                ? String(localized: "A private key (\(format)), protected by a passphrase; Vitrine never shows its contents.", bundle: .previewKit, comment: "A private key's sentence; the argument is its format, e.g. “OpenSSH · ssh-ed25519”.")
                : String(localized: "A private key (\(format)) with no passphrase; Vitrine never shows its contents.", bundle: .previewKit, comment: "An unencrypted private key's sentence; the argument is its format.")
            answers.append(Answer(mark: protected ? .ok : .caution, question: String(localized: "Is it protected", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                  answer: protected ? String(localized: "Yes, by a passphrase", bundle: .previewKit, comment: "Trust card answer: an encrypted private key.")
                                                    : String(localized: "No: anyone with this file can use it", bundle: .previewKit, comment: "Trust card answer: an unencrypted private key.")))
            if let fp = v("publicFingerprint") {
                answers.append(Answer(mark: .neutral, question: String(localized: "Which key is it", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                      answer: fp, evidence: String(localized: "the fingerprint of its public half, as ssh-keygen -l shows it", bundle: .previewKit, comment: "Trust card evidence for a private key's public fingerprint.")))
            }
            return BinaryCard(kind: doc.kind, title: fileName, sentence: sentence, bold: [format],
                              stageChip: String(localized: "Private key", bundle: .previewKit, comment: "The kind chip on a private key's card."),
                              strip: firstThree([Stat(value: format, label: PackageFacts.Key.privateKey), Stat(value: v("passphrase") ?? "?", label: PackageFacts.Key.passphrase)]),
                              rule: top,
                              verdict: verdict(worst, opening: String(localized: "Keep it private", bundle: .previewKit, comment: "Verdict chip on an unprotected private key."),
                                               calmTitle: String(localized: "A private key, protected by a passphrase", bundle: .previewKit, comment: "Calm verdict title for an encrypted private key."),
                                               calmReason: String(localized: "Vitrine never shows its contents.", bundle: .previewKit, comment: "Calm verdict reason for a private key.")),
                              answers: answers)
        }

        // One SSH public key.
        if let type = v("sshType") {
            let comment = v("comment")
            let size = v("bits").map { String(localized: "\($0)-bit", bundle: .previewKit, comment: "A key's size; e.g. “256-bit”.") }
            let described = [type, size].compactMap { $0 }.joined(separator: ", ")
            let sentence = comment.map { String(localized: "An SSH public key (\(described)) for \($0); sharing it is safe.", bundle: .previewKit, comment: "An SSH public key's sentence; e.g. “An SSH public key (ssh-ed25519, 256-bit) for dev@example.com; sharing it is safe.”") }
                ?? String(localized: "An SSH public key (\(described)); sharing it is safe.", bundle: .previewKit, comment: "An SSH public key's sentence without a comment.")
            answers.append(Answer(mark: .neutral, question: String(localized: "Which key is it", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                  answer: v("sshFingerprint") ?? Phrase.unknown, evidence: comment))
            return BinaryCard(kind: doc.kind, title: comment ?? fileName, sentence: sentence, bold: [described],
                              stageChip: String(localized: "SSH key", bundle: .previewKit, comment: "The kind chip on an SSH public key's card."),
                              strip: firstThree([Stat(value: type, label: PackageFacts.Key.type), size.map { Stat(value: $0, label: PackageFacts.Key.bits) }]),
                              rule: top,
                              verdict: verdict(worst, opening: opening, calmTitle: String(localized: "A public key", bundle: .previewKit, comment: "Calm verdict title for an SSH public key."),
                                               calmReason: String(localized: "It lets a server recognise the matching private key; it is safe to share.", bundle: .previewKit, comment: "Calm verdict reason for an SSH public key.")),
                              answers: answers)
        }

        // A list of SSH keys.
        if let keyText = v("keyCount"), let keys = Int(keyText.filter(\.isNumber)) {
            let known = v("container") == "knownHosts"
            let sentence = known
                ? String(localized: "A list of \(keys) server keys this Mac has seen; SSH checks a server against it before connecting.", bundle: .previewKit, comment: "known_hosts sentence; the argument is how many keys.")
                : String(localized: "A list of \(keys) SSH keys allowed to log in to this account.", bundle: .previewKit, comment: "authorized_keys sentence; the argument is how many keys.")
            answers.append(Answer(mark: .neutral, question: known ? String(localized: "Which servers", bundle: .previewKit, comment: "Trust card question (written without its question mark).")
                                                                  : String(localized: "Who can log in", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                  answer: v("comments").map { $0.isEmpty ? Phrase.unknown : $0 } ?? (known ? String(localized: "Host names are hashed", bundle: .previewKit, comment: "Trust card answer: known_hosts names are hidden.") : Phrase.unknown),
                                  evidence: v("types")))
            if !known, let restricted = v("withOptions").flatMap({ Int($0.filter(\.isNumber)) }), restricted > 0 {
                answers.append(Answer(mark: .neutral, question: String(localized: "Any restrictions", bundle: .previewKit, comment: "Trust card question (written without its question mark)."),
                                      answer: String(localized: "\(restricted) of them", bundle: .previewKit, comment: "Trust card answer: how many keys carry options; e.g. “2 of them”."), evidence: v("options")))
            }
            return BinaryCard(kind: doc.kind, title: fileName, sentence: sentence, bold: [keys.formatted()],
                              stageChip: String(localized: "SSH keys", bundle: .previewKit, comment: "The kind chip on authorized_keys and known_hosts cards."),
                              strip: firstThree([Stat(value: keyText, label: PackageFacts.Key.keys),
                                                 (known ? v("hashed") : v("withOptions")).map { Stat(value: $0, label: known ? PackageFacts.Key.hashed : PackageFacts.Key.withOptions) }]),
                              rule: top,
                              verdict: verdict(worst, opening: opening, calmTitle: known ? String(localized: "Servers this Mac trusts", bundle: .previewKit, comment: "Calm verdict title for known_hosts.")
                                                                                        : String(localized: "Keys that can log in", bundle: .previewKit, comment: "Calm verdict title for authorized_keys."),
                                               calmReason: String(localized: "Each line is a public key; none of them is secret.", bundle: .previewKit, comment: "Calm verdict reason for a list of SSH keys.")),
                              answers: answers)
        }

        // A signing request, a bare public key, or nothing readable.
        let what = v("request") ?? v("publicKey").map { String(localized: "A public key (\($0))", bundle: .previewKit, comment: "A bare public key; the argument is its algorithm and size.") }
            ?? v("form") ?? Phrase.unknown
        return BinaryCard(kind: doc.kind, title: fileName, sentence: what + ".", bold: [], stageChip: chip, strip: [], rule: top,
                          verdict: verdict(worst, opening: opening, calmTitle: what, calmReason: local), answers: answers)
    }
}
