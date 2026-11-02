import Foundation

/// A small, bounded reader for Microsoft compound files (CFB, "OLE2"; MS-CFB), enough to read an Outlook `.msg`:
/// the header, the FAT through the DIFAT, the mini FAT and mini stream, the directory, and whole streams. Every
/// sector chain is followed at most as many steps as the FAT has entries, every index is checked, and streams are
/// cut to the bytes the file actually has.
struct EverydayCFB {
    static let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let noStream: UInt32 = 0xFFFF_FFFF
    static let maxEntries = 50_000

    /// One directory entry.
    struct Entry {
        var name: String
        /// 1 storage, 2 stream, 5 root.
        var type: UInt8
        var left: UInt32
        var right: UInt32
        var child: UInt32
        var start: UInt32
        var size: UInt64
    }

    let bytes: [UInt8]
    let sectorSize: Int
    let miniSectorSize: Int
    let miniCutoff: UInt64
    private(set) var fat: [UInt32] = []
    private(set) var miniFAT: [UInt32] = []
    private(set) var entries: [Entry] = []
    private(set) var miniStream: [UInt8] = []
    /// A chain looped, pointed outside the file, the directory was cut short or the read budget ran out.
    private(set) var damaged = false
    /// Bytes all chain reads may copy in all. In a valid file every sector belongs to one chain, so reading every
    /// stream copies about the file's size; looping or shared chains would copy far more, and stop here instead.
    private(set) var budget: Int

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 512, bytes.starts(with: Self.magic) else { return nil }
        self.bytes = bytes
        let shift = Int(Self.u16(bytes, 0x1E))
        let miniShift = Int(Self.u16(bytes, 0x20))
        guard shift == 9 || shift == 12, (1...shift).contains(miniShift) else { return nil }
        sectorSize = 1 << shift
        miniSectorSize = 1 << miniShift
        miniCutoff = UInt64(Self.u32(bytes, 0x38))
        budget = bytes.count * 3 + 1_048_576

        // The FAT's sectors: the header's 109 DIFAT slots, then the DIFAT chain.
        let fatSectorCount = Int(Self.u32(bytes, 0x2C))
        let sectorsInFile = max(0, (bytes.count - sectorSize) / sectorSize + 1)
        guard fatSectorCount <= sectorsInFile else { return nil }
        var fatSectors: [UInt32] = []
        for i in 0..<109 where fatSectors.count < fatSectorCount {
            let sid = Self.u32(bytes, 0x4C + i * 4)
            if sid < 0xFFFF_FFFA { fatSectors.append(sid) }
        }
        var difat = Self.u32(bytes, 0x44)
        var difatSteps = 0
        let perDIFAT = sectorSize / 4 - 1
        while fatSectors.count < fatSectorCount, difat < 0xFFFF_FFFA, difatSteps < sectorsInFile {
            guard let base = offset(of: difat) else { damaged = true; break }
            for i in 0..<perDIFAT where fatSectors.count < fatSectorCount {
                let sid = Self.u32(bytes, base + i * 4)
                if sid < 0xFFFF_FFFA { fatSectors.append(sid) }
            }
            difat = Self.u32(bytes, base + perDIFAT * 4)
            difatSteps += 1
        }
        fat.reserveCapacity(fatSectors.count * sectorSize / 4)
        for sid in fatSectors {
            guard let base = offset(of: sid) else { damaged = true; continue }
            for i in 0..<(sectorSize / 4) { fat.append(Self.u32(bytes, base + i * 4)) }
        }

        // The directory.
        let directory = readChain(Self.u32(bytes, 0x30), size: nil)
        let count = min(directory.count / 128, Self.maxEntries)
        guard count > 0 else { return nil }
        for i in 0..<count {
            let base = i * 128
            let nameLength = min(64, Int(Self.u16(directory, base + 0x40)))
            let units = stride(from: 0, to: max(0, nameLength - 2), by: 2).map { Self.u16(directory, base + $0) }
            let name = String(decoding: units, as: UTF16.self)
            var size = UInt64(Self.u32(directory, base + 0x78))
            if sectorSize == 4096 { size |= UInt64(Self.u32(directory, base + 0x7C)) << 32 }
            entries.append(Entry(name: name, type: directory[base + 0x42], left: Self.u32(directory, base + 0x44),
                                 right: Self.u32(directory, base + 0x48), child: Self.u32(directory, base + 0x4C),
                                 start: Self.u32(directory, base + 0x74), size: size))
        }
        guard entries[0].type == 5 else { return nil }

        // The mini stream (held by the root entry) and the mini FAT.
        miniStream = readChain(entries[0].start, size: entries[0].size)
        let miniFATBytes = readChain(Self.u32(bytes, 0x3C), size: UInt64(Self.u32(bytes, 0x40)) * UInt64(sectorSize))
        miniFAT = stride(from: 0, to: miniFATBytes.count - 3, by: 4).map { Self.u32(miniFATBytes, $0) }
    }

    func offset(of sector: UInt32) -> Int? {
        let base = (Int(sector) + 1) * sectorSize
        return base >= 0 && base + sectorSize <= bytes.count ? base : nil
    }

    /// A regular-sector chain's bytes, cut to `size` when given.
    mutating func readChain(_ start: UInt32, size: UInt64?) -> [UInt8] {
        var out: [UInt8] = []
        let limit = Int(min(size ?? UInt64(bytes.count), UInt64(bytes.count)))
        var sid = start
        var steps = 0
        while sid < 0xFFFF_FFFA, out.count < limit {
            guard steps <= fat.count, let base = offset(of: sid) else { damaged = true; break }
            budget -= sectorSize
            guard budget >= 0 else { damaged = true; break }
            out += bytes[base..<(base + sectorSize)]
            guard Int(sid) < fat.count else { if out.count < limit, size != nil { damaged = true }; break }
            sid = fat[Int(sid)]
            steps += 1
        }
        if out.count > limit { out.removeSubrange(limit...) }
        return out
    }

    /// A stream's whole content (from the mini stream when it is under the cutoff), at most `maxBytes`.
    mutating func stream(_ index: Int, maxBytes: Int = EverydayReader.maxBytes) -> [UInt8] {
        guard entries.indices.contains(index), entries[index].type == 2 else { return [] }
        let entry = entries[index]
        let size = min(entry.size, UInt64(maxBytes))
        if entry.size < miniCutoff {
            var out: [UInt8] = []
            var sid = entry.start
            var steps = 0
            while sid < 0xFFFF_FFFA, out.count < Int(size) {
                let base = Int(sid) * miniSectorSize
                guard steps <= miniFAT.count, base + miniSectorSize <= miniStream.count else { damaged = true; break }
                budget -= miniSectorSize
                guard budget >= 0 else { damaged = true; break }
                out += miniStream[base..<(base + miniSectorSize)]
                guard Int(sid) < miniFAT.count else { break }
                sid = miniFAT[Int(sid)]
                steps += 1
            }
            if out.count > Int(size) { out.removeSubrange(Int(size)...) }
            return out
        }
        return readChain(entry.start, size: size)
    }

    /// The entries directly inside a storage, by name, at most `limit` of them (a recipient or attachment has a few
    /// dozen properties; the limit keeps a crafted sibling tree from being walked once per storage).
    func children(of index: Int, limit: Int = maxEntries) -> [String: Int] {
        guard entries.indices.contains(index) else { return [:] }
        var result: [String: Int] = [:]
        var stack = [entries[index].child]
        var seen = Set<UInt32>()
        while let id = stack.popLast() {
            guard id != Self.noStream, Int(id) < entries.count, seen.count < limit, seen.insert(id).inserted else { continue }
            let entry = entries[Int(id)]
            result[entry.name] = Int(id)
            stack.append(entry.left)
            stack.append(entry.right)
        }
        return result
    }

    static func u16(_ b: [UInt8], _ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= b.count else { return 0 }
        return UInt16(b[at]) | UInt16(b[at + 1]) << 8
    }

    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= b.count else { return 0 }
        return UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    static func u64(_ b: [UInt8], _ at: Int) -> UInt64 {
        UInt64(u32(b, at)) | UInt64(u32(b, at + 4)) << 32
    }
}

/// Reads an Outlook `.msg` (MS-OXMSG: MAPI properties stored in a compound file) into an `EmailSummary`.
enum EverydayOutlook {
    // MAPI property ids.
    static let subject: UInt16 = 0x0037, senderName: UInt16 = 0x0C1A, senderEmail: UInt16 = 0x0C1F
    static let senderSMTP: UInt16 = 0x5D01, representingName: UInt16 = 0x0042, representingEmail: UInt16 = 0x0065
    static let representingSMTP: UInt16 = 0x5D02, body: UInt16 = 0x1000, bodyHTML: UInt16 = 0x1013
    static let transportHeaders: UInt16 = 0x007D, messageID: UInt16 = 0x1035, submitTime: UInt16 = 0x0039
    static let deliveryTime: UInt16 = 0x0E06, messageClass: UInt16 = 0x001A, internetCodepage: UInt16 = 0x3FDE
    static let displayName: UInt16 = 0x3001, emailAddress: UInt16 = 0x3003, smtpAddress: UInt16 = 0x39FE
    static let recipientType: UInt16 = 0x0C15
    static let attachLongName: UInt16 = 0x3707, attachName: UInt16 = 0x3704, attachMime: UInt16 = 0x370E
    static let attachData: UInt16 = 0x3701, attachSize: UInt16 = 0x0E20, attachContentID: UInt16 = 0x3712
    static let attachHidden: UInt16 = 0x7FFE

    static let maxRecipients = 2_000
    static let maxAttachments = 1_000

    /// The properties of one storage (the message, a recipient or an attachment).
    struct Properties {
        var strings: [UInt16: String] = [:]
        var binaries: [UInt16: Int] = [:]        // id → directory index of the stream
        var binaryStorages: [UInt16: Int] = [:]  // id → directory index of an embedded object storage
        var fixed: [UInt16: (type: UInt16, value: UInt64)] = [:]

        func string(_ id: UInt16) -> String? {
            guard let s = strings[id]?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))),
                  !s.isEmpty else { return nil }
            return s
        }

        func long(_ id: UInt16) -> Int? {
            guard let p = fixed[id], p.type == 0x0003 else { return nil }
            return Int(Int32(bitPattern: UInt32(truncatingIfNeeded: p.value)))
        }

        func bool(_ id: UInt16) -> Bool? {
            guard let p = fixed[id], p.type == 0x000B else { return nil }
            return (p.value & 0xFFFF) != 0
        }

        func time(_ id: UInt16) -> Date? {
            guard let p = fixed[id], p.type == 0x0040, p.value > 0 else { return nil }
            let seconds = Double(p.value) / 10_000_000 - 11_644_473_600
            guard seconds.isFinite, abs(seconds) < 1e11 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    static func read(_ bytes: [UInt8]) -> EmailSummary? {
        guard var cfb = EverydayCFB(bytes) else { return nil }
        let rootChildren = cfb.children(of: 0)
        guard rootChildren.keys.contains(where: { $0.hasPrefix("__substg1.0_") || $0.hasPrefix("__properties_version1.0") }) else {
            return nil
        }
        var summary = EmailSummary(format: .msg)
        let message = properties(&cfb, rootChildren, headerSize: 32)

        summary.subject = message.string(subject)
        let fromName = message.string(representingName) ?? message.string(senderName)
        let fromAddress = smtp(message.string(representingSMTP), message.string(representingEmail))
            ?? smtp(message.string(senderSMTP), message.string(senderEmail))
        if fromName != nil || fromAddress != nil { summary.from = .init(name: fromName, address: fromAddress) }
        let senderAddress = smtp(message.string(senderSMTP), message.string(senderEmail))
        if let senderAddress, senderAddress.lowercased() != fromAddress?.lowercased() {
            summary.sender = .init(name: message.string(senderName), address: senderAddress)
        }
        summary.date = message.time(submitTime) ?? message.time(deliveryTime)
        summary.messageID = message.string(messageID)
        summary.plainBody = message.string(body).map { EverydayText.cap($0, EmailSummary.maxBodyCharacters) }
        if let html = message.string(bodyHTML) {
            summary.htmlBody = html
        } else if let index = message.binaries[bodyHTML] {
            let codepage = message.long(internetCodepage)
            summary.htmlBody = EverydayText.decode(cfb.stream(index), charset: codepage.flatMap(charset(forCodepage:)))
        }
        if let html = summary.htmlBody, html.count > EmailSummary.maxBodyCharacters {
            summary.htmlBody = String(html.prefix(EmailSummary.maxBodyCharacters))
            summary.truncated = true
        }

        // The internet headers the message arrived with, when Outlook kept them.
        if let headerText = message.string(transportHeaders) {
            let headers = EverydayMail.parseHeaders(ArraySlice(Array(headerText.utf8)))
            for header in headers.prefix(EmailSummary.maxHeaders) {
                summary.headers.append(EverydayFact(header.original, EverydayText.cap(EverydayMail.decodeWords(header.value), 4_000)))
            }
            if let value = headers.first(where: { $0.name == "authentication-results" })?.value {
                summary.authentication = EverydayMail.authentication(value)
            }
            if let dateText = headers.first(where: { $0.name == "date" })?.value {
                summary.dateText = EverydayText.collapse(dateText)
                if summary.date == nil { summary.date = EverydayMail.parseDate(dateText) }
            }
            if summary.from == nil, let from = headers.first(where: { $0.name == "from" }) {
                summary.from = EverydayMail.addresses(from.value).first
            }
            if summary.messageID == nil { summary.messageID = headers.first { $0.name == "message-id" }?.value }
        }

        // Recipients and attachments live in numbered sub-storages.
        let storages = rootChildren.sorted { $0.key < $1.key }
        for (name, index) in storages where name.hasPrefix("__recip_version1.0_") {
            guard summary.to.count + summary.cc.count + summary.bcc.count < maxRecipients else { summary.truncated = true; break }
            let recipient = properties(&cfb, cfb.children(of: index, limit: 1_000), headerSize: 8)
            let address = EmailSummary.Address(name: recipient.string(displayName),
                                               address: smtp(recipient.string(smtpAddress), recipient.string(emailAddress)))
            switch recipient.long(recipientType) ?? 1 {
            case 2: summary.cc.append(address)
            case 3: summary.bcc.append(address)
            default: summary.to.append(address)
            }
        }
        for (name, index) in storages where name.hasPrefix("__attach_version1.0_") {
            guard summary.attachments.count < maxAttachments else { summary.truncated = true; break }
            let attachment = properties(&cfb, cfb.children(of: index, limit: 1_000), headerSize: 8)
            var size = attachment.long(attachSize) ?? 0
            if let data = attachment.binaries[attachData] {
                size = Int(min(cfb.entries[data].size, UInt64(Int.max)))
            }
            let isEmbedded = attachment.binaryStorages[attachData] != nil
            let name = attachment.string(attachLongName) ?? attachment.string(attachName)
                ?? attachment.string(displayName).map { isEmbedded ? $0 + ".msg" : $0 }
            summary.attachments.append(.init(name: name,
                                             mediaType: attachment.string(attachMime)?.lowercased()
                                                ?? (isEmbedded ? "application/vnd.ms-outlook" : "application/octet-stream"),
                                             size: size, isInline: attachment.bool(attachHidden) ?? false,
                                             contentID: attachment.string(attachContentID)))
        }

        summary.parts = [.init(depth: 0, mediaType: "application/vnd.ms-outlook", name: nil, size: bytes.count,
                               disposition: nil, charset: nil, transferEncoding: nil)]
        if cfb.damaged {
            summary.truncated = true
            summary.warnings.append(EverydayWarning(.caution, code: "email.damagedFile",
                reason: String(localized: "Parts of the Outlook file are damaged or cut short; what could be read is shown.", bundle: .module,
                               comment: "Warning on an email card for an Outlook .msg file.")))
        }
        EverydayMail.addChecks(&summary)
        return summary
    }

    /// An SMTP address: the SMTP property when present, else the email property when it is an internet address
    /// (Exchange's X.500 `/O=…` addresses are not).
    static func smtp(_ smtp: String?, _ email: String?) -> String? {
        if let smtp, smtp.contains("@") { return smtp }
        if let email, email.contains("@"), !email.hasPrefix("/") { return email }
        return nil
    }

    static func charset(forCodepage codepage: Int) -> String? {
        switch codepage {
        case 65001: "utf-8"
        case 1252: "windows-1252"
        case 1250: "windows-1250"
        case 1251: "windows-1251"
        case 932: "shift_jis"
        case 936: "gb2312"
        case 949: "ks_c_5601-1987"
        case 950: "big5"
        case 28591: "iso-8859-1"
        default: nil
        }
    }

    static func properties(_ cfb: inout EverydayCFB, _ children: [String: Int], headerSize: Int) -> Properties {
        var props = Properties()
        for (name, index) in children {
            if name.hasPrefix("__substg1.0_") {
                let hex = name.dropFirst(12)
                guard hex.count >= 8, let tag = UInt32(hex.prefix(8), radix: 16) else { continue }
                let id = UInt16(tag >> 16), type = UInt16(tag & 0xFFFF)
                let entry = cfb.entries[index]
                if entry.type == 1 { props.binaryStorages[id] = index; continue }
                switch type {
                case 0x001F:
                    let raw = cfb.stream(index, maxBytes: 8 * 1024 * 1024)
                    let units = stride(from: 0, to: raw.count - 1, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
                    props.strings[id] = String(decoding: units, as: UTF16.self)
                case 0x001E:
                    props.strings[id] = EverydayText.decode(cfb.stream(index, maxBytes: 8 * 1024 * 1024))
                case 0x0102:
                    props.binaries[id] = index
                default: break
                }
            } else if name == "__properties_version1.0" {
                let raw = cfb.stream(index, maxBytes: 1024 * 1024)
                var at = headerSize
                while at + 16 <= raw.count {
                    let tag = EverydayCFB.u32(raw, at)
                    let id = UInt16(tag >> 16), type = UInt16(tag & 0xFFFF)
                    if [0x0002, 0x0003, 0x000B, 0x0014, 0x0040, 0x0005].contains(type) {
                        props.fixed[id] = (type, EverydayCFB.u64(raw, at + 8))
                    }
                    at += 16
                }
            }
        }
        return props
    }
}
