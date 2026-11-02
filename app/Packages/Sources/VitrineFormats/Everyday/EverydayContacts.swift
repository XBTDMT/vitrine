import Foundation

/// The contact cards in a vCard file (`.vcf`, vCard 2.1, 3.0 and 4.0) (N-4): for each person their name,
/// organisation and title, email addresses, phone numbers, postal addresses, birthday and photo. These are shown to
/// the person who owns the file, so values are kept as written (decoded from quoted-printable or base64 where the
/// card encodes them). roadmap: S-23
public struct ContactsSummary: Sendable, Equatable {
    /// A value with its labels (`work`, `home`, `cell`, `pref`…, lowercased). roadmap: S-23
    public struct Labeled: Sendable, Equatable {
        public var labels: [String]
        public var value: String
    }

    /// A postal address split into its parts (empty parts are nil). roadmap: S-23
    public struct Address: Sendable, Equatable {
        public var labels: [String]
        public var poBox: String?
        public var extended: String?
        public var street: String?
        public var locality: String?
        public var region: String?
        public var postalCode: String?
        public var country: String?

        /// The parts joined over lines for display.
        public var formatted: String {
            let cityLine = [postalCode, locality, region].compactMap { $0 }.joined(separator: " ")
            return [poBox, extended, street, cityLine.isEmpty ? nil : cityLine, country].compactMap { $0 }.joined(separator: "\n")
        }
    }

    /// The N property's parts. roadmap: S-23
    public struct Name: Sendable, Equatable {
        public var family: String?
        public var given: String?
        public var additional: String?
        public var prefix: String?
        public var suffix: String?
    }

    /// A contact photo: the bytes when the card embeds at most `ContactsSummary.maxPhotoBytes`, or the link when it
    /// points elsewhere (never fetched). roadmap: S-23
    public struct Photo: Sendable, Equatable {
        public var data: Data?
        /// `image/jpeg` and so on, when the card says.
        public var mediaType: String?
        /// A non-data URI as written (not fetched).
        public var uri: String?
        /// The embedded image's size, even when it was too large to keep.
        public var byteCount: Int
    }

    /// One vCard. roadmap: S-23
    public struct Contact: Sendable, Equatable {
        /// VERSION as written (`2.1`, `3.0`, `4.0`).
        public var version: String?
        public var formattedName: String?
        public var name: Name?
        public var nickname: String?
        public var organization: String?
        /// Organisational units after the organisation name.
        public var department: String?
        public var title: String?
        public var role: String?
        public var emails: [Labeled]
        public var phones: [Labeled]
        public var addresses: [Address]
        public var urls: [Labeled]
        /// BDAY as `yyyy-mm-dd` (or `--mm-dd` without a year) when it can be read, else as written.
        public var birthday: String?
        public var note: String?
        public var photo: Photo?

        /// The best name to show: FN, else N's parts, else the organisation, else the first email.
        public var displayName: String {
            if let formattedName, !formattedName.isEmpty { return formattedName }
            if let name {
                let joined = [name.prefix, name.given, name.additional, name.family, name.suffix].compactMap { $0 }.joined(separator: " ")
                if !joined.isEmpty { return joined }
            }
            return organization ?? emails.first?.value ?? phones.first?.value
                ?? String(localized: "Unnamed contact", bundle: .module, comment: "Name shown for a contact card that has no name, organisation, email or phone.")
        }
    }

    public static let maxCards = 10_000
    public static let maxPhotoBytes = 2 * 1024 * 1024

    public var cards: [Contact]
    /// Every card counted, even past `maxCards`.
    public var cardCount: Int
    public var warnings: [EverydayWarning]
    public var truncated: Bool

    public var headline: String {
        if cardCount == 1 {
            return cards.first?.displayName ?? String(localized: "Contact", bundle: .module, comment: "Headline of a contact card file holding one card.")
        }
        return String(localized: "\(cardCount) contacts", bundle: .module, comment: "Headline of a contact card file; the argument is a count of cards.")
    }

    public var facts: [EverydayFact] {
        var facts: [EverydayFact] = [EverydayFact(String(localized: "Contacts", bundle: .module, comment: "Fact label on a contacts card: number of cards."),
                                                  "\(cardCount)")]
        if cardCount == 1, let card = cards.first {
            if let organization = card.organization {
                facts.append(EverydayFact(String(localized: "Organization", bundle: .module, comment: "Fact label on a contact card."), organization))
            }
            if let title = card.title {
                facts.append(EverydayFact(String(localized: "Title", bundle: .module, comment: "Fact label on a contact card: job title."), title))
            }
            if let email = card.emails.first {
                facts.append(EverydayFact(String(localized: "Email", bundle: .module, comment: "Fact label on a contact card."), email.value))
            }
            if let phone = card.phones.first {
                facts.append(EverydayFact(String(localized: "Phone", bundle: .module, comment: "Fact label on a contact card."), phone.value))
            }
            if let birthday = card.birthday {
                facts.append(EverydayFact(String(localized: "Birthday", bundle: .module, comment: "Fact label on a contact card."), birthday))
            }
        } else {
            let withEmail = cards.filter { !$0.emails.isEmpty }.count
            let withPhone = cards.filter { !$0.phones.isEmpty }.count
            facts.append(EverydayFact(String(localized: "With email", bundle: .module, comment: "Fact label on a contacts card: cards that have an email address."),
                                      "\(withEmail)"))
            facts.append(EverydayFact(String(localized: "With phone", bundle: .module, comment: "Fact label on a contacts card: cards that have a phone number."),
                                      "\(withPhone)"))
        }
        let versions = Array(Set(cards.compactMap(\.version))).sorted()
        if !versions.isEmpty {
            facts.append(EverydayFact(String(localized: "vCard version", bundle: .module, comment: "Fact label on a contacts card. vCard is a format name."),
                                      versions.joined(separator: ", ")))
        }
        return facts
    }
}

/// The vCard parser behind `ContactsSummary`.
enum EverydayContacts {
    static func read(_ bytes: [UInt8]) -> ContactsSummary? {
        let (lines, linesTruncated) = EverydayContentLines.unfold(EverydayText.decode(bytes))
        guard lines.contains(where: { $0.uppercased().hasPrefix("BEGIN:VCARD") }) else { return nil }
        var summary = ContactsSummary(cards: [], cardCount: 0, warnings: [], truncated: linesTruncated)
        var current: [EverydayContentLine]?
        var unterminated = 0
        var largePhotos = 0
        var unnamed = 0
        func finishCard(_ lines: [EverydayContentLine]) {
            summary.cardCount += 1
            guard summary.cards.count < ContactsSummary.maxCards else { summary.truncated = true; return }
            let card = contact(lines, largePhotos: &largePhotos)
            if card.formattedName == nil && card.name == nil { unnamed += 1 }
            summary.cards.append(card)
        }
        for raw in lines {
            guard let line = EverydayContentLines.parse(raw) else { continue }
            if line.name == "BEGIN", line.value.uppercased().trimmingCharacters(in: .whitespaces) == "VCARD" {
                if let open = current { unterminated += 1; finishCard(open) }
                current = []
            } else if line.name == "END", line.value.uppercased().trimmingCharacters(in: .whitespaces) == "VCARD" {
                if let open = current { finishCard(open) }
                current = nil
            } else if current != nil, current!.count < 5_000 {
                current!.append(line)
            }
        }
        if let open = current { unterminated += 1; finishCard(open) }
        if unterminated > 0 {
            summary.warnings.append(EverydayWarning(.caution, code: "contacts.unterminated",
                reason: String(localized: "\(unterminated) cards are missing END:VCARD; what was there was read.", bundle: .module,
                               comment: "Warning on a contacts card; the argument is a count of cards. END:VCARD stays as it is.")))
        }
        if largePhotos > 0 {
            summary.warnings.append(EverydayWarning(.caution, code: "contacts.largePhoto",
                reason: String(localized: "\(largePhotos) photos are larger than 2 MB and were not loaded.", bundle: .module,
                               comment: "Warning on a contacts card; the argument is a count of photos.")))
        }
        if unnamed > 0 {
            summary.warnings.append(EverydayWarning(.caution, code: "contacts.unnamed",
                reason: String(localized: "\(unnamed) cards have no name.", bundle: .module,
                               comment: "Warning on a contacts card; the argument is a count of cards.")))
        }
        return summary
    }

    /// The value of a property decoded: quoted-printable with its charset (vCard 2.1), base64 text, escapes undone.
    static func decodedValue(_ line: EverydayContentLine) -> String {
        let encoding = line.parameter("ENCODING")?.uppercased()
        let charset = line.parameter("CHARSET")
        if encoding == "QUOTED-PRINTABLE" {
            let decoded = EverydayText.quotedPrintable(Array(line.value.utf8))
            return EverydayContentLine.unescape(EverydayText.decode(decoded, charset: charset ?? "utf-8"))
        }
        if encoding == "BASE64" || encoding == "B", line.name != "PHOTO", line.name != "LOGO", line.name != "SOUND",
           line.name != "KEY", let bytes = EverydayText.base64(line.value) {
            return EverydayText.decode(bytes, charset: charset ?? "utf-8")
        }
        // An 8-bit vCard 2.1 file in a non-UTF-8 charset was already read as Windows-1252 by EverydayText.decode.
        return line.text
    }

    /// The parts of a structured value (N, ADR, ORG) decoded.
    static func decodedComponents(_ line: EverydayContentLine) -> [String] {
        if line.parameter("ENCODING")?.uppercased() == "QUOTED-PRINTABLE" {
            let decoded = EverydayText.decode(EverydayText.quotedPrintable(Array(line.value.utf8)),
                                              charset: line.parameter("CHARSET") ?? "utf-8")
            return EverydayContentLine(group: nil, name: line.name, parameters: [], value: decoded).components()
        }
        return line.components()
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func contact(_ lines: [EverydayContentLine], largePhotos: inout Int) -> ContactsSummary.Contact {
        var card = ContactsSummary.Contact(emails: [], phones: [], addresses: [], urls: [])
        for line in lines {
            switch line.name {
            case "VERSION": card.version = nonEmpty(line.value)
            case "FN": card.formattedName = nonEmpty(decodedValue(line))
            case "N":
                let parts = decodedComponents(line).map { nonEmpty($0) }
                func part(_ i: Int) -> String? { i < parts.count ? parts[i]?.replacingOccurrences(of: ",", with: " ") : nil }
                let name = ContactsSummary.Name(family: part(0), given: part(1), additional: part(2), prefix: part(3), suffix: part(4))
                if [name.family, name.given, name.additional, name.prefix, name.suffix].contains(where: { $0 != nil }) {
                    card.name = name
                }
            case "NICKNAME": card.nickname = nonEmpty(decodedValue(line))
            case "ORG":
                let parts = decodedComponents(line).compactMap { nonEmpty($0) }
                card.organization = parts.first
                if parts.count > 1 { card.department = parts.dropFirst().joined(separator: ", ") }
            case "TITLE": card.title = nonEmpty(decodedValue(line))
            case "ROLE": card.role = nonEmpty(decodedValue(line))
            case "EMAIL":
                if let value = nonEmpty(decodedValue(line)), card.emails.count < 100 {
                    let address = value.lowercased().hasPrefix("mailto:") ? String(value.dropFirst(7)) : value
                    card.emails.append(.init(labels: line.types.filter { $0 != "internet" }, value: address))
                }
            case "TEL":
                if var value = nonEmpty(decodedValue(line)), card.phones.count < 100 {
                    if value.lowercased().hasPrefix("tel:") { value = String(value.dropFirst(4)) }
                    card.phones.append(.init(labels: line.types.filter { $0 != "voice" }, value: value))
                }
            case "URL":
                if let value = nonEmpty(decodedValue(line)), card.urls.count < 100 {
                    card.urls.append(.init(labels: line.types, value: value))
                }
            case "ADR":
                guard card.addresses.count < 50 else { continue }
                let parts = decodedComponents(line).map { nonEmpty($0) }
                func part(_ i: Int) -> String? { i < parts.count ? parts[i] : nil }
                let address = ContactsSummary.Address(labels: line.types, poBox: part(0), extended: part(1), street: part(2),
                                                      locality: part(3), region: part(4), postalCode: part(5), country: part(6))
                if !address.formatted.isEmpty { card.addresses.append(address) }
            case "BDAY": card.birthday = nonEmpty(line.value).map(normalizeBirthday)
            case "NOTE": card.note = nonEmpty(decodedValue(line)).map { EverydayText.cap($0, 4_000) }
            case "PHOTO":
                if card.photo == nil { card.photo = photo(line, largePhotos: &largePhotos) }
            default: break
            }
        }
        return card
    }

    /// `19900214`, `1990-02-14`, `1990-02-14T00:00:00Z`, `--0214` → `1990-02-14` / `--02-14`; else as written.
    static func normalizeBirthday(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("--") {
            let digits = text.dropFirst(2).filter(\.isNumber)
            if digits.count == 4 { return "--\(digits.prefix(2))-\(digits.suffix(2))" }
            return text
        }
        let datePart = text.split(separator: "T").first.map(String.init) ?? text
        let digits = datePart.filter(\.isNumber)
        if digits.count == 8, datePart.count == 8 || datePart.count == 10 {
            let y = digits.prefix(4), m = digits.dropFirst(4).prefix(2), d = digits.suffix(2)
            if let mm = Int(m), let dd = Int(d), (1...12).contains(mm), (1...31).contains(dd) { return "\(y)-\(m)-\(d)" }
        }
        return text
    }

    static func photo(_ line: EverydayContentLine, largePhotos: inout Int) -> ContactsSummary.Photo? {
        let encoding = line.parameter("ENCODING")?.uppercased()
        var mediaType = line.parameter("MEDIATYPE") ?? line.types.first.map { type -> String in
            type.contains("/") ? type : "image/\(type == "jpg" ? "jpeg" : type)"
        }
        let value = line.value.trimmingCharacters(in: .whitespaces)
        var payload: Substring?
        if encoding == "B" || encoding == "BASE64" {
            payload = Substring(value)
        } else if value.lowercased().hasPrefix("data:"), let comma = value.firstIndex(of: ",") {
            let header = value[value.index(value.startIndex, offsetBy: 5)..<comma]
            let pieces = header.split(separator: ";")
            if let type = pieces.first, type.contains("/") { mediaType = String(type) }
            guard pieces.contains(where: { $0.lowercased() == "base64" }) else {
                return .init(data: nil, mediaType: mediaType, uri: nil, byteCount: 0)
            }
            payload = value[value.index(after: comma)...]
        }
        guard let payload else {
            return value.isEmpty ? nil : .init(data: nil, mediaType: mediaType, uri: EverydayText.cap(value, 2_048), byteCount: 0)
        }
        let size = EverydayText.base64Size(payload)
        guard size <= ContactsSummary.maxPhotoBytes else {
            largePhotos += 1
            return .init(data: nil, mediaType: mediaType, uri: nil, byteCount: size)
        }
        guard let bytes = EverydayText.base64(payload) else { return .init(data: nil, mediaType: mediaType, uri: nil, byteCount: 0) }
        return .init(data: Data(bytes), mediaType: mediaType, uri: nil, byteCount: bytes.count)
    }
}
