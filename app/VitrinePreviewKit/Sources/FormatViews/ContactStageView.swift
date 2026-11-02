import AppKit
import VitrineFormats
import VitrineUI

/// Format view F7 (contact), option A (picked): a contact card on the lit stage in the card language, as the
/// Contacts app centres it: the photo (or initials on the avatar gradient), the name, the title and organisation,
/// then the person's phone numbers and email addresses as labelled tiles. A file with several cards shows the first
/// and says how many more there are. An embedded photo is decoded off the main thread; a photo the card only links
/// to is never fetched. roadmap: S-23
@MainActor
final class ContactStageView: NSView {
    /// A phone number or email address drawn as a tile.
    struct Reach: Equatable {
        enum Kind: Equatable { case phone, email }
        var kind: Kind
        var label: String
        var value: String
    }

    let contacts: ContactsSummary
    let contact: ContactsSummary.Contact?
    let initials: String
    let nameField: NSTextField
    let subtitleField: NSTextField?
    let reach: [Reach]
    private(set) var reachValueFields: [NSTextField] = []
    private var reachLabelFields: [NSTextField] = []
    private var reachGlyphs: [NSImageView] = []
    let countField: NSTextField?
    private(set) var photo: CGImage?
    private var photoTask: Task<Void, Never>?
    private(set) var avatarFrame = NSRect.zero
    private var tileFrames: [NSRect] = []
    private(set) var visibleReachCount = 0

    static let maxReach = 6

    init(contacts: ContactsSummary) {
        self.contacts = contacts
        let contact = contacts.cards.first
        self.contact = contact
        let name = contact?.displayName ?? contacts.headline
        initials = DocStage.initials(contact?.name.map { [$0.given, $0.family].compactMap { $0 }.joined(separator: " ") }.flatMap { $0.isEmpty ? nil : $0 } ?? name)
        nameField = DocStage.label(name, font: systemFont(18, cssWeight: 650), color: "t1", alignment: .center)
        let subtitle = [contact?.title, contact?.organization.map { org in [org, contact?.department].compactMap { $0 }.joined(separator: ", ") }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        subtitleField = subtitle.isEmpty ? nil : DocStage.label(subtitle, font: tokenFont("fs-callout"), color: "t2", alignment: .center)
        var reach: [Reach] = []
        for phone in contact?.phones ?? [] {
            reach.append(Reach(kind: .phone, label: Self.label(phone.labels, fallback: String(localized: "phone", bundle: .previewKit,
                                                                                              comment: "Contact stage: label of a phone number with no type.")),
                               value: phone.value))
        }
        for email in contact?.emails ?? [] {
            reach.append(Reach(kind: .email, label: Self.label(email.labels, fallback: String(localized: "email", bundle: .previewKit,
                                                                                              comment: "Contact stage: label of an email address with no type.")),
                               value: email.value))
        }
        self.reach = Array(reach.prefix(Self.maxReach))
        let more = contacts.cardCount - 1
        countField = more > 0
            ? DocStage.label(String(localized: "and \(more) more contacts in this file", bundle: .previewKit,
                                    comment: "Contact stage: the file holds more cards than the one drawn; the argument is how many."),
                             font: tokenFont("fs-caption"), color: "t3", alignment: .center)
            : nil
        super.init(frame: .zero)
        addSubview(nameField)
        if let subtitleField { addSubview(subtitleField) }
        for item in self.reach {
            let glyph = cardSymbol(item.kind == .phone ? "phone" : "envelope", size: 11, color: "t2", weight: .medium)
            glyph.translatesAutoresizingMaskIntoConstraints = true
            let label = DocStage.label(item.label, font: tokenFont("fs-caption"), color: "t3")
            let value = DocStage.label(item.value, font: tokenFont("fs-callout", weight: 500), color: "t1")
            value.toolTip = item.value
            for v in [glyph, label, value] as [NSView] { addSubview(v) }
            reachGlyphs.append(glyph)
            reachLabelFields.append(label)
            reachValueFields.append(value)
        }
        if let countField { addSubview(countField) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(name)
        if let data = contact?.photo?.data {
            photoTask = Task { [weak self] in
                let decoded = await Task.detached(priority: .userInitiated) { DocStageImage.decode(data, maxPixel: 400) }.value
                guard let self else { return }
                self.photo = decoded?.cgImage
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Waits until an embedded photo is decoded (or found unreadable).
    func waitUntilDrawn() async { await photoTask?.value }

    /// The card's labels in plain words: `cell` → mobile, `pref` and `voice` dropped; the first that is left.
    static func label(_ labels: [String], fallback: String) -> String {
        let words = labels.map { $0.lowercased() }.filter { !["pref", "voice", "internet", "x400"].contains($0) && !$0.hasPrefix("x-") }
        guard let first = words.first else { return fallback }
        switch first {
        case "cell", "mobile", "iphone": return String(localized: "mobile", bundle: .previewKit, comment: "Contact stage: label of a mobile phone number.")
        case "work": return String(localized: "work", bundle: .previewKit, comment: "Contact stage: label of a work phone number or address.")
        case "home": return String(localized: "home", bundle: .previewKit, comment: "Contact stage: label of a home phone number or address.")
        case "fax": return String(localized: "fax", bundle: .previewKit, comment: "Contact stage: label of a fax number.")
        default: return first
        }
    }

    // MARK: Layout and drawing

    static let tileHeight: CGFloat = 44

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let avatar = max(56, min(104, (h * 0.30).rounded()))
        let nameH: CGFloat = 23, subH: CGFloat = subtitleField == nil ? 0 : 18
        let countH: CGFloat = countField == nil ? 0 : 18
        // Tiles: as many per row as fit (at most three), at most two rows, as much as the height allows.
        let tileGap: CGFloat = 10
        let perRow = max(1, min(3, reach.count, Int((w - 32 + tileGap) / (200 + tileGap))))
        let tileW = min(260, ((w - 32 - CGFloat(perRow - 1) * tileGap) / CGFloat(perRow)).rounded(.down))
        let head = avatar + 12 + nameH + subH
        let roomForTiles = h - head - countH - 18
        let rows = reach.isEmpty ? 0 : max(0, min(2, (reach.count + perRow - 1) / perRow, Int((roomForTiles + tileGap) / (Self.tileHeight + tileGap))))
        visibleReachCount = min(reach.count, rows * perRow)
        let tilesH = rows == 0 ? 0 : CGFloat(rows) * Self.tileHeight + CGFloat(rows - 1) * tileGap
        let total = head + (rows == 0 ? 0 : 18 + tilesH) + (countH > 0 ? 8 + countH : 0)
        var y = max(0, ((h - total) / 2).rounded())

        avatarFrame = NSRect(x: ((w - avatar) / 2).rounded(), y: y, width: avatar, height: avatar)
        y += avatar + 12
        nameField.frame = NSRect(x: 16, y: y, width: max(0, w - 32), height: nameH)
        y += nameH
        subtitleField?.frame = NSRect(x: 16, y: y, width: max(0, w - 32), height: 17)
        y += subH
        tileFrames = []
        if rows > 0 { y += 18 }
        for i in 0..<reach.count {
            let visible = i < visibleReachCount
            reachGlyphs[i].isHidden = !visible
            reachLabelFields[i].isHidden = !visible
            reachValueFields[i].isHidden = !visible
            guard visible else { continue }
            let row = i / perRow, col = i % perRow
            let inRow = min(perRow, visibleReachCount - row * perRow)
            let rowW = CGFloat(inRow) * tileW + CGFloat(inRow - 1) * tileGap
            let x = ((w - rowW) / 2).rounded() + CGFloat(col) * (tileW + tileGap)
            let tile = NSRect(x: x, y: y + CGFloat(row) * (Self.tileHeight + tileGap), width: tileW, height: Self.tileHeight)
            tileFrames.append(tile)
            reachGlyphs[i].frame = NSRect(x: tile.minX + 12, y: tile.minY + 14, width: 16, height: 16)
            reachLabelFields[i].frame = NSRect(x: tile.minX + 36, y: tile.minY + 6, width: tile.width - 46, height: 14)
            reachValueFields[i].frame = NSRect(x: tile.minX + 36, y: tile.minY + 21, width: tile.width - 46, height: 17)
        }
        y += tilesH
        countField?.frame = NSRect(x: 16, y: y + 8, width: max(0, w - 32), height: 16)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The avatar stands out from the stage with the object shadow, as the cover and the invite card do.
        if let drop = DocStage.shadow("shadow-obj").drop {
            NSGraphicsContext.saveGraphicsState()
            drop.set()
            NSColor.token("card").setFill()
            NSBezierPath(ovalIn: avatarFrame).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        DocStage.drawAvatar(in: avatarFrame, initials: initials, image: photo, flipped: true)
        for tile in tileFrames {
            DocStage.drawPanel(tile, radius: Metric.value("r-card"), fill: "card", ring: "hair", shadow: "shadow-card")
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
