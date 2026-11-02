import AppKit
import VitrineFormats
import VitrineUI

/// Format view F7 (invite), option A (picked): a calendar invite drawn as a small card on the lit stage, in the card
/// language: the date block, the kind and how far away it is, the title, the day, time and place, the hour the event
/// takes on a strip of the day, then the time with its zone (or the caution that the file names none), where, who
/// organised it, who is invited and how they answered, the repeat rule and the alert. A drawn summary of the file,
/// never the person's own calendar; nothing is added anywhere. roadmap: S-23
@MainActor
final class InviteStageView: NSView {
    /// One line under the strip: a glyph and its words, in a tone.
    struct Line: Equatable {
        enum Tone: Equatable { case plain, quiet, caution, danger }
        var symbol: String
        var text: String
        var tone: Tone = .plain
        /// Initials of people drawn as an avatar stack before the words (the organiser, the guests).
        var avatars: [String] = []
    }

    let calendar: CalendarSummary
    let event: CalendarSummary.Event?
    let dateTile: DocStageDateTile
    let kicker: NSTextField
    let titleField: NSTextField
    let whenField: NSTextField
    let strip: DocStageHourStrip?
    let lines: [Line]
    private(set) var lineFields: [NSTextField] = []
    private var lineGlyphs: [NSImageView] = []
    let footer: NSTextField?
    private var cardFrame = NSRect.zero
    private var avatarRects: [(NSRect, String)] = []
    private(set) var visibleLineCount = 0

    init(calendar: CalendarSummary) {
        self.calendar = calendar
        let event = calendar.events.first
        self.event = event
        let start = event?.start ?? calendar.todos.first?.due
        dateTile = DocStageDateTile(components: start?.components)
        kicker = DocStage.label(Self.kicker(calendar: calendar, event: event, start: start).uppercased(),
                                font: tokenFont("fs-caption", weight: 600), color: event?.status == "CANCELLED" ? "danger-text" : "t2")
        let title = event?.summary ?? calendar.todos.first?.summary ?? calendar.headline
        titleField = DocStage.label(title, font: tokenFont("fs-title3"), color: "t1")
        if event?.status == "CANCELLED" {
            titleField.attributedStringValue = NSAttributedString(string: title, attributes: [
                .font: tokenFont("fs-title3"), .foregroundColor: NSColor.token("t2"), .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ])
        }
        whenField = DocStage.label(Self.summaryLine(event: event, start: start), font: tokenFont("fs-control"), color: "t2")
        strip = event.flatMap { e in Self.span(e).map { DocStageHourStrip(start: $0.start, end: $0.end, allDay: e.isAllDay, title: title) } }
        lines = event.map { Self.lines(for: $0, calendar: calendar) } ?? []
        let more = calendar.eventCount - 1
        footer = more > 0
            ? DocStage.label(String(localized: "\(more) more events in this file", bundle: .previewKit,
                                    comment: "Invite stage footer: the calendar file holds more events than the one drawn; the argument is how many."),
                             font: tokenFont("fs-caption"), color: "t3")
            : nil
        super.init(frame: .zero)
        for view in [dateTile, kicker, titleField, whenField] as [NSView] { addSubview(view) }
        if let strip { addSubview(strip) }
        for line in lines {
            let color = switch line.tone {
            case .plain: "t1"
            case .quiet: "t3"
            case .caution: "caution-text"
            case .danger: "danger-text"
            }
            let weight = line.tone == .danger ? 600 : line.tone == .caution ? 500 : 400
            let field = DocStage.label(line.text, font: tokenFont("fs-control", weight: weight), color: color)
            let glyphColor = line.tone == .caution ? "caution" : line.tone == .danger ? "danger" : "t2"
            let glyph = cardSymbol(line.symbol, size: 11, color: glyphColor, weight: .medium)
            glyph.translatesAutoresizingMaskIntoConstraints = true
            addSubview(glyph)
            addSubview(field)
            lineFields.append(field)
            lineGlyphs.append(glyph)
        }
        if let footer { addSubview(footer) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // MARK: Words

    static func kicker(calendar: CalendarSummary, event: CalendarSummary.Event?, start: CalendarSummary.When?) -> String {
        let kind: String
        if event?.status == "CANCELLED" || calendar.method == "CANCEL" {
            kind = String(localized: "Cancelled", bundle: .previewKit, comment: "Invite stage kicker: the event was cancelled.")
        } else if calendar.method == "REQUEST" {
            kind = String(localized: "Invitation", bundle: .previewKit, comment: "Invite stage kicker: the file is an invitation.")
        } else if calendar.method == "REPLY" {
            kind = String(localized: "Reply", bundle: .previewKit, comment: "Invite stage kicker: the file answers an invitation.")
        } else if event == nil, !calendar.todos.isEmpty {
            kind = String(localized: "To-do", bundle: .previewKit, comment: "Invite stage kicker: the file holds a to-do, not an event.")
        } else {
            kind = String(localized: "Event", bundle: .previewKit, comment: "Invite stage kicker: a calendar event.")
        }
        guard let day = start.flatMap(localDay) else { return kind }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: day)).day ?? 0
        let relative = RelativeDateTimeFormatter()
        relative.dateTimeStyle = .named
        relative.unitsStyle = .full
        return kind + " · " + relative.localizedString(from: DateComponents(day: days))
    }

    /// The day the event falls on, for "in 11 days": the moment in this Mac's zone when known, else the date as written.
    static func localDay(_ when: CalendarSummary.When) -> Date? {
        if let date = when.date, !when.isFloating { return date }
        var c = DateComponents(year: when.components.year, month: when.components.month, day: when.components.day)
        c.hour = 12
        return Calendar.current.date(from: c)
    }

    /// The calendar the wall-clock dates are reckoned in: Gregorian in UTC, whatever this Mac's zone.
    static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Wall-clock fields as written, as a Date in UTC so a UTC formatter prints them unchanged.
    static func wallClock(_ components: DateComponents) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var c = DateComponents(year: components.year, month: components.month, day: components.day,
                               hour: components.hour ?? 0, minute: components.minute ?? 0)
        c.second = 0
        return cal.date(from: c)
    }

    static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    /// The end as written, or the start plus the stated duration.
    static func endComponents(_ event: CalendarSummary.Event) -> DateComponents? {
        if let end = event.end?.components { return end }
        guard let duration = event.duration, let start = event.start, let date = wallClock(start.components) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.dateComponents([.year, .month, .day, .hour, .minute], from: date.addingTimeInterval(duration))
    }

    /// "Thu 12 Nov · 14:00–15:00 · Pier 9 Studio" (all-day: "Thu 12 Nov · All day").
    static func summaryLine(event: CalendarSummary.Event?, start: CalendarSummary.When?) -> String {
        guard let start, let date = wallClock(start.components) else {
            return event?.location ?? String(localized: "No date in the file", bundle: .previewKit, comment: "Invite stage: the event has no start date.")
        }
        var parts = [formatter("EEEdMMM").string(from: date)]
        if start.isAllDay || event?.isAllDay == true {
            parts.append(String(localized: "All day", bundle: .previewKit, comment: "Invite stage: an all-day event."))
        } else {
            parts.append(timeRange(event: event, start: start))
        }
        if let location = event?.location, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: " · ")
    }

    static func timeRange(event: CalendarSummary.Event?, start: CalendarSummary.When) -> String {
        guard let from = wallClock(start.components) else { return "" }
        let time = formatter("jmm")
        var text = time.string(from: from)
        if let event, let endC = endComponents(event), let to = wallClock(endC) {
            text += "–" + time.string(from: to)
            if !utcCalendar.isDate(from, inSameDayAs: to) {
                text += " " + formatter("EEEdMMM").string(from: to)
            }
        }
        return text
    }

    /// Wall-clock minutes from the start day's midnight to the start and the end, for the hour strip.
    static func span(_ event: CalendarSummary.Event) -> (start: Double, end: Double)? {
        guard let start = event.start, let from = wallClock(start.components) else { return nil }
        let midnight = utcCalendar.startOfDay(for: from)
        if event.isAllDay || start.isAllDay { return (0, 24 * 60) }
        let s = from.timeIntervalSince(midnight) / 60
        var e = s + 60
        if let endC = endComponents(event), let to = wallClock(endC) { e = max(s + 15, to.timeIntervalSince(midnight) / 60) }
        return (s, e)
    }

    static func lines(for event: CalendarSummary.Event, calendar: CalendarSummary) -> [Line] {
        var lines: [Line] = []
        // When, with its zone.
        if let start = event.start, !(event.isAllDay || start.isAllDay) {
            let range = timeRange(event: event, start: start)
            if start.isUTC {
                lines.append(Line(symbol: "clock", text: range + " · UTC"))
            } else if let zone = start.timeZone {
                let id = start.timeZoneID ?? zone.identifier
                let abbreviation = start.date.flatMap { zone.abbreviation(for: $0) } ?? zone.abbreviation() ?? ""
                lines.append(Line(symbol: "clock", text: range + " · " + id + (abbreviation.isEmpty || abbreviation == id ? "" : " (\(abbreviation))")))
            } else if let id = start.timeZoneID {
                lines.append(Line(symbol: "exclamationmark.triangle.fill",
                                  text: String(localized: "\(range) · unknown time zone “\(id)”", bundle: .previewKit,
                                               comment: "Invite stage: the event names a time zone this Mac does not know; arguments: the time range and the zone as written."),
                                  tone: .caution))
            } else {
                lines.append(Line(symbol: "exclamationmark.triangle.fill",
                                  text: String(localized: "\(range) · no time zone in the file, so it may be meant for another", bundle: .previewKit,
                                               comment: "Invite stage: the event's time has no zone (floating); the argument is the time range."),
                                  tone: .caution))
            }
        } else if event.start != nil {
            lines.append(Line(symbol: "clock", text: String(localized: "All day", bundle: .previewKit, comment: "Invite stage: an all-day event.")))
        }
        if let location = event.location, !location.isEmpty {
            lines.append(Line(symbol: "mappin.and.ellipse", text: location))
        }
        if let organizer = event.organizer, let name = organizer.name ?? organizer.email {
            lines.append(Line(symbol: "person.crop.circle",
                              text: String(localized: "Organised by \(name)", bundle: .previewKit, comment: "Invite stage: who organised the event; the argument is a name."),
                              avatars: [DocStage.initials(name)]))
        }
        if event.attendeeCount > 0 {
            let a = event.answers
            var parts = [String(localized: "\(event.attendeeCount) guests", bundle: .previewKit, comment: "Invite stage: number of people invited.")]
            if a.accepted > 0 { parts.append(String(localized: "\(a.accepted) accepted", bundle: .previewKit, comment: "Invite stage: guests who accepted.")) }
            if a.tentative > 0 { parts.append(String(localized: "\(a.tentative) maybe", bundle: .previewKit, comment: "Invite stage: guests who answered maybe.")) }
            if a.declined > 0 { parts.append(String(localized: "\(a.declined) declined", bundle: .previewKit, comment: "Invite stage: guests who declined.")) }
            if a.needsAction > 0 { parts.append(String(localized: "\(a.needsAction) not answered", bundle: .previewKit, comment: "Invite stage: guests who have not answered.")) }
            let initials = event.attendees.prefix(5).map { DocStage.initials($0.person.name ?? $0.person.email ?? "?") }
            lines.append(Line(symbol: "person.2", text: parts.joined(separator: " · "), avatars: Array(initials)))
        }
        if let recurrence = event.recurrence {
            var text = recurrence
            if event.exceptionCount > 0 {
                text += " · " + String(localized: "\(event.exceptionCount) dates skipped", bundle: .previewKit,
                                       comment: "Invite stage: dates excluded from a repeating event.")
            }
            lines.append(Line(symbol: "repeat", text: text))
        } else {
            lines.append(Line(symbol: "repeat", text: String(localized: "Does not repeat", bundle: .previewKit, comment: "Invite stage: the event happens once."), tone: .quiet))
        }
        if let alarm = event.alarms.first {
            let procedure = alarm.action == "PROCEDURE"
            lines.append(Line(symbol: procedure ? "exclamationmark.octagon.fill" : "bell",
                              text: procedure
                                ? String(localized: "Alert runs a program: \(alarm.trigger)", bundle: .previewKit,
                                         comment: "Invite stage: the event's alarm would run a program (iCalendar PROCEDURE); the argument is when.")
                                : alarm.trigger,
                              tone: procedure ? .danger : .plain))
        }
        return lines
    }

    // MARK: Layout and drawing

    static let lineHeight: CGFloat = 24

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let cardW = min(500, max(240, w - 32))
        let pad: CGFloat = 16
        let inner = cardW - 2 * pad
        // Heights first, so the card can be centred.
        let headerH: CGFloat = 50
        let stripH: CGFloat = strip == nil ? 0 : 58
        let footerH: CGFloat = footer == nil ? 0 : 20
        let fixed = 14 + headerH + (strip == nil ? 0 : 12 + stripH) + 8 + footerH + 14
        let maxCardH = max(0, h - 8)
        let fit = max(0, Int((maxCardH - fixed) / Self.lineHeight))
        visibleLineCount = min(lines.count, fit)
        let cardH = min(maxCardH, fixed + CGFloat(visibleLineCount) * Self.lineHeight)
        cardFrame = NSRect(x: ((w - cardW) / 2).rounded(), y: max(0, ((h - cardH) / 2).rounded()), width: cardW, height: cardH)
        let x0 = cardFrame.minX + pad
        var y = cardFrame.minY + 14

        dateTile.frame = NSRect(x: x0, y: y + 1, width: 46, height: 48)
        let tx = x0 + 46 + 12, tw = max(0, inner - 58)
        kicker.frame = NSRect(x: tx, y: y + 2, width: tw, height: 14)
        titleField.frame = NSRect(x: tx, y: y + 15, width: tw, height: 20)
        whenField.frame = NSRect(x: tx, y: y + 34, width: tw, height: 16)
        y += headerH
        if let strip {
            y += 12
            strip.frame = NSRect(x: x0, y: y, width: inner, height: stripH)
            y += stripH
        }
        y += 8
        avatarRects = []
        for (i, line) in lines.enumerated() {
            let visible = i < visibleLineCount
            lineFields[i].isHidden = !visible
            lineGlyphs[i].isHidden = !visible
            guard visible else { continue }
            let mid = y + Self.lineHeight / 2
            lineGlyphs[i].frame = NSRect(x: x0, y: mid - 8, width: 16, height: 16)
            var x = x0 + 24
            for (k, initials) in line.avatars.enumerated() {
                avatarRects.append((NSRect(x: x + CGFloat(k) * 21, y: mid - 9, width: 18, height: 18), initials))
            }
            if !line.avatars.isEmpty { x += CGFloat(line.avatars.count - 1) * 21 + 18 + 8 }
            lineFields[i].frame = NSRect(x: x, y: mid - 8, width: max(0, cardFrame.maxX - pad - x), height: 16)
            y += Self.lineHeight
        }
        footer?.frame = NSRect(x: x0, y: y + 2, width: inner, height: 16)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        DocStage.drawPanel(cardFrame, radius: Metric.value("r-panel"), fill: "card", ring: nil, shadow: "shadow-pop")
        if visibleLineCount > 0, let first = lineGlyphs.first {
            NSColor.token("sep").setFill()
            NSRect(x: cardFrame.minX + 16, y: first.frame.minY - 8 + 2, width: cardFrame.width - 32, height: 0.5).fill()
        }
        // Avatars in a row, as the guest list draws them.
        for (rect, initials) in avatarRects {
            DocStage.drawAvatar(in: rect, initials: initials, image: nil, flipped: true)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The date block (`.dtile`): the month in white on the calendar red band, the day large beneath, on a light tile
/// with a hairline. roadmap: S-23
@MainActor
final class DocStageDateTile: NSView {
    let month: String
    let day: String

    init(components: DateComponents?) {
        if let components, let date = InviteStageView.wallClock(components) {
            month = InviteStageView.formatter("MMM").string(from: date).uppercased().replacingOccurrences(of: ".", with: "")
            day = InviteStageView.formatter("d").string(from: date)
        } else {
            month = ""
            day = "–"
        }
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(month) \(day)")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DocStage.drawPanel(bounds, radius: 9, fill: "ctl", ring: "hair", shadow: "shadow-ctl")
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).addClip()
        NSColor.token("danger").setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 15).fill()
        NSGraphicsContext.restoreGraphicsState()
        let monthFont = systemFont(9.5, cssWeight: 700)
        let m = NSAttributedString(string: month, attributes: [.font: monthFont, .foregroundColor: NSColor.token("on-accent"), .kern: 0.6])
        m.draw(at: NSPoint(x: bounds.midX - m.size().width / 2, y: 7.5 - m.size().height / 2))
        let d = NSAttributedString(string: day, attributes: [.font: systemFont(22, cssWeight: 500), .foregroundColor: NSColor.token("t1")])
        d.draw(at: NSPoint(x: bounds.midX - d.size().width / 2, y: 15 + (bounds.height - 15) / 2 - d.size().height / 2))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The hour strip: the hours around the event as ticks along a dashed line, and the event as an accent block with
/// a 3 pt accent edge and its title (Fantastical's compact invite, option A's stage). roadmap: S-23
@MainActor
final class DocStageHourStrip: NSView {
    let startMinute: Double
    let endMinute: Double
    let allDay: Bool
    let title: String
    /// The first and last hour drawn, and the step between ticks.
    let hours: (first: Int, last: Int, step: Int)

    init(start: Double, end: Double, allDay: Bool, title: String) {
        startMinute = start
        endMinute = end
        self.allDay = allDay
        self.title = title
        if allDay {
            hours = (0, 24, 6)
        } else {
            let first = max(0, Int(floor(start / 60)) - 1)
            let last = Int(ceil(end / 60)) + 1
            let span = max(1, last - first)
            let step = span <= 4 ? 1 : span <= 8 ? 2 : span <= 18 ? 3 : 6
            hours = (first, first + Int(ceil(Double(span) / Double(step))) * step, step)
        }
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func x(forMinute minute: Double) -> CGFloat {
        let from = Double(hours.first * 60), to = Double(hours.last * 60)
        let usable = bounds.width - 30
        return CGFloat((minute - from) / max(1, to - from)) * usable
    }

    override func draw(_ dirtyRect: NSRect) {
        let dash = NSBezierPath()
        dash.move(to: NSPoint(x: 0, y: 0.25))
        dash.line(to: NSPoint(x: bounds.width, y: 0.25))
        dash.lineWidth = 0.5
        dash.setLineDash([3, 3], count: 2, phase: 0)
        NSColor.token("hair").setStroke()
        dash.stroke()

        let tickFont = tokenFont("fs-micro")
        let hourFormat = InviteStageView.formatter("j")
        var hour = hours.first
        while hour <= hours.last {
            let x = x(forMinute: Double(hour * 60)).rounded() + 0.25
            NSColor.token("sep").setFill()
            NSRect(x: x, y: 18, width: 0.5, height: bounds.height - 18).fill()
            let label = allDay && hour == 24 ? "" : hourFormat.string(from: Date(timeIntervalSince1970: TimeInterval(hour % 24 * 3600)))
            NSAttributedString(string: label, attributes: [.font: tickFont, .foregroundColor: NSColor.token("t3")])
                .draw(at: NSPoint(x: x + 3, y: 3))
            hour += hours.step
        }

        let x0 = x(forMinute: startMinute), x1 = max(x0 + 24, x(forMinute: endMinute))
        let block = NSRect(x: x0, y: 20, width: x1 - x0, height: bounds.height - 24)
        let path = NSBezierPath(roundedRect: block, xRadius: 5, yRadius: 5)
        NSColor.token("accent-soft").setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.token("accent").setFill()
        NSRect(x: block.minX, y: block.minY, width: 3, height: block.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        NSAttributedString(string: title, attributes: [.font: tokenFont("fs-caption", weight: 600), .foregroundColor: NSColor.token("accent-text"),
                                                       .paragraphStyle: style])
            .draw(with: block.insetBy(dx: 7, dy: 3).offsetBy(dx: 2, dy: 0), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
